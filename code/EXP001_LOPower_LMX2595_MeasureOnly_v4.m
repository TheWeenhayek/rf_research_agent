%% ============================================================
% DPD V2 - EXP001
% LMX2595 LO POWER MEASUREMENT ONLY
% ============================================================
% Objective:
%   Measure the LO power delivered by the LMX2595 before connecting it to
%   the ADMV1018/ADMV1017 LO input. This experiment does not transmit with
%   Pluto and does not calculate EVM/ACPR. It only reads the external power
%   detector / STM32 power meter and saves raw samples plus a summary.
%
% Expected physical setup:
%   LMX2595 RFoutA -> 3 dB attenuator -> 6 dB attenuator
%   -> power meter / detector -> STM32 -> PC MATLAB
%
% Important for this experiment:
%   The power meter is connected at the same point that will later feed the
%   ADMV1018/ADMV1017 LO input. Therefore, the measured power is already
%   the LO power at the mixer input. The 9 dB attenuation is saved only to
%   estimate the raw LMX2595 RFoutA power before the attenuators.
%
% Folder convention:
%   DPDV2/
%       code/    this script
%       data/    output data
%       inform/  reports/notes
%
% STM32 protocol expected:
%   MATLAB sends: MEAS,N
%   STM32 returns:
%       START,...
%       DATA,stm32_time_ms,adc_raw,voltage_V,power_dB
%       ...
%       END,...
%
% Notes:
%   - Power measured after the 3 dB + 6 dB attenuators is interpreted as
%     the LO drive power at the mixer input.
%   - powerMeterCorrection_dB is kept at 0 dB unless the power meter itself
%     or an additional measurement-only path requires correction.

clear; clc;
warning('off','all');

%% =========================
% Experiment identification
% =========================
EXP_ID     = "EXP001";
CATEGORY   = "LO";
DEVICE     = "LMX2595";
SHORT_NAME = "POWER_CHECK";
VERSION    = "v4";

runTag = string(datetime("now", "Format", "yyyyMMdd_HHmmss"));
baseName = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + runTag + "_" + VERSION;

%% =========================
% LMX2595 configuration metadata, from TICS Pro screenshot
% =========================
% These values are not programmed by this script. They are only saved as
% metadata to document how the synthesizer was configured during EXP001.

loConfig = struct();
loConfig.Synthesizer              = "LMX2595";
loConfig.Reference_Fosc_Hz        = 100e6;
loConfig.Reference_Doubler        = "x2";
loConfig.PreR                     = 1;
loConfig.Multiplier               = "Bypass";
loConfig.R                        = 1;
loConfig.Fpd_Hz                   = 200e6;
loConfig.NDivider_Integer         = 52;
loConfig.NDivider_Fraction_Num    = 500;
loConfig.NDivider_Fraction_Den    = 1000;
loConfig.NDivider_Effective       = 52.5;
loConfig.Fvco_Hz                  = 10.5e9;
loConfig.RFoutA_Hz                = 10.5e9;
loConfig.RFoutA_PWR_Setting       = 17;
loConfig.RFoutA_Enabled           = true;
loConfig.RFoutB_Hz                = 10.5e9;
loConfig.RFoutB_PWR_Setting       = 31;
loConfig.RFoutB_Enabled           = false;
loConfig.ChargePumpCurrent_mA     = 15;
loConfig.ApproxCurrent_mA         = 336;
loConfig.ApproxVCOGain_MHz_per_V  = 122;
loConfig.FCAL_EN                  = true;
loConfig.Notes = "Configuration transcribed from TICS Pro screenshot. RFoutA is the intended LO output.";

%% =========================
% Safety references for ADMV1018/ADMV1017 LO input
% =========================
% ADMV1017/ADMV1018-family reference values used only for post-measurement
% classification. Check the exact ADMV1018 datasheet before final operation.

loTarget = struct();
loTarget.MixerDevice              = "ADMV1018, using ADMV1017 as close reference";
loTarget.LOInputFrequency_Min_Hz  = 5e9;
loTarget.LOInputFrequency_Max_Hz  = 15e9;
loTarget.LOAmplitudeRecommended_Min_dBm = -8;
loTarget.LOAmplitudeRecommended_Max_dBm = -4;
loTarget.LOInputAbsoluteMax_dBm   = 6;
loTarget.Notes = "Recommended LO drive window used as reference: -8 to -4 dBm; absolute maximum: +6 dBm.";

%% =========================
% Measurement configuration
% =========================
measurementPoint = "After_9dB_Attenuation_Future_Mixer_LO_Input";
notes = "Power meter connected after the fixed 3 dB + 6 dB attenuation network; this point is the future mixer LO input.";

% Fixed attenuation that will remain between the LMX2595 RFoutA and the
% mixer LO input during the experiment chain. This is NOT a correction for
% the mixer LO drive; it is used only to estimate the raw LMX2595 RFoutA
% power before the attenuators.
physicalAttenuation_LMX2595_to_MixerLO_dB = 9.0;  % 3 dB + 6 dB

% Measurement-only correction after the mixer-LO reference point.
% Since the meter is connected exactly at the future mixer LO input point,
% this remains 0 dB. The measured power is therefore the LO drive power.
powerMeterCorrection_dB = 0.0;

% Number of power samples requested from STM32.
nPowerSamples = 100;

% The STM32 power-meter firmware used in the previous experiments expects:
%   MEAS,<tag_or_txgain>,<number_of_samples>
% In EXP001 there is no Pluto TxGain, so this is only a dummy tag.
% The firmware normally ignores this value for the power measurement itself.
measurementCommandTag_dB = 0.0;

serialPort       = "COM12";
serialBaud       = 209700;
serialTerminator = "LF";
serialTimeout_s  = 1.0;

doPingTest = true;

%% =========================
% Output folders
% =========================
thisFile = mfilename('fullpath');
if strlength(string(thisFile)) == 0
    % Fallback if script is executed section-by-section without a filename.
    codeDir = pwd;
else
    codeDir = fileparts(thisFile);
end

projectRoot = fileparts(codeDir);           % expected: DPDV2
if endsWith(string(codeDir), "code")
    dataRoot = fullfile(projectRoot, "data");
else
    % Fallback: create data folder next to current folder.
    dataRoot = fullfile(pwd, "data");
end

experimentFolder = EXP_ID + "_" + CATEGORY + "_" + DEVICE + "_" + SHORT_NAME + "_" + VERSION;
outDir       = fullfile(dataRoot, experimentFolder, runTag);
rawDir       = fullfile(outDir, "raw");
processedDir = fullfile(outDir, "processed");
figuresDir   = fullfile(outDir, "figures");

if ~exist(rawDir, 'dir'), mkdir(rawDir); end
if ~exist(processedDir, 'dir'), mkdir(processedDir); end
if ~exist(figuresDir, 'dir'), mkdir(figuresDir); end

csvRawFile     = fullfile(rawDir,       baseName + "_raw_power_samples.csv");
csvSummaryFile = fullfile(processedDir, baseName + "_power_summary.csv");
matFile        = fullfile(processedDir, baseName + "_workspace.mat");
figPowerFile   = fullfile(figuresDir,   baseName + "_power_samples.png");

fprintf("\n============================================\n");
fprintf("DPD V2 - EXP001 - LMX2595 LO POWER CHECK\n");
fprintf("Output folder: %s\n", outDir);
fprintf("Expected LO frequency: %.6f GHz\n", loConfig.RFoutA_Hz/1e9);
fprintf("RFoutA power setting: %d\n", loConfig.RFoutA_PWR_Setting);
fprintf("Physical attenuation LMX2595->Mixer LO: %.2f dB\n", physicalAttenuation_LMX2595_to_MixerLO_dB);
fprintf("Measurement-only correction: %.2f dB\n", powerMeterCorrection_dB);
fprintf("============================================\n\n");

%% =========================
% Open raw CSV
% =========================
fidRaw = fopen(csvRawFile, 'w');
if fidRaw < 0
    error("Could not open raw CSV file: %s", csvRawFile);
end

fprintf(fidRaw, [ ...
    "pc_timestamp," + ...
    "sample_index," + ...
    "measurement_point," + ...
    "expected_lo_frequency_hz," + ...
    "rfouta_power_setting," + ...
    "physical_attenuation_lmx2595_to_mixerlo_db," + ...
    "power_meter_correction_db," + ...
    "stm32_time_ms," + ...
    "adc_raw," + ...
    "voltage_v," + ...
    "power_measured_dbm," + ...
    "lo_at_mixer_estimated_dbm," + ...
    "lmx2595_rfouta_estimated_dbm," + ...
    "raw_line\n"]);

%% =========================
% Serial connection
% =========================
stm = [];
try
    stm = serialport(serialPort, serialBaud, "Timeout", serialTimeout_s);
    configureTerminator(stm, serialTerminator);
    flush(stm);
    pause(0.2);

    if doPingTest
        fprintf("Testing STM32 communication with PING...\n");
        writeline(stm, "PING");
        pause(0.1);
        while stm.NumBytesAvailable > 0
            fprintf("  STM32: %s\n", strtrim(string(readline(stm))));
        end
    end
catch ME
    fclose(fidRaw);
    error("Could not open STM32 serial port %s: %s", serialPort, ME.message);
end

%% =========================
% Measurement
% =========================
powerMeasured_dBm  = [];
loAtMixerEstimated_dBm = [];
lmx2595RFoutAEstimated_dBm = [];
voltage_V          = [];
adcRaw             = [];
stm32Time_ms       = [];
rawLines           = strings(0,1);

try
    flush(stm);
    % Keep the same command format used by the working power-meter scripts:
    %   MEAS,<tag_or_txgain>,<number_of_samples>
    % The first numeric field is only a dummy tag in this LO-only experiment.
    cmd = sprintf("MEAS,%.2f,%d", measurementCommandTag_dB, nPowerSamples);
    fprintf("Sending command to STM32: %s\n", cmd);
    writeline(stm, cmd);

    sampleIndex = 0;
    gotEnd = false;

    while ~gotEnd
        try
            line = strtrim(string(readline(stm)));
        catch ME
            warning("Timeout/error reading STM32: %s", ME.message);
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
                t_ms = str2double(parts{2});
                adc  = str2double(parts{3});
                v    = str2double(parts{4});
                p    = str2double(parts{5});

                if isnan(t_ms) || isnan(adc) || isnan(v) || isnan(p)
                    warning("Invalid DATA line with NaN: %s", line);
                    continue;
                end

                sampleIndex = sampleIndex + 1;
                loAtMixer = p + powerMeterCorrection_dB;
                lmxOut   = loAtMixer + physicalAttenuation_LMX2595_to_MixerLO_dB;
                pcTimestamp = string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss.SSS"));

                fprintf(fidRaw, "%s,%d,%s,%.0f,%d,%.3f,%.3f,%.0f,%.0f,%.9f,%.6f,%.6f,%.6f,%s\n", ...
                    pcTimestamp, ...
                    sampleIndex, ...
                    sanitizeCsvField(measurementPoint), ...
                    loConfig.RFoutA_Hz, ...
                    loConfig.RFoutA_PWR_Setting, ...
                    physicalAttenuation_LMX2595_to_MixerLO_dB, ...
                    powerMeterCorrection_dB, ...
                    t_ms, ...
                    adc, ...
                    v, ...
                    p, ...
                    loAtMixer, ...
                    lmxOut, ...
                    sanitizeCsvField(line));

                stm32Time_ms(end+1,1)       = t_ms; %#ok<SAGROW>
                adcRaw(end+1,1)             = adc;  %#ok<SAGROW>
                voltage_V(end+1,1)          = v;    %#ok<SAGROW>
                powerMeasured_dBm(end+1,1)  = p;    %#ok<SAGROW>
                loAtMixerEstimated_dBm(end+1,1) = loAtMixer; %#ok<SAGROW>
                lmx2595RFoutAEstimated_dBm(end+1,1) = lmxOut; %#ok<SAGROW>
                rawLines(end+1,1)           = line; %#ok<SAGROW>

            else
                warning("Invalid DATA line: %s", line);
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

catch ME
    warning("Measurement error: %s", ME.message);
end

%% =========================
% Close serial and raw file
% =========================
try
    fclose(fidRaw);
catch
end

try
    clear stm;
catch
end

%% =========================
% Summary table
% =========================
nValid = numel(loAtMixerEstimated_dBm);

% Use scalar-safe statistics. This avoids table-construction errors when
% a vector is empty or when all received samples are invalid/NaN.
Power_mean_measured_dBm  = safeMean(powerMeasured_dBm);
Power_std_measured_dB    = safeStd(powerMeasured_dBm);
Power_min_measured_dBm   = safeMin(powerMeasured_dBm);
Power_max_measured_dBm   = safeMax(powerMeasured_dBm);

LOAtMixer_mean_dBm = safeMean(loAtMixerEstimated_dBm);
LOAtMixer_std_dB   = safeStd(loAtMixerEstimated_dBm);
LOAtMixer_min_dBm  = safeMin(loAtMixerEstimated_dBm);
LOAtMixer_max_dBm  = safeMax(loAtMixerEstimated_dBm);

LMX2595_RFoutA_mean_dBm = safeMean(lmx2595RFoutAEstimated_dBm);
LMX2595_RFoutA_std_dB   = safeStd(lmx2595RFoutAEstimated_dBm);
LMX2595_RFoutA_min_dBm  = safeMin(lmx2595RFoutAEstimated_dBm);
LMX2595_RFoutA_max_dBm  = safeMax(lmx2595RFoutAEstimated_dBm);

isRecommendedForADMV_LO = ...
    LOAtMixer_mean_dBm >= loTarget.LOAmplitudeRecommended_Min_dBm && ...
    LOAtMixer_mean_dBm <= loTarget.LOAmplitudeRecommended_Max_dBm;

marginToAbsMax_dB = loTarget.LOInputAbsoluteMax_dBm - LOAtMixer_max_dBm;

if isnan(LOAtMixer_mean_dBm) || isnan(LOAtMixer_max_dBm)
    safetyClass = "NO_VALID_POWER_SAMPLES";
elseif LOAtMixer_max_dBm >= loTarget.LOInputAbsoluteMax_dBm
    safetyClass = "DANGEROUS_ABOVE_ABSOLUTE_MAX";
elseif LOAtMixer_mean_dBm > loTarget.LOAmplitudeRecommended_Max_dBm
    safetyClass = "ABOVE_RECOMMENDED_LO_DRIVE";
elseif LOAtMixer_mean_dBm < loTarget.LOAmplitudeRecommended_Min_dBm
    safetyClass = "BELOW_RECOMMENDED_LO_DRIVE";
else
    safetyClass = "INSIDE_RECOMMENDED_LO_DRIVE";
end

summaryTable = table( ...
    string(datetime("now", "Format", "yyyy-MM-dd HH:mm:ss")), ...
    string(measurementPoint), ...
    string(notes), ...
    loConfig.Reference_Fosc_Hz, ...
    loConfig.Fpd_Hz, ...
    loConfig.Fvco_Hz, ...
    loConfig.RFoutA_Hz, ...
    loConfig.RFoutA_PWR_Setting, ...
    loConfig.RFoutA_Enabled, ...
    loConfig.RFoutB_Enabled, ...
    loConfig.ChargePumpCurrent_mA, ...
    loConfig.ApproxCurrent_mA, ...
    loConfig.FCAL_EN, ...
    physicalAttenuation_LMX2595_to_MixerLO_dB, ...
    powerMeterCorrection_dB, ...
    nPowerSamples, ...
    nValid, ...
    Power_mean_measured_dBm, ...
    Power_std_measured_dB, ...
    Power_min_measured_dBm, ...
    Power_max_measured_dBm, ...
    LOAtMixer_mean_dBm, ...
    LOAtMixer_std_dB, ...
    LOAtMixer_min_dBm, ...
    LOAtMixer_max_dBm, ...
    LMX2595_RFoutA_mean_dBm, ...
    LMX2595_RFoutA_std_dB, ...
    LMX2595_RFoutA_min_dBm, ...
    LMX2595_RFoutA_max_dBm, ...
    loTarget.LOAmplitudeRecommended_Min_dBm, ...
    loTarget.LOAmplitudeRecommended_Max_dBm, ...
    loTarget.LOInputAbsoluteMax_dBm, ...
    isRecommendedForADMV_LO, ...
    marginToAbsMax_dB, ...
    string(safetyClass), ...
    'VariableNames', { ...
        'PC_Timestamp', ...
        'MeasurementPoint', ...
        'Notes', ...
        'Reference_Fosc_Hz', ...
        'Fpd_Hz', ...
        'Fvco_Hz', ...
        'RFoutA_Hz', ...
        'RFoutA_PWR_Setting', ...
        'RFoutA_Enabled', ...
        'RFoutB_Enabled', ...
        'ChargePumpCurrent_mA', ...
        'ApproxCurrent_mA', ...
        'FCAL_EN', ...
        'PhysicalAttenuation_LMX2595_to_MixerLO_dB', ...
        'PowerMeterCorrection_dB', ...
        'RequestedSamples', ...
        'ValidSamples', ...
        'Power_Mean_Measured_dBm', ...
        'Power_Std_Measured_dB', ...
        'Power_Min_Measured_dBm', ...
        'Power_Max_Measured_dBm', ...
        'LOAtMixer_Mean_dBm', ...
        'LOAtMixer_Std_dB', ...
        'LOAtMixer_Min_dBm', ...
        'LOAtMixer_Max_dBm', ...
        'LMX2595_RFoutA_Mean_dBm', ...
        'LMX2595_RFoutA_Std_dB', ...
        'LMX2595_RFoutA_Min_dBm', ...
        'LMX2595_RFoutA_Max_dBm', ...
        'ADMV_LO_Recommended_Min_dBm', ...
        'ADMV_LO_Recommended_Max_dBm', ...
        'ADMV_LO_AbsoluteMax_dBm', ...
        'InsideRecommendedWindow', ...
        'MarginToAbsoluteMax_dB', ...
        'SafetyClass'} ...
);

writetable(summaryTable, csvSummaryFile);

%% =========================
% Quick figure
% =========================
try
    figure;
    plot(1:nValid, loAtMixerEstimated_dBm, "o-", "LineWidth", 1.2);
    hold on;
    yline(loTarget.LOAmplitudeRecommended_Min_dBm, "--", "ADMV LO min recommended");
    yline(loTarget.LOAmplitudeRecommended_Max_dBm, "--", "ADMV LO max recommended");
    yline(loTarget.LOInputAbsoluteMax_dBm, "-.", "ADMV LO absolute max");
    xlabel("Sample index");
    ylabel("Estimated LO power at mixer input [dBm]");
    title("EXP001 - LMX2595 LO power measurement");
    grid on;
    hold off;
    saveas(gcf, figPowerFile);
catch ME
    warning("Could not create/save figure: %s", ME.message);
end

%% =========================
% Save MAT
% =========================
save(matFile, ...
    "loConfig", ...
    "loTarget", ...
    "measurementPoint", ...
    "notes", ...
    "physicalAttenuation_LMX2595_to_MixerLO_dB", ...
    "powerMeterCorrection_dB", ...
    "nPowerSamples", ...
    "measurementCommandTag_dB", ...
    "serialPort", ...
    "serialBaud", ...
    "serialTimeout_s", ...
    "stm32Time_ms", ...
    "adcRaw", ...
    "voltage_V", ...
    "powerMeasured_dBm", ...
    "loAtMixerEstimated_dBm", ...
    "lmx2595RFoutAEstimated_dBm", ...
    "rawLines", ...
    "summaryTable");

fprintf("\n========== EXP001 SUMMARY ==========%s", newline);
disp(summaryTable);

fprintf("\nFiles saved:\n");
fprintf("  Raw samples : %s\n", csvRawFile);
fprintf("  Summary     : %s\n", csvSummaryFile);
fprintf("  Figure      : %s\n", figPowerFile);
fprintf("  MAT         : %s\n", matFile);
fprintf("====================================\n");

warning('on','all');

%% ============================================================
% Local helper
% ============================================================

function y = safeMean(x)
    x = x(:);
    x = x(~isnan(x));
    if isempty(x)
        y = NaN;
    else
        y = mean(x);
    end
end

function y = safeStd(x)
    x = x(:);
    x = x(~isnan(x));
    if numel(x) < 2
        y = NaN;
    else
        y = std(x);
    end
end

function y = safeMin(x)
    x = x(:);
    x = x(~isnan(x));
    if isempty(x)
        y = NaN;
    else
        y = min(x);
    end
end

function y = safeMax(x)
    x = x(:);
    x = x(~isnan(x));
    if isempty(x)
        y = NaN;
    else
        y = max(x);
    end
end

function safe = sanitizeCsvField(txt)
    safe = string(txt);
    safe = replace(safe, '"', '""');
    safe = '"' + safe + '"';
end
