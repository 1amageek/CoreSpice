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
| [Schema](../Schema/DESIGN.md) | depends on | Exact release/schema | Shared input meaning | Classical native levels only |
| [Devices preparation](../../CoreSpiceDevices/MOSPreparation/DESIGN.md) | used by | Input/receipt/failure | Owns actual preparation and transfer | No portable C kernel dependency |
| [IR MOS instances](../../CoreSpiceIR/MOSInstances/DESIGN.md) | used by | Resolution/receipt | Stage-tagged circuit data | Compile requires prepared stage |

## Architecture

```text
ResolvedMOSInstance + MOSPreparationConditions -> MOSPreparationInput
input + implementation identity -> MOSPreparationIdentity
identity + fixed classical topology + admitted bytes -> MOSPreparationReceipt
```

## Contracts and Invariants

Conditions explicitly hold ambient and nominal temperatures in Kelvin, requested
analysis capabilities. Temperatures are finite and positive.
Capabilities distinguish DC, AC, transient and noise; requested noise is never
inferred from an unrelated configuration. Every condition is explicit and part of identity.

`MOSAnalysisCapabilities` is a UInt8 OptionSet with `.dc`, `.ac`, `.transient`
and `.noise`. Conditions use `ambientKelvin`, `nominalKelvin`,
`analysisCapabilities`; the mask
must be nonempty and contain only these four capabilities. Identity stores
`resolved`, `conditions` and a nonempty exact `implementationIdentity` string.
Equality/hash include every resolved semantic field and exclude retained-byte
accounting metadata. No persistent digest is implied.

`MOSPreparedTopology` is the fixed classical four-physical-port value. Its public
`init()` is nonthrowing, `localNodeCount` is always 4 and `auxiliaryNodeCount` is
always 0. It has no configurable private nodes, BSIM prime/body/charge roles or
role alias map. Native classical binding requires no owned auxiliary nodes.
The independently prepared OSDI topology is owned by OSDI contracts and is not
represented by this type.

Limits bound retained bytes, temporary bytes, diagnostic bytes and preparation
work, with explicit positive UInt64 `maximumRetainedBytes`,
`maximumTemporaryBytes`, `maximumDiagnosticBytes` and `maximumWorkUnits`.
Caller controls provide `checkCancellation()` and `chargeWork(units:)` as protocol
requirements throwing `MOSPreparationFailure`. Failures distinguish unsupported release/schema/instance semantics,
invalid coefficients, condition mismatch, capacity, cancellation and
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

Invalid condition/limit/identity/receipt construction throws typed
`MOSPreparationFailure`. `MOSBindingFailure` separately represents receipt,
identity, conditions, topology, node/matrix, terminal-IC and cancellation rejection.
Portable contracts never wrap a binding failure as successful preparation.
Legacy native compact models are rejected before numerical allocation. A preparation implementation records its
actual retained and peak temporary payload according to its documented metric.
Controls are called before expensive work and before receipt publication; a failed
operation publishes neither partial topology nor an executable owner.

## Verification and Change Impact

CoreSpiceMOSContractsTests owns condition/identity failures and the fixed classical topology contract.
Devices tests own actual exact-release preparation, owner transfer and cancellation.
Native/WASM/Embedded runtime probes verify these portable values. Changes require
rechecking IR, Devices and native execution composition assumptions.

## D2 Frozen Environment Admission

MOSPreparationIdentity compares a resolved value's non-nil evaluation environment
with ambient/nominal preparation Kelvin words before publishing an identity.
Mismatch is invalidConditions; no kernel owner/setup is created. Accounting
capacities remain separate from semantic identity.


## Classical Native Preparation Boundary
Native MOS preparation supports classical Level 1/2/3 only. Conditions contain
ambient and nominal Kelvin temperatures and requested analysis capabilities;
there is no compact-model stress-iteration field. The legacy native BSIM owner,
parameter selectors and physics are removed. OSDI preparation uses its own
metadata, topology and lifecycle contracts. The fixed four-port topology remains shared classical preparation/receipt
vocabulary; no BSIM topology or executable is retained.
