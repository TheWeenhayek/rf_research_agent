function C=configuracion_b31()
% Unidades: ganancias/atenuaciones dB; potencias dBm; pico digital adimensional.
C.root=fileparts(fileparts(mfilename('fullpath')));
C.peak=0.8; % REQUISITO FIJO. No cambiar entre etapas.
C.fs=[]; % Tasa AUTOMATICA en caracterizacion y EVM.
C.fsACPR=61.44e6; % Solo EXP016/017; no acredita banda analogica.
C.fc=5e9; C.serialPort="COM12"; C.serialBaud=209700;
C.rutaEVM="C:\Users\jpfer\OneDrive\Documentos\MATLAB\Examples\R2024b\5g\NRWaveformCaptureAndAnalysisWithSDRExample";
C.txDSA_dB=5; C.rxDSA_dB=15; % Ajustar fisicamente en ACE. No lo controla MATLAB.
C.loopbackAttenuation_dB=20; % Atenuador RF fisico DESPUES del filtro.
C.bguProtection_dB=6; C.rfMeterProtection_dB=20; C.ifMeterProtection_dB=0;
C.filterLoss_dB=3; % Sustituir por perdida medida si difiere.
C.rxGain=8; % El punto TX se edita en la linea 51 de EXP015/016/017.
C.targetCompression_dB=0.5;
C.evmGains=(-34:0.5:-20).'; C.linearGains=[-32 -30 -28];
C.captureSeconds=0.08; C.settleSeconds=0.8;
C.rxPeakLimit_dBFS=-3; C.minSync=0.95;
C.verifiedRxUsefulBW_Hz=NaN; % SOLO completar con evidencia de respuesta medida.
C.evidenceRxBW=""; % Ruta o descripcion de esa medicion; no basta fijar 60e6.
C.lambdaNuevo=0.05; C.deltaNuevo=0.1; % En coordenadas de columnas normalizadas.
assert(C.peak==0.8,'El Power Scale Factor debe conservarse en 0.8');
assert(C.txDSA_dB==5,'Los nombres estandarizados de esta entrega corresponden a TX DSA=5 dB');
end
