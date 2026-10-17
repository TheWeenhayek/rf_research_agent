% EXP036 - Repetibilidad GMP
% Autonomo: copiar este .m a DPDv2/code. No necesita otros .m de esta entrega.
% Leer primero LEEME_EXPERIMENTOS_GMP.md. No ejecuta comprobaciones de equipos.
clear; close all; clc;
C=struct();
C.exp=36; C.stage="repeat";
% PUNTO DE TRABAJO: valores heredados de EXP010; editar con los medidos hoy.
C.txGain=-22.25; C.rxGain=8; C.txDSA_dB=5;
C.fc=5e9; C.device="Pluto"; C.idleGain=-80; C.peak=0.8;
C.sampleRate=61.44e6; % canal NR sigue en 20 MHz; no cambia firmware
C.useSTM32=true; C.serialPort="COM12"; C.serialBaud=209700;
C.captureTime_s=80e-3; C.maxCaptureAttempts=5;
C.evmRetryThreshold_pct=60; C.minSyncMetric=0.95;
C.alignDecimationFactor=16; C.fineSearchHalfWindow_samples=4000;
C.phaseFitMagnitudeThreshold=0.05; C.numFramesForAlign=1;
C.examplePath="C:\Users\jpfer\OneDrive\Documentos\MATLAB\Examples\R2024b\5g\NRWaveformCaptureAndAnalysisWithSDRExample";
% Banda util YA conocida, si existe. NaN: ACPR completo no reportable; no bloquea DPD.
C.rxUsefulBW_Hz=NaN;
C.lambda=0.05; C.mu=0.08; C.delta=0.1; C.beta=1;
C.lambdas=[0.005 0.05 0.5]; C.mus=[0.08 0.2 1]; C.deltas=[0.03 0.1 0.3];
C.iterations=5; C.repeats=1; C.finalRepeats=3;
C.selectionIterations=3; C.shortlistCount=2; C.maxFitRows=60000;
C.structureTieEVM_pct=0.1;
% EXP031 mantiene parametros de ajuste de EXP010 para su piloto GMP.
C.pilotLambdaRel=0.01; C.pilotMu=0.12; C.pilotIterations=10;
C.maxTXPeak=0.95; C.maxPAPRExtra_dB=6.5; C.maxPeakRatio=1.10;
C.rxPeakLimit_dBFS=-3; C.maxPowerDrop_dB=1.8; C.maxPowerRise_dB=1;
C.maxEVMDegradation_pct=0.5; C.maxACPRDegradation_dB=0.5;
C.validationSeed=8317;
C.referenceGains=sort(unique([C.txGain+(-4:0.5:2),C.txGain]));
% Si se eligen manualmente, usar un MAT producido por EXP032/035/036.
C.structureFile=""; C.parametersFile=""; C.coefficientsFile="";
scriptDir=fileparts(mfilename('fullpath')); if isempty(scriptDir), scriptDir=pwd; end
C.projectDir=fileparts(scriptDir); C.baselineDir=fullfile(C.projectDir,'baseline');
C.stateDir=fullfile(C.projectDir,'data','GMP_EXP031_037');
runCampaign(C);

function runCampaign(C)
if ~isfolder(C.stateDir), mkdir(C.stateDir); end
timeTag=string(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
output=fullfile(C.stateDir,sprintf('EXP%03d_',C.exp)+timeTag);
rawDir=fullfile(output,'raw'); processedDir=fullfile(output,'processed');
mkdir(output); mkdir(rawDir); mkdir(processedDir);
C.runTag=timeTag;
% Una corrida fallida no debe reutilizar silenciosamente una eleccion antigua.
stateName="";
if C.stage=="structures", stateName="ultima_estructura.mat"; end
if C.stage=="sensitivity", stateName="ultimos_parametros.mat"; end
if C.stage=="repeat", stateName="ultima_repetibilidad.mat"; end
if strlength(stateName)>0
 statePath=fullfile(C.stateDir,stateName);
 if isfile(statePath), copyfile(statePath,fullfile(processedDir,'estado_anterior.mat')); end
 status="en_curso_sin_resultado_publicado"; save(statePath,'status','C');
end
if isfolder(C.examplePath), addpath(C.examplePath); end
examplePath=fullfile(matlabroot,'examples','5g','NRWaveformCaptureAndAnalysisWithSDRExample');
if isfolder(examplePath), addpath(examplePath); end
models=modelCatalog();
[x,cfgDLFRC,sampleRate]=createWaveform(C,false);
assert(sampleRate==C.sampleRate && cfgDLFRC.ChannelBandwidth==20);
save(fullfile(processedDir,'configuracion_y_senal.mat'),'C','models','x','cfgDLFRC','sampleRate','-v7.3');
acprCoverage(C.rxUsefulBW_Hz);
% Alias de nombres para conservar literalmente la inicializacion de EXP010.
deviceName=C.device; centerFrequency=C.fc; idleGain_dB=C.idleGain;
fixedTxGain_Pluto=C.txGain; fixedRxGain_Pluto=C.rxGain;
useSTM32PowerMeter=C.useSTM32; serialPort=C.serialPort; serialBaud=C.serialBaud;
serialTerminator="LF"; serialTimeout_s=2; doPingTest=true;
csvMeterRawFile=fullfile(rawDir,'stm32-meter-raw.csv'); fidMeterRaw=-1;
cfgEVM = struct();
cfgEVM.PlotEVM    = false;
cfgEVM.DisplayEVM = false;
cfgEVM.SampleRate = sampleRate;
cfgEVM.IQImbalance = true;
cfgEVM.TargetRNTIs = 0;
cfgEVM.CorrectCoarseFO = true;
cfgEVM.CorrectFineFO   = true;
cfgEVM.ExcludeDC = true;
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

cleanupObj = onCleanup(@() cleanupSDR(sdrTransmitter, sdrReceiver, idleGain_dB)); %#ok<NASGU>
stm = [];
if useSTM32PowerMeter
    try
        fprintf("\nOpening STM32 power meter on %s...\n", serialPort);
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

        fidMeterRaw = fopen(csvMeterRawFile, "w");
        if fidMeterRaw < 0
            error("Could not create STM32 raw CSV: %s", csvMeterRawFile);
        end
        fprintf(fidMeterRaw, "pc_timestamp,label,iteration,txGain_dB,rxGain_dB,stm32_time_ms,adc_raw,voltage_V,power_dB_meter,raw_line\n");
    catch ME
        warning("Could not initialize STM32 power meter. Continuing without meter: %s", ME.message);
        useSTM32PowerMeter = false;
        stm = [];
    end
end
meterCleanup=onCleanup(@() closeMeterLog(fidMeterRaw)); %#ok<NASGU>
reference=[]; rows=struct([]); frozen=struct([]);
if C.stage=="pilot"
 jobs=makeJob(3,"pilot",C.pilotLambdaRel,Inf,C.pilotMu);
 C.iterations=C.pilotIterations;
elseif C.stage=="structures"
 reference=measureReference(C.referenceGains,x,cfgDLFRC,"referencia");
 sdrTransmitter.Gain=C.txGain;
 train=measure(x,cfgDLFRC,"seleccion_train",x);
 independent=measure(x,cfgDLFRC,"seleccion_independiente",x);
 assert(train.usable && independent.usable,'Capturas no utilizables para seleccionar GMP');
 shortlist=screenModels(train,independent,x,models,C,processedDir);
 jobs=struct([]);
 for k=shortlist(:).'
  jobs=appendStruct(jobs,makeJob(k,"blend",C.lambda,Inf,C.mu));
  jobs=appendStruct(jobs,makeJob(k,"bounded",C.lambda,C.delta,1));
 end
 C.iterations=C.selectionIterations;
elseif C.stage=="validation"
 state=loadRequired(C.coefficientsFile,fullfile(C.stateDir,'ultima_repetibilidad.mat'));
 checkSettings(state.C,C); frozen=state.frozen;
 assert(~isempty(frozen),'EXP036 no produjo coeficientes aceptados para validar');
 [x,cfgDLFRC,sampleRate]=createWaveform(C,true); %#ok<ASGLU>
 save(fullfile(processedDir,'senal_independiente.mat'),'x','cfgDLFRC','C','-v7.3');
 reference=measureReference(C.referenceGains,x,cfgDLFRC,"referencia_nueva");
 evalRows=struct([]);
 for j=1:numel(frozen)
  item=frozen(j);
  w=applyGMP(x,item.coeff,item.model,item.scales);
  [pass,peak,papr]=waveformGuard(w,x,C);
  if ~pass
   save(fullfile(processedDir,sprintf('validacion_%02d_rechazo_TX.mat',j)),'item','peak','papr');
   continue;
  end
  sdrTransmitter.Gain=C.txGain;
  before=measure(x,cfgDLFRC,sprintf('validacion_%02d_antes',j),x);
  post=measure(w,cfgDLFRC,sprintf('validacion_%02d_DPD',j),x);
  after=measure(x,cfgDLFRC,sprintf('validacion_%02d_despues',j),x);
  r=resultRow(post); r.job=j; r.method=item.job.method; r.lambda=item.job.lambda;
  r.mu=item.job.mu; r.delta=item.job.delta; r.modelID=item.model.ID;
  r=equalPower(r,reference); evalRows=appendStruct(evalRows,r);
  writetable(struct2table(evalRows),fullfile(processedDir,'validacion_senal_nueva.csv'));
  post=compactResult(post); before=compactResult(before); after=compactResult(after);
  save(fullfile(processedDir,sprintf('validacion_%02d.mat',j)),'item','w','x','post','before','after','C','-v7.3');
 end
 disp("EXP037 terminado: "+output); return;
else
 state=loadRequired(C.structureFile,fullfile(C.stateDir,'ultima_estructura.mat'));
 checkSettings(state.C,C); models=state.models; selectedModel=state.selectedModel;
 reference=state.reference;
 if C.stage=="blend"
  jobs=makeJob(selectedModel,"blend",C.lambda,Inf,C.mu);
 elseif C.stage=="bounded"
  jobs=makeJob(selectedModel,"bounded",C.lambda,C.delta,1);
 elseif C.stage=="sensitivity"
  jobs=struct([]);
  for la=C.lambdas
   for mu=C.mus, jobs=appendStruct(jobs,makeJob(selectedModel,"blend",la,Inf,mu)); end
   for de=C.deltas, jobs=appendStruct(jobs,makeJob(selectedModel,"bounded",la,de,1)); end
  end
 elseif C.stage=="repeat"
  params=loadRequired(C.parametersFile,fullfile(C.stateDir,'ultimos_parametros.mat'));
  checkSettings(params.C,C); jobs=params.jobs;
  assert(all([jobs.modelIndex]==selectedModel),'La estructura cambio desde EXP035');
  C.repeats=C.finalRepeats;
 else
  error('Etapa desconocida');
 end
end

rng(91031+C.exp); order=randperm(numel(jobs)*C.repeats);
save(fullfile(processedDir,'plan_ejecucion.mat'),'C','models','jobs','order');
for index=order
 j=mod(index-1,numel(jobs))+1; rep=floor((index-1)/numel(jobs))+1;
 job=jobs(j); p=models(job.modelIndex);
 tag=sprintf('j%02d_r%02d',j,rep);
 sdrTransmitter.Gain=C.txGain;
 before=measure(x,cfgDLFRC,tag+"_sinDPD_antes",x);
 if ~before.usable, recordFailure(tag,"baseline no utilizable",job); continue; end
 [B,~,~,labels]=buildGMPMatrix(x,p);
 scales=max(sqrt(mean(abs(B).^2,1)),1e-12); clear B;
 if job.method=="pilot", scales=ones(size(scales)); end
 coeff=zeros(numel(scales),1); coeff(1)=scales(1);
 u=x; R=before; feedbackGain=(x'*R.rxAligned)/(x'*x+eps);
 basePAPR=10*log10(max(abs(x)).^2/mean(abs(x).^2));
 finalAccepted=false;
 for iteration=1:C.iterations
  y=R.rxAligned/(feedbackGain+eps);
  [B,a,b]=buildGMPMatrix(y,p); target=u(a:b); X=B./scales; clear B;
  idx=abs(y(a:b))>0.08*max(abs(y(a:b)));
  if nnz(idx)>size(X,2), X=X(idx,:); target=target(idx); end
  t=tic;
  if job.method=="pilot"
   effective=job.lambda*mean(sum(abs(X).^2,1));
   hat=[X;sqrt(effective)*eye(size(X,2))]\[target;zeros(size(X,2),1)];
   if iteration==1, candidate=hat; else, candidate=(1-job.mu)*coeff+job.mu*hat; end
   info=struct('cost',mean(abs(target-X*candidate).^2)+effective/size(X,1)*norm(candidate)^2, ...
    'condition',cond(X),'multiplier',0,'stepNorm',norm(candidate-coeff));
  else
   [fit,info]=solveBoundedRidge(X,target,coeff,job.lambda,job.delta);
   if job.method=="blend"
    candidate=(1-job.mu)*coeff+job.mu*fit;
    info.cost=mean(abs(target-X*candidate).^2)+job.lambda*norm(candidate)^2;
   else, candidate=fit;
   end
  end
  info.solveSeconds=toc(t); rawDPD=applyGMP(x,candidate,p,scales);
  normalizationFactor=1;
  if job.method=="pilot"
   txDPD=normalizeDPDWaveform(rawDPD,x,C.maxPeakRatio);
   normalizationFactor=real((rawDPD'*txDPD)/(rawDPD'*rawDPD+eps));
   info.costBeforeNormalization=info.cost;
   candidate=candidate*normalizationFactor; % coordenadas de la senal realmente emitida
   info.cost=mean(abs(target-X*candidate).^2)+effective/size(X,1)*norm(candidate)^2;
  else, txDPD=rawDPD;
  end
  info.stepApplied=norm(candidate-coeff); info.coeffNorm=norm(candidate);
  [guard,peak,papr]=waveformGuard(txDPD,x,C);
  if ~guard || papr>basePAPR+C.maxPAPRExtra_dB
   recordFailure(tag+"_i"+iteration,"pico o PAPR TX",job);
   save(fullfile(processedDir,tag+"_i"+iteration+"_propuesta_rechazada.mat"), ...
    'candidate','coeff','job','p','scales','info','peak','papr','normalizationFactor','-v7.3');
   break;
  end
  validationMSE=NaN;
  if job.method~="pilot"
   % Holdout del identificador bajo la misma entrada usada para su ajuste.
   independent=measure(u,cfgDLFRC,tag+"_i"+iteration+"_independiente",x);
   if independent.usable
    [V,aa,bb]=buildGMPMatrix(independent.rxAligned/(feedbackGain+eps),p);
    validationMSE=mean(abs(u(aa:bb)-(V./scales)*candidate).^2);
   end
  else, independent=R;
  end
  post=measure(txDPD,cfgDLFRC,tag+"_i"+iteration+"_post",x);
  if ~post.usable || ~independent.usable
   recordFailure(tag+"_i"+iteration,"captura post no utilizable",job); break;
  end
  r=resultRow(post); r.job=j; r.repeat=rep; r.iteration=iteration;
  r.modelIndex=job.modelIndex; r.modelID=p.ID; r.coeffCount=numel(candidate);
  r.method=job.method; r.lambda=job.lambda; r.mu=job.mu; r.delta=job.delta;
  r.stepNorm=info.stepApplied; r.coeffNorm=norm(candidate); r.condition=info.condition;
  r.cost=info.cost; r.validationMSE=validationMSE; r.solveSeconds=info.solveSeconds;
  r.PAPR_dB=papr; r.peakTX=peak; r.normalizationFactor=normalizationFactor;
  powerChange=post.rxPower_dBFS-before.rxPower_dBFS;
  r.powerGuard=powerChange>=-C.maxPowerDrop_dB && powerChange<=C.maxPowerRise_dB;
  r.acprAvailable=post.acprValid && before.acprValid;
  spectralGuard=true;
  if r.acprAvailable
   spectralGuard=post.acprLower<=before.acprLower+C.maxACPRDegradation_dB && ...
    post.acprUpper<=before.acprUpper+C.maxACPRDegradation_dB;
  end
  r.accepted=r.powerGuard && spectralGuard && post.peakRx_dBFS<C.rxPeakLimit_dBFS && ...
   post.evmWaveformDesired_pct<=before.evmWaveformDesired_pct+C.maxEVMDegradation_pct;
  r=equalPower(r,reference); rows=appendStruct(rows,r);
  writetable(struct2table(rows),fullfile(processedDir,'iteraciones.csv'));
  coeffTable=table((1:numel(candidate)).',labels,real(candidate),imag(candidate), ...
   real(candidate./scales.'),imag(candidate./scales.'), ...
   'VariableNames',{'index','term','real_normalized','imag_normalized','real_raw','imag_raw'});
  writetable(coeffTable,fullfile(processedDir,tag+"_i"+iteration+"_coeficientes.csv"));
  actualInput=txDPD; previousInput=u; %#ok<NASGU>
  savedPost=compactResult(post); savedIndependent=compactResult(independent);
  save(fullfile(processedDir,tag+"_i"+iteration+"_estado.mat"), ...
   'candidate','coeff','job','p','scales','labels','info','feedbackGain','actualInput', ...
   'previousInput','savedPost','savedIndependent','normalizationFactor','C','-v7.3');
  if ~r.accepted, recordFailure(tag+"_i"+iteration,"guarda fisica",job); break; end
  coeff=candidate; u=txDPD; R=post;
  finalAccepted=iteration==C.iterations;
 end
 after=measure(x,cfgDLFRC,tag+"_sinDPD_despues",x); %#ok<NASGU>
 if finalAccepted
  item=struct('job',job,'repeat',rep,'coeff',coeff,'model',p,'scales',scales);
  frozen=appendStruct(frozen,item);
 end
end
if ~isempty(rows), T=struct2table(rows); else, T=table(); end
save(fullfile(processedDir,'resumen.mat'),'T','jobs','models','C','reference','frozen');
exportFigures(T,processedDir);
if C.stage=="structures"
 [ok,selectedModel,ranking]=chooseStructure(T,jobs,models,C);
 writetable(ranking,fullfile(processedDir,'seleccion_estructura.csv'));
 if ok
  save(fullfile(processedDir,'estructura_elegida.mat'),'selectedModel','models','reference','C','ranking');
  save(fullfile(C.stateDir,'ultima_estructura.mat'),'selectedModel','models','reference','C','ranking');
  fprintf('Estructura elegida: %s. Continuar con EXP033.\n',models(selectedModel).ID);
 else
  warning('No hay estructura ganadora comparable. Ver seleccion_estructura.csv; no se publica una eleccion.');
 end
elseif C.stage=="sensitivity"
 [ok,jobs,ranking]=chooseParameters(T,jobs,C);
 writetable(ranking,fullfile(processedDir,'seleccion_parametros.csv'));
 if ok
  save(fullfile(processedDir,'parametros_elegidos.mat'),'jobs','C','ranking');
  save(fullfile(C.stateDir,'ultimos_parametros.mat'),'jobs','C','ranking');
 else, warning('No se publican parametros: faltan corridas completas comparables en ambos metodos.');
 end
elseif C.stage=="repeat"
 save(fullfile(processedDir,'coeficientes_repetibilidad.mat'),'frozen','C');
 save(fullfile(C.stateDir,'ultima_repetibilidad.mat'),'frozen','C');
end
fprintf('\nEXP%03d terminado. Resultados: %s\n',C.exp,output);

 function result=measure(w,cfg,label,desired)
  % Misma transmision, espera y llamada de adquisicion que EXP010.
  transmitRepeat(sdrTransmitter,w); pause(0.8);
  result=captureAndMeasureWithRetry( ...
   sdrReceiver,w,cfg,cfgEVM,sampleRate, ...
   C.captureTime_s,round(C.captureTime_s*sampleRate),round(sampleRate*10e-3), ...
   C.maxCaptureAttempts,C.evmRetryThreshold_pct,C.minSyncMetric, ...
   C.alignDecimationFactor,C.fineSearchHalfWindow_samples,C.phaseFitMagnitudeThreshold,C.numFramesForAlign, ...
   rawDir,true,string(label),sdrTransmitter.Gain,C.rxGain,C.txDSA_dB/0.5,C.txDSA_dB);
  iterationToken=regexp(char(label),'_i(\d+)_','tokens','once');
  meterIteration=0;
  if ~isempty(iterationToken), meterIteration=str2double(iterationToken{1}); end
  result=attachMeterMeasurement(result,stm,useSTM32PowerMeter,sdrTransmitter.Gain,C.rxGain,50,fidMeterRaw,label,meterIteration);
  result.acprLower=NaN; result.acprUpper=NaN; result.acprValid=false;
  result.evmWaveformDesired_pct=NaN;
  if result.usable
   g=(desired'*result.rxAligned)/(desired'*desired+eps);
   result.evmWaveformDesired_pct=100*norm(result.rxAligned/(g+eps)-desired)/norm(desired);
   [result.acpr_dBc,result.acprLower,result.acprUpper,result.acprValid]=computeACPRCentered(result.rxAligned,sampleRate,20e6);
  end
  metadata=compactResult(result);
  save(fullfile(processedDir,string(label)+"_medicion.mat"),'metadata','C');
 end

 function reference=measureReference(gains,w,cfg,prefix)
  refRows=struct([]);
  for gain=gains
   sdrTransmitter.Gain=gain;
   result=measure(w,cfg,prefix+"_tx_"+string(gain),w);
   rr=resultRow(result); rr.txGain=gain; refRows=appendStruct(refRows,rr);
   reference=struct2table(refRows);
   writetable(reference,fullfile(processedDir,prefix+"_sin_DPD.csv"));
  end
  sdrTransmitter.Gain=C.txGain;
 end

 function recordFailure(tag,reason,job)
  item=struct('tag',tag,'reason',reason,'job',job,'time',datetime('now'));
  save(fullfile(processedDir,string(tag)+"_fallo.mat"),'item');
  fprintf('Corrida detenida [%s]: %s\n',tag,reason);
 end
end

function job=makeJob(model,method,lambda,delta,mu)
job=struct('modelIndex',model,'method',method,'lambda',lambda,'delta',delta,'mu',mu);
end

function list=appendStruct(list,item)
if isempty(list), list=item; else, list(end+1)=item; end
end

function checkSettings(saved,C)
fields={'txGain','rxGain','txDSA_dB','fc','sampleRate','peak'};
for k=1:numel(fields)
 field=fields{k}; assert(isequal(saved.(field),C.(field)),'Cambio %s respecto al estado anterior; repetir la etapa correspondiente',field);
end
end

function state=loadRequired(manual,automatic)
path=automatic; if strlength(manual)>0, path=manual; end
assert(isfile(path),'No existe el resultado anterior requerido: %s',path);
state=load(path);
assert(~isfield(state,'status'),'La ultima ejecucion no publico un resultado valido: %s. Revisar la corrida anterior.',path);
end

function r=resultRow(R)
r=struct('usable',R.usable,'EVM_NR_pct',R.evm_pct,'EVM_waveform_pct',R.evmWaveformDesired_pct, ...
 'rxPower_dBFS',R.rxPower_dBFS,'rxPeak_dBFS',R.peakRx_dBFS,'meterPower_dBm',R.meterPower_dBm, ...
 'meterVoltage_V',R.meterVoltage_V,'meterNValid',R.meterNValid, ...
 'ACPR_lower_dBc',R.acprLower,'ACPR_upper_dBc',R.acprUpper,'ACPR_total_dBc',R.acpr_dBc, ...
 'sync',R.syncMetric,'attempts',R.attemptCount,'time',datetime('now'));
end

function r=equalPower(r,reference)
r.eqEVM_gain=NaN; r.eqACPR_lower_gain=NaN; r.eqACPR_upper_gain=NaN;
if isempty(reference), return; end
good=reference.usable & isfinite(reference.rxPower_dBFS) & isfinite(reference.EVM_waveform_pct);
ref=reference(good,:); [p,~,g]=unique(ref.rxPower_dBFS);
if numel(p)<2 || r.rxPower_dBFS<min(p) || r.rxPower_dBFS>max(p), return; end
r.eqEVM_gain=interp1(p,accumarray(g,ref.EVM_waveform_pct,[],@mean),r.rxPower_dBFS)-r.EVM_waveform_pct;
if all(isfinite(ref.ACPR_lower_dBc)) && all(isfinite(ref.ACPR_upper_dBc))
 r.eqACPR_lower_gain=interp1(p,accumarray(g,ref.ACPR_lower_dBc,[],@mean),r.rxPower_dBFS)-r.ACPR_lower_dBc;
 r.eqACPR_upper_gain=interp1(p,accumarray(g,ref.ACPR_upper_dBc,[],@mean),r.rxPower_dBFS)-r.ACPR_upper_dBc;
end
end

function R=compactResult(R)
% El IQ crudo ya fue guardado por la rutina original. Evitar duplicarlo.
R.rawCapture=[]; R.rxAligned=[]; R.eqSymb=[]; R.refSymb=[];
end

function [ok,peak,papr]=waveformGuard(w,x,C)
peak=max(abs(w)); papr=10*log10(peak^2/mean(abs(w).^2));
ok=all(isfinite(w)) && peak<=C.maxTXPeak && papr<=10*log10(max(abs(x))^2/mean(abs(x).^2))+C.maxPAPRExtra_dB;
end

function closeMeterLog(fid)
if fid>0, fclose(fid); end
end

function value=acprCoverage(varargin)
persistent bandwidth;
if nargin>0, bandwidth=varargin{1}; end
if isempty(bandwidth), bandwidth=NaN; end
value=bandwidth;
end

function [total,lower,upper,valid]=computeACPRCentered(x,fs,bw)
total=NaN; lower=NaN; upper=NaN; valid=false;
if fs<=3*bw || ~(acprCoverage()>=3*bw), return; end
x=x(:); if numel(x)<1024, return; end
L=min(4096,numel(x));
[P,f]=pwelch(x-mean(x),hamming(L),[],32768,fs,'centered'); df=f(2)-f(1);
main=sum(P(f>=-bw/2 & f<bw/2))*df;
lo=sum(P(f>=-1.5*bw & f<-bw/2))*df;
hi=sum(P(f>=bw/2 & f<1.5*bw))*df;
if min([main lo hi])<=0, return; end
lower=10*log10(lo/main); upper=10*log10(hi/main); total=10*log10((lo+hi)/main); valid=true;
end

function exportFigures(T,folder)
if isempty(T) || ~ismember('iteration',T.Properties.VariableNames), return; end
try
 fig=figure('Visible','off'); tiledlayout(2,2);
 pairs=[T.job T.repeat]; [list,~,group]=unique(pairs,'rows');
 fields={'EVM_waveform_pct','eqEVM_gain','stepNorm','rxPower_dBFS'};
 for k=1:4
  nexttile; hold on;
  for j=1:size(list,1), t=T(group==j,:); plot(t.iteration,t.(fields{k}),'-o'); end
  grid on; xlabel('Iteracion'); ylabel(fields{k},'Interpreter','none');
 end
 exportgraphics(fig,fullfile(folder,'evolucion.png')); close(fig);
catch err, warning('No se pudo exportar figura: %s',err.message); end
end

function [txWaveform,cfgDLFRC,sampleRate]=createWaveform(C,independentData)
powerScaleFactor=C.peak;
cfgDLFRC = nrDLCarrierConfig;
cfgDLFRC.Label = 'DL-FRC-FR1-256QAM';
cfgDLFRC.FrequencyRange = 'FR1';
cfgDLFRC.ChannelBandwidth = 20;
cfgDLFRC.NCellID = 1;
cfgDLFRC.NumSubframes = 10;
cfgDLFRC.InitialNSubframe = 0;
cfgDLFRC.WindowingPercent = 0;
cfgDLFRC.CarrierFrequency = 0;
cfgDLFRC.SampleRate = C.sampleRate; % tasa explicita; el canal sigue en 20 MHz

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

if independentData
    rng(C.validationSeed);
    cfgDLFRC.PDSCH{1}.DataSource = randi([0 1],100003,1);
end
[waveform, info] = nrWaveformGenerator(cfgDLFRC);
sampleRate = info.ResourceGrids(1).Info.SampleRate;

txWaveform = waveform * (powerScaleFactor / max(abs(waveform)));
txWaveform = txWaveform(:);
end

function models=modelCatalog()
models=[struct('ID',"GMP_22coef_Orden7",'Ka',4,'La',4,'Kb',2,'Lb',3,'Mb',1,'Kc',0,'Lc',0,'Mc',0), ...
struct('ID',"GMP_26coef_Orden9",'Ka',5,'La',4,'Kb',2,'Lb',3,'Mb',1,'Kc',0,'Lc',0,'Mc',0), ...
struct('ID',"GMP_29coef_EnvolventeAdelantada",'Ka',5,'La',4,'Kb',2,'Lb',3,'Mb',1,'Kc',1,'Lc',3,'Mc',1), ...
struct('ID',"GMP_33coef_Orden11",'Ka',6,'La',4,'Kb',2,'Lb',3,'Mb',1,'Kc',1,'Lc',3,'Mc',1), ...
struct('ID',"GMP_37coef_MayorMemoria",'Ka',5,'La',5,'Kb',2,'Lb',4,'Mb',1,'Kc',1,'Lc',4,'Mc',1), ...
struct('ID',"GMP_35coef_MayorOrdenCruzado",'Ka',5,'La',4,'Kb',3,'Lb',3,'Mb',1,'Kc',2,'Lc',3,'Mc',1)];
end

function [X, nStart, nEnd, labels] = buildGMPMatrix(signal, p)
    % Build a reduced generalized-memory-polynomial basis.
    %
    % Aligned branch:
    %   x[n-l] * |x[n-l]|^(2k), k = 0,...,Ka-1
    %
    % Lagging-envelope branch:
    %   x[n-l] * |x[n-l-m]|^(2k), k = 1,...,Kb
    %
    % Leading-envelope branch:
    %   x[n-l] * |x[n-l+m]|^(2k), k = 1,...,Kc

    signal = signal(:);
    L = length(signal);

    validateGMPParameters(p);

    maxDelay = max([p.La-1, (p.Lb-1+p.Mb)*(p.Kb>0), (p.Lc-1)*(p.Kc>0), 0]);
    maxAdvance = p.Mc;

    nStart = 1 + maxDelay;
    nEnd = L - maxAdvance;

    if nEnd < nStart
        error('Signal is too short for the selected GMP delays/advances.');
    end

    N = nEnd - nStart + 1;
    nCoeff = p.Ka*p.La + p.Kb*p.Lb*p.Mb + p.Kc*p.Lc*p.Mc;

    X = complex(zeros(N, nCoeff));
    labels = strings(nCoeff,1);
    col = 1;

    % A branch: aligned Memory Polynomial terms.
    for l = 0:p.La-1
        s = signal(nStart-l:nEnd-l);
        for k = 0:p.Ka-1
            X(:,col) = s .* abs(s).^(2*k);
            labels(col) = sprintf("A_l%d_ord%d", l, 2*k+1);
            col = col + 1;
        end
    end

    % B branch: lagging-envelope cross terms.
    for l = 0:p.Lb-1
        sComplex = signal(nStart-l:nEnd-l);
        for m = 1:p.Mb
            sEnvelope = signal(nStart-l-m:nEnd-l-m);
            for k = 1:p.Kb
                X(:,col) = sComplex .* abs(sEnvelope).^(2*k);
                labels(col) = sprintf("B_l%d_m%d_ord%d", l, m, 2*k+1);
                col = col + 1;
            end
        end
    end

    % C branch: leading-envelope cross terms.
    for l = 0:p.Lc-1
        sComplex = signal(nStart-l:nEnd-l);
        for m = 1:p.Mc
            sEnvelope = signal(nStart-l+m:nEnd-l+m);
            for k = 1:p.Kc
                X(:,col) = sComplex .* abs(sEnvelope).^(2*k);
                labels(col) = sprintf("C_l%d_m%d_ord%d", l, m, 2*k+1);
                col = col + 1;
            end
        end
    end

    if col-1 ~= nCoeff
        error('Internal GMP coefficient-count mismatch: expected %d, built %d.', nCoeff, col-1);
    end
end


function validateGMPParameters(p)
    required = ["Ka","La","Kb","Lb","Mb","Kc","Lc","Mc"];
    for ii = 1:numel(required)
        name = required(ii);
        if ~isfield(p, name)
            error('Missing GMP parameter: %s', name);
        end
        value = p.(name);
        if ~isscalar(value) || ~isfinite(value) || value < 0 || value ~= floor(value)
            error('GMP parameter %s must be a nonnegative integer.', name);
        end
    end

    if p.Ka < 1 || p.La < 1
        error('Ka and La must be at least 1.');
    end

    if p.Kb > 0 && (p.Lb < 1 || p.Mb < 1)
        error('Lb and Mb must be at least 1 when Kb > 0.');
    end
    if p.Kb == 0 && (p.Lb ~= 0 || p.Mb ~= 0)
        error('Set Lb = Mb = 0 when Kb = 0.');
    end

    if p.Kc > 0 && (p.Lc < 1 || p.Mc < 1)
        error('Lc and Mc must be at least 1 when Kc > 0.');
    end
    if p.Kc == 0 && (p.Lc ~= 0 || p.Mc ~= 0)
        error('Set Lc = Mc = 0 when Kc = 0.');
    end
end


function y=applyGMP(x,c,p,s)
% Periodic extension is consistent with transmitRepeat; no identity edge splice.
x=x(:); h=max([p.La,p.Lb+p.Mb,p.Lc+p.Mc])+2;
z=x(mod((-h:numel(x)+h-1)',numel(x))+1);
[X,a,b]=buildGMPMatrix(z,p); idx=(a:b)';
keep=idx>=h+1 & idx<=h+numel(x);
y=(X(keep,:)./s)*c;
assert(numel(y)==numel(x));
end

function [next,info]=solveBoundedRidge(X,u,c,lambda,delta)
% Final coefficient ridge in frozen normalized coordinates, fixed radius.
assert(lambda>0 && delta>0 && all(isfinite(X(:))) && all(isfinite(u)));
N=size(X,1); P=size(X,2); A=X/sqrt(N); v=u/sqrt(N);
H=A'*A+lambda*eye(P); H=(H+H')/2; g=A'*v-H*c;
% QR for unconstrained ridge; Hermitian eigensystem for secular equation.
hat=[A;sqrt(lambda)*eye(P)]\[v;zeros(P,1)]; d=hat-c; eta=0;
if norm(d)>delta
    [V,D]=eig(H,'vector'); D=max(real(D),0); q=V'*g;
    lo=0; hi=max(1,norm(g)/delta);
    while norm(q./(D+hi))>delta, hi=2*hi; end
    for k=1:80
        mid=(lo+hi)/2;
        if norm(q./(D+mid))>delta, lo=mid; else, hi=mid; end
    end
    eta=hi; d=V*(q./(D+eta));
end
next=c+d;
info=struct('stepNorm',norm(d),'coeffNorm',norm(next),'multiplier',eta, ...
'cost',mean(abs(u-X*next).^2)+lambda*norm(next)^2,'condition',cond(A));
assert(norm(d)<=delta*(1+1e-8));
end

function shortlist=screenModels(train,validation,x,models,C,folder)
gain=(x'*train.rxAligned)/(x'*x+eps);
yt=train.rxAligned/(gain+eps); yv=validation.rxAligned/(gain+eps);
rows=struct([]);
for k=1:numel(models)
 p=models(k); [B,~,~]=buildGMPMatrix(x,p);
 scales=max(sqrt(mean(abs(B).^2,1)),1e-12); clear B;
 [X,a,b]=buildGMPMatrix(yt,p); target=x(a:b);
 idx=unique(round(linspace(1,size(X,1),min(C.maxFitRows,size(X,1)))));
 X=X(idx,:)./scales; target=target(idx);
 c0=zeros(size(X,2),1); c0(1)=scales(1);
 [coeff,info]=solveBoundedRidge(X,target,c0,C.lambda,Inf);
 [V,a,b]=buildGMPMatrix(yv,p); desired=x(a:b);
 idx=unique(round(linspace(1,size(V,1),min(C.maxFitRows,size(V,1)))));
 V=V(idx,:)./scales; desired=desired(idx);
 nmse=mean(abs(desired-V*coeff).^2)/mean(abs(desired).^2);
 r=struct('modelIndex',k,'modelID',p.ID,'coeffCount',numel(coeff), ...
  'Ka',p.Ka,'La',p.La,'Kb',p.Kb,'Lb',p.Lb,'Mb',p.Mb,'Kc',p.Kc,'Lc',p.Lc,'Mc',p.Mc, ...
  'validationNMSE_dB',10*log10(nmse),'trainingCost',info.cost,'condition',info.condition);
 rows=appendStruct(rows,r);
end
ranking=sortrows(struct2table(rows),{'validationNMSE_dB','coeffCount'});
shortlist=ranking.modelIndex(1:min(C.shortlistCount,height(ranking)));
writetable(ranking,fullfile(folder,'preseleccion_seis_modelos.csv'));
save(fullfile(folder,'preseleccion_seis_modelos.mat'),'ranking','shortlist','C');
disp(ranking(:,{'modelID','coeffCount','validationNMSE_dB'}));
end

function [ok,index,ranking]=chooseStructure(T,jobs,models,C)
rows=struct([]); index=NaN; ok=false;
for modelIndex=unique([jobs.modelIndex])
 p=models(modelIndex); score=[NaN NaN]; eligible=true; methods=["blend","bounded"];
 for k=1:2
  ids=find([jobs.modelIndex]==modelIndex & string({jobs.method})==methods(k));
  if isempty(T), eligible=false; break; end
  terminal=T(ismember(T.job,ids) & T.iteration==C.iterations,:);
  if height(terminal)~=C.repeats || ~all(terminal.accepted) || ~all(isfinite(terminal.eqEVM_gain))
   eligible=false; break;
  end
  score(k)=mean(terminal.eqEVM_gain);
 end
 count=p.Ka*p.La+p.Kb*p.Lb*p.Mb+p.Kc*p.Lc*p.Mc;
 row=struct('modelIndex',modelIndex,'modelID',p.ID,'coeffCount',count, ...
  'eligible',eligible,'blendGain',score(1),'boundedGain',score(2),'worstMethodGain',min(score));
 rows=appendStruct(rows,row);
end
ranking=struct2table(rows); eligible=ranking(ranking.eligible,:);
if isempty(eligible), return; end
best=max(eligible.worstMethodGain);
near=eligible(eligible.worstMethodGain>=best-C.structureTieEVM_pct,:);
near=sortrows(near,{'coeffCount','modelIndex'}); index=near.modelIndex(1); ok=true;
end

function [ok,selected,ranking]=chooseParameters(T,jobs,C)
selected=struct([]); rows=struct([]); ok=false;
for j=1:numel(jobs)
 item=jobs(j); eligible=false; score=NaN;
 if ~isempty(T)
  terminal=T(T.job==j & T.iteration==C.iterations,:);
  eligible=height(terminal)==C.repeats && all(terminal.accepted) && all(isfinite(terminal.eqEVM_gain));
  if eligible, score=mean(terminal.eqEVM_gain); end
 end
 row=struct('job',j,'modelIndex',item.modelIndex,'method',item.method, ...
  'lambda',item.lambda,'mu',item.mu,'delta',item.delta,'eligible',eligible,'eqEVM_gain',score);
 rows=appendStruct(rows,row);
end
ranking=struct2table(rows);
for method=["blend","bounded"]
 eligible=ranking(ranking.eligible & ranking.method==method,:);
 if isempty(eligible), return; end
 eligible=sortrows(eligible,'eqEVM_gain','descend');
 selected=appendStruct(selected,jobs(eligible.job(1)));
end
ok=numel(selected)==2;
end

function result = captureAndMeasureWithRetry( ...
    rxObj, txReference, cfgDL, cfgEVM, sampleRate, ...
    captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
    maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
    alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign, ...
    rawDir, saveRawCaptures, label, txGain, rxGain, dsaSteps, dsaAtten)

    result = initResultStruct();
    best = result;
    best.evm_pct = Inf;
    best.syncMetric = -Inf;

    for attempt = 1:maxCaptureAttempts
        fprintf('  Capture attempt %d/%d [%s]\n', attempt, maxCaptureAttempts, label);

        pause(0.10);
        rxCapture = capture(rxObj, captureTime_s, "Seconds");

        if length(rxCapture) < totalSamplesNeeded
            warning('Insufficient capture in attempt %d.', attempt);
            continue;
        end

        rxCapture = rxCapture(1:totalSamplesNeeded);

        if saveRawCaptures
            rawFile = fullfile(rawDir, sprintf('%s_tx_%+05.2fdB_rx_%+05.2fdB_dsa_%02.0f_attempt_%d.mat', ...
                label, txGain, rxGain, dsaSteps, attempt));
            save(rawFile, 'rxCapture', 'txGain', 'rxGain', 'dsaSteps', 'dsaAtten', 'attempt');
        end

        try
            [alignInfo, alignedData] = robustAlignTxRxForDPD( ...
                txReference, rxCapture, sampleRate, ...
                alignDecimationFactor, fineSearchHalfWindow_samples, ...
                phaseFitMagnitudeThreshold, numFramesForAlign);
        catch ME
            fprintf('    Robust alignment failed: %s\n', ME.message);
            continue;
        end

        rxAligned = alignedData.y_cfo_corrected(:);
        syncMetric = alignInfo.syncMetric;
        freqOffset = alignInfo.freqOffset_Hz;
        rxPower_dBFS = alignInfo.rxPower_dBFS;
        peakRx_dBFS = alignInfo.peakRx_dBFS;

        if isempty(rxAligned) || syncMetric < minSyncMetric
            fprintf('    Sync failed/weak. Metric = %.4f | Required %.4f\n', syncMetric, minSyncMetric);
            continue;
        end

        evm_pct = NaN;
        eqSymb = [];
        refSymb = [];
        try
            Lframe = min(samplesPerFrame, numel(rxAligned));
            [evmInfo, eqSymb, refSymb] = hNRDownlinkEVM(cfgDL, rxAligned(1:Lframe), cfgEVM);
            evm_pct = evmInfo.PDSCH.OverallEVM.RMS * 100;
        catch ME
            fprintf('    EVM failed: %s\n', ME.message);
        end

        acpr_dBc = computeACPRCentered(rxAligned, sampleRate, 20e6);

        fprintf('    EVM %.2f %% | ACPR %.2f dBc | RX %.2f dBFS | peak %.2f dBFS | Sync %.4f | NMSE %.2f dB\n', ...
            evm_pct, acpr_dBc, rxPower_dBFS, peakRx_dBFS, syncMetric, alignInfo.nmse_dB);

        candidate = initResultStruct();
        candidate.usable = true;
        candidate.retryFailed = false;
        candidate.attemptCount = attempt;
        candidate.evm_pct = evm_pct;
        candidate.acpr_dBc = acpr_dBc;
        candidate.rxPower_dBFS = rxPower_dBFS;
        candidate.peakRx_dBFS = peakRx_dBFS;
        candidate.nmse_aligned_dB = alignInfo.nmse_dB;
        candidate.waveformEVM_pct = alignInfo.waveformEVM_pct;
        candidate.txPower_dBFS = 10*log10(mean(abs(txReference(:)).^2) + eps);
        candidate.syncMetric = syncMetric;
        candidate.freqOffset_Hz = freqOffset;
        candidate.rxAligned = rxAligned;
        candidate.rawCapture = rxCapture;
        candidate.eqSymb = eqSymb;
        candidate.refSymb = refSymb;

        if isfinite(evm_pct) && evm_pct < best.evm_pct
            best = candidate;
        elseif ~isfinite(best.evm_pct) && syncMetric > best.syncMetric
            best = candidate;
        elseif isinf(best.evm_pct)
            best = candidate;
        end

        if isfinite(evm_pct) && evm_pct < evmRetryThreshold_pct
            result = candidate;
            return;
        else
            fprintf('    Rejected attempt: EVM invalid or above %.2f %%.\n', evmRetryThreshold_pct);
        end
    end

    if ~best.usable || ~isfinite(best.evm_pct) || best.evm_pct >= evmRetryThreshold_pct || ...
            ~isfinite(best.syncMetric) || best.syncMetric < minSyncMetric
        result = initResultStruct();
        result.usable = false;
        result.retryFailed = true;
        result.attemptCount = maxCaptureAttempts;
        result.evm_pct = NaN;
        result.acpr_dBc = NaN;
        result.rxPower_dBFS = NaN;
        result.txPower_dBFS = 10*log10(mean(abs(txReference(:)).^2) + eps);
        result.syncMetric = best.syncMetric;
        result.freqOffset_Hz = NaN;
        fprintf('    Datum killed after %d attempts: no valid sync/EVM below %.2f %%.\n', ...
            maxCaptureAttempts, evmRetryThreshold_pct);
        return;
    end

    result = best;
    result.attemptCount = maxCaptureAttempts;
    result.retryFailed = false;
end

function s = initResultStruct()
    s = struct();
    s.usable = false;
    s.retryFailed = false;
    s.attemptCount = 0;
    s.evm_pct = NaN;
    s.acpr_dBc = NaN;
    s.rxPower_dBFS = NaN;
    s.peakRx_dBFS = NaN;
    s.nmse_aligned_dB = NaN;
    s.waveformEVM_pct = NaN;
    s.txPower_dBFS = NaN;
    s.meterPower_dBm = NaN;
    s.meterVoltage_V = NaN;
    s.meterADC_raw = NaN;
    s.meterNValid = NaN;
    s.syncMetric = NaN;
    s.freqOffset_Hz = NaN;
    s.rxAligned = [];
    s.rawCapture = [];
    s.eqSymb = [];
    s.refSymb = [];
end

function [alignInfo, alignedData] = robustAlignTxRxForDPD(xTx, yRx, Fs, D, fineHalfWin, magThrRel, numFramesForAlign)
    %#ok<INUSD>
    % EXP010I / EXP008 result: best alignment mode is NORMAL_NO_CFO.
    % This function therefore performs:
    %   1) coarse decimated correlation
    %   2) fine integer-delay search
    %   3) scalar complex-gain normalization
    % and intentionally DOES NOT apply external CFO correction.

    xTx = xTx(:);
    yRx = yRx(:);

    Ntx = numel(xTx);
    Nuse = min(Ntx*numFramesForAlign, Ntx);
    x = xTx(1:Nuse);

    if numel(yRx) < Nuse + 10
        error('RX capture too short for NORMAL_NO_CFO alignment.');
    end

    x0 = x - mean(x, 'omitnan');
    y0 = yRx - mean(yRx, 'omitnan');
    x0 = x0 ./ (rms(abs(x0)) + eps);
    y0 = y0 ./ (rms(abs(y0)) + eps);

    xD = x0(1:D:end);
    yD = y0(1:D:end);
    if numel(yD) < numel(xD)
        error('Decimated RX capture shorter than decimated reference.');
    end

    cCoarse = conv(yD, flipud(conj(xD)), 'valid');
    [~, idxCoarse] = max(abs(cCoarse));
    startCoarse = (idxCoarse - 1) * D + 1;

    startMin = max(1, startCoarse - fineHalfWin);
    startMax = min(numel(yRx) - Nuse + 1, startCoarse + fineHalfWin);
    if startMax < startMin
        error('Invalid fine-search window.');
    end

    starts = startMin:startMax;
    corrVals = nan(numel(starts),1);
    for kk = 1:numel(starts)
        ys = y0(starts(kk):starts(kk)+Nuse-1);
        corrVals(kk) = abs(x0' * ys) / ((norm(x0)+eps)*(norm(ys)+eps));
    end

    [syncMetricCoarseFine, iBest] = max(corrVals);
    startSample = starts(iBest);
    delaySamples = startSample - 1;

    yAlignedRaw = yRx(startSample:startSample+Nuse-1);
    xAligned = x;

    complexGain = (xAligned' * yAlignedRaw) / (xAligned' * xAligned + eps);
    yNorm = yAlignedRaw ./ (complexGain + eps);

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
    alignInfo.freqOffset_Hz = 0;
    alignInfo.phaseSlope_radPerSample = 0;
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
    alignedData.y_cfo_corrected = yAlignedRaw;   % compatibility alias: no CFO is applied
    alignedData.y_normalized = yNorm;
end

function result = attachMeterMeasurement(result, stm, useSTM32PowerMeter, txGain, rxGain, nSamples, fidMeterRaw, label, iteration)
    result.meterPower_dBm = NaN;
    result.meterVoltage_V = NaN;
    result.meterADC_raw = NaN;
    result.meterNValid = 0;

    if ~useSTM32PowerMeter || isempty(stm)
        fprintf("  STM32 meter skipped: disabled or serial object empty.\n");
        return;
    end

    try
        flush(stm);
        pause(0.05);

        cmd = sprintf("MEAS,%.2f,%d", txGain, nSamples);
        fprintf("  Sending STM32 command: %s\n", cmd);
        writeline(stm, cmd);

        [pVals, vVals, adcVals, nValid, nInvalid] = readSTM32PowerBlock_EXP010I( ...
            stm, fidMeterRaw, string(label), iteration, txGain, rxGain);

        result.meterNValid = nValid;
        if ~isempty(pVals)
            result.meterPower_dBm = mean(pVals, "omitnan");
        end
        if ~isempty(vVals)
            result.meterVoltage_V = mean(vVals, "omitnan");
        end
        if ~isempty(adcVals)
            result.meterADC_raw = mean(adcVals, "omitnan");
        end

        fprintf("  STM32 meter: label %s | iter %d | Tx %.2f | Rx %.2f | P %.3f dBm | V %.4f V | Nvalid %d | Ninvalid %d\n", ...
            string(label), iteration, txGain, rxGain, result.meterPower_dBm, result.meterVoltage_V, nValid, nInvalid);
    catch ME
        warning("STM32 meter read failed: %s", ME.message);
    end
end

function [powerValues_dB, voltageValues_V, adcValues_raw, nValid, nInvalid] = readSTM32PowerBlock_EXP010I(stm, fidMeterRaw, label, iteration, txGain, rxGain)
    % Robust reader adapted from the working EXP004/EXP005 MEAS protocol:
    %   command: MEAS,<tag_or_txgain>,<samples>
    %   response:
    %     START,...
    %     DATA,stm32_time_ms,adc_raw,voltage_V,power_dB
    %     END,...
    %
    % This version logs START/DATA/END/ERR lines, keeps raw CSV rows, and
    % protects the experiment from hanging indefinitely if END is not received.

    powerValues_dB = [];
    voltageValues_V = [];
    adcValues_raw = [];
    nValid = 0;
    nInvalid = 0;
    gotEnd = false;

    maxBlockTime_s = 12.0;
    t0 = tic;

    while ~gotEnd
        if toc(t0) > maxBlockTime_s
            warning("STM32 block timeout after %.1f s without END. Valid samples = %d.", maxBlockTime_s, nValid);
            break;
        end

        try
            line = strtrim(string(readline(stm)));
        catch ME_READ
            warning("STM32 readline timeout/error after %.2f s: %s", toc(t0), ME_READ.message);
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

                if isfinite(power_dB)
                    powerValues_dB(end+1,1) = power_dB; %#ok<AGROW>
                end
                if isfinite(voltage_V)
                    voltageValues_V(end+1,1) = voltage_V; %#ok<AGROW>
                end
                if isfinite(adc_raw)
                    adcValues_raw(end+1,1) = adc_raw; %#ok<AGROW>
                end

                if isfinite(power_dB) || isfinite(voltage_V) || isfinite(adc_raw)
                    nValid = nValid + 1;
                else
                    nInvalid = nInvalid + 1;
                end

                if exist("fidMeterRaw","var") && fidMeterRaw > 0
                    pc_timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));
                    fprintf(fidMeterRaw, "%s,%s,%d,%.2f,%.2f,%.0f,%.0f,%.9f,%.6f,%s\n", ...
                        pc_timestamp, sanitizeCsvField(label), iteration, txGain, rxGain, ...
                        stm32_time_ms, adc_raw, voltage_V, power_dB, sanitizeCsvField(line));
                end
            else
                nInvalid = nInvalid + 1;
                fprintf("  Invalid DATA line: %s\n", line);
            end

        elseif startsWith(line, "END")
            fprintf("  %s\n", line);
            gotEnd = true;

        elseif startsWith(line, "ERR")
            warning("STM32 returned error: %s", line);
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

function setSafeState(txObj, idleGain)
    try
        txObj.Gain = idleGain;
        transmitRepeat(txObj, zeros(1000,1));
    catch
    end
end

function cleanupSDR(txObj, rxObj, idleGain)
    try
        setSafeState(txObj, idleGain);
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
end

function tx_dpd = normalizeDPDWaveform(tx_dpd, tx_ref, maxPeakRatio)
    tx_dpd = tx_dpd(:);
    tx_ref = tx_ref(:);
    pRef = mean(abs(tx_ref).^2);
    pDpd = mean(abs(tx_dpd).^2);
    if isfinite(pRef) && isfinite(pDpd) && pRef > 0 && pDpd > 0
        tx_dpd = tx_dpd * sqrt(pRef/pDpd);
    end
    maxAllowedPeak = maxPeakRatio * max(abs(tx_ref));
    currentPeak = max(abs(tx_dpd));
    if isfinite(currentPeak) && currentPeak > maxAllowedPeak && currentPeak > 0
        tx_dpd = tx_dpd / currentPeak * maxAllowedPeak;
    end
end
