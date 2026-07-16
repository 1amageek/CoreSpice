// swift-tools-version: 6.3
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
    dependencies: [
        .package(path: "../CircuiteFoundation"),
    ],
    targets: [
        // --- C module: Metal-compatible types ---
        .target(name: "SharedTypes", path: "Sources/SharedTypes", exclude: ["README.md"], publicHeadersPath: "include"),

        // --- Event, observer, and cancellation primitives ---
        .target(name: "CoreSpiceEvent", exclude: ["README.md"]),

        // --- IR ---
        .target(name: "CoreSpiceIR", dependencies: ["CoreSpiceEvent"], exclude: ["README.md"]),

        // --- LAPACK ABI boundary ---
        .target(
            name: "CoreSpiceLAPACK",
            cSettings: [.define("ACCELERATE_NEW_LAPACK")],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),

        // --- Devices ---
        .target(name: "CoreSpiceDevices", dependencies: ["CoreSpiceIR", "CoreSpiceEvent"], exclude: ["README.md"]),

        // --- Compile ---
        .target(
            name: "CoreSpiceCompile",
            dependencies: ["CoreSpiceIR", "CoreSpiceLAPACK"],
            exclude: ["README.md"]
        ),

        // --- Backend ---
        .target(name: "CoreSpiceBackend", dependencies: ["CoreSpiceEvent", "SharedTypes"],
                exclude: ["README.md", "Shaders"]),

        // --- Analysis ---
        .target(name: "CoreSpiceAnalysis",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceLAPACK",
                               "CoreSpiceBackend", "CoreSpiceEvent"],
                exclude: ["README.md"]),

        // --- Photonic Plugin ---
        // Note: Photonic shaders are provided by CoreSpiceBackend
        .target(name: "PluginsPhotonic",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceBackend", "CoreSpiceEvent", "SharedTypes"],
                exclude: ["README.md"]),

        // --- Optoelectronic Device Models ---
        .target(name: "CoreSpiceOptoelectronics",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceEvent"]),

        // --- Umbrella ---
        .target(name: "CoreSpice",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceAnalysis", "CoreSpiceBackend", "CoreSpiceEvent",
                               "CoreSpiceOptoelectronics",
                               .product(name: "CircuiteFoundation", package: "CircuiteFoundation")]),

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
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceAnalysis",
                               "CoreSpiceParsedIR", "CoreSpiceWaveform",
                               "CoreSpiceParser", "CoreSpiceParserSPICE",
                               "CoreSpiceLowering", "CoreSpiceExporter",
                               "CoreSpiceExporterRAW", "CoreSpiceExporterCSV",
                               "CoreSpiceExporterPSF"]),

        // CLI core and executable entry
        .target(
            name: "CoreSpiceCLICore",
            dependencies: [
                "CoreSpice",
                "CoreSpiceIO",
                "CoreSpiceAnalysis",
                "CoreSpiceDevices",
                "CoreSpiceOptoelectronics",
                "CoreSpiceCompile",
                "CoreSpiceExporter",
                "CoreSpiceExporterRAW",
                "CoreSpiceExporterCSV",
                "CoreSpiceExporterPSF",
                "CoreSpiceBackend",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation")
            ],
            path: "Sources/CoreSpiceCLI",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "CoreSpiceCLI",
            dependencies: ["CoreSpiceCLICore"],
            path: "Sources/CoreSpiceCLIEntry"
        ),

        // ==========================================================================
        // Tests
        // ==========================================================================

        .testTarget(name: "CoreSpiceIRTests", dependencies: ["CoreSpiceIR"]),
        .testTarget(
            name: "CoreSpiceDevicesTests",
            dependencies: [
                "CoreSpiceDevices",
                "CoreSpiceIR",
                "CoreSpiceCompile",
                "CoreSpiceAnalysis",
                "CoreSpiceEvent"
            ]
        ),
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
        .testTarget(
            name: "CoreSpiceWaveformTests",
            dependencies: ["CoreSpiceWaveform", "CoreSpiceAnalysis", "CoreSpiceCompile"]
        ),
        .testTarget(name: "CoreSpiceParserSPICETests", dependencies: ["CoreSpiceParserSPICE"]),
        .testTarget(name: "CoreSpiceIOTests", dependencies: ["CoreSpiceIO", "CoreSpiceCompile", "CoreSpiceEvent"]),
        .testTarget(name: "CoreSpiceLoweringTests", dependencies: ["CoreSpiceLowering", "CoreSpiceIR"]),
        .testTarget(name: "CoreSpiceExporterTests", dependencies: ["CoreSpiceExporterRAW", "CoreSpiceExporterCSV", "CoreSpiceExporterPSF", "CoreSpiceWaveform"]),
        .testTarget(
            name: "CoreSpiceCLITests",
            dependencies: [
                "CoreSpiceCLICore",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation")
            ],
            path: "Tests/CoreSpiceCLITests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
