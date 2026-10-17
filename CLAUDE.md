# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A research workspace (not a software package) for digital predistortion (DPD) of a custom 5 GHz RF chain: ADALM-Pluto SDR → IF board → ADMV1018 up/downconverter (LO from LMX2595) → PA → back through the downconverter into the Pluto RX. There is no build system, test suite, or linter. Each experiment is a standalone MATLAB script that drives real hardware. Scripts cannot be run here without the lab setup (Pluto, STM32 power meter on a serial port, Windows with ADI ACE).

## Layout

- `code/` — one script per experiment, named `EXP<NNN>[letter]_<Description>_v<N>.m`. Versions are kept side by side rather than overwritten, and the highest version number is not always the final one. Don't delete or rename any of them. Final versions confirmed by the author for the characterization experiments: `EXP002_..._v3_LongBaseline`, `EXP003_..._v3_ATT20`, `EXP004_Downconverter_RFIn_Compression_Check_v3` (the v4/v5 variants are not final) and `EXP006_FullChain_TXRXSweep_EVM_ACPR_NMSE_v2`. For other experiments, ask which version is final.
- `code/control_ace.py` — Python (pythonnet / `clr`) CLI that talks to the ADI ACE client on `localhost:2357` and writes ADMV1018 DSA registers. Called from MATLAB via `system(...)` with `--target txboth --atten1 N --atten2 N` (0–15 each; also RX attenuator targets). Paths are Windows-specific (`C:\Program Files (x86)\Analog Devices\ACE\Client`).
- `baseline/` — CSVs of measured power/gain-compression baselines for each hardware block (IF board, upconverter, downconverter, Pluto TX). Experiments read these to convert meter readings to corrected output power and gain compression.
- `inform/` — LaTeX report (and build artifacts) for EXP001. `paper/RF_DPD_v4.pdf` — the accepted paper (untracked). `code/` and `baseline/` hold the experiments behind it.
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
