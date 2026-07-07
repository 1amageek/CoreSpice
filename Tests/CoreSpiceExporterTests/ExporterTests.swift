import Testing
import Foundation
@testable import CoreSpiceExporter
@testable import CoreSpiceExporterRAW
@testable import CoreSpiceExporterCSV
@testable import CoreSpiceExporterPSF
@testable import CoreSpiceWaveform

@Suite
struct RAWExporterTests {

    @Test
    func exportToMemory() async throws {
        let metadata = SimulationMetadata(
            title: "Test",
            analysisType: .transient,
            pointCount: 3,
            variableCount: 1
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1e-9, 2e-9],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0], [2.0], [3.0]]
        )

        let exporter = RAWExporter(useBinaryFormat: false)
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == 3)
        #expect(result.data != nil)

        if let data = result.data, let content = String(data: data, encoding: .utf8) {
            #expect(content.contains("Title: Test"))
            #expect(content.contains("Plotname: Transient Analysis"))
            #expect(content.contains("Variables:"))
            #expect(content.contains("time"))
            #expect(content.contains("V(out)"))
        }
    }

    @Test
    func exportRowMajorDataToMemory() async throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Row Major RAW",
                analysisType: .transient,
                pointCount: 2,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [
                .voltage(node: "out", index: 0),
                .current(device: "R1", index: 1)
            ],
            realRowMajorData: [
                1.0, 0.001,
                2.0, 0.002
            ],
            pointCount: 2,
            variableCount: 2
        )

        let exporter = RAWExporter(useBinaryFormat: false)
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == 2)

        guard let data = result.data, let content = String(data: data, encoding: .utf8) else {
            Issue.record("RAW export produced no data")
            return
        }

        #expect(content.contains("0\t0.000000000000000e+00\t1.000000000000000e+00\t1.000000000000000e-03"))
        #expect(content.contains("1\t1.000000000000000e+00\t2.000000000000000e+00\t2.000000000000000e-03"))
    }

    @Test
    func exportBinaryFormat() async throws {
        let metadata = SimulationMetadata(
            title: "Binary Test",
            analysisType: .transient,
            pointCount: 2,
            variableCount: 1
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1e-9],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0], [2.0]]
        )

        let exporter = RAWExporter(useBinaryFormat: true)
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.data != nil)

        if let data = result.data, let content = String(data: data, encoding: .utf8) {
            #expect(content.contains("Binary:"))
        }
    }

    @Test
    func exportComplexData() async throws {
        let metadata = SimulationMetadata(
            title: "AC Test",
            analysisType: .ac,
            pointCount: 2,
            variableCount: 1,
            isComplex: true
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .frequency(),
            sweepValues: [1e3, 1e4],
            variables: [.voltage(node: "out", index: 0)],
            complexData: [[(real: 1.0, imag: 0.5)], [(real: 0.5, imag: 0.25)]]
        )

        let exporter = RAWExporter(useBinaryFormat: false)
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        if let data = result.data, let content = String(data: data, encoding: .utf8) {
            #expect(content.contains("Flags: complex"))
        }
    }
}

@Suite
struct CSVExporterTests {

    @Test
    func exportToMemory() async throws {
        let metadata = SimulationMetadata(
            title: "CSV Test",
            analysisType: .transient,
            pointCount: 3,
            variableCount: 2
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1e-9, 2e-9],
            variables: [
                .voltage(node: "out", index: 0),
                .current(device: "R1", index: 1)
            ],
            realData: [[1.0, 0.001], [2.0, 0.002], [3.0, 0.003]]
        )

        let exporter = CSVExporter()
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == 3)
        #expect(result.variablesExported == 2)

        if let data = result.data, let content = String(data: data, encoding: .utf8) {
            let lines = content.split(separator: "\n")
            #expect(lines.count == 4) // header + 3 data rows

            // Check header
            #expect(lines[0].contains("time"))
            #expect(lines[0].contains("V(out)"))
            #expect(lines[0].contains("I(R1)"))
        }
    }

    @Test
    func exportRowMajorDataToMemory() async throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Row Major CSV",
                analysisType: .transient,
                pointCount: 2,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [
                .voltage(node: "out", index: 0),
                .current(device: "R1", index: 1)
            ],
            realRowMajorData: [
                1.0, 0.001,
                2.0, 0.002
            ],
            pointCount: 2,
            variableCount: 2
        )

        let exporter = CSVExporter()
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == 2)

        guard let data = result.data, let content = String(data: data, encoding: .utf8) else {
            Issue.record("CSV export produced no data")
            return
        }

        let lines = content.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1] == "0,1,0.001")
        #expect(lines[2] == "1,2,0.002")
    }

    @Test
    func exportWithCustomSeparator() async throws {
        let metadata = SimulationMetadata(
            analysisType: .transient,
            pointCount: 2,
            variableCount: 1
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0], [2.0]]
        )

        let exporter = CSVExporter(separator: "\t")
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        if let data = result.data, let content = String(data: data, encoding: .utf8) {
            #expect(content.contains("\t"))
        }
    }

    @Test
    func exportWithoutHeader() async throws {
        let metadata = SimulationMetadata(
            analysisType: .transient,
            pointCount: 2,
            variableCount: 1
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0], [2.0]]
        )

        let exporter = CSVExporter(includeHeader: false)
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        if let data = result.data, let content = String(data: data, encoding: .utf8) {
            let lines = content.split(separator: "\n")
            #expect(lines.count == 2) // No header, just 2 data rows
        }
    }
}

@Suite
struct ExporterRegistryTests {

    @Test
    func registerAndRetrieve() {
        let registry = ExporterRegistry()
        registry.register(RAWExporter())
        registry.register(CSVExporter())

        #expect(registry.exporter(for: "raw") != nil)
        #expect(registry.exporter(for: "csv") != nil)
        #expect(registry.exporter(for: "unknown") == nil)
    }

    @Test
    func retrieveByPath() {
        let registry = ExporterRegistry()
        registry.register(RAWExporter())
        registry.register(CSVExporter())

        #expect(registry.exporter(forPath: "output.raw")?.formatIdentifier == "raw")
        #expect(registry.exporter(forPath: "output.csv")?.formatIdentifier == "csv")
        #expect(registry.exporter(forPath: "output.xyz") == nil)
    }
}

@Suite
struct PSFExporterTests {

    @Test
    func exportToMemory() async throws {
        let metadata = SimulationMetadata(
            title: "PSF Test",
            analysisType: .transient,
            pointCount: 3,
            variableCount: 1
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1e-9, 2e-9],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0], [2.0], [3.0]]
        )

        let exporter = PSFExporter()
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == 3)
        #expect(result.data != nil)

        // Check for PSF magic number (big-endian 0x00000001)
        if let data = result.data {
            #expect(data.count > 4)
            #expect(data[0] == 0x00)
            #expect(data[1] == 0x00)
            #expect(data[2] == 0x00)
            #expect(data[3] == 0x01)
        }
    }

    @Test
    func exportRowMajorDataToMemory() async throws {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                title: "Row Major PSF",
                analysisType: .transient,
                pointCount: 2,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [
                .voltage(node: "out", index: 0),
                .current(device: "R1", index: 1)
            ],
            realRowMajorData: [
                1.0, 0.001,
                2.0, 0.002
            ],
            pointCount: 2,
            variableCount: 2
        )

        let exporter = PSFExporter()
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == 2)

        guard let data = result.data else {
            Issue.record("PSF export produced no data")
            return
        }

        #expect(data.count > 4)
        #expect(data[0] == 0x00)
        #expect(data[1] == 0x00)
        #expect(data[2] == 0x00)
        #expect(data[3] == 0x01)
    }

    @Test
    func exportComplexData() async throws {
        let metadata = SimulationMetadata(
            title: "PSF AC Test",
            analysisType: .ac,
            pointCount: 2,
            variableCount: 1,
            isComplex: true
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .frequency(),
            sweepValues: [1e3, 1e4],
            variables: [.voltage(node: "out", index: 0)],
            complexData: [[(real: 1.0, imag: 0.5)], [(real: 0.5, imag: 0.25)]]
        )

        let exporter = PSFExporter()
        let result = try await exporter.export(waveform, to: .memory, configuration: .default)

        #expect(result.success)
        #expect(result.pointsExported == 2)
    }

    @Test
    func formatIdentifier() {
        let exporter = PSFExporter()
        #expect(exporter.formatIdentifier == "psf")
        #expect(exporter.fileExtension == "psf")
        #expect(exporter.supportsStreaming)
    }
}

@Suite
struct PSFFormatTests {

    @Test
    func sectionHeaderRejectsUnknownSectionType() {
        do {
            _ = try PSFFormat.SectionHeader(type: 99, size: 0)
            Issue.record("Expected invalidSectionType")
        } catch let error as PSFFormat.ValidationError {
            #expect(error == .invalidSectionType(99))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func propertyRejectsMismatchedTypeAndValue() {
        do {
            _ = try PSFFormat.Property(
                id: PSFFormat.propTitle,
                type: PSFFormat.typeReal,
                value: .string("title")
            )
            Issue.record("Expected propertyTypeValueMismatch")
        } catch let error as PSFFormat.ValidationError {
            #expect(error == .propertyTypeValueMismatch(type: PSFFormat.typeReal, value: .string("title")))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func traceDefinitionRejectsInvalidDataType() {
        do {
            _ = try PSFFormat.TraceDefinition(name: "V(out)", dataType: PSFFormat.typeString)
            Issue.record("Expected invalidTraceDataType")
        } catch let error as PSFFormat.ValidationError {
            #expect(error == .invalidTraceDataType(PSFFormat.typeString))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func traceDefinitionRejectsInvalidElementCount() {
        do {
            _ = try PSFFormat.TraceDefinition(name: "V(out)", dataType: PSFFormat.typeReal, elementCount: 0)
            Issue.record("Expected invalidTraceElementCount")
        } catch let error as PSFFormat.ValidationError {
            #expect(error == .invalidTraceElementCount(0))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func traceDefinitionRejectsEmptyName() {
        do {
            _ = try PSFFormat.TraceDefinition(name: "", dataType: PSFFormat.typeReal)
            Issue.record("Expected emptyTraceName")
        } catch let error as PSFFormat.ValidationError {
            #expect(error == .emptyTraceName)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite
struct ExportConfigurationTests {

    @Test
    func defaultConfiguration() {
        let config = ExportConfiguration.default
        #expect(config.variableFilter == nil)
        #expect(config.sweepRange == nil)
        #expect(config.precision == 15)
        #expect(config.compression == .none)
    }

    @Test
    func filterByVariableName() {
        let metadata = SimulationMetadata(
            analysisType: .transient,
            pointCount: 2,
            variableCount: 3
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [
                .voltage(node: "in", index: 0),
                .voltage(node: "out", index: 1),
                .current(device: "R1", index: 2)
            ],
            realData: [[1.0, 2.0, 0.001], [1.5, 2.5, 0.002]]
        )

        var config = ExportConfiguration.default
        config.variableFilter = ["V(out)"]

        let filtered = config.applyFilters(to: waveform)

        #expect(filtered.variableCount == 1)
        #expect(filtered.variables.first?.name == "V(out)")
    }

    @Test
    func filterVariablesKeepsRowMajorStorage() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                analysisType: .transient,
                pointCount: 3,
                variableCount: 3
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0],
            variables: [
                .voltage(node: "in", index: 0),
                .voltage(node: "out", index: 1),
                .current(device: "R1", index: 2)
            ],
            realRowMajorData: [
                1.0, 2.0, 0.1,
                4.0, 5.0, 0.2,
                7.0, 8.0, 0.3
            ],
            pointCount: 3,
            variableCount: 3
        )

        var config = ExportConfiguration.default
        config.variableFilter = ["V(out)", "I(R1)"]

        let filtered = config.applyFilters(to: waveform)

        #expect(filtered.variableCount == 2)
        var projectedValues: [Double] = []
        let completed = filtered.forEachRealValue(at: 1) { value in
            projectedValues.append(value)
        }
        #expect(completed)
        #expect(projectedValues == [5.0, 0.2])

        let borrowsBaseStorage = waveform.withRealValues(at: 1) { basePoint in
            filtered.withRealValues(at: 1) { filteredPoint in
                #expect(Array(filteredPoint) == [5.0, 0.2])
                return filteredPoint.baseAddress == basePoint.baseAddress.map { $0 + 1 }
            } ?? false
        } ?? false
        #expect(borrowsBaseStorage)
    }

    @Test
    func filterByWildcard() {
        let metadata = SimulationMetadata(
            analysisType: .transient,
            pointCount: 2,
            variableCount: 3
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [
                .voltage(node: "in", index: 0),
                .voltage(node: "out", index: 1),
                .current(device: "R1", index: 2)
            ],
            realData: [[1.0, 2.0, 0.001], [1.5, 2.5, 0.002]]
        )

        var config = ExportConfiguration.default
        config.variableFilter = ["V(*)"]

        let filtered = config.applyFilters(to: waveform)

        #expect(filtered.variableCount == 2)
        #expect(filtered.variables.allSatisfy { $0.name.hasPrefix("V(") })
    }

    @Test
    func unmatchedVariableFilterReturnsEmptyProjection() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                analysisType: .transient,
                pointCount: 2,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [
                .voltage(node: "in", index: 0),
                .voltage(node: "out", index: 1)
            ],
            realRowMajorData: [
                1.0, 2.0,
                3.0, 4.0
            ],
            pointCount: 2,
            variableCount: 2
        )

        var config = ExportConfiguration.default
        config.variableFilter = ["I(missing)"]

        let filtered = config.applyFilters(to: waveform)

        #expect(filtered.pointCount == 2)
        #expect(filtered.variableCount == 0)
        var values: [Double] = []
        let completed = filtered.forEachRealValue(at: 0) { value in
            values.append(value)
        }
        #expect(completed)
        #expect(values.isEmpty)
    }

    @Test
    func filterBySweepRange() {
        let metadata = SimulationMetadata(
            analysisType: .transient,
            pointCount: 5,
            variableCount: 1
        )

        let waveform = WaveformData(
            metadata: metadata,
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0, 3.0, 4.0],
            variables: [.voltage(node: "out", index: 0)],
            realData: [[1.0], [2.0], [3.0], [4.0], [5.0]]
        )

        var config = ExportConfiguration.default
        config.sweepRange = 1.0...3.0

        let filtered = config.applyFilters(to: waveform)

        #expect(filtered.pointCount == 3)
        let sweepValues = (0..<filtered.pointCount).compactMap { filtered.sweepValue(at: $0) }
        #expect(sweepValues == [1.0, 2.0, 3.0])
    }

    @Test
    func filterSweepRangeKeepsRowMajorStorage() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                analysisType: .transient,
                pointCount: 3,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0],
            variables: [
                .voltage(node: "out", index: 0),
                .current(device: "R1", index: 1)
            ],
            realRowMajorData: [
                1.0, 0.1,
                2.0, 0.2,
                3.0, 0.3
            ],
            pointCount: 3,
            variableCount: 2
        )

        var config = ExportConfiguration.default
        config.sweepRange = 1.0...2.0

        let filtered = config.applyFilters(to: waveform)

        #expect(filtered.pointCount == 2)
        let sweepValues = (0..<filtered.pointCount).compactMap { filtered.sweepValue(at: $0) }
        #expect(sweepValues == [1.0, 2.0])

        var projectedValues: [Double] = []
        let completed = filtered.forEachRealValue(at: 1) { value in
            projectedValues.append(value)
        }
        #expect(completed)
        #expect(projectedValues == [3.0, 0.3])

        let borrowsBaseStorage = waveform.withRealValues(at: 2) { basePoint in
            filtered.withRealValues(at: 1) { filteredPoint in
                #expect(Array(filteredPoint) == [3.0, 0.3])
                return filteredPoint.baseAddress == basePoint.baseAddress
            } ?? false
        } ?? false
        #expect(borrowsBaseStorage)
    }

    @Test
    func unmatchedSweepRangeReturnsEmptyProjection() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                analysisType: .transient,
                pointCount: 2,
                variableCount: 1
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0],
            variables: [.voltage(node: "out", index: 0)],
            realRowMajorData: [1.0, 2.0],
            pointCount: 2,
            variableCount: 1
        )

        var config = ExportConfiguration.default
        config.sweepRange = 2.0...3.0

        let filtered = config.applyFilters(to: waveform)

        #expect(filtered.pointCount == 0)
        #expect(filtered.variableCount == 1)
    }

    @Test
    func filtersCanComposeOnLazyViews() {
        let waveform = WaveformData(
            metadata: SimulationMetadata(
                analysisType: .transient,
                pointCount: 3,
                variableCount: 2
            ),
            sweepVariable: .time(),
            sweepValues: [0.0, 1.0, 2.0],
            variables: [
                .voltage(node: "in", index: 0),
                .voltage(node: "out", index: 1)
            ],
            realRowMajorData: [
                1.0, 2.0,
                3.0, 4.0,
                5.0, 6.0
            ],
            pointCount: 3,
            variableCount: 2
        )

        var variableConfig = ExportConfiguration.default
        variableConfig.variableFilter = ["V(out)"]
        let variableView = variableConfig.applyFilters(to: waveform)

        var rangeConfig = ExportConfiguration.default
        rangeConfig.sweepRange = 1.0...2.0
        let composedView = rangeConfig.applyFilters(to: variableView)

        #expect(composedView.pointCount == 2)
        #expect(composedView.variableCount == 1)
        #expect(composedView.sweepValue(at: 0) == 1.0)
        #expect(composedView.realValue(variable: 0, point: 0) == 4.0)
        #expect(composedView.realValue(variable: 0, point: 1) == 6.0)
    }

    @Test
    func formatValuePrecision() {
        var config = ExportConfiguration.default
        config.precision = 3

        let formatted = config.formatValue(3.14159265)
        #expect(formatted.count <= 7) // "3.14" or similar
    }

    @Test
    func compressionOption() {
        #expect(CompressionOption.none.fileExtension == nil)
        #expect(CompressionOption.gzip.fileExtension == "gz")
        #expect(CompressionOption.bzip2.fileExtension == "bz2")
        #expect(CompressionOption.zstd.fileExtension == "zst")
    }

    @Test
    func compressionRoundTrip() throws {
        let original = Data("Test data for compression".utf8)

        // Test gzip
        let gzipCompressed = try CompressionOption.gzip.compress(original)
        let gzipDecompressed = try CompressionOption.gzip.decompress(gzipCompressed)
        #expect(gzipDecompressed == original)

        // Test none
        let noneCompressed = try CompressionOption.none.compress(original)
        #expect(noneCompressed == original)
    }
}
