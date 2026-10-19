import CoreSpiceIO
import CoreSpiceEvent
import CoreSpiceIR
import CoreSpiceParsedIR
import CoreSpiceLowering
import CoreSpiceMOSContracts
import CoreSpiceOSDIContracts

/// Immutable final source values; it carries inspection capability, never executable devices.
struct CoreSpiceCLIResolvedCircuit: Sendable {
    private let frontendReservation: SPICESourceStorageReservation
    let resources: SPICESimulationResources
    let lowered: LoweredCircuit
    let options: SPICEAnalysisOptions
    let analyses: [ParsedAnalysisCommand]
    let initialNodeVoltages: [Node: Double]
    let nodeSetVoltages: [Node: Double]

    static func resolve(_ compiled: CompiledNetlist, policy: CoreSpiceCLIExecutionPolicy,
                        seed: UInt64, selectedAnalysisIndex: Int?, cancellation: CancellationToken? = nil,
                        osdiInstances: [String: OSDIResolvedInstance] = [:]) throws -> Self {
        let resources = try policy.resources()
        let envelope = try NetlistLowering.resourceEnvelope(limits: policy.resolutionLimits)
        let retained = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: envelope.maximumRetainedBytes)
        let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: envelope.maximumTemporaryBytes)
        defer { withExtendedLifetime(scratch) {} }
        let control = CoreSpiceCLIResolutionControl(resources: resources, cancellation: cancellation)
        do {
        var session = try NetlistLowering.beginEvaluation(compiled, profile: policy.profile,
            limits: policy.resolutionLimits, seed: seed, control: control)
        let options = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
        do { try session.lower(geometryScale: options.geometryScale, diodeProfile: policy.diodeProfile, osdiInstances: osdiInstances) }
        catch let failure as DiodeResolutionFailure {
            throw SPICESimulationPreparationError.diodeResolution(failure, resourceCause: nil, reservation: retained)
        }
        guard let circuit = session.circuit else { throw CLIError.state("lowering produced no circuit") }
        var analyses = compiled.source.analyses
        if let index = selectedAnalysisIndex {
            guard analyses.indices.contains(index) else { throw CLIError.state("analysis is outside compiled source") }
            analyses[index] = try SPICEAnalysisCommands.resolve(analyses[index], at: index,
                from: compiled, session: &session)
        }
        // Fourier consumes the declared transient schedule in this same scalar session.
        if let index = selectedAnalysisIndex, requiresTransient(analyses[index]),
           let transientIndex = compiled.source.analyses.firstIndex(where: {
               if case .transient = $0 { return true }; return false
           }) {
            analyses[transientIndex] = try SPICEAnalysisCommands.resolve(analyses[transientIndex],
                at: transientIndex, from: compiled, session: &session)
        }
        let resolver = SPICENodeVoltageResolver()
        let initial: [Node: Double]
        let nodeset: [Node: Double]
        do {
            initial = try resolver.resolve(.initialConditions, compiled: compiled, session: &session, circuit: circuit)
            nodeset = try resolver.resolve(.nodeSets, compiled: compiled, session: &session, circuit: circuit)
        } catch let error as SPICENodeVoltageResolutionError {
            switch error {
            case .unknownNode(let name): throw CLIError.invalidArguments("node assignment references unknown node '\(name)'")
            case .nonfiniteValue(let name, let value): throw CLIError.invalidArguments("node assignment \(name) must be finite: \(value)")
            case .nonzeroGround: throw CLIError.invalidArguments("node assignment for ground must be zero")
            default: throw error
            }
        }
        return Self(frontendReservation: retained, resources: resources, lowered: try session.finish(), options: options, analyses: analyses,
            initialNodeVoltages: initial, nodeSetVoltages: nodeset)
        } catch { throw control.preservingResourceCause(error) }
    }

    private static func requiresTransient(_ analysis: ParsedAnalysisCommand) -> Bool {
        if case .fourier = analysis { return true }
        if case .monteCarlo(let spec) = analysis { return requiresTransient(spec.analysis) }
        return false
    }
}
