%% ========================================================================
%  S01 - Can a lambda-delta step respect the TX peak limit?
%        (DPD v3.1 EXP017 and EXP033-EXP037: columns normalized by their RMS,
%         ||step|| <= delta, proposal rejected if max|tx| > 0.95)
%  ----------------------------------------------------------------------
%  ISCAS-phase check. No hardware. Base MATLAB + Signal Processing Toolbox.
%  Outputs: sim/iscas/out/S01/. Guide: docs/learning/S01_delta_peak_check.md
%
%  Idea: delta bounds the norm of the coefficient step in NORMALIZED
%  coordinates. The time-domain change of the waveform is
%        dz[n] = sum_j d_j * Xs[n,j],     |dz[n]| <= ||d|| * ||Xs[n,:]||
%  and ||Xs[n,:]|| (row norm of the normalized basis) is large at the peaks of
%  the signal because the high-order columns are very peaky (peak/RMS ~ 100).
%  So delta = 0.1 does NOT mean "small change of the waveform".
%
%  PART 1  worst-case peak after a step of norm delta (depends ONLY on the
%          TX waveform and the GMP structure, not on the PA)
%  PART 2  the actual first step against a simulated PA (depends on the PA:
%          it is a simulation, to be repeated offline with a real capture)
%% ========================================================================

clear; close all; clc;
rng(41);

moduleName = 'S01';
scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir), scriptDir = pwd; end
outDir = fullfile(scriptDir, 'out', moduleName);
figDir = fullfile(outDir, 'figures');
if ~exist(figDir, 'dir'), mkdir(figDir); end
delete(fullfile(figDir, '*.png'));
diary off; diary(fullfile(outDir, 'console.txt'));
fprintf('%s run: %s  (MATLAB %s)\n\n', moduleName, datestr(now,'yyyy-mm-dd HH:MM:SS'), version);

%% 0. Configuration ------------------------------------------------------
cfg.nfft = 2048; cfg.scs = 30e3; cfg.nActive = 612; cfg.ncp = 144; cfg.nSym = 40;
cfg.fs = cfg.nfft*cfg.scs; cfg.bw = cfg.nActive*cfg.scs;          % 61.44 MS/s, as EXP016/017
cfg.idx = [cfg.nfft-cfg.nActive/2+1:cfg.nfft, 2:cfg.nActive/2+1].';
peakDigital = 0.8;       % powerScaleFactor of the lab scripts
peakLimit   = 0.95;      % EXP017 / EXP033-037: proposal not transmitted above this
lambdaNew   = 0.05;      % EXP017: C.lambdaNuevo
deltaList   = [1e-4 3e-4 1e-3 3e-3 1e-2 3e-2 0.1 0.3];   % includes EXP017 (0.1) and the EXP035 grid (0.03, 0.1, 0.3)
snrObs      = 38;        % ASSUMED
targetC     = 0.5;

% The four structures of EXP015/016/017 (29, 33, 37, 35 complex coefficients)
models = struct('ID', {'F1 (29)', 'F2 high order (33)', 'F3 high memory (37)', 'F4 cross order (35)'}, ...
    'Ka', {5 6 5 5}, 'La', {4 4 5 4}, 'Kb', {2 2 2 3}, 'Lb', {3 3 4 3}, 'Mb', {1 1 1 1}, ...
    'Kc', {1 1 1 2}, 'Lc', {3 3 4 3}, 'Mc', {1 1 1 1});

x = makeSignal(cfg);
xdig = x * (peakDigital/max(abs(x)));                  % lab scale: peak 0.8
fprintf('Waveform: %d samples, fs = %.2f MS/s, peak %.2f, RMS %.3f, PAPR %.1f dB\n\n', numel(xdig), cfg.fs/1e6, max(abs(xdig)), rms(xdig), 20*log10(max(abs(xdig))/rms(xdig)));

%% PART 1: worst-case bound -----------------------------------------------
fprintf('PART 1: worst-case TX peak after a step of norm delta (PA independent)\n');
nM = numel(models); bound = zeros(nM, numel(deltaList)); deltaSafe = zeros(nM,1); rowMax = zeros(nM,1); colPk = zeros(nM,1);
for q = 1:nM
    p = models(q); [X, ns, ne] = buildGMPMatrix(xdig, p);
    sc = max(sqrt(mean(abs(X).^2, 1)), 1e-12); Xs = X ./ sc;
    rn = vecnorm(Xs, 2, 2); xr = abs(xdig(ns:ne));
    rowMax(q) = max(rn); colPk(q) = max(max(abs(Xs)));
    for j = 1:numel(deltaList), bound(q,j) = max(xr + deltaList(j)*rn); end
    deltaSafe(q) = bisect(@(d) max(xr + d*rn) - peakLimit, 0, 1);
end
fprintf('  %-22s %5s %12s %12s | worst-case peak for delta = %s | delta_safe\n', 'Structure', 'Nc', 'max row norm', 'max col peak', sprintf('%7.0e', deltaList));
for q = 1:nM
    fprintf('  %-22s %5d %12.0f %12.0f | %s | %.5f\n', models(q).ID, nCoefficients(models(q)), rowMax(q), colPk(q), sprintf('%7.1f', bound(q,:)), deltaSafe(q));
end
fprintf('  delta_safe = largest delta that GUARANTEES peak <= %.2f for any step direction. Real steps are not worst-case, see Part 2.\n\n', peakLimit);

%% PART 2: the actual first step against a simulated PA -------------------
fprintf('PART 2: first lambda-delta step (identity start) against a simulated PA at %.1f dB compression\n', targetC);
paRaw = @(u) paFun(u, 2);
drive = calibrateDrive(x, paRaw, targetC);                % RMS of the PA input (PA units) at the operating point
sc0 = drive / rms(xdig); pa = @(u) paRaw(u*sc0);          % PA fed with the lab-scale digital waveform
noiseAmp = sqrt(mean(abs(pa(xdig)).^2)) * 10^(-snrObs/20);
yo = pa(xdig); yo = yo + noiseAmp*cnoise(numel(yo));
evm0 = evmOFDM(x, yo, cfg); fprintf('  No DPD: EVM %.2f %% (paper: 6.47 %%)\n', evm0);
fprintf('  The first step is the same for EXP015-style (original-waveform target) and corrected (emitted-input) rules: at iteration 1 u = x.\n\n');
G = (xdig'*yo)/(xdig'*xdig); yn = yo / G;

nD = numel(deltaList); peakStep = zeros(nM, nD); evmStep = zeros(nM, nD); dpStep = zeros(nM, nD);
fprintf('  %-22s %8s | %10s %8s %8s %8s\n', 'Structure', 'delta', 'peak', 'verdict', 'EVM(%)', 'dPout');
for q = 1:nM
    p = models(q); nc = nCoefficients(p);
    [Xb, ns, ne] = buildGMPMatrix(xdig, p); sc = max(sqrt(mean(abs(Xb).^2, 1)), 1e-12);
    [Xn, ~, ~] = buildGMPMatrix(yn, p); t = xdig(ns:ne); amp = abs(yn(ns:ne));
    idx = find(amp > 0.08*max(amp)); idx = idx(1:max(1, floor(numel(idx)/30000)):end);
    c0 = zeros(nc,1); c0(1) = 1;
    for j = 1:nD
        nextS = stepLambdaDelta(Xn(idx,:)./sc, t(idx), c0.*sc.', lambdaNew, deltaList(j));
        z = xdig; z(ns:ne) = Xb * (nextS./sc.');
        peakStep(q,j) = max(abs(z));
        yz = pa(z) ; yz = yz + noiseAmp*cnoise(numel(yz));
        evmStep(q,j) = evmOFDM(x, yz, cfg); dpStep(q,j) = 10*log10(mean(abs(yz).^2)/mean(abs(yo).^2));
        verdict = 'OK'; if peakStep(q,j) > peakLimit, verdict = 'REJECT'; end
        fprintf('  %-22s %8.0e | %10.2f %8s %8.2f %8.2f\n', models(q).ID, deltaList(j), peakStep(q,j), verdict, evmStep(q,j), dpStep(q,j));
    end
end
fprintf('\n  REJECT = proposal not transmitted by EXP017 (max|tx| > %.2f). EVM/dPout are shown even for rejected steps, for information only.\n', peakLimit);
okMask = peakStep <= peakLimit;
for q = 1:nM
    if any(okMask(q,:)), dmax = deltaList(find(okMask(q,:), 1, 'last')); bestE = min(evmStep(q, okMask(q,:))); else, dmax = NaN; bestE = NaN; end
    fprintf('  %-22s largest delta of the grid that passes: %s | lowest EVM among passing steps: %.2f %% (no DPD %.2f %%)\n', models(q).ID, num2str(dmax), bestE, evm0);
end

figure('Name','S01-1 delta vs TX peak','Position',[40 40 1300 480]);
subplot(1,3,1); loglog(deltaList, bound', 'o-'); hold on; yline(peakLimit, 'k--', '0.95 limit'); yline(peakDigital, 'k:', '0.8 original'); grid on;
xlabel('\delta (normalized coordinates)'); ylabel('Worst-case TX peak'); legend({models.ID}, 'Location', 'northwest'); title('Part 1: guaranteed (worst-case) bound');
subplot(1,3,2); loglog(deltaList, peakStep', 'o-'); hold on; yline(peakLimit, 'k--', '0.95 limit'); grid on;
xlabel('\delta'); ylabel('Peak of the first proposed waveform'); title('Part 2: real first step (simulated PA)');
subplot(1,3,3); semilogx(deltaList, evmStep', 'o-'); hold on; yline(evm0, 'k--', 'no DPD'); grid on;
for q = 1:nM, semilogx(deltaList(~okMask(q,:)), evmStep(q,~okMask(q,:)), 'rx'); end
xlabel('\delta'); ylabel('EVM if transmitted (%)'); title('Red x = rejected by the 0.95 peak guard');

%% 7. Save ---------------------------------------------------------------
writetable(array2table([deltaList(:) bound'], 'VariableNames', ['delta' matlab.lang.makeValidName({models.ID})]), fullfile(outDir, 'worstcase_bound.csv'));
writetable(array2table([deltaList(:) peakStep'], 'VariableNames', ['delta' matlab.lang.makeValidName({models.ID})]), fullfile(outDir, 'first_step_peak.csv'));
writetable(array2table([deltaList(:) evmStep'], 'VariableNames', ['delta' matlab.lang.makeValidName({models.ID})]), fullfile(outDir, 'first_step_evm.csv'));
writetable(table({models.ID}.', deltaSafe, rowMax, 'VariableNames', {'Structure','DeltaSafe','MaxRowNorm'}), fullfile(outDir, 'delta_safe.csv'));
saveAllFigures(figDir);
fprintf('\nSaved to %s\n', outDir);
diary off;

%% ===================== Local functions =================================
function n = nCoefficients(p), n = p.Ka*p.La + p.Kb*p.Lb*p.Mb + p.Kc*p.Lc*p.Mc; end

function [X, nStart, nEnd] = buildGMPMatrix(signal, p)
    % Same basis as buildGMPMatrix in code/EXP017 (DPD v3.1): aligned MP branch A,
    % lagging-envelope branch B, leading-envelope branch C.
    signal = signal(:); L = numel(signal);
    maxDelay = max([p.La-1, p.Lb-1+p.Mb, 0]); nStart = 1 + maxDelay; nEnd = L - p.Mc;
    N = nEnd - nStart + 1; X = complex(zeros(N, nCoefficients(p))); col = 1;
    for l = 0:p.La-1
        s = signal(nStart-l:nEnd-l);
        for k = 0:p.Ka-1, X(:,col) = s .* abs(s).^(2*k); col = col + 1; end
    end
    for l = 0:p.Lb-1
        s = signal(nStart-l:nEnd-l);
        for m = 1:p.Mb
            e = signal(nStart-l-m:nEnd-l-m);
            for k = 1:p.Kb, X(:,col) = s .* abs(e).^(2*k); col = col + 1; end
        end
    end
    for l = 0:p.Lc-1
        s = signal(nStart-l:nEnd-l);
        for m = 1:p.Mc
            e = signal(nStart-l+m:nEnd-l+m);
            for k = 1:p.Kc, X(:,col) = s .* abs(e).^(2*k); col = col + 1; end
        end
    end
end

function next = stepLambdaDelta(X, u, c, lambda, delta)
    % Copy of the solver of code/funciones/resolver_actualizacion_GMP.m (DPD v3.1), without the info struct.
    N = size(X,1); P = size(X,2); A = X/sqrt(N); v = u/sqrt(N);
    H = A'*A + lambda*eye(P); H = (H+H')/2; g = A'*v - H*c;
    hat = [A; sqrt(lambda)*eye(P)] \ [v; zeros(P,1)]; d = hat - c;
    if norm(d) > delta
        [V, D] = eig(H, 'vector'); D = max(real(D), 0); q = V'*g;
        lo = 0; hi = max(1, norm(g)/delta);
        while norm(q./(D+hi)) > delta, hi = 2*hi; end
        for k = 1:80
            mid = (lo+hi)/2;
            if norm(q./(D+mid)) > delta, lo = mid; else, hi = mid; end
        end
        d = V*(q./(D+hi));
    end
    next = c + d;
end

function y = paFun(u, p)
    u = u(:); v = filter([1 0.15 -0.05], 1, u); a = abs(v);
    g = 1 ./ (1 + a.^(2*p)).^(1/(2*p)); phi = 0.3 * a.^2 ./ (1 + a.^2);
    y = filter([1 0.08], 1, v .* g .* exp(1j*phi));
end

function d = calibrateDrive(x, pa, targetC)
    gOf = @(dd) 10*log10(mean(abs(pa(x*10^(dd/20))).^2)) - dd;
    G0 = gOf(-40); dBv = bisect(@(dd) (G0 - gOf(dd)) - targetC, -30, 5); d = 10^(dBv/20);
end

function r = bisect(f, lo, hi)
    flo = f(lo);
    for k = 1:60
        mid = (lo+hi)/2; fm = f(mid);
        if sign(fm) == sign(flo), lo = mid; flo = fm; else, hi = mid; end
    end
    r = (lo+hi)/2;
end

function n = cnoise(N), n = (randn(N,1) + 1j*randn(N,1))/sqrt(2); end

function x = makeSignal(cfg)
    x = generateOFDM(cfg);
    Xf = fft(x); fAxis = (0:numel(x)-1).'/numel(x)*cfg.fs;
    fAxis(fAxis >= cfg.fs/2) = fAxis(fAxis >= cfg.fs/2) - cfg.fs;
    Xf(abs(fAxis) > 0.50*cfg.bw) = 0;
    x = ifft(Xf); x = x / sqrt(mean(abs(x).^2));
end

%% ---- copied from L01-L04 ----
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
