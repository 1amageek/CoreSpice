# CoreSpice Remaining Tasks

Updated: 2026-07-26

CoreSpice is complete for its declared native supported-model envelope. The
items below are explicit typed failures on parsed but unsupported native
capabilities; no silent fallback is present.

## Remaining tasks

| ID | Priority | Owner | Task | Exit criteria |
|---|---|---|---|---|
| CSP-1 | P1 | CoreSpice | Implement native lowering and execution for parsed B-sources. Ideal lossless T-lines, uniform-RC, and NMF/PMF MESFET DC/AC/transient execution are complete. | B-sources lower to concrete current- and voltage-output devices, participate in DC/AC/transient analyses, preserve branch ownership, reject malformed or unsupported expressions with typed errors, and have success/failure/numerical correlation tests. |
| CSP-3 | P1 | CoreSpice | Add BSIM3/BSIM4 and other required compact-model execution through a qualified native or explicit external backend. | Model selection is capability-driven, unsupported models cannot be reported as native success, numerical fixtures cover operating regions and derivatives, and foundry production claims still require independent ToolQualification evidence. |

## Source markers

The current `FIXME(INCOMPLETE_IMPLEMENTATION)` marker is authoritative for
callable incomplete branches:

- `Sources/CoreSpiceLowering/SubcircuitExpander.swift`

## External prerequisites

Foundry compact-model production qualification requires a qualified external
simulator or independently qualified native implementation. That decision is
not owned by CoreSpice.

## Evidence reviewed

- `GOAL_STATUS.md`
- `README.md`
- The marked lowering and descriptor implementations
- Native success and typed-failure tests associated with the markers
- SPICE3/ngspice-compatible uniform-RC parser, lowering, and DC/AC/transient tests
- SPICE Curtice NMF/PMF model equations, signed waveform parsing, and DC/AC/transient numerical tests
- Ideal lossless T-line DC/AC equations, bounded interpolating transient history, delay-constrained timestep, and public parse-to-analysis tests
