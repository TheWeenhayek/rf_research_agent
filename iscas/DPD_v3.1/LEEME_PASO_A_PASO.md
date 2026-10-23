# DPD B3.1 — Guía de laboratorio

## Qué ejecutar y en qué orden

| Orden | Archivo en `code` | Montaje y propósito | Archivo estable en `baseline` |
|---|---|---|---|
| 1 | `EXP01_Compresion_cadena_IF.m` | Pluto y cadena de dos BGU; detector a la salida IF | `Baseline_Power_IF_Board.csv` |
| 2 | `EXP02_Compresion_upconverter.m` | Añadir upconverter; medir RF después del filtro | `Baseline_Power_Upconverter_RFOUT_TXDSA5.csv` y alias `Baseline_Power_Upconverter_RFOUT.csv` |
| 3 | `EXP03_Compresion_downconverter.m` | Cerrar loopback RF y medir IF de salida del downconverter | `Baseline_Downconverter_Compresion.csv` |
| 4 | `EXP04_Observacion_DSA_RX.m` | Caracterizar la observación con DSA RX en su valor de trabajo | `Baseline_Downconverter_ObservationPath.csv` |
| 5 | `EXP05_EVM_directa.m` | Cadena completa hasta Pluto RX; EVM NR sin alineamiento externo | `Baseline_EVM_directa.csv` |
| 6 | `EXP06_EVM_sincronizada_y_punto.m` | Misma cadena; EVM con sincronización original EXP015; referencia y punto actual | `Referencia_sin_DPD_automatica.csv`, `Baseline_Cadena_Completa.csv`, `Punto_operacion.mat` |
| 7 | `EXP015_GMP_original_punto_configurable.m` | GMP histórico, tasa automática, punto configurable | Resultados en `data/EXP015_...` |
| 8a | `EXP06B_Referencia_sin_DPD_61M44.m` | Referencia sin DPD a la tasa nueva para no mezclar condiciones | `Referencia_sin_DPD_61M44.csv` |
| 8b | `EXP016_GMP_original_tasa_61M44.m` | Mismo algoritmo de EXP015; cambia la tasa a 61.44 MS/s | Resultados en `data/EXP016_...` |
| 9 | `EXP017_GMP_lambda_delta.m` | Misma base GMP; entrenamiento con lambda y radio delta, sin mezcla mu | Resultados en `data/EXP017_...` |

Los números 015, 016 y 017 se conservan para que resulte clara su relación con el experimento histórico. El nuevo EXP016 NO es el antiguo experimento de modelos avanzados.

Se interpreta EVM como lo confirmado en la conversación: primero directa y después sincronizada. No se cambia el ancho del canal NR de 20 MHz.

## Por qué se sigue este procedimiento

La idea es establecer primero qué hace físicamente cada etapa, después comprobar cómo medimos su salida y finalmente comparar algoritmos. Si se cambia todo a la vez, una EVM menor podría venir de transmitir con menos potencia o de cambiar la adquisición, en vez de venir del GMP.

| Etapa | Qué pregunta resuelve y por qué importa |
|---|---|
| Baseline Pluto, ya existente | Traduce la ganancia TX programada a potencia de salida medida. Da la referencia de entrada del BGU sin repetir la calibración del Pluto. |
| EXP01, BGU | Comprueba cuánto amplifica la cadena IF y cuándo pierde ganancia. Si ya comprime, no podemos atribuir toda la distorsión posterior al upconverter. |
| EXP02, upconverter | Con la salida BGU conocida, estima su ganancia propia y el punto donde empieza a comprimir. Ese es el comportamiento que queremos corregir mediante DPD. |
| EXP03–04, downconverter y observación | Comprueba que el camino usado para mirar la salida no añada su propia compresión. De lo contrario entrenaríamos el predistorsionador con una medición deformada. |
| EXP05 frente a EXP06 | Separa el efecto del alineamiento de la calidad de la señal: la comparación indica cuánto cambia la EVM al proporcionar al demodulador una captura alineada. |
| EXP015 original | Establece una referencia con el algoritmo conocido, antes de introducir nuevas formas de ajuste. |
| EXP016 | Permite estudiar el efecto de cambiar la tasa, manteniendo el algoritmo anterior, y disponer de los bins necesarios para integrar los adyacentes. La banda física debe verificarse aparte. |
| EXP017 | Solo después se evalúa el cambio a lambda–delta frente a una referencia identificada y repetible. |

La compresión se mide como pérdida de ganancia respecto a la región de pequeña señal. No basta con que la potencia de salida aumente: si la entrada aumenta 1 dB y la salida aumenta menos de 1 dB, hay indicios de compresión. Un punto de 0.5 dB de compresión significa que la ganancia está 0.5 dB por debajo de su referencia lineal, no que la ganancia TX deba ajustarse a 0.5 dB.

## Preparación común

1. Copiar la carpeta completa, manteniendo `code`, `code/funciones`, `baseline` y `data`.
2. Abrir `code/configuracion_b31.m`. El factor de escala de la señal original es **0.8 en todo el proceso**. No cambiarlo a 0.7.
3. Configurar el puerto STM32, su velocidad y la ruta a los auxiliares MATLAB del ejemplo `NRWaveformCaptureAndAnalysisWithSDRExample`. El valor de partida del puerto es COM12, a 209700 baudios. Se utiliza el protocolo histórico `MEAS,<ganancia>,50`.
4. Mantener la frecuencia IF de trabajo de 5 GHz, el canal NR de 20 MHz y SCS de 30 kHz. La generación de señal y las pruebas de caracterización/EVM dejan automática la tasa de muestreo. EXP016/017 y EXP06B la fijan a 61.44 MS/s.
5. Anotar la conexión de cada detector STM32. Los cálculos históricos de potencia toman el primer canal de cada línea DATA. Las líneas completas se guardan y permiten recuperar los demás canales. No confundir un canal que mide otra parte del montaje con la salida de la etapa bajo prueba.
6. Los valores de DSA se ajustan físicamente en ACE. MATLAB los registra como metadatos; no los cambia. Esta entrega estandariza TX DSA a **5 dB**. DSA RX inicial: **15 dB**. Atenuador RF de loopback inicial: **20 dB**. Confirmar esos valores en el montaje antes de medir; si cambian, corregir la configuración y repetir las referencias que dependen de ellos.

`baseline/Baseline_Power_Tx_Pluto.csv` es la única calibración histórica copiada de entrada. Es el archivo original de DPDv2, verificado byte por byte; no se vuelve a calcular ni se sobrescribe en esta secuencia. Las nuevas mediciones empiezan en el BGU.

La tabla contiene **201 puntos**, con columnas `TxGain_dB` y `Potencia_SA_dBm`, entre -50 y 0 dB de ganancia TX. Por ejemplo, TX gain=-22.25 dB corresponde a **-30.175 dBm** de potencia de salida en esa calibración. Para una ganancia intermedia se interpola la curva. Así se convierte la consigna de ganancia del Pluto en una estimación de potencia física de entrada a la cadena; no se está convirtiendo directamente una unidad dB en dBm.

EXP01 y la estimación de potencia de los entrenamientos leen ese CSV. EXP02 usa la salida BGU obtenida a partir de él. Los cálculos heredados de EXP03–04 conservan además el ajuste lineal histórico de la curva Pluto, `Pout ≈ 0.9935446912·TxGain − 8.1924257506`, para sus campos de potencia Pluto; no reajustan sus coeficientes ni hacen otra calibración. La potencia de entrada al upconverter/downconverter se apoya en los baselines medidos de BGU/RF. Por eso no debe suponerse que todos los campos de todas las etapas proceden de la interpolación exacta del CSV.

Se conserva pico original 0.8 y las condiciones de la calibración. La tasa nueva de EXP016 debe acompañarse de la referencia sin DPD correspondiente: el baseline histórico no equivale a haber recalibrado físicamente el Pluto a cada tasa.

Las etapas 1–4 conservan los métodos de las versiones de compresión existentes, con rutas locales y publicación automática. Mantienen sus límites y filtrado de puntos por potencia. No transmiten todos los niveles sin aplicar esas condiciones. Los barridos máximos son editables en cada archivo; el rango efectivo puede reducirse por las guardas heredadas.

## Cómo distinguir compresión de un límite del medidor

El piso cercano a **-32 dBm** corresponde al comportamiento práctico observado del detector y su conversión en este montaje, no a una especificación universal de todos los canales. Se trata de potencia absoluta en dBm, no de ganancia en dB. Confirmar el rango útil del detector utilizado en cada conexión.

- **Piso inferior:** si al seguir bajando TX la lectura queda casi fija alrededor de -32 dBm, o el ADC/voltaje se aproxima a cero, el detector ha dejado de resolver la potencia. Ese tramo no demuestra compresión ni sirve para calcular ganancia de pequeña señal. Sumar la corrección del atenuador no recupera una medición que el detector no pudo realizar.
- **Saturación superior:** si al subir TX la lectura o el voltaje/ADC queda pegado a su extremo, puede estar saturando el detector o su adquisición. No atribuir automáticamente esa meseta al amplificador. Un límite de protección de software no equivale a haber caracterizado el límite metrológico del detector.
- **Tramo útil:** seleccionar la referencia de ganancia donde el detector responda a cambios de nivel, esté por encima de su piso y lejos de saturación superior, y la etapa todavía esté en región lineal. Si no hay suficientes puntos en ese intervalo, no hay base para informar un P1dB fiable.
- **Huecos y tramos rectificados:** los NaN pueden indicar puntos omitidos o inválidos. En EXP01 existe además una extrapolación explícita de pequeña señal para alimentar el siguiente baseline; identificarla en `IFBoardOutputBaselineSource` y `DetectorReliableForBaseline`. Una curva dibujada o extrapolada no convierte un tramo bajo el piso en una medición válida.

Si el detector satura arriba, aumentar la atenuación de protección **antes del detector**, registrar su valor real y repetir la medición. Si se llega al piso inferior, puede requerirse menos protección en una medición separada de los niveles bajos, conservando el margen del instrumento. No retirar atenuación durante un barrido sin separar y documentar las condiciones. No confundir ese cambio con quitar el atenuador RF de loopback que protege al downconverter.

Los filtros heredados NO son idénticos en todas las etapas:

| Etapa | Guarda inferior presente en el código | Qué implica |
|---|---|---|
| EXP01, líneas 888–890 | Lectura del detector >-32 dBm y voltaje >0.15 V; referencia preferida por debajo de -24 dBm | El piso se filtra antes de la corrección de protección. No se calcula compresión de los puntos marcados no fiables. |
| EXP02, línea 542 | `minimumValidOutputPower_dBm=-90`, aplicado a potencia corregida | No garantiza excluir un detector que se quede en -32 dBm. Revisar lectura original y voltaje antes de aceptar su referencia y baseline. |
| EXP03, línea 590; EXP04, línea 605 | `minimumValidIFOutputPower_dBm=-90`, aplicado a potencia IF corregida | Tampoco garantiza excluir el piso del detector. Verificar manualmente el intervalo usado para estimar la ganancia lineal. |

Se conservan esos umbrales para no modificar el procesamiento original sin señalarlo. No asumir que la publicación automática de un baseline o la selección automática de punto validan el rango útil del instrumento. Si hay lecturas de piso o saturación en los puntos de referencia de EXP02–04, detener el uso de ese baseline, corregir el rango físico de medición y repetirlo; cualquier adaptación posterior del filtro de validez debe documentarse como cambio de versión.

EXP01 conserva un corte de protección de lectura de +2 dBm y EXP02 uno de 0 dBm; son valores configurados en los códigos originales, no una autorización universal para aplicar esos niveles a cualquier detector. Mantener los límites reales del equipo. Las guardas de RF_IN de EXP03–04 se refieren a la entrada del downconverter, no a la fiabilidad del medidor IF.

## Experimento 1: conexión y ejecución

Conexión de partida del código:

```text
Pluto TX, 5 GHz
  → entrada de placa IF / BGU 1
  → atenuador intermedio de 3 dB
  → BGU 2
  → atenuador de protección de 6 dB
  → detector IF LTC5596 / STM32
```

No incluir upconverter, downconverter ni Pluto RX en esta medición. El atenuador intermedio de 3 dB pertenece a la cadena de BGU descrita por el código; el de salida de 6 dB protege el detector y su pérdida se suma a la lectura para reconstruir la potencia a la salida de la cadena IF. No insertar un atenuador entre Pluto y BGU sin incorporar su pérdida en la calibración de entrada.

Si el atenuador de protección instalado no es de 6 dB, cambiar `C.bguProtection_dB` por el valor real. No conservar una corrección de 6 dB cuando no existe físicamente ese atenuador.

Ejecutar EXP01. Barre ganancia TX desde -44 hasta -6 dB en su configuración heredada, sujeto al corte de protección del detector. Guarda cada lectura y calcula ganancia de cadena y pérdida de ganancia respecto a los puntos de pequeña señal. Revisar que la referencia lineal tenga potencia medible: los puntos por debajo del rango útil del detector no son una referencia física fiable.

Al terminar publica automáticamente `Baseline_Power_IF_Board.csv`. La tabla distingue mediciones fiables y valores extrapolados desde pequeña señal; no tratar una extrapolación como medición directa. Para la zona de operación que se vaya a utilizar en DPD debe haber datos medidos suficientemente fiables.

Esta conexión mide **los dos BGU como conjunto**. No identifica por separado cuál BGU comprime. Los niveles internos calculados con ganancias típicas son estimaciones, no mediciones entre BGU 1 y BGU 2. Separarlos requeriría medir también ese punto intermedio.

## Experimento 2: compresión del upconverter

```text
Pluto TX → placa IF/BGU completa
  → IF_IN del upconverter, TX DSA=5 dB
  → RF_OUT
  → filtro de 26 GHz
  → atenuador de protección RF de 20 dB
  → detector RF adecuado para esa frecuencia / STM32
```

El downconverter y Pluto RX no forman parte de esta medición. Utilizar el canal de detector que realmente mide RF; el código histórico lee el primer grupo de la línea DATA. Si ese grupo no corresponde al detector conectado, corregir el mapeo antes de utilizar los datos.

Se carga automáticamente el baseline BGU de EXP01 para estimar la potencia en IF_IN. Se reconstruyen por separado potencia después del filtro y en RF_OUT, usando `C.rfMeterProtection_dB=20` y `C.filterLoss_dB=3`. Las pérdidas de cables declaradas en el archivo también deben coincidir con las reales. La pérdida del filtro es una corrección, no una ganancia adicional medida.

El barrido heredado es -34 a -17 dB de ganancia TX. Revisar la curva de ganancia del upconverter frente a su potencia de entrada estimada. Para atribuir la compresión a esa etapa, confirmar que el baseline BGU permanece lineal alrededor del punto que se pretende utilizar. Si el BGU ya comprime, no interpretar toda la compresión de la cadena como exclusiva del upconverter.

Al terminar se publican los dos nombres estables de baseline RF indicados en la tabla inicial. No copiar archivos manualmente ni reutilizar el de TX DSA=7 dB.

## Experimento 3: compresión del downconverter

```text
Pluto TX → BGU → IF_IN upconverter, TX DSA=5 dB
  → RF_OUT → filtro 26 GHz
  → atenuador RF de loopback de 20 dB
  → RF_IN downconverter, DSA RX declarado en el montaje
  → IF_OUT
  → protección IF, si existe
  → detector IF / STM32
```

El atenuador RF ahora es parte del loopback hacia RF_IN; no es la protección del detector RF de EXP02. Se conserva el filtro. La corrección IF por defecto es 0 dB porque el montaje de partida no incluye un atenuador entre IF_OUT y detector; si se instala uno, registrar su valor positivo en `C.ifMeterProtection_dB`.

Pluto RX todavía no es necesario para esta medición. Mantener el downconverter en el ajuste DSA RX que se está caracterizando. El código no puede cambiarlo automáticamente.

EXP03 estima la potencia de entrada RF a partir del baseline medido en EXP02, descuenta el loopback y calcula la ganancia del downconverter a partir de la potencia IF medida. Su barrido solicitado es -34 a -14 dB, pero elimina niveles que exceden el límite RF_IN heredado: máximo -8 dBm y margen de planificación de 1 dB, es decir, se planifica hasta -9 dBm. No anular ese filtro para forzar la búsqueda de P1dB. Si no aparece compresión dentro del rango permitido, el resultado correcto es que no se encontró en ese rango.

Se publica `Baseline_Downconverter_Compresion.csv`. Comparar pérdida de ganancia del downconverter con la del upconverter: la entrada al downconverter ya puede provenir de una etapa comprimida. La separación de ganancias depende de las mediciones previas, no de asumir una transmisión lineal perfecta.

## Experimento 4: observación con la cadena armada

Conservar el loopback del experimento 3. Fijar el DSA RX de trabajo a **15 dB** si ese es el ajuste físico confirmado. Medir IF_OUT con el detector; preparar la salida IF hacia Pluto RX para EXP05–06 con las mismas pérdidas, sin añadir o retirar divisores sin anotarlo.

```text
TX → BGU → upconverter → filtro → loopback 20 dB
  → downconverter, RX DSA=15 dB
  → punto de observación IF
      ├─ detector IF / STM32
      └─ Pluto RX para las etapas siguientes
```

La bifurcación representa el montaje de observación real, mediante el punto de prueba, acoplador o divisor disponible. No conectar dos cargas con una T improvisada. Si se incorpora un divisor, sus pérdidas modifican los niveles y deben medirse/declararse; las calibraciones antes y después deben representar el mismo camino.

EXP04 solicita el rango -40 a -20 dB y aplica los límites RF de entrada. Se amplió el extremo respecto a la versión previa (-24 dB) para poder revisar la zona histórica cercana a -22.25 dB sin extrapolar. Si los límites impiden llegar, modificar el montaje de atenuación y repetir las calibraciones correspondientes, no forzar un punto no medido.

Se publica `Baseline_Downconverter_ObservationPath.csv`. Revisar que la ganancia del downconverter permanezca estable en el intervalo elegido para DPD. EXP05–06 solo usan niveles dentro del intervalo medido y con desviación absoluta de ganancia estimada del downconverter menor o igual a 0.2 dB. Ese margen es una tolerancia práctica, no una precisión de instrumento demostrada.

## Experimento 5: EVM directa

Conectar la cadena completa de EXP04 hasta Pluto RX y conservar el detector en el punto IF identificado. No cambiar ganancias o atenuaciones entre la medición del detector y la captura IQ.

EXP05 transmite la señal original con pico 0.8, captura 80 ms y entrega los primeros 10 ms directamente a `hNRDownlinkEVM`, sin correlación/alineamiento externo con TX. El auxiliar NR mantiene sus correcciones internas de frecuencia y ecualización, como en el flujo histórico: «directa» no significa desactivar el procesamiento interno del demodulador NR.

El rango editable está en `C.evmGains`; parte de -34 a -20 dB en pasos de 0.5 dB y se limita a los puntos de observación admitidos. RX=8 dB. Se guarda `EVM_NR_Direct_pct`; el campo de EVM sincronizada queda NaN. Las capturas brutas y errores del demodulador quedan guardados. Si no hay al menos tres puntos válidos, se conservan los archivos de la corrida, pero no se reemplaza el baseline estable.

## Experimento 6: EVM sincronizada, referencia y punto de compresión

No cambiar el montaje de EXP05. EXP06 añade el sincronizador de EXP015 original: correlación gruesa diezmada, búsqueda fina de retardo entero y métricas de ganancia y sincronía; modo histórico sin corrección CFO externa. La EVM NR sigue siendo la del demodulador NR. No confundirla con la EVM de forma de onda.

Se generan automáticamente:

- CSV de referencia compatible con el lector de EXP015 dentro de `data/.../processed`, con sufijo `OFFICIAL_NODPD_REFERENCE.csv`.
- Copia estable `baseline/Referencia_sin_DPD_automatica.csv`.
- `Baseline_Cadena_Completa.csv`, que contiene EVM/potencia actuales, compresión de etapas estimada con los baselines recientes y compresión global IQ/detector respecto a los niveles de `C.linearGains` (-32, -30 y -28 dB por defecto).
- `Punto_operacion.mat`, solo si hay candidato válido.

El criterio automático inicial busca la primera ganancia con EVM/sincronía válidas, compresión estimada del upconverter entre **0.5 y 0.75 dB**, y desviación absoluta de ganancia BGU y downconverter no mayor a 0.2 dB. El objetivo 0.5 dB se configura en `C.targetCompression_dB`. La decisión se apoya en las mediciones de etapa; no localiza un transistor o amplificador interno del módulo.

Comprobar que los tres niveles tomados como referencia lineal realmente lo son y que el detector está en su rango útil. La compresión global y la separación por etapas no deben contradecirse sin explicación. Si detector e IQ no responden de forma coherente a cambios conocidos de nivel, resolverlo antes de declarar un punto validado.

Si no hay candidato, no se inventa uno: se avisa y se retira del uso el punto anterior cuando el criterio de selección llega a esa conclusión. Si la adquisición falla antes de terminar, no interpretar el punto de una corrida anterior como nueva confirmación; revisar la fecha y la corrida de procedencia guardadas.

## EXP015: réplica histórica con punto configurable

Conservar el montaje completo. Se entrega una copia byte a byte del archivo histórico en `code/originales/EXP015_original_sin_cambios.m` para trazabilidad; el archivo a ejecutar es `code/EXP015_GMP_original_punto_configurable.m`.

La variante ejecutable conserva la señal y el algoritmo del EXP015 recibido: cuatro modelos GMP de 29, 33, 37 y 35 coeficientes; hasta cinco iteraciones; `mu=0.08` desde la segunda iteración; primera actualización completa; `lambdaRel=0.05`; tasa automática; normalización histórica RMS/pico; bordes históricos; criterio histórico de selección. No carga coeficientes de EXP031 ni de otro entrenamiento nuevo.

El punto se modifica **dentro del propio código**, sin editar un archivo aparte. En la **línea 51** de cada archivo de entrenamiento está:

```matlab
fixedTxGain_Pluto = -22.25; % EDITAR AQUI: ganancia TX (dB) del punto de compresion medido.
```

| Archivo | Línea a editar |
|---|---:|
| `code/EXP015_GMP_original_punto_configurable.m` | **51** |
| `code/EXP016_GMP_original_tasa_61M44.m` | **51** |
| `code/EXP017_GMP_lambda_delta.m` | **51** |

Sustituir únicamente `-22.25` por la ganancia TX correspondiente al punto medido. Por ejemplo, si la caracterización confirma el punto a -23 dB, escribir `fixedTxGain_Pluto = -23.00;`. Es ganancia TX en dB, no potencia de salida en dBm ni cantidad de compresión. Introducir el mismo punto en los tres archivos cuando se comparen entre sí.

EXP06 guarda el candidato en `Punto_operacion.mat` y lo muestra en pantalla, pero **no cambia automáticamente** el valor dentro de EXP015/016/017. Revisar la fecha y las condiciones de ese resultado y trasladar al código el valor que se haya confirmado en laboratorio. `configuracion_b31.m` ya no contiene una opción alternativa para sobrescribir la ganancia de entrenamiento.

Se conservan Power Scale Factor=0.8 y los parámetros originales del ajuste GMP. Los cambios de soporte respecto al archivo histórico son la ruta a helpers y una comprobación de procedencia de referencia (tasa, pico y RX) antes de transmitir; la asignación numérica del punto sigue el formato original. Las diferencias exactas aparecen en `DIFERENCIAS_EXP015.patch`.

RX permanece en 8 dB y el puerto histórico es COM12 en los archivos de entrenamiento. Si el equipo requiere otro puerto, editar esa asignación en los tres archivos de entrenamiento y documentar el ajuste de entorno; cambiar `C.serialPort` afecta a caracterización/EVM, pero no altera silenciosamente el original GMP. El auxiliar `hNRDownlinkEVM` debe estar en el path de MATLAB, como en el experimento histórico.

No restauramos a la vez algoritmos nuevos ni corregimos la normalización histórica: el objetivo de esta etapa es reproducir la referencia. Mantener pico original 0.8 no significa que el pico GMP quede siempre en 0.8; el original permite hasta 0.88 y puede bajar el RMS al limitarlo. Registrar ese efecto antes de atribuir toda mejora al algoritmo.

## EXP016: cambiar solamente la tasa

Ejecutar primero EXP06B para obtener referencia sin DPD con 61.44 MS/s. Después ejecutar EXP016. Respecto a la variante EXP015, solo cambia `cfgDLFRC.SampleRate` a 61.44e6 y las etiquetas de la carpeta de resultados. La verificación de referencia es la misma en ambos y evita reutilizar una tasa incompatible.

Mu, lambda relativo, modelos, normalización, bordes y número máximo de iteraciones permanecen iguales. El mismo retardo en muestras representa otra duración física al cambiar de tasa; esto forma parte del efecto de cambiar la tasa, no de un ajuste adicional de memoria.

El pico original sigue en 0.8. Comprobar de nuevo niveles y compresión al cambiar la tasa: el remuestreo/generación puede cambiar el PAPR y la potencia media aun conservando ese pico.

El histórico calcula un ACPR total a partir de los bins disponibles. A tasa automática puede integrar adyacentes incompletos; **no usar ese número como ACPR completo**. A 61.44 MS/s caben las bandas [-30,-10], [-10,+10] y [+10,+30] MHz, pero quedan solo 0.72 MHz hasta Nyquist en cada extremo. Eso no prueba que la respuesta analógica/digital de observación sea útil en todos esos puntos.

Después de una corrida completa, ejecutar offline:

```matlab
addpath('code','code/funciones')
reprocesar_ACPR_b31('RUTA_COMPLETA_A_LA_CARPETA_data_EXP016_DE_LA_CORRIDA');
```

La rutina integra **IQ bruto**, produce `ACPR_IQ_BRUTO_B31.csv` y separa cocientes observados de validados. Con `verifiedRxUsefulBW_Hz=NaN` o sin `evidenceRxBW`, los resultados validados permanecen NaN. Solo completar esos campos con evidencia de caracterización de filtros/downconverter/receptor; no escribir 60 MHz por el hecho de usar 61.44 MS/s. El indicador no aplica una calibración de respuesta automáticamente: si la respuesta requiere corrección frecuencial, esa calibración todavía debe incorporarse antes de certificar el resultado RF.

Si la banda útil no cubre los adyacentes, conservar el resultado observado y medirlos mediante sintonización RX por separado o un analizador apropiado. Esta entrega no implementa un barrido de sintonía de los adyacentes ni promete cobertura física que no se haya medido.

La referencia se autodetecta como en el original. Si después de EXP06B se quiere repetir EXP015 automático, repetir EXP06 para que la referencia más reciente vuelva a corresponder a la tasa automática. Una tasa incompatible detiene el entrenamiento antes de transmitir.

## EXP017: nuevo algoritmo lambda–delta

Ejecutar después de validar EXP015/016. Utiliza la misma tasa ancha y las mismas cuatro bases de EXP016. Cambia el ajuste de coeficientes por:

```text
minimizar  (1/N) ||X_normalizada·d − objetivo||² + lambda ||d||²
sujeto a   ||d − d_anterior||₂ ≤ delta
```

Las escalas de columnas se calculan una sola vez con la señal original y se congelan por modelo. El vector inicial representa identidad. El radio restringe el incremento en esas coordenadas normalizadas. No se usa mezcla mu: se aplica el incremento restringido completo. Los valores iniciales son `C.lambdaNuevo=0.05` y `C.deltaNuevo=0.1`.

Este lambda corresponde al coste normalizado anterior; **no es el mismo parámetro efectivo que `lambdaRel` del original**, aunque ambos empiecen numéricamente en 0.05. Delta no es porcentaje de potencia ni de amplitud. La solución se obtiene por ridge y multiplicador de Lagrange cuando la restricción está activa.

No se normaliza RMS/pico después de resolver: hacerlo cambiaría los coeficientes y podría invalidar el radio. Si la onda propuesta supera pico digital 0.95 o no es finita, se guarda y no se transmite. Las capturas no utilizables y las iteraciones que no cumplen guardas detienen esa corrida del modelo. Se comprueba el pico RX real en esta variante. Las estructuras y el objetivo histórico de identificación se mantienen; cambiar a la vez la arquitectura de aprendizaje queda fuera de esta etapa.

Se guardan `restricted_model_*_iter_*.mat` con escalas, vectores anterior/nuevo, lambda, delta y estado del solver; `restricted_acceptance_*` registra la aceptación tras medir. Los MAT/CSV históricos y las capturas brutas se conservan. Las variables de compatibilidad del histórico no sustituyen a esos campos para identificar el ajuste restringido.

Comparar resultados de EXP016 y EXP017 a igual potencia observada usando una referencia sin DPD compatible y repetir las corridas. La copia histórica conserva su forma de selección; una corrida aceptada no demuestra por sí sola mejora de EVM o ACPR.

## Baselines, historial y resultados

Los baselines nuevos se publican al finalizar cada medición. Si existe el nombre estable, se copia primero a `baseline/historial` con fecha y hora y luego se reemplaza automáticamente, sin pedir copiar rutas ni sobrescribir a mano. Un CSV con menos de tres puntos o sin tres lecturas válidas cuando contiene contador de muestras no se publica. Que se publique significa que hay datos suficientes para guardarlo, no que se haya demostrado compresión o validez física de todo el montaje.

`data` recibe las referencias EVM y los entrenamientos GMP. Las etapas de compresión conservan sus carpetas con fecha en `resultados`, creadas automáticamente en la raíz B3.1. Cada corrida guarda parámetros, tablas y, cuando corresponde, IQ bruto. No copiar los baselines del montaje anterior por encima de las nuevas mediciones.

Repetir las etapas dependientes si cambia atenuación, detector, ganancia, señal o montaje. No mezclar el baseline de BGU recién medido con un baseline RF de otra condición. Las pérdidas internas y ganancias inferidas siguen dependiendo de la calibración y del rango útil de los detectores.

## Verificación de esta entrega

Se compararon las instrucciones de figuras de EXP01–04 directamente con sus códigos de origen de DPDv2: coinciden las llamadas de creación, trazado, ejes, títulos, leyendas y guardado. Lo mismo se comprobó para EXP015. No se rediseñaron ni se reemplazaron por gráficos nuevos. Eso no garantiza que una curva adquirida con el detector fuera de rango sea interpretable: debe aplicarse la revisión metrológica anterior.

Las pruebas EVM EXP05–06 sí son rutinas nuevas con IQ y tablas guardadas; no son copias completas de las pantallas de un experimento anterior. Los auxiliares organizan generación NR, sincronización histórica, lectura STM32, publicación y validación de referencias. EXP015 conserva el algoritmo original; EXP017 cambia deliberadamente el ajuste y algunas guardas, como se detalla en esta guía y en los archivos de diferencias.

Los códigos de compresión no son copias byte por byte: se adaptaron rutas, configuración y publicación automática; se mantienen visibles las advertencias; la tasa queda automática y el pico original es 0.8. Se unificó la referencia del upconverter a TX DSA=5 dB. EXP04 amplió su extremo de barrido de -24 a -20 dB, conservando los límites de RF_IN, para revisar el punto histórico sin extrapolar. Estos cambios pueden alterar qué datos aparecen en una figura, pero no rediseñan la figura. Los valores de pérdidas de la configuración deben describir el montaje real.

`code/VALIDAR_OFFLINE_B31.m` revisa sintaxis y comprueba con señales sintéticas el solver, su radio delta, las condiciones KKT y la integración espectral. No conecta equipos. La validación offline se ejecutó en MATLAB R2024b; los diagnósticos se entregan aparte. No se han ejecutado las mediciones físicas ni se afirma que el montaje ya esté validado.

Las diferencias y procedencias se entregan en `MANIFIESTO.json` y los archivos `.patch`. El original EXP015 de archivo se verificó por SHA-256. La ejecución del original conservado no selecciona el nuevo punto automáticamente: para la secuencia de esta guía se ejecuta la variante de `code`, no el archivo de `code/originales`.
