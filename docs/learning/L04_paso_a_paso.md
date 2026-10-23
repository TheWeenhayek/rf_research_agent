# L04 paso a paso: el lazo ILA, la mezcla µ y la selección de iteración

Script: `sim/learn/L04_ILA_loop_blending_and_selection.m`. Salidas en `sim/learn/out/L04/`.
Corresponde a la Ec. 6, la Fig. 4 y la Tabla II del paper, y al lazo de `code/EXP010–EXP020`.

Los números de abajo vienen de un port numérico con otra semilla; sirven de guía, no de resultado. Compara con tu corrida y dime las diferencias.

## El lazo en cinco pasos

1. Se transmite `u_k` (en k = 0, `u_0 = x`, sin DPD).
2. Se captura `y_k` (con ruido) y se normaliza por la ganancia compleja: `y_n = y_k / G`.
3. Se ajusta el postdistorter `u_k ≈ f(y_n)` con LS regularizado (igual que L03).
4. Se mezcla: `c ← (1−µ)·c + µ·ĉ` (µ = 0.12 en el paper).
5. `u_{k+1} = normalizar(MP(x; c))`: se iguala la potencia media a la de x y se limita el pico a `maxPeakRatio × pico(x)`. En EXP010–020 ese límite es **1.10**.

Preparación (consola): el punto de operación sale con EVM sin DPD ≈ 6.1 % y ACPR ≈ −27 dBc (paper: 6.47 % y −26.57 dBc). El ruido del receptor es ahora **absoluto**: fijo en −38 dB respecto a la potencia de salida sin DPD. Así, si el DPD baja la potencia, la SNR también baja, como en el laboratorio.

## Parte A: anatomía de una corrida (Fig. L04-1)

M3K5, µ = 0.12, 10 iteraciones.

- **Panel 1 (EVM y ACPR por iteración):** la iteración 0 es el sistema sin DPD. Se espera una caída fuerte en la primera actualización (EVM ≈ 6.1 → ≈ 1.9 %, ACPR ≈ −27 → ≈ −34 dBc) y luego una mejora lenta (EVM ≈ 1.3 % y ACPR ≈ −34.7 dBc en la iteración 10).
- **Panel 2:** la potencia de salida cae ≈ 3.6 dB **en la primera actualización** y luego se mantiene. Es el efecto de igualar la potencia media y recortar el pico. El tamaño de cada actualización (‖c_nuevo − c‖) se reduce geométricamente.
- **Panel 3 (AM/AM de toda la cadena):** sin DPD la nube se dobla; con DPD se acerca a la recta ideal. Es lo mismo que la Fig. 3(a) del paper.
- **Panel 4:** espectros con la misma referencia (0 dB = pico del no-DPD). Los hombros bajan unos 7 dB; la meseta principal también baja un poco.

**Laboratorio:** la primera iteración hace casi todo el trabajo. Si tras la iteración 1 no ves mejora clara de EVM, revisa alineación y SNR antes de tocar el modelo.

## Parte B: efecto de µ (Fig. L04-2)

Mismo modelo, µ ∈ {1, 0.5, 0.25, 0.12, 0.06, 0.03}.

| µ | Comportamiento esperado (EVM iteraciones 1 → 10) |
|---|---|
| 1 | Explota: 17.6 → miles de % |
| 0.5 | Sube lentamente (8.5 → ≈ 100) |
| 0.25 | Mejora tras unas iteraciones (3.6 → 1.3) |
| **0.12** | **Mejora suave y monótona (1.9 → 1.3)** |
| 0.06 | Más lento (3.4 → 1.7) |
| 0.03 | Muy lento (5.1 → 2.1) |

**Qué enseña:** hay una ventana de µ. Con µ grande, el modelo se aplica sin haber "visto" los picos expandidos (el problema de dominio de L03) y diverge. Con µ pequeño es estable pero necesita muchas iteraciones, y cada iteración en hardware cuesta tiempo. µ = 0.12 es un buen compromiso en esta simulación, aunque no demuestra que sea el óptimo en el laboratorio.

## Parte C: tres modelos y la regla de selección (Fig. L04-3)

Equivalente a la Fig. 4 y la Tabla II del paper. La estrella marca la iteración retenida por la regla: **entre las iteraciones cuyo ACPR está a ≤ 0.1 dB del mejor ACPR, se elige la de menor EVM** (paper, Sec. III-C).

Resultados esperados (10 iteraciones, µ = 0.12, límite 1.10):

| Modelo | Iteración elegida | EVM | ACPR | EVM no-DPD a igual potencia | Ganancia real |
|---|---|---|---|---|---|
| M1K3 | ≈ 10 | ≈ 1.3 % | ≈ −34.8 dBc | ≈ 3.3 % | ≈ +2.0 pp / 3.5 dB |
| M3K5 | ≈ 10 | ≈ 1.3 % | ≈ −34.7 dBc | ≈ 2.6 % | ≈ +1.3 pp / 2.3 dB |
| M5K6 | **1** | ≈ 2.6 % | ≈ −30.8 dBc | ≈ 1.9 % | **≈ −0.6 pp** |

- **M1K3** es la que más mejora, de forma lenta y monótona.
- **M5K6 degrada** tras la primera iteración (EVM 2.6 → 4.6 %). Es cualitativamente lo que el paper describe: "varios modelos alcanzaron el mínimo EVM en las primeras actualizaciones y luego empeoraron". En el paper M1K3 se retuvo en la iteración 1; M3K5 y M5K6 en la 4. Aquí los modelos pequeños mejoran hasta la última iteración, así que **la sim no reproduce la misma forma para todos los modelos**.
- La barra de la derecha (**ganancia a igual potencia**) es la comparación honesta. Con el límite de pico 1.10 la potencia de salida baja 2.5–6.7 dB, y para M5K6 un simple retroceso de potencia ya da mejor EVM que el DPD.

## Parte D: ¿cuándo se degrada? (Fig. L04-4)

M5K6, 10 iteraciones, variando µ y el límite de pico.

| µ, límite | EVM (it. 1 → 10) | Potencia |
|---|---|---|
| 0.12, 1.10 | 2.8 → ≈ 5 (**degrada**) | −7 dB |
| 0.06, 1.10 | 2.1 → 1.7 (mejora) | −4 dB |
| 0.12, 1.50 | 1.9 → 1.4 (mejora) | −3 dB |
| 0.12, 3.00 | 2.6 → 1.5 (mejora) | −3 dB |

**Qué enseña:** en la simulación la degradación aparece cuando se juntan un modelo grande, un µ no pequeño y un **límite de pico que está activo**. El límite actúa como un recortador duro dentro del lazo, que el polinomio no puede invertir, y el lazo "persigue" ese error. Con µ más pequeño o con más margen de pico desaparece. Es una **hipótesis consistente con el paper** (que menciona paso adaptativo y parada por validación como trabajo futuro, y el LEEME de EXP034 propone un paso acotado), pero no está demostrada en hardware.

**Laboratorio:** si un modelo degrada tras la iteración 1, mira en tus CSV de EXP010–020 si `PeakRatio_DPD_to_Original` está pegado al límite (1.10) y si `RxPower_Delta_dB` cae más de ~2 dB.

## Parte E: el lazo de EXP020 contra el del paper (Fig. L04-5)

**Hallazgo al leer `code/EXP020`** (verifiqué que la misma regla está en EXP010 v2/v3 y EXP015–017; EXP012 y EXP018 no entrenan):

- El **objetivo** del ajuste es la forma de onda original `txWaveform`, no la señal realmente transmitida `u_k`. El regresor es el RX normalizado a esa forma de onda.
- En la **iteración 1** los coeficientes se reemplazan (`coeffCurrent = coeffHat`, sin mezcla). La mezcla con µ empieza en la iteración 2.
- Es una regla distinta a la Ec. 6 del paper y a un ILA clásico. El LEEME de EXP031–037 dice que corrigieron justo esto ("el objetivo del postinverso es esa entrada emitida").

**Contexto:** EXP001–EXP020 son el trabajo presentado en LAMC (EXP020 es el último). Los scripts para ISCAS son EXP031–EXP037 y los que vengan después, así que esta diferencia es **historia entre dos generaciones de código**, no un error que haya que corregir en LAMC. Importa porque define qué se puede afirmar en ISCAS sobre la mejora respecto de LAMC.

**Por qué importa (razonamiento, no medición):** al iterar, el cascada DPD+PA se parece cada vez más a la identidad, así que el ĉ de las iteraciones siguientes se parece a la identidad, y la mezcla con µ = 0.12 arrastra los coeficientes de vuelta hacia ella. El punto fijo es una corrección *parcial*, no la inversa del PA. Eso podría explicar que muchos modelos tengan su mejor EVM en las primeras iteraciones y luego degraden.

**Qué muestra la simulación (M3K5, 6 iteraciones, límite 1.10):**

| PA | Lazo clásico | Regla EXP020 |
|---|---|---|
| p = 1 (saturación suave) | EVM 3.5 → 2.0, mejora lenta | **mejor en la iteración 1 (≈ 0.7 %) y luego sube hasta ≈ 1.6 %** |
| p = 2 (saturación abrupta, la del paper) | 6.1 → 1.7 → 1.3 | explota en la iteración 1 (EVM ≈ 18 %, potencia −16 dB) |

- Con el PA suave, la regla de EXP020 reproduce justo el patrón "mínimo en las primeras actualizaciones y luego degrada".
- Con el PA abrupto (el que mejor reproduce el EVM de 6.47 % del paper) explotaría en la iteración 1, y eso **no** pasó en el laboratorio, donde esa iteración funcionó. Por lo tanto el PA simulado no es el del laboratorio, y esta parte no confirma nada sobre el hardware.

**Cómo comprobarlo con datos reales (sin hardware nuevo):** en los CSV de coeficientes de EXP010–020, mira para un modelo `‖c‖` y `‖c_i − c_{i−1}‖` por iteración. La regla de EXP020 predice que `c` cambia mucho de la iteración 1 a la 2 y que después los cambios decaen geométricamente (≈ ×0.88 por iteración); un ILA clásico predice cambios mucho más pequeños y regulares desde el principio. Si coincide con la regla de EXP020, tendría un argumento sólido para el ISCAS: la comparación entre mezcla fija y paso acotado debe hacerse con el objetivo corregido (como en EXP031–037) para no mezclar efectos.

## Resumen de diagnóstico

| Observas | Probable causa | Qué hacer |
|---|---|---|
| El EVM sube con cada iteración desde el principio | µ demasiado grande | Reducir µ (0.12 → 0.06) |
| La mejora es muy lenta | µ pequeño | Más iteraciones o µ algo mayor |
| Mejor iteración = 1 y luego empeora | Límite de pico activo, regla de actualización, ruido | Revisa `PeakRatio` y `RxPower_Delta_dB`; compara con el lazo corregido |
| `RxPower_Delta_dB` baja > 2 dB | Igualación de potencia + límite de pico | Comparar siempre a igual potencia |
| Modelo grande peor que el pequeño | Limitado por ruido, o degradación en el lazo | Mirar L03 (SNR) y la Parte D |

## Referencias

- Paper RF_DPD_v4, Ec. 6 y Sec. III-C (selección de iteración).
- `docs/GMP_EXP031_037_LEEME.md`, secciones 4 (EXP033/EXP034) y 5, para la formulación corregida con mezcla fija y paso restringido.
