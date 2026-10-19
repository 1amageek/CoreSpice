import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIR
import Foundation

/// Effective settings consumed by the completed Native transient, not source guesses.
public struct CoreSpiceCLIPrecisionSettings: Codable, Sendable, Hashable {
    public struct Convergence: Codable, Sendable, Hashable {
        public let abstol: Double, reltol: Double, vntol: Double, gmin: Double, minDamping: Double, opticalPowerTolerance: Double
        public let maxIterations: Int
        init(_ value: ConvergenceConfig) {
            abstol = value.abstol; reltol = value.reltol; vntol = value.vntol; gmin = value.gmin
            minDamping = value.minDamping; opticalPowerTolerance = value.opticalPowerTolerance; maxIterations = value.maxIterations
        }
        func validate() throws {
            guard [abstol, vntol, minDamping, opticalPowerTolerance].allSatisfy({ $0.isFinite && $0 > 0 }),
                  reltol.isFinite, reltol >= 0, gmin.isFinite, gmin >= 0, minDamping <= 1, maxIterations > 0 else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved convergence settings")
            }
        }
    }
    public struct Transient: Codable, Sendable, Hashable {
        public let stopTime: Double, maxTimeStep: Double, minTimeStep: Double, lteTolerance: Double, shrinkFactor: Double
        public let initialTimeStep: Double?
        public let preferredMethod: String
        public let useInitialConditions: Bool
        public let maxTimeStepReductions: Int, gminSteppingThreshold: Int
        public let initialGmin: Double, finalGmin: Double, gminReductionFactor: Double
        public let maximumGminSteps: Int
        init(_ value: TransientConfig) {
            stopTime = value.stopTime; maxTimeStep = value.maxTimeStep; minTimeStep = value.minTimeStep
            lteTolerance = value.lteTolerance; shrinkFactor = value.shrinkFactor; initialTimeStep = value.initialTimeStep
            preferredMethod = value.preferredMethod == .backwardEuler ? "backwardEuler" : "trapezoidal"
            useInitialConditions = value.useInitialConditions; maxTimeStepReductions = value.maxTimeStepReductions
            gminSteppingThreshold = value.gminSteppingThreshold; initialGmin = value.gminStepping.initialGmin
            finalGmin = value.gminStepping.finalGmin; gminReductionFactor = value.gminStepping.reductionFactor
            maximumGminSteps = value.gminStepping.maxSteps
        }
        func validate() throws {
            guard [stopTime, maxTimeStep, minTimeStep, lteTolerance].allSatisfy({ $0.isFinite && $0 > 0 }),
                  initialTimeStep.map({ $0.isFinite && $0 > 0 }) ?? true,
                  ["backwardEuler", "trapezoidal"].contains(preferredMethod), minTimeStep <= maxTimeStep,
                  shrinkFactor.isFinite, shrinkFactor > 0, shrinkFactor < 1, maxTimeStepReductions >= 0,
                  gminSteppingThreshold > 0, initialGmin.isFinite, initialGmin > 0,
                  finalGmin.isFinite, finalGmin >= 0, gminReductionFactor.isFinite, gminReductionFactor > 1, maximumGminSteps > 0 else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved transient settings")
            }
        }
    }
    public struct InitialValue: Codable, Sendable, Hashable {
        public let row: Int?
        public let value: Double
    }
    public let analysis: String
    public let analysisIndex: Int
    public let seed: UInt64
    public let convergence: Convergence
    public let transient: Transient
    public let numericalLimits: TransientExecutionLimits
    public let initialConditions: [InitialValue]
    public let nodeSets: [InitialValue]
    public let temperatureKelvin: Double
    public let nominalTemperatureKelvin: Double

    init(_ record: SPICENativeSimulationRecord) throws {
        let config = record.input.configuration
        let value: TransientConfig
        switch config.analysis {
        case .transient(let transient): value = transient; analysis = "tran"
        case .fourier(_, _, let transient): value = transient; analysis = "four"
        default: throw CoreSpiceCLIOSDIError.unsupportedAnalysis("precision evidence requires transient or Fourier")
        }
         analysisIndex = config.analysisIndex; seed = config.seed
        convergence = .init(config.options.convergence); transient = .init(value); numericalLimits = config.numericalLimits
        temperatureKelvin = record.circuitPreparation.operatingConditions.temperatureKelvin
        nominalTemperatureKelvin = record.circuitPreparation.operatingConditions.nominalTemperatureKelvin
        func initial(_ values: [Node: Double]) throws -> [InitialValue] {
            try values.map { node, value in
                let row = record.plan.topology.variableMap[.nodeVoltage(node)]
                guard row != nil || (node == record.plan.ir.groundNode && value == 0) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Initial node is outside compiled rows") }
                return InitialValue(row: row, value: value)
            }.sorted { ($0.row ?? -1) < ($1.row ?? -1) }
        }
        initialConditions = try initial(value.initialNodeVoltages); nodeSets = try initial(value.nodeVoltageGuesses)
    }
    func validate(rowCount: Int) throws {
        try convergence.validate(); try transient.validate(); try numericalLimits.validate()
        guard ["tran", "four"].contains(analysis), analysisIndex >= 0, temperatureKelvin.isFinite, temperatureKelvin > 0,
              nominalTemperatureKelvin.isFinite, nominalTemperatureKelvin > 0,
              [initialConditions, nodeSets].allSatisfy({ values in
                  values.count <= rowCount + 1 && Set(values.map { $0.row ?? -1 }).count == values.count &&
                  values.allSatisfy({ $0.value.isFinite && ($0.row.map { (0..<rowCount).contains($0) } ?? ($0.value == 0)) })
              }) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid saved effective settings") }
    }
}
