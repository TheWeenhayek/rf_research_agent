clear; clc;
warning('off','all')

addpath("C:\Users\jpfer\OneDrive\Documentos\MATLAB\Examples\R2024b\5g\NRWaveformCaptureAndAnalysisWithSDRExample")

%% ============================================================
% EXP009F - OFFICIAL NO-DPD FULL SWEEP DPDV2: EVM + ACPR + POWER + COMPRESSION
% ============================================================
% Configuracion fisica recomendada para DPD:
%
%   Pluto TX -> BGU -> Upconverter IF_IN -> RF_OUT
%            -> filtro 26 GHz (-3 dB)
%            -> atenuador RF loopback 30 dB
%            -> RF_IN Downconverter -> IF_OUT
%            -> Pluto RX
%
% Objetivo principal:
%   Obtener pares IQ alineados x[n] <-> y[n] para entrenar DPD.
%
% Este script NO depende del EVM NR para validar sincronizacion.
% Valida la sincronizacion con:
%   - retardo entero estimado por correlacion robusta
%   - CFO residual estimado por pendiente de fase
%   - ganancia compleja
%   - sync metric normalizado
%   - NMSE alineado
%   - waveform EVM
%   - potencia digital RX y pico RX dBFS
%
% Opcionalmente calcula tambien EVM NR con hNRDownlinkEVM usando:
%   1) rxFrame original recortado por captura
%   2) rxFrame prealineado/corregido
%
% Recomendacion:
%   Usar EXP009 primero como diagnostico de sincronizacion. Si las metricas
%   son estables, esta misma rutina puede integrarse en EXP007 y en Phase 2.

%% ============================================================
% CONFIGURACION 5G NR DOWNLINK FRC
% ============================================================

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
pdschreserved = nrPDSCHReservedConfig;
pdschreserved.PRBSet = [];
pdschreserved.SymbolSet = [];
pdschreserved.Period = [];
pdsch3.ReservedPRB = {pdschreserved};
pdschdmrs = nrPDSCHDMRSConfig;
pdschdmrs.DMRSConfigurationType = 1;
pdschdmrs.DMRSReferencePoint = 'CRB0';
pdschdmrs.DMRSTypeAPosition = 2;
pdschdmrs.DMRSAdditionalPosition = 0;
pdschdmrs.DMRSLength = 1;
pdschdmrs.CustomSymbolSet = [];
pdschdmrs.DMRSPortSet = [];
pdschdmrs.NIDNSCID = [];
pdschdmrs.NSCID = 0;
pdschdmrs.NumCDMGroupsWithoutData = 2;
pdschdmrs.DMRSDownlinkR16 = false;
pdschdmrs.DMRSEnhancedR18 = false;
pdsch3.DMRS = pdschdmrs;
pdschptrs = nrPDSCHPTRSConfig;
pdschptrs.TimeDensity = 1;
pdschptrs.FrequencyDensity = 2;
pdschptrs.REOffset = '00';
pdschptrs.PTRSPortSet = [];
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
% GENERACION DE WAVEFORM + PAPR
% ============================================================

[waveform, info] = nrWaveformGenerator(cfgDLFRC);
Fs = info.ResourceGrids(1).Info.SampleRate;
sampleRate = Fs;
fprintf("Sample rate generado: %.3f Msps\n", sampleRate/1e6);

powerScaleFactor = 0.8;
txWaveform = waveform .* (1 ./ max(abs(waveform)) * powerScaleFactor);
txWaveform = txWaveform(:);

frameDuration_s = 10e-3;
samplesPerFrame = round(sampleRate * frameDuration_s);
fprintf("Muestras por frame de 10 ms: %d\n", samplesPerFrame);

txInstantaneousPower = abs(txWaveform).^2;
txAveragePower_linear = mean(txInstantaneousPower);
txPeakPower_linear = max(txInstantaneousPower);
PAPR_linear = txPeakPower_linear / (txAveragePower_linear + eps);
PAPR_dB = 10*log10(PAPR_linear);
fprintf("PAPR waveform TX: %.3f dB\n", PAPR_dB);

%% ============================================================
% CONFIGURACION OPCIONAL EVM NR
% ============================================================

computeNR_EVM = true;
rc   = "DL-FRC-FR1-256QAM";
bw   = "20MHz";
scs  = "30kHz";
dm   = "FDD";
rnti = 0;

try
    rcwavegen = hNRReferenceWaveformGenerator(rc,bw,scs,dm);
    cfgDL = rcwavegen.Config;
    cfgEVM = struct();
    cfgEVM.PlotEVM = false;
    cfgEVM.DisplayEVM = false;
    cfgEVM.Label = rc;
    cfgEVM.SampleRate = sampleRate;
    cfgEVM.IQImbalance = true;
    cfgEVM.TargetRNTIs = rnti;
    cfgEVM.CorrectCoarseFO = true;
    cfgEVM.CorrectFineFO = true;
    cfgEVM.ExcludeDC = true;
catch ME
    warning("No se pudo inicializar hNRDownlinkEVM. Se desactiva EVM NR: %s", ME.message);
    computeNR_EVM = false;
    cfgDL = [];
    cfgEVM = [];
end

%% ============================================================
% CONFIGURACION EXPERIMENTO
% ============================================================

deviceName       = "Pluto";
centerFrequency = 5e9;
idleGain_dB     = -80;

% Configuracion fisica usada como metadatos.
rfOutFilterInsertionLoss_dB = 3.0;
rfLoopbackAttenuator_dB = 30.0;
ifOutMeterProtectionAttenuator_dB = 0.0;

% Archivos de calibracion/estimacion usados para separar contribuciones.
% IMPORTANTE DPDV2:
% Este codigo debe ejecutarse desde DPDV2/code/. Los baselines se leen desde DPDV2/baseline/.
% La potencia fisica medida por STM32 NO sale de estos archivos; estos solo estiman flujo de potencia
% para separar Pluto, IF board, upconverter y ruta de observacion.
scriptDirForBaseline = fileparts(mfilename("fullpath"));
if strlength(string(scriptDirForBaseline)) == 0
    scriptDirForBaseline = pwd;
end
projectDirForBaseline = fileparts(scriptDirForBaseline);
baselineDir = fullfile(projectDirForBaseline, "baseline");

usePlutoMeasuredCurveCSV = true;
plutoTxCurveCsvFile = fullfile(baselineDir, "Baseline_Power_Tx_Pluto.csv");
plutoTxPowerSlopeFallback_dBperdB = 0.9935446912;
plutoTxPowerInterceptFallback_dBm = -8.1924257506;

useBGUCalibrationCSV = true;
bguCalibrationCsvFile = fullfile(baselineDir, "Baseline_Power_IF_Board.csv");
bguSmallSignalGainFallback_dB = 21.045267;

useUpconverterCalibrationCSV = true;
upconverterTxDsaAtten_dB = 5.0;   % Configuracion manual en ACE: TX DSA interno del upconverter = 5 dB
upconverterCalibrationCsvFile = fullfile(baselineDir, "Baseline_Power_Upconverter_RFOUT_TXDSA5.csv");
upconverterSmallSignalGainFallback_dB = 20.78;

fprintf("\n========== DPDV2 BASELINES ==========\n");
fprintf("Baseline dir       : %s\n", baselineDir);
fprintf("Pluto baseline     : %s\n", plutoTxCurveCsvFile);
fprintf("IF board baseline  : %s\n", bguCalibrationCsvFile);
fprintf("Upconverter TXDSA5 : %s\n", upconverterCalibrationCsvFile);
fprintf("=====================================\n\n");

% Ventana de referencia para compresion de cadena medida. Debe estar en zona lineal y con potencia medible.
compressionReferenceTxGainMin_dB = -31.0;
compressionReferenceTxGainMax_dB = -28.0;
minimumValidMeterPower_dBm = -90;
minimumValidVoltage_V = 0.01;

% RX gain fijo para el barrido EXP009.
% Recomendacion actual: 14 dB para balancear SNR y margen digital.
% Si deseas máxima seguridad contra clipping, prueba 8 dB, pero puede degradar EVM en baja potencia.
RxGain_fixed_dB = 14;

% Barrido principal para verificar EVM, potencia y compresion con la cadena original:
% Pluto TX -> BGU -> Upconverter -> filtro -> 30 dB RF loopback -> Downconverter -> medidor/Pluto RX.
TxGain_start_dB = -38;
TxGain_stop_dB  = -17;
TxGain_step_dB  = 0.25;
TxGainList = (TxGain_start_dB:TxGain_step_dB:TxGain_stop_dB).';
RxGainList = RxGain_fixed_dB * ones(size(TxGainList));

% Captura y reintentos.
numFramesCapture = 8;       % captura larga para buscar correlacion robusta
numFramesForAlign = 1;      % se alinea un frame TX contra la captura RX
captureTime_s = numFramesCapture * frameDuration_s;
maxCaptureAttempts = 3;       % EXP009F: NORMAL_NO_CFO fue el modo mas estable; 3 intentos reduce tiempo total

% Criterios de aceptacion del alineamiento. No son criterios de EVM NR.
acceptSyncMetricMin = 0.95;
acceptNMSEMax_dB = -10.0;       % mas negativo es mejor
acceptPeakRxMax_dBFS = -3.0;    % margen recomendado para DPD / evitar clipping
acceptRxPowerMin_dBFS = -70.0;  % evitar piso de ruido extremo

% Criterios para usar puntos en referencias digitales y futura captura DPD.
% La referencia digital NO debe incluir puntos con mala sincronizacion, clipping o NMSE pobre.
dpdSyncMetricMin = 0.95;
dpdNMSEMax_dB = -10.0;
dpdPeakRxMax_dBFS = -3.0;

% ACPR baseline reference. Main channel is +/- acprMainBandwidth_Hz/2.
% Adjacent channels are integrated over [-1.5BW,-0.5BW] and [0.5BW,1.5BW].
acprMainBandwidth_Hz = 20e6;

% Parametros de sincronizacion.
coarseDecimation = 16;
fineSearchHalfWindow_samples = 96;
phaseFitMagnitudeThreshold = 0.05; % relativo a max(abs(x))

% Guardado de pares alineados. Puede generar archivos grandes.
% Para Phase 1 se deja apagado; para entrenamiento DPD se activara en el siguiente experimento.
saveAlignedPairs = false;
maxAlignedSamplesToSave = samplesPerFrame; % 1 frame de 10 ms por punto

% Medidor STM32 opcional para voltaje/potencia durante EXP009.
useSTM32PowerMeter = true;
serialPort       = "COM12";
serialBaud       = 209700;
serialTerminator = "LF";
serialTimeout_s  = 0.30;
doPingTest = true;
nPowerSamplesPerPoint = 50;

% Tiempos.
rfSettleAfterTxChange_s = 0.50;
rfSettleAfterRxChange_s = 0.10;
rfOffSettle_s = 0.20;

%% ============================================================
% ARCHIVOS DE SALIDA
% ============================================================

EXP_ID     = "EXP009F";
CATEGORY   = "DPD";
DEVICE     = "26GHz-Link";
SHORT_NAME = "NODPD_FULLSWEEP_DPDV2_TXDSA5_NORMAL_NOCFO";
VERSION    = "v1";

runTag = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
experimentFolder = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + VERSION;

scriptDir = fileparts(mfilename("fullpath"));
if strlength(string(scriptDir)) == 0
    scriptDir = pwd;
end
characterizationDir = fileparts(scriptDir);
outputDir = fullfile(characterizationDir, "data", experimentFolder);
rawDir       = fullfile(outputDir, "raw");
processedDir = fullfile(outputDir, "processed");
figuresDir   = fullfile(outputDir, "figures");
alignedDir   = fullfile(outputDir, "aligned_pairs");

if ~exist(rawDir, "dir"); mkdir(rawDir); end
if ~exist(processedDir, "dir"); mkdir(processedDir); end
if ~exist(figuresDir, "dir"); mkdir(figuresDir); end
if saveAlignedPairs && ~exist(alignedDir, "dir"); mkdir(alignedDir); end

baseName = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + runTag + "_" + VERSION;

csvPlanFile        = fullfile(processedDir, baseName + "_sync-plan.csv");
csvAttemptsFile    = fullfile(rawDir,       baseName + "_sync-attempts.csv");
csvMetricsFile     = fullfile(processedDir, baseName + "_alignment-metrics.csv");
csvPowerRawFile    = fullfile(rawDir,       baseName + "_stm32-power-raw.csv");
csvPowerSummaryFile= fullfile(processedDir, baseName + "_stm32-power-summary.csv");
matFile            = fullfile(processedDir, baseName + "_results.mat");
figMetricsFile     = fullfile(figuresDir,   baseName + "_alignment-metrics.png");
figAMAMFile        = fullfile(figuresDir,   baseName + "_amam_best_point.png");
figAMPMFile        = fullfile(figuresDir,   baseName + "_ampm_best_point.png");
figCorrFile        = fullfile(figuresDir,   baseName + "_correlation_best_point.png");
csvPhase1File      = fullfile(processedDir, baseName + "_phase1-evm-power-compression.csv");
csvP1dbFile        = fullfile(processedDir, baseName + "_p1db-summary.csv");
figOverviewFile    = fullfile(figuresDir,   baseName + "_phase1-overview.png");
figCompressionFile = fullfile(figuresDir,   baseName + "_compression-comparison.png");
figPowerEVMFile    = fullfile(figuresDir,   baseName + "_evm-vs-power.png");
figDigitalFile     = fullfile(figuresDir,   baseName + "_digital-compression-rxlevel.png");

fprintf("\nOutput directory:\n%s\n\n", outputDir);

PointIndex = (1:numel(TxGainList)).';
sweepPlanTable = table(PointIndex, TxGainList, RxGainList, ...
    repmat(rfLoopbackAttenuator_dB, numel(TxGainList),1), ...
    repmat(ifOutMeterProtectionAttenuator_dB, numel(TxGainList),1), ...
    repmat(PAPR_dB, numel(TxGainList),1), ...
    'VariableNames', {'PointIndex','TxGain_dB','RxGain_dB','RFLoopbackAttenuator_dB','IFOutMeterProtectionAttenuator_dB','PAPR_dB'});
writetable(sweepPlanTable, csvPlanFile);

%% ============================================================
% INICIALIZAR SERIAL STM32
% ============================================================

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
            fprintf("Probando comunicacion con PING...\n");
            writeline(stm, "PING");
            pause(0.2);
            while stm.NumBytesAvailable > 0
                fprintf("STM32: %s\n", strtrim(readline(stm)));
            end
            flush(stm);
        end

        fidPower = fopen(csvPowerRawFile, "w");
        if fidPower < 0
            error("No se pudo crear CSV de potencia.");
        end
        fprintf(fidPower, "pc_timestamp,pointIndex,txGain_dB,rxGain_dB,stm32_time_ms,adc_raw,voltage_V,power_dB_stm32,raw_line\n");
    catch ME
        warning("No se pudo inicializar STM32. Se continua sin medidor: %s", ME.message);
        useSTM32PowerMeter = false;
    end
end

%% ============================================================
% OBJETOS SDR
% ============================================================

sdrTransmitter = sdrtx(deviceName);
sdrTransmitter.BasebandSampleRate = sampleRate;
sdrTransmitter.CenterFrequency = centerFrequency;
sdrTransmitter.Gain = idleGain_dB;

sdrReceiver = sdrrx(deviceName);
sdrReceiver.BasebandSampleRate = sampleRate;
sdrReceiver.CenterFrequency = centerFrequency;
sdrReceiver.OutputDataType = "double";
sdrReceiver.GainSource = "Manual";

%% ============================================================
% PREALOCACION
% ============================================================

attemptRows = numel(TxGainList) * maxCaptureAttempts;
Attempt_PointIndex = nan(attemptRows,1);
Attempt_TxGain_dB = nan(attemptRows,1);
Attempt_RxGain_dB = nan(attemptRows,1);
Attempt_Number = nan(attemptRows,1);
Attempt_DelaySamples = nan(attemptRows,1);
Attempt_StartSample = nan(attemptRows,1);
Attempt_SyncMetric = nan(attemptRows,1);
Attempt_FreqOffset_Hz = nan(attemptRows,1);
Attempt_ComplexGainAbs = nan(attemptRows,1);
Attempt_ComplexGainPhase_deg = nan(attemptRows,1);
Attempt_NMSE_dB = nan(attemptRows,1);
Attempt_WaveformEVM_pct = nan(attemptRows,1);
Attempt_RxPower_dBFS = nan(attemptRows,1);
Attempt_PeakRx_dBFS = nan(attemptRows,1);
Attempt_ClippingFlag = false(attemptRows,1);
Attempt_IsAccepted = false(attemptRows,1);
Attempt_EVM_NR_Original_pct = nan(attemptRows,1);
Attempt_EVM_NR_Aligned_pct = nan(attemptRows,1);
Attempt_ACPR_dBc = nan(attemptRows,1);
Attempt_ErrorMessage = strings(attemptRows,1);
attemptRow = 0;

% Resumen por punto.
nP = numel(TxGainList);
BestAttempt = nan(nP,1);
DelaySamples = nan(nP,1);
StartSample = nan(nP,1);
SyncMetric = nan(nP,1);
FreqOffset_Hz = nan(nP,1);
ComplexGainAbs = nan(nP,1);
ComplexGainPhase_deg = nan(nP,1);
NMSE_aligned_dB = nan(nP,1);
WaveformEVM_pct = nan(nP,1);
RxPower_dBFS = nan(nP,1);
PeakRx_dBFS = nan(nP,1);
ClippingFlag = false(nP,1);
Accepted = false(nP,1);
EVM_NR_Original_pct = nan(nP,1);
EVM_NR_Aligned_pct = nan(nP,1);
ACPR_dBc = nan(nP,1);
FIR17_NMSE_y_dB = nan(nP,1);
FIR33_NMSE_y_dB = nan(nP,1);
FIR33_Improvement_dB = nan(nP,1);
AlignedPairFile = strings(nP,1);

Power_mean_dB_stm32 = nan(nP,1);
Power_std_dB_stm32 = nan(nP,1);
Voltage_mean_V = nan(nP,1);
Voltage_std_V = nan(nP,1);
ADC_mean_raw = nan(nP,1);
N_power_valid = zeros(nP,1);
N_power_invalid = zeros(nP,1);

lastTxGain = NaN;
bestDiagnostic = struct();
bestDiagnostic.hasData = false;
bestDiagnostic.metricForSelection = Inf;

%% ============================================================
% BARRIDO PRINCIPAL
% ============================================================

try
    for iPoint = 1:nP
        pointIndex = PointIndex(iPoint);
        txGain = TxGainList(iPoint);
        rxGain = RxGainList(iPoint);

        fprintf("\n====================================\n");
        fprintf("EXP009 punto %d/%d | TxGain %.2f dB | RxGain %.2f dB\n", iPoint, nP, txGain, rxGain);
        fprintf("====================================\n");

        if isnan(lastTxGain) || txGain ~= lastTxGain
            sdrTransmitter.Gain = txGain;
            transmitRepeat(sdrTransmitter, txWaveform);
            pause(rfSettleAfterTxChange_s);
            lastTxGain = txGain;
        end

        sdrReceiver.Gain = rxGain;
        pause(rfSettleAfterRxChange_s);

        bestAttemptInfo = [];
        bestAttemptScore = Inf;
        bestAttemptData = [];
        acceptedThisPoint = false;

        for attempt = 1:maxCaptureAttempts
            attemptRow = attemptRow + 1;
            fprintf("  Intento sync %d/%d...\n", attempt, maxCaptureAttempts);

            Attempt_PointIndex(attemptRow) = pointIndex;
            Attempt_TxGain_dB(attemptRow) = txGain;
            Attempt_RxGain_dB(attemptRow) = rxGain;
            Attempt_Number(attemptRow) = attempt;

            try
                rxCapture = capture(sdrReceiver, captureTime_s, "Seconds");
                rxCapture = rxCapture(:);

                [alignInfo, alignedData] = robustAlignTxRxForDPD( ...
                    txWaveform, rxCapture, sampleRate, ...
                    coarseDecimation, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign);

                evmOriginal_pct = NaN;
                evmAligned_pct = NaN;
                if computeNR_EVM
                    evmOriginal_pct = computeNREVM_Safe(rxCapture(1:min(samplesPerFrame,numel(rxCapture))), cfgDL, cfgEVM);
                    evmAligned_pct = computeNREVM_Safe(alignedData.y_cfo_corrected, cfgDL, cfgEVM);
                end

                acprAligned_dBc = computeACPRCentered_EXP009F(alignedData.y_cfo_corrected, sampleRate, acprMainBandwidth_Hz);

                isClip = alignInfo.peakRx_dBFS >= acceptPeakRxMax_dBFS;
                isAccepted = alignInfo.syncMetric >= acceptSyncMetricMin && ...
                             alignInfo.nmse_dB <= acceptNMSEMax_dB && ...
                             alignInfo.peakRx_dBFS < acceptPeakRxMax_dBFS && ...
                             alignInfo.rxPower_dBFS > acceptRxPowerMin_dBFS;

                score = alignAttemptScore(alignInfo, isClip);

                Attempt_DelaySamples(attemptRow) = alignInfo.delaySamples;
                Attempt_StartSample(attemptRow) = alignInfo.startSample;
                Attempt_SyncMetric(attemptRow) = alignInfo.syncMetric;
                Attempt_FreqOffset_Hz(attemptRow) = alignInfo.freqOffset_Hz;
                Attempt_ComplexGainAbs(attemptRow) = abs(alignInfo.complexGain);
                Attempt_ComplexGainPhase_deg(attemptRow) = angle(alignInfo.complexGain)*180/pi;
                Attempt_NMSE_dB(attemptRow) = alignInfo.nmse_dB;
                Attempt_WaveformEVM_pct(attemptRow) = alignInfo.waveformEVM_pct;
                Attempt_RxPower_dBFS(attemptRow) = alignInfo.rxPower_dBFS;
                Attempt_PeakRx_dBFS(attemptRow) = alignInfo.peakRx_dBFS;
                Attempt_ClippingFlag(attemptRow) = isClip;
                Attempt_IsAccepted(attemptRow) = isAccepted;
                Attempt_EVM_NR_Original_pct(attemptRow) = evmOriginal_pct;
                Attempt_EVM_NR_Aligned_pct(attemptRow) = evmAligned_pct;
                Attempt_ACPR_dBc(attemptRow) = acprAligned_dBc;

                fprintf("    delay=%d | sync=%.3f | CFO=%.2f Hz | NMSE=%.2f dB | wfEVM=%.2f %% | Rx=%.1f dBFS | peak=%.1f dBFS | NR-EVM aligned=%.3f %% | ACPR=%.2f dBc\n", ...
                    alignInfo.delaySamples, alignInfo.syncMetric, alignInfo.freqOffset_Hz, ...
                    alignInfo.nmse_dB, alignInfo.waveformEVM_pct, ...
                    alignInfo.rxPower_dBFS, alignInfo.peakRx_dBFS, evmAligned_pct, acprAligned_dBc);

                if score < bestAttemptScore
                    bestAttemptScore = score;
                    bestAttemptInfo = alignInfo;
                    bestAttemptData = alignedData;
                    bestAttemptInfo.evmOriginal_pct = evmOriginal_pct;
                    bestAttemptInfo.evmAligned_pct = evmAligned_pct;
                    bestAttemptInfo.acprAligned_dBc = acprAligned_dBc;
                    bestAttemptInfo.attempt = attempt;
                    bestAttemptInfo.isAccepted = isAccepted;
                end

                if isAccepted
                    fprintf("    Intento aceptado.\n");
                    acceptedThisPoint = true;
                    break;
                end

            catch ME
                Attempt_ErrorMessage(attemptRow) = string(ME.message);
                fprintf("    Fallo intento %d: %s\n", attempt, ME.message);
            end
        end

        if ~isempty(bestAttemptInfo)
            BestAttempt(iPoint) = bestAttemptInfo.attempt;
            DelaySamples(iPoint) = bestAttemptInfo.delaySamples;
            StartSample(iPoint) = bestAttemptInfo.startSample;
            SyncMetric(iPoint) = bestAttemptInfo.syncMetric;
            FreqOffset_Hz(iPoint) = bestAttemptInfo.freqOffset_Hz;
            ComplexGainAbs(iPoint) = abs(bestAttemptInfo.complexGain);
            ComplexGainPhase_deg(iPoint) = angle(bestAttemptInfo.complexGain)*180/pi;
            NMSE_aligned_dB(iPoint) = bestAttemptInfo.nmse_dB;
            WaveformEVM_pct(iPoint) = bestAttemptInfo.waveformEVM_pct;
            RxPower_dBFS(iPoint) = bestAttemptInfo.rxPower_dBFS;
            PeakRx_dBFS(iPoint) = bestAttemptInfo.peakRx_dBFS;
            ClippingFlag(iPoint) = bestAttemptInfo.peakRx_dBFS >= acceptPeakRxMax_dBFS;
            Accepted(iPoint) = acceptedThisPoint || bestAttemptInfo.isAccepted;
            EVM_NR_Original_pct(iPoint) = bestAttemptInfo.evmOriginal_pct;
            EVM_NR_Aligned_pct(iPoint) = bestAttemptInfo.evmAligned_pct;
            ACPR_dBc(iPoint) = bestAttemptInfo.acprAligned_dBc;

            % Diagnostico de memoria lineal: mejora de NMSE al ajustar FIR x->y.
            % No se usa para corregir EVM; solo queda como metrica para justificar modelos DPD con memoria.
            try
                xFir = bestAttemptData.x_aligned;
                yFir = bestAttemptData.y_aligned_raw;
                [FIR17_NMSE_y_dB(iPoint), ~, ~] = fitComplexFIRMemoryDiagnostic_EXP009F(xFir, yFir, 17);
                [FIR33_NMSE_y_dB(iPoint), ~, ~] = fitComplexFIRMemoryDiagnostic_EXP009F(xFir, yFir, 33);
                FIR33_Improvement_dB(iPoint) = NMSE_aligned_dB(iPoint) - FIR33_NMSE_y_dB(iPoint);
            catch ME_FIR
                fprintf("  ADVERTENCIA FIR diagnostic punto %d: %s\n", pointIndex, ME_FIR.message);
            end

            if saveAlignedPairs
                % FIX EXP009B:
                % Saving aligned IQ pairs can fail on Windows if the path is too long.
                % In EXP009 this stopped the complete sweep after the first point.
                % Now saving is optional, uses a short filename, and any save error
                % is reported but does NOT stop the sweep.
                try
                    Ns = min(maxAlignedSamplesToSave, numel(bestAttemptData.x_aligned));
                    x_aligned = bestAttemptData.x_aligned(1:Ns); %#ok<NASGU>
                    y_aligned_raw = bestAttemptData.y_aligned_raw(1:Ns); %#ok<NASGU>
                    y_cfo_corrected = bestAttemptData.y_cfo_corrected(1:Ns); %#ok<NASGU>
                    y_normalized = bestAttemptData.y_normalized(1:Ns); %#ok<NASGU>
                    alignInfo = bestAttemptInfo; %#ok<NASGU>
                    pairFile = fullfile(alignedDir, sprintf("p%03d_Tx%+.2f_Rx%+.2f.mat", pointIndex, txGain, rxGain));
                    save(pairFile, "x_aligned", "y_aligned_raw", "y_cfo_corrected", "y_normalized", "alignInfo", "sampleRate", "txGain", "rxGain", "-v7.3");
                    AlignedPairFile(iPoint) = string(pairFile);
                catch ME_SAVE
                    fprintf("  ADVERTENCIA: no se pudo guardar par IQ alineado en punto %d: %s\n", pointIndex, ME_SAVE.message);
                    AlignedPairFile(iPoint) = "";
                end
            end

            if bestAttemptScore < bestDiagnostic.metricForSelection && isfinite(bestAttemptScore)
                bestDiagnostic.hasData = true;
                bestDiagnostic.metricForSelection = bestAttemptScore;
                bestDiagnostic.pointIndex = pointIndex;
                bestDiagnostic.txGain = txGain;
                bestDiagnostic.rxGain = rxGain;
                bestDiagnostic.alignInfo = bestAttemptInfo;
                bestDiagnostic.alignedData = bestAttemptData;
            end
        end

        if useSTM32PowerMeter
            flush(stm);
            cmd = sprintf("MEAS,%.2f,%d", txGain, nPowerSamplesPerPoint);
            fprintf("  STM32: %s\n", cmd);
            writeline(stm, cmd);
            [pVals, vVals, adcVals, nRec, nInv] = readSTM32PowerBlock_EXP009(stm, fidPower, pointIndex, txGain, rxGain);
            N_power_valid(iPoint) = nRec;
            N_power_invalid(iPoint) = nInv;
            if ~isempty(pVals)
                Power_mean_dB_stm32(iPoint) = mean(pVals, "omitnan");
                Power_std_dB_stm32(iPoint) = std(pVals, "omitnan");
            end
            if ~isempty(vVals)
                Voltage_mean_V(iPoint) = mean(vVals, "omitnan");
                Voltage_std_V(iPoint) = std(vVals, "omitnan");
            end
            if ~isempty(adcVals)
                ADC_mean_raw(iPoint) = mean(adcVals, "omitnan");
            end
        end

        if iPoint < nP
            nextTxGain = TxGainList(iPoint+1);
            if nextTxGain ~= txGain
                sdrTransmitter.Gain = idleGain_dB;
                transmitRepeat(sdrTransmitter, txWaveform);
                pause(rfOffSettle_s);
                lastTxGain = NaN;
            end
        end
    end
catch ME
    % FIX EXP009B: print the real error even if MATLAB warnings are disabled.
    fprintf(2, "\nERROR durante EXP009B: %s\n", ME.message);
    for kk = 1:numel(ME.stack)
        fprintf(2, "  at %s line %d\n", ME.stack(kk).name, ME.stack(kk).line);
    end
end

%% ============================================================
% CIERRE SEGURO
% ============================================================

fprintf("\nCerrando equipos...\n");
try
    sdrTransmitter.Gain = idleGain_dB;
    transmitRepeat(sdrTransmitter, txWaveform);
    pause(0.2);
catch
end
try
    release(sdrTransmitter);
catch
end
try
    release(sdrReceiver);
catch
end
if useSTM32PowerMeter
    try; fclose(fidPower); catch; end
    try; clear stm; catch; end
end

%% ============================================================
% TABLAS
% ============================================================

attemptsTable = table( ...
    Attempt_PointIndex(1:attemptRow), Attempt_TxGain_dB(1:attemptRow), Attempt_RxGain_dB(1:attemptRow), Attempt_Number(1:attemptRow), ...
    Attempt_DelaySamples(1:attemptRow), Attempt_StartSample(1:attemptRow), Attempt_SyncMetric(1:attemptRow), Attempt_FreqOffset_Hz(1:attemptRow), ...
    Attempt_ComplexGainAbs(1:attemptRow), Attempt_ComplexGainPhase_deg(1:attemptRow), Attempt_NMSE_dB(1:attemptRow), Attempt_WaveformEVM_pct(1:attemptRow), ...
    Attempt_RxPower_dBFS(1:attemptRow), Attempt_PeakRx_dBFS(1:attemptRow), Attempt_ClippingFlag(1:attemptRow), Attempt_IsAccepted(1:attemptRow), ...
    Attempt_EVM_NR_Original_pct(1:attemptRow), Attempt_EVM_NR_Aligned_pct(1:attemptRow), Attempt_ACPR_dBc(1:attemptRow), Attempt_ErrorMessage(1:attemptRow), ...
    'VariableNames', {'PointIndex','TxGain_dB','RxGain_dB','Attempt','DelaySamples','StartSample','SyncMetric','FreqOffset_Hz', ...
    'ComplexGainAbs','ComplexGainPhase_deg','NMSE_aligned_dB','WaveformEVM_pct','RxPower_dBFS','PeakRx_dBFS','ClippingFlag','IsAccepted', ...
    'EVM_NR_Original_pct','EVM_NR_Aligned_pct','ACPR_dBc','ErrorMessage'});

metricsTable = table( ...
    PointIndex, TxGainList, RxGainList, BestAttempt, Accepted, DelaySamples, StartSample, SyncMetric, FreqOffset_Hz, ...
    ComplexGainAbs, ComplexGainPhase_deg, NMSE_aligned_dB, WaveformEVM_pct, RxPower_dBFS, PeakRx_dBFS, ClippingFlag, ...
    EVM_NR_Original_pct, EVM_NR_Aligned_pct, ACPR_dBc, FIR17_NMSE_y_dB, FIR33_NMSE_y_dB, FIR33_Improvement_dB, ...
    Power_mean_dB_stm32, Power_std_dB_stm32, Voltage_mean_V, Voltage_std_V, ADC_mean_raw, N_power_valid, N_power_invalid, ...
    AlignedPairFile, ...
    repmat(rfLoopbackAttenuator_dB,nP,1), repmat(ifOutMeterProtectionAttenuator_dB,nP,1), repmat(PAPR_dB,nP,1), ...
    'VariableNames', {'PointIndex','TxGain_dB','RxGain_dB','BestAttempt','Accepted','DelaySamples','StartSample','SyncMetric','FreqOffset_Hz', ...
    'ComplexGainAbs','ComplexGainPhase_deg','NMSE_aligned_dB','WaveformEVM_pct','RxPower_dBFS','PeakRx_dBFS','ClippingFlag', ...
    'EVM_NR_Original_pct','EVM_NR_Aligned_pct','ACPR_dBc','FIR17_NMSE_y_dB','FIR33_NMSE_y_dB','FIR33_Improvement_dB','Power_mean_dB_stm32','Power_std_dB_stm32','Voltage_mean_V','Voltage_std_V','ADC_mean_raw', ...
    'N_power_valid','N_power_invalid','AlignedPairFile','RFLoopbackAttenuator_dB','IFOutMeterProtectionAttenuator_dB','PAPR_dB'});

%% ============================================================
% EXP009 - METRICAS DE POTENCIA, EVM Y COMPRESION
% ============================================================

[phase1Table, p1dbSummaryTable] = buildEXP009Phase1Metrics( ...
    metricsTable, ...
    TxGainList, ...
    PAPR_dB, ...
    rfOutFilterInsertionLoss_dB, ...
    rfLoopbackAttenuator_dB, ...
    ifOutMeterProtectionAttenuator_dB, ...
    usePlutoMeasuredCurveCSV, ...
    plutoTxCurveCsvFile, ...
    plutoTxPowerSlopeFallback_dBperdB, ...
    plutoTxPowerInterceptFallback_dBm, ...
    useBGUCalibrationCSV, ...
    bguCalibrationCsvFile, ...
    bguSmallSignalGainFallback_dB, ...
    useUpconverterCalibrationCSV, ...
    upconverterCalibrationCsvFile, ...
    upconverterSmallSignalGainFallback_dB, ...
    compressionReferenceTxGainMin_dB, ...
    compressionReferenceTxGainMax_dB, ...
    minimumValidMeterPower_dBm, ...
    minimumValidVoltage_V, ...
    dpdSyncMetricMin, ...
    dpdNMSEMax_dB, ...
    dpdPeakRxMax_dBFS);

writetable(attemptsTable, csvAttemptsFile);
writetable(metricsTable, csvMetricsFile);
writetable(phase1Table, csvPhase1File);
writetable(p1dbSummaryTable, csvP1dbFile);

% Official comparison/reference table for later DPD experiments.
referenceTable = phase1Table(:, {'PointIndex','TxGain_dB','RxGain_dB','Accepted','IsUsefulForDPD', ...
    'EVM_NR_Original_pct','EVM_NR_Aligned_pct','ACPR_dBc','NMSE_aligned_dB','WaveformEVM_pct','FIR17_NMSE_y_dB','FIR33_NMSE_y_dB','FIR33_Improvement_dB','SyncMetric', ...
    'RxPower_dBFS','PeakRx_dBFS','ClippingFlag','PAPR_dB', ...
    'Power_mean_dB_stm32','Power_std_dB_stm32','Voltage_mean_V','Voltage_std_V','ADC_mean_raw','IFOutCorrected_dBm', ...
    'PlutoOutEstimated_dBm','BGUOutputEstimated_dBm','BGUGainEstimated_dB','BGUCompressionEstimated_dB', ...
    'UpconverterInputEstimated_dBm','UpconverterInputPeakEnvelopeEstimated_dBm', ...
    'RFOutPinEstimated_dBm','RFOutAfterFilterEstimated_dBm','UpconverterGainEstimated_dB','UpconverterCompressionEstimated_dB', ...
    'DownconverterRFInputEstimated_dBm','DownconverterRFInputPeakEnvelopeEstimated_dBm', ...
    'DownconverterGainMeasured_dB','DownconverterGainCompression_dB', ...
    'ObservedChainGain_FromUpIn_toIFOut_dB','ObservedChainCompression_dB', ...
    'DigitalGain_dB','DigitalGainIdealFit_dB','DigitalCompression_dB', ...
    'DigitalRxPowerIdealFit_dBFS','DigitalRxPowerCompression_dB'});
csvReferenceFile = fullfile(processedDir, baseName + "_OFFICIAL_NODPD_REFERENCE.csv");
writetable(referenceTable, csvReferenceFile);

if useSTM32PowerMeter
    powerSummaryTable = metricsTable(:, {'PointIndex','TxGain_dB','RxGain_dB','Power_mean_dB_stm32','Power_std_dB_stm32','Voltage_mean_V','Voltage_std_V','ADC_mean_raw','N_power_valid','N_power_invalid'});
    writetable(powerSummaryTable, csvPowerSummaryFile);
else
    powerSummaryTable = table();
end

fprintf("\n========== EXP009 METRICAS DE SINCRONIZACION ==========%s", newline);
disp(metricsTable(:, {'PointIndex','TxGain_dB','RxGain_dB','Accepted','SyncMetric','FreqOffset_Hz','NMSE_aligned_dB','WaveformEVM_pct','RxPower_dBFS','PeakRx_dBFS','EVM_NR_Aligned_pct','ACPR_dBc','FIR33_NMSE_y_dB','Voltage_mean_V'}));

fprintf("\n========== EXP009 RESUMEN P1dB / COMPRESION ==========%s", newline);
disp(p1dbSummaryTable);

fprintf("\n========== EXP009 TABLA PRINCIPAL EVM + POTENCIA + COMPRESION ==========%s", newline);
disp(phase1Table(:, {'PointIndex','TxGain_dB','RxGain_dB','EVM_NR_Aligned_pct','ACPR_dBc','Power_mean_dB_stm32','IFOutCorrected_dBm','ObservedChainCompression_dB','DigitalCompression_dB','UpconverterCompressionEstimated_dB','DownconverterGainCompression_dB','PeakRx_dBFS','ClippingFlag','IsUsefulForDPD'}));

%% ============================================================
% GRAFICAS
% ============================================================
try
    figure;
    tiledlayout(3,1);
    nexttile;
    plot(metricsTable.TxGain_dB, metricsTable.SyncMetric, "o-", "LineWidth", 1.3); grid on;
    yline(acceptSyncMetricMin, "--", "sync min");
    xlabel("TxGain [dB]"); ylabel("Sync metric"); title("EXP009 synchronization metric");
    nexttile;
    plot(metricsTable.TxGain_dB, metricsTable.NMSE_aligned_dB, "o-", "LineWidth", 1.3); grid on;
    yline(acceptNMSEMax_dB, "--", "NMSE max");
    xlabel("TxGain [dB]"); ylabel("NMSE [dB]"); title("Aligned NMSE");
    nexttile;
    plot(metricsTable.TxGain_dB, metricsTable.WaveformEVM_pct, "o-", "LineWidth", 1.3); grid on;
    xlabel("TxGain [dB]"); ylabel("Waveform EVM [%]"); title("Waveform EVM from aligned IQ");
    saveas(gcf, figMetricsFile);
catch ME
    warning("No se pudo generar grafica de metricas: %s", ME.message);
end

try
    if bestDiagnostic.hasData
        x = bestDiagnostic.alignedData.x_aligned;
        y = bestDiagnostic.alignedData.y_normalized;
        Nplot = min(50000, numel(x));
        idxPlot = round(linspace(1,numel(x),Nplot));

        figure;
        plot(abs(x(idxPlot)), abs(y(idxPlot)), '.', 'MarkerSize', 4);
        grid on;
        xlabel('|x[n]|'); ylabel('|y_{norm}[n]|');
        title(sprintf('AM/AM best sync point | Tx %.2f dB | NMSE %.2f dB', bestDiagnostic.txGain, bestDiagnostic.alignInfo.nmse_dB));
        saveas(gcf, figAMAMFile);

        figure;
        phaseErr_deg = angle(y(idxPlot).*conj(x(idxPlot))) * 180/pi;
        plot(abs(x(idxPlot)), phaseErr_deg, '.', 'MarkerSize', 4);
        grid on;
        xlabel('|x[n]|'); ylabel('phase(y/x) [deg]');
        title(sprintf('AM/PM best sync point | Tx %.2f dB', bestDiagnostic.txGain));
        saveas(gcf, figAMPMFile);

        figure;
        plot(bestDiagnostic.alignInfo.corrDelayAxis_samples, bestDiagnostic.alignInfo.corrMagNormalized, 'LineWidth', 1.2);
        grid on;
        xlabel('Delay candidate [samples]'); ylabel('Normalized correlation');
        title(sprintf('Fine correlation peak | Tx %.2f dB | delay %d samples', bestDiagnostic.txGain, bestDiagnostic.alignInfo.delaySamples));
        saveas(gcf, figCorrFile);
    end
catch ME
    warning("No se pudieron generar graficas diagnosticas AM/AM-AM/PM: %s", ME.message);
end

%% ============================================================
% EXP009 - GRAFICAS DE DESEMPENO
% ============================================================
try
    figure;
    tiledlayout(4,1);
    nexttile;
    plot(phase1Table.TxGain_dB, phase1Table.EVM_NR_Aligned_pct, "o-", "LineWidth", 1.3); grid on;
    ylabel("EVM NR aligned [%]"); title("EXP009 EVM, compression and RX level overview");
    nexttile;
    plot(phase1Table.TxGain_dB, phase1Table.ObservedChainCompression_dB, "o-", "LineWidth", 1.3); hold on;
    plot(phase1Table.TxGain_dB, phase1Table.UpconverterCompressionEstimated_dB, "s-", "LineWidth", 1.2);
    plot(phase1Table.TxGain_dB, phase1Table.DownconverterGainCompression_dB, "d-", "LineWidth", 1.2);
    yline(1.0,"--","1 dB"); grid on; ylabel("Compression [dB]");
    legend("Observed chain", "Upconverter est", "Downconverter meas", "Location", "best");
    nexttile;
    plot(phase1Table.TxGain_dB, phase1Table.PeakRx_dBFS, "o-", "LineWidth", 1.3); hold on;
    yline(-3,"--","-3 dBFS target"); yline(0,":","0 dBFS"); grid on;
    ylabel("Peak RX [dBFS]");
    nexttile;
    plot(phase1Table.TxGain_dB, phase1Table.IFOutCorrected_dBm, "o-", "LineWidth", 1.3); grid on;
    xlabel("Pluto TxGain [dB]"); ylabel("IF_OUT corrected [dBm]");
    saveas(gcf, figOverviewFile);
catch ME
    warning("No se pudo generar overview EXP009: %s", ME.message);
end

try
    figure;
    plot(phase1Table.TxGain_dB, phase1Table.ObservedChainCompression_dB, "o-", "LineWidth", 1.4); hold on;
    plot(phase1Table.TxGain_dB, phase1Table.DigitalCompression_dB, "s-", "LineWidth", 1.4);
    plot(phase1Table.TxGain_dB, phase1Table.UpconverterCompressionEstimated_dB, "d-", "LineWidth", 1.4);
    yline(1.0,"--","1 dB compression"); grid on;
    xlabel("Pluto TxGain [dB]"); ylabel("Compression [dB]");
    title("EXP009 compression comparison");
    legend("Observed physical chain", "Digital IQ gain", "Upconverter estimated", "Location", "best");
    saveas(gcf, figCompressionFile);
catch ME
    warning("No se pudo generar grafica de compresion EXP009: %s", ME.message);
end

try
    figure;
    scatter(phase1Table.IFOutCorrected_dBm, phase1Table.EVM_NR_Aligned_pct, 70, phase1Table.TxGain_dB, "filled");
    grid on; colorbar;
    xlabel("IF_OUT corrected power [dBm]"); ylabel("EVM NR aligned [%]");
    title("EXP009 EVM vs measured IF_OUT power");
    saveas(gcf, figPowerEVMFile);
catch ME
    warning("No se pudo generar EVM vs potencia EXP009: %s", ME.message);
end

try
    figure;
    tiledlayout(2,1);
    nexttile;
    plot(phase1Table.TxGain_dB, phase1Table.DigitalGain_dB, "o-", "LineWidth", 1.3); grid on;
    ylabel("Digital gain 20log10(|a|) [dB]"); title("EXP009 digital gain/compression and RX level");
    nexttile;
    plot(phase1Table.TxGain_dB, phase1Table.DigitalCompression_dB, "o-", "LineWidth", 1.3); hold on;
    yline(1.0,"--","1 dB"); grid on;
    xlabel("Pluto TxGain [dB]"); ylabel("Digital compression [dB]");
    saveas(gcf, figDigitalFile);
catch ME
    warning("No se pudo generar digital compression EXP009: %s", ME.message);
end

save(matFile, "sweepPlanTable", "attemptsTable", "metricsTable", "powerSummaryTable", "phase1Table", "p1dbSummaryTable", ...
    "cfgDLFRC", "cfgDL", "cfgEVM", "txWaveform", "sampleRate", "samplesPerFrame", "PAPR_dB", ...
    "rfLoopbackAttenuator_dB", "ifOutMeterProtectionAttenuator_dB", "coarseDecimation", ...
    "fineSearchHalfWindow_samples", "phaseFitMagnitudeThreshold", "acceptSyncMetricMin", "acceptNMSEMax_dB", ...
    "acceptPeakRxMax_dBFS", "acceptRxPowerMin_dBFS");

fprintf("\n============================================\n");
fprintf("EXP009F OFFICIAL NO-DPD FULL SWEEP DPDV2 FINALIZADO\n");
fprintf("Plan                  : %s\n", csvPlanFile);
fprintf("Intentos sync          : %s\n", csvAttemptsFile);
fprintf("Metricas alineamiento  : %s\n", csvMetricsFile);
fprintf("Phase1 EVM/power/comp   : %s\n", csvPhase1File);
fprintf("Official no-DPD reference: %s\n", csvReferenceFile);
fprintf("P1dB summary            : %s\n", csvP1dbFile);
if useSTM32PowerMeter
    fprintf("Potencia STM32 raw     : %s\n", csvPowerRawFile);
    fprintf("Potencia STM32 resumen : %s\n", csvPowerSummaryFile);
end
fprintf("MAT                   : %s\n", matFile);
fprintf("Fig metricas           : %s\n", figMetricsFile);
fprintf("============================================\n");

warning('on','all')

%% ============================================================
% FUNCIONES LOCALES
% ============================================================



function acpr_dBc = computeACPRCentered_EXP009F(x, fs, bw)
    acpr_dBc = NaN;
    try
        x = x(:);
        if isempty(x) || length(x) < 1024
            return;
        end
        Ntarget = 614400;
        N = min(Ntarget, length(x));
        x = x(1:N);
        x = x - mean(x, 'omitnan');
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
        warning("Error en computeACPRCentered_EXP009F: %s", ME.message);
        acpr_dBc = NaN;
    end
end

function [phase1Table, p1dbSummaryTable] = buildEXP009Phase1Metrics( ...
    metricsTable, txGainList, PAPR_dB, rfOutFilterInsertionLoss_dB, rfLoopbackAttenuator_dB, ifOutMeterProtectionAttenuator_dB, ...
    usePlutoMeasuredCurveCSV, plutoTxCurveCsvFile, plutoSlopeFallback, plutoInterceptFallback, ...
    useBGUCalibrationCSV, bguCalibrationCsvFile, bguSmallSignalGainFallback_dB, ...
    useUpconverterCalibrationCSV, upconverterCalibrationCsvFile, upconverterSmallSignalGainFallback_dB, ...
    refTxMin, refTxMax, minimumValidMeterPower_dBm, minimumValidVoltage_V, ...
    dpdSyncMetricMin, dpdNMSEMax_dB, dpdPeakRxMax_dBFS)

    nP = height(metricsTable);
    txGain = metricsTable.TxGain_dB;

    [PlutoOutEstimated_dBm, PlutoCalibrationMode] = estimatePlutoOutput_EXP009(txGain, usePlutoMeasuredCurveCSV, plutoTxCurveCsvFile, plutoSlopeFallback, plutoInterceptFallback);

    [BGUOutputEstimated_dBm, BGUGainEstimated_dB, BGUCompressionEstimated_dB, BGUCalibrationMode] = estimateBGUOutput_EXP009( ...
        txGain, bguCalibrationCsvFile, useBGUCalibrationCSV, PlutoOutEstimated_dBm, bguSmallSignalGainFallback_dB);

    UpconverterInputEstimated_dBm = BGUOutputEstimated_dBm;
    UpconverterInputPeakEnvelopeEstimated_dBm = UpconverterInputEstimated_dBm + PAPR_dB;

    [RFOutPinEstimated_dBm, RFOutAfterFilterEstimated_dBm, UpconverterGainEstimated_dB, UpconverterCompressionEstimated_dB, UpconverterCalibrationMode] = estimateUpconverterRFOut_EXP009( ...
        txGain, upconverterCalibrationCsvFile, useUpconverterCalibrationCSV, UpconverterInputEstimated_dBm, upconverterSmallSignalGainFallback_dB, rfOutFilterInsertionLoss_dB);

    DownconverterRFInputEstimated_dBm = RFOutAfterFilterEstimated_dBm - rfLoopbackAttenuator_dB;
    DownconverterRFInputPeakEnvelopeEstimated_dBm = DownconverterRFInputEstimated_dBm + PAPR_dB;

    IFOutCorrected_dBm = metricsTable.Power_mean_dB_stm32 + ifOutMeterProtectionAttenuator_dB;
    IFOutPeakEnvelopeCorrected_dBm = IFOutCorrected_dBm + PAPR_dB;

    ObservedChainGain_FromUpIn_toIFOut_dB = IFOutCorrected_dBm - UpconverterInputEstimated_dBm;
    DownconverterGainMeasured_dB = IFOutCorrected_dBm - DownconverterRFInputEstimated_dBm;
    DigitalGain_dB = 20*log10(metricsTable.ComplexGainAbs + eps);

    validPhysicalMask = isfinite(ObservedChainGain_FromUpIn_toIFOut_dB) & isfinite(IFOutCorrected_dBm) & ...
        isfinite(metricsTable.Power_mean_dB_stm32) & metricsTable.Power_mean_dB_stm32 > minimumValidMeterPower_dBm & ...
        isfinite(metricsTable.Voltage_mean_V) & metricsTable.Voltage_mean_V >= minimumValidVoltage_V & ...
        txGain >= refTxMin & txGain <= refTxMax;

    validDownMask = isfinite(DownconverterGainMeasured_dB) & validPhysicalMask;

    % Referencia digital y seleccion DPD: excluir puntos con mala sincronizacion o clipping.
    validDigitalQualityMask = isfinite(DigitalGain_dB) & metricsTable.Accepted & ...
        isfinite(metricsTable.SyncMetric) & metricsTable.SyncMetric >= dpdSyncMetricMin & ...
        isfinite(metricsTable.NMSE_aligned_dB) & metricsTable.NMSE_aligned_dB <= dpdNMSEMax_dB & ...
        isfinite(metricsTable.PeakRx_dBFS) & metricsTable.PeakRx_dBFS <= dpdPeakRxMax_dBFS & ...
        ~metricsTable.ClippingFlag;

    validDigitalMask = validDigitalQualityMask & txGain >= refTxMin & txGain <= refTxMax;

    if nnz(validDigitalMask) < 2
        warning("Referencia digital con pocos puntos validos. Se usara fallback: Accepted & no clipping en ventana de referencia.");
        validDigitalMask = isfinite(DigitalGain_dB) & metricsTable.Accepted & ~metricsTable.ClippingFlag & ...
            txGain >= refTxMin & txGain <= refTxMax;
    end

    SmallSignalObservedChainGainReference_dB = mean(ObservedChainGain_FromUpIn_toIFOut_dB(validPhysicalMask), 'omitnan');
    SmallSignalDownconverterGainReference_dB = mean(DownconverterGainMeasured_dB(validDownMask), 'omitnan');

    ObservedChainCompression_dB = SmallSignalObservedChainGainReference_dB - ObservedChainGain_FromUpIn_toIFOut_dB;
    DownconverterGainCompression_dB = SmallSignalDownconverterGainReference_dB - DownconverterGainMeasured_dB;

    % ============================================================
    % EXP009D - COMPRESION DIGITAL POR AJUSTE LINEAL
    % ============================================================
    % La version anterior calculaba:
    %   DigitalCompression = referencia_constante - DigitalGain
    % Eso es incorrecto para un barrido de TxGain, porque DigitalGain debe subir
    % aproximadamente 1 dB por cada 1 dB de TxGain en la zona lineal.
    % Ahora se ajusta una recta en zona lineal y de buena sincronizacion:
    %   DigitalGain_ideal(TxGain) = a*TxGain + b
    %   DigitalCompression = DigitalGain_ideal - DigitalGain_medido
    % Tambien se calcula la misma metrica usando RxPower_dBFS.

    [DigitalGainFitSlope_dBperdB, DigitalGainFitIntercept_dB, DigitalGainIdeal_dB, DigitalCompression_dB, nDigitalFitPoints] = ...
        fitDigitalCompressionVsTxGain_EXP009D(txGain, DigitalGain_dB, validDigitalMask);

    validDigitalRxPowerMask = validDigitalQualityMask & isfinite(metricsTable.RxPower_dBFS) & ...
        txGain >= refTxMin & txGain <= refTxMax;
    if nnz(validDigitalRxPowerMask) < 2
        validDigitalRxPowerMask = metricsTable.Accepted & ~metricsTable.ClippingFlag & ...
            isfinite(metricsTable.RxPower_dBFS) & txGain >= refTxMin & txGain <= refTxMax;
    end

    [DigitalRxPowerFitSlope_dBperdB, DigitalRxPowerFitIntercept_dBFS, DigitalRxPowerIdeal_dBFS, DigitalRxPowerCompression_dB, nDigitalRxPowerFitPoints] = ...
        fitDigitalCompressionVsTxGain_EXP009D(txGain, metricsTable.RxPower_dBFS, validDigitalRxPowerMask);

    % Referencia promedio se conserva solo como diagnostico heredado, no para compresion.
    SmallSignalDigitalGainReference_dB = mean(DigitalGain_dB(validDigitalMask), 'omitnan');

    phase1Table = metricsTable;
    phase1Table.PlutoOutEstimated_dBm = PlutoOutEstimated_dBm;
    phase1Table.BGUOutputEstimated_dBm = BGUOutputEstimated_dBm;
    phase1Table.BGUGainEstimated_dB = BGUGainEstimated_dB;
    phase1Table.BGUCompressionEstimated_dB = BGUCompressionEstimated_dB;
    phase1Table.UpconverterInputEstimated_dBm = UpconverterInputEstimated_dBm;
    phase1Table.UpconverterInputPeakEnvelopeEstimated_dBm = UpconverterInputPeakEnvelopeEstimated_dBm;
    phase1Table.RFOutPinEstimated_dBm = RFOutPinEstimated_dBm;
    phase1Table.RFOutAfterFilterEstimated_dBm = RFOutAfterFilterEstimated_dBm;
    phase1Table.UpconverterGainEstimated_dB = UpconverterGainEstimated_dB;
    phase1Table.UpconverterCompressionEstimated_dB = UpconverterCompressionEstimated_dB;
    phase1Table.DownconverterRFInputEstimated_dBm = DownconverterRFInputEstimated_dBm;
    phase1Table.DownconverterRFInputPeakEnvelopeEstimated_dBm = DownconverterRFInputPeakEnvelopeEstimated_dBm;
    phase1Table.IFOutCorrected_dBm = IFOutCorrected_dBm;
    phase1Table.IFOutPeakEnvelopeCorrected_dBm = IFOutPeakEnvelopeCorrected_dBm;
    phase1Table.ObservedChainGain_FromUpIn_toIFOut_dB = ObservedChainGain_FromUpIn_toIFOut_dB;
    phase1Table.SmallSignalObservedChainGainReference_dB = repmat(SmallSignalObservedChainGainReference_dB,nP,1);
    phase1Table.ObservedChainCompression_dB = ObservedChainCompression_dB;
    phase1Table.DownconverterGainMeasured_dB = DownconverterGainMeasured_dB;
    phase1Table.SmallSignalDownconverterGainReference_dB = repmat(SmallSignalDownconverterGainReference_dB,nP,1);
    phase1Table.DownconverterGainCompression_dB = DownconverterGainCompression_dB;
    phase1Table.DigitalGain_dB = DigitalGain_dB;
    phase1Table.SmallSignalDigitalGainReference_dB = repmat(SmallSignalDigitalGainReference_dB,nP,1);
    phase1Table.DigitalGainIdealFit_dB = DigitalGainIdeal_dB;
    phase1Table.DigitalGainFitSlope_dBperdB = repmat(DigitalGainFitSlope_dBperdB,nP,1);
    phase1Table.DigitalGainFitIntercept_dB = repmat(DigitalGainFitIntercept_dB,nP,1);
    phase1Table.NDigitalGainFitPoints = repmat(nDigitalFitPoints,nP,1);
    phase1Table.DigitalCompression_dB = DigitalCompression_dB;
    phase1Table.DigitalRxPowerIdealFit_dBFS = DigitalRxPowerIdeal_dBFS;
    phase1Table.DigitalRxPowerFitSlope_dBperdB = repmat(DigitalRxPowerFitSlope_dBperdB,nP,1);
    phase1Table.DigitalRxPowerFitIntercept_dBFS = repmat(DigitalRxPowerFitIntercept_dBFS,nP,1);
    phase1Table.NDigitalRxPowerFitPoints = repmat(nDigitalRxPowerFitPoints,nP,1);
    phase1Table.DigitalRxPowerCompression_dB = DigitalRxPowerCompression_dB;
    phase1Table.PlutoCalibrationMode = repmat(string(PlutoCalibrationMode),nP,1);
    phase1Table.BGUCalibrationMode = repmat(string(BGUCalibrationMode),nP,1);
    phase1Table.UpconverterCalibrationMode = repmat(string(UpconverterCalibrationMode),nP,1);
    phase1Table.CompressionReferenceTxGainMin_dB = repmat(refTxMin,nP,1);
    phase1Table.CompressionReferenceTxGainMax_dB = repmat(refTxMax,nP,1);
    phase1Table.IsPhysicalReferencePoint = validPhysicalMask;
    phase1Table.IsDigitalReferencePoint = validDigitalMask;
    phase1Table.IsDigitalRxPowerReferencePoint = validDigitalRxPowerMask;
    % Puntos candidatos para entrenamiento: buena sync, sin clipping y EVM NR calculable.
    % Se excluyen automaticamente las fallas puntuales de sincronizacion.
    phase1Table.IsUsefulForDPD = validDigitalQualityMask & isfinite(metricsTable.EVM_NR_Aligned_pct);
    phase1Table.DPDSyncMetricMin = repmat(dpdSyncMetricMin,nP,1);
    phase1Table.DPDNMSEMax_dB = repmat(dpdNMSEMax_dB,nP,1);
    phase1Table.DPDPeakRxMax_dBFS = repmat(dpdPeakRxMax_dBFS,nP,1);

    [txP1Obs, pwrP1Obs, evmP1Obs] = interpolateP1dB_EXP009(txGain, ObservedChainCompression_dB, IFOutCorrected_dBm, metricsTable.EVM_NR_Aligned_pct);
    [txP1Dig, pwrP1Dig, evmP1Dig] = interpolateP1dB_EXP009(txGain, DigitalCompression_dB, IFOutCorrected_dBm, metricsTable.EVM_NR_Aligned_pct);
    [txP1Up, pwrP1Up, evmP1Up] = interpolateP1dB_EXP009(txGain, UpconverterCompressionEstimated_dB, IFOutCorrected_dBm, metricsTable.EVM_NR_Aligned_pct);
    [txP1Down, pwrP1Down, evmP1Down] = interpolateP1dB_EXP009(txGain, DownconverterGainCompression_dB, IFOutCorrected_dBm, metricsTable.EVM_NR_Aligned_pct);

    Method = ["ObservedChainCompression"; "DigitalCompression"; "UpconverterEstimatedCompression"; "DownconverterMeasuredCompression"];
    TxGain_P1dB = [txP1Obs; txP1Dig; txP1Up; txP1Down];
    IFOutCorrected_P1dB_dBm = [pwrP1Obs; pwrP1Dig; pwrP1Up; pwrP1Down];
    EVM_NR_Aligned_at_P1dB_pct = [evmP1Obs; evmP1Dig; evmP1Up; evmP1Down];
    ReferenceTxMin_dB = repmat(refTxMin,4,1);
    ReferenceTxMax_dB = repmat(refTxMax,4,1);
    p1dbSummaryTable = table(Method, TxGain_P1dB, IFOutCorrected_P1dB_dBm, EVM_NR_Aligned_at_P1dB_pct, ReferenceTxMin_dB, ReferenceTxMax_dB);
end

function [txP1, pwrP1, evmP1] = interpolateP1dB_EXP009(txGain, compression, power, evm)
    txP1 = NaN; pwrP1 = NaN; evmP1 = NaN;
    valid = isfinite(txGain) & isfinite(compression);
    tx = txGain(valid); c = compression(valid); p = power(valid); e = evm(valid);
    [tx, ord] = sort(tx); c = c(ord); p = p(ord); e = e(ord);
    idx = find(c(1:end-1) < 1 & c(2:end) >= 1, 1, 'first');
    if isempty(idx); return; end
    c1 = c(idx); c2 = c(idx+1); tx1 = tx(idx); tx2 = tx(idx+1);
    alpha = (1 - c1) / (c2 - c1 + eps);
    txP1 = tx1 + alpha*(tx2 - tx1);
    if numel(p) >= idx+1 && isfinite(p(idx)) && isfinite(p(idx+1))
        pwrP1 = p(idx) + alpha*(p(idx+1)-p(idx));
    end
    if numel(e) >= idx+1 && isfinite(e(idx)) && isfinite(e(idx+1))
        evmP1 = e(idx) + alpha*(e(idx+1)-e(idx));
    end
end

function [Pout, modeUsed] = estimatePlutoOutput_EXP009(txGain, useCsv, curveFile, slopeFallback, interceptFallback)
    Pout = slopeFallback .* txGain + interceptFallback;
    modeUsed = "fallback_linear_pluto_curve";
    if useCsv
        fileFound = findCalibrationFile_EXP009(curveFile);
        if strlength(fileFound) > 0
            try
                T = readtable(fileFound);
                names = T.Properties.VariableNames;
                txCol = find(contains(lower(names),'tx') & contains(lower(names),'gain'),1);
                pCol = find((contains(lower(names),'dbm') | contains(lower(names),'power')) & ~contains(lower(names),'gain'),1);
                if isempty(txCol); txCol = 1; end
                if isempty(pCol); pCol = min(2,width(T)); end
                txCal = T{:,txCol}; pCal = T{:,pCol};
                valid = isfinite(txCal) & isfinite(pCal);
                txCal = txCal(valid); pCal = pCal(valid);
                [txCal, ord] = sort(txCal); pCal = pCal(ord);
                Pout = interp1(txCal, pCal, txGain, 'linear', 'extrap');
                modeUsed = "csv_interpolation:" + string(fileFound);
            catch ME
                warning("No se pudo usar curva medida Pluto. Fallback lineal. Error: %s", ME.message);
            end
        end
    end
end

function [BGUOut, BGUGain, BGUComp, modeUsed] = estimateBGUOutput_EXP009(txGain, bguFile, useCsv, plutoOut, fallbackGain)
    BGUOut = plutoOut + fallbackGain;
    BGUGain = repmat(fallbackGain,size(txGain));
    BGUComp = zeros(size(txGain));
    modeUsed = "fallback_fixed_IFBoard_gain";
    if useCsv
        fileFound = findCalibrationFile_EXP009(bguFile);
        if strlength(fileFound) > 0
            try
                T = readtable(fileFound);
                txCal = T.TxGain_dB(:);
                names = T.Properties.VariableNames;

                if ismember('IFChainOutputCorrected_dBm', names)
                    outCal = T.IFChainOutputCorrected_dBm(:);
                elseif ismember('IFBoardOutputBaseline_dBm', names)
                    outCal = T.IFBoardOutputBaseline_dBm(:);
                elseif ismember('DUTOutputCorrected_dBm', names)
                    outCal = T.DUTOutputCorrected_dBm(:);
                elseif ismember('MeasuredOutputCorrected_dBm', names)
                    outCal = T.MeasuredOutputCorrected_dBm(:);
                else
                    error('No se encontro columna de salida IF board/BGU.');
                end

                if ismember('IFChainGainMeasured_dB', names)
                    gainCal = T.IFChainGainMeasured_dB(:);
                elseif ismember('IFBoardGainEstimated_dB', names)
                    gainCal = T.IFBoardGainEstimated_dB(:);
                elseif ismember('DUTGain_dB', names)
                    gainCal = T.DUTGain_dB(:);
                else
                    gainCal = outCal - interp1(txGain, plutoOut, txCal, 'linear','extrap');
                end

                if ismember('GainCompression_dB', names)
                    compCal = T.GainCompression_dB(:);
                elseif ismember('IFBoardCompressionEstimated_dB', names)
                    compCal = T.IFBoardCompressionEstimated_dB(:);
                else
                    compCal = zeros(size(outCal));
                end

                valid = isfinite(txCal) & isfinite(outCal);
                txCal = txCal(valid); outCal = outCal(valid); gainCal = gainCal(valid); compCal = compCal(valid);
                [txCal,ord] = sort(txCal); outCal=outCal(ord); gainCal=gainCal(ord); compCal=compCal(ord);
                BGUOut = interp1(txCal,outCal,txGain,'linear','extrap');
                BGUGain = interp1(txCal,gainCal,txGain,'linear','extrap');
                BGUComp = interp1(txCal,compCal,txGain,'linear','extrap');
                modeUsed = "csv_interpolation:" + string(fileFound);
            catch ME
                warning("No se pudo usar CSV IF board/BGU. Fallback. Error: %s", ME.message);
            end
        end
    end
end

function [RFOutPin, RFOutAfterFilter, UpGain, UpComp, modeUsed] = estimateUpconverterRFOut_EXP009(txGain, upFile, useCsv, upInput, fallbackGain, filtLoss)
    UpGain = repmat(fallbackGain,size(txGain));
    RFOutPin = upInput + fallbackGain;
    RFOutAfterFilter = RFOutPin - filtLoss;
    UpComp = zeros(size(txGain));
    modeUsed = "fallback_fixed_upconverter_gain";
    if useCsv
        fileFound = findCalibrationFile_EXP009(upFile);
        if strlength(fileFound) > 0
            try
                T = readtable(fileFound);
                names = T.Properties.VariableNames;
                txCal = T.TxGain_dB(:);

                if ismember('RFOutPinCorrected_dBm', names)
                    pinCal = T.RFOutPinCorrected_dBm(:);
                else
                    error('No RFOutPinCorrected_dBm column.');
                end
                if ismember('RFOutAfterFilterCorrected_dBm', names)
                    aftCal = T.RFOutAfterFilterCorrected_dBm(:);
                else
                    aftCal = pinCal - filtLoss;
                end
                if ismember('UpconverterGain_RFOutPin_dB', names)
                    gainCal = T.UpconverterGain_RFOutPin_dB(:);
                elseif ismember('UpconverterGain_dB', names)
                    gainCal = T.UpconverterGain_dB(:);
                else
                    gainCal = nan(size(pinCal));
                end
                if ismember('UpconverterGainCompression_dB', names)
                    compCal = T.UpconverterGainCompression_dB(:);
                else
                    compCal = zeros(size(pinCal));
                end

                valid = isfinite(txCal) & isfinite(pinCal) & isfinite(aftCal);
                txCal = txCal(valid); pinCal=pinCal(valid); aftCal=aftCal(valid); gainCal=gainCal(valid); compCal=compCal(valid);
                [txCal,ord] = sort(txCal); pinCal=pinCal(ord); aftCal=aftCal(ord); gainCal=gainCal(ord); compCal=compCal(ord);
                RFOutPin = interp1(txCal,pinCal,txGain,'linear','extrap');
                RFOutAfterFilter = interp1(txCal,aftCal,txGain,'linear','extrap');
                if any(isfinite(gainCal)); UpGain = interp1(txCal,gainCal,txGain,'linear','extrap'); else; UpGain = RFOutPin - upInput; end
                UpComp = interp1(txCal,compCal,txGain,'linear','extrap');
                modeUsed = "csv_interpolation:" + string(fileFound);
            catch ME
                warning("No se pudo usar CSV upconverter. Fallback. Error: %s", ME.message);
            end
        end
    end
end

function fileFound = findCalibrationFile_EXP009(fileName)
    candidateFiles = strings(0,1);
    candidateFiles(end+1,1) = string(fileName);
    candidateFiles(end+1,1) = fullfile(pwd,string(fileName));
    scriptDir = fileparts(mfilename('fullpath'));
    if strlength(string(scriptDir)) > 0
        projectDir = fileparts(scriptDir);
        candidateFiles(end+1,1) = fullfile(scriptDir,string(fileName));
        candidateFiles(end+1,1) = fullfile(projectDir,'baseline',string(fileName));
        candidateFiles(end+1,1) = fullfile(projectDir,'data',string(fileName));
    end
    fileFound = "";
    for k = 1:numel(candidateFiles)
        if exist(candidateFiles(k),'file')
            fileFound = candidateFiles(k);
            return;
        end
    end
end

function [alignInfo, alignedData] = robustAlignTxRxForDPD(xTx, yRx, Fs, D, fineHalfWin, magThrRel, numFramesForAlign)
    %#ok<INUSD>
    % EXP009F NORMAL_NO_CFO:
    % EXP008 mostro que el modo estable es NORMAL_NO_CFO.
    % No se aplica conjugacion ni correccion CFO externa.
    xTx = xTx(:);
    yRx = yRx(:);

    Ntx = numel(xTx);
    Nuse = min(Ntx*numFramesForAlign, Ntx);
    x = xTx(1:Nuse);

    if numel(yRx) < Nuse + 10
        error('Captura RX demasiado corta para alineamiento.');
    end

    x0 = x - mean(x, 'omitnan');
    y0 = yRx - mean(yRx, 'omitnan');
    x0 = x0 ./ (rms(abs(x0)) + eps);
    y0 = y0 ./ (rms(abs(y0)) + eps);

    xD = x0(1:D:end);
    yD = y0(1:D:end);
    if numel(yD) < numel(xD)
        error('Captura decimada menor que referencia decimada.');
    end
    cCoarse = conv(yD, flipud(conj(xD)), 'valid');
    [~, idxCoarse] = max(abs(cCoarse));
    startCoarse = (idxCoarse - 1) * D + 1;

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
    [syncMetricCoarseFine, iBest] = max(corrVals);
    startSample = starts(iBest);
    delaySamples = startSample - 1;

    yAlignedRaw = yRx(startSample:startSample+Nuse-1);
    xAligned = x;

    complexGain = (xAligned' * yAlignedRaw) / (xAligned' * xAligned + eps);
    yCFO = yAlignedRaw;
    yNorm = yAlignedRaw ./ (complexGain + eps);
    freqOffset_Hz = 0;
    phaseSlope_radPerSample = 0;

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
    alignInfo.freqOffset_Hz = freqOffset_Hz;
    alignInfo.phaseSlope_radPerSample = phaseSlope_radPerSample;
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

function [powerValues_dB, voltageValues_V, adcValues_raw, nReceived, nInvalid] = readSTM32PowerBlock_EXP009(stm, fidPower, pointIndex, txGain, rxGain)
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

                pc_timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));
                fprintf(fidPower, "%s,%d,%.2f,%.2f,%.0f,%.0f,%.9f,%.6f,%s\n", ...
                    pc_timestamp, pointIndex, txGain, rxGain, stm32_time_ms, adc_raw, voltage_V, power_dB, sanitizeCsvField(line));
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

function safe = sanitizeCsvField(txt)
    safe = string(txt);
    safe = replace(safe, '"', '""');
    safe = '"' + safe + '"';
end


function [nmseYdB, nmseXdB, condX] = fitComplexFIRMemoryDiagnostic_EXP009F(x, y, L)
% Ajuste FIR complejo centrado: y[n] ~= sum_k h[k] x[n-k].
% Sirve como diagnostico de memoria lineal de la ruta observada.
    x = x(:);
    y = y(:);
    L = round(L);
    if L < 1 || mod(L,2) == 0
        error('FIR length must be odd and positive.');
    end
    N = min(numel(x), numel(y));
    maxSamples = 200000;
    if N > maxSamples
        x = x(1:maxSamples);
        y = y(1:maxSamples);
        N = maxSamples;
    end
    discardInitialSamples = 100;
    if N > discardInitialSamples + 10*L
        x = x(discardInitialSamples+1:end);
        y = y(discardInitialSamples+1:end);
        N = min(numel(x), numel(y));
    end
    x = x - mean(x,'omitnan');
    y = y - mean(y,'omitnan');
    if N < 10*L
        error('Not enough samples for FIR length %d.', L);
    end
    half = floor(L/2);
    nValid = (1+half):(N-half);
    M = numel(nValid);
    X = complex(zeros(M,L));
    for k = 1:L
        lag = k - (half+1);
        X(:,k) = x(nValid - lag);
    end
    yv = y(nValid);
    xv = x(nValid);
    h = X \ yv;
    yHat = X*h;
    errY = yv - yHat;
    nmseYdB = 10*log10(sum(abs(errY).^2)/(sum(abs(yv).^2)+eps) + eps);
    gBack = (yHat' * xv) / (yHat' * yHat + eps);
    xHat = gBack * yHat;
    errX = xHat - xv;
    nmseXdB = 10*log10(sum(abs(errX).^2)/(sum(abs(xv).^2)+eps) + eps);
    s = svd(X, 'econ');
    condX = max(s)/(min(s)+eps);
end

function [slope, intercept, yIdeal, compression, nFit] = fitDigitalCompressionVsTxGain_EXP009D(txGain_dB, yMeasured_dB, fitMask)
%FITDIGITALCOMPRESSIONVSTXGAIN_EXP009D
% Ajusta una recta y = a*TxGain + b en una zona lineal valida.
% La compresion digital se define como perdida respecto a esa recta:
%   compression = yIdeal - yMeasured
% Si no existen suficientes puntos, devuelve NaN para evitar interpretaciones falsas.

    txGain_dB = txGain_dB(:);
    yMeasured_dB = yMeasured_dB(:);
    fitMask = fitMask(:) & isfinite(txGain_dB) & isfinite(yMeasured_dB);
    nFit = nnz(fitMask);

    slope = NaN;
    intercept = NaN;
    yIdeal = NaN(size(yMeasured_dB));
    compression = NaN(size(yMeasured_dB));

    if nFit < 2
        warning("EXP009D: no hay suficientes puntos validos para ajuste digital lineal.");
        return;
    end

    p = polyfit(txGain_dB(fitMask), yMeasured_dB(fitMask), 1);
    slope = p(1);
    intercept = p(2);
    yIdeal = polyval(p, txGain_dB);
    compression = yIdeal - yMeasured_dB;
end
