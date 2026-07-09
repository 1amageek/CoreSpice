import CoreSpiceIR
import CoreSpiceAnalysis
import CoreSpiceCompile
import Foundation

extension WaveformData {

    // MARK: - From DC Result

    /// Creates waveform data from a DC operating point result.
    ///
    /// DC results have a single point with all node voltages and branch currents.
    public static func from(
        dcResult: DCResult,
        topology: CircuitTopology,
        title: String? = nil
    ) -> WaveformData {
        let (variables, realData) = buildVariablesFromMNA(
            variableMap: dcResult.variableMap,
            solutions: [dcResult.variables],
            topology: topology
        )

        let metadata = SimulationMetadata(
            title: title,
            analysisType: .operatingPoint,
            pointCount: 1,
            variableCount: variables.count
        )

        let sweepVariable = VariableDescriptor(
            name: "point",
            unit: .dimensionless,
            type: .parameter,
            index: 0
        )

        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: [0.0],
            variables: variables,
            realData: realData
        )
    }

    // MARK: - From AC Result

    /// Creates waveform data from an AC analysis result.
    ///
    /// AC results contain complex values at each frequency point.
    public static func from(
        acResult: ACResult,
        topology: CircuitTopology,
        title: String? = nil
    ) -> WaveformData {
        let (variables, complexData) = buildComplexVariablesFromMNA(
            variableMap: acResult.variableMap,
            solutions: acResult.solutions,
            topology: topology
        )

        let metadata = SimulationMetadata(
            title: title,
            analysisType: .ac,
            pointCount: acResult.frequencies.count,
            variableCount: variables.count,
            isComplex: true
        )

        let sweepVariable = VariableDescriptor.frequency()

        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: acResult.frequencies,
            variables: variables,
            complexData: complexData
        )
    }

    // MARK: - From Transient Result

    /// Creates waveform data from a transient analysis result.
    ///
    /// Transient results contain real values at each time point.
    public static func from(
        transientResult: TransientResult,
        topology: CircuitTopology,
        title: String? = nil
    ) throws -> WaveformData {
        try checkedFrom(transientResult: transientResult, topology: topology, title: title)
    }

    public static func checkedFrom(
        transientResult: TransientResult,
        topology: CircuitTopology,
        title: String? = nil
    ) throws -> WaveformData {
        let variableLayout = WaveformVariableLayout(
            variableMap: transientResult.variableMap,
            topology: topology
        )
        return try checkedFrom(transientResult: transientResult, variableLayout: variableLayout, title: title)
    }

    /// Creates waveform data from a transient result with a precomputed variable layout.
    public static func from(
        transientResult: TransientResult,
        variableLayout: WaveformVariableLayout,
        title: String? = nil
    ) throws -> WaveformData {
        try checkedFrom(transientResult: transientResult, variableLayout: variableLayout, title: title)
    }

    public static func checkedFrom(
        transientResult: TransientResult,
        variableLayout: WaveformVariableLayout,
        title: String? = nil
    ) throws -> WaveformData {
        let variables = variableLayout.variables
        guard variables.count == transientResult.solutionTrace.variableCount else {
            throw WaveformValidationError.variableLayoutWidthMismatch(
                expected: transientResult.solutionTrace.variableCount,
                actual: variables.count
            )
        }
        let metadata = SimulationMetadata(
            title: title,
            analysisType: .transient,
            pointCount: transientResult.timePoints.count,
            variableCount: variables.count
        )

        let sweepVariable = VariableDescriptor.time()

        return try WaveformData(
            validatingMetadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: transientResult.timePoints,
            variables: variables,
            realRowMajorData: transientResult.solutionTrace.rowMajorValues,
            pointCount: transientResult.solutionTrace.pointCount,
            variableCount: transientResult.solutionTrace.variableCount
        )
    }

    // MARK: - From DC Sweep Result

    /// Creates waveform data from a DC sweep result.
    ///
    /// DC sweeps produce one operating point per sweep value, so the sweep
    /// parameter becomes the independent variable.
    public static func from(
        sweepResult: SweepResult<DCResult>,
        topology: CircuitTopology,
        title: String? = nil
    ) -> WaveformData {
        guard let first = sweepResult.results.first else {
            return WaveformData.empty(analysisType: .dc)
        }

        // Build variable descriptors from first result's variable map
        let sortedVars = first.variableMap.sorted { $0.value < $1.value }

        var variables: [VariableDescriptor] = []
        for (idx, (mnaVar, _)) in sortedVars.enumerated() {
            let descriptor: VariableDescriptor
            switch mnaVar {
            case .nodeVoltage(let node):
                let nodeName = topology.name(for: node) ?? String(node.id)
                descriptor = VariableDescriptor(
                    name: "V(\(nodeName))",
                    unit: .volt,
                    type: .voltage,
                    index: idx
                )
            case .branchCurrent(let branch):
                let branchName = topology.name(for: branch) ?? String(branch.id)
                descriptor = VariableDescriptor(
                    name: "I(\(branchName))",
                    unit: .ampere,
                    type: .current,
                    index: idx
                )
            }
            variables.append(descriptor)
        }

        // Build data: one point per sweep value
        var realData: [[Double]] = []
        realData.reserveCapacity(sweepResult.values.count)

        for result in sweepResult.results {
            var point: [Double] = []
            point.reserveCapacity(sortedVars.count)
            for (_, mnaIdx) in sortedVars {
                point.append(result.variables[mnaIdx])
            }
            realData.append(point)
        }

        let metadata = SimulationMetadata(
            title: title ?? "DC Sweep: \(sweepResult.parameterName)",
            analysisType: .dc,
            pointCount: sweepResult.values.count,
            variableCount: variables.count
        )

        // The sweep variable is the parameter being swept
        let sweepVariable = VariableDescriptor(
            name: sweepResult.parameterName,
            unit: .volt, // Usually a voltage source sweep
            type: .parameter,
            index: 0
        )

        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: sweepResult.values,
            variables: variables,
            realData: realData
        )
    }

    // MARK: - From AC Sweep Result (Parametric)

    /// Creates parametric waveform data from an AC parametric sweep result.
    ///
    /// Each AC result contains a full frequency sweep; this method collects
    /// them into a parametric structure for corner/Monte Carlo analysis.
    public static func parametricFrom(
        sweepResult: SweepResult<ACResult>,
        topology: CircuitTopology,
        title: String? = nil
    ) -> ParametricWaveformData {
        var runs: [ParametricWaveformData.Run] = []

        for (index, (value, result)) in zip(sweepResult.values, sweepResult.results).enumerated() {
            let waveform = WaveformData.from(
                acResult: result,
                topology: topology,
                title: "Run \(index + 1)"
            )

            let run = ParametricWaveformData.Run(
                index: index,
                parameters: [sweepResult.parameterName: value],
                waveform: waveform
            )
            runs.append(run)
        }

        return ParametricWaveformData(
            runs: runs,
            analysisType: .ac,
            title: title ?? "Parametric AC: \(sweepResult.parameterName)",
            parameterNames: [sweepResult.parameterName]
        )
    }

    // MARK: - From Transient Sweep Result (Parametric)

    /// Creates parametric waveform data from a transient parametric sweep result.
    ///
    /// Each transient result contains a full time sweep; this method collects
    /// them into a parametric structure for corner/Monte Carlo analysis.
    public static func parametricFrom(
        sweepResult: SweepResult<TransientResult>,
        topology: CircuitTopology,
        title: String? = nil
    ) throws -> ParametricWaveformData {
        try checkedParametricFrom(
            sweepResult: sweepResult,
            topology: topology,
            title: title
        )
    }

    public static func checkedParametricFrom(
        sweepResult: SweepResult<TransientResult>,
        topology: CircuitTopology,
        title: String? = nil
    ) throws -> ParametricWaveformData {
        var runs: [ParametricWaveformData.Run] = []

        for (index, (value, result)) in zip(sweepResult.values, sweepResult.results).enumerated() {
            let waveform = try WaveformData.checkedFrom(
                transientResult: result,
                topology: topology,
                title: "Run \(index + 1)"
            )

            let run = try ParametricWaveformData.Run(
                validatingIndex: index,
                parameters: [sweepResult.parameterName: value],
                waveform: waveform
            )
            runs.append(run)
        }

        return try ParametricWaveformData(
            validatingRuns: runs,
            analysisType: .transient,
            title: title ?? "Parametric Transient: \(sweepResult.parameterName)",
            parameterNames: [sweepResult.parameterName]
        )
    }

    // MARK: - From Transfer Function Result

    /// Creates waveform data from a transfer function result.
    ///
    /// The result is a single data point with three variables:
    /// gain, input impedance, and output impedance.
    public static func from(
        transferFunctionResult: TransferFunctionResult,
        title: String? = nil
    ) -> WaveformData {
        let variables = [
            VariableDescriptor(
                name: "gain",
                unit: .dimensionless,
                type: .voltage,
                index: 0
            ),
            VariableDescriptor(
                name: "Zin",
                unit: .ohm,
                type: .voltage,
                index: 1
            ),
            VariableDescriptor(
                name: "Zout",
                unit: .ohm,
                type: .voltage,
                index: 2
            ),
        ]

        let metadata = SimulationMetadata(
            title: title,
            analysisType: .transferFunction,
            pointCount: 1,
            variableCount: 3
        )

        let sweepVariable = VariableDescriptor(
            name: "point",
            unit: .dimensionless,
            type: .parameter,
            index: 0
        )

        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: [0.0],
            variables: variables,
            realData: [[
                transferFunctionResult.gain,
                transferFunctionResult.inputImpedance,
                transferFunctionResult.outputImpedance,
            ]]
        )
    }

    // MARK: - From Noise Result

    /// Creates waveform data from a noise analysis result.
    ///
    /// The sweep variable is frequency and the variables are output-referred
    /// and input-referred spectral densities plus the integrated output noise.
    public static func from(
        noiseResult: NoiseResult,
        title: String? = nil
    ) -> WaveformData {
        let variables = [
            VariableDescriptor(
                name: "output_noise_density",
                unit: .dimensionless,
                type: .noiseDensity,
                index: 0
            ),
            VariableDescriptor(
                name: "input_referred_noise_density",
                unit: .dimensionless,
                type: .noiseDensity,
                index: 1
            ),
            VariableDescriptor(
                name: "integrated_output_noise",
                unit: .volt,
                type: .voltage,
                index: 2
            ),
        ]

        let pointCount = noiseResult.frequencies.count
        let realData = noiseResult.frequencies.indices.map { index in
            [
                noiseResult.outputNoiseDensity.indices.contains(index)
                    ? noiseResult.outputNoiseDensity[index] : .nan,
                noiseResult.inputReferredNoiseDensity.indices.contains(index)
                    ? noiseResult.inputReferredNoiseDensity[index] : .nan,
                noiseResult.integratedOutputNoise,
            ]
        }

        return WaveformData(
            metadata: SimulationMetadata(
                title: title,
                analysisType: .noise,
                pointCount: pointCount,
                variableCount: variables.count
            ),
            sweepVariable: .frequency(),
            sweepValues: noiseResult.frequencies,
            variables: variables,
            realData: realData
        )
    }

    // MARK: - From Pole-Zero Result

    /// Creates waveform data from a pole-zero analysis result.
    ///
    /// The sweep variable is the result index. Pole and zero values are stored
    /// as complex columns; missing pole/zero slots are represented as NaN.
    public static func from(
        poleZeroResult: PoleZeroResult,
        title: String? = nil
    ) -> WaveformData {
        let pointCount = max(poleZeroResult.poles.count, poleZeroResult.zeros.count, 1)
        let variables = [
            VariableDescriptor(
                name: "pole",
                unit: .radian,
                type: .frequency,
                index: 0
            ),
            VariableDescriptor(
                name: "zero",
                unit: .radian,
                type: .frequency,
                index: 1
            ),
            VariableDescriptor(
                name: "dc_gain",
                unit: .dimensionless,
                type: .magnitude,
                index: 2
            ),
        ]

        let complexData = (0..<pointCount).map { index in
            [
                poleZeroResult.poles.indices.contains(index)
                    ? (
                        real: poleZeroResult.poles[index].real,
                        imag: poleZeroResult.poles[index].imag
                    )
                    : (real: Double.nan, imag: Double.nan),
                poleZeroResult.zeros.indices.contains(index)
                    ? (
                        real: poleZeroResult.zeros[index].real,
                        imag: poleZeroResult.zeros[index].imag
                    )
                    : (real: Double.nan, imag: Double.nan),
                (real: index == 0 ? poleZeroResult.dcGain : Double.nan, imag: 0.0),
            ]
        }

        return WaveformData(
            metadata: SimulationMetadata(
                title: title,
                analysisType: .poleZero,
                pointCount: pointCount,
                variableCount: variables.count
            ),
            sweepVariable: VariableDescriptor(
                name: "index",
                unit: .dimensionless,
                type: .parameter,
                index: 0
            ),
            sweepValues: (0..<pointCount).map(Double.init),
            variables: variables,
            complexData: complexData
        )
    }

    // MARK: - From Fourier Result

    /// Creates waveform data from a Fourier analysis result.
    ///
    /// The sweep variable is the harmonic number, and each analyzed signal
    /// has magnitude and phase variables.
    public static func from(
        fourierResult: FourierResult,
        title: String? = nil
    ) -> WaveformData {
        // Use the first variable's harmonics to determine point count
        guard let firstEntry = fourierResult.harmonics.first else {
            return WaveformData.empty(analysisType: .fourier)
        }

        let harmonicComponents = firstEntry.value
        let pointCount = harmonicComponents.count

        var variables: [VariableDescriptor] = []
        var realData: [[Double]] = Array(repeating: [], count: pointCount)

        var varIndex = 0
        for (varName, components) in fourierResult.harmonics.sorted(by: { $0.key < $1.key }) {
            variables.append(VariableDescriptor(
                name: "\(varName)_mag",
                unit: .volt,
                type: .voltage,
                index: varIndex
            ))
            variables.append(VariableDescriptor(
                name: "\(varName)_phase",
                unit: .degree,
                type: .voltage,
                index: varIndex + 1
            ))
            varIndex += 2

            for (i, comp) in components.enumerated() {
                realData[i].append(comp.magnitude)
                realData[i].append(comp.phase)
            }
        }

        let metadata = SimulationMetadata(
            title: title,
            analysisType: .fourier,
            pointCount: pointCount,
            variableCount: variables.count
        )

        let sweepVariable = VariableDescriptor(
            name: "harmonic",
            unit: .dimensionless,
            type: .parameter,
            index: 0
        )

        let sweepValues = harmonicComponents.map { Double($0.harmonic) }

        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: sweepValues,
            variables: variables,
            realData: realData
        )
    }

    // MARK: - From Sensitivity Result

    /// Creates waveform data from a sensitivity analysis result.
    ///
    /// Each data point corresponds to a parameter, with sensitivity and
    /// normalized sensitivity as variables.
    public static func from(
        sensitivityResult: SensitivityResult,
        title: String? = nil
    ) -> WaveformData {
        let entries = sensitivityResult.sensitivities
        guard !entries.isEmpty else {
            return WaveformData.empty(analysisType: .sensitivity)
        }

        let variables = [
            VariableDescriptor(
                name: "sensitivity",
                unit: .dimensionless,
                type: .voltage,
                index: 0
            ),
            VariableDescriptor(
                name: "normalized_sensitivity",
                unit: .dimensionless,
                type: .voltage,
                index: 1
            ),
        ]

        var realData: [[Double]] = []
        var sweepValues: [Double] = []

        for (i, entry) in entries.enumerated() {
            sweepValues.append(Double(i))
            realData.append([entry.sensitivity, entry.normalizedSensitivity])
        }

        let metadata = SimulationMetadata(
            title: title,
            analysisType: .sensitivity,
            pointCount: entries.count,
            variableCount: 2
        )

        let sweepVariable = VariableDescriptor(
            name: "parameter",
            unit: .dimensionless,
            type: .parameter,
            index: 0
        )

        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: sweepValues,
            variables: variables,
            realData: realData
        )
    }

    // MARK: - Empty Waveform

    /// Creates an empty waveform data for the specified analysis type.
    public static func empty(analysisType: AnalysisKind) -> WaveformData {
        let sweepVariable: VariableDescriptor
        switch analysisType {
        case .transient:
            sweepVariable = .time()
        case .ac:
            sweepVariable = .frequency()
        default:
            sweepVariable = VariableDescriptor(
                name: "x",
                unit: .dimensionless,
                type: .parameter,
                index: 0
            )
        }

        return WaveformData(
            metadata: SimulationMetadata(
                title: nil,
                analysisType: analysisType,
                pointCount: 0,
                variableCount: 0
            ),
            sweepVariable: sweepVariable,
            sweepValues: [],
            variables: [],
            realData: []
        )
    }

    // MARK: - Helper Methods

    /// Builds variable descriptors and data from MNA solution vectors.
    private static func buildVariablesFromMNA(
        variableMap: [MNAVariable: Int],
        solutions: [[Double]],
        topology: CircuitTopology
    ) -> (variables: [VariableDescriptor], data: [[Double]]) {
        let variables = buildVariableDescriptorsFromMNA(
            variableMap: variableMap,
            topology: topology
        )
        let sortedVars = variableMap.sorted { $0.value < $1.value }

        // Transpose data to [point][variable] format
        var data: [[Double]] = []
        data.reserveCapacity(solutions.count)
        for solution in solutions {
            var point: [Double] = []
            point.reserveCapacity(sortedVars.count)
            for (_, mnaIdx) in sortedVars {
                point.append(solution[mnaIdx])
            }
            data.append(point)
        }

        return (variables, data)
    }

    /// Builds variable descriptors from MNA variables sorted by solver index.
    private static func buildVariableDescriptorsFromMNA(
        variableMap: [MNAVariable: Int],
        topology: CircuitTopology
    ) -> [VariableDescriptor] {
        WaveformVariableLayout(variableMap: variableMap, topology: topology).variables
    }

    /// Builds complex variable descriptors and data from MNA solution vectors.
    private static func buildComplexVariablesFromMNA(
        variableMap: [MNAVariable: Int],
        solutions: [[ComplexPair]],
        topology: CircuitTopology
    ) -> (variables: [VariableDescriptor], data: [[(real: Double, imag: Double)]]) {
        let variables = buildVariableDescriptorsFromMNA(
            variableMap: variableMap,
            topology: topology
        )
        let sortedVars = variableMap.sorted { $0.value < $1.value }

        // Transpose data to [point][variable] format
        var data: [[(real: Double, imag: Double)]] = []
        data.reserveCapacity(solutions.count)
        for solution in solutions {
            var point: [(real: Double, imag: Double)] = []
            point.reserveCapacity(sortedVars.count)
            for (_, mnaIdx) in sortedVars {
                let cp = solution[mnaIdx]
                point.append((real: cp.real, imag: cp.imag))
            }
            data.append(point)
        }

        return (variables, data)
    }
}
