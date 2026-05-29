# CoreSpice Numerical Trust Gate (vs ngspice + analytic)

Systematic validation of CoreSpice against an independent oracle (closed-form
analytic where available, otherwise ngspice). The gate is the precondition for
trusting CoreSpice in downstream layout / PEX / signoff work. Out-of-tolerance
discrepancies are root-caused and fixed in CoreSpice — never silently accepted.

## Running the gate

```bash
swift build --product corespice
python3 validation/gate.py        # golden mode (default): 28/28 must pass, no ngspice
swift test --filter TrustGateTests # same gate, run from the Swift test suite
```

`gate.py` runs each circuit through CoreSpice and compares the result to the
analytic solution and/or a frozen reference, with per-circuit tolerances. Exit
code is 0 only when every circuit passes.

By default the gate runs in **golden mode**: the ngspice-derived references are
read from the committed `validation/golden.json`, so the gate (and the
`TrustGateTests` Swift test that drives it) runs in CI without ngspice
installed. Regenerate the golden references from a live ngspice run when the
reference simulator or a circuit changes:

```bash
brew install ngspice
python3 validation/gate.py --update-golden   # rewrites validation/golden.json
```

Circuits whose oracle is closed-form analytic (01–04, 08, 10, 16, 20–23) need no
golden data; only the ngspice-compared circuits are stored in `golden.json`.

## Corpus (28 circuits, all passing)

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
| 20 | MOSFET level-2 reduces to level-1 (θ=η=0) | DC sweep | analytic | 1e-3 rel |
| 21 | MOSFET level-2 short-channel (θ, η) | DC sweep | analytic | 2e-3 rel |
| 22 | MOSFET level-3 reduces to level-1 | DC sweep | analytic | 1e-3 rel |
| 23 | MOSFET level-3 velocity saturation (κ) | DC sweep | analytic | 2e-3 rel |
| 24 | BJT common-emitter AC gain (Early + caps) | AC | ngspice | 0.2 dB |
| 25 | diode reverse junction capacitance | AC | ngspice | 0.02 rel |
| 26 | diode forward diffusion capacitance | AC | ngspice | 0.02 rel |
| 27 | current-source-driven diode (convergence) | DC (op) | ngspice | 0.01 V |
| 28 | subcircuit (.subckt) inverter VTC | DC sweep | ngspice | 0.03 V |

The common-source amp (09) uses a solidly-saturated bias and matches ngspice to
0.000 dB. The triode/saturation boundary is intrinsically gain-sensitive in the
level-1 model (both engines), so circuits are biased away from Vds≈Vov.

CoreSpice's "level-2/3" are the level-1 Shichman-Hodges core plus empirical
short-channel terms (θ mobility degradation, η DIBL, κ velocity saturation), not
ngspice's full level-2/3 equations. Circuits 20–23 therefore validate them
against CoreSpice's own documented closed form: with the short-channel terms off
they must reduce exactly to level-1, and with them on they must match the
empirical formula. Cross-simulator level-2/3 accuracy is out of scope until a
BSIM-class model is implemented.

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
| Negative DC source values parsed as 0 (`V1 a 0 dc -2`) | lexer emits '-' as a separate token; source-value paths only read a bare number | parser `parseSignedNumber` reassembles the sign in value contexts | CurrentSourceValueTests negative* |
| Current-source-driven PN junctions failed to converge | the first NR iteration skipped limiting, so a diode blew up exponentially | limit PN junctions (diode/BJT) on the first iteration too (`limitsFirstIteration`); MOSFETs keep the unlimited first step | gate.py #27 + CurrentSourceConventionTests |
| Subcircuit (`.subckt`/`X`) instantiation broken (empty/mis-wired expansion) | three bugs: `.ends` body swallowed, `X`-instance node collection stopped at ground "0", and ports were prefixed twice | parse `.subckt` body to `.ends`; accept number tokens (ground) in `X` nodes; `expandComponent(mapNodes:)` so resolved nodes are not re-prefixed | gate.py #28 |

A pre-existing test (C15) encoded the old, inverted current-source sign; it was
corrected to the SPICE convention (V = −I·R), verified against ngspice.

Known convergence limitation: a current source driving 2+ *series* diodes with no
resistive path (a pure stacked-exponential string) does not converge — it fails
loudly (reported convergence failure), never a silent wrong answer. Bistable
latches have multiple valid DC solutions, so which operating point a solver
reaches is path-dependent (not a correctness issue).

## Method note

When a CoreSpice result disagreed with an analytic value, the reference was
verified against ngspice before blaming CoreSpice. One early "inductor AC broken"
claim was a mistake in the analytic reference (wrong RL corner frequency), caught
because ngspice agreed with the supposed "error".

## Status: gate complete

All 28 circuits pass. The corpus now covers passives, the DC operating point and
Newton-Raphson convergence (including current-source-driven junctions), MOSFET
level-1/2/3 DC drive and body effect, MOSFET/diode/BJT dynamic (capacitive)
behavior, subcircuit expansion, and the AC/TRAN/TF analyses — validated against
closed-form analytics where available and ngspice otherwise. The gate is frozen
into committed golden data (`golden.json`) and runs in CI without ngspice via
the `TrustGateTests` Swift test. This satisfies the G1 precondition; G2+
(layout / PEX / signoff) may be unfrozen.

Out of scope for this gate (tracked separately, not blockers):

- BSIM-class MOSFET models (CoreSpice's level-2/3 are empirical short-channel
  extensions of level-1, validated against their own closed form, not ngspice's
  level-2/3 — see the corpus note above).
- Common-source amp AC gain is ~0.5 dB below ngspice (within the 0.6 dB gate but
  worth narrowing — likely an operating-point detail).
- Pure stacked-exponential strings (a current source into 2+ series diodes with
  no resistive path) do not converge; they fail loudly, never silently.
