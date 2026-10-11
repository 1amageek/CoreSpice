# BSIM4 4.5.0 Physics and Simulator Adaptation

## Purpose and Scope

Status: original preparation sources implemented; numerical source intake is
proposed and absent. Parent:
[CoreSpiceBSIM45](../DESIGN.md). No children. This component owns exact physical
source intake, original equations and the private simulator ABI adaptation.

## Responsibilities and Boundaries

Import only the nested official 2005-07-29 release. Current 4.8.3 code is useful
for understanding callers, not for reconstructing earlier physics. The external
solver retains limiting, convergence, timestep choice and analysis scheduling.
Source provenance and permitted corrections are part of implementation identity.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Native boundary](../DESIGN.md) | parent | Exclusive opaque context and full local outputs | Kernel composition | All failure paths remain destructible |
| [Research](../../../docs/bsim45-research/RESEARCH.md) | coordinates with | Primary sources and observed counterexamples | Evidence for source selection | Physical file counts are not runtime coverage |
| [4.8.3 physics](../../CoreSpiceBSIM4/Kernel/DESIGN.md) | coordinates with | Adaptation technique only | Separate release | No automatic equation/fix transplantation |
| [Schema](../../CoreSpiceMOSContracts/Schema/DESIGN.md) | coordinates with | Role/kind/scale and correction identity | Typed input boundary | Original SC table has a verified defect |

## Architecture

```text
official zip -> nested BSIM450.tar.Z -> per-file hashes + original notices
 -> deterministic adaptation manifest
 -> b4set + b4temp + b4check + b4geo
 -> b4ld (I, Q, derivatives, transient) / b4acld / b4noi
 -> parent ABI's finite output checks and context-local diagnostics
```

## Contracts and Invariants

- Original model parameter defaults, Given bits, temperature, polarity, BINUNIT,
  per-finger geometry, LOD, WPE and supported selectors remain version-specific.
  Model bounds are resolver selection inputs; physical correction never selects
  a different bin or changes resolved coefficients.
- Compile setup, temperature, geometry, checker, DC/charge, AC and noise from the
  same source manifest. Pin the original constants, units and simulator-service
  semantics; reusing current compatibility constants without comparison is invalid.
- All changes are deterministic transformations with original/adapted hashes and
  a reason classified as symbol isolation, simulator ABI, bounded storage,
  diagnostics, exact-bias evaluation, integration, or explicit defect correction.
  Do not import the unapproved `bugfix_450_new.txt` wholesale.
- Correct `sc` table identity from SCA to the distinct SC selector, consistent
  with Appendix A, Chapter 14 and the original SC setter. Record this as
  `sc-selector-v1`, preserve original source hashes, and verify that scaled SC
  changes well-edge distance while SCA remains unscaled. This is an explicit
  correction, not a claim of bitwise agreement with the defective frontend.
- Original documented/nonfatal parameter regularizations emit bounded diagnostics
  and retain effective values in private prepared storage. Invalid selectors,
  nonfinite values, unsupported parameters and fatal checker conditions fail
  before publication. No silent fallback to a different release, mode or bin.
- The checker cannot depend on successful `fopen("bsim4.out")` to validate inputs.
  Redirect both messages and control flow to context-local failure/diagnostics.
  Preserve every fatal condition even when diagnostic capacity is exhausted.

## Runtime Flows

Preprocessing applies omitted release defaults once, including UD=`1e14`, then
temperature and geometry corrections. Width for physical channels is W/NF;
selection width remains owned by the explicit input profile. Bias-dependent
current and charge use the same local topology and analytic derivatives.
Do not collapse internal nodes or approximate AC NQS using DC capacitances.
NF is a finite real value at least one, not an integer-only count. Omitted exact
model dimensions receive the original 5um L/W defaults only here, never during
family selection. M remains an independent positive frontend parallel multiplier.

Native trial integration uses the existing Analysis method/time step. Preserve
all original junction, gate-mid, intrinsic and q-deficit state contributions;
prepare once, trial many times, advance history only on accepted steps.
Noise preserves original source pairs/correlation and release constants; original
noise service primitives must have a pinned, independently tested implementation.
No external simulator process is part of production execution.

## State, Ownership, and Lifecycle

Every mutable original field, geometry pointer, history buffer and diagnostic
belongs to the parent's single context allocation. Private pointers remain inside
its lifetime. One context represents one model/instance/geometry, so original list
traversal cannot share mutable knots between separate X instances or runs.
Noise scratch and integration scratch cannot overwrite accepted history.

## Failure, Concurrency, and Constraints

Original allocation/free/logging/global task-job queries are adapted explicitly.
Noise intent comes from preparation conditions; immutable topology follows it.
All input sizes, casts, iterations, indexing and diagnostic writes are checked.
The context never holds a borrowed pointer across return. Its parent enforces
exclusive access and generation-bound tokens; no new lock or platform branch
weakens the safe owner's common synchronization contract.

## Verification and Change Impact

Standalone original-source references cover both polarities; all mobility, CAP,
diode, body/gate/series, temperature, WPE/LOD and NQS modes accepted by the release;
representative temperature/body-bias/reverse-operation/geometry limits; and omitted
versus supplied values. Sky130's narrower enabled modes are a separate matrix.
The SC dispatch counterexample in the research record must become a corrected
behavior regression before executable admission. New source defects require a
specific physical counterexample, explicit correction identity and focused tests.

Proposed proof tolerances, fixed before fixture generation: original-reference
current `1e-13 A + 2e-7 relative`, charge `1e-23 C + 2e-7 relative`; derivative
tests use a central-difference step sweep and agreement plateau, with current
Jacobian `1e-10 S + 2e-4 relative` and charge Jacobian
`1e-20 F + 2e-4 relative`. Test all active rows/columns, conservation and aliases.
Reference tolerances are numerical comparison criteria, not foundry accuracy.
AC and transient/numerical analysis thresholds are owned by their integration
tests and must record units, oracle and error norm before execution.
Original-spectrum references use `1e-32 V^2/Hz + 2e-7 relative` per channel for
explicit complex voltage gains, and integrated RMS voltage uses `1e-18 V + 2e-7
relative`. These proposed comparison thresholds start from the existing 4.8.3
proof policy, not a measured 4.5 accuracy claim; changes need a documented numerical
conditioning/error study rather than a passing-test target.

## B45-2 Source Intake

Compile only original parameter tables/setters, setup, temperature/check and
geometry in this unit. The adaptation generator records original/adapted hashes
and rewrites symbol namespaces, simulator services, fixed geometry storage and
context-local diagnostics. Remove file-opening as a guard around fatal checking;
check execution is independent of diagnostic capacity. Preserve formulas and
regularizations. Validate selectors before their original default-reset branches.
The SC selector correction is the sole table-semantic change.

Preparation proof tolerances are `2e-13 relative + 1e-20 absolute` for the
receipt's named SI scalar values; node aliases/counts are exact. They were fixed
before reference generation. The 648-case fixture explicitly supplies AT=0
across temperature modes, avoiding the invalid use of mode-0 default AT with
mode-1/2 temperature semantics. A separate fatal-path case preserves rejection
of that invalid combination. The SC analytical geometry identity is checked
independently of the original erroneous input table.

The original host constants used by preparation and their pinned SPICE3f5
authority are recorded in [NOTICE](../NOTICE.md). Checker diagnostics map to
original file/line sites in upstream.json. All checker control flow executes
when diagnostic capacity is zero; no filesystem state participates.
