import CoreSpiceEvent
import CoreSpiceBackend
import SharedTypes

/// Orchestrates GPU dispatch for photonic mesh simulations.
///
/// The executor compiles the mesh at each wavelength, initialises
/// the port state buffer, dispatches each layer through the
/// `PhotonicComputeBackend`, and collects the output amplitudes.
/// Observer events are emitted at every stage for monitoring.
public struct PhotonicExecutor: Sendable {

    public init() {}

    /// Execute a wavelength-sweep simulation on the given mesh.
    ///
    /// - Parameters:
    ///   - mesh: The 512-port photonic mesh to simulate.
    ///   - batch: Sweep configuration (wavelengths, input port, etc.).
    ///   - backend: A GPU backend conforming to `PhotonicComputeBackend`.
    ///   - observer: Optional event dispatcher for progress reporting.
    ///   - cancellation: Token checked between sweep points for early exit.
    /// - Returns: Aggregated simulation results across all wavelengths.
    public func execute<Backend: PhotonicComputeBackend>(
        mesh: PhotonicMesh512,
        batch: PhotonicSweepBatch,
        backend: Backend,
        observer: EventDispatcher?,
        cancellation: CancellationToken
    ) async throws -> PhotonicResult {
        try batch.validate()
        try mesh.validate()

        let analysisID = AnalysisID()
        let startTimestamp = Timestamp()
        let compiler = PhotonicCompiler()

        await observer?.emit(.analysisStarted(AnalysisStartedInfo(
            id: analysisID,
            type: .photonic,
            timestamp: startTimestamp,
            nodeCount: PhotonicMesh512.portCount,
            deviceCount: mesh.layerCount
        )))

        do {
            var wavelengthResults: [PhotonicWavelengthResult] = []
            let stateElementCount = try batch.stateElementCount()

            for (wavelengthIndex, wavelength) in batch.wavelengths.enumerated() {
                try checkCancellation(cancellation)

                await observer?.emit(.sweepPointStarted(SweepPointInfo(
                    id: analysisID,
                    index: wavelengthIndex,
                    total: batch.wavelengths.count,
                    value: wavelength,
                    parameterName: "wavelength"
                )))

                let plan = try compiler.compile(mesh: mesh, wavelength: wavelength)
                let stateBuffer = try backend.allocateBuffer(
                    type: Float.self,
                    count: stateElementCount,
                    label: "state"
                )
                defer { backend.releaseBuffer(stateBuffer) }

                try backend.withMutableContents(of: stateBuffer, as: Float.self) { state in
                    guard state.count >= stateElementCount else {
                        throw PhotonicExecutionError.insufficientBufferCapacity(
                            label: "state",
                            required: stateElementCount,
                            actual: state.count
                        )
                    }
                    for index in 0..<stateElementCount {
                        state[index] = 0
                    }
                    for repetition in 0..<batch.repetitions {
                        let baseIndex = repetition * PhotonicMesh512.portCount * 2
                        let inputIndex = baseIndex + batch.inputPortIndex * 2
                        state[inputIndex] = Float(batch.inputAmplitude)
                    }
                }

                for layerIndex in 0..<plan.layerCount {
                    try checkCancellation(cancellation)
                    let coefficients = plan.coefficients[layerIndex]
                    let descriptor = plan.descriptors[layerIndex]
                    let coefficientBuffer = try backend.allocateBuffer(
                        type: MZICoefficients.self,
                        count: coefficients.count,
                        label: "coefficients-layer-\(layerIndex)"
                    )
                    defer { backend.releaseBuffer(coefficientBuffer) }

                    try backend.withMutableContents(
                        of: coefficientBuffer,
                        as: MZICoefficients.self
                    ) { destination in
                        guard destination.count >= coefficients.count else {
                            throw PhotonicExecutionError.insufficientBufferCapacity(
                                label: "coefficients-layer-\(layerIndex)",
                                required: coefficients.count,
                                actual: destination.count
                            )
                        }
                        coefficients.withUnsafeBufferPointer { source in
                            guard let sourceAddress = source.baseAddress,
                                  let destinationAddress = destination.baseAddress else {
                                return
                            }
                            destinationAddress.update(
                                from: sourceAddress,
                                count: coefficients.count
                            )
                        }
                    }

                    try await backend.dispatchMZILayer(
                        stateBuffer: stateBuffer,
                        coefficients: coefficientBuffer,
                        layerDescriptor: descriptor,
                        batchSize: batch.repetitions,
                        observer: observer,
                        tag: "layer-\(layerIndex)"
                    )
                }

                try await backend.synchronize()
                let outputs = try backend.withMutableContents(
                    of: stateBuffer,
                    as: Float.self
                ) { state -> [PhotonicPortOutput] in
                    guard state.count >= stateElementCount else {
                        throw PhotonicExecutionError.insufficientBufferCapacity(
                            label: "state",
                            required: stateElementCount,
                            actual: state.count
                        )
                    }
                    var values: [PhotonicPortOutput] = []
                    values.reserveCapacity(PhotonicMesh512.portCount)
                    for port in 0..<PhotonicMesh512.portCount {
                        var totalReal: Float = 0
                        var totalImaginary: Float = 0
                        for repetition in 0..<batch.repetitions {
                            let baseIndex = repetition * PhotonicMesh512.portCount * 2
                            totalReal += state[baseIndex + port * 2]
                            totalImaginary += state[baseIndex + port * 2 + 1]
                        }
                        values.append(PhotonicPortOutput(
                            portIndex: port,
                            real: totalReal / Float(batch.repetitions),
                            imag: totalImaginary / Float(batch.repetitions)
                        ))
                    }
                    return values
                }

                wavelengthResults.append(PhotonicWavelengthResult(
                    wavelength: wavelength,
                    outputs: outputs
                ))

                await observer?.emit(.sweepPointFinished(SweepPointResultInfo(
                    id: analysisID,
                    index: wavelengthIndex,
                    value: wavelength,
                    parameterName: "wavelength",
                    converged: true,
                    iterations: mesh.layerCount
                )))
            }

            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .photonic,
                status: .completed,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp)
            )))

            return PhotonicResult(
                wavelengthResults: wavelengthResults,
                meshLayerCount: mesh.layerCount
            )
        } catch {
            let executionWasCancelled: Bool
            if case .cancelled? = error as? PhotonicExecutionError {
                executionWasCancelled = true
            } else {
                executionWasCancelled = error is CancellationError
            }
            let status: AnalysisStatus = executionWasCancelled
                ? .cancelled
                : .failed
            await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                id: analysisID,
                type: .photonic,
                status: status,
                timestamp: Timestamp(),
                wallTime: Timestamp().elapsed(since: startTimestamp),
                failure: status.failureInfo(for: error)
            )))
            throw error
        }
    }

    private func checkCancellation(_ cancellation: CancellationToken) throws {
        guard !cancellation.isCancelled, !Task.isCancelled else {
            throw PhotonicExecutionError.cancelled
        }
    }
}
