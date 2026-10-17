clear; clc;
warning('off', 'all')

addpath("C:\Users\jpfer\OneDrive\Documentos\MATLAB\Examples\R2024b\5g\NRWaveformCaptureAndAnalysisWithSDRExample")

%% ============================================================
% EXP004 - DOWNCONVERTER COMPRESSION CHECK
% ============================================================
% Configuracion fisica de este experimento:
%
%   Pluto TX -> BGU -> IF_IN del ADMV1018/ADMV1017 upconverter
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
% EXP004 - DOWNCONVERTER RF_IN COMPRESSION SWEEP USING EXP003 UPCONVERTER BASELINE
% ============================================================
% Configuracion fisica propuesta:
%
%   Pluto TX -> BGU -> ADMV1018 Upconverter IF_IN -> RF_OUT
%            -> filtro 26 GHz (-3 dB)
%            -> atenuador RF fisico hacia RF_IN (20 dB)
%            -> ADMV1018 Downconverter RF_IN -> IF_OUT
%            -> atenuador de proteccion del medidor/Pluto RX
%            -> medidor de potencia / STM32
%
% Objetivos:
%   1) Delimitar el barrido para que la potencia estimada en RF_IN del
%      downconverter no supere un limite seguro.
%   2) Medir potencia despues del downconverter en IF_OUT.
%   3) Estimar la ganancia del downconverter:
%         G_Down = P_IFOUT_corregida - P_RFIN_estimada
%   4) Estimar compresion del downconverter:
%         Comp_Down = G_Down_small_signal - G_Down
%   5) Comparar con la compresion ya estimada del BGU y del upconverter.
%
% NOTA IMPORTANTE:
%   Este script NO calcula EVM. Es una prueba de potencia/compresion para
%   verificar si el downconverter esta permaneciendo lineal mientras el
%   upconverter ya entra en compresion.

%% =========================
%  Configuracion Pluto TX
% ==========================

deviceName       = "Pluto";
centerFrequency = 5e9;
idleGain_dB     = -80;

% Calibracion de potencia de salida del Pluto.
% P_PlutoOut[dBm] = slope*TxGain[dB] + intercept
plutoTxPowerSlope_dBperdB = 0.9935446912;
plutoTxPowerIntercept_dBm = -8.1924257506;
plutoTxPowerFitMin_dB = -29;
plutoTxPowerFitMax_dB = -14;
plutoTxPowerFitRMSE_dB = 0.0522602848;
plutoTxPowerFitR2 = 0.9998572208;

% Correccion entre salida Pluto y entrada del BGU.
% Ejemplo: atenuador/perdida 3 dB entre Pluto y BGU => -3.
plutoToBGUInputCorrection_dB = 0.0;

%% =========================
%  Identificacion de la medicion
% ==========================
measurementPoint = "IF_OUT_after_downconverter";
dutName          = "ADMV1018_Downconverter_Check";
notes            = "EXP004: Downconverter compression check using EXP003 TXDSA7 upconverter baseline. Pluto TX -> IF board -> Upconverter TX DSA 7dB -> RF_OUT -> B259MC1S filter -> RF attenuator -> RF_IN Downconverter -> IF_OUT -> meter";

%% =========================
%  Correcciones fisicas de la cadena RF y del medidor
% ==========================
% DSA interno TX/RF del upconverter. Configuracion nueva: 7 dB.
% IMPORTANTE: este valor es metadata; el DSA se configura manualmente en ACE.
upconverterTxDsaAtten_dB = 7.0;

% Filtro despues de RF_OUT antes de volver a RF_IN.
rfOutFilterInsertionLoss_dB = 3.0;

% Atenuador fisico entre el filtro de 26 GHz y RF_IN del downconverter.
% Este es el atenuador que protege al RF_IN del downconverter.
rfLoopbackAttenuator_dB = 30.0;   % Recommended first compression sweep: 20 dB from RF_OUT-after-filter to RF_IN

% Limite seguro de entrada al downconverter.
% Tu indicaste: hasta -3 dBm como maximo en RF_IN.
rfInMaxAllowed_dBm = -8.0;      % hard safety limit; IF downconverter P1dB is around -16 to -10 dBm

% Margen de seguridad adicional aplicado al plan de barrido.
% Si quieres usar exactamente -3 dBm, pon 0.0.
rfInSafetyMargin_dB = 1.0;      % planning limit = -9 dBm
rfInPlanningLimit_dBm = rfInMaxAllowed_dBm - rfInSafetyMargin_dB;

% Atenuador fisico despues del downconverter, antes del medidor/Pluto RX.
% Si NO hay atenuador en IF_OUT antes del medidor, pon 0.
% Si usas 20 dB para proteger el medidor o Pluto, dejar 20.
% IMPORTANTE: en esta configuracion NO hay atenuador entre IF_OUT del downconverter y el medidor.
% Por tanto, la potencia corregida IF_OUT es igual a la lectura directa del LTC5596/STM32.
% Si luego insertas un atenuador fisico en IF_OUT, cambiar este valor al valor real positivo.
ifOutMeterProtectionAttenuator_dB = 0.0;
ifOutMeasurementCorrection_dB = ifOutMeterProtectionAttenuator_dB;

% Ganancia nominal esperada del downconverter en IF mode.
% Solo se usa como referencia visual, no para calcular compresion.
downconverterGainNominal_dB = 18.0;

%% =========================
%  Archivos de calibracion previos
% ==========================
useBGUCalibrationCSV = true;
bguCalibrationCsvFile = "Baseline_Power_IF_Board.csv";
bguSmallSignalGainFallback_dB = 7.796105;

useUpconverterCalibrationCSV = true;
% Baseline experimental generado desde EXP003 con TX DSA interno = 7 dB.
% Debe estar en: DPDV2/baseline/Baseline_Power_Upconverter_RFOUT_TXDSA7.csv
upconverterCalibrationCsvFile = "Baseline_Power_Upconverter_RFOUT_TXDSA7.csv";
upconverterSmallSignalGainFallback_dB = 24.50;

%% =========================
%  Barrido editable SOLO TxGain
% ==========================
% Con 20 dB entre filtro y RF_IN, este rango debe permitir observar la zona
% donde el upconverter comprime sin superar el limite de RF_IN.
TxGain_start_dB = -34;
TxGain_stop_dB  = -14;
TxGain_step_dB  = 0.5;

TxGainList = TxGain_start_dB:TxGain_step_dB:TxGain_stop_dB;

% Si quieres medir puntos manuales, activa esto:
useManualTxGainList = false;
manualTxGainList_dB = -34:0.5:-24;

if useManualTxGainList
    TxGain_dB_candidate = manualTxGainList_dB(:);
else
    TxGain_dB_candidate = TxGainList(:);
end

% Potencia calibrada de Pluto para todos los candidatos.
PlutoOutCalibrated_dBm_candidate = plutoTxPowerSlope_dBperdB .* TxGain_dB_candidate + plutoTxPowerIntercept_dBm;
BGUInputEstimated_dBm_candidate = PlutoOutCalibrated_dBm_candidate + plutoToBGUInputCorrection_dB;
PlutoCalibrationInFitRange_candidate = TxGain_dB_candidate >= plutoTxPowerFitMin_dB & TxGain_dB_candidate <= plutoTxPowerFitMax_dB;

% Estimar salida del BGU desde calibracion previa.
[BGUOutputEstimated_dBm_candidate, BGUGainEstimated_dB_candidate, BGUCompressionEstimated_dB_candidate, BGUCalibrationMode] = estimateBGUOutputFromPreviousSweep( ...
    TxGain_dB_candidate, ...
    bguCalibrationCsvFile, ...
    useBGUCalibrationCSV, ...
    BGUInputEstimated_dBm_candidate, ...
    bguSmallSignalGainFallback_dB);

UpconverterInputEstimated_dBm_candidate = BGUOutputEstimated_dBm_candidate;
UpconverterInputPeakEnvelopeEstimated_dBm_candidate = UpconverterInputEstimated_dBm_candidate + PAPR_dB;

% Estimar RF_OUT desde calibracion previa del EXP004E.
[RFOutPinEstimated_dBm_candidate, RFOutAfterFilterEstimated_dBm_candidate, UpconverterGainEstimated_dB_candidate, UpconverterCompressionEstimated_dB_candidate, UpconverterCalibrationMode] = estimateUpconverterRFOutFromPreviousSweep( ...
    TxGain_dB_candidate, ...
    upconverterCalibrationCsvFile, ...
    useUpconverterCalibrationCSV, ...
    UpconverterInputEstimated_dBm_candidate, ...
    upconverterSmallSignalGainFallback_dB, ...
    rfOutFilterInsertionLoss_dB);

% Potencia estimada a la entrada RF_IN del downconverter.
DownconverterRFInputEstimated_dBm_candidate = RFOutAfterFilterEstimated_dBm_candidate - rfLoopbackAttenuator_dB;
DownconverterRFInputPeakEnvelopeEstimated_dBm_candidate = DownconverterRFInputEstimated_dBm_candidate + PAPR_dB;

% Filtrar automaticamente puntos que superen el limite configurado.
safeMask = isfinite(DownconverterRFInputEstimated_dBm_candidate) & ...
           DownconverterRFInputEstimated_dBm_candidate <= rfInPlanningLimit_dBm;

if ~any(safeMask)
    error("Ningun punto del barrido cumple RF_IN <= %.2f dBm. Aumenta atenuacion RF o baja TxGain_stop_dB.", rfInPlanningLimit_dBm);
end

if any(~safeMask)
    fprintf("\nADVERTENCIA: Se descartaran %d puntos por superar RF_IN planning limit %.2f dBm.\n", nnz(~safeMask), rfInPlanningLimit_dBm);
end

TxGain_dB_plan = TxGain_dB_candidate(safeMask);
PlutoOutCalibrated_dBm = PlutoOutCalibrated_dBm_candidate(safeMask);
BGUInputEstimated_dBm = BGUInputEstimated_dBm_candidate(safeMask);
PlutoCalibrationInFitRange = PlutoCalibrationInFitRange_candidate(safeMask);
BGUOutputEstimated_dBm = BGUOutputEstimated_dBm_candidate(safeMask);
BGUGainEstimated_dB = BGUGainEstimated_dB_candidate(safeMask);
BGUCompressionEstimated_dB = BGUCompressionEstimated_dB_candidate(safeMask);
UpconverterInputEstimated_dBm = UpconverterInputEstimated_dBm_candidate(safeMask);
UpconverterInputPeakEnvelopeEstimated_dBm = UpconverterInputPeakEnvelopeEstimated_dBm_candidate(safeMask);
RFOutPinEstimated_dBm = RFOutPinEstimated_dBm_candidate(safeMask);
RFOutAfterFilterEstimated_dBm = RFOutAfterFilterEstimated_dBm_candidate(safeMask);
UpconverterGainEstimated_dB = UpconverterGainEstimated_dB_candidate(safeMask);
UpconverterCompressionEstimated_dB = UpconverterCompressionEstimated_dB_candidate(safeMask);
DownconverterRFInputEstimated_dBm = DownconverterRFInputEstimated_dBm_candidate(safeMask);
DownconverterRFInputPeakEnvelopeEstimated_dBm = DownconverterRFInputPeakEnvelopeEstimated_dBm_candidate(safeMask);

nPoints = numel(TxGain_dB_plan);
PointIndex = (1:nPoints).';

sweepPlanTable = table( ...
    PointIndex, ...
    TxGain_dB_plan, ...
    PlutoOutCalibrated_dBm, ...
    PlutoCalibrationInFitRange, ...
    BGUInputEstimated_dBm, ...
    BGUOutputEstimated_dBm, ...
    BGUGainEstimated_dB, ...
    BGUCompressionEstimated_dB, ...
    UpconverterInputEstimated_dBm, ...
    UpconverterInputPeakEnvelopeEstimated_dBm, ...
    RFOutPinEstimated_dBm, ...
    RFOutAfterFilterEstimated_dBm, ...
    UpconverterGainEstimated_dB, ...
    UpconverterCompressionEstimated_dB, ...
    DownconverterRFInputEstimated_dBm, ...
    DownconverterRFInputPeakEnvelopeEstimated_dBm, ...
    repmat(string(BGUCalibrationMode), nPoints, 1), ...
    repmat(string(UpconverterCalibrationMode), nPoints, 1), ...
    repmat(string(dutName), nPoints, 1), ...
    repmat(string(measurementPoint), nPoints, 1), ...
    repmat(centerFrequency, nPoints, 1), ...
    repmat(powerScaleFactor, nPoints, 1), ...
    repmat(PAPR_dB, nPoints, 1), ...
    repmat(rfOutFilterInsertionLoss_dB, nPoints, 1), ...
    repmat(rfLoopbackAttenuator_dB, nPoints, 1), ...
    repmat(rfInMaxAllowed_dBm, nPoints, 1), ...
    repmat(rfInSafetyMargin_dB, nPoints, 1), ...
    repmat(ifOutMeterProtectionAttenuator_dB, nPoints, 1), ...
    repmat(ifOutMeasurementCorrection_dB, nPoints, 1), ...
    repmat(upconverterTxDsaAtten_dB, nPoints, 1), ...
    'VariableNames', { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'PlutoOutCalibrated_dBm', ...
        'PlutoCalibrationInFitRange', ...
        'BGUInputEstimated_dBm', ...
        'BGUOutputEstimated_dBm', ...
        'BGUGainEstimated_dB', ...
        'BGUCompressionEstimated_dB', ...
        'UpconverterInputEstimated_dBm', ...
        'UpconverterInputPeakEnvelopeEstimated_dBm', ...
        'RFOutPinEstimated_dBm', ...
        'RFOutAfterFilterEstimated_dBm', ...
        'UpconverterGainEstimated_dB', ...
        'UpconverterCompressionEstimated_dB', ...
        'DownconverterRFInputEstimated_dBm', ...
        'DownconverterRFInputPeakEnvelopeEstimated_dBm', ...
        'BGUCalibrationMode', ...
        'UpconverterCalibrationMode', ...
        'DUT', ...
        'MeasurementPoint', ...
        'CenterFrequency_Hz', ...
        'DigitalPowerScale', ...
        'PAPR_dB', ...
        'RFOutFilterInsertionLoss_dB', ...
        'RFLoopbackAttenuator_dB', ...
        'RFInMaxAllowed_dBm', ...
        'RFInSafetyMargin_dB', ...
        'IFOutMeterProtectionAttenuator_dB', ...
        'IFOutMeasurementCorrection_dB', ...
        'UpconverterTxDsaAtten_dB'} ...
);

fprintf("\n========== PLAN SEGURO EXP004 TXDSA7 ==========%s", newline);
disp(sweepPlanTable(:, {'PointIndex','TxGain_dB','UpconverterCompressionEstimated_dB','RFOutAfterFilterEstimated_dBm','DownconverterRFInputEstimated_dBm','DownconverterRFInputPeakEnvelopeEstimated_dBm'}));

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
%  Referencia de compresion del downconverter
% ==========================
nSmallSignalReferencePoints = 5;
minimumValidIFOutputPower_dBm = -90;

%% =========================
%  Archivos de salida
% ==========================
EXP_ID     = "EXP004";
CATEGORY   = "CMP";
DEVICE     = "26GHz-Link";
SHORT_NAME = "DOWNCONVERTER_RF_IN_COMPRESSION_TXDSA7_BASELINE";
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

if ~exist(rawDir, "dir"); mkdir(rawDir); end
if ~exist(processedDir, "dir"); mkdir(processedDir); end
if ~exist(figuresDir, "dir"); mkdir(figuresDir); end

baseName = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + runTag + "_" + VERSION;

csvPlanFile             = fullfile(processedDir, baseName + "_tx-sweep-plan.csv");
csvPowerRawFile         = fullfile(rawDir,       baseName + "_ifout-power-raw.csv");
csvPowerSummaryFile     = fullfile(processedDir, baseName + "_power-summary.csv");
csvCompressionFile      = fullfile(processedDir, baseName + "_downconverter-compression-check.csv");
matFile                 = fullfile(processedDir, baseName + "_results.mat");
figPowerFile            = fullfile(figuresDir,   baseName + "_power-flow-vs-txgain.png");
figCompressionFile      = fullfile(figuresDir,   baseName + "_compression-comparison.png");
figDownGainFile         = fullfile(figuresDir,   baseName + "_downconverter-gain-compression.png");

fprintf("\nOutput directory:\n%s\n\n", outputDir);

fprintf("Baseline upconverter usado: %s\\n", upconverterCalibrationCsvFile);
fprintf("Metadata TX DSA upconverter: %.2f dB\\n", upconverterTxDsaAtten_dB);
fprintf("Atenuador fisico RF loopback declarado: %.2f dB\\n", rfLoopbackAttenuator_dB);
fprintf("Proteccion software RF_IN planning limit: %.2f dBm\\n\\n", rfInPlanningLimit_dBm);

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
        "pc_timestamp,pointIndex,txGain_dB,plutoOutCalibrated_dBm," + ...
        "bguOutputEstimated_dBm,upconverterInputEstimated_dBm,rfOutAfterFilterEstimated_dBm," + ...
        "rfLoopbackAttenuator_dB,downconverterRFInputEstimated_dBm,centerFrequency_Hz," + ...
        "dut,measurementPoint,digitalPowerScale,papr_dB,ifOutMeterProtectionAttenuator_dB,ifOutMeasurementCorrection_dB," + ...
        "stm32_time_ms,adc_raw,voltage_V,power_dB_meter,raw_line\n"]);
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
Power_n_valid = zeros(nPoints,1);
Power_n_invalid = zeros(nPoints,1);

Voltage_mean_V = nan(nPoints,1);
Voltage_std_V  = nan(nPoints,1);
Voltage_min_V  = nan(nPoints,1);
Voltage_max_V  = nan(nPoints,1);
ADC_mean_raw = nan(nPoints,1);
ADC_std_raw  = nan(nPoints,1);
ADC_min_raw  = nan(nPoints,1);
ADC_max_raw  = nan(nPoints,1);

lastTxGain = NaN;

%% ============================================================
% BARRIDO PRINCIPAL SOLO TX + MEDICION IF_OUT
% ============================================================

try
    for iPoint = 1:nPoints

        pointIndex = sweepPlanTable.PointIndex(iPoint);
        txGain     = sweepPlanTable.TxGain_dB(iPoint);
        rfInEst    = sweepPlanTable.DownconverterRFInputEstimated_dBm(iPoint);

        fprintf("\n====================================\n");
        fprintf("Punto %d/%d | Index = %d\n", iPoint, nPoints, pointIndex);
        fprintf("DUT = %s | Punto medicion = %s\n", dutName, measurementPoint);
        fprintf("TxGain = %.2f dB | Fc = %.3f GHz\n", txGain, centerFrequency/1e9);
        fprintf("P_UpIn_est = %.2f dBm | RF_OUT after filter est = %.2f dBm | RF_IN downconverter est = %.2f dBm\n", ...
            sweepPlanTable.UpconverterInputEstimated_dBm(iPoint), ...
            sweepPlanTable.RFOutAfterFilterEstimated_dBm(iPoint), ...
            rfInEst);
        fprintf("Upconverter compression estimated = %.2f dB | BGU compression estimated = %.2f dB\n", ...
            sweepPlanTable.UpconverterCompressionEstimated_dB(iPoint), ...
            sweepPlanTable.BGUCompressionEstimated_dB(iPoint));
        fprintf("IF_OUT meter attenuator = %.2f dB -> IF_OUT corrected = meter + %.2f dB\n", ...
            ifOutMeterProtectionAttenuator_dB, ifOutMeasurementCorrection_dB);
        fprintf("====================================\n");

        if rfInEst > rfInMaxAllowed_dBm
            warning("Punto omitido por seguridad: RF_IN estimado %.2f dBm > %.2f dBm", rfInEst, rfInMaxAllowed_dBm);
            continue;
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

            [powerValues_dB, voltageValues_V, adcValues_raw, nPowerReceived, nPowerInvalid] = readSTM32PowerBlock_EXP005( ...
                stm, fidPower, pointIndex, txGain, ...
                sweepPlanTable.PlutoOutCalibrated_dBm(iPoint), ...
                sweepPlanTable.BGUOutputEstimated_dBm(iPoint), ...
                sweepPlanTable.UpconverterInputEstimated_dBm(iPoint), ...
                sweepPlanTable.RFOutAfterFilterEstimated_dBm(iPoint), ...
                rfLoopbackAttenuator_dB, ...
                sweepPlanTable.DownconverterRFInputEstimated_dBm(iPoint), ...
                centerFrequency, dutName, measurementPoint, powerScaleFactor, PAPR_dB, ...
                ifOutMeterProtectionAttenuator_dB, ifOutMeasurementCorrection_dB);

            Power_n_valid(iPoint)   = nPowerReceived;
            Power_n_invalid(iPoint) = nPowerInvalid;

            if ~isempty(powerValues_dB)
                Power_mean_dB(iPoint) = mean(powerValues_dB, "omitnan");
                Power_std_dB(iPoint)  = std(powerValues_dB, "omitnan");
                Power_min_dB(iPoint)  = min(powerValues_dB, [], "omitnan");
                Power_max_dB(iPoint)  = max(powerValues_dB, [], "omitnan");

                fprintf("  Lectura medidor IF_OUT: mean = %.4f dBm | std = %.4f dB | min = %.4f | max = %.4f\n", ...
                    Power_mean_dB(iPoint), Power_std_dB(iPoint), Power_min_dB(iPoint), Power_max_dB(iPoint));
                fprintf("  IF_OUT corregida: %.4f dBm\n", Power_mean_dB(iPoint) + ifOutMeasurementCorrection_dB);
            else
                fprintf("  No se recibieron muestras validas de potencia.\n");
            end

            fprintf("  STM32 muestras validas: %d | invalidas: %d\n", nPowerReceived, nPowerInvalid);
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
% TABLAS Y COMPRESION DEL DOWNCONVERTER
% ============================================================

IFOutCorrected_dBm = Power_mean_dB + ifOutMeasurementCorrection_dB;
IFOutMinCorrected_dBm = Power_min_dB + ifOutMeasurementCorrection_dB;
IFOutMaxCorrected_dBm = Power_max_dB + ifOutMeasurementCorrection_dB;
IFOutPeakEnvelopeCorrected_dBm = IFOutCorrected_dBm + PAPR_dB;

DownconverterGainMeasured_dB = IFOutCorrected_dBm - DownconverterRFInputEstimated_dBm;

powerSummaryTable = table( ...
    sweepPlanTable.PointIndex, ...
    sweepPlanTable.TxGain_dB, ...
    sweepPlanTable.PlutoOutCalibrated_dBm, ...
    sweepPlanTable.BGUOutputEstimated_dBm, ...
    sweepPlanTable.BGUGainEstimated_dB, ...
    sweepPlanTable.BGUCompressionEstimated_dB, ...
    sweepPlanTable.UpconverterInputEstimated_dBm, ...
    sweepPlanTable.RFOutPinEstimated_dBm, ...
    sweepPlanTable.RFOutAfterFilterEstimated_dBm, ...
    sweepPlanTable.UpconverterGainEstimated_dB, ...
    sweepPlanTable.UpconverterCompressionEstimated_dB, ...
    sweepPlanTable.DownconverterRFInputEstimated_dBm, ...
    sweepPlanTable.DownconverterRFInputPeakEnvelopeEstimated_dBm, ...
    Power_mean_dB, ...
    Power_std_dB, ...
    Power_min_dB, ...
    Power_max_dB, ...
    Power_n_valid, ...
    Power_n_invalid, ...
    Voltage_mean_V, Voltage_std_V, Voltage_min_V, Voltage_max_V, ...
    1000*Voltage_mean_V, 1000*Voltage_std_V, 1000*Voltage_min_V, 1000*Voltage_max_V, ...
    ADC_mean_raw, ADC_std_raw, ADC_min_raw, ADC_max_raw, ...
    IFOutCorrected_dBm, ...
    IFOutMinCorrected_dBm, ...
    IFOutMaxCorrected_dBm, ...
    IFOutPeakEnvelopeCorrected_dBm, ...
    DownconverterGainMeasured_dB, ...
    'VariableNames', { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'PlutoOutCalibrated_dBm', ...
        'BGUOutputEstimated_dBm', ...
        'BGUGainEstimated_dB', ...
        'BGUCompressionEstimated_dB', ...
        'UpconverterInputEstimated_dBm', ...
        'RFOutPinEstimated_dBm', ...
        'RFOutAfterFilterEstimated_dBm', ...
        'UpconverterGainEstimated_dB', ...
        'UpconverterCompressionEstimated_dB', ...
        'DownconverterRFInputEstimated_dBm', ...
        'DownconverterRFInputPeakEnvelopeEstimated_dBm', ...
        'Power_mean_dB_meter', ...
        'Power_std_dB_meter', ...
        'Power_min_dB_meter', ...
        'Power_max_dB_meter', ...
        'N_valid_samples', ...
        'N_invalid_samples', ...
        'Voltage_Mean_V', 'Voltage_Std_V', 'Voltage_Min_V', 'Voltage_Max_V', ...
        'Voltage_Mean_mV', 'Voltage_Std_mV', 'Voltage_Min_mV', 'Voltage_Max_mV', ...
        'ADC_Mean_raw', 'ADC_Std_raw', 'ADC_Min_raw', 'ADC_Max_raw', ...
        'IFOutCorrected_dBm', ...
        'IFOutMinCorrected_dBm', ...
        'IFOutMaxCorrected_dBm', ...
        'IFOutPeakEnvelopeCorrected_dBm', ...
        'DownconverterGainMeasured_dB'} ...
);

compressionTable = powerSummaryTable;
compressionTable.SmallSignalDownconverterGainReference_dB = nan(height(compressionTable),1);
compressionTable.DownconverterGainCompression_dB = nan(height(compressionTable),1);
compressionTable.IsDownconverterP1dB_or_more = false(height(compressionTable),1);
compressionTable.IsUpconverterP1dB_or_more_est = compressionTable.UpconverterCompressionEstimated_dB >= 1.0;
compressionTable.Interpretation = strings(height(compressionTable),1);

validDownGainMask = ...
    isfinite(compressionTable.DownconverterGainMeasured_dB) & ...
    isfinite(compressionTable.IFOutCorrected_dBm) & ...
    compressionTable.IFOutCorrected_dBm > minimumValidIFOutputPower_dBm;

nRef = min(nSmallSignalReferencePoints, nnz(validDownGainMask));
smallSignalDownconverterGainReference_dB = NaN;

if nRef >= 2
    validIdx = find(validDownGainMask);
    refIdx = validIdx(1:nRef);
    smallSignalDownconverterGainReference_dB = mean(compressionTable.DownconverterGainMeasured_dB(refIdx), "omitnan");

    compressionTable.SmallSignalDownconverterGainReference_dB(:) = smallSignalDownconverterGainReference_dB;
    compressionTable.DownconverterGainCompression_dB(validDownGainMask) = ...
        smallSignalDownconverterGainReference_dB - compressionTable.DownconverterGainMeasured_dB(validDownGainMask);
    compressionTable.IsDownconverterP1dB_or_more = compressionTable.DownconverterGainCompression_dB >= 1.0;

    for k = 1:height(compressionTable)
        if compressionTable.UpconverterCompressionEstimated_dB(k) >= 1.0 && compressionTable.DownconverterGainCompression_dB(k) < 0.5
            compressionTable.Interpretation(k) = "TX/upconverter compression dominates; downconverter still near linear";
        elseif compressionTable.DownconverterGainCompression_dB(k) >= 1.0
            compressionTable.Interpretation(k) = "Downconverter compression detected; observation receiver may contaminate DPD";
        else
            compressionTable.Interpretation(k) = "No strong downconverter compression";
        end
    end

    fprintf("\n========== COMPRESION DOWNCONVERTER / COMPARACION ==========%s", newline);
    fprintf("Referencia pequena senal downconverter: %.4f dB usando los primeros %d puntos validos.\n", ...
        smallSignalDownconverterGainReference_dB, nRef);

    disp(compressionTable(:, { ...
        'PointIndex', ...
        'TxGain_dB', ...
        'RFOutAfterFilterEstimated_dBm', ...
        'DownconverterRFInputEstimated_dBm', ...
        'IFOutCorrected_dBm', ...
        'DownconverterGainMeasured_dB', ...
        'DownconverterGainCompression_dB', ...
        'UpconverterCompressionEstimated_dB', ...
        'BGUCompressionEstimated_dB', ...
        'Interpretation'}));
else
    warning("No hay suficientes puntos validos para estimar la compresion del downconverter.");
end

%% ============================================================
% GRAFICAS
% ============================================================
try
    figure;
    plot(compressionTable.TxGain_dB, compressionTable.RFOutAfterFilterEstimated_dBm, "o-", "LineWidth", 1.4);
    hold on;
    plot(compressionTable.TxGain_dB, compressionTable.DownconverterRFInputEstimated_dBm, "s-", "LineWidth", 1.4);
    plot(compressionTable.TxGain_dB, compressionTable.IFOutCorrected_dBm, "d-", "LineWidth", 1.4);
    yline(rfInMaxAllowed_dBm, "--", "RF_IN max allowed");
    xlabel("Pluto Tx Gain [dB]");
    ylabel("Power [dBm]");
    title(sprintf("EXP004 power flow | RF loop att %.1f dB | IF meter att %.1f dB", rfLoopbackAttenuator_dB, ifOutMeterProtectionAttenuator_dB));
    legend("RF_OUT after filter estimated", "RF_IN downconverter estimated", "IF_OUT corrected measured", "Location", "best");
    grid on;
    hold off;
    saveas(gcf, figPowerFile);
catch ME
    warning("No se pudo generar grafica de potencia: %s", ME.message);
end

try
    figure;
    plot(compressionTable.DownconverterRFInputEstimated_dBm, compressionTable.DownconverterGainMeasured_dB, "o-", "LineWidth", 1.4);
    hold on;
    yline(smallSignalDownconverterGainReference_dB, "--", "Small-signal measured ref");
    yline(downconverterGainNominal_dB, ":", "Nominal 18 dB");
    xlabel("Estimated RF_IN downconverter [dBm]");
    ylabel("Measured downconverter gain [dB]");
    title("Downconverter gain vs estimated RF input");
    grid on;
    hold off;
    saveas(gcf, replace(figDownGainFile, ".png", "_gain.png"));
catch ME
    warning("No se pudo generar grafica de ganancia downconverter: %s", ME.message);
end

try
    figure;
    plot(compressionTable.DownconverterRFInputEstimated_dBm, compressionTable.DownconverterGainCompression_dB, "o-", "LineWidth", 1.4);
    hold on;
    yline(1.0, "--", "1 dB compression");
    xlabel("Estimated RF_IN downconverter [dBm]");
    ylabel("Downconverter gain compression [dB]");
    title("Downconverter compression vs estimated RF input");
    grid on;
    hold off;
    saveas(gcf, figDownGainFile);
catch ME
    warning("No se pudo generar grafica de compresion downconverter: %s", ME.message);
end

try
    figure;
    plot(compressionTable.TxGain_dB, compressionTable.BGUCompressionEstimated_dB, "o-", "LineWidth", 1.2);
    hold on;
    plot(compressionTable.TxGain_dB, compressionTable.UpconverterCompressionEstimated_dB, "s-", "LineWidth", 1.2);
    plot(compressionTable.TxGain_dB, compressionTable.DownconverterGainCompression_dB, "d-", "LineWidth", 1.2);
    yline(1.0, "--", "1 dB compression");
    xlabel("Pluto Tx Gain [dB]");
    ylabel("Compression [dB]");
    title("Compression comparison: BGU vs Upconverter vs Downconverter");
    legend("BGU estimated", "Upconverter estimated", "Downconverter measured", "Location", "best");
    grid on;
    hold off;
    saveas(gcf, figCompressionFile);
catch ME
    warning("No se pudo generar grafica comparativa de compresion: %s", ME.message);
end

%% ============================================================
% GUARDADO FINAL
% ============================================================

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
    "TxGainList", ...
    "useManualTxGainList", ...
    "manualTxGainList_dB", ...
    "dutName", ...
    "measurementPoint", ...
    "notes", ...
    "nPowerSamplesPerPoint", ...
    "plutoTxPowerSlope_dBperdB", ...
    "plutoTxPowerIntercept_dBm", ...
    "plutoTxPowerFitMin_dB", ...
    "plutoTxPowerFitMax_dB", ...
    "plutoTxPowerFitRMSE_dB", ...
    "plutoTxPowerFitR2", ...
    "plutoToBGUInputCorrection_dB", ...
    "rfOutFilterInsertionLoss_dB", ...
    "rfLoopbackAttenuator_dB", ...
    "rfInMaxAllowed_dBm", ...
    "rfInPlanningLimit_dBm", ...
    "ifOutMeterProtectionAttenuator_dB", ...
    "ifOutMeasurementCorrection_dB", ...
    "bguCalibrationCsvFile", ...
    "upconverterCalibrationCsvFile", ...
    "BGUCalibrationMode", ...
    "UpconverterCalibrationMode", ...
    "smallSignalDownconverterGainReference_dB");

fprintf("\n============================================\n");
fprintf("BARRIDO EXP004 FINALIZADO\n");
fprintf("Archivo plan TX              : %s\n", csvPlanFile);
if useSTM32PowerMeter
    fprintf("Archivo potencia cruda       : %s\n", csvPowerRawFile);
end
fprintf("Archivo resumen potencia     : %s\n", csvPowerSummaryFile);
fprintf("Archivo compresion/check     : %s\n", csvCompressionFile);
fprintf("Figura potencia              : %s\n", figPowerFile);
fprintf("Figura compresion comparativa: %s\n", figCompressionFile);
fprintf("Figura downconverter         : %s\n", figDownGainFile);
fprintf("Archivo MAT                  : %s\n", matFile);
fprintf("============================================\n");

warning('on', 'all')

%% ============================================================
% FUNCIONES LOCALES
% ============================================================

function [BGUOutputEstimated_dBm, BGUGainEstimated_dB, BGUCompressionEstimated_dB, modeUsed] = estimateBGUOutputFromPreviousSweep( ...
    txGainPlan_dB, ...
    bguCalibrationCsvFile, ...
    useBGUCalibrationCSV, ...
    bguInputEstimated_dBm, ...
    bguSmallSignalGainFallback_dB)

    BGUOutputEstimated_dBm = nan(size(txGainPlan_dB));
    BGUGainEstimated_dB = nan(size(txGainPlan_dB));
    BGUCompressionEstimated_dB = nan(size(txGainPlan_dB));
    modeUsed = "fallback_fixed_BGU_gain";

    if useBGUCalibrationCSV
        fileFound = findCalibrationFile(bguCalibrationCsvFile);
        if strlength(fileFound) > 0
            try
                T = readtable(fileFound);
                txCal = T.TxGain_dB(:);
                if ismember('DUTOutputCorrected_dBm', T.Properties.VariableNames)
                    bguOutCal = T.DUTOutputCorrected_dBm(:);
                elseif ismember('MeasuredOutputCorrected_dBm', T.Properties.VariableNames)
                    bguOutCal = T.MeasuredOutputCorrected_dBm(:);
                else
                    error('No output power column found in BGU calibration CSV.');
                end

                if ismember('DUTGain_dB', T.Properties.VariableNames)
                    bguGainCal = T.DUTGain_dB(:);
                else
                    bguGainCal = nan(size(bguOutCal));
                end

                if ismember('GainCompression_dB', T.Properties.VariableNames)
                    bguCompCal = T.GainCompression_dB(:);
                else
                    bguCompCal = nan(size(bguOutCal));
                end

                [txCal, order] = sort(txCal);
                bguOutCal = bguOutCal(order);
                bguGainCal = bguGainCal(order);
                bguCompCal = bguCompCal(order);

                BGUOutputEstimated_dBm = interp1(txCal, bguOutCal, txGainPlan_dB, 'linear', 'extrap');
                if any(isfinite(bguGainCal))
                    BGUGainEstimated_dB = interp1(txCal, bguGainCal, txGainPlan_dB, 'linear', 'extrap');
                else
                    BGUGainEstimated_dB = BGUOutputEstimated_dBm - bguInputEstimated_dBm;
                end
                if any(isfinite(bguCompCal))
                    BGUCompressionEstimated_dB = interp1(txCal, bguCompCal, txGainPlan_dB, 'linear', 'extrap');
                end
                modeUsed = "csv_interpolation:" + string(fileFound);
                return;
            catch ME
                warning("No se pudo usar CSV BGU. Se usara fallback. Error: %s", ME.message);
            end
        end
    end

    BGUGainEstimated_dB(:) = bguSmallSignalGainFallback_dB;
    BGUOutputEstimated_dBm = bguInputEstimated_dBm + bguSmallSignalGainFallback_dB;
    BGUCompressionEstimated_dB(:) = 0;
end

function [RFOutPinEstimated_dBm, RFOutAfterFilterEstimated_dBm, UpconverterGainEstimated_dB, UpconverterCompressionEstimated_dB, modeUsed] = estimateUpconverterRFOutFromPreviousSweep( ...
    txGainPlan_dB, ...
    upconverterCalibrationCsvFile, ...
    useUpconverterCalibrationCSV, ...
    upconverterInputEstimated_dBm, ...
    upconverterSmallSignalGainFallback_dB, ...
    rfOutFilterInsertionLoss_dB)

    RFOutPinEstimated_dBm = nan(size(txGainPlan_dB));
    RFOutAfterFilterEstimated_dBm = nan(size(txGainPlan_dB));
    UpconverterGainEstimated_dB = nan(size(txGainPlan_dB));
    UpconverterCompressionEstimated_dB = nan(size(txGainPlan_dB));
    modeUsed = "fallback_fixed_upconverter_gain";

    if useUpconverterCalibrationCSV
        fileFound = findCalibrationFile(upconverterCalibrationCsvFile);
        if strlength(fileFound) > 0
            try
                T = readtable(fileFound);
                txCal = T.TxGain_dB(:);

                if ismember('RFOutPinCorrected_dBm', T.Properties.VariableNames)
                    rfOutPinCal = T.RFOutPinCorrected_dBm(:);
                else
                    error('No RFOutPinCorrected_dBm column found in upconverter calibration CSV.');
                end

                if ismember('RFOutAfterFilterCorrected_dBm', T.Properties.VariableNames)
                    rfAfterFilterCal = T.RFOutAfterFilterCorrected_dBm(:);
                else
                    rfAfterFilterCal = rfOutPinCal - rfOutFilterInsertionLoss_dB;
                end

                if ismember('UpconverterGain_dB', T.Properties.VariableNames)
                    upGainCal = T.UpconverterGain_dB(:);
                else
                    upGainCal = nan(size(rfOutPinCal));
                end

                if ismember('UpconverterGainCompression_dB', T.Properties.VariableNames)
                    upCompCal = T.UpconverterGainCompression_dB(:);
                else
                    upCompCal = nan(size(rfOutPinCal));
                end

                [txCal, order] = sort(txCal);
                rfOutPinCal = rfOutPinCal(order);
                rfAfterFilterCal = rfAfterFilterCal(order);
                upGainCal = upGainCal(order);
                upCompCal = upCompCal(order);

                RFOutPinEstimated_dBm = interp1(txCal, rfOutPinCal, txGainPlan_dB, 'linear', 'extrap');
                RFOutAfterFilterEstimated_dBm = interp1(txCal, rfAfterFilterCal, txGainPlan_dB, 'linear', 'extrap');
                if any(isfinite(upGainCal))
                    UpconverterGainEstimated_dB = interp1(txCal, upGainCal, txGainPlan_dB, 'linear', 'extrap');
                else
                    UpconverterGainEstimated_dB = RFOutPinEstimated_dBm - upconverterInputEstimated_dBm;
                end
                if any(isfinite(upCompCal))
                    UpconverterCompressionEstimated_dB = interp1(txCal, upCompCal, txGainPlan_dB, 'linear', 'extrap');
                end
                modeUsed = "csv_interpolation:" + string(fileFound);
                return;
            catch ME
                warning("No se pudo usar CSV upconverter. Se usara fallback. Error: %s", ME.message);
            end
        end
    end

    UpconverterGainEstimated_dB(:) = upconverterSmallSignalGainFallback_dB;
    RFOutPinEstimated_dBm = upconverterInputEstimated_dBm + upconverterSmallSignalGainFallback_dB;
    RFOutAfterFilterEstimated_dBm = RFOutPinEstimated_dBm - rfOutFilterInsertionLoss_dB;
    UpconverterCompressionEstimated_dB(:) = 0;
end

function fileFound = findCalibrationFile(fileName)
    candidateFiles = strings(0,1);
    candidateFiles(end+1,1) = string(fileName);
    candidateFiles(end+1,1) = fullfile(pwd, string(fileName));

    scriptDir = fileparts(mfilename("fullpath"));
    if strlength(string(scriptDir)) > 0
        candidateFiles(end+1,1) = fullfile(scriptDir, string(fileName));
        candidateFiles(end+1,1) = fullfile(fileparts(scriptDir), "baseline", string(fileName));
        candidateFiles(end+1,1) = fullfile(fileparts(scriptDir), "data", string(fileName));
        candidateFiles(end+1,1) = fullfile(fileparts(scriptDir), "data", "EXP004E_CMP_26GHz-Link_TX_ONLY_UPCONVERTER_v1", "processed", string(fileName));
        candidateFiles(end+1,1) = fullfile(fileparts(scriptDir), "data", "EXP001_CMP_26GHz-Link_TX_ONLY_GAIN_BGU_v2", "processed", string(fileName));
    end

    fileFound = "";
    for k = 1:numel(candidateFiles)
        if exist(candidateFiles(k), "file")
            fileFound = candidateFiles(k);
            return;
        end
    end
end

function [powerValues_dB, voltageValues_V, adcValues_raw, nReceived, nInvalid] = readSTM32PowerBlock_EXP005( ...
    stm, fidPower, pointIndex, txGain, plutoOutCalibrated_dBm, bguOutputEstimated_dBm, ...
    upconverterInputEstimated_dBm, rfOutAfterFilterEstimated_dBm, rfLoopbackAttenuator_dB, ...
    downconverterRFInputEstimated_dBm, centerFrequency, dutName, measurementPoint, powerScaleFactor, PAPR_dB, ...
    ifOutMeterProtectionAttenuator_dB, ifOutMeasurementCorrection_dB)

    nReceived = 0;
    nInvalid  = 0;
    gotEnd    = false;
    powerValues_dB = [];
    voltageValues_V = [];
    adcValues_raw = [];

    while ~gotEnd
        line = strtrim(string(readline(stm)));

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
                    voltageValues_V(end+1,1) = voltage_V; %#ok<AGROW>
                    adcValues_raw(end+1,1) = adc_raw; %#ok<AGROW>
                end

                pc_timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));

                fprintf(fidPower, "%s,%d,%.2f,%.6f,%.6f,%.6f,%.6f,%.2f,%.6f,%.0f,%s,%s,%.6f,%.6f,%.2f,%.2f,%.0f,%.0f,%.9f,%.6f,%s\n", ...
                    pc_timestamp, ...
                    pointIndex, ...
                    txGain, ...
                    plutoOutCalibrated_dBm, ...
                    bguOutputEstimated_dBm, ...
                    upconverterInputEstimated_dBm, ...
                    rfOutAfterFilterEstimated_dBm, ...
                    rfLoopbackAttenuator_dB, ...
                    downconverterRFInputEstimated_dBm, ...
                    centerFrequency, ...
                    sanitizeCsvField(dutName), ...
                    sanitizeCsvField(measurementPoint), ...
                    powerScaleFactor, ...
                    PAPR_dB, ...
                    ifOutMeterProtectionAttenuator_dB, ...
                    ifOutMeasurementCorrection_dB, ...
                    stm32_time_ms, ...
                    adc_raw, ...
                    voltage_V, ...
                    power_dB, ...
                    sanitizeCsvField(line));

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
