function T=reprocesar_ACPR_b31(runDir)
% SOLO offline. Ejemplo: reprocesar_ACPR_b31('.../data/EXP016_...')
C=configuracion_b31();
results=dir(fullfile(runDir,'processed','*_results.mat'));
assert(numel(results)==1,'Seleccionar una corrida completa EXP015/016/017 con results.mat');
S=load(fullfile(results(1).folder,results(1).name),'sampleRate');fs=S.sampleRate;
files=dir(fullfile(runDir,'raw','*attempt*.mat'));rows=struct([]);
for k=1:numel(files)
 s=load(fullfile(files(k).folder,files(k).name),'rxCapture');
 A=acpr_observado_b31(s.rxCapture,fs,C);
 rows(k)=struct('capture',string(files(k).name),'SampleRate_Hz',fs, ...
  'RX_raw_dBFS',10*log10(mean(abs(s.rxCapture).^2)+eps), ...
  'lower_observed_dBc',A.observedLower,'upper_observed_dBc',A.observedUpper, ...
  'total_observed_dBc',A.observedTotal,'validated',A.validated, ...
  'lower_validated_dBc',A.lower,'upper_validated_dBc',A.upper,'total_validated_dBc',A.total); %#ok<AGROW>
end
assert(~isempty(rows),'No hay capturas IQ brutas');T=struct2table(rows);
writetable(T,fullfile(runDir,'processed','ACPR_IQ_BRUTO_B31.csv'));
save(fullfile(runDir,'processed','ACPR_procedencia_B31.mat'),'C','fs');
disp(T);
end
