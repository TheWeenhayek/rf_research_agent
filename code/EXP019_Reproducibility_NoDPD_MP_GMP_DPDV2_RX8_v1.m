%% ========================================================================
%  EXP019 — REPRODUCIBILITY: NO-DPD vs MP vs GMP
%  ----------------------------------------------------------------------
%  Purpose:
%    Quantify run-to-run reproducibility at the fixed training operating
%    point using the exact same 5G NR waveform and fixed coefficient vectors.
%
%    Conditions:
%      1) No-DPD
%      2) MP_M5_K5, iteration 2, 30 coefficients
%      3) GMP_F1_29C, iteration 2, 29 coefficients
%
%    The measurement order rotates between runs to reduce thermal/time-order
%    bias. TX is restarted before every individual capture.
%
%  This is a strict repeatability/reproducibility test:
%    - same baseband waveform every run
%    - same TxGain and RxGain
%    - same DSA/RF-chain configuration
%    - same fixed MP/GMP coefficients
%    - repeated independent TX restarts and captures
%
%  Outputs:

%    - per-run CSV
%    - paired No-DPD/MP/GMP comparison CSV
%    - summary statistics CSV
%    - coefficient/waveform metadata
%    - average PSD CSV
%    - representative AM/AM and AM/PM CSV
%% ========================================================================

clear; close all; clc;

%% ========================================================================
% USER CONFIGURATION
%% ========================================================================

deviceName = "Pluto";
centerFrequency = 5e9;
idleGain_dB = -80;

fixedTxGain_Pluto = -22.25;
fixedRxGain_Pluto = 8;
powerScaleFactor = 0.8;

% Reproducibility campaign.
nRepetitions = 20;
restartSettle_s = 0.80;
idleBetweenRestarts_s = 0.35;
interConditionPause_s = 0.30;

% Rotating order across repetitions:
%   Run 1: No-DPD -> MP -> GMP
%   Run 2: GMP -> No-DPD -> MP
%   Run 3: MP -> GMP -> No-DPD
rotateMeasurementOrder = true;

% EXP017 coefficients. Leave empty to auto-detect latest.
coefficientsCsv = "";

% Official no-DPD reference. Leave empty to auto-detect latest.
officialNoDPDReferenceCsv = "";

% Explicit fair-comparison models.
mpModelID = "MP_M5_K5";
mpIteration = 2;
mpM = 5;
mpK = 5;

gmpModelID = "GMP_F1_29C";
gmpIteration = 2;
gmpParams = struct( ...
    "Ka",5,"La",4, ...
    "Kb",2,"Lb",3,"Mb",1, ...
    "Kc",1,"Lc",3,"Mc",1);

maxPredistortedPeakRatio = 1.10;

% Capture settings.
captureTime_s = 30e-3;
maxCaptureAttempts = 4;
evmRetryThreshold_pct = 80;
minSyncMetric = 0.95;

alignDecimationFactor = 16;
fineSearchHalfWindow_samples = 4000;
phaseFitMagnitudeThreshold = 0.05;
numFramesForAlign = 1;

saveRawCaptures = false;
plotMaxSymbols = 6000;

% Notebook export.
exportNotebookCSVs = true;
plotExportMaxSamplesPerCondition = 60000;
plotExportDecimation = 4;
psdExportNFFT = 16384;
psdExportWindowLength = 4096;

% -------------------- STM32 power meter --------------------
useSTM32PowerMeter = true;
serialPort       = "COM12";
serialBaud       = 209700;
serialTerminator = "LF";
serialTimeout_s  = 2.00;
doPingTest       = true;
nPowerSamplesPerPoint = 50;

%% ========================================================================
% OUTPUT DIRECTORIES
%% ========================================================================

scriptDir = fileparts(mfilename('fullpath'));
if isempty(scriptDir), scriptDir = pwd; end
try
    addpath(fullfile(matlabroot,'examples','5g', ...
        'NRWaveformCaptureAndAnalysisWithSDRExample'));
catch
end

timeTag = string(datetime("now","Format","yyyyMMdd_HHmmss"));
projectDir = fileparts(scriptDir);
dataDir = fullfile(projectDir,"data");
if ~exist(dataDir,"dir"), mkdir(dataDir); end

baseName = "EXP019_Reproducibility_NoDPD_MP_GMP_RX8_" + timeTag;
outputRoot = fullfile(dataDir,baseName);
rawDir = fullfile(outputRoot,"raw");
processedDir = fullfile(outputRoot,"processed");
figuresDir = fullfile(outputRoot,"figures");
notebookDir = fullfile(outputRoot,"notebook_csv");

for d = [{rawDir},{processedDir},{figuresDir},{notebookDir}]
    if ~exist(d{1},"dir"), mkdir(d{1}); end
end

perRunCsvFile = fullfile(processedDir,baseName+"_per_run.csv");
pairedCsvFile = fullfile(processedDir,baseName+"_paired_comparison.csv");
summaryCsvFile = fullfile(processedDir,baseName+"_summary_statistics.csv");
pairStatsCsvFile = fullfile(processedDir,baseName+"_paired_statistics.csv");
powerRawCsvFile = fullfile(rawDir,baseName+"_stm32_power_raw.csv");
matFile = fullfile(processedDir,baseName+"_results.mat");

psdCsvFile = fullfile(notebookDir,baseName+"_average_PSD.csv");
amamCsvFile = fullfile(notebookDir,baseName+"_representative_AMAM_AMPM.csv");
metaCsvFile = fullfile(notebookDir,baseName+"_metadata.csv");

%% ========================================================================
% 5G NR WAVEFORM GENERATION
%% ========================================================================

cfgDLFRC = nrDLCarrierConfig;
cfgDLFRC.Label = 'DL-FRC-FR1-256QAM';
cfgDLFRC.FrequencyRange = 'FR1';
cfgDLFRC.ChannelBandwidth = 20;
cfgDLFRC.NCellID = 1;
cfgDLFRC.NumSubframes = 10;
cfgDLFRC.InitialNSubframe = 0;
cfgDLFRC.WindowingPercent = 0;
cfgDLFRC.CarrierFrequency = 0;
cfgDLFRC.SampleRate = [];

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

[waveform, info] = nrWaveformGenerator(cfgDLFRC);
sampleRate = info.ResourceGrids(1).Info.SampleRate;

txWaveform = waveform * (powerScaleFactor / max(abs(waveform)));
txWaveform = txWaveform(:);
samplesPerFrame = round(sampleRate * 10e-3);
totalSamplesNeeded = round(captureTime_s * sampleRate);
PAPR_noDPD_dB = 10*log10(max(abs(txWaveform)).^2 / mean(abs(txWaveform).^2));

%% ========================================================================
% EVM CONFIGURATION
%% ========================================================================

cfgEVM = struct();
cfgEVM.PlotEVM = false;
cfgEVM.DisplayEVM = false;
cfgEVM.SampleRate = sampleRate;
cfgEVM.IQImbalance = true;
cfgEVM.TargetRNTIs = 0;
cfgEVM.CorrectCoarseFO = true;
cfgEVM.CorrectFineFO = true;
cfgEVM.ExcludeDC = true;

%% ========================================================================
% LOAD EXP017 MP AND GMP COEFFICIENTS
%% ========================================================================

coeffPath = resolveOrAutoFindFile( ...
    coefficientsCsv,scriptDir, ...
    "EXP017_MP_vs_GMP_FAIR_*_best_coefficients.csv");

officialRefPath = resolveOrAutoFindOfficialReference( ...
    officialNoDPDReferenceCsv,scriptDir,fixedRxGain_Pluto);

Tcoeff = readtable(coeffPath);
TrefOfficial = readtable(officialRefPath);

% MP coefficients.
maskMP = string(Tcoeff.ModelID)==mpModelID & ...
         string(Tcoeff.Family)=="MP" & ...
         Tcoeff.Iteration==mpIteration;
if ~any(maskMP)
    error('MP model %s iteration %d not found in %s.', ...
        mpModelID,mpIteration,coeffPath);
end
Tmp = sortrows(Tcoeff(maskMP,:),'CoeffIndex');
coeffMP = complex(Tmp.CoeffReal,Tmp.CoeffImag);
expectedMP = (mpM+1)*mpK;
if numel(coeffMP) ~= expectedMP
    error('MP coefficient count mismatch: expected %d, found %d.', ...
        expectedMP,numel(coeffMP));
end

% GMP coefficients.
maskGMP = string(Tcoeff.ModelID)==gmpModelID & ...
          string(Tcoeff.Family)=="GMP" & ...
          Tcoeff.Iteration==gmpIteration;
if ~any(maskGMP)
    error('GMP model %s iteration %d not found in %s.', ...
        gmpModelID,gmpIteration,coeffPath);
end
Tgmp = sortrows(Tcoeff(maskGMP,:),'CoeffIndex');
coeffGMP = complex(Tgmp.CoeffReal,Tgmp.CoeffImag);
expectedGMP = gmpParams.Ka*gmpParams.La + ...
              gmpParams.Kb*gmpParams.Lb*gmpParams.Mb + ...
              gmpParams.Kc*gmpParams.Lc*gmpParams.Mc;
if numel(coeffGMP) ~= expectedGMP
    error('GMP coefficient count mismatch: expected %d, found %d.', ...
        expectedGMP,numel(coeffGMP));
end

%% ========================================================================
% INITIALIZE STM32 POWER METER
%% ========================================================================

stm = [];
fidPower = -1;
if useSTM32PowerMeter
    try
        fprintf("Abriendo puerto serial STM32...\n");
        stm = serialport(serialPort, serialBaud, "Timeout", serialTimeout_s);
        configureTerminator(stm, serialTerminator);
        flush(stm);
        pause(0.5);

        if doPingTest
            fprintf("Probando comunicacion STM32 con PING...\n");
            writeline(stm, "PING");
            pause(0.2);
            while stm.NumBytesAvailable > 0
                fprintf("STM32: %s\n", strtrim(readline(stm)));
            end
            flush(stm);
        end

        fidPower = fopen(powerRawCsvFile, "w");
        if fidPower < 0
            error("No se pudo crear CSV raw de potencia STM32.");
        end
        fprintf(fidPower, "pc_timestamp,pointIndex,condition,txGain_dB,rxGain_dB,stm32_time_ms,adc_raw,voltage_V,power_dB_stm32,raw_line\n");
    catch ME
        warning("No se pudo inicializar STM32. Se continua sin medicion STM32: %s", ME.message);
        useSTM32PowerMeter = false;
        stm = [];
        if fidPower > 0
            fclose(fidPower);
            fidPower = -1;
        end
    end
end

fprintf('\n===== EXP019 SETUP =====\n');

fprintf('MP model:  %s | iteration %d | M=%d K=%d | coeffs=%d\n', ...
    mpModelID, mpIteration, mpM, mpK, numel(coeffMP));

fprintf('GMP model: %s | iteration %d | coeffs=%d\n', ...
    gmpModelID, gmpIteration, numel(coeffGMP));

fprintf('Coefficient CSV: %s\n', coeffPath);
fprintf('Official no-DPD reference: %s\n', officialRefPath);

fprintf('Fixed TxGain: %.2f dB\n', fixedTxGain_Pluto);
fprintf('Fixed RxGain: %.2f dB\n', fixedRxGain_Pluto);
fprintf('Repetitions: %d\n', nRepetitions);

fprintf('Sample rate: %.3f Msps | No-DPD PAPR %.2f dB\n', ...
    sampleRate/1e6, PAPR_noDPD_dB);

% Build both fixed DPD waveforms once.
txMPraw = applyMemoryPolynomial(txWaveform,coeffMP,mpM,mpK);
[txMP,mpNormDiag] = normalizeDPDWaveformDetailed( ...
    txMPraw,txWaveform,maxPredistortedPeakRatio);

txGMPraw = applyGMP(txWaveform,coeffGMP,gmpParams);
[txGMP,gmpNormDiag] = normalizeDPDWaveformDetailed( ...
    txGMPraw,txWaveform,maxPredistortedPeakRatio);

PAPR_MP_dB = 10*log10(max(abs(txMP)).^2/(mean(abs(txMP).^2)+eps));
PAPR_GMP_dB = 10*log10(max(abs(txGMP)).^2/(mean(abs(txGMP).^2)+eps));

fprintf('MP PAPR %.2f dB | post-average ratio %.2f dB | peak scale %.4f\n', ...
    PAPR_MP_dB,mpNormDiag.PostAveragePowerRatio_dB,mpNormDiag.PeakScaleApplied);
fprintf('GMP PAPR %.2f dB | post-average ratio %.2f dB | peak scale %.4f\n', ...
    PAPR_GMP_dB,gmpNormDiag.PostAveragePowerRatio_dB,gmpNormDiag.PeakScaleApplied);

%% ========================================================================
% INITIALIZE SDR
%% ========================================================================

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

cleanupObj = onCleanup(@() cleanupAll(sdrTransmitter, sdrReceiver, idleGain_dB, fidPower)); %#ok<NASGU>

%% ========================================================================
% FIXED-POINT REPRODUCIBILITY: NO-DPD, MP AND GMP
%% ========================================================================

conditions = ["No-DPD","MP","GMP"];
measurementOrders = {
    ["No-DPD","MP","GMP"]
    ["GMP","No-DPD","MP"]
    ["MP","GMP","No-DPD"]
};

rows = repmat(initReproRow(),0,1);
captureStore = struct();
captureStore.No_DPD = cell(nRepetitions,1);
captureStore.MP = cell(nRepetitions,1);
captureStore.GMP = cell(nRepetitions,1);

fprintf('\n===== EXP019 REPRODUCIBILITY CAMPAIGN =====\n');
fprintf('Runs: %d | TxGain %.2f dB | RxGain %.2f dB\n', ...
    nRepetitions,fixedTxGain_Pluto,fixedRxGain_Pluto);

for run = 1:nRepetitions
    if rotateMeasurementOrder
        thisOrder = measurementOrders{mod(run-1,numel(measurementOrders))+1};
    else
        thisOrder = conditions;
    end

    fprintf('\n============================================================\n');
    fprintf('Repetition %d/%d | order: %s -> %s -> %s\n', ...
        run,nRepetitions,thisOrder(1),thisOrder(2),thisOrder(3));
    fprintf('============================================================\n');

    for io = 1:numel(thisOrder)
        condition = thisOrder(io);

        if condition=="No-DPD"
            txCurrent = txWaveform;
            paprCurrent = PAPR_noDPD_dB;
            modelID = "NONE";
            modelIteration = 0;
            key = 'No_DPD';
        elseif condition=="MP"
            txCurrent = txMP;
            paprCurrent = PAPR_MP_dB;
            modelID = mpModelID;
            modelIteration = mpIteration;
            key = 'MP';
        else
            txCurrent = txGMP;
            paprCurrent = PAPR_GMP_dB;
            modelID = gmpModelID;
            modelIteration = gmpIteration;
            key = 'GMP';
        end

        % Full TX restart before each condition.
        setSafeState(sdrTransmitter,idleGain_dB);
        pause(idleBetweenRestarts_s);

        sdrTransmitter.Gain = fixedTxGain_Pluto;
        transmitRepeat(sdrTransmitter,txCurrent);
        pause(restartSettle_s);

        label = sprintf('run_%02d_%s',run,condition);
        res = captureAndMeasureWithRetry( ...
            sdrReceiver,txCurrent,cfgDLFRC,cfgEVM,sampleRate, ...
            captureTime_s,totalSamplesNeeded,samplesPerFrame, ...
            maxCaptureAttempts,evmRetryThreshold_pct,minSyncMetric, ...
            alignDecimationFactor,fineSearchHalfWindow_samples, ...
            phaseFitMagnitudeThreshold,numFramesForAlign, ...
            rawDir,saveRawCaptures,label, ...
            fixedTxGain_Pluto,fixedRxGain_Pluto);

        stmRes = measureSTM32PowerIfEnabled( ...
            useSTM32PowerMeter,stm,fidPower,run,condition, ...
            fixedTxGain_Pluto,fixedRxGain_Pluto,nPowerSamplesPerPoint);

        row = makeReproResultRow( ...
            run,io,condition,fixedTxGain_Pluto,fixedRxGain_Pluto, ...
            modelID,modelIteration,paprCurrent,res,stmRes);

        rows(end+1,1) = row; %#ok<SAGROW>
        captureStore.(key){run} = res;

        fprintf('%s run %d: EVM %.3f %% | ACPR %.3f dBc | RX %.3f dBFS | STM32 %.3f dBm | Sync %.4f\n', ...
            condition,run,row.EVM_pct,row.ACPR_dBc,row.RxPower_dBFS, ...
            row.Power_mean_dB_stm32,row.SyncMetric);

        setSafeState(sdrTransmitter,idleGain_dB);
        pause(interConditionPause_s);
    end
end

setSafeState(sdrTransmitter,idleGain_dB);

perRunTable = struct2table(rows);
writetable(perRunTable,perRunCsvFile);

%% ========================================================================
% PAIRED AND SUMMARY STATISTICS
%% ========================================================================

pairedTable = buildThreeConditionPairedTable(perRunTable,TrefOfficial);
writetable(pairedTable,pairedCsvFile);

summaryStatsTable = buildThreeConditionSummaryStats(perRunTable);
writetable(summaryStatsTable,summaryCsvFile);

pairedStatsTable = buildPairedDifferenceStatistics(pairedTable);
writetable(pairedStatsTable,pairStatsCsvFile);

disp(summaryStatsTable);
disp(pairedStatsTable);

%% ========================================================================
% NOTEBOOK EXPORTS
%% ========================================================================

if exportNotebookCSVs
    [psdTable,psdMeta] = buildAveragePSDThreeConditions( ...
        captureStore,sampleRate,psdExportNFFT,psdExportWindowLength);
    writetable(psdTable,psdCsvFile);

    amamTable = buildRepresentativeAMAMAMPMThreeConditions( ...
        txWaveform,txMP,txGMP,captureStore,perRunTable, ...
        plotExportMaxSamplesPerCondition,plotExportDecimation);
    writetable(amamTable,amamCsvFile);

    metaTable = table();
    metaTable.TxGain_dB = fixedTxGain_Pluto;
    metaTable.RxGain_dB = fixedRxGain_Pluto;
    metaTable.N_Repetitions = nRepetitions;
    metaTable.SampleRate_Hz = sampleRate;
    metaTable.PAPR_NoDPD_dB = PAPR_noDPD_dB;
    metaTable.PAPR_MP_dB = PAPR_MP_dB;
    metaTable.PAPR_GMP_dB = PAPR_GMP_dB;
    metaTable.MP_PeakScaleApplied = mpNormDiag.PeakScaleApplied;
    metaTable.GMP_PeakScaleApplied = gmpNormDiag.PeakScaleApplied;
    metaTable.MP_PostAveragePowerRatio_dB = mpNormDiag.PostAveragePowerRatio_dB;
    metaTable.GMP_PostAveragePowerRatio_dB = gmpNormDiag.PostAveragePowerRatio_dB;
    metaTable.PSD_Usable_NoDPD = psdMeta.N_NoDPD;
    metaTable.PSD_Usable_MP = psdMeta.N_MP;
    metaTable.PSD_Usable_GMP = psdMeta.N_GMP;
    writetable(metaTable,metaCsvFile);
end

%% ========================================================================
% FIGURES
%% ========================================================================

try
    h1=figure('Name','EXP019 metrics over repetitions','Color','w');
    tiledlayout(4,1);
    nexttile; plotReproMetric(perRunTable,'EVM_pct','EVM RMS (%)'); title('EVM versus repetition');
    nexttile; plotReproMetric(perRunTable,'ACPR_dBc','ACPR (dBc)'); title('ACPR versus repetition');
    nexttile; plotReproMetric(perRunTable,'RxPower_dBFS','RX power (dBFS)'); title('Pluto RX power');
    nexttile; plotReproMetric(perRunTable,'Power_mean_dB_stm32','STM32 power (dBm)'); title('External detector power');
    saveas(h1,fullfile(figuresDir,'01_PerRun_Metrics.png'));
catch ME
    warning('Per-run figure failed: %s',ME.message);
end

try
    h2=figure('Name','EXP019 distributions','Color','w');
    tiledlayout(2,2);
    nexttile; boxplotByThreeConditions(perRunTable,'EVM_pct'); ylabel('EVM RMS (%)'); title('EVM distribution');
    nexttile; boxplotByThreeConditions(perRunTable,'ACPR_dBc'); ylabel('ACPR (dBc)'); title('ACPR distribution');
    nexttile; boxplotByThreeConditions(perRunTable,'RxPower_dBFS'); ylabel('RX power (dBFS)'); title('RX-power distribution');
    nexttile; boxplotByThreeConditions(perRunTable,'Power_mean_dB_stm32'); ylabel('STM32 power (dBm)'); title('Detector-power distribution');
    saveas(h2,fullfile(figuresDir,'02_Distributions.png'));
catch ME
    warning('Distribution figure failed: %s',ME.message);
end

try
    h3=figure('Name','EXP019 paired MP-GMP differences','Color','w');
    tiledlayout(3,1);
    nexttile;
    plot(pairedTable.Run,pairedTable.EVM_MP_minus_GMP_pct,'o-','LineWidth',1.1);
    yline(0,'--'); grid on; ylabel('EVM MP-GMP (%)'); title('Negative means MP has lower EVM');
    nexttile;
    plot(pairedTable.Run,pairedTable.ACPR_MP_minus_GMP_dB,'o-','LineWidth',1.1);
    yline(0,'--'); grid on; ylabel('ACPR MP-GMP (dB)'); title('Positive means GMP has more-negative ACPR');
    nexttile;
    plot(pairedTable.Run,pairedTable.RxPower_MP_minus_GMP_dB,'o-','LineWidth',1.1);
    yline(0,'--'); grid on; xlabel('Repetition'); ylabel('RX power MP-GMP (dB)');
    saveas(h3,fullfile(figuresDir,'03_Paired_MP_minus_GMP.png'));
catch ME
    warning('Paired figure failed: %s',ME.message);
end

%% ========================================================================
% SAVE AND CLEANUP
%% ========================================================================

try
    if fidPower>0
        fclose(fidPower);
        fidPower=-1;
    end
catch
end

save(matFile, ...
    'perRunTable','pairedTable','summaryStatsTable','pairedStatsTable', ...
    'captureStore','txWaveform','txMP','txGMP', ...
    'coeffMP','coeffGMP','mpModelID','mpIteration','mpM','mpK', ...
    'gmpModelID','gmpIteration','gmpParams', ...
    'fixedTxGain_Pluto','fixedRxGain_Pluto','nRepetitions', ...
    'sampleRate','PAPR_noDPD_dB','PAPR_MP_dB','PAPR_GMP_dB', ...
    'mpNormDiag','gmpNormDiag','officialRefPath','TrefOfficial');

fprintf('\n===== EXP019 COMPLETE =====\n');
fprintf('Output root         : %s\n',outputRoot);
fprintf('Per-run CSV         : %s\n',perRunCsvFile);
fprintf('Paired CSV          : %s\n',pairedCsvFile);
fprintf('Summary CSV         : %s\n',summaryCsvFile);
fprintf('Paired statistics   : %s\n',pairStatsCsvFile);
fprintf('Average PSD CSV     : %s\n',psdCsvFile);
fprintf('AM/AM-AM/PM CSV     : %s\n',amamCsvFile);
fprintf('MAT file            : %s\n',matFile);

%% ========================================================================
% LOCAL FUNCTIONS
%% ========================================================================

function s=initReproRow()
    s=struct( ...
        'Run',NaN, ...
        'MeasurementOrderIndex',NaN, ...
        'Condition',string(missing), ...
        'TxGain_dB',NaN, ...
        'RxGain_dB',NaN, ...
        'ModelID',string(missing), ...
        'ModelIteration',NaN, ...
        'PAPR_dB',NaN, ...
        'Usable',false, ...
        'EVM_pct',NaN, ...
        'ACPR_dBc',NaN, ...
        'RxPower_dBFS',NaN, ...
        'PeakRx_dBFS',NaN, ...
        'SyncMetric',NaN, ...
        'NMSE_aligned_dB',NaN, ...
        'WaveformEVM_pct',NaN, ...
        'FreqOffset_Hz',NaN, ...
        'CaptureAttempts',NaN, ...
        'RetryFailed',false, ...
        'Power_mean_dB_stm32',NaN, ...
        'Power_std_dB_stm32',NaN, ...
        'Voltage_mean_V',NaN, ...
        'Voltage_std_V',NaN, ...
        'ADC_mean_raw',NaN, ...
        'N_power_valid',NaN, ...
        'N_power_invalid',NaN);
end

function row=makeReproResultRow(run,orderIndex,condition,txGain,rxGain,modelID,modelIteration,papr,res,stm)
    row=initReproRow();
    row.Run=run;
    row.MeasurementOrderIndex=orderIndex;
    row.Condition=string(condition);
    row.TxGain_dB=txGain;
    row.RxGain_dB=rxGain;
    row.ModelID=string(modelID);
    row.ModelIteration=modelIteration;
    row.PAPR_dB=papr;
    row.Usable=res.usable;
    row.EVM_pct=res.evm_pct;
    row.ACPR_dBc=res.acpr_dBc;
    row.RxPower_dBFS=res.rxPower_dBFS;
    row.PeakRx_dBFS=res.peakRx_dBFS;
    row.SyncMetric=res.syncMetric;
    row.NMSE_aligned_dB=res.nmse_aligned_dB;
    row.WaveformEVM_pct=res.waveformEVM_pct;
    row.FreqOffset_Hz=res.freqOffset_Hz;
    row.CaptureAttempts=res.attemptCount;
    row.RetryFailed=res.retryFailed;
    row.Power_mean_dB_stm32=stm.Power_mean_dB_stm32;
    row.Power_std_dB_stm32=stm.Power_std_dB_stm32;
    row.Voltage_mean_V=stm.Voltage_mean_V;
    row.Voltage_std_V=stm.Voltage_std_V;
    row.ADC_mean_raw=stm.ADC_mean_raw;
    row.N_power_valid=stm.N_power_valid;
    row.N_power_invalid=stm.N_power_invalid;
end

function P=buildThreeConditionPairedTable(T,Tref)
    runs=unique(T.Run);
    rows=struct([]);
    for i=1:numel(runs)
        rnum=runs(i);
        N=firstReproRow(T,rnum,"No-DPD");
        M=firstReproRow(T,rnum,"MP");
        G=firstReproRow(T,rnum,"GMP");
        if isempty(N)||isempty(M)||isempty(G), continue; end

        r.Run=rnum;
        r.EVM_NoDPD_pct=N.EVM_pct(1);
        r.EVM_MP_pct=M.EVM_pct(1);
        r.EVM_GMP_pct=G.EVM_pct(1);
        r.EVM_Improvement_MP_vsNoDPD_pct=r.EVM_NoDPD_pct-r.EVM_MP_pct;
        r.EVM_Improvement_GMP_vsNoDPD_pct=r.EVM_NoDPD_pct-r.EVM_GMP_pct;
        r.EVM_MP_minus_GMP_pct=r.EVM_MP_pct-r.EVM_GMP_pct;

        r.ACPR_NoDPD_dBc=N.ACPR_dBc(1);
        r.ACPR_MP_dBc=M.ACPR_dBc(1);
        r.ACPR_GMP_dBc=G.ACPR_dBc(1);
        r.ACPR_Improvement_MP_vsNoDPD_dB=r.ACPR_NoDPD_dBc-r.ACPR_MP_dBc;
        r.ACPR_Improvement_GMP_vsNoDPD_dB=r.ACPR_NoDPD_dBc-r.ACPR_GMP_dBc;
        r.ACPR_MP_minus_GMP_dB=r.ACPR_MP_dBc-r.ACPR_GMP_dBc;

        r.RxPower_NoDPD_dBFS=N.RxPower_dBFS(1);
        r.RxPower_MP_dBFS=M.RxPower_dBFS(1);
        r.RxPower_GMP_dBFS=G.RxPower_dBFS(1);
        r.RxPower_MP_minus_GMP_dB=r.RxPower_MP_dBFS-r.RxPower_GMP_dBFS;

        r.STM32Power_NoDPD_dBm=N.Power_mean_dB_stm32(1);
        r.STM32Power_MP_dBm=M.Power_mean_dB_stm32(1);
        r.STM32Power_GMP_dBm=G.Power_mean_dB_stm32(1);
        r.STM32Power_MP_minus_GMP_dB=r.STM32Power_MP_dBm-r.STM32Power_GMP_dBm;

        [r.Ref_EVM_MP_SameRxPower_pct,r.Ref_ACPR_MP_SameRxPower_dBc] = ...
            interpReferenceAtPower(Tref,'RxPower_dBFS',r.RxPower_MP_dBFS);
        [r.Ref_EVM_GMP_SameRxPower_pct,r.Ref_ACPR_GMP_SameRxPower_dBc] = ...
            interpReferenceAtPower(Tref,'RxPower_dBFS',r.RxPower_GMP_dBFS);

        r.MP_EVM_Improvement_EqualRxPower_pct= ...
            r.Ref_EVM_MP_SameRxPower_pct-r.EVM_MP_pct;
        r.GMP_EVM_Improvement_EqualRxPower_pct= ...
            r.Ref_EVM_GMP_SameRxPower_pct-r.EVM_GMP_pct;
        r.MP_ACPR_Improvement_EqualRxPower_dB= ...
            r.Ref_ACPR_MP_SameRxPower_dBc-r.ACPR_MP_dBc;
        r.GMP_ACPR_Improvement_EqualRxPower_dB= ...
            r.Ref_ACPR_GMP_SameRxPower_dBc-r.ACPR_GMP_dBc;

        rows=[rows;r]; %#ok<AGROW>
    end
    P=struct2table(rows);
end

function R=firstReproRow(T,run,condition)
    R=T(T.Run==run & T.Condition==condition & T.Usable,:);
    if ~isempty(R), R=R(1,:); end
end

function S=buildThreeConditionSummaryStats(T)
    conditions=["No-DPD","MP","GMP"];
    rows=struct([]);
    for i=1:numel(conditions)
        c=conditions(i);
        X=T(T.Condition==c & T.Usable,:);
        r.Condition=c;
        r.N=height(X);
        r.EVM_Mean_pct=mean(X.EVM_pct,'omitnan');
        r.EVM_Std_pct=std(X.EVM_pct,'omitnan');
        r.EVM_CV_pct=100*r.EVM_Std_pct/(r.EVM_Mean_pct+eps);
        r.EVM_Min_pct=min(X.EVM_pct,[],'omitnan');
        r.EVM_Max_pct=max(X.EVM_pct,[],'omitnan');
        r.ACPR_Mean_dBc=mean(X.ACPR_dBc,'omitnan');
        r.ACPR_Std_dB=std(X.ACPR_dBc,'omitnan');
        r.RxPower_Mean_dBFS=mean(X.RxPower_dBFS,'omitnan');
        r.RxPower_Std_dB=std(X.RxPower_dBFS,'omitnan');
        r.STM32Power_Mean_dBm=mean(X.Power_mean_dB_stm32,'omitnan');
        r.STM32Power_Std_dB=std(X.Power_mean_dB_stm32,'omitnan');
        r.SyncMetric_Mean=mean(X.SyncMetric,'omitnan');
        r.CaptureAttempts_Mean=mean(X.CaptureAttempts,'omitnan');
        rows=[rows;r]; %#ok<AGROW>
    end
    S=struct2table(rows);
end

function S=buildPairedDifferenceStatistics(P)
    metrics = {
        'EVM_MP_minus_GMP_pct'
        'ACPR_MP_minus_GMP_dB'
        'RxPower_MP_minus_GMP_dB'
        'STM32Power_MP_minus_GMP_dB'
        'EVM_Improvement_MP_vsNoDPD_pct'
        'EVM_Improvement_GMP_vsNoDPD_pct'
        'ACPR_Improvement_MP_vsNoDPD_dB'
        'ACPR_Improvement_GMP_vsNoDPD_dB'
    };
    rows=struct([]);
    for i=1:numel(metrics)
        name=metrics{i};
        x=P.(name);
        x=x(isfinite(x));
        r.Metric=string(name);
        r.N=numel(x);
        r.Mean=mean(x,'omitnan');
        r.Std=std(x,'omitnan');
        r.Min=min(x,[],'omitnan');
        r.Max=max(x,[],'omitnan');
        if numel(x)>=2
            r.CI95_HalfWidth=tinv(0.975,numel(x)-1)*std(x,'omitnan')/sqrt(numel(x));
            [~,p]=ttest(x,0);
            r.PairedTTest_p=p;
        else
            r.CI95_HalfWidth=NaN;
            r.PairedTTest_p=NaN;
        end
        rows=[rows;r]; %#ok<AGROW>
    end
    S=struct2table(rows);
end

function plotReproMetric(T,yName,yLabelText)
    hold on;
    conds=["No-DPD","MP","GMP"];
    marks={'o-','s-','d-'};
    for i=1:numel(conds)
        mask=T.Condition==conds(i) & T.Usable & isfinite(T.(yName));
        [x,idx]=sort(T.Run(mask));
        y=T.(yName)(mask); y=y(idx);
        plot(x,y,marks{i},'LineWidth',1.05,'DisplayName',conds(i));
    end
    grid on; xlabel('Repetition'); ylabel(yLabelText); legend('Location','best');
end

function boxplotByThreeConditions(T,yName)
    valid=T.Usable & isfinite(T.(yName));
    boxplot(T.(yName)(valid),T.Condition(valid));
    grid on;
end

function [T,meta]=buildAveragePSDThreeConditions(store,fs,nfft,winLen)
    keys={'No_DPD','MP','GMP'};
    names={'PSD_NoDPD_dB','PSD_MP_dB','PSD_GMP_dB'};
    avg=cell(3,1);
    fCommon=[];
    counts=zeros(3,1);

    for ic=1:3
        acc=[];
        for k=1:numel(store.(keys{ic}))
            res=store.(keys{ic}){k};
            if isempty(res)||~res.usable||isempty(res.rxAligned), continue; end
            x=res.rxAligned(:);
            N=min(numel(x),262144);
            x=x(1:N)-mean(x(1:N));
            w=hamming(min(winLen,N));
            [pxx,f]=pwelch(x,w,[],nfft,fs,'centered');
            if isempty(acc), acc=zeros(size(pxx)); fCommon=f; end
            acc=acc+pxx;
            counts(ic)=counts(ic)+1;
        end
        if counts(ic)>0
            p=10*log10(acc/counts(ic)+eps);
            avg{ic}=p-max(p);
        else
            avg{ic}=nan(size(fCommon));
        end
    end

    T=table();
    T.Frequency_Hz=fCommon;
    T.Frequency_MHz=fCommon/1e6;
    T.PSD_NoDPD_dB=avg{1};
    T.PSD_MP_dB=avg{2};
    T.PSD_GMP_dB=avg{3};

    meta=struct('N_NoDPD',counts(1),'N_MP',counts(2),'N_GMP',counts(3));
end

function T=buildRepresentativeAMAMAMPMThreeConditions(txRef,txMP,txGMP,store,perRun,maxSamples,decim)
    conditions=["No-DPD","MP","GMP"];
    keys={'No_DPD','MP','GMP'};
    txSignals={txRef,txMP,txGMP};
    T=table();

    for ic=1:3
        X=perRun(perRun.Condition==conditions(ic) & perRun.Usable,:);
        target=mean(X.EVM_pct,'omitnan');
        [~,j]=min(abs(X.EVM_pct-target));
        run=X.Run(j);
        res=store.(keys{ic}){run};

        x=txRef(:);
        u=txSignals{ic}(:);
        y=res.rxAligned(:);
        L=min([numel(x),numel(u),numel(y)]);
        x=x(1:L); u=u(1:L); y=y(1:L);

        alpha=(y'*x)/(y'*y+eps);
        yScaled=alpha*y;

        idx=(1:decim:L).';
        if numel(idx)>maxSamples
            idx=idx(round(linspace(1,numel(idx),maxSamples)));
        end

        Tc=table();
        Tc.Condition=repmat(conditions(ic),numel(idx),1);
        Tc.RepresentativeRun=repmat(run,numel(idx),1);
        Tc.SampleIndex=idx;
        Tc.InputAmplitude=abs(x(idx));
        Tc.InputAmplitudeNormalized=abs(x(idx))/(max(abs(x))+eps);
        Tc.TxAppliedAmplitude=abs(u(idx));
        Tc.RxOutputAmplitude=abs(yScaled(idx));
        Tc.DPDPhaseShift_rad=angle(u(idx).*conj(x(idx)));
        Tc.ChainPhaseShift_rad=angle(yScaled(idx).*conj(x(idx)));
        Tc.TxReference_I=real(x(idx));
        Tc.TxReference_Q=imag(x(idx));
        Tc.TxApplied_I=real(u(idx));
        Tc.TxApplied_Q=imag(u(idx));
        Tc.RxScaled_I=real(yScaled(idx));
        Tc.RxScaled_Q=imag(yScaled(idx));
        T=[T;Tc]; %#ok<AGROW>
    end
end


function s = initSweepRow()
    s=struct( ...
        'PointIndex',NaN, ...
        'MeasurementOrderIndex',NaN, ...
        'Condition',string(missing), ...
        'TxGain_dB',NaN, ...
        'RxGain_dB',NaN, ...
        'DistanceFromTraining_dB',NaN, ...
        'ModelID',string(missing), ...
        'ModelIteration',NaN, ...
        'PAPR_dB',NaN, ...
        'Usable',false, ...
        'EVM_pct',NaN, ...
        'ACPR_dBc',NaN, ...
        'RxPower_dBFS',NaN, ...
        'PeakRx_dBFS',NaN, ...
        'SyncMetric',NaN, ...
        'NMSE_aligned_dB',NaN, ...
        'WaveformEVM_pct',NaN, ...
        'FreqOffset_Hz',NaN, ...
        'CaptureAttempts',NaN, ...
        'RetryFailed',false, ...
        'Power_mean_dB_stm32',NaN, ...
        'Power_std_dB_stm32',NaN, ...
        'Voltage_mean_V',NaN, ...
        'Voltage_std_V',NaN, ...
        'ADC_mean_raw',NaN, ...
        'N_power_valid',NaN, ...
        'N_power_invalid',NaN);
end

function row = makeSweepResultRow(pointIndex,orderIndex,condition,txGain,rxGain,modelID,modelIteration,papr,res,stm,trainedTxGain)
    row=initSweepRow();
    row.PointIndex=pointIndex;
    row.MeasurementOrderIndex=orderIndex;
    row.Condition=string(condition);
    row.TxGain_dB=txGain;
    row.RxGain_dB=rxGain;
    row.DistanceFromTraining_dB=txGain-trainedTxGain;
    row.ModelID=string(modelID);
    row.ModelIteration=modelIteration;
    row.PAPR_dB=papr;
    row.Usable=res.usable;
    row.EVM_pct=res.evm_pct;
    row.ACPR_dBc=res.acpr_dBc;
    row.RxPower_dBFS=res.rxPower_dBFS;
    row.PeakRx_dBFS=res.peakRx_dBFS;
    row.SyncMetric=res.syncMetric;
    row.NMSE_aligned_dB=res.nmse_aligned_dB;
    row.WaveformEVM_pct=res.waveformEVM_pct;
    row.FreqOffset_Hz=res.freqOffset_Hz;
    row.CaptureAttempts=res.attemptCount;
    row.RetryFailed=res.retryFailed;
    row.Power_mean_dB_stm32=stm.Power_mean_dB_stm32;
    row.Power_std_dB_stm32=stm.Power_std_dB_stm32;
    row.Voltage_mean_V=stm.Voltage_mean_V;
    row.Voltage_std_V=stm.Voltage_std_V;
    row.ADC_mean_raw=stm.ADC_mean_raw;
    row.N_power_valid=stm.N_power_valid;
    row.N_power_invalid=stm.N_power_invalid;
end

function summary = buildThreeConditionComparisonSummary(T,Tref)
    txList=unique(T.TxGain_dB,'sorted');
    rows=struct([]);

    for i=1:numel(txList)
        tx=txList(i);
        N=firstValidConditionRow(T,tx,"No-DPD");
        M=firstValidConditionRow(T,tx,"MP");
        G=firstValidConditionRow(T,tx,"GMP");

        r.TxGain_dB=tx;
        r.NoDPD_Usable=~isempty(N);
        r.MP_Usable=~isempty(M);
        r.GMP_Usable=~isempty(G);

        r.EVM_NoDPD_pct=getTableScalar(N,'EVM_pct');
        r.EVM_MP_pct=getTableScalar(M,'EVM_pct');
        r.EVM_GMP_pct=getTableScalar(G,'EVM_pct');
        r.ACPR_NoDPD_dBc=getTableScalar(N,'ACPR_dBc');
        r.ACPR_MP_dBc=getTableScalar(M,'ACPR_dBc');
        r.ACPR_GMP_dBc=getTableScalar(G,'ACPR_dBc');
        r.RxPower_NoDPD_dBFS=getTableScalar(N,'RxPower_dBFS');
        r.RxPower_MP_dBFS=getTableScalar(M,'RxPower_dBFS');
        r.RxPower_GMP_dBFS=getTableScalar(G,'RxPower_dBFS');
        r.STM32Power_NoDPD_dBm=getTableScalar(N,'Power_mean_dB_stm32');
        r.STM32Power_MP_dBm=getTableScalar(M,'Power_mean_dB_stm32');
        r.STM32Power_GMP_dBm=getTableScalar(G,'Power_mean_dB_stm32');

        r.EVM_Improvement_MP_vsLiveNoDPD_pct=r.EVM_NoDPD_pct-r.EVM_MP_pct;
        r.EVM_Improvement_GMP_vsLiveNoDPD_pct=r.EVM_NoDPD_pct-r.EVM_GMP_pct;
        r.ACPR_Improvement_MP_vsLiveNoDPD_dB=r.ACPR_NoDPD_dBc-r.ACPR_MP_dBc;
        r.ACPR_Improvement_GMP_vsLiveNoDPD_dB=r.ACPR_NoDPD_dBc-r.ACPR_GMP_dBc;

        r.EVM_MP_minus_GMP_pct=r.EVM_MP_pct-r.EVM_GMP_pct;
        r.ACPR_MP_minus_GMP_dB=r.ACPR_MP_dBc-r.ACPR_GMP_dBc;
        r.RxPower_MP_minus_GMP_dB=r.RxPower_MP_dBFS-r.RxPower_GMP_dBFS;
        r.STM32Power_MP_minus_GMP_dB=r.STM32Power_MP_dBm-r.STM32Power_GMP_dBm;

        % Official same-TxGain reference.
        r.Ref_EVM_SameTxGain_pct=interpCol(Tref,'TxGain_dB','EVM_NR_Aligned_pct',tx);
        r.Ref_ACPR_SameTxGain_dBc=interpCol(Tref,'TxGain_dB','ACPR_dBc',tx);

        r.MP_EVM_Improvement_vsOfficialSameTxGain_pct= ...
            r.Ref_EVM_SameTxGain_pct-r.EVM_MP_pct;
        r.GMP_EVM_Improvement_vsOfficialSameTxGain_pct= ...
            r.Ref_EVM_SameTxGain_pct-r.EVM_GMP_pct;
        r.MP_ACPR_Improvement_vsOfficialSameTxGain_dB= ...
            r.Ref_ACPR_SameTxGain_dBc-r.ACPR_MP_dBc;
        r.GMP_ACPR_Improvement_vsOfficialSameTxGain_dB= ...
            r.Ref_ACPR_SameTxGain_dBc-r.ACPR_GMP_dBc;

        % Equal RX power.
        [r.Ref_EVM_SameRxPower_MP_pct,r.Ref_ACPR_SameRxPower_MP_dBc] = ...
            interpReferenceAtPower(Tref,'RxPower_dBFS',r.RxPower_MP_dBFS);
        [r.Ref_EVM_SameRxPower_GMP_pct,r.Ref_ACPR_SameRxPower_GMP_dBc] = ...
            interpReferenceAtPower(Tref,'RxPower_dBFS',r.RxPower_GMP_dBFS);

        r.MP_EVM_Improvement_vsOfficialSameRxPower_pct= ...
            r.Ref_EVM_SameRxPower_MP_pct-r.EVM_MP_pct;
        r.GMP_EVM_Improvement_vsOfficialSameRxPower_pct= ...
            r.Ref_EVM_SameRxPower_GMP_pct-r.EVM_GMP_pct;
        r.MP_ACPR_Improvement_vsOfficialSameRxPower_dB= ...
            r.Ref_ACPR_SameRxPower_MP_dBc-r.ACPR_MP_dBc;
        r.GMP_ACPR_Improvement_vsOfficialSameRxPower_dB= ...
            r.Ref_ACPR_SameRxPower_GMP_dBc-r.ACPR_GMP_dBc;

        % Equal STM32 power.
        [r.Ref_EVM_SameSTM32Power_MP_pct,r.Ref_ACPR_SameSTM32Power_MP_dBc] = ...
            interpReferenceAtPower(Tref,'Power_mean_dB_stm32',r.STM32Power_MP_dBm);
        [r.Ref_EVM_SameSTM32Power_GMP_pct,r.Ref_ACPR_SameSTM32Power_GMP_dBc] = ...
            interpReferenceAtPower(Tref,'Power_mean_dB_stm32',r.STM32Power_GMP_dBm);

        r.MP_EVM_Improvement_vsOfficialSameSTM32Power_pct= ...
            r.Ref_EVM_SameSTM32Power_MP_pct-r.EVM_MP_pct;
        r.GMP_EVM_Improvement_vsOfficialSameSTM32Power_pct= ...
            r.Ref_EVM_SameSTM32Power_GMP_pct-r.EVM_GMP_pct;
        r.MP_ACPR_Improvement_vsOfficialSameSTM32Power_dB= ...
            r.Ref_ACPR_SameSTM32Power_MP_dBc-r.ACPR_MP_dBc;
        r.GMP_ACPR_Improvement_vsOfficialSameSTM32Power_dB= ...
            r.Ref_ACPR_SameSTM32Power_GMP_dBc-r.ACPR_GMP_dBc;

        r.EVMWinner=winnerLower(r.EVM_MP_pct,r.EVM_GMP_pct,"MP","GMP");
        r.ACPRWinner=winnerLower(r.ACPR_MP_dBc,r.ACPR_GMP_dBc,"MP","GMP");

        rows=[rows;r]; %#ok<AGROW>
    end
    summary=struct2table(rows);
end

function Trow=firstValidConditionRow(T,tx,condition)
    Trow=T(T.TxGain_dB==tx & T.Condition==condition & T.Usable,:);
    if ~isempty(Trow), Trow=Trow(1,:); end
end

function v=getTableScalar(Trow,name)
    if isempty(Trow), v=NaN; else, v=Trow.(name)(1); end
end

function [evm,acpr]=interpReferenceAtPower(Tref,powerCol,powerValue)
    evm=interpCol(Tref,powerCol,'EVM_NR_Aligned_pct',powerValue);
    acpr=interpCol(Tref,powerCol,'ACPR_dBc',powerValue);
end

function w=winnerLower(a,b,nameA,nameB)
    if ~isfinite(a) || ~isfinite(b)
        w="UNAVAILABLE";
    elseif abs(a-b)<1e-9
        w="TIE";
    elseif a<b
        w=string(nameA);
    else
        w=string(nameB);
    end
end

function R=buildGeneralizationRangeSummary(S,trainingTx)
    families=["MP","GMP"];
    rows=struct([]);
    for i=1:numel(families)
        f=families(i);
        if f=="MP"
            evmEq=S.MP_EVM_Improvement_vsOfficialSameRxPower_pct;
            acprEq=S.MP_ACPR_Improvement_vsOfficialSameRxPower_dB;
            evmLive=S.EVM_Improvement_MP_vsLiveNoDPD_pct;
            usable=S.MP_Usable;
        else
            evmEq=S.GMP_EVM_Improvement_vsOfficialSameRxPower_pct;
            acprEq=S.GMP_ACPR_Improvement_vsOfficialSameRxPower_dB;
            evmLive=S.EVM_Improvement_GMP_vsLiveNoDPD_pct;
            usable=S.GMP_Usable;
        end
        tx=S.TxGain_dB;

        maskEvmEq=usable & isfinite(evmEq) & evmEq>0;
        maskAcprEq=usable & isfinite(acprEq) & acprEq>0;
        maskBoth=maskEvmEq & maskAcprEq;
        maskLive=usable & isfinite(evmLive) & evmLive>0;

        r.Family=f;
        r.TrainingTxGain_dB=trainingTx;
        r.ValidPoints=sum(usable);
        r.EVMImproved_Live_Count=sum(maskLive);
        r.EVMImproved_EqualRxPower_Count=sum(maskEvmEq);
        r.ACPRImproved_EqualRxPower_Count=sum(maskAcprEq);
        r.BothImproved_EqualRxPower_Count=sum(maskBoth);
        r.MinTxGain_EVMImproved_EqualRxPower_dB=safeMin(tx(maskEvmEq));
        r.MaxTxGain_EVMImproved_EqualRxPower_dB=safeMax(tx(maskEvmEq));
        r.MinTxGain_BothImproved_EqualRxPower_dB=safeMin(tx(maskBoth));
        r.MaxTxGain_BothImproved_EqualRxPower_dB=safeMax(tx(maskBoth));
        r.MeanEVMImprovement_EqualRxPower_pct=mean(evmEq(maskEvmEq),'omitnan');
        r.MeanACPRImprovement_EqualRxPower_dB=mean(acprEq(maskAcprEq),'omitnan');
        rows=[rows;r]; %#ok<AGROW>
    end
    R=struct2table(rows);
end

function v=safeMin(x)
    if isempty(x), v=NaN; else, v=min(x); end
end

function v=safeMax(x)
    if isempty(x), v=NaN; else, v=max(x); end
end

function plotThreeConditions(T,xName,yName,yLabelText)
    hold on;
    conds=["No-DPD","MP","GMP"];
    marks={'o-','s-','d-'};
    for i=1:numel(conds)
        mask=T.Condition==conds(i) & T.Usable & ...
            isfinite(T.(xName)) & isfinite(T.(yName));
        [x,idx]=sort(T.(xName)(mask));
        y=T.(yName)(mask); y=y(idx);
        plot(x,y,marks{i},'LineWidth',1.15,'DisplayName',conds(i));
    end
    grid on;
    xlabel(strrep(xName,'_',' '));
    ylabel(yLabelText);
    legend('Location','best');
end

function T=buildSweepAMAMAMPMExport(txRef,txMP,txGMP,captureStore,txList,targetGains,maxSamples,decim)
    conditions=["No-DPD","MP","GMP"];
    txSignals={txRef,txMP,txGMP};
    keys={'No_DPD','MP','GMP'};
    T=table();

    for tg=targetGains
        [~,idxGain]=min(abs(txList-tg));
        actualGain=txList(idxGain);

        for ic=1:numel(conditions)
            res=captureStore.(keys{ic}){idxGain};
            if isempty(res) || ~res.usable, continue; end

            txApplied=txSignals{ic}(:);
            rx=res.rxAligned(:);
            L=min([numel(txRef),numel(txApplied),numel(rx)]);
            x=txRef(1:L);
            u=txApplied(1:L);
            y=rx(1:L);

            alpha=(y'*x)/(y'*y+eps);
            yScaled=alpha*y;

            idx=(1:decim:L).';
            if numel(idx)>maxSamples
                idx=idx(round(linspace(1,numel(idx),maxSamples)));
            end

            Tc=table();
            Tc.TxGain_dB=repmat(actualGain,numel(idx),1);
            Tc.Condition=repmat(conditions(ic),numel(idx),1);
            Tc.SampleIndex=idx;
            Tc.InputAmplitude=abs(x(idx));
            Tc.InputAmplitudeNormalized=abs(x(idx))/(max(abs(x))+eps);
            Tc.TxAppliedAmplitude=abs(u(idx));
            Tc.RxOutputAmplitude=abs(yScaled(idx));
            Tc.DPDPhaseShift_rad=angle(u(idx).*conj(x(idx)));
            Tc.ChainPhaseShift_rad=angle(yScaled(idx).*conj(x(idx)));
            Tc.TxReference_I=real(x(idx));
            Tc.TxReference_Q=imag(x(idx));
            Tc.TxApplied_I=real(u(idx));
            Tc.TxApplied_Q=imag(u(idx));
            Tc.RxScaled_I=real(yScaled(idx));
            Tc.RxScaled_Q=imag(yScaled(idx));
            T=[T;Tc]; %#ok<AGROW>
        end
    end
end

function T=buildSweepPSDExport(captureStore,txList,targetGains,fs,nfft,winLen)
    T=table();
    keys={'No_DPD','MP','GMP'};
    colNames={'PSD_NoDPD_dB','PSD_MP_dB','PSD_GMP_dB'};

    for tg=targetGains
        [~,idxGain]=min(abs(txList-tg));
        actualGain=txList(idxGain);
        P=cell(3,1);
        fCommon=[];

        for ic=1:3
            res=captureStore.(keys{ic}){idxGain};
            if isempty(res) || ~res.usable
                P{ic}=nan(nfft,1);
                continue;
            end
            x=res.rxAligned(:);
            N=min(numel(x),262144);
            x=x(1:N)-mean(x(1:N));
            w=hamming(min(winLen,N));
            [pxx,f]=pwelch(x,w,[],nfft,fs,'centered');
            p=10*log10(pxx+eps);
            P{ic}=p-max(p);
            if isempty(fCommon), fCommon=f; end
        end

        if isempty(fCommon), continue; end
        Tp=table();
        Tp.TxGain_dB=repmat(actualGain,numel(fCommon),1);
        Tp.Frequency_Hz=fCommon;
        Tp.Frequency_MHz=fCommon/1e6;
        Tp.PSD_NoDPD_dB=P{1};
        Tp.PSD_MP_dB=P{2};
        Tp.PSD_GMP_dB=P{3};
        T=[T;Tp]; %#ok<AGROW>
    end
end

function T=buildSweepNotebookMetadata(txList,targetGains,fs,papr0,paprMP,paprGMP,mpDiag,gmpDiag)
    actual=arrayfun(@(g) txList(find(abs(txList-g)==min(abs(txList-g)),1)),targetGains);
    T=table();
    T.SampleRate_Hz=fs;
    T.SweepMinTxGain_dB=min(txList);
    T.SweepMaxTxGain_dB=max(txList);
    T.SweepStep_dB=median(diff(txList));
    T.ExportRequestedTxGains=string(mat2str(targetGains));
    T.ExportActualTxGains=string(mat2str(actual));
    T.PAPR_NoDPD_dB=papr0;
    T.PAPR_MP_dB=paprMP;
    T.PAPR_GMP_dB=paprGMP;
    T.MP_PostAveragePowerRatio_dB=mpDiag.PostAveragePowerRatio_dB;
    T.GMP_PostAveragePowerRatio_dB=gmpDiag.PostAveragePowerRatio_dB;
    T.MP_PeakScaleApplied=mpDiag.PeakScaleApplied;
    T.GMP_PeakScaleApplied=gmpDiag.PeakScaleApplied;
end

function [y,diagInfo]=normalizeDPDWaveformDetailed(yRaw,xRef,maxPeakRatio)
    yRaw=yRaw(:); xRef=xRef(:);
    pRef=mean(abs(xRef).^2);
    pRaw=mean(abs(yRaw).^2);

    diagInfo=struct();
    diagInfo.RawAveragePowerRatio_dB=10*log10((pRaw+eps)/(pRef+eps));
    diagInfo.PeakScaleApplied=1;
    diagInfo.NumSamplesAbovePeakBeforeScaling=0;

    y=yRaw;
    if isfinite(pRef)&&isfinite(pRaw)&&pRef>0&&pRaw>0
        y=y*sqrt(pRef/pRaw);
    end

    maxAllowed=maxPeakRatio*max(abs(xRef));
    currentPeak=max(abs(y));
    diagInfo.NumSamplesAbovePeakBeforeScaling=nnz(abs(y)>maxAllowed);
    if isfinite(currentPeak)&&currentPeak>maxAllowed&&currentPeak>0
        diagInfo.PeakScaleApplied=maxAllowed/currentPeak;
        y=y*diagInfo.PeakScaleApplied;
    end
    diagInfo.PostAveragePowerRatio_dB= ...
        10*log10((mean(abs(y).^2)+eps)/(pRef+eps));
end

function y=applyGMP(x,c,p)
    x=x(:);
    [X,validIdx]=buildGMPMatrix_EXP018(x,p);
    y=x;
    if numel(c)~=size(X,2)
        error('GMP coefficient count mismatch.');
    end
    y(validIdx)=X*c;
end

function [X,validIdx]=buildGMPMatrix_EXP018(x,p)
    x=x(:);
    N=numel(x);
    maxPast=max([p.La-1,p.Lb-1+p.Mb,0]);
    maxFuture=max([p.Lc-1+p.Mc,0]);
    validIdx=(1+maxPast:N-maxFuture).';
    if isempty(validIdx), error('Signal too short for GMP structure.'); end

    nCoeff=p.Ka*p.La + p.Kb*p.Lb*p.Mb + p.Kc*p.Lc*p.Mc;
    X=complex(zeros(numel(validIdx),nCoeff));
    col=1;

    for l=0:p.La-1
        s=x(validIdx-l);
        for k=0:p.Ka-1
            X(:,col)=s.*abs(s).^(2*k); col=col+1;
        end
    end

    for l=0:p.Lb-1
        s=x(validIdx-l);
        for m=1:p.Mb
            env=abs(x(validIdx-l-m));
            for k=1:p.Kb
                X(:,col)=s.*env.^(2*k); col=col+1;
            end
        end
    end

    for l=0:p.Lc-1
        s=x(validIdx-l);
        for m=1:p.Mc
            env=abs(x(validIdx-l+m));
            for k=1:p.Kc
                X(:,col)=s.*env.^(2*k); col=col+1;
            end
        end
    end
end


function filePath = resolveFilePath(fileName, scriptDir)
    filePath = string(fileName);
    candidates = strings(0,1);
    candidates(end+1) = filePath;
    candidates(end+1) = fullfile(pwd, filePath);
    candidates(end+1) = fullfile(scriptDir, filePath);
    candidates(end+1) = fullfile(fileparts(scriptDir), filePath);
    candidates(end+1) = fullfile(scriptDir, "data", filePath);
    for k = 1:numel(candidates)
        if strlength(candidates(k)) > 0 && exist(candidates(k), 'file')
            filePath = candidates(k);
            return;
        end
    end
    error('File not found: %s. Use an absolute path in the configuration.', fileName);
end

function filePath = resolveOrAutoFindFile(fileName, scriptDir, pattern)
    if strlength(string(fileName)) > 0
        filePath = resolveFilePath(fileName, scriptDir);
        return;
    end
    projectDirLocal = fileparts(scriptDir);
    searchRoots = [string(pwd); string(scriptDir); string(fullfile(scriptDir,"data")); string(fullfile(projectDirLocal,"data")); string(fullfile(projectDirLocal,"baseline"))];
    matches = [];
    for r = 1:numel(searchRoots)
        if exist(searchRoots(r), 'dir')
            m = dir(fullfile(searchRoots(r), "**", pattern));
            matches = [matches; m(:)]; %#ok<AGROW>
        end
    end
    if isempty(matches)
        error('Could not auto-find file with pattern: %s. Set the CSV path manually.', pattern);
    end
    [~, idx] = max([matches.datenum]);
    filePath = fullfile(matches(idx).folder, matches(idx).name);
end



function filePath = resolveOrAutoFindOfficialReference(fileName, scriptDir, rxGainTarget)
    if strlength(string(fileName)) > 0
        filePath = resolveFilePath(fileName, scriptDir);
        return;
    end

    projectDirLocal = fileparts(scriptDir);
    dataDirLocal = fullfile(projectDirLocal, "data");
    matches = dir(fullfile(dataDirLocal, "**", "*OFFICIAL_NODPD_REFERENCE*.csv"));
    if isempty(matches)
        error('Could not auto-find OFFICIAL_NODPD_REFERENCE under %s. Set officialNoDPDReferenceCsv manually.', dataDirLocal);
    end

    % Prefer EXP009F / NODPD_FULLSWEEP references with the requested RX gain.
    keep = true(numel(matches),1);
    for ii = 1:numel(matches)
        nameFolder = string(fullfile(matches(ii).folder, matches(ii).name));
        keep(ii) = contains(nameFolder, "EXP009F") || contains(nameFolder, "NODPD_FULLSWEEP");
    end
    if any(keep)
        matches = matches(keep);
    end

    rxKeep = false(numel(matches),1);
    for ii = 1:numel(matches)
        try
            Ttmp = readtable(fullfile(matches(ii).folder, matches(ii).name));
            if ismember('RxGain_dB', Ttmp.Properties.VariableNames)
                rxVals = Ttmp.RxGain_dB(isfinite(Ttmp.RxGain_dB));
                rxKeep(ii) = ~isempty(rxVals) && abs(median(rxVals) - rxGainTarget) < 0.25;
            elseif ismember('RxGain_Pluto_dB', Ttmp.Properties.VariableNames)
                rxVals = Ttmp.RxGain_Pluto_dB(isfinite(Ttmp.RxGain_Pluto_dB));
                rxKeep(ii) = ~isempty(rxVals) && abs(median(rxVals) - rxGainTarget) < 0.25;
            else
                % If the column is not present, do not discard; use modified time fallback.
                rxKeep(ii) = true;
            end
        catch
            rxKeep(ii) = false;
        end
    end
    if any(rxKeep)
        matches = matches(rxKeep);
    end

    [~, idx] = max([matches.datenum]);
    filePath = string(fullfile(matches(idx).folder, matches(idx).name));
end

function stm = initSTM32ResultStruct()
    stm = struct();
    stm.Power_mean_dB_stm32 = NaN;
    stm.Power_std_dB_stm32 = NaN;
    stm.Voltage_mean_V = NaN;
    stm.Voltage_std_V = NaN;
    stm.ADC_mean_raw = NaN;
    stm.N_power_valid = 0;
    stm.N_power_invalid = 0;
end

function stmRes = measureSTM32PowerIfEnabled(useSTM32PowerMeter, stm, fidPower, pointIndex, condition, txGain, rxGain, nPowerSamplesPerPoint)
    stmRes = initSTM32ResultStruct();
    if ~useSTM32PowerMeter || isempty(stm)
        return;
    end
    try
        flush(stm);
        cmd = sprintf("MEAS,%.2f,%d", txGain, nPowerSamplesPerPoint);
        fprintf("  STM32 [%s]: %s\n", condition, cmd);
        writeline(stm, cmd);
        [pVals, vVals, adcVals, nRec, nInv] = readSTM32PowerBlock_EXP018(stm, fidPower, pointIndex, condition, txGain, rxGain);
        stmRes.N_power_valid = nRec;
        stmRes.N_power_invalid = nInv;
        if ~isempty(pVals)
            stmRes.Power_mean_dB_stm32 = mean(pVals, "omitnan");
            stmRes.Power_std_dB_stm32 = std(pVals, "omitnan");
        end
        if ~isempty(vVals)
            stmRes.Voltage_mean_V = mean(vVals, "omitnan");
            stmRes.Voltage_std_V = std(vVals, "omitnan");
        end
        if ~isempty(adcVals)
            stmRes.ADC_mean_raw = mean(adcVals, "omitnan");
        end
        fprintf("  STM32 summary [%s]: P=%.3f dB | V=%.4f V | N=%d valid\n", ...
            condition, stmRes.Power_mean_dB_stm32, stmRes.Voltage_mean_V, stmRes.N_power_valid);
    catch ME
        warning("STM32 measurement failed at point %d, %s, TxGain %.2f: %s", pointIndex, condition, txGain, ME.message);
    end
end

function [powerValues_dB, voltageValues_V, adcValues_raw, nReceived, nInvalid] = readSTM32PowerBlock_EXP018(stm, fidPower, pointIndex, condition, txGain, rxGain)
    nReceived = 0;
    nInvalid = 0;
    gotEnd = false;
    powerValues_dB = [];
    voltageValues_V = [];
    adcValues_raw = [];

    while ~gotEnd
        line = strtrim(string(readline(stm)));
        if strlength(line) == 0
            continue;
        end
        if startsWith(line, "START")
            fprintf("    %s\n", line);
        elseif startsWith(line, "DATA")
            parts = split(line, ",");
            if numel(parts) >= 5
                stm32_time_ms = str2double(parts{2});
                adc_raw = str2double(parts{3});
                voltage_V = str2double(parts{4});
                power_dB = str2double(parts{5});

                if isfinite(power_dB); powerValues_dB(end+1,1) = power_dB; end %#ok<AGROW>
                if isfinite(voltage_V); voltageValues_V(end+1,1) = voltage_V; end %#ok<AGROW>
                if isfinite(adc_raw); adcValues_raw(end+1,1) = adc_raw; end %#ok<AGROW>

                if fidPower > 0
                    pc_timestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));
                    fprintf(fidPower, "%s,%d,%s,%.2f,%.2f,%.0f,%.0f,%.9f,%.6f,%s\n", ...
                        pc_timestamp, pointIndex, condition, txGain, rxGain, stm32_time_ms, adc_raw, voltage_V, power_dB, sanitizeCsvField_EXP018(line));
                end
                nReceived = nReceived + 1;
            else
                nInvalid = nInvalid + 1;
            end
        elseif startsWith(line, "END")
            fprintf("    %s\n", line);
            gotEnd = true;
        elseif startsWith(line, "ERR")
            warning("STM32 respondio error: %s", line);
            gotEnd = true;
        else
            fprintf("    STM32: %s\n", line);
        end
    end
end

function safe = sanitizeCsvField_EXP018(txt)
    safe = string(txt);
    safe = replace(safe, '"', '""');
    safe = '"' + safe + '"';
end

function [evm, acpr, rxPow, stmPow] = interpOfficialSameTxGain(Tref, txGain)
    evm = interpCol(Tref, 'TxGain_dB', 'EVM_NR_Aligned_pct', txGain);
    acpr = interpCol(Tref, 'TxGain_dB', 'ACPR_dBc', txGain);
    rxPow = interpCol(Tref, 'TxGain_dB', 'RxPower_dBFS', txGain);
    stmPow = interpCol(Tref, 'TxGain_dB', 'Power_mean_dB_stm32', txGain);
end

function [evm, acpr, txGain] = interpOfficialSameRxPower(Tref, rxPower)
    evm = interpCol(Tref, 'RxPower_dBFS', 'EVM_NR_Aligned_pct', rxPower);
    acpr = interpCol(Tref, 'RxPower_dBFS', 'ACPR_dBc', rxPower);
    txGain = interpCol(Tref, 'RxPower_dBFS', 'TxGain_dB', rxPower);
end

function [evm, acpr, txGain, rxPow] = interpOfficialSameSTM32Power(Tref, stm32Power)
    evm = interpCol(Tref, 'Power_mean_dB_stm32', 'EVM_NR_Aligned_pct', stm32Power);
    acpr = interpCol(Tref, 'Power_mean_dB_stm32', 'ACPR_dBc', stm32Power);
    txGain = interpCol(Tref, 'Power_mean_dB_stm32', 'TxGain_dB', stm32Power);
    rxPow = interpCol(Tref, 'Power_mean_dB_stm32', 'RxPower_dBFS', stm32Power);
end

function yq = interpCol(T, xCol, yCol, xq)
    yq = NaN;
    if ~ismember(xCol, T.Properties.VariableNames) || ~ismember(yCol, T.Properties.VariableNames)
        return;
    end
    x = T.(xCol); y = T.(yCol);
    if ismember('Accepted', T.Properties.VariableNames)
        okAccepted = logical(T.Accepted);
    else
        okAccepted = true(size(x));
    end
    ok = okAccepted & isfinite(x) & isfinite(y);
    x = x(ok); y = y(ok);
    if numel(x) < 3 || ~isfinite(xq)
        return;
    end
    [xSort, idx] = sort(x);
    ySort = y(idx);
    [xUnique, ia] = unique(xSort, 'stable');
    yUnique = ySort(ia);
    if xq < min(xUnique) || xq > max(xUnique)
        return;
    end
    if numel(xUnique) >= 4
        yq = interp1(xUnique, yUnique, xq, 'pchip');
    else
        yq = interp1(xUnique, yUnique, xq, 'linear');
    end
end

function plotCondition(T, xName, yName, yLabelText)
    hold on;
    conds = ["No-DPD", "DPD"];
    for c = conds
        mask = T.Condition == c & T.Usable & isfinite(T.(xName)) & isfinite(T.(yName));
        plot(T.(xName)(mask), T.(yName)(mask), 'o-', 'LineWidth', 1.2, 'DisplayName', c);
    end
    grid on; xlabel(strrep(xName,'_',' ')); ylabel(yLabelText); legend('Location','best');
end

function result = captureAndMeasureWithRetry( ...
    rxObj, txReference, cfgDL, cfgEVM, sampleRate, ...
    captureTime_s, totalSamplesNeeded, samplesPerFrame, ...
    maxCaptureAttempts, evmRetryThreshold_pct, minSyncMetric, ...
    alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign, ...
    rawDir, saveRawCaptures, label, txGain, rxGain)

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
            rawFile = fullfile(rawDir, sprintf('%s_tx_%+05.2fdB_rx_%+05.2fdB_attempt_%d.mat', label, txGain, rxGain, attempt));
            save(rawFile, 'rxCapture', 'txGain', 'rxGain', 'attempt');
        end

        try
            [alignInfo, alignedData] = robustAlignTxRxForDPD(txReference, rxCapture, sampleRate, ...
                alignDecimationFactor, fineSearchHalfWindow_samples, phaseFitMagnitudeThreshold, numFramesForAlign);
        catch ME
            fprintf('    Robust alignment failed: %s\n', ME.message);
            continue;
        end

        rxAligned = alignedData.y_cfo_corrected(:);
        syncMetric = alignInfo.syncMetric;
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
            evm_pct, acpr_dBc, alignInfo.rxPower_dBFS, alignInfo.peakRx_dBFS, syncMetric, alignInfo.nmse_dB);

        candidate = initResultStruct();
        candidate.usable = true;
        candidate.retryFailed = false;
        candidate.attemptCount = attempt;
        candidate.evm_pct = evm_pct;
        candidate.acpr_dBc = acpr_dBc;
        candidate.rxPower_dBFS = alignInfo.rxPower_dBFS;
        candidate.peakRx_dBFS = alignInfo.peakRx_dBFS;
        candidate.nmse_aligned_dB = alignInfo.nmse_dB;
        candidate.waveformEVM_pct = alignInfo.waveformEVM_pct;
        candidate.syncMetric = syncMetric;
        candidate.freqOffset_Hz = alignInfo.freqOffset_Hz;
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
        end
    end

    if ~best.usable || ~isfinite(best.evm_pct) || best.evm_pct >= evmRetryThreshold_pct || ...
            ~isfinite(best.syncMetric) || best.syncMetric < minSyncMetric
        result = initResultStruct();
        result.usable = false;
        result.retryFailed = true;
        result.attemptCount = maxCaptureAttempts;
        result.syncMetric = best.syncMetric;
        fprintf('    Datum killed after %d attempts.\n', maxCaptureAttempts);
        return;
    end

    result = best;
    result.attemptCount = maxCaptureAttempts;
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
    s.syncMetric = NaN;
    s.freqOffset_Hz = NaN;
    s.rxAligned = [];
    s.rawCapture = [];
    s.eqSymb = [];
    s.refSymb = [];
end

function [alignInfo, alignedData] = robustAlignTxRxForDPD(xTx, yRx, Fs, D, fineHalfWin, magThrRel, numFramesForAlign)
    %#ok<INUSD>
    % EXP008/EXP010I result: best synchronization mode is NORMAL_NO_CFO.
    % This local sweep therefore uses the same mode as the DPD training:
    % coarse decimated correlation + fine integer-delay search + scalar
    % complex-gain normalization, intentionally without external CFO correction.

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

function X = buildMPMatrix(signal, M, K)
    signal = signal(:);
    L = length(signal);
    if L <= M; error('Signal length must be larger than M.'); end
    X = zeros(L-M, (M+1)*K);
    col = 1;
    for m=0:M
        s = signal(M+1-m:end-m);
        for k=0:K-1
            X(:,col) = s .* abs(s).^(2*k);
            col = col + 1;
        end
    end
end

function y = applyMemoryPolynomial(x, coeffs, M, K)
    x = x(:);
    y = x;
    X = buildMPMatrix(x, M, K);
    y(M+1:end) = X * coeffs;
    if M > 0; y(1:M) = x(1:M); end
end

function acpr_dBc = computeACPRCentered(x, fs, bw)
    acpr_dBc = NaN;
    try
        x = x(:);
        if isempty(x) || length(x)<1024; return; end
        N = min(614400, length(x));
        x = x(1:N) - mean(x(1:N));
        winLen = min(4096,N);
        nfft = max(4096, 2^nextpow2(min(N,262144)));
        [pxx,f] = pwelch(x, hamming(winLen), [], nfft, fs, 'centered');
        mainIdx = abs(f)<=bw/2;
        adjLowIdx = (f>=-1.5*bw) & (f<-0.5*bw);
        adjHighIdx = (f>0.5*bw) & (f<=1.5*bw);
        pMain = trapz(f(mainIdx), pxx(mainIdx));
        pAdj = 0;
        if any(adjLowIdx); pAdj = pAdj + trapz(f(adjLowIdx), pxx(adjLowIdx)); end
        if any(adjHighIdx); pAdj = pAdj + trapz(f(adjHighIdx), pxx(adjHighIdx)); end
        if pMain>0 && pAdj>0; acpr_dBc = 10*log10(pAdj/pMain); end
    catch ME
        warning('ACPR failed: %s', ME.message);
    end
end


function plotAMAM_AMPM_LocalSweep(txOriginal, txDPD, rxNoDPD, rxDPD, txGain)
    txOriginal = txOriginal(:);
    txDPD = txDPD(:);
    rxNoDPD = rxNoDPD(:);
    rxDPD = rxDPD(:);

    L = min([length(txOriginal), length(txDPD), length(rxNoDPD), length(rxDPD), 120000]);
    txOriginal = txOriginal(1:L);
    txDPD = txDPD(1:L);
    rxNoDPD = rxNoDPD(1:L);
    rxDPD = rxDPD(1:L);

    alphaNo = (rxNoDPD' * txOriginal) / (rxNoDPD' * rxNoDPD + eps);
    alphaDpd = (rxDPD' * txOriginal) / (rxDPD' * rxDPD + eps);
    rxNoScaled = alphaNo * rxNoDPD;
    rxDpdScaled = alphaDpd * rxDPD;

    xAmp = abs(txOriginal);
    xAmpNorm = xAmp / (max(xAmp) + eps);
    commonScale = max([abs(txOriginal); abs(txDPD); abs(rxNoScaled); abs(rxDpdScaled)] + eps);

    yNo = abs(rxNoScaled) / commonScale;
    yPred = abs(txDPD) / commonScale;
    yDpd = abs(rxDpdScaled) / commonScale;

    phNo = angle(rxNoScaled .* conj(txOriginal));
    phPred = angle(txDPD .* conj(txOriginal));
    phDpd = angle(rxDpdScaled .* conj(txOriginal));

    tiledlayout(2,1);

    nexttile;
    scatter(xAmpNorm, yNo, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03); hold on;
    scatter(xAmpNorm, yPred, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    scatter(xAmpNorm, yDpd, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    grid on;
    xlabel('Normalized input amplitude');
    ylabel('Normalized amplitude');
    title(sprintf('AM/AM local sweep at TxGain %.2f dB', txGain));
    legend('Chain output w/o DPD','DPD waveform','Chain output with DPD','Location','best');

    nexttile;
    scatter(xAmpNorm, phNo, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03); hold on;
    scatter(xAmpNorm, phPred, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    scatter(xAmpNorm, phDpd, 5, 'filled', 'MarkerFaceAlpha', 0.03, 'MarkerEdgeAlpha', 0.03);
    grid on;
    xlabel('Normalized input amplitude');
    ylabel('Phase shift (rad)');
    title(sprintf('AM/PM local sweep at TxGain %.2f dB', txGain));
    legend('Chain output w/o DPD','DPD waveform','Chain output with DPD','Location','best');
end

function plotPSDComparison(rx0, rx1, fs, acpr0, acpr1, txGain)
    rx0 = rx0(:); rx1 = rx1(:);
    N = min([numel(rx0), numel(rx1), 262144]);
    rx0 = rx0(1:N); rx1 = rx1(1:N);
    nfft = 8192; win = hamming(4096);
    [P0,f] = pwelch(rx0, win, [], nfft, fs, 'centered');
    [P1,~] = pwelch(rx1, win, [], nfft, fs, 'centered');
    P0dB = 10*log10(P0+eps); P1dB = 10*log10(P1+eps);
    P0dB = P0dB - max(P0dB); P1dB = P1dB - max(P1dB);
    plot(f/1e6, P0dB, 'LineWidth', 1.3); hold on;
    plot(f/1e6, P1dB, 'LineWidth', 1.3);
    xline(-10,'--k'); xline(10,'--k'); xline(-30,':k'); xline(30,':k');
    grid on; xlabel('Frequency (MHz)'); ylabel('PSD (dB normalized)');
    title(sprintf('PSD comparison at TxGain %.2f dB | ACPR no-DPD %.2f dBc | DPD %.2f dBc', txGain, acpr0, acpr1));
    legend('No-DPD','DPD','Location','best');
end

function setSafeState(txObj, idleGain)
    try
        txObj.Gain = idleGain;
        transmitRepeat(txObj, zeros(1000,1));
    catch
    end
end

function cleanupAll(txObj, rxObj, idleGain, fidPower)
    try; setSafeState(txObj, idleGain); catch; end
    try; release(txObj); catch; end
    try; release(rxObj); catch; end
    try
        if fidPower > 0
            fclose(fidPower);
        end
    catch
    end
end
