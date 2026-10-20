import CoreSpiceCompile
import CircuiteFoundation
import CircuiteFoundationFoundation
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIO
import Foundation

/// Complete precision evidence from an actually completed Native transient.
public struct CoreSpiceCLIPrecisionExecution: Codable, Sendable, Hashable {
    public struct EquationRow: Codable, Sendable, Hashable {
        public let row: Int
        public let kind: String
        public let variableAbsoluteTolerance: Double
        public let equationAbsoluteTolerance: Double
        init(row: Int, value: DCEquationRowPolicy) {
            self.row = row
            switch value.kind {
            case .electricalPotential: kind = "electricalPotential"
            case .electricalFlow: kind = "electricalFlow"
            case .thermalPotential: kind = "thermalPotential"
            }
            variableAbsoluteTolerance = value.variableAbsoluteTolerance; equationAbsoluteTolerance = value.equationAbsoluteTolerance
        }
    }
    public struct ColdModel: Codable, Sendable, Hashable {
        public let instanceName: String
        public let program: CoreSpiceCLIPrecisionProgramRecord
        public let workerReference: ArtifactReference
        public let numericProfileSHA256: String
        public let options: CoreSpiceCLIPrecisionOptions
        public let precisionBits: UInt32
        init(_ value: NativeOSDIPreparationRecord) throws {
            guard let receipt = value.transientPrecision else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing completed precision preparation") }
            instanceName = value.instanceName; program = .init(receipt.program); workerReference = receipt.workerReference
            numericProfileSHA256 = receipt.numericProfile.hexadecimalValue; options = .init(receipt.options); precisionBits = receipt.precisionBits
        }
        private enum CodingKeys: String, CodingKey { case instanceName, program, workerReference, numericProfileSHA256, options, precisionBits }
        public init(from decoder: any Decoder) throws { try self.init(from: decoder, maximumBytes: UInt64(Int.max)) }
        init(from decoder: any Decoder, maximumBytes: UInt64) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            instanceName = try c.decode(String.self, forKey: .instanceName)
            workerReference = try c.decode(ArtifactReference.self, forKey: .workerReference)
            numericProfileSHA256 = try c.decode(String.self, forKey: .numericProfileSHA256)
            options = try c.decode(CoreSpiceCLIPrecisionOptions.self, forKey: .options)
            precisionBits = try c.decode(UInt32.self, forKey: .precisionBits)
            _ = try options.checked()
            program = try .init(from: c.superDecoder(forKey: .program), maximumProgramBytes: min(options.maximumProgramBytes, maximumBytes),
                maximumSetupBytes: min(options.maximumMappingBytes, maximumBytes), maximumTotalBytes: maximumBytes)
        }
    }
    public let schemaVersion: Int
    public let configurationSHA256: String
    public let sourceInputIdentity: String
    public let algorithmIdentity: String
    public let solverIdentity: String
    public let legacyBaseDigest: String
    public let executionBudget: CoreSpiceCLIPrecisionExecutionBudget
    public let sources: CoreSpiceCLIPrecisionSources
    public let settings: CoreSpiceCLIPrecisionSettings
    public let equationPolicy: [EquationRow]
    public let coldModels: [ColdModel]
    public let solutionLow: [Double]
    public let highBits: [UInt64]
    public let lowBits: [UInt64]
    public let coordinateBits: [UInt64]
    public let endpointLowComponent: Double
    public let operatingPointRepresentation: String
    public let displayRepresentation: String
    private var storage: Storage? = nil

    /// Reservations retain accounting only; they are not semantic inspection identity.
    private struct Storage: Sendable, Hashable {
        let resources: any SPICESourceResourceAccounting
        let reservation: SPICESourceStorageReservation
        static func == (_ lhs: Self, _ rhs: Self) -> Bool { true }
        func hash(into hasher: inout Hasher) {}
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, configurationSHA256, sourceInputIdentity, algorithmIdentity, solverIdentity, legacyBaseDigest, executionBudget, sources, settings, equationPolicy, coldModels
        case solutionLow, highBits, lowBits, coordinateBits, endpointLowComponent, operatingPointRepresentation, displayRepresentation
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.schemaVersion == rhs.schemaVersion, lhs.configurationSHA256 == rhs.configurationSHA256,
              lhs.sourceInputIdentity == rhs.sourceInputIdentity, lhs.algorithmIdentity == rhs.algorithmIdentity,
              lhs.solverIdentity == rhs.solverIdentity, lhs.legacyBaseDigest == rhs.legacyBaseDigest else { return false }
        guard lhs.executionBudget == rhs.executionBudget, lhs.sources == rhs.sources, lhs.settings == rhs.settings,
              lhs.equationPolicy == rhs.equationPolicy, lhs.coldModels == rhs.coldModels else { return false }
        return lhs.solutionLow == rhs.solutionLow && lhs.highBits == rhs.highBits && lhs.lowBits == rhs.lowBits &&
            lhs.coordinateBits == rhs.coordinateBits && lhs.endpointLowComponent.bitPattern == rhs.endpointLowComponent.bitPattern &&
            lhs.operatingPointRepresentation == rhs.operatingPointRepresentation && lhs.displayRepresentation == rhs.displayRepresentation
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion); hasher.combine(configurationSHA256); hasher.combine(sourceInputIdentity)
        hasher.combine(algorithmIdentity); hasher.combine(solverIdentity); hasher.combine(legacyBaseDigest)
        hasher.combine(executionBudget); hasher.combine(sources); hasher.combine(settings); hasher.combine(equationPolicy)
        hasher.combine(coldModels); hasher.combine(solutionLow); hasher.combine(highBits); hasher.combine(lowBits)
        hasher.combine(coordinateBits); hasher.combine(endpointLowComponent.bitPattern)
        hasher.combine(operatingPointRepresentation); hasher.combine(displayRepresentation)
    }
    init(output: SPICENativeSimulationOutput, budget: CoreSpiceCLIPrecisionExecutionBudget, high: [Double], coordinates: [Double]) throws {
        try budget.validate()
        guard let result = output.transientResult, result.solutionLowTrace != nil,
              let facts = output.phases.first(where: { $0.analysis == (output.fourierResult == nil ? "tran" : "fourier") }), let policy = facts.equationPolicy,
              output.prepared.osdiPreparationRecords.allSatisfy({ $0.transientPrecision != nil }),
              !output.prepared.osdiPreparationRecords.isEmpty else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed precision result, policy or cold receipts missing") }
        var coldBytes: UInt64 = 0
        for value in output.prepared.osdiPreparationRecords {
            guard let receipt = value.transientPrecision else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing precision setup") }
            coldBytes = try Self.add(coldBytes, UInt64(receipt.program.programBytes.count))
            coldBytes = try Self.add(coldBytes, UInt64(receipt.program.setupBytes.count))
        }
        let scalarBytes = try Self.multiply(UInt64(high.count), 24)
        let retained = try Self.add(try Self.add(coldBytes, scalarBytes), try Self.multiply(UInt64(coordinates.count), 8))
        guard retained <= budget.maximumEvidenceBytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Precision retained evidence budget exceeded") }
        let resources = output.prepared.input.resources
        let reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: retained)
        schemaVersion = output.fourierResult == nil ? 1 : 2; configurationSHA256 = output.configurationIdentity.hexadecimalValue
        sourceInputIdentity = output.sourceInputIdentity.hexadecimalValue; algorithmIdentity = output.prepared.algorithmIdentity
        guard let binding = output.prepared.precisionConfigurationBinding else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing actual Native configuration binding") }
        legacyBaseDigest = binding.legacyBaseDigest.hexadecimalValue; solverIdentity = output.prepared.solverIdentity
        executionBudget = budget; sources = .init(output.prepared.input); settings = try .init(output.prepared)
        equationPolicy = policy.rows.enumerated().map { .init(row: $0.offset, value: $0.element) }
        coldModels = try output.prepared.osdiPreparationRecords.map(ColdModel.init)
        var lows: [Double] = []; lows.reserveCapacity(high.count)
        var highs: [UInt64] = []; highs.reserveCapacity(high.count)
        let width = result.variableMap.count
        guard coordinates == result.timePoints, high.count == width * coordinates.count else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Precision result and waveform geometry differ") }
        for point in coordinates.indices {
            try resources.checkCancellation()
            try result.withCompensatedSolution(at: point) { actualHigh, low in
                guard let low, actualHigh.count == width, low.count == width else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing actual low point") }
                for row in 0..<width {
                    guard actualHigh[row].bitPattern == high[point * width + row].bitPattern else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Rounded waveform is not the actual high component") }
                    highs.append(actualHigh[row].bitPattern); lows.append(low[row])
                }
            }
        }
        solutionLow = lows; highBits = highs; lowBits = lows.map(\.bitPattern); coordinateBits = coordinates.map(\.bitPattern)
        endpointLowComponent = 0; operatingPointRepresentation = output.operatingPoint == nil ? "absent-uic" : "binary64"
        displayRepresentation = "rounded-binary64"
        storage = Storage(resources: resources, reservation: reservation)
    }
    private enum SettingsKeys: String, CodingKey { case initialConditions, nodeSets }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        configurationSHA256 = try c.decode(String.self, forKey: .configurationSHA256)
        sourceInputIdentity = try c.decode(String.self, forKey: .sourceInputIdentity)
        algorithmIdentity = try c.decode(String.self, forKey: .algorithmIdentity)
        solverIdentity = try c.decode(String.self, forKey: .solverIdentity)
        legacyBaseDigest = try c.decode(String.self, forKey: .legacyBaseDigest)
        executionBudget = try c.decode(CoreSpiceCLIPrecisionExecutionBudget.self, forKey: .executionBudget); try executionBudget.validate()
        sources = try .init(from: c.superDecoder(forKey: .sources), maximumBytes: executionBudget.maximumEvidenceBytes)
        let rowTable = try c.nestedUnkeyedContainer(forKey: .equationPolicy)
        guard let rowCount = rowTable.count, rowCount <= 8192,
              UInt64(rowCount) <= executionBudget.maximumEvidenceBytes / UInt64(MemoryLayout<EquationRow>.stride) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Equation policy exceeds decode admission")
        }
        let settingsTable = try c.nestedContainer(keyedBy: SettingsKeys.self, forKey: .settings)
        for key in [SettingsKeys.initialConditions, .nodeSets] {
            let values = try settingsTable.nestedUnkeyedContainer(forKey: key)
            guard let count = values.count, count <= 8193 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Initial row binding limit exceeded") }
        }
        settings = try c.decode(CoreSpiceCLIPrecisionSettings.self, forKey: .settings)
        equationPolicy = try c.decode([EquationRow].self, forKey: .equationPolicy)
        var models = try c.nestedUnkeyedContainer(forKey: .coldModels), values: [ColdModel] = []
        let sourceBytes = try sources.captures.reduce(UInt64(0)) { try Self.add($0, UInt64($1.bytes.count)) }
        guard sourceBytes <= executionBudget.maximumEvidenceBytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Source owners exceed evidence ceiling") }
        var remaining = executionBudget.maximumEvidenceBytes - sourceBytes
        while !models.isAtEnd {
            guard values.count < 8192 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Too many cold receipts") }
            let value = try ColdModel(from: models.superDecoder(), maximumBytes: remaining)
            let count = try Self.add(UInt64(value.program.programBytes.count), UInt64(value.program.setupBytes.count))
            guard count <= remaining else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Cold receipts exceed evidence budget") }
            remaining -= count; values.append(value)
        }
        coldModels = values
        var componentBytes = try Self.multiply(UInt64(rowCount), UInt64(MemoryLayout<EquationRow>.stride))
        componentBytes = try Self.add(componentBytes, Self.multiply(UInt64(settings.initialConditions.count + settings.nodeSets.count), UInt64(MemoryLayout<CoreSpiceCLIPrecisionSettings.InitialValue>.stride)))
        for key in [CodingKeys.solutionLow, .highBits, .lowBits, .coordinateBits] {
            let values = try c.nestedUnkeyedContainer(forKey: key)
            guard let count = values.count, count <= 1_000_000,
                  UInt64(count) <= remaining / 8 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Precision component array exceeds explicit admission") }
            componentBytes = try Self.add(componentBytes, Self.multiply(UInt64(count), 8))
            guard componentBytes <= remaining else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Aggregate precision component ownership exceeds evidence admission") }
        }
        solutionLow = try c.decode([Double].self, forKey: .solutionLow)
        highBits = try c.decode([UInt64].self, forKey: .highBits); lowBits = try c.decode([UInt64].self, forKey: .lowBits)
        coordinateBits = try c.decode([UInt64].self, forKey: .coordinateBits)
        endpointLowComponent = try c.decode(Double.self, forKey: .endpointLowComponent)
        operatingPointRepresentation = try c.decode(String.self, forKey: .operatingPointRepresentation)
        displayRepresentation = try c.decode(String.self, forKey: .displayRepresentation)
    }
    func validate(execution: CoreSpiceCLIOSDIExecutionRecord, models: [CoreSpiceCLIOSDIRecord]?) throws {
        _ = try ContentDigest(algorithm: .sha256, hexadecimalValue: configurationSHA256)
        _ = try ContentDigest(algorithm: .sha256, hexadecimalValue: sourceInputIdentity)
        _ = try ContentDigest(algorithm: .sha256, hexadecimalValue: legacyBaseDigest)
        try executionBudget.validate(); try sources.validate(); try settings.validate(rowCount: execution.rows.count)
        guard ((schemaVersion == 1 && settings.analysis == "tran") || (schemaVersion == 2 && settings.analysis == "four")), execution.analysis == "tran", endpointLowComponent.bitPattern == 0,
              algorithmIdentity == "CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v3", solverIdentity == SparseLUSolver.implementationIdentity, displayRepresentation == "rounded-binary64",
              operatingPointRepresentation == (execution.operatingPoint == nil ? "absent-uic" : "binary64"),
              solutionLow.count == execution.real.count, highBits == execution.real.map(\.bitPattern),
              lowBits == solutionLow.map(\.bitPattern), coordinateBits == execution.coordinates.map(\.bitPattern),
              solutionLow.count <= 1_000_000, equationPolicy.count == execution.rows.count,
              equationPolicy.map(\.row) == Array(execution.rows.indices), !coldModels.isEmpty,
              Set(coldModels.map(\.instanceName)).count == coldModels.count else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete precision trace, identity or policy") }
        for index in solutionLow.indices { _ = try CompensatedValue(high: execution.real[index], low: solutionLow[index]) }
        for value in equationPolicy {
            let row = execution.rows[value.row]
            let expected = row.kind == "branch" ? "electricalFlow" : row.unit == "K" ? "thermalPotential" : "electricalPotential"
            guard value.kind == expected, value.variableAbsoluteTolerance.isFinite, value.variableAbsoluteTolerance > 0,
                  value.equationAbsoluteTolerance.isFinite, value.equationAbsoluteTolerance > 0 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid actual equation policy") }
        }
        for value in coldModels {
            try value.program.validate(); _ = try value.options.checked()
            _ = try ContentDigest(algorithm: .sha256, hexadecimalValue: value.numericProfileSHA256)
            guard value.precisionBits >= value.options.minimumPrecisionBits, value.precisionBits <= value.options.maximumPrecisionBits,
                  UInt64(value.program.programBytes.count) <= value.options.maximumProgramBytes,
                  UInt64(value.program.setupBytes.count) <= value.options.maximumMappingBytes else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid completed precision options")
            }
        }
        if let models {
            let outer = models.filter { $0.phase == (settings.analysis == "four" ? "fourier" : "tran") }
            guard Set(outer.map(\.instanceName)) == Set(coldModels.map(\.instanceName)) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing model precision receipt") }
            for cold in coldModels {
                guard let model = outer.first(where: { $0.instanceName == cold.instanceName }),
                      cold.program.modelReference == model.artifact, Int(cold.program.descriptorIndex) == model.descriptorIndex,
                      cold.program.topology.nodes.map(\.name) == model.rawNodeNames,
                      cold.program.topology.nodes.map(\.units) == model.rawNodeUnits,
                      cold.program.topology.nodes.map(\.residualUnits) == model.rawEquationUnits else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Cold model topology or artifact differs from execution")
                }
            }
        }
        for (index, step) in execution.acceptedSteps.enumerated() {
            guard (index != 0 || (step.method == "backwardEuler" && step.previousTimeStepSeconds == nil)),
                  (step.method != "trapezoidal" || step.previousTimeStepSeconds != nil) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Accepted method lacks bootstrap or previous history")
            }
            guard let low = step.timeStepLowComponent, let lowBits = step.timeStepLowBits,
                  step.timeSecondsBits == step.timeSeconds.bitPattern, step.timeStepBits == step.timeStepSeconds.bitPattern,
                  low.bitPattern == lowBits else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing exact accepted interval bits") }
            let actual = try CompensatedValue(high: step.timeSeconds).subtracting(.init(high: execution.coordinates[index]))
            guard actual == (try CompensatedValue(high: step.timeStepSeconds, low: low)) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Accepted interval differs from exact endpoint difference") }
            if let previous = step.previousTimeStepSeconds {
                guard let previousLow = step.previousTimeStepLowComponent,
                      step.previousTimeStepBits == previous.bitPattern, step.previousTimeStepLowBits == previousLow.bitPattern else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete previous interval") }
                _ = try CompensatedValue(high: previous, low: previousLow)
                if index > 0 {
                    let preceding = execution.acceptedSteps[index - 1]
                    guard previous.bitPattern == preceding.timeStepSeconds.bitPattern, previousLow.bitPattern == preceding.timeStepLowComponent?.bitPattern else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Previous interval history differs") }
                }
            } else if step.previousTimeStepLowComponent != nil || step.previousTimeStepBits != nil || step.previousTimeStepLowBits != nil {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Previous low interval lacks a high component")
            }
        }
        guard execution.coordinates.last == settings.transient.stopTime,
              settings.transient.useInitialConditions == (execution.operatingPoint == nil) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed schedule and effective initialization differ") }
        let upper = try serializedUpperBound(execution: execution, models: models)
        // Inner decoding checks intrinsic geometry only. A complete outer record
        // supplies its model receipts and must verify the Native-owned commitment.
        if let models {
            let resources: any SPICESourceResourceAccounting
            if let storage { resources = storage.resources }
            else {
                resources = try SPICESimulationResources(maximumLiveBytes: executionBudget.maximumLiveOwnedBytes,
                    maximumTemporaryBytes: executionBudget.maximumTemporaryBytes,
                    maximumWorkUnits: UInt64(settings.numericalLimits.maximumWorkUnits), maximumHashedBytes: executionBudget.maximumHashedBytes)
            }
            let scratch = try resources.reserveStorage(kind: .temporaryBytes, byteCount: upper)
            defer { withExtendedLifetime(scratch) {} }
            let facts = try nativeFacts(execution: execution, models: models)
            try NativePrecisionConfigurationVerification().verify(facts,
                binding: .init(legacyBaseDigest: .init(algorithm: .sha256, hexadecimalValue: legacyBaseDigest)),
                expectedIdentity: .init(algorithm: .sha256, hexadecimalValue: configurationSHA256),
                maximumEncodingBytes: executionBudget.maximumEvidenceBytes, resources: resources)
        }
    }
    func serializedUpperBound(execution: CoreSpiceCLIOSDIExecutionRecord, models: [CoreSpiceCLIOSDIRecord]? = nil) throws -> UInt64 {
        var binary: UInt64 = 0, metadata: UInt64 = 65536
        func text(_ value: String) throws { metadata = try Self.add(metadata, Self.multiply(UInt64(value.utf8.count), 6)) }
        func reference(_ value: ArtifactReference) throws {
            try text(value.descriptor.role.rawValue); try text(value.descriptor.kind.rawValue); try text(value.descriptor.format.rawValue)
            metadata = try Self.add(metadata, 512)
        }
        try text(sources.rootKey)
        for occurrence in sources.occurrences {
            try text(occurrence.key)
            if let kind = occurrence.kind { try text(kind) }
            if let section = occurrence.parentSection { try text(section) }
            if let section = occurrence.selectedSection { try text(section) }
            metadata = try Self.add(metadata, 1024)
        }
        for source in sources.captures { try reference(source.reference); binary = try Self.add(binary, UInt64(source.bytes.count)); metadata = try Self.add(metadata, UInt64(source.key.utf8.count) * 6 + 1024) }
        for model in coldModels {
            try reference(model.workerReference); try reference(model.program.modelReference)
            binary = try Self.add(binary, UInt64(model.program.programBytes.count)); binary = try Self.add(binary, UInt64(model.program.setupBytes.count))
            for node in model.program.topology.nodes { metadata = try Self.add(metadata, UInt64(node.name.utf8.count + node.units.utf8.count + node.residualUnits.utf8.count) * 6 + 512) }
            metadata = try Self.add(metadata, UInt64(model.instanceName.utf8.count) * 6 + 4096)
        }
        for row in execution.rows { metadata = try Self.add(metadata, UInt64(row.sourceName?.utf8.count ?? 0) * 6 + 512) }
        for column in execution.columns + (execution.projection?.columns ?? []) { metadata = try Self.add(metadata, UInt64(column.name.utf8.count + column.unit.utf8.count) * 6 + 512) }
        if let models {
            for model in models {
                try text(model.instanceName); try text(model.modelName); try text(model.expectedDescriptorName); try reference(model.artifact)
                for name in model.rawNodeNames + model.rawNodeUnits + model.rawEquationUnits { try text(name) }
                let rawCount = try Self.multiply(UInt64(model.rawNodeGlobalRows.count), 96)
                metadata = try Self.add(metadata, rawCount)
                for parameter in model.simulationParameters {
                    try text(parameter.name)
                    if let value = parameter.stringValue { try text(value) }
                    metadata = try Self.add(metadata, 512)
                }
                for parameter in model.modelParameters + model.instanceParameters + model.resolvedParameters {
                    try text(parameter.name)
                    if case .string(let value) = try parameter.assignment().value { try text(value) }
                    metadata = try Self.add(metadata, 512)
                }
                metadata = try Self.add(metadata, Self.multiply(UInt64(model.previousState.count), 64))
            }
        }
        metadata = try Self.add(metadata, Self.multiply(UInt64(settings.initialConditions.count + settings.nodeSets.count), 256))
        let scalarCount = execution.real.count + (execution.imaginary?.count ?? 0) + solutionLow.count + highBits.count + lowBits.count + coordinateBits.count + execution.coordinates.count + (execution.operatingPoint?.count ?? 0) + execution.acceptedSteps.count * 12 + (execution.projection?.real.count ?? 0)
        guard scalarCount <= 1_000_000 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Complete paired evidence scalar budget exceeded") }
        let upper = try Self.add(try Self.add(try Self.multiply(binary, 2), try Self.multiply(UInt64(scalarCount), 64)), metadata)
        guard upper <= executionBudget.maximumEvidenceBytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Serialized precision evidence exceeds explicit ceiling") }
        return upper
    }
    func withSerialization<R>(upperBound: UInt64, _ body: () throws -> R) throws -> R {
        guard upperBound <= executionBudget.maximumEvidenceBytes else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Evidence output ceiling exceeded") }
        if let storage {
            let reservation = try storage.resources.reserveStorage(kind: .temporaryBytes, byteCount: try Self.multiply(upperBound, 3))
            defer { withExtendedLifetime(reservation) {} }
            return try body()
        }
        return try body()
    }
    static func add(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Evidence byte count overflow") }; return value
    }
    static func multiply(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Evidence byte count overflow") }; return value
    }
}
