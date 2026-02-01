# CoreSpiceCLI

Command-line front end for CoreSpice. Supports batch execution against a SPICE deck and an interactive REPL-style shell.

## Build
- `swift build -c release --product corespice`  
- Binary path after build: `.build/release/corespice`

## Batch Usage
```bash
corespice -b <deck.cir> [--op | --tran tstep tstop | --ac dec|lin points start stop | --dc source start stop step] \
         [-r out.raw] [--csv out.csv] [--psf out.psf]
```
- `-b <deck.cir>`: required; loads the SPICE netlist.
- Analysis flags (optional): override auto-detection of `.tran/.ac/.dc/.op` in the deck.
- Output flags: emit results via built-in exporters (RAW, CSV, PSF).
- Exit status is non-zero on parse/compile/run errors.
- Monte Carlo: if the deck contains `.mc <runs> <analysis> [seed=n]`, the CLI runs the Monte Carlo loop with deterministic RNG per run. CSV export writes stats (mean/stddev/min/max/p5/p95) for each variable; RAW/PSF export the first run for compatibility.

## Interactive Shell
```bash
corespice
```
Prompts with `corespice>`. Commands:
- `source <path>` — load a SPICE deck.
- `run` — auto-detects `.tran/.ac/.dc/.op` directives in the loaded deck and executes.
- `op` — run operating-point analysis.
- `tran <tstep> <tstop>` — run transient analysis with fixed initial/max step.
- `ac dec|lin <points> <start> <stop>` — run AC sweep.
- `dc <source> <start> <stop> <step>` — run DC sweep of the named source (e.g., `dc V1 0 1 0.1`).
- `write raw|csv|psf <path>` — export the last result.
- `help` — show command summary.
- `quit`/`exit` — leave the shell.

State: the shell retains the loaded netlist, compiled plan, bound devices, and last waveform so you can `write` after any run.

## Expected Environment
- macOS 26+, Swift 6.2 toolchain.
- Metal available for GPU-backed backends (photonic paths); core electrical analyses run on CPU.

## Roadmap / Notes
- Optional: support `.control ... .endc` sections, expression evaluation for `print/plot`, and solver tuning via `set/unset`.
