# CoreSpiceCLI

Command-line front end for CoreSpice. Supports batch execution and an interactive REPL shell.

## Build

```bash
swift build -c release --product corespice
```

Binary: `.build/release/corespice`

## Batch Mode

```bash
corespice -b <deck.cir> [analysis] [export]
```

### Flags

| Flag | Description |
|------|-------------|
| `-b`, `--batch` `<file>` | Load SPICE netlist (required) |
| `--op` | Run DC operating point |
| `--tran` `<tstep> <tstop>` | Run transient analysis |
| `--ac` `<dec\|lin> <points> <start> <stop>` | Run AC analysis |
| `--dc` `<source> <start> <stop> <step>` | Run DC sweep |
| `-r` `<file>` | Export to RAW format (ngspice) |
| `--csv` `<file>` | Export to CSV format |
| `--psf` `<file>` | Export to PSF format (Cadence) |
| `--coverage-json` `<file>` | Export structured deck coverage evidence |
| `--seed` `<UInt64>` | Record the explicit random seed used by the invocation |
| `--json` | Emit a deterministic machine-readable run record on stdout (see below) |
| `-h`, `--help` | Show help |
| `-v`, `--version` | Show version |

Analysis flags override directives in the netlist. If omitted, the CLI auto-detects the analysis from the deck (first `.tran`, `.ac`, `.dc`, or `.op` found, in that order).

### Examples

```bash
# Auto-detect analysis from deck, export to RAW
corespice -b amplifier.cir -r output.raw

# Override with transient, export to CSV
corespice -b filter.cir --tran 1n 100n --csv output.csv

# AC sweep, export to PSF
corespice -b filter.cir --ac dec 10 1 1meg --psf output.psf

# DC sweep of V1 from 0 to 5V in 0.1V steps
corespice -b diode.cir --dc V1 0 5 0.1 --csv output.csv

# Multiple export formats
corespice -b circuit.cir -r output.raw --csv output.csv --psf output.psf
```

Exit status is non-zero on parse, compile, or analysis errors.

## Post-hoc Waveform Measurement (`measure`)

Evaluates `.measure`-grammar specs against a stored waveform CSV — no
re-simulation. This closes the authoring → inspect → measure loop for agents:
run once, keep the CSV artifact, and measure it as many times as needed.

```bash
corespice measure --waveform <path.csv> --measure "<spec>" [--measure "<spec>" ...] [--json]
```

| Flag | Description |
|------|-------------|
| `--waveform` `<file>` | Waveform CSV to measure (required). Must be in the dialect written by the CoreSpice CSV exporter |
| `--measure` `"<spec>"` | Measurement spec (repeatable, at least one). `.measure` statement grammar without the leading `.measure` |
| `--json` | Emit a machine-readable measurement record on stdout (see below) |

### Spec grammar

`<spec>` is exactly the deck `.measure` statement body, parsed with the same
SPICE parser and evaluated with the same measurement engine as in-deck
`.measure` directives. It must start with the analysis type (`tran`, `ac`,
`dc`, or `op`), followed by the result name and the measurement:

```bash
corespice measure --waveform out.csv \
  --measure "tran vfinal FIND V(out) AT=5u" \
  --measure "tran vpeak MAX V(out) FROM=1u TO=9u" \
  --measure "tran irms RMS I(v1)"
```

Supported measurement kinds (the full set the CoreSpice measurement engine
implements — nothing more is accepted):

| Kind | Form | Result |
|------|------|--------|
| `FIND` | `FIND <var> AT=<x>` | Value at sweep point (interpolated) |
| `AVG` | `AVG <var> [FROM=<x>] [TO=<x>]` | Trapezoidal average over range |
| `RMS` | `RMS <var> [FROM=<x>] [TO=<x>]` | Root-mean-square over range |
| `MIN` | `MIN <var> [FROM=<x>] [TO=<x>]` | Minimum over range |
| `MAX` | `MAX <var> [FROM=<x>] [TO=<x>]` | Maximum over range |
| `PP` | `PP <var> [FROM=<x>] [TO=<x>]` | Peak-to-peak over range |
| `INTEG` | `INTEG <var> [FROM=<x>] [TO=<x>]` | Trapezoidal integral over range |
| `RISE_TIME` | `RISE_TIME <var> [LOW=<f>] [HIGH=<f>]` | Rising transition time (defaults 0.1/0.9) |
| `FALL_TIME` | `FALL_TIME <var> [HIGH=<f>] [LOW=<f>]` | Falling transition time (defaults 0.9/0.1) |
| delay | `TRIG <var> VAL=<v> TARG <var> VAL=<v>` | Time between threshold crossings |
| `WHEN` | `WHEN <condition>` | Sweep point where a condition first becomes true |

Any other `.measure` kind (e.g. `DERIV`, `PARAM`) is rejected with a
structured error — no silent extensions.

`<var>` accepts `V(node)`, `V(node,ref)`, `I(device)`, and for complex (AC)
waveforms `VM()`/`VP()`/`VR()`/`VI()`/`VDB()` forms, exactly as in a deck.

### Input CSV contract

The CSV must be the dialect written by the CoreSpice CSV exporter: one header
row (first column is the sweep variable, e.g. `time [s]`; remaining columns
are variables like `V(out) [V]`), then one numeric row per sweep point. Unit
suffixes (`name [unit]`) and double-quoted fields are optional. Complex (AC)
waveforms are recognized by adjacent `<name>_real`/`<name>_imag` column
pairs. Malformed input (non-numeric cell, ragged rows, unknown unit, broken
complex pairing) is a typed `waveform.csv-read` failure — values are never
coerced to NaN.

The CSV does not record the analysis kind, so it is inferred from the sweep
column name: `time` → `tran`, `frequency`/`freq` → `ac`, anything else →
`dc`/`op`. A spec whose declared analysis type does not match the waveform's
sweep domain fails with `measure.analysis-mismatch` (never silently skipped).

### Output

Text mode prints one line per measurement (`name=value [unit]`, unit omitted
when dimensionless):

```
vfinal=4.999999995 V
vpeak=4.999999995 V
```

A measurement that cannot be evaluated (missing variable, sweep point out of
range, threshold never crossed) fails the whole invocation with a structured
error naming the measurement and the reason.

With `--json`, a completed measurement record identifies the exact input
waveform through `CircuiteFoundation.ArtifactReference`:

```json
{
  "schemaVersion": { "major": 1, "minor": 0, "patch": 0 },
  "status": "succeeded",
  "producer": { "kind": "tool", "identifier": "CoreSpiceCLI", "version": "0.1.0" },
  "invocation": {
    "mode": "externalProcess",
    "executable": "corespice",
    "arguments": ["measure", "--waveform", "/workspace/out.csv", "--measure", "tran vfinal FIND V(out) AT=5u", "--json"],
    "workingDirectory": "/workspace"
  },
  "inputArtifact": {
    "id": "<canonical-content-identity>",
    "descriptor": { "role": "input", "kind": "waveform", "format": "csv" }
  },
  "measurements": [
    { "analysis": "tran", "name": "vfinal", "value": 4.999999995, "unit": "V" }
  ],
  "waveform": {
    "points": 101,
    "variables": ["V(in)", "V(out)", "I(v1)"]
  }
}
```

| Field | Presence | Description |
|-------|----------|-------------|
| `schemaVersion` | always | Version of the measurement record schema |
| `status` | always | `"succeeded"` |
| `invocation` | always | Normalized executable, arguments, and working directory required to replay the measurement |
| `inputArtifact` | always | Foundation reference for the measured CSV, including role, kind, format, SHA-256 digest, and byte count |
| `measurements` | always | Evaluated specs in command-line order (`unit` omitted when empty) |
| `waveform` | always | `variables` (data variable names), `points` (sweep point count) |

Failures use the shared failure record and exit-code convention (0 success,
1 text-mode failure, 2 `--json` failure record); measure-specific codes are
`measure.spec-parse`, `measure.analysis-mismatch`, `measure.evaluation`, and
`waveform.csv-read` (see the failure-code table below).

## Reproducible JSON Records (`--json`)

With `--json`, every invocation writes exactly one JSON object to stdout so
external agents can parse outcomes without scraping prose. Encoding is
deterministic (sorted keys). Without `--json`, output and exit codes are
unchanged (plain text, errors as `error: ...` on stderr).

### Exit codes

| Exit code | Meaning |
|-----------|---------|
| `0` | Success (with `--json`: completed record on stdout) |
| `1` | Failure in text mode (`error: ...` on stderr, no JSON) |
| `2` | Failure with `--json`: failure record on stdout |

### Failure record

Emitted on any failure when `--json` is present:

```json
{
  "status": "failed",
  "code": "io.file-read",
  "message": "The file \"deck.cir\" couldn't be opened because there is no such file.",
  "stage": "load",
  "suggestedActions": ["check that the input path exists and is readable"]
}
```

| Field | Presence | Description |
|-------|----------|-------------|
| `status` | always | `"failed"` |
| `code` | always | Stable dotted-kebab identifier derived from the typed error |
| `message` | always | Human-readable description |
| `stage` | when derivable | `arguments`, `load`, `parse`, `lower`, `compile`, `analysis`, `measure`, or `export` |
| `suggestedActions` | when derivable | Remediation hints |

Stable failure codes:

| Code | Stage | Cause |
|------|-------|-------|
| `cli.invalid-arguments` | `arguments` | Bad or missing command-line arguments |
| `cli.unknown-command` | `arguments` | Unknown command token |
| `cli.state` | — | Invalid CLI state (e.g. no netlist loaded) |
| `cli.unsupported-analysis` | `analysis` | Deck directive the batch runner cannot execute |
| `cli.missing-analysis-directive` | `analysis` | Deck has no runnable analysis directive |
| `io.file-read` | `load` | Deck (or input file) missing or unreadable |
| `io.file-write` | `export` | Output path unwritable |
| `io.posix`, `io.cocoa` | — | Other file-system errors |
| `deck.parse` | `parse` | SPICE syntax error |
| `deck.lower` | `lower` | Netlist lowering failure (undefined model, parameter, ...) |
| `deck.analysis-options` | `lower` | Invalid `.options` values |
| `compile.failed` | `compile` | Circuit compilation failure |
| `compile.device-binding` | `compile` | Device binding failure |
| `analysis.convergence-failure` | `analysis` | Newton-Raphson did not converge |
| `analysis.singular-matrix` | `analysis` | Singular MNA matrix |
| `analysis.cancelled` | `analysis` | Analysis cancelled |
| `analysis.invalid-configuration` | `analysis` | Invalid analysis configuration |
| `analysis.timestep-too-small` | `analysis` | Transient timestep underflow |
| `analysis.internal` | `analysis` | Internal analysis error |
| `analysis.result` | `analysis` | Invalid transient result |
| `waveform.validation` | `analysis` | Waveform shape validation failure |
| `measure.evaluation` | `measure` | `.measure` evaluation failure (in-deck or `measure` verb: missing variable, out-of-range point, ...) |
| `measure.spec-parse` | `parse` | `measure` verb spec is not a valid single `.measure` statement |
| `measure.analysis-mismatch` | `measure` | `measure` verb spec declares an analysis type that does not match the waveform sweep domain |
| `waveform.csv-read` | `load` | `measure` verb waveform CSV is missing columns, ragged, or non-numeric |
| `export.write` | `export` | Waveform export failure |
| `internal.unhandled` | — | Any error without a dedicated mapping |

### Completed batch run record

Emitted when a `-b` batch run completes with `--json`:

```json
{
  "status": "succeeded",
  "schemaVersion": { "major": 1, "minor": 0, "patch": 0 },
  "producer": { "kind": "tool", "identifier": "CoreSpiceCLI", "version": "0.1.0" },
  "invocation": {
    "mode": "externalProcess",
    "executable": "corespice",
    "arguments": ["-b", "/workspace/deck.cir", "--json", "-r", "/workspace/out.raw"],
    "workingDirectory": "/workspace"
  },
  "analyses": ["tran"],
  "inputArtifacts": [
    {
      "id": "<canonical-content-identity>",
      "descriptor": { "role": "input", "kind": "netlist", "format": "spice" }
    }
  ],
  "outputArtifacts": [
    {
      "id": "<canonical-content-identity>",
      "descriptor": { "role": "output", "kind": "waveform", "format": "raw" }
    }
  ],
  "measurements": [
    { "analysis": "tran", "name": "vfinal", "value": 4.999999995, "unit": "V" }
  ],
  "waveform": {
    "points": 51,
    "variables": ["V(in)", "V(out)", "I(v1)"]
  }
}
```

| Field | Presence | Description |
|-------|----------|-------------|
| `schemaVersion` | always | Version of the batch run record schema |
| `status` | always | `"succeeded"` |
| `invocation` | always | Exact executable, arguments, and working directory required to replay the batch run |
| `analyses` | always | Analyses that ran: `op`, `tran`, `ac`, `dc`, or `mc(<inner>)` |
| `inputArtifacts` | always | Foundation references for materialized inputs; the deck is `role=input`, `kind=netlist`, `format=spice` |
| `outputArtifacts` | always | Foundation references for every written file, with role/kind/format, SHA-256 digest, byte count, and CoreSpiceCLI producer identity |
| `measurements` | always | Evaluated `.measure` results (`unit` omitted when empty) |
| `waveform` | when a waveform was produced | `variables` (data variable names), `points` (sweep point count), `runs` (Monte Carlo run count, parametric results only) |

File outputs (`-r`, `--csv`, `--psf`, `--coverage-json`) are written exactly as
in text mode; the record replaces only the human-readable stdout summary.
Non-fatal `.options` diagnostics are still reported as `warning:` lines on
stderr in both modes. The interactive REPL ignores `--json`.

```bash
# Agent-friendly batch run
corespice -b rc.cir --json --csv out.csv -r out.raw
```

## Planning Artifacts

CoreSpice can emit machine-readable planning artifacts for higher-level design loops without introducing a harness abstraction.

### Metric Improvement Objective

```bash
corespice metric-improvement-objective \
  --measurement-report <measurement-report.json> \
  --specification <metric-specification.json> \
  --parameter-space <bounded-parameter-space.json> \
  [--output <planning-problem.json>] \
  [--problem-id <id>] \
  [--created-at <timestamp>] \
  [--pretty]
```

Inputs:

| Input | Contract |
|-------|----------|
| `measurement-report` | JSON object with `metrics` containing metric `name`, numeric `value`, and optional `unit` |
| `specification` | JSON object with `specifications` containing metric bounds or target/tolerance |
| `parameter-space` | JSON object with bounded editable parameters |

Output artifact: `CoreSpiceMetricImprovementPlanningProblem`.

### Convergence Recovery Objective

```bash
corespice convergence-recovery-objective \
  --diagnostic-report <diagnostics.json> \
  --netlist <deck.cir> \
  --analysis-options <analysis-options.json> \
  [--retry-policy <retry-policy.json>] \
  [--output <planning-problem.json>] \
  [--problem-id <id>] \
  [--created-at <timestamp>] \
  [--pretty]
```

Inputs:

| Input | Contract |
|-------|----------|
| `diagnostic-report` | JSON object with `analysisType` and structured convergence diagnostics |
| `netlist` | SPICE netlist reference used as the retry target |
| `analysis-options` | JSON object with analysis options such as tolerance, iteration, timestep, and integration method |
| `retry-policy` | Optional JSON object bounding generated retry options |

Output artifact: `CoreSpiceConvergenceRecoveryPlanningProblem`.

## Interactive Shell

```bash
corespice
```

Prompt: `corespice>`

### Commands

| Command | Syntax | Description |
|---------|--------|-------------|
| `source` | `source <path>` | Load a SPICE netlist |
| `run` | `run` | Auto-detect analysis from loaded deck and execute |
| `op` | `op` | Run DC operating point |
| `tran` | `tran <tstep> <tstop>` | Run transient analysis |
| `ac` | `ac <dec\|lin> <points> <start> <stop>` | Run AC frequency sweep |
| `dc` | `dc <source> <start> <stop> <step>` | Run DC source sweep |
| `write` | `write <raw\|csv\|psf> <path>` | Export last result |
| `help` | `help` | Show command summary |
| `quit` | `quit` or `exit` | Exit |

The shell retains state across commands. Load a netlist once, run multiple analyses, and export at any point.

### Session Example

```
corespice> source amplifier.cir
loaded amplifier.cir
corespice> op
op complete
corespice> ac dec 20 1 10g
ac complete
corespice> write csv ac_response.csv
wrote ac_response.csv
corespice> tran 1n 1u
tran complete
corespice> write raw transient.raw
wrote transient.raw
corespice> quit
```

## Monte Carlo

If the deck contains a `.mc` directive, the CLI automatically runs Monte Carlo iterations.

```spice
RC Filter Variation
V1 in 0 dc 5
R1 in out 1k
C1 out 0 100n
.mc 100 tran 10n 1u seed=42
.end
```

- Each iteration uses a deterministic seed derived from the base seed.
- Supported inner analyses: `.tran`, `.ac`, `.dc`.
- CSV export writes per-variable statistics (mean, stddev, min, max, p5, p95).
- RAW/PSF export the first run for format compatibility.

## Supported SPICE Syntax

### Netlist Structure

```spice
Title Line
* Comment
.param vdd=3.3 vth=0.5

.subckt inv in out vdd vss
M1 out in vdd vdd pch W=2u L=100n
M2 out in vss vss nch W=1u L=100n
.ends inv

.model nch nmos level=1 vto=0.5 kp=200u
.model pch pmos level=1 vto=-0.5 kp=100u

Vdd vdd 0 {vdd}
Vin in 0 pulse(0 3.3 0 1n 1n 10n 20n)
X1 in out vdd 0 inv

.tran 1n 100n
.end
```

### Devices

| Prefix | Device | Nodes | Example |
|--------|--------|-------|---------|
| `R` | Resistor | 2 | `R1 a b 1k` |
| `C` | Capacitor | 2 | `C1 a b 100p` |
| `L` | Inductor | 2 | `L1 a b 1u` |
| `V` | Voltage source | 2 | `V1 a b dc 5 ac 1` |
| `I` | Current source | 2 | `I1 a b 1m` |
| `D` | Diode | 2 | `D1 a b dmod` |
| `Q` | BJT | 3 | `Q1 c b e npnmod` |
| `M` | MOSFET | 4 | `M1 d g s b nch W=1u L=100n` |
| `E` | VCVS | 4 | `E1 out 0 in 0 10` |
| `G` | VCCS | 4 | `G1 out 0 in 0 1m` |
| `F` | CCCS | 2+ref | `F1 out 0 Vsense 5` |
| `H` | CCVS | 2+ref | `H1 out 0 Vsense 1k` |
| `W` | Current switch | 2+ref+model | `W1 in out Vsense cswmod` |
| `X` | Subcircuit | var | `X1 in out vdd 0 inv` |

### Source Waveforms

```spice
* DC
V1 a b 5
V1 a b dc 5 ac 1

* Pulse: v1 v2 delay rise fall width period
V1 a b pulse(0 5 0 1n 1n 5u 10u)

* Sine: offset amplitude frequency delay phase
V1 a b sin(0 1 1meg 0 0)

* Piecewise linear
V1 a b pwl(0 0 1n 0 2n 5 10n 5 11n 0)
```

### Analysis Directives

| Directive | Syntax |
|-----------|--------|
| `.op` | `.op` |
| `.dc` | `.dc V1 0 5 0.1` |
| `.ac` | `.ac dec 10 1 1meg` |
| `.tran` | `.tran 1n 100n` |
| `.noise` | `.noise V(out) Vin dec 10 1 1meg` |
| `.tf` | `.tf V(out) Vin` |
| `.sens` | `.sens V(out)` |
| `.four` | `.four 1meg V(out)` |
| `.pz` | `.pz 1 0 2 0 vol pz` |
| `.mc` | `.mc 100 tran 1n 1u seed=42` |

### Number Suffixes

| Suffix | Multiplier | Example |
|--------|-----------|---------|
| `t` | 10^12 | `1t` = 1e12 |
| `g` | 10^9 | `2.4g` = 2.4e9 |
| `meg` | 10^6 | `1meg` = 1e6 |
| `k` | 10^3 | `4.7k` = 4700 |
| `m` | 10^-3 | `20m` = 0.02 |
| `u` | 10^-6 | `100u` = 1e-4 |
| `n` | 10^-9 | `10n` = 1e-8 |
| `p` | 10^-12 | `22p` = 2.2e-11 |
| `f` | 10^-15 | `1f` = 1e-15 |

### Parameter Expressions

```spice
.param w=2u l=100n ratio={w/l}
M1 d g s b nch W={w} L={l}
```

Supported operators: `+`, `-`, `*`, `/`, `^`. Parentheses for grouping.

## Environment

- macOS 26+, Swift 6.3
- Metal GPU required only for photonic mesh paths; all electrical analyses run on CPU.
