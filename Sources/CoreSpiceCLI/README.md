# CoreSpiceCLI

Command-line front end for CoreSpice. Supports batch execution against a SPICE deck and an interactive REPL-style shell.

## Build
- `swift build -c release --product corespice`  
- Binary path after build: `.build/release/corespice`

## Batch Usage
```bash
corespice -b <deck.cir> [--op | --tran tstep tstop | --ac dec|lin points start stop | --dc start stop step] \
         [-r out.raw] [--csv out.csv] [--psf out.psf]
```
- `-b <deck.cir>`: required; loads the SPICE netlist.
- Analysis flags (optional): override auto-detection of `.tran/.ac/.dc/.op` in the deck.
- Output flags: emit results via built-in exporters (RAW, CSV, PSF).
- Exit status is non-zero on parse/compile/run errors.
- Note: `--dc` parsing works but execution is currently **not implemented** and will report an error.

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
- `dc <start> <stop> <step>` — currently unimplemented; returns an explicit error.
- `write raw|csv|psf <path>` — export the last result.
- `help` — show command summary.
- `quit`/`exit` — leave the shell.

State: the shell retains the loaded netlist, compiled plan, bound devices, and last waveform so you can `write` after any run.

## Expected Environment
- macOS 26+, Swift 6.2 toolchain.
- Metal available for GPU-backed backends (photonic paths); core electrical analyses run on CPU.

## Roadmap / Notes
- Implement DC sweep stepping of source values (`dc` command and `--dc` flag).
- Optional: support `.control ... .endc` sections, expression evaluation for `print/plot`, and solver tuning via `set/unset`.
