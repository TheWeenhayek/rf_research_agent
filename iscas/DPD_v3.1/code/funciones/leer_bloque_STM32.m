function [powerValues_dB, voltageValues_V, adcValues_raw, nValid, nInvalid] = leer_bloque_STM32(stm, fidMeterRaw, label, iteration, txGain, rxGain)
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
                        pc_timestamp, formatear_campo_CSV(label), iteration, txGain, rxGain, ...
                        stm32_time_ms, adc_raw, voltage_V, power_dB, formatear_campo_CSV(line));
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

