clear; clc;
warning('off','all')

addpath("C:\Users\jpfer\OneDrive\Documentos\MATLAB\Examples\R2024b\5g\NRWaveformCaptureAndAnalysisWithSDRExample")

%% ============================================================
% EXP009D - FULL CHAIN EVM + POWER COMPRESSION SWEEP WITH ROBUST IQ SYNC
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
% EXP008 - DPDV2 SYNC ROOT-CAUSE DIAGNOSTIC
% ============================================================
% Objetivo:
%   Identificar por qué el EVM NR puede ser razonable pero el alineamiento
%   IQ x[n] <-> y[n] para DPD falla o queda inestable.
%
% Este experimento:
%   1) Usa la estructura actual DPDV2/code y DPDV2/baseline.
%   2) Usa baseline del upconverter con TX DSA = 5 dB.
%   3) Barre pocos puntos cerca de la zona de compresión.
%   4) Para cada captura prueba múltiples variantes:
%        NORMAL / RX_CONJ
%        NO_CFO / CFO_NEG / CFO_POS
%   5) Guarda TODAS las variantes en CSV, no solo la mejor.
%   6) Guarda también EVM NR original y EVM NR después de cada alineamiento.
%
% Interpretación rápida:
%   - Si RX_CONJ gana consistentemente: problema de inversión/conjugación IQ.
%   - Si NO_CFO gana: la corrección CFO externa está dañando el alineamiento.
%   - Si NORMAL+CFO_NEG gana pero falla a veces: problema de picos, falso pico
%     de correlación, memoria o retardo fraccional.
%   - Si EVM NR original es bueno pero NMSE IQ malo en todos los modos:
%     la demodulación NR funciona, pero el par sample-to-sample no es
%     suficientemente fiel para DPD con esta rutina.
%
% Hardware actual esperado:
%   Pluto TX -> IF board -> Upconverter TX DSA = 5 dB -> RF_OUT
%   -> cable 2 dB -> B259MC1S 3 dB -> cable 2 dB
%   -> atenuador físico 30 dB -> downconverter -> Pluto RX / medidor
% ============================================================

%% =========================
% CONFIGURACION DPDV2 ACTUAL
% ==========================
deviceName       = "Pluto";
centerFrequency  = 5e9;
idleGain_dB      = -80;

% IMPORTANTE: mantener igual al experimento DPD actual.
upconverterTxDsaAtten_dB = 5.0;     % metadata; configurar manualmente en ACE
rxInternalDsaAtten_dB    = 0.0;     % metadata si aplica
rfLoopbackAttenuator_dB  = 30.0;
ifOutMeterProtectionAttenuator_dB = 0.0;

% Perdidas asumidas alrededor del filtro.
cableLoss_RFOut_to_FilterInput_dB = 2.0;
rfOutFilterInsertionLoss_dB       = 3.0;
cableLoss_FilterOutput_to_RFAttInput_dB = 2.0;
totalRFOutPinToRFInLoss_dB = cableLoss_RFOut_to_FilterInput_dB + ...
    rfOutFilterInsertionLoss_dB + cableLoss_FilterOutput_to_RFAttInput_dB + ...
    rfLoopbackAttenuator_dB;

% RX y barrido corto recomendado para diagnostico.
RxGain_fixed_dB = 8;                  % ya observado en tu corrida -22:-18.5
TxGain_start_dB = -22.0;
TxGain_stop_dB  = -18.5;
TxGain_step_dB  = 0.5;                % usa 0.25 si quieres mas resolucion

TxGainList = (TxGain_start_dB:TxGain_step_dB:TxGain_stop_dB).';
RxGainList = RxGain_fixed_dB * ones(size(TxGainList));

% Captura larga para que la correlacion pueda buscar bien el frame.
numFramesCapture = 8;
numFramesForAlign = 1;
captureTime_s = numFramesCapture * frameDuration_s;
maxCaptureAttempts = 3;

% Modos de diagnostico. Se prueban TODOS por cada intento.
rxModeList  = ["NORMAL","RX_CONJ"];
cfoModeList = ["NO_CFO","CFO_NEG","CFO_POS"];

% Parametros de correlacion.
coarseDecimation = 16;
fineSearchHalfWindow_samples = 192;   % mas amplio que EXP009, para evitar falsos maximos locales
phaseFitMagnitudeThreshold = 0.05;

% Criterios de calidad para DPD. No eliminan datos; solo marcan flags.
dpdSyncMetricMin = 0.90;
dpdNMSEMax_dB = -10.0;
dpdPeakRxMax_dBFS = -3.0;

% Medidor STM32/LTC5596.
useSTM32PowerMeter = true;
serialPort       = "COM12";
serialBaud       = 209700;
serialTerminator = "LF";
serialTimeout_s  = 0.30;
doPingTest = true;
nPowerSamplesPerPoint = 50;

% Guardar raw captures para inspeccion manual. Recomendado en EXP008.
saveRawCaptures = true;
saveBestAlignedPair = true;
maxAlignedSamplesToSave = samplesPerFrame;

% Tiempos.
rfSettleAfterTxChange_s = 0.50;
rfSettleAfterRxChange_s = 0.10;
rfOffSettle_s = 0.20;

%% =========================
% BASELINES DPDV2
% ==========================
scriptDir = fileparts(mfilename("fullpath"));
if strlength(string(scriptDir)) == 0
    scriptDir = pwd;
end
projectDir = fileparts(scriptDir);
baselineDir = fullfile(projectDir, "baseline");

plutoTxCurveCsvFile = fullfile(baselineDir, "Baseline_Power_Tx_Pluto.csv");
bguCalibrationCsvFile = fullfile(baselineDir, "Baseline_Power_IF_Board.csv");
upconverterCalibrationCsvFile = fullfile(baselineDir, "Baseline_Power_Upconverter_RFOUT_TXDSA5.csv");

fprintf("\nDPDV2 baseline directory:\n%s\n", baselineDir);
fprintf("Pluto baseline       : %s\n", plutoTxCurveCsvFile);
fprintf("IF board baseline    : %s\n", bguCalibrationCsvFile);
fprintf("Upconverter baseline : %s\n\n", upconverterCalibrationCsvFile);

%% =========================
% ARCHIVOS DE SALIDA
% ==========================
EXP_ID = "EXP008";
CATEGORY = "DPD";
DEVICE = "26GHz-Link";
SHORT_NAME = "SYNC_ROOTCAUSE_TXDSA5_MULTIMODE";
VERSION = "v1";
runTag = string(datetime("now","Format","yyyyMMdd_HHmmss"));

outputDir = fullfile(projectDir, "data", EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + VERSION, runTag);
rawDir = fullfile(outputDir, "raw");
processedDir = fullfile(outputDir, "processed");
figuresDir = fullfile(outputDir, "figures");
alignedDir = fullfile(outputDir, "aligned_pairs");
if ~exist(rawDir,"dir"); mkdir(rawDir); end
if ~exist(processedDir,"dir"); mkdir(processedDir); end
if ~exist(figuresDir,"dir"); mkdir(figuresDir); end
if (saveBestAlignedPair || saveRawCaptures) && ~exist(alignedDir,"dir"); mkdir(alignedDir); end

baseName = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + runTag + "_" + VERSION;

csvPlanFile = fullfile(processedDir, baseName + "_plan.csv");
csvAllModesFile = fullfile(processedDir, baseName + "_all-sync-modes.csv");
csvBestFile = fullfile(processedDir, baseName + "_best-per-point.csv");
csvPowerRawFile = fullfile(rawDir, baseName + "_stm32-power-raw.csv");
matFile = fullfile(processedDir, baseName + "_results.mat");
figModeFile = fullfile(figuresDir, baseName + "_mode-comparison.png");

PointIndex = (1:numel(TxGainList)).';

% Metadatos de potencia desde baselines.
[PlutoOutEstimated_dBm, PlutoMode] = estimatePlutoOutput_DPDV2(TxGainList, plutoTxCurveCsvFile);
[IFBoardOutputEstimated_dBm, IFBoardGainEstimated_dB, IFBoardCompressionEstimated_dB, IFMode] = ...
    estimateIFBoardOutput_DPDV2(TxGainList, bguCalibrationCsvFile, PlutoOutEstimated_dBm);
[RFOutPinEstimated_dBm, RFOutAfterFilterEstimated_dBm, UpconverterGainEstimated_dB, UpconverterCompressionEstimated_dB, UpMode] = ...
    estimateUpconverterOutput_DPDV2(TxGainList, upconverterCalibrationCsvFile, IFBoardOutputEstimated_dBm, rfOutFilterInsertionLoss_dB);

DownconverterRFInputEstimated_dBm = RFOutPinEstimated_dBm - totalRFOutPinToRFInLoss_dB;
DownconverterRFInputPeakEnvelopeEstimated_dBm = DownconverterRFInputEstimated_dBm + PAPR_dB;

sweepPlanTable = table(PointIndex, TxGainList, RxGainList, ...
    PlutoOutEstimated_dBm, IFBoardOutputEstimated_dBm, IFBoardCompressionEstimated_dB, ...
    RFOutPinEstimated_dBm, RFOutAfterFilterEstimated_dBm, UpconverterCompressionEstimated_dB, ...
    DownconverterRFInputEstimated_dBm, DownconverterRFInputPeakEnvelopeEstimated_dBm, ...
    repmat(upconverterTxDsaAtten_dB,numel(TxGainList),1), ...
    repmat(rfLoopbackAttenuator_dB,numel(TxGainList),1), ...
    repmat(totalRFOutPinToRFInLoss_dB,numel(TxGainList),1), ...
    repmat(PAPR_dB,numel(TxGainList),1), ...
    'VariableNames', {'PointIndex','TxGain_dB','RxGain_dB', ...
    'PlutoOutEstimated_dBm','IFBoardOutputEstimated_dBm','IFBoardCompressionEstimated_dB', ...
    'RFOutPinEstimated_dBm','RFOutAfterFilterEstimated_dBm','UpconverterCompressionEstimated_dB', ...
    'DownconverterRFInputEstimated_dBm','DownconverterRFInputPeakEnvelopeEstimated_dBm', ...
    'UpconverterTxDsaAtten_dB','RFLoopbackAttenuator_dB','TotalRFOutPinToRFInLoss_dB','PAPR_dB'});

writetable(sweepPlanTable, csvPlanFile);
disp("EXP008 sweep plan:");
disp(sweepPlanTable(:, {'PointIndex','TxGain_dB','RxGain_dB','IFBoardCompressionEstimated_dB','UpconverterCompressionEstimated_dB','DownconverterRFInputEstimated_dBm'}));

%% =========================
% INICIALIZAR STM32
% ==========================
stm = [];
fidPower = -1;
if useSTM32PowerMeter
    try
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
        fidPower = fopen(csvPowerRawFile, "w");
        fprintf(fidPower, "pc_timestamp,pointIndex,txGain_dB,rxGain_dB,stm32_time_ms,adc_raw,voltage_V,power_dB_stm32,raw_line\n");
    catch ME
        warning("No se pudo inicializar STM32. Se continua sin medidor: %s", ME.message);
        useSTM32PowerMeter = false;
    end
end

%% =========================
% OBJETOS SDR
% ==========================
sdrTransmitter = sdrtx(deviceName);
sdrTransmitter.BasebandSampleRate = sampleRate;
sdrTransmitter.CenterFrequency = centerFrequency;
sdrTransmitter.Gain = idleGain_dB;

sdrReceiver = sdrrx(deviceName);
sdrReceiver.BasebandSampleRate = sampleRate;
sdrReceiver.CenterFrequency = centerFrequency;
sdrReceiver.OutputDataType = "double";
sdrReceiver.GainSource = "Manual";

idleTxWaveform = complex(zeros(size(txWaveform)));

%% =========================
% PREALOCACION COMO TABLAS DINAMICAS
% ==========================
allRows = {};
bestRows = {};
lastTxGain = NaN;

%% =========================
% LOOP PRINCIPAL
% ==========================
try
    for iPoint = 1:numel(TxGainList)
        txGain = TxGainList(iPoint);
        rxGain = RxGainList(iPoint);
        pointIndex = PointIndex(iPoint);

        fprintf("\n========================================\n");
        fprintf("EXP008 point %d/%d | Tx %.2f dB | Rx %.2f dB\n", iPoint, numel(TxGainList), txGain, rxGain);
        fprintf("UpComp est = %.3f dB | IFComp est = %.3f dB | RF_IN est = %.2f dBm\n", ...
            UpconverterCompressionEstimated_dB(iPoint), IFBoardCompressionEstimated_dB(iPoint), DownconverterRFInputEstimated_dBm(iPoint));
        fprintf("========================================\n");

        if isnan(lastTxGain) || txGain ~= lastTxGain
            sdrTransmitter.Gain = txGain;
            transmitRepeat(sdrTransmitter, txWaveform);
            pause(rfSettleAfterTxChange_s);
            lastTxGain = txGain;
        end
        sdrReceiver.Gain = rxGain;
        pause(rfSettleAfterRxChange_s);

        bestInfo = [];
        bestData = [];
        bestScore = Inf;
        bestModeLabel = "";

        for attempt = 1:maxCaptureAttempts
            fprintf("  Capture attempt %d/%d\n", attempt, maxCaptureAttempts);

            rxCapture = capture(sdrReceiver, captureTime_s, "Seconds");
            rxCapture = rxCapture(:);

            rawFile = "";
            if saveRawCaptures
                rawFile = fullfile(rawDir, sprintf("raw_p%03d_Tx%+.2f_Rx%+.2f_att%d.mat", pointIndex, txGain, rxGain, attempt));
                try
                    save(rawFile, "rxCapture", "txWaveform", "txGain", "rxGain", "sampleRate", "attempt", "-v7.3");
                catch ME_SAVE
                    warning("No se pudo guardar raw capture: %s", ME_SAVE.message);
                    rawFile = "";
                end
            end

            evmOriginal_pct = NaN;
            if computeNR_EVM && numel(rxCapture) >= samplesPerFrame
                evmOriginal_pct = computeNREVM_Safe(rxCapture(1:samplesPerFrame), cfgDL, cfgEVM);
            end

            for irx = 1:numel(rxModeList)
                for icfo = 1:numel(cfoModeList)
                    rxMode = rxModeList(irx);
                    cfoMode = cfoModeList(icfo);
                    modeLabel = rxMode + "_" + cfoMode;

                    try
                        [alignInfo, alignedData] = alignTxRxVariant_DPDV2( ...
                            txWaveform, rxCapture, sampleRate, ...
                            coarseDecimation, fineSearchHalfWindow_samples, ...
                            phaseFitMagnitudeThreshold, numFramesForAlign, rxMode, cfoMode);

                        evmAligned_pct = NaN;
                        if computeNR_EVM
                            evmAligned_pct = computeNREVM_Safe(alignedData.y_for_evm, cfgDL, cfgEVM);
                        end

                        isClip = alignInfo.peakRx_dBFS >= dpdPeakRxMax_dBFS;
                        isUseful = alignInfo.syncMetric >= dpdSyncMetricMin && ...
                            alignInfo.nmse_dB <= dpdNMSEMax_dB && ...
                            alignInfo.peakRx_dBFS <= dpdPeakRxMax_dBFS;

                        score = syncVariantScore_DPDV2(alignInfo, isClip);

                        allRows(end+1,:) = {pointIndex, txGain, rxGain, attempt, string(rxMode), string(cfoMode), string(modeLabel), ...
                            alignInfo.delaySamples, alignInfo.startSample, alignInfo.syncMetricCoarseFine, alignInfo.syncMetric, ...
                            alignInfo.freqOffset_Hz, abs(alignInfo.complexGain), angle(alignInfo.complexGain)*180/pi, ...
                            alignInfo.nmse_dB, alignInfo.waveformEVM_pct, alignInfo.rxPower_dBFS, alignInfo.peakRx_dBFS, ...
                            isClip, isUseful, evmOriginal_pct, evmAligned_pct, score, string(rawFile), ""};

                        fprintf("    %-18s | sync %.3f | NMSE %7.2f dB | wfEVM %7.2f %% | peak %6.2f dBFS | NRorig %.2f | NRalign %.2f\n", ...
                            modeLabel, alignInfo.syncMetric, alignInfo.nmse_dB, alignInfo.waveformEVM_pct, ...
                            alignInfo.peakRx_dBFS, evmOriginal_pct, evmAligned_pct);

                        if score < bestScore
                            bestScore = score;
                            bestInfo = alignInfo;
                            bestData = alignedData;
                            bestInfo.evmOriginal_pct = evmOriginal_pct;
                            bestInfo.evmAligned_pct = evmAligned_pct;
                            bestInfo.attempt = attempt;
                            bestInfo.rxMode = string(rxMode);
                            bestInfo.cfoMode = string(cfoMode);
                            bestModeLabel = string(modeLabel);
                        end

                    catch ME_MODE
                        allRows(end+1,:) = {pointIndex, txGain, rxGain, attempt, string(rxMode), string(cfoMode), string(modeLabel), ...
                            NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, NaN, false, false, evmOriginal_pct, NaN, Inf, string(rawFile), string(ME_MODE.message)};
                        fprintf("    %-18s | ERROR: %s\n", modeLabel, ME_MODE.message);
                    end
                end
            end
        end

        % Medicion STM32 por punto.
        pMean = NaN; pStd = NaN; vMean = NaN; vStd = NaN; adcMean = NaN; nValid = 0; nInvalid = 0;
        if useSTM32PowerMeter
            try
                flush(stm);
                cmd = sprintf("MEAS,%.2f,%d", txGain, nPowerSamplesPerPoint);
                writeline(stm, cmd);
                [pVals, vVals, adcVals, nValid, nInvalid] = readSTM32PowerBlock_EXP008(stm, fidPower, pointIndex, txGain, rxGain);
                if ~isempty(pVals); pMean = mean(pVals,"omitnan"); pStd = std(pVals,"omitnan"); end
                if ~isempty(vVals); vMean = mean(vVals,"omitnan"); vStd = std(vVals,"omitnan"); end
                if ~isempty(adcVals); adcMean = mean(adcVals,"omitnan"); end
            catch ME_STM
                warning("STM32 failed at point %d: %s", pointIndex, ME_STM.message);
            end
        end

        alignedPairFile = "";
        if saveBestAlignedPair && ~isempty(bestData)
            try
                Ns = min(maxAlignedSamplesToSave, numel(bestData.x_aligned));
                x_aligned = bestData.x_aligned(1:Ns); %#ok<NASGU>
                y_aligned_raw = bestData.y_aligned_raw(1:Ns); %#ok<NASGU>
                y_corrected = bestData.y_corrected(1:Ns); %#ok<NASGU>
                y_normalized = bestData.y_normalized(1:Ns); %#ok<NASGU>
                alignInfo = bestInfo; %#ok<NASGU>
                alignedPairFile = fullfile(alignedDir, sprintf("best_p%03d_Tx%+.2f_Rx%+.2f_%s.mat", pointIndex, txGain, rxGain, bestModeLabel));
                save(alignedPairFile, "x_aligned", "y_aligned_raw", "y_corrected", "y_normalized", "alignInfo", "sampleRate", "txGain", "rxGain", "-v7.3");
            catch ME_PAIR
                warning("No se pudo guardar best aligned pair: %s", ME_PAIR.message);
                alignedPairFile = "";
            end
        end

        if ~isempty(bestInfo)
            bestRows(end+1,:) = {pointIndex, txGain, rxGain, bestInfo.attempt, bestInfo.rxMode, bestInfo.cfoMode, bestModeLabel, ...
                bestInfo.delaySamples, bestInfo.startSample, bestInfo.syncMetricCoarseFine, bestInfo.syncMetric, bestInfo.freqOffset_Hz, ...
                abs(bestInfo.complexGain), angle(bestInfo.complexGain)*180/pi, bestInfo.nmse_dB, bestInfo.waveformEVM_pct, ...
                bestInfo.rxPower_dBFS, bestInfo.peakRx_dBFS, bestInfo.evmOriginal_pct, bestInfo.evmAligned_pct, ...
                pMean, pStd, vMean, vStd, adcMean, nValid, nInvalid, ...
                IFBoardCompressionEstimated_dB(iPoint), UpconverterCompressionEstimated_dB(iPoint), ...
                DownconverterRFInputEstimated_dBm(iPoint), RFOutPinEstimated_dBm(iPoint), string(alignedPairFile)};
        end

        if iPoint < numel(TxGainList)
            nextTxGain = TxGainList(iPoint+1);
            if nextTxGain ~= txGain
                sdrTransmitter.Gain = idleGain_dB;
                transmitRepeat(sdrTransmitter, idleTxWaveform);
                pause(rfOffSettle_s);
                lastTxGain = NaN;
            end
        end
    end
catch ME
    fprintf(2, "\nERROR durante EXP008: %s\n", ME.message);
    for kk = 1:numel(ME.stack)
        fprintf(2, "  at %s line %d\n", ME.stack(kk).name, ME.stack(kk).line);
    end
end

%% =========================
% CIERRE SEGURO
% ==========================
try
    sdrTransmitter.Gain = idleGain_dB;
    transmitRepeat(sdrTransmitter, idleTxWaveform);
    pause(0.2);
catch
end
try; release(sdrTransmitter); catch; end
try; release(sdrReceiver); catch; end
if useSTM32PowerMeter
    try; fclose(fidPower); catch; end
    try; clear stm; catch; end
end

%% =========================
% GUARDADO TABLAS
% ==========================
allModesTable = cell2table(allRows, 'VariableNames', { ...
    'PointIndex','TxGain_dB','RxGain_dB','Attempt','RxMode','CfoMode','SyncMode', ...
    'DelaySamples','StartSample','SyncMetricCoarseFine','SyncMetric','FreqOffset_Hz', ...
    'ComplexGainAbs','ComplexGainPhase_deg','NMSE_aligned_dB','WaveformEVM_pct', ...
    'RxPower_dBFS','PeakRx_dBFS','ClippingFlag','IsUsefulForDPD', ...
    'EVM_NR_Original_pct','EVM_NR_Aligned_pct','Score','RawCaptureFile','ErrorMessage'});

bestPerPointTable = cell2table(bestRows, 'VariableNames', { ...
    'PointIndex','TxGain_dB','RxGain_dB','BestAttempt','RxMode','CfoMode','SyncMode', ...
    'DelaySamples','StartSample','SyncMetricCoarseFine','SyncMetric','FreqOffset_Hz', ...
    'ComplexGainAbs','ComplexGainPhase_deg','NMSE_aligned_dB','WaveformEVM_pct', ...
    'RxPower_dBFS','PeakRx_dBFS','EVM_NR_Original_pct','EVM_NR_Aligned_pct', ...
    'Power_mean_dB_stm32','Power_std_dB_stm32','Voltage_mean_V','Voltage_std_V','ADC_mean_raw','N_power_valid','N_power_invalid', ...
    'IFBoardCompressionEstimated_dB','UpconverterCompressionEstimated_dB','DownconverterRFInputEstimated_dBm','RFOutPinEstimated_dBm','AlignedPairFile'});

writetable(allModesTable, csvAllModesFile);
writetable(bestPerPointTable, csvBestFile);

save(matFile, "sweepPlanTable", "allModesTable", "bestPerPointTable", "cfgDLFRC", "cfgDL", "cfgEVM", ...
    "txWaveform", "sampleRate", "samplesPerFrame", "PAPR_dB", ...
    "rxModeList", "cfoModeList", "upconverterTxDsaAtten_dB", "RxGain_fixed_dB", ...
    "plutoTxCurveCsvFile", "bguCalibrationCsvFile", "upconverterCalibrationCsvFile");

%% =========================
% FIGURAS
% ==========================
try
    figure("Color","w");
    tiledlayout(3,1);

    nexttile;
    hold on;
    uModes = unique(allModesTable.SyncMode);
    for k = 1:numel(uModes)
        m = allModesTable.SyncMode == uModes(k);
        plot(allModesTable.TxGain_dB(m), allModesTable.SyncMetric(m), "o-", "DisplayName", uModes(k));
    end
    grid on; ylabel("SyncMetric"); title("EXP008 sync metric by mode"); legend("Location","bestoutside");

    nexttile;
    hold on;
    for k = 1:numel(uModes)
        m = allModesTable.SyncMode == uModes(k);
        plot(allModesTable.TxGain_dB(m), allModesTable.NMSE_aligned_dB(m), "o-", "DisplayName", uModes(k));
    end
    yline(dpdNMSEMax_dB, "--", "DPD NMSE max");
    grid on; ylabel("NMSE [dB]"); title("Aligned NMSE by mode");

    nexttile;
    plot(bestPerPointTable.TxGain_dB, bestPerPointTable.EVM_NR_Aligned_pct, "o-", "LineWidth", 1.3); hold on;
    plot(bestPerPointTable.TxGain_dB, bestPerPointTable.UpconverterCompressionEstimated_dB, "s-", "LineWidth", 1.3);
    grid on; xlabel("TxGain [dB]"); ylabel("EVM [%] / Compression [dB]");
    legend("Best-mode NR EVM aligned", "Upconverter compression est.", "Location", "best");
    title("Best mode EVM and estimated compression");

    saveas(gcf, figModeFile);
catch ME
    warning("No se pudo generar figura EXP008: %s", ME.message);
end

fprintf("\n============================================\n");
fprintf("EXP008 FINALIZADO\n");
fprintf("Plan             : %s\n", csvPlanFile);
fprintf("All sync modes   : %s\n", csvAllModesFile);
fprintf("Best per point   : %s\n", csvBestFile);
fprintf("MAT              : %s\n", matFile);
fprintf("Figure           : %s\n", figModeFile);
fprintf("============================================\n");

warning('on','all')

%% ============================================================
% FUNCIONES LOCALES
% ============================================================

function [alignInfo, alignedData] = alignTxRxVariant_DPDV2(xTx, yRxOriginal, Fs, D, fineHalfWin, magThrRel, numFramesForAlign, rxMode, cfoMode)
    xTx = xTx(:);
    yRxOriginal = yRxOriginal(:);

    if rxMode == "RX_CONJ"
        yRx = conj(yRxOriginal);
    else
        yRx = yRxOriginal;
    end

    Ntx = numel(xTx);
    Nuse = min(Ntx*numFramesForAlign, Ntx);
    x = xTx(1:Nuse);

    if numel(yRx) < Nuse + 10
        error('Captura RX demasiado corta para alineamiento.');
    end

    x0 = x - mean(x,'omitnan');
    y0 = yRx - mean(yRx,'omitnan');
    x0 = x0 ./ (rms(abs(x0)) + eps);
    y0 = y0 ./ (rms(abs(y0)) + eps);

    xD = x0(1:D:end);
    yD = y0(1:D:end);
    if numel(yD) < numel(xD)
        error('Captura decimada menor que referencia decimada.');
    end

    cCoarse = conv(yD, flipud(conj(xD)), 'valid');
    [~, idxCoarse] = max(abs(cCoarse));
    startCoarse = (idxCoarse - 1)*D + 1;

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

    g0 = (xAligned' * yAlignedRaw) / (xAligned' * xAligned + eps);
    z = yAlignedRaw .* conj(g0*xAligned);

    magMask = abs(xAligned) > magThrRel * max(abs(xAligned));
    if nnz(magMask) < 1000
        magMask = true(size(xAligned));
    end

    n = (0:Nuse-1).';
    phaseErr = unwrap(angle(z(magMask)));
    nFit = n(magMask);
    p = polyfit(double(nFit), double(phaseErr), 1);
    freqOffsetEstimate_Hz = p(1) * Fs / (2*pi);

    if cfoMode == "NO_CFO"
        freqOffsetApplied_Hz = 0;
        yCorrected = yAlignedRaw;
    elseif cfoMode == "CFO_POS"
        freqOffsetApplied_Hz = freqOffsetEstimate_Hz;
        yCorrected = yAlignedRaw .* exp(1j*2*pi*freqOffsetEstimate_Hz*n/Fs);
    else
        % CFO_NEG: forma usada tradicionalmente en EXP009.
        freqOffsetApplied_Hz = freqOffsetEstimate_Hz;
        yCorrected = yAlignedRaw .* exp(-1j*2*pi*freqOffsetEstimate_Hz*n/Fs);
    end

    complexGain = (xAligned' * yCorrected) / (xAligned' * xAligned + eps);
    yNorm = yCorrected ./ (complexGain + eps);

    err = yNorm - xAligned;
    nmseLin = sum(abs(err).^2) / (sum(abs(xAligned).^2) + eps);
    nmse_dB = 10*log10(nmseLin + eps);
    waveformEVM_pct = 100*sqrt(nmseLin);

    rxPower_dBFS = 20*log10(rms(abs(yAlignedRaw)) + eps);
    peakRx_dBFS = 20*log10(max(abs(yAlignedRaw)) + eps);
    syncMetricFinal = abs(xAligned' * yNorm) / ((norm(xAligned)+eps)*(norm(yNorm)+eps));

    alignInfo = struct();
    alignInfo.rxMode = rxMode;
    alignInfo.cfoMode = cfoMode;
    alignInfo.delaySamples = delaySamples;
    alignInfo.startSample = startSample;
    alignInfo.syncMetricCoarseFine = syncMetricCoarseFine;
    alignInfo.syncMetric = syncMetricFinal;
    alignInfo.freqOffset_Hz = freqOffsetApplied_Hz;
    alignInfo.freqOffsetEstimate_Hz = freqOffsetEstimate_Hz;
    alignInfo.complexGain = complexGain;
    alignInfo.nmse_dB = nmse_dB;
    alignInfo.waveformEVM_pct = waveformEVM_pct;
    alignInfo.rxPower_dBFS = rxPower_dBFS;
    alignInfo.peakRx_dBFS = peakRx_dBFS;
    alignInfo.corrDelayAxis_samples = starts(:)-1;
    alignInfo.corrMagNormalized = corrVals(:);

    alignedData = struct();
    alignedData.x_aligned = xAligned;
    alignedData.y_aligned_raw = yAlignedRaw;
    alignedData.y_corrected = yCorrected;
    alignedData.y_normalized = yNorm;
    alignedData.y_for_evm = yCorrected(1:min(numel(yCorrected), Nuse));
    alignedData.error = err;
end

function score = syncVariantScore_DPDV2(info, isClip)
    score = info.nmse_dB - 8*info.syncMetric;
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

function [Pout, modeUsed] = estimatePlutoOutput_DPDV2(txGain, fileName)
    slopeFallback = 0.9935446912;
    interceptFallback = -8.1924257506;
    Pout = slopeFallback .* txGain + interceptFallback;
    modeUsed = "fallback_linear";
    if exist(fileName, "file")
        try
            T = readtable(fileName);
            names = string(T.Properties.VariableNames);
            if ismember("TxGain_dB", names)
                txCal = T.TxGain_dB(:);
            else
                txCal = T{:,1};
            end
            if ismember("Potencia_SA_dBm", names)
                pCal = T.Potencia_SA_dBm(:);
            elseif ismember("PlutoOutCalibrated_dBm", names)
                pCal = T.PlutoOutCalibrated_dBm(:);
            else
                pCol = find(contains(lower(names),"dbm") | contains(lower(names),"power") | contains(lower(names),"potencia"),1);
                if isempty(pCol); pCol = 2; end
                pCal = T{:,pCol};
            end
            valid = isfinite(txCal) & isfinite(pCal);
            txCal = txCal(valid); pCal = pCal(valid);
            [txCal, ord] = sort(txCal); pCal = pCal(ord);
            Pout = interp1(txCal, pCal, txGain, "linear", "extrap");
            modeUsed = "csv:" + string(fileName);
        catch ME
            warning("No se pudo leer baseline Pluto. Fallback. Error: %s", ME.message);
        end
    end
end

function [IFOut, IFGain, IFComp, modeUsed] = estimateIFBoardOutput_DPDV2(txGain, fileName, plutoOut)
    fallbackGain = 20.8;
    IFOut = plutoOut + fallbackGain;
    IFGain = repmat(fallbackGain, size(txGain));
    IFComp = zeros(size(txGain));
    modeUsed = "fallback";
    if exist(fileName, "file")
        try
            T = readtable(fileName);
            names = string(T.Properties.VariableNames);
            txCal = T.TxGain_dB(:);
            if ismember("IFBoardOutputBaseline_dBm", names)
                outCal = T.IFBoardOutputBaseline_dBm(:);
            elseif ismember("IFChainOutputCorrected_dBm", names)
                outCal = T.IFChainOutputCorrected_dBm(:);
            elseif ismember("IFBoardOutputCorrected_dBm", names)
                outCal = T.IFBoardOutputCorrected_dBm(:);
            elseif ismember("DUTOutputCorrected_dBm", names)
                outCal = T.DUTOutputCorrected_dBm(:);
            else
                error("No compatible IF board output column found.");
            end
            if ismember("IFChainGainMeasured_dB", names)
                gainCal = T.IFChainGainMeasured_dB(:);
            elseif ismember("DUTGain_dB", names)
                gainCal = T.DUTGain_dB(:);
            else
                gainCal = nan(size(outCal));
            end
            if ismember("GainCompression_dB", names)
                compCal = T.GainCompression_dB(:);
            else
                compCal = zeros(size(outCal));
            end
            [txCal,ord] = sort(txCal); outCal=outCal(ord); gainCal=gainCal(ord); compCal=compCal(ord);
            IFOut = interp1(txCal,outCal,txGain,"linear","extrap");
            if any(isfinite(gainCal))
                IFGain = interp1(txCal,gainCal,txGain,"linear","extrap");
            else
                IFGain = IFOut - plutoOut;
            end
            IFComp = interp1(txCal,compCal,txGain,"linear","extrap");
            modeUsed = "csv:" + string(fileName);
        catch ME
            warning("No se pudo leer baseline IF board. Fallback. Error: %s", ME.message);
        end
    end
end

function [RFOutPin, RFOutAfterFilter, UpGain, UpComp, modeUsed] = estimateUpconverterOutput_DPDV2(txGain, fileName, upInput, filterLoss)
    fallbackGain = 20.0;
    RFOutPin = upInput + fallbackGain;
    RFOutAfterFilter = RFOutPin - filterLoss;
    UpGain = repmat(fallbackGain, size(txGain));
    UpComp = zeros(size(txGain));
    modeUsed = "fallback";
    if exist(fileName, "file")
        try
            T = readtable(fileName);
            names = string(T.Properties.VariableNames);
            txCal = T.TxGain_dB(:);
            if ismember("RFOutPinCorrected_dBm", names)
                pinCal = T.RFOutPinCorrected_dBm(:);
            else
                error("No RFOutPinCorrected_dBm column.");
            end
            if ismember("RFOutAfterFilterCorrected_dBm", names)
                aftCal = T.RFOutAfterFilterCorrected_dBm(:);
            else
                aftCal = pinCal - filterLoss;
            end
            if ismember("UpconverterGain_dB", names)
                gainCal = T.UpconverterGain_dB(:);
            else
                gainCal = nan(size(pinCal));
            end
            if ismember("UpconverterGainCompression_dB", names)
                compCal = T.UpconverterGainCompression_dB(:);
            else
                compCal = zeros(size(pinCal));
            end
            [txCal,ord] = sort(txCal); pinCal=pinCal(ord); aftCal=aftCal(ord); gainCal=gainCal(ord); compCal=compCal(ord);
            RFOutPin = interp1(txCal,pinCal,txGain,"linear","extrap");
            RFOutAfterFilter = interp1(txCal,aftCal,txGain,"linear","extrap");
            if any(isfinite(gainCal))
                UpGain = interp1(txCal,gainCal,txGain,"linear","extrap");
            else
                UpGain = RFOutPin - upInput;
            end
            UpComp = interp1(txCal,compCal,txGain,"linear","extrap");
            modeUsed = "csv:" + string(fileName);
        catch ME
            warning("No se pudo leer baseline upconverter. Fallback. Error: %s", ME.message);
        end
    end
end

function [powerValues_dB, voltageValues_V, adcValues_raw, nReceived, nInvalid] = readSTM32PowerBlock_EXP008(stm, fidPower, pointIndex, txGain, rxGain)
    nReceived = 0; nInvalid = 0; gotEnd = false;
    powerValues_dB = []; voltageValues_V = []; adcValues_raw = [];
    while ~gotEnd
        line = strtrim(string(readline(stm)));
        if strlength(line) == 0; continue; end
        if startsWith(line,"DATA")
            parts = split(line,",");
            if numel(parts) >= 5
                stm32_time_ms = str2double(parts{2});
                adc_raw = str2double(parts{3});
                voltage_V = str2double(parts{4});
                power_dB = str2double(parts{5});
                if isfinite(power_dB); powerValues_dB(end+1,1)=power_dB; end %#ok<AGROW>
                if isfinite(voltage_V); voltageValues_V(end+1,1)=voltage_V; end %#ok<AGROW>
                if isfinite(adc_raw); adcValues_raw(end+1,1)=adc_raw; end %#ok<AGROW>
                pc_timestamp = string(datetime("now","Format","yyyy-MM-dd HH:mm:ss.SSS"));
                fprintf(fidPower, "%s,%d,%.2f,%.2f,%.0f,%.0f,%.9f,%.6f,%s\n", ...
                    pc_timestamp, pointIndex, txGain, rxGain, stm32_time_ms, adc_raw, voltage_V, power_dB, sanitizeCsvField_EXP008(line));
                nReceived = nReceived + 1;
            else
                nInvalid = nInvalid + 1;
            end
        elseif startsWith(line,"END")
            gotEnd = true;
        elseif startsWith(line,"ERR")
            warning("STM32 error: %s", line);
            gotEnd = true;
        end
    end
end

function safe = sanitizeCsvField_EXP008(txt)
    safe = string(txt);
    safe = replace(safe, '"', '""');
    safe = '"' + safe + '"';
end
