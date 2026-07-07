import CoreSpiceWaveform
import Foundation

/// Reads waveform CSV files written by `CSVExporter` back into `WaveformData`.
///
/// The reader accepts exactly the dialect the exporter produces: one header
/// row (`sweep, var, var, ...` where each field is `name` or `name [unit]`,
/// optionally double-quoted), followed by numeric rows with one field per
/// column. Complex waveforms are recognized by adjacent `<name>_real` /
/// `<name>_imag` column pairs and are reassembled into complex storage.
///
/// The analysis kind is inferred from the sweep column name because the CSV
/// format does not record it: `time` maps to transient, `frequency`/`freq`
/// maps to AC, and any other sweep name maps to DC.
public struct CSVWaveformReader: Sendable {

    /// The field separator character.
    public var separator: Character

    public init(separator: Character = ",") {
        self.separator = separator
    }

    /// Reads a waveform CSV file from disk.
    public func read(contentsOfFile path: String) throws -> WaveformData {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        return try read(text)
    }

    /// Reads a waveform CSV from an in-memory string.
    public func read(_ text: String) throws -> WaveformData {
        let lines = numberedNonEmptyLines(text)
        guard let headerLine = lines.first else {
            throw CSVWaveformReadError.emptyInput
        }

        let headerFields = try splitFields(headerLine.content, lineNumber: headerLine.number)
        let columns = try parseHeader(headerFields)
        let sweepColumn = columns[0]
        let dataColumns = Array(columns.dropFirst())
        guard !dataColumns.isEmpty else {
            throw CSVWaveformReadError.noVariableColumns
        }

        let rows = try parseRows(lines.dropFirst(), columns: columns)
        guard !rows.isEmpty else {
            throw CSVWaveformReadError.noDataRows
        }

        let sweepVariable = sweepDescriptor(for: sweepColumn)
        let analysisType = inferredAnalysisKind(sweepName: sweepColumn.name)
        let sweepValues = rows.map { row in row[0] }

        if let complexPairs = try complexColumnPairs(dataColumns) {
            return makeComplexWaveform(
                pairs: complexPairs,
                sweepVariable: sweepVariable,
                sweepValues: sweepValues,
                rows: rows,
                analysisType: analysisType
            )
        }
        return makeRealWaveform(
            dataColumns: dataColumns,
            sweepVariable: sweepVariable,
            sweepValues: sweepValues,
            rows: rows,
            analysisType: analysisType
        )
    }

    // MARK: - Header

    private struct HeaderColumn {
        let name: String
        let declaredUnit: SIUnit?
    }

    private func parseHeader(_ fields: [String]) throws -> [HeaderColumn] {
        var columns: [HeaderColumn] = []
        columns.reserveCapacity(fields.count)
        var seenNames: Set<String> = []

        for (index, field) in fields.enumerated() {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                throw CSVWaveformReadError.emptyHeaderField(column: index + 1)
            }
            let column = try parseHeaderField(trimmed)
            let key = column.name.lowercased()
            guard seenNames.insert(key).inserted else {
                throw CSVWaveformReadError.duplicateColumn(name: column.name)
            }
            columns.append(column)
        }
        return columns
    }

    /// Parses one header field of the form `name` or `name [unit]`.
    private func parseHeaderField(_ field: String) throws -> HeaderColumn {
        guard field.hasSuffix("]"), let bracketStart = field.range(of: " [", options: .backwards) else {
            return HeaderColumn(name: field, declaredUnit: nil)
        }
        let name = String(field[..<bracketStart.lowerBound])
        let unitText = String(field[bracketStart.upperBound..<field.index(before: field.endIndex)])
        guard let unit = SIUnit(rawValue: unitText) else {
            throw CSVWaveformReadError.unknownUnit(column: name, unit: unitText)
        }
        return HeaderColumn(name: name, declaredUnit: unit)
    }

    // MARK: - Rows

    private func parseRows(
        _ lines: ArraySlice<(number: Int, content: Substring)>,
        columns: [HeaderColumn]
    ) throws -> [[Double]] {
        var rows: [[Double]] = []
        rows.reserveCapacity(lines.count)

        for line in lines {
            let fields = try splitFields(line.content, lineNumber: line.number)
            guard fields.count == columns.count else {
                throw CSVWaveformReadError.columnCountMismatch(
                    line: line.number,
                    expected: columns.count,
                    found: fields.count
                )
            }
            var row: [Double] = []
            row.reserveCapacity(fields.count)
            for (index, field) in fields.enumerated() {
                let trimmed = field.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, let value = Double(trimmed) else {
                    throw CSVWaveformReadError.invalidNumericValue(
                        line: line.number,
                        column: columns[index].name,
                        value: field
                    )
                }
                row.append(value)
            }
            rows.append(row)
        }
        return rows
    }

    // MARK: - Complex column pairing

    private struct ComplexPair {
        let baseName: String
        let declaredUnit: SIUnit?
        /// Zero-based data-column index of the `_real` column.
        let realIndex: Int
    }

    /// Detects the exporter's complex layout (`X_real, X_imag` adjacent
    /// pairs). Returns nil for a purely real layout; throws when the suffix
    /// naming is present but the pairing is broken.
    private func complexColumnPairs(_ dataColumns: [HeaderColumn]) throws -> [ComplexPair]? {
        let hasComplexSuffix = { (name: String) in
            name.hasSuffix("_real") || name.hasSuffix("_imag")
        }
        guard dataColumns.contains(where: { hasComplexSuffix($0.name) }) else {
            return nil
        }

        var pairs: [ComplexPair] = []
        var index = 0
        while index < dataColumns.count {
            let realColumn = dataColumns[index]
            guard realColumn.name.hasSuffix("_real") else {
                throw CSVWaveformReadError.unpairedComplexColumn(name: realColumn.name)
            }
            let baseName = String(realColumn.name.dropLast("_real".count))
            guard index + 1 < dataColumns.count,
                  dataColumns[index + 1].name == baseName + "_imag" else {
                throw CSVWaveformReadError.unpairedComplexColumn(name: realColumn.name)
            }
            pairs.append(ComplexPair(
                baseName: baseName,
                declaredUnit: realColumn.declaredUnit,
                realIndex: index
            ))
            index += 2
        }
        return pairs
    }

    // MARK: - Waveform assembly

    private func makeRealWaveform(
        dataColumns: [HeaderColumn],
        sweepVariable: VariableDescriptor,
        sweepValues: [Double],
        rows: [[Double]],
        analysisType: AnalysisKind
    ) -> WaveformData {
        let variables = dataColumns.enumerated().map { index, column in
            dataDescriptor(for: column, index: index)
        }
        let realData = rows.map { row in Array(row.dropFirst()) }
        let metadata = SimulationMetadata(
            analysisType: analysisType,
            pointCount: rows.count,
            variableCount: variables.count,
            isComplex: false
        )
        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: sweepValues,
            variables: variables,
            realData: realData
        )
    }

    private func makeComplexWaveform(
        pairs: [ComplexPair],
        sweepVariable: VariableDescriptor,
        sweepValues: [Double],
        rows: [[Double]],
        analysisType: AnalysisKind
    ) -> WaveformData {
        let variables = pairs.enumerated().map { index, pair in
            dataDescriptor(
                for: HeaderColumn(name: pair.baseName, declaredUnit: pair.declaredUnit),
                index: index
            )
        }
        let complexData = rows.map { row in
            pairs.map { pair in
                (real: row[pair.realIndex + 1], imag: row[pair.realIndex + 2])
            }
        }
        let metadata = SimulationMetadata(
            analysisType: analysisType,
            pointCount: rows.count,
            variableCount: variables.count,
            isComplex: true
        )
        return WaveformData(
            metadata: metadata,
            sweepVariable: sweepVariable,
            sweepValues: sweepValues,
            variables: variables,
            complexData: complexData
        )
    }

    // MARK: - Descriptor inference

    private func sweepDescriptor(for column: HeaderColumn) -> VariableDescriptor {
        let type: VariableType
        switch column.name.lowercased() {
        case "time":
            type = .time
        case "frequency", "freq":
            type = .frequency
        default:
            type = .parameter
        }
        return VariableDescriptor(
            name: column.name,
            unit: column.declaredUnit ?? type.defaultUnit,
            type: type,
            index: 0
        )
    }

    private func dataDescriptor(for column: HeaderColumn, index: Int) -> VariableDescriptor {
        let type: VariableType
        let lowered = column.name.lowercased()
        if lowered.hasPrefix("v(") {
            type = .voltage
        } else if lowered.hasPrefix("i(") {
            type = .current
        } else {
            type = .parameter
        }
        return VariableDescriptor(
            name: column.name,
            unit: column.declaredUnit ?? type.defaultUnit,
            type: type,
            index: index
        )
    }

    private func inferredAnalysisKind(sweepName: String) -> AnalysisKind {
        switch sweepName.lowercased() {
        case "time":
            return .transient
        case "frequency", "freq":
            return .ac
        default:
            return .dc
        }
    }

    // MARK: - Line and field splitting

    private func numberedNonEmptyLines(_ text: String) -> [(number: Int, content: Substring)] {
        var lines: [(number: Int, content: Substring)] = []
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            var line = rawLine
            if line.hasSuffix("\r") {
                line = line.dropLast()
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            lines.append((number: lineNumber, content: line))
        }
        return lines
    }

    /// Splits one CSV line into fields, honoring double-quoted fields (the
    /// exporter's `quoteFields` option) so quoted names may contain the
    /// separator. Surrounding quotes are stripped from the returned fields.
    private func splitFields(_ line: Substring, lineNumber: Int) throws -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false

        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character == separator && !inQuotes {
                fields.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        guard !inQuotes else {
            throw CSVWaveformReadError.unterminatedQuote(line: lineNumber)
        }
        fields.append(current)
        return fields
    }
}
