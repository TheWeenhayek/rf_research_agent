%% ========================================================================
%  REPLAY EXP002 - IF-chain gain compression from the raw STM32 CSV
%  ----------------------------------------------------------------------
%  No hardware. Re-runs the analysis section of
%  code/EXP002_IFChain_BGUx2_PowerSweep_Compression_v3_LongBaseline.m
%  ("POWER SUMMARY TABLE" and "GAIN COMPRESSION ESTIMATION") using the raw
%  per-sample CSV the script writes, then compares the result with the
%  previous baseline baseline/Baseline_Power_IF_Board.csv.
%  Run from anywhere; paths are resolved relative to this file.
%% ========================================================================

clear; close all; clc;

simDir = fileparts(mfilename("fullpath"));
if strlength(string(simDir)) == 0, simDir = pwd; end
baselineDir = fullfile(fileparts(simDir), "baseline");

rawFile = fullfile(baselineDir, ...
    "EXP002_IFCHAIN_BGU1_3dB_BGU2_POWER_SWEEP_COMPRESSION_20261016_174127_v3_LongBaseline_stm32-power-raw.csv");
refFile = fullfile(baselineDir, "Baseline_Power_IF_Board.csv");

% Same constants as EXP002 v3
outputMeasurementCorrection_dB = 6.0;
nSmallSignalReferencePoints    = 10;
minimumValidMeterPower_dBm     = -32.0;
minimumValidVoltage_V          = 0.15;
maximumReferenceMeterPower_dBm = -24.0;

%% Per-point statistics (the script averages the ~50 samples of each point)
R = readtable(rawFile, "VariableNamingRule", "preserve");
[g, txGain] = findgroups(R.txGain_dB);
P = table(txGain, ...
    splitapply(@(x) mean(x,"omitnan"), R.plutoOutBaseline_dBm, g), ...
    splitapply(@(x) mean(x,"omitnan"), R.power_meter_dBm, g), ...
    splitapply(@(x) mean(x,"omitnan"), R.voltage_V, g), ...
    splitapply(@numel, R.power_meter_dBm, g), ...
    'VariableNames', {'TxGain_dB','PlutoOut_dBm','MeterMean_dBm','VoltageMean_V','N'});

P.IFOut_dBm  = P.MeterMean_dBm + outputMeasurementCorrection_dB;
P.Gain_dB    = P.IFOut_dBm - P.PlutoOut_dBm;

%% Compression logic (same masks and reference window as the script)
valid = isfinite(P.Gain_dB) & P.MeterMean_dBm > minimumValidMeterPower_dBm & ...
        P.VoltageMean_V > minimumValidVoltage_V;
refMask = valid & P.MeterMean_dBm < maximumReferenceMeterPower_dBm;
if nnz(refMask) < 2, refMask = valid; end
nRef = min(nSmallSignalReferencePoints, nnz(refMask));
idx = find(refMask);
refIdx = idx(1:nRef);
G0 = mean(P.Gain_dB(refIdx));

P.Compression_dB = nan(height(P),1);
P.Compression_dB(valid) = G0 - P.Gain_dB(valid);

fprintf("Points: %d  (TxGain %.1f to %.1f dB), samples/point %d-%d\n", ...
    height(P), min(P.TxGain_dB), max(P.TxGain_dB), min(P.N), max(P.N));
fprintf("Valid (above detector floor): %d points\n", nnz(valid));
fprintf("Small-signal gain reference: %.3f dB (%d points, TxGain %.1f..%.1f dB)\n", ...
    G0, nRef, P.TxGain_dB(refIdx(1)), P.TxGain_dB(refIdx(end)));
i1 = find(P.Compression_dB >= 1.0, 1, "first");
if isempty(i1)
    fprintf("No point with >= 1 dB compression in this sweep. Max compression = %.3f dB\n", max(P.Compression_dB));
else
    fprintf("First >= 1 dB compression: TxGain %.1f dB, PlutoOut %.2f dBm, IF out %.2f dBm\n", ...
        P.TxGain_dB(i1), P.PlutoOut_dBm(i1), P.IFOut_dBm(i1));
end

%% Comparison with previous baseline (overlapping TxGain values only)
Ref = readtable(refFile);
[tf, loc] = ismember(round(P.TxGain_dB,2), round(Ref.TxGain_dB,2));
d = P.IFOut_dBm(tf) - Ref.IFChainOutputCorrected_dBm(loc(tf));
okd = isfinite(d);
fprintf("\nvs Baseline_Power_IF_Board.csv: %d overlapping points\n", nnz(tf));
fprintf("  IF output difference: mean %.3f dB, max |diff| %.3f dB (valid points only)\n", ...
    mean(d(okd)), max(abs(d(okd))));
fprintf("  Gain reference: new %.3f dB, old %.3f dB\n", G0, Ref.SmallSignalGainReference_dB(1));

%% Plots
figure; plot(P.PlutoOut_dBm, P.Gain_dB, "o-"); hold on; yline(G0,"--","G_0");
grid on; xlabel("Pluto output (dBm)"); ylabel("IF-chain gain (dB)");
title("EXP002 replay: gain vs input");
figure; plot(P.PlutoOut_dBm, P.Compression_dB, "o-"); hold on; yline(1,"--","1 dB");
grid on; xlabel("Pluto output (dBm)"); ylabel("Compression (dB)");
title("EXP002 replay: gain compression");
figure; plot(P.TxGain_dB, P.IFOut_dBm, "o-", Ref.TxGain_dB, Ref.IFChainOutputCorrected_dBm, "s--");
grid on; legend("New raw run","Baseline\_Power\_IF\_Board.csv","Location","best");
xlabel("Pluto TxGain (dB)"); ylabel("IF output corrected (dBm)");
