/// Configuration for a wavelength-sweep batch simulation.
///
/// Defines which wavelengths to sweep, how many repetitions to
/// perform per wavelength, and which input port receives the signal.
public struct PhotonicSweepBatch: Sendable {

    /// Wavelengths to sweep in meters.
    public let wavelengths: [Double]

    /// Number of repetitions per wavelength (for noise averaging).
    public let repetitions: Int

    /// Index of the input port that receives the signal (0--511).
    public let inputPortIndex: Int

    /// Amplitude of the input signal (linear).
    public let inputAmplitude: Double

    public init(
        wavelengths: [Double],
        repetitions: Int = 1,
        inputPortIndex: Int = 0,
        inputAmplitude: Double = 1.0
    ) {
        self.wavelengths = wavelengths
        self.repetitions = repetitions
        self.inputPortIndex = inputPortIndex
        self.inputAmplitude = inputAmplitude
    }

    public func validate() throws {
        guard !wavelengths.isEmpty else {
            throw PhotonicExecutionError.emptyWavelengthSweep
        }
        for (index, wavelength) in wavelengths.enumerated() {
            guard wavelength.isFinite, wavelength > 0 else {
                throw PhotonicExecutionError.invalidWavelength(index: index, value: wavelength)
            }
        }
        guard repetitions > 0 else {
            throw PhotonicExecutionError.invalidRepetitionCount(repetitions)
        }
        guard (0..<512).contains(inputPortIndex) else {
            throw PhotonicExecutionError.invalidInputPort(inputPortIndex)
        }
        guard inputAmplitude.isFinite,
              abs(inputAmplitude) <= Double(Float.greatestFiniteMagnitude) else {
            throw PhotonicExecutionError.invalidInputAmplitude(inputAmplitude)
        }
    }

    /// Total number of state vectors across the wavelength sweep.
    public func totalBatchSize() throws -> Int {
        try validate()
        let (size, overflow) = wavelengths.count.multipliedReportingOverflow(by: repetitions)
        guard !overflow else {
            throw PhotonicExecutionError.sizeOverflow("total batch size")
        }
        return size
    }

    func stateElementCount() throws -> Int {
        try validate()
        let (portValues, portOverflow) = PhotonicMesh512.portCount.multipliedReportingOverflow(by: 2)
        let (count, batchOverflow) = repetitions.multipliedReportingOverflow(by: portValues)
        guard !portOverflow, !batchOverflow else {
            throw PhotonicExecutionError.sizeOverflow("state element count")
        }
        return count
    }
}
