# L03 paso a paso: la base MP y los mínimos cuadrados regularizados

Script: `sim/learn/L03_MP_basis_and_regularized_LS.m`. Salidas en `sim/learn/out/L03/`.
Equivale al paper de DPD en: Ec. 2–3 (base MP), Ec. 4–5 (LS con Tikhonov), Ec. 6 (mezcla µ) y Tabla II (tamaño del modelo). Los helpers (`buildMPMatrix`, `solveRegularizedLS`, `normalizeDPDWaveform`) son copias de `code/EXP020_...`.

Los números de abajo vienen de un port numérico con otra semilla: espera valores cercanos, no idénticos.

## La idea en 5 líneas

1. Un PA con memoria se puede aproximar con un polinomio: `z[n] = Σ_m Σ_k c(m,k) · x[n-m] · |x[n-m]|^(2k)`. Los términos son potencias impares (1, 3, …, 2K−1) y tienen M+1 retardos. Nc = (M+1)·K coeficientes.
2. En **aprendizaje indirecto (ILA)** no se identifica el PA. Se capturan la entrada u y la salida y, se normaliza `y_n = y/G` (G = ganancia compleja lineal) y se ajusta un **postdistorter**: un modelo f tal que `u ≈ f(y_n)`.
3. Ese f se copia delante del PA como **predistorter**.
4. El ajuste es lineal en los coeficientes: `y = X c + ε`. Se resuelve con LS regularizado: `ĉ = (XᴴX + λI)⁻¹ Xᴴ y`, con `λ = λ_rel · trace(XᴴX)/Nc` (así lo hace `solveRegularizedLS`).
5. En cada iteración se mezcla: `c(i+1) = (1−µ) c(i) + µ ĉ(i)`, con µ = 0.12 en el paper (Ec. 6).

## Preparación (sin figura)

- Dos señales OFDM independientes: **a** entrena y **b** valida.
- El nivel de entrada se ajusta por bisección hasta C = 0.5 dB, el punto del paper.
- Se simulan dos capturas ruidosas, una por señal. El ruido es SNR = 38 dB en la salida del PA (suposición: el piso del laboratorio es EVM ≈ 1.2 %).
- Consola: `max|y_n|` sale ≈ 0.94 y `max|u|` ≈ 1.48. El PA comprime los picos, así que los picos de `y_n` son menores que los de u. Eso importa en la parte D.

## Parte A: la base (Fig. L03-1)

**Qué hace:** construye la matriz X con las columnas `x[n-m]|x[n-m]|^(2k)` y mide cuán mal condicionada es.

- **Panel izquierdo:** las funciones base de un solo retardo. Todas "crecen" de forma parecida con |x|, solo con distinta pendiente.
- **Panel central:** correlación entre las 36 columnas de M5K6. Se espera una diagonal ancha de valores altos: órdenes vecinos (k, k+1) en el mismo retardo tienen |corr| de 0.88 a 0.99 (los de orden alto casi iguales), y el mismo orden en retardos vecinos ≈ 0.8, porque una señal de banda limitada cambia poco de una muestra a la siguiente. La mediana entre todas las parejas es ≈ 0.33, así que el problema está concentrado junto a la diagonal.
- **Panel derecho:** los valores singulares de X, normalizados. Cuanto más se despliegan, peor el condicionamiento. En la corrida real se ven escalones: cada orden k aporta M+1 copias retardadas casi iguales, y esas copias casi no añaden información nueva (interpretación probable, no verificada).
- **Panel central, en la corrida real:** se ven 6 bloques de 6×6 sobre la diagonal (uno por retardo m). Dentro de cada bloque, vecinos de orden k están casi pegados (≈ 0.9–1.0). Los bloques vecinos (retardos consecutivos) también correlacionan (≈ 0.7–0.8) y los lejanos casi no.

**Consola (corrida real):** cond(X) = 6.4×10¹ (M1K3, 6 coef.), 2.6×10³ (M3K5, 20), 1.6×10⁴ (M5K6, 36). Mediana de |corr| entre columnas distintas: 0.32; máxima: 0.989.

**Qué enseña:** cada coeficiente nuevo entra casi colineal con los anteriores. Sin regularizar, el ruido se amplifica por esas direcciones casi planas. Por eso el paper usa Tikhonov (Ec. 5) en lugar de LS puro.

## Parte B: tamaño del modelo y ruido (Fig. L03-2)

**Qué hace:** ajusta MP para M = 0…5 y K = 1…7 sobre la captura a y evalúa el NMSE sobre la captura b (validación): `NMSE = 10·log10(‖u − f(y_n)‖² / ‖u‖²)`. Usa λ_rel = 10⁻⁶, casi sin regularizar, para ver el efecto del tamaño solo.

**Panel izquierdo (mapa M×K):**
- M = 0 (sin memoria) satura cerca de −23 dB aunque subas K.
- M = 1 ya baja a ≈ −33.5 dB, y de ahí hasta M = 5 la mejora es de solo ≈ 2.5 dB más.
- K = 1 (solo lineal) ≈ −22 dB, K = 3 ≈ −33 dB, K ≥ 5 se aplana.
- **La memoria ayuda en la primera unidad de retardo, y el orden hasta K ≈ 4–5.** Después hay rendimientos decrecientes.

**Panel derecho y tabla de consola (los 3 modelos del paper contra la SNR de captura):**

| SNR (dB) | M1K3 | M3K5 | M5K6 |
|---|---|---|---|
| 200 (sin ruido) | ≈ −34.7 | ≈ −46.8 | ≈ −48.6 |
| 50 | ≈ −34.5 | ≈ −44.3 | ≈ −45.3 |
| 38 | ≈ −32.5 | ≈ −35.7 | ≈ −36.0 |
| 30 | ≈ −27.7 | ≈ −28.4 | ≈ −28.6 |

**Corrida real (M1K3 / M3K5 / M5K6):** 200 dB → −34.3 / −46.0 / −47.8; 50 dB → −34.2 / −43.8 / −44.9; 38 dB → −32.3 / −35.6 / −35.9; 30 dB → −27.6 / −28.4 / −28.5. En el mapa M×K con SNR 38: la memoria aporta sobre todo al pasar de M = 0 (−23) a M = 1 (−33) y a M = 2 (−35.6); desde M = 2 no cambia nada. El orden satura en K ≈ 5.

**Qué enseña — dos regímenes:**
- **Limitado por el modelo (M1K3):** da ≈ −34 dB con SNR de 200 o de 50 dB. El ruido solo lo empeora cuando baja de ~40 dB. Su límite es que le faltan términos.
- **Limitado por el ruido (M3K5, M5K6):** con SNR 38 dB quedan casi iguales (≈ −36 dB, parecido a −SNR). A 30 dB ya ni M1K3 se distingue. Sin ruido, en cambio, el modelo grande gana ≈ 14 dB sobre el pequeño.
- Es la explicación de la Tabla II del paper: "agregar coeficientes no dio mejora monótona" (M1K3: 2.83 % de EVM; M5K6: 2.86 %). La simulación no demuestra el mecanismo real del laboratorio, pero es una explicación coherente.

**Laboratorio:** antes de probar un modelo mayor, estima la SNR de tus capturas. Si el NMSE de validación ya está cerca de −SNR, un modelo más grande no va a ayudar.

## Parte C: regularización λ (Fig. L03-3)

**Qué hace:** para M5K6 barre λ_rel de 10⁻¹⁰ a 1 y mide NMSE de entrenamiento y validación, ‖c‖ y el número de condición de (R + λI).

**Consola (corrida real, M5K6, SNR 38):**

| λ_rel | NMSE val (dB) | ‖c‖ | cond(R+λI) |
|---|---|---|---|
| 10⁻¹⁰ | −36.0 | 12.2 | 2.5×10⁸ |
| 10⁻⁶ | −35.9 | 2.3 | 1.7×10⁷ |
| 10⁻³ | −35.4 | 1.1 | 1.9×10⁴ |
| 10⁻² | −33.2 | 1.04 | 1.9×10³ |
| 10⁻¹ | −25.4 | 0.89 | 1.9×10² |
| 1 | −15.3 | 0.68 | 20 |

**Detalle importante:** el NMSE de entrenamiento y el de validación son casi iguales en todos los λ. Con decenas de miles de muestras y solo 36 coeficientes **no hay sobreajuste**; lo que controla λ es la amplificación del ruido por las direcciones casi planas (‖c‖ y condicionamiento), no el sobreajuste clásico. Con menos muestras o más coeficientes (como en EXP032, con ≤ 60 000 filas) la historia podría cambiar; esta simulación no lo prueba.

**Cómo leerlo:**
- **Meseta (λ ≤ 10⁻⁴):** el NMSE no cambia, pero ‖c‖ baja de ≈ 14 a ≈ 1.2. Es decir, mismos resultados con coeficientes mucho más pequeños y estables, que es lo que la regularización compra.
- **A partir de 10⁻³–10⁻²:** empieza a "morder". λ = 10⁻² cuesta ≈ 2.6 dB de NMSE de validación respecto del mejor valor.
- **λ ≥ 10⁻¹:** el modelo se encoge hacia cero y se estropea.

**Qué enseña:** el paper dice que usó 10⁻² "conservadoramente sin barrido completo". En esta simulación 10⁻² ya está en el borde del codo, y valores de 10⁻⁵–10⁻⁴ darían igual precisión con coeficientes estables. Es un candidato claro para un barrido en el trabajo ISCAS (el LEEME de EXP035 ya prevé barrer λ ∈ {0.005, 0.05, 0.5}, aunque en coordenadas normalizadas, no comparables 1 a 1).

## Parte D: un solo disparo (Fig. L03-4)

**Qué hace:** usa el f ajustado como predistorter sobre la señal de validación, sin iterar. Se mezcla con la identidad (`z = (1−µ)u + µ f(u)`, equivale a mezclar coeficientes), se iguala la potencia media a la de u y se limita el pico a `cap × max|u|`. Después compara contra el no-DPD **con la misma potencia de salida**.

**Panel superior izquierdo (dominios):** el modelo se entrenó con `|y_n|` hasta ≈ 0.94, pero ahora se evalúa con `|u|` hasta ≈ 1.48 (~4 dB más). El predistorter nunca "vio" esos picos.

**Panel superior izquierdo, en la corrida real:** los histogramas de `|y_n|` y `|u|` casi se superponen en el cuerpo; solo difiere la cola, donde `|u|` llega a 1.58 y `|y_n|` a 0.95.

**Panel superior derecho (f(a)):** hasta ≈ 0.95 (línea azul vertical) las tres curvas se parecen y suben por encima de la identidad (f(0.95) ≈ 1.3, una expansión de ≈ 2.7 dB, que es justo lo que compensa la compresión). Después de 0.95, zona rosada, los polinomios de orden alto se disparan: M3K5 y M5K6 pasan de 5 antes de a = 1.4, y M1K3 sube más suave.

**Consola (corrida real):** sin DPD y mismo drive, EVM 6.15 %, ACPR −27.21 dBc.

| Caso (µ, límite de pico) | EVM DPD | ACPR DPD | ΔPout | EVM no-DPD, igual potencia | Ganancia real EVM |
|---|---|---|---|---|---|
| M1K3, 0.12, 1.5 | 5.49 | −28.13 | −0.03 | 6.10 | +0.62 pp |
| M3K5, 0.12, 1.5 | 2.19 | −35.02 | −2.54 | 3.18 | +0.99 pp |
| M5K6, 0.12, 1.5 | 2.28 | −33.48 | **−6.43** | 1.36 | **−0.92 pp** |
| M5K6, 0.12, 3.0 | 4.13 | −30.71 | −0.79 | 4.97 | +0.84 pp |
| M5K6, **1.0**, 3.0 | 22.93 | −14.82 | −15.40 | 0.23 | **−22.7 pp** |

**Qué enseña (tres cosas):**
1. **Un disparo de ILA con µ = 1 explota** (EVM 22.9 %). El postdistorter no sabe qué hacer con picos que no vio. Por eso el paper usa µ = 0.12 y **itera**: cada iteración extiende un poco el dominio. Esa es la L04.
2. **La mejora aparente puede ser retroceso de potencia, e incluso engañar al revés.** El M5K6 con µ = 0.12 y límite 1.5 parece bueno (EVM 6.15 → 2.28 %, ACPR −27 → −33.5 dBc), pero la salida bajó 6.4 dB. Un no-DPD con la misma potencia de salida da 1.36 %: el "DPD" queda **peor** que simplemente bajar la potencia. El límite de pico recorta y reescala la señal. Es el problema que el paper señala ("el DPD redujo la potencia promedio más de 2 dB; la referencia a igual potencia es estrictamente necesaria"), y el tema de L06.
3. **Una mejora real pero modesta** (0.6–1.0 pp de EVM) aparece cuando el recorte no domina.
4. Contraste con el paper: allí la mejora de EVM casi no cambia entre "mismo TX gain" (3.82 pp) y "igual potencia" (3.06–3.50 pp), mientras que el ACPR pasa de 4.3 dB a 1.0–1.45 dB. Es decir, su DPD sí ganó EVM de verdad, y lo que se encoge al igualar potencia es sobre todo el ACPR. En este disparo único simulado ocurre lo contrario, porque aún no hay iteraciones.

**Panel inferior izquierdo:** tres barras por caso (no-DPD mismo drive, DPD y no-DPD igual potencia). **La comparación honesta es la tercera barra.** En M5K6 µ = 0.12 límite 1.5 la barra amarilla es más baja que la naranja.

**Panel inferior derecho:** espectros con la misma referencia (0 dB = pico del no-DPD). Los hombros bajan unos 8 dB, pero la meseta principal también baja: la potencia de banda cayó.

## Qué te llevas al laboratorio

| Observas | Interpretación probable | Qué hacer |
|---|---|---|
| Un modelo más grande no baja el NMSE/EVM | Piso de ruido de captura | Estima SNR; promedia capturas; revisa alineación |
| Coeficientes enormes (‖c‖ ≫ 1) con el mismo NMSE | Falta regularización | Sube λ hasta que ‖c‖ se estabilice |
| NMSE de entrenamiento ≪ validación | Sobreajuste o ruido | Más muestras, menos coeficientes, más λ |
| Con µ = 1 el EVM empeora o el espectro explota | Extrapolación fuera del rango entrenado | µ pequeño + iterar |
| DPD "mejora" mucho pero la potencia RX bajó | Retroceso de potencia | Comparar a igual potencia (L06) |
| Pico del DPD ≈ límite de pico | El recorte está dominando | Revisa `maxPeakRatio` y la potencia |

## Referencias para profundizar

- Ding et al., "A robust digital baseband predistorter constructed using memory polynomials", IEEE Trans. Commun., 2004 (ref. [3] del paper).
- Morgan et al., GMP, IEEE Trans. Signal Process., 2006 (ref. [4]); es lo que viene después de MP.
- Gilabert, Braithwaite, Montoro, "Beyond the Moore–Penrose inverse", IEEE Microw. Mag., 2020 (ref. [9]): regularización y estimación.
- Guan & Zhu, IEEE T-MTT, 2012 (ref. [10]): LS de baja complejidad.
