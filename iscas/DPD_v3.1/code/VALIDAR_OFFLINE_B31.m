% No conecta equipos ni ejecuta experimentos. Sintaxis y solver sintetico.
clear;clc;
raiz=fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(raiz,'code'),fullfile(raiz,'code','funciones'));
files=dir(fullfile(raiz,'code','**','*.m'));
diagnostics=struct('file',{},'line',{},'id',{},'message',{});
for k=1:numel(files)
 f=fullfile(files(k).folder,files(k).name);
 messages=checkcode(f,'-id');
 for j=1:numel(messages)
  diagnostics(end+1)=struct('file',string(f),'line',messages(j).line, ...
   'id',string(messages(j).id),'message',string(messages(j).message)); %#ok<SAGROW>
 end
end
rng(410);N=200;P=9;
X=randn(N,P)+1i*randn(N,P);u=randn(N,1)+1i*randn(N,1);
c=randn(P,1)+1i*randn(P,1);la=0.07;delta=0.1;
[candidate,info]=resolver_actualizacion_GMP(X,u,c,la,delta);
H=X'*X/N+la*eye(P);g=X'*u/N-H*c;d=candidate-c;
assert(norm(d)<=delta*(1+1e-8),'Incumplimiento del radio');
assert(norm((H+info.multiplier*eye(P))*d-g)<1e-9,'Incumplimiento KKT');
assert(abs(norm(d)-delta)<1e-8,'Restriccion activa no satisfecha');
[free,~]=resolver_actualizacion_GMP(X,u,c,la,Inf);
exact=H\(X'*u/N);assert(norm(free-exact)<1e-9,'Ridge libre incorrecto');
assert(norm(c+d-candidate)<1e-12);
C=configuracion_b31();assert(C.peak==0.8 && isempty(C.fs));
rng(3101);[waveAuto,cfgAuto,fsAuto]=generar_senal_b31(C);
assert(cfgAuto.ChannelBandwidth==20 && abs(max(abs(waveAuto))-0.8)<1e-12);
Cwide=C;Cwide.fs=C.fsACPR;
rng(3101);[waveWide,cfgWide,fsWide]=generar_senal_b31(Cwide);
assert(fsWide==61.44e6 && cfgWide.ChannelBandwidth==20);
assert(abs(max(abs(waveWide))-0.8)<1e-12);
% Signal Processing Toolbox: probar cobertura completa y proporciones conocidas.
fs=61.44e6;t=(0:65535)'/fs;
y=exp(1i*2*pi*1e6*t)+0.1*exp(-1i*2*pi*20e6*t)+0.1*exp(1i*2*pi*20e6*t);
A=acpr_observado_b31(y,fs,C);
assert(~A.validated && isnan(A.total),'No debe certificar banda sin evidencia');
assert(abs(A.observedLower+20)<0.2 && abs(A.observedUpper+20)<0.2,'Integracion espectral incorrecta');
A=acpr_observado_b31(y,30.72e6,C);assert(isnan(A.observedTotal),'No admitir adyacentes parciales');
save(fullfile(raiz,'VALIDACION_OFFLINE.mat'),'diagnostics','info','delta','la','fsAuto','fsWide');
if ~isempty(diagnostics)
 T=struct2table(diagnostics);writetable(T,fullfile(raiz,'DIAGNOSTICOS_MATLAB.csv'));
 errors=contains(T.id,'PARSE')|contains(T.id,'SYNER')|contains(lower(T.message),'parse error')|contains(lower(T.message),'invalid expression');
 if any(errors),disp(T(errors,:));error('Errores de sintaxis encontrados');end
end
fprintf('OFFLINE OK: %d archivos revisados; solver, KKT y cobertura espectral probados. Sin hardware.\n',numel(files));
