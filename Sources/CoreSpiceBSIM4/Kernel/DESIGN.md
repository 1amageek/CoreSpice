# Original Berkeley BSIM4 Physics

## Purpose and Scope

This directory owns the original BSIM4 4.8.3 parameter tables, setup, temperature,
current/charge equations and complex AC load. Parent: [C kernel](../DESIGN.md).

## Responsibilities and Boundaries

Original physics is authoritative. Adaptation owns only simulator isolation,
exact-bias evaluation, bounded allocation, diagnostics and symbol names.
No coefficient fit, release substitution or simpler compact-model fallback is
allowed. Noise-spectrum composition is outside this kernel sprint.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [C kernel](../DESIGN.md) | parent | Context ownership and ABI | Embedded simulator storage | Caller serializes all handle access |

## Architecture

`b4mpar/b4par -> b4set -> b4temp/b4check/b4geo -> b4ld -> b4acld`
runs on exactly one context-owned model/instance/geometry.

## Contracts and Invariants

Berkeley's Standard 4.8.3 archive is pinned by SHA-256. The original ECL-2.0
license, NOTICE and copyright notices remain, and adaptations carry explicit
modification notices. `adapt_upstream.py` reproduces every adapted source.
Tables are const and all exported symbols are prefixed. Original global
noise-job inspection becomes an explicit context field. Geometry allocation
and diagnostics are context local. All model checks execute without opening
`bsim4.out`; the original temperature negative-phi branches also contain
uninitialized FILE logging, which is removed while their console diagnostics
and original fatal model checks remain. Diagnostic-capacity failure is explicit. Exact-bias hooks leave
voltage limiting to the outer solver. Current/charge equations and their
analytic derivatives are preserved unless a concrete finite-difference defect
requires a separately documented chain-rule correction.

## Verification and Change Impact

The parent's standalone proof checks the actual original load functions and
rejects derivative, numerical, lifetime and history defects. Reference-source
differences must be documented before comparison; an oracle is not authority
for replacing original physics. Production Level 54 admission requires separate composition proof.

Host `CHARGE` is the SI2019 elementary charge (1.602176634e-19 C); original
hardcoded BSIM constants remain unchanged. The independent oracle records its
host constants and source hashes. Finite-difference residual comparison includes
the standard floating dot-product bound gamma(32) times the sum of absolute
products/RHS, divided by the central-difference denominator; it is derived from
IEEE Double roundoff, never fitted to observed errors.

## Charge Multiplicity Correction

The original archive and original source hashes remain immutable in
`Kernel/upstream.json`. One explicit correctness patch preserves the independent
current law `mult_i * I` and charge law `mult_q * Q`: the body-junction equivalent
RHS must multiply its charge term by mult_q; physical D/S/G-to-NQS-q Jacobian
couplings must also multiply their charge derivatives by mult_q. The original
4.8.3 expressions violate these laws when the factors differ. At constant
initialized bias, dQ/dt=0, but the original body stamp leaves an artificial term
(mult_i - mult_q) * ag0 * C * V. The corrected expressions remove that term and
restore the central finite derivative, without fitting any model coefficient.

The safe evaluator and production binding assume this corrected current/charge
contract. ngspice-46 already contains these corrections and is an independent
corrected implementation oracle for affected settings, not a pristine original
reference. The adaptation manifest records the exact original-to-corrected
expression changes and rationale. Standalone chargeMultiplicity proof covers
both polarities, forward/reverse bias, unequal factors, steady initialized charge,
full-node BE/trapezoidal derivatives including q couplings, and preserved history.
The old 1898-check proof remains evidence only for its unaffected unit-factor
conditions; the new sanitizer and reference run owns affected verification.
