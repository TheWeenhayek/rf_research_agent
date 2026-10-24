%% ========================================================================
%  L04 - The iterative ILA loop: blending (mu), iteration selection and
%        why some models degrade after the first updates
%        (paper Eq. 6, Fig. 4, Table II; code/EXP010-EXP020 loop)
%  ----------------------------------------------------------------------
%  Learning module 4. No hardware. Base MATLAB + Signal Processing Toolbox.
%  Outputs go to sim/learn/out/L04/. Guide: docs/learning/L04_paso_a_paso.md
%
%  One iteration of the loop:
%     1) transmit u_k = predistorted waveform      (k = 0: u_0 = x, no DPD)
%     2) capture y_k, normalize y_n = y_k / G
%     3) fit the post-distorter  u_k ~ f(y_n)       (regularized LS, as L03)
%     4) blend  c <- (1-mu) c + mu * c_hat          (Eq. 6, mu = 0.12)
%     5) u_{k+1} = normalize( MP(x; c) )            (average power match + peak limit)
%
%  PART A  anatomy of one run
%  PART B  effect of mu (stable, slow, divergent)
%  PART C  three models (paper Fig. 4 / Table II) + the EVM-ACPR selection
%          rule + the equal-power check (preview of L06)
%  PART D  M5K6: effect of mu and of the peak limit (does it degrade?)
%  PART E  the loop of code/EXP020 is NOT the loop of the paper text: target =
%          original waveform AND iteration 1 not blended. 2x2 design that
%          separates the two. Simulation only; to be checked with real data.
%% ========================================================================

clear; close all; clc;
rng(33);

moduleName = 'L04';
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
cfg.fs = cfg.nfft*cfg.scs; cfg.bw = cfg.nActive*cfg.scs;
cfg.idx = [cfg.nfft-cfg.nActive/2+1:cfg.nfft, 2:cfg.nActive/2+1].';

targetC  = 0.5;     % compression at the operating point (dB)
snrObs   = 38;      % dB: receiver noise, ABSOLUTE level fixed at (no-DPD output power) - 38 dB (ASSUMED)
muPaper  = 0.12;    % blend step (paper)
lamRel   = 1e-2;    % regularization (paper)
capLab   = 1.10;    % peak limit of the predistorted waveform vs the peak of x (maxPredistortedPeakRatio in EXP010-EXP020)
nIter    = 10;      % paper trains 6 iterations; 10 here to see the trends
tolACPR  = 0.1;     % dB, plateau tolerance of the selection rule (paper)
minAmpRatio = 0.08; nRowsMax = 40000;
models   = [1 3; 3 5; 5 6];

x = makeSignal(cfg);
pa2 = @(u) paFun(u, 2);                       % the PA of L01 / L03
drive2 = calibrateDrive(x, pa2, targetC);
xd2 = x*drive2;
noiseAmp2 = sqrt(mean(abs(pa2(xd2)).^2)) * 10^(-snrObs/20);
fprintf('Operating point (PA smoothness p = 2): drive RMS %.3f, absolute noise amplitude %.4f\n', drive2, noiseAmp2);

% No-DPD reference sweep: the same waveform scaled down (this is the "independent no-DPD sweep" of the paper)
dGrid = (-14:0.5:0).';
ref = refCurve(x, xd2, pa2, noiseAmp2, cfg, dGrid);
fprintf('No-DPD at drive 0: EVM %.2f %%, ACPR %.2f dBc (paper: 6.47 %%, -26.57 dBc)\n\n', ref.EVM(end), ref.ACPR(end));

%% PART A: anatomy of one run -------------------------------------------
fprintf('PART A: M3K5, mu = %.2f, lambda = %.0e, peak limit %.2f, %d iterations\n', muPaper, lamRel, capLab, nIter);
A = runILA(x, xd2, pa2, 3, 5, muPaper, lamRel, noiseAmp2, nIter, capLab, 'classic', minAmpRatio, nRowsMax, cfg);
printTable(A.T);

figure('Name','L04-1 Loop anatomy','Position',[40 40 1300 800]);
subplot(2,2,1); yyaxis left; plot(A.T.Iter, A.T.EVM, 'o-'); ylabel('EVM (%)'); yyaxis right; plot(A.T.Iter, A.T.ACPR, 's-'); ylabel('ACPR (dBc)');
grid on; xlabel('Iteration (0 = no DPD)'); title('EVM and ACPR per iteration');
subplot(2,2,2); yyaxis left; plot(A.T.Iter, A.T.dP, 'o-'); ylabel('Output power change (dB)'); yyaxis right;
plot(A.T.Iter(1:end-1), A.T.dC(1:end-1), 's-'); set(gca, 'YScale', 'log'); ylabel('||c_{new} - c||'); grid on; xlabel('Iteration');
title('Power drops at the first update; updates shrink (mu blending)');
subplot(2,2,3); sel = round(linspace(1, numel(xd2), 9000));
[yn0, ~] = normalizeToX(A.y0, xd2); [ynN, ~] = normalizeToX(A.yN, xd2);
plot(abs(xd2(sel)), abs(yn0(sel)), '.', 'MarkerSize', 3); hold on; plot(abs(xd2(sel)), abs(ynN(sel)), '.', 'MarkerSize', 3);
plot([0 max(abs(xd2))], [0 max(abs(xd2))], 'k--'); grid on; xlabel('|x| (desired)'); ylabel('|y|/G'); legend('no DPD', 'after DPD', 'ideal', 'Location', 'northwest');
title('AM/AM of the whole chain: the DPD straightens it');
subplot(2,2,4); [p0, f] = pwelch(A.y0, hamming(4096), [], 8192, cfg.fs, 'centered'); [pN, ~] = pwelch(A.yN, hamming(4096), [], 8192, cfg.fs, 'centered');
plot(f/1e6, 10*log10(p0/max(p0)), 'k', f/1e6, 10*log10(pN/max(p0)), 'r'); grid on; xlim([-30 30]); ylim([-90 5]);
xlabel('MHz'); ylabel('PSD (dB re no-DPD peak)'); legend('no DPD', 'after DPD'); title('Spectrum (same reference)');

%% PART B: mu sweep ------------------------------------------------------
muList = [1 0.5 0.25 0.12 0.06 0.03];
fprintf('\nPART B: effect of mu (M3K5)\n  %6s | EVM per iteration 0..%d\n', 'mu', nIter);
EV = zeros(numel(muList), nIter+1); AC = EV; cellMu = cell(numel(muList),1);
for q = 1:numel(muList)
    Rq = runILA(x, xd2, pa2, 3, 5, muList(q), lamRel, noiseAmp2, nIter, capLab, 'classic', minAmpRatio, nRowsMax, cfg);
    EV(q,:) = Rq.T.EVM'; AC(q,:) = Rq.T.ACPR';
    fprintf('  %6.2f | %s\n', muList(q), sprintf('%8.2f', min(EV(q,:), 99)));
    Tq = Rq.T; Tq.mu = repmat(muList(q), height(Tq), 1); cellMu{q} = Tq;
end
Tmu = vertcat(cellMu{:});
fprintf('  (values capped at 99 %% for printing)\n');
figure('Name','L04-2 mu sweep','Position',[40 40 1250 450]);
subplot(1,2,1); semilogy(0:nIter, min(EV', 100), 'o-', 'LineWidth', 1.2); grid on; ylim([1 100]);
legend(arrayfun(@(m) sprintf('\\mu = %.2f', m), muList, 'UniformOutput', false), 'Location', 'northeast'); xlabel('Iteration'); ylabel('EVM (%)');
title('Too large: diverges. Too small: slow.');
subplot(1,2,2); plot(0:nIter, max(AC', -45), 'o-', 'LineWidth', 1.2); grid on; ylim([-40 0]); xlabel('Iteration'); ylabel('ACPR (dBc)'); title('ACPR');

%% PART C: three models, selection rule, equal power ---------------------
fprintf('\nPART C: models at mu = %.2f, selection rule: within %.1f dB of the best ACPR, lowest EVM\n', muPaper, tolACPR);
cellM = cell(3,1); selRows = zeros(3, 9); labels = cell(3,1);
fprintf('  %-6s %4s %5s %8s %6s | eq. power no-DPD: %8s %9s | gain: %7s %8s\n', 'Model', 'Nc', 'iter', 'EVM(%)', 'ACPR', 'EVM(%)', 'ACPR', 'EVM pp', 'ACPR dB');
for r = 1:3
    M = models(r,1); K = models(r,2);
    Rr = runILA(x, xd2, pa2, M, K, muPaper, lamRel, noiseAmp2, nIter, capLab, 'classic', minAmpRatio, nRowsMax, cfg);
    Rr.T.Model = repmat(string(sprintf('M%dK%d', M, K)), height(Rr.T), 1); cellM{r} = Rr.T;
    s = selectIteration(Rr.T, tolACPR);
    eE = interp1(ref.P, ref.EVM, s.Pm); aE = interp1(ref.P, ref.ACPR, s.Pm);
    labels{r} = sprintf('M%dK%d', M, K);
    selRows(r,:) = [(M+1)*K s.Iter s.EVM s.ACPR eE aE eE - s.EVM aE - s.ACPR s.dP];
    fprintf('  %-6s %4d %5d %8.2f %6.1f | %27.2f %9.1f | %7.2f %8.2f\n', labels{r}, selRows(r,1), s.Iter, s.EVM, s.ACPR, eE, aE, selRows(r,7), selRows(r,8));
end
fprintf('  Paper (Table II, selected iteration): M1K3 2.83 %% / -31.11 dBc, M3K5 3.00 / -30.99, M5K6 2.86 / -30.97. NMSE and EVM there are measured; here they are simulated.\n');

Tm = vertcat(cellM{:});
figure('Name','L04-3 Models and selection','Position',[40 40 1300 800]);
mc = lines(3);
for k = 1:3
    Tk = Tm(Tm.Model == string(labels{k}), :); sk = selectIteration(Tk, tolACPR);
    subplot(2,2,1); plot(Tk.Iter, Tk.EVM, 'o-', 'Color', mc(k,:)); hold on; plot(sk.Iter, sk.EVM, 'p', 'MarkerSize', 12, 'MarkerFaceColor', mc(k,:), 'Color', 'k');
    subplot(2,2,2); plot(Tk.Iter, Tk.ACPR, 'o-', 'Color', mc(k,:)); hold on; plot(sk.Iter, sk.ACPR, 'p', 'MarkerSize', 12, 'MarkerFaceColor', mc(k,:), 'Color', 'k');
    subplot(2,2,3); plot(Tk.Iter, Tk.dP, 'o-', 'Color', mc(k,:)); hold on;
end
subplot(2,2,1); grid on; ylabel('EVM (%)'); xlabel('Iteration'); legend(labels, 'Location', 'northeast'); title('EVM per iteration (stars = selected, paper Fig. 4)');
subplot(2,2,2); grid on; ylabel('ACPR (dBc)'); xlabel('Iteration'); title('ACPR per iteration');
subplot(2,2,3); grid on; ylabel('Output power change (dB)'); xlabel('Iteration'); title('DPD lowers the output power (peak limit)');
subplot(2,2,4); bar(1:3, [selRows(:,7) selRows(:,8)]); xticks(1:3); xticklabels(labels); grid on; legend('EVM gain (pp)', 'ACPR gain (dB)'); title('Gain over no-DPD at the SAME output power');

%% PART D: when does a model degrade? ------------------------------------
fprintf('\nPART D: M5K6, 10 iterations, effect of mu and of the peak limit\n');
cases = [0.12 1.10; 0.06 1.10; 0.12 1.50; 0.12 3.00];
Dev = zeros(size(cases,1), nIter+1); Ddc = Dev; cellD = cell(size(cases,1),1);
for q = 1:size(cases,1)
    Rq = runILA(x, xd2, pa2, 5, 6, cases(q,1), lamRel, noiseAmp2, nIter, cases(q,2), 'classic', minAmpRatio, nRowsMax, cfg);
    Dev(q,:) = Rq.T.EVM'; Ddc(q,:) = Rq.T.CNorm';
    eE = interp1(ref.P, ref.EVM, Rq.T.Pm(end));
    fprintf('  mu %.2f, peak limit %.2f: EVM it1 %.2f -> it%d %.2f | dPout %.1f dB | no-DPD at same power %.2f %%\n', cases(q,1), cases(q,2), Rq.T.EVM(2), nIter, Rq.T.EVM(end), Rq.T.dP(end), eE);
    Tq = Rq.T; Tq.mu = repmat(cases(q,1), height(Tq), 1); Tq.cap = repmat(cases(q,2), height(Tq), 1); cellD{q} = Tq;
end
Tdeg = vertcat(cellD{:});
figure('Name','L04-4 Degradation','Position',[40 40 1250 450]);
subplot(1,2,1); plot(0:nIter, Dev', 'o-', 'LineWidth', 1.2); grid on; xlabel('Iteration'); ylabel('EVM (%)');
legend(arrayfun(@(i) sprintf('\\mu %.2f, limit %.2f', cases(i,1), cases(i,2)), 1:size(cases,1), 'UniformOutput', false), 'Location', 'best'); title('M5K6: effect of mu and of the peak limit');
subplot(1,2,2); plot(0:nIter, Ddc', 'o-', 'LineWidth', 1.2); grid on; xlabel('Iteration'); ylabel('||c||'); title('Coefficient norm');

%% PART E: target and first update, separated (2x2) --------------------
fprintf('\nPART E (simulation only): EXP020 update rule vs the loop of the paper text, M3K5, 6 iterations\n');
fprintf('  Two things differ in code/EXP020: (1) the fit TARGET is the original waveform, not the one really transmitted;\n');
fprintf('  (2) iteration 1 REPLACES the coefficients (c = c_hat) and blending starts at iteration 2. 2x2 design:\n');
pa1 = @(u) paFun(u, 1); drive1 = calibrateDrive(x, pa1, targetC); xd1 = x*drive1;
noiseAmp1 = sqrt(mean(abs(pa1(xd1)).^2)) * 10^(-snrObs/20);
paList = {pa2, pa1}; xdList = {xd2, xd1}; nzList = [noiseAmp2 noiseAmp1]; pName = {'p = 2 (sharp saturation, EVM(no DPD) like the paper)', 'p = 1 (soft saturation)'};
modes = {'classic', 'emitted_full', 'original_blend', 'legacy'};
modeName = {'emitted target, blend from it. 1 (classic)', 'emitted target, it. 1 replaces', 'original target, blend from it. 1', 'original target, it. 1 replaces (EXP020)'};
figure('Name','L04-5 EXP020 vs classic','Position',[40 40 1250 450]); cellE = cell(8,1);
for q = 1:2
    subplot(1,2,q); hold on; fprintf('  %s\n', pName{q});
    for k = 1:4
        Rk = runILA(x, xdList{q}, paList{q}, 3, 5, muPaper, lamRel, nzList(q), 6, capLab, modes{k}, minAmpRatio, nRowsMax, cfg);
        fprintf('    %-45s EVM: %s\n', modeName{k}, sprintf('%7.2f', Rk.T.EVM));
        plot(0:6, min(Rk.T.EVM, 20), 'o-', 'LineWidth', 1.3);
        Tk = Rk.T; Tk.Rule = repmat(string(modes{k}), height(Tk), 1); Tk.PA = repmat(q, height(Tk), 1); cellE{4*(q-1)+k} = Tk;
    end
    grid on; xlabel('Iteration'); ylabel('EVM (%)'); legend(modeName, 'Location', 'best', 'FontSize', 8); title(pName{q});
end

%% 7. Save ---------------------------------------------------------------
Tle = vertcat(cellE{:});
writetable(A.T, fullfile(outDir, 'anatomy_M3K5.csv'));
writetable(Tmu, fullfile(outDir, 'mu_sweep.csv'));
writetable(Tm, fullfile(outDir, 'models_iterations.csv'));
writetable(array2table(selRows, 'VariableNames', {'Nc','Iter','EVM_pct','ACPR_dBc','EVM_noDPD_eqPower','ACPR_noDPD_eqPower','EVM_gain_pp','ACPR_gain_dB','dPout_dB'}, 'RowNames', labels), fullfile(outDir, 'selection.csv'), 'WriteRowNames', true);
writetable(Tdeg, fullfile(outDir, 'degradation_M5K6.csv'));
writetable(Tle, fullfile(outDir, 'exp020_vs_classic.csv'));
saveAllFigures(figDir);
fprintf('\nSaved to %s\n', outDir);
diary off;

%% ===================== Local functions =================================
function R = runILA(x, xd, pa, M, K, mu, lamRel, noiseAmp, nIter, cap, mode, minAmpRatio, nRowsMax, cfg)
    % One full training run. 'classic': target = transmitted waveform u, all iterations blended.
    % 'legacy': target = original waveform, iteration 1 replaces the coefficients (as code/EXP020).
    nc = (M+1)*K; c = zeros(nc,1); c(1) = 1; u = xd;
    Iter = zeros(nIter+1,1); EVM = Iter; ACPR = Iter; Pm = Iter; CNorm = Iter; dC = Iter; peak = Iter;
    for it = 0:nIter
        y = pa(u); yo = y + noiseAmp*cnoise(numel(y));          % measured capture (noisy)
        Iter(it+1) = it; EVM(it+1) = evmOFDM(x, yo, cfg); ACPR(it+1) = acprCentered(yo, cfg);
        Pm(it+1) = 10*log10(mean(abs(yo).^2)); CNorm(it+1) = norm(c); peak(it+1) = max(abs(u))/max(abs(xd));
        if it == 0, R.y0 = yo; end
        if it == nIter, R.yN = yo; break; end
        % mode: 'classic' = emitted target, all blended; 'legacy' = EXP020 (original target, iteration 1 replaces);
        %       'emitted_full' / 'original_blend' = the two mixed cases (2x2 design of Part E)
        origTarget = any(strcmp(mode, {'legacy', 'original_blend'}));
        firstFull  = any(strcmp(mode, {'legacy', 'emitted_full'}));
        if origTarget
            a = (yo'*xd)/(yo'*yo); yn = a*yo; target = xd;      % normalizeRxToTx of EXP020
        else
            G = (xd'*yo)/(xd'*xd); yn = yo/G; target = u;       % post-inverse of what was really transmitted
        end
        ch = fitPost(yn, target, M, K, lamRel, minAmpRatio, nRowsMax);
        if it == 0 && firstFull, cNew = ch; else, cNew = (1-mu)*c + mu*ch; end
        dC(it+1) = norm(cNew - c); c = cNew;
        u = normalizeDPD(applyMP(xd, c, M, K), xd, cap);
    end
    R.T = table(Iter, EVM, ACPR, Pm, Pm - Pm(1), CNorm, dC, peak, 'VariableNames', {'Iter','EVM','ACPR','Pm','dP','CNorm','dC','PeakRatio'});
    R.c = c;
end

function s = selectIteration(T, tol)
    % Paper rule: among iterations >= 1 whose ACPR is within tol dB of the best ACPR, keep the lowest EVM.
    Tt = T(T.Iter >= 1, :); cand = Tt(Tt.ACPR <= min(Tt.ACPR) + tol, :);
    [~, i] = min(cand.EVM); s = cand(i,:);
end

function R = refCurve(x, xd, pa, noiseAmp, cfg, dGrid)
    n = numel(dGrid); P = zeros(n,1); E = P; A = P;
    for i = 1:n
        yo = pa(xd*10^(dGrid(i)/20)); yo = yo + noiseAmp*cnoise(numel(yo));
        P(i) = 10*log10(mean(abs(yo).^2)); E(i) = evmOFDM(x, yo, cfg); A(i) = acprCentered(yo, cfg);
    end
    R.P = P; R.EVM = E; R.ACPR = A;
end

function printTable(T)
    fprintf('  %4s %8s %9s %8s %8s %8s\n', 'iter', 'EVM(%)', 'ACPR(dBc)', 'dPout', '||c||', '||dc||');
    for i = 1:height(T), fprintf('  %4d %8.2f %9.2f %8.2f %8.3f %8.3f\n', T.Iter(i), T.EVM(i), T.ACPR(i), T.dP(i), T.CNorm(i), T.dC(i)); end
end

function [yn, G] = normalizeToX(y, xd), G = (xd'*y)/(xd'*xd); yn = y/G; end

function X = mpMatrix(s, M, K)
    s = s(:); L = numel(s); X = zeros(L-M, (M+1)*K); col = 1;
    for m = 0:M
        t = s(M+1-m:end-m);
        for k = 0:K-1, X(:,col) = t .* abs(t).^(2*k); col = col + 1; end
    end
end

function y = applyMP(x, c, M, K)
    y = x; y(M+1:end) = mpMatrix(x, M, K)*c;
end

function c = fitPost(yn, target, M, K, lamRel, minAmpRatio, nMax)
    X = mpMatrix(yn, M, K); t = target(M+1:end); amp = abs(yn(M+1:end));
    idx = find(amp > minAmpRatio*max(amp)); idx = idx(1:max(1, floor(numel(idx)/nMax)):end);
    Xf = X(idx,:); R = Xf'*Xf; b = Xf'*t(idx);
    c = (R + lamRel*trace(R)/size(R,1)*eye(size(R))) \ b;
end

function z = normalizeDPD(z, ref, cap)
    % normalizeDPDWaveform of code/EXP020: match average power, then limit the peak to cap*max|ref|
    z = z * sqrt(mean(abs(ref).^2)/mean(abs(z).^2));
    pk = cap*max(abs(ref));
    if max(abs(z)) > pk, z = z / max(abs(z)) * pk; end
end

function y = paFun(u, p)
    % FIR -> Rapp (smoothness p) + AM/PM -> FIR.  p = 2 is the PA of L01-L03.
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
    for k = 1:40
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

%% ---- copied from L01-L03 ----
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
