# Revisión de figuras y límites del detector

Se contrastaron las instrucciones de figuras contra los archivos originales de DPDv2, sin modificar código ni ejecutar mediciones físicas:

| Entrega | Código original contrastado | Instrucciones de figuras comparadas | Coinciden |
|---|---|---:|---|
| EXP01 | EXP002_IFChain_BGUx2_PowerSweep_Compression_v3_LongBaseline.m | 32 | Sí |
| EXP02 | EXP003_TX_Only_Upconverter_RFOUT_IFBoardBaseline_v3_ATT20.m | 42 | Sí |
| EXP03 | EXP004_Downconverter_RFIn_Compression_Check_TXDSA7Baseline_v5.m | 58 | Sí |
| EXP04 | EXP005_Downconverter_RXDSA_SafeSweep_v1.m | 48 | Sí |
| EXP015 | EXP015_Iterative_GMP_DPDV2_DSA5_0p5dB_v1.m | 107 | Sí |

La comparación incluye llamadas de creación de figura, trazado, ejes, títulos, leyendas y guardado. No equivale a comprobar visualmente resultados de una nueva adquisición, que todavía debe realizarse. No se rediseñaron las figuras históricas.

Los datos representados sí dependen de las condiciones y adaptaciones documentadas: rutas/configuración, tasa automática de las etapas de compresión, pico 0.8, TX DSA=5 dB y ampliación del extremo de EXP04 de -24 a -20 dB con los límites RF heredados. La publicación de baselines es automática y conserva historial. EXP05–06 son rutinas nuevas de medición EVM que guardan capturas y tablas.

La revisión encontró una diferencia heredada entre filtros de fiabilidad:

- EXP01 utiliza piso de lectura -32 dBm y voltaje mínimo 0.15 V; distingue baseline medido de extrapolación por piso.
- EXP02 conserva un umbral inferior -90 dBm sobre potencia corregida. EXP03–04 conservan -90 dBm sobre IF corregida. Esos filtros no excluyen por sí solos un detector que se quede cerca de -32 dBm.

Por petición de conservar el procesamiento original, no se han sustituido silenciosamente estos filtros. Se amplió la guía con el procedimiento para reconocer y excluir físicamente condiciones de piso y saturación antes de utilizar los baselines. La publicación automática exige datos mínimos, pero no certifica el rango metrológico del detector.

Las potencias del detector se expresan en dBm. Una meseta cercana a -32 dBm acompañada de voltaje/ADC casi cero indica el piso observado en este montaje, no una medición fiable de compresión del amplificador. Una meseta en el extremo superior puede ser saturación del medidor. Las pérdidas de protección deben aplicarse a lecturas válidas, no utilizarse para recuperar una lectura que quedó fuera de rango.
