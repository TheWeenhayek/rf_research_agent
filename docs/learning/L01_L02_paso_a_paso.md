# L01 y L02 paso a paso: qué hace cada sección y cómo leer cada figura

Convención: cada módulo `sim/learn/L0N_*.m` tiene su guía en `docs/learning/`. La guía dice (1) qué hace cada paso, (2) por qué, (3) cómo debe verse la figura y (4) qué diagnóstico se lleva al laboratorio.

Los números son del modelo simulado (PA inventado, anclado a datos reales donde se indica). Lo importante son las formas.

---

## L01: por qué un PA o upconverter necesita DPD

**Idea central.** Una señal OFDM tiene picos raros muy altos (PAPR ≈ 11 dB). Esos picos llevan al amplificador a compresión aunque la potencia media sea moderada. La compresión produce dos daños: distorsión dentro de la banda (sube el EVM) y energía fuera de la banda (sube el ACPR). El DPD intenta deshacer eso en banda base.

### Paso 1. Señal de prueba (Fig. L01-1)
- **Qué hace:** genera símbolos 256-QAM aleatorios en 612 subportadoras (51 RB × 12, 20 MHz, SCS 30 kHz), hace IFFT, añade prefijo cíclico y filtra el borde de banda.
- **Por qué el filtro:** al pegar símbolos sin ventana aparecen "faldas" espectrales. Sin filtrarlas, la entrada ya tendría mal ACPR y taparía lo que hace el PA. Se corta justo en el borde (0.5·BW); cortar en 0.52·BW dejaba un piso de −28 dBc.
- **Cómo se ve:**
  - Espectro: un bloque plano de ±9.2 MHz con piso de −60 dB. La muesca en el centro es la subportadora DC sin usar.
  - Histograma de amplitud: forma Rayleigh con cola larga.
  - CCDF: la probabilidad de que la potencia instantánea supere el promedio en 10 dB es del orden de 10⁻⁴ a 10⁻⁵.
- **Números de consola:** PAPR ≈ 11 dB (paper: 11.3), ACPR de la entrada ≈ −40 dBc, EVM de la entrada contra sí misma = 0.000 %. Ese último es la prueba de que el demodulador está bien.
- **Laboratorio:** el ACPR de la entrada es el piso: ningún ACPR medido puede ser mejor. Si el DPD "no mejora más allá de X dBc", revisa primero el piso de la señal, del TX y del receptor.

### Paso 2. Barrido de potencia (Fig. L01-2)
- **Qué hace:** escala la misma señal a 33 niveles (de −34 a −2 dB) y la pasa por el PA simulado. Es el equivalente de barrer `TxGain` en el Pluto.
- **Qué calcula por punto:**
  - Ganancia G = Pout − Pin (potencias medias).
  - G_ss = promedio de los primeros 5 puntos (señal pequeña).
  - Compresión C = G_ss − G (Ec. 1 del paper).
  - EVM y ACPR.
- **Cómo se ve:**
  - Pout vs Pin: una recta que se curva hacia abajo.
  - C: cero hasta ≈ −15 dB, luego sube y cruza 1 dB en −4.9 dB.
  - EVM: ≈ 0 % hasta ≈ −20 dB, luego sube. Cruza el límite de 3.5 % en C ≈ 0.2 dB, mucho antes del P1dB.
  - ACPR: plano en −40 dBc (el piso de la entrada) y luego sube ≈ 1.8 dB por cada dB de entrada.
- **Tabla de consola (C = 0.1 / 0.5 / 1.5 dB):** EVM 2.4 / 6.1 / 12.7 %, ACPR −34.5 / −27.3 / −21.1 dBc. En 0.5 dB el paper reporta 6.47 % y −26.57 dBc.
- **Laboratorio:** con 256-QAM no hace falta llegar a P1dB para incumplir 3GPP. Si tu EVM a baja potencia no es plano, el problema no es el PA: es ruido, sincronización o alineación.

### Paso 3. AM/AM y AM/PM en tres puntos (Fig. L01-3)
- **Qué hace:** para C = 0.1, 0.5 y 1.5 dB dibuja, muestra por muestra, |salida| contra |entrada| (AM/AM) y el desfase salida−entrada contra |entrada| (AM/PM). Ambos se normalizan por la ganancia compleja de señal pequeña.
- **Cómo se ve:**
  - AM/AM: sigue la recta (línea discontinua) a amplitud baja y se aplana a amplitud alta. Cuanto mayor es C, antes se aplana.
  - **El ancho de la nube es memoria.** Sin memoria sería una línea fina, porque la salida dependería solo de la entrada actual.
  - AM/PM: ≈ 0° a amplitud baja y sube hasta ≈ 15° a amplitud alta (es el `phi` del modelo).
  - Los ±100° a amplitud muy baja **no son física**: el cociente de fases de dos números casi nulos es ruido. El paper de Lagrava describe lo mismo ("la fase queda dominada por ruido a baja amplitud").
- **Laboratorio:** al ver AM/AM y AM/PM medidos, ignora la zona de amplitud baja y juzga solo la parte alta. La nube gruesa te dice cuánta memoria hay y qué tan útil será un modelo con memoria (MP, GMP).

### Paso 4. Espectros (Fig. L01-4)
- **Qué hace:** compara el espectro de la entrada con el de la salida en los tres puntos.
- **Cómo se ve:** aparecen "hombros" a ambos lados del bloque, y crecen con la compresión. Su ancho llega a ≈ ±27 MHz, 3 veces la mitad de la banda: es la firma del producto de 3er orden. El tramo plano hacia ±30 MHz es 5º orden **replegado** (aliasing), porque a 61.44 MS/s el 5º orden caería en ±46 MHz.
- **Definición de ACPR usada:** canal principal |f| ≤ BW/2, canales adyacentes [0.5, 1.5]·BW, y se **suman** los dos lados (igual que `computeACPRCentered` de EXP020). Un ACPR de un solo lado se lee ≈ 3 dB mejor.
- **Laboratorio:** el receptor del Pluto no ve limpiamente ±27 MHz (el LEEME de EXP031–037 lo advierte). Tu ACPR medido es parcial. Interpreta diferencias de 1–4 dB con cuidado.

### Paso 5. Constelaciones (Fig. L01-5)
- **Qué hace:** demodula cada subportadora, la ecualiza con una toma compleja por subportadora y dibuja los puntos.
- **Cómo se ve:** con C = 0.1 dB (EVM 2.4 %) se distingue la rejilla 16×16. Con 0.5 dB (6.1 %) casi no se separa. Con 1.5 dB (12.7 %) es una nube cuadrada.
- **Laboratorio:** la constelación te dice si el error es "nube redonda" (ruido), "rejilla comprimida hacia el centro" (compresión) o "rejilla rotada según la amplitud" (AM/PM).

---

## L02: la cadena de medida y el mapa de EVM

**Idea central.** El detector solo puede medir un punto a la vez, detrás de un atenuador de protección. Cada bloque se caracteriza en un barrido aparte, y su entrada se **estima** con el baseline del bloque anterior. Por eso los scripts se pasan CSV a mano. En la Parte B se barre TX × RX para elegir el punto de operación.

### Paso 1. Modelo de la cadena (sin figura)
- **Qué hace:** simula Pluto → IF → upconverter → filtro → atenuador de loopback → downconverter → RX con ruido y recorte del ADC. En el código, amplitud² = mW, así que dBm = 10·log10(mean|s|²).
- **Anclado a datos reales:** recta del Pluto (ajuste del baseline del analizador), ganancias de IF y upconverter (≈ 20.8 dB), compresión del upconverter (0.5 dB en TX −22.25, P1dB ≈ −19.8), loopback de 30 dB, filtro de 3 dB, detector 28.8 mV/dB.
- **Inventado:** ganancia del downconverter, pisos de ruido, calibración de escala del RX.

### Paso 2. Calibración (consola)
- **Qué hace:** ajusta la saturación del IF (C = 0.5 en TX −15, del CSV real) y luego la del upconverter (C = 0.5 en TX −22.25). Fija la constante del RX para que el punto nominal quede en −18 dBFS.
- **Por qué ese orden:** si el IF recorta picos primero, el upconverter ve una señal con menos picos y comprime menos.
- **Qué verificar:** "upconverter C at TX −22.25 = 0.50, at −19.8 = 1.03", que cuadra con el P1dB del paper (−19.78).

### Paso 3. Parte A, barrido de TX con el medidor (Fig. L02-1)
**Panel superior izquierdo, detector.** La línea ideal y la lectura coinciden por encima de ≈ −35 dBm. Por debajo el detector se aplana en −42 dBm (su piso). Cerca del piso lee de más (el piso suma potencia), y por eso EXP002 define "puntos válidos": medidor > −32 dBm y V > 0.15 V.

**Panel superior derecho, ganancias.** Los marcadores son estimadas y las líneas son verdaderas. IF ≈ 21 dB y upconverter ≈ 20.8 dB, planos a TX bajo. Luego el upconverter cae primero (hacia −20) y el IF después. El downconverter queda plano en 8 dB.

**Panel inferior izquierdo, compresión (el análogo de la Fig. 2 del paper).**
- Rojo = upconverter, azul = IF, amarillo = downconverter. Marcadores = estimado, líneas = verdadero.
- En la línea del punto DPD (−22.25 dB) solo el upconverter está en ≈ 0.5 dB.
- El IF estima 0.26 dB cuando el verdadero es 0.03. Ese sesgo viene de que G_ss se toma de los primeros puntos válidos, que están cerca del piso del detector, y ahí la lectura sube. Los puntos estimados también dispersan ±0.1–0.2 dB.
- El IF llega a 1 dB hacia −13 dB, dentro del barrido. Eso es coherente con `Baseline_Power_IF_Board.csv` (1 dB en −11 dB) y contradice la Tabla I del paper ("not reached"). Pendiente de aclarar a qué barrido se refería.

**Panel inferior derecho, presupuesto de potencia en el punto nominal.**
| Nodo | Potencia media |
|---|---|
| Salida del Pluto | −30.2 dBm |
| Salida del IF | −9.5 dBm |
| Pin RF_OUT del upconverter | +10.8 dBm |
| Después del filtro | +7.8 dBm |
| Entrada RF del downconverter | −22.2 dBm |
| IF de vuelta (medidor) | −14.2 dBm |

Nivel en el RX del Pluto: −18 dBFS rms, −11.5 dBFS de pico.

**Tabla de consola (Parte A):**
| Bloque | G_ss | TX en 1 dB, est. | TX en 1 dB, verd. | C en −22.25, est. | C en −22.25, verd. |
|---|---|---|---|---|---|
| IF | 21.05 | −13.2 | −12.8 | 0.26 | 0.03 |
| Upconverter | 20.78 | −20.2 | −19.9 | 0.49 | 0.50 |
| Downconverter | 8.00 | no | no | 0.08 | 0.00 |

- El upconverter se estima bien (P1dB −20.2 vs −19.9 verdadero; paper −19.78).
- El IF muestra el sesgo ≈ 0.2 dB.
- El downconverter no llega a 1 dB en el rango.

### Paso 4. Parte B, mapa de EVM (Fig. L02-2)
**Cómo se calcula.** Para cada (TX, RX) se corre la cadena con ruido y recorte, se demodula y se calcula el EVM. También se guarda el pico en dBFS para aplicar el criterio de aceptación del paper (pico RX < −3 dBFS).

**Panel superior izquierdo, el mapa.**
- Colores: azul oscuro = EVM bajo, rojo = EVM alto (escala logarítmica).
- Tres paredes: abajo-izquierda = **ruido** (poca señal sobre el piso del ADC), derecha = **compresión** (el upconverter), arriba = **recorte del RX**.
- Línea blanca discontinua: pico = −3 dBFS. La región aceptable queda debajo y a la izquierda. Línea roja: recorte real (0 dBFS).
- Cuadrado amarillo = punto nominal del paper (TX −22, RX 8): EVM ≈ 6.9 %, sobre la pared de compresión, a propósito.
- Estrella = mínimo EVM aceptado: 0.78 % en TX −36 / RX 24. Está en la **esquina del barrido**, así que el verdadero mínimo del modelo probablemente está más allá.

**Panel superior derecho, EVM vs TX (RX 8 y 16).**
- Forma de U. A la izquierda manda el ruido: el EVM baja al subir TX (más señal sobre el piso). A la derecha manda la compresión: sube con C_up (línea punteada, eje derecho).
- Con RX 16 la U es más baja que con RX 8, porque más ganancia RX supera mejor el piso del ADC.
- **A la derecha las dos curvas se juntan.** Cuando mandan la compresión y el upconverter, el RX ya no importa.

**Panel inferior izquierdo, EVM vs RX.**
- TX −22 (limitado por compresión): plano ≈ 6.8 % hasta RX ≈ 20 y luego sube porque el ADC recorta.
- TX −30 (limitado por ruido): baja de 5 % a 1.3 % y se aplana.
- La línea de puntos marca el límite del pico (RX ≈ 18 para TX −22).

**Panel inferior derecho, mejor RX por TX** (el `best-rx-per-tx` de EXP006).
- La mejor RX es la mayor permitida por el criterio de pico: 24 → 16 conforme sube TX.
- A TX alto (> −18) el EVM casi no depende de RX, y la mejor RX salta sin sentido (8–16).

**Tabla de consola (mejor EVM aceptado por TX):**
| TX | RX | EVM (%) | C_up (dB) |
|---|---|---|---|
| −36 | 24 | 0.78 | 0.00 |
| −32 | 20 | 1.09 | 0.01 |
| −28 | 16 | 1.96 | 0.06 |
| −24 | 16 | 4.39 | 0.27 |
| −20 | 16 | 10.14 | 0.97 |
| −16 | 16 | 18.41 | 2.34 |

---

## Diagnósticos que te llevas al laboratorio

| Observas | Probable causa | Cómo confirmarlo |
|---|---|---|
| El EVM cambia al subir RX | Limitado por ruido | Sube RX hasta que se aplane |
| El EVM no cambia al subir RX, pero sube con TX | Limitado por compresión | Revisa C_up y AM/AM |
| El EVM sube bruscamente al subir RX | Recorte del ADC | Mira el pico en dBFS |
| EVM bajo con muy poca potencia, ACPR plano | Normal: es el piso de señal/TX/RX | Compara con el ACPR de la entrada |
| AM/PM muy ruidoso a amplitud baja | Normal (cociente de fases) | Ignora esa zona |
| Compresión de un bloque algo ≠ 0 en señal pequeña | Sesgo de la referencia G_ss o piso del detector | Usa solo puntos bien sobre el piso |
| El "mejor RX" salta entre valores | EVM insensible a RX (compresión) | No interpretes ese argmin |
| El IF llega a 1 dB dentro del barrido | Revisar qué baseline usó el paper | Comparar con `IF_Board.csv` y `IF_Board_2.csv` |

Para detalles de cómo se mide y qué datos reales se usan, mira los comentarios al inicio de cada `.m`.
