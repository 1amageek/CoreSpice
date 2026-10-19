import CircuiteFoundation
import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIO
import Foundation

extension CoreSpiceCLIPrecisionExecution {
    /// Convert checked inspection values to the Native owner's canonical facts.
    func nativeFacts(execution: CoreSpiceCLIOSDIExecutionRecord, models: [CoreSpiceCLIOSDIRecord]) throws -> NativePrecisionConfigurationFacts {
        typealias Facts = NativePrecisionConfigurationFacts
        func digest(_ value: String) throws -> ContentDigest { try .init(algorithm: .sha256, hexadecimalValue: value) }
        let c = settings.convergence, t = settings.transient
        let convergence = ConvergenceConfig(abstol: c.abstol, reltol: c.reltol, vntol: c.vntol, maxIterations: c.maxIterations,
            gmin: c.gmin, minDamping: c.minDamping, opticalPowerTolerance: c.opticalPowerTolerance)
        let transient = TransientConfig(stopTime: t.stopTime, executionLimits: settings.numericalLimits,
            maxTimeStep: t.maxTimeStep, initialTimeStep: t.initialTimeStep, minTimeStep: t.minTimeStep,
            preferredMethod: t.preferredMethod == "backwardEuler" ? .backwardEuler : .trapezoidal,
            lteTolerance: t.lteTolerance, maxTimeStepReductions: t.maxTimeStepReductions, shrinkFactor: t.shrinkFactor,
            useInitialConditions: t.useInitialConditions, initialNodeVoltages: [:], nodeVoltageGuesses: [:],
            gminSteppingThreshold: t.gminSteppingThreshold, gminStepping: .init(initialGmin: t.initialGmin,
                finalGmin: t.finalGmin, reductionFactor: t.gminReductionFactor, maxSteps: t.maximumGminSteps))
        let values = Facts.Settings(analysisIndex: settings.analysisIndex, seed: settings.seed,
            convergence: convergence, transient: transient, numericalLimits: settings.numericalLimits,
            initialConditions: settings.initialConditions.map { .init(row: $0.row, value: $0.value) },
            nodeSets: settings.nodeSets.map { .init(row: $0.row, value: $0.value) },
            temperatureKelvin: settings.temperatureKelvin, nominalTemperatureKelvin: settings.nominalTemperatureKelvin)
        let rows: [DCEquationRowPolicy] = try equationPolicy.map { row in
            let kind: DCEquationKind
            switch row.kind {
            case "electricalPotential": kind = .electricalPotential
            case "electricalFlow": kind = .electricalFlow
            case "thermalPotential": kind = .thermalPotential
            default: throw CoreSpiceCLIOSDIError.incompleteReceipt("Unknown actual equation kind")
            }
            return try .init(kind: kind, variableAbsoluteTolerance: row.variableAbsoluteTolerance, equationAbsoluteTolerance: row.equationAbsoluteTolerance)
        }
        let cold: [Facts.ColdModel] = try coldModels.map { receipt in
            guard let model = models.first(where: { $0.instanceName == receipt.instanceName && $0.phase == (settings.analysis == "four" ? "fourier" : "tran") }) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing model facts for Native configuration verification")
            }
            let p = receipt.program
            let topology = Facts.Topology(nodes: p.topology.nodes.map { node in
                .init(index: node.index, name: node.name, units: node.units, residualUnits: node.residualUnits,
                    isFlow: node.isFlow, unknownNature: .init(kind: node.unknownNature.kind, index: node.unknownNature.index),
                    residualNature: .init(kind: node.residualNature.kind, index: node.residualNature.index), activeUnknownIndex: node.activeUnknownIndex)
            }, activeUnknownCount: p.topology.activeUnknownCount, stateCount: p.topology.stateCount)
            let parameters: [Facts.ResolvedParameter] = try model.resolvedParameters.map { value in
                guard let index = value.descriptorIndex, let given = value.isGiven else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete resolved parameter facts") }
                return try .init(assignment: value.assignment(), descriptorIndex: index, isGiven: given)
            }
            return try .init(instanceName: receipt.instanceName, modelName: model.modelName, modelReference: p.modelReference,
                descriptorIndex: p.descriptorIndex, expectedDescriptorName: model.expectedDescriptorName,
                modelParameters: model.modelParameters.map { try $0.assignment() }, instanceParameters: model.instanceParameters.map { try $0.assignment() },
                previousState: model.previousState, resolvedParameters: parameters, effectiveKelvin: model.effectiveKelvin,
                topology: topology, rawNodeGlobalRows: model.rawNodeGlobalRows,
                programDigest: digest(p.programSHA256), programByteCount: UInt64(p.programBytes.count),
                setupDigest: digest(p.setupSHA256), setupByteCount: UInt64(p.setupBytes.count), semanticProfile: digest(p.semanticProfileSHA256),
                workerReference: receipt.workerReference, numericProfile: digest(receipt.numericProfileSHA256), options: receipt.options.checked(), precisionBits: receipt.precisionBits)
        }
        return try Facts(sourceInputIdentity: digest(sourceInputIdentity), algorithmIdentity: algorithmIdentity, solverIdentity: solverIdentity,
            settings: values, rootKey: sources.rootKey, captures: sources.captures.map { .init(key: $0.key, reference: $0.reference) },
            occurrences: sources.occurrences.map { .init(key: $0.key, occurrenceID: $0.occurrenceID, parentOccurrenceID: $0.parentOccurrenceID,
                statementByteOffset: $0.statementByteOffset, statementOrdinal: $0.statementOrdinal, kind: $0.kind,
                parentSection: $0.parentSection, selectedSection: $0.selectedSection) },
            compiledRows: execution.rows.map { .init(row: $0.row, kind: $0.kind, sourceName: $0.sourceName, unit: $0.unit) },
            equationPolicy: rows, coldModels: cold)
    }
}
