# CoreSpice Numerical Trust Gate (vs ngspice + analytic)

Systematic, bottom-up validation of CoreSpice against an independent oracle
(closed-form analytic where available, otherwise ngspice). The goal is a
trustworthy simulator: every layer must pass quantified tolerances before
downstream work (layout / PEX / signoff) is allowed to build on it. Out-of-
tolerance discrepancies are root-caused and fixed in CoreSpice — never silently
accepted.

## Environment

| Item | Value |
|---|---|
| ngspice | 46 (KLU direct solver), `brew install ngspice` |
| CoreSpice CLI | 0.1.0 (`.build/debug/corespice`) |
| Method | Same SPICE deck fed to both engines; compare to analytic and/or ngspice |

## Layer ledger

Bottom-up: a layer is trusted only after the layers beneath it pass.

| Layer | Benchmark | Oracle | CoreSpice result | Status |
|---|---|---|---|---|
| L1 linear core | Resistive divider (DC) | analytic | max err 2.5e-9 | PASS |
| L1 linear core | RC low-pass (AC) | analytic + ngspice | rel \|H\| err 2.7e-7, phase 7.8e-6 deg | PASS |
| L1 linear core | RC step (TRAN) | analytic + ngspice | max err 3.0e-8 (beats ngspice) | PASS |
| L2 MOSFET drive | NMOS Id-Vds level-1 | analytic + ngspice | CS/NG 1.0001-1.0003 | PASS |
| L2 MOSFET cap | Gate-cap AC probe | ngspice | phantom 2.3 fF found -> FIXED to 0 | PASS (after fix) |
| L4 composite | Ring oscillator (TRAN) | ngspice | 1.18 GHz -> 1.864 GHz after fix (ngspice 1.854) | PASS (0.56%) |

Conclusion so far: the linear core (MNA solver, R/C/L companion models, DC/AC/
TRAN integration) is essentially exact, and MOSFET level-1 DC drive current
matches the reference to ~0.03%.

## Fix 1: CLI analysis setup (committed dedede7)

The CLI parsed SPICE numbers with raw `Double(_:)`, dropping engineering
suffixes (20p, 50n): deck `.tran` silently fell back to a 1 us stop time, and
`--tran` flags fed 0 into the transient config producing a NaN `fatalError`.
Fixed by routing deck analysis through the parsed netlist, adding
`parseSPICENumber` (reuses `SPICELexer`), failing loudly, and guarding the
transient config. Regression: `Tests/CoreSpiceCLITests/AnalysisSetupTests.swift`.

## Fix 2: MOSFET phantom gate capacitance (default TOX)

### Root cause

`MOSFETModelParameters.tox` and all six MOSFET descriptors (NMOS/PMOS L1/L2/L3)
defaulted TOX to 100 nm. So `cox = eps_ox / tox` was always nonzero and the
Meyer model produced intrinsic gate capacitance even when the model card
specified no capacitance parameters. ngspice (and SPICE convention) derive no
oxide capacitance unless TOX is given.

Confirmation (gate-cap AC probe, W=10u L=1u):

| Model card | CoreSpice Cgg | ngspice Cgg |
|---|---|---|
| no tox | 2.302 fF (phantom) | 0 fF |
| tox=1e-7 explicit | 2.302 fF | 2.302 fF (exact match) |

So CoreSpice's capacitance model is correct; only the default was wrong. The
phantom ~2.3 fF per device loaded every ring-oscillator node, slowing it 36%.

### Fix

Default TOX changed to 0 (unspecified -> no oxide capacitance). `cox` already
returns 0 for `tox <= 0`, so intrinsic Meyer caps become zero, matching ngspice.
When TOX is specified, behavior is unchanged (and matches ngspice exactly).

Files: `MOSFETModelParameters.swift` (init default + docs), the six
`*Descriptor.swift` tox defaults. Regression:
`Tests/CoreSpiceDevicesTests/MOSFETCapacitanceDefaultTests.swift`.

### Result

Ring oscillator: 1.18 GHz -> 1.864 GHz vs ngspice 1.854 GHz (0.56%). Existing
device + analysis suites (292 tests) still pass.

## Reproduction

```bash
# ngspice golden (append .control { run / linearize / wrdata } to a copy)
ngspice -b <deck-with-control>.cir
# CoreSpice
.build/debug/corespice -b <deck>.cir --csv out.csv
# compare to analytic / ngspice (see /tmp/cs_validation harness)
```

## Remaining layers (trust gate not yet complete)

G2+ (layout/PEX/signoff) stays frozen until these pass:

- L2: MOSFET junction capacitances (CJ/CJSW), overlap caps (CGSO/CGDO), BJT and
  diode dynamic behavior, body effect (gamma) accuracy.
- L2/L3: MOSFET level-2 and level-3 DC + dynamic accuracy vs ngspice.
- L3: single-stage CMOS inverter propagation delay vs ngspice.
- Analyses not yet gated: noise, transfer function, pole-zero, Fourier, DC sweep
  of active devices, Monte Carlo determinism.
- Promote this harness into committed Swift regression tests with golden data so
  the gate runs without ngspice installed.
