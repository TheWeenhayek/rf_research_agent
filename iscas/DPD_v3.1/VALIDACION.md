# Validación offline

Ejecutada en MATLAB R2024b, sin activar transmisor, receptor ni puerto serie:

- Revisión de sintaxis con Code Analyzer de los archivos MATLAB de la entrega. No se encontraron errores de sintaxis. Se conservan advertencias del código histórico, principalmente variables sin uso, formato de avisos y ramas desactivadas por configuración.
- Solver complejo con restricción activa: norma del incremento dentro de delta y cumplimiento de condiciones KKT con tolerancia de 1e-9.
- Solver sin restricción activa: coincidencia con solución ridge directa con tolerancia de 1e-9.
- Integración espectral de tres tonos sintéticos: cocientes adyacentes de aproximadamente -20 dBc; bandas parciales rechazadas; banda física sin evidencia no certificada.
- Generación de las dos señales NR: canal de 20 MHz y pico 0.8 en ambas. La selección automática produjo **30.72 MS/s**; la tasa explícita produjo **61.44 MS/s**.
- Original EXP015 archivado y baseline Pluto de entrada cotejados por SHA-256 contra DPDv2. Comparación textual de las variantes EXP015/016/017 entregada en archivos patch.

Estos controles no sustituyen la medición de compresión, la validación de detectores ni la caracterización de ancho de banda del montaje. La adquisición y el entrenamiento con equipos deberán ejecutarse en laboratorio siguiendo `LEEME_PASO_A_PASO.md`.

`VALIDACION_OFFLINE.mat` y `DIAGNOSTICOS_MATLAB.csv` conservan resultados de los controles. Se pueden repetir ejecutando `code/VALIDAR_OFFLINE_B31.m`.

Actualización del punto de operación: la ganancia se edita ahora directamente en la línea 51 de EXP015/016/017, sin lector de punto externo. Se comprobó de nuevo en MATLAB la sintaxis de los cinco archivos afectados; los resultados se conservan en `VALIDACION_ACTUALIZACION_PUNTO.mat` y `DIAGNOSTICOS_ACTUALIZACION_PUNTO.csv`. No se modificaron el solver ni las señales en esta actualización. El baseline Pluto se volvió a cotejar con DPDv2 y permanece idéntico.
