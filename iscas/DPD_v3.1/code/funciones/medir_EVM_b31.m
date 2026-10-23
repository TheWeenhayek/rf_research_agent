function medir_EVM_b31(sincronizar,tasaAncha)
C=configuracion_b31();
if tasaAncha,C.fs=C.fsACPR;end
if isfolder(C.rutaEVM),addpath(C.rutaEVM);end
assert(exist('hNRDownlinkEVM','file')==2,'Configurar rutaEVM al auxiliar hNRDownlinkEVM del ejemplo MATLAB');
base=fullfile(C.root,'baseline');
assert(isfile(fullfile(base,'Baseline_Downconverter_ObservationPath.csv')),'Completar EXP01-04 antes de conectar la cadena completa al RX');
obs=readtable(fullfile(base,'Baseline_Downconverter_ObservationPath.csv'));
assert(all(ismember({'TxGain_dB','DownconverterGainCompression_dB','BGUCompressionEstimated_dB','UpconverterCompressionEstimated_dB'},obs.Properties.VariableNames)),'Baseline de observacion incompatible');
% No extrapolar un nivel que no fue medido por EXP04.
gains=C.evmGains(C.evmGains>=min(obs.TxGain_dB)&C.evmGains<=max(obs.TxGain_dB));
dc=interp1(obs.TxGain_dB,obs.DownconverterGainCompression_dB,gains,'linear');
gains=gains(isfinite(dc)&abs(dc)<=0.2);
assert(~isempty(gains),'Sin niveles de observacion lineal: revisar EXP03-04, DSA RX y atenuador RF');
tag="EXP05_DIRECTA";if sincronizar,tag="EXP06_SYNC";end
if tasaAncha,tag="EXP06B_SYNC_61M44";end
out=fullfile(C.root,'data',tag+"_"+string(datetime('now','Format','yyyyMMdd_HHmmss_SSS')));
rawDir=fullfile(out,'raw'); processedDir=fullfile(out,'processed'); mkdir(rawDir);mkdir(processedDir);
rng(3101);[x,cfg,fs]=generar_senal_b31(C);
save(fullfile(processedDir,'configuracion_y_senal.mat'),'C','cfg','x','fs','sincronizar','-v7.3');
tx=sdrtx('Pluto');tx.BasebandSampleRate=fs;tx.CenterFrequency=C.fc;tx.Gain=-80;
cleanupTX=onCleanup(@() apagar_b31(tx)); %#ok<NASGU>
rx=sdrrx('Pluto');rx.BasebandSampleRate=fs;rx.CenterFrequency=C.fc;
rx.OutputDataType='double';rx.GainSource='Manual';rx.Gain=C.rxGain;
cleanupRX=onCleanup(@() release(rx)); %#ok<NASGU>
stm=serialport(C.serialPort,C.serialBaud,'Timeout',2);configureTerminator(stm,'LF');flush(stm);
fid=fopen(fullfile(rawDir,'stm32-meter-raw.csv'),'w');assert(fid>0);
cleanLog=onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid,'pc_timestamp,label,iteration,txGain_dB,rxGain_dB,stm32_time_ms,adc_raw,voltage_V,power_dB_meter,raw_line\n');
evmCfg=struct('PlotEVM',false,'DisplayEVM',false,'SampleRate',fs,'IQImbalance',true, ...
 'TargetRNTIs',0,'CorrectCoarseFO',true,'CorrectFineFO',true,'ExcludeDC',true);
rows=struct([]);
for k=1:numel(gains)
 gain=gains(k);tx.Gain=gain;transmitRepeat(tx,x);pause(C.settleSeconds);
 y=capture(rx,C.captureSeconds,'Seconds');y=y(:);
 save(fullfile(rawDir,sprintf('capture_%03d.mat',k)),'x','y','gain','fs','C','-v7.3');
 meter=medir_potencia_STM32(struct(),stm,true,gain,C.rxGain,50,fid,string(k),k);
 ai=struct('syncMetric',NaN); aligned=[]; errSync="";evmError="";
 validSync=~sincronizar;
 if sincronizar
  try
   [ai,ad]=robustAlignTxRxForDPD(x,y,fs,16,4000,0.05,1);
   aligned=ad.y_cfo_corrected(:);validSync=ai.syncMetric>=C.minSync;
  catch ME,errSync=string(ME.message);end
 else,aligned=y;
 end
 evm=NaN;eqSymb=[];refSymb=[];
 if ~isempty(aligned)
  try
   N=min(round(fs*10e-3),numel(aligned));
   [evmInfo,eqSymb,refSymb]=hNRDownlinkEVM(cfg,aligned(1:N),evmCfg);
   evm=100*evmInfo.PDSCH.OverallEVM.RMS;
  catch ME,evmError=string(ME.message);end
 end
 power=10*log10(mean(abs(y).^2)+eps);peak=20*log10(max(abs(y))+eps);
 if sincronizar && validSync,power=ai.rxPower_dBFS;peak=ai.peakRx_dBFS;end
 A=acpr_observado_b31(y,fs,C);
 r=struct('TxGain_dB',gain,'RxGain_dB',C.rxGain,'SampleRate_Hz',fs,'PowerScaleFactor',C.peak, ...
  'RxPower_dBFS',power,'RxPeak_dBFS',peak,'Power_mean_dB_stm32',meter.meterPower_dBm, ...
  'EVM_NR_Aligned_pct',evm,'ACPR_dBc',A.total,'ACPR_observed_dBc',A.observedTotal, ...
  'ACPR_lower_observed_dBc',A.observedLower,'ACPR_upper_observed_dBc',A.observedUpper, ...
  'ACPR_validated',A.validated,'SyncMetric',ai.syncMetric,'ExternalAlignment',sincronizar, ...
  'Accepted',validSync&&isfinite(evm)&&peak<C.rxPeakLimit_dBFS);
 if ~sincronizar
  r.EVM_NR_Aligned_pct=NaN;r.EVM_NR_Direct_pct=evm;
 else,r.EVM_NR_Direct_pct=NaN;end
 rows(k)=r; %#ok<AGROW>
 save(fullfile(processedDir,sprintf('measurement_%03d.mat',k)),'r','meter','ai','aligned','eqSymb','refSymb','errSync','evmError','A');
 writetable(struct2table(rows),fullfile(processedDir,'mediciones.csv'));
 fprintf('TX %.2f dB | EVM NR %.3f %% | RX %.3f dBFS | sync %.4f\n',gain,evm,power,ai.syncMetric);
end
T=struct2table(rows);
assert(nnz(T.Accepted)>=3,'Menos de tres puntos EVM validos: se conservan resultados, pero no se reemplaza baseline');
if ~sincronizar
 publicar_baseline(fullfile(processedDir,'mediciones.csv'),fullfile(base,'Baseline_EVM_directa.csv'));
 return;
end
% Referencia con nombres compatibles con el lector historico EXP015.
refFile=fullfile(processedDir,tag+"_OFFICIAL_NODPD_REFERENCE.csv");writetable(T,refFile);
if tasaAncha
 publicar_baseline(refFile,fullfile(base,'Referencia_sin_DPD_61M44.csv'));
 return;
end
publicar_baseline(refFile,fullfile(base,'Referencia_sin_DPD_automatica.csv'));
T.BGUCompression_dB=interp1(obs.TxGain_dB,obs.BGUCompressionEstimated_dB,T.TxGain_dB,'linear');
T.UpconverterCompression_dB=interp1(obs.TxGain_dB,obs.UpconverterCompressionEstimated_dB,T.TxGain_dB,'linear');
T.DownconverterCompression_dB=interp1(obs.TxGain_dB,obs.DownconverterGainCompression_dB,T.TxGain_dB,'linear');
linear=ismember(T.TxGain_dB,C.linearGains(:)) & T.Accepted;
T.GlobalCompression_IQ_dB=nan(height(T),1);T.GlobalCompression_meter_dB=nan(height(T),1);
if nnz(linear)>=3
 q=polyfit(T.TxGain_dB(linear),T.RxPower_dBFS(linear),1);
 T.GlobalCompression_IQ_dB=polyval(q,T.TxGain_dB)-T.RxPower_dBFS;
 m=linear&isfinite(T.Power_mean_dB_stm32);
 if nnz(m)>=3
  q=polyfit(T.TxGain_dB(m),T.Power_mean_dB_stm32(m),1);
  T.GlobalCompression_meter_dB=polyval(q,T.TxGain_dB)-T.Power_mean_dB_stm32;
 end
else
 warning('No hay tres referencias lineales validas para compresion global; revisar linearGains');
end
writetable(T,fullfile(processedDir,'compresion_y_punto.csv'));
publicar_baseline(fullfile(processedDir,'compresion_y_punto.csv'),fullfile(base,'Baseline_Cadena_Completa.csv'));
candidate=T.Accepted & abs(T.BGUCompression_dB)<=0.2 & abs(T.DownconverterCompression_dB)<=0.2 & ...
 T.UpconverterCompression_dB>=C.targetCompression_dB & T.UpconverterCompression_dB<=C.targetCompression_dB+0.25;
point=fullfile(base,'Punto_operacion.mat');
if ~any(candidate)
 if isfile(point)
  hist=fullfile(base,'historial');if ~isfolder(hist),mkdir(hist);end
  movefile(point,fullfile(hist,"Punto_no_reutilizar_"+string(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))+".mat"));
 end
 warning('No se publico punto: no hay candidato con BGU/RX lineales y compresion objetivo del upconverter. Revisar mediciones; opcion manual documentada.');return;
end
idx=find(candidate,1,'first');txGain=T.TxGain_dB(idx);Cguardada=C;
provenance="Estimacion de baselines actuales EXP01-04 y EVM sincronizada EXP06; no identifica componente interno";
temp=fullfile(processedDir,'Punto_operacion.mat');save(temp,'txGain','Cguardada','idx','T','provenance');
publicar_baseline(temp,point);
fprintf('Punto publicado: TX %.2f dB, pico original 0.8, compresion upconverter estimada %.3f dB\n',txGain,T.UpconverterCompression_dB(idx));
end

function apagar_b31(tx)
try,tx.Gain=-80;release(tx);catch,end
end
