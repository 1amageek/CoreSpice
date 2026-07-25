import Foundation

/// Errors that can occur during photonic mesh execution.
public enum PhotonicExecutionError: Error, Sendable, LocalizedError {

    /// The simulation was cancelled via the cancellation token.
    case cancelled

    /// A GPU buffer could not be allocated.
    case bufferAllocationFailed(String)

    /// A GPU kernel dispatch failed.
    case dispatchFailed(String)

    case emptyWavelengthSweep
    case invalidWavelength(index: Int, value: Double)
    case invalidRepetitionCount(Int)
    case invalidInputPort(Int)
    case invalidInputAmplitude(Double)
    case invalidLayer(layer: Int, pairCount: Int, maximum: Int)
    case invalidMZIBlock(layer: Int, block: Int, reason: String)
    case invalidWavelengthModel(String)
    case sizeOverflow(String)
    case insufficientBufferCapacity(label: String, required: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "Photonic execution was cancelled."
        case .bufferAllocationFailed(let reason):
            "Photonic buffer allocation failed: \(reason)"
        case .dispatchFailed(let reason):
            "Photonic dispatch failed: \(reason)"
        case .emptyWavelengthSweep:
            "Photonic wavelength sweep must contain at least one point."
        case .invalidWavelength(let index, let value):
            "Wavelength \(index) must be finite and positive; received \(value)."
        case .invalidRepetitionCount(let value):
            "Repetition count must be positive; received \(value)."
        case .invalidInputPort(let value):
            "Input port must be in 0..<512; received \(value)."
        case .invalidInputAmplitude(let value):
            "Input amplitude must be finite and representable as Float; received \(value)."
        case .invalidLayer(let layer, let pairCount, let maximum):
            "Layer \(layer) contains \(pairCount) pairs; its pattern supports at most \(maximum)."
        case .invalidMZIBlock(let layer, let block, let reason):
            "MZI block \(block) in layer \(layer) is invalid: \(reason)"
        case .invalidWavelengthModel(let reason):
            "Wavelength model is invalid: \(reason)"
        case .sizeOverflow(let context):
            "Photonic buffer size overflowed while computing \(context)."
        case .insufficientBufferCapacity(let label, let required, let actual):
            "Buffer \(label) requires \(required) elements but exposes \(actual)."
        }
    }
}
