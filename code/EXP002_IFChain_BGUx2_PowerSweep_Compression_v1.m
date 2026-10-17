clear; clc;
warning('off', 'all')

%% ============================================================
% EXP002 - IF CHAIN POWER SWEEP AND COMPRESSION CHARACTERIZATION
% =============================================================
% Objective:
%   1) Generate a 5G NR downlink waveform.
%   2) Transmit it with Pluto SDR at 5 GHz.
%   3) Sweep Pluto TxGain.
%   4) Use the external baseline CSV measured with a spectrum analyzer to
%      estimate the actual Pluto output power for each TxGain.
%   5) Measure the output of the IF chain using STM32 + LTC5596.
%   6) Store both detector voltage/ADC data and power in dBm.
%   7) Correct the measured power by the temporary 6 dB protection
%      attenuator placed before the power detector.
%   8) Estimate IF-chain gain and gain compression.
%
% Physical chain for this experiment:
%
%   MATLAB 5G NR waveform
%   -> Pluto TX at 5 GHz
%   -> IF board input
%   -> BGU #1
%   -> passive 3 dB attenuator
%   -> BGU #2
%   -> temporary 6 dB protection attenuator
%   -> LTC5596 / STM32 power meter
%
% Important interpretation:
%   - The 6 dB attenuator is only for protecting the power detector.
%   - Therefore:
%       IFChainOutputCorrected_dBm = Power_meter_dBm + 6 dB
%
%   - The estimated input to BGU #2 is:
%       BGU2InputEstimated_dBm = PlutoOutBaseline_dBm + BGU1_gain_typ_dB - 3 dB
%
%   - The PAPR is computed from the generated waveform and used to estimate
%     peak-envelope stress at BGU #1 and BGU #2 inputs.
%
% Safety note:
%   The code includes a configurable safety stop based on measured detector
%   input power. Adjust only if the power detector, attenuator and cables are
%   rated for the intended level.

%% ============================================================
% 5G NR DOWNLINK FRC CONFIGURATION
% =============================================================

addpath("C:\Users\jpfer\OneDrive\Documentos\MATLAB\Examples\R2024b\5g\NRWaveformCaptureAndAnalysisWithSDRExample")

cfgDLFRC = nrDLCarrierConfig;
cfgDLFRC.Label = 'DL-FRC-FR1-256QAM';
cfgDLFRC.FrequencyRange = 'FR1';
cfgDLFRC.ChannelBandwidth = 20;
cfgDLFRC.NCellID = 1;
cfgDLFRC.NumSubframes = 10;
cfgDLFRC.InitialNSubframe = 0;
cfgDLFRC.WindowingPercent = 0;
cfgDLFRC.SampleRate = [];
cfgDLFRC.CarrierFrequency = 0;

scscarrier = nrSCSCarrierConfig;
scscarrier.SubcarrierSpacing = 30;
scscarrier.NSizeGrid = 51;
scscarrier.NStartGrid = 0;
cfgDLFRC.SCSCarriers = {scscarrier};

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
ssburst.CellBarred = false;
ssburst.IntraFreqReselection = false;
ssburst.PDCCHConfigSIB1 = 0;
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
pdcch.CCEOffset = [];
pdcch.SlotAllocation = 1:19;
pdcch.Period = 20;
pdcch.Coding = false;
pdcch.DataBlockSize = 20;
pdcch.DataSource = 0;
pdcch.RNTI = 0;
pdcch.DMRSScramblingID = 1;
pdcch.DMRSPower = 0;
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
pdsch1.PRBSetType = 'VRB';
pdsch1.VRBToPRBInterleaving = false;
pdsch1.VRBBundleSize = 2;
pdsch1.NID = [];
pdsch1.RNTI = 0;
pdsch1.Coding = true;
pdsch1.TargetCodeRate = 0.7783203125;
pdsch1.TBScaling = 1;
pdsch1.XOverhead = 0;
pdsch1.RVSequence = 0;
pdsch1.DataSource = 'PN9';
pdsch1.DMRSPower = 3;
pdsch1.EnablePTRS = false;
pdsch1.PTRSPower = 0;

pdsch1ReservedPRB = nrPDSCHReservedConfig;
pdsch1ReservedPRB.PRBSet = 0:2;
pdsch1ReservedPRB.SymbolSet = [0 1];
pdsch1ReservedPRB.Period = 1;
pdsch1.ReservedPRB = {pdsch1ReservedPRB};

pdsch1DMRS = nrPDSCHDMRSConfig;
pdsch1DMRS.DMRSConfigurationType = 1;
pdsch1DMRS.DMRSReferencePoint = 'CRB0';
pdsch1DMRS.DMRSTypeAPosition = 2;
pdsch1DMRS.DMRSAdditionalPosition = 2;
pdsch1DMRS.DMRSLength = 1;
pdsch1DMRS.CustomSymbolSet = [];
pdsch1DMRS.DMRSPortSet = [];
pdsch1DMRS.NIDNSCID = [];
pdsch1DMRS.NSCID = 0;
pdsch1DMRS.NumCDMGroupsWithoutData = 2;
pdsch1DMRS.DMRSDownlinkR16 = false;
pdsch1DMRS.DMRSEnhancedR18 = false;
pdsch1.DMRS = pdsch1DMRS;

pdsch1PTRS = nrPDSCHPTRSConfig;
pdsch1PTRS.TimeDensity = 1;
pdsch1PTRS.FrequencyDensity = 2;
pdsch1PTRS.REOffset = '00';
pdsch1PTRS.PTRSPortSet = [];
pdsch1.PTRS = pdsch1PTRS;

pdsch2 = nrWavegenPDSCHConfig;
pdsch2.Enable = true;
pdsch2.Label = 'Data Region OCNG for BWP 1, PRBs 0:50, symbols 0:13, slot 0';
pdsch2.Power = 0;
pdsch2.BandwidthPartID = 1;
pdsch2.Modulation = 'QPSK';
pdsch2.NumLayers = 1;
pdsch2.MappingType = 'A';
pdsch2.ReservedCORESET = [];
pdsch2.SymbolAllocation = [0 14];
pdsch2.SlotAllocation = 0;
pdsch2.Period = 20;
pdsch2.PRBSet = 0:50;
pdsch2.PRBSetType = 'VRB';
pdsch2.VRBToPRBInterleaving = false;
pdsch2.VRBBundleSize = 2;
pdsch2.NID = 2;
pdsch2.RNTI = 2;
pdsch2.Coding = false;
pdsch2.TargetCodeRate = 0.513671875;
pdsch2.TBScaling = 1;
pdsch2.XOverhead = 0;
pdsch2.RVSequence = [0 2 3 1];
pdsch2.DataSource = 'PN9';
pdsch2.DMRSPower = 0;
pdsch2.EnablePTRS = false;
pdsch2.PTRSPower = 0;

pdschreserved = nrPDSCHReservedConfig;
pdschreserved.PRBSet = [];
pdschreserved.SymbolSet = [];
pdschreserved.Period = [];
pdsch2.ReservedPRB = {pdschreserved};

pdschdmrs = nrPDSCHDMRSConfig;
pdschdmrs.DMRSConfigurationType = 1;
pdschdmrs.DMRSReferencePoint = 'CRB0';
pdschdmrs.DMRSTypeAPosition = 2;
pdschdmrs.DMRSAdditionalPosition = 2;
pdschdmrs.DMRSLength = 1;
pdschdmrs.CustomSymbolSet = [];
pdschdmrs.DMRSPortSet = [];
pdschdmrs.NIDNSCID = [];
pdschdmrs.NSCID = 0;
pdschdmrs.NumCDMGroupsWithoutData = 2;
pdschdmrs.DMRSDownlinkR16 = false;
pdschdmrs.DMRSEnhancedR18 = false;
pdsch2.DMRS = pdschdmrs;

pdschptrs = nrPDSCHPTRSConfig;
pdschptrs.TimeDensity = 1;
pdschptrs.FrequencyDensity = 2;
pdschptrs.REOffset = '00';
pdschptrs.PTRSPortSet = [];
pdsch2.PTRS = pdschptrs;

pdsch3 = nrWavegenPDSCHConfig;
pdsch3.Enable = true;
pdsch3.Label = 'Data Region OCNG for BWP 1, PRBs 0:50, symbols 0:1, slots 1:19';
pdsch3.Power = 0;
pdsch3.BandwidthPartID = 1;
pdsch3.Modulation = 'QPSK';
pdsch3.NumLayers = 1;
pdsch3.MappingType = 'B';
pdsch3.ReservedCORESET = [];
pdsch3.SymbolAllocation = [0 2];
pdsch3.SlotAllocation = 1:19;
pdsch3.Period = 20;
pdsch3.PRBSet = 0:50;
pdsch3.PRBSetType = 'VRB';
pdsch3.VRBToPRBInterleaving = false;
pdsch3.VRBBundleSize = 2;
pdsch3.NID = 2;
pdsch3.RNTI = 2;
pdsch3.Coding = false;
pdsch3.TargetCodeRate = 0.513671875;
pdsch3.TBScaling = 1;
pdsch3.XOverhead = 0;
pdsch3.RVSequence = [0 2 3 1];
pdsch3.DataSource = 'PN9';
pdsch3.DMRSPower = 0;
pdsch3.EnablePTRS = false;
pdsch3.PTRSPower = 0;
pdsch3.ReservedPRB = {pdschreserved};

pdschdmrs3 = nrPDSCHDMRSConfig;
pdschdmrs3.DMRSConfigurationType = 1;
pdschdmrs3.DMRSReferencePoint = 'CRB0';
pdschdmrs3.DMRSTypeAPosition = 2;
pdschdmrs3.DMRSAdditionalPosition = 0;
pdschdmrs3.DMRSLength = 1;
pdschdmrs3.CustomSymbolSet = [];
pdschdmrs3.DMRSPortSet = [];
pdschdmrs3.NIDNSCID = [];
pdschdmrs3.NSCID = 0;
pdschdmrs3.NumCDMGroupsWithoutData = 2;
pdschdmrs3.DMRSDownlinkR16 = false;
pdschdmrs3.DMRSEnhancedR18 = false;
pdsch3.DMRS = pdschdmrs3;
pdsch3.PTRS = pdschptrs;

cfgDLFRC.PDSCH = {pdsch1,pdsch2,pdsch3};

csirs = nrWavegenCSIRSConfig;
csirs.Enable = false;
csirs.Label = 'CSIRS1';
csirs.Power = 0;
csirs.BandwidthPartID = 1;
csirs.CSIRSType = 'nzp';
csirs.CSIRSPeriod = 'on';
csirs.RowNumber = 1;
csirs.Density = 'three';
csirs.SymbolLocations = 0;
csirs.SubcarrierLocations = 0;
csirs.NumRB = 51;
csirs.RBOffset = 0;
csirs.NID = 1;
cfgDLFRC.CSIRS = {csirs};

%% ============================================================
% WAVEFORM GENERATION AND PAPR
% =============================================================

[waveform, info] = nrWaveformGenerator(cfgDLFRC);

Fs = info.ResourceGrids(1).Info.SampleRate;
sampleRate = Fs;
fprintf("Sample rate generated: %.3f Msps\n", sampleRate/1e6);

powerScaleFactor = 0.8;
txWaveform = waveform .* (1 ./ max(abs(waveform)) * powerScaleFactor);
txWaveform = txWaveform(:);

samplesPerFrame = round(sampleRate * 10e-3);
fprintf("Samples per 10 ms frame: %d\n", samplesPerFrame);

txInstantaneousPower = abs(txWaveform).^2;
txAveragePower_linear = mean(txInstantaneousPower);
txPeakPower_linear    = max(txInstantaneousPower);
PAPR_linear = txPeakPower_linear/(txAveragePower_linear + eps);
PAPR_dB     = 10*log10(PAPR_linear);

fprintf("Waveform PAPR: %.4f dB | linear %.6f\n", PAPR_dB, PAPR_linear);

%% ============================================================
% EXPERIMENT CONFIGURATION
% =============================================================

deviceName       = "Pluto";
centerFrequency = 5e9;
idleGain_dB     = -80;

measurementPoint = "IFChain_Output_after_BGU2_before_6dB_meter_attenuator";
dutName          = "IFChain_BGU1_3dBAtt_BGU2";
notes            = "EXP002 IF chain power sweep. Pluto -> BGU1 -> 3 dB attenuator -> BGU2 -> 6 dB protection attenuator -> LTC5596/STM32.";

% Physical IF-chain parameters.
bgu1SmallSignalGain_typ_dB = 14.0;      % Datasheet typical gain near 5.1 GHz.
bgu2SmallSignalGain_typ_dB = 14.0;      % Datasheet typical gain near 5.1 GHz.
interstageAttenuator_dB    = 3.0;       % Physical attenuator between BGU #1 and BGU #2.
outputProtectionAttenuator_dB = 6.0;    % Temporary attenuator before the power detector.
outputMeasurementCorrection_dB = outputProtectionAttenuator_dB;

% BGU7258 reference limits used only for flags, not for automatic stopping.
bguInputP1dB_typ_dBm = -4.0;
bguInputAbsMax_dBm  = 10.0;
assumedPAPRForPlanning_dB = 11.0;

% Power detector safety. This is the power seen by the detector, before
% adding the +6 dB correction. Increase only if the detector path is rated.
enableSafetyStop = true;
powerMeterSafetyLimit_dBm = 2.0;

%% =========================
% Pluto baseline CSV
% ==========================
% Baseline file is expected in:
%   DPDV2/baseline/Baseline_Power_Tx_Pluto.csv
%
% Required columns:
%   TxGain_dB
%   Potencia_SA_dBm

useBaselineCSV = true;
baselineCsvFile = "Baseline_Power_Tx_Pluto.csv";

%% =========================
% Sweep plan
% ==========================
% The default range is conservative enough to observe the IF chain moving
% toward BGU #2 compression while protecting the detector with the 6 dB pad.
% You can reduce TxGain_stop_dB if the safety stop triggers too early.

TxGain_start_dB = -44;
TxGain_stop_dB  = -6;
TxGain_step_dB  = 0.25;

useManualTxGainList = false;
manualTxGainList_dB = [-30 -28 -26 -24 -22 -20 -18 -16 -14 -12 -10 -9 -8 -7 -6 -5 -4];

if useManualTxGainList
    TxGain_dB_plan = manualTxGainList_dB(:);
else
    TxGain_dB_plan = (TxGain_start_dB:TxGain_step_dB:TxGain_stop_dB).';
end

nPoints = numel(TxGain_dB_plan);
PointIndex = (1:nPoints).';

scriptDir = fileparts(mfilename("fullpath"));
if strlength(string(scriptDir)) == 0
    scriptDir = pwd;
end
projectDir = fileparts(scriptDir);

[PlutoOutBaseline_dBm, PlutoBaselineMode, baselineResolvedFile] = estimatePlutoPowerFromBaseline( ...
    TxGain_dB_plan, baselineCsvFile, useBaselineCSV, projectDir);

BGU1InputAvgEstimated_dBm = PlutoOutBaseline_dBm;
BGU1InputPEPEstimated_dBm = BGU1InputAvgEstimated_dBm + PAPR_dB;
BGU1OutputAvgSmallSignalEstimated_dBm = BGU1InputAvgEstimated_dBm + bgu1SmallSignalGain_typ_dB;
BGU2InputAvgEstimated_dBm = BGU1OutputAvgSmallSignalEstimated_dBm - interstageAttenuator_dB;
BGU2InputPEPEstimated_dBm = BGU2InputAvgEstimated_dBm + PAPR_dB;
IFChainOutputSmallSignalEstimated_dBm = BGU2InputAvgEstimated_dBm + bgu2SmallSignalGain_typ_dB;
PowerMeterInputSmallSignalEstimated_dBm = IFChainOutputSmallSignalEstimated_dBm - outputProtectionAttenuator_dB;

BGU2AvgAboveP1dBFlag = BGU2InputAvgEstimated_dBm >= bguInputP1dB_typ_dBm;
BGU2PEPAboveP1dBFlag = BGU2InputPEPEstimated_dBm >= bguInputP1dB_typ_dBm;
BGU2PEPNearAbsMaxFlag = BGU2InputPEPEstimated_dBm >= (bguInputAbsMax_dBm - 3.0);

sweepPlanTable = table( ...
    PointIndex, ...
    TxGain_dB_plan, ...
    PlutoOutBaseline_dBm, ...
    BGU1InputAvgEstimated_dBm, ...
    BGU1InputPEPEstimated_dBm, ...
    BGU1OutputAvgSmallSignalEstimated_dBm, ...
    BGU2InputAvgEstimated_dBm, ...
    BGU2InputPEPEstimated_dBm, ...
    IFChainOutputSmallSignalEstimated_dBm, ...
    PowerMeterInputSmallSignalEstimated_dBm, ...
    BGU2AvgAboveP1dBFlag, ...
    BGU2PEPAboveP1dBFlag, ...
    BGU2PEPNearAbsMaxFlag, ...
    repmat(string(PlutoBaselineMode), nPoints, 1), ...
    repmat(string(dutName), nPoints, 1), ...
    repmat(string(measurementPoint), nPoints, 1), ...
    repmat(centerFrequency, nPoints, 1), ...
    repmat(powerScaleFactor, nPoints, 1), ...
    repmat(PAPR_dB, nPoints, 1), ...
    repmat(assumedPAPRForPlanning_dB, nPoints, 1), ...
    repmat(bgu1SmallSignalGain_typ_dB, nPoints, 1), ...
    repmat(interstageAttenuator_dB, nPoints, 1), ...
    repmat(bgu2SmallSignalGain_typ_dB, nPoints, 1), ...
    repmat(outputProtectionAttenuator_dB, nPoints, 1), ...
    repmat(outputMeasurementCorrection_dB, nPoints, 1), ...
    'VariableNames', { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'PlutoOutBaseline_dBm', ...
        'BGU1InputAvgEstimated_dBm', ...
        'BGU1InputPEPEstimated_dBm', ...
        'BGU1OutputAvgSmallSignalEstimated_dBm', ...
        'BGU2InputAvgEstimated_dBm', ...
        'BGU2InputPEPEstimated_dBm', ...
        'IFChainOutputSmallSignalEstimated_dBm', ...
        'PowerMeterInputSmallSignalEstimated_dBm', ...
        'BGU2AvgAboveP1dBFlag', ...
        'BGU2PEPAboveP1dBFlag', ...
        'BGU2PEPNearAbsMaxFlag', ...
        'PlutoBaselineMode', ...
        'DUT', ...
        'MeasurementPoint', ...
        'CenterFrequency_Hz', ...
        'DigitalPowerScale', ...
        'PAPR_dB', ...
        'AssumedPAPRForPlanning_dB', ...
        'BGU1SmallSignalGainTyp_dB', ...
        'InterstageAttenuator_dB', ...
        'BGU2SmallSignalGainTyp_dB', ...
        'OutputProtectionAttenuator_dB', ...
        'OutputMeasurementCorrection_dB'} ...
);

fprintf("\nBaseline source: %s\n", baselineResolvedFile);
fprintf("Estimated TxGain for average BGU2 input near P1dB %.1f dBm: %.2f dB\n", ...
    bguInputP1dB_typ_dBm, estimateTxGainAtTarget(BGU2InputAvgEstimated_dBm, TxGain_dB_plan, bguInputP1dB_typ_dBm));
fprintf("Estimated TxGain for PEP BGU2 input near P1dB %.1f dBm: %.2f dB\n\n", ...
    bguInputP1dB_typ_dBm, estimateTxGainAtTarget(BGU2InputPEPEstimated_dBm, TxGain_dB_plan, bguInputP1dB_typ_dBm));

%% =========================
% STM32 serial configuration
% ==========================

useSTM32PowerMeter = true;
serialPort       = "COM12";
serialBaud       = 209700;
serialTerminator = "LF";
serialTimeout_s  = 0.30;
doPingTest       = true;
nPowerSamplesPerPoint = 50;

rfSettleAfterTxChange_s = 0.50;
rfOffSettle_s           = 0.20;

%% =========================
% Output files
% ==========================

EXP_ID     = "EXP002";
CATEGORY   = "IFCHAIN";
DEVICE     = "BGU1_3dB_BGU2";
SHORT_NAME = "POWER_SWEEP_COMPRESSION";
VERSION    = "v1";

runTag = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
experimentFolder = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + VERSION;

outputDir = fullfile(projectDir, "data", experimentFolder, runTag);
rawDir       = fullfile(outputDir, "raw");
processedDir = fullfile(outputDir, "processed");
figuresDir   = fullfile(outputDir, "figures");

if ~exist(rawDir, "dir"); mkdir(rawDir); end
if ~exist(processedDir, "dir"); mkdir(processedDir); end
if ~exist(figuresDir, "dir"); mkdir(figuresDir); end

baseName = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + runTag + "_" + VERSION;

csvPlanFile         = fullfile(processedDir, baseName + "_tx-sweep-plan.csv");
csvPowerRawFile     = fullfile(rawDir,       baseName + "_stm32-power-raw.csv");
csvPowerSummaryFile = fullfile(processedDir, baseName + "_power-summary.csv");
csvCompressionFile  = fullfile(processedDir, baseName + "_gain-compression.csv");
matFile             = fullfile(processedDir, baseName + "_results.mat");
figPowerFile        = fullfile(figuresDir,   baseName + "_power-vs-txgain.png");
figGainFile         = fullfile(figuresDir,   baseName + "_gain-vs-input.png");
figCompressionFile  = fullfile(figuresDir,   baseName + "_compression-vs-input.png");

fprintf("\nOutput directory:\n%s\n\n", outputDir);

%% ============================================================
% INITIALIZE STM32 SERIAL
% =============================================================

stm = [];
fidPower = -1;

if useSTM32PowerMeter
    fprintf("Opening STM32 serial port...\n");
    stm = serialport(serialPort, serialBaud, "Timeout", serialTimeout_s);
    configureTerminator(stm, serialTerminator);
    flush(stm);
    pause(0.5);

    if doPingTest
        fprintf("Testing communication with PING...\n");
        writeline(stm, "PING");
        pause(0.2);
        while stm.NumBytesAvailable > 0
            fprintf("STM32: %s\n", strtrim(readline(stm)));
        end
        flush(stm);
    end

    fidPower = fopen(csvPowerRawFile, "w");
    if fidPower < 0
        error("Could not create raw power CSV: %s", csvPowerRawFile);
    end

    fprintf(fidPower, [ ...
        "pc_timestamp,pointIndex,txGain_dB,plutoOutBaseline_dBm," + ...
        "bgu2InputAvgEstimated_dBm,bgu2InputPEPEstimated_dBm," + ...
        "ifChainOutputSmallSignalEstimated_dBm,centerFrequency_Hz," + ...
        "dut,measurementPoint,digitalPowerScale,papr_dB," + ...
        "outputProtectionAttenuator_dB,outputMeasurementCorrection_dB," + ...
        "stm32_time_ms,adc_raw,voltage_V,voltage_mV,power_meter_dBm," + ...
        "ifChainOutputCorrected_dBm,ifChainGainMeasured_dB,raw_line\n"]);
end

%% ============================================================
% SDR TX OBJECT
% =============================================================

sdrTransmitter = sdrtx(deviceName);
sdrTransmitter.BasebandSampleRate = sampleRate;
sdrTransmitter.CenterFrequency = centerFrequency;
sdrTransmitter.Gain = idleGain_dB;

%% ============================================================
% PREALLOCATE MEASUREMENT ARRAYS
% =============================================================

Power_mean_meter_dBm = nan(nPoints,1);
Power_std_meter_dB   = nan(nPoints,1);
Power_min_meter_dBm  = nan(nPoints,1);
Power_max_meter_dBm  = nan(nPoints,1);

Voltage_mean_V = nan(nPoints,1);
Voltage_std_V  = nan(nPoints,1);
Voltage_min_V  = nan(nPoints,1);
Voltage_max_V  = nan(nPoints,1);
Voltage_mean_mV = nan(nPoints,1);
Voltage_std_mV  = nan(nPoints,1);
Voltage_min_mV  = nan(nPoints,1);
Voltage_max_mV  = nan(nPoints,1);

ADC_mean_raw = nan(nPoints,1);
ADC_std_raw  = nan(nPoints,1);
ADC_min_raw  = nan(nPoints,1);
ADC_max_raw  = nan(nPoints,1);

N_valid_samples = zeros(nPoints,1);
N_invalid_samples = zeros(nPoints,1);
SafetyStopTriggered = false(nPoints,1);

lastTxGain = NaN;
stopSweep = false;

%% ============================================================
% MAIN TX-ONLY SWEEP
% =============================================================

try
    for iPoint = 1:nPoints
        if stopSweep
            break;
        end

        pointIndex = sweepPlanTable.PointIndex(iPoint);
        txGain     = sweepPlanTable.TxGain_dB(iPoint);

        fprintf("\n====================================\n");
        fprintf("Point %d/%d | Index = %d\n", iPoint, nPoints, pointIndex);
        fprintf("DUT = %s\n", dutName);
        fprintf("TxGain = %.2f dB | Fc = %.3f GHz\n", txGain, centerFrequency/1e9);
        fprintf("Pluto baseline Pout = %.2f dBm\n", sweepPlanTable.PlutoOutBaseline_dBm(iPoint));
        fprintf("BGU2 input avg/PEP estimated = %.2f / %.2f dBm\n", ...
            sweepPlanTable.BGU2InputAvgEstimated_dBm(iPoint), ...
            sweepPlanTable.BGU2InputPEPEstimated_dBm(iPoint));
        fprintf("Expected detector input if linear = %.2f dBm\n", ...
            sweepPlanTable.PowerMeterInputSmallSignalEstimated_dBm(iPoint));
        fprintf("====================================\n");

        if isnan(lastTxGain) || txGain ~= lastTxGain
            fprintf("Updating Pluto TxGain to %.2f dB\n", txGain);
            sdrTransmitter.Gain = txGain;
            transmitRepeat(sdrTransmitter, txWaveform);
            pause(rfSettleAfterTxChange_s);
            lastTxGain = txGain;
        end

        if useSTM32PowerMeter
            flush(stm);
            cmd = sprintf("MEAS,%.2f,%d", txGain, nPowerSamplesPerPoint);
            fprintf("Sending STM32 command: %s\n", cmd);
            writeline(stm, cmd);

            [powerValues_dBm, voltageValues_V, adcValues_raw, nReceived, nInvalid] = readSTM32PowerBlock_IFChain( ...
                stm, ...
                fidPower, ...
                pointIndex, ...
                txGain, ...
                sweepPlanTable.PlutoOutBaseline_dBm(iPoint), ...
                sweepPlanTable.BGU2InputAvgEstimated_dBm(iPoint), ...
                sweepPlanTable.BGU2InputPEPEstimated_dBm(iPoint), ...
                sweepPlanTable.IFChainOutputSmallSignalEstimated_dBm(iPoint), ...
                centerFrequency, ...
                dutName, ...
                measurementPoint, ...
                powerScaleFactor, ...
                PAPR_dB, ...
                outputProtectionAttenuator_dB, ...
                outputMeasurementCorrection_dB);

            N_valid_samples(iPoint) = nReceived;
            N_invalid_samples(iPoint) = nInvalid;

            if ~isempty(powerValues_dBm)
                Power_mean_meter_dBm(iPoint) = safeMean(powerValues_dBm);
                Power_std_meter_dB(iPoint)   = safeStd(powerValues_dBm);
                Power_min_meter_dBm(iPoint)  = safeMin(powerValues_dBm);
                Power_max_meter_dBm(iPoint)  = safeMax(powerValues_dBm);

                Voltage_mean_V(iPoint) = safeMean(voltageValues_V);
                Voltage_std_V(iPoint)  = safeStd(voltageValues_V);
                Voltage_min_V(iPoint)  = safeMin(voltageValues_V);
                Voltage_max_V(iPoint)  = safeMax(voltageValues_V);

                Voltage_mean_mV(iPoint) = 1000*Voltage_mean_V(iPoint);
                Voltage_std_mV(iPoint)  = 1000*Voltage_std_V(iPoint);
                Voltage_min_mV(iPoint)  = 1000*Voltage_min_V(iPoint);
                Voltage_max_mV(iPoint)  = 1000*Voltage_max_V(iPoint);

                ADC_mean_raw(iPoint) = safeMean(adcValues_raw);
                ADC_std_raw(iPoint)  = safeStd(adcValues_raw);
                ADC_min_raw(iPoint)  = safeMin(adcValues_raw);
                ADC_max_raw(iPoint)  = safeMax(adcValues_raw);

                fprintf("  Meter power: mean = %.4f dBm | std = %.4f dB | min = %.4f | max = %.4f\n", ...
                    Power_mean_meter_dBm(iPoint), Power_std_meter_dB(iPoint), ...
                    Power_min_meter_dBm(iPoint), Power_max_meter_dBm(iPoint));
                fprintf("  Sensor voltage: mean = %.4f mV | ADC mean = %.2f\n", ...
                    Voltage_mean_mV(iPoint), ADC_mean_raw(iPoint));
                fprintf("  IF-chain output corrected: mean = %.4f dBm\n", ...
                    Power_mean_meter_dBm(iPoint) + outputMeasurementCorrection_dB);

                if enableSafetyStop && Power_max_meter_dBm(iPoint) >= powerMeterSafetyLimit_dBm
                    SafetyStopTriggered(iPoint) = true;
                    warning("Safety stop: detector input reached %.2f dBm, limit %.2f dBm. Sweep will stop.", ...
                        Power_max_meter_dBm(iPoint), powerMeterSafetyLimit_dBm);
                    stopSweep = true;
                end
            else
                fprintf("  No valid STM32 power samples received.\n");
            end

            fprintf("  STM32 valid samples: %d | invalid samples: %d\n", nReceived, nInvalid);
        end

        if iPoint < nPoints && ~stopSweep
            nextTxGain = sweepPlanTable.TxGain_dB(iPoint + 1);
            if nextTxGain ~= txGain
                sdrTransmitter.Gain = idleGain_dB;
                transmitRepeat(sdrTransmitter, txWaveform);
                pause(rfOffSettle_s);
                lastTxGain = NaN;
            end
        end
    end
catch ME
    warning("Error during main sweep: %s", ME.message);
end

%% ============================================================
% SAFE CLOSE SDR / SERIAL
% =============================================================

fprintf("\nClosing instruments...\n");

try
    sdrTransmitter.Gain = idleGain_dB;
    transmitRepeat(sdrTransmitter, txWaveform);
    pause(0.2);
catch ME
    warning("Could not set Pluto to idle: %s", ME.message);
end

try
    release(sdrTransmitter);
catch
end

if useSTM32PowerMeter
    try
        fclose(fidPower);
    catch
    end
    try
        clear stm;
    catch
    end
end

%% ============================================================
% POWER SUMMARY TABLE
% =============================================================

IFChainOutputCorrected_dBm = Power_mean_meter_dBm + outputMeasurementCorrection_dB;
IFChainOutputMinCorrected_dBm = Power_min_meter_dBm + outputMeasurementCorrection_dB;
IFChainOutputMaxCorrected_dBm = Power_max_meter_dBm + outputMeasurementCorrection_dB;
IFChainGainMeasured_dB = IFChainOutputCorrected_dBm - sweepPlanTable.PlutoOutBaseline_dBm;
IFChainGainExpectedSmallSignal_dB = bgu1SmallSignalGain_typ_dB - interstageAttenuator_dB + bgu2SmallSignalGain_typ_dB;

powerSummaryTable = table( ...
    sweepPlanTable.PointIndex, ...
    sweepPlanTable.TxGain_dB, ...
    sweepPlanTable.PlutoOutBaseline_dBm, ...
    sweepPlanTable.BGU1InputAvgEstimated_dBm, ...
    sweepPlanTable.BGU1InputPEPEstimated_dBm, ...
    sweepPlanTable.BGU2InputAvgEstimated_dBm, ...
    sweepPlanTable.BGU2InputPEPEstimated_dBm, ...
    sweepPlanTable.BGU2AvgAboveP1dBFlag, ...
    sweepPlanTable.BGU2PEPAboveP1dBFlag, ...
    sweepPlanTable.BGU2PEPNearAbsMaxFlag, ...
    sweepPlanTable.IFChainOutputSmallSignalEstimated_dBm, ...
    sweepPlanTable.PowerMeterInputSmallSignalEstimated_dBm, ...
    sweepPlanTable.PlutoBaselineMode, ...
    sweepPlanTable.DUT, ...
    sweepPlanTable.MeasurementPoint, ...
    sweepPlanTable.CenterFrequency_Hz, ...
    sweepPlanTable.DigitalPowerScale, ...
    sweepPlanTable.PAPR_dB, ...
    sweepPlanTable.AssumedPAPRForPlanning_dB, ...
    sweepPlanTable.OutputProtectionAttenuator_dB, ...
    sweepPlanTable.OutputMeasurementCorrection_dB, ...
    Power_mean_meter_dBm, ...
    Power_std_meter_dB, ...
    Power_min_meter_dBm, ...
    Power_max_meter_dBm, ...
    IFChainOutputCorrected_dBm, ...
    IFChainOutputMinCorrected_dBm, ...
    IFChainOutputMaxCorrected_dBm, ...
    IFChainGainMeasured_dB, ...
    repmat(IFChainGainExpectedSmallSignal_dB, nPoints, 1), ...
    Voltage_mean_V, ...
    Voltage_std_V, ...
    Voltage_min_V, ...
    Voltage_max_V, ...
    Voltage_mean_mV, ...
    Voltage_std_mV, ...
    Voltage_min_mV, ...
    Voltage_max_mV, ...
    ADC_mean_raw, ...
    ADC_std_raw, ...
    ADC_min_raw, ...
    ADC_max_raw, ...
    N_valid_samples, ...
    N_invalid_samples, ...
    SafetyStopTriggered, ...
    'VariableNames', { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'PlutoOutBaseline_dBm', ...
        'BGU1InputAvgEstimated_dBm', ...
        'BGU1InputPEPEstimated_dBm', ...
        'BGU2InputAvgEstimated_dBm', ...
        'BGU2InputPEPEstimated_dBm', ...
        'BGU2AvgAboveP1dBFlag', ...
        'BGU2PEPAboveP1dBFlag', ...
        'BGU2PEPNearAbsMaxFlag', ...
        'IFChainOutputSmallSignalEstimated_dBm', ...
        'PowerMeterInputSmallSignalEstimated_dBm', ...
        'PlutoBaselineMode', ...
        'DUT', ...
        'MeasurementPoint', ...
        'CenterFrequency_Hz', ...
        'DigitalPowerScale', ...
        'PAPR_dB', ...
        'AssumedPAPRForPlanning_dB', ...
        'OutputProtectionAttenuator_dB', ...
        'OutputMeasurementCorrection_dB', ...
        'Power_Mean_Meter_dBm', ...
        'Power_Std_Meter_dB', ...
        'Power_Min_Meter_dBm', ...
        'Power_Max_Meter_dBm', ...
        'IFChainOutputCorrected_dBm', ...
        'IFChainOutputMinCorrected_dBm', ...
        'IFChainOutputMaxCorrected_dBm', ...
        'IFChainGainMeasured_dB', ...
        'IFChainGainExpectedSmallSignal_dB', ...
        'Voltage_Mean_V', ...
        'Voltage_Std_V', ...
        'Voltage_Min_V', ...
        'Voltage_Max_V', ...
        'Voltage_Mean_mV', ...
        'Voltage_Std_mV', ...
        'Voltage_Min_mV', ...
        'Voltage_Max_mV', ...
        'ADC_Mean_raw', ...
        'ADC_Std_raw', ...
        'ADC_Min_raw', ...
        'ADC_Max_raw', ...
        'N_valid_samples', ...
        'N_invalid_samples', ...
        'SafetyStopTriggered'} ...
);

fprintf("\n========== TX SWEEP PLAN ==========%s", newline);
disp(sweepPlanTable);

fprintf("\n========== IF CHAIN POWER SUMMARY ==========%s", newline);
disp(powerSummaryTable);

%% ============================================================
% GAIN COMPRESSION ESTIMATION
% =============================================================

compressionTable = powerSummaryTable;
compressionTable.SmallSignalGainReference_dB = nan(height(compressionTable),1);
compressionTable.GainCompression_dB = nan(height(compressionTable),1);
compressionTable.IsP1dB_or_more = false(height(compressionTable),1);
compressionTable.UsefulForMixerDriveCandidate = false(height(compressionTable),1);

nSmallSignalReferencePoints = 5;
minimumValidMeterPower_dBm = -60;

validGainMask = isfinite(compressionTable.IFChainGainMeasured_dB) & ...
                isfinite(compressionTable.Power_Mean_Meter_dBm) & ...
                compressionTable.Power_Mean_Meter_dBm > minimumValidMeterPower_dBm;

nRef = min(nSmallSignalReferencePoints, nnz(validGainMask));
smallSignalGainReference_dB = NaN;

if nRef >= 2
    validIdx = find(validGainMask);
    refIdx = validIdx(1:nRef);
    smallSignalGainReference_dB = mean(compressionTable.IFChainGainMeasured_dB(refIdx), "omitnan");
    compressionTable.SmallSignalGainReference_dB(:) = smallSignalGainReference_dB;
    compressionTable.GainCompression_dB(validGainMask) = ...
        smallSignalGainReference_dB - compressionTable.IFChainGainMeasured_dB(validGainMask);
    compressionTable.IsP1dB_or_more = compressionTable.GainCompression_dB >= 1.0;

    % Candidate region for later mixer drive:
    %   - valid measurement
    %   - IF chain compression below 0.5 dB
    %   - BGU2 average input below P1dB
    compressionTable.UsefulForMixerDriveCandidate = ...
        validGainMask & ...
        compressionTable.GainCompression_dB < 0.5 & ...
        compressionTable.BGU2InputAvgEstimated_dBm < bguInputP1dB_typ_dBm & ...
        ~compressionTable.SafetyStopTriggered;

    fprintf("\n========== IF CHAIN GAIN COMPRESSION ==========%s", newline);
    fprintf("Small-signal gain reference: %.4f dB using first %d valid points.\n", ...
        smallSignalGainReference_dB, nRef);
    disp(compressionTable(:, { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'PlutoOutBaseline_dBm', ...
        'BGU2InputAvgEstimated_dBm', ...
        'BGU2InputPEPEstimated_dBm', ...
        'IFChainOutputCorrected_dBm', ...
        'IFChainGainMeasured_dB', ...
        'SmallSignalGainReference_dB', ...
        'GainCompression_dB', ...
        'UsefulForMixerDriveCandidate'}));

    idxFirstP1dB = find(compressionTable.GainCompression_dB >= 1.0, 1, 'first');
    if ~isempty(idxFirstP1dB)
        fprintf("\nFirst point with IF-chain gain compression >= 1 dB:\n");
        fprintf("  PointIndex              = %d\n", compressionTable.PointIndex(idxFirstP1dB));
        fprintf("  TxGain                  = %.2f dB\n", compressionTable.TxGain_dB(idxFirstP1dB));
        fprintf("  PlutoOutBaseline        = %.4f dBm\n", compressionTable.PlutoOutBaseline_dBm(idxFirstP1dB));
        fprintf("  BGU2InputAvgEstimated   = %.4f dBm\n", compressionTable.BGU2InputAvgEstimated_dBm(idxFirstP1dB));
        fprintf("  IFChainOutputCorrected  = %.4f dBm\n", compressionTable.IFChainOutputCorrected_dBm(idxFirstP1dB));
        fprintf("  IFChainGainMeasured     = %.4f dB\n", compressionTable.IFChainGainMeasured_dB(idxFirstP1dB));
        fprintf("  GainCompression         = %.4f dB\n", compressionTable.GainCompression_dB(idxFirstP1dB));
    else
        fprintf("\nNo >=1 dB IF-chain gain compression found in the measured range.\n");
    end
else
    warning("Not enough valid points to estimate IF-chain gain compression.");
end

%% ============================================================
% PLOTS
% =============================================================

try
    figure;
    plot(compressionTable.TxGain_dB, compressionTable.IFChainOutputCorrected_dBm, "o-", "LineWidth", 1.4);
    hold on;
    plot(compressionTable.TxGain_dB, compressionTable.PlutoOutBaseline_dBm, "s--", "LineWidth", 1.2);
    xlabel("Pluto Tx Gain [dB]");
    ylabel("Power [dBm]");
    title("EXP002 IF-chain power sweep");
    legend("IF-chain output corrected", "Pluto output baseline", "Location", "best");
    grid on;
    hold off;
    saveas(gcf, figPowerFile);
catch ME
    warning("Could not save power plot: %s", ME.message);
end

try
    figure;
    plot(compressionTable.PlutoOutBaseline_dBm, compressionTable.IFChainGainMeasured_dB, "o-", "LineWidth", 1.4);
    hold on;
    if isfinite(smallSignalGainReference_dB)
        yline(smallSignalGainReference_dB, "--", "Small-signal gain ref");
    end
    xlabel("Pluto output baseline [dBm]");
    ylabel("Measured IF-chain gain [dB]");
    title("IF-chain gain vs Pluto output power");
    grid on;
    hold off;
    saveas(gcf, figGainFile);
catch ME
    warning("Could not save gain plot: %s", ME.message);
end

try
    figure;
    plot(compressionTable.BGU2InputAvgEstimated_dBm, compressionTable.GainCompression_dB, "o-", "LineWidth", 1.4);
    hold on;
    yline(1.0, "--", "P1dB compression criterion");
    xline(bguInputP1dB_typ_dBm, "--", "BGU input P1dB typ");
    xlabel("Estimated BGU #2 average input power [dBm]");
    ylabel("Gain compression [dB]");
    title("IF-chain gain compression vs estimated BGU #2 input");
    grid on;
    hold off;
    saveas(gcf, figCompressionFile);
catch ME
    warning("Could not save compression plot: %s", ME.message);
end

%% ============================================================
% SAVE FINAL FILES
% =============================================================

writetable(sweepPlanTable, csvPlanFile);
writetable(powerSummaryTable, csvPowerSummaryFile);
writetable(compressionTable, csvCompressionFile);

save(matFile, ...
    "sweepPlanTable", ...
    "powerSummaryTable", ...
    "compressionTable", ...
    "cfgDLFRC", ...
    "centerFrequency", ...
    "sampleRate", ...
    "powerScaleFactor", ...
    "PAPR_dB", ...
    "PAPR_linear", ...
    "txAveragePower_linear", ...
    "txPeakPower_linear", ...
    "TxGain_dB_plan", ...
    "useManualTxGainList", ...
    "manualTxGainList_dB", ...
    "dutName", ...
    "measurementPoint", ...
    "notes", ...
    "nPowerSamplesPerPoint", ...
    "baselineCsvFile", ...
    "baselineResolvedFile", ...
    "PlutoBaselineMode", ...
    "bgu1SmallSignalGain_typ_dB", ...
    "bgu2SmallSignalGain_typ_dB", ...
    "interstageAttenuator_dB", ...
    "outputProtectionAttenuator_dB", ...
    "outputMeasurementCorrection_dB", ...
    "bguInputP1dB_typ_dBm", ...
    "bguInputAbsMax_dBm", ...
    "enableSafetyStop", ...
    "powerMeterSafetyLimit_dBm", ...
    "smallSignalGainReference_dB");

fprintf("\n============================================\n");
fprintf("EXP002 IF-CHAIN POWER SWEEP FINISHED\n");
fprintf("Sweep plan CSV           : %s\n", csvPlanFile);
if useSTM32PowerMeter
    fprintf("Raw STM32 CSV            : %s\n", csvPowerRawFile);
end
fprintf("Power summary CSV        : %s\n", csvPowerSummaryFile);
fprintf("Gain compression CSV     : %s\n", csvCompressionFile);
fprintf("Power figure             : %s\n", figPowerFile);
fprintf("Gain figure              : %s\n", figGainFile);
fprintf("Compression figure       : %s\n", figCompressionFile);
fprintf("MAT file                 : %s\n", matFile);
fprintf("============================================\n");

warning('on', 'all')

%% ============================================================
% LOCAL FUNCTIONS
% =============================================================

function [Pout_dBm, modeUsed, resolvedFile] = estimatePlutoPowerFromBaseline(txGainPlan_dB, baselineCsvFile, useBaselineCSV, projectDir)
    Pout_dBm = nan(size(txGainPlan_dB));
    modeUsed = "fallback_linear_model";
    resolvedFile = "";

    % Fallback retained only to avoid script failure if the CSV is missing.
    fallbackSlope = 0.9935446912;
    fallbackIntercept = -8.1924257506;

    if useBaselineCSV
        candidateFiles = strings(0,1);
        candidateFiles(end+1,1) = string(baselineCsvFile);
        candidateFiles(end+1,1) = fullfile(pwd, string(baselineCsvFile));
        candidateFiles(end+1,1) = fullfile(projectDir, "baseline", string(baselineCsvFile));
        candidateFiles(end+1,1) = fullfile(projectDir, "Baseline", string(baselineCsvFile));

        for k = 1:numel(candidateFiles)
            if exist(candidateFiles(k), "file")
                resolvedFile = candidateFiles(k);
                break;
            end
        end

        if strlength(resolvedFile) > 0
            try
                T = readtable(resolvedFile);

                if ~ismember('TxGain_dB', T.Properties.VariableNames)
                    error('Baseline CSV must contain TxGain_dB.');
                end

                if ismember('Potencia_SA_dBm', T.Properties.VariableNames)
                    pCol = T.Potencia_SA_dBm;
                elseif ismember('Power_SA_dBm', T.Properties.VariableNames)
                    pCol = T.Power_SA_dBm;
                elseif ismember('PlutoOut_dBm', T.Properties.VariableNames)
                    pCol = T.PlutoOut_dBm;
                else
                    error('Baseline CSV must contain Potencia_SA_dBm, Power_SA_dBm or PlutoOut_dBm.');
                end

                txCal = T.TxGain_dB(:);
                pCal = pCol(:);
                valid = isfinite(txCal) & isfinite(pCal);
                txCal = txCal(valid);
                pCal = pCal(valid);

                [txCal, sortIdx] = sort(txCal);
                pCal = pCal(sortIdx);

                Pout_dBm = interp1(txCal, pCal, txGainPlan_dB, 'linear', 'extrap');
                modeUsed = "csv_interpolation";
                return;
            catch ME
                warning("Could not use baseline CSV. Falling back to linear model. Error: %s", ME.message);
            end
        else
            warning("Baseline CSV was not found. Falling back to linear model: %s", baselineCsvFile);
        end
    end

    Pout_dBm = fallbackSlope .* txGainPlan_dB + fallbackIntercept;
    resolvedFile = "fallback_slope_intercept";
end

function txGainAtTarget = estimateTxGainAtTarget(powerVector_dBm, txGainVector_dB, targetPower_dBm)
    txGainAtTarget = NaN;
    valid = isfinite(powerVector_dBm) & isfinite(txGainVector_dB);
    if nnz(valid) < 2
        return;
    end
    p = powerVector_dBm(valid);
    t = txGainVector_dB(valid);
    [p, idx] = sort(p);
    t = t(idx);
    if targetPower_dBm < min(p) || targetPower_dBm > max(p)
        return;
    end
    txGainAtTarget = interp1(p, t, targetPower_dBm, 'linear');
end

function [powerValues_dBm, voltageValues_V, adcValues_raw, nReceived, nInvalid] = readSTM32PowerBlock_IFChain( ...
    stm, ...
    fidPower, ...
    pointIndex, ...
    txGain, ...
    plutoOutBaseline_dBm, ...
    bgu2InputAvgEstimated_dBm, ...
    bgu2InputPEPEstimated_dBm, ...
    ifChainOutputSmallSignalEstimated_dBm, ...
    centerFrequency, ...
    dutName, ...
    measurementPoint, ...
    powerScaleFactor, ...
    PAPR_dB, ...
    outputProtectionAttenuator_dB, ...
    outputMeasurementCorrection_dB)

    powerValues_dBm = [];
    voltageValues_V = [];
    adcValues_raw   = [];
    nReceived = 0;
    nInvalid  = 0;
    gotEnd    = false;

    while ~gotEnd
        try
            line = strtrim(string(readline(stm)));
        catch ME
            warning("Timeout/error reading STM32 at PointIndex %d: %s", pointIndex, ME.message);
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
                power_dBm     = str2double(parts{5});

                if isnan(stm32_time_ms) || isnan(adc_raw) || isnan(voltage_V) || isnan(power_dBm)
                    nInvalid = nInvalid + 1;
                    fprintf("  DATA line with NaN: %s\n", line);
                    continue;
                end

                voltage_mV = 1000*voltage_V;
                ifChainOutputCorrected_dBm = power_dBm + outputMeasurementCorrection_dB;
                ifChainGainMeasured_dB = ifChainOutputCorrected_dBm - plutoOutBaseline_dBm;

                pc_timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));

                fprintf(fidPower, "%s,%d,%.2f,%.6f,%.6f,%.6f,%.6f,%.0f,%s,%s,%.6f,%.6f,%.6f,%.6f,%.0f,%.0f,%.9f,%.6f,%.6f,%.6f,%.6f,%s\n", ...
                    pc_timestamp, ...
                    pointIndex, ...
                    txGain, ...
                    plutoOutBaseline_dBm, ...
                    bgu2InputAvgEstimated_dBm, ...
                    bgu2InputPEPEstimated_dBm, ...
                    ifChainOutputSmallSignalEstimated_dBm, ...
                    centerFrequency, ...
                    sanitizeCsvField(dutName), ...
                    sanitizeCsvField(measurementPoint), ...
                    powerScaleFactor, ...
                    PAPR_dB, ...
                    outputProtectionAttenuator_dB, ...
                    outputMeasurementCorrection_dB, ...
                    stm32_time_ms, ...
                    adc_raw, ...
                    voltage_V, ...
                    voltage_mV, ...
                    power_dBm, ...
                    ifChainOutputCorrected_dBm, ...
                    ifChainGainMeasured_dB, ...
                    sanitizeCsvField(line));

                powerValues_dBm(end+1,1) = power_dBm; %#ok<AGROW>
                voltageValues_V(end+1,1) = voltage_V; %#ok<AGROW>
                adcValues_raw(end+1,1) = adc_raw; %#ok<AGROW>
                nReceived = nReceived + 1;
            else
                nInvalid = nInvalid + 1;
                fprintf("  Invalid DATA line: %s\n", line);
            end

        elseif startsWith(line, "END")
            fprintf("  %s\n", line);
            gotEnd = true;

        elseif startsWith(line, "ERR")
            warning("STM32 responded with error: %s", line);
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

function y = safeMean(x)
    x = x(isfinite(x));
    if isempty(x); y = NaN; else; y = mean(x); end
end

function y = safeStd(x)
    x = x(isfinite(x));
    if numel(x) < 2; y = NaN; else; y = std(x); end
end

function y = safeMin(x)
    x = x(isfinite(x));
    if isempty(x); y = NaN; else; y = min(x); end
end

function y = safeMax(x)
    x = x(isfinite(x));
    if isempty(x); y = NaN; else; y = max(x); end
end
