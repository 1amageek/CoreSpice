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
        ).retainingStorage(dcResult.retainedStorage)
    }

    /// Creates a checked operating-point waveform without copying or reordering the solution buffer.
    ///
    /// The layout must describe the result's exact compiled variable map and width.
    public static func from(
        dcResult: DCResult,
        variableLayout: WaveformVariableLayout,
        title: String? = nil
    ) throws -> WaveformData {
        try variableLayout.validate(variableMap: dcResult.variableMap, variableCount: dcResult.variables.count)
        return try WaveformData(
            validatingMetadata: SimulationMetadata(
                title: title,
                analysisType: .operatingPoint,
                pointCount: 1,
                variableCount: variableLayout.variables.count
            ),
            sweepVariable: VariableDescriptor(name: "point", unit: .dimensionless, type: .parameter, index: 0),
            sweepValues: [0.0],
            variables: variableLayout.variables,
            realRowMajorData: dcResult.variables,
            pointCount: 1,
            variableCount: variableLayout.variables.count
        ).retainingStorage(dcResult.retainedStorage)
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
        ).retainingStorage(acResult.retainedStorage)
    }

    /// Creates an AC waveform using the result's exact compiled layout and physical units.
    public static func from(
        acResult: ACResult,
        variableLayout: WaveformVariableLayout,
        title: String? = nil
    ) throws -> WaveformData {
        try variableLayout.validate(
            variableMap: acResult.variableMap,
            variableCount: acResult.solutions.first?.count ?? 0
        )
        // ComplexPair becomes a tuple only at the waveform storage boundary.
        let complexData = acResult.solutions.map { solution in
            solution.map { (real: $0.real, imag: $0.imag) }
        }
        return try WaveformData(
            validatingMetadata: SimulationMetadata(
                title: title,
                analysisType: .ac,
                pointCount: acResult.frequencies.count,
                variableCount: variableLayout.variables.count,
                isComplex: true
            ),
            sweepVariable: .frequency(),
            sweepValues: acResult.frequencies,
            variables: variableLayout.variables,
            complexData: complexData
        ).retainingStorage(acResult.retainedStorage)
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
        try variableLayout.validate(
            variableMap: transientResult.variableMap,
            variableCount: transientResult.solutionTrace.variableCount
        )
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
        ).retainingStorage(transientResult.retainedStorage)
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
        ).retainingStorage(sweepResult.retainedStorage)
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
    /// One data point contains gain and each typed finite port impedance.
    /// Metadata explicitly classifies both ports, including omitted open ports.
    public static func from(
        transferFunctionResult: TransferFunctionResult,
        title: String? = nil
    ) -> WaveformData {
        var variables = [
            VariableDescriptor(
                name: "gain",
                unit: .dimensionless,
                type: .voltage,
                index: 0
            ),
        ]
        var row = [transferFunctionResult.gain]
        var portClassifications: [String: String] = [:]
        switch transferFunctionResult.inputPortImpedance {
        case .finite(let value):
            variables.append(VariableDescriptor(name: "Zin", unit: .ohm, type: .voltage, index: variables.count))
            row.append(value)
            portClassifications["input_port_impedance"] = "finite"
        case .openCircuit:
            portClassifications["input_port_impedance"] = "open_circuit"
        }
        switch transferFunctionResult.outputPortImpedance {
        case .finite(let value):
            variables.append(VariableDescriptor(name: "Zout", unit: .ohm, type: .voltage, index: variables.count))
            row.append(value)
            portClassifications["output_port_impedance"] = "finite"
        case .openCircuit:
            portClassifications["output_port_impedance"] = "open_circuit"
        }

        let metadata = SimulationMetadata(
            title: title,
            analysisType: .transferFunction,
            pointCount: 1,
            variableCount: variables.count,
            options: portClassifications
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
            realData: [row]
        ).retainingStorage(transferFunctionResult.retainedStorage)
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
                unit: .voltSquaredPerHertz,
                type: .noiseDensity,
                index: 0
            ),
            VariableDescriptor(
                name: "input_referred_noise_density",
                unit: noiseResult.inputQuantity == .current ? .ampereSquaredPerHertz : .voltSquaredPerHertz,
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
                noiseResult.outputNoiseDensity[index],
                noiseResult.inputReferredNoiseDensity[index],
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
        ).retainingStorage(noiseResult.retainedStorage)
    }

    // MARK: - From Pole-Zero Result

    /// Creates waveform data from a pole-zero analysis result.
    ///
    /// One complex point contains an individually named column for each actual
    /// pole and zero in rad/s, followed by the dimensionless DC gain.
    public static func from(
        poleZeroResult: PoleZeroResult,
        title: String? = nil
    ) -> WaveformData {
        let variableCount = poleZeroResult.poles.count + poleZeroResult.zeros.count + 1
        var variables: [VariableDescriptor] = []
        var row: [(real: Double, imag: Double)] = []
        variables.reserveCapacity(variableCount)
        row.reserveCapacity(variableCount)
        for (index, pole) in poleZeroResult.poles.enumerated() {
            variables.append(VariableDescriptor(name: "pole_\(index)", unit: .radianPerSecond,
                type: .frequency, index: variables.count))
            row.append((real: pole.real, imag: pole.imag))
        }
        for (index, zero) in poleZeroResult.zeros.enumerated() {
            variables.append(VariableDescriptor(name: "zero_\(index)", unit: .radianPerSecond,
                type: .frequency, index: variables.count))
            row.append((real: zero.real, imag: zero.imag))
        }
        variables.append(VariableDescriptor(name: "dc_gain", unit: .dimensionless,
            type: .magnitude, index: variables.count))
        row.append((real: poleZeroResult.dcGain, imag: 0))

        return WaveformData(
            metadata: SimulationMetadata(
                title: title,
                analysisType: .poleZero,
                pointCount: 1,
                variableCount: variables.count,
                isComplex: true
            ),
            sweepVariable: VariableDescriptor(
                name: "index",
                unit: .dimensionless,
                type: .parameter,
                index: 0
            ),
            sweepValues: [0],
            variables: variables,
            complexData: [row]
        ).retainingStorage(poleZeroResult.retainedStorage)
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
        ).retainingStorage(fourierResult.retainedStorage)
    }

    // MARK: - From Sensitivity Result

    /// Creates waveform data from a sensitivity analysis result.
    ///
    /// Each data point corresponds to a parameter. The shared normalized
    /// sensitivity column is included only when every parameter defines it.
    public static func from(
        sensitivityResult: SensitivityResult,
        title: String? = nil
    ) -> WaveformData {
        let entries = sensitivityResult.sensitivities
        guard !entries.isEmpty else {
            return WaveformData.empty(analysisType: .sensitivity)
        }

        let includeNormalized = entries.allSatisfy { $0.normalizedSensitivity != nil }
        var variables = [
            VariableDescriptor(
                name: "sensitivity",
                unit: .dimensionless,
                type: .voltage,
                index: 0
            ),
        ]
        if includeNormalized {
            variables.append(VariableDescriptor(
                name: "normalized_sensitivity",
                unit: .dimensionless,
                type: .voltage,
                index: 1
            ))
        }

        var realData: [[Double]] = []
        var sweepValues: [Double] = []

        for (i, entry) in entries.enumerated() {
            sweepValues.append(Double(i))
            var row = [entry.sensitivity]
            if includeNormalized, let normalized = entry.normalizedSensitivity {
                row.append(normalized)
            }
            realData.append(row)
        }

        let metadata = SimulationMetadata(
            title: title,
            analysisType: .sensitivity,
            pointCount: entries.count,
            variableCount: variables.count
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
        ).retainingStorage(sensitivityResult.retainedStorage)
    }

    /// Creates complex waveform data from an AC sensitivity result.
    ///
    /// Each parameter contributes an absolute derivative column over the shared
    /// sweep. Its normalized column requires a defined value at every frequency.
    public static func from(
        acSensitivityResult: ACSensitivityResult,
        title: String? = nil
    ) -> WaveformData {
        let includeNormalized = acSensitivityResult.sensitivities.map {
            $0.normalizedSensitivities.allSatisfy { $0 != nil }
        }
        var variables: [VariableDescriptor] = []
        variables.reserveCapacity(acSensitivityResult.sensitivities.count * 2)
        for (index, entry) in acSensitivityResult.sensitivities.enumerated() {
            let baseName = "\(entry.deviceName).\(entry.parameterName)"
            variables.append(VariableDescriptor(
                name: "d\(acSensitivityResult.outputVariable)/d\(baseName)",
                unit: .dimensionless,
                type: .voltage,
                index: variables.count
            ))
            if includeNormalized[index] {
                variables.append(VariableDescriptor(
                    name: "normalized_\(baseName)",
                    unit: .dimensionless,
                    type: .magnitude,
                    index: variables.count
                ))
            }
        }

        let complexData = acSensitivityResult.frequencies.indices.map { frequencyIndex in
            var row: [(real: Double, imag: Double)] = []
            row.reserveCapacity(variables.count)
            for (index, entry) in acSensitivityResult.sensitivities.enumerated() {
                let derivative = entry.sensitivities[frequencyIndex]
                row.append((real: derivative.real, imag: derivative.imag))
                if includeNormalized[index],
                   let normalized = entry.normalizedSensitivities[frequencyIndex] {
                    row.append((real: normalized.real, imag: normalized.imag))
                }
            }
            return row
        }

        return WaveformData(
            metadata: SimulationMetadata(
                title: title,
                analysisType: .sensitivity,
                pointCount: acSensitivityResult.frequencies.count,
                variableCount: variables.count,
                isComplex: true
            ),
            sweepVariable: .frequency(),
            sweepValues: acSensitivityResult.frequencies,
            variables: variables,
            complexData: complexData
        ).retainingStorage(acSensitivityResult.retainedStorage)
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
