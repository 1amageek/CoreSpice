/// A device with an explicit noise-analysis capability admission contract.
public protocol NoiseAnalysisAdmissionDevice: BoundDevice {
    func validateNoiseAnalysis() throws
}
