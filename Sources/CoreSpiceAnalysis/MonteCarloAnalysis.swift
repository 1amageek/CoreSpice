import CoreSpiceCompile
import CoreSpiceDevices
import CoreSpiceIR
import CoreSpiceEvent

/// Monte Carlo (.mc) analysis.
///
/// Runs an inner analysis multiple times with randomly varied device
/// parameters, collecting the results for statistical analysis.
///
/// Each iteration:
/// 1. Samples random parameter values from specified distributions.
/// 2. Creates perturbed device instances with the sampled values.
/// 3. Rebinds devices and runs the inner analysis.
/// 4. Collects the result.
///
/// The analysis supports deterministic runs via a seed value for
/// reproducibility.
public struct MonteCarloAnalysis<A: Analysis>: Sendable {

    /// The number of Monte Carlo iterations.
    public let iterations: Int

    /// The parameter variations to apply.
    public let variations: [ParameterVariation]

    /// Factory that creates the inner analysis.
    public let analysisFactory: @Sendable () -> A

    /// Optional seed for reproducible results.
    public let seed: UInt64?

    public init(
        iterations: Int,
        variations: [ParameterVariation],
        analysisFactory: @Sendable @escaping () -> A,
        seed: UInt64? = nil
    ) {
        self.iterations = iterations
        self.variations = variations
        self.analysisFactory = analysisFactory
        self.seed = seed
    }

    /// Runs the Monte Carlo analysis.
    ///
    /// - Parameters:
    ///   - plan: The compiled execution plan.
    ///   - devices: Bound device instances (used as baseline template).
    ///   - solver: The linear solver.
    ///   - observer: Optional event dispatcher.
    ///   - cancellation: Cooperative cancellation token.
    /// - Returns: A ``MonteCarloResult`` with results from all iterations.
    public func run(
        plan: ExecutionPlan,
        devices: [any BoundDevice],
        solver: any LinearSolver,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> MonteCarloResult<A.Result> {
        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .mc,
            timestamp: startTimestamp,
            nodeCount: plan.ir.nodes.count,
            deviceCount: devices.count
        )))

        do {
            let registry = DeviceRegistry.standard()
            var rng: any RandomNumberGenerator = seed.map {
                SeededRandomNumberGenerator(seed: $0) as any RandomNumberGenerator
            } ?? SystemRandomNumberGenerator() as any RandomNumberGenerator

            var allResults: [A.Result] = []
            var allParamValues: [[String: Double]] = []

            for iteration in 0..<iterations {
                if cancellation.isCancelled {
                    throw AnalysisError.cancelled
                }

                // Sample parameter values for this iteration
                var sampledParams: [String: Double] = [:]
                var instanceOverrides: [String: [String: Double]] = [:]

                for variation in variations {
                    let value = variation.sample(rng: &rng)
                    let key = "\(variation.deviceName).\(variation.parameterName)"
                    sampledParams[key] = value
                    instanceOverrides[variation.deviceName, default: [:]][variation.parameterName] = value
                }

                // Rebuild devices with the sampled parameters
                let perturbedDevices = try rebindDevices(
                    plan: plan,
                    registry: registry,
                    overrides: instanceOverrides
                )

                // Run the inner analysis
                let analysis = analysisFactory()
                let result = try await analysis.run(
                    plan: plan,
                    devices: perturbedDevices,
                    solver: solver,
                    observer: nil,
                    cancellation: cancellation
                )

                allResults.append(result)
                allParamValues.append(sampledParams)

                // Emit progress
                let fraction = Double(iteration + 1) / Double(iterations)
                await observer?.emit(.progressUpdate(ProgressInfo(
                    id: analysisID,
                    fraction: fraction,
                    message: "Monte Carlo: iteration \(iteration + 1)/\(iterations)"
                )))
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .mc,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return MonteCarloResult(
                iterations: iterations,
                results: allResults,
                parameterValues: allParamValues,
                seed: seed
            )
        } catch {
            let status: AnalysisStatus
            if let analysisError = error as? AnalysisError,
               case .cancelled = analysisError {
                status = .cancelled
            } else {
                status = .failed
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .mc,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))

            throw error
        }
    }

    // MARK: - Private

    /// Rebinds all device instances, applying parameter overrides where specified.
    private func rebindDevices(
        plan: ExecutionPlan,
        registry: DeviceRegistry,
        overrides: [String: [String: Double]]
    ) throws -> [any BoundDevice] {
        let structure = plan.matrixStructure
        var context = BindingContext(
            variableMap: plan.topology.variableMap,
            matrixDimension: plan.topology.dimension,
            stampIndexResolver: { row, col in structure.index(row: row, col: col) }
        )
        var devices: [any BoundDevice] = []

        for instance in plan.ir.instances {
            let inst: Instance
            if let paramOverrides = overrides[instance.name] {
                var params = instance.parameters
                for (key, value) in paramOverrides {
                    params[key] = .real(value)
                }
                inst = Instance(
                    name: instance.name,
                    typeName: instance.typeName,
                    nodes: instance.nodes,
                    parameters: params
                )
            } else {
                inst = instance
            }

            guard let desc = registry.descriptor(for: inst.typeName) else { continue }
            let bound = try desc.bind(instance: inst, context: &context)
            devices.append(bound)
        }

        return devices
    }
}
