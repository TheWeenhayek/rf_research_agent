%% ========================================================================
%  EXP017 — FAIR COMPARISON OF MEMORY POLYNOMIAL AND GMP DPD
%  ----------------------------------------------------------------------
%  Objective:
%    Compare a 30-coefficient Memory Polynomial (MP) against a
%    29-coefficient Generalized Memory Polynomial (GMP) at the same:
%      - 5G NR waveform
%      - TX/RX gains
%      - DSA configuration
%      - RF chain and operating point
%      - baseline capture
%      - training/verification protocol
%
%  Experiment stages:
%    A) Capture one common no-DPD baseline.
%    B) Train MP and GMP independently from that same baseline.
%    C) Select the best physical-guard and equal-power iteration for each.
%    D) Verify No-DPD, MP and GMP in alternating repeated runs.
%    E) Export CSV data for paper-quality plots in Python/Jupyter:
%         - AM/AM and AM/PM sample data
%         - PSD frequency traces
%         - per-run metrics
%         - summary statistics
%         - paired MP-vs-GMP comparisons
%         - coefficient tables
%
%  IMPORTANT:
%    The CSV waveform export is intentionally decimated/limited to avoid
%    producing excessively large files. Raw captures remain in MAT files.
%% ========================================================================

clear; close all; clc;

%% ========================================================================
%  EASY-TO-MODIFY CONFIGURATION
%% ========================================================================

% -------------------- Physical operating point --------------------
deviceName = "Pluto";
centerFrequency = 5e9;
idleGain_dB = -80;

fixedTxGain_Pluto = -22.25;
fixedRxGain_Pluto = 8;
powerScaleFactor = 0.8;

fixedDsaSteps_Metadata = 10;
dsaStep_dB = 0.5;
fixedDsaAtten_dB_Metadata = fixedDsaSteps_Metadata*dsaStep_dB;

% -------------------- Capture/retry --------------------
captureTime_s = 80e-3;
maxCaptureAttempts = 5;
evmRetryThreshold_pct = 60;
minSyncMetric = 0.95;

alignDecimationFactor = 16;
fineSearchHalfWindow_samples = 4000;
phaseFitMagnitudeThreshold = 0.05;
numFramesForAlign = 1;

% -------------------- Training protocol --------------------
maxTrainingIterations = 5;
patienceNoImprove = 2;
minEvmImprovement_pctPoints = 0.03;

coeffBlendMu_MP = 0.08;
coeffBlendMu_GMP = 0.08;

lambdaRel_MP = 1e-2;
lambdaRel_GMP = 3e-2;

minTrainingAmplitudeRatio = 0.08;
maxConsecutiveHardFailures = 2;

% -------------------- Fair-complexity models --------------------
% MP: (M+1)*K = 6*5 = 30 complex coefficients.
mpModel = struct( ...
    "ID","MP_M5_K5", ...
    "Family","MP", ...
    "M",5, ...
    "K",5, ...
    "LambdaRel",lambdaRel_MP, ...
    "BlendMu",coeffBlendMu_MP);

% GMP: Ka*La + Kb*Lb*Mb + Kc*Lc*Mc = 20+6+3 = 29.
gmpModel = struct( ...
    "ID","GMP_F1_29C", ...
    "Family","GMP", ...
    "Ka",5,"La",4, ...
    "Kb",2,"Lb",3,"Mb",1, ...
    "Kc",1,"Lc",3,"Mc",1, ...
    "LambdaRel",lambdaRel_GMP, ...
    "BlendMu",coeffBlendMu_GMP);

candidateModels = {mpModel, gmpModel};

% -------------------- Verification/reproducibility --------------------
numVerificationRuns = 5;
verificationOrder = ["NODPD","MP","GMP"];  % repeated in this order
verificationPause_s = 0.35;

% -------------------- DPD waveform guards --------------------
maxPredistortedPeakRatio = 1.10;
maxAllowedDpdPAPR_Extra_dB = 6.5;
minAllowedAveragePowerRatio_dB = -2.5;

% -------------------- Physical selection guards --------------------
maxAllowedRxPowerDrop_dB = 1.8;
maxAllowedRxPowerRise_dB = 1.0;
digitalRxSaturationLimit_dBFS = -3.0;
maxAcceptedPostEVM_pct = 50;
minACPRImprovement_dB = 0.3;

% -------------------- Official no-DPD equal-power reference --------------------
noDPDReferenceCsv = "";
referenceRxPowerColumn = 'RxPower_dBFS';
referenceMeterPowerColumn = 'Power_mean_dB_stm32';
referenceEVMColumn = 'EVM_NR_Aligned_pct';
referenceACPRColumn = 'ACPR_dBc';
referenceTxGainColumn = 'TxGain_dB';
referenceAcceptedColumn = 'Accepted';

weightEqPowerEVM = 1.00;
weightEqPowerACPR = 0.35;
weightMeterEVM = 0.35;
weightPAPR = 0.08;

% -------------------- CSV export for notebook plots --------------------
exportNotebookCSVs = true;
plotExportMaxSamplesPerCondition = 60000;
plotExportDecimation = 4;
psdExportNFFT = 16384;
psdExportWindowLength = 4096;

% -------------------- Raw capture and visualization --------------------
saveRawCaptures = true;
plotMaxSymbols = 6000;

% -------------------- STM32/LTC5596 meter --------------------
useSTM32PowerMeter = true;
serialPort = "COM12";
serialBaud = 209700;
serialTerminator = "LF";
serialTimeout_s = 2.00;
doPingTest = true;
nPowerSamplesPerPoint = 50;

%% ========================================================================
%  OUTPUT DIRECTORIES
%% ========================================================================

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir)
    scriptDir = pwd;
end

try
    examplePath = fullfile(matlabroot, 'examples', '5g', ...
        'NRWaveformCaptureAndAnalysisWithSDRExample');
    if exist(examplePath, 'dir')
        addpath(examplePath);
    end
catch
end

projectDir = fileparts(scriptDir);
baselineDir = fullfile(projectDir, "baseline");
dataDir = fullfile(projectDir, "data");
if ~exist(dataDir, "dir"), mkdir(dataDir); end

if strlength(string(noDPDReferenceCsv)) == 0
    noDPDReferenceCsv = findLatestOfficialNoDPDReference(dataDir);
end

[plutoOutEstimated_dBm, plutoOutCalibrationMode] = ...
    estimatePlutoOutputFromDPDV2Baseline(fixedTxGain_Pluto, baselineDir);

txTag = string(strrep(sprintf('%.2f', fixedTxGain_Pluto), '.', 'p'));
rxTag = string(strrep(sprintf('%.2f', fixedRxGain_Pluto), '.', 'p'));
timeTag = string(datetime("now","Format","yyyyMMdd_HHmmss"));

baseName = "EXP017_MP_vs_GMP_FAIR_Tx_" + txTag + "_Rx_" + rxTag + "_" + timeTag;
outputRoot = fullfile(dataDir, baseName);
rawDir = fullfile(outputRoot, "raw");
processedDir = fullfile(outputRoot, "processed");
figuresDir = fullfile(outputRoot, "figures");
notebookDir = fullfile(outputRoot, "notebook_csv");

for d = [{rawDir},{processedDir},{figuresDir},{notebookDir}]
    if ~exist(d{1},"dir"), mkdir(d{1}); end
end

trainingCsvFile = fullfile(processedDir, baseName + "_training_metrics.csv");
verificationCsvFile = fullfile(processedDir, baseName + "_verification_per_run.csv");
summaryCsvFile = fullfile(processedDir, baseName + "_summary_statistics.csv");
pairedCsvFile = fullfile(processedDir, baseName + "_paired_MP_vs_GMP.csv");
coeffCsvFile = fullfile(processedDir, baseName + "_best_coefficients.csv");
bestCsvFile = fullfile(processedDir, baseName + "_best_model_selections.csv");
matFile = fullfile(processedDir, baseName + "_results.mat");

amamCsvFile = fullfile(notebookDir, baseName + "_AMAM_AMPM_samples.csv");
psdCsvFile = fullfile(notebookDir, baseName + "_PSD_traces.csv");
waveformMetaCsvFile = fullfile(notebookDir, baseName + "_waveform_export_metadata.csv");

csvMeterRawFile = fullfile(rawDir, baseName + "_stm32_meter_raw.csv");
fidMeterRaw = -1;


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

fprintf('\n===== EXP017 FAIR MP-vs-GMP SETUP =====\n');
fprintf('TX gain                 = %.2f dB\n', fixedTxGain_Pluto);
fprintf('Pluto output estimated  = %.3f dBm\n', plutoOutEstimated_dBm);
fprintf('RX gain                 = %.2f dB\n', fixedRxGain_Pluto);
fprintf('powerScaleFactor        = %.3f\n', powerScaleFactor);
fprintf('Original PAPR           = %.2f dB\n', PAPR_tx_dB);
fprintf('Original TX power       = %.2f dBFS rel.\n', txPower_dBFS);
fprintf('GMP-HILA iterations/model   = %d\n', maxTrainingIterations);
fprintf('MP coefficient blend mu     = %.3f\n', coeffBlendMu_MP);
fprintf('GMP coefficient blend mu    = %.3f\n', coeffBlendMu_GMP);
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


%% ========================================================================
%  COMMON NO-DPD BASELINE
%% ========================================================================

fprintf('\n===== EXP017 COMMON BASELINE =====\n');

sdrTransmitter.Gain = fixedTxGain_Pluto;
transmitRepeat(sdrTransmitter, txWaveform);
pause(0.8);

baseline = captureAndMeasureWithRetry( ...
    sdrReceiver, txWaveform, cfgDLFRC, cfgEVM, sampleRate, ...
    captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
    maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
    alignDecimationFactor, fineSearchHalfWindow_samples, ...
    phaseFitMagnitudeThreshold, numFramesForAlign, ...
    rawDir, saveRawCaptures, "common_baseline", ...
    fixedTxGain_Pluto, fixedRxGain_Pluto, ...
    fixedDsaSteps_Metadata, fixedDsaAtten_dB_Metadata);

if ~baseline.usable
    error('Common baseline capture is unusable.');
end

baseline = attachMeterMeasurement( ...
    baseline, stm, useSTM32PowerMeter, ...
    fixedTxGain_Pluto, fixedRxGain_Pluto, ...
    nPowerSamplesPerPoint, fidMeterRaw, "COMMON_BASELINE", 0);

baselineRxNorm = normalizeRxToTx(baseline.rxAligned, txWaveform);

fprintf('Baseline: EVM %.3f %% | ACPR %.3f dBc | RX %.3f dBFS | Meter %.3f dBm | Sync %.4f\n', ...
    baseline.evm_pct, baseline.acpr_dBc, baseline.rxPower_dBFS, ...
    baseline.meterPower_dBm, baseline.syncMetric);

%% ========================================================================
%  INDEPENDENT TRAINING OF MP AND GMP
%% ========================================================================

trainingRows = repmat(createTrainingRow(),0,1);
coeffRows = repmat(createUnifiedCoeffRow(),0,1);
trainingArtifacts = struct();

for iModel = 1:numel(candidateModels)
    model = candidateModels{iModel};
    modelID = char(model.ID);
    family = string(model.Family);

    fprintf('\n============================================================\n');
    fprintf('TRAINING %s (%s)\n', modelID, char(family));
    fprintf('============================================================\n');

    if family == "MP"
        nCoeff = (model.M+1)*model.K;
    else
        nCoeff = model.Ka*model.La + ...
                 model.Kb*model.Lb*model.Mb + ...
                 model.Kc*model.Lc*model.Mc;
    end

    coeffPrev = zeros(nCoeff,1);
    coeffCurrent = zeros(nCoeff,1);
    trainSourceNorm = baselineRxNorm;

    bestPhysicalScore = -Inf;
    bestEqualScore = -Inf;
    bestPhysical = [];
    bestEqual = [];
    bestAnyEVM = Inf;
    bestAny = [];

    noImproveCount = 0;
    bestLocalEVM = Inf;
    consecutiveFailures = 0;

    % Baseline row shared by each model.
    r = createTrainingRow();
    r.ModelID = string(modelID);
    r.Family = string(family);
    r.Iteration = 0;
    r.CoeffCount = nCoeff;
    r.LambdaRel = model.LambdaRel;
    r.BlendMu = model.BlendMu;
    r.EVM_Post_pct = baseline.evm_pct;
    r.ACPR_Post_dBc = baseline.acpr_dBc;
    r.RxPower_Post_dBFS = baseline.rxPower_dBFS;
    r.MeterPower_DPD_dBm = baseline.meterPower_dBm;
    r.SyncMetric_Post = baseline.syncMetric;
    r.UsableCapture = true;
    r.SelectionClass = "BASELINE";
    trainingRows(end+1,1) = r; %#ok<SAGROW>

    for iter = 1:maxTrainingIterations
        fprintf('\n--- %s iteration %d/%d ---\n', modelID, iter, maxTrainingIterations);

        try
            tBuild = tic;
            if family == "MP"
                [Xreg,ytrim,idxTrain,coeffLabels] = buildMPTrainingSetUnified( ...
                    trainSourceNorm, txWaveform, model.M, model.K, ...
                    minTrainingAmplitudeRatio);
            else
                [Xreg,ytrim,idxTrain,coeffLabels] = buildGMPTrainingSet( ...
                    trainSourceNorm, txWaveform, model, ...
                    minTrainingAmplitudeRatio);
            end
            matrixBuildTime_s = toc(tBuild);

            if size(Xreg,1) <= size(Xreg,2)
                warning('Insufficient training samples for %s.', modelID);
                break;
            end

            tSolve = tic;
            coeffHat = solveRegularizedLS(Xreg,ytrim,model.LambdaRel);
            lsSolveTime_s = toc(tSolve);

            if iter == 1
                coeffCurrent = coeffHat;
            else
                coeffCurrent = (1-model.BlendMu)*coeffPrev + ...
                                model.BlendMu*coeffHat;
            end
            coeffDeltaNorm = norm(coeffCurrent-coeffPrev);
            coeffPrev = coeffCurrent;

            tApply = tic;
            if family == "MP"
                txDPDRaw = applyMemoryPolynomialUnified( ...
                    txWaveform,coeffCurrent,model.M,model.K);
            else
                txDPDRaw = applyGMP(txWaveform,coeffCurrent,model);
            end
            [txDPD,normDiag] = normalizeDPDWaveformDetailed( ...
                txDPDRaw,txWaveform,maxPredistortedPeakRatio);
            dpdApplyTime_s = toc(tApply);

            paprDPD_dB = 10*log10(max(abs(txDPD)).^2/ ...
                (mean(abs(txDPD).^2)+eps));
            peakRatio = max(abs(txDPD))/(max(abs(txWaveform))+eps);
            paprGuardPass = isfinite(paprDPD_dB) && ...
                paprDPD_dB <= PAPR_tx_dB + maxAllowedDpdPAPR_Extra_dB;

            R = Xreg'*Xreg;
            scaleR = trace(R)/max(size(R,1),1);
            lambdaActual = model.LambdaRel*max(scaleR,eps);
            condEstimateRegularized = condest( ...
                R + lambdaActual*speye(size(R,1)));

            fprintf('Samples %d | coeff %d | cond(reg) %.3e\n', ...
                nnz(idxTrain),nCoeff,condEstimateRegularized);
            fprintf('PAPR %.3f dB | peak ratio %.4f | post-average ratio %.3f dB\n', ...
                paprDPD_dB,peakRatio,normDiag.PostAveragePowerRatio_dB);

            if ~paprGuardPass
                warning('PAPR guard failed for %s iteration %d.',modelID,iter);
                continue;
            end

            sdrTransmitter.Gain = fixedTxGain_Pluto;
            transmitRepeat(sdrTransmitter,txDPD);
            pause(0.8);

            post = captureAndMeasureWithRetry( ...
                sdrReceiver,txDPD,cfgDLFRC,cfgEVM,sampleRate, ...
                captureTime_s,totalSamplesNeeded,samplesPerFrame, ...
                maxCaptureAttempts,evmRetryThreshold_pct,minSyncMetric, ...
                alignDecimationFactor,fineSearchHalfWindow_samples, ...
                phaseFitMagnitudeThreshold,numFramesForAlign, ...
                rawDir,saveRawCaptures, ...
                sprintf('%s_train_iter_%02d',modelID,iter), ...
                fixedTxGain_Pluto,fixedRxGain_Pluto, ...
                fixedDsaSteps_Metadata,fixedDsaAtten_dB_Metadata);

            post = attachMeterMeasurement( ...
                post,stm,useSTM32PowerMeter, ...
                fixedTxGain_Pluto,fixedRxGain_Pluto, ...
                nPowerSamplesPerPoint,fidMeterRaw,string(modelID),iter);

            r = createTrainingRow();
            r.ModelID = string(modelID);
            r.Family = string(family);
            r.Iteration = iter;
            r.CoeffCount = nCoeff;
            r.LambdaRel = model.LambdaRel;
            r.BlendMu = model.BlendMu;
            r.TrainSamples = nnz(idxTrain);
            r.CondEstimateRegularized = condEstimateRegularized;
            r.CoeffNorm = norm(coeffCurrent);
            r.CoeffDeltaNorm = coeffDeltaNorm;
            r.MatrixBuildTime_s = matrixBuildTime_s;
            r.LSSolveTime_s = lsSolveTime_s;
            r.DPDApplyTime_s = dpdApplyTime_s;
            r.PAPR_DPD_dB = paprDPD_dB;
            r.PeakRatio_DPD_to_Original = peakRatio;
            r.DPDRawAveragePowerRatio_dB = normDiag.RawAveragePowerRatio_dB;
            r.DPDPostAveragePowerRatio_dB = normDiag.PostAveragePowerRatio_dB;
            r.DPDPeakScaleApplied = normDiag.PeakScaleApplied;
            r.DPDNumSamplesAbovePeak = normDiag.NumSamplesAbovePeakBeforeScaling;
            r.PAPRGuardPass = paprGuardPass;

            if post.usable
                consecutiveFailures = 0;
                r.UsableCapture = true;
                r.EVM_Post_pct = post.evm_pct;
                r.ACPR_Post_dBc = post.acpr_dBc;
                r.RxPower_Post_dBFS = post.rxPower_dBFS;
                r.RxPower_Delta_dB = post.rxPower_dBFS-baseline.rxPower_dBFS;
                r.MeterPower_DPD_dBm = post.meterPower_dBm;
                r.MeterPower_Delta_dB = post.meterPower_dBm-baseline.meterPower_dBm;
                r.SyncMetric_Post = post.syncMetric;
                r.NMSE_Post_dB = post.nmse_aligned_dB;

                averagePowerDiagnosticPass = ...
                    normDiag.PostAveragePowerRatio_dB >= ...
                    minAllowedAveragePowerRatio_dB;

                r.PowerGuardPass = ...
                    r.RxPower_Delta_dB >= -maxAllowedRxPowerDrop_dB && ...
                    r.RxPower_Delta_dB <= maxAllowedRxPowerRise_dB && ...
                    averagePowerDiagnosticPass;

                r.ClippingGuardPass = ...
                    post.rxPower_dBFS < digitalRxSaturationLimit_dBFS;
                r.IterationAccepted = ...
                    post.evm_pct < maxAcceptedPostEVM_pct && ...
                    post.syncMetric >= minSyncMetric && ...
                    r.PowerGuardPass && ...
                    r.ClippingGuardPass && ...
                    r.PAPRGuardPass;

                % Temporary raw score. Equal-power columns are added later.
                r.RawScore = ...
                    (baseline.evm_pct-post.evm_pct) + ...
                    0.35*(baseline.acpr_dBc-post.acpr_dBc) - ...
                    0.08*max(0,paprDPD_dB-PAPR_tx_dB);

                if r.IterationAccepted && r.RawScore > bestPhysicalScore
                    bestPhysicalScore = r.RawScore;
                    bestPhysical = packageBestArtifact( ...
                        modelID,family,iter,coeffCurrent,coeffLabels, ...
                        txDPD,post,r,"PHYSICAL_GUARD");
                end

                if post.evm_pct < bestAnyEVM
                    bestAnyEVM = post.evm_pct;
                    bestAny = packageBestArtifact( ...
                        modelID,family,iter,coeffCurrent,coeffLabels, ...
                        txDPD,post,r,"LOWEST_EVM_FALLBACK");
                end

                % Prepare next post-inverse training source.
                trainSourceNorm = normalizeRxToTx(post.rxAligned,txWaveform);

                if r.IterationAccepted && ...
                        post.evm_pct < bestLocalEVM-minEvmImprovement_pctPoints
                    bestLocalEVM = post.evm_pct;
                    noImproveCount = 0;
                else
                    noImproveCount = noImproveCount+1;
                end
            else
                consecutiveFailures = consecutiveFailures+1;
                r.UsableCapture = false;
            end

            trainingRows(end+1,1) = r; %#ok<SAGROW>

            % Coefficient long table.
            for ic = 1:numel(coeffCurrent)
                cr = createUnifiedCoeffRow();
                cr.ModelID = string(modelID);
                cr.Family = string(family);
                cr.Iteration = iter;
                cr.CoeffIndex = ic;
                cr.CoeffLabel = coeffLabels(ic);
                cr.CoeffReal = real(coeffCurrent(ic));
                cr.CoeffImag = imag(coeffCurrent(ic));
                cr.CoeffAbs = abs(coeffCurrent(ic));
                cr.CoeffPhase_rad = angle(coeffCurrent(ic));
                coeffRows(end+1,1) = cr; %#ok<SAGROW>
            end

            if consecutiveFailures >= maxConsecutiveHardFailures
                warning('%s stopped after consecutive failures.',modelID);
                break;
            end
            if noImproveCount >= patienceNoImprove
                fprintf('%s early stop after %d no-improvement iterations.\n', ...
                    modelID,patienceNoImprove);
                break;
            end

        catch ME
            warning('%s iteration %d failed: %s',modelID,iter,ME.message);
            consecutiveFailures = consecutiveFailures+1;
            if consecutiveFailures >= maxConsecutiveHardFailures
                break;
            end
        end

        setSafeState(sdrTransmitter,idleGain_dB);
        pause(0.25);
    end

    if isempty(bestPhysical)
        warning('%s has no strict physical-guard result. Using lowest-EVM result.',modelID);
        selected = bestAny;
    else
        selected = bestPhysical;
    end

    if isempty(selected)
        error('No usable trained result for %s.',modelID);
    end

    trainingArtifacts.(matlab.lang.makeValidName(family)) = selected;
    setSafeState(sdrTransmitter,idleGain_dB);
    pause(0.5);
end

%% ========================================================================
%  ADD OFFICIAL EQUAL-POWER COMPARISONS TO TRAINING TABLE
%% ========================================================================

trainingTable = struct2table(trainingRows);
trainingTable = addEqualPowerColumnsUnified( ...
    trainingTable,noDPDReferenceCsv, ...
    referenceRxPowerColumn,referenceMeterPowerColumn, ...
    referenceEVMColumn,referenceACPRColumn, ...
    referenceTxGainColumn,referenceAcceptedColumn, ...
    weightEqPowerEVM,weightEqPowerACPR,weightMeterEVM,weightPAPR,PAPR_tx_dB);

% Re-select the best equal-power iteration independently for each model.
bestSelectionRows = repmat(createBestSelectionRow(),0,1);

families = ["MP","GMP"];
for iFam = 1:numel(families)
    fam = families(iFam);
    mask = trainingTable.Family == fam & ...
           trainingTable.Iteration > 0 & ...
           trainingTable.UsableCapture & ...
           trainingTable.PAPRGuardPass & ...
           trainingTable.ClippingGuardPass;

    physicalMask = mask & trainingTable.IterationAccepted & ...
        isfinite(trainingTable.CompositeScore);

    equalMask = mask & ...
        isfinite(trainingTable.DPD_EVM_Improvement_vsSameRxPower_pct) & ...
        isfinite(trainingTable.CompositeScore);

    if any(physicalMask)
        idx = find(physicalMask);
        [~,j] = max(trainingTable.CompositeScore(idx));
        physicalRow = idx(j);
    else
        physicalRow = NaN;
    end

    if any(equalMask)
        idx = find(equalMask);
        [~,j] = max(trainingTable.CompositeScore(idx));
        equalRow = idx(j);
    else
        equalRow = NaN;
    end

    br = createBestSelectionRow();
    br.Family = fam;
    if isfinite(physicalRow)
        br.PhysicalIteration = trainingTable.Iteration(physicalRow);
        br.PhysicalEVM_pct = trainingTable.EVM_Post_pct(physicalRow);
        br.PhysicalACPR_dBc = trainingTable.ACPR_Post_dBc(physicalRow);
        br.PhysicalCompositeScore = trainingTable.CompositeScore(physicalRow);
    end
    if isfinite(equalRow)
        br.EqualPowerIteration = trainingTable.Iteration(equalRow);
        br.EqualPowerEVM_pct = trainingTable.EVM_Post_pct(equalRow);
        br.EqualPowerACPR_dBc = trainingTable.ACPR_Post_dBc(equalRow);
        br.EqualPowerCompositeScore = trainingTable.CompositeScore(equalRow);
    end
    bestSelectionRows(end+1,1) = br; %#ok<SAGROW>
end

bestSelectionTable = struct2table(bestSelectionRows);
coeffTable = struct2table(coeffRows);

writetable(trainingTable,trainingCsvFile);
writetable(coeffTable,coeffCsvFile);
writetable(bestSelectionTable,bestCsvFile);

%% ========================================================================
%  ALTERNATING VERIFICATION RUNS
%% ========================================================================

mpBest = trainingArtifacts.MP;
gmpBest = trainingArtifacts.GMP;

verificationRows = repmat(createVerificationRow(),0,1);
verificationArtifacts = struct();
verificationArtifacts.NODPD = cell(numVerificationRuns,1);
verificationArtifacts.MP = cell(numVerificationRuns,1);
verificationArtifacts.GMP = cell(numVerificationRuns,1);

for run = 1:numVerificationRuns
    fprintf('\n============================================================\n');
    fprintf('VERIFICATION ROUND %d/%d\n',run,numVerificationRuns);
    fprintf('============================================================\n');

    for iCond = 1:numel(verificationOrder)
        condition = verificationOrder(iCond);

        switch condition
            case "NODPD"
                txCurrent = txWaveform;
            case "MP"
                txCurrent = mpBest.txDPD;
            case "GMP"
                txCurrent = gmpBest.txDPD;
            otherwise
                error('Unknown verification condition.');
        end

        sdrTransmitter.Gain = fixedTxGain_Pluto;
        transmitRepeat(sdrTransmitter,txCurrent);
        pause(0.8);

        result = captureAndMeasureWithRetry( ...
            sdrReceiver,txCurrent,cfgDLFRC,cfgEVM,sampleRate, ...
            captureTime_s,totalSamplesNeeded,samplesPerFrame, ...
            maxCaptureAttempts,evmRetryThreshold_pct,minSyncMetric, ...
            alignDecimationFactor,fineSearchHalfWindow_samples, ...
            phaseFitMagnitudeThreshold,numFramesForAlign, ...
            rawDir,saveRawCaptures, ...
            sprintf('verify_run_%02d_%s',run,condition), ...
            fixedTxGain_Pluto,fixedRxGain_Pluto, ...
            fixedDsaSteps_Metadata,fixedDsaAtten_dB_Metadata);

        result = attachMeterMeasurement( ...
            result,stm,useSTM32PowerMeter, ...
            fixedTxGain_Pluto,fixedRxGain_Pluto, ...
            nPowerSamplesPerPoint,fidMeterRaw,condition,run);

        vr = createVerificationRow();
        vr.Run = run;
        vr.Condition = condition;
        vr.TxGain_dB = fixedTxGain_Pluto;
        vr.RxGain_dB = fixedRxGain_Pluto;

        if result.usable
            vr.UsableCapture = true;
            vr.EVM_pct = result.evm_pct;
            vr.ACPR_dBc = result.acpr_dBc;
            vr.RxPower_dBFS = result.rxPower_dBFS;
            vr.MeterPower_dBm = result.meterPower_dBm;
            vr.SyncMetric = result.syncMetric;
            vr.NMSE_dB = result.nmse_aligned_dB;
            vr.PAPR_Tx_dB = 10*log10(max(abs(txCurrent)).^2/ ...
                (mean(abs(txCurrent).^2)+eps));
        end

        verificationRows(end+1,1) = vr; %#ok<SAGROW>
        verificationArtifacts.(char(condition)){run} = result;

        fprintf('%s run %d: EVM %.3f %% | ACPR %.3f dBc | RX %.3f dBFS | Meter %.3f dBm\n', ...
            condition,run,vr.EVM_pct,vr.ACPR_dBc, ...
            vr.RxPower_dBFS,vr.MeterPower_dBm);

        setSafeState(sdrTransmitter,idleGain_dB);
        pause(verificationPause_s);
    end
end

verificationTable = struct2table(verificationRows);
writetable(verificationTable,verificationCsvFile);

%% ========================================================================
%  SUMMARY STATISTICS AND PAIRED MP-vs-GMP COMPARISON
%% ========================================================================

summaryTable = buildVerificationSummary(verificationTable);
pairedTable = buildPairedComparison(verificationTable);
writetable(summaryTable,summaryCsvFile);
writetable(pairedTable,pairedCsvFile);

%% ========================================================================
%  EXPORT NOTEBOOK CSV DATA: AM/AM, AM/PM AND PSD
%% ========================================================================

if exportNotebookCSVs
    % Use the first usable verification capture for each condition.
    exportResults = struct();
    exportTx = struct();
    exportTx.NODPD = txWaveform;
    exportTx.MP = mpBest.txDPD;
    exportTx.GMP = gmpBest.txDPD;

    for condition = ["NODPD","MP","GMP"]
        exportResults.(char(condition)) = firstUsableResult( ...
            verificationArtifacts.(char(condition)));
    end

    amamTable = buildAMAMAMPMExportTable( ...
        txWaveform,exportTx,exportResults, ...
        plotExportMaxSamplesPerCondition,plotExportDecimation);
    writetable(amamTable,amamCsvFile);

    psdTable = buildPSDExportTable( ...
        exportResults,sampleRate,psdExportNFFT,psdExportWindowLength);
    writetable(psdTable,psdCsvFile);

    waveformMetaTable = buildWaveformExportMetadata( ...
        exportTx,exportResults,sampleRate, ...
        plotExportMaxSamplesPerCondition,plotExportDecimation);
    writetable(waveformMetaTable,waveformMetaCsvFile);
end

%% ========================================================================
%  QUICK MATLAB FIGURES
%% ========================================================================

try
    h = figure('Color','w');
    boxchart(categorical(verificationTable.Condition),verificationTable.EVM_pct);
    grid on; ylabel('EVM RMS (%)'); xlabel('Condition');
    title('EXP017 verification EVM: No DPD vs MP vs GMP');
    saveas(h,fullfile(figuresDir,'01_Verification_EVM_Boxchart.png'));
catch ME
    warning('EVM boxchart failed: %s',ME.message);
end

try
    h = figure('Color','w');
    boxchart(categorical(verificationTable.Condition),verificationTable.ACPR_dBc);
    grid on; ylabel('ACPR (dBc)'); xlabel('Condition');
    title('EXP017 verification ACPR: No DPD vs MP vs GMP');
    saveas(h,fullfile(figuresDir,'02_Verification_ACPR_Boxchart.png'));
catch ME
    warning('ACPR boxchart failed: %s',ME.message);
end

%% ========================================================================
%  SAVE FINAL MAT AND CLEANUP
%% ========================================================================

try
    if exist("fidMeterRaw","var") && fidMeterRaw > 0
        fclose(fidMeterRaw);
        fidMeterRaw = -1;
    end
catch
end

save(matFile, ...
    'cfgDLFRC','cfgEVM','sampleRate','txWaveform','PAPR_tx_dB', ...
    'fixedTxGain_Pluto','fixedRxGain_Pluto', ...
    'fixedDsaSteps_Metadata','fixedDsaAtten_dB_Metadata', ...
    'plutoOutEstimated_dBm','plutoOutCalibrationMode', ...
    'mpModel','gmpModel','baseline','trainingArtifacts', ...
    'trainingTable','verificationTable','summaryTable','pairedTable', ...
    'coeffTable','bestSelectionTable','verificationArtifacts', ...
    'noDPDReferenceCsv');

setSafeState(sdrTransmitter,idleGain_dB);

fprintf('\n===== EXP017 COMPLETE =====\n');
fprintf('Output root             : %s\n',outputRoot);
fprintf('Training metrics        : %s\n',trainingCsvFile);
fprintf('Verification per run    : %s\n',verificationCsvFile);
fprintf('Summary statistics      : %s\n',summaryCsvFile);
fprintf('Paired MP vs GMP        : %s\n',pairedCsvFile);
fprintf('Best coefficients       : %s\n',coeffCsvFile);
fprintf('AM/AM-AM/PM notebook CSV: %s\n',amamCsvFile);
fprintf('PSD notebook CSV        : %s\n',psdCsvFile);
fprintf('MAT results             : %s\n',matFile);



%% ========================================================================
%  EXP017 LOCAL FUNCTIONS
%% ========================================================================

function s = createTrainingRow()
    s = struct( ...
        'ModelID',string(missing), ...
        'Family',string(missing), ...
        'Iteration',NaN, ...
        'CoeffCount',NaN, ...
        'LambdaRel',NaN, ...
        'BlendMu',NaN, ...
        'TrainSamples',NaN, ...
        'CondEstimateRegularized',NaN, ...
        'CoeffNorm',NaN, ...
        'CoeffDeltaNorm',NaN, ...
        'MatrixBuildTime_s',NaN, ...
        'LSSolveTime_s',NaN, ...
        'DPDApplyTime_s',NaN, ...
        'PAPR_DPD_dB',NaN, ...
        'PeakRatio_DPD_to_Original',NaN, ...
        'DPDRawAveragePowerRatio_dB',NaN, ...
        'DPDPostAveragePowerRatio_dB',NaN, ...
        'DPDPeakScaleApplied',NaN, ...
        'DPDNumSamplesAbovePeak',NaN, ...
        'PAPRGuardPass',false, ...
        'EVM_Post_pct',NaN, ...
        'ACPR_Post_dBc',NaN, ...
        'RxPower_Post_dBFS',NaN, ...
        'RxPower_Delta_dB',NaN, ...
        'MeterPower_DPD_dBm',NaN, ...
        'MeterPower_Delta_dB',NaN, ...
        'SyncMetric_Post',NaN, ...
        'NMSE_Post_dB',NaN, ...
        'PowerGuardPass',false, ...
        'ClippingGuardPass',false, ...
        'IterationAccepted',false, ...
        'UsableCapture',false, ...
        'RawScore',NaN, ...
        'RefNoDPD_EVM_AtSameRxPower_pct',NaN, ...
        'RefNoDPD_ACPR_AtSameRxPower_dBc',NaN, ...
        'DPD_EVM_Improvement_vsSameRxPower_pct',NaN, ...
        'DPD_ACPR_Improvement_vsSameRxPower_dB',NaN, ...
        'RefNoDPD_EVM_AtSameMeterPower_pct',NaN, ...
        'RefNoDPD_ACPR_AtSameMeterPower_dBc',NaN, ...
        'DPD_EVM_Improvement_vsSameMeterPower_pct',NaN, ...
        'DPD_ACPR_Improvement_vsSameMeterPower_dB',NaN, ...
        'CompositeScore',NaN, ...
        'SelectionClass',string(missing));
end

function s = createUnifiedCoeffRow()
    s = struct( ...
        'ModelID',string(missing), ...
        'Family',string(missing), ...
        'Iteration',NaN, ...
        'CoeffIndex',NaN, ...
        'CoeffLabel',string(missing), ...
        'CoeffReal',NaN, ...
        'CoeffImag',NaN, ...
        'CoeffAbs',NaN, ...
        'CoeffPhase_rad',NaN);
end

function s = createVerificationRow()
    s = struct( ...
        'Run',NaN, ...
        'Condition',string(missing), ...
        'TxGain_dB',NaN, ...
        'RxGain_dB',NaN, ...
        'EVM_pct',NaN, ...
        'ACPR_dBc',NaN, ...
        'RxPower_dBFS',NaN, ...
        'MeterPower_dBm',NaN, ...
        'SyncMetric',NaN, ...
        'NMSE_dB',NaN, ...
        'PAPR_Tx_dB',NaN, ...
        'UsableCapture',false);
end

function s = createBestSelectionRow()
    s = struct( ...
        'Family',string(missing), ...
        'PhysicalIteration',NaN, ...
        'PhysicalEVM_pct',NaN, ...
        'PhysicalACPR_dBc',NaN, ...
        'PhysicalCompositeScore',NaN, ...
        'EqualPowerIteration',NaN, ...
        'EqualPowerEVM_pct',NaN, ...
        'EqualPowerACPR_dBc',NaN, ...
        'EqualPowerCompositeScore',NaN);
end

function artifact = packageBestArtifact(modelID,family,iteration,coeffs,labels,txDPD,post,row,mode)
    artifact = struct();
    artifact.modelID = string(modelID);
    artifact.family = string(family);
    artifact.iteration = iteration;
    artifact.coeffs = coeffs;
    artifact.coeffLabels = labels;
    artifact.txDPD = txDPD;
    artifact.post = post;
    artifact.trainingRow = row;
    artifact.selectionMode = string(mode);
end

function [Xfit,yfit,idxTrain,labels] = buildMPTrainingSetUnified(rxNorm,txRef,M,K,minAmpRatio)
    rxNorm = rxNorm(:);
    txRef = txRef(:);
    L = min(numel(rxNorm),numel(txRef));
    rxNorm = rxNorm(1:L);
    txRef = txRef(1:L);

    X = buildMPMatrixUnified(rxNorm,M,K);
    y = txRef(M+1:end);

    amp = abs(rxNorm(M+1:end));
    ampMax = max(amp);
    if ~isfinite(ampMax) || ampMax <= 0
        error('Invalid MP training amplitude.');
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

    labels = strings((M+1)*K,1);
    col = 1;
    for m = 0:M
        for k = 0:K-1
            labels(col) = sprintf("MP_m%d_ord%d",m,2*k+1);
            col = col+1;
        end
    end
end

function X = buildMPMatrixUnified(x,M,K)
    x = x(:);
    L = numel(x);
    if L <= M
        error('Signal length must exceed MP memory depth.');
    end
    X = complex(zeros(L-M,(M+1)*K));
    col = 1;
    for m = 0:M
        s = x(M+1-m:end-m);
        for k = 0:K-1
            X(:,col) = s.*abs(s).^(2*k);
            col = col+1;
        end
    end
end

function y = applyMemoryPolynomialUnified(x,coeffs,M,K)
    x = x(:);
    y = x;
    X = buildMPMatrixUnified(x,M,K);
    if numel(coeffs) ~= size(X,2)
        error('MP coefficient-count mismatch.');
    end
    y(M+1:end) = X*coeffs;
end

function T = addEqualPowerColumnsUnified(T,refCsv,refRxCol,refMeterCol,refEvmCol,refAcprCol,refTxCol,refAcceptedCol,wEvm,wAcpr,wMeter,wPapr,paprBase)
    n = height(T);
    T.RefNoDPD_EVM_AtSameRxPower_pct = nan(n,1);
    T.RefNoDPD_ACPR_AtSameRxPower_dBc = nan(n,1);
    T.DPD_EVM_Improvement_vsSameRxPower_pct = nan(n,1);
    T.DPD_ACPR_Improvement_vsSameRxPower_dB = nan(n,1);
    T.RefNoDPD_EVM_AtSameMeterPower_pct = nan(n,1);
    T.RefNoDPD_ACPR_AtSameMeterPower_dBc = nan(n,1);
    T.DPD_EVM_Improvement_vsSameMeterPower_pct = nan(n,1);
    T.DPD_ACPR_Improvement_vsSameMeterPower_dB = nan(n,1);
    T.CompositeScore = nan(n,1);

    if isempty(refCsv) || ~exist(refCsv,'file')
        warning('No official no-DPD reference available for equal-power columns.');
        T.CompositeScore = T.RawScore;
        return;
    end

    Tref = readtable(refCsv);
    if ismember(refAcceptedCol,Tref.Properties.VariableNames)
        Tref = Tref(logical(Tref.(refAcceptedCol)),:);
    end

    [evmRx,acprRx] = interpReferenceSimple( ...
        Tref,refRxCol,refEvmCol,refAcprCol,T.RxPower_Post_dBFS);
    T.RefNoDPD_EVM_AtSameRxPower_pct = evmRx;
    T.RefNoDPD_ACPR_AtSameRxPower_dBc = acprRx;
    T.DPD_EVM_Improvement_vsSameRxPower_pct = evmRx-T.EVM_Post_pct;
    T.DPD_ACPR_Improvement_vsSameRxPower_dB = acprRx-T.ACPR_Post_dBc;

    if ismember(refMeterCol,Tref.Properties.VariableNames)
        [evmM,acprM] = interpReferenceSimple( ...
            Tref,refMeterCol,refEvmCol,refAcprCol,T.MeterPower_DPD_dBm);
        T.RefNoDPD_EVM_AtSameMeterPower_pct = evmM;
        T.RefNoDPD_ACPR_AtSameMeterPower_dBc = acprM;
        T.DPD_EVM_Improvement_vsSameMeterPower_pct = evmM-T.EVM_Post_pct;
        T.DPD_ACPR_Improvement_vsSameMeterPower_dB = acprM-T.ACPR_Post_dBc;
    end

    paprPenalty = max(0,T.PAPR_DPD_dB-paprBase);
    T.CompositeScore = ...
        wEvm*T.DPD_EVM_Improvement_vsSameRxPower_pct + ...
        wAcpr*T.DPD_ACPR_Improvement_vsSameRxPower_dB + ...
        wMeter*fillmissing(T.DPD_EVM_Improvement_vsSameMeterPower_pct,'constant',0) - ...
        wPapr*paprPenalty;
end

function [evmInterp,acprInterp] = interpReferenceSimple(Tref,xCol,evmCol,acprCol,xq)
    evmInterp = nan(size(xq));
    acprInterp = nan(size(xq));
    if ~all(ismember({xCol,evmCol,acprCol},Tref.Properties.VariableNames))
        return;
    end
    x = Tref.(xCol);
    e = Tref.(evmCol);
    a = Tref.(acprCol);
    valid = isfinite(x)&isfinite(e)&isfinite(a);
    x=x(valid); e=e(valid); a=a(valid);
    if numel(x)<4, return; end
    [x,idx]=sort(x); e=e(idx); a=a(idx);
    [xu,ia]=unique(x,'stable'); eu=e(ia); au=a(ia);
    inRange=isfinite(xq)&xq>=min(xu)&xq<=max(xu);
    evmInterp(inRange)=interp1(xu,eu,xq(inRange),'pchip');
    acprInterp(inRange)=interp1(xu,au,xq(inRange),'pchip');
end

function T = buildVerificationSummary(V)
    conditions = unique(V.Condition,'stable');
    rows = struct([]);
    for i=1:numel(conditions)
        c=conditions(i);
        X=V(V.Condition==c & V.UsableCapture,:);
        r.Condition=c;
        r.N=height(X);
        r.EVM_Mean_pct=mean(X.EVM_pct,'omitnan');
        r.EVM_Std_pct=std(X.EVM_pct,'omitnan');
        r.EVM_Min_pct=min(X.EVM_pct,[],'omitnan');
        r.EVM_Max_pct=max(X.EVM_pct,[],'omitnan');
        r.ACPR_Mean_dBc=mean(X.ACPR_dBc,'omitnan');
        r.ACPR_Std_dB=std(X.ACPR_dBc,'omitnan');
        r.RxPower_Mean_dBFS=mean(X.RxPower_dBFS,'omitnan');
        r.RxPower_Std_dB=std(X.RxPower_dBFS,'omitnan');
        r.MeterPower_Mean_dBm=mean(X.MeterPower_dBm,'omitnan');
        r.MeterPower_Std_dB=std(X.MeterPower_dBm,'omitnan');
        rows=[rows;r]; %#ok<AGROW>
    end
    T=struct2table(rows);
end

function T = buildPairedComparison(V)
    runs=unique(V.Run);
    rows=struct([]);
    for i=1:numel(runs)
        rnum=runs(i);
        M=V(V.Run==rnum & V.Condition=="MP" & V.UsableCapture,:);
        G=V(V.Run==rnum & V.Condition=="GMP" & V.UsableCapture,:);
        N=V(V.Run==rnum & V.Condition=="NODPD" & V.UsableCapture,:);
        if isempty(M)||isempty(G), continue; end
        r.Run=rnum;
        r.EVM_MP_pct=M.EVM_pct(1);
        r.EVM_GMP_pct=G.EVM_pct(1);
        r.EVM_MP_minus_GMP_pct=r.EVM_MP_pct-r.EVM_GMP_pct;
        r.ACPR_MP_dBc=M.ACPR_dBc(1);
        r.ACPR_GMP_dBc=G.ACPR_dBc(1);
        r.ACPR_MP_minus_GMP_dB=r.ACPR_MP_dBc-r.ACPR_GMP_dBc;
        r.RxPower_MP_dBFS=M.RxPower_dBFS(1);
        r.RxPower_GMP_dBFS=G.RxPower_dBFS(1);
        r.MeterPower_MP_dBm=M.MeterPower_dBm(1);
        r.MeterPower_GMP_dBm=G.MeterPower_dBm(1);
        if ~isempty(N)
            r.EVM_NoDPD_pct=N.EVM_pct(1);
            r.ACPR_NoDPD_dBc=N.ACPR_dBc(1);
        else
            r.EVM_NoDPD_pct=NaN;
            r.ACPR_NoDPD_dBc=NaN;
        end
        rows=[rows;r]; %#ok<AGROW>
    end
    T=struct2table(rows);
end

function result = firstUsableResult(resultCells)
    result=[];
    for i=1:numel(resultCells)
        if ~isempty(resultCells{i}) && resultCells{i}.usable
            result=resultCells{i};
            return;
        end
    end
    error('No usable verification result available for notebook export.');
end

function T = buildAMAMAMPMExportTable(txReference,txStruct,resultStruct,maxSamples,decim)
    conditions=["NODPD","MP","GMP"];
    allRows=table();

    for condition=conditions
        txApplied=txStruct.(char(condition));
        rx=resultStruct.(char(condition)).rxAligned(:);
        txApplied=txApplied(:);
        txReference=txReference(:);

        L=min([numel(txReference),numel(txApplied),numel(rx)]);
        txRef=txReference(1:L);
        txApp=txApplied(1:L);
        rx=rx(1:L);

        % Normalize measured RX to the original reference for fair AM/AM-AM/PM.
        alpha=(rx'*txRef)/(rx'*rx+eps);
        rxScaled=alpha*rx;

        idx=(1:decim:L).';
        if numel(idx)>maxSamples
            idx=idx(round(linspace(1,numel(idx),maxSamples)));
        end

        ampRef=abs(txRef(idx));
        ampRefNorm=ampRef/(max(abs(txRef))+eps);

        Tc=table();
        Tc.Condition=repmat(condition,numel(idx),1);
        Tc.SampleIndex=idx;
        Tc.InputAmplitude=ampRef;
        Tc.InputAmplitudeNormalized=ampRefNorm;
        Tc.TxAppliedAmplitude=abs(txApp(idx));
        Tc.RxOutputAmplitude=abs(rxScaled(idx));
        Tc.DPD_AM_Ratio=abs(txApp(idx))./(abs(txRef(idx))+eps);
        Tc.Chain_AM_Ratio=abs(rxScaled(idx))./(abs(txRef(idx))+eps);
        Tc.DPD_PhaseShift_rad=angle(txApp(idx).*conj(txRef(idx)));
        Tc.Chain_PhaseShift_rad=angle(rxScaled(idx).*conj(txRef(idx)));
        Tc.TxReference_I=real(txRef(idx));
        Tc.TxReference_Q=imag(txRef(idx));
        Tc.TxApplied_I=real(txApp(idx));
        Tc.TxApplied_Q=imag(txApp(idx));
        Tc.RxScaled_I=real(rxScaled(idx));
        Tc.RxScaled_Q=imag(rxScaled(idx));

        allRows=[allRows;Tc]; %#ok<AGROW>
    end
    T=allRows;
end

function T = buildPSDExportTable(resultStruct,fs,nfft,winLen)
    conditions=["NODPD","MP","GMP"];
    P=cell(numel(conditions),1);
    fCommon=[];

    for i=1:numel(conditions)
        x=resultStruct.(char(conditions(i))).rxAligned(:);
        N=min(numel(x),262144);
        x=x(1:N)-mean(x(1:N));
        w=hamming(min(winLen,N));
        [pxx,f]=pwelch(x,w,[],nfft,fs,'centered');
        pxxdB=10*log10(pxx+eps);
        pxxdB=pxxdB-max(pxxdB);
        P{i}=pxxdB;
        if isempty(fCommon), fCommon=f; end
    end

    T=table();
    T.Frequency_Hz=fCommon;
    T.Frequency_MHz=fCommon/1e6;
    T.PSD_NoDPD_dB=P{1};
    T.PSD_MP_dB=P{2};
    T.PSD_GMP_dB=P{3};
end

function T = buildWaveformExportMetadata(txStruct,resultStruct,fs,maxSamples,decim)
    conditions=["NODPD","MP","GMP"];
    rows=struct([]);
    for i=1:numel(conditions)
        c=conditions(i);
        tx=txStruct.(char(c));
        rx=resultStruct.(char(c));
        r.Condition=c;
        r.SampleRate_Hz=fs;
        r.TxSamples=numel(tx);
        r.RxAlignedSamples=numel(rx.rxAligned);
        r.ExportMaxSamples=maxSamples;
        r.ExportDecimation=decim;
        r.TxPAPR_dB=10*log10(max(abs(tx)).^2/(mean(abs(tx).^2)+eps));
        r.EVM_pct=rx.evm_pct;
        r.ACPR_dBc=rx.acpr_dBc;
        r.RxPower_dBFS=rx.rxPower_dBFS;
        rows=[rows;r]; %#ok<AGROW>
    end
    T=struct2table(rows);
end


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
        'LambdaRel', NaN, ...
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
        'DPDRawAveragePowerRatio_dB', NaN, ...
        'DPDPostAveragePowerRatio_dB', NaN, ...
        'DPDPeakScaleApplied', NaN, ...
        'DPDNumSamplesAbovePeak', NaN, ...
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
        'AveragePowerDiagnosticPass', false, ...
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
        'LambdaRel', NaN, ...
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
    % EXP016 / EXP008 result: best alignment mode is NORMAL_NO_CFO.
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

function [tx_dpd, diagInfo] = normalizeDPDWaveformDetailed(tx_dpd_raw, tx_ref, maxPeakRatio)
    tx_dpd_raw = tx_dpd_raw(:);
    tx_ref = tx_ref(:);

    pRef = mean(abs(tx_ref).^2);
    pRaw = mean(abs(tx_dpd_raw).^2);

    diagInfo = struct();
    diagInfo.RawAveragePowerRatio_dB = 10*log10((pRaw + eps)/(pRef + eps));
    diagInfo.PostAveragePowerRatio_dB = NaN;
    diagInfo.PeakScaleApplied = 1;
    diagInfo.NumSamplesAbovePeakBeforeScaling = 0;
    diagInfo.MaxAllowedPeak = maxPeakRatio * max(abs(tx_ref));
    diagInfo.RawPeak = max(abs(tx_dpd_raw));

    tx_dpd = tx_dpd_raw;

    % Step 1: normalize average digital power to the original waveform.
    if isfinite(pRef) && isfinite(pRaw) && pRef > 0 && pRaw > 0
        tx_dpd = tx_dpd * sqrt(pRef/pRaw);
    end

    % Step 2: enforce one global peak-scaling factor if the allowed peak is exceeded.
    maxAllowedPeak = diagInfo.MaxAllowedPeak;
    currentPeak = max(abs(tx_dpd));
    diagInfo.NumSamplesAbovePeakBeforeScaling = nnz(abs(tx_dpd) > maxAllowedPeak);

    if isfinite(currentPeak) && currentPeak > maxAllowedPeak && currentPeak > 0
        scaleFactor = maxAllowedPeak/currentPeak;
        tx_dpd = tx_dpd * scaleFactor;
        diagInfo.PeakScaleApplied = scaleFactor;
    end

    pPost = mean(abs(tx_dpd).^2);
    diagInfo.PostAveragePowerRatio_dB = 10*log10((pPost + eps)/(pRef + eps));
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

    % EXP016 v1:
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

        [pVals, vVals, adcVals, nValid, nInvalid] = readSTM32PowerBlock_EXP016( ...
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

function [powerValues_dB, voltageValues_V, adcValues_raw, nValid, nInvalid] = readSTM32PowerBlock_EXP016(stm, fidMeterRaw, label, iteration, txGain, rxGain)
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
