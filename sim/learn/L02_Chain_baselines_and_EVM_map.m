%% ========================================================================
%  L02 - The measurement chain: stage-wise baselines (EXP002-004) and the
%        TX x RX EVM map (EXP006)
%  ----------------------------------------------------------------------
%  Learning module 2. No hardware. Requires nothing beyond base MATLAB + the
%  FFT. Run section by section or all at once. Outputs go to
%  sim/learn/out/L02/ (console.txt, figures/*.png, CSVs).
%
%  PART A  "How do we know WHICH block compresses?"  (paper Fig. 2 / Table I)
%     A power sweep through Pluto -> IF board -> upconverter -> filter ->
%     loopback pad -> downconverter -> Pluto RX. The STM32 + LTC5596 detector
%     can only look at ONE point at a time (behind a protection pad), so each
%     block is measured in a separate sweep, and the estimated INPUT of every
%     block comes from the baseline of the previous one. That is why the
%     scripts feed each other through baseline/*.csv.
%       gain_i        = P_out_i - P_in_i(baseline of the previous block)
%       C_i           = G_ss - gain_i      (G_ss = mean of first valid points)
%     Here we also know the TRUE values, so we can see how good the
%     estimates are.
%
%  PART B  "Where do I operate?"  (EXP006 and the Lagrava/Moncada EVM maps)
%     Sweep Pluto TX gain x Pluto RX gain and compute EVM. The map has a
%     valley with three walls: noise (low TX, low RX), compression (high TX),
%     RX clipping (high RX).
%
%  MODEL ANCHORS (what is taken from the real data, what is assumed)
%     Real : Pluto TX line (baseline/Baseline_Power_Tx_Pluto.csv fit),
%            IF-board gain 20.8 dB, upconverter gain 20.8 dB with TX DSA 5,
%            upconverter 0.5 dB compression at TX = -22.25 dB and P1dB near
%            -19.8 dB (paper Table I, Baseline_..._TXDSA5.csv),
%            IF board reaching 0.5 dB at TX ~ -15 (Baseline_Power_IF_Board.csv),
%            detector V = 28.8 mV/dB * (P + 37.9 dBm) (EXP002 raw CSV),
%            loopback 30 dB (paper), filter -3 dB.
%     Assumed (invented): downconverter gain, noise floors, Pluto RX
%            full-scale calibration, detector noise floor. The SHAPES matter,
%            not the absolute noise numbers.
%% ========================================================================

clear; close all; clc;
rng(11);

moduleName = 'L02';
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

par.plutoSlope = 0.971; par.plutoInt = -8.637;   % Pluto out (dBm) = slope*TxGain + int (fit of the SA baseline)
par.gIF   = 20.8;      % IF board small-signal gain (dB)
par.gUp   = 20.8;      % upconverter small-signal gain with TX DSA = 5 dB (dB)
par.filt  = 3.0;       % 26 GHz filter insertion loss (dB)
par.loop  = 30.0;      % RF loopback attenuator (dB); paper: 30 (EXP004 v3 used 23, EXP006 v2 used 20)
par.gDn   = 8.0;       % downconverter gain (ASSUMED)
par.PsatDn = 10.0;     % downconverter output saturation (dBm), far from reached
par.txSNR = 44.0;      % Pluto TX noise, dB below signal (ASSUMED, sets ~0.6 % EVM floor)
par.adcFloor = -54.0;  % Pluto RX noise at the ADC, dBFS (ASSUMED)
par.nominalTX = -22.25; par.nominalRX = 8;       % operating point of the DPD paper
par.nominalDBFS = -18;                           % RX level at the nominal point (ASSUMED, sets K)
par.detFloor = -42;    % detector noise floor (dBm)  (ASSUMED)
par.detSigma = 0.05;   % dB, std of the average of ~50 detector samples (ASSUMED)
par.padIF = 6; par.padUp = 22; par.padDn = 0;    % protection pads before the meter: EXP002 6 dB, EXP003 20+2 dB cable, EXP004 0 dB
par.minMeter = -32; par.minVolt = 0.15; par.maxRefMeter = -24; par.nRef = 10;   % EXP002 constants
par.peakAccept = -3;   % dBFS: captures with RX peak above this are rejected (paper)

txA = (-44:0.5:-6).';  % Part A sweep (EXP002 default range)
txB = (-40:1:-10).';   % Part B sweep
rxB = (0:2:24).';

%% 1. Signal -------------------------------------------------------------
% Same 256-QAM OFDM as L01, scaled so that mean|x|^2 = 1 mW. Then a waveform
% sample amplitude^2 is directly power in mW and dBm = 10*log10(mean|s|^2).
x = generateOFDM(cfg);
Xf = fft(x); fAxis = (0:numel(x)-1).'/numel(x)*cfg.fs;
fAxis(fAxis >= cfg.fs/2) = fAxis(fAxis >= cfg.fs/2) - cfg.fs;
Xf(abs(fAxis) > 0.50*cfg.bw) = 0;
x = ifft(Xf); x = x / sqrt(mean(abs(x).^2));
fprintf('PAPR = %.1f dB\n', 20*log10(max(abs(x))/rms(x)));

%% 2. Calibrate the model against the real anchors -----------------------
% (a) IF board: Psat so that its compression is 0.5 dB at TX = -15 dB.
par.PsatIF = bisect(@(ps) 0.5 - cIFboard(x, par, ps, -15), -20, 30);
% (b) Upconverter: Psat so that its compression is 0.5 dB at the nominal TX.
%     (done AFTER the IF board, because IF peak clipping changes what the upconverter sees)
par.PsatUp = bisect(@(ps) 0.5 - cUpconv(x, par, ps, par.nominalTX), 0, 40);
% (c) Pluto RX full-scale constant so that the nominal point lands at nominalDBFS.
par.K = 0;  o = chainRun(x, par.nominalTX, par.nominalRX, par, false);
par.K = par.nominalDBFS - o.dbfs;
fprintf('Calibration: IF Psat = %.2f dBm, upconverter Psat = %.2f dBm, RX constant K = %.2f dB\n', par.PsatIF, par.PsatUp, par.K);
fprintf('Check: upconverter C at TX -22.25 = %.2f dB, at -19.8 = %.2f dB (paper P1dB: -19.78)\n\n', ...
    cUpconv(x, par, par.PsatUp, -22.25), cUpconv(x, par, par.PsatUp, -19.8));

%% PART A ---------------------------------------------------------------
% 3. Sweep TxGain once; keep the TRUE power at every node (known here) and
%    what the detector would READ at the three measurement points.
nA = numel(txA);
T = struct('pluto',zeros(nA,1),'ifo',zeros(nA,1),'rfpin',zeros(nA,1),'af',zeros(nA,1),'dnin',zeros(nA,1),'ifback',zeros(nA,1));
for k = 1:nA
    o = chainRun(x, txA(k), par.nominalRX, par, false);     % noiseless: only the meter is noisy
    T.pluto(k)=o.pluto; T.ifo(k)=o.ifo; T.rfpin(k)=o.rfpin; T.af(k)=o.af; T.dnin(k)=o.dnin; T.ifback(k)=o.ifback;
end
plutoBase = T.pluto + 0.05*randn(nA,1);                      % spectrum-analyzer baseline of the Pluto (EXP002 input)

% 3a. EXP002: IF board. Meter sees IF out - 6 dB.
[mIF, vIF] = meterRead(T.ifo - par.padIF, par);
ifOut   = mIF + par.padIF;
gIFm    = ifOut - plutoBase;
[G0IF, cIFm, validIF] = smallSignalCompression(gIFm, mIF, vIF, par);
ifBase  = ifOut;  ifBase(~validIF) = plutoBase(~validIF) + G0IF;   % extrapolation below the detector floor (EXP002)

% 3b. EXP003: upconverter. Meter sees (RF out after filter) - 22 dB. Input = IF baseline.
[mUp, vUp] = meterRead(T.af - par.padUp, par);
afMeas  = mUp + par.padUp;               % RF out after filter
rfPin   = afMeas + par.filt;             % at the RF_OUT pin
gUpm    = rfPin - ifBase;
[G0Up, cUpm, validUp] = smallSignalCompression(gUpm, mUp, vUp, par);
afBase  = afMeas;  afBase(~validUp) = ifBase(~validUp) + G0Up - par.filt;

% 3c. EXP004: downconverter. Meter sees IF out directly. Input = AF baseline - loopback pad.
[mDn, vDn] = meterRead(T.ifback - par.padDn, par);
dnInEst = afBase - par.loop;
gDnm    = (mDn + par.padDn) - dnInEst;
[G0Dn, cDnm, validDn] = smallSignalCompression(gDnm, mDn, vDn, par);

% 3d. TRUE compression of each block (known only in simulation)
gIFt = T.ifo - T.pluto;   gUpt = T.rfpin - T.ifo;   gDnt = T.ifback - T.dnin;
cIFt = mean(gIFt(1:5)) - gIFt;  cUpt = mean(gUpt(1:5)) - gUpt;  cDnt = mean(gDnt(1:5)) - gDnt;

% 3e. Summary table
fprintf('Part A: stage-wise results (TxGain at which C reaches 1 dB, "none" = not reached in -44..-6 dB)\n');
fprintf('  %-12s %8s %12s %12s %14s %14s\n', 'Block', 'Gss(dB)', 'TX@1dB est', 'TX@1dB true', 'C@-22.25 est', 'C@-22.25 true');
rows = {'IF board', G0IF, cIFm, cIFt; 'Upconverter', G0Up, cUpm, cUpt; 'Downconv.', G0Dn, cDnm, cDnt};
for r = 1:3
    fprintf('  %-12s %8.2f %12s %12s %14.2f %14.2f\n', rows{r,1}, rows{r,2}, ...
        crossStr(txA, rows{r,3}, 1), crossStr(txA, rows{r,4}, 1), ...
        interp1(txA, rows{r,3}, par.nominalTX), interp1(txA, rows{r,4}, par.nominalTX));
end
fprintf('  Paper Table I: upconverter P1dB at TX -19.78 dB, C = 0.50 dB at -22.25 dB; IF block "not reached"; downconverter "not reached".\n');
fprintf('  NOTE: Baseline_Power_IF_Board.csv reaches 1 dB at TX -11 dB, i.e. inside the swept range. Open question vs Table I.\n\n');

% 3f. Power budget at the nominal point
oN = chainRun(x, par.nominalTX, par.nominalRX, par, false);
budget = [oN.pluto oN.ifo oN.rfpin oN.af oN.dnin oN.ifback];
bNames = {'Pluto out','IF board out','Upconv. RF_OUT pin','After filter','Downconv. RF_IN','IF back (meter)'};
fprintf('Power budget at TX = %.2f dB (average power, dBm):\n', par.nominalTX);
for k = 1:numel(budget), fprintf('  %-20s %8.2f\n', bNames{k}, budget(k)); end
fprintf('  RX level: %.1f dBFS rms, %.1f dBFS peak at RX gain %d dB\n\n', oN.dbfs, oN.peak, par.nominalRX);

% 4. Figure A
figure('Name','L02-1 Stage-wise baselines','Position',[40 40 1250 800]);
subplot(2,2,1);
pTrue = (-60:0.5:0).'; pm = meterRead(pTrue, par);
plot(pTrue, pTrue, 'k--'); hold on; plot(pTrue, pm, 'LineWidth', 1.4); xline(par.minMeter, ':r', 'valid above'); grid on;
xlabel('True power at detector (dBm)'); ylabel('Detector reading (dBm)'); legend('ideal','detector (noise floor)','Location','northwest');
title('Detector: reads high near its floor');
subplot(2,2,2);
plot(txA, gIFm, 'o', 'MarkerSize', 3); hold on; plot(txA, gUpm, 's', 'MarkerSize', 3); plot(txA, gDnm, '^', 'MarkerSize', 3);
plot(txA, gIFt, 'b-'); plot(txA, gUpt, 'r-'); plot(txA, gDnt, 'g-'); grid on; ylim([-20 35]);
xlabel('Pluto TxGain (dB)'); ylabel('Gain (dB)'); title('Block gains: estimated (markers) vs true (lines)');
legend('IF est','Up est','Down est','IF true','Up true','Down true','Location','best');
subplot(2,2,3);
plot(txA, cIFm, 'o', 'MarkerSize', 3); hold on; plot(txA, cUpm, 's', 'MarkerSize', 3); plot(txA, cDnm, '^', 'MarkerSize', 3);
plot(txA, cIFt, 'b-'); plot(txA, cUpt, 'r-'); plot(txA, cDnt, 'g-');
yline(1, '--k', '1 dB'); xline(par.nominalTX, ':k', 'DPD point'); grid on; ylim([-1 4]);
xlabel('Pluto TxGain (dB)'); ylabel('Compression C = G_{ss} - G (dB)'); title('Paper Fig. 2: only the upconverter compresses at the DPD point');
subplot(2,2,4);
plot(1:numel(budget), budget, 'o-', 'LineWidth', 1.4); grid on; xticks(1:numel(budget)); xticklabels(bNames); xtickangle(25); set(gca, 'TickLabelInterpreter', 'none');
ylabel('Average power (dBm)'); title(sprintf('Power budget at TX = %.2f dB', par.nominalTX));

%% PART B ---------------------------------------------------------------
% 5. EVM map. Every point: run the chain WITH noise and clipping, then EVM.
nT = numel(txB); nR = numel(rxB);
EVM = zeros(nR, nT); PK = zeros(nR, nT); CUP = zeros(1, nT);
for j = 1:nT
    CUP(j) = cUpconv(x, par, par.PsatUp, txB(j));
    for i = 1:nR
        [o, y] = chainRun(x, txB(j), rxB(i), par, true);
        EVM(i,j) = evmOFDM(x, y, cfg);
        PK(i,j)  = o.peak;
    end
end
acc = PK < par.peakAccept;
EVMacc = EVM; EVMacc(~acc) = inf;
[minEVM, iMin] = min(EVMacc(:)); [iR, iT] = ind2sub(size(EVM), iMin);
[~, jN] = min(abs(txB - par.nominalTX)); [~, iN] = min(abs(rxB - par.nominalRX));
fprintf('Part B: EVM map %d TX x %d RX points\n', nT, nR);
fprintf('  Minimum EVM among accepted captures (peak < %.0f dBFS): %.2f %% at TX %.0f dB, RX %d dB   (Lagrava: 1.27 %%, Moncada: ~1.2 %%)\n', ...
    par.peakAccept, minEVM, txB(iT), rxB(iR));
fprintf('  Nominal DPD point (TX %.0f, RX %d): EVM = %.2f %%, peak %.1f dBFS  (paper no-DPD: 6.47 %%)\n', txB(jN), rxB(iN), EVM(iN,jN), PK(iN,jN));
fprintf('\n  Best accepted RX per TX (the "best-rx-per-tx" table of EXP006):\n  %6s %6s %9s %10s\n', 'TX', 'RX', 'EVM(%)', 'C_up(dB)');
bestRX = nan(nT,1); bestEVM = nan(nT,1);
for j = 1:nT
    [e, i] = min(EVMacc(:,j)); if isfinite(e), bestRX(j) = rxB(i); bestEVM(j) = e; end
end
for j = 1:4:nT, fprintf('  %6.0f %6.0f %9.2f %10.2f\n', txB(j), bestRX(j), bestEVM(j), CUP(j)); end
fprintf('\n');

% 6. Figure B
figure('Name','L02-2 EVM map TX x RX','Position',[40 40 1250 800]);
subplot(2,2,1);
imagesc(txB, rxB, EVM); set(gca, 'YDir', 'normal', 'ColorScale', 'log'); colormap(turbo); clim([1 20]); colorbar; hold on;
contour(txB, rxB, PK, [par.peakAccept par.peakAccept], 'w--', 'LineWidth', 1.6);
contour(txB, rxB, PK, [0 0], 'r', 'LineWidth', 1.6);
plot(txB(iT), rxB(iR), 'wp', 'MarkerFaceColor', 'w', 'MarkerSize', 12);
plot(par.nominalTX, par.nominalRX, 'ks', 'MarkerFaceColor', 'y', 'MarkerSize', 9);
text(-39, 3, 'noise', 'Color', 'w', 'FontWeight', 'bold'); text(-17, 4, 'compression', 'Color', 'w', 'FontWeight', 'bold');
text(-30, 22.5, 'RX clipping', 'Color', 'w', 'FontWeight', 'bold');
xlabel('Pluto TX gain (dB)'); ylabel('Pluto RX gain (dB)');
title({'EVM (%) map', 'white dashed: peak = -3 dBFS, red: clipping; star = min, square = DPD point'});
subplot(2,2,2);
yyaxis left; plot(txB, EVM(iN,:), 'o-', txB, EVM(find(rxB==16,1),:), 's-'); ylabel('EVM (%)'); set(gca, 'YScale', 'log');
yline(3.5, '--', '3.5 %'); yyaxis right; plot(txB, CUP, 'k:', 'LineWidth', 1.5); ylabel('Upconverter compression (dB)');
grid on; xlabel('Pluto TX gain (dB)'); legend('RX 8 dB','RX 16 dB','C_{up}','Location','north'); title('EVM vs TX: noise on the left, compression on the right');
subplot(2,2,3);
semilogy(rxB, EVM(:, jN), 'o-', rxB, EVM(:, find(txB==-30,1)), 's-'); hold on; grid on;
xline(rxB(find(PK(:,jN) >= par.peakAccept, 1)), ':', 'peak limit (TX -22)');
xlabel('Pluto RX gain (dB)'); ylabel('EVM (%)'); legend('TX -22 dB', 'TX -30 dB', 'Location','northeast');
title('EVM vs RX: falls with gain until the ADC clips');
subplot(2,2,4);
yyaxis left; plot(txB, bestEVM, 'o-'); ylabel('Best accepted EVM (%)'); set(gca, 'YScale', 'log');
yyaxis right; plot(txB, bestRX, 's-'); ylabel('RX gain of that best point (dB)'); grid on;
xlabel('Pluto TX gain (dB)'); title('Best RX for each TX (EXP006 best-rx-per-tx)');

%% 7. Save ---------------------------------------------------------------
baseT = table(txA, plutoBase, ifBase, afBase, gIFm, gUpm, gDnm, cIFm, cUpm, cDnm, cIFt, cUpt, cDnt, ...
    'VariableNames', {'TxGain_dB','PlutoOutBaseline_dBm','IFBoardOutputBaseline_dBm','RFOutAfterFilterBaseline_dBm', ...
    'IFGain_est_dB','UpGain_est_dB','DnGain_est_dB','IFComp_est_dB','UpComp_est_dB','DnComp_est_dB','IFComp_true_dB','UpComp_true_dB','DnComp_true_dB'});
writetable(baseT, fullfile(outDir, 'stagewise_baselines.csv'));
[TT, RR] = meshgrid(txB, rxB);
mapT = table(TT(:), RR(:), EVM(:), PK(:), acc(:), 'VariableNames', {'TxGain_dB','RxGain_dB','EVM_pct','RxPeak_dBFS','Accepted'});
writetable(mapT, fullfile(outDir, 'evm_map.csv'));
writetable(table(txB, bestRX, bestEVM, CUP(:), 'VariableNames', {'TxGain_dB','BestRx_dB','BestEVM_pct','UpComp_dB'}), fullfile(outDir, 'best_rx_per_tx.csv'));
saveAllFigures(figDir);
fprintf('Saved to %s\n', outDir);
diary off;

%% ===================== Local functions =================================
function [o, y] = chainRun(x, txg, rxg, par, addNoise)
    % Whole chain in complex baseband; amplitude^2 = mW.
    pl = par.plutoSlope*txg + par.plutoInt;               % Pluto output, dBm
    s = x * 10^(pl/20);
    if addNoise, s = s + cnoise(numel(s)) * 10^((pl - par.txSNR)/20); end
    ifo = rapp(s, par.gIF, par.PsatIF, 0);                % IF board
    v = filter([1 0.15 -0.05], 1, ifo);                   % upconverter: input memory, Rapp + AM/PM, output memory
    up = filter([1 0.08], 1, rapp(v, par.gUp - 1.44, par.PsatUp, 0.3));
    af = up * 10^(-par.filt/20);                          % 26 GHz filter
    dnin = af * 10^(-par.loop/20);                        % loopback attenuator
    dn = rapp(dnin, par.gDn, par.PsatDn, 0);              % downconverter
    o.pluto = pl; o.ifo = pw(ifo); o.rfpin = pw(up); o.af = pw(af); o.dnin = pw(dnin); o.ifback = pw(dn);
    y = dn * 10^((rxg + par.K)/20);                       % Pluto RX gain; |y| = 1 is 0 dBFS
    if addNoise, y = y + cnoise(numel(y)) * 10^(par.adcFloor/20); end
    a = abs(y); y = y .* min(1, 1 ./ max(a, 1e-12));      % ADC clipping (radial limiter)
    o.dbfs = pw(y); o.peak = 20*log10(max(abs(y)));
end

function y = rapp(u, Gdb, PsatDbm, phimax)
    % Rapp limiter (p=2) at the OUTPUT: gain Gdb, saturation amplitude sqrt(10^(Psat/10)).
    Gl = 10^(Gdb/20); As = sqrt(10^(PsatDbm/10));
    v = Gl*u; a = abs(v);
    y = v ./ (1 + (a/As).^4).^(1/4);
    if phimax ~= 0, y = y .* exp(1j*phimax*(a/As).^2 ./ (1 + (a/As).^2)); end
end

function c = cIFboard(x, par, Psat, txg)
    pl = par.plutoSlope*txg + par.plutoInt; s = x*10^(pl/20);
    c = par.gIF - (pw(rapp(s, par.gIF, Psat, 0)) - pw(s));
end

function c = cUpconv(x, par, Psat, txg)
    % True compression of the upconverter alone, fed by the (already compressing) IF board.
    pl = par.plutoSlope*txg + par.plutoInt; ifo = rapp(x*10^(pl/20), par.gIF, par.PsatIF, 0);
    f = @(s) filter([1 0.08], 1, rapp(filter([1 0.15 -0.05], 1, s), par.gUp - 1.44, Psat, 0.3));
    small = ifo * 10^(-40/20);
    c = (pw(f(small)) - pw(small)) - (pw(f(ifo)) - pw(ifo));
end

function [pm, v] = meterRead(pTrue, par)
    % LTC5596 + STM32: noise floor adds power; V = 28.8 mV/dB * (P + 37.9 dBm)
    pm = 10*log10(10.^(pTrue/10) + 10^(par.detFloor/10)) + par.detSigma*randn(size(pTrue));
    v = 0.0288 * (pm + 37.9);
end

function [G0, C, valid] = smallSignalCompression(gain, meterP, volt, par)
    % Same logic as EXP002 v3: reliable points are above the detector floor; G_ss is the mean gain
    % of the first nRef reliable points whose meter power is below maxRefMeter.
    valid = isfinite(gain) & meterP > par.minMeter & volt > par.minVolt;
    ref = valid & meterP < par.maxRefMeter; if nnz(ref) < 2, ref = valid; end
    idx = find(ref); idx = idx(1:min(par.nRef, numel(idx)));
    G0 = mean(gain(idx));
    C = nan(size(gain)); C(valid) = G0 - gain(valid);
end

function s = crossStr(x, c, target)
    i = find(c >= target, 1, 'first');
    if isempty(i), s = 'none'; return; end
    if i == 1, s = sprintf('%.1f', x(1)); return; end
    s = sprintf('%.1f', x(i-1) + (target - c(i-1))*(x(i)-x(i-1))/(c(i)-c(i-1)));
end

function r = bisect(f, lo, hi)
    % root of f on [lo,hi] (f(lo) and f(hi) must have opposite signs)
    flo = f(lo);
    for k = 1:40
        mid = (lo+hi)/2; fm = f(mid);
        if sign(fm) == sign(flo), lo = mid; flo = fm; else, hi = mid; end
    end
    r = (lo+hi)/2;
end

function p = pw(s), p = 10*log10(mean(abs(s).^2)); end
function n = cnoise(N), n = (randn(N,1) + 1j*randn(N,1))/sqrt(2); end

%% ---- copied from L01 (same definitions as code/EXP020) ----
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
