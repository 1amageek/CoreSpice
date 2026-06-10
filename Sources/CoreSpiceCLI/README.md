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
