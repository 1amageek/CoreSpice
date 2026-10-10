# MOS Preparation Contracts

## Purpose and Scope

Parent: [MOS contracts](../DESIGN.md). This portable component owns explicit
preparation inputs, conditions, identity, topology, limits and typed failures.
No children. Device physics and numerical state belong to Devices.

## Responsibilities and Boundaries

A preparation input retains one checked immutable resolution and one complete
condition value. Preparation identity retains that same resolution, schema,
conditions and preparation implementation identity. It is process-local semantic
identity; persistent artifact encoders must frame exact captured source identities.
No model lookup, expression evaluation, dimension rescaling or release substitution
is permitted at this boundary.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Values](../Values/DESIGN.md) | depends on | ResolvedMOSInstance | Sole model and supplied-value authority | Missing dimensions remain absent |
| [Schema](../Schema/DESIGN.md) | depends on | Exact release/schema | Shared input meaning | Inspectable 4.5 is not executable |
| [Devices preparation](../../CoreSpiceDevices/MOSPreparation/DESIGN.md) | used by | Input/receipt/failure | Owns actual preparation and transfer | No portable C kernel dependency |
| [IR MOS instances](../../CoreSpiceIR/MOSInstances/DESIGN.md) | used by | Resolution/receipt | Stage-tagged circuit data | Compile requires prepared stage |

## Architecture

```text
ResolvedMOSInstance + MOSPreparationConditions -> MOSPreparationInput
input + implementation identity -> MOSPreparationIdentity
identity + exact local-role topology + admitted bytes -> MOSPreparationReceipt
```

## Contracts and Invariants

Conditions explicitly hold ambient and nominal temperatures in Kelvin, requested
analysis capabilities and stress policy. Temperatures are finite and positive.
Capabilities distinguish DC, AC, transient and noise; requested noise is never
inferred from an unrelated configuration. Policy is explicit and part of identity.

`MOSAnalysisCapabilities` is a UInt8 OptionSet with `.dc`, `.ac`, `.transient`
and `.noise`. Conditions use `ambientKelvin`, `nominalKelvin`,
`analysisCapabilities` and positive UInt32 `maximumStressIterations`; the mask
must be nonempty and contain only these four capabilities. Identity stores
`resolved`, `conditions` and a nonempty exact `implementationIdentity` string.
Equality/hash include every resolved semantic field and exclude retained-byte
accounting metadata. No persistent digest is implied.

MOSPreparedTopology holds the exact ordered local slots and their aliases to four
physical ports or private auxiliary slots. Classical MOS uses D/G/S/B. BSIM3 adds
DP/SP/Q roles; BSIM4 adds DP/SP/GP/GM/BP/DB/SB/Q roles. Distinct roles can alias a
single slot only as returned by that exact physical preparation. `localNodeCount` is the maximum non-ground slot, matching existing kernels:
classic is 4, ground is 0, ports D/G/S/B are 1/2/3/4, and private slots are
5...localNodeCount inclusive. `auxiliaryNodeCount` is localNodeCount minus 4.
Each of the eight roles is in 0...localNodeCount; aliases are allowed, and every
private slot must be referenced by at least one role. Consequently the topology
can represent at most eight distinct private slots; this is a representation
bound derived from the role inventory, not a physical-model admission policy.

Limits bound retained bytes, temporary bytes, diagnostic bytes and preparation
work, with explicit positive UInt64 `maximumRetainedBytes`,
`maximumTemporaryBytes`, `maximumDiagnosticBytes` and `maximumWorkUnits`.
Caller controls provide `checkCancellation()` and `chargeWork(units:)` as protocol
requirements throwing `MOSPreparationFailure`. Failures distinguish unsupported release/schema/instance semantics,
invalid coefficients, conditions/topology mismatch, capacity, cancellation and
binding rejection. No successful receipt is constructed before actual preparation. Its package-only
checked constructor requires identity, topology, actual retained/peak-temporary
metrics, `coldSetupCount == 1` and limits. Retained bytes must be nonzero and both
reported metrics must satisfy their ceilings. Devices owns complete accounting
and the evidence of one actual cold setup; the portable receipt does not repeat
kernel allocation or reinterpret those metrics.

## State, Ownership, and Lifecycle

All stored contract values are immutable Sendable values. The receipt can be copied
for inspection. It does not contain or authorize use of a mutable numerical owner.
The noncopyable device owner is defined by Devices and consumed by binding once.

## Failure, Concurrency, and Constraints

Invalid condition/limit/topology/identity/receipt construction throws typed
`MOSPreparationFailure`. `MOSBindingFailure` separately represents receipt,
identity, conditions, topology, node/matrix, terminal-IC and cancellation rejection.
Portable contracts never wrap a binding failure as successful preparation. BSIM4.5 must
be rejected before numerical allocation. A preparation implementation records its
actual retained and peak temporary payload according to its documented metric.
Controls are called before expensive work and before receipt publication; a failed
operation publishes neither partial topology nor an executable owner.

## Verification and Change Impact

CoreSpiceMOSContractsTests owns condition, identity and malformed topology failures.
Devices tests own actual exact-release preparation, owner transfer and cancellation.
Native/WASM/Embedded runtime probes verify these portable values. Changes require
rechecking IR, Devices and native execution composition assumptions.
