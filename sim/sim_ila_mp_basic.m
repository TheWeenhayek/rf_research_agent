%% ========================================================================
%  SIM001 - Offline ILA with memory polynomial against a simulated PA
%  ----------------------------------------------------------------------
%  No hardware. Checks that the MP basis / regularized LS / ILA loop used in
%  code/EXP010-EXP020 converges on a known nonlinear PA with memory.
%  The helper functions below are copies of the ones in
%  code/EXP020_Iterative_ILA_DPDV2_7MPModels_NotebookExports_v1.m
%  (buildMPMatrix, applyMemoryPolynomial, solveRegularizedLS,
%  normalizeDPDWaveform, computeACPRCentered).
%  Requires: Signal Processing Toolbox (pwelch) only for ACPR.
%% ========================================================================

clear; close all; clc;
rng(1);

%% Configuration
M = 3;  K = 5;                 % MP structure, coefficients = (M+1)*K
numIter = 6;
coeffBlendMu = 0.5;            % 1 = replace coefficients every iteration
lambdaRel = 1e-2;
minAmpRatio = 0.08;
maxPeakRatio = 1.5;
inputRms = 0.45;               % sets how far into compression the PA runs

%% 5G-like OFDM test signal (15 kHz SCS, 600 active subcarriers, 4x oversampled)
nfft = 4096; nActive = 600; nSym = 40; scs = 15e3;
fs = nfft*scs; bw = nActive*scs;
x = [];
for s = 1:nSym
    S = zeros(nfft,1);
    idx = [nfft-nActive/2+1:nfft, 2:nActive/2+1];
    S(idx) = (sign(randn(nActive,1)) + 1j*sign(randn(nActive,1)))/sqrt(2);
    x = [x; ifft(S)*sqrt(nfft)]; %#ok<AGROW>
end
% Symbols are concatenated without CP/windowing, which leaves sinc skirts at
% about -24 dBc in the adjacent bands. Remove them (circular brick-wall filter)
% so that the ACPR floor of the input does not hide the PA distortion.
Xf = fft(x);
fAxis = (0:numel(x)-1).'/numel(x)*fs;
fAxis(fAxis >= fs/2) = fAxis(fAxis >= fs/2) - fs;
Xf(abs(fAxis) > 0.55*bw) = 0;
x = ifft(Xf);
x = x / sqrt(mean(abs(x).^2)) * inputRms;
fprintf('ACPR of the input signal itself: %.1f dBc\n', computeACPRCentered(x, fs, bw));
fprintf('Samples: %d, fs = %.2f MHz, bw = %.2f MHz, PAPR = %.1f dB\n', ...
    numel(x), fs/1e6, bw/1e6, 20*log10(max(abs(x))/rms(x)));

%% Closed loop
paFun = @(u) simulatedPA(u);

coeffs = zeros((M+1)*K,1); coeffs(1) = 1;     % identity: x passes unchanged
u = x;
res = struct('iter',[],'nmse',[],'acpr',[]);
for it = 0:numIter
    y = paFun(u);
    G = (x'*y)/(x'*x);                        % complex linear gain
    yn = y / G;
    res.iter(end+1) = it;
    res.nmse(end+1) = 10*log10(sum(abs(yn-x).^2)/sum(abs(x).^2));
    res.acpr(end+1) = computeACPRCentered(y, fs, bw);
    fprintf('iter %d  NMSE = %7.2f dB   ACPR = %7.2f dBc\n', it, res.nmse(end), res.acpr(end));
    if it == numIter, break; end

    % Indirect learning: fit post-distorter  u ~ MP(yn), then use it as pre-distorter.
    [Xfit, yfit] = buildTrainingSet(yn, u, M, K, minAmpRatio);
    cNew = solveRegularizedLS(Xfit, yfit, lambdaRel);
    coeffs = (1-coeffBlendMu)*coeffs + coeffBlendMu*cNew;

    u = applyMemoryPolynomial(x, coeffs, M, K);
    u = normalizeDPDWaveform(u, x, maxPeakRatio);
end

%% Checks
ok1 = res.nmse(end) < res.nmse(1) - 5;
ok2 = res.acpr(end) < res.acpr(1) - 5;
fprintf('\nNMSE improved > 5 dB : %s\n', string(ok1));
fprintf('ACPR improved > 5 dB : %s\n', string(ok2));

figure; subplot(2,1,1); plot(res.iter,res.nmse,'-o'); grid on; ylabel('NMSE (dB)');
subplot(2,1,2); plot(res.iter,res.acpr,'-o'); grid on; ylabel('ACPR (dBc)'); xlabel('Iteration');

figure; [p0,f] = pwelch(paFun(x),hamming(4096),[],8192,fs,'centered');
p1 = pwelch(y,hamming(4096),[],8192,fs,'centered');
plot(f/1e6,10*log10(p0),f/1e6,10*log10(p1)); grid on;
legend('No DPD','DPD'); xlabel('MHz'); ylabel('PSD (dB/Hz)');

%% Simulated PA: FIR -> Rapp AM/AM + AM/PM -> FIR
function y = simulatedPA(u)
    u = u(:);
    v = filter([1 0.15 -0.05], 1, u);
    a = abs(v); Asat = 1; p = 2;
    g = 1 ./ (1 + (a/Asat).^(2*p)).^(1/(2*p));
    phi = 0.3 * a.^2 ./ (1 + a.^2);
    w = v .* g .* exp(1j*phi);
    y = filter([1 0.08], 1, w);
end

%% Helpers copied from code/EXP020 (keep in sync if those change)
function [Xfit, yfit, idxTrain] = buildTrainingSet(rx_norm, tx_ref, M, K, minAmpRatio)
    rx_norm = rx_norm(:);
    tx_ref = tx_ref(:);
    L = min(length(rx_norm), length(tx_ref));
    rx_norm = rx_norm(1:L);
    tx_ref = tx_ref(1:L);
    X = buildMPMatrix(rx_norm, M, K);
    y = tx_ref(M+1:end);
    amp = abs(rx_norm(M+1:end));
    ampMax = max(amp);
    if ampMax <= 0 || ~isfinite(ampMax)
        error('Invalid RX amplitude for DPD training.');
    end
    idxTrain = amp > minAmpRatio*ampMax;
    if nnz(idxTrain) <= size(X,2)
        idxTrain = amp > 0.01*ampMax;
    end
    if nnz(idxTrain) <= size(X,2)
        idxTrain = true(size(amp));
    end
    Xfit = X(idxTrain,:);
    yfit = y(idxTrain);
end

function X = buildMPMatrix(signal, M, K)
    signal = signal(:);
    L = length(signal);
    if L <= M
        error('Signal length must be larger than memory depth M.');
    end
    X = zeros(L-M, (M+1)*K);
    col = 1;
    for m = 0:M
        s = signal(M+1-m:end-m);
        for k = 0:K-1
            X(:,col) = s .* abs(s).^(2*k);
            col = col + 1;
        end
    end
end

function y = applyMemoryPolynomial(x, coeffs, M, K)
    x = x(:);
    y = x;
    X = buildMPMatrix(x, M, K);
    y(M+1:end) = X * coeffs;
    if M > 0
        y(1:M) = x(1:M);
    end
end

function coeffs = solveRegularizedLS(X, y, lambdaRel)
    X = double(X);
    y = double(y);
    R = X' * X;
    b = X' * y;
    scale = trace(R)/max(size(R,1),1);
    if ~isfinite(scale) || scale <= 0
        scale = 1;
    end
    lambda = lambdaRel * scale;
    coeffs = (R + lambda*eye(size(R))) \ b;
end

function tx_dpd = normalizeDPDWaveform(tx_dpd, tx_ref, maxPeakRatio)
    tx_dpd = tx_dpd(:);
    tx_ref = tx_ref(:);
    pRef = mean(abs(tx_ref).^2);
    pDpd = mean(abs(tx_dpd).^2);
    if isfinite(pRef) && isfinite(pDpd) && pRef > 0 && pDpd > 0
        tx_dpd = tx_dpd * sqrt(pRef/pDpd);
    end
    maxAllowedPeak = maxPeakRatio * max(abs(tx_ref));
    currentPeak = max(abs(tx_dpd));
    if isfinite(currentPeak) && currentPeak > maxAllowedPeak && currentPeak > 0
        tx_dpd = tx_dpd / currentPeak * maxAllowedPeak;
    end
end

function acpr_dBc = computeACPRCentered(x, fs, bw)
    x = x(:) - mean(x);
    N = length(x);
    winLen = min(4096, N);
    nfft = max(4096, 2^nextpow2(min(N, 262144)));
    [pxx, f] = pwelch(x, hamming(winLen), [], nfft, fs, 'centered');
    mainIdx = abs(f) <= bw/2;
    adjLowIdx  = (f >= -1.5*bw) & (f < -0.5*bw);
    adjHighIdx = (f >  0.5*bw) & (f <= 1.5*bw);
    pMain = trapz(f(mainIdx), pxx(mainIdx));
    pAdj = trapz(f(adjLowIdx), pxx(adjLowIdx)) + trapz(f(adjHighIdx), pxx(adjHighIdx));
    acpr_dBc = 10*log10(pAdj / pMain);
end
