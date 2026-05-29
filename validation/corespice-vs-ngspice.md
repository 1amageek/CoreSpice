# CoreSpice Numerical Trust Gate (vs ngspice + analytic)

Systematic validation of CoreSpice against an independent oracle (closed-form
analytic where available, otherwise ngspice). The gate is the precondition for
trusting CoreSpice in downstream layout / PEX / signoff work. Out-of-tolerance
discrepancies are root-caused and fixed in CoreSpice — never silently accepted.

## Running the gate

```bash
brew install ngspice
swift build --product corespice
python3 validation/gate.py        # 19/19 circuits must pass
```

`gate.py` runs each circuit through CoreSpice and compares the result to the
analytic solution and/or ngspice, with per-circuit tolerances. Exit code is 0
only when every circuit passes.

## Corpus (19 circuits, all passing)

| # | Circuit | Analysis | Oracle | Tolerance |
|---|---|---|---|---|
| 01 | resistive divider | DC sweep | analytic | 1e-6 |
| 02 | RC low-pass | AC | analytic | 1e-3 rel |
| 03 | RC step | TRAN | analytic | 1e-3 |
| 04 | RL high-pass | AC | analytic | 1e-3 rel |
| 05 | RLC series | AC | ngspice | 0.05 dB |
| 06 | RLC step | TRAN | ngspice | 0.02 V |
| 07 | diode I-V | DC sweep | ngspice | 5e-3 V |
| 08 | NMOS Id-Vds | DC sweep | analytic + ngspice | 5e-3 rel |
| 09 | common-source amp | AC | ngspice | 0.6 dB |
| 10 | current source → resistor | DC | analytic + ngspice | 1e-6 |
| 11 | current mirror reference | DC | ngspice | 0.01 V |
| 12 | CMOS inverter VTC | DC sweep | ngspice | 0.03 V |
| 13 | 5T OTA operating point | DC (op) | ngspice | 0.02 V |
| 14 | ring oscillator frequency | TRAN | ngspice | 2% |
| 15 | differential pair balance | DC | ngspice | 1e-3 / 0.02 |
| 16 | MOSFET body effect (Vsb≠0) | DC | analytic + ngspice | 5e-3 rel |
| 17 | MOSFET explicit caps (CGSO/CGDO/CJ) | AC | ngspice | 1e-3 rel |
| 18 | BJT common-emitter bias | DC | ngspice | 0.05 V |
| 19 | PMOS common-source, saturated | AC | ngspice | 0.02 dB |

The common-source amp (09) uses a solidly-saturated bias and matches ngspice to
0.000 dB. The triode/saturation boundary is intrinsically gain-sensitive in the
level-1 model (both engines), so circuits are biased away from Vds≈Vov.

The linear core (R/C/L, DC/AC/TRAN) matches analytic to ~1e-7. MOSFET level-1 DC
drive current matches ngspice to ~0.03%. The ring oscillator is within 0.56%.

## Bugs found and fixed (committed)

| Bug | Root cause | Fix | Regression |
|---|---|---|---|
| CLI dropped SPICE suffixes (20p/50n); silent 1us fallback + NaN fatalError | CLI parsed analysis numbers with raw `Double(_:)` | Route deck analysis through parsed netlist; `parseSPICENumber`; fail loudly | AnalysisSetupTests |
| MOSFET phantom gate capacitance (ring osc 36% slow) | default TOX = 100nm → cox always nonzero | default TOX = 0 (no oxide cap unless specified) | MOSFETCapacitanceDefaultTests |
| Every DC current source was 0 A | parser stored the current value under "v"; descriptor reads "i" | parser stores current-source DC value under "i" | CurrentSourceValueTests |
| Current source sign inverted vs SPICE | non-standard convention in `BoundCurrentSource` | draw from + node, inject into − node (SPICE) | CurrentSourceConventionTests |
| NR could accept a false (degenerate) DC solution | convergence checked only the update norm ‖Δx‖ | also require KCL residual ‖F(x)=(G+gmin)·x−s‖ within tol | (guarded by OTA/mirror in gate.py + CurrentSourceConventionTests) |
| MOSFET body effect 22% off (Vsb≠0) | threshold used `2·phi` but SPICE PHI is already the full surface potential | use PHI directly in all 6 MOSFET levels (L1/2/3 × N/P) | gate.py #16 + MOSFETPhysicsTests gmbs |

A pre-existing test (C15) encoded the old, inverted current-source sign; it was
corrected to the SPICE convention (V = −I·R), verified against ngspice.

## Method note

When a CoreSpice result disagreed with an analytic value, the reference was
verified against ngspice before blaming CoreSpice. One early "inductor AC broken"
claim was a mistake in the analytic reference (wrong RL corner frequency), caught
because ngspice agreed with the supposed "error".

## Remaining (gate not yet complete; G2+ still frozen)

- MOSFET junction (CJ/CJSW) and overlap (CGSO/CGDO) capacitances, body effect.
- MOSFET level-2 / level-3 accuracy vs ngspice.
- BJT and diode dynamic (capacitive) behavior.
- Analyses not yet gated: noise, transfer function, pole-zero, Fourier, Monte Carlo.
- Common-source amp AC gain is 0.5 dB below ngspice (within the 0.6 dB gate but
  worth narrowing — likely an operating-point detail).
- Promote the corpus into committed golden-data Swift tests so the gate also runs
  without ngspice installed.
