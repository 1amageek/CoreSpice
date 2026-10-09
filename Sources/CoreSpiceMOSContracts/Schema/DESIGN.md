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
