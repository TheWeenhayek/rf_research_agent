# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A research workspace (not a software package) for digital predistortion (DPD) of a custom 26 GHz heterodyne chain built on a sub-6 GHz SDR at a 5 GHz IF: ADALM-Pluto SDR (5 GHz) → IF board (2× BGU amplifiers + 3 dB pad) → ADMV1018 upconverter (LO from LMX2595, doubled internally; ~10.5 GHz LO → 26 GHz) → 26 GHz bandpass filter (~3 dB loss) → RF loopback attenuator → ADMV1018 reconfigured as downconverter → back to 5 GHz IF into the Pluto RX. An STM32 + LTC5596 RMS detector gives an independent relative-power reading. The nonlinear device is the integrated upconverter, not a discrete PA. There is no build system, test suite, or linter. Each experiment in `code/` is a standalone MATLAB script that drives real hardware and cannot run without the lab setup (Pluto, STM32 power meter on a serial port, Windows with ADI ACE). Offline work lives in `sim/` and is run by the user in MATLAB Online (see `docs/decisions.md`).

The user (Carlos Mendieta) is a co-author of the three papers below. The team is at UMSA / UPB (La Paz, Bolivia). The next goal is a new paper for ISCAS built on the GMP phase (EXP031–037) and later experiments.

## Papers (`paper/`)

All three are published and are the context for the research line. Only `RF_DPD_v4.pdf` is the baseline the code is organized around.

- `RF_DPD_v4.pdf` — **the baseline**: "Stage-Localized Linearization and Equal-Power DPD Evaluation of a 26 GHz Heterodyne Transmitter". MP-DPD (M1K3 / M3K5 / M5K6, 6–36 coefficients), regularized iterative indirect learning (λ=1e-2 relative, blend µ=0.12, six iterations), operating point GTX = −22.25 dB with 5 dB TX DSA (~0.5 dB upconverter compression), equal-power comparison against an independent no-DPD sweep (interpolating EVM/ACPR at equal RX power or detector power), 20 paired runs. Headline: EVM 6.47→2.65 %, ACPR −26.57→−30.88 dBc, NMSE −14.77→−24.05 dB; detector-equal-power mean gain 3.24 pp EVM / 1.36 dB ACPR. Its future work (GMP, validation-based stopping, adaptive step, retraining near P1dB) is what EXP031–037 pursue.
- `m39123-lagrava final.pdf` — testbed and metrology: "Characterization of Millimeter-Wave RF Components Using a Low-Cost SDR Platform". Defines the IF-loopback platform, the RMS detector calibration (28.82 mV/dB, R²=0.9997, STM32 reads it), passive insertion loss over 22–30 GHz, the 2-D TX/RX-gain EVM map (min EVM 1.27 % at TX −25 dB / RX 18 dB), and AM/AM–AM/PM from raw I/Q (modified 5G Toolbox demod that skips equalization/CPE). Explains why the baselines and EXP001–006 exist.
- `m39195-moncada final.pdf` — control: "Minimum EVM Power Regulation of a Low-Cost 26 GHz SDR mmWave Chain". EVM map (min ~1.2 % at −29.25 dBm / RX 16 dB) mapped to a detector voltage (Vref 0.55 V), plant identified as 2nd-order dominated by the detector output filter (τ1≈0.273 ms, τ2≈0.092 ms), deadband PI on the IF-stage PE43711 DSA running on an STM32L4R5. Not about DPD; it is the source of the STM32 detector behavior and the DSA actuator.

Chain of reuse: the Lagrava testbed and detector calibration → stage-wise baselines (EXP002–004, EXP006) → operating-point selection → the DPD paper.

## Stage-wise baselines (the preliminary scripts of the DPD paper)

These four are the final versions and produce Fig. 2 / Table I of the DPD paper. Each one writes a CSV that is copied by hand into `baseline/` and consumed by the next one:

`Baseline_Power_Tx_Pluto.csv` (spectrum-analyzer TxGain→dBm, manual) → EXP002 (IF board gain/compression, 6 dB detector pad, +6 dB correction) → `Baseline_Power_IF_Board.csv` → EXP003 (upconverter RF_OUT, 20 dB protection pad + filter/cable losses, `UpconverterGain = RFOutPin − UpconverterInput`) → `Baseline_Power_Upconverter_RFOUT*.csv` → EXP004 (RF_OUT→RF_IN loopback, downconverter compression, `RFIn = RFOutAfterFilter − rfLoopbackAttenuator_dB`) → `Baseline_*Downconverter*.csv`. EXP006 reads `Baseline_Power_Upconverter_RFOUT.csv` to estimate RF_IN power and sweeps TX gain × RX gain measuring EVM/ACPR/NMSE.

Compression is always `C = G_small_signal − G_i`, with G_ss taken from the first reliable low-power points (above the detector floor). Per-script notes: `docs/scripts/`. Do not trust the filenames in `baseline/` alone: there are `_old`, `_TXDSA5`, `_TXDSA7`, `_2` and `(2)` variants and the provenance of the one used in the paper is an open question.

## Layout

- `code/` — one script per experiment, named `EXP<NNN>[letter]_<Description>_v<N>.m`. Versions are kept side by side rather than overwritten, and the highest version number is not always the final one. Don't delete or rename any of them. Final versions confirmed by the author for the characterization experiments: `EXP002_..._v3_LongBaseline`, `EXP003_..._v3_ATT20`, `EXP004_Downconverter_RFIn_Compression_Check_v3` (the v4/v5 variants are not final) and `EXP006_FullChain_TXRXSweep_EVM_ACPR_NMSE_v2`. For other experiments, ask which version is final.
- `code/control_ace.py` — Python (pythonnet / `clr`) CLI that talks to the ADI ACE client on `localhost:2357` and writes ADMV1018 DSA registers. Called from MATLAB via `system(...)` with `--target txboth --atten1 N --atten2 N` (0–15 each; also RX attenuator targets). Paths are Windows-specific (`C:\Program Files (x86)\Analog Devices\ACE\Client`).
- `baseline/` — CSVs of measured power/gain-compression baselines for each hardware block (IF board, upconverter, downconverter, Pluto TX). Experiments read these to convert meter readings to corrected output power and gain compression.
- `inform/` — LaTeX report (and build artifacts) for EXP001.
- `paper/` — the three published papers (see above). `RF_DPD_v4.pdf` is tracked; the two `m*` PDFs are untracked.
- `docs/` — `decisions.md` (decision log, newest first), `GMP_EXP031_037_LEEME.md` (delivery notes for the GMP phase, in Spanish), `scripts/EXPNNN.md` (per-experiment notes, so far only EXP002).
- `sim/` — offline MATLAB scripts for MATLAB Online, no hardware or toolboxes beyond Signal Processing (`pwelch`). `sim_ila_mp_basic.m` (ILA with MP against a simulated Rapp PA; helpers copied from EXP020) and `replay_exp002_compression.m` (re-runs EXP002's analysis from its raw CSV). `sim/learn/L0N_*.m` is a numbered tutorial series that follows the DPD paper (L01 compression/EVM/ACPR; L02 stage-wise baselines with detector model + TX×RX EVM map; planned: L03 MP basis + regularized LS, L04 ILA loop and blending µ, L05 model size M1K3/M3K5/M5K6, L06 equal-power evaluation, L07 alignment, then GMP). Every `L0N` script writes `sim/learn/out/L0N/` (`console.txt` via `diary`, `figures/*.png`, CSVs) and is meant to be committed and pushed from MATLAB Online so the outputs can be reviewed here; the folder is not gitignored, and each run overwrites the previous PNGs. Never edit `code/` for simulation purposes; copy helpers into `sim/` and note the source.
- `data/` — gitignored output root; it does not exist in the checkout. Experiments create `data/<experiment>/<runTag>/{raw,processed,figures}`.

## Experiment progression

- EXP001–006: hardware characterization (LO power, IF chain compression, TX-only upconverter, downconverter RF-in compression, RX DSA safe sweep, full-chain EVM/ACPR/NMSE).
- EXP007–008: capture synchronization/alignment diagnostics (coarse decimated search + fine search + complex gain normalization, no external CFO correction).
- EXP009: the "official" no-DPD reference sweep. It produces `*OFFICIAL_NODPD_REFERENCE*.csv`, which later DPD experiments locate via `findLatestOfficialNoDPDReference` (recursive glob under `data/`) and compare against.
- EXP010–020: iterative ILA/HILA DPD training with memory polynomial (MP) and GMP models, at an operating point ~0.5 dB into compression of the upconverter. Covers model-size sweeps, reproducibility/restart, generalization to new 5G waveforms, and MP vs GMP fair comparison.
- EXP031–EXP037: GMP phase (mixed-blend vs bounded-step update), received as a delivery from collaborators. The seven files are the same program differing only in `C.exp`/`C.stage`, so a common change must be applied to all seven. They must run in order and pass results through `data/GMP_EXP031_037/ultima_*.mat`. Full description in `docs/GMP_EXP031_037_LEEME.md`; `C.txGain`/`C.rxGain`/`C.txDSA_dB` at the top of each file are inherited EXP010 values and must be set to the real lab point.
- EXP103*: upconverter RF-out sweeps with ACE-controlled DSAs.

## Conventions shared across scripts

- Each script is self-contained and long (1.7–2.2k lines): a "configuration" block at the top, then capture/align/fit loops, then CSV/figure export, with local helper functions at the bottom of the file. Shared helpers are copy-pasted between versions rather than factored into a common library, so a fix to alignment or metrics logic usually has to be applied to every script that still matters.
- `projectDir = fileparts(scriptDir)`, so scripts must stay in `code/` and write to `<repo>/data`.
- Hardware config is hard-coded near the top: Pluto (`sdrtx`/`sdrrx`, 5 GHz center), STM32 meter on `serialPort = "COM12"` at baud 209700 (command protocol: `MEAS,<txGain>,<nSamples>`), and the Python/ACE script path. Change these for a different machine.
- TX DSA setting is physical, not software: `fixedDsaSteps_Metadata` is only recorded in outputs and must match what was actually set through ACE (0.5 dB per step).
- DPD training is iterative: capture → robust align (retry up to `maxCaptureAttempts`, gated on `evmRetryThreshold_pct` and `minSyncMetric`) → LS fit with relative regularization → blend coefficients with `coeffBlendMu` → repeat; the best iteration per model is exported (metrics, coefficients, AM/AM, AM/PM, PSD, IQ CSVs for notebooks).
- Comments and some variable names are mixed English/Spanish.

## Known inconsistencies to resolve before the ISCAS paper

- Loopback attenuator: the paper says 30 dB; EXP004 v3 uses 23 dB, EXP006 v2 uses 20 dB, and the baseline CSV is named `RXDSA15` with 20 dB. Confirm which value was physical in the DPD runs.
- Part numbers: papers and code say ADMV1018, the Lagrava paper cites the ADMV1017 datasheet; the LO is LMX2595 in the code but the papers cite LMX2594. Confirm before citing.
- Operating points differ by paper (DPD: TX −22.25 dB / RX 8 dB / TX DSA 5 dB; Lagrava: −25 / 18; Moncada: −29.25 dBm / 16). They are different campaigns, not errors.
- `Baseline_Power_IF_Board.csv` (77 points) vs the 2026-10-16 EXP002 run (51 points): which was used in the paper is unknown (see `docs/scripts/EXP002.md`).
- Sample rate: EXP010-era scripts vs 61.44 MS/s fixed in EXP031–037; GMP memory lags are not comparable across the two.
- Several scripts hard-code `addpath("C:\Users\jpfer\...")` for the 5G Toolbox example (`hNRDownlinkEVM` etc.).
