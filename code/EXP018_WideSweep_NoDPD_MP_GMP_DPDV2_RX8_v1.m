%% ========================================================================
%  EXP018 — WIDE TX-GAIN SWEEP: NO-DPD vs MP vs GMP
%  ----------------------------------------------------------------------
%  Purpose:
%    Validate the generalization range of the two models selected in EXP017:
%
%      1) Memory Polynomial MP_M5_K5: 30 complex coefficients
%      2) GMP_F1_29C:              29 complex coefficients
%
%    The two predistorters are trained at TxGain = -22.25 dB and then kept
%    fixed while TxGain is swept from -27 dB to -17 dB.
%
%  Main comparisons:
%    - EVM, ACPR, NMSE and received power versus TxGain
%    - MP versus GMP at the same TxGain
%    - MP/GMP versus official no-DPD reference at equal RX power
%    - MP/GMP versus official no-DPD reference at equal STM32 power
%    - Validity/generalization range around the training point
%    - AM/AM, AM/PM and PSD exports for Python/Jupyter
%
%  Measurement order rotates at each sweep point to reduce thermal bias:
%    Point 1: No-DPD -> MP -> GMP
%    Point 2: GMP    -> No-DPD -> MP
%    Point 3: MP     -> GMP -> No-DPD
%
%  IMPORTANT:
%    The same fixed MP and GMP coefficient vectors are used over the entire
%    sweep. No retraining is performed at individual TxGain values.
%% ========================================================================

clear; close all; clc;

%% ========================================================================
% USER CONFIGURATION
%% ========================================================================

deviceName = "Pluto";
centerFrequency = 5e9;
idleGain_dB = -80;

fixedRxGain_Pluto = 8;
powerScaleFactor = 0.8;

% Wide validation sweep.
TxGainList = (-27.00:0.50:-17.00).';
trainedTxGain_dB = -22.25;

% Points exported for AM/AM, AM/PM and PSD notebook figures.
% The closest available sweep value is used.
notebookExportTxGains_dB = [-26.0 -24.0 -22.0 -20.0 -18.0];

% EXP017 coefficient CSV. Leave empty to auto-detect latest.
coefficientsCsv = "";

% Official no-DPD reference from EXP009F. Leave empty to auto-detect latest.
officialNoDPDReferenceCsv = "";

% Explicit fair-comparison model selections.
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

% Use the same waveform guard as EXP017.
maxPredistortedPeakRatio = 1.10;

% Capture settings.
captureTime_s = 30e-3;
maxCaptureAttempts = 4;
evmRetryThreshold_pct = 80;
minSyncMetric = 0.95;

% Alignment copied from EXP009/EXP017.
alignDecimationFactor = 16;
fineSearchHalfWindow_samples = 4000;
phaseFitMagnitudeThreshold = 0.05;
numFramesForAlign = 1;

% Safety/acceptance limits.
digitalRxSaturationLimit_dBFS = -3.0;
hardStopEVM_pct = 60;
hardStopConsecutiveInvalidPoints = 2;

% Save full raw captures? Useful but large.
saveRawCaptures = false;
plotMaxSymbols = 6000;

% Notebook CSV export.
exportNotebookCSVs = true;
plotExportMaxSamplesPerCondition = 50000;
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
if isempty(scriptDir)
    scriptDir = pwd;
end
try
    addpath(fullfile(matlabroot,'examples','5g', ...
        'NRWaveformCaptureAndAnalysisWithSDRExample'));
catch
end

timeTag = string(datetime("now","Format","yyyyMMdd_HHmmss"));
projectDir = fileparts(scriptDir);
dataDir = fullfile(projectDir,"data");
if ~exist(dataDir,"dir"), mkdir(dataDir); end

baseName = "EXP018_WideSweep_NoDPD_MP_GMP_RX8_" + timeTag;
outputRoot = fullfile(dataDir,baseName);
rawDir = fullfile(outputRoot,"raw");
processedDir = fullfile(outputRoot,"processed");
figuresDir = fullfile(outputRoot,"figures");
notebookDir = fullfile(outputRoot,"notebook_csv");

for d = [{rawDir},{processedDir},{figuresDir},{notebookDir}]
    if ~exist(d{1},"dir"), mkdir(d{1}); end
end

resultsCsvFile = fullfile(processedDir,baseName+"_all_conditions.csv");
summaryCsvFile = fullfile(processedDir,baseName+"_pointwise_comparison.csv");
rangeSummaryCsvFile = fullfile(processedDir,baseName+"_generalization_summary.csv");
powerRawCsvFile = fullfile(rawDir,baseName+"_stm32_power_raw.csv");
matFile = fullfile(processedDir,baseName+"_results.mat");

amamCsvFile = fullfile(notebookDir,baseName+"_AMAM_AMPM_samples.csv");
psdCsvFile = fullfile(notebookDir,baseName+"_PSD_traces.csv");
notebookMetaCsvFile = fullfile(notebookDir,baseName+"_export_metadata.csv");

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

fprintf('\n===== EXP018 SETUP =====\n');
fprintf('MP model:  %s | iteration %d | M=%d K=%d | coeffs=%d\n', ...
    mpModelID,mpIteration,mpM,mpK,numel(coeffMP));
fprintf('GMP model: %s | iteration %d | coeffs=%d\n', ...
    gmpModelID,gmpIteration,numel(coeffGMP));
fprintf('Coefficient CSV: %s\n',coeffPath);
fprintf('Official no-DPD reference: %s\n',officialRefPath);
fprintf('Sweep: %.2f to %.2f dB, step %.2f dB\n', ...
    min(TxGainList),max(TxGainList),median(diff(TxGainList)));
fprintf('Training point: %.2f dB | RX gain %.2f dB\n', ...
    trainedTxGain_dB,fixedRxGain_Pluto);
fprintf('Sample rate: %.3f Msps | No-DPD PAPR %.2f dB\n', ...
    sampleRate/1e6,PAPR_noDPD_dB);

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
% TX-GAIN SWEEP: NO-DPD, MP AND GMP
%% ========================================================================

conditions = ["No-DPD","MP","GMP"];
txSignals = struct("No_DPD",txWaveform,"MP",txMP,"GMP",txGMP);
paprByCondition = struct("No_DPD",PAPR_noDPD_dB,"MP",PAPR_MP_dB,"GMP",PAPR_GMP_dB);

% Rotating order to mitigate thermal/time-order bias.
measurementOrders = {
    ["No-DPD","MP","GMP"]
    ["GMP","No-DPD","MP"]
    ["MP","GMP","No-DPD"]
};

nP = numel(TxGainList);
rows = repmat(initSweepRow(),0,1);
captureStore = struct();
captureStore.No_DPD = cell(nP,1);
captureStore.MP = cell(nP,1);
captureStore.GMP = cell(nP,1);

consecutiveAllInvalid = 0;

for i = 1:nP
    txGain = TxGainList(i);
    thisOrder = measurementOrders{mod(i-1,numel(measurementOrders))+1};

    fprintf('\n=======================================================\n');
    fprintf('Sweep point %d/%d | TxGain %.2f dB | order: %s -> %s -> %s\n', ...
        i,nP,txGain,thisOrder(1),thisOrder(2),thisOrder(3));
    fprintf('=======================================================\n');

    validAtPoint = 0;

    for io = 1:numel(thisOrder)
        condition = thisOrder(io);
        key = matlab.lang.makeValidName(strrep(char(condition),'-','_'));
        if condition=="No-DPD"
            txCurrent = txWaveform;
            paprCurrent = PAPR_noDPD_dB;
            modelID = "NONE";
            modelIteration = 0;
        elseif condition=="MP"
            txCurrent = txMP;
            paprCurrent = PAPR_MP_dB;
            modelID = mpModelID;
            modelIteration = mpIteration;
        else
            txCurrent = txGMP;
            paprCurrent = PAPR_GMP_dB;
            modelID = gmpModelID;
            modelIteration = gmpIteration;
        end

        fprintf('\n%s capture at TxGain %.2f dB\n',condition,txGain);
        sdrTransmitter.Gain = txGain;
        transmitRepeat(sdrTransmitter,txCurrent);
        pause(0.7);

        res = captureAndMeasureWithRetry( ...
            sdrReceiver,txCurrent,cfgDLFRC,cfgEVM,sampleRate, ...
            captureTime_s,totalSamplesNeeded,samplesPerFrame, ...
            maxCaptureAttempts,evmRetryThreshold_pct,minSyncMetric, ...
            alignDecimationFactor,fineSearchHalfWindow_samples, ...
            phaseFitMagnitudeThreshold,numFramesForAlign, ...
            rawDir,saveRawCaptures, ...
            sprintf('%s_tx_%+05.2f',condition,txGain), ...
            txGain,fixedRxGain_Pluto);

        stmRes = measureSTM32PowerIfEnabled( ...
            useSTM32PowerMeter,stm,fidPower,i,condition, ...
            txGain,fixedRxGain_Pluto,nPowerSamplesPerPoint);

        row = makeSweepResultRow( ...
            i,io,condition,txGain,fixedRxGain_Pluto, ...
            modelID,modelIteration,paprCurrent,res,stmRes, ...
            trainedTxGain_dB);

        rows(end+1,1) = row; %#ok<SAGROW>
        captureStore.(key){i} = res;

        if res.usable
            validAtPoint = validAtPoint+1;
        end

        % Safety warnings. Do not automatically terminate for one bad model.
        if res.usable && res.peakRx_dBFS >= digitalRxSaturationLimit_dBFS
            warning('%s at TxGain %.2f dB is close to digital RX saturation: %.2f dBFS.', ...
                condition,txGain,res.peakRx_dBFS);
        end
        if res.usable && isfinite(res.evm_pct) && res.evm_pct >= hardStopEVM_pct
            warning('%s at TxGain %.2f dB has EVM %.2f %% above hard-stop diagnostic.', ...
                condition,txGain,res.evm_pct);
        end

        setSafeState(sdrTransmitter,idleGain_dB);
        pause(0.25);
    end

    if validAtPoint==0
        consecutiveAllInvalid = consecutiveAllInvalid+1;
    else
        consecutiveAllInvalid = 0;
    end

    if consecutiveAllInvalid >= hardStopConsecutiveInvalidPoints
        warning('Stopping sweep: all three conditions invalid at %d consecutive points.', ...
            consecutiveAllInvalid);
        break;
    end
end

setSafeState(sdrTransmitter,idleGain_dB);

resultsTable = struct2table(rows);
writetable(resultsTable,resultsCsvFile);

summaryTable = buildThreeConditionComparisonSummary( ...
    resultsTable,TrefOfficial);
writetable(summaryTable,summaryCsvFile);

rangeSummaryTable = buildGeneralizationRangeSummary( ...
    summaryTable,trainedTxGain_dB);
writetable(rangeSummaryTable,rangeSummaryCsvFile);

disp(rangeSummaryTable);

%% ========================================================================
% NOTEBOOK CSV EXPORTS
%% ========================================================================

if exportNotebookCSVs
    amamTable = buildSweepAMAMAMPMExport( ...
        txWaveform,txMP,txGMP,captureStore,TxGainList, ...
        notebookExportTxGains_dB, ...
        plotExportMaxSamplesPerCondition,plotExportDecimation);
    writetable(amamTable,amamCsvFile);

    psdTable = buildSweepPSDExport( ...
        captureStore,TxGainList,notebookExportTxGains_dB, ...
        sampleRate,psdExportNFFT,psdExportWindowLength);
    writetable(psdTable,psdCsvFile);

    metaTable = buildSweepNotebookMetadata( ...
        TxGainList,notebookExportTxGains_dB,sampleRate, ...
        PAPR_noDPD_dB,PAPR_MP_dB,PAPR_GMP_dB, ...
        mpNormDiag,gmpNormDiag);
    writetable(metaTable,notebookMetaCsvFile);
end

%% ========================================================================
% MATLAB FIGURES
%% ========================================================================

try
    h1=figure('Name','EXP018 EVM and ACPR vs TxGain','Color','w');
    tiledlayout(2,1);
    nexttile;
    plotThreeConditions(resultsTable,'TxGain_dB','EVM_pct','EVM RMS (%)');
    xline(trainedTxGain_dB,'--','Training point');
    title('EVM versus TxGain');
    nexttile;
    plotThreeConditions(resultsTable,'TxGain_dB','ACPR_dBc','ACPR (dBc)');
    xline(trainedTxGain_dB,'--','Training point');
    title('ACPR versus TxGain');
    saveas(h1,fullfile(figuresDir,'01_EVM_ACPR_vs_TxGain.png'));
catch ME
    warning('Figure 1 failed: %s',ME.message);
end

try
    h2=figure('Name','EXP018 power vs TxGain','Color','w');
    tiledlayout(2,1);
    nexttile;
    plotThreeConditions(resultsTable,'TxGain_dB','RxPower_dBFS','RX power (dBFS)');
    xline(trainedTxGain_dB,'--','Training point');
    title('Pluto RX power versus TxGain');
    nexttile;
    plotThreeConditions(resultsTable,'TxGain_dB','Power_mean_dB_stm32','STM32 power (dBm)');
    xline(trainedTxGain_dB,'--','Training point');
    title('STM32 detector power versus TxGain');
    saveas(h2,fullfile(figuresDir,'02_Power_vs_TxGain.png'));
catch ME
    warning('Figure 2 failed: %s',ME.message);
end

try
    h3=figure('Name','EXP018 equal-power EVM improvements','Color','w');
    tiledlayout(2,1);
    nexttile;
    plot(summaryTable.TxGain_dB,summaryTable.MP_EVM_Improvement_vsOfficialSameRxPower_pct,'o-','LineWidth',1.1); hold on;
    plot(summaryTable.TxGain_dB,summaryTable.GMP_EVM_Improvement_vsOfficialSameRxPower_pct,'s-','LineWidth',1.1);
    yline(0,'--'); xline(trainedTxGain_dB,':'); grid on;
    xlabel('TxGain (dB)'); ylabel('EVM improvement (percentage points)');
    legend('MP','GMP','Location','best');
    title('EVM improvement versus official no-DPD at equal RX power');
    nexttile;
    plot(summaryTable.TxGain_dB,summaryTable.MP_EVM_Improvement_vsOfficialSameSTM32Power_pct,'o-','LineWidth',1.1); hold on;
    plot(summaryTable.TxGain_dB,summaryTable.GMP_EVM_Improvement_vsOfficialSameSTM32Power_pct,'s-','LineWidth',1.1);
    yline(0,'--'); xline(trainedTxGain_dB,':'); grid on;
    xlabel('TxGain (dB)'); ylabel('EVM improvement (percentage points)');
    legend('MP','GMP','Location','best');
    title('EVM improvement versus official no-DPD at equal STM32 power');
    saveas(h3,fullfile(figuresDir,'03_EqualPower_EVM_Improvement.png'));
catch ME
    warning('Figure 3 failed: %s',ME.message);
end

try
    h4=figure('Name','EXP018 MP minus GMP','Color','w');
    tiledlayout(3,1);
    nexttile;
    plot(summaryTable.TxGain_dB,summaryTable.EVM_MP_minus_GMP_pct,'o-','LineWidth',1.1);
    yline(0,'--'); xline(trainedTxGain_dB,':'); grid on;
    ylabel('EVM MP-GMP (%)'); title('Negative means MP has lower EVM');
    nexttile;
    plot(summaryTable.TxGain_dB,summaryTable.ACPR_MP_minus_GMP_dB,'o-','LineWidth',1.1);
    yline(0,'--'); xline(trainedTxGain_dB,':'); grid on;
    ylabel('ACPR MP-GMP (dB)'); title('Positive means GMP has more-negative ACPR');
    nexttile;
    plot(summaryTable.TxGain_dB,summaryTable.RxPower_MP_minus_GMP_dB,'o-','LineWidth',1.1);
    yline(0,'--'); xline(trainedTxGain_dB,':'); grid on;
    xlabel('TxGain (dB)'); ylabel('RX power MP-GMP (dB)');
    title('Power difference between predistorters');
    saveas(h4,fullfile(figuresDir,'04_MP_minus_GMP.png'));
catch ME
    warning('Figure 4 failed: %s',ME.message);
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
    'resultsTable','summaryTable','rangeSummaryTable', ...
    'TxGainList','trainedTxGain_dB','fixedRxGain_Pluto', ...
    'txWaveform','txMP','txGMP','coeffMP','coeffGMP', ...
    'mpModelID','mpIteration','mpM','mpK', ...
    'gmpModelID','gmpIteration','gmpParams', ...
    'sampleRate','PAPR_noDPD_dB','PAPR_MP_dB','PAPR_GMP_dB', ...
    'mpNormDiag','gmpNormDiag','captureStore', ...
    'officialRefPath','TrefOfficial');

fprintf('\n===== EXP018 COMPLETE =====\n');
fprintf('Output root             : %s\n',outputRoot);
fprintf('All-condition CSV       : %s\n',resultsCsvFile);
fprintf('Pointwise summary CSV   : %s\n',summaryCsvFile);
fprintf('Generalization CSV      : %s\n',rangeSummaryCsvFile);
fprintf('AM/AM-AM/PM CSV         : %s\n',amamCsvFile);
fprintf('PSD CSV                 : %s\n',psdCsvFile);
fprintf('MAT file                : %s\n',matFile);

%% ========================================================================
% LOCAL FUNCTIONS
%% ========================================================================

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
