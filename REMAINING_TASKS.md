# CoreSpice Remaining Tasks

Updated: 2026-07-26

CoreSpice is complete for its declared native supported-model envelope. The
items below are explicit typed failures on parsed but unsupported native
capabilities; no silent fallback is present.

## Remaining P1 tasks

None.

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
- Behavioral voltage/current devices with canonical expression lowering, scalar
  automatic differentiation, DC/AC/transient and `.func` execution tests,
  typed malformed/non-finite failures, and a release benchmark at 1.43x the
  specialized VCCS stamp on the reviewed machine
- Explicit ngspice compact-model backend with digest-bound capability,
  verified relative-path input staging, external invocation evidence, typed
  seed limitations, live BSIM3 level 49 operating-point correlation, and live
  BSIM4 level 54 operating-region/finite-difference derivative correlation
