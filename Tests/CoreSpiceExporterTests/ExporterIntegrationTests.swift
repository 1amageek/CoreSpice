import Testing
import Foundation
@testable import CoreSpiceExporter
@testable import CoreSpiceExporterRAW
@testable import CoreSpiceExporterCSV
@testable import CoreSpiceExporterPSF
@testable import CoreSpiceWaveform

@Suite("Exporter Integration Tests")
struct ExporterIntegrationTests {

    // MARK: - K3: AC Data CSV Export

    @Test("K3: AC complex data CSV export contains real and imaginary columns")
    func acDataCSVExport() async throws {
        // Build an AC-like complex waveform with known values
        // Simulate RC lowpass filter AC response: H(f) = 1 / (1 + j*f/fc)
        // fc = 1/(2π×1kΩ×1µF) ≈ 159.15 Hz
        let fc = 1.0 / (2.0 * Double.pi * 1000.0 * 1e-6)
        let frequencies = [1.0, 10.0, 100.0, 1000.0, 10000.0, 100000.0]

        var complexData: [[(real: Double, imag: Double)]] = []
        for f in frequencies {
            let ratio = f / fc
            let denom = 1.0 + ratio * ratio
            let real = 1.0 / denom
            let imag = -ratio / denom
            complexData.append([(real: real, imag: imag)])
        }

        let metadata = SimulationMetadata(
            title: "RC LPF AC",
            analysisType: .ac,
            pointCount: frequencies.count,
            variableCount: 1,
            isComplex: true
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .frequency(),
            sweepValues: frequencies,
            variables: [.voltage(node: "out", index: 0)],
            complexData: complexData
        )

        // Export to CSV
        let exporter = CSVExporter()
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == frequencies.count)

        guard let data = result.data, let content = String(data: data, encoding: .utf8) else {
            Issue.record("CSV export produced no data")
            return
        }

        let lines = content.split(separator: "\n")

        // Header + 6 data rows
        #expect(lines.count == 7,
                "Should have header + 6 data rows, got \(lines.count)")

        // Header should contain frequency, real, and imag columns
        let header = String(lines[0])
        #expect(header.contains("frequency"), "Header should contain 'frequency', got: \(header)")
        #expect(header.contains("V(out)_real"), "Header should contain 'V(out)_real', got: \(header)")
        #expect(header.contains("V(out)_imag"), "Header should contain 'V(out)_imag', got: \(header)")

        // Verify data row count matches
        let dataLines = Array(lines.dropFirst())
        #expect(dataLines.count == frequencies.count)

        // Parse first data row (f=1Hz ≈ DC: real≈1.0, imag≈0.0)
        let firstFields = dataLines[0].split(separator: ",")
        #expect(firstFields.count == 3, "Each row should have 3 fields (freq, real, imag)")

        // At f=1Hz (<<fc), real part should be ≈ 1.0
        if let realVal = Double(firstFields[1].trimmingCharacters(in: .whitespaces)) {
            #expect(realVal > 0.99, "At f<<fc, real part should be ~1.0, got \(realVal)")
        }

        // Parse last data row (f=100kHz >> fc: real≈0, imag≈0)
        let lastFields = dataLines[5].split(separator: ",")
        if let realVal = Double(lastFields[1].trimmingCharacters(in: .whitespaces)),
           let imagVal = Double(lastFields[2].trimmingCharacters(in: .whitespaces)) {
            #expect(abs(realVal) < 0.01, "At f>>fc, real should be ~0, got \(realVal)")
            #expect(abs(imagVal) < 0.01, "At f>>fc, imag should be ~0, got \(imagVal)")
        }

        // Also export to RAW and verify complex flag
        let rawExporter = RAWExporter(useBinaryFormat: false)
        let rawResult = try await rawExporter.export(waveform, to: .memory, configuration: .default)
        #expect(rawResult.success)

        if let rawData = rawResult.data, let rawContent = String(data: rawData, encoding: .utf8) {
            #expect(rawContent.contains("Flags: complex"),
                    "RAW export should indicate complex data")
            #expect(rawContent.contains("AC Analysis"),
                    "RAW plotname should be 'AC Analysis'")
        }
    }

    // MARK: - K7: RAW ASCII Export Round-Trip Verification

    @Test("K7: RAW ASCII export round-trip data integrity")
    func rawASCIIRoundTrip() async throws {
        // Create a known dataset with multiple variables and points
        let sweepValues = [0.0, 1.0, 2.0, 3.0, 4.0]
        let variables: [VariableDescriptor] = [
            .voltage(node: "in", index: 0),
            .voltage(node: "out", index: 1),
            .current(device: "R1", index: 2),
        ]
        let realData: [[Double]] = [
            [5.0, 2.5, 0.0025],
            [4.0, 2.0, 0.002],
            [3.0, 1.5, 0.0015],
            [2.0, 1.0, 0.001],
            [1.0, 0.5, 0.0005],
        ]

        let metadata = SimulationMetadata(
            title: "Round-Trip Test",
            analysisType: .dc,
            pointCount: sweepValues.count,
            variableCount: variables.count
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: VariableDescriptor(
                name: "V1", unit: .volt, type: .sweepVoltage, index: 0
            ),
            sweepValues: sweepValues,
            variables: variables,
            realData: realData
        )

        // Export to ASCII RAW
        let exporter = RAWExporter(useBinaryFormat: false)
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == 5)
        #expect(result.variablesExported == 3)

        guard let data = result.data, let content = String(data: data, encoding: .utf8) else {
            Issue.record("RAW export produced no data")
            return
        }

        // Parse header
        let lines = content.components(separatedBy: "\n")

        // Verify header fields
        #expect(lines.contains(where: { $0.hasPrefix("Title: Round-Trip Test") }),
                "Should contain title")
        #expect(lines.contains(where: { $0.hasPrefix("Plotname: DC transfer") }),
                "Should contain DC plotname")
        #expect(lines.contains(where: { $0.hasPrefix("Flags: real") }),
                "Should have real flag")
        #expect(lines.contains(where: { $0.hasPrefix("No. Variables: 4") }),
                "Should have 4 variables (sweep + 3 data)")
        #expect(lines.contains(where: { $0.hasPrefix("No. Points: 5") }),
                "Should have 5 points")

        // Find Variables section
        guard let varStart = lines.firstIndex(where: { $0 == "Variables:" }) else {
            Issue.record("Missing Variables: section")
            return
        }
        // Variable 0 should be sweep
        #expect(lines[varStart + 1].contains("V1"), "First variable should be sweep V1")
        // Variable 1 should be V(in)
        #expect(lines[varStart + 2].contains("V(in)"), "Second variable should be V(in)")
        // Variable 2 should be V(out)
        #expect(lines[varStart + 3].contains("V(out)"), "Third variable should be V(out)")
        // Variable 3 should be I(R1)
        #expect(lines[varStart + 4].contains("I(R1)"), "Fourth variable should be I(R1)")

        // Find Values section and parse data
        guard let valStart = lines.firstIndex(where: { $0 == "Values:" }) else {
            Issue.record("Missing Values: section")
            return
        }

        // Parse data lines (format: "index\tsweep\tval1\tval2\t...")
        var parsedSweep: [Double] = []
        var parsedData: [[Double]] = []

        for i in (valStart + 1)..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let fields = line.split(separator: "\t")
            if fields.count < 4 { continue } // index + sweep + 3 vars

            if let sweep = Double(fields[1]) {
                parsedSweep.append(sweep)
            }
            var row: [Double] = []
            for j in 2..<fields.count {
                if let val = Double(fields[j]) {
                    row.append(val)
                }
            }
            parsedData.append(row)
        }

        // Verify parsed data matches original
        #expect(parsedSweep.count == sweepValues.count,
                "Should parse \(sweepValues.count) sweep values, got \(parsedSweep.count)")

        for (i, originalSweep) in sweepValues.enumerated() {
            guard i < parsedSweep.count else { break }
            #expect(abs(parsedSweep[i] - originalSweep) < 1e-10,
                    "Sweep[\(i)]: expected \(originalSweep), got \(parsedSweep[i])")
        }

        for (i, originalRow) in realData.enumerated() {
            guard i < parsedData.count else { break }
            for (j, originalVal) in originalRow.enumerated() {
                guard j < parsedData[i].count else { break }
                let relError: Double
                if abs(originalVal) > 1e-15 {
                    relError = abs(parsedData[i][j] - originalVal) / abs(originalVal)
                } else {
                    relError = abs(parsedData[i][j] - originalVal)
                }
                #expect(relError < 1e-10,
                        "Data[\(i)][\(j)]: expected \(originalVal), got \(parsedData[i][j])")
            }
        }

        // Also verify binary export produces data
        let binaryExporter = RAWExporter(useBinaryFormat: true)
        let binaryResult = try await binaryExporter.export(waveform, to: .memory, configuration: .default)
        #expect(binaryResult.success)
        #expect(binaryResult.data != nil)

        // Binary format should be more compact than ASCII
        if let asciiSize = result.data?.count, let binarySize = binaryResult.data?.count {
            #expect(binarySize < asciiSize,
                    "Binary (\(binarySize) bytes) should be smaller than ASCII (\(asciiSize) bytes)")
        }
    }

    // MARK: - K8: Large-Scale Data Export

    @Test("K8: Large-scale data export (10000 points × 10 variables)")
    func largeScaleDataExport() async throws {
        let pointCount = 10000
        let variableCount = 10

        // Generate sweep values (time: 0 to 1ms)
        let dt = 1e-3 / Double(pointCount - 1)
        var sweepValues: [Double] = []
        sweepValues.reserveCapacity(pointCount)
        for i in 0..<pointCount {
            sweepValues.append(Double(i) * dt)
        }

        // Generate variable descriptors
        var variables: [VariableDescriptor] = []
        for i in 0..<variableCount {
            variables.append(.voltage(node: "n\(i)", index: i))
        }

        // Generate data: each variable is a sinusoid at different frequency
        var realData: [[Double]] = []
        realData.reserveCapacity(pointCount)
        for i in 0..<pointCount {
            let t = sweepValues[i]
            var row: [Double] = []
            row.reserveCapacity(variableCount)
            for j in 0..<variableCount {
                let freq = Double(j + 1) * 1000.0 // 1kHz, 2kHz, ..., 10kHz
                row.append(sin(2.0 * Double.pi * freq * t))
            }
            realData.append(row)
        }

        let metadata = SimulationMetadata(
            title: "Large Scale Test",
            analysisType: .transient,
            pointCount: pointCount,
            variableCount: variableCount
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: sweepValues,
            variables: variables,
            realData: realData
        )

        // Test CSV export
        let csvExporter = CSVExporter()
        let csvResult = try await csvExporter.export(waveform, to: .memory, configuration: .default)

        #expect(csvResult.success)
        #expect(csvResult.pointsExported == pointCount)
        #expect(csvResult.variablesExported == variableCount)
        #expect(csvResult.bytesWritten > 0)

        // Verify CSV data integrity by parsing
        if let csvData = csvResult.data, let csvContent = String(data: csvData, encoding: .utf8) {
            let csvLines = csvContent.split(separator: "\n")
            // Header + 10000 data rows
            #expect(csvLines.count == pointCount + 1,
                    "CSV should have \(pointCount + 1) lines, got \(csvLines.count)")

            // Verify header has all variable names
            let header = String(csvLines[0])
            #expect(header.contains("time"), "Header should contain 'time'")
            for i in 0..<variableCount {
                #expect(header.contains("V(n\(i))"),
                        "Header should contain V(n\(i))")
            }

            // Spot-check a few data rows
            // Row 0 (t=0): all sinusoids should be 0
            let firstRow = csvLines[1].split(separator: ",")
            #expect(firstRow.count == variableCount + 1, // sweep + vars
                    "Each row should have \(variableCount + 1) fields")

            // Check first value (t=0, sin(0)=0)
            if let val = Double(firstRow[1].trimmingCharacters(in: .whitespaces)) {
                #expect(abs(val) < 1e-10, "sin(0) should be ~0, got \(val)")
            }
        }

        // Test RAW ASCII export
        let rawASCIIExporter = RAWExporter(useBinaryFormat: false)
        let rawASCIIResult = try await rawASCIIExporter.export(waveform, to: .memory, configuration: .default)

        #expect(rawASCIIResult.success)
        #expect(rawASCIIResult.pointsExported == pointCount)

        // Test RAW Binary export
        let rawBinaryExporter = RAWExporter(useBinaryFormat: true)
        let rawBinaryResult = try await rawBinaryExporter.export(waveform, to: .memory, configuration: .default)

        #expect(rawBinaryResult.success)
        #expect(rawBinaryResult.pointsExported == pointCount)

        // Binary should be significantly smaller than ASCII
        if let asciiSize = rawASCIIResult.data?.count,
           let binarySize = rawBinaryResult.data?.count {
            #expect(binarySize < asciiSize,
                    "Binary (\(binarySize)) should be smaller than ASCII (\(asciiSize))")
        }

        // Test PSF export
        let psfExporter = PSFExporter()
        let psfResult = try await psfExporter.export(waveform, to: .memory, configuration: .default)

        #expect(psfResult.success)
        #expect(psfResult.pointsExported == pointCount)

        // Test direct export with a lazy variable filter.
        var filterConfig = ExportConfiguration.default
        filterConfig.variableFilter = ["V(n0)", "V(n9)"]
        let directFilteredResult = try await csvExporter.export(
            waveform,
            to: .memory,
            configuration: filterConfig
        )

        #expect(directFilteredResult.success)
        #expect(directFilteredResult.variablesExported == 2,
                "Direct filtered export should have 2 variables, got \(directFilteredResult.variablesExported)")

        // Test export of a prebuilt lazy view.
        let filteredWaveform = filterConfig.applyFilters(to: waveform)

        #expect(filteredWaveform.variableCount == 2,
                "Filtered waveform should have 2 variables, got \(filteredWaveform.variableCount)")

        let filteredResult = try await csvExporter.export(filteredWaveform, to: .memory, configuration: .default)
        #expect(filteredResult.success)
        #expect(filteredResult.variablesExported == 2,
                "Filtered export should have 2 variables, got \(filteredResult.variablesExported)")

        // Verify filtered CSV has correct headers
        if let fData = filteredResult.data, let fContent = String(data: fData, encoding: .utf8) {
            let fHeader = String(fContent.split(separator: "\n")[0])
            #expect(fHeader.contains("V(n0)"), "Filtered header should contain V(n0)")
            #expect(fHeader.contains("V(n9)"), "Filtered header should contain V(n9)")
            #expect(!fHeader.contains("V(n1)"), "Filtered header should not contain V(n1)")
        }

        // Test direct export with a lazy sweep range filter.
        var rangeConfig = ExportConfiguration.default
        rangeConfig.sweepRange = 0.0...1e-4 // First 10% of time

        let rangeResult = try await csvExporter.export(waveform, to: .memory, configuration: rangeConfig)
        #expect(rangeResult.success)
        // Should have approximately 1001 points (10% of 10000, inclusive of endpoints)
        #expect(rangeResult.pointsExported > 900 && rangeResult.pointsExported < 1100,
                "Range-filtered export should have ~1000 points, got \(rangeResult.pointsExported)")
    }
}
