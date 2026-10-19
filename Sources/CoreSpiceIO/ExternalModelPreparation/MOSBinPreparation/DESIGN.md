# External MOS Bin Preparation

## Purpose and Scope

This component selects original MOS declarations and normalizes explicitly supplied
source parameters for an explicitly selected external OSDI provider. Parent:
[ExternalModelPreparation](../DESIGN.md). No children. It owns no device physics,
model defaults, native BSIM schema or compiler implementation.

## Responsibilities and Boundaries

Lowering owns the original component, immutable declaration/invocation graph,
nearest lexical exact/family candidates and the sole scalar evaluation session.
The external normalization profile owns source dispatch metadata, candidate order
and bounds policy, aliases, geometry units and provider parameter correspondence.
The admitted foreign descriptor owns setter names, aliases and exact value kinds.
Actual model setup remains required; copied descriptor metadata alone does not
establish a successful external model or foundry qualification.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [ExternalModelPreparation](../DESIGN.md) | parent | Explicit provider composition | Shared preparation entry | No implicit provider |
| [Lowering Frontend](../../../CoreSpiceLowering/Frontend/DESIGN.md) | depends on | ExternalMOSSourceRequest and synchronous evaluator | Original source and sole evaluation owner | No reparsing or second RNG/session |
| [MOS Declarations](../../../CoreSpiceMOSResolution/Declarations/DESIGN.md) | depends on | Snapshot identities, source and lexical candidates | Immutable original declarations | IDs require the same snapshot |
| [OSDI Binding](../../../CoreSpiceOSDIContracts/Binding/DESIGN.md) | depends on | Artifact/descriptor and typed assignments | Exact foreign selection | Model setup checks actual metadata |

## Architecture

```text
original M + checked lexical candidates + immutable snapshot
    -> explicit profile / descriptor parameter binding
    -> source instance evaluation and geometry normalization
    -> candidate metadata and bounds selection
    -> selected source coefficients, exact aliases / Given / typed assignments
    -> OSDIResolvedInstance + source-addressed facts
same Lowering evaluator callback and cumulative work/cancellation owner
same IO resource owner for temporary and retained capacity
```

## Contracts and Invariants

Profiles are caller supplied, immutable values. A caller label is not identity.
The preparer computes a bounded length-framed SHA-256 identity over the label,
artifact, every descriptor/parameter/alias field, source dispatch, all rules and
geometry/bin/polarity/version conventions using the existing IO semantic encoder
and the same resource owner. The explicit identity byte ceiling is caller owned.
Different rules under the same label therefore cannot share profile authority.
No built-in source level, version,
PDK name, bin count, model card or external artifact is selected by this component.
Level and exact version spelling are explicitly admitted dispatch metadata. A
version is forwarded as a string only when the profile binds an actual string
setter. Polarity is bound explicitly to actual model setters; an omitted provider
default cannot silently turn a source PMOS into an NMOS.

Profile parameter rules distinguish source-only metadata from typed provider
assignments and declare exact none/length/area scaling and explicit nonnegative
or required-value constraints (for supplied geometry or capability flags). Provider aliases and role/type/array shape are checked against copied descriptor
metadata. Repeated names across different parameter indices remain explicitly
ambiguous; they do not invalidate a descriptor with a separately unique qualified
alias. Only the profile-selected name must resolve to exactly one setter, using
the SDK global name/alias lookup contract. Assignments and facts retain that chosen
alias rather than substituting a potentially ambiguous first name. Duplicate
assignments are checked by resolved parameter index plus scope. Integer
setters require an exact finite Int32; real setters require finite values. No
Boolean truncation or real-to-integer rounding is permitted. Supplied values alone
produce Given setters; omission stays absent. Scalar overrides retain their actual
callback addresses and cannot fabricate an unsupplied original parameter.

Length and width are positive supplied source geometry. NF is an integer at least
one; omitted NF may use the profile's explicit selection identity without creating
a Given setter. Multiplicity is separate, positive and finite; it never changes
NF, width or bin choice. Document scale is applied exactly once to each declared
geometry role, area by two ordered multiplications. Nonfinite, underflow-to-zero
positive geometry and duplicate document/provider scale application fail. No
numerical heuristic infers source units from a final dimension.

Source input width, selection width and provider width each have an explicit
whole-device/per-finger convention. Division before scale is retained for total
source width selected per finger. Opposite conversion uses the profile's declared
multiplication order. Raw, effective total, selection and provider geometry remain
distinct facts; provider W is also retained in its actual setter fact.

Nearest lexical candidates are supplied by Lowering and never replaced by a parent
or sibling search. Unique selection checks every candidate and rejects ambiguity.
An explicit source-ordered profile may select the first match in its specified
forward/reverse order and duplicate-card policy, using its supplied endpoint
policy/tolerance. There is no implicit 1e-9 tolerance or bin-number preference.
Missing, nonfinite or inverted bounds fail rather than disappear. The source
profile owns whether an exact declaration requires bounds. All visited bounds
remain addressed facts; a selected model coefficient reuses its memoized value.

The original Sky130 TT N and P card ranges share endpoints. Therefore unique
closed bounds and explicit source-ordered profiles are different contracts; the
latter requires an exact source/profile policy binding. Neither is silently
substituted for the other.

## Runtime Flows

Validate profile/descriptor -> admit temporary capacities -> evaluate instance
slots once -> normalize geometry -> visit original candidate bounds -> select one
source declaration -> evaluate selected coefficient slots -> overlay only supplied
model overrides -> create typed model/instance assignments and retained facts.
Every scalar access goes through the nonescaping synchronous callback. Work and
cancellation checks precede metadata visits/comparisons; failures publish no result.

## State, Ownership, and Lifecycle

The preparer retains an immutable profile and the caller's synchronized resource
accounting owner. Construction preadmits one live-owned reservation for its value
header, retained profile array capacities/nested text payloads, and canonical
identity before hashing or identity materialization. Preparer and request copies
share that reservation owner; it refunds exactly once when the last copy dies.
Failed construction releases both live and hash-temporary reservations. The caller
owns its input before construction; this charge accounts the preparer's independent
retention, not unique physical COW/RSS bytes. Lowering separately accounts its
returned facts/identity; wrapper accounting owns only its own metadata and references,
not a second copy of this delegate payload. Request snapshot/graph and all source metadata remain immutable.
Temporary reservations survive their arrays and release on every exit. Returned
facts and assignments are retained through the Lowering result owner. No pointer,
mutable session, task, callback or RNG escapes the synchronous preparation call.
Native/WASM/Embedded share the same value and synchronization contract; no
platform condition removes resource-owner isolation.

## Failure, Concurrency, and Constraints

Typed preparation errors identify invalid profiles, descriptor/alias/type mismatch,
source metadata or origin mismatch, non-scalar source, missing/ambiguous/no-match
bins, geometry/NF/multiplicity/scale failures and conflicting assignments. Existing
callback/resource errors propagate unchanged. Checked count/byte arithmetic and
preadmitted maximum result/temp capacities precede allocation; truncation is never
successful. Stateless preparations may share immutable profile/snapshot and the
same synchronized resource owner; each invocation has local temporary arrays.

## Verification and Change Impact

`MOSBinPreparationTests` owns Given omission, actual metadata alias/type binding,
polarity, scale/order/NF/total-versus-per-finger/multiplicity, exact/family/source
order/boundary refusal, source-address facts and callback/resource failures. An
explicitly enabled actual original Sky130 TT N/P witness retains captured source,
selected declaration, geometry and source spans, and is separate from model setup
qualification. Synthetic descriptor fixtures prove only this preparation contract.
Successful synthetic fixtures enter the accounted `parseProfile` path so their
model origins retain physical statement byte offsets, just like the actual
source witness. Legacy text-only parser output intentionally lacks that authority
and has a separate refusal regression; a capture label alone cannot satisfy the
preparer's source gate. No test supplies or fabricates missing offsets manually.
Root owns compilation, actual provider setup and API/CLI integration. Changes to
source evaluation or foreign mapping require those owners' regression evidence.
