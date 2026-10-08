# Native Prepared Simulation Execution

## Purpose and Scope

Status: proposed, not implemented. Parent: [CoreSpice module](../DESIGN.md).
No children. Own compilation, actual model/device binding and numerical dispatch
for a retained IO preparation; initial profile coverage is `.op`, `.dc`, `.tran`.

## Responsibilities and Boundaries

Move domain algorithm selection out of Xcircuite's CoreSpiceSimulationEngine.
Reuse StandardCompiler, existing device/solver/analysis implementations and waveform
IR. IO owns parsing/settings; host owns output artifact serialization/location,
measurement acceptance and ledger. No new universal Engine or AgentHarness wrapper.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Module](../DESIGN.md) | parent | Direct native domain API | Result integration | External backend is separately qualified |
| [IO preparation](../../CoreSpiceIO/SimulationPreparation/DESIGN.md) | depends on | Actual graph/CircuitIR/config and retained IC/nodeset | Immutable executable intent | No source reread/reparse |
| [Compile](../../CoreSpiceCompile/DESIGN.md) | depends on | StandardCompiler and topology | Actual node/device binding | Admission ceilings precede construction |
| [Analysis](../../CoreSpiceAnalysis/DESIGN.md) | depends on | Existing DC/transient limits and results | Numerical behavior | No numerical-policy fallback |
| [Devices](../../CoreSpiceDevices/DESIGN.md) | depends on | Actual selected model/device semantics | Physics capability | Loaded declarations are not executed model proof |
| [Host](../../../../Xcircuite/Sources/Xcircuite/ProfileExecution/DESIGN.md) | used by | Prepared plan, observations and output | PDK-before-execution match | Evidence is not release approval |

## Architecture

```text
PreparedSPICESimulation -> compile/bind -> PreparedNativeSPICESimulation
       -> host PDK comparison -> execute same owner -> numerical output + observations
```

## Contracts and Invariants

Proposed separate interfaces:

```swift
public protocol SPICENativePreparing: Sendable {
    func prepare(_ input: PreparedSPICESimulation, limits: SPICENativeExecutionLimits)
        throws(SPICENativePreparationError) -> PreparedNativeSPICESimulation
}
public protocol SPICENativeExecuting: Sendable {
    func execute(_ prepared: PreparedNativeSPICESimulation, cancellation: CancellationToken)
        async throws(SPICENativeExecutionError) -> SPICENativeSimulationOutput
}
```

NE-01: Preparation compiles the same CircuitIR and resolves actual descriptors,
models, node assignments and analysis binding. Its internal-constructor owner
retains the IO owner, immutable plan/configuration, supported model selection and
effective algorithm/solver identities. Extend IO configuration identity with native
choices and effective numerical limits before host comparison. Capability refusal
occurs before a numerical run; a requested model name is not an observed binding.

NE-02: Execute has no reader, String, filename, source list, parser or replacement
settings argument. Allocate invocation-local mutable device/solver state from the
retained plan. Do not share those mutable objects between concurrent executions.
DC points instantiate/bind the recorded override target/value; `.tran` passes the
resolved initial voltages, guesses and UIC into TransientConfig. `.op` applies
supported nodeset semantics explicitly; an unsupported assignment/analysis
combination refuses instead of silently ignoring it. `.ic` effects follow the
existing analysis contract, rather than inventing a new initialization rule.

NE-03: Output retains complete actual input/config identities, prepared owner,
analysis/point schedule, actual executed model receipts, effective runtime
conditions and numerical completion statistics with waveform IR. Partial points
or cancellation never become completed full-schedule evidence. Host report/CSV
generation observes this output without starting another analysis. A preparation
receipt proves intended bound inputs; executed-model coverage requires run receipts.

## Runtime Flows

prepare -> admitted native owner -> expected-profile match by caller -> execute ->
await actual analysis completion -> verify finite/domain-valid output -> completed
output. Cancellation bridges the caller task to the existing cancellation token;
no detached cleanup task or hidden background run outlives the call. Failure retains
typed cause and releases invocation state without publishing a completed output.

## State, Ownership, and Lifecycle

Immutable IO/plan backing may be shared. Mutable devices, solver workspace,
cancellation and result buffers have one execution owner. Repeated executions use
fresh state and retain parent backing. Budget counters use the existing synchronized
owner; callbacks/I/O are outside locks. No target-specific raw mutable state or
weakened Sendable contract is introduced.

## Failure, Concurrency, and Constraints

Native limits bound compilation/device counts and allocation, sweep points, solver
work, waveform retention and numerical duration. Existing TransientExecutionLimits
own transient semantics; source-intake capacity does not imply numerical limits.
Pre-admit new compile/bind materialization and bound each transformation or return
typed unsupported-resource capability. No fallback changes model, solver, analysis
or backend. This first lane is Native CPU; Metal changes require real xcodebuild
test and are a separate verified capability, not a claim from CPU fixtures.

## Verification and Change Impact

Proposed `CoreSpiceNativeExecutionTests` owns actual waveform changes from IC/UIC,
nodeset application/refusal, real supply versus stimulus sweeps, exact prepared
input execution after original files change, configuration drift, concurrent
independent runs, bounded refusal and cancellation. CLI/host integration verifies
direct use of this owner. Existing numerical algorithms are regression-checked
only for the affected paths; repeated grammar/resolver proof is unnecessary.
Implementation adds explicit module dependencies and migrates host numerical
dispatch plus relevant CLI calls. Unsupported remaining host analyses retain an
explicit incomplete marker and cannot claim profile coverage.
