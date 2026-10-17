%% ========================================================================
%  EXP012 — REPRODUCIBILITY VALIDATION WITH AND WITHOUT MEMORY-DPD
%  ----------------------------------------------------------------------
%  Purpose:
%    Validate reproducibility over time for a selected DPD model at a fixed operating point.
%    The script performs repeated no-DPD and DPD captures and compares their statistics against each other and against the official no-DPD Block-A reference:
%       - EVM vs TxGain / RX power
%       - ACPR vs TxGain / RX power
%       - RX power delta
%       - STM32 detector/meter power delta and equal-STM32-power comparison
%       - PSD comparison at the trained operating point or best point
%
%  Inputs:
%    1) Coefficients CSV from EXP010:
%       *_coefficients_long.csv
%    2) Best selection CSV from EXP010:
%       *_best_selection.csv
%
%  Physical chain assumed:
%    Pluto TX -> BGU -> Upconverter -> filter -> 30 dB RF attenuation
%    -> Downconverter -> STM32 detector/meter + Pluto RX
%
%% ========================================================================

clear; close all; clc;

%% ========================================================================
% USER CONFIGURATION
%% ========================================================================

deviceName = "Pluto";
centerFrequency = 5e9;
idleGain_dB = -80;

fixedRxGain_Pluto = 8;
powerScaleFactor = 0.8;

% Fixed operating point for reproducibility validation.
% This is the 0.5 dB-compression training point selected from EXP010I.
fixedTxGain_Pluto = -22.25;
trainedTxGain_dB = fixedTxGain_Pluto;

% Repeated captures per condition.
% Total captures = nRepeatRuns no-DPD + nRepeatRuns DPD.
nRepeatRuns = 20;
interRunPause_s = 0.35;

% --- Coefficients / model selection ---
% Put these CSVs in the same folder as this script or use absolute paths.
% Leave empty strings to auto-detect the latest EXP010I files under ./data.
coefficientsCsv = "";
bestSelectionCsv = "";

% Official no-DPD reference from Block A. This is the main comparison baseline.
officialNoDPDReferenceCsv = "";

% selectionMode:
%   "best_csv" -> use whatever is in bestSelectionCsv
%   "manual"   -> force ManualModelID and ManualIteration
selectionMode = "manual";

% Best current memory model from EXP010I.
ManualModelID = "M5_K6";
ManualIteration = 3;

% Use the same DPD waveform normalization as the training script.
maxPredistortedPeakRatio = 1.10;

% Capture settings
captureTime_s = 30e-3;
maxCaptureAttempts = 4;
evmRetryThreshold_pct = 80;
minSyncMetric = 0.95;

% Robust alignment parameters copied from EXP009/EXP010.
alignDecimationFactor = 16;
fineSearchHalfWindow_samples = 4000;
phaseFitMagnitudeThreshold = 0.05;
numFramesForAlign = 1;

% Save raw captures? Useful but large.
saveRawCaptures = false;
plotMaxSymbols = 6000;

% -------------------- STM32 power meter --------------------
% This block is now enabled so DPD and no-DPD points both get an external
% detector/meter power measurement, not only Pluto RX digital power.
useSTM32PowerMeter = true;
serialPort       = "COM12";
serialBaud       = 209700;
serialTerminator = "LF";
serialTimeout_s  = 2.00;
doPingTest       = true;
nPowerSamplesPerPoint = 50;

%% ========================================================================
% OUTPUT DIRECTORIES
%% ========================================================================

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir)
    scriptDir = pwd;
end
try
    addpath(fullfile(matlabroot, 'examples', '5g', 'NRWaveformCaptureAndAnalysisWithSDRExample'));
catch
end

timeTag = string(datetime("now","Format","yyyyMMdd_HHmmss"));

projectDir = fileparts(scriptDir);
dataDir = fullfile(projectDir, "data");
if ~exist(dataDir, "dir")
    mkdir(dataDir);
end

outputRoot = fullfile(dataDir, "EXP012_Reproducibility_0p5dBComp_M5K6Iter3_vs_NoDPD_RX8_" + timeTag);
rawDir = fullfile(outputRoot, "raw");
processedDir = fullfile(outputRoot, "processed");
figuresDir = fullfile(outputRoot, "figures");
for d = [{rawDir}, {processedDir}, {figuresDir}]
    if ~exist(d{1}, "dir"); mkdir(d{1}); end
end
baseName = "EXP012_Reproducibility_0p5dBComp_M5K6Iter3_vs_NoDPD_RX8_" + timeTag;
perRunCsvFile = fullfile(processedDir, baseName + "_per_run.csv");
pairedCsvFile = fullfile(processedDir, baseName + "_paired_comparison.csv");
summaryCsvFile = fullfile(processedDir, baseName + "_summary_stats.csv");
powerRawCsvFile = fullfile(rawDir, baseName + "_stm32_power_raw.csv");
matFile = fullfile(processedDir, baseName + "_results.mat");

%% ========================================================================
% 5G NR WAVEFORM GENERATION
%% ========================================================================

cfgDLFRC = nrDLCarrierConfig;
cfgDLFRC.Label = 'DL-FRC-FR1-256QAM';
cfgDLFRC.FrequencyRange = 'FR1';
cfgDLFRC.ChannelBandwidth = 20;
cfgDLFRC.NCellID = 1;
cfgDLFRC.NumSubframes = 10;
cfgDLFRC.InitialNSubframe = 0;
cfgDLFRC.WindowingPercent = 0;
cfgDLFRC.CarrierFrequency = 0;
cfgDLFRC.SampleRate = [];

scs = nrSCSCarrierConfig;
scs.SubcarrierSpacing = 30;
scs.NSizeGrid = 51;
scs.NStartGrid = 0;
cfgDLFRC.SCSCarriers = {scs};

bwp = nrWavegenBWPConfig;
bwp.BandwidthPartID = 1;
bwp.Label = 'BWP1';
bwp.SubcarrierSpacing = 30;
bwp.CyclicPrefix = 'normal';
bwp.NSizeBWP = 51;
bwp.NStartBWP = 0;
cfgDLFRC.BandwidthParts = {bwp};

ssburst = nrWavegenSSBurstConfig;
ssburst.Enable = true;
ssburst.Power = 0;
ssburst.BlockPattern = 'Case B';
ssburst.TransmittedBlocks = [1 0 0 0];
ssburst.Period = 10;
ssburst.NCRBSSB = [];
ssburst.KSSB = 0;
ssburst.DataSource = 'MIB';
ssburst.DMRSTypeAPosition = 2;
ssburst.SubcarrierSpacingCommon = 30;
cfgDLFRC.SSBurst = ssburst;

coreset = nrCORESETConfig;
coreset.CORESETID = 1;
coreset.Label = 'CORESET1';
coreset.FrequencyResources = ones([1 8]);
coreset.Duration = 2;
coreset.CCEREGMapping = 'noninterleaved';
coreset.REGBundleSize = 2;
coreset.InterleaverSize = 2;
coreset.ShiftIndex = 0;
coreset.PrecoderGranularity = 'sameAsREG-bundle';
coreset.RBOffset = [];
cfgDLFRC.CORESET = {coreset};

searchspace = nrSearchSpaceConfig;
searchspace.SearchSpaceID = 1;
searchspace.Label = 'SearchSpace1';
searchspace.CORESETID = 1;
searchspace.SearchSpaceType = 'common';
searchspace.StartSymbolWithinSlot = 0;
searchspace.SlotPeriodAndOffset = [1 0];
searchspace.Duration = 1;
searchspace.NumCandidates = [8 8 4 2 1];
cfgDLFRC.SearchSpaces = {searchspace};

pdcch = nrWavegenPDCCHConfig;
pdcch.Enable = false;
pdcch.Label = 'PDCCH1';
pdcch.Power = 0;
pdcch.BandwidthPartID = 1;
pdcch.SearchSpaceID = 1;
pdcch.AggregationLevel = 1;
pdcch.AllocatedCandidate = 1;
pdcch.SlotAllocation = 1:19;
pdcch.Period = 20;
pdcch.Coding = false;
pdcch.DataSource = 0;
cfgDLFRC.PDCCH = {pdcch};

pdsch1 = nrWavegenPDSCHConfig;
pdsch1.Enable = true;
pdsch1.Label = 'Full-band PDSCH sequence';
pdsch1.Power = 0;
pdsch1.BandwidthPartID = 1;
pdsch1.Modulation = '256QAM';
pdsch1.NumLayers = 1;
pdsch1.MappingType = 'A';
pdsch1.ReservedCORESET = [];
pdsch1.SymbolAllocation = [2 12];
pdsch1.SlotAllocation = 1:19;
pdsch1.Period = 20;
pdsch1.PRBSet = 0:50;
pdsch1.Coding = true;
pdsch1.TargetCodeRate = 0.7783203125;
pdsch1.RVSequence = 0;
pdsch1.DataSource = 'PN9';
pdsch1.DMRSPower = 3;

pdsch1DMRS = nrPDSCHDMRSConfig;
pdsch1DMRS.DMRSConfigurationType = 1;
pdsch1DMRS.DMRSReferencePoint = 'CRB0';
pdsch1DMRS.DMRSTypeAPosition = 2;
pdsch1DMRS.DMRSAdditionalPosition = 2;
pdsch1DMRS.DMRSLength = 1;
pdsch1DMRS.NSCID = 0;
pdsch1DMRS.NumCDMGroupsWithoutData = 2;
pdsch1.DMRS = pdsch1DMRS;
cfgDLFRC.PDSCH = {pdsch1};

[waveform, info] = nrWaveformGenerator(cfgDLFRC);
sampleRate = info.ResourceGrids(1).Info.SampleRate;

txWaveform = waveform * (powerScaleFactor / max(abs(waveform)));
txWaveform = txWaveform(:);
samplesPerFrame = round(sampleRate * 10e-3);
totalSamplesNeeded = round(captureTime_s * sampleRate);
PAPR_noDPD_dB = 10*log10(max(abs(txWaveform)).^2 / mean(abs(txWaveform).^2));

%% ========================================================================
% EVM CONFIGURATION
%% ========================================================================

cfgEVM = struct();
cfgEVM.PlotEVM = false;
cfgEVM.DisplayEVM = false;
cfgEVM.SampleRate = sampleRate;
cfgEVM.IQImbalance = true;
cfgEVM.TargetRNTIs = 0;
cfgEVM.CorrectCoarseFO = true;
cfgEVM.CorrectFineFO = true;
cfgEVM.ExcludeDC = true;

%% ========================================================================
% LOAD BEST DPD COEFFICIENTS
%% ========================================================================

coeffPath = resolveOrAutoFindFile(coefficientsCsv, scriptDir, "EXP010I_HILA_0p5DBCOMP_DPDV2_OFFREF_Tx_-22p25_Rx_8p00_*_coefficients_long.csv");
bestPath = resolveOrAutoFindFile(bestSelectionCsv, scriptDir, "EXP010I_HILA_0p5DBCOMP_DPDV2_OFFREF_Tx_-22p25_Rx_8p00_*_best_selection*.csv");
officialRefPath = resolveOrAutoFindOfficialReference(officialNoDPDReferenceCsv, scriptDir, fixedRxGain_Pluto);
Tcoeff = readtable(coeffPath);
Tbest = readtable(bestPath);
TrefOfficial = readtable(officialRefPath);

%% ========================================================================
% INITIALIZE STM32 POWER METER
%% ========================================================================

stm = [];
fidPower = -1;
if useSTM32PowerMeter
    try
        fprintf("Abriendo puerto serial STM32...\n");
        stm = serialport(serialPort, serialBaud, "Timeout", serialTimeout_s);
        configureTerminator(stm, serialTerminator);
        flush(stm);
        pause(0.5);

        if doPingTest
            fprintf("Probando comunicacion STM32 con PING...\n");
            writeline(stm, "PING");
            pause(0.2);
            while stm.NumBytesAvailable > 0
                fprintf("STM32: %s\n", strtrim(readline(stm)));
            end
            flush(stm);
        end

        fidPower = fopen(powerRawCsvFile, "w");
        if fidPower < 0
            error("No se pudo crear CSV raw de potencia STM32.");
        end
        fprintf(fidPower, "pc_timestamp,pointIndex,condition,txGain_dB,rxGain_dB,stm32_time_ms,adc_raw,voltage_V,power_dB_stm32,raw_line\n");
    catch ME
        warning("No se pudo inicializar STM32. Se continua sin medicion STM32: %s", ME.message);
        useSTM32PowerMeter = false;
        stm = [];
        if fidPower > 0
            fclose(fidPower);
            fidPower = -1;
        end
    end
end

if selectionMode == "best_csv"
    bestModelID = string(Tbest.ModelID(1));
    bestIteration = Tbest.Iteration(1);
    M = Tbest.M(1);
    K = Tbest.K(1);
else
    bestModelID = string(ManualModelID);
    bestIteration = ManualIteration;
    maskTmp = strcmp(string(Tcoeff.ModelID), bestModelID) & Tcoeff.Iteration == bestIteration;
    if ~any(maskTmp)
        error('Manual model %s iteration %d not found in coefficients CSV.', bestModelID, bestIteration);
    end
    M = Tcoeff.M(find(maskTmp,1,'first'));
    K = Tcoeff.K(find(maskTmp,1,'first'));
end

maskCoeff = strcmp(string(Tcoeff.ModelID), bestModelID) & Tcoeff.Iteration == bestIteration;
Tc = sortrows(Tcoeff(maskCoeff,:), 'CoeffIndex');
coeffs = complex(Tc.CoeffReal, Tc.CoeffImag);

fprintf('\n===== EXP012 REPRODUCIBILITY SETUP =====\n');
fprintf('Best model used: %s | M=%d | K=%d | iteration=%d | coeffs=%d\n', bestModelID, M, K, bestIteration, numel(coeffs));
fprintf('Fixed TxGain: %.2f dB | RxGain: %.2f dB | runs/condition: %d\n', fixedTxGain_Pluto, fixedRxGain_Pluto, nRepeatRuns);
fprintf('Sample rate: %.3f Msps | No-DPD PAPR %.2f dB\n', sampleRate/1e6, PAPR_noDPD_dB);
fprintf('Synchronization mode: NORMAL_NO_CFO | Official reference: %s\n', officialRefPath);

% Build DPD waveform once. Same DPD baseband is used while sweeping TxGain.
txDPD = applyMemoryPolynomial(txWaveform, coeffs, M, K);
txDPD = normalizeDPDWaveform(txDPD, txWaveform, maxPredistortedPeakRatio);
PAPR_DPD_dB = 10*log10(max(abs(txDPD)).^2 / mean(abs(txDPD).^2));
fprintf('DPD PAPR: %.2f dB | peak ratio %.3f\n', PAPR_DPD_dB, max(abs(txDPD))/max(abs(txWaveform)));

%% ========================================================================
% INITIALIZE SDR
%% ========================================================================

sdrTransmitter = sdrtx(deviceName);
sdrTransmitter.BasebandSampleRate = sampleRate;
sdrTransmitter.CenterFrequency = centerFrequency;
sdrTransmitter.Gain = idleGain_dB;

sdrReceiver = sdrrx(deviceName);
sdrReceiver.BasebandSampleRate = sampleRate;
sdrReceiver.CenterFrequency = centerFrequency;
sdrReceiver.OutputDataType = "double";
sdrReceiver.GainSource = "Manual";
sdrReceiver.Gain = fixedRxGain_Pluto;

cleanupObj = onCleanup(@() cleanupAll(sdrTransmitter, sdrReceiver, idleGain_dB, fidPower)); %#ok<NASGU>

%% ========================================================================
% REPRODUCIBILITY VALIDATION: REPEATED NO-DPD AND DPD CAPTURES
%% ========================================================================

rows = cell(2*nRepeatRuns,1);
row = 0;
rxNoDPDCell = cell(nRepeatRuns,1);
rxDPDCell = cell(nRepeatRuns,1);
eqNoDPDCell = cell(nRepeatRuns,1);
refNoDPDCell = cell(nRepeatRuns,1);
eqDPDCell = cell(nRepeatRuns,1);
refDPDCell = cell(nRepeatRuns,1);

fprintf('\n===== EXP012: NO-DPD REPEATED CAPTURES =====\n');
sdrTransmitter.Gain = fixedTxGain_Pluto;
transmitRepeat(sdrTransmitter, txWaveform);
pause(0.8);

for r = 1:nRepeatRuns
    fprintf('\nNO-DPD reproducibility run %d/%d | TxGain %.2f dB\n', r, nRepeatRuns, fixedTxGain_Pluto);
    res0 = captureAndMeasureWithRetry( ...
        sdrReceiver, txWaveform, cfgDLFRC, cfgEVM, sampleRate, ...
        captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
        maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
        alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign, ...
        rawDir, saveRawCaptures, sprintf('run_%02d_noDPD_tx_%+05.2f', r, fixedTxGain_Pluto), fixedTxGain_Pluto, fixedRxGain_Pluto);

    stm0 = measureSTM32PowerIfEnabled(useSTM32PowerMeter, stm, fidPower, r, "No-DPD", fixedTxGain_Pluto, fixedRxGain_Pluto, nPowerSamplesPerPoint);

    row = row + 1;
    rows{row} = makeResultRow(r, "No-DPD", fixedTxGain_Pluto, fixedRxGain_Pluto, bestModelID, bestIteration, M, K, PAPR_noDPD_dB, res0, stm0);
    rxNoDPDCell{r} = res0.rxAligned;
    eqNoDPDCell{r} = res0.eqSymb;
    refNoDPDCell{r} = res0.refSymb;
    pause(interRunPause_s);
end

setSafeState(sdrTransmitter, idleGain_dB);
pause(0.5);

fprintf('\n===== EXP012: DPD REPEATED CAPTURES =====\n');
sdrTransmitter.Gain = fixedTxGain_Pluto;
transmitRepeat(sdrTransmitter, txDPD);
pause(0.8);

for r = 1:nRepeatRuns
    fprintf('\nDPD reproducibility run %d/%d | TxGain %.2f dB\n', r, nRepeatRuns, fixedTxGain_Pluto);
    res1 = captureAndMeasureWithRetry( ...
        sdrReceiver, txDPD, cfgDLFRC, cfgEVM, sampleRate, ...
        captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
        maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
        alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign, ...
        rawDir, saveRawCaptures, sprintf('run_%02d_DPD_tx_%+05.2f', r, fixedTxGain_Pluto), fixedTxGain_Pluto, fixedRxGain_Pluto);

    stm1 = measureSTM32PowerIfEnabled(useSTM32PowerMeter, stm, fidPower, r, "DPD", fixedTxGain_Pluto, fixedRxGain_Pluto, nPowerSamplesPerPoint);

    row = row + 1;
    rows{row} = makeResultRow(r, "DPD", fixedTxGain_Pluto, fixedRxGain_Pluto, bestModelID, bestIteration, M, K, PAPR_DPD_dB, res1, stm1);
    rxDPDCell{r} = res1.rxAligned;
    eqDPDCell{r} = res1.eqSymb;
    refDPDCell{r} = res1.refSymb;
    pause(interRunPause_s);
end

setSafeState(sdrTransmitter, idleGain_dB);

perRunTable = struct2table([rows{1:row}]);
writetable(perRunTable, perRunCsvFile);

%% ========================================================================
% BUILD PAIRED AND STATISTICAL SUMMARIES
%% ========================================================================

pairedTable = buildReproducibilityPairedSummary(perRunTable, TrefOfficial, fixedTxGain_Pluto);
writetable(pairedTable, pairedCsvFile);

summaryStatsTable = buildReproducibilityStats(perRunTable, pairedTable, TrefOfficial, fixedTxGain_Pluto, nRepeatRuns, bestModelID, bestIteration, M, K);
writetable(summaryStatsTable, summaryCsvFile);

disp(summaryStatsTable);

%% ========================================================================
% FIGURES
%% ========================================================================

try
    preMask = perRunTable.Condition == "No-DPD" & perRunTable.Usable;
    postMask = perRunTable.Condition == "DPD" & perRunTable.Usable;

    h1 = figure('Name','EXP012 repeated metrics over time','Color','w');
    tiledlayout(4,1);
    nexttile;
    plot(perRunTable.PointIndex(preMask), perRunTable.EVM_pct(preMask), 'o-', 'LineWidth', 1.2); hold on;
    plot(perRunTable.PointIndex(postMask), perRunTable.EVM_pct(postMask), 'o-', 'LineWidth', 1.2);
    grid on; xlabel('Run index'); ylabel('EVM RMS (%)'); title('Reproducibility: EVM vs run'); legend('No-DPD','DPD','Location','best');
    nexttile;
    plot(perRunTable.PointIndex(preMask), perRunTable.ACPR_dBc(preMask), 'o-', 'LineWidth', 1.2); hold on;
    plot(perRunTable.PointIndex(postMask), perRunTable.ACPR_dBc(postMask), 'o-', 'LineWidth', 1.2);
    grid on; xlabel('Run index'); ylabel('ACPR (dBc)'); title('Reproducibility: ACPR vs run'); legend('No-DPD','DPD','Location','best');
    nexttile;
    plot(perRunTable.PointIndex(preMask), perRunTable.RxPower_dBFS(preMask), 'o-', 'LineWidth', 1.2); hold on;
    plot(perRunTable.PointIndex(postMask), perRunTable.RxPower_dBFS(postMask), 'o-', 'LineWidth', 1.2);
    grid on; xlabel('Run index'); ylabel('RX power (dBFS)'); title('Reproducibility: Pluto RX power vs run'); legend('No-DPD','DPD','Location','best');
    nexttile;
    plot(perRunTable.PointIndex(preMask), perRunTable.Power_mean_dB_stm32(preMask), 'o-', 'LineWidth', 1.2); hold on;
    plot(perRunTable.PointIndex(postMask), perRunTable.Power_mean_dB_stm32(postMask), 'o-', 'LineWidth', 1.2);
    grid on; xlabel('Run index'); ylabel('STM32 power (dB)'); title('Reproducibility: STM32 detector power vs run'); legend('No-DPD','DPD','Location','best');
    saveas(h1, fullfile(figuresDir, '01_Reproducibility_PerRun_Metrics.png'));
catch ME
    warning('Could not create per-run reproducibility figure: %s', ME.message);
end

try
    h2 = figure('Name','EXP012 repeated metric distributions','Color','w');
    tiledlayout(2,2);
    nexttile; boxplotByCondition_EXP012(perRunTable, 'EVM_pct'); ylabel('EVM RMS (%)'); title('EVM distribution'); grid on;
    nexttile; boxplotByCondition_EXP012(perRunTable, 'ACPR_dBc'); ylabel('ACPR (dBc)'); title('ACPR distribution'); grid on;
    nexttile; boxplotByCondition_EXP012(perRunTable, 'RxPower_dBFS'); ylabel('RX power (dBFS)'); title('Pluto RX power distribution'); grid on;
    nexttile; boxplotByCondition_EXP012(perRunTable, 'Power_mean_dB_stm32'); ylabel('STM32 power (dB)'); title('STM32 power distribution'); grid on;
    saveas(h2, fullfile(figuresDir, '02_Reproducibility_Boxplots.png'));
catch ME
    warning('Could not create reproducibility boxplots: %s', ME.message);
end

try
    h3 = figure('Name','EXP012 paired improvements','Color','w');
    tiledlayout(4,1);
    nexttile; plot(pairedTable.RunIndex, pairedTable.EVM_Improvement_Live_pct_points, 'o-', 'LineWidth', 1.2); hold on; yline(0,'--'); grid on; xlabel('Run index'); ylabel('EVM gain (pct points)'); title('Paired EVM improvement: no-DPD minus DPD');
    nexttile; plot(pairedTable.RunIndex, pairedTable.ACPR_Improvement_Live_dB, 'o-', 'LineWidth', 1.2); hold on; yline(0,'--'); grid on; xlabel('Run index'); ylabel('ACPR gain (dB)'); title('Paired ACPR improvement');
    nexttile; plot(pairedTable.RunIndex, pairedTable.RxPower_Delta_Live_dB, 'o-', 'LineWidth', 1.2); hold on; yline(0,'--'); grid on; xlabel('Run index'); ylabel('\Delta RX power (dB)'); title('DPD minus no-DPD Pluto RX power');
    nexttile; plot(pairedTable.RunIndex, pairedTable.STM32Power_Delta_Live_dB, 'o-', 'LineWidth', 1.2); hold on; yline(0,'--'); grid on; xlabel('Run index'); ylabel('\Delta STM32 power (dB)'); title('DPD minus no-DPD STM32 detector power');
    saveas(h3, fullfile(figuresDir, '03_Reproducibility_Paired_Improvements.png'));
catch ME
    warning('Could not create paired improvement figure: %s', ME.message);
end

try
    [f_psd, pxx_no_mean, pxx_dpd_mean] = averagePSD_EXP012(rxNoDPDCell, rxDPDCell, sampleRate);
    if ~isempty(f_psd)
        h4 = figure('Name','EXP012 average PSD','Color','w');
        tiledlayout(2,1);
        p0 = 10*log10(pxx_no_mean + eps); p1 = 10*log10(pxx_dpd_mean + eps);
        p0 = p0 - max(p0); p1 = p1 - max(p1);
        nexttile; plot(f_psd/1e6, p0, 'LineWidth', 1.2); hold on; plot(f_psd/1e6, p1, 'LineWidth', 1.2); grid on; xlim([-45 45]); ylabel('PSD (dB norm.)'); title('Average PSD across repeated captures'); legend('No-DPD','DPD','Location','best');
        nexttile; plot(f_psd/1e6, p0, 'LineWidth', 1.2); hold on; plot(f_psd/1e6, p1, 'LineWidth', 1.2); grid on; xlim([-30 30]); xlabel('Relative frequency (MHz)'); ylabel('PSD (dB norm.)'); title('Average PSD zoom'); legend('No-DPD','DPD','Location','best');
        saveas(h4, fullfile(figuresDir, '04_Reproducibility_Average_PSD.png'));
    end
catch ME
    warning('Could not create average PSD figure: %s', ME.message);
end

try
    noRep = representativeRunIndex_EXP012(perRunTable, "No-DPD", mean(perRunTable.EVM_pct(perRunTable.Condition=="No-DPD" & perRunTable.Usable),'omitnan'));
    dpdRep = representativeRunIndex_EXP012(perRunTable, "DPD", mean(perRunTable.EVM_pct(perRunTable.Condition=="DPD" & perRunTable.Usable),'omitnan'));
    if ~isnan(noRep) && ~isnan(dpdRep)
        [refNo, eqNo] = getConstellationVectors_EXP012(refNoDPDCell{noRep}, eqNoDPDCell{noRep}, plotMaxSymbols);
        [refDpd, eqDpd] = getConstellationVectors_EXP012(refDPDCell{dpdRep}, eqDPDCell{dpdRep}, plotMaxSymbols);
        h5 = figure('Name','EXP012 representative constellation','Color','w');
        tiledlayout(1,2);
        nexttile; if ~isempty(refNo), plot(real(refNo), imag(refNo), 'r+', 'LineWidth', 1.2, 'MarkerSize', 6); hold on; end; if ~isempty(eqNo), plot(real(eqNo), imag(eqNo), '.', 'MarkerSize', 8); end; axis equal; grid on; xlabel('In-phase'); ylabel('Quadrature'); title(sprintf('No-DPD representative run %d', noRep)); legend('Reference','Equalized received','Location','best');
        nexttile; if ~isempty(refDpd), plot(real(refDpd), imag(refDpd), 'r+', 'LineWidth', 1.2, 'MarkerSize', 6); hold on; end; if ~isempty(eqDpd), plot(real(eqDpd), imag(eqDpd), '.', 'MarkerSize', 8); end; axis equal; grid on; xlabel('In-phase'); ylabel('Quadrature'); title(sprintf('DPD representative run %d', dpdRep)); legend('Reference','Equalized received','Location','best');
        saveas(h5, fullfile(figuresDir, '05_Reproducibility_Representative_Constellation.png'));

        if ~isempty(rxNoDPDCell{noRep}) && ~isempty(rxDPDCell{dpdRep})
            h6 = figure('Name','EXP012 representative AMAM AMPM','Color','w');
            plotAMAM_AMPM_EXP012(txWaveform, txDPD, rxNoDPDCell{noRep}, rxDPDCell{dpdRep});
            saveas(h6, fullfile(figuresDir, '06_Reproducibility_AMAM_AMPM_Representative.png'));
        end
    end
catch ME
    warning('Could not create constellation/AMAM figures: %s', ME.message);
end

save(matFile, 'perRunTable', 'pairedTable', 'summaryStatsTable', 'fixedTxGain_Pluto', 'fixedRxGain_Pluto', ...
    'nRepeatRuns', 'txWaveform', 'txDPD', 'coeffs', 'bestModelID', 'bestIteration', 'M', 'K', ...
    'sampleRate', 'PAPR_noDPD_dB', 'PAPR_DPD_dB', 'rxNoDPDCell', 'rxDPDCell', ...
    'officialNoDPDReferenceCsv', 'TrefOfficial', 'maxPredistortedPeakRatio', ...
    'useSTM32PowerMeter', 'serialPort', 'nPowerSamplesPerPoint', 'powerRawCsvFile');

fprintf('\n===== EXP012 COMPLETE =====\n');
fprintf('Output root: %s\n', outputRoot);
fprintf('Per-run CSV: %s\n', perRunCsvFile);
fprintf('Paired CSV: %s\n', pairedCsvFile);
fprintf('Summary CSV: %s\n', summaryCsvFile);
fprintf('MAT file: %s\n', matFile);
fprintf('Figures: %s\n', figuresDir);

%% ========================================================================
% LOCAL FUNCTIONS
%% ========================================================================

function filePath = resolveFilePath(fileName, scriptDir)
    filePath = string(fileName);
    candidates = strings(0,1);
    candidates(end+1) = filePath;
    candidates(end+1) = fullfile(pwd, filePath);
    candidates(end+1) = fullfile(scriptDir, filePath);
    candidates(end+1) = fullfile(fileparts(scriptDir), filePath);
    candidates(end+1) = fullfile(scriptDir, "data", filePath);
    for k = 1:numel(candidates)
        if strlength(candidates(k)) > 0 && exist(candidates(k), 'file')
            filePath = candidates(k);
            return;
        end
    end
    error('File not found: %s. Use an absolute path in the configuration.', fileName);
end

function filePath = resolveOrAutoFindFile(fileName, scriptDir, pattern)
    if strlength(string(fileName)) > 0
        filePath = resolveFilePath(fileName, scriptDir);
        return;
    end
    projectDirLocal = fileparts(scriptDir);
    searchRoots = [string(pwd); string(scriptDir); string(fullfile(scriptDir,"data")); string(fullfile(projectDirLocal,"data")); string(fullfile(projectDirLocal,"baseline"))];
    matches = [];
    for r = 1:numel(searchRoots)
        if exist(searchRoots(r), 'dir')
            m = dir(fullfile(searchRoots(r), "**", pattern));
            matches = [matches; m(:)]; %#ok<AGROW>
        end
    end
    if isempty(matches)
        error('Could not auto-find file with pattern: %s. Set the CSV path manually.', pattern);
    end
    [~, idx] = max([matches.datenum]);
    filePath = fullfile(matches(idx).folder, matches(idx).name);
end



function filePath = resolveOrAutoFindOfficialReference(fileName, scriptDir, rxGainTarget)
    if strlength(string(fileName)) > 0
        filePath = resolveFilePath(fileName, scriptDir);
        return;
    end

    projectDirLocal = fileparts(scriptDir);
    dataDirLocal = fullfile(projectDirLocal, "data");
    matches = dir(fullfile(dataDirLocal, "**", "*OFFICIAL_NODPD_REFERENCE*.csv"));
    if isempty(matches)
        error('Could not auto-find OFFICIAL_NODPD_REFERENCE under %s. Set officialNoDPDReferenceCsv manually.', dataDirLocal);
    end

    % Prefer EXP009F / NODPD_FULLSWEEP references with the requested RX gain.
    keep = true(numel(matches),1);
    for ii = 1:numel(matches)
        nameFolder = string(fullfile(matches(ii).folder, matches(ii).name));
        keep(ii) = contains(nameFolder, "EXP009F") || contains(nameFolder, "NODPD_FULLSWEEP");
    end
    if any(keep)
        matches = matches(keep);
    end

    rxKeep = false(numel(matches),1);
    for ii = 1:numel(matches)
        try
            Ttmp = readtable(fullfile(matches(ii).folder, matches(ii).name));
            if ismember('RxGain_dB', Ttmp.Properties.VariableNames)
                rxVals = Ttmp.RxGain_dB(isfinite(Ttmp.RxGain_dB));
                rxKeep(ii) = ~isempty(rxVals) && abs(median(rxVals) - rxGainTarget) < 0.25;
            elseif ismember('RxGain_Pluto_dB', Ttmp.Properties.VariableNames)
                rxVals = Ttmp.RxGain_Pluto_dB(isfinite(Ttmp.RxGain_Pluto_dB));
                rxKeep(ii) = ~isempty(rxVals) && abs(median(rxVals) - rxGainTarget) < 0.25;
            else
                % If the column is not present, do not discard; use modified time fallback.
                rxKeep(ii) = true;
            end
        catch
            rxKeep(ii) = false;
        end
    end
    if any(rxKeep)
        matches = matches(rxKeep);
    end

    [~, idx] = max([matches.datenum]);
    filePath = string(fullfile(matches(idx).folder, matches(idx).name));
end


function stm = initSTM32ResultStruct()
    stm = struct();
    stm.Power_mean_dB_stm32 = NaN;
    stm.Power_std_dB_stm32 = NaN;
    stm.Voltage_mean_V = NaN;
    stm.Voltage_std_V = NaN;
    stm.ADC_mean_raw = NaN;
    stm.N_power_valid = 0;
    stm.N_power_invalid = 0;
end

function stmRes = measureSTM32PowerIfEnabled(useSTM32PowerMeter, stm, fidPower, pointIndex, condition, txGain, rxGain, nPowerSamplesPerPoint)
    stmRes = initSTM32ResultStruct();
    if ~useSTM32PowerMeter || isempty(stm)
        return;
    end
    try
        flush(stm);
        cmd = sprintf("MEAS,%.2f,%d", txGain, nPowerSamplesPerPoint);
        fprintf("  STM32 [%s]: %s\n", condition, cmd);
        writeline(stm, cmd);
        [pVals, vVals, adcVals, nRec, nInv] = readSTM32PowerBlock_EXP012(stm, fidPower, pointIndex, condition, txGain, rxGain);
        stmRes.N_power_valid = nRec;
        stmRes.N_power_invalid = nInv;
        if ~isempty(pVals)
            stmRes.Power_mean_dB_stm32 = mean(pVals, "omitnan");
            stmRes.Power_std_dB_stm32 = std(pVals, "omitnan");
        end
        if ~isempty(vVals)
            stmRes.Voltage_mean_V = mean(vVals, "omitnan");
            stmRes.Voltage_std_V = std(vVals, "omitnan");
        end
        if ~isempty(adcVals)
            stmRes.ADC_mean_raw = mean(adcVals, "omitnan");
        end
        fprintf("  STM32 summary [%s]: P=%.3f dB | V=%.4f V | N=%d valid\n", ...
            condition, stmRes.Power_mean_dB_stm32, stmRes.Voltage_mean_V, stmRes.N_power_valid);
    catch ME
        warning("STM32 measurement failed at point %d, %s, TxGain %.2f: %s", pointIndex, condition, txGain, ME.message);
    end
end

function [powerValues_dB, voltageValues_V, adcValues_raw, nReceived, nInvalid] = readSTM32PowerBlock_EXP012(stm, fidPower, pointIndex, condition, txGain, rxGain)
    nReceived = 0;
    nInvalid = 0;
    gotEnd = false;
    powerValues_dB = [];
    voltageValues_V = [];
    adcValues_raw = [];

    while ~gotEnd
        line = strtrim(string(readline(stm)));
        if strlength(line) == 0
            continue;
        end
        if startsWith(line, "START")
            fprintf("    %s\n", line);
        elseif startsWith(line, "DATA")
            parts = split(line, ",");
            if numel(parts) >= 5
                stm32_time_ms = str2double(parts{2});
                adc_raw = str2double(parts{3});
                voltage_V = str2double(parts{4});
                power_dB = str2double(parts{5});

                if isfinite(power_dB); powerValues_dB(end+1,1) = power_dB; end %#ok<AGROW>
                if isfinite(voltage_V); voltageValues_V(end+1,1) = voltage_V; end %#ok<AGROW>
                if isfinite(adc_raw); adcValues_raw(end+1,1) = adc_raw; end %#ok<AGROW>

                if fidPower > 0
                    pc_timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));
                    fprintf(fidPower, "%s,%d,%s,%.2f,%.2f,%.0f,%.0f,%.9f,%.6f,%s\n", ...
                        pc_timestamp, pointIndex, condition, txGain, rxGain, stm32_time_ms, adc_raw, voltage_V, power_dB, sanitizeCsvField_EXP012(line));
                end
                nReceived = nReceived + 1;
            else
                nInvalid = nInvalid + 1;
            end
        elseif startsWith(line, "END")
            fprintf("    %s\n", line);
            gotEnd = true;
        elseif startsWith(line, "ERR")
            warning("STM32 respondio error: %s", line);
            gotEnd = true;
        else
            fprintf("    STM32: %s\n", line);
        end
    end
end

function safe = sanitizeCsvField_EXP012(txt)
    safe = string(txt);
    safe = replace(safe, '"', '""');
    safe = '"' + safe + '"';
end

function row = makeResultRow(pointIndex, condition, txGain, rxGain, modelID, iter, M, K, papr, res, stm)
    row = struct();
    row.PointIndex = pointIndex;
    row.Condition = string(condition);
    row.TxGain_dB = txGain;
    row.RxGain_dB = rxGain;
    row.ModelID = string(modelID);
    row.ModelIteration = iter;
    row.M = M;
    row.K = K;
    row.PAPR_dB = papr;
    row.Usable = res.usable;
    row.EVM_pct = res.evm_pct;
    row.ACPR_dBc = res.acpr_dBc;
    row.RxPower_dBFS = res.rxPower_dBFS;
    row.PeakRx_dBFS = res.peakRx_dBFS;
    row.SyncMetric = res.syncMetric;
    row.NMSE_aligned_dB = res.nmse_aligned_dB;
    row.WaveformEVM_pct = res.waveformEVM_pct;
    row.FreqOffset_Hz = res.freqOffset_Hz;
    row.CaptureAttempts = res.attemptCount;
    row.RetryFailed = res.retryFailed;
    row.Power_mean_dB_stm32 = stm.Power_mean_dB_stm32;
    row.Power_std_dB_stm32 = stm.Power_std_dB_stm32;
    row.Voltage_mean_V = stm.Voltage_mean_V;
    row.Voltage_std_V = stm.Voltage_std_V;
    row.ADC_mean_raw = stm.ADC_mean_raw;
    row.N_power_valid = stm.N_power_valid;
    row.N_power_invalid = stm.N_power_invalid;
end

function summaryTable = buildPointByPointComparisonSummary(T, Tref)
    % Builds a point-by-point comparison table.
    % 1) Live no-DPD vs DPD at the same TxGain from this run.
    % 2) Official Block-A no-DPD reference vs DPD at same TxGain.
    % 3) Official Block-A no-DPD reference vs DPD at same RX digital power.
    % 4) Official Block-A no-DPD reference vs DPD at same STM32 detector power.

    T0 = T(T.Condition=="No-DPD" & T.Usable,:);
    T1 = T(T.Condition=="DPD" & T.Usable,:);
    common = intersect(T0.PointIndex, T1.PointIndex);

    n = numel(common);
    PointIndex = common(:);
    TxGain_dB = nan(n,1);

    EVM_NoDPD_Live_pct = nan(n,1);
    EVM_DPD_pct = nan(n,1);
    EVM_Improvement_LiveSameTxGain_pct_points = nan(n,1);
    ACPR_NoDPD_Live_dBc = nan(n,1);
    ACPR_DPD_dBc = nan(n,1);
    ACPR_Improvement_LiveSameTxGain_dB = nan(n,1);
    RxPower_NoDPD_Live_dBFS = nan(n,1);
    RxPower_DPD_dBFS = nan(n,1);
    RxPower_Delta_Live_dB = nan(n,1);
    STM32Power_NoDPD_Live_dB = nan(n,1);
    STM32Power_DPD_dB = nan(n,1);
    STM32Power_Delta_Live_dB = nan(n,1);
    Voltage_NoDPD_Live_V = nan(n,1);
    Voltage_DPD_V = nan(n,1);

    RefNoDPD_EVM_SameTxGain_pct = nan(n,1);
    RefNoDPD_ACPR_SameTxGain_dBc = nan(n,1);
    RefNoDPD_RxPower_SameTxGain_dBFS = nan(n,1);
    RefNoDPD_STM32Power_SameTxGain_dB = nan(n,1);
    EVM_Improvement_vsOfficialSameTxGain_pct_points = nan(n,1);
    ACPR_Improvement_vsOfficialSameTxGain_dB = nan(n,1);
    RxPower_Delta_vsOfficialSameTxGain_dB = nan(n,1);
    STM32Power_Delta_vsOfficialSameTxGain_dB = nan(n,1);

    RefNoDPD_EVM_SameRxPower_pct = nan(n,1);
    RefNoDPD_ACPR_SameRxPower_dBc = nan(n,1);
    RefNoDPD_TxGain_SameRxPower_dB = nan(n,1);
    EVM_Improvement_vsOfficialSameRxPower_pct_points = nan(n,1);
    ACPR_Improvement_vsOfficialSameRxPower_dB = nan(n,1);

    RefNoDPD_EVM_SameSTM32Power_pct = nan(n,1);
    RefNoDPD_ACPR_SameSTM32Power_dBc = nan(n,1);
    RefNoDPD_TxGain_SameSTM32Power_dB = nan(n,1);
    RefNoDPD_RxPower_SameSTM32Power_dBFS = nan(n,1);
    EVM_Improvement_vsOfficialSameSTM32Power_pct_points = nan(n,1);
    ACPR_Improvement_vsOfficialSameSTM32Power_dB = nan(n,1);

    DPD_Better_EVM_SameTxGain = false(n,1);
    DPD_Better_ACPR_SameTxGain = false(n,1);
    DPD_Better_Both_SameTxGain = false(n,1);
    DPD_Better_EVM_SameRxPower = false(n,1);
    DPD_Better_ACPR_SameRxPower = false(n,1);
    DPD_Better_Both_SameRxPower = false(n,1);
    DPD_Better_EVM_SameSTM32Power = false(n,1);
    DPD_Better_ACPR_SameSTM32Power = false(n,1);
    DPD_Better_Both_SameSTM32Power = false(n,1);

    for i=1:n
        a = T0(T0.PointIndex==common(i),:); a = a(1,:);
        b = T1(T1.PointIndex==common(i),:); b = b(1,:);
        TxGain_dB(i) = a.TxGain_dB;

        EVM_NoDPD_Live_pct(i) = a.EVM_pct;
        EVM_DPD_pct(i) = b.EVM_pct;
        EVM_Improvement_LiveSameTxGain_pct_points(i) = a.EVM_pct - b.EVM_pct;
        ACPR_NoDPD_Live_dBc(i) = a.ACPR_dBc;
        ACPR_DPD_dBc(i) = b.ACPR_dBc;
        ACPR_Improvement_LiveSameTxGain_dB(i) = a.ACPR_dBc - b.ACPR_dBc;
        RxPower_NoDPD_Live_dBFS(i) = a.RxPower_dBFS;
        RxPower_DPD_dBFS(i) = b.RxPower_dBFS;
        RxPower_Delta_Live_dB(i) = b.RxPower_dBFS - a.RxPower_dBFS;
        STM32Power_NoDPD_Live_dB(i) = a.Power_mean_dB_stm32;
        STM32Power_DPD_dB(i) = b.Power_mean_dB_stm32;
        STM32Power_Delta_Live_dB(i) = b.Power_mean_dB_stm32 - a.Power_mean_dB_stm32;
        Voltage_NoDPD_Live_V(i) = a.Voltage_mean_V;
        Voltage_DPD_V(i) = b.Voltage_mean_V;

        [refEvmTx, refAcprTx, refRxPowTx, refStmPowTx] = interpOfficialSameTxGain(Tref, TxGain_dB(i));
        RefNoDPD_EVM_SameTxGain_pct(i) = refEvmTx;
        RefNoDPD_ACPR_SameTxGain_dBc(i) = refAcprTx;
        RefNoDPD_RxPower_SameTxGain_dBFS(i) = refRxPowTx;
        RefNoDPD_STM32Power_SameTxGain_dB(i) = refStmPowTx;
        EVM_Improvement_vsOfficialSameTxGain_pct_points(i) = refEvmTx - b.EVM_pct;
        ACPR_Improvement_vsOfficialSameTxGain_dB(i) = refAcprTx - b.ACPR_dBc;
        RxPower_Delta_vsOfficialSameTxGain_dB(i) = b.RxPower_dBFS - refRxPowTx;
        STM32Power_Delta_vsOfficialSameTxGain_dB(i) = b.Power_mean_dB_stm32 - refStmPowTx;

        [refEvmRx, refAcprRx, refTxRx] = interpOfficialSameRxPower(Tref, b.RxPower_dBFS);
        RefNoDPD_EVM_SameRxPower_pct(i) = refEvmRx;
        RefNoDPD_ACPR_SameRxPower_dBc(i) = refAcprRx;
        RefNoDPD_TxGain_SameRxPower_dB(i) = refTxRx;
        EVM_Improvement_vsOfficialSameRxPower_pct_points(i) = refEvmRx - b.EVM_pct;
        ACPR_Improvement_vsOfficialSameRxPower_dB(i) = refAcprRx - b.ACPR_dBc;

        [refEvmStm, refAcprStm, refTxStm, refRxStm] = interpOfficialSameSTM32Power(Tref, b.Power_mean_dB_stm32);
        RefNoDPD_EVM_SameSTM32Power_pct(i) = refEvmStm;
        RefNoDPD_ACPR_SameSTM32Power_dBc(i) = refAcprStm;
        RefNoDPD_TxGain_SameSTM32Power_dB(i) = refTxStm;
        RefNoDPD_RxPower_SameSTM32Power_dBFS(i) = refRxStm;
        EVM_Improvement_vsOfficialSameSTM32Power_pct_points(i) = refEvmStm - b.EVM_pct;
        ACPR_Improvement_vsOfficialSameSTM32Power_dB(i) = refAcprStm - b.ACPR_dBc;

        DPD_Better_EVM_SameTxGain(i) = EVM_Improvement_vsOfficialSameTxGain_pct_points(i) > 0;
        DPD_Better_ACPR_SameTxGain(i) = ACPR_Improvement_vsOfficialSameTxGain_dB(i) > 0;
        DPD_Better_Both_SameTxGain(i) = DPD_Better_EVM_SameTxGain(i) && DPD_Better_ACPR_SameTxGain(i);
        DPD_Better_EVM_SameRxPower(i) = EVM_Improvement_vsOfficialSameRxPower_pct_points(i) > 0;
        DPD_Better_ACPR_SameRxPower(i) = ACPR_Improvement_vsOfficialSameRxPower_dB(i) > 0;
        DPD_Better_Both_SameRxPower(i) = DPD_Better_EVM_SameRxPower(i) && DPD_Better_ACPR_SameRxPower(i);
        DPD_Better_EVM_SameSTM32Power(i) = EVM_Improvement_vsOfficialSameSTM32Power_pct_points(i) > 0;
        DPD_Better_ACPR_SameSTM32Power(i) = ACPR_Improvement_vsOfficialSameSTM32Power_dB(i) > 0;
        DPD_Better_Both_SameSTM32Power(i) = DPD_Better_EVM_SameSTM32Power(i) && DPD_Better_ACPR_SameSTM32Power(i);
    end

    summaryTable = table(PointIndex, TxGain_dB, ...
        EVM_NoDPD_Live_pct, EVM_DPD_pct, EVM_Improvement_LiveSameTxGain_pct_points, ...
        ACPR_NoDPD_Live_dBc, ACPR_DPD_dBc, ACPR_Improvement_LiveSameTxGain_dB, ...
        RxPower_NoDPD_Live_dBFS, RxPower_DPD_dBFS, RxPower_Delta_Live_dB, ...
        STM32Power_NoDPD_Live_dB, STM32Power_DPD_dB, STM32Power_Delta_Live_dB, Voltage_NoDPD_Live_V, Voltage_DPD_V, ...
        RefNoDPD_EVM_SameTxGain_pct, RefNoDPD_ACPR_SameTxGain_dBc, RefNoDPD_RxPower_SameTxGain_dBFS, RefNoDPD_STM32Power_SameTxGain_dB, ...
        EVM_Improvement_vsOfficialSameTxGain_pct_points, ACPR_Improvement_vsOfficialSameTxGain_dB, RxPower_Delta_vsOfficialSameTxGain_dB, STM32Power_Delta_vsOfficialSameTxGain_dB, ...
        RefNoDPD_EVM_SameRxPower_pct, RefNoDPD_ACPR_SameRxPower_dBc, RefNoDPD_TxGain_SameRxPower_dB, ...
        EVM_Improvement_vsOfficialSameRxPower_pct_points, ACPR_Improvement_vsOfficialSameRxPower_dB, ...
        RefNoDPD_EVM_SameSTM32Power_pct, RefNoDPD_ACPR_SameSTM32Power_dBc, RefNoDPD_TxGain_SameSTM32Power_dB, RefNoDPD_RxPower_SameSTM32Power_dBFS, ...
        EVM_Improvement_vsOfficialSameSTM32Power_pct_points, ACPR_Improvement_vsOfficialSameSTM32Power_dB, ...
        DPD_Better_EVM_SameTxGain, DPD_Better_ACPR_SameTxGain, DPD_Better_Both_SameTxGain, ...
        DPD_Better_EVM_SameRxPower, DPD_Better_ACPR_SameRxPower, DPD_Better_Both_SameRxPower, ...
        DPD_Better_EVM_SameSTM32Power, DPD_Better_ACPR_SameSTM32Power, DPD_Better_Both_SameSTM32Power);
end

function [evm, acpr, rxPow, stmPow] = interpOfficialSameTxGain(Tref, txGain)
    evm = interpCol(Tref, 'TxGain_dB', 'EVM_NR_Aligned_pct', txGain);
    acpr = interpCol(Tref, 'TxGain_dB', 'ACPR_dBc', txGain);
    rxPow = interpCol(Tref, 'TxGain_dB', 'RxPower_dBFS', txGain);
    stmPow = interpCol(Tref, 'TxGain_dB', 'Power_mean_dB_stm32', txGain);
end

function [evm, acpr, txGain] = interpOfficialSameRxPower(Tref, rxPower)
    evm = interpCol(Tref, 'RxPower_dBFS', 'EVM_NR_Aligned_pct', rxPower);
    acpr = interpCol(Tref, 'RxPower_dBFS', 'ACPR_dBc', rxPower);
    txGain = interpCol(Tref, 'RxPower_dBFS', 'TxGain_dB', rxPower);
end

function [evm, acpr, txGain, rxPow] = interpOfficialSameSTM32Power(Tref, stm32Power)
    evm = interpCol(Tref, 'Power_mean_dB_stm32', 'EVM_NR_Aligned_pct', stm32Power);
    acpr = interpCol(Tref, 'Power_mean_dB_stm32', 'ACPR_dBc', stm32Power);
    txGain = interpCol(Tref, 'Power_mean_dB_stm32', 'TxGain_dB', stm32Power);
    rxPow = interpCol(Tref, 'Power_mean_dB_stm32', 'RxPower_dBFS', stm32Power);
end

function yq = interpCol(T, xCol, yCol, xq)
    yq = NaN;
    if ~ismember(xCol, T.Properties.VariableNames) || ~ismember(yCol, T.Properties.VariableNames)
        return;
    end
    x = T.(xCol); y = T.(yCol);
    if ismember('Accepted', T.Properties.VariableNames)
        okAccepted = logical(T.Accepted);
    else
        okAccepted = true(size(x));
    end
    ok = okAccepted & isfinite(x) & isfinite(y);
    x = x(ok); y = y(ok);
    if numel(x) < 3 || ~isfinite(xq)
        return;
    end
    [xSort, idx] = sort(x);
    ySort = y(idx);
    [xUnique, ia] = unique(xSort, 'stable');
    yUnique = ySort(ia);
    if xq < min(xUnique) || xq > max(xUnique)
        return;
    end
    if numel(xUnique) >= 4
        yq = interp1(xUnique, yUnique, xq, 'pchip');
    else
        yq = interp1(xUnique, yUnique, xq, 'linear');
    end
end

function plotCondition(T, xName, yName, yLabelText)
    hold on;
    conds = ["No-DPD", "DPD"];
    for c = conds
        mask = T.Condition == c & T.Usable & isfinite(T.(xName)) & isfinite(T.(yName));
        plot(T.(xName)(mask), T.(yName)(mask), 'o-', 'LineWidth', 1.2, 'DisplayName', c);
    end
    grid on; xlabel(strrep(xName,'_',' ')); ylabel(yLabelText); legend('Location','best');
end

function result = captureAndMeasureWithRetry( ...
    rxObj, txReference, cfgDL, cfgEVM, sampleRate, ...
    captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
    maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
    alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign, ...
    rawDir, saveRawCaptures, label, txGain, rxGain)

    result = initResultStruct();
    best = result;
    best.evm_pct = Inf;
    best.syncMetric = -Inf;

    for attempt = 1:maxCaptureAttempts
        fprintf('  Capture attempt %d/%d [%s]\n', attempt, maxCaptureAttempts, label);
        pause(0.10);
        rxCapture = capture(rxObj, captureTime_s, "Seconds");
        if length(rxCapture) < totalSamplesNeeded
            warning('Insufficient capture in attempt %d.', attempt);
            continue;
        end
        rxCapture = rxCapture(1:totalSamplesNeeded);

        if saveRawCaptures
            rawFile = fullfile(rawDir, sprintf('%s_tx_%+05.2fdB_rx_%+05.2fdB_attempt_%d.mat', label, txGain, rxGain, attempt));
            save(rawFile, 'rxCapture', 'txGain', 'rxGain', 'attempt');
        end

        try
            [alignInfo, alignedData] = robustAlignTxRxForDPD(txReference, rxCapture, sampleRate, ...
                alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign);
        catch ME
            fprintf('    Robust alignment failed: %s\n', ME.message);
            continue;
        end

        rxAligned = alignedData.y_cfo_corrected(:);
        syncMetric = alignInfo.syncMetric;
        if isempty(rxAligned) || syncMetric < minSyncMetric
            fprintf('    Sync failed/weak. Metric = %.4f | Required %.4f\n', syncMetric, minSyncMetric);
            continue;
        end

        evm_pct = NaN;
        eqSymb = [];
        refSymb = [];
        try
            Lframe = min(samplesPerFrame, numel(rxAligned));
            [evmInfo, eqSymb, refSymb] = hNRDownlinkEVM(cfgDL, rxAligned(1:Lframe), cfgEVM);
            evm_pct = evmInfo.PDSCH.OverallEVM.RMS * 100;
        catch ME
            fprintf('    EVM failed: %s\n', ME.message);
        end

        acpr_dBc = computeACPRCentered(rxAligned, sampleRate, 20e6);
        fprintf('    EVM %.2f %% | ACPR %.2f dBc | RX %.2f dBFS | peak %.2f dBFS | Sync %.4f | NMSE %.2f dB\n', ...
            evm_pct, acpr_dBc, alignInfo.rxPower_dBFS, alignInfo.peakRx_dBFS, syncMetric, alignInfo.nmse_dB);

        candidate = initResultStruct();
        candidate.usable = true;
        candidate.retryFailed = false;
        candidate.attemptCount = attempt;
        candidate.evm_pct = evm_pct;
        candidate.acpr_dBc = acpr_dBc;
        candidate.rxPower_dBFS = alignInfo.rxPower_dBFS;
        candidate.peakRx_dBFS = alignInfo.peakRx_dBFS;
        candidate.nmse_aligned_dB = alignInfo.nmse_dB;
        candidate.waveformEVM_pct = alignInfo.waveformEVM_pct;
        candidate.syncMetric = syncMetric;
        candidate.freqOffset_Hz = alignInfo.freqOffset_Hz;
        candidate.rxAligned = rxAligned;
        candidate.rawCapture = rxCapture;
        candidate.eqSymb = eqSymb;
        candidate.refSymb = refSymb;

        if isfinite(evm_pct) && evm_pct < best.evm_pct
            best = candidate;
        elseif ~isfinite(best.evm_pct) && syncMetric > best.syncMetric
            best = candidate;
        elseif isinf(best.evm_pct)
            best = candidate;
        end

        if isfinite(evm_pct) && evm_pct < evmRetryThreshold_pct
            result = candidate;
            return;
        end
    end

    if ~best.usable || ~isfinite(best.evm_pct) || best.evm_pct >= evmRetryThreshold_pct || ...
            ~isfinite(best.syncMetric) || best.syncMetric < minSyncMetric
        result = initResultStruct();
        result.usable = false;
        result.retryFailed = true;
        result.attemptCount = maxCaptureAttempts;
        result.syncMetric = best.syncMetric;
        fprintf('    Datum killed after %d attempts.\n', maxCaptureAttempts);
        return;
    end

    result = best;
    result.attemptCount = maxCaptureAttempts;
end

function s = initResultStruct()
    s = struct();
    s.usable = false;
    s.retryFailed = false;
    s.attemptCount = 0;
    s.evm_pct = NaN;
    s.acpr_dBc = NaN;
    s.rxPower_dBFS = NaN;
    s.peakRx_dBFS = NaN;
    s.nmse_aligned_dB = NaN;
    s.waveformEVM_pct = NaN;
    s.syncMetric = NaN;
    s.freqOffset_Hz = NaN;
    s.rxAligned = [];
    s.rawCapture = [];
    s.eqSymb = [];
    s.refSymb = [];
end

function [alignInfo, alignedData] = robustAlignTxRxForDPD(xTx, yRx, Fs, D, fineHalfWin, magThrRel, numFramesForAlign)
    %#ok<INUSD>
    % EXP008/EXP010I result: best synchronization mode is NORMAL_NO_CFO.
    % This local sweep therefore uses the same mode as the DPD training:
    % coarse decimated correlation + fine integer-delay search + scalar
    % complex-gain normalization, intentionally without external CFO correction.

    xTx = xTx(:);
    yRx = yRx(:);

    Ntx = numel(xTx);
    Nuse = min(Ntx*numFramesForAlign, Ntx);
    x = xTx(1:Nuse);

    if numel(yRx) < Nuse + 10
        error('RX capture too short for NORMAL_NO_CFO alignment.');
    end

    x0 = x - mean(x, 'omitnan');
    y0 = yRx - mean(yRx, 'omitnan');
    x0 = x0 ./ (rms(abs(x0)) + eps);
    y0 = y0 ./ (rms(abs(y0)) + eps);

    xD = x0(1:D:end);
    yD = y0(1:D:end);
    if numel(yD) < numel(xD)
        error('Decimated RX capture shorter than decimated reference.');
    end

    cCoarse = conv(yD, flipud(conj(xD)), 'valid');
    [~, idxCoarse] = max(abs(cCoarse));
    startCoarse = (idxCoarse - 1) * D + 1;

    startMin = max(1, startCoarse - fineHalfWin);
    startMax = min(numel(yRx) - Nuse + 1, startCoarse + fineHalfWin);
    if startMax < startMin
        error('Invalid fine-search window.');
    end

    starts = startMin:startMax;
    corrVals = nan(numel(starts),1);
    for kk = 1:numel(starts)
        ys = y0(starts(kk):starts(kk)+Nuse-1);
        corrVals(kk) = abs(x0' * ys) / ((norm(x0)+eps)*(norm(ys)+eps));
    end

    [syncMetricCoarseFine, iBest] = max(corrVals);
    startSample = starts(iBest);
    delaySamples = startSample - 1;

    yAlignedRaw = yRx(startSample:startSample+Nuse-1);
    xAligned = x;

    complexGain = (xAligned' * yAlignedRaw) / (xAligned' * xAligned + eps);
    yNorm = yAlignedRaw ./ (complexGain + eps);

    err = yNorm - xAligned;
    nmseLin = sum(abs(err).^2) / (sum(abs(xAligned).^2) + eps);
    nmse_dB = 10*log10(nmseLin + eps);
    waveformEVM_pct = 100*sqrt(nmseLin);

    rxPower_dBFS = 20*log10(rms(abs(yAlignedRaw)) + eps);
    peakRx_dBFS = 20*log10(max(abs(yAlignedRaw)) + eps);
    syncMetricFinal = abs(xAligned' * yNorm) / ((norm(xAligned)+eps)*(norm(yNorm)+eps));

    alignInfo = struct();
    alignInfo.delaySamples = delaySamples;
    alignInfo.startSample = startSample;
    alignInfo.syncMetric = syncMetricFinal;
    alignInfo.syncMetricCoarseFine = syncMetricCoarseFine;
    alignInfo.freqOffset_Hz = 0;
    alignInfo.phaseSlope_radPerSample = 0;
    alignInfo.complexGain = complexGain;
    alignInfo.nmse_dB = nmse_dB;
    alignInfo.waveformEVM_pct = waveformEVM_pct;
    alignInfo.rxPower_dBFS = rxPower_dBFS;
    alignInfo.peakRx_dBFS = peakRx_dBFS;
    alignInfo.corrDelayAxis_samples = starts(:) - 1;
    alignInfo.corrMagNormalized = corrVals(:);
    alignInfo.syncMode = "NORMAL_NO_CFO";

    alignedData = struct();
    alignedData.x_aligned = xAligned;
    alignedData.y_aligned_raw = yAlignedRaw;
    alignedData.y_cfo_corrected = yAlignedRaw;   % compatibility alias: no CFO is applied
    alignedData.y_normalized = yNorm;
end


function X = buildMPMatrix(signal, M, K)
    signal = signal(:);
    L = length(signal);
    if L <= M; error('Signal length must be larger than M.'); end
    X = zeros(L-M, (M+1)*K);
    col = 1;
    for m=0:M
        s = signal(M+1-m:end-m);
        for k=0:K-1
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
    if M > 0; y(1:M) = x(1:M); end
end

function y = normalizeDPDWaveform(y, xRef, maxPeakRatio)
    y = y(:); xRef = xRef(:);
    pRef = mean(abs(xRef).^2);
    pY = mean(abs(y).^2);
    if isfinite(pRef) && isfinite(pY) && pRef > 0 && pY > 0
        y = y * sqrt(pRef/pY);
    end
    maxAllowedPeak = maxPeakRatio * max(abs(xRef));
    currentPeak = max(abs(y));
    if isfinite(currentPeak) && currentPeak > maxAllowedPeak && currentPeak > 0
        y = y / currentPeak * maxAllowedPeak;
    end
end

function acpr_dBc = computeACPRCentered(x, fs, bw)
    acpr_dBc = NaN;
    try
        x = x(:);
        if isempty(x) || length(x)<1024; return; end
        N = min(614400, length(x));
        x = x(1:N) - mean(x(1:N));
        winLen = min(4096,N);
        nfft = max(4096, 2^nextpow2(min(N,262144)));
        [pxx,f] = pwelch(x, hamming(winLen), [], nfft, fs, 'centered');
        mainIdx = abs(f)<=bw/2;
        adjLowIdx = (f>=-1.5*bw) & (f<-0.5*bw);
        adjHighIdx = (f>0.5*bw) & (f<=1.5*bw);
        pMain = trapz(f(mainIdx), pxx(mainIdx));
        pAdj = 0;
        if any(adjLowIdx); pAdj = pAdj + trapz(f(adjLowIdx), pxx(adjLowIdx)); end
        if any(adjHighIdx); pAdj = pAdj + trapz(f(adjHighIdx), pxx(adjHighIdx)); end
        if pMain>0 && pAdj>0; acpr_dBc = 10*log10(pAdj/pMain); end
    catch ME
        warning('ACPR failed: %s', ME.message);
    end
end

function plotPSDComparison(rx0, rx1, fs, acpr0, acpr1, txGain)
    rx0 = rx0(:); rx1 = rx1(:);
    N = min([numel(rx0), numel(rx1), 262144]);
    rx0 = rx0(1:N); rx1 = rx1(1:N);
    nfft = 8192; win = hamming(4096);
    [P0,f] = pwelch(rx0, win, [], nfft, fs, 'centered');
    [P1,~] = pwelch(rx1, win, [], nfft, fs, 'centered');
    P0dB = 10*log10(P0+eps); P1dB = 10*log10(P1+eps);
    P0dB = P0dB - max(P0dB); P1dB = P1dB - max(P1dB);
    plot(f/1e6, P0dB, 'LineWidth', 1.3); hold on;
    plot(f/1e6, P1dB, 'LineWidth', 1.3);
    xline(-10,'--k'); xline(10,'--k'); xline(-30,':k'); xline(30,':k');
    grid on; xlabel('Frequency (MHz)'); ylabel('PSD (dB normalized)');
    title(sprintf('PSD comparison at TxGain %.2f dB | ACPR no-DPD %.2f dBc | DPD %.2f dBc', txGain, acpr0, acpr1));
    legend('No-DPD','DPD','Location','best');
end


function pairedTable = buildReproducibilityPairedSummary(T, Tref, fixedTxGain)
    T0 = T(T.Condition=="No-DPD" & T.Usable,:);
    T1 = T(T.Condition=="DPD" & T.Usable,:);
    common = intersect(T0.PointIndex, T1.PointIndex);
    n = numel(common);
    RunIndex = common(:);
    TxGain_dB = fixedTxGain*ones(n,1);
    EVM_NoDPD_pct = nan(n,1); EVM_DPD_pct = nan(n,1); EVM_Improvement_Live_pct_points = nan(n,1);
    ACPR_NoDPD_dBc = nan(n,1); ACPR_DPD_dBc = nan(n,1); ACPR_Improvement_Live_dB = nan(n,1);
    RxPower_NoDPD_dBFS = nan(n,1); RxPower_DPD_dBFS = nan(n,1); RxPower_Delta_Live_dB = nan(n,1);
    STM32Power_NoDPD_dB = nan(n,1); STM32Power_DPD_dB = nan(n,1); STM32Power_Delta_Live_dB = nan(n,1);
    RefNoDPD_EVM_SameTxGain_pct = nan(n,1); RefNoDPD_ACPR_SameTxGain_dBc = nan(n,1);
    RefNoDPD_EVM_SameRxPower_pct = nan(n,1); RefNoDPD_ACPR_SameRxPower_dBc = nan(n,1); RefNoDPD_TxGain_SameRxPower_dB = nan(n,1);
    RefNoDPD_EVM_SameSTM32Power_pct = nan(n,1); RefNoDPD_ACPR_SameSTM32Power_dBc = nan(n,1); RefNoDPD_TxGain_SameSTM32Power_dB = nan(n,1);
    EVM_Improvement_vsOfficialSameRxPower_pct_points = nan(n,1);
    ACPR_Improvement_vsOfficialSameRxPower_dB = nan(n,1);
    EVM_Improvement_vsOfficialSameSTM32Power_pct_points = nan(n,1);
    ACPR_Improvement_vsOfficialSameSTM32Power_dB = nan(n,1);

    for ii = 1:n
        r = common(ii);
        a = T0(T0.PointIndex==r,:); b = T1(T1.PointIndex==r,:);
        a = a(1,:); b = b(1,:);
        EVM_NoDPD_pct(ii) = a.EVM_pct; EVM_DPD_pct(ii) = b.EVM_pct;
        EVM_Improvement_Live_pct_points(ii) = a.EVM_pct - b.EVM_pct;
        ACPR_NoDPD_dBc(ii) = a.ACPR_dBc; ACPR_DPD_dBc(ii) = b.ACPR_dBc;
        ACPR_Improvement_Live_dB(ii) = a.ACPR_dBc - b.ACPR_dBc;
        RxPower_NoDPD_dBFS(ii) = a.RxPower_dBFS; RxPower_DPD_dBFS(ii) = b.RxPower_dBFS;
        RxPower_Delta_Live_dB(ii) = b.RxPower_dBFS - a.RxPower_dBFS;
        STM32Power_NoDPD_dB(ii) = a.Power_mean_dB_stm32; STM32Power_DPD_dB(ii) = b.Power_mean_dB_stm32;
        STM32Power_Delta_Live_dB(ii) = b.Power_mean_dB_stm32 - a.Power_mean_dB_stm32;
        [eTx,aTx,~,~] = interpOfficialSameTxGain(Tref, fixedTxGain);
        RefNoDPD_EVM_SameTxGain_pct(ii) = eTx; RefNoDPD_ACPR_SameTxGain_dBc(ii) = aTx;
        [eRx,aRx,tRx] = interpOfficialSameRxPower(Tref, b.RxPower_dBFS);
        RefNoDPD_EVM_SameRxPower_pct(ii) = eRx; RefNoDPD_ACPR_SameRxPower_dBc(ii) = aRx; RefNoDPD_TxGain_SameRxPower_dB(ii) = tRx;
        [eStm,aStm,tStm,~] = interpOfficialSameSTM32Power(Tref, b.Power_mean_dB_stm32);
        RefNoDPD_EVM_SameSTM32Power_pct(ii) = eStm; RefNoDPD_ACPR_SameSTM32Power_dBc(ii) = aStm; RefNoDPD_TxGain_SameSTM32Power_dB(ii) = tStm;
        EVM_Improvement_vsOfficialSameRxPower_pct_points(ii) = eRx - b.EVM_pct;
        ACPR_Improvement_vsOfficialSameRxPower_dB(ii) = aRx - b.ACPR_dBc;
        EVM_Improvement_vsOfficialSameSTM32Power_pct_points(ii) = eStm - b.EVM_pct;
        ACPR_Improvement_vsOfficialSameSTM32Power_dB(ii) = aStm - b.ACPR_dBc;
    end
    pairedTable = table(RunIndex, TxGain_dB, EVM_NoDPD_pct, EVM_DPD_pct, EVM_Improvement_Live_pct_points, ...
        ACPR_NoDPD_dBc, ACPR_DPD_dBc, ACPR_Improvement_Live_dB, ...
        RxPower_NoDPD_dBFS, RxPower_DPD_dBFS, RxPower_Delta_Live_dB, ...
        STM32Power_NoDPD_dB, STM32Power_DPD_dB, STM32Power_Delta_Live_dB, ...
        RefNoDPD_EVM_SameTxGain_pct, RefNoDPD_ACPR_SameTxGain_dBc, ...
        RefNoDPD_EVM_SameRxPower_pct, RefNoDPD_ACPR_SameRxPower_dBc, RefNoDPD_TxGain_SameRxPower_dB, ...
        RefNoDPD_EVM_SameSTM32Power_pct, RefNoDPD_ACPR_SameSTM32Power_dBc, RefNoDPD_TxGain_SameSTM32Power_dB, ...
        EVM_Improvement_vsOfficialSameRxPower_pct_points, ACPR_Improvement_vsOfficialSameRxPower_dB, ...
        EVM_Improvement_vsOfficialSameSTM32Power_pct_points, ACPR_Improvement_vsOfficialSameSTM32Power_dB);
end

function summaryStatsTable = buildReproducibilityStats(T, P, Tref, fixedTxGain, nRepeatRuns, modelID, iteration, M, K)
    m0 = T.Condition=="No-DPD" & T.Usable;
    m1 = T.Condition=="DPD" & T.Usable;
    [refEvmTx, refAcprTx, refRxTx, refStmTx] = interpOfficialSameTxGain(Tref, fixedTxGain);
    summaryStatsTable = table();
    summaryStatsTable.ModelID = string(modelID);
    summaryStatsTable.ModelIteration = iteration;
    summaryStatsTable.M = M;
    summaryStatsTable.K = K;
    summaryStatsTable.TxGain_dB = fixedTxGain;
    summaryStatsTable.N_TargetRuns = nRepeatRuns;
    summaryStatsTable.N_Usable_NoDPD = nnz(m0);
    summaryStatsTable.N_Usable_DPD = nnz(m1);
    summaryStatsTable.EVM_NoDPD_mean_pct = mean(T.EVM_pct(m0),'omitnan');
    summaryStatsTable.EVM_NoDPD_std_pct = std(T.EVM_pct(m0),'omitnan');
    summaryStatsTable.EVM_DPD_mean_pct = mean(T.EVM_pct(m1),'omitnan');
    summaryStatsTable.EVM_DPD_std_pct = std(T.EVM_pct(m1),'omitnan');
    summaryStatsTable.EVM_Improvement_Live_mean_pct_points = mean(P.EVM_Improvement_Live_pct_points,'omitnan');
    summaryStatsTable.EVM_Improvement_Live_std_pct_points = std(P.EVM_Improvement_Live_pct_points,'omitnan');
    summaryStatsTable.ACPR_NoDPD_mean_dBc = mean(T.ACPR_dBc(m0),'omitnan');
    summaryStatsTable.ACPR_NoDPD_std_dB = std(T.ACPR_dBc(m0),'omitnan');
    summaryStatsTable.ACPR_DPD_mean_dBc = mean(T.ACPR_dBc(m1),'omitnan');
    summaryStatsTable.ACPR_DPD_std_dB = std(T.ACPR_dBc(m1),'omitnan');
    summaryStatsTable.ACPR_Improvement_Live_mean_dB = mean(P.ACPR_Improvement_Live_dB,'omitnan');
    summaryStatsTable.ACPR_Improvement_Live_std_dB = std(P.ACPR_Improvement_Live_dB,'omitnan');
    summaryStatsTable.RxPower_NoDPD_mean_dBFS = mean(T.RxPower_dBFS(m0),'omitnan');
    summaryStatsTable.RxPower_DPD_mean_dBFS = mean(T.RxPower_dBFS(m1),'omitnan');
    summaryStatsTable.RxPower_Delta_mean_dB = mean(P.RxPower_Delta_Live_dB,'omitnan');
    summaryStatsTable.STM32Power_NoDPD_mean_dB = mean(T.Power_mean_dB_stm32(m0),'omitnan');
    summaryStatsTable.STM32Power_DPD_mean_dB = mean(T.Power_mean_dB_stm32(m1),'omitnan');
    summaryStatsTable.STM32Power_Delta_mean_dB = mean(P.STM32Power_Delta_Live_dB,'omitnan');
    summaryStatsTable.RefNoDPD_EVM_SameTxGain_pct = refEvmTx;
    summaryStatsTable.RefNoDPD_ACPR_SameTxGain_dBc = refAcprTx;
    summaryStatsTable.RefNoDPD_RxPower_SameTxGain_dBFS = refRxTx;
    summaryStatsTable.RefNoDPD_STM32Power_SameTxGain_dB = refStmTx;
    summaryStatsTable.EVM_Improvement_vsOfficialSameRxPower_mean_pct_points = mean(P.EVM_Improvement_vsOfficialSameRxPower_pct_points,'omitnan');
    summaryStatsTable.ACPR_Improvement_vsOfficialSameRxPower_mean_dB = mean(P.ACPR_Improvement_vsOfficialSameRxPower_dB,'omitnan');
    summaryStatsTable.EVM_Improvement_vsOfficialSameSTM32Power_mean_pct_points = mean(P.EVM_Improvement_vsOfficialSameSTM32Power_pct_points,'omitnan');
    summaryStatsTable.ACPR_Improvement_vsOfficialSameSTM32Power_mean_dB = mean(P.ACPR_Improvement_vsOfficialSameSTM32Power_dB,'omitnan');
end

function boxplotByCondition_EXP012(T, yName)
    valid = T.Usable & isfinite(T.(yName));
    boxplot(T.(yName)(valid), T.Condition(valid));
end

function [f_psd, pxx_no_mean, pxx_dpd_mean] = averagePSD_EXP012(rxNoCell, rxDpdCell, fs)
    [f_psd, pxx_no_mean] = averageOneConditionPSD_EXP012(rxNoCell, fs);
    [f2, pxx_dpd_mean] = averageOneConditionPSD_EXP012(rxDpdCell, fs);
    if isempty(f_psd) || isempty(f2)
        f_psd = []; pxx_no_mean = []; pxx_dpd_mean = [];
    end
end

function [f_psd, pxx_mean] = averageOneConditionPSD_EXP012(rxCell, fs)
    f_psd = []; acc = []; n = 0;
    for k = 1:numel(rxCell)
        x = rxCell{k};
        if isempty(x) || length(x) < 1024, continue; end
        [pxx, f] = localPSD_EXP012(x, fs);
        if isempty(pxx), continue; end
        if isempty(acc), acc = zeros(size(pxx)); f_psd = f; end
        acc = acc + pxx; n = n + 1;
    end
    if n == 0, f_psd = []; pxx_mean = []; else, pxx_mean = acc/n; end
end

function [pxx, f] = localPSD_EXP012(x, fs)
    x = x(:); pxx = []; f = [];
    N = min(614400, length(x));
    if N < 1024, return; end
    x = x(1:N) - mean(x(1:N));
    winLen = min(4096, N);
    nfft = max(4096, 2^nextpow2(min(N, 262144)));
    [pxx, f] = pwelch(x, hamming(winLen), [], nfft, fs, 'centered');
end

function idxRun = representativeRunIndex_EXP012(T, condName, targetEVM)
    idxRun = NaN;
    mask = T.Condition == condName & T.Usable & isfinite(T.EVM_pct);
    if ~any(mask), return; end
    candidates = find(mask);
    [~, k] = min(abs(T.EVM_pct(candidates) - targetEVM));
    idxRun = T.PointIndex(candidates(k));
end

function [refVec, eqVec] = getConstellationVectors_EXP012(refSymbCell, eqSymbCell, maxSymbols)
    refVec = []; eqVec = [];
    try
        if iscell(refSymbCell)
            for k = 1:numel(refSymbCell), if ~isempty(refSymbCell{k}), refVec = refSymbCell{k}(:); break; end, end
        elseif ~isempty(refSymbCell), refVec = refSymbCell(:); end
        if iscell(eqSymbCell)
            for k = 1:numel(eqSymbCell), if ~isempty(eqSymbCell{k}), eqVec = eqSymbCell{k}(:); break; end, end
        elseif ~isempty(eqSymbCell), eqVec = eqSymbCell(:); end
        if ~isempty(refVec) && length(refVec) > maxSymbols, idx = round(linspace(1,length(refVec),maxSymbols)); refVec = refVec(idx); end
        if ~isempty(eqVec) && length(eqVec) > maxSymbols, idx = round(linspace(1,length(eqVec),maxSymbols)); eqVec = eqVec(idx); end
    catch
        refVec = []; eqVec = [];
    end
end

function plotAMAM_AMPM_EXP012(txOriginal, txDPD, rxNoDPD, rxDPD)
    txOriginal = txOriginal(:);
    txDPD = txDPD(:);
    rxNoDPD = rxNoDPD(:);
    rxDPD = rxDPD(:);

    L = min([length(txOriginal), length(txDPD), length(rxNoDPD), length(rxDPD), 120000]);
    txOriginal = txOriginal(1:L);
    txDPD = txDPD(1:L);
    rxNoDPD = rxNoDPD(1:L);
    rxDPD = rxDPD(1:L);

    alphaNo = (rxNoDPD' * txOriginal) / (rxNoDPD' * rxNoDPD + eps);
    alphaDpd = (rxDPD' * txOriginal) / (rxDPD' * rxDPD + eps);
    rxNoScaled = alphaNo * rxNoDPD;
    rxDpdScaled = alphaDpd * rxDPD;

    xAmp = abs(txOriginal);
    xAmpNorm = xAmp / (max(xAmp) + eps);
    commonScale = max([abs(txOriginal); abs(txDPD); abs(rxNoScaled); abs(rxDpdScaled)] + eps);

    yNo = abs(rxNoScaled) / commonScale;
    yPred = abs(txDPD) / commonScale;
    yDpd = abs(rxDpdScaled) / commonScale;

    phNo = angle(rxNoScaled .* conj(txOriginal));
    phPred = angle(txDPD .* conj(txOriginal));
    phDpd = angle(rxDpdScaled .* conj(txOriginal));

    tiledlayout(2,1);

    nexttile;
    scatter(xAmpNorm, yNo, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03); hold on;
    scatter(xAmpNorm, yPred, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    scatter(xAmpNorm, yDpd, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    grid on;
    xlabel('Normalized input amplitude');
    ylabel('Normalized amplitude');
    title('AM/AM representative reproducibility comparison');
    legend('Chain output w/o DPD','DPD waveform','Chain output with DPD','Location','best');

    nexttile;
    scatter(xAmpNorm, phNo, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03); hold on;
    scatter(xAmpNorm, phPred, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    scatter(xAmpNorm, phDpd, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    grid on;
    xlabel('Normalized input amplitude');
    ylabel('Phase shift (rad)');
    title('AM/PM representative reproducibility comparison');
    legend('Chain output w/o DPD','DPD waveform','Chain output with DPD','Location','best');
end

function plotPSDComparison(rx0, rx1, fs, acpr0, acpr1, txGain)
    rx0 = rx0(:); rx1 = rx1(:);
    N = min([numel(rx0), numel(rx1), 262144]);
    rx0 = rx0(1:N); rx1 = rx1(1:N);
    nfft = 8192; win = hamming(4096);
    [P0,f] = pwelch(rx0, win, [], nfft, fs, 'centered');
    [P1,~] = pwelch(rx1, win, [], nfft, fs, 'centered');
    P0dB = 10*log10(P0+eps); P1dB = 10*log10(P1+eps);
    P0dB = P0dB - max(P0dB); P1dB = P1dB - max(P1dB);
    plot(f/1e6, P0dB, 'LineWidth', 1.3); hold on;
    plot(f/1e6, P1dB, 'LineWidth', 1.3);
    xline(-10,'--k'); xline(10,'--k'); xline(-30,':k'); xline(30,':k');
    grid on; xlabel('Frequency (MHz)'); ylabel('PSD (dB normalized)');
    title(sprintf('PSD comparison at TxGain %.2f dB | ACPR no-DPD %.2f dBc | DPD %.2f dBc', txGain, acpr0, acpr1));
    legend('No-DPD','DPD','Location','best');
end

function setSafeState(txObj, idleGain)
    try
        txObj.Gain = idleGain;
        transmitRepeat(txObj, zeros(1000,1));
    catch
    end
end

function cleanupAll(txObj, rxObj, idleGain, fidPower)
    try; setSafeState(txObj, idleGain); catch; end
    try; release(txObj); catch; end
    try; release(rxObj); catch; end
    try
        if fidPower > 0
            fclose(fidPower);
        end
    catch
    end
end

function [meanAmp, meanPhase] = binAverage_EXP012(xNorm, yAmp, yPhase, edges)
    meanAmp = nan(length(edges)-1,1); meanPhase = nan(length(edges)-1,1);
    for ii = 1:length(edges)-1
        idx = xNorm >= edges(ii) & xNorm < edges(ii+1);
        if nnz(idx) > 20
            meanAmp(ii) = mean(yAmp(idx),'omitnan');
            meanPhase(ii) = mean(yPhase(idx),'omitnan');
        end
    end
end

function setSafeState(txObj, idleGain)
    try
        txObj.Gain = idleGain;
        transmitRepeat(txObj, zeros(1000,1));
    catch
    end
end

function cleanupAll(txObj, rxObj, idleGain, fidPower)
    try; setSafeState(txObj, idleGain); catch; end
    try; release(txObj); catch; end
    try; release(rxObj); catch; end
    try
        if fidPower > 0
            fclose(fidPower);
        end
    catch
    end
end
