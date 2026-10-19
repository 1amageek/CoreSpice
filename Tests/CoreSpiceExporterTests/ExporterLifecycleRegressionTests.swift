import Foundation
import Testing
import CoreSpiceExporter
import CoreSpiceExporterCSV
import CoreSpiceExporterRAW
import CoreSpiceExporterPSF
import CoreSpiceWaveform

@Suite(.timeLimit(.minutes(1)))
struct ExporterLifecycleRegressionTests {
    private enum Format: String, CaseIterable, Sendable {
        case csv, rawASCII, rawBinary, psf

        var exporter: any StreamingWaveformExporter {
            switch self {
            case .csv: CSVExporter()
            case .rawASCII: RAWExporter(useBinaryFormat: false)
            case .rawBinary: RAWExporter(useBinaryFormat: true)
            case .psf: PSFExporter()
            }
        }
    }

    private actor StartBarrier {
        private var remaining: Int
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(parties: Int) { remaining = parties }

        func arrive() async {
            remaining -= 1
            if remaining == 0 {
                for waiter in waiters { waiter.resume() }
                waiters.removeAll()
            } else {
                await withCheckedContinuation { waiters.append($0) }
            }
        }
    }

    private struct CancellingWaveform: WaveformReadable {
        let base: WaveformData
        var metadata: SimulationMetadata { base.metadata }
        var sweepVariable: VariableDescriptor { base.sweepVariable }
        var variables: [VariableDescriptor] { base.variables }
        var isComplex: Bool { false }
        var pointCount: Int { base.pointCount }
        var variableCount: Int { base.variableCount }
        func sweepValue(at point: Int) -> Double? { base.sweepValue(at: point) }
        func realValue(variable: Int, point: Int) -> Double? {
            if point == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            return base.realValue(variable: variable, point: point)
        }
        func complexValue(variable: Int, point: Int) -> (real: Double, imag: Double)? { nil }
        func withRealValues<R>(
            at point: Int, _ body: (UnsafeBufferPointer<Double>) throws -> R
        ) rethrows -> R? { nil }
        func withComplexValues<R>(
            at point: Int, _ body: (UnsafeBufferPointer<(real: Double, imag: Double)>) throws -> R
        ) rethrows -> R? { nil }
    }

    private func waveform() -> WaveformData {
        WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 3, variableCount: 1),
            sweepVariable: .time(), sweepValues: [0, 1, 2],
            variables: [.voltage(node: "out", index: 0)], realData: [[1], [2], [3]]
        )
    }

    private func session(
        _ format: Format, points: Int, destination: ExportDestination = .memory
    ) async throws -> any ExportSession {
        try await format.exporter.beginExport(
            to: destination,
            metadata: SimulationMetadata(analysisType: .transient, pointCount: points, variableCount: 1),
            sweepVariable: .time(), variables: [.voltage(node: "out", index: 0)],
            configuration: .default
        )
    }

    @Test(arguments: [false, true])
    func differentialAndQuotedComplexDescriptorsRoundTrip(forceQuotes: Bool) async throws {
        let variables = [
            VariableDescriptor(name: "V(a,b)", unit: .volt, type: .voltage, index: 0),
            VariableDescriptor(name: "V(quoted\"node)", unit: .volt, type: .voltage, index: 1),
            VariableDescriptor(name: "I(line\nreturn)", unit: .ampere, type: .current, index: 2),
        ]
        let source = WaveformData(
            metadata: SimulationMetadata(analysisType: .ac, pointCount: 2, variableCount: 3, isComplex: true),
            sweepVariable: .frequency(), sweepValues: [100, 200], variables: variables,
            complexData: [[(1.25, -2.5), (3.75, 4.5), (-5.25, 6.5)], [(7.25, 8.5), (-9.75, 10.5), (11.25, -12.5)]]
        )
        let exporter = CSVExporter(quoteFields: forceQuotes)
        let bytes = try await exporter.exportToData(source, configuration: .highPrecision)
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.hasPrefix("frequency [Hz],\"V(a,b)_real [V]\"") || forceQuotes)
        #expect(text.contains("quoted\"\"node"))
        let reloaded = try CSVWaveformReader().read(text)
        #expect(reloaded.variables == source.variables)
        #expect(reloaded.sweepValues == source.sweepValues)
        #expect(reloaded.metadata.analysisType == .ac)
        for point in 0..<2 {
            for variable in 0..<3 {
                let actual = try #require(reloaded.complexValue(variable: variable, point: point))
                let expected = try #require(source.complexValue(variable: variable, point: point))
                #expect(actual.real == expected.real)
                #expect(actual.imag == expected.imag)
            }
        }
    }

    @Test
    func realDifferentialAndCustomSeparatorRoundTrip() async throws {
        let source = WaveformData(
            metadata: SimulationMetadata(analysisType: .transient, pointCount: 2, variableCount: 2),
            sweepVariable: .time(), sweepValues: [0, 1],
            variables: [
                VariableDescriptor(name: "V(a,b)", unit: .volt, type: .voltage, index: 0),
                VariableDescriptor(name: "I(a;b)", unit: .ampere, type: .current, index: 1),
            ], realData: [[1.25, -2.5], [3.75, -4.5]]
        )
        let separators: [Character] = [",", ";", "\t"]
        for separator in separators {
            let bytes = try await CSVExporter(separator: String(separator)).exportToData(source)
            let text = try #require(String(data: bytes, encoding: .utf8))
            let reloaded = try CSVWaveformReader(separator: separator).read(text)
            #expect(reloaded.variables == source.variables)
            #expect(reloaded.sweepValues == source.sweepValues)
            #expect(reloaded.allRealData == source.allRealData)
        }
    }

    @Test(arguments: Format.allCases)
    private func concurrentFirstWritersPublishOneHeaderAndEveryCompleteRow(format: Format) async throws {
        let count = 64
        let output = try await session(format, points: count)
        let start = StartBarrier(parties: count)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for point in 0..<count {
                group.addTask {
                    await start.arrive()
                    try await output.writePoint(sweepValue: Double(point), values: [Double(point + 1000)])
                }
            }
            try await group.waitForAll()
        }
        let result = try await output.finalize()
        #expect(output.pointsWritten == count)
        #expect(result.pointsExported == count)
        let rows = try decodedRows(try #require(result.data), format: format)
        #expect(rows.count == count)
        #expect(Set(rows.map { $0.0 }) == Set((0..<count).map { Double($0) }))
        for (sweep, value) in rows { #expect(value == sweep + 1000) }
    }

    @Test(arguments: Format.allCases)
    private func cancellationNeverPublishesAndRemovesPartialFiles(format: Format) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeDirectory(directory) }
        let destination = directory.appendingPathComponent("waveform")
        let original = Data("previous complete export".utf8)
        try original.write(to: destination)
        let base = waveform()
        for stage in ["prestart", "mid", "beforePublication"] {
            let task = Task {
                if stage == "beforePublication" {
                    let output = try await session(format, points: 3, destination: .file(path: destination.path))
                    for point in 0..<3 {
                        try await output.writePoint(sweepValue: Double(point), values: [Double(point + 1)])
                    }
                    withUnsafeCurrentTask { $0?.cancel() }
                    return try await output.finalize()
                }
                if stage == "prestart" { withUnsafeCurrentTask { $0?.cancel() } }
                let source: any WaveformReadable
                if stage == "mid" {
                    source = CancellingWaveform(base: base)
                } else {
                    source = base
                }
                return try await format.exporter.export(source, to: .file(path: destination.path), configuration: .default)
            }
            do {
                _ = try await task.value
                Issue.record("Cancelled export returned success at \(stage), \(format)")
            } catch is CancellationError {
                // Cancellation is the required observable outcome.
            }
            #expect(try Data(contentsOf: destination) == original)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["waveform"])
        }
    }

    @Test(arguments: Format.allCases)
    private func finalizeCancelRaceProducesCompleteOutputOrFailure(format: Format) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { removeDirectory(directory) }
        let destination = directory.appendingPathComponent("waveform")
        let original = Data("previous complete export".utf8)
        try original.write(to: destination)
        let output = try await session(format, points: 2, destination: .file(path: destination.path))
        try await output.writePoint(sweepValue: 0, values: [1000])
        try await output.writePoint(sweepValue: 1, values: [1001])
        let start = StartBarrier(parties: 2)
        let finalize = Task {
            await start.arrive()
            return try await output.finalize()
        }
        let cancel = Task {
            await start.arrive()
            await output.cancel()
        }
        await cancel.value
        do {
            let result = try await finalize.value
            #expect(result.pointsExported == 2)
            let bytes = try Data(contentsOf: destination)
            let rows = try decodedRows(bytes, format: format)
            #expect(rows.map { $0.0 } == [0, 1])
            #expect(rows.map { $0.1 } == [1000, 1001])
        } catch is ExporterError {
            #expect(try Data(contentsOf: destination) == original)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["waveform"])
        await #expect(throws: ExporterError.self) {
            try await output.writePoint(sweepValue: 2, values: [1002])
        }
    }

    private func decodedRows(_ bytes: Data, format: Format) throws -> [(Double, Double)] {
        switch format {
        case .csv:
            let text = try #require(String(data: bytes, encoding: .utf8))
            #expect(text.components(separatedBy: "time [s]").count == 2)
            let waveform = try CSVWaveformReader().read(text)
            return try (0..<waveform.pointCount).map {
                (try #require(waveform.sweepValue(at: $0)), try #require(waveform.realValue(variable: 0, point: $0)))
            }
        case .rawASCII:
            let text = try #require(String(data: bytes, encoding: .utf8))
            #expect(text.components(separatedBy: "Title:").count == 2)
            let values = try #require(text.range(of: "Values:\n"))
            return try text[values.upperBound...].split(separator: "\n").enumerated().map { index, line in
                let fields = line.split(separator: "\t")
                try #require(fields.count == 3)
                #expect(Int(fields[0]) == index)
                return (try #require(Double(fields[1])), try #require(Double(fields[2])))
            }
        case .rawBinary:
            let marker = Data("Binary:\n".utf8)
            let range = try #require(bytes.range(of: marker))
            #expect(bytes.range(of: marker, in: range.upperBound..<bytes.count) == nil)
            let payload = bytes[range.upperBound...]
            try #require(payload.count % 16 == 0)
            return stride(from: payload.startIndex, to: payload.endIndex, by: 16).map { offset in
                (double(bytes, at: offset, bigEndian: false), double(bytes, at: offset + 8, bigEndian: false))
            }
        case .psf:
            #expect(bytes.count >= 4)
            #expect(integer(bytes, at: 0, width: 4) == 1)
            var offset = 4
            var rows: [(Double, Double)] = []
            var valueSections = 0
            var endSections = 0
            while offset + 8 <= bytes.count {
                let kind = integer(bytes, at: offset, width: 4)
                let size = Int(integer(bytes, at: offset + 4, width: 4))
                offset += 8
                try #require(offset + size <= bytes.count)
                if kind == 4 {
                    valueSections += 1
                    try #require(size % 16 == 0)
                    for position in stride(from: offset, to: offset + size, by: 16) {
                        rows.append((double(bytes, at: position, bigEndian: true), double(bytes, at: position + 8, bigEndian: true)))
                    }
                } else if kind == 15 {
                    endSections += 1
                    #expect(size == 0)
                    #expect(offset == bytes.count)
                }
                offset += size
            }
            #expect(valueSections == 1)
            #expect(endSections == 1)
            #expect(offset == bytes.count)
            return rows
        }
    }

    private func integer(_ bytes: Data, at offset: Int, width: Int) -> UInt64 {
        bytes[offset..<(offset + width)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private func double(_ bytes: Data, at offset: Int, bigEndian: Bool) -> Double {
        let bits = bigEndian
            ? integer(bytes, at: offset, width: 8)
            : bytes[offset..<(offset + 8)].reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(bitPattern: bits)
    }

    private func removeDirectory(_ directory: URL) {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove export regression directory: \(error)")
        }
    }
}
