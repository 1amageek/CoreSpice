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
@_exported import CoreSpiceDevices
@_exported import CoreSpiceAnalysis
@_exported import CoreSpiceParsedIR
@_exported import CoreSpiceWaveform
@_exported import CoreSpiceParser
@_exported import CoreSpiceParserSPICE
@_exported import CoreSpiceLowering
@_exported import CoreSpiceMOSContracts
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

    /// Parses a SPICE netlist string with explicit parser configuration and file resolution.
    ///
    /// - Parameters:
    ///   - source: The netlist source text.
    ///   - fileName: Optional file name for diagnostics and relative include resolution.
    ///   - configuration: Parser configuration options.
    ///   - fileResolver: Resolver used for `.include` and `.lib`.
    /// - Returns: The parse result.
    public static func parse(
        _ source: String,
        fileName: String? = nil,
        configuration: ParserConfiguration,
        fileResolver: any FileResolver
    ) async -> ParseResult {
        let parser = SPICEParser()
        return await parser.parse(
            source: source,
            fileName: fileName,
            configuration: configuration,
            fileResolver: fileResolver
        )
    }

    /// Parses and resolves a SPICE netlist under explicit caller evaluation policy.
    public static func parseAndLower(
        _ source: String,
        profile: MOSInputProfile,
        seed: UInt64,
        limits: MOSResolutionLimits,
        control: (any MOSResolutionControlling)? = nil
    ) async throws -> LoweredCircuit {
        let result = await parse(source)
        return try lower(result.get(), profile: profile, seed: seed, limits: limits, control: control)
    }

    /// Returns the resolved circuit together with its exact inspection and evaluation owners.
    public static func lower(
        _ netlist: ParsedNetlist,
        profile: MOSInputProfile,
        seed: UInt64,
        limits: MOSResolutionLimits,
        control: (any MOSResolutionControlling)? = nil
    ) throws -> LoweredCircuit {
        let compiled = try NetlistLowering.compile(netlist, limits: limits, control: control)
        var session = try NetlistLowering.beginEvaluation(compiled, profile: profile, limits: limits,
                                                         seed: seed, control: control)
        let options = try SPICEAnalysisOptions.resolve(from: compiled, session: &session)
        try session.lower(geometryScale: options.geometryScale)
        return try session.finish()
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
