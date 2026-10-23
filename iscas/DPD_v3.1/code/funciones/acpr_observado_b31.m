function A=acpr_observado_b31(y,fs,C)
% Separar cobertura numerica de calibracion fisica. Nunca usar bandas parciales.
A=struct('observedLower',NaN,'observedUpper',NaN,'observedTotal',NaN, ...
 'validated',false,'lower',NaN,'upper',NaN,'total',NaN);
if fs<=60e6 || numel(y)<4096, return; end
[P,f]=pwelch(y(:)-mean(y),hamming(4096),2048,32768,fs,'centered');
df=f(2)-f(1);
bands=[-10e6 10e6;-30e6 -10e6;10e6 30e6]; power=zeros(3,1);
for k=1:3
 mask=f>=bands(k,1)&f<bands(k,2); power(k)=sum(P(mask))*df;
end
if any(power<=0),return;end
A.observedLower=10*log10(power(2)/power(1));
A.observedUpper=10*log10(power(3)/power(1));
A.observedTotal=10*log10(sum(power(2:3))/power(1));
A.validated=C.verifiedRxUsefulBW_Hz>=60e6 && strlength(C.evidenceRxBW)>0;
if A.validated
 A.lower=A.observedLower; A.upper=A.observedUpper; A.total=A.observedTotal;
end
end
