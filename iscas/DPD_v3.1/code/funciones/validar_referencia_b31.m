function validar_referencia_b31(file,fs)
C=configuracion_b31();
if isfolder(C.rutaEVM),addpath(C.rutaEVM);end
assert(strlength(string(file))>0 && isfile(file),'Falta referencia: ejecutar EXP06 antes de EXP015, o EXP06B antes de EXP016/017');
T=readtable(file);
assert(all(ismember({'SampleRate_Hz','PowerScaleFactor','RxGain_dB'},T.Properties.VariableNames)), ...
 'Referencia sin procedencia B3.1: repetir EXP06/06B');
assert(all(T.SampleRate_Hz==fs),'Tasa incompatible con referencia: ejecutar EXP06 para tasa automatica o EXP06B para 61.44 MS/s');
assert(all(T.PowerScaleFactor==0.8) && all(T.RxGain_dB==8),'Referencia incompatible: se requiere pico original 0.8 y RX=8 dB');
assert(any(T.Accepted & isfinite(T.EVM_NR_Aligned_pct)),'Referencia sin EVM sincronizada valida');
end
