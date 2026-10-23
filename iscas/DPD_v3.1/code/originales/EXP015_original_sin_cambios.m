%% ========================================================================
%  EXP015 — ITERATIVE HILA / ILA GMP-DPD TRAINING WITH DPDV2 NO-DPD REFERENCE
%  ----------------------------------------------------------------------
%  Goal:
%    Train iterative Generalized Memory Polynomial (GMP) DPD models at one selected point of
%    operation and visualize the evolution of:
%      - coefficients
%      - EVM
%      - ACPR
%      - Delta RX power
%      - PAPR / peak ratio
%
%  Main idea:
%    For each candidate GMP parameter set, the script:
%      1) captures a baseline response without DPD,
%      2) estimates post-inverse coefficients,
%      3) applies them as a predistorter,
%      4) recaptures the response,
%      5) updates the coefficients iteratively.
%
%  Important:
%    - Ka/La define the aligned MP branch.
%    - Kb/Lb/Mb define lagging-envelope cross terms.
%    - Kc/Lc/Mc define leading-envelope cross terms.
%    - The actual DPD is defined by the complex coefficient vector.
%    - The coefficients are updated at every iteration.
%    - The best iteration is selected by valid EVM/ACPR/power behavior.
%
%  Recommended starting point from Phase 1:
%    fixedTxGain_Pluto = -15.25 dB
%    fixedRxGain_Pluto = 14 dB
%
%  Physical chain assumed:
%    Pluto TX -> BGU -> Upconverter -> 26 GHz filter -> 30 dB attenuator
%    -> Downconverter -> meter / Pluto RX
%
%% ========================================================================

clear; close all; clc;

%% ========================================================================
%  EASY-TO-MODIFY EXPERIMENT CONFIGURATION
%% ========================================================================

% -------------------- Operating point --------------------
deviceName = "Pluto";
centerFrequency = 5e9;
idleGain_dB = -80;

fixedTxGain_Pluto = -22.25;   % approx. 0.5 dB upconverter compression from EXP009F
fixedRxGain_Pluto = 8;        % keep same RX gain as EXP009F baseline sweep
powerScaleFactor  = 0.8;

% Metadata only. Match this with your physical DSA setup.
fixedDsaSteps_Metadata = 10;   % TX DSA = 5 dB in ADMV/ACE
dsaStep_dB = 0.5;
fixedDsaAtten_dB_Metadata = fixedDsaSteps_Metadata*dsaStep_dB;

% -------------------- Capture and retry --------------------
captureTime_s = 80e-3;   % longer capture for robust retry at compressed operating point
maxCaptureAttempts = 5;
evmRetryThreshold_pct = 60;
minSyncMetric = 0.95;       % EXP008 showed NORMAL_NO_CFO around 0.97-0.98

% Robust alignment parameters copied from the EXP009 workflow.
% These are important because EXP009 used a decimated coarse search plus
% fine search and then complex-gain normalization without external CFO correction. The older xcorr-only routine
% can pick a weaker timing point and produce artificially high EVM.
alignDecimationFactor = 16;
fineSearchHalfWindow_samples = 4000;
phaseFitMagnitudeThreshold = 0.05;
numFramesForAlign = 1;

% -------------------- Iterative HILA settings --------------------
% GMP model parameters:
%   aligned branch: x[n-l] |x[n-l]|^(2k), k = 0...Ka-1
%   lagging branch: x[n-l] |x[n-l-m]|^(2k), k = 1...Kb
%   leading branch: x[n-l] |x[n-l+m]|^(2k), k = 1...Kc
%
% The first two models use only lagging cross terms. The third adds a
% reduced leading-envelope branch. Their coefficient counts are 22, 26,
% and 29, respectively.
gmpModels = [
    struct("ID","GMP_F1_REF", ...
           "Ka",5,"La",4, ...
           "Kb",2,"Lb",3,"Mb",1, ...
           "Kc",1,"Lc",3,"Mc",1)

    struct("ID","GMP_F2_HIGH_ORDER", ...
           "Ka",6,"La",4, ...
           "Kb",2,"Lb",3,"Mb",1, ...
           "Kc",1,"Lc",3,"Mc",1)

    struct("ID","GMP_F3_HIGH_MEMORY", ...
           "Ka",5,"La",5, ...
           "Kb",2,"Lb",4,"Mb",1, ...
           "Kc",1,"Lc",4,"Mc",1)

    struct("ID","GMP_F4_HIGH_CROSS_ORDER", ...
           "Ka",5,"La",4, ...
           "Kb",3,"Lb",3,"Mb",1, ...
           "Kc",2,"Lc",3,"Mc",1)
];

maxHilaIterations = 5;               % 15 iterations/model
coeffBlendMu = 0.08;                   % smoother update for GMP candidates
regularizationLambdaRel = 5e-2;       % stronger stabilization for correlated GMP bases
minTrainingAmplitudeRatio = 0.08;
maxConsecutiveHardFailures = 2;        % do not kill the model after a single bad iteration

% -------------------- Equal-power reference comparison --------------------
% This file should come from the full no-DPD Phase 1 sweep, ideally the
% alignment-metrics / phase-1 table containing RxPower_dBFS and EVM.
% Use the official Block-A no-DPD baseline. Keep this CSV in the same
% folder as this script, or provide an absolute path.
% Leave empty to auto-detect the most recent EXP009F OFFICIAL_NODPD_REFERENCE
% inside DPDV2/data/**/processed. You may also paste an absolute path here.
noDPDReferenceCsv = "";
referenceRxPowerColumn = 'RxPower_dBFS';
referenceMeterPowerColumn = 'Power_mean_dB_stm32';   % detector/VGU/IF-observation power
referenceEVMColumn = 'EVM_NR_Aligned_pct';
referenceACPRColumn = 'ACPR_dBc';
referenceTxGainColumn = 'TxGain_dB';
referenceAcceptedColumn = 'Accepted';

% Composite score weights for selecting the final DPD iteration.
weightEqPowerEVM   = 1.00;   % main criterion: EVM improvement vs no-DPD at same RX power
weightEqPowerACPR  = 0.35;   % ACPR improvement vs no-DPD at same RX power
weightMeterEVM     = 0.35;   % EVM improvement vs no-DPD at same meter/VGU power
weightPAPR         = 0.08;   % penalty for excessive PAPR growth

% -------------------- Early stopping --------------------
minEvmImprovement_pctPoints = 0.03; % informational threshold only
patienceNoImprove = 2;            % do not stop just because one iteration does not improve

% -------------------- DPD waveform guards --------------------
maxPredistortedPeakRatio = 1.10;    % allow moderate expansion while staying safe
maxAllowedDpdPAPR_Extra_dB = 6.5;   % diagnostic limit

% -------------------- Selection / physical guards --------------------
maxAllowedRxPowerDrop_dB = 1.8;
maxAllowedRxPowerRise_dB = 1.0;
digitalRxSaturationLimit_dBFS = -3.0;
maxAcceptedPostEVM_pct = 50;
minACPRImprovement_dB = 0.3;

% -------------------- Visualization --------------------
plotMaxSymbols = 6000;
saveRawCaptures = true;
% -------------------- STM32 / LTC5596 meter --------------------
% This measures the observation IF power at the same operating point.
% It is used for fair comparison against EXP009F at the same meter power.
useSTM32PowerMeter = true;
serialPort       = "COM12";
serialBaud       = 209700;
serialTerminator = "LF";
serialTimeout_s  = 2.00;   % robust STM32 block read timeout
doPingTest       = true;
nPowerSamplesPerPoint = 50;


%% ========================================================================
%  OUTPUT DIRECTORIES
%% ========================================================================

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir)
    scriptDir = pwd;
end

try
    examplePath = fullfile(matlabroot, 'examples', '5g', 'NRWaveformCaptureAndAnalysisWithSDRExample');
    if exist(examplePath, 'dir')
        addpath(examplePath);
    end
catch
end

txTag = string(strrep(sprintf('%.2f', fixedTxGain_Pluto), '.', 'p'));
rxTag = string(strrep(sprintf('%.2f', fixedRxGain_Pluto), '.', 'p'));
timeTag = string(datetime("now","Format","yyyyMMdd_HHmmss"));

projectDir = fileparts(scriptDir);
baselineDir = fullfile(projectDir, "baseline");
dataDir = fullfile(projectDir, "data");

if ~exist(dataDir, "dir")
    mkdir(dataDir);
end

if strlength(string(noDPDReferenceCsv)) == 0
    noDPDReferenceCsv = findLatestOfficialNoDPDReference(dataDir);
end

% Estimate Pluto output power at the selected operating point from the current DPDV2 baseline.
% This is metadata for fair comparison and for the output tables; it is not used
% to control the SDR gain.
[plutoOutEstimated_dBm, plutoOutCalibrationMode] = estimatePlutoOutputFromDPDV2Baseline(fixedTxGain_Pluto, baselineDir);

outputRoot = fullfile(dataDir, ...
    "EXP015_GMP_HILA_0p5DBCOMP_DPDV2_OFFREF_Tx_" + txTag + "_Rx_" + rxTag + "_" + timeTag);
rawDir       = fullfile(outputRoot, "raw");
processedDir = fullfile(outputRoot, "processed");
figuresDir   = fullfile(outputRoot, "figures");
for d = [{rawDir}, {processedDir}, {figuresDir}]
    if ~exist(d{1}, "dir")
        mkdir(d{1});
    end
end
baseName = "EXP015_GMP_HILA_0p5DBCOMP_DPDV2_OFFREF_Tx_" + txTag + "_Rx_" + rxTag + "_" + timeTag;

metricsCsvFile = fullfile(processedDir, baseName + "_iterative_metrics.csv");
coeffCsvFile   = fullfile(processedDir, baseName + "_coefficients_long.csv");
bestCsvFile    = fullfile(processedDir, baseName + "_best_selection.csv");
matFile        = fullfile(processedDir, baseName + "_results.mat");
csvMeterRawFile = fullfile(rawDir, baseName + "_stm32-meter-raw.csv");
fidMeterRaw = -1;

%% ========================================================================
%  5G NR WAVEFORM GENERATION
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
cfgDLFRC.SampleRate = [];   % Keep auto sample rate, as in EXP009 (typically 30.72 Msps).

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

PAPR_tx_dB = 10*log10(max(abs(txWaveform)).^2 / mean(abs(txWaveform).^2));
txPower_dBFS = 10*log10(mean(abs(txWaveform).^2) + eps);

fprintf('\n===== EXP015 0.5 dB-COMPRESSION HILA SETUP — GMP MODELS + OFFICIAL REFERENCE =====\n');
fprintf('TX gain                 = %.2f dB\n', fixedTxGain_Pluto);
fprintf('Pluto output estimated  = %.3f dBm\n', plutoOutEstimated_dBm);
fprintf('RX gain                 = %.2f dB\n', fixedRxGain_Pluto);
fprintf('powerScaleFactor        = %.3f\n', powerScaleFactor);
fprintf('Original PAPR           = %.2f dB\n', PAPR_tx_dB);
fprintf('Original TX power       = %.2f dBFS rel.\n', txPower_dBFS);
fprintf('GMP-HILA iterations/model   = %d\n', maxHilaIterations);
fprintf('Coefficient blend mu    = %.3f\n', coeffBlendMu);

%% ========================================================================
%  EVM CONFIGURATION
%% ========================================================================

cfgEVM = struct();
cfgEVM.PlotEVM    = false;
cfgEVM.DisplayEVM = false;
cfgEVM.SampleRate = sampleRate;
cfgEVM.IQImbalance = true;
cfgEVM.TargetRNTIs = 0;
cfgEVM.CorrectCoarseFO = true;
cfgEVM.CorrectFineFO   = true;
cfgEVM.ExcludeDC = true;

%% ========================================================================
%  INITIALIZE SDR
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

cleanupObj = onCleanup(@() cleanupSDR(sdrTransmitter, sdrReceiver, idleGain_dB)); %#ok<NASGU>

%% ========================================================================
%  INITIALIZE STM32 POWER METER
%% ========================================================================

stm = [];
if useSTM32PowerMeter
    try
        fprintf("\nOpening STM32 power meter on %s...\n", serialPort);
        stm = serialport(serialPort, serialBaud, "Timeout", serialTimeout_s);
        configureTerminator(stm, serialTerminator);
        flush(stm);
        pause(0.5);

        if doPingTest
            writeline(stm, "PING");
            pause(0.2);
            while stm.NumBytesAvailable > 0
                fprintf("STM32: %s\n", strtrim(readline(stm)));
            end
            flush(stm);
        end

        fidMeterRaw = fopen(csvMeterRawFile, "w");
        if fidMeterRaw < 0
            error("Could not create STM32 raw CSV: %s", csvMeterRawFile);
        end
        fprintf(fidMeterRaw, "pc_timestamp,label,iteration,txGain_dB,rxGain_dB,stm32_time_ms,adc_raw,voltage_V,power_dB_meter,raw_line\n");
    catch ME
        warning("Could not initialize STM32 power meter. Continuing without meter: %s", ME.message);
        useSTM32PowerMeter = false;
        stm = [];
    end
end


%% ========================================================================
%  BASELINE CAPTURE WITHOUT DPD
%% ========================================================================

fprintf('\n===== BASELINE CAPTURE WITHOUT DPD =====\n');

sdrTransmitter.Gain = fixedTxGain_Pluto;
transmitRepeat(sdrTransmitter, txWaveform);
pause(0.8);

baseline = captureAndMeasureWithRetry( ...
    sdrReceiver, txWaveform, cfgDLFRC, cfgEVM, sampleRate, ...
    captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
    maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
    alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign, ...
    rawDir, saveRawCaptures, "baseline", ...
    fixedTxGain_Pluto, fixedRxGain_Pluto, ...
    fixedDsaSteps_Metadata, fixedDsaAtten_dB_Metadata);

if ~baseline.usable
    error('Baseline capture is not usable. Check RF path, RX gain, synchronization and saturation.');
end

baseline = attachMeterMeasurement(baseline, stm, useSTM32PowerMeter, fixedTxGain_Pluto, fixedRxGain_Pluto, nPowerSamplesPerPoint, fidMeterRaw, "baseline", 0);

fprintf('Baseline: EVM %.2f %% | ACPR %.2f dBc | RX %.2f dBFS | Sync %.4f | Meter %.2f dBm | V %.4f V\n', ...
    baseline.evm_pct, baseline.acpr_dBc, baseline.rxPower_dBFS, baseline.syncMetric, baseline.meterPower_dBm, baseline.meterVoltage_V);

baselineRxNorm = normalizeRxToTx(baseline.rxAligned, txWaveform);

%% ========================================================================
%  ITERATIVE HILA / ILA TRAINING
%% ========================================================================

nModels = numel(gmpModels);
metricsRows = createMetricsRowStruct();
metricsRows(1) = [];
coeffRows = createCoeffRowStruct();
coeffRows(1) = [];
rowCounter = 0;
coeffCounter = 0;
rowCoeffs = {};
rowTxDPD = {};
rowPostResult = {};

modelHistories = cell(nModels, 1);

for iModel = 1:nModels

    p = gmpModels(iModel);
    modelID = char(p.ID);
    nCoeff = p.Ka*p.La + p.Kb*p.Lb*p.Mb + p.Kc*p.Lc*p.Mc;

    % Compatibility fields for legacy tables/plots:
    % M stores the maximum causal delay represented by the GMP basis.
    % K stores the number of aligned nonlinear branches Ka.
    M = max([p.La-1, p.Lb-1+p.Mb, 0]);
    K = p.Ka;

    fprintf('\n=================================================================\n');
    fprintf('MODEL %d/%d: %s\n', iModel, nModels, modelID);
    fprintf('=================================================================\n');

    coeffPrev = zeros(nCoeff,1);
    coeffCurrent = zeros(nCoeff,1);
    coeffDeltaNorm = 0;
    noImproveCount = 0;
    consecutiveHardFailures = 0;
    bestLocalEVM = Inf;
    trainSourceNorm = baselineRxNorm;

    history = struct();
    history.modelID = modelID;
    history.M = M;
    history.K = K;
    history.GMPParameters = p;
    history.tableRowIDs = [];

    % -------------------- iteration 0 = baseline row --------------------
    rowCounter = rowCounter + 1;
    metricsRows(rowCounter) = createMetricsRowStruct();
    metricsRows(rowCounter).TableRowID = rowCounter;
    metricsRows(rowCounter).ModelID = string(modelID);
    metricsRows(rowCounter).M = M;
    metricsRows(rowCounter).K = K;
    metricsRows(rowCounter).Ka = p.Ka;
    metricsRows(rowCounter).La = p.La;
    metricsRows(rowCounter).Kb = p.Kb;
    metricsRows(rowCounter).Lb = p.Lb;
    metricsRows(rowCounter).Mb = p.Mb;
    metricsRows(rowCounter).Kc = p.Kc;
    metricsRows(rowCounter).Lc = p.Lc;
    metricsRows(rowCounter).Mc = p.Mc;
    metricsRows(rowCounter).Iteration = 0;
    metricsRows(rowCounter).TxGain_Pluto_dB = fixedTxGain_Pluto;
    metricsRows(rowCounter).RxGain_Pluto_dB = fixedRxGain_Pluto;
    metricsRows(rowCounter).PlutoOutEstimated_dBm = plutoOutEstimated_dBm;
    metricsRows(rowCounter).PlutoOutCalibrationMode = string(plutoOutCalibrationMode);
    metricsRows(rowCounter).TrainSamples = NaN;
    metricsRows(rowCounter).CondEstimate = NaN;
    metricsRows(rowCounter).CoeffCount = nCoeff;
    metricsRows(rowCounter).CoeffNorm = 0;
    metricsRows(rowCounter).CoeffDeltaNorm = 0;
    metricsRows(rowCounter).PAPR_DPD_dB = PAPR_tx_dB;
    metricsRows(rowCounter).PeakRatio_DPD_to_Original = 1.0;
    metricsRows(rowCounter).PAPRGuardPass = true;
    metricsRows(rowCounter).EVM_Pre_pct = baseline.evm_pct;
    metricsRows(rowCounter).EVM_Post_pct = baseline.evm_pct;
    metricsRows(rowCounter).EVM_Improvement_pct_points = 0;
    metricsRows(rowCounter).ACPR_Pre_dBc = baseline.acpr_dBc;
    metricsRows(rowCounter).ACPR_Post_dBc = baseline.acpr_dBc;
    metricsRows(rowCounter).ACPR_Improvement_dB = 0;
    metricsRows(rowCounter).RxPower_Pre_dBFS = baseline.rxPower_dBFS;
    metricsRows(rowCounter).RxPower_Post_dBFS = baseline.rxPower_dBFS;
    metricsRows(rowCounter).RxPower_Delta_dB = 0;
    metricsRows(rowCounter).MeterPower_DPD_dBm = baseline.meterPower_dBm;
    metricsRows(rowCounter).MeterVoltage_DPD_V = baseline.meterVoltage_V;
    metricsRows(rowCounter).MeterADC_DPD_raw = baseline.meterADC_raw;
    metricsRows(rowCounter).MeterNValid = baseline.meterNValid;
    metricsRows(rowCounter).PowerGuardPass = true;
    metricsRows(rowCounter).SyncMetric_Post = baseline.syncMetric;
    metricsRows(rowCounter).FreqOffset_Hz = baseline.freqOffset_Hz;
    metricsRows(rowCounter).PostCaptureAttempts = baseline.attemptCount;
    metricsRows(rowCounter).PostEVMRetryFailed = baseline.retryFailed;
    metricsRows(rowCounter).ClippingGuardPass = baseline.rxPower_dBFS < digitalRxSaturationLimit_dBFS;
    metricsRows(rowCounter).IterationAccepted = false;
    metricsRows(rowCounter).EarlyStop = false;
    metricsRows(rowCounter).UsableCapture = true;
    rowCoeffs{rowCounter,1} = coeffCurrent;
    rowTxDPD{rowCounter,1} = txWaveform;
    rowPostResult{rowCounter,1} = baseline;
    history.tableRowIDs(end+1) = rowCounter;

    for iter = 1:maxHilaIterations
        fprintf('\n--- %s | Iteration %d/%d ---\n', modelID, iter, maxHilaIterations);

        try
            tBuild = tic;
            [Xreg, ytrim, idxTrain, coeffLabels] = buildGMPTrainingSet(trainSourceNorm, txWaveform, p, minTrainingAmplitudeRatio);
            matrixBuildTime_s = toc(tBuild);

            if size(Xreg,1) <= size(Xreg,2)
                warning('Too few training samples for %s iteration %d. Stopping model.', modelID, iter);
                break;
            end

            tSolve = tic;
            coeffHat = solveRegularizedLS(Xreg, ytrim, regularizationLambdaRel);
            lsSolveTime_s = toc(tSolve);

            if iter == 1
                coeffCurrent = coeffHat;
            else
                coeffCurrent = (1-coeffBlendMu)*coeffPrev + coeffBlendMu*coeffHat;
            end
            coeffDeltaNorm = norm(coeffCurrent - coeffPrev);
            coeffPrev = coeffCurrent;

            tApply = tic;
            txDPD = applyGMP(txWaveform, coeffCurrent, p);
            txDPD = normalizeDPDWaveform(txDPD, txWaveform, maxPredistortedPeakRatio);
            dpdApplyTime_s = toc(tApply);

            paprDPD_dB = 10*log10(max(abs(txDPD)).^2 / mean(abs(txDPD).^2));
            peakRatio = max(abs(txDPD)) / max(abs(txWaveform));
            paprGuardPass = isfinite(paprDPD_dB) && paprDPD_dB <= (PAPR_tx_dB + maxAllowedDpdPAPR_Extra_dB);

            fprintf('  Train samples = %d | condEst = %.3e\n', nnz(idxTrain), condest(Xreg'*Xreg + speye(size(Xreg,2))*eps));
            fprintf('  Timing: build %.4f s | LS %.4f s | apply %.4f s\n', ...
                matrixBuildTime_s, lsSolveTime_s, dpdApplyTime_s);
            fprintf('  Coeff norm = %.3e | delta norm = %.3e\n', norm(coeffCurrent), coeffDeltaNorm);
            fprintf('  PAPR DPD = %.2f dB | peak ratio = %.3f | PAPR guard = %d\n', paprDPD_dB, peakRatio, paprGuardPass);

            if ~paprGuardPass
                warning('PAPR guard failed for %s iteration %d. Logging the iteration and continuing.', modelID, iter);
                rowCounter = rowCounter + 1;
                metricsRows(rowCounter) = createMetricsRowStruct();
                metricsRows(rowCounter).TableRowID = rowCounter;
                metricsRows(rowCounter).ModelID = string(modelID);
                metricsRows(rowCounter).M = M;
                metricsRows(rowCounter).K = K;
                metricsRows(rowCounter).Ka = p.Ka;
                metricsRows(rowCounter).La = p.La;
                metricsRows(rowCounter).Kb = p.Kb;
                metricsRows(rowCounter).Lb = p.Lb;
                metricsRows(rowCounter).Mb = p.Mb;
                metricsRows(rowCounter).Kc = p.Kc;
                metricsRows(rowCounter).Lc = p.Lc;
                metricsRows(rowCounter).Mc = p.Mc;
                metricsRows(rowCounter).Iteration = iter;
                metricsRows(rowCounter).TxGain_Pluto_dB = fixedTxGain_Pluto;
                metricsRows(rowCounter).RxGain_Pluto_dB = fixedRxGain_Pluto;
                metricsRows(rowCounter).PlutoOutEstimated_dBm = plutoOutEstimated_dBm;
                metricsRows(rowCounter).PlutoOutCalibrationMode = string(plutoOutCalibrationMode);
                metricsRows(rowCounter).TrainSamples = nnz(idxTrain);
                metricsRows(rowCounter).CondEstimate = condest(Xreg'*Xreg + speye(size(Xreg,2))*eps);
                metricsRows(rowCounter).CoeffCount = nCoeff;
                metricsRows(rowCounter).MatrixBuildTime_s = matrixBuildTime_s;
                metricsRows(rowCounter).LSSolveTime_s = lsSolveTime_s;
                metricsRows(rowCounter).DPDApplyTime_s = dpdApplyTime_s;
                metricsRows(rowCounter).CoeffNorm = norm(coeffCurrent);
                metricsRows(rowCounter).CoeffDeltaNorm = coeffDeltaNorm;
                metricsRows(rowCounter).PAPR_DPD_dB = paprDPD_dB;
                metricsRows(rowCounter).PeakRatio_DPD_to_Original = peakRatio;
                metricsRows(rowCounter).PAPRGuardPass = false;
                metricsRows(rowCounter).EVM_Pre_pct = baseline.evm_pct;
                metricsRows(rowCounter).ACPR_Pre_dBc = baseline.acpr_dBc;
                metricsRows(rowCounter).RxPower_Pre_dBFS = baseline.rxPower_dBFS;
                metricsRows(rowCounter).EarlyStop = true;
                rowCoeffs{rowCounter,1} = coeffCurrent;
                rowTxDPD{rowCounter,1} = txDPD;
                rowPostResult{rowCounter,1} = initResultStruct();
                history.tableRowIDs(end+1) = rowCounter;
                setSafeState(sdrTransmitter, idleGain_dB);
                pause(0.25);
                continue;
            end

            sdrTransmitter.Gain = fixedTxGain_Pluto;
            transmitRepeat(sdrTransmitter, txDPD);
            pause(0.8);

            post = captureAndMeasureWithRetry( ...
                sdrReceiver, txDPD, cfgDLFRC, cfgEVM, sampleRate, ...
                captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
                maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
                alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign, ...
                rawDir, saveRawCaptures, sprintf('%s_iter_%02d', modelID, iter), ...
                fixedTxGain_Pluto, fixedRxGain_Pluto, ...
                fixedDsaSteps_Metadata, fixedDsaAtten_dB_Metadata);

            post = attachMeterMeasurement(post, stm, useSTM32PowerMeter, fixedTxGain_Pluto, fixedRxGain_Pluto, nPowerSamplesPerPoint, fidMeterRaw, string(modelID), iter);

            rowCounter = rowCounter + 1;
            metricsRows(rowCounter) = createMetricsRowStruct();
            metricsRows(rowCounter).TableRowID = rowCounter;
            metricsRows(rowCounter).ModelID = string(modelID);
            metricsRows(rowCounter).M = M;
            metricsRows(rowCounter).K = K;
            metricsRows(rowCounter).Ka = p.Ka;
            metricsRows(rowCounter).La = p.La;
            metricsRows(rowCounter).Kb = p.Kb;
            metricsRows(rowCounter).Lb = p.Lb;
            metricsRows(rowCounter).Mb = p.Mb;
            metricsRows(rowCounter).Kc = p.Kc;
            metricsRows(rowCounter).Lc = p.Lc;
            metricsRows(rowCounter).Mc = p.Mc;
            metricsRows(rowCounter).Iteration = iter;
            metricsRows(rowCounter).TxGain_Pluto_dB = fixedTxGain_Pluto;
            metricsRows(rowCounter).RxGain_Pluto_dB = fixedRxGain_Pluto;
            metricsRows(rowCounter).PlutoOutEstimated_dBm = plutoOutEstimated_dBm;
            metricsRows(rowCounter).PlutoOutCalibrationMode = string(plutoOutCalibrationMode);
            metricsRows(rowCounter).TrainSamples = nnz(idxTrain);
            metricsRows(rowCounter).CondEstimate = condest(Xreg'*Xreg + speye(size(Xreg,2))*eps);
            metricsRows(rowCounter).CoeffCount = nCoeff;
            metricsRows(rowCounter).MatrixBuildTime_s = matrixBuildTime_s;
            metricsRows(rowCounter).LSSolveTime_s = lsSolveTime_s;
            metricsRows(rowCounter).DPDApplyTime_s = dpdApplyTime_s;
            metricsRows(rowCounter).CoeffNorm = norm(coeffCurrent);
            metricsRows(rowCounter).CoeffDeltaNorm = coeffDeltaNorm;
            metricsRows(rowCounter).PAPR_DPD_dB = paprDPD_dB;
            metricsRows(rowCounter).PeakRatio_DPD_to_Original = peakRatio;
            metricsRows(rowCounter).PAPRGuardPass = paprGuardPass;
            metricsRows(rowCounter).EVM_Pre_pct = baseline.evm_pct;
            metricsRows(rowCounter).ACPR_Pre_dBc = baseline.acpr_dBc;
            metricsRows(rowCounter).RxPower_Pre_dBFS = baseline.rxPower_dBFS;
            metricsRows(rowCounter).MeterPower_DPD_dBm = post.meterPower_dBm;
            metricsRows(rowCounter).MeterVoltage_DPD_V = post.meterVoltage_V;
            metricsRows(rowCounter).MeterADC_DPD_raw = post.meterADC_raw;
            metricsRows(rowCounter).MeterNValid = post.meterNValid;

            rowCoeffs{rowCounter,1} = coeffCurrent;
            rowTxDPD{rowCounter,1} = txDPD;
            rowPostResult{rowCounter,1} = post;
            history.tableRowIDs(end+1) = rowCounter;

            if ~post.usable
                warning('Capture unusable for %s iteration %d. Keeping previous training source and continuing.', modelID, iter);
                metricsRows(rowCounter).PostCaptureAttempts = post.attemptCount;
                metricsRows(rowCounter).PostEVMRetryFailed = post.retryFailed;
                metricsRows(rowCounter).UsableCapture = false;
                metricsRows(rowCounter).EarlyStop = false;
                consecutiveHardFailures = consecutiveHardFailures + 1;
                if consecutiveHardFailures >= maxConsecutiveHardFailures
                    warning('Model %s stopped after %d consecutive unusable iterations.', modelID, consecutiveHardFailures);
                    break;
                end
                setSafeState(sdrTransmitter, idleGain_dB);
                pause(0.25);
                continue;
            end
            consecutiveHardFailures = 0;

            metricsRows(rowCounter).UsableCapture = true;
            metricsRows(rowCounter).EVM_Post_pct = post.evm_pct;
            metricsRows(rowCounter).EVM_Improvement_pct_points = baseline.evm_pct - post.evm_pct;
            metricsRows(rowCounter).ACPR_Post_dBc = post.acpr_dBc;
            metricsRows(rowCounter).ACPR_Improvement_dB = baseline.acpr_dBc - post.acpr_dBc;
            metricsRows(rowCounter).RxPower_Post_dBFS = post.rxPower_dBFS;
            metricsRows(rowCounter).RxPower_Delta_dB = post.rxPower_dBFS - baseline.rxPower_dBFS;
            metricsRows(rowCounter).SyncMetric_Post = post.syncMetric;
            metricsRows(rowCounter).FreqOffset_Hz = post.freqOffset_Hz;
            metricsRows(rowCounter).PostCaptureAttempts = post.attemptCount;
            metricsRows(rowCounter).PostEVMRetryFailed = post.retryFailed;

            powerGuardPass = metricsRows(rowCounter).RxPower_Delta_dB >= -maxAllowedRxPowerDrop_dB && ...
                             metricsRows(rowCounter).RxPower_Delta_dB <=  maxAllowedRxPowerRise_dB;
            clippingGuardPass = post.rxPower_dBFS < digitalRxSaturationLimit_dBFS;
            acprImproved = isfinite(post.acpr_dBc) && ((baseline.acpr_dBc - post.acpr_dBc) >= minACPRImprovement_dB);
            evmValid = isfinite(post.evm_pct) && post.evm_pct < maxAcceptedPostEVM_pct;
            syncValid = isfinite(post.syncMetric) && post.syncMetric >= minSyncMetric;

            metricsRows(rowCounter).PowerGuardPass = powerGuardPass;
            metricsRows(rowCounter).ClippingGuardPass = clippingGuardPass;
            metricsRows(rowCounter).IterationAccepted = evmValid && syncValid && powerGuardPass && clippingGuardPass && paprGuardPass;

            fprintf('  POST: EVM %.2f %% | ACPR %.2f dBc | RX %.2f dBFS | dRX %.2f dB | Sync %.4f | Accepted %d\n', ...
                post.evm_pct, post.acpr_dBc, post.rxPower_dBFS, metricsRows(rowCounter).RxPower_Delta_dB, ...
                post.syncMetric, metricsRows(rowCounter).IterationAccepted);

            % Store coefficients in long format for later inspection/export.
            for kCoeff = 1:numel(coeffCurrent)
                coeffCounter = coeffCounter + 1;
                coeffRows(coeffCounter) = createCoeffRowStruct(); %#ok<SAGROW>
                coeffRows(coeffCounter).TableRowID = rowCounter;
                coeffRows(coeffCounter).ModelID = string(modelID);
                coeffRows(coeffCounter).M = M;
                coeffRows(coeffCounter).K = K;
                coeffRows(coeffCounter).Ka = p.Ka;
                coeffRows(coeffCounter).La = p.La;
                coeffRows(coeffCounter).Kb = p.Kb;
                coeffRows(coeffCounter).Lb = p.Lb;
                coeffRows(coeffCounter).Mb = p.Mb;
                coeffRows(coeffCounter).Kc = p.Kc;
                coeffRows(coeffCounter).Lc = p.Lc;
                coeffRows(coeffCounter).Mc = p.Mc;
                coeffRows(coeffCounter).CoeffLabel = coeffLabels(kCoeff);
                coeffRows(coeffCounter).Iteration = iter;
                coeffRows(coeffCounter).CoeffIndex = kCoeff;
                coeffRows(coeffCounter).CoeffReal = real(coeffCurrent(kCoeff));
                coeffRows(coeffCounter).CoeffImag = imag(coeffCurrent(kCoeff));
                coeffRows(coeffCounter).CoeffAbs = abs(coeffCurrent(kCoeff));
                coeffRows(coeffCounter).CoeffPhase_rad = angle(coeffCurrent(kCoeff));
            end

            % Prepare next training source from the latest measured output.
            trainSourceNorm = normalizeRxToTx(post.rxAligned, txWaveform);

            % Early stopping logic.
            if metricsRows(rowCounter).IterationAccepted
                if post.evm_pct < bestLocalEVM - minEvmImprovement_pctPoints
                    bestLocalEVM = post.evm_pct;
                    noImproveCount = 0;
                else
                    noImproveCount = noImproveCount + 1;
                end
            else
                noImproveCount = noImproveCount + 1;
            end

            if noImproveCount >= patienceNoImprove
                fprintf('  Early stop: no meaningful EVM improvement for %d consecutive iterations.\n', patienceNoImprove);
                metricsRows(rowCounter).EarlyStop = true;
                break;
            end

        catch ME
            warning('Model %s iteration %d failed: %s', modelID, iter, ME.message);
            consecutiveHardFailures = consecutiveHardFailures + 1;
            if consecutiveHardFailures >= maxConsecutiveHardFailures
                warning('Model %s stopped after %d consecutive hard failures.', modelID, consecutiveHardFailures);
                break;
            else
                setSafeState(sdrTransmitter, idleGain_dB);
                pause(0.25);
                continue;
            end
        end

        setSafeState(sdrTransmitter, idleGain_dB);
        pause(0.25);
    end

    setSafeState(sdrTransmitter, idleGain_dB);
    pause(0.5);
    modelHistories{iModel} = history;
end

%% ========================================================================
%  BUILD TABLES AND SELECT BEST ITERATION
%% ========================================================================

metricsTable = struct2table(metricsRows);
if isempty(coeffRows)
    coeffTable = table();
else
    coeffTable = struct2table(coeffRows);
end

% Augment with fair equal-power comparison against the no-DPD Phase 1 sweep.
metricsTable = addOfficialNoDPDReferenceComparison(metricsTable, noDPDReferenceCsv, ...
    referenceRxPowerColumn, referenceMeterPowerColumn, referenceEVMColumn, referenceACPRColumn, ...
    referenceTxGainColumn, referenceAcceptedColumn, ...
    weightEqPowerEVM, weightEqPowerACPR, weightMeterEVM, weightPAPR, PAPR_tx_dB);

writetable(metricsTable, metricsCsvFile);
if ~isempty(coeffTable)
    writetable(coeffTable, coeffCsvFile);
end

if ismember('CompositeScore', metricsTable.Properties.VariableNames)
    validMask = metricsTable.Iteration > 0 & metricsTable.UsableCapture & ...
                metricsTable.PAPRGuardPass & metricsTable.ClippingGuardPass & ...
                isfinite(metricsTable.EVM_Post_pct) & isfinite(metricsTable.ACPR_Post_dBc) & ...
                isfinite(metricsTable.CompositeScore);
else
    validMask = metricsTable.Iteration > 0 & metricsTable.UsableCapture & ...
                metricsTable.PAPRGuardPass & metricsTable.ClippingGuardPass & ...
                isfinite(metricsTable.EVM_Post_pct) & isfinite(metricsTable.ACPR_Post_dBc);
end

if any(validMask)
    candidateRows = find(validMask);
    if ismember('CompositeScore', metricsTable.Properties.VariableNames)
        [~, locBest] = max(metricsTable.CompositeScore(candidateRows));
    else
        [~, locBest] = min(metricsTable.EVM_Post_pct(candidateRows));
    end
    bestGlobalRow = candidateRows(locBest);
    bestSelection = metricsTable(bestGlobalRow,:);
else
    warning('No fully usable DPD iteration found. Selecting lowest post-EVM among usable iterations.');
    usableMask = metricsTable.Iteration > 0 & metricsTable.UsableCapture & isfinite(metricsTable.EVM_Post_pct);
    if any(usableMask)
        candidateRows = find(usableMask);
        [~, locBest] = min(metricsTable.EVM_Post_pct(candidateRows));
        bestGlobalRow = candidateRows(locBest);
        bestSelection = metricsTable(bestGlobalRow,:);
    else
        error('No usable post-DPD capture found.');
    end
end

bestModelID = char(bestSelection.ModelID);
bestRowID = bestSelection.TableRowID;
bestCoeffs = rowCoeffs{bestRowID};
bestTxDPD = rowTxDPD{bestRowID};
bestPost = rowPostResult{bestRowID};

bestSummaryTable = bestSelection;
writetable(bestSummaryTable, bestCsvFile);

fprintf('\n===== BEST ITERATIVE DPD RESULT =====\n');
disp(bestSummaryTable);

%% ========================================================================
%  FIGURES: EVOLUTION OF ITERATIONS AND COEFFICIENTS
%% ========================================================================

try
    plotMetricEvolutionByModel(metricsTable, 'EVM_Post_pct', 'EVM RMS (%)', ...
        'Evolution of EVM across HILA iterations', ...
        fullfile(figuresDir, '01_EVM_Evolution_All_Models.png'));

    plotMetricEvolutionByModel(metricsTable, 'ACPR_Post_dBc', 'ACPR (dBc)', ...
        'Evolution of ACPR across HILA iterations', ...
        fullfile(figuresDir, '02_ACPR_Evolution_All_Models.png'));

    plotMetricEvolutionByModel(metricsTable, 'RxPower_Delta_dB', '\Delta RX power (dB)', ...
        'Evolution of RX power delta across HILA iterations', ...
        fullfile(figuresDir, '03_DeltaPower_Evolution_All_Models.png'));

    plotMetricEvolutionByModel(metricsTable, 'CoeffDeltaNorm', '||\Delta c||_2', ...
        'Evolution of coefficient update norm across HILA iterations', ...
        fullfile(figuresDir, '04_CoeffDeltaNorm_Evolution_All_Models.png'));

    plotMetricEvolutionByModel(metricsTable, 'PAPR_DPD_dB', 'PAPR (dB)', ...
        'Evolution of DPD waveform PAPR across HILA iterations', ...
        fullfile(figuresDir, '05_PAPR_Evolution_All_Models.png'));

    if ismember('DPD_EVM_Improvement_vsSameRxPower_pct', metricsTable.Properties.VariableNames)
        plotMetricEvolutionByModel(metricsTable, 'DPD_EVM_Improvement_vsSameRxPower_pct', 'EVM gain vs same-RX-power no-DPD (pct points)', ...
            'Same-RX-power EVM improvement across HILA iterations', ...
            fullfile(figuresDir, '05B_SameRxPower_EVM_Gain_All_Models.png'));
    end
    if ismember('DPD_ACPR_Improvement_vsSameRxPower_dB', metricsTable.Properties.VariableNames)
        plotMetricEvolutionByModel(metricsTable, 'DPD_ACPR_Improvement_vsSameRxPower_dB', 'ACPR gain vs same-RX-power no-DPD (dB)', ...
            'Same-RX-power ACPR improvement across HILA iterations', ...
            fullfile(figuresDir, '05C_SameRxPower_ACPR_Gain_All_Models.png'));
    end
catch ME
    warning('Could not create all-model figures: %s', ME.message);
end

try
    % Best model focused figure: EVM / ACPR / Delta power / Coeff update norm.
    maskBestModel = strcmp(metricsTable.ModelID, string(bestModelID));
    TbestModel = metricsTable(maskBestModel,:);
    TbestModel = sortrows(TbestModel, 'Iteration');

    hFigBest = figure('Name','Best model iteration evolution','Color','w');
    tiledlayout(4,1);

    nexttile;
    plot(TbestModel.Iteration, TbestModel.EVM_Post_pct, 'o-', 'LineWidth', 1.2); hold on;
    xline(bestSelection.Iteration, '--r', 'Best iter');
    grid on; xlabel('Iteration'); ylabel('EVM RMS (%)');
    title(sprintf('Best model %s: EVM evolution', bestModelID));

    nexttile;
    plot(TbestModel.Iteration, TbestModel.ACPR_Post_dBc, 'o-', 'LineWidth', 1.2); hold on;
    xline(bestSelection.Iteration, '--r', 'Best iter');
    grid on; xlabel('Iteration'); ylabel('ACPR (dBc)');
    title('ACPR evolution');

    nexttile;
    plot(TbestModel.Iteration, TbestModel.RxPower_Delta_dB, 'o-', 'LineWidth', 1.2); hold on;
    yline(-maxAllowedRxPowerDrop_dB, '--', 'Max drop');
    yline(maxAllowedRxPowerRise_dB, '--', 'Max rise');
    xline(bestSelection.Iteration, '--r', 'Best iter');
    grid on; xlabel('Iteration'); ylabel('\Delta RX power (dB)');
    title('Delta RX power evolution');

    nexttile;
    plot(TbestModel.Iteration, TbestModel.CoeffDeltaNorm, 'o-', 'LineWidth', 1.2); hold on;
    xline(bestSelection.Iteration, '--r', 'Best iter');
    grid on; xlabel('Iteration'); ylabel('||\Delta c||_2');
    title('Coefficient update norm evolution');

    saveas(hFigBest, fullfile(figuresDir, '06_BestModel_Iteration_Evolution.png'));
catch ME
    warning('Could not create best-model iteration figure: %s', ME.message);
end

try
    % Coefficient evolution of best model.
    bestRowsMask = strcmp(metricsTable.ModelID, string(bestModelID)) & metricsTable.Iteration > 0;
    TcoeffBest = metricsTable(bestRowsMask,:);
    TcoeffBest = sortrows(TcoeffBest, 'Iteration');
    iterList = TcoeffBest.Iteration(:).';
    nIterBest = numel(iterList);
    nCoeffBest = bestSelection.CoeffCount;
    absCoeffMat = nan(nCoeffBest, nIterBest);
    phaseCoeffMat = nan(nCoeffBest, nIterBest);
    for ii = 1:nIterBest
        coeffVec = rowCoeffs{TcoeffBest.TableRowID(ii)};
        L = min(length(coeffVec), nCoeffBest);
        absCoeffMat(1:L,ii) = abs(coeffVec(1:L));
        phaseCoeffMat(1:L,ii) = angle(coeffVec(1:L));
    end

    hFigCoeff = figure('Name','Best model coefficient evolution','Color','w');
    tiledlayout(3,1);

    nexttile;
    imagesc(iterList, 1:nCoeffBest, absCoeffMat);
    axis xy; colorbar; xlabel('Iteration'); ylabel('Coefficient index');
    title(sprintf('Best model %s: |c_k| evolution', bestModelID));

    nexttile;
    imagesc(iterList, 1:nCoeffBest, phaseCoeffMat);
    axis xy; colorbar; xlabel('Iteration'); ylabel('Coefficient index');
    title('Coefficient phase evolution (rad)');

    nexttile;
    plot(TbestModel.Iteration, TbestModel.CoeffNorm, 'o-', 'LineWidth', 1.2); hold on;
    plot(TbestModel.Iteration, TbestModel.CoeffDeltaNorm, 's-', 'LineWidth', 1.2);
    xline(bestSelection.Iteration, '--r', 'Best iter');
    grid on; xlabel('Iteration'); ylabel('Norm');
    legend('||c||_2','||\Delta c||_2','Location','best');
    title('Coefficient norms across iterations');

    saveas(hFigCoeff, fullfile(figuresDir, '07_BestModel_Coefficient_Evolution.png'));
catch ME
    warning('Could not create coefficient evolution figure: %s', ME.message);
end


try
    % Coefficient evolution as numerical traces for the best model.
    bestRowsMask2 = strcmp(metricsTable.ModelID, string(bestModelID)) & metricsTable.Iteration > 0;
    TcoeffTrace = metricsTable(bestRowsMask2,:);
    TcoeffTrace = sortrows(TcoeffTrace, 'Iteration');
    iterTrace = TcoeffTrace.Iteration(:).';
    nTrace = numel(iterTrace);
    nCoeffTrace = bestSelection.CoeffCount;
    coeffMatTrace = nan(nCoeffTrace, nTrace);
    for ii = 1:nTrace
        coeffVec = rowCoeffs{TcoeffTrace.TableRowID(ii)};
        L = min(length(coeffVec), nCoeffTrace);
        coeffMatTrace(1:L,ii) = coeffVec(1:L);
    end

    if nTrace > 0
        [~, ordCoeff] = sort(abs(coeffMatTrace(:,end)), 'descend');
        nShow = min(10, nCoeffTrace);
        idxShow = ordCoeff(1:nShow);

        hFigCoeffLines = figure('Name','Best model coefficient numerical traces','Color','w');
        tiledlayout(3,1);

        nexttile;
        hold on;
        for jj = 1:nShow
            plot(iterTrace, real(coeffMatTrace(idxShow(jj),:)), 'o-', 'LineWidth', 1.1, ...
                'DisplayName', sprintf('c%d', idxShow(jj)));
        end
        grid on; xlabel('Iteration'); ylabel('Real(c_k)');
        title(sprintf('Best model %s: real coefficient traces', bestModelID));
        legend('Location','bestoutside');

        nexttile;
        hold on;
        for jj = 1:nShow
            plot(iterTrace, imag(coeffMatTrace(idxShow(jj),:)), 'o-', 'LineWidth', 1.1, ...
                'DisplayName', sprintf('c%d', idxShow(jj)));
        end
        grid on; xlabel('Iteration'); ylabel('Imag(c_k)');
        title('Imaginary coefficient traces');

        nexttile;
        hold on;
        for jj = 1:nShow
            plot(iterTrace, abs(coeffMatTrace(idxShow(jj),:)), 'o-', 'LineWidth', 1.1, ...
                'DisplayName', sprintf('|c%d|', idxShow(jj)));
        end
        grid on; xlabel('Iteration'); ylabel('|c_k|');
        title('Magnitude coefficient traces');

        saveas(hFigCoeffLines, fullfile(figuresDir, '07B_BestModel_Coefficient_Numerical_Traces.png'));
    end
catch ME
    warning('Could not create coefficient numerical trace figure: %s', ME.message);
end


try
    % IQ constellation comparison: baseline vs best iteration.
    [refPre, eqPre] = getConstellationVectors(baseline.refSymb, baseline.eqSymb, plotMaxSymbols);
    [refPost, eqPost] = getConstellationVectors(bestPost.refSymb, bestPost.eqSymb, plotMaxSymbols);

    hFigIQ = figure('Name','IQ constellation comparison','Color','w');
    tiledlayout(1,2);

    nexttile;
    if ~isempty(refPre)
        plot(real(refPre), imag(refPre), 'r+', 'LineWidth', 1.2, 'MarkerSize', 6); hold on;
    end
    if ~isempty(eqPre)
        plot(real(eqPre), imag(eqPre), '.', 'MarkerSize', 8);
    end
    axis equal; grid on;
    xlabel('In-phase'); ylabel('Quadrature');
    title(sprintf('Baseline IQ | EVM %.2f %%', baseline.evm_pct));
    legend('Reference','Equalized received','Location','best');

    nexttile;
    if ~isempty(refPost)
        plot(real(refPost), imag(refPost), 'r+', 'LineWidth', 1.2, 'MarkerSize', 6); hold on;
    end
    if ~isempty(eqPost)
        plot(real(eqPost), imag(eqPost), '.', 'MarkerSize', 8);
    end
    axis equal; grid on;
    xlabel('In-phase'); ylabel('Quadrature');
    title(sprintf('Best DPD IQ | %s iter %d | EVM %.2f %%', ...
        bestModelID, bestSelection.Iteration, bestPost.evm_pct));
    legend('Reference','Equalized received','Location','best');

    saveas(hFigIQ, fullfile(figuresDir, '08_IQ_Constellation_Baseline_vs_Best.png'));
catch ME
    warning('Could not create IQ comparison figure: %s', ME.message);
end

try
    % PSD comparison to visualize ACPR improvement.
    hFigPSD = figure('Name','PSD comparison','Color','w');
    plotPSDComparison(baseline.rxAligned, bestPost.rxAligned, sampleRate, baseline.acpr_dBc, bestPost.acpr_dBc, bestModelID, bestSelection.Iteration);
    saveas(hFigPSD, fullfile(figuresDir, '08B_PSD_Baseline_vs_Best.png'));
catch ME
    warning('Could not create PSD comparison figure: %s', ME.message);
end

try
    % AM/AM and AM/PM comparison: baseline vs best DPD.
    hFigAM = figure('Name','AMAM AMPM comparison','Color','w');
    plotAMAM_AMPM(txWaveform, bestTxDPD, baseline.rxAligned, bestPost.rxAligned);
    saveas(hFigAM, fullfile(figuresDir, '09_AMAM_AMPM_Baseline_vs_Best.png'));
catch ME
    warning('Could not create AM/AM AM/PM figure: %s', ME.message);
end

try
    if exist("fidMeterRaw","var") && fidMeterRaw > 0
        fclose(fidMeterRaw);
        fidMeterRaw = -1;
    end
catch
end

%% ========================================================================
%  SAVE FINAL MAT
%% ========================================================================

save(matFile, ...
    'cfgDLFRC','cfgEVM','sampleRate','powerScaleFactor', ...
    'fixedTxGain_Pluto','fixedRxGain_Pluto','plutoOutEstimated_dBm','plutoOutCalibrationMode', ...
    'noDPDReferenceCsv','weightEqPowerEVM','weightEqPowerACPR','weightMeterEVM','weightPAPR', ...
    'fixedDsaSteps_Metadata','fixedDsaAtten_dB_Metadata', ...
    'txWaveform','baseline', ...
    'gmpModels','maxHilaIterations','coeffBlendMu', ...
    'regularizationLambdaRel','minTrainingAmplitudeRatio', ...
    'maxPredistortedPeakRatio','maxAllowedDpdPAPR_Extra_dB', ...
    'maxAllowedRxPowerDrop_dB','maxAllowedRxPowerRise_dB', ...
    'minSyncMetric','digitalRxSaturationLimit_dBFS', ...
    'metricsTable','coeffTable','bestSummaryTable', ...
    'rowCoeffs','rowTxDPD','rowPostResult','bestGlobalRow', ...
    'bestModelID','bestCoeffs','bestTxDPD','bestPost');

setSafeState(sdrTransmitter, idleGain_dB);

fprintf('\n===== EXP015 COMPLETE =====\n');
fprintf('Output root           : %s\n', outputRoot);
fprintf('Metrics CSV           : %s\n', metricsCsvFile);
fprintf('Coefficients CSV      : %s\n', coeffCsvFile);
fprintf('Best selection CSV    : %s\n', bestCsvFile);
if exist('csvMeterRawFile','var'); fprintf('STM32 raw CSV         : %s\n', csvMeterRawFile); end
fprintf('MAT file              : %s\n', matFile);
fprintf('Figures dir           : %s\n', figuresDir);

%% ========================================================================
%  LOCAL FUNCTIONS
%% ========================================================================

function s = createMetricsRowStruct()
    s = struct( ...
        'TableRowID', NaN, ...
        'ModelID', string(missing), ...
        'M', NaN, ...
        'K', NaN, ...
        'Ka', NaN, ...
        'La', NaN, ...
        'Kb', NaN, ...
        'Lb', NaN, ...
        'Mb', NaN, ...
        'Kc', NaN, ...
        'Lc', NaN, ...
        'Mc', NaN, ...
        'Iteration', NaN, ...
        'TxGain_Pluto_dB', NaN, ...
        'RxGain_Pluto_dB', NaN, ...
        'PlutoOutEstimated_dBm', NaN, ...
        'PlutoOutCalibrationMode', string(missing), ...
        'TrainSamples', NaN, ...
        'CondEstimate', NaN, ...
        'CoeffCount', NaN, ...
        'MatrixBuildTime_s', NaN, ...
        'LSSolveTime_s', NaN, ...
        'DPDApplyTime_s', NaN, ...
        'CoeffNorm', NaN, ...
        'CoeffDeltaNorm', NaN, ...
        'PAPR_DPD_dB', NaN, ...
        'PeakRatio_DPD_to_Original', NaN, ...
        'PAPRGuardPass', false, ...
        'EVM_Pre_pct', NaN, ...
        'EVM_Post_pct', NaN, ...
        'EVM_Improvement_pct_points', NaN, ...
        'ACPR_Pre_dBc', NaN, ...
        'ACPR_Post_dBc', NaN, ...
        'ACPR_Improvement_dB', NaN, ...
        'RxPower_Pre_dBFS', NaN, ...
        'RxPower_Post_dBFS', NaN, ...
        'RxPower_Delta_dB', NaN, ...
        'MeterPower_DPD_dBm', NaN, ...
        'MeterVoltage_DPD_V', NaN, ...
        'MeterADC_DPD_raw', NaN, ...
        'MeterNValid', NaN, ...
        'PowerGuardPass', false, ...
        'SyncMetric_Post', NaN, ...
        'FreqOffset_Hz', NaN, ...
        'PostCaptureAttempts', NaN, ...
        'PostEVMRetryFailed', false, ...
        'ClippingGuardPass', false, ...
        'IterationAccepted', false, ...
        'EarlyStop', false, ...
        'UsableCapture', false);
end

function s = createCoeffRowStruct()
    s = struct( ...
        'TableRowID', NaN, ...
        'ModelID', string(missing), ...
        'M', NaN, ...
        'K', NaN, ...
        'Ka', NaN, ...
        'La', NaN, ...
        'Kb', NaN, ...
        'Lb', NaN, ...
        'Mb', NaN, ...
        'Kc', NaN, ...
        'Lc', NaN, ...
        'Mc', NaN, ...
        'Iteration', NaN, ...
        'TxGain_Pluto_dB', NaN, ...
        'RxGain_Pluto_dB', NaN, ...
        'PlutoOutEstimated_dBm', NaN, ...
        'PlutoOutCalibrationMode', string(missing), ...
        'CoeffIndex', NaN, ...
        'CoeffLabel', string(missing), ...
        'CoeffReal', NaN, ...
        'CoeffImag', NaN, ...
        'CoeffAbs', NaN, ...
        'CoeffPhase_rad', NaN);
end

function rxNorm = normalizeRxToTx(rxAligned, txRef)
    rxAligned = rxAligned(:);
    txRef = txRef(:);
    L = min(length(rxAligned), length(txRef));
    rxAligned = rxAligned(1:L);
    txRef = txRef(1:L);
    alpha = (rxAligned' * txRef) / (rxAligned' * rxAligned + eps);
    rxNorm = alpha * rxAligned;
end

function plotMetricEvolutionByModel(T, metricName, yLabelText, titleText, savePath)
    modelIDs = unique(T.ModelID, 'stable');
    hFig = figure('Color','w');
    hold on;
    for i = 1:numel(modelIDs)
        mask = strcmp(T.ModelID, modelIDs(i));
        Tm = T(mask,:);
        Tm = sortrows(Tm, 'Iteration');
        y = Tm.(metricName);
        x = Tm.Iteration;
        plot(x, y, 'o-', 'LineWidth', 1.2, 'DisplayName', char(modelIDs(i)));
    end
    grid on;
    xlabel('Iteration');
    ylabel(yLabelText);
    title(titleText);
    legend('Location','best');
    saveas(hFig, savePath);
end

function result = captureAndMeasureWithRetry( ...
    rxObj, txReference, cfgDL, cfgEVM, sampleRate, ...
    captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
    maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
    alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign, ...
    rawDir, saveRawCaptures, label, txGain, rxGain, dsaSteps, dsaAtten)

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
            rawFile = fullfile(rawDir, sprintf('%s_tx_%+05.2fdB_rx_%+05.2fdB_dsa_%02.0f_attempt_%d.mat', ...
                label, txGain, rxGain, dsaSteps, attempt));
            save(rawFile, 'rxCapture', 'txGain', 'rxGain', 'dsaSteps', 'dsaAtten', 'attempt');
        end

        try
            [alignInfo, alignedData] = robustAlignTxRxForDPD( ...
                txReference, rxCapture, sampleRate, ...
                alignDecimationFactor, fineSearchHalfWindow_samples, ...
                phaseFitMagnitudeThreshold, numFramesForAlign);
        catch ME
            fprintf('    Robust alignment failed: %s\n', ME.message);
            continue;
        end

        rxAligned = alignedData.y_cfo_corrected(:);
        syncMetric = alignInfo.syncMetric;
        freqOffset = alignInfo.freqOffset_Hz;
        rxPower_dBFS = alignInfo.rxPower_dBFS;
        peakRx_dBFS = alignInfo.peakRx_dBFS;

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
            evm_pct, acpr_dBc, rxPower_dBFS, peakRx_dBFS, syncMetric, alignInfo.nmse_dB);

        candidate = initResultStruct();
        candidate.usable = true;
        candidate.retryFailed = false;
        candidate.attemptCount = attempt;
        candidate.evm_pct = evm_pct;
        candidate.acpr_dBc = acpr_dBc;
        candidate.rxPower_dBFS = rxPower_dBFS;
        candidate.peakRx_dBFS = peakRx_dBFS;
        candidate.nmse_aligned_dB = alignInfo.nmse_dB;
        candidate.waveformEVM_pct = alignInfo.waveformEVM_pct;
        candidate.txPower_dBFS = 10*log10(mean(abs(txReference(:)).^2) + eps);
        candidate.syncMetric = syncMetric;
        candidate.freqOffset_Hz = freqOffset;
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
        else
            fprintf('    Rejected attempt: EVM invalid or above %.2f %%.\n', evmRetryThreshold_pct);
        end
    end

    if ~best.usable || ~isfinite(best.evm_pct) || best.evm_pct >= evmRetryThreshold_pct || ...
            ~isfinite(best.syncMetric) || best.syncMetric < minSyncMetric
        result = initResultStruct();
        result.usable = false;
        result.retryFailed = true;
        result.attemptCount = maxCaptureAttempts;
        result.evm_pct = NaN;
        result.acpr_dBc = NaN;
        result.rxPower_dBFS = NaN;
        result.txPower_dBFS = 10*log10(mean(abs(txReference(:)).^2) + eps);
        result.syncMetric = best.syncMetric;
        result.freqOffset_Hz = NaN;
        fprintf('    Datum killed after %d attempts: no valid sync/EVM below %.2f %%.\n', ...
            maxCaptureAttempts, evmRetryThreshold_pct);
        return;
    end

    result = best;
    result.attemptCount = maxCaptureAttempts;
    result.retryFailed = false;
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
    s.txPower_dBFS = NaN;
    s.meterPower_dBm = NaN;
    s.meterVoltage_V = NaN;
    s.meterADC_raw = NaN;
    s.meterNValid = NaN;
    s.syncMetric = NaN;
    s.freqOffset_Hz = NaN;
    s.rxAligned = [];
    s.rawCapture = [];
    s.eqSymb = [];
    s.refSymb = [];
end


function [alignInfo, alignedData] = robustAlignTxRxForDPD(xTx, yRx, Fs, D, fineHalfWin, magThrRel, numFramesForAlign)
    %#ok<INUSD>
    % EXP015 / EXP008 result: best alignment mode is NORMAL_NO_CFO.
    % This function therefore performs:
    %   1) coarse decimated correlation
    %   2) fine integer-delay search
    %   3) scalar complex-gain normalization
    % and intentionally DOES NOT apply external CFO correction.

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

function [rx_aligned, freqOffset, syncMetric] = synchronizeFineXcorr(txWaveform, rxCapture, cfgDL)
    rx_aligned = [];
    freqOffset = 0;
    syncMetric = 0;

    try
        sampleRate = cfgDL.SampleRate;
        txWaveform = txWaveform(:);
        rxCapture  = rxCapture(:);
        Ltx = length(txWaveform);
        Lrx = length(rxCapture);

        if Lrx < Ltx
            warning('RX capture shorter than TX waveform.');
            return;
        end

        Lref = min(120000, Ltx);
        txRef = txWaveform(1:Lref);

        [c, lags] = xcorr(rxCapture, txRef);
        [peakVal, idxMax] = max(abs(c));
        delay = lags(idxMax);

        startIdx = delay + 1;
        startIdx = max(1, startIdx);

        if startIdx + Ltx - 1 > Lrx
            startIdx = Lrx - Ltx + 1;
        end

        if startIdx < 1 || startIdx + Ltx - 1 > Lrx
            return;
        end

        rxSegForMetric = rxCapture(startIdx:startIdx+Lref-1);
        syncMetric = peakVal / sqrt(sum(abs(rxSegForMetric).^2)*sum(abs(txRef).^2) + eps);

        rx_aligned = rxCapture(startIdx:startIdx + Ltx - 1);

        z = rx_aligned .* conj(txWaveform);
        valid = abs(txWaveform) > 0.05 * max(abs(txWaveform));

        if nnz(valid) > 1000
            phaseErr = unwrap(angle(z(valid)));
            n = (0:length(phaseErr)-1).';
            p = polyfit(n, phaseErr, 1);
            freqOffset = p(1) * sampleRate / (2*pi);
        else
            freqOffset = 0;
        end

        if ~isfinite(freqOffset) || abs(freqOffset) > 0.25*sampleRate
            freqOffset = 0;
        end

    catch ME
        warning('Error in synchronizeFineXcorr: %s', ME.message);
        rx_aligned = [];
        freqOffset = 0;
        syncMetric = 0;
    end
end

function [Xfit, yfit, idxTrain, labels] = buildGMPTrainingSet(rx_norm, tx_ref, p, minAmpRatio)
    rx_norm = rx_norm(:);
    tx_ref = tx_ref(:);

    L = min(length(rx_norm), length(tx_ref));
    rx_norm = rx_norm(1:L);
    tx_ref = tx_ref(1:L);

    [X, nStart, nEnd, labels] = buildGMPMatrix(rx_norm, p);
    y = tx_ref(nStart:nEnd);

    amp = abs(rx_norm(nStart:nEnd));
    ampMax = max(amp);

    if ampMax <= 0 || ~isfinite(ampMax)
        error('Invalid RX amplitude for GMP-DPD training.');
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

function [X, nStart, nEnd, labels] = buildGMPMatrix(signal, p)
    % Build a reduced generalized-memory-polynomial basis.
    %
    % Aligned branch:
    %   x[n-l] * |x[n-l]|^(2k), k = 0,...,Ka-1
    %
    % Lagging-envelope branch:
    %   x[n-l] * |x[n-l-m]|^(2k), k = 1,...,Kb
    %
    % Leading-envelope branch:
    %   x[n-l] * |x[n-l+m]|^(2k), k = 1,...,Kc

    signal = signal(:);
    L = length(signal);

    validateGMPParameters(p);

    maxDelay = max([p.La-1, p.Lb-1+p.Mb, 0]);
    maxAdvance = p.Mc;

    nStart = 1 + maxDelay;
    nEnd = L - maxAdvance;

    if nEnd < nStart
        error('Signal is too short for the selected GMP delays/advances.');
    end

    N = nEnd - nStart + 1;
    nCoeff = p.Ka*p.La + p.Kb*p.Lb*p.Mb + p.Kc*p.Lc*p.Mc;

    X = complex(zeros(N, nCoeff));
    labels = strings(nCoeff,1);
    col = 1;

    % A branch: aligned Memory Polynomial terms.
    for l = 0:p.La-1
        s = signal(nStart-l:nEnd-l);
        for k = 0:p.Ka-1
            X(:,col) = s .* abs(s).^(2*k);
            labels(col) = sprintf("A_l%d_ord%d", l, 2*k+1);
            col = col + 1;
        end
    end

    % B branch: lagging-envelope cross terms.
    for l = 0:p.Lb-1
        sComplex = signal(nStart-l:nEnd-l);
        for m = 1:p.Mb
            sEnvelope = signal(nStart-l-m:nEnd-l-m);
            for k = 1:p.Kb
                X(:,col) = sComplex .* abs(sEnvelope).^(2*k);
                labels(col) = sprintf("B_l%d_m%d_ord%d", l, m, 2*k+1);
                col = col + 1;
            end
        end
    end

    % C branch: leading-envelope cross terms.
    for l = 0:p.Lc-1
        sComplex = signal(nStart-l:nEnd-l);
        for m = 1:p.Mc
            sEnvelope = signal(nStart-l+m:nEnd-l+m);
            for k = 1:p.Kc
                X(:,col) = sComplex .* abs(sEnvelope).^(2*k);
                labels(col) = sprintf("C_l%d_m%d_ord%d", l, m, 2*k+1);
                col = col + 1;
            end
        end
    end

    if col-1 ~= nCoeff
        error('Internal GMP coefficient-count mismatch: expected %d, built %d.', nCoeff, col-1);
    end
end

function y = applyGMP(x, coeffs, p)
    x = x(:);
    y = x;

    [X, nStart, nEnd] = buildGMPMatrix(x, p);

    if numel(coeffs) ~= size(X,2)
        error('GMP coefficient vector has %d elements; expected %d.', ...
            numel(coeffs), size(X,2));
    end

    y(nStart:nEnd) = X * coeffs;

    % Edge samples remain equal to the original signal because the full GMP
    % basis is unavailable at the beginning/end of the finite waveform.
    if nStart > 1
        y(1:nStart-1) = x(1:nStart-1);
    end
    if nEnd < length(x)
        y(nEnd+1:end) = x(nEnd+1:end);
    end
end

function validateGMPParameters(p)
    required = ["Ka","La","Kb","Lb","Mb","Kc","Lc","Mc"];
    for ii = 1:numel(required)
        name = required(ii);
        if ~isfield(p, name)
            error('Missing GMP parameter: %s', name);
        end
        value = p.(name);
        if ~isscalar(value) || ~isfinite(value) || value < 0 || value ~= floor(value)
            error('GMP parameter %s must be a nonnegative integer.', name);
        end
    end

    if p.Ka < 1 || p.La < 1
        error('Ka and La must be at least 1.');
    end

    if p.Kb > 0 && (p.Lb < 1 || p.Mb < 1)
        error('Lb and Mb must be at least 1 when Kb > 0.');
    end
    if p.Kb == 0 && (p.Lb ~= 0 || p.Mb ~= 0)
        error('Set Lb = Mb = 0 when Kb = 0.');
    end

    if p.Kc > 0 && (p.Lc < 1 || p.Mc < 1)
        error('Lc and Mc must be at least 1 when Kc > 0.');
    end
    if p.Kc == 0 && (p.Lc ~= 0 || p.Mc ~= 0)
        error('Set Lc = Mc = 0 when Kc = 0.');
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
    acpr_dBc = NaN;
    try
        x = x(:);
        if isempty(x) || length(x) < 1024
            return;
        end
        Ntarget = 614400;
        N = min(Ntarget, length(x));
        x = x(1:N);
        x = x - mean(x);
        winLen = min(4096, N);
        if winLen < 128
            return;
        end
        nfft = max(4096, 2^nextpow2(min(N, 262144)));
        [pxx, f] = pwelch(x, hamming(winLen), [], nfft, fs, 'centered');
        mainIdx = abs(f) <= bw/2;
        adjLowIdx  = (f >= -1.5*bw) & (f < -0.5*bw);
        adjHighIdx = (f >  0.5*bw) & (f <= 1.5*bw);
        if ~any(mainIdx) || (~any(adjLowIdx) && ~any(adjHighIdx))
            return;
        end
        pMain = trapz(f(mainIdx), pxx(mainIdx));
        pAdj = 0;
        if any(adjLowIdx),  pAdj = pAdj + trapz(f(adjLowIdx),  pxx(adjLowIdx)); end
        if any(adjHighIdx), pAdj = pAdj + trapz(f(adjHighIdx), pxx(adjHighIdx)); end
        if pMain <= 0 || pAdj <= 0 || ~isfinite(pMain) || ~isfinite(pAdj)
            return;
        end
        acpr_dBc = 10*log10(pAdj / pMain);
    catch ME
        warning('Error in computeACPRCentered: %s', ME.message);
        acpr_dBc = NaN;
    end
end

function metricsTable = addOfficialNoDPDReferenceComparison(metricsTable, refCsv, refRxCol, refMeterCol, refEvmCol, refAcprCol, refTxCol, refAcceptedCol, wEqEvm, wEqAcpr, wMeterEvm, wPAPR, paprBase)
    % Adds fair comparison columns against the official no-DPD Block-A sweep.
    % Two comparisons are computed:
    %   1) same RX digital power (RxPower_dBFS)
    %   2) same detector/VGU/IF-observation power (Power_mean_dB_stm32)
    % The second one is useful because it is closer to a physical output-power
    % comparison, not only a Pluto RX digital-level comparison.

    n = height(metricsTable);
    metricsTable.RefNoDPD_EVM_AtSameRxPower_pct = nan(n,1);
    metricsTable.RefNoDPD_ACPR_AtSameRxPower_dBc = nan(n,1);
    metricsTable.RefNoDPD_TxGain_AtSameRxPower_dB = nan(n,1);
    metricsTable.DPD_EVM_Improvement_vsSameRxPower_pct = nan(n,1);
    metricsTable.DPD_ACPR_Improvement_vsSameRxPower_dB = nan(n,1);

    metricsTable.RefNoDPD_EVM_AtSameMeterPower_pct = nan(n,1);
    metricsTable.RefNoDPD_ACPR_AtSameMeterPower_dBc = nan(n,1);
    metricsTable.RefNoDPD_TxGain_AtSameMeterPower_dB = nan(n,1);
    metricsTable.DPD_EVM_Improvement_vsSameMeterPower_pct = nan(n,1);
    metricsTable.DPD_ACPR_Improvement_vsSameMeterPower_dB = nan(n,1);

    metricsTable.CompositeScore = nan(n,1);

    if isempty(refCsv)
        warning('No official no-DPD reference CSV provided. Composite selection falls back to raw EVM.');
        return;
    end

    refPath = refCsv;
    if ~exist(refPath, 'file')
        altPath = fullfile(fileparts(mfilename('fullpath')), refCsv);
        if exist(altPath, 'file')
            refPath = altPath;
        else
            warning('Official no-DPD reference CSV not found: %s', refCsv);
            return;
        end
    end

    Tref = readtable(refPath);
    needed = {refRxCol, refEvmCol, refAcprCol, refTxCol};
    for kk = 1:numel(needed)
        if ~ismember(needed{kk}, Tref.Properties.VariableNames)
            warning('Reference CSV does not contain required column: %s', needed{kk});
            return;
        end
    end

    if ismember(refAcceptedCol, Tref.Properties.VariableNames)
        Tref = Tref(logical(Tref.(refAcceptedCol)),:);
    end

    % Same-RX-power comparison.
    [evmRx, acprRx, txRx] = interpReferenceByColumn(Tref, refRxCol, refEvmCol, refAcprCol, refTxCol, metricsTable.RxPower_Post_dBFS);
    metricsTable.RefNoDPD_EVM_AtSameRxPower_pct = evmRx;
    metricsTable.RefNoDPD_ACPR_AtSameRxPower_dBc = acprRx;
    metricsTable.RefNoDPD_TxGain_AtSameRxPower_dB = txRx;
    metricsTable.DPD_EVM_Improvement_vsSameRxPower_pct = evmRx - metricsTable.EVM_Post_pct;
    % ACPR is negative. Improvement is positive if DPD is more negative.
    metricsTable.DPD_ACPR_Improvement_vsSameRxPower_dB = acprRx - metricsTable.ACPR_Post_dBc;

    % Same-meter/VGU/IF-observation-power comparison, if available.
    if ismember(refMeterCol, Tref.Properties.VariableNames) && ismember('MeterPower_DPD_dBm', metricsTable.Properties.VariableNames)
        [evmM, acprM, txM] = interpReferenceByColumn(Tref, refMeterCol, refEvmCol, refAcprCol, refTxCol, metricsTable.MeterPower_DPD_dBm);
        metricsTable.RefNoDPD_EVM_AtSameMeterPower_pct = evmM;
        metricsTable.RefNoDPD_ACPR_AtSameMeterPower_dBc = acprM;
        metricsTable.RefNoDPD_TxGain_AtSameMeterPower_dB = txM;
        metricsTable.DPD_EVM_Improvement_vsSameMeterPower_pct = evmM - metricsTable.EVM_Post_pct;
        metricsTable.DPD_ACPR_Improvement_vsSameMeterPower_dB = acprM - metricsTable.ACPR_Post_dBc;
    end

    paprPenalty = max(0, metricsTable.PAPR_DPD_dB - paprBase);

    % Composite score: prioritize equal-RX-power EVM, then ACPR, then meter-power EVM if available.
    metricsTable.CompositeScore = ...
        wEqEvm   * metricsTable.DPD_EVM_Improvement_vsSameRxPower_pct + ...
        wEqAcpr  * metricsTable.DPD_ACPR_Improvement_vsSameRxPower_dB + ...
        wMeterEvm* fillmissing(metricsTable.DPD_EVM_Improvement_vsSameMeterPower_pct, 'constant', 0) - ...
        wPAPR    * paprPenalty;
end

function [evmInterp, acprInterp, txInterp] = interpReferenceByColumn(Tref, xCol, evmCol, acprCol, txCol, xQuery)
    evmInterp = nan(size(xQuery));
    acprInterp = nan(size(xQuery));
    txInterp = nan(size(xQuery));

    x = Tref.(xCol);
    evm = Tref.(evmCol);
    acpr = Tref.(acprCol);
    tx = Tref.(txCol);

    valid = isfinite(x) & isfinite(evm) & isfinite(acpr) & isfinite(tx);
    x = x(valid); evm = evm(valid); acpr = acpr(valid); tx = tx(valid);
    if numel(x) < 4
        return;
    end

    [xSort, idx] = sort(x);
    evmSort = evm(idx);
    acprSort = acpr(idx);
    txSort = tx(idx);
    [xUnique, ia] = unique(xSort, 'stable');
    evmUnique = evmSort(ia);
    acprUnique = acprSort(ia);
    txUnique = txSort(ia);

    inRange = isfinite(xQuery) & xQuery >= min(xUnique) & xQuery <= max(xUnique);
    evmInterp(inRange) = interp1(xUnique, evmUnique, xQuery(inRange), 'pchip');
    acprInterp(inRange) = interp1(xUnique, acprUnique, xQuery(inRange), 'pchip');
    txInterp(inRange) = interp1(xUnique, txUnique, xQuery(inRange), 'pchip');
end

function [refVec, eqVec] = getConstellationVectors(refSymbCell, eqSymbCell, maxSymbols)
    refVec = [];
    eqVec = [];
    try
        if iscell(refSymbCell)
            for k = 1:numel(refSymbCell)
                if ~isempty(refSymbCell{k})
                    refVec = refSymbCell{k}(:);
                    break;
                end
            end
        elseif ~isempty(refSymbCell)
            refVec = refSymbCell(:);
        end

        if iscell(eqSymbCell)
            for k = 1:numel(eqSymbCell)
                if ~isempty(eqSymbCell{k})
                    eqVec = eqSymbCell{k}(:);
                    break;
                end
            end
        elseif ~isempty(eqSymbCell)
            eqVec = eqSymbCell(:);
        end

        if ~isempty(refVec) && length(refVec) > maxSymbols
            idx = round(linspace(1, length(refVec), maxSymbols));
            refVec = refVec(idx);
        end
        if ~isempty(eqVec) && length(eqVec) > maxSymbols
            idx = round(linspace(1, length(eqVec), maxSymbols));
            eqVec = eqVec(idx);
        end
    catch
        refVec = [];
        eqVec = [];
    end
end

function plotAMAM_AMPM(txOriginal, txDPD, rxPre, rxPost)
    txOriginal = txOriginal(:);
    txDPD = txDPD(:);
    rxPre = rxPre(:);
    rxPost = rxPost(:);
    L = min([length(txOriginal), length(txDPD), length(rxPre), length(rxPost), 120000]);
    txOriginal = txOriginal(1:L);
    txDPD = txDPD(1:L);
    rxPre = rxPre(1:L);
    rxPost = rxPost(1:L);

    % Align gains to the original TX for visual comparison.
    alphaPre = (rxPre' * txOriginal) / (rxPre' * rxPre + eps);
    alphaPost = (rxPost' * txOriginal) / (rxPost' * rxPost + eps);
    rxPreScaled = alphaPre * rxPre;
    rxPostScaled = alphaPost * rxPost;

    inputAmp = abs(txOriginal);
    inputAmpNorm = inputAmp / (max(inputAmp) + eps);
    commonScale = max([abs(txOriginal); abs(txDPD); abs(rxPreScaled); abs(rxPostScaled)] + eps);
    yPre = abs(rxPreScaled) / commonScale;
    yDPD = abs(txDPD) / commonScale;
    yPost = abs(rxPostScaled) / commonScale;
    phasePre = angle(rxPreScaled .* conj(txOriginal));
    phaseDPD = angle(txDPD .* conj(txOriginal));
    phasePost = angle(rxPostScaled .* conj(txOriginal));

    % EXP015 v1:
    % AM/AM and AM/PM are shown as scatter clouds only.
    % The previous binned mean trend lines were removed to avoid over-
    % interpreting smoothing artifacts in the final visual comparison.

    tiledlayout(2,1);

    nexttile;
    scatter(inputAmpNorm, yPre, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03); hold on;
    scatter(inputAmpNorm, yDPD, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    scatter(inputAmpNorm, yPost, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    grid on;
    xlabel('Normalized input amplitude');
    ylabel('Normalized amplitude');
    title('AM/AM comparison (scatter cloud only)');
    legend('Chain output w/o DPD','DPD waveform','Chain output with DPD','Location','best');

    nexttile;
    scatter(inputAmpNorm, phasePre, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03); hold on;
    scatter(inputAmpNorm, phaseDPD, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    scatter(inputAmpNorm, phasePost, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    grid on;
    xlabel('Normalized input amplitude');
    ylabel('Phase shift (rad)');
    title('AM/PM comparison (scatter cloud only)');
    legend('Chain output w/o DPD','DPD waveform','Chain output with DPD','Location','best');
end

function [meanAmp, meanPhase] = binAverage(xNorm, yAmp, yPhase, edges)
    meanAmp = nan(length(edges)-1,1);
    meanPhase = nan(length(edges)-1,1);
    for ii = 1:length(edges)-1
        idx = xNorm >= edges(ii) & xNorm < edges(ii+1);
        if nnz(idx) > 20
            meanAmp(ii) = mean(yAmp(idx), 'omitnan');
            meanPhase(ii) = mean(yPhase(idx), 'omitnan');
        end
    end
end

function plotPSDComparison(rxBaseline, rxBest, fs, acprBase, acprBest, bestModelID, bestIter)
    rxBaseline = rxBaseline(:);
    rxBest = rxBest(:);
    N = min([length(rxBaseline), length(rxBest), 262144]);
    rxBaseline = rxBaseline(1:N);
    rxBest = rxBest(1:N);

    nfft = 8192;
    win = hamming(4096);
    [P0,f] = pwelch(rxBaseline, win, [], nfft, fs, 'centered');
    [P1,~] = pwelch(rxBest, win, [], nfft, fs, 'centered');
    P0dB = 10*log10(P0 + eps);
    P1dB = 10*log10(P1 + eps);
    % Normalize to each in-band peak for easier visual ACPR comparison.
    P0dB = P0dB - max(P0dB);
    P1dB = P1dB - max(P1dB);

    plot(f/1e6, P0dB, 'LineWidth', 1.4); hold on;
    plot(f/1e6, P1dB, 'LineWidth', 1.4);
    xline(-10, '--k'); xline(10, '--k');
    xline(-30, ':k'); xline(30, ':k');
    grid on;
    xlabel('Frequency (MHz)');
    ylabel('PSD (dB, normalized)');
    title(sprintf('PSD comparison | Baseline ACPR %.2f dBc | Best %s iter %d ACPR %.2f dBc', ...
        acprBase, bestModelID, bestIter, acprBest));
    legend('Baseline no DPD','Best DPD','Main-band edge','Main-band edge','Adj-band marker','Adj-band marker','Location','best');
end


function [pOut, modeUsed] = estimatePlutoOutputFromDPDV2Baseline(txGain, baselineDir)
    pOut = 0.9935446912 .* txGain - 8.1924257506;
    modeUsed = "fallback_linear_pluto_curve";

    try
        f = fullfile(baselineDir, "Baseline_Power_Tx_Pluto.csv");
        if ~exist(f, "file")
            return;
        end
        T = readtable(f);
        names = string(T.Properties.VariableNames);

        txCol = find(contains(lower(names), "tx") & contains(lower(names), "gain"), 1);
        pCol = find(contains(lower(names), "dbm") | contains(lower(names), "potencia") | contains(lower(names), "power"), 1);
        if isempty(txCol)
            txCol = 1;
        end
        if isempty(pCol)
            pCol = min(2, width(T));
        end

        tx = T{:,txCol};
        pp = T{:,pCol};
        valid = isfinite(tx) & isfinite(pp);
        tx = tx(valid);
        pp = pp(valid);
        [tx, ord] = sort(tx);
        pp = pp(ord);

        if numel(tx) >= 2
            pOut = interp1(tx, pp, txGain, "linear", "extrap");
            modeUsed = "csv_interpolation:" + string(f);
        end
    catch ME
        warning("Could not read Pluto baseline. Fallback linear curve used: %s", ME.message);
    end
end

function latestFile = findLatestOfficialNoDPDReference(dataDir)
    latestFile = "";
    try
        files = dir(fullfile(dataDir, "**", "*OFFICIAL_NODPD_REFERENCE*.csv"));
        if isempty(files)
            warning("No OFFICIAL_NODPD_REFERENCE CSV found in %s.", dataDir);
            return;
        end
        % Prefer EXP009F DPDV2 TXDSA5 reference if present.
        names = string({files.name});
        prefer = contains(names, "EXP009F") | contains(names, "NODPD_FULLSWEEP");
        if any(prefer)
            files = files(prefer);
        end
        [~, idx] = max([files.datenum]);
        latestFile = string(fullfile(files(idx).folder, files(idx).name));
        fprintf("Official no-DPD reference auto-detected:\n  %s\n", latestFile);
    catch ME
        warning("Could not auto-detect official no-DPD reference: %s", ME.message);
        latestFile = "";
    end
end

function result = attachMeterMeasurement(result, stm, useSTM32PowerMeter, txGain, rxGain, nSamples, fidMeterRaw, label, iteration)
    result.meterPower_dBm = NaN;
    result.meterVoltage_V = NaN;
    result.meterADC_raw = NaN;
    result.meterNValid = 0;

    if ~useSTM32PowerMeter || isempty(stm)
        fprintf("  STM32 meter skipped: disabled or serial object empty.\n");
        return;
    end

    try
        flush(stm);
        pause(0.05);

        cmd = sprintf("MEAS,%.2f,%d", txGain, nSamples);
        fprintf("  Sending STM32 command: %s\n", cmd);
        writeline(stm, cmd);

        [pVals, vVals, adcVals, nValid, nInvalid] = readSTM32PowerBlock_EXP015( ...
            stm, fidMeterRaw, string(label), iteration, txGain, rxGain);

        result.meterNValid = nValid;
        if ~isempty(pVals)
            result.meterPower_dBm = mean(pVals, "omitnan");
        end
        if ~isempty(vVals)
            result.meterVoltage_V = mean(vVals, "omitnan");
        end
        if ~isempty(adcVals)
            result.meterADC_raw = mean(adcVals, "omitnan");
        end

        fprintf("  STM32 meter: label %s | iter %d | Tx %.2f | Rx %.2f | P %.3f dBm | V %.4f V | Nvalid %d | Ninvalid %d\n", ...
            string(label), iteration, txGain, rxGain, result.meterPower_dBm, result.meterVoltage_V, nValid, nInvalid);
    catch ME
        warning("STM32 meter read failed: %s", ME.message);
    end
end

function [powerValues_dB, voltageValues_V, adcValues_raw, nValid, nInvalid] = readSTM32PowerBlock_EXP015(stm, fidMeterRaw, label, iteration, txGain, rxGain)
    % Robust reader adapted from the working EXP004/EXP005 MEAS protocol:
    %   command: MEAS,<tag_or_txgain>,<samples>
    %   response:
    %     START,...
    %     DATA,stm32_time_ms,adc_raw,voltage_V,power_dB
    %     END,...
    %
    % This version logs START/DATA/END/ERR lines, keeps raw CSV rows, and
    % protects the experiment from hanging indefinitely if END is not received.

    powerValues_dB = [];
    voltageValues_V = [];
    adcValues_raw = [];
    nValid = 0;
    nInvalid = 0;
    gotEnd = false;

    maxBlockTime_s = 12.0;
    t0 = tic;

    while ~gotEnd
        if toc(t0) > maxBlockTime_s
            warning("STM32 block timeout after %.1f s without END. Valid samples = %d.", maxBlockTime_s, nValid);
            break;
        end

        try
            line = strtrim(string(readline(stm)));
        catch ME_READ
            warning("STM32 readline timeout/error after %.2f s: %s", toc(t0), ME_READ.message);
            break;
        end

        if strlength(line) == 0
            continue;
        end

        if startsWith(line, "START")
            fprintf("  %s\n", line);

        elseif startsWith(line, "DATA")
            parts = split(line, ",");
            if numel(parts) >= 5
                stm32_time_ms = str2double(parts{2});
                adc_raw       = str2double(parts{3});
                voltage_V     = str2double(parts{4});
                power_dB      = str2double(parts{5});

                if isfinite(power_dB)
                    powerValues_dB(end+1,1) = power_dB; %#ok<AGROW>
                end
                if isfinite(voltage_V)
                    voltageValues_V(end+1,1) = voltage_V; %#ok<AGROW>
                end
                if isfinite(adc_raw)
                    adcValues_raw(end+1,1) = adc_raw; %#ok<AGROW>
                end

                if isfinite(power_dB) || isfinite(voltage_V) || isfinite(adc_raw)
                    nValid = nValid + 1;
                else
                    nInvalid = nInvalid + 1;
                end

                if exist("fidMeterRaw","var") && fidMeterRaw > 0
                    pc_timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));
                    fprintf(fidMeterRaw, "%s,%s,%d,%.2f,%.2f,%.0f,%.0f,%.9f,%.6f,%s\n", ...
                        pc_timestamp, sanitizeCsvField(label), iteration, txGain, rxGain, ...
                        stm32_time_ms, adc_raw, voltage_V, power_dB, sanitizeCsvField(line));
                end
            else
                nInvalid = nInvalid + 1;
                fprintf("  Invalid DATA line: %s\n", line);
            end

        elseif startsWith(line, "END")
            fprintf("  %s\n", line);
            gotEnd = true;

        elseif startsWith(line, "ERR")
            warning("STM32 returned error: %s", line);
            gotEnd = true;

        else
            fprintf("  STM32: %s\n", line);
        end
    end
end

function safe = sanitizeCsvField(txt)
    safe = string(txt);
    safe = replace(safe, '"', '""');
    safe = '"' + safe + '"';
end

function setSafeState(txObj, idleGain)
    try
        txObj.Gain = idleGain;
        transmitRepeat(txObj, zeros(1000,1));
    catch
    end
end

function cleanupSDR(txObj, rxObj, idleGain)
    try
        setSafeState(txObj, idleGain);
    catch
    end
    try
        release(txObj);
    catch
    end
    try
        release(rxObj);
    catch
    end
end
