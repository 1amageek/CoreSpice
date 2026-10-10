# MOS Selection and Normalization

## Purpose and Scope

Parent: [Resolution](../DESIGN.md). This component owns checked MOS resolution,
normalization and independent inspection. It does not evaluate expression trees,
parse text or prepare numerical devices. No children.

## Responsibilities and Boundaries

`resolveMOS` is a concrete free algorithm with an injected schema provider. It
consumes the immutable declaration snapshot and Evaluation's exclusive session.
The session alone owns invocation lookup, memoization, random state, cumulative
work, temporary/cache capacity and terminal diagnostics. Selection cannot replace
those mechanisms or search model names after publishing the resolved result.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Evaluation](../Evaluation/DESIGN.md) | coordinates with | Collaborator contract | Shared evaluation and budgets | Failures poison the session |
| [Declarations](../Declarations/DESIGN.md) | depends on | Ordered exact/family ranges | Source and lexical ownership | Candidate slices remain borrowed |
| [Schema](../../CoreSpiceMOSContracts/Schema/DESIGN.md) | depends on | Exact releases, aliases and scale | Single parameter authority | Schema is checked on every resolve |
| [Values](../../CoreSpiceMOSContracts/Values/DESIGN.md) | depends on | Geometry and candidate bounds | Independent inspection evidence | Identity token checked before dereference |

## Architecture

```text
request + snapshot -> nearest lexical owner -> exact / family range
         session -> raw instance slots + active model slots (one evaluation)
         schema  -> exact release + canonical setters + SI normalization
                    -> checked result + evaluated bounds
result + matching snapshot -> inspection (no evaluator or PRNG)
```

## Contracts and Invariants

Nearest ownership is established before geometric matching. At each lexical scope
an exact match has priority over its dot-digit family. A nearer family that cannot
match prevents parent and sibling fallback. Families require explicitly supplied
L and W; exact models preserve omitted dimensions as absent.

| Rule | coreStrictV1 | pinnedNgspiceNormalV1 |
|---|---|---|
| Same-name model cards | duplicate error | first source card, later expressions never evaluated |
| Distinct bins | all visited; multiple current matches ambiguous | reverse first-registration order, first match |
| Bounds | inclusive endpoints, no tolerance | endpoint absolute difference below 1e-9 meters or interior |
| Missing bound | invalid declaration | exclude with retained reason |
| Invalid/inverted visited bounds | typed failure | typed failure |
| Selection width | full normalized drawn width | full width; explicit global flag uses raw W/NF then scale |
| Missing BSIM version | reject | 3.3.0 / 4.8.3 with default origin |

Explicit classic levels retain `explicitLevel`; an omitted level defaults to L1.
Exact version strings never prefix-match or substitute an executable release.
BSIM4 4.5 resolution/inspection succeeds independently of preparation admission.
All visited active-card assignments evaluate in source order. Strict rejects
canonical alias collisions; pinned evaluates each then keeps the last assignment.
The resulting model/instance buffer has one winning raw SymbolID/value per schema
canonical setter group. Original spelling survives; no snapshot re-interning or
multiple alias application occurs. Later discarded model cards never evaluate.

Supplied instance expressions are cached as raw values by complete request identity.
Model caches hold unscaled canonical winners by declaration-owning invocation and
profile. Schema identity/release and parameter roles/kinds are checked on every
resolve before cache reuse. Model coefficients, bounds and BINUNIT are unscaled.
Instance dimensions use only the schema's exact scale rules. NF is real >=1;
multiplicity remains separate. Overflow, nonfinite values and positive-to-zero
conversion fail. Raw, SI and selection geometries are distinct values.

Visited candidate evidence retains evaluated optional LMIN/LMAX/WMIN/WMAX and its
missing-field mask. Selected coefficient bounds and selection evidence share the
same evaluated slots. Exact candidates have no evaluated bin bounds. Inspection
first checks snapshot identity, then source/owner/release/schema/rules and the held
bounds/geometry against the recorded policy and visit order. It never evaluates
an expression or consumes a random draw.

## Runtime Flows

beginRequest -> raw cache/evaluation -> owner/range -> per-visited release/schema
-> model cache/evaluation -> candidate bounds/normalization -> checked result.
Any failure poisons the session with the active instance, geometry and candidate
attempt. A subsequent call cannot retry or consume more randomness.

## State, Ownership, and Lifecycle

Candidate ranges borrow immutable snapshot indices. Temporary arrays/dictionaries
and canonical-name text reference charges are reserved through the session and
released exactly once on success or failure. Cached buffers have independent
immutable retention charges. Result evidence owns only visited candidates; pinned
stops at its first match and does not fabricate unvisited evaluations.

## Failure, Concurrency, and Constraints

Candidate count, scope traversal, schema/name visits, comparisons, source-order
assignments and all temporary growth use the same cumulative session limits.
There is no truncated successful search. Inspection has explicit limits and an
optional cancellation controller, and checks the identity token before any ID
lookup. Its return summary retains only checked declaration metadata/evidence.
Native, WASM and Embedded share the same synchronous implementation.

## Verification and Change Impact

MOSSelectionTests owns lexical isolation, exact priority, duplicates, strict and
pinned boundaries/visited failures, source-order aliases and one-evaluation slots.
MOSNormalizationTests owns scaling, omitted dimensions, NF/full-device width,
roles and exact release/default origins. MOSInspectionTests owns wrong-token
refusal and independent held-bound inspection without evaluation. Evaluation tests
own evaluator semantics and the shared PRNG/cache. Root owns actual build/runtime
verification and the coherent commit; these tests do not prove MOS physics.

Resolved values retain the original checked geometry scale. Inspection repeats the
original divide-before-scale per-finger operation with that value, never an inverse
ratio reconstructed from rounded normalized values. Subnormal values therefore
preserve the resolver's exact accepted rounding boundary.
