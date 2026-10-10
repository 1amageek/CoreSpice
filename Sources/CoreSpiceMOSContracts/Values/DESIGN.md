# MOS Contract Values

## Purpose and Scope

Parent: [Contracts](../DESIGN.md). This component owns portable immutable values,
typed failures and invocation work/cancellation requirements. No children.

## Responsibilities and Boundaries

Snapshot-local IDs identify interned symbols, scopes, declarations, programs,
bindings and functions. Expression references use symbols only; the concrete
resolver follows concrete caller ancestry for numeric binding lookup and evaluates
each final binding once per owning invocation. Requests retain supplied instance
expression programs; a checked immutable invocation graph is the sole parameter
environment authority. Explicit invocation actuals can replace or introduce symbols with snapshot
programs or finite constants. Program actuals retain their exact caller identity
for self-reference when a caller exists; root constants support global overrides
without mutating or duplicating the shared snapshot. Resolved results have a
package-only checked constructor.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Schema](../Schema/DESIGN.md) | depends on | Release/schema identities | Validates result identity | BSIM4 4.5 remains inspect-only |
| [Declarations](../../CoreSpiceMOSResolution/Declarations/DESIGN.md) | used by | IDs and expression graph | Immutable indexed snapshot | No borrowed pointer escapes |

## Architecture

```text
source occurrence -> declaration/binding IDs -> expression programs
request(profile, scope instantiation, programs, scale, seed) -> checked result
```

## Contracts and Invariants

Programs count nodes/depth and retain unique symbol dependencies. Their AST is
fully bound to the snapshot symbol table, without interpreting source strings.
Geometry distinguishes raw supplied values, normalized values and selection
dimensions. Missing instance values stay absent. Numeric coefficients and supplied
values must be finite and unique. Results retain selected declaration, exact
release/default origin, schema and candidate/rule evidence. Source identity fields
are opaque caller-provided provenance, never a fabricated digest.

## State, Ownership, and Lifecycle

Arrays and strings use immutable Swift value ownership. The resolver alone owns
the mutable/noncopyable evaluation session and caches. Cancellation/work controls
are protocol requirements so existential calls are valid under Embedded Swift.

## Failure, Concurrency, and Constraints

Explicit limits bound symbols, scopes, declarations, programs, bindings, functions,
AST nodes/depth, candidates, cached entries and evaluation steps. Invalid values,
overflow, missing IDs, unsupported profiles/releases, cycles and cancellation use
MOSResolutionFailure. No default success/fallback is provided.

## Verification and Change Impact

CoreSpiceMOSContractsTests verifies actual constructor failures, AST metadata and
source/result preservation. Resolver and device consumers must revalidate when
these contracts change.

### Snapshot-local identity and coefficient provenance

`MOSIdentitySpace` is an immutable process-local identity token. A snapshot creates
one token; a resolved result shares that exact token. Inspection must compare token
identity before dereferencing declaration/candidate/symbol IDs against a supplied
snapshot. Equal numeric IDs from another snapshot are never interchangeable. The
token retains only identity, not the snapshot; inspection therefore requires a
live shared snapshot owner. No persistent digest or independent source-search
capability is implied.

Coefficient IDs reference accepted original input symbols. Canonical uniqueness
means one setter group, as defined by schema canonicalName, not canonical spelling.
Selection keeps the last winning raw symbol/value for pinned alias assignments;
the immutable snapshot and its source occurrences are not mutated or re-interned.

### Retained payload and construction capacity accounting

`maximumRetainedBytes` counts record strides, encoded UTF-8 text payload per
retained reference, and actual element capacities for Array/Set/Dictionary buffers. Dictionary
capacity counts key/value tuple stride, not bucket metadata. All snapshot tables
and indices, request/result buffers and expression-program buffers use this metric. Shared text/array references are charged
conservatively at each retention boundary. Swift String does not expose storage
capacity; its encoded payload is counted, not its hidden allocation. Allocator
headers, alignment rounding, indirect-enum box headers, owner bookkeeping and
hash-table bucket metadata are outside this payload metric; it is not a physical heap measurement.

Request and checked-result construction require explicit limits before retaining
source or backing arrays. Request equality/hash cover semantic inputs and exclude
retained-byte/capacity admission metadata. Program construction uses an admitted pending stack and
metadata arrays, with no Set or sorting scratch. Requested growth is checked
before `reserveCapacity`; the returned actual capacity is checked before append.
During growth both old and new element capacities count toward the peak. If the
allocator supplies excess capacity that breaches the limit, construction throws
before retention/publication. Heap sort and in-place deduplication retain the
admitted arrays. `retainedBytes`, `peakOwnedBufferBytes` and `workUnits` expose the
counted result, construction peak and work. Program construction within a builder
uses its remaining budget and returns consumed work even on failure.

Composed checked-result construction borrows the evaluation session's work ledger.
Every text byte and validation iteration consumes that same cumulative work and
cancellation contract. Its local transitive payload metric does not re-add shared
snapshot/cache buffers to the session's live storage. New validation scratch is
admitted by the session and released on every exit. Independent constructor tests
provide their own explicit validation ledger; resolution never resets it.

Selected candidate bounds and missing masks are owned by
[Selection](../../CoreSpiceMOSResolution/Selection/DESIGN.md). Classic explicit
level selectors retain explicitLevel origin independently of BSIM version origin.
