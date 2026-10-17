%% ========================================================================
%  EXP006 — FULL-CHAIN TX/RX SWEEP FOR DPD OPERATING REGION
%  ------------------------------------------------------------------------
%  Physical configuration:
%    Pluto TX @ 5 GHz
%      -> IF board
%      -> ADMV1018 upconverter
%      -> RF_OUT
%      -> B259MC1S 26 GHz filter
%      -> RF loopback attenuator
%      -> RF_IN downconverter
%      -> RX internal DSA manually configured in ACE
%      -> IF_OUT
%      -> detector / STM32 power meter
%      -> Pluto RX
%
%  Objective:
%    Sweep Pluto TX gain and Pluto RX gain while keeping the downconverter
%    observation path sufficiently linear. Save:
%      - EVM RMS (%)
%      - ACPR (dBc)
%      - NMSE (dB), after complex gain/phase alignment
%      - Pout / IF_OUT measured physical power (dBm)
%      - RX digital power (dBFS)
%      - sync metric, frequency offset, detector voltage, detector dBm
%
%  Requested sweep:
%      TX gain: -44 to -35 dB, step 0.5 dB
%      RX gain:   5 to  15 dB, step 1 dB
%
%  Notes:
%    1) The ADMV1018 RX internal DSA is NOT controlled by this MATLAB script.
%       Set it manually in ACE/TICS before running. This value is stored as
%       metadata only.
%    2) The RF_IN physical power is estimated from the EXP003 RF_OUT baseline
%       and the physical RF loopback attenuator. The internal DSA does not
%       protect the RF_IN pin; it only reduces internal RX chain drive.
%    3) ifOutMeterProtectionAttenuator_dB = 0 dB unless a physical attenuator
%       is inserted between IF_OUT and the detector/Pluto RX.
% ========================================================================

clear; close all; clc;
warning('off','all');

%% ==================== USER CONFIGURATION ====================

% Project / paths
scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir); scriptDir = pwd; end
projectDir = fileparts(scriptDir);

% If this script is run outside DPDV2/code, adjust projectDir manually here:
% projectDir = "C:\...\DPDV2";

baselineDir = fullfile(projectDir, "baseline");
upconverterBaselineCsvFile = fullfile(baselineDir, "Baseline_Power_Upconverter_RFOUT.csv");

% SDR
deviceName      = "Pluto";
centerFrequency = 5e9;
idleGain_dB     = -80;

% Requested sweep
txGainList = (-35:0.5:-28).';
rxGainList = (14:1:15).';

% Waveform
powerScaleFactor = 0.8;
captureTime_s = 30e-3;

% ADMV1018 / RF chain metadata
rfLoopbackAttenuator_dB = 20.0;      % physical attenuator from RF_OUT-after-filter to RF_IN
rxInternalDsaAtten_dB   = 15.0;      % manually set in ACE; metadata only
ifOutMeterProtectionAttenuator_dB = 0.0;
ifOutMeasurementCorrection_dB = ifOutMeterProtectionAttenuator_dB;

% Safety planning based on physical RF_IN pin power.
% The DSA internal attenuation is NOT used to protect the RF_IN pin.
rfInMaxAllowed_dBm = -8.0;
rfInSafetyMargin_dB = 1.0;
rfInPlanningLimit_dBm = rfInMaxAllowed_dBm - rfInSafetyMargin_dB;

% STM32 detector
useSTM32PowerMeter = true;
stm32Port = "COM12";
stm32Baud = 209700;
stm32Terminator = "LF";
ifDetectorSamplesPerPoint = 80;

% Capture/EVM
minSyncMetric = 0.96;
maxCaptureAttempts = 3;
evmRetryThreshold_pct = 50;
maxValidEVM_pct = 50;

% RX saturation guard
digitalRxSaturationLimit_dBFS = -1.0;

% Raw capture storage
saveRawCaptures = false;

% Pluto TX power calibration metadata
usePlutoTxLinearModel = true;
plutoTxPowerSlope_dBperdB = 0.9935446912;
plutoTxPowerIntercept_dBm = -8.1924257506;
plutoTxPowerFitMin_dB = -29;
plutoTxPowerFitMax_dB = -14;
plutoTxPowerFitRMSE_dB = 0.0522602848;
plutoTxPowerFitR2 = 0.9998572208;

%% ==================== OUTPUT DIRECTORIES ====================

runTag = string(datetime("now","Format","yyyyMMdd_HHmmss"));
EXP_ID = "EXP006";
SHORT_NAME = "FULLCHAIN_TXRX_SWEEP_EVM_ACPR_NMSE";
VERSION = "v1";

outputDir = fullfile(projectDir, "data", EXP_ID + "_" + SHORT_NAME + "_" + VERSION, runTag);
rawDir = fullfile(outputDir, "raw");
processedDir = fullfile(outputDir, "processed");
figuresDir = fullfile(outputDir, "figures");

if ~exist(rawDir,"dir"); mkdir(rawDir); end
if ~exist(processedDir,"dir"); mkdir(processedDir); end
if ~exist(figuresDir,"dir"); mkdir(figuresDir); end

baseName = EXP_ID + "_" + SHORT_NAME + "_" + runTag + "_" + VERSION;
csvSummaryFile = fullfile(processedDir, baseName + "_summary.csv");
csvPlanFile = fullfile(processedDir, baseName + "_sweep-plan.csv");
csvBestPerTxFile = fullfile(processedDir, baseName + "_best-rx-per-tx.csv");
matFile = fullfile(processedDir, baseName + "_results.mat");

%% ==================== 5G NR WAVEFORM GENERATION ====================

try
    addpath(fullfile(matlabroot, 'examples', '5g', 'NRWaveformCaptureAndAnalysisWithSDRExample'));
catch
end

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
cfgDLFRC.PDSCH = {pdsch1};

[waveform, info] = nrWaveformGenerator(cfgDLFRC);
sampleRate = info.ResourceGrids(1).Info.SampleRate;

txWaveform = waveform * (powerScaleFactor / max(abs(waveform)));
txWaveform = txWaveform(:);

% IMPORTANT: SDRTxPluto locks the input frame size after the first
% transmitRepeat() call. Therefore, the idle waveform must have exactly
% the same size and complexity as txWaveform. Do not use zeros(1000,1).
idleTxWaveform = complex(zeros(size(txWaveform)));

PAPR_dB = 10*log10(max(abs(txWaveform)).^2 / mean(abs(txWaveform).^2));
samplesPerFrame = round(sampleRate*10e-3);
totalSamplesNeeded = round(captureTime_s*sampleRate);

fprintf("\n===== EXP006 SETUP =====\n");
fprintf("TX sweep: %.1f to %.1f dB, step %.1f dB\n", txGainList(1), txGainList(end), txGainList(2)-txGainList(1));
fprintf("RX sweep: %.1f to %.1f dB, step %.1f dB\n", rxGainList(1), rxGainList(end), rxGainList(2)-rxGainList(1));
fprintf("PAPR = %.2f dB\n", PAPR_dB);
fprintf("RX internal DSA metadata = %.1f dB\n", rxInternalDsaAtten_dB);
fprintf("RF loopback attenuator = %.1f dB\n", rfLoopbackAttenuator_dB);

%% ==================== LOAD EXP003 UPCONVERTER BASELINE ====================

if ~exist(upconverterBaselineCsvFile, "file")
    error("Missing baseline file: %s", upconverterBaselineCsvFile);
end

Tup = readtable(upconverterBaselineCsvFile);
requiredCols = ["TxGain_dB","RFOutAfterFilterCorrected_dBm","RFOutPinCorrected_dBm","UpconverterGainCompression_dB"];
for c = requiredCols
    if ~ismember(c, string(Tup.Properties.VariableNames))
        error("Baseline missing required column: %s", c);
    end
end

txBase = Tup.TxGain_dB(:);
[txBase, order] = sort(txBase);
rfAfterFilterBase = Tup.RFOutAfterFilterCorrected_dBm(order);
rfOutPinBase = Tup.RFOutPinCorrected_dBm(order);
upCompBase = Tup.UpconverterGainCompression_dB(order);

%% ==================== SWEEP PLAN ====================

[TXGRID, RXGRID] = ndgrid(txGainList, rxGainList);
TxGain_dB_plan = TXGRID(:);
RxGain_dB_plan = RXGRID(:);
nPoints = numel(TxGain_dB_plan);

RFOutAfterFilterEstimated_dBm = interp1(txBase, rfAfterFilterBase, TxGain_dB_plan, "linear", "extrap");
RFOutPinEstimated_dBm = interp1(txBase, rfOutPinBase, TxGain_dB_plan, "linear", "extrap");
UpconverterCompressionEstimated_dB = interp1(txBase, upCompBase, TxGain_dB_plan, "linear", "extrap");

DownconverterRFInputEstimated_dBm = RFOutAfterFilterEstimated_dBm - rfLoopbackAttenuator_dB;
DownconverterRFInputPeakEnvelopeEstimated_dBm = DownconverterRFInputEstimated_dBm + PAPR_dB;

DownconverterAfterRxDsaEstimated_dBm = DownconverterRFInputEstimated_dBm - rxInternalDsaAtten_dB;
DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm = DownconverterAfterRxDsaEstimated_dBm + PAPR_dB;

PlutoOutCalibrated_dBm = plutoTxPowerSlope_dBperdB .* TxGain_dB_plan + plutoTxPowerIntercept_dBm;
RFInputSafetyOK = DownconverterRFInputEstimated_dBm <= rfInPlanningLimit_dBm;

if any(~RFInputSafetyOK)
    warning("Some points exceed RF_IN planning limit %.2f dBm. They will be skipped.", rfInPlanningLimit_dBm);
end

sweepPlanTable = table( ...
    (1:nPoints).', TxGain_dB_plan, RxGain_dB_plan, PlutoOutCalibrated_dBm, ...
    RFOutPinEstimated_dBm, RFOutAfterFilterEstimated_dBm, UpconverterCompressionEstimated_dB, ...
    DownconverterRFInputEstimated_dBm, DownconverterRFInputPeakEnvelopeEstimated_dBm, ...
    rxInternalDsaAtten_dB*ones(nPoints,1), ...
    DownconverterAfterRxDsaEstimated_dBm, DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm, ...
    RFInputSafetyOK, ...
    rfLoopbackAttenuator_dB*ones(nPoints,1), ...
    ifOutMeterProtectionAttenuator_dB*ones(nPoints,1), ...
    powerScaleFactor*ones(nPoints,1), ...
    'VariableNames', { ...
        'PointIndex','TxGain_dB','RxGain_dB','PlutoOutCalibrated_dBm', ...
        'RFOutPinEstimated_dBm','RFOutAfterFilterEstimated_dBm','UpconverterCompressionEstimated_dB', ...
        'DownconverterRFInputEstimated_dBm','DownconverterRFInputPeakEnvelopeEstimated_dBm', ...
        'RxInternalDsaAtten_dB', ...
        'DownconverterAfterRxDsaEstimated_dBm','DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm', ...
        'RFInputSafetyOK','RFLoopbackAttenuator_dB','IFOutMeterProtectionAttenuator_dB','PowerScaleFactor'} ...
);

writetable(sweepPlanTable, csvPlanFile);

%% ==================== EVM CONFIGURATION ====================

cfgEVM = struct();
cfgEVM.PlotEVM = false;
cfgEVM.DisplayEVM = false;
cfgEVM.SampleRate = sampleRate;
cfgEVM.IQImbalance = false;
cfgEVM.TargetRNTIs = 0;
cfgEVM.CorrectCoarseFO = false;
cfgEVM.CorrectFineFO = false;
cfgEVM.ExcludeDC = true;

%% ==================== INITIALIZE STM32 ====================

stm32 = [];
if useSTM32PowerMeter
    stm32 = serialport(stm32Port, stm32Baud, "Timeout", 3);
    configureTerminator(stm32, stm32Terminator);
    flush(stm32);
    try
        pongLine = querySTM32(stm32, "PING", "PONG", 3);
        fprintf("[STM32] OK: %s\n", pongLine);
    catch ME
        warning("STM32 PING failed: %s", ME.message);
    end
end

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
sdrReceiver.Gain = rxGainList(1);

cleanupObj = onCleanup(@() cleanupEXP006(sdrTransmitter, sdrReceiver, idleGain_dB, stm32, idleTxWaveform));

%% ==================== PREALLOCATE ====================

EVM_RMS_pct = nan(nPoints,1);
ACPR_dBc = nan(nPoints,1);
NMSE_dB = nan(nPoints,1);
SyncMetric = nan(nPoints,1);
FreqOffset_Hz = nan(nPoints,1);
RxPower_dBFS = nan(nPoints,1);
TxPower_dBFS = nan(nPoints,1);
DigitalGain_dB = nan(nPoints,1);
CaptureAttempts = nan(nPoints,1);
EVMRetryFailed = false(nPoints,1);

STM32_IFRaw_mean = nan(nPoints,1);
STM32_IFVoltage_mean_V = nan(nPoints,1);
STM32_IFVoltage_mean_mV = nan(nPoints,1);
STM32_IFOut_mean_dBm = nan(nPoints,1);
IFOutCorrected_dBm = nan(nPoints,1);

BestAttemptUsed = strings(nPoints,1);

%% ==================== MAIN SWEEP ====================

fprintf("\n===== EXP006 MAIN TX/RX SWEEP =====\n");

for iPoint = 1:nPoints
    txGain = sweepPlanTable.TxGain_dB(iPoint);
    rxGain = sweepPlanTable.RxGain_dB(iPoint);

    fprintf("\nPoint %d/%d | TX %.2f dB | RX %.2f dB\n", iPoint, nPoints, txGain, rxGain);
    fprintf("  RF_IN est = %.2f dBm | after RX DSA est = %.2f dBm | Upconv comp est = %.2f dB\n", ...
        sweepPlanTable.DownconverterRFInputEstimated_dBm(iPoint), ...
        sweepPlanTable.DownconverterAfterRxDsaEstimated_dBm(iPoint), ...
        sweepPlanTable.UpconverterCompressionEstimated_dB(iPoint));

    if ~sweepPlanTable.RFInputSafetyOK(iPoint)
        warning("Skipping unsafe point: RF_IN estimated %.2f dBm > planning limit %.2f dBm", ...
            sweepPlanTable.DownconverterRFInputEstimated_dBm(iPoint), rfInPlanningLimit_dBm);
        continue;
    end

    % TX
    sdrTransmitter.Gain = txGain;
    transmitRepeat(sdrTransmitter, txWaveform);
    pause(0.45);

    % Detector measurement
    if useSTM32PowerMeter
        try
            pwr = measureIFPowerSTM32(stm32, txGain, ifDetectorSamplesPerPoint);
            STM32_IFRaw_mean(iPoint) = pwr.raw_mean;
            STM32_IFVoltage_mean_V(iPoint) = pwr.voltage_mean_V;
            STM32_IFVoltage_mean_mV(iPoint) = 1000*pwr.voltage_mean_V;
            STM32_IFOut_mean_dBm(iPoint) = pwr.dBm_mean;
            IFOutCorrected_dBm(iPoint) = pwr.dBm_mean + ifOutMeasurementCorrection_dB;
            fprintf("  STM32 IF_OUT = %.2f dBm | %.3f V | N=%d\n", pwr.dBm_mean, pwr.voltage_mean_V, pwr.n_valid);
        catch ME
            warning("STM32 measurement failed: %s", ME.message);
        end
    end

    best = struct();
    best.evm = Inf; best.acpr = NaN; best.nmse = NaN; best.sync = NaN; best.fo = NaN;
    best.rxpow = NaN; best.txpow = NaN; best.diggain = NaN; best.rxAligned = [];
    accepted = false;

    for attempt = 1:maxCaptureAttempts
        fprintf("  Capture attempt %d/%d\n", attempt, maxCaptureAttempts);
        sdrReceiver.Gain = rxGain;
        pause(0.10);

        rxCapture = capture(sdrReceiver, captureTime_s, "Seconds");
        if length(rxCapture) < totalSamplesNeeded
            warning("Insufficient capture.");
            continue;
        end
        rxCapture = rxCapture(1:totalSamplesNeeded);

        if saveRawCaptures
            save(fullfile(rawDir, sprintf("raw_p%03d_tx_%+.1f_rx_%+.1f_attempt_%d.mat", iPoint, txGain, rxGain, attempt)), ...
                "rxCapture","txGain","rxGain","powerScaleFactor");
        end

        [rxAligned, freqOffset, syncMetric] = synchronizeFineXcorr(txWaveform, rxCapture, cfgDLFRC);
        fprintf("    Sync = %.4f | FO = %.2f Hz\n", syncMetric, freqOffset);

        if isempty(rxAligned) || syncMetric < minSyncMetric
            continue;
        end

        t = (0:length(rxAligned)-1).'/sampleRate;
        rxAligned = rxAligned(:).*exp(-1i*2*pi*freqOffset*t);

        txSeg = txWaveform(1:samplesPerFrame);
        rxSeg = rxAligned(1:samplesPerFrame);

        txPower_dBFS = 10*log10(mean(abs(txSeg).^2) + eps);
        rxPower_dBFS = 10*log10(mean(abs(rxSeg).^2) + eps);
        digitalGain_dB = rxPower_dBFS - txPower_dBFS - txGain;

        evmPct = NaN;
        try
            [evmInfo, ~, ~] = hNRDownlinkEVM(cfgDLFRC, rxSeg, cfgEVM);
            evmPct = evmInfo.PDSCH.OverallEVM.RMS * 100;
        catch ME
            fprintf("    EVM failed: %s\n", ME.message);
        end

        acpr = computeACPRCentered(rxAligned, sampleRate, 20e6);
        nmse = computeNMSEComplexGain(txWaveform, rxAligned, samplesPerFrame);

        fprintf("    EVM = %.3f %% | ACPR = %.2f dBc | NMSE = %.2f dB | RX = %.2f dBFS\n", ...
            evmPct, acpr, nmse, rxPower_dBFS);

        if isfinite(evmPct) && evmPct < best.evm
            best.evm = evmPct;
            best.acpr = acpr;
            best.nmse = nmse;
            best.sync = syncMetric;
            best.fo = freqOffset;
            best.rxpow = rxPower_dBFS;
            best.txpow = txPower_dBFS;
            best.diggain = digitalGain_dB;
            best.rxAligned = rxAligned;
            BestAttemptUsed(iPoint) = "lowest_finite_EVM";
        elseif ~isfinite(best.evm) && syncMetric > best.sync
            best.evm = evmPct;
            best.acpr = acpr;
            best.nmse = nmse;
            best.sync = syncMetric;
            best.fo = freqOffset;
            best.rxpow = rxPower_dBFS;
            best.txpow = txPower_dBFS;
            best.diggain = digitalGain_dB;
            best.rxAligned = rxAligned;
            BestAttemptUsed(iPoint) = "best_sync_no_valid_EVM";
        end

        if isfinite(evmPct) && evmPct < evmRetryThreshold_pct
            accepted = true;
            break;
        end
    end

    CaptureAttempts(iPoint) = attempt;
    if ~accepted
        EVMRetryFailed(iPoint) = true;
    end

    if isfinite(best.sync) && best.sync >= minSyncMetric && isfinite(best.evm) && best.evm < maxValidEVM_pct
        EVM_RMS_pct(iPoint) = best.evm;
        ACPR_dBc(iPoint) = best.acpr;
        NMSE_dB(iPoint) = best.nmse;
        SyncMetric(iPoint) = best.sync;
        FreqOffset_Hz(iPoint) = best.fo;
        RxPower_dBFS(iPoint) = best.rxpow;
        TxPower_dBFS(iPoint) = best.txpow;
        DigitalGain_dB(iPoint) = best.diggain;
    else
        SyncMetric(iPoint) = best.sync;
        FreqOffset_Hz(iPoint) = best.fo;
    end

    % Incremental save
    phase6Summary = buildEXP006Summary(sweepPlanTable, ...
        STM32_IFRaw_mean, STM32_IFVoltage_mean_V, STM32_IFVoltage_mean_mV, STM32_IFOut_mean_dBm, IFOutCorrected_dBm, ...
        EVM_RMS_pct, ACPR_dBc, NMSE_dB, SyncMetric, FreqOffset_Hz, RxPower_dBFS, TxPower_dBFS, DigitalGain_dB, ...
        CaptureAttempts, EVMRetryFailed, BestAttemptUsed);

    writetable(phase6Summary, csvSummaryFile);
    save(matFile, "phase6Summary","sweepPlanTable","cfgDLFRC","sampleRate","txWaveform","PAPR_dB", ...
        "txGainList","rxGainList","powerScaleFactor","rxInternalDsaAtten_dB","rfLoopbackAttenuator_dB", ...
        "ifOutMeterProtectionAttenuator_dB","upconverterBaselineCsvFile","idleTxWaveform");

    sdrTransmitter.Gain = idleGain_dB;
    transmitRepeat(sdrTransmitter, idleTxWaveform);
    pause(0.10);
end

%% ==================== FINAL TABLES ====================

phase6Summary = buildEXP006Summary(sweepPlanTable, ...
    STM32_IFRaw_mean, STM32_IFVoltage_mean_V, STM32_IFVoltage_mean_mV, STM32_IFOut_mean_dBm, IFOutCorrected_dBm, ...
    EVM_RMS_pct, ACPR_dBc, NMSE_dB, SyncMetric, FreqOffset_Hz, RxPower_dBFS, TxPower_dBFS, DigitalGain_dB, ...
    CaptureAttempts, EVMRetryFailed, BestAttemptUsed);

writetable(phase6Summary, csvSummaryFile);

% Best RX gain per TX gain:
bestRows = [];
for k = 1:numel(txGainList)
    mask = phase6Summary.TxGain_dB == txGainList(k) & ...
           isfinite(phase6Summary.EVM_RMS_pct) & ...
           phase6Summary.SyncMetric >= minSyncMetric & ...
           phase6Summary.RxPower_dBFS < digitalRxSaturationLimit_dBFS;

    if any(mask)
        idx = find(mask);
        % Prefer lowest EVM. You can change this to lowest NMSE if desired.
        [~, localIdx] = min(phase6Summary.EVM_RMS_pct(idx));
        bestRows(end+1,1) = idx(localIdx); %#ok<AGROW>
    end
end

if ~isempty(bestRows)
    bestPerTxTable = phase6Summary(bestRows,:);
else
    bestPerTxTable = table();
end

writetable(bestPerTxTable, csvBestPerTxFile);

save(matFile, "phase6Summary","bestPerTxTable","sweepPlanTable","cfgDLFRC","sampleRate","txWaveform","PAPR_dB", ...
    "txGainList","rxGainList","powerScaleFactor","rxInternalDsaAtten_dB","rfLoopbackAttenuator_dB", ...
    "ifOutMeterProtectionAttenuator_dB","upconverterBaselineCsvFile","idleTxWaveform");

%% ==================== FIGURES ====================

try
    plotMetricHeatmap(phase6Summary, "EVM_RMS_pct", "EVM RMS (%)", figuresDir, baseName);
    plotMetricHeatmap(phase6Summary, "NMSE_dB", "NMSE (dB)", figuresDir, baseName);
    plotMetricHeatmap(phase6Summary, "ACPR_dBc", "ACPR (dBc)", figuresDir, baseName);
    plotMetricHeatmap(phase6Summary, "RxPower_dBFS", "RX power (dBFS)", figuresDir, baseName);
    plotMetricHeatmap(phase6Summary, "IFOutCorrected_dBm", "IF OUT / Pout (dBm)", figuresDir, baseName);

    if ~isempty(bestPerTxTable)
        h = figure("Name","EXP006 best RX per TX","Color","w");
        tiledlayout(4,1);

        nexttile;
        plot(bestPerTxTable.TxGain_dB, bestPerTxTable.EVM_RMS_pct, "o-","LineWidth",1.2); grid on;
        xlabel("Pluto TX gain (dB)"); ylabel("EVM (%)"); title("Best RX per TX: EVM");

        nexttile;
        plot(bestPerTxTable.TxGain_dB, bestPerTxTable.NMSE_dB, "o-","LineWidth",1.2); grid on;
        xlabel("Pluto TX gain (dB)"); ylabel("NMSE (dB)"); title("Best RX per TX: NMSE");

        nexttile;
        plot(bestPerTxTable.TxGain_dB, bestPerTxTable.ACPR_dBc, "o-","LineWidth",1.2); grid on;
        xlabel("Pluto TX gain (dB)"); ylabel("ACPR (dBc)"); title("Best RX per TX: ACPR");

        nexttile;
        yyaxis left;
        plot(bestPerTxTable.TxGain_dB, bestPerTxTable.IFOutCorrected_dBm, "o-","LineWidth",1.2);
        ylabel("Pout / IF_OUT (dBm)");
        yyaxis right;
        plot(bestPerTxTable.TxGain_dB, bestPerTxTable.RxGain_dB, "s-","LineWidth",1.2);
        ylabel("Selected RX gain (dB)");
        grid on;
        xlabel("Pluto TX gain (dB)");
        title("Best RX per TX: Pout and selected RX gain");

        saveas(h, fullfile(figuresDir, baseName + "_best-rx-per-tx.png"));
    end
catch ME
    warning("Figure generation failed: %s", ME.message);
end

fprintf("\nEXP006 completed.\n");
fprintf("Summary CSV: %s\n", csvSummaryFile);
fprintf("Best per TX CSV: %s\n", csvBestPerTxFile);
fprintf("MAT: %s\n", matFile);

warning('on','all');

%% ========================================================================
% LOCAL FUNCTIONS
% ========================================================================

function line = querySTM32(stm32, cmd, expectedPrefix, timeout_s)
    if nargin < 4; timeout_s = 3; end
    flush(stm32);
    writeline(stm32, cmd);
    t0 = tic;
    line = "";
    while toc(t0) < timeout_s
        if stm32.NumBytesAvailable > 0
            line = strtrim(readline(stm32));
            if startsWith(line, expectedPrefix) || contains(line, expectedPrefix)
                return;
            end
        end
        pause(0.01);
    end
    error('STM32 timeout. CMD="%s", expected="%s", last line="%s"', cmd, expectedPrefix, line);
end

function pwr = measureIFPowerSTM32(stm32, txGain, nSamples)
    if nargin < 3 || isempty(nSamples); nSamples = 80; end
    nSamples = max(1, min(1000, round(nSamples)));

    cmd = sprintf('MEAS,%.2f,%d', txGain, nSamples);
    flush(stm32);
    writeline(stm32, cmd);

    rawVals = [];
    voltageVals = [];
    dBmVals = [];
    gotEnd = false;
    lastLine = "";
    timeout_s = max(6, 0.03*nSamples + 3);
    t0 = tic;

    while toc(t0) < timeout_s
        if stm32.NumBytesAvailable > 0
            lastLine = strtrim(readline(stm32));
            if strlength(lastLine) == 0; continue; end
            if startsWith(lastLine, "ERR")
                error('STM32 returned error: %s', lastLine);
            end
            if startsWith(lastLine, "DATA")
                parts = split(lastLine, ",");
                if numel(parts) >= 5
                    rawVal = str2double(parts(3));
                    voltageVal = str2double(parts(4));
                    dBmVal = str2double(parts(5));
                    if isfinite(rawVal) && isfinite(voltageVal) && isfinite(dBmVal)
                        rawVals(end+1,1) = rawVal; %#ok<AGROW>
                        voltageVals(end+1,1) = voltageVal; %#ok<AGROW>
                        dBmVals(end+1,1) = dBmVal; %#ok<AGROW>
                    end
                end
            elseif startsWith(lastLine, "END")
                gotEnd = true;
                break;
            end
        end
        pause(0.002);
    end

    if ~gotEnd
        error('STM32 MEAS timeout. Last line: %s', lastLine);
    end
    if isempty(dBmVals)
        error('STM32 MEAS returned no valid DATA lines. Last line: %s', lastLine);
    end

    pwr.raw_mean = mean(rawVals, 'omitnan');
    pwr.raw_std = std(rawVals, 'omitnan');
    pwr.voltage_mean_V = mean(voltageVals, 'omitnan');
    pwr.voltage_std_V = std(voltageVals, 'omitnan');
    pwr.dBm_mean = mean(dBmVals, 'omitnan');
    pwr.dBm_std = std(dBmVals, 'omitnan');
    pwr.n_valid = numel(dBmVals);
end

function [rx_aligned, freqOffset, syncMetric] = synchronizeFineXcorr(txWaveform, rxCapture, cfgDL)
    rx_aligned = [];
    freqOffset = 0;
    syncMetric = 0;
    try
        sampleRate = cfgDL.SampleRate;
        txWaveform = txWaveform(:);
        rxCapture = rxCapture(:);
        Ltx = length(txWaveform);
        Lrx = length(rxCapture);
        if Lrx < Ltx; return; end

        Lref = min(120000, Ltx);
        txRef = txWaveform(1:Lref);

        [c,lags] = xcorr(rxCapture, txRef);
        [peakVal, idxMax] = max(abs(c));
        delay = lags(idxMax);

        startIdx = max(1, delay+1);
        if startIdx + Ltx - 1 > Lrx
            startIdx = Lrx - Ltx + 1;
        end
        if startIdx < 1 || startIdx + Ltx - 1 > Lrx
            return;
        end

        rxSegForMetric = rxCapture(startIdx:startIdx+Lref-1);
        syncMetric = peakVal / sqrt(sum(abs(rxSegForMetric).^2)*sum(abs(txRef).^2) + eps);
        rx_aligned = rxCapture(startIdx:startIdx+Ltx-1);

        z = rx_aligned .* conj(txWaveform);
        valid = abs(txWaveform) > 0.05*max(abs(txWaveform));
        if nnz(valid) > 1000
            phaseErr = unwrap(angle(z(valid)));
            n = (0:length(phaseErr)-1).';
            p = polyfit(n, phaseErr, 1);
            freqOffset = p(1)*sampleRate/(2*pi);
        end
        if ~isfinite(freqOffset) || abs(freqOffset) > 0.25*sampleRate
            freqOffset = 0;
        end
    catch
        rx_aligned = [];
        freqOffset = 0;
        syncMetric = 0;
    end
end

function acpr_dBc = computeACPRCentered(x, fs, bw)
    acpr_dBc = NaN;
    try
        x = x(:);
        if numel(x) < 1024; return; end
        N = min(614400, numel(x));
        x = x(1:N) - mean(x(1:N));
        winLen = min(4096, N);
        nfft = max(4096, 2^nextpow2(min(N, 262144)));
        [pxx, f] = pwelch(x, hamming(winLen), [], nfft, fs, 'centered');
        mainIdx = abs(f) <= bw/2;
        adjLowIdx = (f >= -1.5*bw) & (f < -0.5*bw);
        adjHighIdx = (f > 0.5*bw) & (f <= 1.5*bw);
        pMain = trapz(f(mainIdx), pxx(mainIdx));
        pAdj = 0;
        if any(adjLowIdx); pAdj = pAdj + trapz(f(adjLowIdx), pxx(adjLowIdx)); end
        if any(adjHighIdx); pAdj = pAdj + trapz(f(adjHighIdx), pxx(adjHighIdx)); end
        if pMain > 0 && pAdj > 0
            acpr_dBc = 10*log10(pAdj/pMain);
        end
    catch
        acpr_dBc = NaN;
    end
end

function nmse_dB = computeNMSEComplexGain(tx, rx, N)
    nmse_dB = NaN;
    try
        tx = tx(:);
        rx = rx(:);
        N = min([N, numel(tx), numel(rx)]);
        tx = tx(1:N);
        rx = rx(1:N);

        valid = abs(tx) > 0.02*max(abs(tx));
        txv = tx(valid);
        rxv = rx(valid);

        % Complex least-squares gain: rx ≈ alpha*tx
        alpha = (txv' * rxv) / (txv' * txv + eps);
        err = rxv - alpha*txv;
        nmse_dB = 10*log10(sum(abs(err).^2) / (sum(abs(rxv).^2) + eps));
    catch
        nmse_dB = NaN;
    end
end

function T = buildEXP006Summary(sweepPlanTable, ...
    STM32_IFRaw_mean, STM32_IFVoltage_mean_V, STM32_IFVoltage_mean_mV, STM32_IFOut_mean_dBm, IFOutCorrected_dBm, ...
    EVM_RMS_pct, ACPR_dBc, NMSE_dB, SyncMetric, FreqOffset_Hz, RxPower_dBFS, TxPower_dBFS, DigitalGain_dB, ...
    CaptureAttempts, EVMRetryFailed, BestAttemptUsed)

    T = table( ...
        sweepPlanTable.PointIndex, sweepPlanTable.TxGain_dB, sweepPlanTable.RxGain_dB, sweepPlanTable.PlutoOutCalibrated_dBm, ...
        sweepPlanTable.RFOutPinEstimated_dBm, sweepPlanTable.RFOutAfterFilterEstimated_dBm, sweepPlanTable.UpconverterCompressionEstimated_dB, ...
        sweepPlanTable.DownconverterRFInputEstimated_dBm, sweepPlanTable.DownconverterRFInputPeakEnvelopeEstimated_dBm, ...
        sweepPlanTable.RxInternalDsaAtten_dB, ...
        sweepPlanTable.DownconverterAfterRxDsaEstimated_dBm, sweepPlanTable.DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm, ...
        sweepPlanTable.RFInputSafetyOK, sweepPlanTable.RFLoopbackAttenuator_dB, sweepPlanTable.IFOutMeterProtectionAttenuator_dB, sweepPlanTable.PowerScaleFactor, ...
        STM32_IFRaw_mean, STM32_IFVoltage_mean_V, STM32_IFVoltage_mean_mV, STM32_IFOut_mean_dBm, IFOutCorrected_dBm, ...
        EVM_RMS_pct, ACPR_dBc, NMSE_dB, SyncMetric, FreqOffset_Hz, RxPower_dBFS, TxPower_dBFS, DigitalGain_dB, ...
        CaptureAttempts, EVMRetryFailed, BestAttemptUsed, ...
        'VariableNames', { ...
            'PointIndex','TxGain_dB','RxGain_dB','PlutoOutCalibrated_dBm', ...
            'RFOutPinEstimated_dBm','RFOutAfterFilterEstimated_dBm','UpconverterCompressionEstimated_dB', ...
            'DownconverterRFInputEstimated_dBm','DownconverterRFInputPeakEnvelopeEstimated_dBm', ...
            'RxInternalDsaAtten_dB', ...
            'DownconverterAfterRxDsaEstimated_dBm','DownconverterAfterRxDsaPeakEnvelopeEstimated_dBm', ...
            'RFInputSafetyOK','RFLoopbackAttenuator_dB','IFOutMeterProtectionAttenuator_dB','PowerScaleFactor', ...
            'STM32_IFRaw_mean','STM32_IFVoltage_mean_V','STM32_IFVoltage_mean_mV','STM32_IFOut_mean_dBm','IFOutCorrected_dBm', ...
            'EVM_RMS_pct','ACPR_dBc','NMSE_dB','SyncMetric','FreqOffset_Hz','RxPower_dBFS','TxPower_dBFS','DigitalGain_dB', ...
            'CaptureAttempts','EVMRetryFailed','BestAttemptUsed'} ...
    );
end

function plotMetricHeatmap(T, metricName, metricLabel, figuresDir, baseName)
    if ~ismember(metricName, string(T.Properties.VariableNames)); return; end

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
    xlabel("Pluto TX gain (dB)");
    ylabel("Pluto RX gain (dB)");
    title("EXP006 " + metricLabel);
    saveas(h, fullfile(figuresDir, baseName + "_" + metricName + "_heatmap.png"));
end

function cleanupEXP006(txObj, rxObj, idleGain, stm32, idleTxWaveform)
    try
        txObj.Gain = idleGain;
        transmitRepeat(txObj, idleTxWaveform);
    catch
    end
    try; release(txObj); catch; end
    try; release(rxObj); catch; end
    try; clear stm32; catch; end
end
