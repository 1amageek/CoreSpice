import CoreSpiceCompile
import CircuiteFoundation
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceIR
import CoreSpiceParsedIR
import OSDIContracts

/// Immutable descriptive inputs committed by actual Native precision preparation.
public struct NativePrecisionConfigurationFacts: Sendable {
    public let sourceInputIdentity: ContentDigest
    public let algorithmIdentity: String
    public let solverIdentity: String
    public let settings: Settings
    public let rootKey: String
    public let captures: [Capture]
    public let occurrences: [Occurrence]
    public let compiledRows: [CompiledRow]
    public let equationPolicy: [DCEquationRowPolicy]
    public let coldModels: [ColdModel]
    private let reservation: SPICESourceStorageReservation?

    public init(sourceInputIdentity: ContentDigest, algorithmIdentity: String, solverIdentity: String,
                settings: Settings, rootKey: String, captures: [Capture], occurrences: [Occurrence],
                compiledRows: [CompiledRow], equationPolicy: [DCEquationRowPolicy], coldModels: [ColdModel]) {
        self.sourceInputIdentity = sourceInputIdentity; self.algorithmIdentity = algorithmIdentity
        self.solverIdentity = solverIdentity; self.settings = settings; self.rootKey = rootKey
        self.captures = captures; self.occurrences = occurrences; self.compiledRows = compiledRows
        self.equationPolicy = equationPolicy; self.coldModels = coldModels
        reservation = nil
    }
    private init(retaining facts: Self, reservation: SPICESourceStorageReservation) {
        sourceInputIdentity = facts.sourceInputIdentity; algorithmIdentity = facts.algorithmIdentity; solverIdentity = facts.solverIdentity
        settings = facts.settings; rootKey = facts.rootKey; captures = facts.captures; occurrences = facts.occurrences
        compiledRows = facts.compiledRows; equationPolicy = facts.equationPolicy; coldModels = facts.coldModels; self.reservation = reservation
    }
    public struct CompiledRow: Sendable {
        public let row: Int
        public let kind: String
        public let sourceName: String?
        public let unit: String
        public init(row: Int, kind: String, sourceName: String?, unit: String) {
            self.row = row; self.kind = kind; self.sourceName = sourceName; self.unit = unit
        }
    }
    public struct InitialValue: Sendable {
        public let row: Int?
        public let value: Double
        public init(row: Int?, value: Double) { self.row = row; self.value = value }
    }
    public struct Settings: Sendable {
        public let analysisIndex: Int
        public let seed: UInt64
        public let convergence: ConvergenceConfig
        public let transient: TransientConfig
        public let numericalLimits: TransientExecutionLimits
        public let initialConditions: [InitialValue]
        public let nodeSets: [InitialValue]
        public let temperatureKelvin: Double
        public let nominalTemperatureKelvin: Double
        /// Node dictionaries are represented by the explicit compiled row bindings.
        public init(analysisIndex: Int, seed: UInt64, convergence: ConvergenceConfig, transient: TransientConfig,
                    numericalLimits: TransientExecutionLimits, initialConditions: [InitialValue], nodeSets: [InitialValue],
                    temperatureKelvin: Double, nominalTemperatureKelvin: Double) {
            self.analysisIndex = analysisIndex; self.seed = seed; self.convergence = convergence; self.transient = transient
            self.numericalLimits = numericalLimits; self.initialConditions = initialConditions; self.nodeSets = nodeSets
            self.temperatureKelvin = temperatureKelvin; self.nominalTemperatureKelvin = nominalTemperatureKelvin
        }
    }
    public struct Capture: Sendable {
        public let key: String
        public let reference: ArtifactReference
        public init(key: String, reference: ArtifactReference) { self.key = key; self.reference = reference }
    }
    public struct Occurrence: Sendable {
        public let key: String
        public let occurrenceID: UInt64
        public let parentOccurrenceID: UInt64?
        public let statementByteOffset: UInt64?
        public let statementOrdinal: UInt64?
        public let kind: String?
        public let parentSection: String?
        public let selectedSection: String?
        public init(key: String, occurrenceID: UInt64, parentOccurrenceID: UInt64?, statementByteOffset: UInt64?,
                    statementOrdinal: UInt64?, kind: String?, parentSection: String?, selectedSection: String?) {
            self.key = key; self.occurrenceID = occurrenceID; self.parentOccurrenceID = parentOccurrenceID
            self.statementByteOffset = statementByteOffset; self.statementOrdinal = statementOrdinal; self.kind = kind
            self.parentSection = parentSection; self.selectedSection = selectedSection
        }
    }
    public struct Nature: Sendable {
        public let kind: UInt32
        public let index: UInt32
        public init(kind: UInt32, index: UInt32) { self.kind = kind; self.index = index }
    }
    public struct Node: Sendable {
        public let index: Int
        public let name: String
        public let units: String
        public let residualUnits: String
        public let isFlow: Bool
        public let unknownNature: Nature
        public let residualNature: Nature
        public let activeUnknownIndex: Int?
        public init(index: Int, name: String, units: String, residualUnits: String, isFlow: Bool,
                    unknownNature: Nature, residualNature: Nature, activeUnknownIndex: Int?) {
            self.index = index; self.name = name; self.units = units; self.residualUnits = residualUnits; self.isFlow = isFlow
            self.unknownNature = unknownNature; self.residualNature = residualNature; self.activeUnknownIndex = activeUnknownIndex
        }
    }
    public struct Topology: Sendable {
        public let nodes: [Node]
        public let activeUnknownCount: Int
        public let stateCount: Int
        public init(nodes: [Node], activeUnknownCount: Int, stateCount: Int) {
            self.nodes = nodes; self.activeUnknownCount = activeUnknownCount; self.stateCount = stateCount
        }
    }
    public struct ResolvedParameter: Sendable {
        public let assignment: OSDIParameterAssignment
        public let descriptorIndex: Int
        public let isGiven: Bool
        public init(assignment: OSDIParameterAssignment, descriptorIndex: Int, isGiven: Bool) {
            self.assignment = assignment; self.descriptorIndex = descriptorIndex; self.isGiven = isGiven
        }
    }
    public struct ColdModel: Sendable {
        public let instanceName: String
        public let modelName: String
        public let modelReference: ArtifactReference
        public let descriptorIndex: UInt32
        public let expectedDescriptorName: String
        public let modelParameters: [OSDIParameterAssignment]
        public let instanceParameters: [OSDIParameterAssignment]
        public let previousState: [Double]
        public let resolvedParameters: [ResolvedParameter]
        public let effectiveKelvin: Double
        public let topology: Topology
        public let rawNodeGlobalRows: [Int?]
        public let programDigest: ContentDigest
        public let programByteCount: UInt64
        public let setupDigest: ContentDigest
        public let setupByteCount: UInt64
        public let semanticProfile: ContentDigest
        public let workerReference: ArtifactReference
        public let numericProfile: ContentDigest
        public let options: OSDIPrecisionOptions
        public let precisionBits: UInt32
        public let simulationParameters: [OSDISimulationParameter]
        public init(instanceName: String, modelName: String, modelReference: ArtifactReference, descriptorIndex: UInt32,
                    expectedDescriptorName: String, modelParameters: [OSDIParameterAssignment], instanceParameters: [OSDIParameterAssignment],
                    previousState: [Double], resolvedParameters: [ResolvedParameter], effectiveKelvin: Double,
                    topology: Topology, rawNodeGlobalRows: [Int?], programDigest: ContentDigest, programByteCount: UInt64,
                    setupDigest: ContentDigest, setupByteCount: UInt64, semanticProfile: ContentDigest,
                    workerReference: ArtifactReference, numericProfile: ContentDigest, options: OSDIPrecisionOptions, precisionBits: UInt32,
                    simulationParameters: [OSDISimulationParameter] = []) {
            self.simulationParameters = simulationParameters
            self.instanceName = instanceName; self.modelName = modelName; self.modelReference = modelReference
            self.descriptorIndex = descriptorIndex; self.expectedDescriptorName = expectedDescriptorName
            self.modelParameters = modelParameters; self.instanceParameters = instanceParameters; self.previousState = previousState
            self.resolvedParameters = resolvedParameters; self.effectiveKelvin = effectiveKelvin; self.topology = topology
            self.rawNodeGlobalRows = rawNodeGlobalRows; self.programDigest = programDigest; self.programByteCount = programByteCount
            self.setupDigest = setupDigest; self.setupByteCount = setupByteCount; self.semanticProfile = semanticProfile
            self.workerReference = workerReference; self.numericProfile = numericProfile; self.options = options; self.precisionBits = precisionBits
        }
    }
}

extension NativePrecisionConfigurationFacts {
    internal static func metadataByteCount(input: PreparedSPICESimulation, common: NativeCircuitPreparationRecord) throws -> UInt64 {
        var bytes = UInt64(MemoryLayout<Self>.stride)
        func add(_ count: Int, _ stride: Int, factor: UInt64 = 4) throws {
            let (size, overflow) = UInt64(count).multipliedReportingOverflow(by: UInt64(stride))
            let (capacity, second) = size.multipliedReportingOverflow(by: factor)
            let (next, third) = bytes.addingReportingOverflow(capacity)
            guard !overflow, !second, !third else { throw SPICENativePreparationError.capacityExceeded }; bytes = next
        }
        // Four logical table/array generations cover construction and retained capacity.
        // Policy construction additionally owns its optional row scratch; initial-row
        // sorting may coexist with both arrays. Immutable strings/assignments/maps are COW.
        try add(input.sources.count, MemoryLayout<Capture>.stride)
        try add(input.sourceOccurrences.count, MemoryLayout<Occurrence>.stride)
        try add(common.plan.topology.dimension, MemoryLayout<DCEquationRowPolicy?>.stride, factor: 8)
        try add(common.plan.topology.dimension, MemoryLayout<CompiledRow?>.stride, factor: 8)
        switch input.configuration.analysis {
        case .transient(let transient), .fourier(_, _, let transient):
            try add(transient.initialNodeVoltages.count + transient.nodeVoltageGuesses.count, MemoryLayout<InitialValue>.stride, factor: 8)
        default: break
        }
        try add(common.osdiPreparationRecords.count, MemoryLayout<ColdModel>.stride)
        for model in common.osdiPreparationRecords {
            try add(model.receipt.topology.nodes.count, MemoryLayout<Node>.stride)
            try add(model.receipt.resolvedParameters.count, MemoryLayout<ResolvedParameter>.stride)
        }
        return bytes
    }

    internal static func prepared(input: PreparedSPICESimulation, common: NativeCircuitPreparationRecord,
                                  reservation: SPICESourceStorageReservation) throws -> Self {
        let transient: TransientConfig
        switch input.configuration.analysis {
        case .transient(let config), .fourier(_, _, let config): transient = config
        default: throw NativePrecisionConfigurationVerification.Failure.invalidFacts("Precision binding requires transient settings")
        }
        let config = input.configuration
        let ground = common.plan.ir.groundNode
        func initial(_ values: [CoreSpiceIR.Node: Double]) throws -> [InitialValue] {
            try values.map { node, value in
                let row = common.plan.topology.variableMap[.nodeVoltage(node)]
                guard row != nil || (node == ground && value == 0) else {
                    throw NativePrecisionConfigurationVerification.Failure.invalidFacts("Initial node outside compiled rows")
                }
                return InitialValue(row: row, value: value)
            }.sorted { ($0.row ?? -1) < ($1.row ?? -1) }
        }
        let settings = try Settings(analysisIndex: config.analysisIndex, seed: config.seed, convergence: config.options.convergence,
            transient: transient, numericalLimits: config.numericalLimits, initialConditions: initial(transient.initialNodeVoltages),
            nodeSets: initial(transient.nodeVoltageGuesses), temperatureKelvin: common.operatingConditions.temperatureKelvin,
            nominalTemperatureKelvin: common.operatingConditions.nominalTemperatureKelvin)
        let captures = input.sources.map { Capture(key: $0.binding.key, reference: $0.binding.reference) }
        let occurrences = input.sourceOccurrences.map { value in
            Occurrence(key: value.source.binding.key, occurrenceID: value.occurrenceID.rawValue,
                parentOccurrenceID: value.parentOccurrenceID?.rawValue, statementByteOffset: value.statementByteOffset,
                statementOrdinal: value.statementOrdinal, kind: value.kind?.rawValue,
                parentSection: value.parentSection, selectedSection: value.selectedSection)
        }
        var compiledRows = [CompiledRow?](repeating: nil, count: common.plan.topology.dimension)
        for (variable, row) in common.plan.topology.variableMap {
            guard compiledRows.indices.contains(row), compiledRows[row] == nil else {
                throw NativePrecisionConfigurationVerification.Failure.invalidFacts("Invalid compiled row mapping")
            }
            switch variable {
            case .nodeVoltage(let node):
                compiledRows[row] = CompiledRow(row: row, kind: "node", sourceName: common.plan.ir.nodeNames[node],
                    unit: common.osdiVariableKinds[variable] == .thermalPotential ? "K" : "V")
            case .branchCurrent(let branch):
                compiledRows[row] = CompiledRow(row: row, kind: "branch", sourceName: common.plan.ir.branchNames[branch], unit: "A")
            }
        }
        let rows = try compiledRows.map { value in
            guard let value else { throw NativePrecisionConfigurationVerification.Failure.invalidFacts("Missing compiled row") }; return value
        }
        let models = try common.osdiPreparationRecords.map { value -> ColdModel in
            guard let precision = value.transientPrecision else {
                throw NativePrecisionConfigurationVerification.Failure.invalidFacts("Missing actual precision receipt")
            }
            let receipt = value.receipt, binding = receipt.resolved.binding, program = precision.program
            let nodes = program.topology.nodes.map { value in
                Node(index: value.index, name: value.name, units: value.units, residualUnits: value.residualUnits,
                    isFlow: value.isFlow, unknownNature: Nature(kind: value.unknownNature.kind, index: value.unknownNature.index),
                    residualNature: Nature(kind: value.residualNature.kind, index: value.residualNature.index),
                    activeUnknownIndex: value.activeUnknownIndex)
            }
            let resolved = try receipt.resolvedParameters.map { value -> ResolvedParameter in
                guard let name = value.parameter.names.first else {
                    throw NativePrecisionConfigurationVerification.Failure.invalidFacts("Resolved parameter lacks name")
                }
                return try ResolvedParameter(assignment: OSDIParameterAssignment(name: name, scope: value.scope, value: value.value),
                    descriptorIndex: value.parameter.index, isGiven: value.isGiven)
            }
            return ColdModel(instanceName: value.instanceName, modelName: binding.modelName, modelReference: binding.artifact,
                descriptorIndex: program.descriptorIndex, expectedDescriptorName: binding.expectedDescriptorName,
                modelParameters: binding.modelParameters, instanceParameters: receipt.resolved.instanceParameters,
                previousState: receipt.resolved.previousState, resolvedParameters: resolved, effectiveKelvin: receipt.effectiveTemperatureKelvin,
                topology: Topology(nodes: nodes, activeUnknownCount: program.topology.activeUnknownCount, stateCount: program.topology.stateCount),
                rawNodeGlobalRows: value.rawNodeGlobalRows, programDigest: program.programDigest, programByteCount: UInt64(program.programByteCount),
                setupDigest: program.setupDigest, setupByteCount: UInt64(program.setupByteCount), semanticProfile: program.semanticProfile,
                workerReference: precision.workerReference, numericProfile: precision.numericProfile, options: precision.options, precisionBits: precision.precisionBits,
                simulationParameters: receipt.simulationParameters)
        }
        let result = Self(sourceInputIdentity: input.sourceInputIdentity, algorithmIdentity: SPICENativeSimulationRecord.algorithmIdentity(for: common),
            solverIdentity: SparseLUSolver.implementationIdentity, settings: settings, rootKey: occurrences.first?.key ?? "",
            captures: captures, occurrences: occurrences, compiledRows: rows,
            equationPolicy: try NativeOSDIPhysicalValidator.policy(record: common, config: config.options.convergence).rows,
            coldModels: models)
        return Self(retaining: result, reservation: reservation)
    }
}
