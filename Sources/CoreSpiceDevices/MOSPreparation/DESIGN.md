# Native Classic MOS Preparation

## Purpose and Scope

This component owns checked native preparation and consuming binding for classic
MOS L1/L2/L3. Parent: [CoreSpiceDevices](../DESIGN.md). It has no children.
Native BSIM3/BSIM4.5/BSIM4.8 evaluators, descriptors, prepared cases, private
node mappings and device implementations are removed. Compact models execute
through the separate OSDI adapter with exact model artifact identity.

## Responsibilities and Boundaries

`NativeMOSDevicePreparer` implements `MOSDevicePreparing` for already checked
classic `ResolvedMOSInstance` inputs. `NativePreparedMOSDevice` has only its
classic case and preserves the existing consuming `PreparedMOSDevice` interface.
It prepares and validates one immutable classic parameter value; it does not
interpret source, select declarations, compile, solve, or qualify a process.
Copyable receipts carry no executable authority.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpiceDevices](../DESIGN.md) | parent | BoundDevice and checked binding | Native composition | Validate before publication |
| [Portable preparation](../../CoreSpiceMOSContracts/Preparation/DESIGN.md) | depends on | Identity, conditions, limits, failure | Exact source identity | Source/schema recognition does not authorize native BSIM execution |
| [IR](../../CoreSpiceIR/DESIGN.md) | depends on | Prepared stage and receipt | Compiler admission | Full receipt equality is required |
| [Classic devices](../Devices/DESIGN.md) | depends on | Parameter validators and stamps | L1/L2/L3 physics | No BSIM fallback |
| [OSDI](../../CoreSpiceOSDI/DESIGN.md) | coordinates with | Exact compiled model adapter | Compact-model migration route | No release reinterpretation or parameter translation here |
| [Native execution](../../CoreSpice/NativeExecution/DESIGN.md) | used by | Consuming prepared owner | Whole-run resources | OSDI and classic owners remain distinct |

## Architecture

```text
checked classic MOS + conditions/limits/control -> NativeMOSDevicePreparer
    -> classic prepared value + receipt -> Compiler -> consuming bind
    -> BoundNMOS/PMOS L1/L2/L3 -> Analysis
source legacy BSIM selection -> frontend refusal / explicit OSDI model migration
```

## Contracts and Invariants

Only L1/L2/L3 exist in the portable native MOS release/schema API and may publish
a native prepared owner. Source legacy BSIM selection is rejected by source
admission before preparation and must migrate explicitly to OSDI; it cannot
become L1/L3 or another release. Registry contains no legacy native BSIM descriptors.
The classic implementation identity is `CoreSpice.NativeMOS.L1-L3.v2`.

Classic supplied M is absent or exactly one; OFF is absent or zero. Supplied
terminal IC remains unsupported, including zero. W/L are not modified to emulate
multiplicity. Existing classic physical equations and temperature/noise behavior
are unchanged. Ambient and nominal temperatures and requested analysis
capabilities remain part of exact preparation identity.

Binding requires full receipt/identity equality, matching conditions, four ports,
no private auxiliary nodes, and every active compiled index/CSR entry. Unqualified
nmos/pmos aliases are allowed only for L1. Qualified names preserve release and
polarity. Failures publish no partial bound device or ownership claim.
`MOSPreparedTopology()` is the fixed classic value: four physical ports and zero
auxiliary nodes. There are no selectable prime/body/gate/charge roles or variable
native compact-model node counts to reconstruct during preparation or binding.

## Runtime Flows

Preparation checks cancellation, admits retained
payload/work, validates existing parameters, then publishes a receipt/value.
Consuming binding checks identity and compiled mapping before constructing the
classic bound device. There is no compact-model projection or foreign cold setup.

## State, Ownership, and Lifecycle

Prepared parameters and receipts are immutable Sendable values. The noncopyable
classic case transfers once into its existing concrete bound device. Existing
classic transient history owners and synchronization are unchanged. This adapter
owns no native compact-model allocation, evaluator pointer or foreign lifetime.

## Failure, Concurrency, and Constraints

Typed MOSPreparationFailure and MOSBindingFailure retain their existing admission,
identity, condition and mapping failures. Classic retained payload and per-parameter
work are checked before publication. Classic preparation creates no projected
parameter dictionary or retained diagnostic array; temporary projection payload
is zero. Cancellation remains on the common control contract for every target.

## Verification and Change Impact

[CoreSpiceMOSPreparationTests](../../../Tests/CoreSpiceMOSPreparationTests)
checks both polarities for L1/L2/L3 physical stamps, aliases, receipt/condition
mismatch, mapping failure, cancellation, strict supplied values and exact retained
capacity. Registry tests require absent legacy entries, preventing fallback. Source owners
verify explicit legacy-source refusal before native preparation. OSDI execution and four-family qualification belong
to the separate OSDI owner. API/IR/Compiler/native composition must revalidate
changes to identity, topology or consuming interfaces.
