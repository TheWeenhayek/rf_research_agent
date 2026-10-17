# Entrenamiento GMP: EXP031–EXP037

Esta entrega continúa el trabajo de DPDv2 con la cadena completa ya montada y los puntos de compresión obtenidos en laboratorio. No repite caracterización del Pluto, compresión por etapas ni pruebas de conexión.

El objetivo es determinar si una actualización GMP regularizada con incremento limitado mejora la evolución, los fallos y la repetibilidad frente a una actualización regularizada con mezcla fija también ajustada. Ambos métodos se comparan con la misma estructura GMP y a igual potencia observada. La mejora y la contribución para un artículo se deben demostrar con las mediciones; no están garantizadas por la formulación.

## 1. Qué copiar y dónde

Copiar **los siete archivos de `code`** a la carpeta `code` de DPDv2. Mantener los baselines que ya tienen los equipos:

```text
DPDv2/
  baseline/                 ← sus calibraciones y referencias existentes
  code/
    EXP031_Piloto_GMP_desde_EXP010.m
    EXP032_Seleccion_estructura_GMP.m
    EXP033_GMP_mezcla_fija.m
    EXP034_GMP_paso_restringido.m
    EXP035_Sensibilidad_lambda_mu_delta.m
    EXP036_Repetibilidad_GMP.m
    EXP037_Validacion_senal_nueva.m
  data/
    GMP_EXP031_037/         ← se crea al ejecutar
```

Cada `.m` contiene su configuración, su programa y todas sus funciones locales. No necesita DPDv3, una carpeta nueva de auxiliares ni un archivo de configuración externo. Los experimentos posteriores sí leen los **resultados de las etapas anteriores**, guardados automáticamente en `data/GMP_EXP031_037`; por eso deben ejecutarse en orden. No copiar resultados de otra cadena como si fueran propios.

Los CSV de calibración existentes no se sobrescriben ni se utilizan para declarar que la compresión antigua sigue siendo la actual. Aquí se parte del punto de operación que ustedes ya obtuvieron y se mide una referencia actual sin DPD. `baseline` se conserva en su lugar; estos experimentos no vuelven a medir sus etapas ni necesitan que se transfieran nuestros baselines locales.

## 2. Antes del primer entrenamiento: editar solamente el punto real

Al principio de **cada archivo** aparecen:

```matlab
C.txGain=-22.25; C.rxGain=8; C.txDSA_dB=5;
```

Son los valores heredados del EXP010 disponible, **no una afirmación de que sean los puntos nuevos medidos hoy**. Sustituirlos por los valores del laboratorio y mantenerlos iguales en EXP031–EXP037. El DSA es metadato: los códigos no lo cambian en ACE ni modifican conexiones físicas.

También se conservan IF de 5 GHz, STM32 en COM12 a 209700 baudios y pico digital 0.8. Si el puerto o la ruta al auxiliar EVM del ejemplo MATLAB son distintos en esa computadora, cambiar `C.serialPort` o `C.examplePath`. No se instala ni configura nada automáticamente.

La señal NR se mantiene en **20 MHz, 51 RB, SCS 30 kHz y 256QAM**, con SSB y la configuración de trama de EXP010. El muestreo se fija a **61.44 MS/s**, conforme a lo acordado. No se cambia firmware. La captura sigue siendo de **80 ms**, con los reintentos y umbrales de EXP010.

Si se cambia el punto, la tasa, la escala digital o las ganancias entre etapas, los resultados anteriores dejan de ser una referencia equivalente: los archivos de enlace lo detectan. Volver a EXP032 con la nueva condición. Eso es coherencia entre datos experimentales, no una comprobación adicional de equipos.

## 3. Qué se conservó de EXP010

Fuente: `EXP010_Iterative_ILA_DPDV2_DSA5_0p5dB_Top3Models_v2.m`, la versión más reciente de EXP010 disponible en esta carpeta. Las correcciones de hoy fueron de hardware, según lo informado.

Se copiaron literalmente en los siete códigos:

- Inicialización de `sdrtx`, `sdrrx`, ganancias y tipo de dato.
- Inicialización serial STM32, terminador, timeout y secuencia PING ya existente.
- `captureAndMeasureWithRetry`, incluidos captura, reintentos, guardado IQ, alineación y cálculo de EVM NR.
- La alineación `NORMAL_NO_CFO` de EXP010.
- `attachMeterMeasurement`, `readSTM32PowerBlock_EXP010I` y el formato de registros STM32.
- Las rutinas de reposo y liberación del radio.
- La normalización histórica de RMS/pico, utilizada en el piloto EXP031.

La transmisión sigue usando `transmitRepeat`, con la misma espera de 0.8 s y la misma llamada a la rutina de captura. No se cambiaron los comandos `MEAS`, su formato ni su interpretación. Las capturas adicionales en los experimentos comparativos son datos de identificación/evaluación del DPD, no pruebas de funcionamiento de la placa.

El auxiliar `hNRDownlinkEVM` del ejemplo MATLAB sigue siendo el que utilizaba EXP010 y debe estar accesible en la computadora. No se reemplazó por otra definición de EVM. Si falla, la rutina original puede agotar sus reintentos; revisar su mensaje en lugar de aceptar una EVM inválida.

Lo que sí cambia es la base MP por GMP, la identificación/transferencia de coeficientes, el control de la actualización, el plan de selección y la exportación de resultados. Para las bandas espectrales se corrigió el cálculo que antes podía integrar adyacentes incompletos.

## 4. Orden de ejecución

### EXP031 — Piloto GMP desde EXP010

Primera prueba de entrenamiento con una única estructura GMP de **29 coeficientes complejos**. No busca todavía la mejor estructura ni los mejores hiperparámetros.

Conserva los valores del estimador de EXP010 disponible: hasta **10 iteraciones**, `LambdaRel=0.01` y mezcla **0.12** después del primer ajuste completo. Usa la penalización de coeficientes sin normalización de columnas, con:

`lambda_efectiva = LambdaRel × trace(X'X) / número_de_coeficientes`.

La función histórica ajusta RMS y pico de la onda predistorsionada. Ese factor ahora se registra y se incorpora a los coeficientes que representan la entrada realmente emitida. El objetivo del postinverso es esa entrada emitida, y la ganancia de realimentación se fija con la referencia inicial. Son correcciones del cálculo ILA; no cambian el envío o la lectura de datos.

Se mide una referencia sin DPD antes y después. No se hace un barrido de compresión ni se utilizan sus métricas como prueba de superioridad del método propuesto. La comparación a igual potencia queda sin valor cuando todavía no hay barrido de referencia. Revisar `iteraciones.csv`, `evolucion.png` y los estados de cada iteración. Si aparece una falla, conservar su registro y resolverla antes de avanzar.

### EXP032 — Referencia actual y selección de estructura

1. Mide un barrido **sin DPD**, desde 4 dB por debajo hasta 2 dB por encima de la ganancia TX configurada, cada 0.5 dB. Su propósito es disponer de EVM/potencia de referencia para comparar el DPD a igual potencia; no separa compresión por etapas.
2. En el punto de entrenamiento toma dos capturas sin DPD: una para identificar y otra independiente para preseleccionar.
3. Ajusta seis bases GMP sobre los mismos datos, con lambda inicial 0.05 y hasta 60000 filas distribuidas por la trama. Ordena por NMSE de reconstrucción del postinverso en la segunda captura.
4. Las dos mejores bases pasan a un piloto físico con **ambos** algoritmos: mezcla 0.08 y radio fijo 0.1, tres iteraciones por corrida. Cada corrida empieza desde identidad; el orden se aleatoriza.
5. Entre las estructuras que completan las corridas aceptadas en ambos métodos, compara la mejora de EVM de forma de onda a igual potencia RX. Maximiza el resultado del peor de los dos métodos. Dentro de 0.1 puntos porcentuales de EVM de la mejor, prefiere menos coeficientes.

El margen 0.1 es una tolerancia práctica, no una prueba de significación estadística. La selección es exploratoria entre las dos preseleccionadas y con esos parámetros iniciales; no demuestra el óptimo global entre modelos e hiperparámetros. El error del postinverso sirve para cribar, no para declarar por sí solo que el DPD físico mejora.

| Nombre descriptivo | Ka, La | Kb, Lb, Mb | Kc, Lc, Mc | Coeficientes complejos |
|---|---|---|---|---:|
| Orden principal 7 | 4, 4 | 2, 3, 1 | 0, 0, 0 | 22 |
| Orden principal 9 | 5, 4 | 2, 3, 1 | 0, 0, 0 | 26 |
| Envolvente adelantada | 5, 4 | 2, 3, 1 | 1, 3, 1 | 29 |
| Orden principal 11 | 6, 4 | 2, 3, 1 | 1, 3, 1 | 33 |
| Mayor memoria | 5, 5 | 2, 4, 1 | 1, 4, 1 | 37 |
| Mayor orden cruzado | 5, 4 | 3, 3, 1 | 2, 3, 1 | 35 |

El conteo es `Ka*La + Kb*Lb*Mb + Kc*Lc*Mc`. Ka cuenta órdenes impares: Ka=5 representa grados 1,3,5,7,9. Las memorias se expresan en muestras: a 61.44 MS/s no representan la misma duración que a 30.72 MS/s, aunque sus números coincidan con los históricos.

Salida importante: `ultima_estructura.mat`, con la estructura elegida, el catálogo y el barrido de referencia. Si no hay ganadora comparable, el código lo informa y no publica una elección; no continuar como si la hubiera.

### EXP033 — GMP con mezcla fija

Entrena la estructura elegida, cinco iteraciones desde identidad. Usa lambda=0.05 y mu=0.08 como punto inicial:

\[
\widehat\theta_i=\arg\min_\theta\left(\|u_i-X_i\theta\|^2/N+\lambda\|\theta\|^2\right),
\qquad \theta_{i+1}=(1-\mu)\theta_i+\mu\widehat\theta_i.
\]

Se aplica mezcla desde la primera iteración. Esta referencia usa las coordenadas normalizadas comunes de la comparación; no es una reproducción exacta del estimador raw de EXP010. No se reescala silenciosamente la onda generada. Si supera el límite TX, se rechaza y se guarda la propuesta.

### EXP034 — GMP con paso restringido

Misma estructura y condiciones, cinco iteraciones, lambda=0.05 y delta=0.1:

\[
\min_d\ \|u_i-X_i(\theta_i+d)\|^2/N+\lambda\|\theta_i+d\|^2,
\qquad \|d\|\leq\Delta,\qquad \theta_{i+1}=\theta_i+d.
\]

Se regularizan los coeficientes finales, no solamente el incremento. Aquí mu=1: se aplica el incremento resuelto, que ya cumple el radio. No se añade mezcla 0.08. El radio es **fijo** durante la corrida; no se implementa una política adaptativa de expansión/reducción. El multiplicador interno del solver no es otro hiperparámetro a barrer.

En EXP033–036, las columnas se normalizan con escalas calculadas sobre la señal original y fijas durante cada corrida. Lambda y delta se interpretan en esas coordenadas; delta=0.1 no significa 10 % de potencia. Beta=1 y L=I. El solver usa ajuste aumentado y ecuación secular cuando la restricción está activa, sin inversión explícita de matrices. Entrenamiento y aplicación usan el mismo orden de términos; los bordes TX usan extensión periódica coherente con `transmitRepeat`.

### EXP035 — Sensibilidad

Mantiene fija la estructura elegida y compara:

| Método | Barrido | Configuraciones |
|---|---|---:|
| Mezcla fija | lambda={0.005,0.05,0.5}, mu={0.08,0.2,1} | 9 |
| Paso restringido | los mismos lambda, delta={0.03,0.1,0.3} | 9 |

El 0.08 es una referencia histórica de EXP015/016, no un óptimo demostrado. Mu=1 sin restricción es el control de ajuste completo. Cada configuración dispone del mismo máximo de cinco iteraciones y empieza desde identidad; el orden es aleatorio. Las interrupciones y los reintentos pueden producir presupuestos reales diferentes y deben contarse.

Cada iteración comparativa toma una captura independiente con la entrada actual para medir error de identificación sin reutilizar su captura de ajuste. Después transmite la propuesta y mide su resultado físico. El coste del postinverso no se confunde con EVM ni ACPR.

Se elige una configuración por método por mayor mejora de EVM de forma de onda a igual potencia RX entre corridas completas aceptadas. Se guardan todos los candidatos, incluidos fallos. El selector no exige mejora positiva: si los mejores resultados empeoran, eso debe quedar como resultado, no presentarse como una ventaja. Salida: `ultimos_parametros.mat`.

### EXP036 — Repetibilidad

Repite tres veces cada configuración elegida en EXP035, desde identidad y con capturas nuevas. Mantiene la señal de entrenamiento para separar variación entre corridas de variación entre señales. Guarda métricas y coeficientes finales de cada corrida que complete sus iteraciones aceptadas, sin seleccionar retrospectivamente la mejor repetición. Salida: `ultima_repetibilidad.mat`.

Las corridas fallidas también cuentan. Para resumir resultados, indicar cuántas de las tres repeticiones completó cada método; no calcular estabilidad solamente sobre las mejores capturas.

### EXP037 — Señal nueva con coeficientes congelados

Cambia los datos PDSCH usando una semilla fija nueva, manteniendo ancho, modulación, SCS y duración. **No vuelve a entrenar** ni cambia hiperparámetros. Aplica los coeficientes aceptados de EXP036, conservando sus escalas de columnas originales.

Mide una referencia sin DPD específica para esta señal nueva, con el mismo rango de ganancias que EXP032. Después evalúa cada juego de coeficientes con referencias locales sin DPD antes/después. No utiliza esta etapa para volver a escoger el modelo o los parámetros.

## 5. Cómo interpretar aceptación y potencia

El identificador minimiza error de reconstrucción más regularización. La aceptación física considera captura usable, pico RX menor de -3 dBFS, variación de potencia respecto a la referencia local entre -1.8 y +1 dB, degradación de EVM de forma de onda no mayor que 0.5 puntos porcentuales y, cuando es medible, degradación de cada ACPR no mayor de 0.5 dB. El pico TX máximo es 0.95 y el incremento PAPR máximo es 6.5 dB. Estos límites iniciales están visibles en cada código.

Una propuesta rechazada termina esa corrida y queda registrada. No se usa como nuevo estado para entrenar. Una reducción del coste de identificación no garantiza una mejora física. La EVM NR se mantiene separada de la EVM de forma de onda; el criterio comparativo automático utiliza la segunda.

La comparación a igual potencia interpola el barrido de la propia campaña dentro del rango medido y sin extrapolar. Usa potencia RX como proxy con la observación fija; la potencia STM32 también se registra. No es un servo de potencia RF ni una medición directa de potencia a 26 GHz. Las referencias locales antes/después permiten examinar deriva; no se corrige automáticamente la deriva térmica.

## 6. ACPR y muestreo

Las bandas son principal [-10,+10] MHz, inferior [-30,-10] MHz y superior [+10,+30] MHz. Se registran inferior, superior y suma por separado; la suma no equivale al ACPR de un solo adyacente.

61.44 MS/s permite representar digitalmente ese intervalo, pero **no demuestra 60 MHz útiles de observación**. El Pluto documenta 20 MHz en su configuración de fábrica y MathWorks 56 MHz en modo AD9364; aumentar la tasa no elimina por sí solo la limitación de filtros. Tampoco demuestra que se transmita todo el soporte de una señal predistorsionada de alto orden.

Por ello `C.rxUsefulBW_Hz=NaN` deja el ACPR completo sin reportar. El DPD sigue entrenando y guarda IQ/EVM/potencia; no se integra un fragmento del adyacente como si fuera completo. Completar ese valor solo si ya existe evidencia de la cobertura completa; no poner 61.44e6 por ser la tasa. No se añadieron pruebas de banda ni cambios de firmware a la secuencia. Si no se resuelve esta cobertura, el informe experimental debe declarar la limitación y no atribuir mejoras de ACPR que no se midieron.

Referencias técnicas: [especificaciones de Pluto, Analog Devices](https://www.analog.com/en/resources/evaluation-hardware-and-software/evaluation-boards-kits/adalm-pluto.html) y [modos AD9363/AD9364, MathWorks](https://www.mathworks.com/help/comm/plutoradio/ref/configureplutoradio.html).

## 7. Archivos y continuidad entre experimentos

Cada ejecución tiene una carpeta con fecha/hora en `data/GMP_EXP031_037/EXP0xx_...`:

- `raw`: IQ crudo y registros STM32 con el protocolo original.
- `processed`: configuración, señal exacta, métricas por iteración, coeficientes normalizados y raw en CSV, estados MAT, selección y figura de evolución.
- Los estados guardan estructura, escalas, coeficientes antes/después, entrada realmente emitida, coste, error independiente y factor de normalización cuando corresponde.
- Los registros `*_fallo.mat` y propuestas rechazadas explican por qué se detuvo una corrida. No borrarlos.

Los archivos `ultima_estructura.mat`, `ultimos_parametros.mat` y `ultima_repetibilidad.mat` enlazan las etapas. Una nueva ejecución de la etapa correspondiente marca su enlace como pendiente, guardando el enlace previo dentro de la nueva carpeta de resultados; si falla, no se reutiliza silenciosamente una elección antigua. Para usar deliberadamente una ejecución anterior, indicar su MAT en `C.structureFile`, `C.parametersFile` o `C.coefficientsFile`.

Mantener libres **decenas de GB**: a 61.44 MS/s y 80 ms, una captura compleja double ocupa aproximadamente 79 MB antes de compresión MAT. Solo EXP035 puede producir 216 capturas sin contar reintentos: aproximadamente 17 GB crudos antes de compresión, además de estados y de las otras etapas. Los reintentos aumentan esa cantidad. No reducir o borrar el IQ durante la campaña sin decidir qué datos se necesitan conservar.

## 8. Alcance de la revisión

Se conserva el flujo de hardware de la versión fuente y se comprueba que las funciones originales incorporadas no cambien. Las comprobaciones de software no equivalen a haber ejecutado estos entrenamientos sobre la cadena real. No se operaron equipos al preparar la entrega. Anotar la configuración física usada y conservar los mensajes de error si una ejecución falla; no cambiar simultáneamente punto de trabajo, estructura e hiperparámetros tratando de ocultar el fallo.

Revisión de software completada en MATLAB: conteos de las seis bases, aplicación identidad, restricción del paso, condiciones de optimalidad del solver, recuperación del ridge sin restricción, criterios de selección, interpolación sin extrapolación y generación NR de 20 MHz a 61.44 MS/s con datos originales y nuevos. También se completó el enlace EXP031–EXP037 con radios y adquisición simulados, sin emplear dispositivos; esa simulación comprueba el flujo de archivos y las decisiones del programa, no sus resultados experimentales.
