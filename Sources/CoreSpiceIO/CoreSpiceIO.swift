/// CoreSpiceIO - Unified SPICE I/O Architecture
///
/// This umbrella module re-exports all I/O-related modules for CoreSpice:
///
/// - **CoreSpiceParsedIR**: Parsed netlist intermediate representation (AST types)
/// - **CoreSpiceWaveform**: Waveform data intermediate representation
/// - **CoreSpiceParser**: Parser protocols and registry
/// - **CoreSpiceParserSPICE**: SPICE netlist parser implementation
/// - **CoreSpiceLowering**: ParsedNetlist → CircuitIR conversion
/// - **CoreSpiceExporter**: Exporter protocols and registry
/// - **CoreSpiceExporterRAW**: RAW format exporter (ngspice compatible)
/// - **CoreSpiceExporterCSV**: CSV format exporter
/// - **CoreSpiceExporterPSF**: PSF format exporter (Cadence compatible)

// Re-export all I/O modules
@_exported import CoreSpiceIR
@_exported import CoreSpiceParsedIR
@_exported import CoreSpiceWaveform
@_exported import CoreSpiceParser
@_exported import CoreSpiceParserSPICE
@_exported import CoreSpiceLowering
@_exported import CoreSpiceExporter
@_exported import CoreSpiceExporterRAW
@_exported import CoreSpiceExporterCSV
@_exported import CoreSpiceExporterPSF

/// Convenience namespace for CoreSpice I/O operations.
public enum SPICEIO {

    /// Creates a default parser registry with all built-in parsers.
    public static func defaultParserRegistry() -> ParserRegistry {
        let registry = ParserRegistry()
        registry.register(SPICEParser())
        return registry
    }

    /// Creates a default exporter registry with all built-in exporters.
    public static func defaultExporterRegistry() -> ExporterRegistry {
        let registry = ExporterRegistry()
        registry.register(RAWExporter())
        registry.register(CSVExporter())
        registry.register(PSFExporter())
        return registry
    }

    /// Parses a SPICE netlist string.
    ///
    /// - Parameters:
    ///   - source: The netlist source text.
    ///   - fileName: Optional file name for diagnostics.
    /// - Returns: The parse result.
    public static func parse(
        _ source: String,
        fileName: String? = nil
    ) async -> ParseResult {
        let parser = SPICEParser()
        return await parser.parse(source: source, fileName: fileName)
    }

    /// Parses and lowers a SPICE netlist to CircuitIR.
    ///
    /// - Parameters:
    ///   - source: The netlist source text.
    ///   - configuration: Lowering configuration.
    /// - Returns: The circuit IR.
    public static func parseAndLower(
        _ source: String,
        configuration: NetlistLowering.Configuration = .default
    ) async throws -> CircuitIR {
        let result = await parse(source)
        let netlist = try result.get()
        let lowering = NetlistLowering(configuration: configuration)
        return try lowering.lower(netlist)
    }

    /// Lowers a parsed SPICE netlist to CircuitIR with the given configuration.
    public static func lower(
        _ netlist: ParsedNetlist,
        configuration: NetlistLowering.Configuration = .default
    ) throws -> CircuitIR {
        let lowering = NetlistLowering(configuration: configuration)
        return try lowering.lower(netlist)
    }

    /// Exports waveform data to RAW format.
    ///
    /// - Parameters:
    ///   - data: The waveform data to export.
    ///   - path: The output file path.
    /// - Returns: The export result.
    public static func exportToRAW(
        _ data: WaveformData,
        path: String
    ) async throws -> ExportResult {
        let exporter = RAWExporter()
        return try await exporter.export(data, toPath: path)
    }

    /// Exports waveform data to CSV format.
    ///
    /// - Parameters:
    ///   - data: The waveform data to export.
    ///   - path: The output file path.
    /// - Returns: The export result.
    public static func exportToCSV(
        _ data: WaveformData,
        path: String
    ) async throws -> ExportResult {
        let exporter = CSVExporter()
        return try await exporter.export(data, toPath: path)
    }

    /// Exports waveform data to PSF format (Cadence compatible).
    ///
    /// - Parameters:
    ///   - data: The waveform data to export.
    ///   - path: The output file path.
    /// - Returns: The export result.
    public static func exportToPSF(
        _ data: WaveformData,
        path: String
    ) async throws -> ExportResult {
        let exporter = PSFExporter()
        return try await exporter.export(data, toPath: path)
    }
}
