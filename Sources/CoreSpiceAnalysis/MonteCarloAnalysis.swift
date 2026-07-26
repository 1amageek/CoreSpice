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

    /// Device binding service used for every sampled circuit.
    public let deviceBinding: any CircuitDeviceBinding

    public init(
        iterations: Int,
        variations: [ParameterVariation],
        analysisFactory: @Sendable @escaping () -> A,
        seed: UInt64? = nil,
        deviceBinding: any CircuitDeviceBinding = StandardCircuitDeviceBinding()
    ) {
        self.iterations = iterations
        self.variations = variations
        self.analysisFactory = analysisFactory
        self.seed = seed
        self.deviceBinding = deviceBinding
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
        try PreparedCircuit.validate(plan: plan, devices: devices)
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
            guard iterations > 0 else {
                throw AnalysisError.invalidConfiguration("Monte Carlo iterations must be positive")
            }
            try validateVariations(in: plan)

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
                let perturbedCircuit = try rebindDevices(
                    plan: plan,
                    overrides: instanceOverrides
                )

                // Run the inner analysis
                let analysis = analysisFactory()
                let result = try await analysis.run(
                    plan: plan,
                    devices: perturbedCircuit.devices,
                    solver: solver,
                    observer: nil,
                    cancellation: cancellation
                )

                allResults.append(result)
                allParamValues.append(sampledParams)

                // Emit progress
                let fraction = Double(iteration + 1) / Double(iterations)
                await observer?.emit(.progressUpdate(try ProgressInfo(
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
        overrides: [String: [String: Double]]
    ) throws -> PreparedCircuit {
        var instances: [Instance] = []
        instances.reserveCapacity(plan.ir.instances.count)
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
                    parameters: params,
                    ownedBranches: instance.ownedBranches,
                    referencedBranches: instance.referencedBranches,
                    referencedNodes: instance.referencedNodes,
                    opticalNodes: instance.opticalNodes
                )
            } else {
                inst = instance
            }

            instances.append(inst)
        }
        return try deviceBinding.bind(plan: plan, instances: instances)
    }

    private func validateVariations(in plan: ExecutionPlan) throws {
        let instances = Dictionary(
            uniqueKeysWithValues: plan.ir.instances.map { ($0.name.lowercased(), $0) }
        )
        for variation in variations {
            guard variation.nominalValue.isFinite else {
                throw AnalysisError.invalidConfiguration(
                    "Monte Carlo nominal value must be finite for \(variation.deviceName).\(variation.parameterName)"
                )
            }
            guard let instance = instances[variation.deviceName.lowercased()] else {
                throw AnalysisError.invalidConfiguration(
                    "Monte Carlo device \(variation.deviceName) does not exist"
                )
            }
            guard case .real? = instance.parameters[variation.parameterName] else {
                throw AnalysisError.invalidConfiguration(
                    "Monte Carlo parameter \(variation.deviceName).\(variation.parameterName) is not a real device parameter"
                )
            }
            switch variation.distribution {
            case .gaussian(let sigma):
                guard sigma.isFinite, sigma >= 0 else {
                    throw AnalysisError.invalidConfiguration(
                        "Monte Carlo sigma must be finite and nonnegative"
                    )
                }
            case .uniform(let range):
                guard range.isFinite, range >= 0 else {
                    throw AnalysisError.invalidConfiguration(
                        "Monte Carlo range must be finite and nonnegative"
                    )
                }
            }
        }
    }
}
