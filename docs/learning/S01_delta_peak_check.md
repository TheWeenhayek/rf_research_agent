# S01: ¿puede un paso λ–δ respetar el límite de pico de TX?

Script: `sim/iscas/S01_delta_peak_check.m`. Salidas en `sim/iscas/out/S01/`.
Se aplica a `DPD v3.1/code/EXP017_GMP_lambda_delta.m` y a EXP033–EXP037 (columnas normalizadas por su RMS, `‖paso‖ ≤ delta`, propuesta no transmitida si `max|tx| > 0.95`).

Los números de abajo vienen de un port numérico (señal OFDM sintética de 61.44 MS/s, pico 0.8; no la señal NR exacta del laboratorio). Compara con tu corrida.

## La idea

`delta` limita la **norma del paso de coeficientes en coordenadas normalizadas**, no el cambio de la forma de onda. El cambio en el dominio del tiempo es

`dz[n] = Σ_j d_j · Xs[n,j]`, con `|dz[n]| ≤ ‖d‖ · ‖Xs[n,:]‖`.

Las columnas de orden alto de la base GMP son muy "picudas" (pico/RMS ≈ 100 o más). Al normalizarlas por su RMS, la norma de fila `‖Xs[n,:]‖` en los picos de la señal es ≈ 200–270. Entonces un `delta = 0.1` puede mover un pico hasta unas 20 unidades, y el límite es 0.95.

## Parte 1: cota de peor caso (no depende del PA)

Depende solo de la forma de onda de TX y de la estructura GMP.

| Estructura | Nc | norma máx. de fila | pico de peor caso con δ = 0.003 / 0.01 / 0.1 | δ seguro (garantizado) |
|---|---|---|---|---|
| F1 | 29 | ≈ 193 | 1.4 / 2.7 / 19.9 | ≈ 0.0008 |
| F2 (orden alto) | 33 | ≈ 266 | 1.6 / 3.4 / 27.1 | ≈ 0.0006 |
| F3 (memoria alta) | 37 | ≈ 194 | 1.4 / 2.7 / 19.9 | ≈ 0.0008 |
| F4 (orden cruzado) | 35 | ≈ 221 | 1.4 / 2.9 / 22.7 | ≈ 0.0007 |

`δ seguro` es el mayor δ que **garantiza** pico ≤ 0.95 para cualquier dirección de paso. Es una cota rigurosa, pero el paso real no es de peor caso.

## Parte 2: el primer paso real contra un PA simulado

El primer paso es **el mismo para cualquier regla de objetivo** (en la iteración 1, `u = x`), así que este resultado no depende de la hipótesis sobre EXP020.

Con la estructura F1, λ = 0.05, identidad inicial (port numérico):

| δ | pico propuesto | veredicto | EVM si se transmitiera |
|---|---|---|---|
| 1×10⁻⁴ | 0.80 | OK | 6.13 % |
| 1×10⁻³ | 0.83 | OK | 6.05 % |
| 3×10⁻³ | 0.91 | OK | 5.82 % |
| 1×10⁻² | 1.31 | **RECHAZO** | 4.82 % |
| 0.1 | 1.51 | **RECHAZO** | 5.07 % |

(Sin DPD el EVM era 6.14 %.)

**Lectura:** en esta simulación el δ = 0.1 de EXP017 produce una propuesta con pico ≈ 1.5, y EXP017 no la transmitiría (`Propuesta restringida no transmitida: pico TX excedido`). Los δ que sí pasan el límite hacen pasos tan pequeños que mejoran muy poco el EVM por iteración.

## Qué comprobar con tu corrida

- Que la Parte 1 dé normas de fila del orden de 200 con tu señal (si son muy distintas, mi razonamiento sobre las columnas picudas no se aplica a tu señal).
- Qué δ de la rejilla pasa el límite en la Parte 2 y cuánto mejora el EVM. Los valores de este PA simulado no son los del hardware: lo que importa es **si δ = 0.1 (o 0.03–0.3 de EXP035) supera 0.95 con una captura real**.
- Chequeo con datos reales sin hardware nuevo: en `data/EXP017_.../processed` los archivos `restricted_model_*_iter_*.mat` guardan `txDPD`, `nextScaled` y `frozenScales`. Si existe alguno, `max(abs(txDPD))` te dice directamente si se rechazó.

## Qué hacer si se confirma

Es decisión del equipo; las opciones razonables son:

1. Usar un δ mucho menor (por debajo de ≈ 10⁻³), a costa de más iteraciones.
2. Poner el radio en una norma que sí limite la forma de onda (por ejemplo, ponderar el paso con los picos de las columnas, o acotar directamente `max|dz|`).
3. Subir el límite de pico, sabiendo que cambia la comparación (más margen de pico implica menos retroceso de potencia, como en L04).

No he modificado ningún script de laboratorio.
