# Output-Referred Device Noise

## Purpose and Scope

This component owns the typed transfer-gain boundary for device noise whose
correlated sources cannot be represented by independent current PSDs.
Parent: [Devices](../DESIGN.md). It owns no device physics or network solver.

## Responsibilities and Boundaries

Analysis computes complex transfer from a unit current injected at each requested
physical/owned node to its differential output. Devices consume those immutable
gains and return stable named output-referred channels in V²/Hz. Gains are V/A;
ground gain is exactly zero. Unknown nodes, nonfinite gains or negative/nonfinite
PSD are failures, never default zero. The original independent NoisyDevice
contract remains separate; a device is accumulated through one path only.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Devices](../DESIGN.md) | parent | BoundDevice | Noise owner boundary | No solver types cross into device values |
| [Analysis](../../CoreSpiceAnalysis/DESIGN.md) | used by | Original complex AC transfer | Creates all requested gains | Same factorization at each frequency |

## Architecture

`requested nodes -> Analysis LU unit injections -> immutable complex gains -> device spectrum -> named V²/Hz channels`

## Contracts and Invariants

OutputReferredNoisyDevice declares stable required nodes and provides a throwing
spectrum requirement. NoiseTransferGains owns finite values and rejects missing
non-ground lookup. Channels have stable unique names across the sweep. No callback
or borrow escapes; neither the evaluator lock nor the gain values retain a solver.
A device returning output PSD must not also be accumulated as independent PSD.

## State, Ownership, and Lifecycle

All values are immutable Sendable owners. Analysis owns per-frequency gains and
reuses its factorization and solve buffers. There is no shared mutable state in
this component, and no Native/WASM/Embedded synchronization branch.

## Failure, Concurrency, and Constraints

Invalid requested nodes and unknown/nonfinite gain values are typed errors.
Shared node transfer is solved once per frequency. Requested-node capacity follows
the prepared circuit. No native BSIM implementation or fixed BSIM slot count
remains in this boundary.

## Verification and Change Impact

Analysis noise regressions own complex transfer, malformed gain and independent
source behavior. Native BSIM-specific noise tests are removed with those devices;
OSDI noise qualification remains with its separate adapter owner.
Host CPU runtime evidence does not qualify WASM/Embedded or Metal.
