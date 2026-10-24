%% ========================================================================
%  L03 - Memory-polynomial basis and regularized least squares
%        (paper Eq. 2-6, Table II; code/EXP010-EXP020 helpers)
%  ----------------------------------------------------------------------
%  Learning module 3. No hardware. Base MATLAB + Signal Processing Toolbox
%  (pwelch). Outputs go to sim/learn/out/L03/. Guide: docs/learning/L03_paso_a_paso.md
%
%  PART A  The basis: what are the columns of the MP regression matrix, and
%          why are they nearly collinear (ill-conditioning)?
%  PART B  Model size vs accuracy and noise (why 36 coefficients are not
%          better than 6: Table II of the paper)
%  PART C  Tikhonov (ridge) regularization: effect of lambda
%  PART D  Using the fitted model as a predistorter in ONE shot: why a single
%          shot fails (training domain) and why the iterative loop of L04 and
%          the equal-power comparison of L06 exist
%
%  Indirect learning (ILA) in one line: capture the PA input u and output y,
%  normalize y by the complex linear gain, y_n = y/G, and fit a POST-distorter
%  that maps y_n back to u. Then copy it in front of the PA as a PRE-distorter.
%% ========================================================================

clear; close all; clc;
rng(21);

moduleName = 'L03';
scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir), scriptDir = pwd; end
outDir = fullfile(scriptDir, 'out', moduleName);
figDir = fullfile(outDir, 'figures');
if ~exist(figDir, 'dir'), mkdir(figDir); end
delete(fullfile(figDir, '*.png'));
diary off; if exist(fullfile(outDir, 'console.txt'), 'file'), delete(fullfile(outDir, 'console.txt')); end   % diary appends: start clean
diary(fullfile(outDir, 'console.txt'));
fprintf('%s run: %s  (MATLAB %s)\n\n', moduleName, datestr(now,'yyyy-mm-dd HH:MM:SS'), version);

%% 0. Configuration ------------------------------------------------------
cfg.nfft = 2048; cfg.scs = 30e3; cfg.nActive = 612; cfg.ncp = 144; cfg.nSym = 40;
cfg.fs = cfg.nfft*cfg.scs; cfg.bw = cfg.nActive*cfg.scs;
cfg.idx = [cfg.nfft-cfg.nActive/2+1:cfg.nfft, 2:cfg.nActive/2+1].';

targetC   = 0.5;        % operating point: 0.5 dB of compression (paper)
snrObs    = 38;         % dB, noise on the captured PA output (ASSUMED; lab EVM floor ~1.2 %)
minAmpRatio = 0.08;     % training rows: |y_n| > 0.08 * max (as in EXP020)
nRowsMax  = 40000;      % rows used by each fit (speed)
lamGrid   = 1e-6;       % "almost no" regularization for Parts A/B
lamPaper  = 1e-2;       % paper value (relative to trace(X'X)/Nc)
muPaper   = 0.12;       % paper blend step
maxPeakRatio = 1.5;     % peak limit of the predistorted waveform, vs the peak of u (as in EXP020)
Mgrid = 0:5; Kgrid = 1:7;
snrList = [200 50 38 30];       % 200 dB = noiseless
models = [1 3; 3 5; 5 6];       % paper: M1K3 (6 coef), M3K5 (20), M5K6 (36)

%% 1. Signals and operating point ---------------------------------------
% Two independent waveforms: 'a' trains the model, 'b' validates it.
xa = makeSignal(cfg); xb = makeSignal(cfg);
% drive level (RMS of the PA input) that gives targetC dB of compression
gOf = @(d) 10*log10(mean(abs(simulatedPA(xa*10^(d/20))).^2)) - d;
Gss = gOf(-40);
drive = bisect(@(d) (Gss - gOf(d)) - targetC, -30, 0);
rmsIn = 10^(drive/20);
fprintf('Operating point: input RMS %.3f (%.2f dB re PA saturation), compression %.2f dB\n\n', rmsIn, drive, Gss - gOf(drive));

ua = xa*rmsIn; ub = xb*rmsIn;
[yna, ~] = captureILA(ua, snrObs);          % training capture (noisy, normalized by the complex gain)
[ynb, ~] = captureILA(ub, snrObs);          % validation capture
fprintf('Capture: max|y_n| = %.2f, max|u| = %.2f (the PA compresses the peaks, so y_n peaks are lower than u peaks)\n\n', max(abs(yna)), max(abs(ua)));

%% PART A: the basis -----------------------------------------------------
fprintf('PART A: conditioning of the regression matrix X (y_n -> basis)\n');
nBasisRows = 60000;
sv = cell(size(models,1),1);
for r = 1:size(models,1)
    M = models(r,1); K = models(r,2);
    s = svd(mpMatrix(yna(1:nBasisRows), M, K), 'econ'); sv{r} = s;
    fprintf('  M%dK%d  Nc = %2d   cond(X) = %.2e\n', M, K, (M+1)*K, s(1)/s(end));
end
Xbig = mpMatrix(yna(1:nBasisRows), 5, 6);
Xn = Xbig ./ vecnorm(Xbig);  Ccorr = abs(Xn' * Xn);
fprintf('  M5K6: median |correlation| between different columns = %.2f, max = %.3f\n\n', ...
    median(Ccorr(~eye(36))), max(Ccorr(~eye(36))));

figure('Name','L03-1 MP basis','Position',[40 40 1300 420]);
subplot(1,3,1); a = linspace(0, 1.6, 200);
hold on; for k = 0:5, plot(a, a.^(2*k+1)); end; grid on; ylim([0 4]);
xlabel('|x|'); ylabel('|x| \cdot |x|^{2k}  (basis magnitude)'); legend(arrayfun(@(k) sprintf('k=%d',k), 0:5, 'UniformOutput', false), 'Location', 'northwest');
title('Basis functions of one tap: all "grow" similarly');
subplot(1,3,2); imagesc(Ccorr); axis image; colorbar; clim([0 1]); xlabel('column (m outer, k inner)'); ylabel('column');
title('|correlation| between M5K6 columns');
subplot(1,3,3);
for r = 1:size(models,1), semilogy(sv{r}/sv{r}(1), 'o-'); hold on; end; grid on;
xlabel('singular value index'); ylabel('\sigma_i / \sigma_1'); legend('M1K3','M3K5','M5K6','Location','southwest');
title('Singular values of X: wider spread = worse conditioning');

%% PART B: model size and noise -----------------------------------------
fprintf('PART B: validation NMSE (dB) of the post-distorter u ~ f(y_n), lambda = %.0e, SNR = %d dB\n', lamGrid, snrObs);
NM = zeros(numel(Mgrid), numel(Kgrid)); NT = NM; NC = NM;
for i = 1:numel(Mgrid)
    for j = 1:numel(Kgrid)
        c = fitMP(yna, ua, Mgrid(i), Kgrid(j), lamGrid, minAmpRatio, nRowsMax);
        NM(i,j) = nmseDB(ub(Mgrid(i)+1:end), mpMatrix(ynb, Mgrid(i), Kgrid(j))*c);
        NC(i,j) = (Mgrid(i)+1)*Kgrid(j);
    end
end
fprintf('        K=%s\n', sprintf('%7d', Kgrid));
for i = 1:numel(Mgrid), fprintf('  M=%d  %s\n', Mgrid(i), sprintf('%7.1f', NM(i,:))); end
fprintf('\n  Same three paper models vs observation SNR (validation NMSE, dB):\n  %10s %9s %9s %9s\n', 'SNR (dB)', 'M1K3', 'M3K5', 'M5K6');
NS = zeros(numel(snrList), 3);
for q = 1:numel(snrList)
    [yq1, ~] = captureILA(ua, snrList(q)); [yq2, ~] = captureILA(ub, snrList(q));
    for r = 1:3
        M = models(r,1); K = models(r,2);
        c = fitMP(yq1, ua, M, K, lamGrid, minAmpRatio, nRowsMax);
        NS(q,r) = nmseDB(ub(M+1:end), mpMatrix(yq2, M, K)*c);
    end
    fprintf('  %10d %9.1f %9.1f %9.1f\n', snrList(q), NS(q,1), NS(q,2), NS(q,3));
end
fprintf('  (200 dB = noiseless. With noise the big models stop improving: they are noise-limited, not model-limited.)\n\n');

figure('Name','L03-2 Model size','Position',[40 40 1250 450]);
subplot(1,2,1); imagesc(Kgrid, Mgrid, NM); set(gca,'YDir','normal'); colorbar; colormap(parula);
xlabel('K (nonlinear branches, odd orders 1..2K-1)'); ylabel('M (memory depth)');
title(sprintf('Validation NMSE (dB), SNR %d dB', snrObs));
for i = 1:numel(Mgrid), for j = 1:numel(Kgrid), text(Kgrid(j), Mgrid(i), sprintf('%.0f', NM(i,j)), 'HorizontalAlignment','center','Color','w','FontSize',8); end, end
subplot(1,2,2); nc = [6 20 36];
for q = 1:numel(snrList), plot(nc, NS(q,:), 'o-', 'LineWidth', 1.3); hold on; end; grid on;
xticks(nc); xticklabels({'M1K3 (6)','M3K5 (20)','M5K6 (36)'});
xlabel('Model (coefficients)'); ylabel('Validation NMSE (dB)');
legend(arrayfun(@(s) sprintf('SNR %d dB', s), snrList, 'UniformOutput', false), 'Location', 'southwest');
title('More coefficients help only until the noise floor');

%% PART C: Tikhonov regularization --------------------------------------
fprintf('PART C: ridge regression for M5K6, SNR %d dB (lambda = lamRel * trace(X''X)/Nc, as in EXP020)\n', snrObs);
lamList = 10.^(-10:0).';  M = 5; K = 6;
Ctr = zeros(size(lamList)); Cva = Ctr; Cnorm = Ctr; Ccond = Ctr;
for q = 1:numel(lamList)
    [c, cnd] = fitMP(yna, ua, M, K, lamList(q), minAmpRatio, nRowsMax);
    Ctr(q) = nmseDB(ua(M+1:end), mpMatrix(yna, M, K)*c);
    Cva(q) = nmseDB(ub(M+1:end), mpMatrix(ynb, M, K)*c);
    Cnorm(q) = norm(c); Ccond(q) = cnd;
end
fprintf('  %9s %11s %11s %9s %12s\n', 'lamRel', 'train NMSE', 'val NMSE', '||c||', 'cond(R+lam)');
for q = 1:numel(lamList), fprintf('  %9.0e %11.2f %11.2f %9.2f %12.2e\n', lamList(q), Ctr(q), Cva(q), Cnorm(q), Ccond(q)); end
iP = find(abs(log10(lamList) - log10(lamPaper)) < 1e-9);
fprintf('  Paper choice lamRel = 1e-2: costs %.1f dB of validation NMSE relative to the best value, in exchange for ||c|| %.1f vs %.1f.\n\n', ...
    Cva(iP) - min(Cva), Cnorm(iP), Cnorm(1));

figure('Name','L03-3 Lambda','Position',[40 40 1250 450]);
subplot(1,2,1); semilogx(lamList, Ctr, 'o-', lamList, Cva, 's-'); grid on; xline(lamPaper, '--', 'paper');
xlabel('\lambda_{rel}'); ylabel('NMSE (dB)'); legend('train','validation','Location','northwest'); title('Fit quality vs regularization');
subplot(1,2,2); yyaxis left; plot(lamList, Cnorm, 'o-'); set(gca, 'YScale', 'log'); ylabel('||c||');
yyaxis right; plot(lamList, Ccond, 's-'); set(gca, 'YScale', 'log'); ylabel('cond(R + \lambda I)');
set(gca, 'XScale', 'log'); grid on; xline(lamPaper, '--', 'paper'); xlabel('\lambda_{rel}'); title('Coefficient size and conditioning');

%% PART D: one-shot predistortion ---------------------------------------
fprintf('PART D: apply the post-distorter as a pre-distorter in ONE shot (no iterations)\n');
% Domain check: the model was trained for |y_n| up to max|y_n|, but now it is evaluated on |u|, whose peaks are higher.
fprintf('  Training domain max|y_n| = %.2f, application domain max|u| = %.2f  (%.1f dB higher)\n', max(abs(yna)), max(abs(ua)), 20*log10(max(abs(ua))/max(abs(yna))));
y0 = simulatedPA(ub); P0 = 10*log10(mean(abs(y0).^2));
evm0 = evmOFDM(xb, y0, cfg); acpr0 = acprCentered(y0, cfg);
fprintf('  No DPD, same drive: EVM %.2f %%, ACPR %.2f dBc\n\n', evm0, acpr0);
cases = [1 3 muPaper 1.5; 3 5 muPaper 1.5; 5 6 muPaper 1.5; 5 6 muPaper 3.0; 5 6 1.0 3.0];
nCase = size(cases,1); R = zeros(nCase, 7); labels = cell(nCase,1);
fprintf('  %-22s | %7s %9s %8s | %9s %10s | %s\n', 'case (mu, peak limit)', 'EVM(%)', 'ACPR(dBc)', 'dPout', 'EVM(%) eq.', 'ACPR eq.', 'real EVM gain (pp)');
for q = 1:nCase
    M = cases(q,1); K = cases(q,2); mu = cases(q,3); cap = cases(q,4);
    c = fitMP(yna, ua, M, K, lamPaper, minAmpRatio, nRowsMax);
    z = predistort(ub, c, M, K, mu, cap);
    y = simulatedPA(z); dP = 10*log10(mean(abs(y).^2)) - P0;
    e = evmOFDM(xb, y, cfg); a = acprCentered(y, cfg);
    % The no-DPD waveform that produces the SAME output power (paper Eq. 8, here by construction)
    dEq = bisect(@(d) (10*log10(mean(abs(simulatedPA(ub*10^(d/20))).^2)) - P0) - dP, -30, 6);
    yEq = simulatedPA(ub*10^(dEq/20)); eE = evmOFDM(xb, yEq, cfg); aE = acprCentered(yEq, cfg);
    labels{q} = sprintf('M%dK%d mu=%.2f cap=%.1f', M, K, mu, cap);
    R(q,:) = [e a dP eE aE evm0 acpr0];
    fprintf('  %-22s | %7.2f %9.2f %8.2f | %9.2f %10.2f | %.2f\n', labels{q}, e, a, dP, eE, aE, eE - e);
end
fprintf('  dPout = output power change vs no DPD at the same drive (dB). "eq." = no-DPD at the same output power.\n');
fprintf('  The EVM gain that survives against the equal-power reference is the last column; compare with the first columns.\n\n');

figure('Name','L03-4 One-shot DPD','Position',[40 40 1300 800]);
subplot(2,2,1); histogram(abs(yna), 60, 'Normalization', 'pdf'); hold on; histogram(abs(ua), 60, 'Normalization', 'pdf'); grid on;
xline(max(abs(yna)), 'b--'); xline(max(abs(ua)), 'r--'); legend('|y_n| (training)', '|u| (application)', 'max |y_n|', 'max |u|');
xlabel('amplitude'); title('Training domain vs application domain');
subplot(2,2,2); aa = linspace(0.02, 1.8, 200).'; hold on;
for r = 1:3
    M = models(r,1); K = models(r,2); c = fitMP(yna, ua, M, K, lamPaper, minAmpRatio, nRowsMax);
    cc = c(1:K); plot(aa, abs((aa.^(2*(0:K-1))) * cc .* aa));      % memoryless slice (tap m = 0)
end
plot(aa, aa, 'k--'); xline(max(abs(yna)), 'b--'); patch([max(abs(yna)) 1.8 1.8 max(abs(yna))], [0 0 5 5], 'r', 'FaceAlpha', 0.07, 'EdgeColor', 'none');
ylim([0 5]); grid on; legend('M1K3','M3K5','M5K6','identity','Location','northwest'); xlabel('input amplitude'); ylabel('|f(a)| (tap m = 0)');
title('Fitted polynomial: reliable inside the training range, wild outside');
subplot(2,2,3); bar(1:nCase, [R(:,6) R(:,1) R(:,4)]); grid on; ylabel('EVM (%)');
xticks(1:nCase); xticklabels(labels); xtickangle(20); set(gca, 'TickLabelInterpreter', 'none');
legend('no DPD, same drive', 'DPD', 'no DPD, same output power', 'Location', 'northwest'); title('The honest comparison is the 3rd bar');
subplot(2,2,4); [p0, f] = pwelch(y0, hamming(4096), [], 8192, cfg.fs, 'centered'); hold on;
plot(f/1e6, 10*log10(p0/max(p0)), 'k');                 % both spectra use the no-DPD peak as 0 dB
cBest = fitMP(yna, ua, 5, 6, lamPaper, minAmpRatio, nRowsMax); zB = predistort(ub, cBest, 5, 6, muPaper, 1.5); [pB, f] = pwelch(simulatedPA(zB), hamming(4096), [], 8192, cfg.fs, 'centered');
plot(f/1e6, 10*log10(pB/max(p0)), 'r'); grid on; xlim([-30 30]); ylim([-90 5]); legend('no DPD', 'M5K6 one-shot, mu 0.12');
xlabel('MHz'); ylabel('PSD (dB re no-DPD peak)'); title('Same reference: shoulders lower, but in-band power also dropped');

%% 7. Save ---------------------------------------------------------------
writetable(table(repelem(Mgrid(:), numel(Kgrid)), repmat(Kgrid(:), numel(Mgrid), 1), reshape(NC', [], 1), reshape(NM', [], 1), ...
    'VariableNames', {'M','K','Nc','ValNMSE_dB'}), fullfile(outDir, 'model_grid.csv'));
writetable(table(lamList, Ctr, Cva, Cnorm, Ccond, 'VariableNames', {'LambdaRel','TrainNMSE_dB','ValNMSE_dB','NormC','Cond'}), fullfile(outDir, 'lambda_sweep.csv'));
writetable(table(labels, R(:,1), R(:,2), R(:,3), R(:,4), R(:,5), 'VariableNames', {'Case','EVM_pct','ACPR_dBc','dPout_dB','EVM_noDPD_equalPower_pct','ACPR_noDPD_equalPower_dBc'}), fullfile(outDir, 'oneshot.csv'));
writetable(array2table([snrList(:) NS], 'VariableNames', {'SNR_dB','M1K3','M3K5','M5K6'}), fullfile(outDir, 'noise_vs_model.csv'));
saveAllFigures(figDir);
fprintf('Saved to %s\n', outDir);
diary off;

%% ===================== Local functions =================================
function X = mpMatrix(s, M, K)
    % Same as buildMPMatrix in code/EXP020: columns ordered tap m (outer), branch k (inner).
    s = s(:); L = numel(s); X = zeros(L-M, (M+1)*K); col = 1;
    for m = 0:M
        t = s(M+1-m:end-m);
        for k = 0:K-1, X(:,col) = t .* abs(t).^(2*k); col = col + 1; end
    end
end

function [c, cnd] = fitMP(yn, u, M, K, lamRel, minAmpRatio, nMax)
    % Regularized LS, as solveRegularizedLS in EXP020: lambda = lamRel * trace(R)/Nc
    X = mpMatrix(yn, M, K); t = u(M+1:end); amp = abs(yn(M+1:end));
    idx = find(amp > minAmpRatio*max(amp));
    idx = idx(1:max(1, floor(numel(idx)/nMax)):end);
    Xf = X(idx,:); R = Xf'*Xf; b = Xf'*t(idx);
    sc = trace(R)/size(R,1); A = R + lamRel*sc*eye(size(R));
    c = A \ b; cnd = cond(A);
end

function z = predistort(u, c, M, K, mu, cap)
    % z = (1-mu)*u + mu*f(u)  (equivalent to blending the coefficients with the identity), then
    % match the average power of u and limit the peak to cap*max|u| (normalizeDPDWaveform of EXP020).
    X = mpMatrix(u, M, K); f = u; f(M+1:end) = X*c;
    z = (1-mu)*u + mu*f;
    z = z * sqrt(mean(abs(u).^2)/mean(abs(z).^2));
    pk = cap*max(abs(u));
    if max(abs(z)) > pk, z = z / max(abs(z)) * pk; end
end

function [yn, G] = captureILA(u, snr_dB)
    % "Capture": PA output + receiver noise, normalized by the complex linear gain G (LS fit u -> y).
    y = simulatedPA(u);
    G = (u'*y)/(u'*u);
    if snr_dB < 150
        y = y + (randn(size(y)) + 1j*randn(size(y)))/sqrt(2) * sqrt(mean(abs(y).^2)) * 10^(-snr_dB/20);
    end
    yn = y / G;
end

function e = nmseDB(target, est), e = 10*log10(sum(abs(target - est).^2) / sum(abs(target).^2)); end

function r = bisect(f, lo, hi)
    flo = f(lo);
    for k = 1:40
        mid = (lo+hi)/2; fm = f(mid);
        if sign(fm) == sign(flo), lo = mid; flo = fm; else, hi = mid; end
    end
    r = (lo+hi)/2;
end

function y = simulatedPA(u)
    % Same PA as L01: FIR -> Rapp AM/AM + AM/PM -> FIR
    u = u(:); v = filter([1 0.15 -0.05], 1, u);
    a = abs(v); Asat = 1; p = 2;
    g = 1 ./ (1 + (a/Asat).^(2*p)).^(1/(2*p));
    phi = 0.3 * a.^2 ./ (1 + a.^2);
    y = filter([1 0.08], 1, v .* g .* exp(1j*phi));
end

function x = makeSignal(cfg)
    x = generateOFDM(cfg);
    Xf = fft(x); fAxis = (0:numel(x)-1).'/numel(x)*cfg.fs;
    fAxis(fAxis >= cfg.fs/2) = fAxis(fAxis >= cfg.fs/2) - cfg.fs;
    Xf(abs(fAxis) > 0.50*cfg.bw) = 0;
    x = ifft(Xf); x = x / sqrt(mean(abs(x).^2));
end

%% ---- copied from L01/L02 ----
function acpr_dBc = acprCentered(x, cfg)
    x = x(:) - mean(x);
    [pxx, f] = pwelch(x, hamming(4096), [], 8192, cfg.fs, 'centered');
    main = abs(f) <= cfg.bw/2;
    lo = (f >= -1.5*cfg.bw) & (f < -0.5*cfg.bw);
    hi = (f >  0.5*cfg.bw) & (f <= 1.5*cfg.bw);
    acpr_dBc = 10*log10((trapz(f(lo),pxx(lo)) + trapz(f(hi),pxx(hi))) / trapz(f(main),pxx(main)));
end

function saveAllFigures(figDir)
    figs = findall(groot, 'Type', 'figure');
    for k = 1:numel(figs)
        nm = regexprep(figs(k).Name, '[^\w-]+', '_');
        if isempty(nm), nm = sprintf('figure_%d', figs(k).Number); end
        fn = fullfile(figDir, [nm '.png']);
        try
            exportgraphics(figs(k), fn, 'Resolution', 130);
        catch
            saveas(figs(k), fn);
        end
    end
end

function x = generateOFDM(cfg)
    lv = -15:2:15;
    S  = (lv(randi(16, cfg.nActive, cfg.nSym)) + 1j*lv(randi(16, cfg.nActive, cfg.nSym))) / sqrt(170);
    x  = zeros(cfg.nSym*(cfg.nfft+cfg.ncp), 1);
    for s = 1:cfg.nSym
        F = zeros(cfg.nfft,1);  F(cfg.idx) = S(:,s);
        t = ifft(F)*sqrt(cfg.nfft);
        x((s-1)*(cfg.nfft+cfg.ncp) + (1:cfg.nfft+cfg.ncp)) = [t(end-cfg.ncp+1:end); t];
    end
end

function S = demodOFDM(sig, cfg)
    S = zeros(cfg.nActive, cfg.nSym);
    for s = 1:cfg.nSym
        i0 = (s-1)*(cfg.nfft+cfg.ncp) + cfg.ncp;
        F = fft(sig(i0 + (1:cfg.nfft))) / sqrt(cfg.nfft);
        S(:,s) = F(cfg.idx);
    end
end

function evm = evmOFDM(xref, y, cfg)
    Xs = demodOFDM(xref(:), cfg);  Ys = demodOFDM(y(:), cfg);
    H  = sum(conj(Xs).*Ys, 2) ./ sum(abs(Xs).^2, 2);
    Yeq = Ys ./ H;
    evm = 100*sqrt(sum(abs(Yeq - Xs).^2, 'all') / sum(abs(Xs).^2, 'all'));
end
