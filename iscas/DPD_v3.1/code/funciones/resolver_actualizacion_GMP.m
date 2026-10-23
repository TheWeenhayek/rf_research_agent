function [next,info]=resolver_actualizacion_GMP(X,u,c,lambda,delta)
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
