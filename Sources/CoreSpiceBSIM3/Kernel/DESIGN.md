# Berkeley BSIM3 Physics

## Purpose and Scope

This directory contains the original parameter tables, defaults, temperature,
current, charge and AC equations plus private compatibility headers. Parent:
[CoreSpiceBSIM3](../DESIGN.md).

## Responsibilities and Boundaries

Berkeley equations own physical preprocessing and analytic derivatives. The
adapter owns bounded storage, context-local diagnostics, exact-bias evaluation
and integration coefficients; the outer solver owns voltage limiting.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [C target](../DESIGN.md) | parent | Context-local ABI | Physics consumer | No standalone SPICE3 simulator |

## Architecture

`b3mpar/b3par → b3set → b3temp/b3check → b3ld → b3acld` runs on one embedded
model and instance. Private headers satisfy only the dependencies of this path.

## Contracts and Invariants

Original tables and source version strings are const. No mutable file-scope
state exists. Geometry allocation is redirected into the handle's single zeroed
geometry block. Original check logging is redirected into its bounded context;
duplicate console logging is removed. Original fatal format arguments are
reordered to name the instance and model correctly. Exported symbols carry a
CoreSpice BSIM3 prefix; no generic SPICE simulator integration symbol leaks. Original load evaluates exact supplied
bias; identity voltage-limit hooks do not run an inner Newton solver. One
misparenthesized original convergence comparison is corrected without changing
the intended comparison. The CTM stable `VdseffCV = VdsatCV * T4`
body derivative omitted the `T4 = 1 - T3` factor: its original
`dT0_dVb * (1 - T5) + T5 * dT1_dVb` is corrected to
`dT0_dVb * (T4 - T5) + T5 * dT1_dVb`, matching the product/chain rule
and the adjacent gate derivative. This changes the analytic derivative only;
physical current and charge equations remain the original model. Trailing source whitespace is normalized during reproducible adaptation. Finite
differences reject the original expression for both polarities at body-forward
and reverse-drain biases. All equation changes are confined to those documented
adapter changes; noise and unrelated simulator entrypoints are not compiled.

## Verification and Change Impact

Use the source provenance manifest and adaptation script to compare with the
pinned Berkeley archive. The safe consumer's tests execute these original
physics functions, including NQS, series nodes and integration state.
