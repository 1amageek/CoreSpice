import CoreSpice
import CoreSpiceIO
import CoreSpiceParsedIR
import CoreSpiceMOSContracts
import CoreSpiceAnalysis
import CoreSpiceWaveform

/// Exact selected coordinates and complete observations for one prepared execution.
struct CoreSpiceCLIPreparedCase: Codable, Sendable {
    struct Selection: Codable, Sendable, Equatable {
        let seed: UInt64
        let temperatureControlIndex: Int?
        let temperatureIndex: Int?
        let temperatureCelsius: Double
        let nominalTemperatureCelsius: Double
        let monteCarloIteration: Int?
        let monteCarloIterations: Int?
        let monteCarloBaseSeed: UInt64?
        let monteCarloSeedOrigin: String?
        init(_ configuration: SPICEEffectiveSimulationConfiguration) {
            let selected = configuration.runSelection
            seed = configuration.seed
            temperatureControlIndex = selected.temperatureSelection?.controlIndex
            temperatureIndex = selected.temperatureSelection?.valueIndex
            temperatureCelsius = configuration.temperatureCelsius
            nominalTemperatureCelsius = configuration.nominalTemperatureCelsius
            monteCarloIteration = selected.monteCarloIteration
            monteCarloIterations = selected.monteCarloIterations
            monteCarloBaseSeed = selected.monteCarloBaseSeed
            monteCarloSeedOrigin = selected.monteCarloSeedOrigin?.rawValue
        }
        func validate() throws {
            guard temperatureCelsius.isFinite, temperatureCelsius > -273.15,
                  nominalTemperatureCelsius.isFinite, nominalTemperatureCelsius > -273.15,
                  (temperatureControlIndex == nil) == (temperatureIndex == nil),
                  temperatureIndex.map({ $0 >= 0 }) ?? true,
                  temperatureControlIndex.map({ $0 >= 0 }) ?? true else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid prepared temperature coordinate")
            }
            if let iteration = monteCarloIteration, let count = monteCarloIterations, let base = monteCarloBaseSeed {
                let (expected, overflow) = base.addingReportingOverflow(UInt64(max(0, iteration)))
                guard count > 0, iteration >= 0, iteration < count, !overflow, seed == expected,
                      monteCarloSeedOrigin.map({ ["callerOverride", "sourceDirective", "requestDefault"].contains($0) }) == true else {
                    throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid prepared Monte Carlo coordinate")
                }
            } else if monteCarloIteration != nil || monteCarloIterations != nil || monteCarloBaseSeed != nil || monteCarloSeedOrigin != nil {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Partial prepared Monte Carlo coordinate")
            }
        }
    }
    let statistics: TransientExecutionStatistics
    let index: Int
    let selection: Selection
    let completion: CoreSpiceCLIPreparedRunRecord
    let waveform: CoreSpiceCLIPreparedWaveform
    let measurements: [CoreSpiceCLIMeasurement]
    let mosModels: [CoreSpiceCLIPreparedMOSModel]
    var sourceReexecutions: [CoreSpiceCLIPreparedReexecution] { completion.sourceReexecutions ?? [] }
    private let reservation: SPICESourceStorageReservation?
    private enum CodingKeys: String, CodingKey { case statistics, index, selection, completion, waveform, measurements, mosModels }

    init(index: Int, output: SPICENativeSimulationOutput, completion: CoreSpiceCLIPreparedRunRecord,
         resources: any SPICESourceResourceAccounting) throws {
        var metadataBytes: UInt64 = 4096
        func text(_ value: String?) throws {
            guard let value else { return }
            metadataBytes = try CoreSpiceCLIPrecisionExecution.add(metadataBytes, UInt64(value.utf8.count))
        }
        func mos(_ receipt: MOSPreparationReceipt) throws {
            let resolved = receipt.identity.resolved
            metadataBytes = try CoreSpiceCLIPrecisionExecution.add(metadataBytes,
                CoreSpiceCLIPrecisionExecution.multiply(UInt64(resolved.modelCoefficients.count + resolved.instanceParameters.count), 256))
            try text(resolved.instance); try text(resolved.source.captureID)
            try text(receipt.identity.implementationIdentity)
            for parameter in resolved.modelCoefficients + resolved.instanceParameters {
                try text(resolved.symbolNames[Int(parameter.symbol.rawValue)])
            }
        }
        for phase in output.phases {
            for receipt in phase.mosPreparationReceipts { try mos(receipt) }
            metadataBytes = try CoreSpiceCLIPrecisionExecution.add(metadataBytes,
                CoreSpiceCLIPrecisionExecution.multiply(UInt64(phase.diodePreparationReceipts.count), 32 * 1024))
            for child in phase.sourceReexecutions {
                for receipt in child.preparation.mosPreparationReceipts { try mos(receipt) }
                metadataBytes = try CoreSpiceCLIPrecisionExecution.add(metadataBytes,
                    CoreSpiceCLIPrecisionExecution.multiply(UInt64(child.preparation.diodePreparationReceipts.count), 32 * 1024))
                for scalar in child.sourceOverrides {
                    try text(scalar.instanceName); try text(scalar.parameterName)
                    metadataBytes = try CoreSpiceCLIPrecisionExecution.add(metadataBytes, 256)
                }
            }
        }
        if let execution = completion.fourierTransientExecution ?? completion.osdiExecution {
            metadataBytes = try CoreSpiceCLIPrecisionExecution.add(metadataBytes,
                CoreSpiceCLIPrecisionExecution.multiply(UInt64(execution.real.count + (execution.imaginary?.count ?? 0) + execution.coordinates.count), 64))
            for model in completion.osdiModels ?? [] {
                metadataBytes = try CoreSpiceCLIPrecisionExecution.add(metadataBytes,
                    CoreSpiceCLIPrecisionExecution.multiply(UInt64(model.resolvedParameters.count + model.instanceParameters.count + model.modelParameters.count + model.rawNodeNames.count), 1024))
            }
        }
        reservation = try resources.reserveStorage(kind: .liveOwnedBytes, byteCount: metadataBytes)
        statistics = output.statistics
        self.index = index; self.completion = completion
        selection = Selection(output.prepared.input.configuration)
        waveform = try CoreSpiceCLIPreparedWaveform(output.waveform, resources: resources)
        let measures = output.prepared.input.netlist.controls.compactMap { control -> MeasureSpec? in
            if case .measure(let spec) = control { return spec }; return nil
        }
        let evaluated = try SPICEMeasureEvaluator().evaluate(measures: measures, waveform: output.waveform)
        guard measures.allSatisfy({ spec in evaluated.contains { $0.name == spec.resultName && $0.analysisType == spec.analysisType } }) else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Requested prepared measurement has no completed analysis")
        }
        measurements = evaluated.map { .init(analysis: $0.analysisType.rawValue, name: $0.name,
            value: $0.value, unit: $0.unit.isEmpty ? nil : $0.unit) }
        var selectedModels: [CoreSpiceCLIPreparedMOSModel] = []
        for phase in output.phases {
            for receipt in phase.mosPreparationReceipts {
                selectedModels.append(try .init(phase: phase.analysis, receipt: receipt, completedPoints: phase.completedPointCount))
            }
        }
        mosModels = selectedModels
        try validate()
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statistics = try c.decode(TransientExecutionStatistics.self, forKey: .statistics)
        index = try c.decode(Int.self, forKey: .index)
        selection = try c.decode(Selection.self, forKey: .selection)
        completion = try c.decode(CoreSpiceCLIPreparedRunRecord.self, forKey: .completion)
        waveform = try c.decode(CoreSpiceCLIPreparedWaveform.self, forKey: .waveform)
        measurements = try c.decode([CoreSpiceCLIMeasurement].self, forKey: .measurements)
        mosModels = try c.decode([CoreSpiceCLIPreparedMOSModel].self, forKey: .mosModels)
        reservation = nil
        try validate()
    }

    func validate() throws {
        try selection.validate(); try waveform.validate()
        guard index >= 0, completion.cases == nil, completion.points == waveform.coordinates.count,
              statistics.newtonIterations == completion.newtonIterations,
              [statistics.acceptedSteps, statistics.rejectedSteps, statistics.solveAttempts, statistics.newtonIterations,
               statistics.savedScalars, statistics.workUnits, statistics.matrixDimension].allSatisfy({ $0 >= 0 }),
              measurements.allSatisfy({ $0.value.isFinite }),
              Set(measurements.map { $0.analysis + ":" + $0.name }).count == measurements.count else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Incomplete prepared case observations")
        }
        if let network = completion.network { try network.validateWaveform(waveform) }
        if let transferFunction = completion.transferFunction { try transferFunction.validateWaveform(waveform) }
        for model in mosModels { try model.validate() }
        for child in sourceReexecutions {
            try child.validate()
            guard child.sourceInputIdentity == completion.sourceInputIdentity, child.selection == selection else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Sensitivity reexecution belongs to another case")
            }
        }
    }
}
