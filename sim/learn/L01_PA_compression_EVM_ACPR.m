%% ========================================================================
%  L01 - Why a PA/upconverter needs DPD: compression, AM/AM, AM/PM, EVM, ACPR
%  ----------------------------------------------------------------------
%  Learning module 1 of the DPD paper (RF_DPD_v4). No hardware.
%  Requires: Signal Processing Toolbox (pwelch). Run section by section
%  (Ctrl+Enter in MATLAB Online) or the whole file.
%
%  What you will see, in the same order as the paper:
%    Fig 1  The test signal: 20 MHz, 30 kHz SCS, 256-QAM OFDM, PAPR ~ 11 dB
%    Fig 2  A power sweep -> gain, gain compression C = Gss - G, EVM, ACPR
%           (this is the same logic as EXP002/003/004 and EXP006)
%    Fig 3  AM/AM and AM/PM at three drive levels (0.1, 0.5, 1.5 dB comp.)
%    Fig 4  Spectrum before/after the PA (spectral regrowth -> ACPR)
%    Fig 5  Received constellation at the same three levels (-> EVM)
%
%  The "PA" here is a made-up model (FIR -> Rapp AM/AM + AM/PM -> FIR), so
%  the NUMBERS will not match the lab. The SHAPES and the ORDER OF EVENTS
%  are what you should compare with real captures.
%% ========================================================================

clear; close all; clc;
rng(7);

% Outputs go to sim/learn/out/L01/ (console.txt, figures/*.png, *.csv) so that
% after a run you can commit + push them and they can be reviewed from the repo.
moduleName = 'L01';
scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir), scriptDir = pwd; end
outDir = fullfile(scriptDir, 'out', moduleName);
figDir = fullfile(outDir, 'figures');
if ~exist(figDir, 'dir'), mkdir(figDir); end
delete(fullfile(figDir, '*.png'));                 % keep only the latest run
diary off; diary(fullfile(outDir, 'console.txt'));  % everything printed below is logged
fprintf('%s run: %s  (MATLAB %s)\n\n', moduleName, datestr(now,'yyyy-mm-dd HH:MM:SS'), version);

%% 0. Configuration ------------------------------------------------------
cfg.nfft    = 2048;            % FFT size. 2048 * 30 kHz = 61.44 MS/s (rate fixed in EXP031-037)
cfg.scs     = 30e3;            % subcarrier spacing (paper: 30 kHz)
cfg.nActive = 612;             % 51 RB * 12 subcarriers = 20 MHz carrier (paper)
cfg.ncp     = 144;             % cyclic prefix samples
cfg.nSym    = 60;              % OFDM symbols in the capture
cfg.fs      = cfg.nfft*cfg.scs;
cfg.bw      = cfg.nActive*cfg.scs;      % occupied bandwidth, 18.36 MHz
cfg.idx     = [cfg.nfft-cfg.nActive/2+1:cfg.nfft, 2:cfg.nActive/2+1].';

levelsDB = (-34:1:-2).';       % drive sweep: RMS of the PA input in dB re 1.0 (PA saturates near 1.0)
Cgrid    = [0.1 0.5 1.5];      % compression (dB) at which we look closely; 0.5 dB = paper operating point
nSS      = 5;                  % first points used as small-signal reference (as in EXP002)

%% 1. Test signal --------------------------------------------------------
% STEP: random 256-QAM symbols on 612 subcarriers -> IFFT -> add cyclic prefix.
% WHY : OFDM is a sum of 612 independent tones, so by the central limit theorem
%       its amplitude is Gaussian-like -> rare, very large peaks (high PAPR).
%       Those peaks are what drive the PA into compression.
[x0, S] = generateOFDM(cfg);

% STEP: brick-wall filter to remove the sinc skirts created by gluing symbols
%       together without windowing (real 5G uses windowing for the same reason).
%       Without it the INPUT itself would already have a poor ACPR and hide the PA.
Xf = fft(x0);
fAxis = (0:numel(x0)-1).'/numel(x0)*cfg.fs;
fAxis(fAxis >= cfg.fs/2) = fAxis(fAxis >= cfg.fs/2) - cfg.fs;
Xf(abs(fAxis) > 0.50*cfg.bw) = 0;     % cut exactly at the band edge (0.52 left a -28 dBc ACPR floor, 0.50 gives ~-40)
x = ifft(Xf);
x = x / sqrt(mean(abs(x).^2));          % unit RMS: drive level is set later

papr = 20*log10(max(abs(x))/rms(x));
fprintf('Signal: %d samples, fs = %.2f MS/s, occupied BW = %.2f MHz\n', numel(x), cfg.fs/1e6, cfg.bw/1e6);
fprintf('PAPR = %.1f dB   (paper: ~11.3 dB)\n', papr);
fprintf('ACPR of the input itself = %.1f dBc   (floor: nothing below this can be measured)\n', acprCentered(x, cfg));
[evmIn, ~] = evmOFDM(x, x, cfg);
fprintf('EVM of the input vs itself = %.3f %%   (must be ~0: sanity check of the demodulator)\n\n', evmIn);

figure('Name','L01-1 Signal','Position',[50 50 1100 380]);
subplot(1,3,1);
[p, f] = pwelch(x, hamming(4096), [], 8192, cfg.fs, 'centered');
plot(f/1e6, 10*log10(p/max(p))); grid on; xlim([-30 30]); ylim([-90 5]);
xlabel('Frequency (MHz)'); ylabel('PSD (dB, normalized)'); title('Spectrum: flat 20 MHz block');
subplot(1,3,2);
histogram(abs(x)/rms(x), 80, 'Normalization','pdf'); grid on;
xlabel('|x| / RMS'); ylabel('pdf'); title('Amplitude (Rayleigh-like)');
subplot(1,3,3);
amp = sort(20*log10(abs(x)/rms(x)));
ccdf = 1 - (1:numel(amp)).'/numel(amp);
semilogy(amp, ccdf); grid on; xlim([0 papr+1]); ylim([1e-5 1]);
xlabel('Instantaneous power above average (dB)'); ylabel('P(power > abscissa)');
title('CCDF: rare peaks 8-10 dB over RMS');

%% 2. Power sweep: gain, compression, EVM, ACPR -------------------------
% STEP: scale the same waveform to many RMS levels and push each through the PA.
% WHY : this is the simulated version of the hardware sweeps. In the lab the
%       knob is the Pluto TxGain; here it is the RMS of the PA input.
%   Gain       G_i = 10 log10( mean|y|^2 / mean|u|^2 )         (average power gain)
%   Small-sig  Gss = mean of G over the first nSS points
%   Compression C_i = Gss - G_i                                (paper Eq. 1)
nL = numel(levelsDB);
Pin = zeros(nL,1); Pout = zeros(nL,1); evm = zeros(nL,1); acpr = zeros(nL,1);
for k = 1:nL
    u = x * 10^(levelsDB(k)/20);
    y = simulatedPA(u);
    Pin(k)  = 10*log10(mean(abs(u).^2));
    Pout(k) = 10*log10(mean(abs(y).^2));
    evm(k)  = evmOFDM(x, y, cfg);
    acpr(k) = acprCentered(y, cfg);
end
G   = Pout - Pin;
Gss = mean(G(1:nSS));
C   = Gss - G;

pC = @(t) findCrossing(Pin, C, t);          % drive level (dB) where C reaches t
P1dB_in = pC(1.0);
fprintf('Small-signal gain Gss = %.2f dB\n', Gss);
fprintf('Input-referred P1dB (average-power sense) = %.2f dB re 1.0\n', P1dB_in);
fprintf('\n  C (dB)   drive (dB)   EVM (%%)   ACPR (dBc)\n');
levAt = zeros(size(Cgrid));
for j = 1:numel(Cgrid)
    levAt(j) = pC(Cgrid(j));
    fprintf('  %5.2f    %7.2f      %6.2f     %7.2f\n', Cgrid(j), levAt(j), ...
        interp1(Pin, evm, levAt(j)), interp1(Pin, acpr, levAt(j)));
end
fprintf('\nReference, paper at ~0.5 dB compression: EVM 6.47 %%, ACPR -26.57 dBc (no DPD).\n\n');

figure('Name','L01-2 Power sweep','Position',[50 50 1100 700]);
subplot(2,2,1); plot(Pin, Pout, 'o-', Pin, Pin+Gss, '--'); grid on;
xlabel('Pin (dB)'); ylabel('Pout (dB)'); legend('measured','ideal linear','Location','best');
title('Pout vs Pin: curve bends away from the line');
subplot(2,2,2); plot(Pin, C, 'o-'); grid on; yline(1,'--','1 dB'); yline(0.5,':','0.5 dB');
xlabel('Pin (dB)'); ylabel('Compression C = Gss - G (dB)'); title('Gain compression (paper Fig. 2 y-axis)');
subplot(2,2,3); plot(Pin, evm, 'o-'); grid on; xlabel('Pin (dB)'); ylabel('EVM (%)');
yline(3.5,'--','3GPP 256QAM 3.5 %'); title('EVM: flat at ~0 until compression starts');
subplot(2,2,4); plot(Pin, acpr, 'o-'); grid on; xlabel('Pin (dB)'); ylabel('ACPR (dBc)');
title('ACPR: ~2 dB per dB of drive while 3rd order dominates');

%% 3. AM/AM and AM/PM at three operating points --------------------------
% AM/AM : |output| vs |input|   -> gain falls at large amplitude
% AM/PM : phase(output)-phase(input) vs |input| -> phase rotates with amplitude
% Both are measured sample by sample, so the scatter WIDTH is the memory effect
% (output depends on past samples, not just the current one).
uS = x * 10^(levelsDB(1)/20);                % lowest drive = linear reference
yS = simulatedPA(uS);
g0 = (uS'*yS)/(uS'*uS);                      % complex small-signal gain (magnitude + phase)

figure('Name','L01-3 AM/AM AM/PM','Position',[50 50 1100 650]);
col = lines(3); nPlot = 12000; sel = round(linspace(1, numel(x), nPlot));
for j = 1:numel(Cgrid)
    u = x * 10^(levAt(j)/20);  y = simulatedPA(u);
    subplot(2,3,j);
    plot(abs(u(sel)), abs(y(sel))/abs(g0), '.', 'Color', col(j,:), 'MarkerSize', 3); hold on;
    plot([0 max(abs(u))], [0 max(abs(u))], 'k--'); grid on;
    xlabel('|input|'); ylabel('|output| / |g_{ss}|'); title(sprintf('AM/AM, C = %.1f dB', Cgrid(j)));
    subplot(2,3,3+j);
    ph = angle(y(sel).*conj(u(sel))) - angle(g0); ph = angle(exp(1j*ph))*180/pi;
    plot(abs(u(sel)), ph, '.', 'Color', col(j,:), 'MarkerSize', 3); grid on;
    xlabel('|input|'); ylabel('Phase shift (deg)'); title(sprintf('AM/PM, C = %.1f dB', Cgrid(j)));
end

%% 4. Spectrum before/after the PA ---------------------------------------
% Odd-order nonlinearity (3rd, 5th, ...) turns the 18 MHz block into a signal
% about 3x, 5x wider: that out-of-band energy is "spectral regrowth".
% ACPR = power in the adjacent channels / power in the main channel.
figure('Name','L01-4 Spectrum','Position',[50 50 1100 450]);
hold on;
[p0, f] = pwelch(x, hamming(4096), [], 8192, cfg.fs, 'centered');
plot(f/1e6, 10*log10(p0/max(p0)), 'k', 'LineWidth', 1.2);
leg = {'input'};
for j = 1:numel(Cgrid)
    u = x * 10^(levAt(j)/20);  y = simulatedPA(u);
    [py, f] = pwelch(y, hamming(4096), [], 8192, cfg.fs, 'centered');
    plot(f/1e6, 10*log10(py/max(py)), 'Color', col(j,:));
    leg{end+1} = sprintf('C = %.1f dB (ACPR %.1f dBc)', Cgrid(j), acprCentered(y, cfg)); %#ok<SAGROW>
end
xline([-1.5 -0.5 0.5 1.5]*cfg.bw/1e6, ':'); grid on; xlim([-30 30]); ylim([-90 5]);
xlabel('Frequency (MHz)'); ylabel('PSD (dB, normalized to peak)'); legend(leg, 'Location','south');
title('Dotted lines: main channel and the two adjacent channels used for ACPR');

%% 5. Constellations -----------------------------------------------------
% After the receiver equalizes ONE complex gain per subcarrier, what is left
% is distortion. EVM = RMS(error)/RMS(ideal). 256-QAM needs <3.5 % (3GPP).
figure('Name','L01-5 Constellation','Position',[50 50 1100 380]);
for j = 1:numel(Cgrid)
    u = x * 10^(levAt(j)/20);  y = simulatedPA(u);
    [e, Yeq] = evmOFDM(x, y, cfg);
    subplot(1,3,j); plot(real(Yeq(:)), imag(Yeq(:)), '.', 'MarkerSize', 2); axis equal; grid on;
    title(sprintf('C = %.1f dB, EVM = %.2f %%', Cgrid(j), e));
end

fprintf('WHAT TO CHECK\n');
fprintf(' 1. Fig 2: EVM ~ 0 and C ~ 0 at low drive; both rise once the peaks reach the knee of the PA.\n');
fprintf(' 2. Fig 2: at C = 0.5 dB, EVM is already several %% -> far above the 3.5 %% limit; that is why DPD is needed\n');
fprintf('    even with "only" 0.5 dB of compression (the paper operating point).\n');
fprintf(' 3. Fig 3: AM/AM scatter bends below the dashed line only at large |input|; scatter width = memory.\n');
fprintf(' 4. Fig 4: shoulders appear next to the main block and grow with drive.\n');

%% 6. Save outputs --------------------------------------------------------
sweepTable = table(levelsDB, Pin, Pout, G, C, evm, acpr, ...
    'VariableNames', {'Drive_dB','Pin_dB','Pout_dB','Gain_dB','Compression_dB','EVM_pct','ACPR_dBc'});
writetable(sweepTable, fullfile(outDir, 'sweep.csv'));
opTable = table(Cgrid(:), levAt(:), interp1(Pin, evm, levAt(:)), interp1(Pin, acpr, levAt(:)), ...
    'VariableNames', {'Compression_dB','Drive_dB','EVM_pct','ACPR_dBc'});
writetable(opTable, fullfile(outDir, 'operating_points.csv'));
saveAllFigures(figDir);
fprintf('\nSaved to %s\n', outDir);
diary off;

%% ===================== Local functions =================================
function saveAllFigures(figDir)
    % One PNG per open figure, named after its 'Name' property.
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

function [x, S] = generateOFDM(cfg)
    lv = -15:2:15;                                  % 256-QAM levels per axis
    S  = (lv(randi(16, cfg.nActive, cfg.nSym)) + 1j*lv(randi(16, cfg.nActive, cfg.nSym))) / sqrt(170);
    x  = zeros(cfg.nSym*(cfg.nfft+cfg.ncp), 1);
    for s = 1:cfg.nSym
        F = zeros(cfg.nfft,1);  F(cfg.idx) = S(:,s);
        t = ifft(F)*sqrt(cfg.nfft);
        x((s-1)*(cfg.nfft+cfg.ncp) + (1:cfg.nfft+cfg.ncp)) = [t(end-cfg.ncp+1:end); t];
    end
end

function y = simulatedPA(u)
    % FIR (input match) -> Rapp AM/AM + AM/PM (static nonlinearity) -> FIR (output match)
    u = u(:);
    v = filter([1 0.15 -0.05], 1, u);
    a = abs(v); Asat = 1; p = 2;
    g = 1 ./ (1 + (a/Asat).^(2*p)).^(1/(2*p));      % Rapp: smooth limiter
    phi = 0.3 * a.^2 ./ (1 + a.^2);                  % amplitude-dependent phase (rad)
    w = v .* g .* exp(1j*phi);
    y = filter([1 0.08], 1, w);
end

function S = demodOFDM(sig, cfg)
    S = zeros(cfg.nActive, cfg.nSym);
    for s = 1:cfg.nSym
        i0 = (s-1)*(cfg.nfft+cfg.ncp) + cfg.ncp;
        F = fft(sig(i0 + (1:cfg.nfft))) / sqrt(cfg.nfft);
        S(:,s) = F(cfg.idx);
    end
end

function [evm, Yeq] = evmOFDM(xref, y, cfg)
    % EVM vs the transmitted waveform, after one complex equalizer tap per subcarrier
    % (estimated on the whole capture, like a channel estimate).
    Xs = demodOFDM(xref(:), cfg);  Ys = demodOFDM(y(:), cfg);
    H  = sum(conj(Xs).*Ys, 2) ./ sum(abs(Xs).^2, 2);
    Yeq = Ys ./ H;
    evm = 100*sqrt(sum(abs(Yeq - Xs).^2, 'all') / sum(abs(Xs).^2, 'all'));
end

function acpr_dBc = acprCentered(x, cfg)
    % Same definition as computeACPRCentered in code/EXP020: main = |f|<=bw/2,
    % adjacent = [0.5bw,1.5bw] on each side, SUM of both sides (so it reads ~3 dB
    % worse than a single-side ACPR).
    x = x(:) - mean(x);
    [pxx, f] = pwelch(x, hamming(4096), [], 8192, cfg.fs, 'centered');
    main = abs(f) <= cfg.bw/2;
    lo = (f >= -1.5*cfg.bw) & (f < -0.5*cfg.bw);
    hi = (f >  0.5*cfg.bw) & (f <= 1.5*cfg.bw);
    acpr_dBc = 10*log10((trapz(f(lo),pxx(lo)) + trapz(f(hi),pxx(hi))) / trapz(f(main),pxx(main)));
end

function xc = findCrossing(x, y, target)
    % First x where y crosses target (linear interpolation); last x if never reached.
    i = find(y >= target, 1, 'first');
    if isempty(i), xc = x(end); return; end
    if i == 1,     xc = x(1);   return; end
    xc = x(i-1) + (target - y(i-1)) * (x(i) - x(i-1)) / (y(i) - y(i-1));
end
