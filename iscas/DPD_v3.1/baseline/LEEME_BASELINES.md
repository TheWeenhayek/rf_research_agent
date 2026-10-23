# Baselines de esta entrega

Solo se incluye inicialmente `Baseline_Power_Tx_Pluto.csv`, copiado sin cambios de DPDv2 como calibración histórica de entrada. Los demás archivos deben provenir de las nuevas mediciones EXP01–06. No se incluyeron baselines antiguos de BGU/upconverter/downconverter como si fueran resultados de B3.1.

Las mediciones publican automáticamente nombres estables en esta carpeta. Si existe uno, su versión anterior pasa a `historial` antes de reemplazarlo. `Punto_operacion.mat` se genera mediante EXP06 cuando hay un candidato válido y documenta el resultado. No cambia el entrenamiento automáticamente: editar `fixedTxGain_Pluto` en la línea 51 de cada EXP015/016/017.

El baseline del Pluto se conserva como entrada; ninguno de estos experimentos vuelve a medirlo ni lo sobrescribe. Contiene 201 pares de `TxGain_dB` y `Potencia_SA_dBm` entre -50 y 0 dB. Por ejemplo, para TX gain=-22.25 dB la potencia de salida medida que figura en la tabla es -30.175 dBm. Esta es la calibración ganancia TX → potencia física; no una conversión universal entre unidades dB y dBm.

Ver la guía de la raíz para conexiones, atenuaciones y limitaciones de la separación de compresión por etapas.
