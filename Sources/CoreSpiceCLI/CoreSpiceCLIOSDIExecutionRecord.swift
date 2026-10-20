import CoreSpice
import CoreSpiceAnalysis
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceWaveform
import Foundation

/// Complete observed values, independent of display projection and portable execution state.
public struct CoreSpiceCLIOSDIExecutionRecord: Codable, Sendable, Hashable {
    public struct Row: Codable, Sendable, Hashable {
        public let row: Int
        public let kind: String
        public let sourceName: String?
        public let unit: String
    }
    public struct Column: Codable, Sendable, Hashable {
        public let name: String
        public let unit: String
        public let compiledRow: Int?
    }
    public struct Projection: Codable, Sendable, Hashable {
        public let columns: [Column]
        public let real: [Double]
        public let imaginary: [Double]?
    }
    public struct Step: Codable, Sendable, Hashable {
        public let timeSeconds: Double
        public let timeStepSeconds: Double
        public let method: String
        public let previousTimeStepSeconds: Double?
        public let timeStepLowComponent: Double?
        public let previousTimeStepLowComponent: Double?
        public let timeSecondsBits: UInt64?
        public let timeStepBits: UInt64?
        public let timeStepLowBits: UInt64?
        public let previousTimeStepBits: UInt64?
        public let previousTimeStepLowBits: UInt64?
    }
    public struct Noise: Codable, Sendable, Hashable {
        public struct Channel: Codable, Sendable, Hashable {
            public let deviceName: String
            public let sourceIndex: Int
            public let sourceName: String
            public let residualUnit: String
            public let positiveRow: Int?
            public let negativeRow: Int?
            public let sourceDensity: [Double]
            public let outputDensity: [Double]
        }
        public let inputQuantity: String
        public let outputUnit: String
        public let inputReferredUnit: String
        public let integratedOutputUnit: String
        public let outputDensity: [Double]
        public let inputReferredDensity: [Double]
        public let integratedOutputNoise: Double
        public let channels: [Channel]
    }
    public private(set) var precision: CoreSpiceCLIPrecisionExecution?
    public private(set) var schemaVersion: Int
    public let analysis: String
    public let rows: [Row]
    public let columns: [Column]
    public let sweepName: String
    public let sweepUnit: String
    public let coordinates: [Double]
    /// Point-major complete waveform; noise columns are observables rather than MNA rows.
    public let real: [Double]
    public let imaginary: [Double]?
    public let operatingPoint: [Double]?
    public let acceptedSteps: [Step]
    public let noise: Noise?
    public private(set) var projectedColumns: [Int]
    public private(set) var projection: Projection?

    init(record: NativeCircuitPreparationRecord, waveform: WaveformData,
         operatingPoint: DCResult?, transient: TransientResult?, noise: NoiseResult?) throws {
        schemaVersion = 1; precision = nil
        analysis = waveform.metadata.analysisType == .transient ? "tran" : waveform.metadata.analysisType == .noise ? "noise" : "ac"
        let count = waveform.pointCount, width = waveform.variableCount
        guard count > 0, width > 0, count <= 1_000_000 / width,
              (!waveform.isComplex || count <= 500_000 / width), record.plan.topology.dimension <= 8192 else {
            throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed evidence scalar budget exceeded")
        }
        if let noise {
            guard noise.deviceContributions.count <= 8192, noise.deviceContributions.count < 500_000,
                  count <= 1_000_000 / (noise.deviceContributions.count * 2 + width + 2) else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed noise evidence scalar budget exceeded")
            }
        }
        let sourceCount = noise?.deviceContributions.count ?? 0
        let perPoint = width * (waveform.isComplex ? 2 : 1) + 1 + sourceCount * 2 + (noise == nil ? 0 : 2)
        let stepCount = transient?.acceptedSteps.count ?? 0
        guard stepCount <= 250_000, count <= 1_000_000 / perPoint else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Complete evidence scalar budget exceeded") }
        let used = count * perPoint
        guard stepCount * 4 <= 1_000_000 - used,
              (operatingPoint?.variables.count ?? 0) <= 1_000_000 - used - stepCount * 4 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Complete evidence audit budget exceeded") }
        let map = record.plan.topology.variableMap
        var indexed: [Row?] = Array(repeating: nil, count: record.plan.topology.dimension)
        for (variable, row) in map {
            guard indexed.indices.contains(row), indexed[row] == nil else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid compiled row map") }
            switch variable {
            case .nodeVoltage(let node): indexed[row] = .init(row: row, kind: "node", sourceName: record.plan.ir.nodeNames[node], unit: record.osdiVariableKinds[variable] == .thermalPotential ? "K" : "V")
            case .branchCurrent(let branch): indexed[row] = .init(row: row, kind: "branch", sourceName: record.plan.ir.branchNames[branch], unit: "A")
            }
        }
        rows = try indexed.map { guard let row = $0 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing compiled row") }; return row }
        columns = waveform.variables.enumerated().map { index, descriptor in
            .init(name: descriptor.name, unit: descriptor.unit.rawValue, compiledRow: noise == nil ? index : nil)
        }
        sweepName = waveform.sweepVariable.name; sweepUnit = waveform.sweepVariable.unit.rawValue
        coordinates = try (0..<count).map { guard let value = waveform.sweepValue(at: $0) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing coordinate") }; return value }
        var realValues: [Double] = [], imaginaryValues: [Double] = []
        realValues.reserveCapacity(count * width)
        if waveform.isComplex { imaginaryValues.reserveCapacity(count * width) }
        for point in 0..<count {
            try Task.checkCancellation()
            for column in 0..<width {
                if waveform.isComplex {
                    guard let value = waveform.complexValue(variable: column, point: point) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing complex sample") }
                    realValues.append(value.real); imaginaryValues.append(value.imag)
                } else {
                    guard let value = waveform.realValue(variable: column, point: point) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing scalar sample") }
                    realValues.append(value)
                }
            }
        }
        real = realValues; imaginary = waveform.isComplex ? imaginaryValues : nil
        if let operatingPoint {
            guard operatingPoint.variableMap == map else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Operating-point mapping differs") }
            self.operatingPoint = operatingPoint.variables
        } else { self.operatingPoint = nil }
        acceptedSteps = transient?.acceptedSteps.map { step in
            .init(timeSeconds: step.time, timeStepSeconds: step.timeStep,
                  method: step.method == .backwardEuler ? "backwardEuler" : "trapezoidal", previousTimeStepSeconds: step.previousTimeStep,
                  timeStepLowComponent: record.osdiRuntimeInputs?.transientPrecision == nil ? nil : step.timeStepLowComponent,
                  previousTimeStepLowComponent: record.osdiRuntimeInputs?.transientPrecision == nil ? nil : step.previousTimeStepLowComponent,
                  timeSecondsBits: record.osdiRuntimeInputs?.transientPrecision == nil ? nil : step.time.bitPattern,
                  timeStepBits: record.osdiRuntimeInputs?.transientPrecision == nil ? nil : step.timeStep.bitPattern,
                  timeStepLowBits: record.osdiRuntimeInputs?.transientPrecision == nil ? nil : step.timeStepLowComponent.bitPattern,
                  previousTimeStepBits: record.osdiRuntimeInputs?.transientPrecision == nil ? nil : step.previousTimeStep?.bitPattern,
                  previousTimeStepLowBits: record.osdiRuntimeInputs?.transientPrecision == nil ? nil : step.previousTimeStepLowComponent?.bitPattern)
        } ?? []
        if let noise {
            self.noise = try .init(inputQuantity: noise.inputQuantity.rawValue, outputUnit: "V²/Hz",
                inputReferredUnit: noise.inputQuantity == .voltage ? "V²/Hz" : "A²/Hz", integratedOutputUnit: "V",
                outputDensity: noise.outputNoiseDensity, inputReferredDensity: noise.inputReferredNoiseDensity,
                integratedOutputNoise: noise.integratedOutputNoise, channels: noise.deviceContributions.map { contribution in
                    guard let source = contribution.residualSource, let density = contribution.sourceSpectralDensity else {
                        throw CoreSpiceCLIOSDIError.incompleteReceipt("Completed canonical noise source metadata is missing")
                    }
                    func row(_ variable: MNAVariable?) throws -> Int? {
                        guard let variable else { return nil }
                        guard let row = map[variable] else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Noise endpoint is absent") }; return row
                    }
                    return try .init(deviceName: contribution.deviceName, sourceIndex: source.index, sourceName: source.name,
                        residualUnit: source.unit.rawValue, positiveRow: row(source.positive), negativeRow: row(source.negative),
                        sourceDensity: density, outputDensity: contribution.spectralDensity)
                })
        } else { self.noise = nil }
        projection = nil
        projectedColumns = Array(columns.indices)
        try validate()
    }

    private enum CodingKeys: String, CodingKey {
        case precision, schemaVersion, analysis, rows, columns, sweepName, sweepUnit, coordinates, real, imaginary, operatingPoint, acceptedSteps, noise, projectedColumns, projection
    }
    /// Checks intrinsic geometry. Full completion additionally requires the outer
    /// model receipts and their Native configuration commitment verification.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        precision = try c.decodeIfPresent(CoreSpiceCLIPrecisionExecution.self, forKey: .precision)
        analysis = try c.decode(String.self, forKey: .analysis)
        rows = try c.decode([Row].self, forKey: .rows)
        columns = try c.decode([Column].self, forKey: .columns)
        sweepName = try c.decode(String.self, forKey: .sweepName)
        sweepUnit = try c.decode(String.self, forKey: .sweepUnit)
        coordinates = try c.decode([Double].self, forKey: .coordinates)
        real = try c.decode([Double].self, forKey: .real)
        imaginary = try c.decodeIfPresent([Double].self, forKey: .imaginary)
        operatingPoint = try c.decodeIfPresent([Double].self, forKey: .operatingPoint)
        acceptedSteps = try c.decode([Step].self, forKey: .acceptedSteps)
        noise = try c.decodeIfPresent(Noise.self, forKey: .noise)
        projectedColumns = try c.decode([Int].self, forKey: .projectedColumns)
        projection = try c.decodeIfPresent(Projection.self, forKey: .projection)
        try validate()
    }

    mutating func attachPrecision(_ output: SPICENativeSimulationOutput, budget: CoreSpiceCLIPrecisionExecutionBudget) throws {
        guard output.prepared.osdiRuntimeInputs?.transientPrecision != nil else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Precision request was not consumed") }
        precision = try .init(output: output, budget: budget, high: real, coordinates: coordinates)
        schemaVersion = 2
    }

    mutating func project(_ waveform: WaveformData) throws {
        guard waveform.pointCount == coordinates.count else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Projection changed coordinate count") }
        let indices = waveform.variables.map { descriptor in columns.firstIndex { $0.name == descriptor.name && $0.unit == descriptor.unit.rawValue } }
        if indices.allSatisfy({ $0 != nil }) {
            projectedColumns = try indices.map { guard let index = $0 else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing projection index") }; return index }
            projection = nil
        } else {
            guard waveform.variableCount > 0, waveform.variableCount <= 8192,
                  coordinates.count <= (waveform.isComplex ? 500_000 : 1_000_000) / waveform.variableCount else {
                throw CoreSpiceCLIOSDIError.incompleteReceipt("Projected evidence scalar budget exceeded")
            }
            let required = waveform.pointCount * waveform.variableCount * (waveform.isComplex ? 2 : 1)
            guard required <= 1_000_000 - (try scalarCount()) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Complete projected evidence scalar budget exceeded") }
            var real: [Double] = [], imaginary: [Double] = []
            for point in coordinates.indices {
                try Task.checkCancellation()
                for column in waveform.variables.indices {
                    if waveform.isComplex {
                        guard let value = waveform.complexValue(variable: column, point: point) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing projected complex sample") }
                        real.append(value.real); imaginary.append(value.imag)
                    } else {
                        guard let value = waveform.realValue(variable: column, point: point) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing projected sample") }; real.append(value)
                    }
                }
            }
            projection = .init(columns: waveform.variables.enumerated().map { index, descriptor in
                .init(name: descriptor.name, unit: descriptor.unit.rawValue, compiledRow: indices[index])
            }, real: real, imaginary: waveform.isComplex ? imaginary : nil)
            projectedColumns = []
        }
    }

    private func scalarCount() throws -> Int {
        var remaining = 1_000_000
        func charge(_ count: Int) throws {
            guard count <= remaining else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Complete evidence scalar budget exceeded") }; remaining -= count
        }
        try charge(real.count); try charge(imaginary?.count ?? 0); try charge(coordinates.count)
        try charge(operatingPoint?.count ?? 0)
        for _ in acceptedSteps { try charge(4) }
        if let noise {
            try charge(noise.outputDensity.count); try charge(noise.inputReferredDensity.count); try charge(1)
            for channel in noise.channels { try charge(channel.sourceDensity.count); try charge(channel.outputDensity.count) }
        }
        if let projection { try charge(projection.real.count); try charge(projection.imaginary?.count ?? 0) }
        return 1_000_000 - remaining
    }

    func validate(models: [CoreSpiceCLIOSDIRecord]? = nil) throws {
        func require(_ condition: Bool) throws {
            guard condition else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Invalid complete OSDI analysis evidence") }
        }
        _ = try scalarCount()
        var metadataRemaining = 8 * 1024 * 1024
        func text(_ value: String) throws {
            guard value.utf8.count <= metadataRemaining else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Complete evidence metadata budget exceeded") }; metadataRemaining -= value.utf8.count
        }
        for row in rows { if let name = row.sourceName { try text(name) } }
        for column in columns + (projection?.columns ?? []) { try text(column.name); try text(column.unit) }
        if let noise { for channel in noise.channels { try text(channel.deviceName); try text(channel.sourceName) } }
        try require(((schemaVersion == 1 && precision == nil) || (schemaVersion == 2 && precision != nil && analysis == "tran")) && ["ac", "tran", "noise"].contains(analysis))
        try require(!rows.isEmpty && rows.count <= 8192 && rows.map(\.row) == Array(rows.indices))
        try require(rows.allSatisfy { ($0.kind == "node" && ["V", "K"].contains($0.unit)) || ($0.kind == "branch" && $0.unit == "A") })
        try require(!columns.isEmpty && columns.count <= 8192 && Set(columns.map(\.name)).count == columns.count)
        try require(!coordinates.isEmpty && coordinates.count <= 1_000_000 / columns.count)
        try require(coordinates.allSatisfy { $0.isFinite && $0 >= 0 } && zip(coordinates, coordinates.dropFirst()).allSatisfy { $0 < $1 })
        try require(real.count == coordinates.count * columns.count && real.allSatisfy(\.isFinite))
        try require((projection != nil || !projectedColumns.isEmpty) && projectedColumns.count <= columns.count && Set(projectedColumns).count == projectedColumns.count && projectedColumns.allSatisfy { columns.indices.contains($0) })
        if let projection {
            try require(projectedColumns.isEmpty && !projection.columns.isEmpty && projection.columns.count <= 8192)
            try require(coordinates.count <= (projection.imaginary == nil ? 1_000_000 : 500_000) / projection.columns.count)
            try require(Set(projection.columns.map(\.name)).count == projection.columns.count && projection.columns.allSatisfy { !$0.name.isEmpty && ($0.compiledRow.map { columns.indices.contains($0) } ?? true) })
            try require(projection.real.count == coordinates.count * projection.columns.count && projection.real.allSatisfy(\.isFinite))
            if let imaginary = projection.imaginary { try require(imaginary.count == projection.real.count && imaginary.allSatisfy(\.isFinite)) }
        }
        if let operatingPoint { try require(operatingPoint.count == rows.count && operatingPoint.allSatisfy(\.isFinite)) }
        if let models {
        try require(models.count <= 8192)
        for model in models {
            try text(model.instanceName); try text(model.modelName); try text(model.expectedDescriptorName)
            for name in model.rawNodeNames { try text(name) }
            for parameter in model.simulationParameters {
                try text(parameter.name)
                if let value = parameter.stringValue { try text(value) }
            }
            for parameter in model.modelParameters + model.instanceParameters + model.resolvedParameters {
                try text(parameter.name)
                if case .string(let value) = try parameter.assignment().value { try text(value) }
            }
        }
        try require(!models.isEmpty && Set(models.map { $0.phase + ":" + $0.instanceName }).count == models.count)
        let outer = models.filter { $0.phase == (precision?.settings.analysis == "four" ? "fourier" : analysis) }
        try require(!outer.isEmpty && outer.allSatisfy { $0.completedPointCount == coordinates.count })
        let op = models.filter { $0.phase == "op" }
        try require((operatingPoint == nil && op.isEmpty) || (operatingPoint != nil && Set(op.map(\.instanceName)) == Set(outer.map(\.instanceName)) && op.allSatisfy { $0.completedPointCount == 1 }))
        try require(models.count == op.count + outer.count)
        for pointModel in op {
            guard let model = outer.first(where: { $0.instanceName == pointModel.instanceName }) else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing outer model binding") }
            try require(pointModel.artifact == model.artifact && pointModel.descriptorIndex == model.descriptorIndex && pointModel.modelName == model.modelName && pointModel.rawNodeGlobalRows == model.rawNodeGlobalRows && pointModel.rawNodeNames == model.rawNodeNames && pointModel.modelParameters == model.modelParameters && pointModel.instanceParameters == model.instanceParameters && pointModel.effectiveKelvin == model.effectiveKelvin && pointModel.expectedDescriptorName == model.expectedDescriptorName && pointModel.rawNodeUnits == model.rawNodeUnits && pointModel.rawEquationUnits == model.rawEquationUnits && pointModel.previousState == model.previousState && pointModel.resolvedParameters == model.resolvedParameters && pointModel.simulationParameters == model.simulationParameters)
        }
        for model in models {
            for (index, row) in model.rawNodeGlobalRows.enumerated() {
                if let row { try require(rows.indices.contains(row) && rows[row].unit == model.rawNodeUnits[index]) }
            }
        }
        }
        if analysis == "noise" {
            try require(sweepUnit == "Hz" && coordinates.allSatisfy { $0 > 0 })
            try require(imaginary == nil && acceptedSteps.isEmpty && operatingPoint != nil && columns.allSatisfy { $0.compiledRow == nil })
            guard let noise else { throw CoreSpiceCLIOSDIError.incompleteReceipt("Missing noise evidence") }
            try require(["voltage", "current"].contains(noise.inputQuantity) && noise.outputUnit == "V²/Hz" && noise.integratedOutputUnit == "V")
            try require(noise.inputReferredUnit == (noise.inputQuantity == "voltage" ? "V²/Hz" : "A²/Hz"))
            try require(noise.integratedOutputNoise.isFinite && noise.integratedOutputNoise >= 0)
            try require(noise.channels.count <= 8192 && noise.channels.count < 500_000 && coordinates.count <= 1_000_000 / (noise.channels.count * 2 + columns.count + 2))
            try require(columns.count == 3 && columns.map(\.unit) == [noise.outputUnit, noise.inputReferredUnit, noise.integratedOutputUnit])
            try require(noise.outputDensity.count == coordinates.count && noise.inputReferredDensity.count == coordinates.count)
            for point in coordinates.indices {
                try require(real[point * 3] == noise.outputDensity[point] && real[point * 3 + 1] == noise.inputReferredDensity[point] && real[point * 3 + 2] == noise.integratedOutputNoise)
            }
            let spectra = [noise.outputDensity, noise.inputReferredDensity] + noise.channels.flatMap { [$0.sourceDensity, $0.outputDensity] }
            try require(spectra.allSatisfy { $0.count == coordinates.count && $0.allSatisfy { $0.isFinite && $0 >= 0 } })
            try require(noise.channels.count <= 8192 && Set(noise.channels.map { $0.deviceName + ":" + String($0.sourceIndex) }).count == noise.channels.count)
            for channel in noise.channels {
                try require(channel.sourceIndex >= 0 && !channel.deviceName.isEmpty && !channel.sourceName.isEmpty && ["A", "V", "W"].contains(channel.residualUnit))
                try require([channel.positiveRow, channel.negativeRow].allSatisfy { $0.map { rows.indices.contains($0) } ?? true })
                for row in [channel.positiveRow, channel.negativeRow].compactMap({ $0 }) {
                    let expected = rows[row].unit == "V" ? "A" : rows[row].unit == "K" ? "W" : "V"
                    try require(channel.residualUnit == expected)
                }
            }
            // Nonnegative sums and trapezoidal RMS may differ only by floating-point
            // accumulation order: allow 64 epsilon per contributing arithmetic term.
            func sameAccumulation(_ actual: Double, _ expected: Double, terms: Int) -> Bool {
                let relative = 64 * Double.ulpOfOne * Double(max(1, terms))
                let tolerance = max(Double.leastNonzeroMagnitude * 64 * Double(max(1, terms)), max(abs(actual), abs(expected)) * relative)
                return actual.isFinite && expected.isFinite && abs(actual - expected) <= tolerance
            }
            for point in coordinates.indices {
                let sum = noise.channels.reduce(0.0) { $0 + $1.outputDensity[point] }
                try require(sameAccumulation(sum, noise.outputDensity[point], terms: noise.channels.count + 1))
            }
            var integral = 0.0
            for point in coordinates.indices.dropFirst() {
                integral += (noise.outputDensity[point] + noise.outputDensity[point - 1]) / 2 * (coordinates[point] - coordinates[point - 1])
            }
            try require(sameAccumulation(sqrt(integral), noise.integratedOutputNoise, terms: coordinates.count * 4))
        } else {
            try require(noise == nil && columns.count == rows.count && columns.enumerated().allSatisfy { $0.element.compiledRow == $0.offset && $0.element.unit == rows[$0.offset].unit })
            if analysis == "ac" {
                try require(sweepUnit == "Hz" && operatingPoint != nil && acceptedSteps.isEmpty)
                try require(imaginary?.count == real.count && imaginary?.allSatisfy(\.isFinite) == true && real.count <= 500_000)
            } else {
                try require(sweepUnit == "s" && imaginary == nil && acceptedSteps.count == coordinates.count - 1)
                for (index, step) in acceptedSteps.enumerated() {
                    let delta = coordinates[index + 1] - coordinates[index]
                    try require(step.timeSeconds == coordinates[index + 1] && step.timeStepSeconds.isFinite && step.timeStepSeconds > 0 && abs(step.timeStepSeconds - delta) <= max(abs(step.timeSeconds), step.timeStepSeconds) * 64 * Double.ulpOfOne)
                    try require(["backwardEuler", "trapezoidal"].contains(step.method))
                    try require(step.previousTimeStepSeconds.map { $0.isFinite && $0 > 0 } ?? true)
                }
            }
        }
        if let precision { try precision.validate(execution: self, models: models) }
    }
}
