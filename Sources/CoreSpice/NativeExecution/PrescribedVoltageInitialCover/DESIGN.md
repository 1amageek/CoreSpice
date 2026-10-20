# Conditional Prescribed-Voltage Initial Cover

## Purpose and Scope

Parent: [NativeExecution](../DESIGN.md). No children. Check a finite cover of all
initial algebraic states in an explicit reduced-coordinate/source domain. The
result is conditional on that domain. Physical model/PVT/history-derived global
initial-set inclusion remains UNPROVED and is not manufactured by this component.

The package-only implementation follows this contract. Qualification is required
before any successful runtime path is treated as complete.

## Responsibilities and Boundaries

Own exact tree coverage, strict actual-H component exclusion, matching of existing
checked initial-root inclusions, explicit unresolved leaves and retained evidence.
Do not search for roots, implement model equations, accept H/J callbacks, construct
a global InitialSetScope or claim source-family/history completeness.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [NativeExecution](../DESIGN.md) | parent | Exclusive preparation/control | Actual owner | No replacement ledger |
| [PrescribedVoltageChart](../PrescribedVoltageChart/DESIGN.md) | depends on | Strong B P Q=0 and checked InitialRoot | Root witnesses | Failed root is not exclusion |
| [PrescribedVoltageValues](../PrescribedVoltageValues/DESIGN.md) | depends on | Complete actual F0/Q and original inventory | Exclusion values | Preserve all guard leaves/aliases |
| [ValidatedParametricRoot](../../../CoreSpiceAnalysis/ValidatedParametricRoot/DESIGN.md) | indirect dependency | Strict Krawczyk inclusion/q<1 | Existing numerical lemma | No domain/global-root authority |
| [RangeExecution](../../../CoreSpiceOSDI/RangeExecution/DESIGN.md) | indirect dependency | Source/setup/domain/cleanup | Actual source conditions | Finite queries do not prove tails |

## Architecture

```text
actual owner + checked strong B/L plane + original D/exact initial context
  + explicit Z0/initial U0 + untrusted split tree
  + actual Values / existing InitialRoot witness references
      -> exact geometry / owner / source / condition checks
      -> excluded | included | unresolved leaves
      -> immutable conditional cover; complete iff unresolved count == 0
upper global initial-set inclusion remains separate
```

## Contracts and Invariants

### Target

The target is the ENTIRE exact endpoint product Z0 times the ENTIRE initial
normalized source product U0, intersected with the actual prescribed-source
constraints and original D. Z endpoints are finite normalized CompensatedValue
pairs in the actual forest reduced order. U endpoints are finite Double values
in the original source laws' normalized ranges. Initial time is the same exact
represented singleton context required by InitialRoot. Actual source device,
rail/time law, program/setup/topology, worker/profile and query conditions retain
the existing lower contracts. No internal, thermal, flow or formal source-current
section is silently removed or given a new ground.

B is a checked strong-null-charge row selector and L its canonical complement.
For a target point d0 IS z_L; a leaf derives its d0 parameter box by projecting
its Z endpoints onto L. No additional initial-coordinate restriction or q0 is
introduced. The target equations are the existing
Hinit=(z_L-d0, B P F0(Az+E phi0)). A root witness may cover larger d0/U ranges,
but must cover every leaf tuple. Actual Q remains the existing post-root query.

### Exact Split Tree

One rooted finite binary tree starts at exactly Z0 times U0. A split uses one
axis and an exact represented point strictly inside its interval. Children keep
all other endpoints and share that SAME split endpoint, so their CLOSED boxes
union to the parent and overlap only on its face. U splits must be representable
by the existing Double source API; no rounded replacement is accepted. Rebuild
child domains rather than trusting caller leaf boxes. Reject cycles, shared or
missing children, unreachable records and missing/duplicate leaf evidence.

Shared faces are not dropped. A face root is accounted for by a matched larger
checked-root box or remains unresolved. Overlapping root certificates do not
imply distinct roots; this operation certifies a covering union, not a root count
or branch-continuation identity.

### Leaf Evidence

| Classification | Required independent check |
|---|---|
| Excluded | Build Hcell from actual Values enclosing the WHOLE leaf image and derived d0 box, summing all original F0 rows through P before B selection. Some finite outward component has lower>0 OR upper<0. Retain the row, enclosure and actual Values/source condition. No differentiability or new solver is needed for this sign theorem. |
| Included | Existing private-init InitialRoot has the same owner/control, source conditions, B/L/order and initial time. WHOLE leaf Z is contained in its retained checkedLower/checkedUpper, and WHOLE leaf d0/U projection in its parameter ranges. Use checked Z, never proposal or clipped Krawczyk image. Its uniqueness then accounts for every root in the leaf. Root-box-subset-leaf is insufficient. |
| Unresolved | No accepted witness. No success/absence claim. Zero touch, root .uncertified, singular Y, unsupported source or an unproved domain lift must not be treated as exclusion. |

Witness domains must cover the leaf, not merely overlap it. Query OriginalD is a
checked subdomain of the declared original D and contains the whole relevant
lift; source/context identity is checked, not inferred from similar scalar
images. A partially escaping lift is never clipped. A finite complete cover
proves only that every target Hinit root belongs to a retained checked-root box.
It does not prove existence for every parameter tuple. An all-excluded target is
empty only by strict component proofs, not by a failed source or root query.

### Package Boundary

The existing prepared owner can expose this package-only operation through an
extension located in this component:

```swift
package borrowing func checkPrescribedVoltageInitialCover(
    structure: NativePrescribedVoltageInitialStructure,
    originalLower: [CompensatedValue], originalUpper: [CompensatedValue],
    initialNormalized: [ClosedRange<Double>],
    proposal: NativePrescribedVoltageInitialCoverProposal,
    limits: NativePrescribedVoltageInitialCoverLimits,
    cancellation: CancellationToken
) throws -> NativePrescribedVoltageInitialCover
```

The proposal contains finite tree topology, exact
splits and typed existing Values/InitialRoot references, never executable proof
callbacks. Limits explicitly bound axes, nodes/depth, witness references and
logical temporary/result bytes. The result is final, immutable and private-init,
retaining original target/source scope, counts, isComplete and indexed or scoped
borrow inspection of leaves. There is no public/global InitialSetScope factory.

### Independent Strong-Plane Access

Current InitialRootAssembly checks strong BQ and full-domain source identities
before Krawczyk, but exposes them only after root success. Values alone does not
prove BQ=0; PreparedNativeCircuit.devices is private. Requiring a successful root
to attest excluded/empty domains is circular.

The minimum shared check produces an immutable internal initial-plane witness containing the same
record/control, Values, B/L/forest mapping and existing checked full-domain source
identities. Factor only the existing strong-BQ/source-binding part out of
InitialRoot; retain its arithmetic, failure order and cumulative control. Both
InitialRoot and the independent Cover witness factory invoke the same checked-plane routine. No arbitrary caller can create it.
The package factory follows the actual prepared-owner path; callers cannot
substitute devices. No model equations or existing root checks are duplicated.

## Runtime Flows

The checker is synchronous and performs no model query. The existing actual-owner
operations first produce Values and InitialRoot witnesses; their source failure
and cleanup behavior is unchanged. Reusing a witness for several leaves requires
each leaf's complete containment check. Explicit unresolved leaves may preserve
unrefined parents; no automatic solver/search is introduced.

## State, Ownership, and Lifecycle

Borrow caller-owned immutable proposals. Admit fixed scratch, result metadata and
witness-reference arrays BEFORE initialization/copy, with checked capacity and
old/new coexistence. Existing Values/root/source/program backing retains its
original leases; no physical duplicate charge is claimed. The immutable result
holds its own metadata lease and all referenced owners until final-copy release.
No Span escapes inspection or crosses await.

All cells share the ORIGINAL mandatory preparation control: no per-cell reset,
work refund or new controller. Traversal scratch is exclusive local state; no
new mutable cache or target-conditional synchronization is introduced.

## Failure, Concurrency, and Constraints

Malformed geometry, foreign owner/source/context/plane and insufficient or forged
witnesses are typed failures. Explicit unresolved leaves are valid partial-cover
evidence. Resource/cancellation failures propagate without publishing a partial
result or manufacturing an unresolved success. Check supplied/Task cancellation
before and after fallible control callbacks and in bounded traversal/copy loops.
No callback runs under a Mutex. Concurrent calls use separate scratch and the
same existing synchronized cumulative control.

## Verification and Change Impact

New disjoint Native pure and actual-source cover test files own the following:

- Separate algebraic branches: one witness cannot hide the other; both branches
  plus excluded remainder close only the explicit finite target. Full parameter
  ranges are preserved, not replaced by midpoint values.
- Root on a shared split face, leaf/checked-root containment direction, omitted
  child/leaf, changed endpoint, shared/cyclic child and duplicate evidence.
- Strict positive/negative actual-H exclusion versus zero touch, failed/singular
  Krawczyk and explicit unresolved. Source, B/L, d0/U, context, OriginalD, owner
  and raw/global inventory mismatch refusal.
- Pre-spent cumulative work, every reservation/cancellation refusal, no partial
  publication, temporary refund, owner reuse and last copied result refund.
- Existing isolated-C initial-coordinate and actual SDK fixtures keep original
  source bytes and execute without skipping. No invented DC/zero-charge rule.

Existing InitialRoot/Chart test bodies and numerical contracts remain unchanged.
The lower factoring requires their affected focused regression once
at the stable boundary. Global initial-set inclusion, continuation and all-history
proof remain separate open obligations even after a complete finite result.
