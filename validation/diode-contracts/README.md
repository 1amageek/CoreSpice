# D1 Diode Contract Verification

D1 implements two public, Standard-Library-only targets. It does not adopt these
contracts in the legacy parser, resolver or numerical device path. Those migrations
belong to D2-D5 in the [package design](../../DESIGN.md#diode-boundary-design-and-implementation-units).

```text
EvaluationContracts/Environment -> DiodeContracts/Input
               checked values -> checked scalar model/instance inputs
                               -> required-feature inspection (not execution)
```

## Reproduce

Use the default Swift 6.4.0 release compiler and its matching SDKs
`swift-6.4.0-RELEASE_wasm` and `swift-6.4.0-RELEASE_wasm-embedded`.
Node.js 24.19.0 runs WASI Preview 1 in the recorded environment.
From the CoreSpice root, choose one output directory and run the phases in order:

```sh
python3 validation/diode-contracts/verify.py --output /tmp/diode-d1-proof --phase native
python3 validation/diode-contracts/verify.py --output /tmp/diode-d1-proof --phase portable
python3 validation/diode-contracts/verify.py --output /tmp/diode-d1-proof --phase integration
```

The runner symlinks the exact production source and test directories into a
standalone SwiftPM fixture with no external package dependencies. It records
source hashes, toolchain/SDK commands, logs and elapsed times. Integration requires
matching Native/portable source hashes, checks the real package dependency graph,
builds both registered targets and type-checks intentionally invalid client code.
Subprocess timeouts are 10-120 seconds, depending on the step. No external
simulator, C device kernel, Metal, solver or network oracle is needed by the fixture.
Root package target builds use the existing package graph and `.build` directory.

Embedded builds use debug `-Onone`, WMO and `-Xlinker -lswiftUnicodeDataTables`.
The matching SDK supplies that archive for `wasm32-unknown-wasip1`; it is needed
for the same public string/error paths used on Native and normal WASM. Omitting
it fails linking on this baseline. Do not use optimization or a weakened target
implementation to conceal that dependency.

## Evidence Boundaries

| Evidence | Proof | Limit |
|---|---|---|
| Native Swift Testing: 6 environment + 12 diode methods | Domains, defaults, case duplicates, role separation, normalization, overflow/underflow, thermal identity, each unsupported feature and caller limits | Pure checked numeric inputs, not source resolution |
| Public probe on Native / normal WASM / Embedded WASM | Checked construction, model m vs instance M, perimeter scale, thermal delta, exact identity, Level3/coefficient/feature/environment refusal | Minimal runtime; no numerical physics or thread qualification |
| Compiler refusal | Schema identity forgery, instance ID used for model access, SI perimeter passed as raw input | Public Swift type boundary |
| Registered target builds / manifest inspection | Evaluation target has no dependencies; diode target depends only on evaluation contracts | Existing targets have not adopted D1 |

The complete D1 review found and corrected normalized perimeter being accepted
at a raw-input boundary, unchecked reuse at a different evaluation environment,
and a helper name exposing unscaled geometry as if it were canonical SI. The
first two have behavioral/compiler counterexamples; the scalar admission helper
is now internal and explicitly leaves geometry unscaled until typed normalization.
Checked Kelvin/Celsius conversion also preserves the original canonical Kelvin
word across a typed round trip, including fractional temperatures.

All stored production state is immutable on all three targets. Mutable locals
exist only during checked construction, and coefficient views are scoped Span
borrows of InlineArray storage. There are no unsafe pointers, shared mutable
caches, conditional Sendable conformances or platform-specific isolation paths.
No allocation/copy speedup is claimed by this evidence.

The existing public simulation path and Sky130 Level3 numerical support remain
outside D1. A schema-recognized coefficient with required features is not a
numerical capability declaration. Devices must explicitly reject absent features
when D4 adopts these checked inputs; selecting or inspecting them is not execution.
