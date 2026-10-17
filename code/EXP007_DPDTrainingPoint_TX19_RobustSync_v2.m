%% ========================================================================
%  EXP007 / PHASE 1 — DPD TRAINING POINT SEARCH WITH PHYSICAL + DIGITAL COMPRESSION
%  ------------------------------------------------------------------------
%  Physical configuration:
%    Pluto TX -> BGU -> ADMV1018/ADMV1017 upconverter IF_IN -> RF_OUT
%       -> 26 GHz filter, insertion loss = 3 dB
%       -> RF loopback attenuator = 30 dB
%       -> RF_IN downconverter -> IF_OUT
%       -> detector / STM32 power meter before Pluto RX
%
%  DPD design intent:
%    The 30 dB RF loopback attenuator is used so the downconverter remains
%    close to linear while the upconverter can enter compression. The RX path
%    is therefore treated as an observation receiver.
%
%  Objective:
%    1) Find the full-chain observed compression point with finer TX sweep.
%    2) Save EVM, ACPR, RX digital level, detector power, and detector voltage.
%    3) Provide a Phase-1 operating-point CSV for later EVM/DPD analysis.
%
%  IMPORTANT:
%    ifOutMeterProtectionAttenuator_dB = 0 dB in the current setup. Therefore:
%       IFOutCorrected_dBm = STM32_IFOut_mean_dBm + 0 dB
%
% ========================================================================
%
%  Original basis: PHASE 1 — DOWNCONVERTED IF COMPRESSION SEARCH BY PLUTO TX-GAIN SWEEP
%  NEW SETUP: NO SPLITTERS + POWER MEASURED AFTER DOWNCONVERSION BEFORE PLUTO RX
%  ------------------------------------------------------------------------
%  New physical measurement:
%    - STM32 single ADC channel measures the downconverted IF power located
%      AFTER the RF/downconversion chain and BEFORE the Pluto RX input.
%    - There are NO splitters in this new setup, so the default measurement
%      correction is 0 dB.
%
%  Sweep objective:
%    Find compression of the complete measured chain by sweeping Pluto TX
%    gain while measuring:
%      1) physical downconverted power before Pluto RX,
%      2) Pluto RX digital power,
%      3) EVM,
%      4) ACPR,
%      5) physical and digital compression estimates.
%
%  Recommended starting conditions from the latest DPD run:
%    - powerScaleFactor = 0.8
%    - Pluto RX gain    = 8 dB
%    - No splitter correction
%
%  IMPORTANT:
%    Since the detector is placed before the Pluto RX and there are no
%    splitters/couplers in the measurement path, the corrected measured
%    power is:
%
%        MeasuredIFCorrected_dBm = STM32_SingleSensor_dBm + measurementCorrection_dB
%
%    Keep measurementCorrection_dB = 0 unless you intentionally insert a
%    known attenuator/coupler/cable correction before the detector.
%
%  Hardware control:
%    - STM32 measures one detector channel by command MEAS,TxGain,nSamples.
%    - This script does not command external DSA.
%
%  Outputs:
%    - MAT file with all vectors and metadata.
%    - CSV summary with one row per sweep point.
%    - PNG figures.
%
% ========================================================================

clear; close all; clc;

%% ==================== USER CONFIGURATION ====================

% SDR configuration
deviceName       = "Pluto";
centerFrequency  = 5e9;
idleGain_dB      = -80;

% Fixed waveform and gain setup
powerScaleFactor = 0.8;
fixedRxGain_Pluto = 19;     % EDIT: best Pluto RX gain selected from EXP006

% TX gain sweep around the intended DPD training point.
% User target: Pluto TX gain around -19 dB. Keep useSingleFixedTxGain=false
% for the first EXP007 sweep, then set true to repeat only the selected point.
fixedTxCandidate_dB = -19.0;
useSingleFixedTxGain = false;
txGainList = (fixedTxCandidate_dB-10:0.5:fixedTxCandidate_dB+3).';
if useSingleFixedTxGain
    txGainList = fixedTxCandidate_dB;
end

% External DSA metadata only.
% This script does NOT command the DSA. Set this to match your physical setup.
% If no external DSA is used, leave fixedDsaSteps = 0.
dsaStep_dB       = 0.5;
fixedDsaSteps    = 0;                       % metadata only
fixedDsaAtten_dB = fixedDsaSteps*dsaStep_dB;

% Full-chain RF/IF physical metadata for this EXP007.
% These values must match the hardware.
% Physical losses from upconverter RF_OUT pin to downconverter RF_IN.
% Previous assumption:
%   RF_OUT pin -> cable 2 dB -> B259MC1S filter 3 dB -> cable 2 dB
%              -> physical RF loopback attenuator 30 dB -> RF_IN downconverter
cableLoss_RFOut_to_FilterInput_dB = 2.0;
rfOutFilterInsertionLoss_dB = 3.0;
cableLoss_FilterOutput_to_RFAttInput_dB = 2.0;
rfLoopbackAttenuator_dB = 30.0;
totalRFOutPinToRFInLoss_dB = cableLoss_RFOut_to_FilterInput_dB + ...
    rfOutFilterInsertionLoss_dB + cableLoss_FilterOutput_to_RFAttInput_dB + ...
    rfLoopbackAttenuator_dB;

ifOutMeterProtectionAttenuator_dB = 0.0; % IF_OUT -> detector/STM32
downconverterObservationMode = "RX observation path intended to remain near-linear";

% Baseline selection for physical compression attribution.
% Change the DSA/baseline pair consistently before running.
upconverterTxDsaAtten_dB = 7.0;  % set 5.0 or 7.0 to match ACE
if abs(upconverterTxDsaAtten_dB - 5.0) < 1e-9
    upconverterBaselineFileName = "Baseline_Power_Upconverter_RFOUT_TXDSA5.csv";
elseif abs(upconverterTxDsaAtten_dB - 7.0) < 1e-9
    upconverterBaselineFileName = "Baseline_Power_Upconverter_RFOUT_TXDSA7.csv";
else
    upconverterBaselineFileName = "Baseline_Power_Upconverter_RFOUT.csv";
end

ifBoardBaselineFileName = "Baseline_Power_IF_Board.csv";
useIfBoardBaseline = true;
useUpconverterBaseline = true;

% Measurement correction for the detector path.
% New setup: no splitters, and power is measured after downconversion and
% before Pluto RX. Therefore default correction is 0 dB.
% Change only if you insert a known attenuator/coupler/cable correction.
measurementCorrection_dB = ifOutMeterProtectionAttenuator_dB;

% Backward-compatible aliases used by old plotting/table code.
ifSplitterCorrection_dB = measurementCorrection_dB;
mixerOutCorrection_dB = NaN;

% Detector floor guard for physical compression reference.
% Points below this corrected measured output level are not used to estimate
% the small-signal linear reference. Adjust after seeing first CSV.
ifDetectorFloorGuard_dBm = -60.0;  % lower guard because IF meter attenuation is 0 dB

% STM32 serial configuration
stm32Port = "COM12";
stm32Baud = 209700;
stm32Terminator = "LF";    % use "CR/LF" only if your firmware requires it

% Number of IF detector samples requested from STM32 per TX-gain point.
% Firmware command format: MEAS,TxGain,nSamples
ifDetectorSamplesPerPoint = 80;

% Capture and EVM settings
captureTime_s = 30e-3;
minSyncMetric = 0.96;    % stricter because this sweep is used to confirm compression point
maxValidEVMForDPD_pct = 30;

% Compression reference
nLinearPoints = 5;
% Candidate compression window for DPD.
% 0.3-1.5 dB = moderate compression.
% 1.0-2.5 dB = more aggressive DPD exploration.
ifCompressionTargetLow_dB  = 0.3;
ifCompressionTargetHigh_dB = 2.5;

% RX saturation guard. Points above this are risky for DPD decision.
digitalRxSaturationLimit_dBFS = -1.0;

% Optional raw capture storage
saveRawCaptures = true;

% Retry configuration for sporadic synchronization/demodulation failures
maxCaptureAttempts = 3;
evmRetryThreshold_pct = 50;    % retry if EVM is NaN or above this value

% Pluto TX output power linear calibration
% Derived from Curva_Transferencia_Tx_Pluto.csv and Datos2.ipynb.
% For the planned sweep range TxGain = -29 to -14 dB, the measured Pluto
% output power is highly linear. Linear fit used here:
%
%   PlutoOutEstimated_dBm = plutoTxPowerSlope_dBperdB * TxGain_dB + plutoTxPowerIntercept_dBm
%
% Fit range: -29 dB <= TxGain <= -14 dB
% Fit result from the provided CSV:
%   slope     = 0.9935446912 dBm/dB
%   intercept = -8.1924257506 dBm
%   RMSE      ≈ 0.052 dB
%   R²        ≈ 0.999857
%
% IMPORTANT: This assumes the Pluto characterization was made using the same
% waveform and powerScaleFactor used in this sweep.
usePlutoTxLinearModel = true;
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

try
    addpath(fullfile(matlabroot, 'examples', '5g', 'NRWaveformCaptureAndAnalysisWithSDRExample'));
catch
end

projectDir = fileparts(scriptDir);
baselineDir = fullfile(projectDir, "baseline");

outputDir = fullfile(projectDir, "data", ...
    "EXP007_DPDTrainingPoint_TX19_PhysicalDigital_" + string(datetime("now","Format","yyyyMMdd_HHmmss")));

rawDir       = fullfile(outputDir, "raw");
processedDir = fullfile(outputDir, "processed");
figuresDir   = fullfile(outputDir, "figures");

for d = [{rawDir}, {processedDir}, {figuresDir}]
    if ~exist(d{1}, "dir")
        mkdir(d{1});
    end
end

baseName = "EXP007_Phase1_FullChain_Compression_EVM_TXSweep_" + string(datetime("now","Format","yyyyMMdd_HHmmss"));
matFile  = fullfile(processedDir, baseName + "_results.mat");
csvFile  = fullfile(processedDir, baseName + "_summary.csv");

%% ==================== 5G NR WAVEFORM GENERATION ====================

cfgDLFRC = nrDLCarrierConfig;
cfgDLFRC.Label = 'DL-FRC-FR1-256QAM';
cfgDLFRC.FrequencyRange = 'FR1';
cfgDLFRC.ChannelBandwidth = 20;            % MHz
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

PAPR_dB = 10*log10(max(abs(txWaveform)).^2 / mean(abs(txWaveform).^2));

samplesPerFrame = round(sampleRate * 10e-3);
totalSamplesNeeded = round(captureTime_s * sampleRate);

fprintf('\n===== WAVEFORM / SETUP =====\n');
fprintf('powerScaleFactor       = %.3f\n', powerScaleFactor);
fprintf('Sample rate            = %.2f Msps\n', sampleRate/1e6);
fprintf('PAPR                   = %.2f dB\n', PAPR_dB);
fprintf('TX gain sweep          = %.1f to %.1f dB (%d points)\n', ...
    txGainList(1), txGainList(end), numel(txGainList));
fprintf('Pluto RX gain fixed    = %.1f dB\n', fixedRxGain_Pluto);
fprintf('External DSA fixed     = %d steps = %.2f dB\n', fixedDsaSteps, fixedDsaAtten_dB);
fprintf('Measurement correction  = %.2f dB\n', ifSplitterCorrection_dB);
fprintf('Mixer correction       = %.2f dB\n', mixerOutCorrection_dB);
fprintf('IF floor guard         = %.2f dBm corrected\n', ifDetectorFloorGuard_dBm);
fprintf('EVM retry threshold    = %.2f %% | max attempts = %d\n', evmRetryThreshold_pct, maxCaptureAttempts);
fprintf('Pluto linear model     = Pout = %.6f*TxGain + %.6f dBm | fit range %.1f to %.1f dB | RMSE %.3f dB | R2 %.6f\n', ...
    plutoTxPowerSlope_dBperdB, plutoTxPowerIntercept_dBm, ...
    plutoTxPowerFitMin_dB, plutoTxPowerFitMax_dB, ...
    plutoTxPowerFitRMSE_dB, plutoTxPowerFitR2);

%% ==================== EVM CONFIGURATION ====================

cfgEVM = struct();
cfgEVM.PlotEVM    = false;
cfgEVM.DisplayEVM = false;
cfgEVM.SampleRate = sampleRate;
cfgEVM.IQImbalance = false;
cfgEVM.TargetRNTIs = 0;
cfgEVM.CorrectCoarseFO = true;
cfgEVM.CorrectFineFO   = true;
cfgEVM.ExcludeDC = true;

% Robust synchronization settings imported from EXP009.
numFramesForAlign = 1;
coarseDecimation = 16;
fineSearchHalfWindow_samples = 96;
phaseFitMagnitudeThreshold = 0.05;

% Alignment acceptance criteria. These are intentionally separate from NR EVM.
acceptSyncMetricMin = 0.70;
acceptNMSEMax_dB = -10.0;
acceptPeakRxMax_dBFS = -1.0;
acceptRxPowerMin_dBFS = -70.0;



%% ==================== BASELINE METADATA LOADING ====================

ifBoardBaselineCsvFile = fullfile(baselineDir, ifBoardBaselineFileName);
upconverterBaselineCsvFile = fullfile(baselineDir, upconverterBaselineFileName);

ifBoardBase = loadIFBoardBaseline(ifBoardBaselineCsvFile, useIfBoardBaseline);
upBase = loadUpconverterBaseline(upconverterBaselineCsvFile, useUpconverterBaseline);

fprintf('\n===== BASELINE CONFIGURATION =====\n');
fprintf('IF board baseline        : %s | available = %d\n', ifBoardBaselineCsvFile, ifBoardBase.available);
fprintf('Upconverter baseline     : %s | available = %d\n', upconverterBaselineCsvFile, upBase.available);
fprintf('Upconverter TX DSA meta  : %.1f dB\n', upconverterTxDsaAtten_dB);
fprintf('RF_OUT pin -> RF_IN loss : %.1f dB = cable %.1f + filter %.1f + cable %.1f + attenuator %.1f\n', ...
    totalRFOutPinToRFInLoss_dB, cableLoss_RFOut_to_FilterInput_dB, rfOutFilterInsertionLoss_dB, ...
    cableLoss_FilterOutput_to_RFAttInput_dB, rfLoopbackAttenuator_dB);

%% ==================== SWEEP PLAN ====================

nPoints = numel(txGainList);

if usePlutoTxLinearModel
    plutoOutCalibrated_dBm_plan = ...
        plutoTxPowerSlope_dBperdB .* txGainList(:) + plutoTxPowerIntercept_dBm;
else
    plutoOutCalibrated_dBm_plan = nan(nPoints,1);
end

% IF board / BGU metadata from baseline
IFBoardOutputEstimated_dBm_plan = interpBaseline(ifBoardBase.tx, ifBoardBase.out, txGainList(:));
IFBoardGainEstimated_dB_plan = interpBaseline(ifBoardBase.tx, ifBoardBase.gain, txGainList(:));
IFBoardCompressionEstimated_dB_plan = interpBaseline(ifBoardBase.tx, ifBoardBase.comp, txGainList(:));

% Upconverter metadata from selected DSA baseline
RFOutPinEstimated_dBm_plan = interpBaseline(upBase.tx, upBase.rfPin, txGainList(:));
RFOutAfterFilterEstimated_dBm_plan = interpBaseline(upBase.tx, upBase.rfAfterFilter, txGainList(:));
UpconverterGainEstimated_dB_plan = interpBaseline(upBase.tx, upBase.gain, txGainList(:));
UpconverterCompressionEstimated_dB_plan = interpBaseline(upBase.tx, upBase.comp, txGainList(:));

% Reconstruct RF input to downconverter using full physical loss from RF_OUT pin.
% This explicitly includes cable before filter, filter, cable after filter, and 30 dB RF attenuator.
DownconverterRFInputEstimated_dBm_plan = RFOutPinEstimated_dBm_plan - totalRFOutPinToRFInLoss_dB;
DownconverterRFInputPeakEnvelopeEstimated_dBm_plan = DownconverterRFInputEstimated_dBm_plan + PAPR_dB;

RFInputSafetyOK_plan = DownconverterRFInputEstimated_dBm_plan <= -9.0;

sweepPlanTable = table( ...
    (1:nPoints).', ...
    txGainList(:), ...
    plutoOutCalibrated_dBm_plan(:), ...
    fixedRxGain_Pluto * ones(nPoints,1), ...
    fixedDsaSteps * ones(nPoints,1), ...
    fixedDsaAtten_dB * ones(nPoints,1), ...
    ifSplitterCorrection_dB * ones(nPoints,1), ...
    mixerOutCorrection_dB * ones(nPoints,1), ...
    cableLoss_RFOut_to_FilterInput_dB * ones(nPoints,1), ...
    rfOutFilterInsertionLoss_dB * ones(nPoints,1), ...
    cableLoss_FilterOutput_to_RFAttInput_dB * ones(nPoints,1), ...
    rfLoopbackAttenuator_dB * ones(nPoints,1), ...
    totalRFOutPinToRFInLoss_dB * ones(nPoints,1), ...
    ifOutMeterProtectionAttenuator_dB * ones(nPoints,1), ...
    powerScaleFactor * ones(nPoints,1), ...
    upconverterTxDsaAtten_dB * ones(nPoints,1), ...
    IFBoardOutputEstimated_dBm_plan, ...
    IFBoardGainEstimated_dB_plan, ...
    IFBoardCompressionEstimated_dB_plan, ...
    RFOutPinEstimated_dBm_plan, ...
    RFOutAfterFilterEstimated_dBm_plan, ...
    UpconverterGainEstimated_dB_plan, ...
    UpconverterCompressionEstimated_dB_plan, ...
    DownconverterRFInputEstimated_dBm_plan, ...
    DownconverterRFInputPeakEnvelopeEstimated_dBm_plan, ...
    RFInputSafetyOK_plan, ...
    'VariableNames', { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'PlutoOutCalibrated_dBm', ...
        'RxGain_dB', ...
        'DsaExtSteps', ...
        'DsaExtAtten_dB', ...
        'IFSplitterCorrection_dB', ...
        'MixerOutCorrection_dB', ...
        'CableLoss_RFOut_to_FilterInput_dB', ...
        'RFOutFilterInsertionLoss_dB', ...
        'CableLoss_FilterOutput_to_RFAttInput_dB', ...
        'RFLoopbackAttenuator_dB', ...
        'TotalRFOutPinToRFInLoss_dB', ...
        'IFOutMeterProtectionAttenuator_dB', ...
        'PowerScaleFactor', ...
        'UpconverterTxDsaAtten_dB', ...
        'IFBoardOutputEstimated_dBm', ...
        'IFBoardGainEstimated_dB', ...
        'IFBoardCompressionEstimated_dB', ...
        'RFOutPinEstimated_dBm', ...
        'RFOutAfterFilterEstimated_dBm', ...
        'UpconverterGainEstimated_dB', ...
        'UpconverterCompressionEstimated_dB', ...
        'DownconverterRFInputEstimated_dBm', ...
        'DownconverterRFInputPeakEnvelopeEstimated_dBm', ...
        'RFInputSafetyOK'} ...
);

disp('Sweep plan:');
disp(sweepPlanTable(:, {'PointIndex','TxGain_dB','RxGain_dB','PlutoOutCalibrated_dBm', ...
    'IFBoardCompressionEstimated_dB','UpconverterCompressionEstimated_dB', ...
    'RFOutPinEstimated_dBm','DownconverterRFInputEstimated_dBm','RFInputSafetyOK'}));

%% ==================== INITIALIZE STM32 ====================

stm32 = serialport(stm32Port, stm32Baud);
configureTerminator(stm32, stm32Terminator);
stm32.Timeout = 3;
flush(stm32);

try
    pongLine = querySTM32(stm32, "PING", "PONG", 3);
    fprintf('[STM32] Communication OK: %s\n', pongLine);
catch ME
    warning('STM32 PING failed: %s', ME.message);
end

fprintf('[STM32] One-sensor firmware detected. No AT,n command is sent.\n');
fprintf('[STM32] External DSA metadata: %d steps = %.2f dB. Make sure firmware/hardware matches this value.\n', ...
    fixedDsaSteps, fixedDsaAtten_dB);

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
sdrReceiver.Gain = fixedRxGain_Pluto;

cleanupObj = onCleanup(@() cleanupPhase1_CorrectedSensors( ...
    sdrTransmitter, sdrReceiver, idleGain_dB, stm32, fixedDsaSteps));

%% ==================== PREALLOCATE RESULTS ====================

evm_values                 = nan(nPoints, 1);
sync_metric_values         = nan(nPoints, 1);
freq_offset_values_Hz      = nan(nPoints, 1);
acpr_values_dBc            = nan(nPoints, 1);
nmse_values_dB              = nan(nPoints, 1);

rx_power_dBFS_values       = nan(nPoints, 1);
tx_power_dBFS_values       = nan(nPoints, 1);
digital_gain_values_dB     = nan(nPoints, 1);
digital_compression_dB     = nan(nPoints, 1);
attempt_count_values       = nan(nPoints, 1);
evm_retry_failed_values    = false(nPoints, 1);

stm32_mixer_raw_values     = nan(nPoints, 1);
stm32_if_raw_values        = nan(nPoints, 1);
stm32_mixer_voltage_values = nan(nPoints, 1);
stm32_if_voltage_values    = nan(nPoints, 1);

stm32_mixer_dBm_values     = nan(nPoints, 1);
stm32_if_dBm_values        = nan(nPoints, 1);

mixer_out_corr_dBm_values  = nan(nPoints, 1);
if_out_corr_dBm_values     = nan(nPoints, 1);

pluto_out_calibrated_dBm_values = sweepPlanTable.PlutoOutCalibrated_dBm;
if_gain_proxy_dB_values    = nan(nPoints, 1);   % IFOutCorrected - commanded Pluto TX gain
if_gain_calibrated_dB_values = nan(nPoints, 1); % IFOutCorrected - calibrated Pluto output power
if_compression_dB_values   = nan(nPoints, 1);   % main IF compression, calibrated if available
if_compression_proxy_dB_values = nan(nPoints, 1);

mixer_control_gain_dB_values = nan(nPoints, 1);
mixer_control_compression_dB = nan(nPoints, 1);

linear_if_gain_proxy_dB      = NaN;
linear_if_gain_calibrated_dB = NaN;
linear_mixer_control_gain_dB = NaN;
linear_digital_gain_dB       = NaN;

best_EVM = Inf;
best_tx_iq = [];
best_rx_iq = [];

P1dB_IF_found = false;
P1dB_IF_index = NaN;

P1dB_digital_found = false;
P1dB_digital_index = NaN;

%% ==================== SWEEP LOOP ====================

fprintf('\n===== PHASE 1: TX-GAIN SWEEP, SINGLE IF SENSOR =====\n');

try
    for iPoint = 1:nPoints

        pointCleanup = onCleanup(@() setSafeState_CorrectedSensors( ...
            sdrTransmitter, idleGain_dB, stm32, fixedDsaSteps));

        pointIndex = sweepPlanTable.PointIndex(iPoint);
        txGain     = sweepPlanTable.TxGain_dB(iPoint);
        plutoOutCal_dBm = sweepPlanTable.PlutoOutCalibrated_dBm(iPoint);
        rxGain     = sweepPlanTable.RxGain_dB(iPoint);

        fprintf('\nPoint %d/%d | Pluto TX = %.2f dB | Pluto RX = %.2f dB | DSA = %d steps = %.2f dB\n', ...
            iPoint, nPoints, txGain, rxGain, fixedDsaSteps, fixedDsaAtten_dB);
        if isfinite(plutoOutCal_dBm)
            fprintf('  Calibrated Pluto output power = %.2f dBm\n', plutoOutCal_dBm);
        end

        % External DSA is not commanded from MATLAB in this one-sensor firmware.
        % Make sure the firmware/hardware DSA state matches fixedDsaSteps.
        pause(0.15);

        % Transmit at current gain.
        sdrTransmitter.Gain = txGain;
        transmitRepeat(sdrTransmitter, txWaveform);
        pause(0.45);

        %% ----------------------------------------------------------------
        %  STM32 IF POWER MEASUREMENT — SINGLE SENSOR VERSION
        %  ----------------------------------------------------------------
        %  The STM32 firmware receives:
        %      MEAS,TxGain,nSamples
        %
        %  It returns several DATA lines:
        %      DATA,time_ms,raw,voltage_V,dBm
        %
        %  This code averages those DATA lines and uses the result as the
        %  physical IF output power estimate.
        % -----------------------------------------------------------------

        try
            pwr = measureIFPowerSTM32(stm32, txGain, ifDetectorSamplesPerPoint);

            % Single sensor -> IF output main detector
            stm32_if_raw_values(iPoint)        = pwr.raw_mean;
            stm32_if_voltage_values(iPoint)    = pwr.voltage_mean_V;
            stm32_if_dBm_values(iPoint)        = pwr.dBm_mean;

            % Mixer placeholders are intentionally left as NaN in this version.
            stm32_mixer_raw_values(iPoint)     = NaN;
            stm32_mixer_voltage_values(iPoint) = NaN;
            stm32_mixer_dBm_values(iPoint)     = NaN;
            mixer_out_corr_dBm_values(iPoint)  = NaN;

            % Corrected IF power: only measurementCorrection_dB is applied.
            if_out_corr_dBm_values(iPoint) = ...
                stm32_if_dBm_values(iPoint) + ifSplitterCorrection_dB;

            fprintf(['  [STM32] IFout mean = %.2f dBm | IFout corr = %.2f dBm | ', 'std = %.3f dB | N = %d'], ...
                stm32_if_dBm_values(iPoint), ...
                if_out_corr_dBm_values(iPoint), ...
                pwr.dBm_std, ...
                pwr.n_valid);

        catch ME
            warning('STM32 IF measurement failed at point %d: %s', pointIndex, ME.message);
        end

        %% ----------------------------------------------------------------
        %  CAPTURE / SYNC / EVM / ACPR WITH RETRY
        % -----------------------------------------------------------------
        % If EVM is NaN or above evmRetryThreshold_pct, repeat the capture.
        % After maxCaptureAttempts, keep the best attempt and mark the point.
        % -----------------------------------------------------------------

        bestAttempt = struct();
        bestAttempt.evm = Inf;
        bestAttempt.rxAligned = [];
        bestAttempt.freqOffset = NaN;
        bestAttempt.syncMetric = NaN;
        bestAttempt.rxPower_dBFS = NaN;
        bestAttempt.txPower_dBFS = NaN;
        bestAttempt.digitalGain_dB = NaN;
        bestAttempt.acpr_dBc = NaN;
        bestAttempt.nmse_dB = NaN;
        bestAttempt.eqSymb = [];
        bestAttempt.refSymb = [];
        bestAttempt.success = false;

        acceptedAttempt = false;
        attemptsUsed = 0;

        for attempt = 1:maxCaptureAttempts

            attemptsUsed = attempt;
            fprintf('  -> Robust capture attempt %d/%d\n', attempt, maxCaptureAttempts);

            sdrReceiver.Gain = rxGain;
            pause(0.10);

            try
                rxCapture = capture(sdrReceiver, captureTime_s, "Seconds");
                rxCapture = rxCapture(:);
            catch ME
                fprintf('     Capture failed: %s\n', ME.message);
                continue;
            end

            if length(rxCapture) < totalSamplesNeeded
                warning('Insufficient capture at point %d, attempt %d.', pointIndex, attempt);
                continue;
            end

            rxCapture = rxCapture(1:totalSamplesNeeded);

            if saveRawCaptures
                rawFile = fullfile(rawDir, sprintf('raw_point_%03d_tx_%+05.2fdB_attempt_%d.mat', ...
                    pointIndex, txGain, attempt));
                save(rawFile, 'rxCapture', 'txGain', 'rxGain', ...
                    'fixedDsaSteps', 'fixedDsaAtten_dB', 'powerScaleFactor', 'attempt');
            end

            % ============================================================
            % ROBUST IQ ALIGNMENT FOR DPD
            % ============================================================
            % This alignment is taken from the previous EXP009 robust-sync
            % methodology. It does not rely on hNRDownlinkEVM to validate
            % synchronization. The acceptance is based on:
            %   - normalized IQ correlation,
            %   - residual NMSE after complex gain and CFO correction,
            %   - RX peak level to avoid clipping.
            %
            % The NR EVM is still calculated after alignment, but it is no
            % longer used as the only synchronization gate.
            % ============================================================

            try
                [alignInfo, alignedData] = robustAlignTxRxForDPD( ...
                    txWaveform, rxCapture, sampleRate, ...
                    coarseDecimation, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign);
            catch ME
                fprintf('     Robust alignment failed: %s\n', ME.message);
                continue;
            end

            rxAlignedAttempt = alignedData.y_cfo_corrected(:);
            rxNormalizedAttempt = alignedData.y_normalized(:);

            freqOffsetAttempt = alignInfo.freqOffset_Hz;
            syncMetricAttempt = alignInfo.syncMetric;
            nmseAttempt_dB = alignInfo.nmse_dB;
            waveformEVMAttempt_pct = alignInfo.waveformEVM_pct;

            txPowerAttempt_dBFS = 20*log10(rms(abs(alignedData.x_aligned)) + eps);
            rxPowerAttempt_dBFS = alignInfo.rxPower_dBFS;
            peakRxAttempt_dBFS = alignInfo.peakRx_dBFS;

            % Digital gain after complex LS fit. This is more meaningful for
            % DPD than the previous power-ratio proxy because it comes from
            % the aligned x[n] -> y[n] pair.
            digitalGainAttempt_dB = 20*log10(abs(alignInfo.complexGain) + eps);

            fprintf('     delay=%d | sync=%.4f | CFO=%.2f Hz | NMSE=%.2f dB | wfEVM=%.2f %% | Rx=%.2f dBFS | peak=%.2f dBFS\n', ...
                alignInfo.delaySamples, syncMetricAttempt, freqOffsetAttempt, ...
                nmseAttempt_dB, waveformEVMAttempt_pct, rxPowerAttempt_dBFS, peakRxAttempt_dBFS);

            % EVM NR after robust alignment.
            evmAttempt_pct = NaN;
            eqSymbAttempt = [];
            refSymbAttempt = [];

            try
                % Let hNRDownlinkEVM still perform its own residual FO
                % correction. The input is already pre-aligned and CFO-corrected.
                cfgEVM.CorrectCoarseFO = true;
                cfgEVM.CorrectFineFO   = true;

                [evmInfoAttempt, eqSymbAttempt, refSymbAttempt] = hNRDownlinkEVM( ...
                    cfgDLFRC, rxAlignedAttempt(1:samplesPerFrame), cfgEVM);

                evmAttempt_pct = evmInfoAttempt.PDSCH.OverallEVM.RMS * 100;

                fprintf('     NR EVM aligned = %.2f %%\n', evmAttempt_pct);

            catch ME
                fprintf('     NR EVM after robust alignment failed: %s\n', ME.message);
                evmAttempt_pct = NaN;
            end

            % ACPR from robustly aligned/corrected waveform.
            acprAttempt_dBc = NaN;
            try
                acprAttempt_dBc = computeACPRCentered(rxAlignedAttempt, sampleRate, 20e6);
                fprintf('     ACPR approx. = %.2f dBc\n', acprAttempt_dBc);
            catch
                acprAttempt_dBc = NaN;
            end

            % Alignment acceptance. This is the critical change versus the old
            % EXP007: a point may be accepted even if NR EVM fails, provided
            % the IQ pair is well aligned for DPD diagnostics.
            isClip = peakRxAttempt_dBFS >= acceptPeakRxMax_dBFS;
            isAlignedAccepted = ...
                syncMetricAttempt >= acceptSyncMetricMin && ...
                nmseAttempt_dB <= acceptNMSEMax_dB && ...
                peakRxAttempt_dBFS < acceptPeakRxMax_dBFS && ...
                rxPowerAttempt_dBFS > acceptRxPowerMin_dBFS;

            % Score: lower is better. Prioritize NMSE, then sync, then avoid clipping.
            scoreAttempt = nmseAttempt_dB - 8*syncMetricAttempt;
            if isClip
                scoreAttempt = scoreAttempt + 50;
            end
            if ~isfinite(scoreAttempt)
                scoreAttempt = Inf;
            end

            % Save best attempt:
            % priority 1: accepted robust alignment with lowest NMSE-based score
            % priority 2: if no accepted attempt exists, keep best diagnostic.
            previousScore = Inf;
            if isfield(bestAttempt, 'score') && isfinite(bestAttempt.score)
                previousScore = bestAttempt.score;
            end

            if isempty(bestAttempt.rxAligned) || scoreAttempt < previousScore
                bestAttempt.evm = evmAttempt_pct;
                bestAttempt.rxAligned = rxAlignedAttempt;
                bestAttempt.freqOffset = freqOffsetAttempt;
                bestAttempt.syncMetric = syncMetricAttempt;
                bestAttempt.rxPower_dBFS = rxPowerAttempt_dBFS;
                bestAttempt.txPower_dBFS = txPowerAttempt_dBFS;
                bestAttempt.digitalGain_dB = digitalGainAttempt_dB;
                bestAttempt.acpr_dBc = acprAttempt_dBc;
                bestAttempt.nmse_dB = nmseAttempt_dB;
                bestAttempt.eqSymb = eqSymbAttempt;
                bestAttempt.refSymb = refSymbAttempt;
                bestAttempt.success = isAlignedAccepted;
                bestAttempt.score = scoreAttempt;
                bestAttempt.waveformEVM_pct = waveformEVMAttempt_pct;
                bestAttempt.peakRx_dBFS = peakRxAttempt_dBFS;
                bestAttempt.xAligned = alignedData.x_aligned;
                bestAttempt.yNormalized = rxNormalizedAttempt;
            end

            if isAlignedAccepted
                acceptedAttempt = true;
                fprintf('     Accepted robust alignment attempt %d: sync/NMSE/peak criteria passed.\n', attempt);
                break;
            else
                fprintf('     Rejected robust alignment attempt %d: sync/NMSE/peak criteria not satisfied.\n', attempt);
            end
        end

        attempt_count_values(iPoint) = attemptsUsed;

        if ~acceptedAttempt
            evm_retry_failed_values(iPoint) = true;
            warning('Point %d failed EVM retry criterion after %d attempts. Best EVM = %.2f %%.', ...
                pointIndex, maxCaptureAttempts, bestAttempt.evm);
        end

        % Kill bad points. Do not keep a best-bad capture, because it can
        % destroy compression/EVM plots and the candidate decision.
        if isempty(bestAttempt.rxAligned) || ~isfinite(bestAttempt.syncMetric) || ...
                ~isfinite(bestAttempt.nmse_dB) || ...
                bestAttempt.syncMetric < acceptSyncMetricMin || ...
                bestAttempt.nmse_dB > acceptNMSEMax_dB || ...
                (isfield(bestAttempt, 'peakRx_dBFS') && bestAttempt.peakRx_dBFS >= acceptPeakRxMax_dBFS)
            warning('No valid capture at point %d after retries. Marking point as NaN and continuing.', pointIndex);
            evm_values(iPoint) = NaN;
            acpr_values_dBc(iPoint) = NaN;
            nmse_values_dB(iPoint) = NaN;
            sync_metric_values(iPoint) = bestAttempt.syncMetric;
            freq_offset_values_Hz(iPoint) = NaN;
            rx_power_dBFS_values(iPoint) = NaN;
            tx_power_dBFS_values(iPoint) = NaN;
            digital_gain_values_dB(iPoint) = NaN;
            setSafeState_CorrectedSensors(sdrTransmitter, idleGain_dB, stm32, fixedDsaSteps);
            continue;
        end

        % Assign selected attempt to main vectors
        sync_metric_values(iPoint)     = bestAttempt.syncMetric;
        freq_offset_values_Hz(iPoint)  = bestAttempt.freqOffset;
        rx_power_dBFS_values(iPoint)   = bestAttempt.rxPower_dBFS;
        tx_power_dBFS_values(iPoint)   = bestAttempt.txPower_dBFS;
        digital_gain_values_dB(iPoint) = bestAttempt.digitalGain_dB;
        acpr_values_dBc(iPoint)        = bestAttempt.acpr_dBc;
        nmse_values_dB(iPoint)          = bestAttempt.nmse_dB;
        evm_values(iPoint)             = bestAttempt.evm;

        fprintf('  -> SELECTED: EVM = %.2f %% | Sync = %.4f | RX power = %.2f dBFS | ACPR = %.2f dBc | NMSE = %.2f dB | attempts = %d\n', ...
            evm_values(iPoint), ...
            sync_metric_values(iPoint), ...
            rx_power_dBFS_values(iPoint), ...
            acpr_values_dBc(iPoint), ...
            nmse_values_dB(iPoint), ...
            attemptsUsed);

        if isfinite(evm_values(iPoint)) && evm_values(iPoint) < best_EVM
            best_EVM = evm_values(iPoint);

            if ~isempty(bestAttempt.refSymb) && ~isempty(bestAttempt.eqSymb)
                best_tx_iq = bestAttempt.refSymb{1}(:);
                best_rx_iq = bestAttempt.eqSymb{1}(:);
            end
        end

        %% ----------------------------------------------------------------
        %  PHYSICAL IF COMPRESSION ESTIMATE
        %  ----------------------------------------------------------------
        %  IFOut is measured directly at IF board output after splitter.
        %  Therefore, only measurementCorrection_dB is applied.
        %  DO NOT add external DSA attenuation here unless the detector is located before that attenuator.
        %
        %  IFGainProxy is not an absolute RF gain, because TxGain_dB is not
        %  Pluto output power in dBm. However, with fixed powerScaleFactor it
        %  is a useful compression proxy versus commanded input drive.
        % -----------------------------------------------------------------

        if_gain_proxy_dB_values(iPoint) = ...
            if_out_corr_dBm_values(iPoint) - txGain;

        if isfinite(plutoOutCal_dBm)
            if_gain_calibrated_dB_values(iPoint) = ...
                if_out_corr_dBm_values(iPoint) - plutoOutCal_dBm;
        end

        % Mixer output is a control channel only.
        mixer_control_gain_dB_values(iPoint) = ...
            mixer_out_corr_dBm_values(iPoint) - if_out_corr_dBm_values(iPoint);

        %% ----------------------------------------------------------------
        %  LINEAR REFERENCES
        % -----------------------------------------------------------------

        % IF command-proxy linear reference, avoiding detector floor.
        validIFProxy = ...
            isfinite(if_gain_proxy_dB_values) & ...
            isfinite(if_out_corr_dBm_values) & ...
            if_out_corr_dBm_values > ifDetectorFloorGuard_dBm;

        if isnan(linear_if_gain_proxy_dB) && nnz(validIFProxy) >= nLinearPoints
            idx = find(validIFProxy, nLinearPoints, 'first');

            linear_if_gain_proxy_dB = mean(if_gain_proxy_dB_values(idx), 'omitnan');

            fprintf('  ++ Linear IF command-proxy gain = %.2f dB using IF points above %.1f dBm\n', ...
                linear_if_gain_proxy_dB, ifDetectorFloorGuard_dBm);
        end

        % IF calibrated linear reference using Pluto linear output model.
        validIFCal = ...
            isfinite(if_gain_calibrated_dB_values) & ...
            isfinite(if_out_corr_dBm_values) & ...
            isfinite(pluto_out_calibrated_dBm_values) & ...
            if_out_corr_dBm_values > ifDetectorFloorGuard_dBm;

        if isnan(linear_if_gain_calibrated_dB) && nnz(validIFCal) >= nLinearPoints
            idx = find(validIFCal, nLinearPoints, 'first');

            linear_if_gain_calibrated_dB = mean(if_gain_calibrated_dB_values(idx), 'omitnan');

            fprintf('  ++ Linear IF calibrated gain = %.2f dB using Pluto TX linear power model\n', ...
                linear_if_gain_calibrated_dB);
        end

        % Mixer control reference. Not used as primary compression decision.
        validMixerCtrl = isfinite(mixer_control_gain_dB_values);

        if isnan(linear_mixer_control_gain_dB) && nnz(validMixerCtrl) >= nLinearPoints
            idx = find(validMixerCtrl, nLinearPoints, 'first');

            linear_mixer_control_gain_dB = mean(mixer_control_gain_dB_values(idx), 'omitnan');

            fprintf('  ++ Linear mixer-control gain = %.2f dB\n', ...
                linear_mixer_control_gain_dB);
        end

        % Digital relative reference.
        validDig = isfinite(digital_gain_values_dB);

        if isnan(linear_digital_gain_dB) && nnz(validDig) >= nLinearPoints
            idx = find(validDig, nLinearPoints, 'first');

            linear_digital_gain_dB = mean(digital_gain_values_dB(idx), 'omitnan');

            fprintf('  ++ Linear digital relative gain = %.2f dB\n', ...
                linear_digital_gain_dB);
        end

        %% ----------------------------------------------------------------
        %  COMPRESSION CALCULATION
        % -----------------------------------------------------------------

        if isfinite(linear_if_gain_proxy_dB)
            if_compression_proxy_dB_values(iPoint) = ...
                linear_if_gain_proxy_dB - if_gain_proxy_dB_values(iPoint);
        end

        if isfinite(linear_if_gain_calibrated_dB) && isfinite(if_gain_calibrated_dB_values(iPoint))
            if_compression_dB_values(iPoint) = ...
                linear_if_gain_calibrated_dB - if_gain_calibrated_dB_values(iPoint);
        elseif isfinite(if_compression_proxy_dB_values(iPoint))
            % Fallback if Pluto linear model is unavailable.
            if_compression_dB_values(iPoint) = if_compression_proxy_dB_values(iPoint);
        end

        if isfinite(linear_mixer_control_gain_dB)
            mixer_control_compression_dB(iPoint) = ...
                linear_mixer_control_gain_dB - mixer_control_gain_dB_values(iPoint);
        end

        if isfinite(linear_digital_gain_dB)
            digital_compression_dB(iPoint) = ...
                linear_digital_gain_dB - digital_gain_values_dB(iPoint);
        end

        fprintf('  -> RX digital power = %.2f dBFS rel.\n', ...
            rx_power_dBFS_values(iPoint));

        fprintf(['  -> IF compression main = %.2f dB | IF proxy comp = %.2f dB | ', ...
                 'Digital compression = %.2f dB | Mixer control compression = %.2f dB\n'], ...
            if_compression_dB_values(iPoint), ...
            if_compression_proxy_dB_values(iPoint), ...
            digital_compression_dB(iPoint), ...
            mixer_control_compression_dB(iPoint));

        if ~P1dB_IF_found && isfinite(if_compression_dB_values(iPoint)) && if_compression_dB_values(iPoint) >= 1.0
            P1dB_IF_found = true;
            P1dB_IF_index = iPoint;
            fprintf('  ++ IF physical/proxy P1dB detected at point %d | TX gain = %.2f dB\n', pointIndex, txGain);
        end

        if ~P1dB_digital_found && isfinite(digital_compression_dB(iPoint)) && digital_compression_dB(iPoint) >= 1.0
            P1dB_digital_found = true;
            P1dB_digital_index = iPoint;
            fprintf('  ++ Digital relative P1dB detected at point %d | TX gain = %.2f dB\n', pointIndex, txGain);
        end

        % Save incremental results.
        phase1Summary = buildSummaryTable(sweepPlanTable, ...
            stm32_mixer_raw_values, stm32_if_raw_values, ...
            stm32_mixer_voltage_values, stm32_if_voltage_values, ...
            stm32_mixer_dBm_values, stm32_if_dBm_values, ...
            mixer_out_corr_dBm_values, if_out_corr_dBm_values, ...
            pluto_out_calibrated_dBm_values, ...
            if_gain_proxy_dB_values, if_gain_calibrated_dB_values, ...
            if_compression_proxy_dB_values, if_compression_dB_values, ...
            mixer_control_gain_dB_values, mixer_control_compression_dB, ...
            evm_values, acpr_values_dBc, nmse_values_dB, sync_metric_values, freq_offset_values_Hz, ...
            rx_power_dBFS_values, tx_power_dBFS_values, ...
            digital_gain_values_dB, digital_compression_dB, ...
            attempt_count_values, evm_retry_failed_values);

        save(matFile, ...
            'sweepPlanTable', 'phase1Summary', ...
            'cfgDLFRC', 'sampleRate', 'powerScaleFactor', 'PAPR_dB', ...
            'txWaveform', ...
            'fixedRxGain_Pluto', 'fixedDsaSteps', 'fixedDsaAtten_dB', ...
            'ifSplitterCorrection_dB', 'mixerOutCorrection_dB', 'rfOutFilterInsertionLoss_dB', 'rfLoopbackAttenuator_dB', 'ifOutMeterProtectionAttenuator_dB', 'ifDetectorFloorGuard_dBm', 'ifDetectorSamplesPerPoint', ...
            'usePlutoTxLinearModel', 'plutoTxPowerSlope_dBperdB', 'plutoTxPowerIntercept_dBm', ...
            'plutoTxPowerFitMin_dB', 'plutoTxPowerFitMax_dB', 'plutoTxPowerFitRMSE_dB', 'plutoTxPowerFitR2', ...
            'evm_values', 'sync_metric_values', 'freq_offset_values_Hz', ...
            'acpr_values_dBc', 'nmse_values_dB', ...
            'rx_power_dBFS_values', 'tx_power_dBFS_values', ...
            'digital_gain_values_dB', 'digital_compression_dB', ...
            'attempt_count_values', 'evm_retry_failed_values', ...
            'stm32_mixer_raw_values', 'stm32_if_raw_values', ...
            'stm32_mixer_voltage_values', 'stm32_if_voltage_values', ...
            'stm32_mixer_dBm_values', 'stm32_if_dBm_values', ...
            'mixer_out_corr_dBm_values', 'if_out_corr_dBm_values', ...
            'pluto_out_calibrated_dBm_values', ...
            'if_gain_proxy_dB_values', 'if_gain_calibrated_dB_values', ...
            'if_compression_proxy_dB_values', 'if_compression_dB_values', ...
            'mixer_control_gain_dB_values', 'mixer_control_compression_dB', ...
            'linear_if_gain_proxy_dB', 'linear_if_gain_calibrated_dB', ...
            'linear_mixer_control_gain_dB', 'linear_digital_gain_dB', ...
            'P1dB_IF_found', 'P1dB_IF_index', ...
            'P1dB_digital_found', 'P1dB_digital_index', ...
            'best_EVM', 'best_tx_iq', 'best_rx_iq');

        writetable(phase1Summary, csvFile);

        fprintf('  Incremental MAT/CSV saved.\n');

        setSafeState_CorrectedSensors(sdrTransmitter, idleGain_dB, stm32, fixedDsaSteps);
        pause(0.10);

        delete(pointCleanup);
    end

catch ME
    warning('%s', sprintf('Error during TX sweep: %s', ME.message));
    setSafeState_CorrectedSensors(sdrTransmitter, idleGain_dB, stm32, fixedDsaSteps);
end

%% ==================== FINAL SUMMARY AND CANDIDATE SELECTION ====================

phase1Summary = buildSummaryTable(sweepPlanTable, ...
    stm32_mixer_raw_values, stm32_if_raw_values, ...
    stm32_mixer_voltage_values, stm32_if_voltage_values, ...
    stm32_mixer_dBm_values, stm32_if_dBm_values, ...
    mixer_out_corr_dBm_values, if_out_corr_dBm_values, ...
    pluto_out_calibrated_dBm_values, ...
    if_gain_proxy_dB_values, if_gain_calibrated_dB_values, ...
    if_compression_proxy_dB_values, if_compression_dB_values, ...
    mixer_control_gain_dB_values, mixer_control_compression_dB, ...
    evm_values, acpr_values_dBc, nmse_values_dB, sync_metric_values, freq_offset_values_Hz, ...
    rx_power_dBFS_values, tx_power_dBFS_values, ...
    digital_gain_values_dB, digital_compression_dB, ...
    attempt_count_values, evm_retry_failed_values);

writetable(phase1Summary, csvFile);

fprintf('\n===== FINAL PHASE 1 SUMMARY =====\n');
fprintf('CSV saved to:\n%s\n', csvFile);
fprintf('MAT saved to:\n%s\n', matFile);

%% ==================== P1dB INTERPOLATION AND DIAGNOSTIC POINTS ====================
% Interpolate the TX gain where the measured IF-chain compression crosses 1 dB.
phase1P1dB = table();
try
    validP1 = isfinite(phase1Summary.TxGain_dB) & isfinite(phase1Summary.IFCompression_dB);
    xP1 = phase1Summary.TxGain_dB(validP1);
    yP1 = phase1Summary.IFCompression_dB(validP1);

    idxCross = find(yP1(1:end-1) < 1.0 & yP1(2:end) >= 1.0, 1, 'first');

    if ~isempty(idxCross)
        txP1 = interp1(yP1(idxCross:idxCross+1), xP1(idxCross:idxCross+1), 1.0, 'linear');
        ifOutP1 = interp1(phase1Summary.TxGain_dB, phase1Summary.IFOutCorrected_dBm, txP1, 'linear', 'extrap');
        evmP1 = interp1(phase1Summary.TxGain_dB, phase1Summary.EVM_RMS_pct, txP1, 'linear', 'extrap');
        rxPowP1 = interp1(phase1Summary.TxGain_dB, phase1Summary.RxPower_dBFS, txP1, 'linear', 'extrap');
        vP1 = interp1(phase1Summary.TxGain_dB, phase1Summary.STM32_IFVoltage_mean_V, txP1, 'linear', 'extrap');

        phase1P1dB = table(txP1, ifOutP1, evmP1, rxPowP1, vP1, ...
            'VariableNames', {'TxGain_P1dB_dB','IFOutCorrected_P1dB_dBm','EVM_at_P1dB_pct','RxPower_at_P1dB_dBFS','MeterVoltage_at_P1dB_V'});

        writetable(phase1P1dB, fullfile(processedDir, baseName + "_p1db-interpolated.csv"));

        fprintf('\n===== INTERPOLATED PHASE-1 P1dB =====\n');
        disp(phase1P1dB);
    else
        fprintf('\nNo 1 dB crossing found in IFCompression_dB within this sweep.\n');
    end
catch ME
    warning('Could not interpolate P1dB: %s', ME.message);
end

% DPD candidate selection:
% Prefer IF physical/proxy compression from IF output detector, while
% avoiding RX saturation and invalid demodulation.
validForDPD_IF = ...
    isfinite(phase1Summary.EVM_RMS_pct) & ...
    phase1Summary.EVM_RMS_pct < maxValidEVMForDPD_pct & ...
    phase1Summary.SyncMetric >= minSyncMetric & ...
    isfinite(phase1Summary.IFCompression_dB) & ...
    phase1Summary.IFCompression_dB >= ifCompressionTargetLow_dB & ...
    phase1Summary.IFCompression_dB <= ifCompressionTargetHigh_dB & ...
    phase1Summary.RxPower_dBFS < digitalRxSaturationLimit_dBFS;

if any(validForDPD_IF)
    idxList = find(validForDPD_IF);
    [~, k] = min(phase1Summary.EVM_RMS_pct(idxList));
    dpdIdx = idxList(k);
    selectionMode = "Downconverted IF physical compression + valid EVM + no RX saturation";
else
    validDiag = ...
        isfinite(phase1Summary.EVM_RMS_pct) & ...
        phase1Summary.SyncMetric >= minSyncMetric & ...
        phase1Summary.RxPower_dBFS < digitalRxSaturationLimit_dBFS;

    if any(validDiag)
        idxList = find(validDiag);
        [~, k] = min(phase1Summary.EVM_RMS_pct(idxList));
        dpdIdx = idxList(k);
        selectionMode = "diagnostic best EVM before RX saturation";
    else
        dpdIdx = NaN;
        selectionMode = "no valid candidate";
    end
end

if isfinite(dpdIdx)
    fprintf('\nCandidate selected by: %s\n', selectionMode);
    fprintf('Point %d | TX gain = %.2f dB | IF comp = %.2f dB | Digital comp = %.2f dB | EVM = %.2f %% | RX power = %.2f dBFS\n', ...
        phase1Summary.PointIndex(dpdIdx), ...
        phase1Summary.TxGain_dB(dpdIdx), ...
        phase1Summary.IFCompression_dB(dpdIdx), ...
        phase1Summary.DigitalCompression_dB(dpdIdx), ...
        phase1Summary.EVM_RMS_pct(dpdIdx), ...
        phase1Summary.RxPower_dBFS(dpdIdx));
else
    warning('No valid DPD candidate was found.');
end

save(matFile, ...
    'sweepPlanTable', 'phase1Summary', ...
    'cfgDLFRC', 'sampleRate', 'powerScaleFactor', 'PAPR_dB', ...
    'txWaveform', ...
    'fixedRxGain_Pluto', 'fixedDsaSteps', 'fixedDsaAtten_dB', ...
    'ifSplitterCorrection_dB', 'mixerOutCorrection_dB', 'rfOutFilterInsertionLoss_dB', 'rfLoopbackAttenuator_dB', 'ifOutMeterProtectionAttenuator_dB', 'ifDetectorFloorGuard_dBm', 'ifDetectorSamplesPerPoint', ...
            'usePlutoTxLinearModel', 'plutoTxPowerSlope_dBperdB', 'plutoTxPowerIntercept_dBm', ...
            'plutoTxPowerFitMin_dB', 'plutoTxPowerFitMax_dB', 'plutoTxPowerFitRMSE_dB', 'plutoTxPowerFitR2', ...
    'evm_values', 'sync_metric_values', 'freq_offset_values_Hz', ...
    'acpr_values_dBc', 'nmse_values_dB', ...
    'rx_power_dBFS_values', 'tx_power_dBFS_values', ...
    'digital_gain_values_dB', 'digital_compression_dB', ...
    'attempt_count_values', 'evm_retry_failed_values', ...
    'stm32_mixer_raw_values', 'stm32_if_raw_values', ...
    'stm32_mixer_voltage_values', 'stm32_if_voltage_values', ...
    'stm32_mixer_dBm_values', 'stm32_if_dBm_values', ...
    'mixer_out_corr_dBm_values', 'if_out_corr_dBm_values', ...
    'pluto_out_calibrated_dBm_values', ...
            'if_gain_proxy_dB_values', 'if_gain_calibrated_dB_values', ...
            'if_compression_proxy_dB_values', 'if_compression_dB_values', ...
    'mixer_control_gain_dB_values', 'mixer_control_compression_dB', ...
    'linear_if_gain_proxy_dB', 'linear_if_gain_calibrated_dB', ...
            'linear_mixer_control_gain_dB', 'linear_digital_gain_dB', ...
    'P1dB_IF_found', 'P1dB_IF_index', ...
    'P1dB_digital_found', 'P1dB_digital_index', ...
    'best_EVM', 'best_tx_iq', 'best_rx_iq', ...
    'dpdIdx', 'selectionMode', 'phase1P1dB');

%% ==================== FIGURES ====================

try
    hFig1 = figure('Name','Downconverted IF No-Splitter Power','Color','w');
    tiledlayout(3,1);

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.IFOutCorrected_dBm, 'o-'); hold on;
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('Corrected power (dBm)');
    legend('IF output corrected','Location','best');
    title('Corrected downconverted IF detector power before Pluto RX');

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.RxPower_dBFS, 'o-'); hold on;
    yline(digitalRxSaturationLimit_dBFS, '--', 'RX saturation guard');
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('RX digital power (dBFS rel.)');
    title('Pluto RX digital power');

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.SyncMetric, 'o-');
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('Sync metric');
    title('Synchronization metric');

    saveas(hFig1, fullfile(figuresDir, 'TxSweep_DownconvertedIF_NoSplitter_Power.png'));

    hFig2 = figure('Name','Downconverted IF Compression No Splitter','Color','w');
    tiledlayout(3,1);

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.IFGainCalibrated_dB, 'o-');
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('IF calibrated gain (dB)');
    title('IF gain using calibrated Pluto TX output power');

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.IFCompression_dB, 'o-'); hold on;
    yline(1.0, '--', 'P1dB');
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('Compression (dB)');
    title('Downconverted IF physical compression');

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.DigitalCompression_dB, 'o-'); hold on;
    yline(1.0, '--', 'P1dB');
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('Compression (dB)');
    legend('Digital relative','Location','best');
    title('Digital relative compression');

    saveas(hFig2, fullfile(figuresDir, 'TxSweep_DownconvertedIF_NoSplitter_Compression.png'));

    hFig3 = figure('Name','EVM ACPR Downconverted IF Sweep','Color','w');
    tiledlayout(2,1);

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.EVM_RMS_pct, 'o-');
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('EVM RMS (%)');
    title('EVM vs TX gain');

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.ACPR_dBc, 'o-');
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('ACPR (dBc)');
    title('Approximate ACPR vs TX gain');

    saveas(hFig3, fullfile(figuresDir, 'TxSweep_DownconvertedIF_NoSplitter_EVM_ACPR.png'));

    hFig4 = figure('Name','Compression Candidate Overview','Color','w');
    tiledlayout(4,1);

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.IFOutCorrected_dBm, 'o-', 'LineWidth', 1.2);
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('Measured power (dBm)');
    title('Downconverted measured output power before Pluto RX');

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.IFCompression_dB, 'o-', 'LineWidth', 1.2); hold on;
    yline(1.0, '--', '1 dB compression');
    yline(ifCompressionTargetLow_dB, ':', 'DPD low target');
    yline(ifCompressionTargetHigh_dB, ':', 'DPD high target');
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('Physical compression (dB)');
    title('Physical compression from detector');

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.EVM_RMS_pct, 'o-', 'LineWidth', 1.2);
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('EVM RMS (%)');
    title('EVM vs compression point');

    nexttile;
    yyaxis left;
    plot(phase1Summary.TxGain_dB, phase1Summary.RxPower_dBFS, 'o-', 'LineWidth', 1.2);
    ylabel('RX power (dBFS rel.)');
    yyaxis right;
    plot(phase1Summary.TxGain_dB, phase1Summary.ACPR_dBc, 's-', 'LineWidth', 1.2);
    ylabel('ACPR (dBc)');
    grid on;
    xlabel('Pluto TX gain (dB)');
    title('RX digital power and ACPR');

    saveas(hFig4, fullfile(figuresDir, 'TxSweep_DownconvertedIF_NoSplitter_CandidateOverview.png'));

    hFig5 = figure('Name','EXP007 Meter Voltage and Power','Color','w');
    tiledlayout(2,1);

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.STM32_IFVoltage_mean_V, 'o-', 'LineWidth', 1.2);
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('Detector voltage (V)');
    title('STM32/LTC5596 detector voltage vs TX gain');

    nexttile;
    plot(phase1Summary.TxGain_dB, phase1Summary.STM32_IFOut_mean_dBm, 'o-', 'LineWidth', 1.2); hold on;
    plot(phase1Summary.TxGain_dB, phase1Summary.IFOutCorrected_dBm, 's-', 'LineWidth', 1.2);
    grid on;
    xlabel('Pluto TX gain (dB)');
    ylabel('Power (dBm)');
    legend('Meter reading','Corrected IF output','Location','best');
    title('Power meter reading and corrected IF power');

    saveas(hFig5, fullfile(figuresDir, 'EXP007_MeterVoltage_Power.png'));

catch ME
    warning('Could not create figures: %s', ME.message);
end

fprintf('\nDone.\n');

%% ========================================================================
%  LOCAL FUNCTIONS
% ========================================================================


function base = loadIFBoardBaseline(fileName, useFlag)
    base.available = false;
    base.tx = []; base.out = []; base.gain = []; base.comp = [];

    if ~useFlag || ~exist(fileName, "file")
        warning("IF board baseline not found or disabled: %s", fileName);
        return;
    end

    try
        T = readtable(fileName);
        names = string(T.Properties.VariableNames);

        txCol = pickColumn(names, ["TxGain_dB"]);
        outCol = pickColumn(names, ["IFBoardOutputBaseline_dBm","IFChainOutputCorrected_dBm","IFBoardOutputCorrected_dBm","DUTOutputCorrected_dBm","MeasuredOutputCorrected_dBm"]);
        gainCol = pickColumn(names, ["IFChainGainMeasured_dB","IFBoardGainMeasured_dB","DUTGain_dB"]);
        compCol = pickColumn(names, ["GainCompression_dB","IFBoardGainCompression_dB","IFChainGainCompression_dB","BGUCompressionEstimated_dB"]);

        base.tx = T.(txCol)(:);
        base.out = T.(outCol)(:);

        if strlength(gainCol) > 0
            base.gain = T.(gainCol)(:);
        else
            base.gain = nan(size(base.tx));
        end

        if strlength(compCol) > 0
            base.comp = T.(compCol)(:);
        else
            base.comp = nan(size(base.tx));
        end

        valid = isfinite(base.tx) & isfinite(base.out);
        base.tx = base.tx(valid);
        base.out = base.out(valid);
        base.gain = base.gain(valid);
        base.comp = base.comp(valid);

        [base.tx, order] = sort(base.tx);
        base.out = base.out(order);
        base.gain = base.gain(order);
        base.comp = base.comp(order);

        base.available = numel(base.tx) >= 2;
    catch ME
        warning("Could not load IF board baseline %s: %s", fileName, ME.message);
    end
end

function base = loadUpconverterBaseline(fileName, useFlag)
    base.available = false;
    base.tx = []; base.rfPin = []; base.rfAfterFilter = []; base.gain = []; base.comp = [];

    if ~useFlag || ~exist(fileName, "file")
        warning("Upconverter baseline not found or disabled: %s", fileName);
        return;
    end

    try
        T = readtable(fileName);
        names = string(T.Properties.VariableNames);

        txCol = pickColumn(names, ["TxGain_dB"]);
        rfPinCol = pickColumn(names, ["RFOutPinCorrected_dBm","RFOutPinEstimated_dBm"]);
        rfAfterCol = pickColumn(names, ["RFOutAfterFilterCorrected_dBm","RFOutAfterFilterEstimated_dBm"]);
        gainCol = pickColumn(names, ["UpconverterGain_dB","UpconverterGainEstimated_dB"]);
        compCol = pickColumn(names, ["UpconverterGainCompression_dB","UpconverterCompressionEstimated_dB"]);

        base.tx = T.(txCol)(:);
        base.rfPin = T.(rfPinCol)(:);

        if strlength(rfAfterCol) > 0
            base.rfAfterFilter = T.(rfAfterCol)(:);
        else
            base.rfAfterFilter = nan(size(base.rfPin));
        end

        if strlength(gainCol) > 0
            base.gain = T.(gainCol)(:);
        else
            base.gain = nan(size(base.rfPin));
        end

        if strlength(compCol) > 0
            base.comp = T.(compCol)(:);
        else
            base.comp = nan(size(base.rfPin));
        end

        valid = isfinite(base.tx) & isfinite(base.rfPin);
        base.tx = base.tx(valid);
        base.rfPin = base.rfPin(valid);
        base.rfAfterFilter = base.rfAfterFilter(valid);
        base.gain = base.gain(valid);
        base.comp = base.comp(valid);

        [base.tx, order] = sort(base.tx);
        base.rfPin = base.rfPin(order);
        base.rfAfterFilter = base.rfAfterFilter(order);
        base.gain = base.gain(order);
        base.comp = base.comp(order);

        base.available = numel(base.tx) >= 2;
    catch ME
        warning("Could not load upconverter baseline %s: %s", fileName, ME.message);
    end
end

function col = pickColumn(names, candidates)
    col = "";
    for k = 1:numel(candidates)
        hit = find(names == candidates(k), 1, "first");
        if ~isempty(hit)
            col = names(hit);
            return;
        end
    end
end

function yq = interpBaseline(x, y, xq)
    yq = nan(size(xq));
    if isempty(x) || isempty(y) || numel(x) < 2 || ~any(isfinite(y))
        return;
    end
    valid = isfinite(x) & isfinite(y);
    if nnz(valid) < 2
        return;
    end
    yq = interp1(x(valid), y(valid), xq, "linear", "extrap");
end

function nmse_dB = computeNMSEAligned(txRef, rxObs)
    txRef = txRef(:);
    rxObs = rxObs(:);
    N = min(length(txRef), length(rxObs));
    txRef = txRef(1:N);
    rxObs = rxObs(1:N);

    valid = isfinite(real(txRef)) & isfinite(imag(txRef)) & ...
            isfinite(real(rxObs)) & isfinite(imag(rxObs));
    txRef = txRef(valid);
    rxObs = rxObs(valid);

    if numel(txRef) < 1000
        nmse_dB = NaN;
        return;
    end

    % Least-squares complex scaling from TX reference to RX observation.
    alpha = (txRef' * rxObs) / (txRef' * txRef + eps);
    err = rxObs - alpha*txRef;
    nmse_dB = 10*log10(mean(abs(err).^2) / (mean(abs(rxObs).^2) + eps) + eps);
end

function txShort = bestAttemptLocalTx(txWaveform, n)
    txWaveform = txWaveform(:);
    n = min(n, length(txWaveform));
    txShort = txWaveform(1:n);
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
            warning('RX capture is shorter than TX waveform.');
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
        warning('%s', sprintf('Error in synchronizeFineXcorr: %s', ME.message));
        rx_aligned = [];
        freqOffset = 0;
        syncMetric = 0;
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
        if any(adjLowIdx)
            pAdj = pAdj + trapz(f(adjLowIdx), pxx(adjLowIdx));
        end
        if any(adjHighIdx)
            pAdj = pAdj + trapz(f(adjHighIdx), pxx(adjHighIdx));
        end

        if pMain <= 0 || pAdj <= 0 || ~isfinite(pMain) || ~isfinite(pAdj)
            return;
        end

        acpr_dBc = 10*log10(pAdj / pMain);

    catch ME
        warning('%s', sprintf('Error in computeACPRCentered: %s', ME.message));
        acpr_dBc = NaN;
    end
end

function line = querySTM32(stm32, cmd, expectedPrefix, timeout_s)
    if nargin < 4
        timeout_s = 3;
    end

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

    error('STM32 timeout. CMD="%s", expected="%s", last line="%s"', ...
        cmd, expectedPrefix, line);
end

function pwr = measureIFPowerSTM32(stm32, txGain, nSamples)
    % Reads the one-sensor STM32 firmware response.
    % Command:
    %   MEAS,TxGain,nSamples
    % Expected lines:
    %   RXCMD,MEAS,...
    %   START,TxGain
    %   DATA,time_ms,raw,voltage_V,dBm
    %   ...
    %   END,TxGain,nValid

    if nargin < 3 || isempty(nSamples)
        nSamples = 80;
    end

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

            if strlength(lastLine) == 0
                continue;
            end

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

function setSafeState_CorrectedSensors(txObj, idleGain, stm32, fixedDsaSteps)
    %#ok<INUSD> fixedDsaSteps is metadata only in the one-sensor firmware.
    try
        txObj.Gain = idleGain;
        % Do not transmit a different idle frame length here; SDRTxPluto is size-locked.
        % Idle gain is sufficient for safe state.
    catch
    end
end

function cleanupPhase1_CorrectedSensors(txObj, rxObj, idleGain, stm32, fixedDsaSteps)
    try
        setSafeState_CorrectedSensors(txObj, idleGain, stm32, fixedDsaSteps);
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

    try
        clear stm32;
    catch
    end
end

function T = buildSummaryTable(sweepPlanTable, ...
    stm32_mixer_raw_values, stm32_if_raw_values, ...
    stm32_mixer_voltage_values, stm32_if_voltage_values, ...
    stm32_mixer_dBm_values, stm32_if_dBm_values, ...
    mixer_out_corr_dBm_values, if_out_corr_dBm_values, ...
    pluto_out_calibrated_dBm_values, ...
    if_gain_proxy_dB_values, if_gain_calibrated_dB_values, ...
    if_compression_proxy_dB_values, if_compression_dB_values, ...
    mixer_control_gain_dB_values, mixer_control_compression_dB, ...
    evm_values, acpr_values_dBc, nmse_values_dB, sync_metric_values, freq_offset_values_Hz, ...
    rx_power_dBFS_values, tx_power_dBFS_values, ...
    digital_gain_values_dB, digital_compression_dB, ...
    attempt_count_values, evm_retry_failed_values)

    % One-sensor summary table. Mixer-related inputs are accepted only for
    % compatibility with the old calling sequence and are intentionally not
    % written to the CSV.

    T = table( ...
        sweepPlanTable.PointIndex, ...
        sweepPlanTable.TxGain_dB, ...
        sweepPlanTable.PlutoOutCalibrated_dBm, ...
        sweepPlanTable.RxGain_dB, ...
        sweepPlanTable.DsaExtSteps, ...
        sweepPlanTable.DsaExtAtten_dB, ...
        sweepPlanTable.IFSplitterCorrection_dB, ...
        sweepPlanTable.CableLoss_RFOut_to_FilterInput_dB, ...
        sweepPlanTable.RFOutFilterInsertionLoss_dB, ...
        sweepPlanTable.CableLoss_FilterOutput_to_RFAttInput_dB, ...
        sweepPlanTable.RFLoopbackAttenuator_dB, ...
        sweepPlanTable.TotalRFOutPinToRFInLoss_dB, ...
        sweepPlanTable.IFOutMeterProtectionAttenuator_dB, ...
        sweepPlanTable.PowerScaleFactor, ...
        sweepPlanTable.UpconverterTxDsaAtten_dB, ...
        sweepPlanTable.IFBoardCompressionEstimated_dB, ...
        sweepPlanTable.RFOutPinEstimated_dBm, ...
        sweepPlanTable.RFOutAfterFilterEstimated_dBm, ...
        sweepPlanTable.UpconverterCompressionEstimated_dB, ...
        sweepPlanTable.DownconverterRFInputEstimated_dBm, ...
        stm32_if_raw_values, ...
        stm32_if_voltage_values, ...
        stm32_if_dBm_values, ...
        if_out_corr_dBm_values, ...
        pluto_out_calibrated_dBm_values, ...
        if_gain_proxy_dB_values, ...
        if_gain_calibrated_dB_values, ...
        if_compression_proxy_dB_values, ...
        if_compression_dB_values, ...
        evm_values, ...
        acpr_values_dBc, ...
        nmse_values_dB, ...
        sync_metric_values, ...
        freq_offset_values_Hz, ...
        rx_power_dBFS_values, ...
        tx_power_dBFS_values, ...
        digital_gain_values_dB, ...
        digital_compression_dB, ...
        attempt_count_values, ...
        evm_retry_failed_values, ...
        'VariableNames', { ...
            'PointIndex', ...
            'TxGain_dB', ...
            'PlutoOutCalibrated_dBm', ...
            'RxGain_dB', ...
            'DsaExtSteps', ...
            'DsaExtAtten_dB', ...
            'IFSplitterCorrection_dB', ...
            'CableLoss_RFOut_to_FilterInput_dB', ...
            'RFOutFilterInsertionLoss_dB', ...
            'CableLoss_FilterOutput_to_RFAttInput_dB', ...
            'RFLoopbackAttenuator_dB', ...
            'TotalRFOutPinToRFInLoss_dB', ...
            'IFOutMeterProtectionAttenuator_dB', ...
            'PowerScaleFactor', ...
            'UpconverterTxDsaAtten_dB', ...
            'IFBoardCompressionEstimated_dB', ...
            'Pout_RFOutPinEstimated_dBm', ...
            'RFOutAfterFilterEstimated_dBm', ...
            'UpconverterCompressionEstimated_dB', ...
            'DownconverterRFInputEstimated_dBm', ...
            'STM32_IFRaw_mean', ...
            'STM32_IFVoltage_mean_V', ...
            'STM32_IFOut_mean_dBm', ...
            'IFOutCorrected_dBm', ...
            'PlutoOutCalibrated_dBm_Vector', ...
            'IFGainProxyCmd_dB', ...
            'IFGainCalibrated_dB', ...
            'IFCompressionProxyCmd_dB', ...
            'IFCompression_dB', ...
            'EVM_RMS_pct', ...
            'ACPR_dBc', ...
            'NMSE_dB', ...
            'SyncMetric', ...
            'FreqOffset_Hz', ...
            'RxPower_dBFS', ...
            'TxPower_dBFS', ...
            'DigitalGain_dB', ...
            'DigitalCompression_dB', ...
            'CaptureAttempts', ...
            'EVMRetryFailed'} ...
    );
end


%% ============================================================
% ROBUST SYNC FUNCTIONS IMPORTED FROM EXP009
%% ============================================================
function [alignInfo, alignedData] = robustAlignTxRxForDPD(xTx, yRx, Fs, D, fineHalfWin, magThrRel, numFramesForAlign)
    xTx = xTx(:);
    yRx = yRx(:);

    Ntx = numel(xTx);
    Nuse = min(Ntx*numFramesForAlign, Ntx);
    x = xTx(1:Nuse);

    if numel(yRx) < Nuse + 10
        error('Captura RX demasiado corta para alineamiento.');
    end

    % Normalizacion para correlacion, sin alterar datos usados despues.
    x0 = x - mean(x, 'omitnan');
    y0 = yRx - mean(yRx, 'omitnan');
    x0 = x0 ./ (rms(abs(x0)) + eps);
    y0 = y0 ./ (rms(abs(y0)) + eps);

    % Correlacion gruesa decimada.
    xD = x0(1:D:end);
    yD = y0(1:D:end);
    if numel(yD) < numel(xD)
        error('Captura decimada menor que referencia decimada.');
    end
    cCoarse = conv(yD, flipud(conj(xD)), 'valid');
    [~, idxCoarse] = max(abs(cCoarse));
    startCoarse = (idxCoarse - 1) * D + 1;

    % Busqueda fina alrededor del inicio grueso.
    startMin = max(1, startCoarse - fineHalfWin);
    startMax = min(numel(yRx) - Nuse + 1, startCoarse + fineHalfWin);
    if startMax < startMin
        error('Ventana fina invalida.');
    end

    starts = startMin:startMax;
    corrVals = nan(numel(starts),1);
    for k = 1:numel(starts)
        ys = y0(starts(k):starts(k)+Nuse-1);
        corrVals(k) = abs(x0' * ys) / ((norm(x0)+eps)*(norm(ys)+eps));
    end
    [syncMetric, iBest] = max(corrVals);
    startSample = starts(iBest);
    delaySamples = startSample - 1;

    yAlignedRaw = yRx(startSample:startSample+Nuse-1);
    xAligned = x;

    % Primera ganancia compleja.
    g0 = (xAligned' * yAlignedRaw) / (xAligned' * xAligned + eps);
    z = yAlignedRaw .* conj(g0*xAligned);

    % Estimacion CFO por pendiente de fase. Evitar muestras con magnitud baja.
    magMask = abs(xAligned) > magThrRel * max(abs(xAligned));
    if nnz(magMask) < 1000
        magMask = true(size(xAligned));
    end
    n = (0:Nuse-1).';
    phaseErr = unwrap(angle(z(magMask)));
    nFit = n(magMask);
    p = polyfit(double(nFit), double(phaseErr), 1);
    phaseSlope_radPerSample = p(1);
    freqOffset_Hz = phaseSlope_radPerSample * Fs / (2*pi);

    % Corregir CFO en y.
    yCFO = yAlignedRaw .* exp(-1j*2*pi*freqOffset_Hz*n/Fs);

    % Segunda ganancia compleja despues de CFO.
    complexGain = (xAligned' * yCFO) / (xAligned' * xAligned + eps);
    yNorm = yCFO ./ (complexGain + eps);

    err = yNorm - xAligned;
    nmseLin = sum(abs(err).^2) / (sum(abs(xAligned).^2) + eps);
    nmse_dB = 10*log10(nmseLin + eps);
    waveformEVM_pct = 100*sqrt(nmseLin);

    rxPower_dBFS = 20*log10(rms(abs(yAlignedRaw)) + eps);
    peakRx_dBFS = 20*log10(max(abs(yAlignedRaw)) + eps);

    % Correlacion final normalizada despues de CFO/ganancia.
    syncMetricFinal = abs(xAligned' * yNorm) / ((norm(xAligned)+eps)*(norm(yNorm)+eps));

    alignInfo = struct();
    alignInfo.delaySamples = delaySamples;
    alignInfo.startSample = startSample;
    alignInfo.syncMetric = syncMetricFinal;
    alignInfo.syncMetricCoarseFine = syncMetric;
    alignInfo.freqOffset_Hz = freqOffset_Hz;
    alignInfo.phaseSlope_radPerSample = phaseSlope_radPerSample;
    alignInfo.complexGain = complexGain;
    alignInfo.nmse_dB = nmse_dB;
    alignInfo.waveformEVM_pct = waveformEVM_pct;
    alignInfo.rxPower_dBFS = rxPower_dBFS;
    alignInfo.peakRx_dBFS = peakRx_dBFS;
    alignInfo.corrDelayAxis_samples = starts(:) - 1;
    alignInfo.corrMagNormalized = corrVals(:);

    alignedData = struct();
    alignedData.x_aligned = xAligned;
    alignedData.y_aligned_raw = yAlignedRaw;
    alignedData.y_cfo_corrected = yCFO;
    alignedData.y_normalized = yNorm;
    alignedData.error = err;
end

function score = alignAttemptScore(info, isClip)
    % Menor score es mejor. Priorizamos NMSE y penalizamos saturacion.
    score = info.nmse_dB;
    score = score - 8*info.syncMetric;
    if isClip
        score = score + 50;
    end
    if ~isfinite(score)
        score = Inf;
    end
end

function evmPct = computeNREVM_Safe(rxFrame, cfgDL, cfgEVM)
    evmPct = NaN;
    try
        rxFrame = rxFrame(:);
        evmInfo = hNRDownlinkEVM(cfgDL, rxFrame, cfgEVM);
        evmPct = evmInfo.PDSCH.OverallEVM.RMS * 100;
    catch
        evmPct = NaN;
    end
end

