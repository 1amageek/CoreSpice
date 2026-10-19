# OSDI Circuit Fixtures

## Purpose and Scope

Own actual analytic Verilog-A inputs and exact circuit requests for S3 independent
DC evidence and S4 dynamic analytic controls. Parent: [adapter tests](../DESIGN.md).
No children. Tool and schema authority is the
[independent DC verification design](../../../tools/OSDIDCVerification/DESIGN.md).

## Responsibilities and Boundaries

Supply compact, genuinely compiled analytic models and unchanged-source BSIM
circuit requests which discriminate the production adapter and solver contracts.
The independent oracle owns native execution and numerical reference generation;
the Swift test target owns CoreSpice execution and comparison. A fixture input or
point evaluation alone is not circuit completion evidence.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Adapter tests](../DESIGN.md) | parent | Behavioral verification ownership | Actual DC behavior | Native CPU only |
| [CoreSpice](../../../DESIGN.md) | ancestor | S3 verification ownership | Package integration | Target-local evidence |
| [Independent tool](../../../tools/OSDIDCVerification/DESIGN.md) | used by | Exact schema and direct ABI reference | Fixture compilation/capture | No production mapping reused |
| [OSDI adapter](../../../Sources/CoreSpiceOSDI/DESIGN.md) | verification target | Setup projection and DC stamp | Production numerical path | Every private unknown must participate |

## Architecture

```text
analytic VA + exact circuit/policy request -> pinned full-residual compiler
unchanged selected BSIM image             -> independent C solve
same request + same image                 -> CoreSpice solve
analytic identities + full-vector comparison + C physical residual -> evidence
```

## Contracts and Invariants

| Fixture family | Independent fact and failure discriminated |
|---|---|
| Current-driven linear law | Known voltage and voltage-source branch current detect terminal/source signs and ground handling |
| Mixed collapse on/off instances | Distinct current injections and shared non-ground reference expose alias sums, private-node collisions and preparation reuse |
| Driven auxiliary | Nonzero internal solution exercises physical/internal coupling which zero-auxiliary DC cannot discriminate |
| Voltage-defined flow | A unknown and V equation expose flow mapping and tolerance classification |
| Monotone cubic | Known nonzero root exposes incorrect Newton RHS or Jacobian projection |
| Explicit failed solve | Nonzero unsatisfiable equation or fixed iteration exhaustion must not publish a completed result |
| BSIM n/p forward and reverse | Same generated model checks polarity, terminal mapping and original-source circuit solution |
| BSIM resistive-load drain and series nodes | Unconstrained drain and internal voltage drops must be solved, not copied from external bias |
| BSIM free self-heating | Thermal rise K and balance W must be solved with the electrical circuit |

Circuit and per-unit numerical policies are explicit and frozen before any capture.
Analytic source equations, their independently derived values and their request
parameters stay together. The real BSIM source/image is caller-provided and
hash-pinned by the tool design; no model equations are edited or recreated here.
Source conditions include exact Kelvin and typed parameter scope. Fixture results
retain every internal unknown and every source branch current. Ground/collapse and
ordinary auxiliary coordinates do not erase unit, ownership or residual checks.
Library IDs select exact artifact records, even when independent model releases
share one descriptor name. The adapter circuit test loads the selected record
directly and checks the prepared artifact identity; descriptor-name lookup cannot
substitute another release.

The genuinely compiled `dynamic_rc.va`, `dynamic_context.va`,
`dynamic_flow_thermal.va` and `dynamic_latch.va` inputs implement the analytic
controls defined by the
[independent dynamic contract](../../../tools/OSDIDCVerification/DESIGN.md#s4-independent-dynamic-qualification).
That design owns analysis flags, initialization/history, candidate replay and
numerical acceptance. The
[family capture design](../../../tools/OSDIModelQualification/DESIGN.md#retained-s4-dynamic-evidence)
owns the frozen dynamic matrix and retained behavioral evidence.

## Failure, Concurrency, and Constraints

One generated fixture set is immutable after capture and can be read by concurrent
tests. Mutable native instances belong to each solver invocation. Fixture builds
and subprocesses use the independent tool's bounded policy; no global mutable
fixture path or implicit artifact discovery is used.

## Verification and Change Impact

The tool checks analytic exact values before publishing references. Swift tests
compare complete semantic coordinates and independently re-evaluate returned
CoreSpice states through validate mode. Expected failed solves require a typed
failure and absence of completed output. A fixture source/request/policy or any
compiler/header/model identity change requires fresh capture. Tests must not hide
an invalid reference by accepting its process exit alone or altering tolerances.
