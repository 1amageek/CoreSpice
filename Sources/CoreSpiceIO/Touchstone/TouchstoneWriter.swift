import CoreSpiceCompile
import CoreSpiceExporter
import Foundation

/// Exclusively owned synchronous formatter/output. It is intentionally non-Sendable.
final class TouchstoneWriter {
    private let output: TouchstoneOutput
    private let configuration: TouchstoneEncodingConfiguration
    private let portCount: Int
    private let frequencyCount: Int
    private var writtenPoints = 0
    private var previousFrequency: Double?
    private var previousWireFrequency: Double?

    init(destination: ExportDestination, parameterKind: TouchstoneParameterKind,
         references: [Double], frequencyCount: Int,
         configuration: TouchstoneEncodingConfiguration, limits: TouchstoneLimits) throws {
        try limits.validate()
        try Task.checkCancellation()
        guard !references.isEmpty, references.allSatisfy({ $0.isFinite && $0 > 0 }), frequencyCount > 0 else {
            throw TouchstoneError.invalidData("Positive references and frequency count required")
        }
        guard references.count <= limits.maximumPorts, frequencyCount <= limits.maximumFrequencyPoints else {
            throw TouchstoneError.invalidConfiguration("Ports or frequency count exceed codec limits")
        }
        let (elements, overflow) = references.count.multipliedReportingOverflow(by: references.count)
        guard !overflow else { throw TouchstoneError.invalidData("Port matrix size overflow") }
        let matrixBytes = try touchstoneBytes(elements, MemoryLayout<ComplexPair>.stride)
        guard matrixBytes <= limits.maximumRetainedBytes else { throw TouchstoneError.invalidConfiguration("Matrix exceeds retained storage limit") }
        self.configuration = configuration
        portCount = references.count
        self.frequencyCount = frequencyCount
        output = try TouchstoneOutput(destination: destination, limits: limits)
        do {
            try output.writeLine("[Version] \(configuration.version.rawValue)")
            try output.writeLine("# \(configuration.frequencyUnit.rawValue) \(parameterKind.rawValue) \(configuration.dataFormat.rawValue) R 50")
            try output.writeLine("[Number of Ports] \(portCount)")
            if portCount == 2 { try output.writeLine("[Two-Port Data Order] \(configuration.twoPortOrder.rawValue)") }
            try output.writeLine("[Number of Frequencies] \(frequencyCount)")
            var referenceLine = "[Reference]"
            for value in references { try append(String(value), to: &referenceLine) }
            try output.writeLine(referenceLine)
            try output.writeLine("[Matrix Format] \(configuration.matrixFormat.rawValue)")
            try output.writeLine("[Network Data]")
        } catch { throw output.discard(after: error) }
    }

    func writePoint(_ point: TouchstonePoint) throws {
        try output.requireOpen()
        try Task.checkCancellation()
        guard writtenPoints < frequencyCount, point.matrix.portCount == portCount,
              previousFrequency.map({ point.frequencyHz > $0 }) ?? true else {
            throw TouchstoneError.invalidData("Unexpected point count, width or frequency order")
        }
        let frequency = point.frequencyHz / configuration.frequencyUnit.multiplier
        guard frequency.isFinite, point.frequencyHz == 0 || frequency > 0 else {
            throw TouchstoneError.unrepresentable("Frequency unit conversion underflow")
        }
        guard previousWireFrequency.map({ frequency > $0 }) ?? true else {
            throw TouchstoneError.unrepresentable("Frequency unit conversion collapses distinct points")
        }
        if configuration.matrixFormat != .full {
            for row in 0..<portCount {
                try Task.checkCancellation()
                for column in 0..<row {
                    if column % 128 == 0 { try Task.checkCancellation() }
                    guard point.matrix.values[row * portCount + column] == point.matrix.values[column * portCount + row] else {
                        throw TouchstoneError.unrepresentable("Triangular output requires an exactly symmetric matrix")
                    }
                }
            }
        }
        for row in 0..<portCount {
            try Task.checkCancellation()
            var text = row == 0 ? String(frequency) : ""
            let triangular = configuration.matrixFormat != .full
            let useLower = configuration.matrixFormat == .lower || (portCount == 2 && triangular)
            let first = triangular && !useLower ? row : 0
            let last = triangular && useLower ? row + 1 : portCount
            for column in first..<last {
                if column % 128 == 0 { try Task.checkCancellation() }
                let pair: ComplexPair
                if portCount == 2, !triangular, configuration.twoPortOrder == .order21_12 {
                    pair = point.matrix.values[column * portCount + row]
                } else { pair = point.matrix.values[row * portCount + column] }
                let values = try encoded(pair)
                try append(String(values.0), to: &text)
                try append(String(values.1), to: &text)
            }
            try output.writeLine(text)
        }
        previousFrequency = point.frequencyHz
        previousWireFrequency = frequency
        writtenPoints += 1
    }

    private func append(_ value: String, to text: inout String) throws {
        let (bytes, overflow) = text.utf8.count.addingReportingOverflow(value.utf8.count + (text.isEmpty ? 0 : 1))
        guard !overflow else { throw TouchstoneError.invalidData("Encoded line byte count overflow") }
        try output.admitLineStorage(byteCount: bytes)
        if !text.isEmpty { text += " " }
        text += value
    }

    private func encoded(_ pair: ComplexPair) throws -> (Double, Double) {
        guard pair.real.isFinite, pair.imag.isFinite else { throw TouchstoneError.invalidData("Nonfinite matrix element") }
        if configuration.dataFormat == .realImaginary { return (pair.real, pair.imag) }
        let magnitude = hypot(pair.real, pair.imag)
        guard magnitude.isFinite else { throw TouchstoneError.unrepresentable("Magnitude exceeds finite representation") }
        let angle = atan2(pair.imag, pair.real) * (180 / .pi)
        if configuration.dataFormat == .magnitudeAngle { return (magnitude, angle) }
        guard magnitude > 0 else { throw TouchstoneError.unrepresentable("Exact zero has no finite dB representation; use RI or MA") }
        return (20 * log10(magnitude), angle)
    }

    func finalize() throws -> ExportResult {
        try output.requireOpen()
        try Task.checkCancellation()
        guard writtenPoints == frequencyCount else { throw TouchstoneError.invalidData("Declared frequency count does not match written points") }
        try output.writeLine("[End]")
        return try output.finalize(points: writtenPoints, elements: portCount * portCount)
    }

    func cancel() throws { try output.cancel() }
    func discard(after error: any Error) -> any Error { output.discard(after: error) }
}
