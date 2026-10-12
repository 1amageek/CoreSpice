# D2 Temperature Environment Verification

The sole D2 evaluator is the production noncopyable MOSEvaluationSession. The
portable probe links production EvaluationContracts, MOSContracts and MOSResolution
without Foundation, Devices, C compact kernels, Metal or an external simulator.

```sh
python3 validation/temperature-environment/verify.py --output /absolute/evidence/path
python3 validation/temperature-environment/public-fixture.py --output /absolute/evidence/path
# Build the IO dependency target first on a cold cache; use a 120-second subprocess deadline.
# Then build/run the selected test targets using the same fixture and scratch path.
env TOOLCHAINS=org.swift.640202609131a scripts/swift-test-timeout.sh 120 --package-path /absolute/evidence/path/public-component --build-path /absolute/evidence/path/public-native --jobs 12 --filter 'ConditionEvaluationTests|PreparedNativeExecutionTests|MOSEvaluationTests|ResistorLoweringTests|SPICEExecutionIntentTests'
```

All subprocesses have deadlines. The release Swift 6.4.0 compiler and matching
WASM SDKs are explicit. Embedded uses debug Onone/WMO and links the matching
Unicode tables; optimized link success is not substituted for runtime proof.
Generated logs, commands, durations and production source hashes live outside Git.
Numerical execution evidence is Native CPU only.

| Owner / invariant | Behavioral evidence |
|---|---|
| Exclusive bootstrap/freeze | ConditionEvaluationTests and EnvironmentProbe consume one owner, retaining dependency memo and exact PRNG state |
| Reserved ambient reference | Direct/indirect ambient cycles, function formal shadow, lexical global binding and reserved source/actual refusal |
| Condition roots | Last ordered source, explicit caller override, separate nominal root, dead expressions skipped but invalid syntax refused |
| Failure resources | Cancel/work exhaustion, poisoned session, bounded diagnostic source and dependency path |
| IR/native condition identity | TemperatureEnvironmentExecutionTests rejects ambient/nominal drift before reservations and at direct Analysis binding |
| MOS/model/local temperature | Resolved MOS and prepared receipt retain the circuit environment; BSIM3 model Tnom and resistor instance TEMP/Tnom remain separate |
| Public execution | Exact-source profile preparer and NativeSimulation perform scalar/runtime resistor DC and Level1 MOS DC; CLI fixtures verify the same composition |
| Platform contract | Native, WASM and Embedded use identical stored environment/session state and mutation entrypoints, with no conditional isolation weakening |

There is no newly shared mutable state. The evaluator, bootstrap and lowering
session are exclusive noncopyable owners. Environment and resolution/receipt values
are immutable Sendable. Existing native kernel/device Mutex owners are unchanged.
The test cancellation gate uses Synchronization.Mutex and introduces no platform branch.

The overall review corrected missing root-directive source retention, explicit
imports required by Embedded compilation and CLI failure classification, bootstrap
failure wrapping, and Celsius-to-Kelvin reconstruction in native MOS admission.
The final check is limited to these findings and the fixed D2 invariants.

Downstream adoption remains D5: Xcircuite already uses selected session conditions;
Studio pins the previous CoreSpice and must move process overrides before
beginEvaluation when it updates that pin. D2 does not claim diode D3/D4 numerical
support or downstream pin adoption.

| State | Native | WASM | Embedded | Read/mutation/release owner |
|---|---|---|---|---|
| Frozen environment | immutable checked value | same | same | borrow/read only; value lifetime |
| Evaluation memo/RNG/diagnostic | noncopyable session | same | same | exclusive mutating interpreter; consuming freeze/finish |
| Lowering scalar memo | noncopyable frontend | no platform branch | no platform branch | exclusive session; no Sendable/shared mutable escape |
| Native kernel history | existing Mutex owners | numerical proof not claimed | numerical proof not claimed | unchanged Devices contracts |

Public IO keeps bootstrap diagnostic and underlying frontend resource cause in
SPICESimulationPreparationError.condition. Native MOS admission uses canonical
OperatingConditions words, avoiding a second Celsius-to-Kelvin reconstruction.

## Verified D2 Snapshot

On 2026-10-12, affected CPU tests passed 416 methods, and the finding-specific
canonical-Kelvin regression passed one additional method. The latter uses a positive
Kelvin value whose Celsius projection does not round-trip to the same bits; native
MOS admission preserves the original words. The test does not claim physical
qualification at that temperature.

The registered CLI completed resistor and Level1 MOS OP runs. Its resistor CSV
returned V(out)=1 V and I(v1)=-0.00173913043578261 A, within 1e-10 A of -2/1150 A.
A cyclic ambient directive returned evaluation.temperature with line 2 and no
execution-success record. The typed public path separately executed BSIM3 with
model Tnom distinct from global nominal and resistor local temperature.

Cold test preparation initially exceeded deadlines because the root test command
built unrelated targets. The final focused fixture stages the CoreSpiceIO dependency
build first, preserving the same production sources, declared dependencies and lock.
The measured final IO build took 69 seconds, affected test build 43 seconds, and
finding-specific incremental build 12 seconds. Test execution itself took under
one second in aggregate; these are debug verification timings, not performance claims.
