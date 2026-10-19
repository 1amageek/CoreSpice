import CircuiteFoundation
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceIO
import CoreSpiceWaveform
import Foundation

/// Inspection-only exact network observations, never an executable circuit owner.
struct CoreSpiceCLINetworkRecord: Codable, Sendable {
    struct ComplexBits: Codable, Sendable, Equatable {
        let real: UInt64
        let imaginary: UInt64
        init(_ value: ComplexPair) { real = value.real.bitPattern; imaginary = value.imag.bitPattern }
        var value: ComplexPair { .init(real: Double(bitPattern: real), imag: Double(bitPattern: imaginary)) }
    }
    struct Port: Codable, Sendable, Equatable {
        let source: String
        let branch: Int
        let positiveNode: Int
        let referenceNode: Int
        let referenceImpedanceBits: UInt64
        let prescribedDCBits: UInt64
    }
    struct Metric: Codable, Sendable, Equatable {
        let valueBits: UInt64?
        let unavailableReason: String?
        init(_ metric: TwoPortStability.Metric) {
            switch metric {
            case .defined(let value): valueBits = value.bitPattern; unavailableReason = nil
            case .undefined(let reason): valueBits = nil; unavailableReason = reason.rawValue
            }
        }
        var value: TwoPortStability.Metric {
            get throws {
                if let valueBits, unavailableReason == nil {
                    let number = Double(bitPattern: valueBits)
                    guard number.isFinite else {
                        throw CoreSpiceCLIOSDIError.incompleteReceipt("Nonfinite saved network stability metric")
                    }
                    return .defined(number)
                }
                guard valueBits == nil, let unavailableReason,
                      let reason = TwoPortStability.Reason(rawValue: unavailableReason) else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved network stability availability")
                }
                return .undefined(reason)
            }
        }
    }
    struct Stability: Codable, Sendable, Equatable {
        let delta: ComplexBits
        let rollettK: Metric
        let mu: Metric
        let reverseMu: Metric
        let satisfiesRollettInequalities: Bool?
        init(_ value: TwoPortStability) {
            delta = .init(value.delta); rollettK = .init(value.rollettK)
            mu = .init(value.mu); reverseMu = .init(value.reverseMu)
            satisfiesRollettInequalities = value.satisfiesRollettInequalities
        }
        var value: TwoPortStability {
            get throws {
                try TwoPortStability(savedDelta: delta.value, rollettK: rollettK.value,
                    mu: mu.value, reverseMu: reverseMu.value,
                    satisfiesRollettInequalities: satisfiesRollettInequalities)
            }
        }
    }
    struct Point: Codable, Sendable {
        let frequencyBits: UInt64
        let y: [ComplexBits]
        let s: [ComplexBits]
        let z: [ComplexBits]?
        let zUnavailableReason: String?
        let stability: Stability?
        let maximumBackwardResidualBits: UInt64
        init(_ point: NetworkParameterPoint) {
            frequencyBits = point.frequency.bitPattern
            y = point.y.values.map(ComplexBits.init); s = point.s.values.map(ComplexBits.init)
            switch point.z {
            case .defined(let matrix): z = matrix.values.map(ComplexBits.init); zUnavailableReason = nil
            case .undefined(let reason): z = nil; zUnavailableReason = reason.rawValue
            }
            stability = point.stability.map(Stability.init)
            maximumBackwardResidualBits = point.maximumBackwardResidual.bitPattern
        }
    }
    struct Limits: Codable, Sendable {
        let maximumPorts: Int
        let maximumFrequencyPoints: Int
        let maximumResultScalars: Int
        let maximumTemporaryBytes: Int
        let residualToleranceBits: UInt64
        let executionLimits: TransientExecutionLimits
        init(_ value: NetworkParameterLimits) {
            maximumPorts = value.maximumPorts; maximumFrequencyPoints = value.maximumFrequencyPoints
            maximumResultScalars = value.maximumResultScalars; maximumTemporaryBytes = value.maximumTemporaryBytes
            residualToleranceBits = value.residualTolerance.bitPattern; executionLimits = value.executionLimits
        }
        var value: NetworkParameterLimits { .init(maximumPorts: maximumPorts, maximumFrequencyPoints: maximumFrequencyPoints,
            maximumResultScalars: maximumResultScalars, maximumTemporaryBytes: maximumTemporaryBytes,
            residualTolerance: Double(bitPattern: residualToleranceBits), executionLimits: executionLimits) }
    }
    let schemaVersion: Int
    let profile: String
    let excitation: String
    let currentConvention: String
    let matrixAxes: String
    let stabilityScope: String
    let sourceInputIdentity: String
    let configurationIdentity: String
    let analysisIndex: Int
    let sourceArtifacts: [ArtifactReference]
    let osdiInstances: [String]
    let ports: [Port]
    let points: [Point]
    let operatingPoint: SPICENativeStoredDCResult
    let limits: Limits
    private let reservation: SPICESourceStorageReservation?
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profile, excitation, currentConvention, matrixAxes, stabilityScope,
             sourceInputIdentity, configurationIdentity, analysisIndex, sourceArtifacts, osdiInstances, ports, points, operatingPoint, limits
    }

    init(_ output: SPICENativeSimulationOutput) throws {
        guard let result = output.networkResult,
              case .network(let frequencies, let requested, let policy) = output.prepared.input.configuration.analysis,
              result.ports == requested, result.points.count == frequencies.count,
              output.phases.map(\.analysis) == ["op", "network"],
              output.phases.map(\.completedPointCount) == [1, frequencies.count] else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing completed network schedule")
        }
        let entries = try CoreSpiceCLIPrecisionExecution.multiply(UInt64(requested.count), UInt64(requested.count))
        let scalarBytes = try CoreSpiceCLIPrecisionExecution.multiply(
            CoreSpiceCLIPrecisionExecution.multiply(entries, UInt64(frequencies.count)), 6 * 8)
        let headers = try CoreSpiceCLIPrecisionExecution.multiply(UInt64(frequencies.count), 512)
        var bytes = try CoreSpiceCLIPrecisionExecution.add(scalarBytes, headers)
        for port in requested { bytes = try CoreSpiceCLIPrecisionExecution.add(bytes, CoreSpiceCLIPrecisionExecution.add(UInt64(port.voltageSourceName.utf8.count), 256)) }
        bytes = try CoreSpiceCLIPrecisionExecution.add(bytes,
            CoreSpiceCLIPrecisionExecution.multiply(UInt64(output.prepared.input.sources.count), 1024))
        reservation = try output.prepared.input.resources.reserveStorage(kind: .liveOwnedBytes, byteCount: bytes)
        schemaVersion = 1; profile = "voltage-controlled.real-power-wave.v1"
        excitation = "unit-port-voltage.other-independent-ac-zero"
        currentConvention = "into-dut.negative-source-branch"
        matrixAxes = "row-response.column-excitation"
        stabilityScope = "pointwise-two-port-algebra.internal-stability-assumed.no-broadband-claim"
        sourceInputIdentity = output.sourceInputIdentity.hexadecimalValue
        configurationIdentity = output.configurationIdentity.hexadecimalValue
        analysisIndex = output.prepared.input.configuration.analysisIndex
        sourceArtifacts = output.prepared.input.sources.map(\.binding.reference)
        osdiInstances = output.prepared.osdiPreparationRecords.map(\.instanceName).sorted()
        let instances = output.prepared.plan.ir.instances
        ports = try requested.map { port in
            let matches = instances.filter { $0.name.lowercased() == port.voltageSourceName.lowercased() }
            guard matches.count == 1, let source = matches.first, source.typeName == "vsource",
                  source.nodes.count == 2, source.ownedBranches.count == 1,
                  case .real(let dc) = source.parameters["v"], dc.isFinite else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing actual network source boundary")
            }
            return Port(source: source.name, branch: source.ownedBranches[0].id,
                positiveNode: source.nodes[0].id, referenceNode: source.nodes[1].id,
                referenceImpedanceBits: port.referenceImpedance.bitPattern, prescribedDCBits: dc.bitPattern)
        }
        points = result.points.map(Point.init)
        operatingPoint = try .init(operatingPoint: result.operatingPoint)
        limits = .init(policy)
        try validate()
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        profile = try c.decode(String.self, forKey: .profile)
        excitation = try c.decode(String.self, forKey: .excitation)
        currentConvention = try c.decode(String.self, forKey: .currentConvention)
        matrixAxes = try c.decode(String.self, forKey: .matrixAxes)
        stabilityScope = try c.decode(String.self, forKey: .stabilityScope)
        sourceInputIdentity = try c.decode(String.self, forKey: .sourceInputIdentity)
        configurationIdentity = try c.decode(String.self, forKey: .configurationIdentity)
        analysisIndex = try c.decode(Int.self, forKey: .analysisIndex)
        sourceArtifacts = try c.decode([ArtifactReference].self, forKey: .sourceArtifacts)
        osdiInstances = try c.decode([String].self, forKey: .osdiInstances)
        ports = try c.decode([Port].self, forKey: .ports)
        points = try c.decode([Point].self, forKey: .points)
        operatingPoint = try c.decode(SPICENativeStoredDCResult.self, forKey: .operatingPoint)
        limits = try c.decode(Limits.self, forKey: .limits)
        reservation = nil
        try validate()
        guard let context = decoder.userInfo[CoreSpiceCLINetworkVerification.key] as? CoreSpiceCLINetworkVerification else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("RF cold import requires CoreSpiceCLIJSON.networkDecoder and explicit verification resources")
        }
        try validateSavedMathematics(context)
    }

    func validate() throws {
        try limits.value.validate()
        guard schemaVersion == 1, profile == "voltage-controlled.real-power-wave.v1",
              excitation == "unit-port-voltage.other-independent-ac-zero",
              currentConvention == "into-dut.negative-source-branch", matrixAxes == "row-response.column-excitation",
              stabilityScope == "pointwise-two-port-algebra.internal-stability-assumed.no-broadband-claim",
              analysisIndex >= 0, !sourceArtifacts.isEmpty,
              osdiInstances == osdiInstances.sorted(), Set(osdiInstances).count == osdiInstances.count,
              osdiInstances.allSatisfy({ !$0.isEmpty }), !ports.isEmpty, ports.count <= limits.maximumPorts,
              !points.isEmpty, points.count <= limits.maximumFrequencyPoints,
              operatingPoint.analysis == "op", operatingPoint.points.count == 1,
              Set(ports.map { $0.source.lowercased() }).count == ports.count,
              Set(ports.map(\.branch)).count == ports.count else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved network profile or schedule")
        }
        for port in ports {
            let reference = Double(bitPattern: port.referenceImpedanceBits)
            guard !port.source.isEmpty, port.branch >= 0, port.positiveNode >= 0, port.referenceNode >= 0,
                  port.positiveNode != port.referenceNode, reference.isFinite, reference > 0,
                  Double(bitPattern: port.prescribedDCBits).isFinite,
                  operatingPoint.rows.contains(where: { $0.kind == .branchCurrent && $0.identifier == port.branch }),
                  [port.positiveNode, port.referenceNode].allSatisfy({ node in node == 0 || operatingPoint.rows.contains { $0.kind == .nodeVoltage && $0.identifier == node } }) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved network port or bias rows")
            }
        }
        for (index, point) in points.enumerated() {
            let frequency = Double(bitPattern: point.frequencyBits)
            let residual = Double(bitPattern: point.maximumBackwardResidualBits)
            guard frequency.isFinite, frequency > 0,
                  index == 0 || frequency > Double(bitPattern: points[index - 1].frequencyBits),
                  residual.isFinite, residual >= 0, residual <= limits.value.residualTolerance else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved network frequency or residual")
            }
            let (square, overflow) = ports.count.multipliedReportingOverflow(by: ports.count)
            guard !overflow, point.y.count == square, point.s.count == square,
                  point.z.map({ $0.count == square }) ?? true,
                  [point.y, point.s, point.z ?? []].allSatisfy({ $0.allSatisfy { $0.value.real.isFinite && $0.value.imag.isFinite } }) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved network matrix shape or finite components")
            }
            if point.z != nil {
                guard point.zUnavailableReason == nil else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Spurious network Z unavailability") }
            } else {
                guard point.zUnavailableReason == "singularAdmittance" else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing network Z availability") }
            }
            guard (point.stability != nil) == (ports.count == 2) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved network stability shape")
            }
            _ = try point.stability?.value
        }
    }

    private func validateSavedMathematics(_ context: CoreSpiceCLINetworkVerification) throws {
        guard context.numerical.limits == limits.executionLimits else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("RF cold verification policy differs from saved numerical limits")
        }
        let requested = try ports.map { try NetworkPort(voltageSourceName: $0.source,
            referenceImpedance: Double(bitPattern: $0.referenceImpedanceBits)) }
        let (square, overflow) = ports.count.multipliedReportingOverflow(by: ports.count)
        guard !overflow else { throw SPICESourceStorageError.arithmeticOverflow }
        let budget = try context.numerical.budget(dimension: ports.count, nonZeroCount: square, deviceCount: 0)
        for point in points {
            try context.source.checkCancellation()
            let bytes = try CoreSpiceCLIPrecisionExecution.add(256,
                CoreSpiceCLIPrecisionExecution.multiply(UInt64(square), 6 * 8))
            let scratch = try context.storage.reserveTemporaryBytes(bytes)
            let y = try NetworkParameterMatrix(portCount: ports.count, values: point.y.map(\.value))
            let s = try NetworkParameterMatrix(portCount: ports.count, values: point.s.map(\.value))
            let z: NetworkImpedanceParameters
            if let values = point.z { z = .defined(try .init(portCount: ports.count, values: values.map(\.value))) }
            else { z = .undefined(.singularAdmittance) }
            _ = try NetworkParameterPoint.validatingSaved(frequency: Double(bitPattern: point.frequencyBits),
                y: y, s: s, z: z, stability: point.stability?.value,
                maximumBackwardResidual: Double(bitPattern: point.maximumBackwardResidualBits), ports: requested,
                limits: limits.value, budget: budget, storage: context.storage, cancellation: context.cancellation)
            withExtendedLifetime(scratch) {}
        }
    }

    func validateWaveform(_ waveform: CoreSpiceCLIPreparedWaveform) throws {
        try validate(); try waveform.validate()
        let count = ports.count
        var names: [String] = []
        for kind in ["S", "Y"] {
            for row in 0..<count { for column in 0..<count { names.append("\(kind)[\(row + 1),\(column + 1)]") } }
        }
        guard waveform.analysis == .networkParameters, waveform.coordinates.map(\.bitPattern) == points.map(\.frequencyBits),
              waveform.sweep.name == "frequency", waveform.sweep.unit == .hertz, waveform.sweep.type == .frequency,
              waveform.variables.map(\.name) == names, let imaginary = waveform.imaginary,
              waveform.options == ["network_profile": profile, "matrix_axes": "response,excitation"] else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved network presentation differs from its canonical axes")
        }
        for (index, variable) in waveform.variables.enumerated() {
            guard variable.type == .parameter, variable.unit == (index < count * count ? SIUnit.dimensionless : .siemens) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved network presentation units differ")
            }
        }
        for (pointIndex, point) in points.enumerated() {
            for (column, value) in (point.s + point.y).enumerated() {
                let offset = pointIndex * names.count + column
                guard waveform.real[offset].bitPattern == value.real, imaginary[offset].bitPattern == value.imaginary else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Saved network presentation component differs")
                }
            }
        }
    }
}
