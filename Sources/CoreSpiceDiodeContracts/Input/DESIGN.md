# Diode Input Contract

## Purpose and Scope

Status: D1 numeric contracts/schema implemented; source resolution and executable
stages described below remain D3/D4 work. Parent: [DiodeContracts](../DESIGN.md). No children.
Own the exact diode input profile, role/unit schema and immutable stage contracts.
This boundary does not implement Sky130 Level-3 diode physics or claim ngspice
compatibility. The initial profile is explicitly `coreDiodeV1`, with law identity
`coreJunctionV1`; omitted level or exact numeric level=1 selects that law. Other
levels, version selectors and dialect extensions are rejected without fallback.

## Responsibilities and Boundaries

Keep source coefficients, evaluated model values, supplied instance values,
normalized geometry and prepared effective values separate. Schema is the single
role/unit/domain/default/required-feature authority; Devices cannot maintain a
second whitelist. Supplied zero is still supplied and requires admission.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [DiodeContracts](../DESIGN.md) | parent | Pure value module | Ownership boundary | No physics dependency |
| [Environment](../../CoreSpiceEvaluationContracts/Environment/DESIGN.md) | depends on | Temperature units and identity | Ambient vs nominal/local temperature | No temperature mutation |
| [Diode resolution](../../CoreSpiceLowering/DiodeResolution/DESIGN.md) | used by | Checked model/instance values | Sole source adapter | Keep all occurrences |
| [Diode device](../../CoreSpiceDevices/Diode/DESIGN.md) | used by | Required features and preparation identity | Numerical admission | Known coefficient is not implemented feature |

## Architecture

```text
ordered assignments -> role/schema admission -> evaluated values -> normalization
  -> ResolvedDiodeInstance -> feature/capability admission -> preparation receipt
```

## Contracts and Invariants

### Model and instance roles

| Role / canonical ID | Source keys in coreDiodeV1 | Unit / default / constraint |
|---|---|---|
| Model saturation current / ideality | is / n | A / dimensionless; 1e-14 / 1; positive finite |
| Model series resistance | rs | ohm; 0; nonnegative finite; nonzero requires seriesResistance feature |
| Model breakdown | bv / ibv | V / A; omitted bv means disabled, ibv=1e-3; positive finite when supplied; explicit bv requires breakdown feature |
| Model depletion / gradingCoefficient | cjo / vj / m | F / V / dimensionless; 0 / 1 / 0.5; cjo>=0, vj>0, 0<=grading<1; source m belongs here only |
| Model transit time | tt | s; 0; nonnegative finite; nonzero requires diffusionCharge feature |
| Model temperature law | eg / xti / tnom | eV / dimensionless / Celsius; 1.11 / 3 / frozen global nominal; eg>0, xti finite, converted Tnom>0 K |
| Instance geometry | area / pj | dimensionless AreaFactor / SI PerimeterMetres; defaults 1 / 0; area>0, pj>=0; nonzero pj requires sidewall feature |
| Instance parallel replicas | m | dimensionless ParallelMultiplicity; default 1; positive finite real, not an integer-only count |
| Instance thermal input | temp / dtemp | Celsius absolute / temperature delta; mutually exclusive; omitted uses ambient; effective temperature>0 K |

Every numeric input must be finite, including values whose feature is inactive.
Model m and instance m have different parameter IDs and never share storage.
No is/n/rs/etc instance overrides, model-level area/pj/multiplier reinterpretation,
`tnom_k` source extension, unknown alias, flag/off/IC, l/w or positional diode value
is admitted in this initial explicit profile. Reject these with source location;
do not consume and discard them. Direct typed APIs use Kelvin values rather than
a second tnom_k string spelling. Future aliases belong to an exact schema revision.

`area` here is a SPICE-style reference-area factor, NOT square metres. It receives
no deck scale. `pj` is a raw source length and receives explicit deck length scale
once. Distinguish RawDiodeGeometry, DiodeAreaFactor, DiodePerimeterMetres and
ParallelMultiplicity. A future density/physical-area law needs a different tagged
geometry/schema; never relabel the factor as SI area or guess units from keys.
Source Tnom and instance temp convert once into typed Kelvin during resolution;
dtemp remains a typed delta. Preparation consumes these canonical thermal values.
Neither model coefficients nor Tnom nor multiplicity receive geometry scale.
Scale must be finite/positive; conversion rejects overflow, nonfinite results and
positive-to-zero underflow. Omitted/defaulted values retain default provenance and
are not re-scaled. Sidewall is unimplemented in the initial native capability;
nonzero pj fails preparation even if all model coefficients otherwise parse.

A model-side unknown coefficient rejects the selected declaration even when zero,
unused by the chosen analysis, or attached to a zero-perimeter instance. Distinguish
unknownParameter, wrongRole, duplicateAssignment/aliasConflict, invalidValue and
unsupportedModelLaw. An explicitly understood but unavailable numerical feature
produces unsupportedFeature/unsupportedAnalysis at preparation, not success.
There is no generic "ignored" disposition. A schema-defined inactive value (e.g.
validated default ibv with breakdown disabled) has an explicit inactive reason in
the consumption report; it is not an unknown coefficient bypass.

### Stage values and interfaces (D1 schema; D3/D4 resolved/prepared stages)

| Value | Owned payload |
|---|---|
| DiodeModelSchema | Exact schema/law/profile ID, model and instance parameter IDs, units/defaults/domains and required feature mapping |
| ResolvedDiodeModel | Selected declaration/source identity, immutable contiguous coefficient buffer and supplied/default origin bits; lexical invocation identity |
| ResolvedDiodeInstance | Model reference, supplied instance values, normalized tagged geometry, local thermal request, effective multiplier, frozen environment identity and resolution provenance |
| DiodePreparationInput | Checked resolution, identical frozen environment, requested analyses and explicit preparation policy/limits |
| DiodePreparationIdentity | Resolution identity, law/schema/implementation identity, ambient/global nominal/model nominal/effective temperature, capabilities/policy and prepared topology identity |
| DiodePreparationReceipt | Immutable preparation identity, required features, exact topology/resource facts; no executable ownership |

Resolved identity binds canonical values, selected declaration occurrence, scope
invocation, profile/schema and evaluation environment/provenance. Names alone are
not identity. Equality/serialization must not use Swift Hasher or pointer addresses.
Native execution owns external digest encoding using existing artifact contracts.
Immutable backing owners keep coefficient/range borrows alive; use typed IDs and
Span in synchronous paths, without per-instance map merges or intermediate copies.

```swift
// Implemented in D1; source resolution and native preparation remain separate.
public protocol DiodeModelSchemaProviding: Sendable {
    func schema(for law: DiodeModelLaw)
        throws(DiodeSchemaFailure) -> DiodeModelSchema
}
```

Schema providers supply exact schema values; built-in role checking, normalization,
feature derivation and checked construction are non-overridable functions. Reject
schema identity/content disagreement at admission. Do not let a provider override
an algorithm or claim a feature is numerically implemented.

## State, Ownership, and Lifecycle

Models may share immutable evaluated buffers only for the same declaration,
lexical invocation and frozen environment. Instance geometry/multiplier are not
written into those buffers. Prepared results additionally bind effective local
T and requested capabilities. Resolved values are reusable only under their exact
evaluation identity; executable owners are freshly prepared per execution.

## Failure, Concurrency, and Constraints

Typed failures separate undefined/wrong-type/duplicate model, duplicate parameter,
wrong role, unknown parameter, unsupported law/schema, expression/cycle, invalid
numeric/normalization, unsupported feature/analysis, environment/topology mismatch,
resource limit and cancel. Diagnostics preserve declaration and assignment origins,
instance/scope/invocation, parameter ID, raw/normalized values and rejection reason.
Source owners/ranges are retained once; bounded diagnostic truncation is explicit
and never changes failure into success. Model visits, expression work, retained
capacity, temporary peak and diagnostic capacity have caller-owned limits.

## Verification and Change Impact

[DiodeSchemaTests](../../../Tests/CoreSpiceDiodeContractsTests/DiodeSchemaTests.swift) covers every row/role, model m=0.4 with instance m=2,
unknown zero-valued fields, aliases/case duplicates, forbidden instance is, Level3,
area-factor vs perimeter scale, underflow/overflow, omitted vs explicit defaults,
Tnom/temp/dtemp and immutable buffer reuse. Native prepare tests must reject a
known feature when its implementation is absent. A Level3 js change must yield
an exact unsupported-law result, never the unchanged successful default current.
The resolver and Devices tests consume the same schema fixture/identity; neither
may maintain an independent list of accepted names.

## Primary Reference and Deliberate Profile Boundary

Fixed reference: ngspice commit ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6,
[diode parameter tables](https://github.com/imr/ngspice/blob/ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6/src/spicelib/devices/dio/dio.c),
[instance input conversion](https://github.com/imr/ngspice/blob/ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6/src/spicelib/devices/dio/dioparam.c),
[temperature/geometry preparation](https://github.com/imr/ngspice/blob/ebdaf58ec76a06ffaac7e0f138360dd1cf5ee4b6/src/spicelib/devices/dio/diotemp.c).
The parameter tables separate instance multiplier from model grading coefficient;
the temperature path separately applies area/perimeter contributions and multiplier,
and scales series conductance. These observations justify separating roles; they do
not establish compatibility of coreDiodeV1 with all ngspice diode laws. In particular,
ngspice has model-area/perimeter defaults and Level3 aliases absent from this initial
profile. Do not infer physical-area/density units solely from an alias spelling.

Original installed Sky130 reference is Volare version
c6d73a35f524070e85faff4a6a9eef49553ebc2b/sky130A/libs.ref/sky130_fd_pr/spice,
including sky130_fd_pr__pfet_20v0__parasitic__diode_pw2dn.model.spice.
Its level=3, scalm, model area, js/jsw, cj/cjsw and temperature selectors require
an exact separate law. Their current unknown/unsupported status is intentional
admission, not permission to erase coefficients or change the source card.

## D1 Concrete Contract Implementation

D1 implements checked numeric input values, not ResolvedDiodeInstance or executable
receipts (owned by D3/D4). DiodeModelInput contains an InlineArray of 12 optional
canonical coefficient values and a supplied-bit mask; disabled BV remains nil.
DiodeInstanceInput contains distinct geometry, multiplicity and thermal values.
Borrow model storage with a synchronous withCoefficients(Span) closure. No unsafe
pointer, COW model dictionary, dynamic schema table or mutable shared state is needed.
Source-name lookup happens only at this explicit input boundary and is bounded by
DiodeInputLimits; checked inputs accept scalar assignment spans and reject every
unknown/wrong-role/duplicate supplied field before returning a value. Selectors are
checked separately by the explicit coreDiodeV1 schema factory. Tnom is canonical
Kelvin in checked model storage; parameter definitions distinguish source and
canonical units. Required features describe needs, not numerical implementation.
D1 tests also prove schema/content identity is unforgeable through public schema
construction. A provider may fail, but cannot substitute a mutable name table.

RawDiodeGeometry.perimeter is DiodeInputPerimeter (unscaled source length), never
DiodePerimeterMetres. Schema source/canonical unit metadata distinguishes inputLength
from metres. Compile-negative verification rejects feeding SI perimeter back into
the raw constructor. Checked model/instance inputs validate their stored environment
identity; effective instance temperature uses that guard before applying local input.

### D1 Behavioral Proof and Change Impact

| Owned invariant | Public implementation | Counterexample evidence |
|---|---|---|
| Exact law and immutable schema content | DiodeInputProfile, StandardDiodeModelSchemas, DiodeModelSchema | exactLawAndProvider; compile-negative schema-forgery |
| Model/instance roles never merge | DiodeModelInput, DiodeInstanceInput, distinct parameter IDs | sameSpellingDifferentRoles; model-instance-id-mix compile refusal |
| Every supplied field is admitted or refused | Schema name/domain admission and supplied masks | unknownZeroAndWrongRolesRejected, duplicateCaseFoldedFieldsRejected, coefficientAndInstanceDomains |
| Input lengths and SI lengths differ; defaults are not scaled | RawDiodeGeometry, DiodeInputPerimeter, DiodePerimeterMetres | normalizedGeometryAndOrigin; raw-si-geometry-mix compile refusal |
| Nominal/local/ambient temperatures and frozen identity remain distinct | Checked model/instance environment guards | nominalLocalAndAmbientRemainSeparate, checkedInputRejectsAnotherEvaluationEnvironment |
| Recognition never claims physical execution | requiredFeatures and requireSupport | featureRequirementsAreNotNumericalAdmission |
| Bounded inspection and immutable storage | DiodeInputLimits, InlineArray and scoped Span | callerLimitsBoundAllInputInspection, everyModelDefaultAndBorrowedStorage |

The [independent verification runner](../../../validation/diode-contracts/README.md)
executes these public factories without parser, Devices, C, Metal or external
simulator dependencies. D1 has no preparation owner, source diagnostic arena or
mutable shared state to cancel/release. D2-D5 must supply their own source, lifecycle
and numerical evidence before changing public diode admission.
