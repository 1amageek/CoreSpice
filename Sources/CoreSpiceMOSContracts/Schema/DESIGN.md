# MOS Release Schema

## Purpose and Scope

Parent: [Contracts](../DESIGN.md). This component owns exact release admission,
parameter roles/kinds and parameter-specific geometry scaling. No children.

## Responsibilities and Boundaries

Schemas describe Level 1/2/3, BSIM3 3.3.0, BSIM4 4.5 and BSIM4 4.8.3. BSIM4 4.5
is inspect-only; current native numerical evaluators admit exact 3.3.0 and 4.8.3.
Schema does not implement device physics or choose a model declaration.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Values](../Values/DESIGN.md) | used by | Release/schema identity | Checked resolution result | No string version rounding |
| [BSIM3](../../CoreSpiceDevices/BSIM3/DESIGN.md) | coordinates with | Exact 3.3.0 admission | Current executable release | Revalidate original parameter kinds |
| [BSIM4](../../CoreSpiceDevices/BSIM4/DESIGN.md) | coordinates with | Exact 4.8.3 admission | Current executable release | 4.5 cannot substitute 4.8.3 |

## Architecture

```text
exact release -> schema identity -> parameter role/kind/scale rule
                                      |
                            resolver normalization only
```

## Contracts and Invariants

Model coefficients, model bin bounds and BINUNIT are never scaled. Instance
l/w/pd/ps use S, ad/as use S squared; BSIM4 sa/sb/sd/sc use S. Multiplicity,
finger count, squares and sca/scb/scc remain unscaled. Aliases retain their original IFparm selector identity through canonicalName;
source order and profile-specific duplicate policy remain resolver-owned.
Rules use exact parameter
names, never dimensional/name heuristics. Release-specific selectors retain their
integer/flag kinds. Unknown names fail schema lookup explicitly.

## Verification and Change Impact

CoreSpiceMOSContractsTests owns release exactness, executable capability and scale
rules. Parameter tables are checked against current original native C kernels;
the pinned normal-profile scale evidence is retained in the parent verification
run. Device preparation remains the final numerical admission owner.

## Proposed Exact 4.5 Executable Schema

Status: design for the [4.5 adoption](../../../DESIGN.md); current source is still
inspect-only. [Research](../../../docs/bsim45-research/RESEARCH.md) pins the original
33 instance / 746 model input table and the SC dispatch defect. This component
owns the executable schema changes; kernel physics remains separate.

Canonical physical release identity becomes `4.5.0`. Preserve the declaration's
original version spelling and explicit/default origin. Register exact spellings
`4.5` and `4.5.0`; the explicit normal-ngspice profile additionally admits the
observed Sky130 spelling `4.500000e+0`. No floating-point version rounding,
prefix matching or arbitrary spelling inference. Unknown releases, including
`4.62`, remain failures. Profile-owned omission defaults remain unchanged.

Generate portable parameter IDs/kinds/canonical aliases from a pinned source
manifest, and independently check them against the compiled C table. Do not make
the portable build depend on C, Foundation or build-time network access. The
manifest records the deliberate SC->SC correction; SC is length-scaled and SCA
is unscaled. Numeric original selector values alone are not semantic identities.

Every accepted non-original instance field must name its owner: outer M belongs
to Devices parallel stamping; IC scalar aliases lower into the original IC vector;
spelling aliases preserve the same semantic ID. Current simulator extensions
`mulu0` and `dtemp` have no original-table authority and must be refused for this
exact-source implementation until a separate explicit extension contract owns
their effects and preparation conditions. Do not silently forward or discard them.
This intentional admission narrowing needs successful original inputs and explicit
extension-failure tests. Original physical defaults stay in the kernel; family
selection cannot fabricate missing L/W.

Remove the portable release-wide `isExecutable` decision. Portable schema describes
meaning; a native provider reports executable release/feature/analysis capabilities.
Resolution can succeed independently of an available native implementation.
Update direct consumers and tests of that property in the adoption unit.

Proposed verification owner: `CoreSpiceMOSContractsTests` for every original input
ID/kind/alias, exact version spellings and units, and `CoreSpiceMOSResolutionTests`
for normalized SC/SCA, NF/M, missing dimensions and preserved release origin.
Test a later-only parameter against 4.5 and a 4.62 declaration explicitly. Native,
ordinary WASM and Embedded WASM must compile, link and execute these pure contracts
on exact Swift 6.4.0 and matching SDKs, independent of any numerical kernel.
