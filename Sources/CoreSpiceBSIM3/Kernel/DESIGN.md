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
adapter changes. The original `b3noi.c` StrongInversionNoiseEval and N_DENS
source equations are extracted reproducibly; simulator traversal, frontend
callbacks, noise history and Nintegrate are not compiled.

## Verification and Change Impact

Use the source provenance manifest and adaptation script to compare with the
pinned Berkeley archive. The safe consumer's tests execute these original
physics functions, including NQS, series nodes and integration state.


### Noise equation boundary

The original six `noimod` values select SPICE2 or BSIM3 channel thermal and
flicker equations, including the original modes 5/6 linear/saturation correction.
No mode is substituted. Original `rd`, `rs`, `id`, `1overf` sources are independent;
the total is a sum, not a fifth source. The private host `NevalSrc` primitive
returns `4*k*T*conductance` for THERMNOISE and one for N_GAIN: transfer belongs
to CoreSpiceAnalysis. Host-supplied SI constants are k=1.380649e-23 and
q=1.602176634e-19, consistent with existing CoreSpice device noise. Original
model constants such as 8.62e-5 and smoothed Ssi/Swi branches remain unchanged.
The noise wrapper validates frequency, the BSIM flicker effective length
`leff-2*lintnoi`, and all four densities. It allocates no storage and owns no
mutable global. Only original instance/geometry/OP variables are consumed.

Finite checks also precede the original Ssi/Swi smoothing branch and division by
frequency power. For example noia=-1e308 can produce negative infinity and the
original `T1 > 0` test selects zero; this numerical failure must throw instead
of publishing a zero flicker PSD. Finite original smoothing/limit branches are
unchanged. The guard is an adapter failure check, not a noise coefficient change.
