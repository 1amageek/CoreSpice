import CoreSpiceCompile
import CircuiteFoundation
import CoreSpiceAnalysis
import CoreSpiceIO
import CoreSpiceParsedIR
import OSDIContracts

/// Cold, bounded configuration verification. Performs no source parsing or model evaluation.
public struct NativePrecisionConfigurationVerification: Sendable {
    public enum Failure: Error {
        case invalidFacts(String)
        case identityMismatch
        case resource(any Error)
    }
    public init() {}
    public func verify(_ facts: NativePrecisionConfigurationFacts, binding: NativePrecisionConfigurationBinding,
                       expectedIdentity: ContentDigest, maximumEncodingBytes: UInt64,
                       resources: any SPICESourceResourceAccounting) throws(Failure) {
        guard try identity(facts, binding: binding, maximumEncodingBytes: maximumEncodingBytes, resources: resources) == expectedIdentity else {
            throw .identityMismatch
        }
    }
    public func identity(_ facts: NativePrecisionConfigurationFacts, binding: NativePrecisionConfigurationBinding,
                         maximumEncodingBytes: UInt64, resources: any SPICESourceResourceAccounting) throws(Failure) -> ContentDigest {
        do {
            let digest = try SPICEPreparationEncoding.digest(domain: "CoreSpice.native-precision-replay-facts.v1",
                maximumBytes: maximumEncodingBytes, resources: resources) { try Self.encode(facts, into: &$0) }
            return try SPICEPreparationEncoding.digest(domain: "CoreSpice.native-configuration.v6.osdi-precision-binding",
                maximumBytes: maximumEncodingBytes, resources: resources) { encoding in
                try Self.digest(binding.legacyBaseDigest, into: &encoding)
                try Self.digest(digest, into: &encoding)
            }
        } catch let failure as Failure { throw failure }
        catch { throw .resource(error) }
    }

    internal static func policiesMatch(_ actual: DCEquationPolicy?, _ committed: [DCEquationRowPolicy]) -> Bool {
        guard let actual, actual.rows.count == committed.count else { return false }
        for index in committed.indices {
            let left = actual.rows[index], right = committed[index]
            guard left.kind == right.kind,
                  left.variableAbsoluteTolerance.bitPattern == right.variableAbsoluteTolerance.bitPattern,
                  left.equationAbsoluteTolerance.bitPattern == right.equationAbsoluteTolerance.bitPattern else { return false }
        }
        return true
    }

    private static func encode(_ facts: NativePrecisionConfigurationFacts, into e: inout SPICEPreparationEncoding) throws {
        guard facts.algorithmIdentity == "CoreSpice.NativeCPU.OSDI.op-ac-tran-noise.precision.v3",
              facts.solverIdentity == SparseLUSolver.implementationIdentity, !facts.coldModels.isEmpty,
              !facts.captures.isEmpty, !facts.occurrences.isEmpty, !facts.equationPolicy.isEmpty,
              facts.occurrences.first?.key == facts.rootKey else { throw Failure.invalidFacts("Missing precision configuration facts") }
        try digest(facts.sourceInputIdentity, into: &e)
        try e.field(facts.algorithmIdentity); try e.field(facts.solverIdentity)
        try settings(facts.settings, into: &e)
        try e.field(facts.rootKey); try count(facts.captures.count, into: &e)
        for capture in facts.captures { try e.field(capture.key); try reference(capture.reference, into: &e) }
        try count(facts.occurrences.count, into: &e)
        for occurrence in facts.occurrences {
            try e.field(occurrence.key); try e.integer(occurrence.occurrenceID)
            try optional(occurrence.parentOccurrenceID, into: &e); try optional(occurrence.statementByteOffset, into: &e)
            try optional(occurrence.statementOrdinal, into: &e); try optional(occurrence.kind, into: &e)
            try optional(occurrence.parentSection, into: &e); try optional(occurrence.selectedSection, into: &e)
        }
        guard facts.compiledRows.count == facts.equationPolicy.count else { throw Failure.invalidFacts("Compiled rows differ from equation policy") }
        try count(facts.compiledRows.count, into: &e)
        for (index, row) in facts.compiledRows.enumerated() {
            guard row.row == index,
                  (row.kind == "node" && ["V", "K"].contains(row.unit)) || (row.kind == "branch" && row.unit == "A") else {
                throw Failure.invalidFacts("Invalid compiled row descriptor")
            }
            try count(row.row, into: &e); try e.field(row.kind); try optional(row.sourceName, into: &e); try e.field(row.unit)
        }
        try count(facts.equationPolicy.count, into: &e)
        for row in facts.equationPolicy {
            switch row.kind {
            case .electricalPotential: try e.field("electricalPotential")
            case .electricalFlow: try e.field("electricalFlow")
            case .thermalPotential: try e.field("thermalPotential")
            }
            try e.number(row.variableAbsoluteTolerance); try e.number(row.equationAbsoluteTolerance)
        }
        try count(facts.coldModels.count, into: &e)
        for model in facts.coldModels { try coldModel(model, rowCount: facts.equationPolicy.count, into: &e) }
    }

    private static func settings(_ value: NativePrecisionConfigurationFacts.Settings, into e: inout SPICEPreparationEncoding) throws {
        try e.field("tran"); try count(value.analysisIndex, into: &e); try e.integer(value.seed)
        let c = value.convergence, t = value.transient, l = value.numericalLimits
        for number in [c.abstol, c.reltol, c.vntol, c.gmin, c.minDamping, c.opticalPowerTolerance] { try e.number(number) }
        try count(c.maxIterations, into: &e)
        for number in [t.stopTime, t.maxTimeStep, t.minTimeStep, t.lteTolerance, t.shrinkFactor] { try e.number(number) }
        if let initial = t.initialTimeStep { try e.integer(1); try e.number(initial) } else { try e.integer(0) }
        try e.field(t.preferredMethod == .backwardEuler ? "backwardEuler" : "trapezoidal")
        try e.integer(t.useInitialConditions ? 1 : 0)
        try count(t.maxTimeStepReductions, into: &e); try count(t.gminSteppingThreshold, into: &e)
        for number in [t.gminStepping.initialGmin, t.gminStepping.finalGmin, t.gminStepping.reductionFactor] { try e.number(number) }
        try count(t.gminStepping.maxSteps, into: &e)
        for limit in [l.maximumAcceptedSteps, l.maximumSolveAttempts, l.maximumNewtonIterations, l.maximumSavedScalars,
                      l.maximumMatrixDimension, l.maximumWorkUnits, l.maximumBreakpoints] { try count(limit, into: &e) }
        for values in [value.initialConditions, value.nodeSets] {
            try count(values.count, into: &e)
            for initial in values {
                if let row = initial.row { try e.integer(1); try count(row, into: &e) } else { try e.integer(0) }
                try e.number(initial.value)
            }
        }
        try e.number(value.temperatureKelvin); try e.number(value.nominalTemperatureKelvin)
    }

    private static func coldModel(_ model: NativePrecisionConfigurationFacts.ColdModel, rowCount: Int,
                                  into e: inout SPICEPreparationEncoding) throws {
        guard model.rawNodeGlobalRows.count == model.topology.nodes.count,
              model.precisionBits >= model.options.minimumPrecisionBits, model.precisionBits <= model.options.maximumPrecisionBits,
              model.programByteCount > 0, model.setupByteCount > 0,
              model.programByteCount <= model.options.maximumProgramBytes, model.setupByteCount <= model.options.maximumMappingBytes else {
            throw Failure.invalidFacts("Invalid cold model geometry or precision policy")
        }
        try e.field(model.instanceName); try e.field(model.modelName); try reference(model.modelReference, into: &e)
        try e.integer(UInt64(model.descriptorIndex)); try e.field(model.expectedDescriptorName)
        for assignments in [model.modelParameters, model.instanceParameters] {
            try count(assignments.count, into: &e)
            for value in assignments { try assignment(value, into: &e) }
        }
        try count(model.previousState.count, into: &e)
        for value in model.previousState { try e.number(value) }
        try count(model.resolvedParameters.count, into: &e)
        for value in model.resolvedParameters {
            try assignment(value.assignment, into: &e); try count(value.descriptorIndex, into: &e); try e.integer(value.isGiven ? 1 : 0)
        }
        try e.number(model.effectiveKelvin)
        try count(model.topology.activeUnknownCount, into: &e); try count(model.topology.stateCount, into: &e)
        try count(model.topology.nodes.count, into: &e)
        for node in model.topology.nodes {
            try count(node.index, into: &e); try e.field(node.name); try e.field(node.units); try e.field(node.residualUnits)
            try e.integer(node.isFlow ? 1 : 0)
            try e.integer(UInt64(node.unknownNature.kind)); try e.integer(UInt64(node.unknownNature.index))
            try e.integer(UInt64(node.residualNature.kind)); try e.integer(UInt64(node.residualNature.index))
            if let index = node.activeUnknownIndex { try e.integer(1); try count(index, into: &e) } else { try e.integer(0) }
        }
        try count(model.rawNodeGlobalRows.count, into: &e)
        for row in model.rawNodeGlobalRows {
            if let row {
                guard row >= 0 && row < rowCount else { throw Failure.invalidFacts("Cold row outside compiled policy") }
                try e.integer(1); try count(row, into: &e)
            } else { try e.integer(0) }
        }
        try digest(model.programDigest, into: &e); try e.integer(model.programByteCount)
        try digest(model.setupDigest, into: &e); try e.integer(model.setupByteCount)
        try digest(model.semanticProfile, into: &e); try reference(model.workerReference, into: &e)
        try digest(model.numericProfile, into: &e); try e.integer(UInt64(model.precisionBits))
        let o = model.options
        for value in [o.maximumProgramBytes, o.maximumMappingBytes, o.arenaBytes, o.maximumWorkUnits,
                      UInt64(o.minimumPrecisionBits), UInt64(o.maximumPrecisionBits), o.startupTimeoutNanoseconds,
                      o.evaluationTimeoutNanoseconds, o.cleanupTimeoutNanoseconds, o.pollNanoseconds] { try e.integer(value) }
    }
    private static func assignment(_ value: OSDIParameterAssignment, into e: inout SPICEPreparationEncoding) throws {
        try e.field(value.name); try e.integer(UInt64(value.scope.rawValue))
        switch value.value {
        case .real(let value): try e.field("real"); try e.number(value)
        case .integer(let value): try e.field("integer"); try e.integer(UInt64(bitPattern: Int64(value)))
        case .string(let value): try e.field("string"); try e.field(value)
        }
    }
    private static func reference(_ value: ArtifactReference, into e: inout SPICEPreparationEncoding) throws {
        try digest(value.digest, into: &e); try e.integer(value.byteCount)
        try e.field(value.descriptor.role.rawValue); try e.field(value.descriptor.kind.rawValue); try e.field(value.descriptor.format.rawValue)
    }
    private static func digest(_ value: ContentDigest, into e: inout SPICEPreparationEncoding) throws {
        try e.field(value.algorithm.rawValue); try e.field(value.hexadecimalValue)
    }
    private static func count(_ value: Int, into e: inout SPICEPreparationEncoding) throws {
        guard let value = UInt64(exactly: value) else { throw Failure.invalidFacts("Negative configuration count or index") }
        try e.integer(value)
    }
    private static func optional(_ value: UInt64?, into e: inout SPICEPreparationEncoding) throws {
        if let value { try e.integer(1); try e.integer(value) } else { try e.integer(0) }
    }
    private static func optional(_ value: String?, into e: inout SPICEPreparationEncoding) throws {
        if let value { try e.integer(1); try e.field(value) } else { try e.integer(0) }
    }
}
