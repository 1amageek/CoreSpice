import Foundation

/// Errors raised while reading a waveform CSV file back into `WaveformData`.
///
/// The reader is strict: every violation of the CSV waveform dialect written
/// by `CSVExporter` is reported as a typed error instead of being coerced
/// into NaN values or silently skipped rows.
public enum CSVWaveformReadError: Error, Equatable, LocalizedError {

    /// The input contained no header line.
    case emptyInput

    /// A header line was present but a header field was empty.
    case emptyHeaderField(column: Int)

    /// A header field ended in an unterminated quoted section.
    case unterminatedQuote(line: Int)

    /// A header declared a unit suffix that is not a known `SIUnit` symbol.
    case unknownUnit(column: String, unit: String)

    /// Two columns resolved to the same variable name (case-insensitive).
    case duplicateColumn(name: String)

    /// The header declared only a sweep column and no data variables.
    case noVariableColumns

    /// A column used the complex `_real`/`_imag` naming but had no
    /// correctly ordered partner column.
    case unpairedComplexColumn(name: String)

    /// The file contained a header but no numeric data rows.
    case noDataRows

    /// A data row did not have exactly one field per header column.
    case columnCountMismatch(line: Int, expected: Int, found: Int)

    /// A data field could not be parsed as a floating-point number.
    case invalidNumericValue(line: Int, column: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "waveform CSV is empty; expected a header row and numeric data rows"
        case .emptyHeaderField(let column):
            return "waveform CSV header field \(column) is empty"
        case .unterminatedQuote(let line):
            return "waveform CSV line \(line) has an unterminated quoted field"
        case .unknownUnit(let column, let unit):
            return "waveform CSV column '\(column)' declares unknown unit '\(unit)'"
        case .duplicateColumn(let name):
            return "waveform CSV declares duplicate column '\(name)'"
        case .noVariableColumns:
            return "waveform CSV declares only a sweep column and no data variables"
        case .unpairedComplexColumn(let name):
            return "waveform CSV complex column '\(name)' has no adjacent _real/_imag partner"
        case .noDataRows:
            return "waveform CSV contains a header but no numeric data rows"
        case .columnCountMismatch(let line, let expected, let found):
            return "waveform CSV line \(line) has \(found) fields, expected \(expected)"
        case .invalidNumericValue(let line, let column, let value):
            return "waveform CSV line \(line), column '\(column)': '\(value)' is not a number"
        }
    }
}
