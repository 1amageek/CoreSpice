# Continuous Equation Structure

## Purpose and Scope

Child of [CoreSpiceDevices](../DESIGN.md), with no children. Own package-internal
structural facts about the coordinate inputs and equation outputs of actual bound
continuous F/Q laws, plus exact represented linear-law coefficients for native
R/C/V. Native R/C/V and the actual OSDI mapping provide structural witnesses.
This is not a physical admission, numerical rank, source jet or root certificate.
The existing structural lower contract is qualified by six Devices and three OSDI focused
tests, all262 Devices and37 reported OSDI owner tests, including one optional
binding performance skip, and one closed comprehensive review.
The OSDI run includes actual four-family point/circuit checks; it does not qualify
other targets or new CoreSpice API/CLI persistence paths.
The R/C/V coefficient extension is qualified by 14 Native focused tests in two
suites, all 270 Devices owner tests in 36 suites with no skips, and one closed
comprehensive review with no findings. The [qualification receipt](../../../.verification/continuous-equation-structure-20261019/linear-verification-r1.json)
pins the actual sources and central execution evidence. This qualifies native
R/C/V laws only; it is not a Core whole-circuit chart or global root proof. The
unchanged OSDI structural witness retains its separate existing evidence and does
not acquire the native linear-law capability.

## Responsibilities and Boundaries

Facts belong to a queried bound device, not to its typeName, parameter dictionary,
referencedBranches metadata, sampled derivative or sampled zero. An unqualified
custom implementation cannot gain authority from protocol conformance alone.
The future whole-circuit consumer must admit its actual producer, join every
MNAVariable/index against the same complete compiled axis and retain that device.
Unsupported devices provide no witness. Other native devices remain unproved.

## Related Designs

| Design | Relationship | Contract Used | Caution |
|---|---|---|---|
| [Devices module](../DESIGN.md) | parent | Bound-device lifecycle | No public product/API expansion |
| [Native devices](../Devices/DESIGN.md) | used by | Actual resolved R/C/V indices and source value law | Do not reparse original parameters |
| [OSDI execution](../../CoreSpiceOSDI/DCExecution/DESIGN.md) | used by | Immutable actual raw/active/global projection | Keep aliases, internal body/thermal/flow coordinates |
| [Prescribed reduction](../../CoreSpiceAnalysis/PrescribedVoltageReduction/DESIGN.md) | future consumer | Conditional source incidence forest | No current composition or admission wrapper |

## Architecture

```text
actual bound R/C/V or OSDI device
  -> synchronous visitor: READ coordinate / WRITE F row / WRITE Q row
  -> caller's complete variable-axis join and existing resource checkpoints
  -> structural nondependence obligations for a selected source elimination
actual bound V -> immutable identity/terminal/branch/Waveform value-law fact
actual bound R/C/V -> sparse F/Q linear terms with exact binary64 coefficient bits
```

## Contracts and Invariants

Visitors enumerate conservative complete support of continuous F and Q, not of a
Newton/companion stamp or accepted history. Each visit carries the actual
MNAVariable identity and its bound global index. Duplicates are permitted; omission
is permitted only for exact ground or a structurally absent term, never a sampled
zero. R reads its two potentials and writes F there; C reads its two potentials
and writes Q there. V reads its potentials and owned current and writes F at its
potentials and constraint row, with Q identically zero. Ground has no global row;
unmapped non-ground endpoints or an absent source branch refuse explicitly.

The independent-V fact carries the actual stored Instance, positive/negative Node
and optional rows, actual claimed Branch/row and stored Waveform. Its join check
requires these identities to match the caller's complete variableMap. It declares
a value law only, without a derivative, smoothness, phase family or past history.

### Exact represented native R/C/V laws

The package-only `ContinuousEquationLinearLawProviding` capability refines the
existing structural witness. Its synchronous visitor publishes every non-ground
linear term of the actual bound continuous F/Q law. Each immutable term contains
the F or Q plane, actual equation MNAVariable and bound global row, actual input
MNAVariable and bound global column, and `coefficientBits: UInt64` for a finite
binary64 coefficient. The bits denote that represented number exactly; the
consumer may convert it to an exact dyadic scalar without rounding. This is an
algebraic represented-coefficient law, not a claim that arbitrary floating-point
evaluation has no rounding. No sampled Jacobian, point zero or parameter
dictionary grants this capability.

Let `e` be the positive-minus-negative terminal incidence, omitting only actual
ground coordinates, and let `b` denote the actual owned source-current coordinate.

| Qualified producer | Complete F law | Complete Q law | Coefficient authority |
|---|---|---|---|
| BoundResistor | g e (e^T x) | Zero | Stored prepared parameters.conductance, including resolved temperature/multiplicity/scale; never acConductance |
| BoundCapacitor | Zero | C e (e^T x) | Stored prepared capacitance; no IC or companion/history term |
| BoundVoltageSource | Potential rows e i_b; branch row e^T x - u(t) | Zero | Four signed unit incidence terms plus separately retained source law |

The V linear visitor publishes only the coordinate terms. Its separate source
fact additionally retains the actual stored `dcVoltage` and actual stored
`Waveform`, so DC uses the former and transient uses the latter's symbolic value
law. A waveform is not assumed affine in time, differentiable at seams, or a
certified source jet. AC magnitude/phase and numerical continuation source scale
are outside this continuous physical law. The caller must combine the separate
source contribution with the complete coordinate terms rather than assume F=0.

R/C enumerate all four signed outer-product incidence terms. Equal non-ground
endpoints remain duplicate terms for exact cancellation; they are not deduplicated
or omitted by sampled value. Ground has no row or column and contributes no term.
Each candidate terminal/term step still performs the caller's mandatory throwing
checkpoint, including steps omitted because of ground. Nonfinite stored
coefficients and invalid actual identities/indices refuse with typed component
failures. Callback failures propagate unchanged and may leave only an incomplete
prefix, which the consumer must discard.

The native witnesses describe electrical potential inputs/current-balance rows,
plus the ideal V's electrical current input/voltage-constraint row. The caller
must join both identities and indices against its same complete compiled axis and
equation natures; this local witness cannot assign a thermal, internal OSDI or
otherwise unmatched axis by positional inference. Unknown devices, behavioral
R/C and other native families have no new linear-law witness.

To use iV=-K*r, the future caller must establish that every remaining admitted
producer's READ support excludes every selected iV coordinate and both F/Q WRITE
supports exclude selected source constraint rows. Selected V contributions are
handled through their own exact incidence/value-law facts. These tests are
conditional on qualified producer facts and a complete actual-device inventory;
the component does not perform generic circuit admission or discharge a root.

## State, Ownership, and Lifecycle

All fact state is immutable. Visitors borrow already bound indices and allocate
no support array, cache or session. The queried device retains its native/OSDI
owner throughout synchronous visitation. The V fact owns immutable value copies
of Instance and Waveform; array backing follows existing COW ownership. A copied
fact cannot replace the consumer's actual-device/complete-axis join.

The caller supplies a mandatory throwing checkpoint closure backed by its existing
work/cancellation owner, called before each bounded coordinate step, including
omitted ground rows. Output sparsity cannot hide traversal work. Every support
callback and any retained projection must also follow the caller's existing
storage/admission policy. Callback errors,
including cancellation and resource refusal, propagate unchanged. A failed visit
may have delivered a prefix; callers must discard any incomplete inventory. There is no
independent budget, unsafe storage or shared mutable state.

The new term visitor similarly allocates no output buffer and owns no quota.
Its mandatory checkpoint uses the caller's existing work/cancellation owner;
the callback must admit storage before retaining term values or derived exact
limbs. Terms are immutable value copies with no pointer/view lifetime. The
queried device remains alive through visitation, and the consumer must retain
the actual producer alongside any inventory. The V fact's copied PWL backing
uses existing immutable COW ownership; retaining/copying a fact does not discharge
the consumer's source-storage accounting or complete-axis join.

## Failure, Concurrency, and Constraints

Invalid bound identities/indices raise a typed structural binding failure.
Unsupported/unknown devices have no protocol witness and must remain unproved.
No caller callback executes under a component lock. Package-only visibility
prevents third-party devices from implicitly opting into these internal facts.
Existing point/stamp/session methods are unchanged.

## Verification and Change Impact

ContinuousEquationStructureTests owns actual R/C/V binding, ground omission,
canonical owned-branch order, full-axis identity mismatch, visitor refusal, source
law retention, unsupported CCCS feedback and unknown masquerading instances.
OSDI ContinuousEquationStructureTests owns actual prepared binding plus exact
alias/ground/body/thermal/internal-flow mapping and callback refusal. These tests
prove structural observations only. Source-jet, whole-circuit range composition,
all roots/flow/history and physical qualification remain separate obligations.

The coefficient extension's focused Devices tests independently compare
actual resolved coefficients and all incidences against actual DC stamps/F and
static-C unadjusted charge differences at exact binary states. Temperature,
multiplicity/scale, distinct AC resistance, source DC versus all symbolic waveform
families, ground and coincident endpoints, permuted full axes and unrelated branch
coordinates distinguish actual bound authority from metadata reconstruction.
Tests also cover invalid binding/nonfinite coefficient refusal, caller work and
storage refusal, cancellation without ledger reset, immutable term/fact copying
and repeat queries. This extension does not qualify whole-circuit chart assembly,
source jets, roots, history or physical PDK models. Native central execution and
the closed review are recorded in the qualification receipt linked above; future
consumer composition requires its own integration evidence.
