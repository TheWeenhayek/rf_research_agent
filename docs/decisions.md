# Decisions log

Newest first. Each entry: date, decision, why.

## 2026-10-23: Tutorial scripts export their outputs to the repo

- **Decision:** Each `sim/learn/L0N_*.m` saves `console.txt`, `figures/*.png` and CSV tables under `sim/learn/out/L0N/`, and the folder is committed.
- **Why:** The scripts run in MATLAB Online, which Claude Code cannot see. Pushing the outputs lets Claude review the plots and numbers.
- **How to apply:** New modules copy the output block of L01 (setup after `rng`, `saveAllFigures` helper at the end). Keep PNGs at about 130 dpi and do not save raw waveforms.

## 2026-10-17: Offline testing runs on MATLAB Online, not locally

- **Decision:** Offline/simulation work is written as plain MATLAB scripts and functions in new folders (`sim/`, later `lib/`), never by editing the accepted-paper scripts in `code/`. The user runs them in MATLAB Online.
- **Why:** There is no Pluto, STM32 meter or ACE available, and Claude Code cannot execute MATLAB Online itself.
- **How to apply:**
  - Keep sim code free of `sdrtx`, `sdrrx`, `serialport` and `system(...)`, and use as few toolboxes as possible.
  - Claude writes the files and the user uploads or syncs them (MATLAB Drive or git), runs them, and pastes back the output for review.
  - Offline scope: DPD math (MP/GMP, LS fit, blending, ILA loop) against a simulated PA, alignment/sync with injected delay/gain/phase, and metrics (EVM, ACPR, NMSE) checked against `baseline/` CSVs.
  - Out of scope: real captures, DSA settings, STM32 protocol, ACE register writes.
