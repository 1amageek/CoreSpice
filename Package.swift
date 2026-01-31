// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoreSpice",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoreSpice", targets: ["CoreSpice"]),
        .library(name: "CoreSpiceIO", targets: ["CoreSpiceIO"]),
        .library(name: "PluginsPhotonic", targets: ["PluginsPhotonic"]),
        .executable(name: "corespice", targets: ["CoreSpiceCLI"]),
    ],
    targets: [
        // --- C module: Metal互換型 ---
        .target(name: "SharedTypes", path: "Sources/SharedTypes", publicHeadersPath: "include"),

        // --- Event/Observer/Cancel（依存なし）---
        .target(name: "CoreSpiceEvent"),

        // --- IR ---
        .target(name: "CoreSpiceIR", dependencies: ["CoreSpiceEvent"]),

        // --- Devices ---
        .target(name: "CoreSpiceDevices", dependencies: ["CoreSpiceIR", "CoreSpiceEvent"]),

        // --- Compile ---
        .target(name: "CoreSpiceCompile", dependencies: ["CoreSpiceIR"]),

        // --- Backend ---
        .target(name: "CoreSpiceBackend", dependencies: ["CoreSpiceEvent", "SharedTypes"],
                resources: [.process("Shaders")]),

        // --- Analysis ---
        .target(name: "CoreSpiceAnalysis",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceBackend", "CoreSpiceEvent"]),

        // --- Photonic Plugin ---
        // Note: Photonic shaders are provided by CoreSpiceBackend
        .target(name: "PluginsPhotonic",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceBackend", "CoreSpiceEvent", "SharedTypes"]),

        // --- Optoelectronic Device Models ---
        .target(name: "CoreSpiceOptoelectronics",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceEvent"]),

        // --- Umbrella ---
        .target(name: "CoreSpice",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceAnalysis", "CoreSpiceBackend", "CoreSpiceEvent",
                               "CoreSpiceOptoelectronics"]),

        // ==========================================================================
        // I/O Architecture Modules
        // ==========================================================================

        // --- ParsedIR: AST types for parsed netlists ---
        .target(name: "CoreSpiceParsedIR"),

        // --- Waveform: Waveform data IR and conversion ---
        .target(name: "CoreSpiceWaveform",
                dependencies: ["CoreSpiceIR", "CoreSpiceAnalysis", "CoreSpiceCompile"]),

        // --- Parser: Parser protocols and registry ---
        .target(name: "CoreSpiceParser",
                dependencies: ["CoreSpiceParsedIR"]),

        // --- ParserSPICE: SPICE netlist parser ---
        .target(name: "CoreSpiceParserSPICE",
                dependencies: ["CoreSpiceParsedIR", "CoreSpiceParser"]),

        // --- Lowering: ParsedNetlist → CircuitIR conversion ---
        .target(name: "CoreSpiceLowering",
                dependencies: ["CoreSpiceParsedIR", "CoreSpiceIR"]),

        // --- Exporter: Exporter protocols and registry ---
        .target(name: "CoreSpiceExporter",
                dependencies: ["CoreSpiceWaveform"]),

        // --- ExporterRAW: RAW format exporter ---
        .target(name: "CoreSpiceExporterRAW",
                dependencies: ["CoreSpiceWaveform", "CoreSpiceExporter"]),

        // --- ExporterCSV: CSV format exporter ---
        .target(name: "CoreSpiceExporterCSV",
                dependencies: ["CoreSpiceWaveform", "CoreSpiceExporter"]),

        // --- ExporterPSF: PSF format exporter (Cadence) ---
        .target(name: "CoreSpiceExporterPSF",
                dependencies: ["CoreSpiceWaveform", "CoreSpiceExporter"]),

        // --- I/O Umbrella: Re-exports all I/O modules ---
        .target(name: "CoreSpiceIO",
                dependencies: ["CoreSpiceIR", "CoreSpiceParsedIR", "CoreSpiceWaveform",
                               "CoreSpiceParser", "CoreSpiceParserSPICE",
                               "CoreSpiceLowering", "CoreSpiceExporter",
                               "CoreSpiceExporterRAW", "CoreSpiceExporterCSV",
                               "CoreSpiceExporterPSF"]),

        // CLI executable
        .executableTarget(
            name: "CoreSpiceCLI",
            dependencies: [
                "CoreSpice",
                "CoreSpiceIO",
                "CoreSpiceAnalysis",
                "CoreSpiceDevices",
                "CoreSpiceCompile",
                "CoreSpiceExporter",
                "CoreSpiceExporterRAW",
                "CoreSpiceExporterCSV",
                "CoreSpiceExporterPSF",
                "CoreSpiceBackend"
            ],
            path: "Sources/CoreSpiceCLI"
        ),

        // ==========================================================================
        // Tests
        // ==========================================================================

        .testTarget(name: "CoreSpiceIRTests", dependencies: ["CoreSpiceIR"]),
        .testTarget(name: "CoreSpiceDevicesTests", dependencies: ["CoreSpiceDevices"]),
        .testTarget(name: "CoreSpiceCompileTests", dependencies: ["CoreSpiceCompile"]),
        .testTarget(name: "CoreSpiceAnalysisTests", dependencies: ["CoreSpiceAnalysis"]),
        .testTarget(name: "CoreSpiceBackendTests", dependencies: ["CoreSpiceBackend"]),
        .testTarget(name: "PluginsPhotonicTests", dependencies: ["PluginsPhotonic"]),
        .testTarget(name: "CoreSpiceTests", dependencies: ["CoreSpice"]),
        .testTarget(name: "CoreSpiceOptoelectronicsTests",
                    dependencies: ["CoreSpiceOptoelectronics", "CoreSpiceDevices",
                                   "CoreSpiceIR", "CoreSpiceCompile", "CoreSpiceAnalysis",
                                   "CoreSpiceEvent"]),

        // I/O Tests
        .testTarget(name: "CoreSpiceParsedIRTests", dependencies: ["CoreSpiceParsedIR"]),
        .testTarget(name: "CoreSpiceWaveformTests", dependencies: ["CoreSpiceWaveform", "CoreSpiceAnalysis"]),
        .testTarget(name: "CoreSpiceParserSPICETests", dependencies: ["CoreSpiceParserSPICE"]),
        .testTarget(name: "CoreSpiceLoweringTests", dependencies: ["CoreSpiceLowering", "CoreSpiceIR"]),
        .testTarget(name: "CoreSpiceExporterTests", dependencies: ["CoreSpiceExporterRAW", "CoreSpiceExporterCSV", "CoreSpiceExporterPSF", "CoreSpiceWaveform"]),
        .testTarget(
            name: "CoreSpiceCLITests",
            dependencies: [
                "CoreSpiceCLI"
            ],
            path: "Tests/CoreSpiceCLITests"
        ),
    ]
)
