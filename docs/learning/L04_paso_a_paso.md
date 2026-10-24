# L04 paso a paso: el lazo ILA, la mezcla µ y la selección de iteración

Script: `sim/learn/L04_ILA_loop_blending_and_selection.m`. Salidas en `sim/learn/out/L04/`.
Corresponde a la Ec. 6, la Fig. 4 y la Tabla II del paper, y al lazo de `code/EXP010–EXP020`.

Los números de las Partes A–D son de la corrida real en MATLAB Online (2026-10-23). Los del diseño 2×2 de la Parte E vienen de un port numérico con otra semilla, pendientes de confirmar con una nueva corrida del script.

## El lazo en cinco pasos

1. Se transmite `u_k` (en k = 0, `u_0 = x`, sin DPD).
2. Se captura `y_k` (con ruido) y se normaliza por la ganancia compleja: `y_n = y_k / G`.
3. Se ajusta el postdistorter `u_k ≈ f(y_n)` con LS regularizado (igual que L03).
4. Se mezcla: `c ← (1−µ)·c + µ·ĉ` (µ = 0.12 en el paper).
5. `u_{k+1} = normalizar(MP(x; c))`: se iguala la potencia media a la de x y se limita el pico a `maxPeakRatio × pico(x)`. En EXP010–020 ese límite es **1.10**.

Preparación (consola): el punto de operación sale con EVM sin DPD ≈ 6.1 % y ACPR ≈ −27 dBc (paper: 6.47 % y −26.57 dBc). El ruido del receptor es ahora **absoluto**: fijo en −38 dB respecto a la potencia de salida sin DPD. Así, si el DPD baja la potencia, la SNR también baja, como en el laboratorio.

## Parte A: anatomía de una corrida (Fig. L04-1)

M3K5, µ = 0.12, 10 iteraciones. **Corrida real en MATLAB Online (2026-10-23):**

| Iteración | EVM (%) | ACPR (dBc) | ΔPout (dB) | ‖c‖ | ‖Δc‖ |
|---|---|---|---|---|---|
| 0 (sin DPD) | 6.08 | −27.02 | 0 | 1.000 | 0.045 |
| 1 | 2.14 | −33.33 | −2.85 | 0.997 | 0.040 |
| 5 | 1.55 | −34.12 | −3.38 | 0.870 | 0.028 |
| 10 | 1.28 | −34.37 | −3.48 | 0.770 | — |

- **Panel 1:** casi toda la mejora llega en la primera actualización (6.1 → 2.1 %); después se afina lentamente.
- **Panel 2:** la potencia de salida cae 2.85 dB **en la primera actualización** y se estabiliza en ≈ −3.5 dB. El tamaño de cada actualización (‖Δc‖) decrece de forma casi lineal en escala log.
- **Panel 3 (AM/AM de toda la cadena):** sin DPD la nube se dobla por debajo de la recta a amplitud alta (|x| > 0.7); con DPD sigue la recta ideal hasta el máximo.
- **Panel 4:** los hombros espectrales desaparecen. La meseta fuera de banda queda a ≈ −44 dB, que es el **piso de ruido** de la captura. El ACPR con DPD (≈ −34.4 dBc) está limitado por ese piso, no por el PA: sumar dos canales adyacentes de ruido blanco da ≈ −38 + 3 dB.
- **‖c‖** baja de 1.0 a 0.77 de forma monótona: la regularización encoge los coeficientes poco a poco.

**Laboratorio:**
- La primera iteración hace casi todo el trabajo. Si tras ella no ves mejora clara de EVM, revisa alineación y SNR antes de tocar el modelo.
- Si el ACPR con DPD se aplana, compara con el piso de ruido de tu espectro antes de culpar al modelo. En el simulador ese piso explica por completo el límite.

## Parte B: efecto de µ (Fig. L04-2)

M3K5, µ ∈ {1, 0.5, 0.25, 0.12, 0.06, 0.03}. **Corrida real, EVM en las iteraciones 1 / 5 / 10:**

| µ | 1 | 5 | 10 |
|---|---|---|---|
| 1 | 16.5 | >99 | >99 |
| 0.5 | 7.6 | 10.4 | 44.5 (sube) |
| 0.25 | 2.9 | 1.5 | 1.18 |
| **0.12** | **2.2** | **1.55** | **1.28** |
| 0.06 | 4.0 | 2.1 | 1.6 |
| 0.03 | 5.4 | 2.9 | 2.2 |

**Qué enseña:** hay una ventana de µ. Con µ grande el modelo se aplica sin haber "visto" los picos expandidos (el problema de dominio de L03) y diverge. Con µ pequeño es estable pero necesita muchas iteraciones, y cada iteración en hardware cuesta tiempo. En esta simulación µ = 0.25 y 0.12 terminan igual (≈ 1.2 %). El de 0.25 llega antes, pero es el vecino inmediato de la zona que diverge (0.5), así que µ = 0.12 deja más margen. Es una simulación: no demuestra el óptimo del laboratorio.

## Parte C: tres modelos y la regla de selección (Fig. L04-3)

Equivalente a la Fig. 4 y la Tabla II del paper. La estrella marca la iteración retenida: **entre las iteraciones cuyo ACPR está a ≤ 0.1 dB del mejor ACPR, la de menor EVM** (paper, Sec. III-C).

**Corrida real (10 iteraciones, µ = 0.12, límite de pico 1.10):**

| Modelo | Iteración elegida | EVM | ACPR | EVM no-DPD a igual potencia | Ganancia real |
|---|---|---|---|---|---|
| M1K3 | 10 | 1.31 % | −34.4 dBc | 3.33 % | **+2.02 pp / +3.4 dB** |
| M3K5 | 10 | 1.28 % | −34.4 dBc | 2.69 % | +1.42 pp / +2.3 dB |
| M5K6 | 10 | 1.47 % | −33.8 dBc | 2.60 % | +1.12 pp / +1.6 dB |

- Los tres terminan en un EVM de 1.3–1.5 %, **cerca del piso de ruido** de la simulación (SNR 38 dB ⇒ ≈ 1.26 %). Las diferencias están en la velocidad y en cuánta potencia se pierde.
- **M1K3 converge lento** (EVM 5.0 % tras la 1ª iteración) pero pierde poco (−2.4 dB); M5K6 cae enseguida (−5 dB en la 1ª) y luego recupera hasta −3.7 dB.
- **A igual potencia, el modelo pequeño gana más (+2.0 pp contra +1.1 pp).** Es coherente con la conclusión del paper (M1K3 como implementación preferida), aunque los números no son comparables con los suyos.
- Como todos mejoran hasta la última iteración, **la regla de selección elige siempre la 10**. En el paper (6 iteraciones) la regla sí eligió iteraciones intermedias para M3K5 y M5K6; esta simulación **no reproduce ese comportamiento**.

## Parte D: M5K6, µ y límite de pico (Fig. L04-4)

M5K6, 10 iteraciones. **Corrida real:**

| µ, límite de pico | EVM it. 1 → it. 10 | Potencia |
|---|---|---|
| 0.12, 1.10 | 2.10 → 1.49 | −3.7 dB |
| 0.06, 1.10 | 2.67 → 1.63 | −3.6 dB |
| 0.12, 1.50 | 2.31 → 1.31 | −3.3 dB |
| 0.12, 3.00 | **5.27** → 1.35 | −2.7 dB |

**Corrección importante:** en mi primer port numérico M5K6 con µ = 0.12 y límite 1.10 *degradaba* tras la iteración 1 (2.6 → 4.6 %). **En MATLAB no se reproduce**: todas las curvas mejoran de forma monótona. Esa degradación dependía de la semilla del ruido; no es un resultado de la simulación y no debe citarse. Lo que sí se ve de forma consistente:

- Sin límite de pico efectivo (3.00), la **primera** iteración es mala (5.3 %, casi no mejora): el modelo extrapola con picos que no vio. **El límite de pico actúa como protección**, a costa de bajar la potencia.
- ‖c‖ baja monótonamente en todos los casos (0.69–0.85 tras 10 iteraciones); con el límite 1.10 y µ = 0.12 baja más rápido.

## Parte E: el lazo de EXP020 contra el del paper (Fig. L04-5)

**Hallazgo al leer `code/EXP020`** (verifiqué que la misma regla está en EXP010 v2/v3 y EXP015–017; EXP012 y EXP018 no entrenan). El ajuste difiere del texto del paper (Ec. 6) en **dos cosas a la vez**:

1. **Objetivo:** la forma de onda *original* `txWaveform`, no la señal realmente transmitida.
2. **Primera iteración:** reemplaza los coeficientes (`coeffCurrent = coeffHat`); la mezcla con µ empieza en la iteración 2.

El LEEME de EXP031–037 dice que corrigieron justo el objetivo ("el objetivo del postinverso es esa entrada emitida").

**Contexto:** EXP001–EXP020 son el trabajo de LAMC; los scripts para ISCAS son DPD v3.1 y EXP031–037. Esta diferencia es **historia entre dos generaciones de código**, no un error que haya que corregir en LAMC. Importa porque define qué se puede afirmar en ISCAS sobre la mejora respecto de LAMC.

**Por qué importa (razonamiento, no medición):** al iterar, la cascada DPD+PA se parece cada vez más a la identidad, así que el ĉ de las iteraciones siguientes se parece a la identidad, y la mezcla arrastra los coeficientes de vuelta hacia ella. El punto fijo sería una corrección *parcial*, no la inversa del PA.

**Resultado de la corrida real (primer diseño, con los dos factores juntos), M3K5, 6 iteraciones:**

| PA | Lazo clásico | Regla EXP020 |
|---|---|---|
| p = 2 (el que reproduce el EVM de 6.47 %) | 6.07 → 2.19 → … → 1.47 | explota en la iteración 1: EVM ≈ 17 %, potencia −13.9 dB |
| p = 1 (saturación suave) | 3.44 → 3.15 → … → 1.98 | **mejor en la iteración 1 (0.83 %), luego sube a 1.63 %** |

- Con el PA suave, la regla de EXP020 muestra el patrón "mínimo en las primeras actualizaciones y luego degrada" que el paper describe.
- Con el PA abrupto explotaría en la iteración 1, y eso **no** pasó en el laboratorio. Por eso el PA simulado no es el del laboratorio y esto **no confirma nada sobre el hardware**.

**Limitación que descubrí al revisarlo:** esa comparación mezclaba los dos factores, así que no decía cuál causa qué. El script ahora corre un **diseño 2×2** (objetivo emitido u original, por primera iteración reemplazada o mezclada). En el port numérico (otra semilla; la corrida en MATLAB debe confirmarlo) salió:

| EVM (%) tras 10 iteraciones | 1ª iteración mezclada | 1ª iteración reemplaza |
|---|---|---|
| PA suave (p = 1), objetivo emitido | 1.43 (lento) | **0.90** (rápido y estable) |
| PA suave (p = 1), objetivo original | 2.12 (se estanca) | 1.88 (sube desde 0.83) |
| PA abrupto (p = 2), objetivo emitido | 1.32 | explota (18 %) |
| PA abrupto (p = 2), objetivo original | 2.01 (sube tras la it. 2) | explota (18 %) |

Lectura: **los dos factores importan.** El reemplazo completo en la iteración 1 da el salto rápido (pero puede explotar con un PA abrupto). El objetivo original produce el deterioro posterior y un EVM final peor en todos los casos donde el lazo no explota. Si la corrida real de MATLAB lo confirma, un diseño con objetivo emitido y primera actualización completa sería el más rápido y estable en el PA suave.

**Cómo comprobarlo con datos reales (sin hardware nuevo):** en los CSV de coeficientes de EXP010–020 mira para un modelo `‖c‖` y `‖c_i − c_{i−1}‖` por iteración. La regla de EXP020 predice un cambio grande entre las iteraciones 1 y 2, y luego cambios que decaen geométricamente (≈ ×0.88 por iteración).

## Resumen de diagnóstico

| Observas | Probable causa | Qué hacer |
|---|---|---|
| El EVM sube con cada iteración desde el principio | µ demasiado grande | Reducir µ (0.12 → 0.06) |
| La mejora es muy lenta | µ pequeño | Más iteraciones o µ algo mayor |
| Mejor iteración = 1 y luego empeora | Objetivo de ajuste original en vez de la señal emitida (ver Parte E); también ruido | Revisa `‖c‖` y `‖Δc‖` por iteración; compara con el lazo corregido |
| `RxPower_Delta_dB` baja > 2 dB | Igualación de potencia + límite de pico | Comparar siempre a igual potencia |
| Modelo grande peor que el pequeño | Limitado por ruido, o más retroceso de potencia | Mirar L03 (SNR) y comparar a igual potencia |

## Referencias

- Paper RF_DPD_v4, Ec. 6 y Sec. III-C (selección de iteración).
- `docs/GMP_EXP031_037_LEEME.md`, secciones 4 (EXP033/EXP034) y 5, para la formulación corregida con mezcla fija y paso restringido.
