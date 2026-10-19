# Compensated DC

## Purpose and Scope

This component owns DC coordinate precision selection, complete device-owned
original-equation composition, and the final unregularized certificate.
Parent: [CoreSpiceAnalysis](../DESIGN.md). There are no child components.

## Responsibilities and Boundaries

DCAnalysis owns recovery sequencing and accepted-state publication. Both binary64
and compensated publication require final zero-Gmin equations; the compensated
path additionally requires the original-law enclosure certificate. Devices own
their admitted static laws and source scaling. This component uses existing
compensated Newton updates and enclosure arithmetic; it introduces no device
physics, solver, or tolerance relaxation. Native execution owns byte reservations
and durable artifacts.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Analysis](../DESIGN.md) | parent | DC lifecycle and immutable results | Analysis composition | Preserve terminal-event and commit ordering |
| [CompensatedTransient](../CompensatedTransient/DESIGN.md) | depends on | Paired Newton solve and original residual enclosure | Reuses the numerical implementation | DC owns its separate recovery and original-equation gate |
| [Devices](../../CoreSpiceDevices/Devices/DESIGN.md) | depends on | DCPhysicalResidualEnclosureContributing | Devices evaluate original equations at complete coordinates | BoundDevice stamps alone do not establish precision capability |
| [NativeExecution](../../CoreSpice/NativeExecution/DESIGN.md) | used by | DCResult high/low values | Invocation and evidence composition | Rounded waveform values are display projections |

## Architecture

```text
precision request + admitted devices
    -> complete capability selection
    -> device original equations + recovery source scale
    -> existing compensated Newton + configured gmin
    -> full-source zero-gmin polish
    -> fresh unregularized row enclosure certificate
    -> paired accepted state / immutable DCResult
```

## Contracts and Invariants

- Automatic selection uses paired coordinates only when every device contributes
  original DC enclosures and neither optics nor a legacy voltage limiter is present.
  Binary64 selection is explicit; a requested unsupported compensated solve fails.
- A caller's explicit row policy remains authoritative. Otherwise electrical node
  rows use V/A tolerances and branch rows use A/V tolerances from ConvergenceConfig.
- Every recovery solve preserves high and low coordinates. Independent sources
  use the same source scale in their stamp and original residual contribution.
- Newton owns gmin terms. Device contributors exclude them. Final publication
  requires full source scale, zero gmin, and a fresh original-equation upper bound
  no greater than each unchanged absolute equation tolerance.
- DCResult validates finite normalized pairs with identical component lengths.
  Existing Double accessors expose high components; compensated accessors and
  scoped borrows expose the complete represented state without rebuilding arrays.

## Runtime Flows

Direct Newton, gmin recovery and source recovery share the selected precision
configuration and caller-owned execution budget. Recovery catches convergence
failures only. The final polish/certificate precedes additional caller validation,
device accepted-state commits, completion finalization and completed publication.

## State, Ownership, and Lifecycle

All coordinate, enclosure and recovery scratch arrays belong to one invocation.
Newton reuses its existing scratch vectors. No per-iteration conversion or
intermediate result publication occurs. DCResult owns retained component arrays;
its scoped borrow does not transfer pointer ownership. There is no shared mutable
state or platform-specific isolation branch in this component.

## Failure, Concurrency, and Constraints

Unsupported requested capability, malformed pairs, invalid rows/radii, original
residual failure, device errors and cancellation propagate explicitly. They do not
become successful rounded values or convergence recovery. The shared budget charges
additional saved low scalars and enclosed residual work; Native composition admits
the additional coordinate and certificate byte capacity before allocation.

## Verification and Change Impact

[CompensatedDCTests](../../../Tests/CoreSpiceAnalysisTests/CompensatedDCTests.swift)
owns actual sub-ULP DC roots, unchanged physical KCL acceptance, default automatic
selection, explicit ordinary selection, unsupported requested capability,
gmin/source recovery coordinate retention, malformed output pairs and failure
publication ordering. Parent integration verifies the Native API/CLI exact result
binding and durable component replay separately. CPU evidence does not qualify
WASM, Embedded or Metal execution.
