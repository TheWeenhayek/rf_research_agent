function result = medir_potencia_STM32(result, stm, useSTM32PowerMeter, txGain, rxGain, nSamples, fidMeterRaw, label, iteration)
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

        [pVals, vVals, adcVals, nValid, nInvalid] = leer_bloque_STM32( ...
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

