# CoreSpice vs ngspice Cross-Validation

Reference-oracle validation of CoreSpice against ngspice, using the LSI
ring-oscillator dogfood netlist as the first benchmark. The goal is to
strengthen CoreSpice by holding its results against an independent simulator.

## Environment

| Item | Value |
|---|---|
| ngspice | 46 (KLU direct solver), `brew install ngspice` |
| CoreSpice CLI | 0.1.0 (`.build/debug/corespice`) |
| Benchmark deck | `dogfood/ring-oscillator-001/.../pre-layout.cir` |
| Circuit | Five-stage CMOS ring oscillator, MOSFET `level=1`, explicit startup pulse |
| Analysis | `.tran 20p 50n` |

Both engines run the same `.cir`. The deck uses only MOSFET level-1 models, which
both simulators support, so it sits inside the shared model envelope.

## Reproduction

```bash
SRC=dogfood/ring-oscillator-001/flow-output/.xcircuite/flow-runs/ring-oscillator-001/pre-layout.cir

# ngspice (append a control block that runs the deck's .tran and dumps v(n1))
#   .control / run / linearize / wrdata ng_n1.csv v(n1) / .endc
ngspice -b ng_ringosc.cir

# CoreSpice
.build/debug/corespice -b "$SRC" --csv cs_out.csv
```

## Defects found and fixed (CoreSpice CLI analysis setup)

All three share one root cause: the CLI parsed SPICE numbers with raw
`Double(_:)`, which does not understand engineering suffixes (`20p`, `50n`).

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Deck `.tran 20p 50n` ran to 1 us (20x too long); no oscillation | `AnalysisDetector.detect(source:)` re-parsed the raw string; `Double("20p")` → nil → **silent fallback** to `.tran(1e-9, 1e-6)` | Route batch/REPL through the already-parsed `parsedNetlist.analyses`; delete `AnalysisDetector` |
| 2 | `--tran 20p 50n` flag → `fatalError` (NaN→Int) | `Double("20p") ?? 0` → tstep=tstop=0 → `0/0`=NaN in step-count | `parseSPICENumber` (reuses `SPICELexer`); throw on non-numeric; guard tstop/tstep > 0 |
| 3 | Same crash via REPL `tran`/`ac`/`dc` and `--ac`/`--dc` | Same `Double(_:) ?? default` pattern | Same fail-loud parsing across all CLI number inputs |

Both behaviors violated repository rules (no silent fallback; no `fatalError` in
production paths). Regression coverage added in
`Tests/CoreSpiceCLITests/AnalysisSetupTests.swift` (4 tests, passing).

## Results after fix

| Metric | ngspice | CoreSpice | Status |
|---|---|---|---|
| Initial operating point V(n1..n5) | 0.895254 V | 0.895217 V | Match (rel ~4e-5) |
| Stop time honored | 50 ns | 50 ns | Fixed |
| Oscillates | yes | yes | Fixed |
| Oscillation frequency | 1.854 GHz | 1.178 GHz | **OPEN: 36% low** |
| Amplitude | 1.819 V | 1.897 V | +4% |

CoreSpice's 1.178 GHz matches the circuit-studio dogfood run (1.176 GHz), so the
CLI and library paths are now consistent.

## Open discrepancy (next investigation)

CoreSpice's ring-oscillator frequency is 36% below ngspice on the identical
level-1 netlist. Per-stage delay: ngspice 53.9 ps vs CoreSpice 84.9 ps (1.57x).

The model card specifies no capacitance parameters (no `tox`, `cgso`, `cgdo`,
`cj`). Hypothesis: the engines disagree on default MOSFET intrinsic/overlap
capacitance when those parameters are omitted (SPICE convention treats them as
zero unless specified). This is **not yet confirmed** and must not be reported
as resolved.

Attempted isolation by raising load caps to 1 pF was inconclusive: the 20 fC
startup pulse only moves a 1 pF node by ~20 mV, so CoreSpice did not leave the
metastable point (startup-sensitivity confound). Next: characterize a single
inverter's step-response propagation delay into a fixed load, with and without
explicit MOSFET capacitance parameters, to separate drive current from load
capacitance.
