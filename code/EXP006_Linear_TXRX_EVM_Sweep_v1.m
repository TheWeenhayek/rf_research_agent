%% ========================================================================
%  EXP006 — LINEAR CONFIGURATION TX/RX EVM SWEEP
%  ------------------------------------------------------------------------
%  Purpose:
%    Find the best full-chain operating point under the linear observation
%    configuration before running the heavier metric experiments.
%
%  Physical configuration:
%    Pluto TX @ 5 GHz
%      -> IF board
%      -> ADMV1018/ADMV1017 upconverter
%      -> RF_OUT
%      -> B259MC1S 26 GHz filter
%      -> RF loopback attenuator
%      -> RF_IN downconverter
%      -> RX internal DSA manually configured in ACE
%      -> IF_OUT
%      -> Pluto RX
%
%  This script intentionally keeps the measurement simple:
%    - Sweeps Pluto TX gain and Pluto RX gain.
%    - Calculates only EVM from hNRDownlinkEVM.
%    - Does NOT use manual cross-correlation synchronization.
%    - Does NOT calculate ACPR, NMSE, or DPD metrics.
%    - Does NOT require STM32/LTC5596 measurement.
%
%  Recommended linear observation configuration:
%    - RF loopback physical attenuator = 20 dB
%    - RX internal DSA = 15 dB, configured manually in ACE
%    - IF_OUT physical attenuation = 0 dB
%
%  Requested sweep:
%    - TX gain: -44 to -35 dB, step 1 dB
%    - RX gain:   5 to  15 dB, step 1 dB
%
%  Basis:
%    This script follows the simpler Tx/Rx EVM sweep style of EXP0020,
%    and removes the heavier synchronization/ACPR/NMSE logic from the
%    previous EXP006 version.
% ========================================================================

clear; close all; clc;
warning('off','all');

%% ==================== USER CONFIGURATION ====================

try
    addpath(fullfile(matlabroot, 'examples', '5g', 'NRWaveformCaptureAndAnalysisWithSDRExample'));
catch
end

% SDR configuration
deviceName      = "Pluto";
centerFrequency = 5e9;
idleGain_dB     = -80;

% Sweep requested for linear operating-point search
TxGainList = (-39:1:-22).';
RxGainList = (14:1:15).';

% Waveform amplitude. Keep < 1 to avoid digital clipping at TX.
powerScaleFactor = 0.8;

% Linear observation-path metadata. This script does not command the
% ADMV1018 internal DSA. Set RX internal DSA manually in ACE before running.
rxInternalDsaAtten_dB = 5.0;
rfLoopbackAttenuator_dB = 20.0;
ifOutMeterProtectionAttenuator_dB = 0.0;

% Optional safety metadata from upconverter baseline.
% If the file exists, the script estimates RF_IN downconverter power.
% If it does not exist, the sweep still runs and those columns are NaN.
useUpconverterBaselineForMetadata = true;
rfInMaxAllowed_dBm = -8.0;
rfInSafetyMargin_dB = 1.0;
rfInPlanningLimit_dBm = rfInMaxAllowed_dBm - rfInSafetyMargin_dB;

% EVM capture settings
numFramesDiscard = 1;      % discard first frame after gain switching
numFramesUseful  = 2;      % useful 10 ms frames per Tx/Rx point
numFramesCapture = numFramesDiscard + numFramesUseful;

frameDuration_s = 10e-3;
captureTime_s = numFramesCapture * frameDuration_s;

% EVM acceptance settings
evmRejectLimit_pct = 50.0;     % values above this are kept as NaN
evmGoodThreshold_pct = 3.5;    % visual marker only
numBestPoints = 20;

% Settling times
rfSettleAfterTxChange_s = 0.45;
rfSettleAfterRxChange_s = 0.12;
rfOffSettle_s = 0.10;

% Optional raw capture storage. Keep false for fast sweep.
saveRawCaptures = false;

% Pluto TX output linear calibration metadata
plutoTxPowerSlope_dBperdB = 0.9935446912;
plutoTxPowerIntercept_dBm = -8.1924257506;
plutoTxPowerFitMin_dB = -29;
plutoTxPowerFitMax_dB = -14;
plutoTxPowerFitRMSE_dB = 0.0522602848;
plutoTxPowerFitR2 = 0.9998572208;

%% ==================== PATHS AND OUTPUT DIRECTORIES ====================

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir)
    scriptDir = pwd;
end

% Expected project layout:
%   DPDV2/code/this_script.m
%   DPDV2/baseline/
%   DPDV2/data/
projectDir = fileparts(scriptDir);
baselineDir = fullfile(projectDir, "baseline");
upconverterBaselineCsvFile = fullfile(baselineDir, "Baseline_Power_Upconverter_RFOUT.csv");

runTag = string(datetime("now","Format","yyyyMMdd_HHmmss"));
EXP_ID = "EXP006";
SHORT_NAME = "LINEAR_TXRX_EVM_SWEEP";
VERSION = "v1";

outputDir = fullfile(projectDir, "data", EXP_ID + "_" + SHORT_NAME + "_" + VERSION, runTag);
rawDir = fullfile(outputDir, "raw");
processedDir = fullfile(outputDir, "processed");
figuresDir = fullfile(outputDir, "figures");

if ~exist(rawDir,"dir"); mkdir(rawDir); end
if ~exist(processedDir,"dir"); mkdir(processedDir); end
if ~exist(figuresDir,"dir"); mkdir(figuresDir); end

baseName = EXP_ID + "_" + SHORT_NAME + "_" + runTag + "_" + VERSION;

csvPlanFile       = fullfile(processedDir, baseName + "_sweep-plan.csv");
csvFrameFile      = fullfile(rawDir,       baseName + "_evm-frame-by-frame.csv");
csvSummaryFile    = fullfile(processedDir, baseName + "_evm-summary.csv");
csvBestFile       = fullfile(processedDir, baseName + "_best-points.csv");
csvBestPerTxFile  = fullfile(processedDir, baseName + "_best-rx-per-tx.csv");
matFile           = fullfile(processedDir, baseName + "_results.mat");

fprintf("\nOutput directory:\n%s\n\n", outputDir);

%% ==================== 5G NR WAVEFORM GENERATION ====================

cfgDLFRC = nrDLCarrierConfig;
cfgDLFRC.Label = 'DL-FRC-FR1-256QAM';
cfgDLFRC.FrequencyRange = 'FR1';
cfgDLFRC.ChannelBandwidth = 20;
cfgDLFRC.NCellID = 1;
cfgDLFRC.NumSubframes = 10;
cfgDLFRC.InitialNSubframe = 0;
cfgDLFRC.WindowingPercent = 0;
cfgDLFRC.CarrierFrequency = 0;
cfgDLFRC.SampleRate = 61.44e6;

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

% PDSCH 1: main full-band 256-QAM data
pdsch1 = nrWavegenPDSCHConfig;
pdsch1.Enable = true;
pdsch1.Label = 'Full-band PDSCH sequence';
pdsch1.Power = 0;
pdsch1.BandwidthPartID = 1;
pdsch1.Modulation = '256QAM';
pdsch1.NumLayers = 1;
pdsch1.MappingType = 'A';
pdsch1.SymbolAllocation = [2 12];
pdsch1.SlotAllocation = 1:19;
pdsch1.Period = 20;
pdsch1.PRBSet = 0:50;
pdsch1.Coding = true;
pdsch1.TargetCodeRate = 0.7783203125;
pdsch1.DataSource = 'PN9';
pdsch1.RNTI = 0;
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

% PDSCH 2: OCNG slot 0, same style as previous sweep scripts
pdsch2 = nrWavegenPDSCHConfig;
pdsch2.Enable = true;
pdsch2.Label = 'Data Region OCNG slot 0';
pdsch2.Power = 0;
pdsch2.BandwidthPartID = 1;
pdsch2.Modulation = 'QPSK';
pdsch2.NumLayers = 1;
pdsch2.MappingType = 'A';
pdsch2.SymbolAllocation = [0 14];
pdsch2.SlotAllocation = 0;
pdsch2.Period = 20;
pdsch2.PRBSet = 0:50;
pdsch2.Coding = false;
pdsch2.DataSource = 'PN9';
pdsch2.RNTI = 2;

pdsch2DMRS = nrPDSCHDMRSConfig;
pdsch2DMRS.DMRSConfigurationType = 1;
pdsch2DMRS.DMRSReferencePoint = 'CRB0';
pdsch2DMRS.DMRSTypeAPosition = 2;
pdsch2DMRS.DMRSAdditionalPosition = 2;
pdsch2DMRS.NSCID = 0;
pdsch2DMRS.NumCDMGroupsWithoutData = 2;
pdsch2.DMRS = pdsch2DMRS;

% Some MATLAB versions do not accept custom fields above. Recreate safely if needed.
try
    cfgDLFRC.PDSCH = {pdsch1,pdsch2};
catch
    cfgDLFRC.PDSCH = {pdsch1};
end

[waveform, info] = nrWaveformGenerator(cfgDLFRC);
sampleRate = info.ResourceGrids(1).Info.SampleRate;

txWaveform = waveform .* (powerScaleFactor / max(abs(waveform)));
txWaveform = txWaveform(:);

% IMPORTANT: SDRTxPluto locks the input frame size after transmitRepeat().
% The idle waveform must keep exactly the same size as txWaveform.
idleTxWaveform = complex(zeros(size(txWaveform)));

samplesPerFrame = round(sampleRate * frameDuration_s);
totalSamplesNeeded = numFramesCapture * samplesPerFrame;

PAPR_dB = 10*log10(max(abs(txWaveform)).^2 / mean(abs(txWaveform).^2));

fprintf("===== EXP006 LINEAR TX/RX EVM SWEEP SETUP =====\n");
fprintf("TX sweep: %.1f to %.1f dB, step %.1f dB\n", TxGainList(1), TxGainList(end), TxGainList(2)-TxGainList(1));
fprintf("RX sweep: %.1f to %.1f dB, step %.1f dB\n", RxGainList(1), RxGainList(end), RxGainList(2)-RxGainList(1));
fprintf("Sample rate: %.2f Msps\n", sampleRate/1e6);
fprintf("Frames: discard %d, useful %d\n", numFramesDiscard, numFramesUseful);
fprintf("PAPR: %.2f dB\n", PAPR_dB);
fprintf("RX internal DSA metadata: %.1f dB\n", rxInternalDsaAtten_dB);
fprintf("RF loopback attenuator: %.1f dB\n", rfLoopbackAttenuator_dB);

%% ==================== EVM CONFIGURATION ====================
% This is intentionally non-manual synchronization. hNRDownlinkEVM handles
% carrier/frequency correction internally according to these flags.

cfgEVM = struct();
cfgEVM.PlotEVM = false;
cfgEVM.DisplayEVM = false;
cfgEVM.SampleRate = sampleRate;
cfgEVM.IQImbalance = true;
cfgEVM.TargetRNTIs = 0;
cfgEVM.CorrectCoarseFO = true;
cfgEVM.CorrectFineFO = true;
cfgEVM.ExcludeDC = true;

%% ==================== OPTIONAL BASELINE METADATA ====================

baselineAvailable = false;
txBase = [];
rfAfterFilterBase = [];
rfOutPinBase = [];
upCompBase = [];

if useUpconverterBaselineForMetadata && exist(upconverterBaselineCsvFile, "file")
    try
        Tup = readtable(upconverterBaselineCsvFile);
        requiredCols = ["TxGain_dB","RFOutAfterFilterCorrected_dBm","RFOutPinCorrected_dBm","UpconverterGainCompression_dB"];
        ok = true;
        for c = requiredCols
            ok = ok && ismember(c, string(Tup.Properties.VariableNames));
        end

        if ok
            txBase = Tup.TxGain_dB(:);
            [txBase, order] = sort(txBase);
            rfAfterFilterBase = Tup.RFOutAfterFilterCorrected_dBm(order);
            rfOutPinBase = Tup.RFOutPinCorrected_dBm(order);
            upCompBase = Tup.UpconverterGainCompression_dB(order);
            baselineAvailable = true;
            fprintf("Upconverter baseline loaded:\n%s\n", upconverterBaselineCsvFile);
        else
            warning("Upconverter baseline exists but required columns are missing. Metadata columns will be NaN.");
        end
    catch ME
        warning("Could not load upconverter baseline: %s", ME.message);
    end
else
    fprintf("No upconverter baseline found. Metadata columns will be NaN.\n");
end

%% ==================== SWEEP PLAN ====================

[TXGRID, RXGRID] = ndgrid(TxGainList, RxGainList);
TxGain_dB_plan = TXGRID(:);
RxGain_dB_plan = RXGRID(:);
nPoints = numel(TxGain_dB_plan);

PlutoOutCalibrated_dBm = plutoTxPowerSlope_dBperdB .* TxGain_dB_plan + plutoTxPowerIntercept_dBm;
PlutoCalibrationInFitRange = TxGain_dB_plan >= plutoTxPowerFitMin_dB & TxGain_dB_plan <= plutoTxPowerFitMax_dB;

RFOutAfterFilterEstimated_dBm = nan(nPoints,1);
RFOutPinEstimated_dBm = nan(nPoints,1);
UpconverterCompressionEstimated_dB = nan(nPoints,1);
DownconverterRFInputEstimated_dBm = nan(nPoints,1);
DownconverterRFInputPeakEnvelopeEstimated_dBm = nan(nPoints,1);
DownconverterAfterRxDsaEstimated_dBm = nan(nPoints,1);
DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm = nan(nPoints,1);
RFInputSafetyOK = true(nPoints,1);

if baselineAvailable
    RFOutAfterFilterEstimated_dBm = interp1(txBase, rfAfterFilterBase, TxGain_dB_plan, "linear", "extrap");
    RFOutPinEstimated_dBm = interp1(txBase, rfOutPinBase, TxGain_dB_plan, "linear", "extrap");
    UpconverterCompressionEstimated_dB = interp1(txBase, upCompBase, TxGain_dB_plan, "linear", "extrap");

    DownconverterRFInputEstimated_dBm = RFOutAfterFilterEstimated_dBm - rfLoopbackAttenuator_dB;
    DownconverterRFInputPeakEnvelopeEstimated_dBm = DownconverterRFInputEstimated_dBm + PAPR_dB;

    DownconverterAfterRxDsaEstimated_dBm = DownconverterRFInputEstimated_dBm - rxInternalDsaAtten_dB;
    DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm = DownconverterAfterRxDsaEstimated_dBm + PAPR_dB;

    RFInputSafetyOK = DownconverterRFInputEstimated_dBm <= rfInPlanningLimit_dBm;
end

sweepPlanTable = table( ...
    (1:nPoints).', ...
    TxGain_dB_plan, ...
    RxGain_dB_plan, ...
    PlutoOutCalibrated_dBm, ...
    PlutoCalibrationInFitRange, ...
    RFOutPinEstimated_dBm, ...
    RFOutAfterFilterEstimated_dBm, ...
    UpconverterCompressionEstimated_dB, ...
    DownconverterRFInputEstimated_dBm, ...
    DownconverterRFInputPeakEnvelopeEstimated_dBm, ...
    rxInternalDsaAtten_dB*ones(nPoints,1), ...
    DownconverterAfterRxDsaEstimated_dBm, ...
    DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm, ...
    RFInputSafetyOK, ...
    rfLoopbackAttenuator_dB*ones(nPoints,1), ...
    ifOutMeterProtectionAttenuator_dB*ones(nPoints,1), ...
    powerScaleFactor*ones(nPoints,1), ...
    'VariableNames', { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'RxGain_dB', ...
        'PlutoOutCalibrated_dBm', ...
        'PlutoCalibrationInFitRange', ...
        'RFOutPinEstimated_dBm', ...
        'RFOutAfterFilterEstimated_dBm', ...
        'UpconverterCompressionEstimated_dB', ...
        'DownconverterRFInputEstimated_dBm', ...
        'DownconverterRFInputPeakEnvelopeEstimated_dBm', ...
        'RxInternalDsaAtten_dB', ...
        'DownconverterAfterRxDsaEstimated_dBm', ...
        'DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm', ...
        'RFInputSafetyOK', ...
        'RFLoopbackAttenuator_dB', ...
        'IFOutMeterProtectionAttenuator_dB', ...
        'PowerScaleFactor'} ...
);

writetable(sweepPlanTable, csvPlanFile);

%% ==================== INITIALIZE SDR ====================

sdrTransmitter = sdrtx(deviceName);
sdrTransmitter.BasebandSampleRate = sampleRate;
sdrTransmitter.CenterFrequency = centerFrequency;
sdrTransmitter.Gain = idleGain_dB;

sdrReceiver = sdrrx(deviceName);
sdrReceiver.BasebandSampleRate = sampleRate;
sdrReceiver.CenterFrequency = centerFrequency;
sdrReceiver.OutputDataType = "double";
sdrReceiver.GainSource = "Manual";
sdrReceiver.Gain = RxGainList(1);

cleanupObj = onCleanup(@() cleanupEXP006LinearSweep(sdrTransmitter, sdrReceiver, idleGain_dB, idleTxWaveform));

%% ==================== PREALLOCATE FRAME RESULTS ====================

maxRows = nPoints * numFramesUseful;

Frame_PointIndex = zeros(maxRows,1);
Frame_TxGain_dB = zeros(maxRows,1);
Frame_RxGain_dB = zeros(maxRows,1);
Frame_FrameIndex = zeros(maxRows,1);
Frame_EVM_RMS_abs = nan(maxRows,1);
Frame_EVM_RMS_pct = nan(maxRows,1);
Frame_RxPower_dBFS = nan(maxRows,1);

row = 0;
lastTxGain = NaN;

%% ==================== MAIN TX/RX SWEEP ====================

fprintf("\n===== EXP006 LINEAR MAIN TX/RX EVM SWEEP =====\n");

try
    for iPoint = 1:height(sweepPlanTable)

        pointIndex = sweepPlanTable.PointIndex(iPoint);
        txGain = sweepPlanTable.TxGain_dB(iPoint);
        rxGain = sweepPlanTable.RxGain_dB(iPoint);

        fprintf("\n====================================\n");
        fprintf("Point %d/%d | Index = %d\n", iPoint, height(sweepPlanTable), pointIndex);
        fprintf("TxGain = %.2f dB | RxGain = %.2f dB\n", txGain, rxGain);

        if baselineAvailable
            fprintf("RF_IN est = %.2f dBm | after RX DSA est = %.2f dBm | Upconv comp est = %.2f dB\n", ...
                sweepPlanTable.DownconverterRFInputEstimated_dBm(iPoint), ...
                sweepPlanTable.DownconverterAfterRxDsaEstimated_dBm(iPoint), ...
                sweepPlanTable.UpconverterCompressionEstimated_dB(iPoint));

            if ~sweepPlanTable.RFInputSafetyOK(iPoint)
                warning("Skipping unsafe point: RF_IN estimated %.2f dBm > planning limit %.2f dBm", ...
                    sweepPlanTable.DownconverterRFInputEstimated_dBm(iPoint), rfInPlanningLimit_dBm);
                continue;
            end
        end
        fprintf("====================================\n");

        % TX update only when TxGain changes
        if isnan(lastTxGain) || txGain ~= lastTxGain
            fprintf("Updating TxGain to %.2f dB\n", txGain);
            sdrTransmitter.Gain = txGain;
            transmitRepeat(sdrTransmitter, txWaveform);
            pause(rfSettleAfterTxChange_s);
            lastTxGain = txGain;
        end

        % RX update
        sdrReceiver.Gain = rxGain;
        pause(rfSettleAfterRxChange_s);

        % Capture
        try
            rxWaveform = capture(sdrReceiver, captureTime_s, "Seconds");
        catch ME
            warning("Capture failed at Index %d | Tx %.2f / Rx %.2f: %s", ...
                pointIndex, txGain, rxGain, ME.message);
            continue;
        end

        if numel(rxWaveform) < totalSamplesNeeded
            warning("Insufficient capture at Index %d. Expected %d samples, got %d.", ...
                pointIndex, totalSamplesNeeded, numel(rxWaveform));
            continue;
        end

        rxWaveform = rxWaveform(1:totalSamplesNeeded);

        if saveRawCaptures
            rawFile = fullfile(rawDir, sprintf("raw_point_%03d_tx_%+05.1fdB_rx_%+05.1fdB.mat", ...
                pointIndex, txGain, rxGain));
            save(rawFile, "rxWaveform", "txGain", "rxGain", "powerScaleFactor");
        end

        evmPoint_pct = nan(numFramesUseful,1);
        rxPowerPoint_dBFS = nan(numFramesUseful,1);

        % Frame-by-frame EVM. No manual synchronization is used here.
        for frameIdx = 1:numFramesUseful
            realFrameIdx = frameIdx + numFramesDiscard;

            idx1 = (realFrameIdx - 1)*samplesPerFrame + 1;
            idx2 = realFrameIdx*samplesPerFrame;

            rxFrame = rxWaveform(idx1:idx2);

            rxPower_dBFS = 10*log10(mean(abs(rxFrame).^2) + eps);

            try
                evmInfo = hNRDownlinkEVM(cfgDLFRC, rxFrame, cfgEVM);

                evmRMS_abs_value = evmInfo.PDSCH.OverallEVM.RMS;
                evmRMS_pct_value = evmRMS_abs_value * 100;

                if evmRMS_pct_value > evmRejectLimit_pct
                    fprintf("  Frame %02d: EVM %.4f %% > %.2f %% -> NaN\n", ...
                        frameIdx, evmRMS_pct_value, evmRejectLimit_pct);
                    evmRMS_abs_value = NaN;
                    evmRMS_pct_value = NaN;
                end

            catch ME
                warning("EVM failed at Index %d | Tx %.2f / Rx %.2f / Frame %d: %s", ...
                    pointIndex, txGain, rxGain, frameIdx, ME.message);
                evmRMS_abs_value = NaN;
                evmRMS_pct_value = NaN;
            end

            evmPoint_pct(frameIdx) = evmRMS_pct_value;
            rxPowerPoint_dBFS(frameIdx) = rxPower_dBFS;

            row = row + 1;
            Frame_PointIndex(row) = pointIndex;
            Frame_TxGain_dB(row) = txGain;
            Frame_RxGain_dB(row) = rxGain;
            Frame_FrameIndex(row) = frameIdx;
            Frame_EVM_RMS_abs(row) = evmRMS_abs_value;
            Frame_EVM_RMS_pct(row) = evmRMS_pct_value;
            Frame_RxPower_dBFS(row) = rxPower_dBFS;

            fprintf("  Useful frame %02d/%02d: EVM = %.4f %% | RX power = %.2f dBFS\n", ...
                frameIdx, numFramesUseful, evmRMS_pct_value, rxPower_dBFS);
        end

        fprintf("  Point summary: EVM mean = %.4f %% | std = %.4f %% | RX mean = %.2f dBFS\n", ...
            mean(evmPoint_pct,"omitnan"), std(evmPoint_pct,"omitnan"), mean(rxPowerPoint_dBFS,"omitnan"));

        % Incremental save
        resultsFrame = table( ...
            Frame_PointIndex(1:row), ...
            Frame_TxGain_dB(1:row), ...
            Frame_RxGain_dB(1:row), ...
            Frame_FrameIndex(1:row), ...
            Frame_EVM_RMS_abs(1:row), ...
            Frame_EVM_RMS_pct(1:row), ...
            Frame_RxPower_dBFS(1:row), ...
            'VariableNames', { ...
                'PointIndex','TxGain_dB','RxGain_dB','FrameIndex', ...
                'EVM_RMS_abs','EVM_RMS_pct','RxPower_dBFS'} ...
        );

        summaryTable = buildSummaryTable(resultsFrame, sweepPlanTable);
        writetable(resultsFrame, csvFrameFile);
        writetable(summaryTable, csvSummaryFile);
        save(matFile, ...
            "sweepPlanTable","resultsFrame","summaryTable", ...
            "cfgDLFRC","cfgEVM","sampleRate","powerScaleFactor","PAPR_dB", ...
            "TxGainList","RxGainList","rxInternalDsaAtten_dB", ...
            "rfLoopbackAttenuator_dB","ifOutMeterProtectionAttenuator_dB", ...
            "txWaveform","idleTxWaveform");

        % Keep TX on while sweeping RX at same TX. Turn off only when TX changes.
        if iPoint < height(sweepPlanTable)
            nextTxGain = sweepPlanTable.TxGain_dB(iPoint + 1);
            if nextTxGain ~= txGain
                sdrTransmitter.Gain = idleGain_dB;
                transmitRepeat(sdrTransmitter, idleTxWaveform);
                pause(rfOffSettle_s);
                lastTxGain = NaN;
            end
        end
    end
catch ME
    warning("Error during EXP006 linear sweep: %s", ME.message);
end

%% ==================== SAFE SHUTDOWN ====================

fprintf("\nClosing SDR safely...\n");
try
    sdrTransmitter.Gain = idleGain_dB;
    transmitRepeat(sdrTransmitter, idleTxWaveform);
    pause(0.2);
catch
end

try; release(sdrTransmitter); catch; end
try; release(sdrReceiver); catch; end

%% ==================== FINAL TABLES ====================

resultsFrame = table( ...
    Frame_PointIndex(1:row), ...
    Frame_TxGain_dB(1:row), ...
    Frame_RxGain_dB(1:row), ...
    Frame_FrameIndex(1:row), ...
    Frame_EVM_RMS_abs(1:row), ...
    Frame_EVM_RMS_pct(1:row), ...
    Frame_RxPower_dBFS(1:row), ...
    'VariableNames', { ...
        'PointIndex','TxGain_dB','RxGain_dB','FrameIndex', ...
        'EVM_RMS_abs','EVM_RMS_pct','RxPower_dBFS'} ...
);

summaryTable = buildSummaryTable(resultsFrame, sweepPlanTable);

validSummary = summaryTable(isfinite(summaryTable.EVM_mean_pct), :);
validSummary = sortrows(validSummary, {'EVM_mean_pct','EVM_std_pct'}, {'ascend','ascend'});

nBest = min(numBestPoints, height(validSummary));
if nBest > 0
    bestPointsTable = validSummary(1:nBest,:);
else
    bestPointsTable = table();
end

% Best RX per TX, useful for picking the next fixed-RX configuration
bestRows = [];
for k = 1:numel(TxGainList)
    mask = summaryTable.TxGain_dB == TxGainList(k) & isfinite(summaryTable.EVM_mean_pct);
    if any(mask)
        idx = find(mask);
        [~, localIdx] = min(summaryTable.EVM_mean_pct(idx));
        bestRows(end+1,1) = idx(localIdx); %#ok<AGROW>
    end
end

if ~isempty(bestRows)
    bestPerTxTable = summaryTable(bestRows,:);
else
    bestPerTxTable = table();
end

validUnderThresholdTable = validSummary(validSummary.EVM_mean_pct < evmGoodThreshold_pct, :);

fprintf("\n========== EVM SUMMARY BY TX/RX POINT ==========%s", newline);
disp(summaryTable);

fprintf("\n========== BEST POINTS ==========%s", newline);
disp(bestPointsTable);

fprintf("\n========== BEST RX PER TX ==========%s", newline);
disp(bestPerTxTable);

fprintf("\n========== POINTS WITH EVM < %.2f %% ==========%s", evmGoodThreshold_pct, newline);
disp(validUnderThresholdTable);

writetable(resultsFrame, csvFrameFile);
writetable(summaryTable, csvSummaryFile);
writetable(bestPointsTable, csvBestFile);
writetable(bestPerTxTable, csvBestPerTxFile);

save(matFile, ...
    "sweepPlanTable","resultsFrame","summaryTable","bestPointsTable","bestPerTxTable","validUnderThresholdTable", ...
    "cfgDLFRC","cfgEVM","sampleRate","powerScaleFactor","PAPR_dB", ...
    "TxGainList","RxGainList","rxInternalDsaAtten_dB", ...
    "rfLoopbackAttenuator_dB","ifOutMeterProtectionAttenuator_dB", ...
    "txWaveform","idleTxWaveform", ...
    "plutoTxPowerSlope_dBperdB","plutoTxPowerIntercept_dBm", ...
    "baselineAvailable","upconverterBaselineCsvFile");

%% ==================== FIGURES ====================

try
    % EVM heatmap
    plotHeatmap(summaryTable, "EVM_mean_pct", "Mean EVM (%)", figuresDir, baseName);

    % RX power heatmap
    plotHeatmap(summaryTable, "RxPower_mean_dBFS", "Mean RX power (dBFS)", figuresDir, baseName);

    % Best RX per TX curve
    if ~isempty(bestPerTxTable)
        h1 = figure("Name","Best RX per TX","Color","w");
        tiledlayout(2,1);

        nexttile;
        plot(bestPerTxTable.TxGain_dB, bestPerTxTable.EVM_mean_pct, "o-", "LineWidth", 1.2);
        grid on;
        xlabel("Pluto TX gain [dB]");
        ylabel("Mean EVM [%]");
        title("EXP006 linear sweep: best EVM per TX gain");

        nexttile;
        plot(bestPerTxTable.TxGain_dB, bestPerTxTable.RxGain_dB, "s-", "LineWidth", 1.2);
        grid on;
        xlabel("Pluto TX gain [dB]");
        ylabel("Selected Pluto RX gain [dB]");
        title("Selected RX gain for each TX gain");

        saveas(h1, fullfile(figuresDir, baseName + "_best-rx-per-tx.png"));
    end

    % Scatter overview
    h2 = figure("Name","EVM scatter","Color","w");
    scatter(summaryTable.TxGain_dB, summaryTable.RxGain_dB, 90, summaryTable.EVM_mean_pct, "filled", "MarkerEdgeColor", "k");
    xlabel("Pluto TX gain [dB]");
    ylabel("Pluto RX gain [dB]");
    title(sprintf("EXP006 linear sweep: mean EVM, %d useful frames", numFramesUseful));
    colorbar;
    grid on;
    hold on;

    goodMask = summaryTable.EVM_mean_pct < evmGoodThreshold_pct;
    scatter(summaryTable.TxGain_dB(goodMask), summaryTable.RxGain_dB(goodMask), 150, "o", "LineWidth", 1.8);

    if ~isempty(bestPointsTable)
        scatter(bestPointsTable.TxGain_dB, bestPointsTable.RxGain_dB, 180, "p", "filled", "MarkerEdgeColor", "k");
    end

    legend("EVM mean", sprintf("EVM < %.1f %%", evmGoodThreshold_pct), "Top points", "Location", "bestoutside");
    hold off;
    saveas(h2, fullfile(figuresDir, baseName + "_evm-scatter.png"));

catch ME
    warning("Could not create figures: %s", ME.message);
end

fprintf("\n============================================\n");
fprintf("EXP006 LINEAR TX/RX EVM SWEEP FINISHED\n");
fprintf("Sweep plan       : %s\n", csvPlanFile);
fprintf("Frame EVM CSV    : %s\n", csvFrameFile);
fprintf("Summary CSV      : %s\n", csvSummaryFile);
fprintf("Best points CSV  : %s\n", csvBestFile);
fprintf("Best RX/TX CSV   : %s\n", csvBestPerTxFile);
fprintf("MAT file         : %s\n", matFile);
fprintf("============================================\n");

warning('on','all');

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function summaryTable = buildSummaryTable(resultsFrame, sweepPlanTable)

    if isempty(resultsFrame) || height(resultsFrame) == 0
        summaryTable = sweepPlanTable;
        summaryTable.GroupCount = zeros(height(summaryTable),1);
        summaryTable.EVM_mean_pct = nan(height(summaryTable),1);
        summaryTable.EVM_std_pct = nan(height(summaryTable),1);
        summaryTable.EVM_min_pct = nan(height(summaryTable),1);
        summaryTable.EVM_max_pct = nan(height(summaryTable),1);
        summaryTable.RxPower_mean_dBFS = nan(height(summaryTable),1);
        summaryTable.RxPower_std_dBFS = nan(height(summaryTable),1);
        return;
    end

    G = groupsummary( ...
        resultsFrame, ...
        {'PointIndex','TxGain_dB','RxGain_dB'}, ...
        {'mean','std','min','max'}, ...
        {'EVM_RMS_pct','RxPower_dBFS'} ...
    );

    % Rename columns for readability
    if ismember('mean_EVM_RMS_pct', G.Properties.VariableNames)
        G.Properties.VariableNames{'mean_EVM_RMS_pct'} = 'EVM_mean_pct';
    end
    if ismember('std_EVM_RMS_pct', G.Properties.VariableNames)
        G.Properties.VariableNames{'std_EVM_RMS_pct'} = 'EVM_std_pct';
    end
    if ismember('min_EVM_RMS_pct', G.Properties.VariableNames)
        G.Properties.VariableNames{'min_EVM_RMS_pct'} = 'EVM_min_pct';
    end
    if ismember('max_EVM_RMS_pct', G.Properties.VariableNames)
        G.Properties.VariableNames{'max_EVM_RMS_pct'} = 'EVM_max_pct';
    end
    if ismember('mean_RxPower_dBFS', G.Properties.VariableNames)
        G.Properties.VariableNames{'mean_RxPower_dBFS'} = 'RxPower_mean_dBFS';
    end
    if ismember('std_RxPower_dBFS', G.Properties.VariableNames)
        G.Properties.VariableNames{'std_RxPower_dBFS'} = 'RxPower_std_dBFS';
    end

    % Merge metadata from sweep plan
    metaCols = setdiff(sweepPlanTable.Properties.VariableNames, {'PointIndex','TxGain_dB','RxGain_dB'}, 'stable');
    summaryTable = outerjoin( ...
        sweepPlanTable, ...
        G, ...
        'Keys', {'PointIndex','TxGain_dB','RxGain_dB'}, ...
        'MergeKeys', true, ...
        'Type', 'left' ...
    );

    % Keep a practical column order
    preferred = [ ...
        "PointIndex","TxGain_dB","RxGain_dB","GroupCount", ...
        "EVM_mean_pct","EVM_std_pct","EVM_min_pct","EVM_max_pct", ...
        "RxPower_mean_dBFS","RxPower_std_dBFS", ...
        string(metaCols) ...
    ];

    existingPreferred = preferred(ismember(preferred, string(summaryTable.Properties.VariableNames)));
    remaining = setdiff(string(summaryTable.Properties.VariableNames), existingPreferred, 'stable');
    summaryTable = summaryTable(:, [cellstr(existingPreferred), cellstr(remaining)]);
end

function plotHeatmap(T, metricName, metricLabel, figuresDir, baseName)

    if isempty(T) || ~ismember(metricName, string(T.Properties.VariableNames))
        return;
    end

    txVals = unique(T.TxGain_dB);
    rxVals = unique(T.RxGain_dB);
    Z = nan(numel(rxVals), numel(txVals));

    for i = 1:numel(txVals)
        for j = 1:numel(rxVals)
            mask = T.TxGain_dB == txVals(i) & T.RxGain_dB == rxVals(j);
            if any(mask)
                Z(j,i) = T.(metricName)(find(mask,1,'first'));
            end
        end
    end

    h = figure("Name", metricLabel, "Color", "w");
    imagesc(txVals, rxVals, Z);
    axis xy;
    colorbar;
    xlabel("Pluto TX gain [dB]");
    ylabel("Pluto RX gain [dB]");
    title("EXP006 linear sweep: " + metricLabel);
    saveas(h, fullfile(figuresDir, baseName + "_" + metricName + "_heatmap.png"));
end

function cleanupEXP006LinearSweep(txObj, rxObj, idleGain, idleTxWaveform)
    try
        txObj.Gain = idleGain;
        transmitRepeat(txObj, idleTxWaveform);
    catch
    end
    try; release(txObj); catch; end
    try; release(rxObj); catch; end
end
