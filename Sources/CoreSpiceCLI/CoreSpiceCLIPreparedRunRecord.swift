import CoreSpice
import CoreSpiceIO
import CoreSpiceAnalysis
import CoreSpiceCompile
import CoreSpiceIR
import CoreSpiceWaveform
import CircuiteFoundation
import CircuiteFoundationCrypto
import Foundation

/// Inspection-only completed summary; decoding cannot authorize executable state.
struct CoreSpiceCLIPreparedRunRecord: Codable, Sendable {
    let network: CoreSpiceCLINetworkRecord?
    let transferFunction: CoreSpiceCLITransferFunctionRecord?
    let sensitivityEvidence: CoreSpiceCLISensitivityEvidence?
    let fourierTransientExecution: CoreSpiceCLIOSDIExecutionRecord?
    let generalMOSModels: [CoreSpiceCLIPreparedMOSModel]?
    let sourceReexecutions: [CoreSpiceCLIPreparedReexecution]?
    let numericalUsage: CoreSpiceCLINumericalUsage?
    let cases: [CoreSpiceCLIPreparedCase]?
    let expectedCaseCount: Int?
    let temperatureCount: Int?
    let analysis: String?
    let savedWaveform: CoreSpiceCLIPreparedWaveform?
    let schemaVersion: Int
    let status: String
    let sourceInputIdentity: String
    let solverIdentity: String?
    let executionProfile: CoreSpiceCLIExecutionProfile?
    let executionProfileReference: ArtifactReference?
    let configurationIdentity: String
    let nativeDCResult: SPICENativeStoredDCResult?
    let osdiExecution: CoreSpiceCLIOSDIExecutionRecord?
    let osdiVariables: [CoreSpiceCLIOSDIVariableRecord]?
    let osdiModels: [CoreSpiceCLIOSDIRecord]?
    let diodeModels: [CoreSpiceCLIDiodeRecord]
    let points: Int
    let newtonIterations: Int
    private enum CodingKeys: String, CodingKey {
        case network, transferFunction, sensitivityEvidence, fourierTransientExecution, generalMOSModels, sourceReexecutions, numericalUsage, cases, expectedCaseCount, temperatureCount, analysis, savedWaveform, executionProfile, executionProfileReference, solverIdentity, nativeDCResult, schemaVersion, status, sourceInputIdentity, configurationIdentity, osdiExecution, osdiModels, osdiVariables, diodeModels, points, newtonIterations
    }
    init(_ output: SPICENativeSimulationOutput, budget: CoreSpiceCLIPrecisionExecutionBudget? = nil,
         executionProfile: CoreSpiceCLIExecutionProfile? = nil, executionProfileReference: ArtifactReference? = nil) throws {
        try CoreSpiceCLIExecutionProfile.validateSaved(executionProfile, reference: executionProfileReference, hasPrecisionBudget: budget != nil)
        self.executionProfile = executionProfile; self.executionProfileReference = executionProfileReference
        guard (budget != nil) == (output.prepared.osdiRuntimeInputs?.transientPrecision != nil) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Explicit completed precision budget is missing or spurious") }
        numericalUsage = nil
        cases = nil; expectedCaseCount = nil; temperatureCount = nil
        let phase = output.waveform.metadata.analysisType.rawValue
        let general = ["tf", "pz", "sens", "four", "network"].contains(phase) || (phase == "dc" && !output.prepared.osdiPreparationRecords.isEmpty)
        analysis = general ? phase : nil
        network = phase == "network" ? try .init(output) : nil
        transferFunction = phase == "tf" ? try .init(output) : nil
        sensitivityEvidence = phase == "sens" ? try .init(output) : nil
        if general {
            var selected: [CoreSpiceCLIPreparedMOSModel] = []
            var children: [CoreSpiceCLIPreparedReexecution] = []
            for facts in output.phases {
                for receipt in facts.mosPreparationReceipts {
                    selected.append(try .init(phase: facts.analysis, receipt: receipt, completedPoints: facts.completedPointCount))
                }
                for child in facts.sourceReexecutions {
                    children.append(try .init(child, phase: facts.analysis, completedPoints: facts.completedPointCount))
                }
            }
            generalMOSModels = selected; sourceReexecutions = children
        } else { generalMOSModels = nil; sourceReexecutions = nil }
        savedWaveform = general ? try CoreSpiceCLIPreparedWaveform(output.waveform, resources: output.prepared.input.resources) : nil
        if let network, let savedWaveform { try network.validateWaveform(savedWaveform) }
        if let transferFunction, let savedWaveform { try transferFunction.validateWaveform(savedWaveform) }
        nativeDCResult = (general && phase == "dc") || output.storedDCResult?.points.contains(where: { $0.representation == .compensated }) == true ? output.storedDCResult : nil
        schemaVersion = phase == "network" ? 9 : general ? (phase == "four" && budget != nil ? 8 : 7) : nativeDCResult != nil ? 5 : budget != nil ? 4 : !output.prepared.circuitPreparation.osdiPreparationRecords.isEmpty && output.waveform.metadata.analysisType != .operatingPoint ? 3 : 2; status="succeeded"
        solverIdentity = output.prepared.solverIdentity
        sourceInputIdentity=output.sourceInputIdentity.hexadecimalValue
        configurationIdentity=output.configurationIdentity.hexadecimalValue
        points=output.waveform.pointCount; newtonIterations=output.statistics.newtonIterations
        var models: [CoreSpiceCLIDiodeRecord]=[]
        for model in output.executedModels where model.deviceType == "diode" {
            guard let receipt=model.diodePreparation, let name=model.selectedModelIdentifier else {
                throw CoreSpiceCLICaseError.incompleteOutput("completed diode receipt is missing")
            }
            models.append(.init(phase: phase,receipt: receipt,modelName: name,completedPointCount: model.completedPointCount))
        }
        diodeModels=models
        let expectedOSDI = output.prepared.input.circuit.instances.filter { $0.osdi != nil }.count
        var completedOSDI: [CoreSpiceCLIOSDIRecord] = []
        if expectedOSDI > 0 {
            for (pointIndex, facts) in output.phases.enumerated() {
                guard facts.osdiPreparationRecords.count == expectedOSDI else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed native OSDI model count differs") }
                for receipt in facts.osdiPreparationRecords {
                    completedOSDI.append(try .init(phase: facts.analysis, completed: receipt, completedPointCount: facts.completedPointCount,
                        sourceName: facts.analysis == "dc" ? facts.sourceName : nil,
                        sourceValue: facts.analysis == "dc" ? facts.sourceValue : nil,
                        sourcePointIndex: facts.analysis == "dc" ? pointIndex : nil))
                }
            }
            guard Set(completedOSDI.map(\.instanceName)).count == expectedOSDI else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed native OSDI receipts are absent") }
        }
        osdiModels = completedOSDI.isEmpty ? nil : completedOSDI
        if phase == "four", let budget, let transient = output.transientResult {
            let prepared = output.prepared.circuitPreparation, plan = prepared.plan
            let thermal = Set(prepared.osdiVariableKinds.compactMap { variable, kind -> Node? in
                guard kind == .thermalPotential, case .nodeVoltage(let node) = variable else { return nil }; return node
            })
            let layout = try WaveformVariableLayout(validatingVariableMap: transient.variableMap,
                topology: plan.topology.circuitTopology, temperatureRiseNodes: thermal)
            let waveform = try WaveformData.from(transientResult: transient, variableLayout: layout, title: "Fourier Transient")
            var execution = try CoreSpiceCLIOSDIExecutionRecord(record: prepared, waveform: waveform,
                operatingPoint: output.operatingPoint, transient: transient, noise: nil)
            try execution.attachPrecision(output, budget: budget); try execution.validate(models: completedOSDI)
            fourierTransientExecution = execution
        } else { fourierTransientExecution = nil }
        if expectedOSDI > 0 && phase != "op" && !general {
            var execution = try CoreSpiceCLIOSDIExecutionRecord(record: output.prepared.circuitPreparation,
                waveform: output.waveform, operatingPoint: output.operatingPoint,
                transient: output.transientResult, noise: output.noiseResult)
            if let budget { try execution.attachPrecision(output, budget: budget) }
            try execution.project(SPICEOutputProjector.project(output.waveform, controls: output.prepared.input.netlist.controls))
            try execution.validate(models: completedOSDI)
            osdiExecution = execution; osdiVariables = nil
        } else {
            osdiExecution = nil
            osdiVariables = general ? nil : try CoreSpiceCLIOSDIVariableRecord.records(output.prepared.circuitPreparation, waveform: output.waveform)
            if !general { try CoreSpiceCLIOSDIVariableRecord.validate(models: osdiModels, variables: osdiVariables) }
        }
    }
    init(cases: [CoreSpiceCLIPreparedCase], expectedCaseCount: Int, temperatureCount: Int,
         numericalUsage: AnalysisExecutionUsage, resources: any SPICESourceResourceAccounting) throws {
        try self.init(cases: cases, expectedCaseCount: expectedCaseCount, temperatureCount: temperatureCount,
            numericalUsage: CoreSpiceCLINumericalUsage(numericalUsage), resources: resources)
    }
    init(cases: [CoreSpiceCLIPreparedCase], expectedCaseCount: Int, temperatureCount: Int,
         numericalUsage: CoreSpiceCLINumericalUsage, resources: any SPICESourceResourceAccounting) throws {
        guard let first = cases.first else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Empty prepared family") }
        self.numericalUsage = numericalUsage
        self.cases = cases; self.expectedCaseCount = expectedCaseCount; self.temperatureCount = temperatureCount
        network = nil; transferFunction = nil; sensitivityEvidence = nil; fourierTransientExecution = nil
        generalMOSModels = nil; sourceReexecutions = nil
        schemaVersion = 6; status = "succeeded"; sourceInputIdentity = first.completion.sourceInputIdentity
        solverIdentity = first.completion.solverIdentity; executionProfile = first.completion.executionProfile
        executionProfileReference = first.completion.executionProfileReference
        configurationIdentity = try Self.familyIdentity(cases, resources: resources)
        nativeDCResult = nil; osdiExecution = nil; osdiModels = nil; osdiVariables = nil; diodeModels = []
        analysis = nil; savedWaveform = nil
        var pointCount = 0, iterations = 0
        for run in cases {
            let (nextPoints, pointOverflow) = pointCount.addingReportingOverflow(run.completion.points)
            let (nextIterations, iterationOverflow) = iterations.addingReportingOverflow(run.completion.newtonIterations)
            guard !pointOverflow, !iterationOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
            pointCount = nextPoints; iterations = nextIterations
        }
        points = pointCount; newtonIterations = iterations
        try validateFamily()
    }

    private static func familyIdentity(_ cases: [CoreSpiceCLIPreparedCase],
                                       resources: (any SPICESourceResourceAccounting)? = nil) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var identities = ["CoreSpiceCLI.prepared-family.v6"]
        for run in cases {
            let selection = try encoder.encode(run.selection)
            guard let text = String(data: selection, encoding: .utf8) else { throw SPICENativeStoredDCResult.Failure.invalidState }
            identities.append(run.completion.sourceInputIdentity); identities.append(run.completion.configurationIdentity)
            identities.append(String(run.index)); identities.append(text)
        }
        let bytes = Array(try encoder.encode(identities))
        let scratch = try resources?.reserveStorage(kind: .temporaryBytes, byteCount: UInt64(bytes.count))
        defer { withExtendedLifetime(scratch) {} }
        try resources?.chargeHashedBytes(UInt64(bytes.count))
        return try SHA256ContentDigester().digest(using: .sha256,
            limits: .init(maximumChunkByteCount: UInt64(max(1, bytes.count)), maximumTotalByteCount: UInt64(max(1, bytes.count)), maximumUpdateCount: 1)) {
                (lease: borrowing ContentDigestUpdateLease) throws(ContentDigestError) in try lease.update(bytes)
            }.digest.hexadecimalValue
    }

    private func validateFamily() throws {
        guard let cases, let expectedCaseCount, let temperatureCount, expectedCaseCount > 0,
              expectedCaseCount <= 10_000, temperatureCount > 0, cases.count == expectedCaseCount,
              analysis == nil, savedWaveform == nil, network == nil, transferFunction == nil, sensitivityEvidence == nil, fourierTransientExecution == nil, generalMOSModels == nil, sourceReexecutions == nil, nativeDCResult == nil, osdiExecution == nil,
              osdiModels == nil, osdiVariables == nil, diodeModels.isEmpty, let first = cases.first else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete prepared family")
        }
        let iterations = first.selection.monteCarloIterations ?? 1
        let (expected, overflow) = temperatureCount.multipliedReportingOverflow(by: iterations)
        guard !overflow, expected == expectedCaseCount else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing temperature/Monte Carlo family members")
        }
        var pointCount = 0, work = 0, attempts = 0, numericalWork = 0, dimension = 0
        for (index, run) in cases.enumerated() {
            try run.validate()
            let temperatureIndex = first.selection.temperatureIndex == nil ? nil : index / iterations
            guard run.index == index, run.selection.temperatureIndex == temperatureIndex,
                  run.selection.temperatureControlIndex == first.selection.temperatureControlIndex,
                  run.selection.monteCarloIteration == (first.selection.monteCarloIteration == nil ? nil : index % iterations),
                  run.selection.monteCarloIterations == first.selection.monteCarloIterations,
                  run.selection.monteCarloBaseSeed == first.selection.monteCarloBaseSeed,
                  run.selection.monteCarloSeedOrigin == first.selection.monteCarloSeedOrigin,
                  run.completion.sourceInputIdentity == sourceInputIdentity,
                  run.completion.solverIdentity == solverIdentity,
                  run.completion.executionProfile == executionProfile,
                  run.completion.executionProfileReference == executionProfileReference else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Prepared family order, identity or selection differs")
            }
            let (nextPoints, pointOverflow) = pointCount.addingReportingOverflow(run.completion.points)
            let (nextWork, workOverflow) = work.addingReportingOverflow(run.completion.newtonIterations)
            guard !pointOverflow, !workOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
            pointCount = nextPoints; work = nextWork
            let (nextAttempts, attemptsOverflow) = attempts.addingReportingOverflow(run.statistics.solveAttempts)
            let (nextNumericalWork, numericalOverflow) = numericalWork.addingReportingOverflow(run.statistics.workUnits)
            guard !attemptsOverflow, !numericalOverflow else { throw SPICESourceStorageError.arithmeticOverflow }
            attempts = nextAttempts; numericalWork = nextNumericalWork; dimension = max(dimension, run.statistics.matrixDimension)
        }
        guard numericalUsage?.solveAttempts == attempts, numericalUsage?.newtonIterations == work,
              numericalUsage?.workUnits == numericalWork, numericalUsage?.maximumMatrixDimension == dimension,
              pointCount == points, work == newtonIterations,
              configurationIdentity == (try Self.familyIdentity(cases)) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Prepared family aggregate or identity differs")
        }
    }

    private func validateOSDIDC(_ waveform: CoreSpiceCLIPreparedWaveform) throws {
        guard let nativeDCResult, nativeDCResult.analysis == "dc", nativeDCResult.points.count == points,
              let coordinates = nativeDCResult.coordinateBits, coordinates == waveform.coordinates.map(\.bitPattern),
              let osdiModels, !osdiModels.isEmpty else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing complete OSDI DC numerical state")
        }
        let instances = Set(osdiModels.map(\.instanceName))
        let (expected, overflow) = instances.count.multipliedReportingOverflow(by: points)
        guard !overflow, osdiModels.count == expected else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete OSDI DC point/model inventory")
        }
        for point in 0..<points {
            let selected = osdiModels.filter { $0.sourcePointIndex == point }
            guard selected.count == instances.count, Set(selected.map(\.instanceName)) == instances,
                  selected.allSatisfy({ $0.phaseSchemaVersion == 4 && $0.phase == "dc" && $0.completedPointCount == 1 &&
                      $0.sourceName == nativeDCResult.parameterName && $0.sourceValueBits == coordinates[point] }) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("OSDI DC receipt differs from its actual source point")
            }
        }
    }

    init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion=try c.decode(Int.self,forKey: .schemaVersion); status=try c.decode(String.self,forKey: .status)
        guard [2, 3, 4, 5, 6, 7, 8, 9].contains(schemaVersion), status=="succeeded" else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion,in: c,debugDescription: "Unsupported prepared completion schema/status")
        }
        network = try c.decodeIfPresent(CoreSpiceCLINetworkRecord.self, forKey: .network)
        transferFunction = try c.decodeIfPresent(CoreSpiceCLITransferFunctionRecord.self, forKey: .transferFunction)
        sensitivityEvidence = try c.decodeIfPresent(CoreSpiceCLISensitivityEvidence.self, forKey: .sensitivityEvidence)
        fourierTransientExecution = try c.decodeIfPresent(CoreSpiceCLIOSDIExecutionRecord.self, forKey: .fourierTransientExecution)
        generalMOSModels = try c.decodeIfPresent([CoreSpiceCLIPreparedMOSModel].self, forKey: .generalMOSModels)
        sourceReexecutions = try c.decodeIfPresent([CoreSpiceCLIPreparedReexecution].self, forKey: .sourceReexecutions)
        numericalUsage = try c.decodeIfPresent(CoreSpiceCLINumericalUsage.self, forKey: .numericalUsage)
        cases = try c.decodeIfPresent([CoreSpiceCLIPreparedCase].self, forKey: .cases)
        expectedCaseCount = try c.decodeIfPresent(Int.self, forKey: .expectedCaseCount)
        temperatureCount = try c.decodeIfPresent(Int.self, forKey: .temperatureCount)
        analysis = try c.decodeIfPresent(String.self, forKey: .analysis)
        savedWaveform = try c.decodeIfPresent(CoreSpiceCLIPreparedWaveform.self, forKey: .savedWaveform)
        solverIdentity = try c.decodeIfPresent(String.self, forKey: .solverIdentity)
        executionProfile = try c.decodeIfPresent(CoreSpiceCLIExecutionProfile.self, forKey: .executionProfile)
        executionProfileReference = try c.decodeIfPresent(ArtifactReference.self, forKey: .executionProfileReference)
        try CoreSpiceCLIExecutionProfile.validateSaved(executionProfile, reference: executionProfileReference, hasPrecisionBudget: schemaVersion == 4 || fourierTransientExecution?.precision != nil)
        guard solverIdentity == nil || solverIdentity == SparseLUSolver.implementationIdentity else {
            throw DecodingError.dataCorruptedError(forKey: .solverIdentity, in: c, debugDescription: "Unsupported saved solver identity")
        }
        sourceInputIdentity=try c.decode(String.self,forKey: .sourceInputIdentity)
        configurationIdentity=try c.decode(String.self,forKey: .configurationIdentity)
        guard [sourceInputIdentity, configurationIdentity].allSatisfy({ value in
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Malformed prepared content identity") }
        osdiVariables=try c.decodeIfPresent([CoreSpiceCLIOSDIVariableRecord].self,forKey: .osdiVariables)
        osdiModels=try c.decodeIfPresent([CoreSpiceCLIOSDIRecord].self,forKey: .osdiModels)
        diodeModels=try c.decode([CoreSpiceCLIDiodeRecord].self,forKey: .diodeModels)
        points=try c.decode(Int.self,forKey: .points); newtonIterations=try c.decode(Int.self,forKey: .newtonIterations)
        nativeDCResult = try c.decodeIfPresent(SPICENativeStoredDCResult.self, forKey: .nativeDCResult)
        osdiExecution = try c.decodeIfPresent(CoreSpiceCLIOSDIExecutionRecord.self, forKey: .osdiExecution)
        if schemaVersion == 6 {
            try validateFamily()
            return
        }
        guard cases == nil, expectedCaseCount == nil, temperatureCount == nil, numericalUsage == nil else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Spurious prepared family fields")
        }
        if schemaVersion == 7 || schemaVersion == 8 || schemaVersion == 9 {
            guard let analysis, ["dc", "tf", "pz", "sens", "four", "network"].contains(analysis), let savedWaveform,
                  savedWaveform.analysis.rawValue == analysis, savedWaveform.coordinates.count == points,
                  (nativeDCResult == nil || analysis == "dc"), osdiExecution == nil, osdiVariables == nil,
                  points > 0, newtonIterations >= 0 else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete general prepared analysis")
            }
            try savedWaveform.validate()
            if analysis == "dc" { try validateOSDIDC(savedWaveform) }
            guard (analysis == "tf") == (transferFunction != nil), (analysis == "sens") == (sensitivityEvidence != nil),
                  (schemaVersion == 8) == (fourierTransientExecution != nil), schemaVersion != 8 || analysis == "four",
                  (schemaVersion == 9) == (network != nil), (analysis == "network") == (network != nil) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing or spurious general derivation evidence")
            }
            if let network {
                try network.validateWaveform(savedWaveform)
                guard network.sourceInputIdentity == sourceInputIdentity,
                      network.configurationIdentity == configurationIdentity else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Network completion identity differs")
                }
                for phase in ["op", "network"] {
                    let models = (osdiModels ?? []).filter { $0.phase == phase }
                    guard Set(models.map(\.instanceName)).count == models.count,
                          models.allSatisfy({ $0.completedPointCount == (phase == "op" ? 1 : points) }),
                          Set(models.map(\.instanceName)) == Set(network.osdiInstances) else {
                        throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete network model phase inventory")
                    }
                }
                for baseline in (osdiModels ?? []).filter({ $0.phase == "op" }) {
                    guard let completed = osdiModels?.first(where: { $0.phase == "network" && $0.instanceName == baseline.instanceName }),
                          completed.phaseSchemaVersion == 5, completed.artifact == baseline.artifact,
                          completed.modelName == baseline.modelName, completed.descriptorIndex == baseline.descriptorIndex,
                          completed.expectedDescriptorName == baseline.expectedDescriptorName,
                          completed.modelParameters == baseline.modelParameters, completed.instanceParameters == baseline.instanceParameters,
                          completed.resolvedParameters == baseline.resolvedParameters,
                          completed.simulationParameters == baseline.simulationParameters, completed.previousState == baseline.previousState,
                          completed.effectiveKelvin.bitPattern == baseline.effectiveKelvin.bitPattern,
                          completed.rawNodeGlobalRows == baseline.rawNodeGlobalRows,
                          completed.rawNodeNames == baseline.rawNodeNames, completed.rawNodeUnits == baseline.rawNodeUnits,
                          completed.rawEquationUnits == baseline.rawEquationUnits else {
                        throw CoreSpiceCLIOSDIError.incompleteReceipt("Network model binding differs from its actual bias phase")
                    }
                }
                guard (osdiModels ?? []).allSatisfy({ ["op", "network"].contains($0.phase) }) else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Spurious network model phase")
                }
            }
            if let transferFunction { try transferFunction.validateWaveform(savedWaveform) }
            if let execution = fourierTransientExecution {
                guard let precision = execution.precision, precision.schemaVersion == 2,
                      precision.settings.analysis == "four", precision.configurationSHA256 == configurationIdentity,
                      precision.sourceInputIdentity == sourceInputIdentity, let osdiModels else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing Fourier precision identity")
                }
                try execution.validate(models: osdiModels)
            }
            if let sensitivityEvidence {
                try sensitivityEvidence.validate()
                try sensitivityEvidence.validateWaveform(savedWaveform)
                guard sensitivityEvidence.sourceInputIdentity == sourceInputIdentity,
                      sensitivityEvidence.configurationIdentity == configurationIdentity,
                      sensitivityEvidence.children.map(\.source) == sourceReexecutions else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Sensitivity derivation identity differs")
                }
            }
            guard let generalMOSModels, let sourceReexecutions,
                  analysis != "sens" || !sourceReexecutions.isEmpty else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing general prepared source/model evidence")
            }
            for model in generalMOSModels { try model.validate() }
            for child in sourceReexecutions {
                try child.validate()
                guard child.sourceInputIdentity == sourceInputIdentity else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Fresh child source differs from prepared analysis")
                }
            }
            return
        }
        guard analysis == nil, savedWaveform == nil, network == nil, transferFunction == nil, sensitivityEvidence == nil, fourierTransientExecution == nil, generalMOSModels == nil, sourceReexecutions == nil else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Spurious general prepared analysis fields")
        }
        guard (schemaVersion == 5) == (nativeDCResult != nil), nativeDCResult == nil || (nativeDCResult?.points.count == points && nativeDCResult?.points.contains(where: { $0.representation == .compensated }) == true) else {
            throw SPICENativeStoredDCResult.Failure.invalidState
        }
        if let osdiExecution {
            guard schemaVersion == (osdiExecution.precision == nil ? 3 : 4), let osdiModels, osdiVariables == nil, points == osdiExecution.coordinates.count else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete prepared dynamic evidence")
            }
            try osdiExecution.validate(models: osdiModels)
            if let precision = osdiExecution.precision {
                guard diodeModels.isEmpty, precision.configurationSHA256 == configurationIdentity, precision.sourceInputIdentity == sourceInputIdentity else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Prepared precision identity differs from complete evidence")
                }
            }
        } else {
            guard schemaVersion == 2 || schemaVersion == 5 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing dynamic execution evidence") }
            try CoreSpiceCLIOSDIVariableRecord.validate(models: osdiModels, variables: osdiVariables)
            guard osdiModels == nil || points == 1 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing prepared dynamic values") }
        }
        guard points>0, newtonIterations>=0, diodeModels.allSatisfy({$0.completedPointCount==points}) else {
            throw DecodingError.dataCorruptedError(forKey: .points,in: c,debugDescription: "Invalid completed numerical point counts")
        }
    }
}
