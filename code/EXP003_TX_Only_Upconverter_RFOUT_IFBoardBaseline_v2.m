clear; clc;
warning('off', 'all')

addpath("C:\Users\jpfer\OneDrive\Documentos\MATLAB\Examples\R2024b\5g\NRWaveformCaptureAndAnalysisWithSDRExample")

%% ============================================================
% EXP003 - TX-ONLY RF_OUT POWER SWEEP FOR UPCONVERTER USING IF BOARD BASELINE
% ============================================================
% Configuracion fisica de este experimento:
%
%   Pluto TX -> IF board (BGU1 -> 3 dB -> BGU2) -> IF_IN del ADMV1018/ADMV1017 upconverter
%            -> RF_OUT -> filtro 26 GHz (-3 dB)
%            -> atenuador fisico de proteccion (20 dB)
%            -> medidor de potencia / STM32
%
% No se conecta RF_OUT a RF_IN.
% No se usa downconverter.
% No se usa Pluto RX.
% No se calcula EVM.
%
% Objetivo:
%   1) Barrer solamente TxGain del Pluto.
%   2) Medir potencia despues del filtro usando el medidor protegido por
%      un atenuador fisico de 20 dB.
%   3) Reconstruir:
%        RFOutAfterFilterCorrected_dBm = PowerMeterReading_dBm + 20 dB
%        RFOutPinCorrected_dBm         = PowerMeterReading_dBm + 20 dB + 3 dB
%   4) Estimar la entrada al upconverter desde el barrido previo del BGU.
%   5) Calcular ganancia real del upconverter:
%        UpconverterGain_dB = RFOutPinCorrected_dBm - UpconverterInputEstimated_dBm
%   6) Calcular compresion:
%        UpconverterGainCompression_dB =
%            SmallSignalUpconverterGainReference_dB - UpconverterGain_dB
%
% IMPORTANTE:
%   - El DSA del upconverter esta asumido en 0 dB.
%   - La perdida del filtro NO se suma a la potencia "despues del filtro";
%     solo se suma para reconstruir la potencia en el pin RF_OUT.
%   - Se conserva la rutina de lectura serial del EXP002 porque esa version
%     si funcionaba con tu firmware MEAS.

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

%% PDSCH 1 - Full-band 256QAM
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

%% PDSCH 2 - OCNG slot 0
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

%% PDSCH 3 - OCNG symbols 0:1 slots 1:19
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

% Mantener < 1 para evitar clipping digital.
powerScaleFactor = 0.8;
txWaveform = waveform .* (1 ./ max(abs(waveform)) * powerScaleFactor);
txWaveform = txWaveform(:);

samplesPerFrame = round(sampleRate * 10e-3);
fprintf("Muestras por frame de 10 ms: %d\n", samplesPerFrame);

% PAPR de la waveform compleja baseband transmitida por Pluto.
txInstantaneousPower = abs(txWaveform).^2;
txAveragePower_linear = mean(txInstantaneousPower);
txPeakPower_linear = max(txInstantaneousPower);
PAPR_linear = txPeakPower_linear / (txAveragePower_linear + eps);
PAPR_dB = 10*log10(PAPR_linear);

fprintf("PAPR waveform TX: %.3f dB\n", PAPR_dB);


%% ============================================================
% CONFIGURACION DEL BARRIDO TX-ONLY + MEDICION DE UPCONVERTER
% ============================================================

%% =========================
%  Configuracion Pluto TX
% ==========================

deviceName       = "Pluto";
centerFrequency = 5e9;
idleGain_dB     = -80;

%% =========================
%  Identificacion de la medicion
% ==========================
measurementPoint = "RF_OUT_after_B259MC1S_filter";
dutName          = "ADMV1018_Upconverter_with_IFBoard_Drive";
inputStageName   = "IFBoard_Output_to_Upconverter_IF_Input";
notes            = "EXP003: Pluto TX -> IF board BGU1+3dB+BGU2 -> upconverter IF_IN -> RF_OUT -> B259MC1S filter -> 20dB attenuator -> power meter";

%% =========================
%  Baselines usados
% ==========================
% Este archivo debe estar en:
%   DPDV2/baseline/Baseline_Power_IF_Board.csv
%
% Recomendacion: usar el CSV limpio generado a partir de EXP002 gain-compression,
% con al menos estas columnas:
%   TxGain_dB
%   IFChainOutputCorrected_dBm
% Opcionalmente:
%   IFChainGainMeasured_dB
%   GainCompression_dB
%   Voltage_Mean_V
%   Voltage_Mean_mV
%   UsefulForMixerDriveCandidate

useIFBoardBaselineCSV = true;
ifBoardBaselineCsvFile = "Baseline_Power_IF_Board.csv";

% Si el CSV no se encuentra, el codigo puede usar una aproximacion de emergencia.
% No usar para reporte final; solo para prueba rapida de comunicacion.
useFallbackIFBoardGain = false;
ifBoardSmallSignalGainFallback_dB = 21.045267;

%% =========================
%  Correcciones fisicas de RF_OUT
% ==========================
% Topologia de medicion actual:
%   RF_OUT del upconverter
%       -> cable RF_OUT a filtro             : 2 dB aprox.
%       -> filtro pasabanda B259MC1S         : 3 dB aprox.
%       -> cable filtro a atenuador/medidor  : 2 dB aprox.
%       -> atenuador  de proteccion medidor   : 6 dB
%       -> LTC5596 / STM32
%
% Por tanto:
%   P_medidor = P_RFOUT_pin - 2 - 3 - 2 - 6
%   P_RFOUT_pin = P_medidor + 13 dB
%
% Ademas se reconstruyen puntos intermedios:
%   P_after_filter = P_medidor + 6 + 2
%   P_before_filter = P_medidor + 6 + 2 + 3

outputProtectionAttenuator_dB = 20.0;
cableLoss_RFOut_to_FilterInput_dB = 2.0;
rfFilterInsertionLoss_dB = 3.0;
cableLoss_FilterOutput_to_AttenuatorInput_dB = 2.0;

% Correccion para reconstruir potencia justo despues del filtro,
% antes del cable posterior y antes del atenuador de proteccion.
outputMeasurementCorrection_dB = outputProtectionAttenuator_dB + cableLoss_FilterOutput_to_AttenuatorInput_dB;

% Correccion para reconstruir la potencia en la entrada del filtro.
rfFilterInputMeasurementCorrection_dB = outputProtectionAttenuator_dB + cableLoss_FilterOutput_to_AttenuatorInput_dB + rfFilterInsertionLoss_dB;

% Correccion total para reconstruir potencia en el pin RF_OUT del upconverter.
rfOutPinMeasurementCorrection_dB = outputProtectionAttenuator_dB + cableLoss_FilterOutput_to_AttenuatorInput_dB + rfFilterInsertionLoss_dB + cableLoss_RFOut_to_FilterInput_dB;

totalRFOutToMeterLoss_dB = rfOutPinMeasurementCorrection_dB;

% DSA interno TX del upconverter. Actualmente asumido en 0 dB.
upconverterTxDsaAtten_dB = 0.0;

% Perdida/correccion entre salida de la placa IF medida en EXP002 y la entrada
% real IF_IN del upconverter. Si conectas directo, dejar 0 dB.
ifBoardOutputToUpconverterInputCorrection_dB = 0.0;

%% =========================
%  Barrido editable SOLO TxGain
% ==========================
% Objetivo: observar la compresion del upconverter/mixer RF_OUT.
% Paso solicitado: 0.5 dB.
%
% Nota de seguridad:
%   En EXP002 la placa IF ya muestra P1dB cercano a TxGain ~= -14.25 dB.
%   Por encima de ese punto, el IF board ya no es lineal; aun asi el CSV de
%   baseline permite estimar la potencia real que entra al upconverter.

TxGain_start_dB = -45;
TxGain_stop_dB  = -18;
TxGain_step_dB  = 0.5;

TxGainList = TxGain_start_dB:TxGain_step_dB:TxGain_stop_dB;

useManualTxGainList = false;
manualTxGainList_dB = -30:0.5:-6;

if useManualTxGainList
    TxGain_dB_plan = manualTxGainList_dB(:);
else
    TxGain_dB_plan = TxGainList(:);
end

nPoints = numel(TxGain_dB_plan);
PointIndex = (1:nPoints).';

%% =========================
%  Safety limits
% ==========================
% Limite conservador para el medidor, ANTES de sumar el atenuador de 20 dB.
enableMeterSafetyStop = true;
powerMeterSafetyLimit_dBm = 0.0;

% Limite de entrada IF del ADMV1017/1018. El datasheet del ADMV1017 indica
% maximo absoluto IF input power = +5 dBm. Usamos margen conservador.
enableUpconverterInputSafetyStop = true;
upconverterIFInputSafetyLimit_dBm = 4.0;

%% =========================
%  Estimar entrada al upconverter desde baseline IF board
% ==========================
[IFBoardOutputEstimated_dBm, IFBoardGainEstimated_dB, IFBoardCompressionEstimated_dB, IFBoardVoltageBaseline_V, IFBoardBaselineMode] = estimateIFBoardOutputFromBaseline( ...
    TxGain_dB_plan, ...
    ifBoardBaselineCsvFile, ...
    useIFBoardBaselineCSV, ...
    useFallbackIFBoardGain, ...
    ifBoardSmallSignalGainFallback_dB);

UpconverterInputEstimated_dBm = IFBoardOutputEstimated_dBm + ifBoardOutputToUpconverterInputCorrection_dB;
UpconverterInputPeakEnvelopeEstimated_dBm = UpconverterInputEstimated_dBm + PAPR_dB;

% Marcas de seguridad estimadas antes de medir RF_OUT.
UpconverterIFInputNearLimitFlag = UpconverterInputEstimated_dBm >= (upconverterIFInputSafetyLimit_dBm - 1.0);
UpconverterIFInputAboveLimitFlag = UpconverterInputEstimated_dBm >= upconverterIFInputSafetyLimit_dBm;

sweepPlanTable = table( ...
    PointIndex, ...
    TxGain_dB_plan, ...
    IFBoardOutputEstimated_dBm, ...
    IFBoardGainEstimated_dB, ...
    IFBoardCompressionEstimated_dB, ...
    IFBoardVoltageBaseline_V, ...
    UpconverterInputEstimated_dBm, ...
    UpconverterInputPeakEnvelopeEstimated_dBm, ...
    UpconverterIFInputNearLimitFlag, ...
    UpconverterIFInputAboveLimitFlag, ...
    repmat(string(IFBoardBaselineMode), nPoints, 1), ...
    repmat(string(dutName), nPoints, 1), ...
    repmat(string(measurementPoint), nPoints, 1), ...
    repmat(centerFrequency, nPoints, 1), ...
    repmat(powerScaleFactor, nPoints, 1), ...
    repmat(PAPR_dB, nPoints, 1), ...
    repmat(outputProtectionAttenuator_dB, nPoints, 1), ...
    repmat(cableLoss_RFOut_to_FilterInput_dB, nPoints, 1), ...
    repmat(rfFilterInsertionLoss_dB, nPoints, 1), ...
    repmat(cableLoss_FilterOutput_to_AttenuatorInput_dB, nPoints, 1), ...
    repmat(outputMeasurementCorrection_dB, nPoints, 1), ...
    repmat(rfFilterInputMeasurementCorrection_dB, nPoints, 1), ...
    repmat(rfOutPinMeasurementCorrection_dB, nPoints, 1), ...
    repmat(totalRFOutToMeterLoss_dB, nPoints, 1), ...
    repmat(upconverterTxDsaAtten_dB, nPoints, 1), ...
    repmat(ifBoardOutputToUpconverterInputCorrection_dB, nPoints, 1), ...
    'VariableNames', { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'IFBoardOutputEstimated_dBm', ...
        'IFBoardGainEstimated_dB', ...
        'IFBoardCompressionEstimated_dB', ...
        'IFBoardVoltageBaseline_V', ...
        'UpconverterInputEstimated_dBm', ...
        'UpconverterInputPeakEnvelopeEstimated_dBm', ...
        'UpconverterIFInputNearLimitFlag', ...
        'UpconverterIFInputAboveLimitFlag', ...
        'IFBoardBaselineMode', ...
        'DUT', ...
        'MeasurementPoint', ...
        'CenterFrequency_Hz', ...
        'DigitalPowerScale', ...
        'PAPR_dB', ...
        'OutputProtectionAttenuator_dB', ...
        'CableLoss_RFOut_to_FilterInput_dB', ...
        'RFFilterInsertionLoss_dB', ...
        'CableLoss_FilterOutput_to_AttenuatorInput_dB', ...
        'OutputMeasurementCorrection_dB', ...
        'RFFilterInputMeasurementCorrection_dB', ...
        'RFOutPinMeasurementCorrection_dB', ...
        'TotalRFOutToMeterLoss_dB', ...
        'UpconverterTxDsaAtten_dB', ...
        'IFBoardOutputToUpconverterInputCorrection_dB'} ...
);

%% =========================
%  Configuracion Serial STM32 / medidor
% ==========================
useSTM32PowerMeter = true;

serialPort       = "COM12";
serialBaud       = 209700;
serialTerminator = "LF";
serialTimeout_s  = 0.30;

doPingTest = true;
nPowerSamplesPerPoint = 50;

%% =========================
%  Tiempos de estabilizacion
% ==========================
rfSettleAfterTxChange_s = 0.50;
rfOffSettle_s           = 0.20;

%% =========================
%  Referencia de compresion
% ==========================
nSmallSignalReferencePoints = 5;
minimumValidOutputPower_dBm = -90;

%% =========================
%  Archivos de salida
% ==========================
EXP_ID     = "EXP003";
CATEGORY   = "CMP";
DEVICE     = "26GHz-Link";
SHORT_NAME = "TX_ONLY_UPCONVERTER_IFBOARD_BASELINE";
VERSION    = "v2";

runTag = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
experimentFolder = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + VERSION;

scriptDir = fileparts(mfilename("fullpath"));
if strlength(string(scriptDir)) == 0
    scriptDir = pwd;
end

projectDir = fileparts(scriptDir);
outputDir = fullfile(projectDir, "data", experimentFolder, runTag);

rawDir       = fullfile(outputDir, "raw");
processedDir = fullfile(outputDir, "processed");
figuresDir   = fullfile(outputDir, "figures");

if ~exist(rawDir, "dir"); mkdir(rawDir); end
if ~exist(processedDir, "dir"); mkdir(processedDir); end
if ~exist(figuresDir, "dir"); mkdir(figuresDir); end

baseName = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + runTag + "_" + VERSION;

csvPlanFile             = fullfile(processedDir, baseName + "_tx-sweep-plan.csv");
csvPowerRawFile         = fullfile(rawDir,       baseName + "_rfout-power-raw.csv");
csvPowerSummaryFile     = fullfile(processedDir, baseName + "_power-summary.csv");
csvCompressionFile      = fullfile(processedDir, baseName + "_upconverter-gain-compression.csv");
matFile                 = fullfile(processedDir, baseName + "_results.mat");
figPowerFile            = fullfile(figuresDir,   baseName + "_upconverter-power-vs-txgain.png");
figCompressionFile      = fullfile(figuresDir,   baseName + "_upconverter-compression.png");
figCompressionTxFile    = fullfile(figuresDir,   baseName + "_compression-vs-txgain.png");
figCompressionVoltageFile = fullfile(figuresDir, baseName + "_compression-vs-voltage.png");

fprintf("\nOutput directory:\n%s\n\n", outputDir);

%% ============================================================
% INICIALIZAR SERIAL STM32
% ============================================================

stm = [];
fidPower = -1;

if useSTM32PowerMeter
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
        error("No se pudo crear el archivo CSV de potencia: %s", csvPowerRawFile);
    end

    fprintf(fidPower, [ ...
        "pc_timestamp,pointIndex,txGain_dB,ifBoardOutputEstimated_dBm," + ...
        "upconverterInputEstimated_dBm,centerFrequency_Hz," + ...
        "dut,measurementPoint,digitalPowerScale,papr_dB," + ...
        "outputProtectionAttenuator_dB,rfFilterInsertionLoss_dB,outputMeasurementCorrection_dB,rfOutPinMeasurementCorrection_dB," + ...
        "stm32_time_ms,adc_raw,voltage_V,voltage_mV,power_dB_meter,raw_line\n"]);
end

%% ============================================================
% OBJETO SDR TX
% ============================================================

sdrTransmitter = sdrtx(deviceName);
sdrTransmitter.BasebandSampleRate = sampleRate;
sdrTransmitter.CenterFrequency = centerFrequency;
sdrTransmitter.Gain = idleGain_dB;

%% ============================================================
% PREALOCACION DE RESUMEN DE POTENCIA
% ============================================================

Power_mean_dB = nan(nPoints,1);
Power_std_dB  = nan(nPoints,1);
Power_min_dB  = nan(nPoints,1);
Power_max_dB  = nan(nPoints,1);

Voltage_mean_V = nan(nPoints,1);
Voltage_std_V  = nan(nPoints,1);
Voltage_min_V  = nan(nPoints,1);
Voltage_max_V  = nan(nPoints,1);

ADC_mean_raw = nan(nPoints,1);
ADC_std_raw  = nan(nPoints,1);
ADC_min_raw  = nan(nPoints,1);
ADC_max_raw  = nan(nPoints,1);

Power_n_valid = zeros(nPoints,1);
Power_n_invalid = zeros(nPoints,1);
SafetyStopTriggered = false(nPoints,1);

lastTxGain = NaN;
stopSweep = false;

%% ============================================================
% BARRIDO PRINCIPAL SOLO TX
% ============================================================

try
    for iPoint = 1:nPoints
        pointIndex = sweepPlanTable.PointIndex(iPoint);
        txGain     = sweepPlanTable.TxGain_dB(iPoint);

        fprintf("\n====================================\n");
        fprintf("Punto %d/%d | Index = %d\n", iPoint, nPoints, pointIndex);
        fprintf("DUT = %s | Punto medicion = %s\n", dutName, measurementPoint);
        fprintf("TxGain = %.2f dB | Fc = %.3f GHz\n", txGain, centerFrequency/1e9);
        fprintf("P_IFBoardOut_est = %.2f dBm | P_UpconvIn_est = %.2f dBm | PEP_UpconvIn_est = %.2f dBm\n", ...
            sweepPlanTable.IFBoardOutputEstimated_dBm(iPoint), ...
            sweepPlanTable.UpconverterInputEstimated_dBm(iPoint), ...
            sweepPlanTable.UpconverterInputPeakEnvelopeEstimated_dBm(iPoint));
        fprintf("Atenuador medidor = %.2f dB | filtro = %.2f dB\n", ...
            outputProtectionAttenuator_dB, rfFilterInsertionLoss_dB);
        fprintf("====================================\n");

        if enableUpconverterInputSafetyStop && sweepPlanTable.UpconverterIFInputAboveLimitFlag(iPoint)
            warning("Safety stop antes de transmitir: entrada IF estimada al upconverter %.2f dBm >= limite %.2f dBm", ...
                sweepPlanTable.UpconverterInputEstimated_dBm(iPoint), upconverterIFInputSafetyLimit_dBm);
            SafetyStopTriggered(iPoint) = true;
            stopSweep = true;
            break;
        end

        if isnan(lastTxGain) || txGain ~= lastTxGain
            fprintf("Actualizando TxGain a %.2f dB\n", txGain);
            sdrTransmitter.Gain = txGain;
            transmitRepeat(sdrTransmitter, txWaveform);
            pause(rfSettleAfterTxChange_s);
            lastTxGain = txGain;
        end

        if useSTM32PowerMeter
            flush(stm);
            cmd = sprintf("MEAS,%.2f,%d", txGain, nPowerSamplesPerPoint);
            fprintf("Enviando comando STM32: %s\n", cmd);
            writeline(stm, cmd);

            [powerValues_dB, voltageValues_V, adcValues_raw, nPowerReceived, nPowerInvalid] = readSTM32PowerBlock_RFOut( ...
                stm, ...
                fidPower, ...
                pointIndex, ...
                txGain, ...
                sweepPlanTable.IFBoardOutputEstimated_dBm(iPoint), ...
                sweepPlanTable.UpconverterInputEstimated_dBm(iPoint), ...
                centerFrequency, ...
                dutName, ...
                measurementPoint, ...
                powerScaleFactor, ...
                PAPR_dB, ...
                outputProtectionAttenuator_dB, ...
                rfFilterInsertionLoss_dB, ...
                outputMeasurementCorrection_dB, ...
                rfOutPinMeasurementCorrection_dB);

            Power_n_valid(iPoint)   = nPowerReceived;
            Power_n_invalid(iPoint) = nPowerInvalid;

            if ~isempty(powerValues_dB)
                Power_mean_dB(iPoint) = mean(powerValues_dB, "omitnan");
                Power_std_dB(iPoint)  = std(powerValues_dB, "omitnan");
                Power_min_dB(iPoint)  = min(powerValues_dB, [], "omitnan");
                Power_max_dB(iPoint)  = max(powerValues_dB, [], "omitnan");

                Voltage_mean_V(iPoint) = mean(voltageValues_V, "omitnan");
                Voltage_std_V(iPoint)  = std(voltageValues_V, "omitnan");
                Voltage_min_V(iPoint)  = min(voltageValues_V, [], "omitnan");
                Voltage_max_V(iPoint)  = max(voltageValues_V, [], "omitnan");

                ADC_mean_raw(iPoint) = mean(adcValues_raw, "omitnan");
                ADC_std_raw(iPoint)  = std(adcValues_raw, "omitnan");
                ADC_min_raw(iPoint)  = min(adcValues_raw, [], "omitnan");
                ADC_max_raw(iPoint)  = max(adcValues_raw, [], "omitnan");

                fprintf("  Lectura medidor: mean = %.4f dBm | V = %.4f V | %.2f mV\n", ...
                    Power_mean_dB(iPoint), Voltage_mean_V(iPoint), 1000*Voltage_mean_V(iPoint));
                fprintf("  Potencia despues del filtro: %.4f dBm\n", ...
                    Power_mean_dB(iPoint) + outputMeasurementCorrection_dB);
                fprintf("  Potencia reconstruida en pin RF_OUT: %.4f dBm\n", ...
                    Power_mean_dB(iPoint) + rfOutPinMeasurementCorrection_dB);

                if enableMeterSafetyStop && Power_mean_dB(iPoint) >= powerMeterSafetyLimit_dBm
                    warning("Safety stop: medidor %.2f dBm >= limite %.2f dBm", Power_mean_dB(iPoint), powerMeterSafetyLimit_dBm);
                    SafetyStopTriggered(iPoint) = true;
                    stopSweep = true;
                end
            else
                fprintf("  No se recibieron muestras validas de potencia.\n");
            end

            fprintf("  STM32 muestras validas: %d | invalidas: %d\n", nPowerReceived, nPowerInvalid);
        end

        if stopSweep
            break;
        end

        if iPoint < nPoints
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
    warning("Error durante el barrido principal: %s", ME.message);
end

%% ============================================================
% CIERRE SEGURO SDR / SERIAL
% ============================================================

fprintf("\nCerrando equipos...\n");
try
    sdrTransmitter.Gain = idleGain_dB;
    transmitRepeat(sdrTransmitter, txWaveform);
    pause(0.2);
catch ME
    warning("No se pudo colocar Pluto en reposo: %s", ME.message);
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
% TABLA DE RESUMEN DE POTENCIA
% ============================================================

RFOutAfterFilterCorrected_dBm = Power_mean_dB + outputMeasurementCorrection_dB;
RFOutAfterFilterMinCorrected_dBm = Power_min_dB + outputMeasurementCorrection_dB;
RFOutAfterFilterMaxCorrected_dBm = Power_max_dB + outputMeasurementCorrection_dB;

RFFilterInputCorrected_dBm = Power_mean_dB + rfFilterInputMeasurementCorrection_dB;
RFFilterInputMinCorrected_dBm = Power_min_dB + rfFilterInputMeasurementCorrection_dB;
RFFilterInputMaxCorrected_dBm = Power_max_dB + rfFilterInputMeasurementCorrection_dB;

RFOutPinCorrected_dBm = Power_mean_dB + rfOutPinMeasurementCorrection_dB;
RFOutPinMinCorrected_dBm = Power_min_dB + rfOutPinMeasurementCorrection_dB;
RFOutPinMaxCorrected_dBm = Power_max_dB + rfOutPinMeasurementCorrection_dB;
RFOutPinPeakEnvelopeCorrected_dBm = RFOutPinCorrected_dBm + PAPR_dB;

UpconverterGain_AfterFilter_dB = RFOutAfterFilterCorrected_dBm - UpconverterInputEstimated_dBm;
UpconverterGain_RFOutPin_dB = RFOutPinCorrected_dBm - UpconverterInputEstimated_dBm;

powerSummaryTable = table( ...
    sweepPlanTable.PointIndex, ...
    sweepPlanTable.TxGain_dB, ...
    sweepPlanTable.IFBoardOutputEstimated_dBm, ...
    sweepPlanTable.IFBoardGainEstimated_dB, ...
    sweepPlanTable.IFBoardCompressionEstimated_dB, ...
    sweepPlanTable.IFBoardVoltageBaseline_V, ...
    sweepPlanTable.UpconverterInputEstimated_dBm, ...
    sweepPlanTable.UpconverterInputPeakEnvelopeEstimated_dBm, ...
    sweepPlanTable.UpconverterIFInputNearLimitFlag, ...
    sweepPlanTable.UpconverterIFInputAboveLimitFlag, ...
    sweepPlanTable.IFBoardBaselineMode, ...
    sweepPlanTable.DUT, ...
    sweepPlanTable.MeasurementPoint, ...
    sweepPlanTable.CenterFrequency_Hz, ...
    sweepPlanTable.DigitalPowerScale, ...
    sweepPlanTable.PAPR_dB, ...
    sweepPlanTable.OutputProtectionAttenuator_dB, ...
    sweepPlanTable.CableLoss_RFOut_to_FilterInput_dB, ...
    sweepPlanTable.RFFilterInsertionLoss_dB, ...
    sweepPlanTable.CableLoss_FilterOutput_to_AttenuatorInput_dB, ...
    sweepPlanTable.OutputMeasurementCorrection_dB, ...
    sweepPlanTable.RFFilterInputMeasurementCorrection_dB, ...
    sweepPlanTable.RFOutPinMeasurementCorrection_dB, ...
    sweepPlanTable.TotalRFOutToMeterLoss_dB, ...
    Power_mean_dB, Power_std_dB, Power_min_dB, Power_max_dB, ...
    Voltage_mean_V, Voltage_std_V, Voltage_min_V, Voltage_max_V, ...
    1000*Voltage_mean_V, 1000*Voltage_std_V, 1000*Voltage_min_V, 1000*Voltage_max_V, ...
    ADC_mean_raw, ADC_std_raw, ADC_min_raw, ADC_max_raw, ...
    Power_n_valid, Power_n_invalid, SafetyStopTriggered, ...
    RFOutAfterFilterCorrected_dBm, RFOutAfterFilterMinCorrected_dBm, RFOutAfterFilterMaxCorrected_dBm, ...
    RFFilterInputCorrected_dBm, RFFilterInputMinCorrected_dBm, RFFilterInputMaxCorrected_dBm, ...
    RFOutPinCorrected_dBm, RFOutPinMinCorrected_dBm, RFOutPinMaxCorrected_dBm, RFOutPinPeakEnvelopeCorrected_dBm, ...
    UpconverterGain_AfterFilter_dB, UpconverterGain_RFOutPin_dB, ...
    'VariableNames', { ...
        'PointIndex', 'TxGain_dB', ...
        'IFBoardOutputEstimated_dBm', 'IFBoardGainEstimated_dB', 'IFBoardCompressionEstimated_dB', 'IFBoardVoltageBaseline_V', ...
        'UpconverterInputEstimated_dBm', 'UpconverterInputPeakEnvelopeEstimated_dBm', ...
        'UpconverterIFInputNearLimitFlag', 'UpconverterIFInputAboveLimitFlag', ...
        'IFBoardBaselineMode', 'DUT', 'MeasurementPoint', 'CenterFrequency_Hz', 'DigitalPowerScale', 'PAPR_dB', ...
        'OutputProtectionAttenuator_dB', 'CableLoss_RFOut_to_FilterInput_dB', 'RFFilterInsertionLoss_dB', 'CableLoss_FilterOutput_to_AttenuatorInput_dB', 'OutputMeasurementCorrection_dB', 'RFFilterInputMeasurementCorrection_dB', 'RFOutPinMeasurementCorrection_dB', 'TotalRFOutToMeterLoss_dB', ...
        'Power_mean_dB_meter', 'Power_std_dB_meter', 'Power_min_dB_meter', 'Power_max_dB_meter', ...
        'Voltage_Mean_V', 'Voltage_Std_V', 'Voltage_Min_V', 'Voltage_Max_V', ...
        'Voltage_Mean_mV', 'Voltage_Std_mV', 'Voltage_Min_mV', 'Voltage_Max_mV', ...
        'ADC_Mean_raw', 'ADC_Std_raw', 'ADC_Min_raw', 'ADC_Max_raw', ...
        'N_valid_samples', 'N_invalid_samples', 'SafetyStopTriggered', ...
        'RFOutAfterFilterCorrected_dBm', 'RFOutAfterFilterMinCorrected_dBm', 'RFOutAfterFilterMaxCorrected_dBm', ...
        'RFFilterInputCorrected_dBm', 'RFFilterInputMinCorrected_dBm', 'RFFilterInputMaxCorrected_dBm', ...
        'RFOutPinCorrected_dBm', 'RFOutPinMinCorrected_dBm', 'RFOutPinMaxCorrected_dBm', 'RFOutPinPeakEnvelopeCorrected_dBm', ...
        'UpconverterGain_AfterFilter_dB', 'UpconverterGain_RFOutPin_dB'} ...
);

fprintf("\n========== PLAN DE BARRIDO TX ==========\n");
disp(sweepPlanTable);

fprintf("\n========== RESUMEN DE POTENCIA UPCONVERTER ==========\n");
disp(powerSummaryTable);

%% ============================================================
% COMPRESION DEL UPCONVERTER SIN REGRESION
% ============================================================

compressionTable = powerSummaryTable;
compressionTable.SmallSignalUpconverterGainReference_dB = nan(height(compressionTable),1);
compressionTable.UpconverterGainCompression_dB = nan(height(compressionTable),1);
compressionTable.IsP1dB_or_more = false(height(compressionTable),1);

validGainMask = isfinite(compressionTable.UpconverterGain_AfterFilter_dB) & ...
    isfinite(compressionTable.RFOutAfterFilterCorrected_dBm) & ...
    compressionTable.RFOutAfterFilterCorrected_dBm > minimumValidOutputPower_dBm;

nRef = min(nSmallSignalReferencePoints, nnz(validGainMask));
smallSignalUpconverterGainReference_dB = NaN;

if nRef >= 2
    validIdx = find(validGainMask);
    refIdx = validIdx(1:nRef);

    smallSignalUpconverterGainReference_dB = mean(compressionTable.UpconverterGain_AfterFilter_dB(refIdx), "omitnan");

    compressionTable.SmallSignalUpconverterGainReference_dB(:) = smallSignalUpconverterGainReference_dB;
    compressionTable.UpconverterGainCompression_dB(validGainMask) = ...
        smallSignalUpconverterGainReference_dB - compressionTable.UpconverterGain_AfterFilter_dB(validGainMask);
    compressionTable.IsP1dB_or_more = compressionTable.UpconverterGainCompression_dB >= 1.0;

    fprintf("\n========== COMPRESION DEL UPCONVERTER ==========\n");
    fprintf("Referencia pequena senal: %.4f dB usando los primeros %d puntos validos.\n", ...
        smallSignalUpconverterGainReference_dB, nRef);

    idxFirstP1dB = find(compressionTable.UpconverterGainCompression_dB >= 1.0, 1, 'first');
    if ~isempty(idxFirstP1dB)
        fprintf("\nPrimer punto con compresion del upconverter >= 1 dB:\n");
        fprintf("  PointIndex                  = %d\n", compressionTable.PointIndex(idxFirstP1dB));
        fprintf("  TxGain                      = %.2f dB\n", compressionTable.TxGain_dB(idxFirstP1dB));
        fprintf("  UpconverterInputEstimated   = %.4f dBm\n", compressionTable.UpconverterInputEstimated_dBm(idxFirstP1dB));
        fprintf("  RFOutAfterFilterCorrected   = %.4f dBm\n", compressionTable.RFOutAfterFilterCorrected_dBm(idxFirstP1dB));
        fprintf("  RFOutPinCorrected           = %.4f dBm\n", compressionTable.RFOutPinCorrected_dBm(idxFirstP1dB));
        fprintf("  Voltage                     = %.4f V\n", compressionTable.Voltage_Mean_V(idxFirstP1dB));
        fprintf("  UpconverterCompression      = %.4f dB\n", compressionTable.UpconverterGainCompression_dB(idxFirstP1dB));
    else
        fprintf("\nNo se encontro compresion >= 1 dB en el rango barrido.\n");
    end
else
    warning("No hay suficientes puntos validos para estimar la compresion del upconverter.");
end

%% ============================================================
% GRAFICAS RAPIDAS
% ============================================================

try
    figure;
    plot(compressionTable.TxGain_dB, compressionTable.RFOutAfterFilterCorrected_dBm, "o-", "LineWidth", 1.4);
    hold on;
    plot(compressionTable.TxGain_dB, compressionTable.RFOutPinCorrected_dBm, "d-", "LineWidth", 1.4);
    plot(compressionTable.TxGain_dB, compressionTable.UpconverterInputEstimated_dBm, "s--", "LineWidth", 1.2);
    xlabel("Pluto Tx Gain [dB]");
    ylabel("Power [dBm]");
    title(sprintf("EXP003 RF_OUT power | total RF_OUT-to-meter loss %.1f dB", totalRFOutToMeterLoss_dB));
    legend("After filter corrected", "Reconstructed RF_OUT pin", "Estimated upconverter IF input", "Location", "best");
    grid on;
    hold off;
    saveas(gcf, figPowerFile);
catch ME
    warning("No se pudo generar o guardar la grafica de potencia: %s", ME.message);
end

try
    figure;
    plot(compressionTable.RFOutAfterFilterCorrected_dBm, compressionTable.UpconverterGainCompression_dB, "o-", "LineWidth", 1.4);
    hold on;
    yline(1.0, "--", "1 dB compression");
    xlabel("RF output after filter corrected [dBm]");
    ylabel("Upconverter gain compression [dB]");
    title("Upconverter compression vs RF output after filter");
    grid on;
    hold off;
    saveas(gcf, figCompressionFile);
catch ME
    warning("No se pudo generar o guardar la grafica de compresion: %s", ME.message);
end

try
    figure;
    plot(compressionTable.TxGain_dB, compressionTable.UpconverterGainCompression_dB, "o-", "LineWidth", 1.4);
    hold on;
    yline(1.0, "--", "1 dB compression");
    xlabel("Pluto Tx Gain [dB]");
    ylabel("Upconverter gain compression [dB]");
    title("Upconverter compression vs Pluto Tx Gain");
    grid on;
    hold off;
    saveas(gcf, figCompressionTxFile);
catch ME
    warning("No se pudo generar grafica de compresion vs TxGain: %s", ME.message);
end

try
    figure;
    plot(compressionTable.Voltage_Mean_V, compressionTable.UpconverterGainCompression_dB, "o-", "LineWidth", 1.4);
    hold on;
    yline(1.0, "--", "1 dB compression");
    xlabel("LTC5596 sensor voltage [V]");
    ylabel("Upconverter gain compression [dB]");
    title("Upconverter compression vs sensor voltage");
    grid on;
    hold off;
    saveas(gcf, figCompressionVoltageFile);
catch ME
    warning("No se pudo generar grafica de compresion vs voltaje: %s", ME.message);
end

%% ============================================================
% GUARDADO FINAL
% ============================================================

writetable(sweepPlanTable, csvPlanFile);
writetable(powerSummaryTable, csvPowerSummaryFile);
writetable(compressionTable, csvCompressionFile);

save(matFile, ...
    "sweepPlanTable", "powerSummaryTable", "compressionTable", ...
    "cfgDLFRC", "centerFrequency", "sampleRate", "powerScaleFactor", ...
    "PAPR_dB", "PAPR_linear", "txAveragePower_linear", "txPeakPower_linear", ...
    "TxGainList", "useManualTxGainList", "manualTxGainList_dB", ...
    "dutName", "measurementPoint", "notes", "nPowerSamplesPerPoint", ...
    "ifBoardBaselineCsvFile", "IFBoardBaselineMode", ...
    "ifBoardOutputToUpconverterInputCorrection_dB", ...
    "outputProtectionAttenuator_dB", "outputMeasurementCorrection_dB", ...
    "rfFilterInsertionLoss_dB", "cableLoss_RFOut_to_FilterInput_dB", "cableLoss_FilterOutput_to_AttenuatorInput_dB", ...
    "rfFilterInputMeasurementCorrection_dB", "totalRFOutToMeterLoss_dB", "rfOutPinMeasurementCorrection_dB", ...
    "upconverterTxDsaAtten_dB", "smallSignalUpconverterGainReference_dB");

fprintf("\n============================================\n");
fprintf("BARRIDO TX-ONLY UPCONVERTER FINALIZADO\n");
fprintf("Archivo plan TX              : %s\n", csvPlanFile);
if useSTM32PowerMeter
    fprintf("Archivo potencia cruda       : %s\n", csvPowerRawFile);
end
fprintf("Archivo resumen potencia     : %s\n", csvPowerSummaryFile);
fprintf("Archivo compresion upconverter: %s\n", csvCompressionFile);
fprintf("Figura potencia              : %s\n", figPowerFile);
fprintf("Figura compresion            : %s\n", figCompressionFile);
fprintf("Archivo MAT                  : %s\n", matFile);
fprintf("============================================\n");

warning('on', 'all')

%% ============================================================
% FUNCIONES LOCALES
% ============================================================

function [IFBoardOutputEstimated_dBm, IFBoardGainEstimated_dB, IFBoardCompressionEstimated_dB, IFBoardVoltageBaseline_V, modeUsed] = estimateIFBoardOutputFromBaseline( ...
    txGainPlan_dB, ...
    ifBoardBaselineCsvFile, ...
    useIFBoardBaselineCSV, ...
    useFallbackIFBoardGain, ...
    ifBoardSmallSignalGainFallback_dB)

    IFBoardOutputEstimated_dBm = nan(size(txGainPlan_dB));
    IFBoardGainEstimated_dB = nan(size(txGainPlan_dB));
    IFBoardCompressionEstimated_dB = nan(size(txGainPlan_dB));
    IFBoardVoltageBaseline_V = nan(size(txGainPlan_dB));
    modeUsed = "not_available";

    if useIFBoardBaselineCSV
        candidateFiles = strings(0,1);
        candidateFiles(end+1,1) = string(ifBoardBaselineCsvFile);
        candidateFiles(end+1,1) = fullfile(pwd, string(ifBoardBaselineCsvFile));

        scriptDir = fileparts(mfilename("fullpath"));
        if strlength(string(scriptDir)) > 0
            candidateFiles(end+1,1) = fullfile(scriptDir, string(ifBoardBaselineCsvFile));
            candidateFiles(end+1,1) = fullfile(fileparts(scriptDir), "baseline", string(ifBoardBaselineCsvFile));
        end

        fileFound = "";
        for k = 1:numel(candidateFiles)
            if exist(candidateFiles(k), "file")
                fileFound = candidateFiles(k);
                break;
            end
        end

        if strlength(fileFound) > 0
            T = readtable(fileFound);
            txCal = T.TxGain_dB(:);

            if ismember('IFChainOutputCorrected_dBm', T.Properties.VariableNames)
                ifOutCal = T.IFChainOutputCorrected_dBm(:);
            elseif ismember('IFBoardOutputCorrected_dBm', T.Properties.VariableNames)
                ifOutCal = T.IFBoardOutputCorrected_dBm(:);
            else
                error('No se encontro columna IFChainOutputCorrected_dBm en Baseline_Power_IF_Board.csv');
            end

            if ismember('IFChainGainMeasured_dB', T.Properties.VariableNames)
                ifGainCal = T.IFChainGainMeasured_dB(:);
            else
                ifGainCal = nan(size(ifOutCal));
            end

            if ismember('GainCompression_dB', T.Properties.VariableNames)
                ifCompCal = T.GainCompression_dB(:);
            else
                ifCompCal = nan(size(ifOutCal));
            end

            if ismember('Voltage_Mean_V', T.Properties.VariableNames)
                ifVoltCal = T.Voltage_Mean_V(:);
            else
                ifVoltCal = nan(size(ifOutCal));
            end

            valid = isfinite(txCal) & isfinite(ifOutCal);
            txCal = txCal(valid);
            ifOutCal = ifOutCal(valid);
            ifGainCal = ifGainCal(valid);
            ifCompCal = ifCompCal(valid);
            ifVoltCal = ifVoltCal(valid);

            [txCal, sortIdx] = sort(txCal);
            ifOutCal = ifOutCal(sortIdx);
            ifGainCal = ifGainCal(sortIdx);
            ifCompCal = ifCompCal(sortIdx);
            ifVoltCal = ifVoltCal(sortIdx);

            IFBoardOutputEstimated_dBm = interp1(txCal, ifOutCal, txGainPlan_dB, 'linear', 'extrap');
            IFBoardGainEstimated_dB = interp1(txCal, ifGainCal, txGainPlan_dB, 'linear', 'extrap');
            IFBoardCompressionEstimated_dB = interp1(txCal, ifCompCal, txGainPlan_dB, 'linear', 'extrap');
            IFBoardVoltageBaseline_V = interp1(txCal, ifVoltCal, txGainPlan_dB, 'linear', 'extrap');

            modeUsed = "csv_interpolation:" + string(fileFound);
            fprintf("IF board baseline loaded from:\n%s\n", fileFound);
            return;
        else
            warning("No se encontro Baseline_Power_IF_Board.csv: %s", ifBoardBaselineCsvFile);
        end
    end

    if useFallbackIFBoardGain
        warning("Usando fallback por ganancia fija del IF board. No usar para reporte final.");
        % Requiere una columna de potencia Pluto real; no esta disponible aqui.
        % Por seguridad se deja NaN si no hay CSV.
        modeUsed = "fallback_requested_but_no_pluto_power_available";
    end
end

function [powerValues_dB, voltageValues_V, adcValues_raw, nReceived, nInvalid] = readSTM32PowerBlock_RFOut( ...
    stm, fidPower, pointIndex, txGain, ifBoardOutputEstimated_dBm, upconverterInputEstimated_dBm, centerFrequency, ...
    dutName, measurementPoint, powerScaleFactor, PAPR_dB, outputProtectionAttenuator_dB, rfFilterInsertionLoss_dB, ...
    outputMeasurementCorrection_dB, rfOutPinMeasurementCorrection_dB)

    powerValues_dB = [];
    voltageValues_V = [];
    adcValues_raw = [];
    nReceived = 0;
    nInvalid  = 0;
    gotEnd    = false;

    while ~gotEnd
        try
            line = strtrim(string(readline(stm)));
        catch ME
            warning("Timeout/error leyendo STM32 en PointIndex %d: %s", pointIndex, ME.message);
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

                if isnan(stm32_time_ms) || isnan(adc_raw) || isnan(voltage_V) || isnan(power_dB)
                    nInvalid = nInvalid + 1;
                    fprintf("  Linea DATA con NaN: %s\n", line);
                    continue;
                end

                pc_timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));

                fprintf(fidPower, "%s,%d,%.2f,%.6f,%.6f,%.0f,%s,%s,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.0f,%.0f,%.9f,%.6f,%.6f,%s\n", ...
                    pc_timestamp, pointIndex, txGain, ifBoardOutputEstimated_dBm, upconverterInputEstimated_dBm, centerFrequency, ...
                    sanitizeCsvField(dutName), sanitizeCsvField(measurementPoint), powerScaleFactor, PAPR_dB, ...
                    outputProtectionAttenuator_dB, rfFilterInsertionLoss_dB, outputMeasurementCorrection_dB, rfOutPinMeasurementCorrection_dB, ...
                    stm32_time_ms, adc_raw, voltage_V, 1000*voltage_V, power_dB, sanitizeCsvField(line));

                powerValues_dB(end+1,1) = power_dB; %#ok<AGROW>
                voltageValues_V(end+1,1) = voltage_V; %#ok<AGROW>
                adcValues_raw(end+1,1) = adc_raw; %#ok<AGROW>
                nReceived = nReceived + 1;
            else
                nInvalid = nInvalid + 1;
                fprintf("  Linea DATA invalida: %s\n", line);
            end

        elseif startsWith(line, "END")
            fprintf("  %s\n", line);
            gotEnd = true;

        elseif startsWith(line, "ERR")
            warning("STM32 respondio error: %s", line);
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
