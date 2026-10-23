function publicar_baseline(source,destination)
% Cada publicacion conserva la version anterior y deja un nombre comun estable.
assert(isfile(source),'No se encontro la salida de baseline: %s',source);
[~,~,extension]=fileparts(source);
if strcmpi(extension,'.csv')
 T=readtable(source);assert(height(T)>=3,'Baseline con menos de tres puntos: no se publica');
 if ismember('N_valid_samples',T.Properties.VariableNames)
  assert(nnz(T.N_valid_samples>0)>=3,'Baseline sin tres mediciones validas: no se publica');
 end
end
if isfile(destination)
 [folder,name,ext]=fileparts(destination);
 previous=fullfile(folder,'historial'); if ~isfolder(previous), mkdir(previous); end
 copyfile(destination,fullfile(previous,string(name)+'_'+string(datetime('now','Format','yyyyMMdd_HHmmss_SSS'))+string(ext)));
end
copyfile(source,destination);
fprintf('Baseline comun actualizado: %s\n',destination);
end
