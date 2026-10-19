import CoreSpiceAnalysis
import CoreSpiceIO

/// CLI-only validation of explicit network intent and its existing execution-profile envelope.
struct CoreSpiceCLINetworkOptions: Sendable {
    let analysisIndex: Int
    let ports: [NetworkPort]
    let residualTolerance: Double

    init(analysisIndex: Int?, ports: [NetworkPort], residualTolerance: Double?) throws {
        guard let analysisIndex, analysisIndex >= 0, !ports.isEmpty,
              let residualTolerance, residualTolerance.isFinite, residualTolerance > 0, residualTolerance < 1 else {
            throw CLIError.invalidArguments("Network extraction requires --analysis-index, ordered --network-port source reference-ohms and --network-residual-tolerance between zero and one")
        }
        guard Set(ports.map { $0.voltageSourceName.lowercased() }).count == ports.count else {
            throw CLIError.invalidArguments("Network port sources must be unique")
        }
        self.analysisIndex = analysisIndex; self.ports = ports; self.residualTolerance = residualTolerance
    }

    func selection(policy: CoreSpiceCLIExecutionPolicy) throws -> SPICENetworkParameterSelection {
        guard let temporary = Int(exactly: policy.maximumTemporaryBytes) else { throw SPICESourceStorageError.arithmeticOverflow }
        return .init(ports: ports, limits: .init(maximumPorts: policy.maximumElements,
            maximumFrequencyPoints: 1000, maximumResultScalars: policy.numericalLimits.maximumSavedScalars,
            maximumTemporaryBytes: temporary, residualTolerance: residualTolerance, executionLimits: policy.numericalLimits))
    }
}
