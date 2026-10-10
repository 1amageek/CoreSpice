# CoreSpiceBSIM3

## Purpose and Scope

This C target privately isolates official Berkeley BSIM3 3.3.0 equations. Its
package parent is [CoreSpice](../../DESIGN.md); its implementation child is
[Kernel](Kernel/DESIGN.md). Its safe consumer is
[BSIM3Evaluator](../CoreSpiceCompactModels/BSIM3/DESIGN.md).

## Responsibilities and Boundaries

The target owns the fixed ABI and context-local SPICE compatibility adapter.
It does not include a simulator, solver, process backend, or public canonical
SPICE3 structures. The ABI requires exclusive caller access to each handle.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [CoreSpice](../../DESIGN.md) | parent | Compact-model ownership | Target composition | CPU evidence only |
| [Kernel](Kernel/DESIGN.md) | child | Original model physics | Private compatibility context | Preserve Berkeley terms and upstream provenance |
| [BSIM3Evaluator](../CoreSpiceCompactModels/BSIM3/DESIGN.md) | used by | Exclusive lifetime / safe inputs | Exclusive construction; Mutex serializes published access | No pointer escapes the safe wrapper |

## Architecture

`CSBSIM3Handle` embeds the original model, one instance, geometry, local complex
matrix, diagnostic buffer and all history arrays. The exported header contains
only fixed value structs, opaque handles and status codes.

## Contracts and Invariants

Creation/configuration/setup precede evaluation. Preparation is attempted once;
rejected partial setup cannot be reused. Partial initialization is
always destructible. The noise ABI returns four fixed owned doubles, uses the
same exact-bias DC/small-signal OP, and never imports simulator noise history.
Inputs and outputs are finite-checked. A failure invalidates
the trial but preserves accepted state. Every original parameter-check branch
runs regardless of filesystem permissions. Original warnings are captured
without emitting stdout, stderr or a fixed log file.

## Verification and Change Impact

The Swift behavioral suite exercises the real ABI. The original-file manifest
and adaptation script permit review of changes against the release archive.
Sanitizer cold lifecycle and history probes supplement Swift runtime evidence.


## Exact Owner Allocation Query

Status: approved S3 ABI addition; existing allocation/lifetime behavior is the
implementation premise. `size_t cs_bsim3_owner_size(void)` returns
`sizeof(CSBSIM3Handle)` in the same compiled adapter as create/destroy. It
requires no handle, performs no allocation or mutation, and exposes no private
structure. It is the exact byte count requested by the single owner calloc, not
an estimate inferred from public topology or a claim about allocator metadata.

The count includes every embedded model, instance, geometry, diagnostic buffer,
matrix and history block. Setup's redirected geometry allocation borrows embedded
storage; it adds no owner heap allocation. Create failure retains no allocation;
all partial preparation states remain destructible, and successful create requires
exactly one serialized destroy. The safe Swift consumer converts the query to
its checked UInt64 storage vocabulary before allocation/admission. Swift object,
parameter transformation and copied diagnostic storage are separate upper-layer
budgets, so no embedded block is counted twice.

ABI validation must compile/link/call the actual query, check it against the same
private handle sizeof in a C-owned fixture, and run create/failure/destroy lifetime
checks. Changing the embedded handle changes the returned count automatically and
requires safe-evaluator and Devices budget revalidation. The query changes no
model equations, parameter tables, setup work, noise or history semantics.
