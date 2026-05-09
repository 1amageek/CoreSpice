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

        var wavelengthResults: [PhotonicWavelengthResult] = []

        for (wIdx, wavelength) in batch.wavelengths.enumerated() {
            if cancellation.isCancelled {
                await observer?.emit(.analysisFinished(AnalysisFinishedInfo(
                    id: analysisID,
                    type: .photonic,
                    status: .cancelled,
                    timestamp: Timestamp(),
                    wallTime: Timestamp().elapsed(since: startTimestamp)
                )))
                throw PhotonicExecutionError.cancelled
            }

            await observer?.emit(.sweepPointStarted(SweepPointInfo(
                id: analysisID,
                index: wIdx,
                total: batch.wavelengths.count,
                value: wavelength,
                parameterName: "wavelength"
            )))

            // Compile the mesh for this wavelength
            let plan = compiler.compile(mesh: mesh, wavelength: wavelength)

            // Allocate state buffer: repetitions * 512 complex values (float2)
            let batchSize = batch.repetitions
            let stateBuffer = try backend.allocateBuffer(
                type: Float.self,
                count: batchSize * 512 * 2,
                label: "state"
            )

            // Initialize state: zero everything, then set the input port amplitude
            let statePtr = backend.contents(of: stateBuffer, as: Float.self)
            for i in 0..<statePtr.count {
                statePtr[i] = 0
            }
            for r in 0..<batchSize {
                let baseIdx = r * 512 * 2
                statePtr[baseIdx + batch.inputPortIndex * 2] = Float(batch.inputAmplitude)
                statePtr[baseIdx + batch.inputPortIndex * 2 + 1] = 0  // imag = 0
            }

            // Process each layer through the GPU
            for layerIdx in 0..<plan.layerCount {
                let coeffs = plan.coefficients[layerIdx]
                let desc = plan.descriptors[layerIdx]

                // Upload coefficients to GPU buffer
                let coeffBuffer = try backend.allocateBuffer(
                    type: MZICoefficients.self,
                    count: coeffs.count,
                    label: "coeffs_L\(layerIdx)"
                )
                let coeffPtr = backend.contents(of: coeffBuffer, as: MZICoefficients.self)
                for (i, c) in coeffs.enumerated() {
                    coeffPtr[i] = c
                }

                try await backend.dispatchMZILayer(
                    stateBuffer: stateBuffer,
                    coefficients: coeffBuffer,
                    layerDescriptor: desc,
                    batchSize: batchSize,
                    observer: observer,
                    tag: "layer_\(layerIdx)"
                )

                backend.releaseBuffer(coeffBuffer)
            }

            try await backend.synchronize()

            // Read results and average over repetitions
            var outputs: [PhotonicPortOutput] = []
            let resultPtr = backend.contents(of: stateBuffer, as: Float.self)
            for port in 0..<512 {
                var totalReal: Float = 0
                var totalImag: Float = 0
                for r in 0..<batchSize {
                    let baseIdx = r * 512 * 2
                    totalReal += resultPtr[baseIdx + port * 2]
                    totalImag += resultPtr[baseIdx + port * 2 + 1]
                }
                outputs.append(PhotonicPortOutput(
                    portIndex: port,
                    real: totalReal / Float(batchSize),
                    imag: totalImag / Float(batchSize)
                ))
            }

            backend.releaseBuffer(stateBuffer)

            wavelengthResults.append(PhotonicWavelengthResult(
                wavelength: wavelength,
                outputs: outputs
            ))

            await observer?.emit(.sweepPointFinished(SweepPointResultInfo(
                id: analysisID,
                index: wIdx,
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
    }
}
