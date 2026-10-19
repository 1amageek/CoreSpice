# CLI Execution Policy

## Purpose and Scope

Own finite CLI resource admission and explicit caller-selected overrides. Parent:
[CoreSpiceCLI](../DESIGN.md). No children.

## Responsibilities and Boundaries

Validate `--execution-profile <JSON>`, bind its exact input bytes, construct the
existing execution policy, and retain one invocation resource owner. Source
`.options` continues to own numerical work, dimensions and tolerances. The caller
profile changes resource admission, not electrical or model semantics.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CLI](../DESIGN.md) | parent | Batch and prepared completion | Explicit caller admission | Developer defaults remain unchanged |
| [Native execution](../../CoreSpice/NativeExecution/DESIGN.md) | depends on | Native limits and same-owner capacity | Runtime admission | No implicit capacity increase |

## Architecture

```text
64 KiB checked profile read -> closed typed validation + exact artifact reference
 -> existing CLI policy + one shared resource owner
 -> resource-aware local capture and contextual parseProfile / lowering / Native execution
 -> completion JSON retains exact validated profile and input reference
```

## Contracts and Invariants

Schema version 1 requires exactly `schemaVersion`, `maximumElements`,
`maximumNativeAllocationBytes`, `maximumLiveOwnedBytes`, `maximumTemporaryBytes`,
`maximumHashedBytes`, `maximumSourceBytes`, `maximumPreparationWorkUnits`, and
`maximumResolutionRetainedBytes`. Counts and ceilings are positive integers
representable by the consuming Int/UInt64 APIs. Unknown, missing, fractional,
negative, zero, nonfinite and overflowing values fail before execution. Source
bytes and resolution retained bytes must fit their live and temporary owners.
The profile is explicit; no hardware-memory-derived values or larger defaults
are selected. OSDI catalog execution budgets and caller execution profiles are
mutually exclusive. All profile-selected source/preparation operations share
one resource owner; later scalar sessions do not reset cumulative work.

The element ceiling feeds the existing parser/transform/resolver/native-device
limits. The source ceiling bounds aggregate captured source bytes and prepared
source reads. The profile work ceiling bounds source/resolution/preparation work;
source numerical options remain authoritative. Completed batch and prepared
records persist the exact validated profile and its exact content reference.
Historical records omit both fields and remain absent on reload. Decoders reject
partial profile/reference pairs and invalid saved profiles. These values are
execution provenance, not solver or physical configuration identities.

## State, Ownership, and Lifecycle

The immutable policy retains the existing Mutex-backed SPICESimulationResources
owner. Captured input reservations live through their execution. Resource callbacks
remain outside locks. No target-dependent isolation or Sendable change is added.
Profile-selected batch passes that owner into the resource-aware IO loader before
content read, hashing or parsing. Its retained LoadedSPICEDeck owns parse/source
leases through the Session's compiled-source lifetime; it is not reconstructed
from the legacy parser result after unaccounted loading.

| Logical state | Native owner and access | Other targets | Release |
|---|---|---|---|
| Invocation counters | Existing `SPICESimulationResources` Mutex; unified reserve/charge APIs | Host CLI is not qualified on WASM/Embedded; no alternate raw storage | Final reservation owner |
| First frontend resource failure | `CoreSpiceCLIResolutionControl` immutable owner with one Mutex retaining the original cause and its translated MOS failure; record/read under the same lock | Same unconditional storage and Sendable declaration | Resolution-control lifetime |

Resource calls and error publication execute outside the failure-record lock.

## Failure, Concurrency, and Constraints

LocalSPICESourceReader bounds the profile file to 64 KiB before JSON decoding.
Typed profile validation errors distinguish malformed input and conflicting policy;
existing source/resource/native errors retain their original failure paths.
The typed MOS callback cannot throw host resource errors. Its control retains
the first original resource refusal behind Mutex; the host compile/evaluation
boundary wraps a matching MOS failure with that cause. Temperature bootstrap and
diode resolution retain their domain diagnostic categories and source coordinates
when wrapping the translated MOS failure. Diode diagnostic reservations remain
owned by the returned error. A recorded cause is attached only when the returned
failure contains the same translated MOS failure; unrelated domain failures and
existing resource causes remain unchanged. Cumulative capacity-byte work
refusal remains `invocation.work-limit`, rather than claiming the retained-byte
ceiling was exceeded. This does not change the MOS protocol or its own limits.

## Verification and Change Impact

CLI tests own closed JSON validation, default preservation, policy conflicts,
source and element refusal, actual batch/prepared execution above the developer
element ceiling, saved/reloaded exact values/reference, and cumulative owner
identity. Native and Analysis tests continue to own numerical semantics.

`ResolutionResourceCauseTests` selects actual temperature bootstrap and diode
model-storage admission boundaries with a test-only MOS control. Both forward
real evaluation charges to the existing shared invocation owner, prove original
work-refusal preservation through the actual domain wrappers, and verify diode
diagnostic-lease final release. Ordinary temperature/diode failures and unrelated
raw MOS failures retain their categories with or without an earlier resource
refusal. These focused tests do not assert a whole-process cumulative budget value.
