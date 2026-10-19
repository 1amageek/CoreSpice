# OSDI CLI Qualification Tests

## Purpose and Scope

Parent: [CoreSpice](../../DESIGN.md). Own actual Native/CLI evidence and saved
artifacts. Existing DC, ordinary dynamic and historical precision suites retain
their existing contracts and fixture owners.

## Responsibilities and Boundaries

The dedicated `OSDISoi101PrecisionCLITests` consumes only the explicit
`CORESPICE_OSDI_SOI101_QUALIFICATION` input manifest. It executes four latest SOI
101 n/p PD/DD full compensated schedules through prepared API, fresh Native API,
and actual batch/prepared executable lanes. Historical shared manifest helpers
are unchanged. The [new qualification tool](../../tools/OSDIPrecisionSOIQualification/DESIGN.md)
owns source/profile admission, schedule selection and independent replay.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Released OSDI adoption | Consumer evidence | Host macOS 27 arm64 |
| [Latest SOI tool](../../tools/OSDIPrecisionSOIQualification/DESIGN.md) | depends on | Four frozen inputs and exact new worker | Independent same-candidate replay | No legacy SOI substitution |
| [Signoff process control](../../../SignoffToolSupport/DESIGN.md) | depends on | TimedProcessRunner, control, typed failure and cleanup handle | Bounded actual CLI process tree | Failed cleanup retains its owner |
| [Native execution](../../Sources/CoreSpice/NativeExecution/DESIGN.md) | verification target | Prepare, execute, cancellation and close | Real public API | Completed execution must release foreign owners |

## Architecture

```text
frozen case -> capacity-admitted catalog -> prepared API -> direct Native rerun
                                  -> batch executable / prepared executable
                                  -> strict JSON + paired CSV + exact comparison
```

## Contracts and Invariants

All rows, paired coordinates, accepted steps, source/model/program/worker/profile
bindings and original policy survive persistence. Original stop and tolerances
are checked against input, not inferred from successful output. A pre-cancelled
run and exhausted worker budget cannot publish completion. Fresh execution after
refusal cannot silently select ordinary arithmetic. The source/model identities
remain available after workers close, and each Native rerun prepares fresh owners.
Each invocation admits the same frozen source and catalog through the public
`SPICESimulationPreparer` with a new resource accountant under the same CLI
policy. A completed output and its precision evidence retain invocation storage
reservations; they are not reused as the accountant for another run. The first
prepared-API owner ends before the direct Native lane, and comparisons retain
only strictly reloaded immutable evidence. Cancellation and the post-failure
rerun also acquire independent invocation owners without increasing ceilings.

The explicitly filtered `remainingNDD` and `remainingPDD` methods may consume
`CORESPICE_OSDI_SOI101_API_WITNESS`, a root-frozen
`corespice.soi101.api-witness.v1` receipt created after both API records completed.
It binds the exact input and precision manifests, original test bundle, execution
helper and public-graph source receipt, plus each selected catalog, prepared/API
JSON, paired CSV, configuration/source identities and Native limit scalars.
All bytes are hash/size checked before catalog loading or kernel/CLI work. Both
strictly decoded records pass the existing full checks, candidate/configuration
comparison and paired-CSV checks against the current frozen inputs. Continuation
does not recreate the catalog or overwrite completed API artifacts. It executes
the existing cancellation, batch/prepared CLI, exhausted-worker and fresh Native
release checks. Default full methods always execute both API lanes.

## Failure, Concurrency, and Constraints

The SOI suite is serialized and each case is separately filterable. Original full
methods retain an explicit 20-minute Swift Testing limit. The suite ceiling and
explicit continuation limit are 24 minutes, so inherited limits cannot shorten
continuation to 20 minutes. This changes only qualification granularity and its
deadline, not circuit conditions, numerical/storage/work ceilings or per-child
timeouts. CLI children use SignoffToolSupport process-group execution with the caller's
positive timeout and the fixture's evidence-byte ceiling. Failures retain raw
stdout/stderr and the typed primary cause. A bounded cleanup retry either closes
the owner or propagates the still-owned handle with the retry failure; failed
log persistence retains that primary failure. Output directories are fresh and retained.
Mutable test state is local; no process-global environment mutation is introduced.
After all builds finish, distinct cases may run in separate processes against an
immutable test bundle. Each process owns one fresh case directory and resources;
they share only read-only model/program/worker inputs and the production CLI.
The outer verification owner must stop all owned descendant groups on timeout,
including helpers and workers that create a new session, and reject stale children.
The continuation methods alone have a 24-minute limit: current full DD lanes
measure approximately 350 seconds each, leaving three full computations after
the two frozen API computations. Numerical/resource policies are unchanged.
The cheap mutated-witness-digest test refuses before any kernel or child starts.

## Verification and Change Impact

Root verifies all four complete workflows using explicitly filtered full or
prerequisite-bound continuation methods. The independent tool replays every
accepted F/DeltaQ/h equation at the saved high/low candidate. Source/profile,
parameters, stop, policy or runtime changes invalidate affected evidence.

The composite CLI suite owns ordinary four-family DC/AC sensitivity case publication:
outer batch and nested prepared completion must strictly reload, source completion
bytes must equal the published artifact, and metric semantics bind both derivation
and source-completion identities. Missing nested completion, changed content/hash,
and altered source joins must be rejected. Actual typed child parameter receipts
and physical finite differences are checked against the selected baseline.

### Measured Ordinary SOI Sensitivity Admission

The ordinary `soi101-n-dd-hot-series-thermal` DC/AC sensitivity fixture owns an
explicit version1 execution profile with a 144 MiB live-owned ceiling. The exact
profile bytes are an input artifact, and the saved batch must retain that profile
and its reference. Native allocation, temporary storage, hashed bytes, source
bytes, preparation work, resolution storage and element ceilings retain the
developer defaults. Other composite model fixtures retain the default profile.

| Measured boundary | Bytes | Fixture guarantee |
|---|---:|---|
| Default live ceiling | 134217728 | Typed storage refusal publishes no case or CSV |
| Refused current live plus request | 134174134 + 353495 | The complete input exceeds default admission |
| Full DC/AC peak live | 137357646 | All supplied parameter children and saved facts retained |
| Full DC/AC peak temporary | 55141420 | Existing 64 MiB temporary ceiling retained |
| Selected explicit live ceiling | 150994944 | Measured workload completes with bounded headroom |

The root-owned `soi-metadata-storage-diagnostic` and
`soi-peak-profile-diagnostic` receipts under
`.verification/production-release-20261018` own those measurements. This is an
operational fixture choice based on the actual complete workload. It changes no
production default, source/model conditions, child count or numerical tolerance.
The success path strictly reloads the batch and complete source evidence and
reloads every CSV coordinate and value at the existing display precision. The
default refusal regression uses the same original ordinary batch publication
path, without an execution profile override.
