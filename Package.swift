// swift-tools-version: 6.4
import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    revision: "ae88104c556f5802819713ed741f5b2fffffc2d9"
)

let signoffToolSupportDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/SignoffToolSupport.git",
    exact: "26.812.0"
)

let package = Package(
    name: "CoreSpice",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "CoreSpice", targets: ["CoreSpice"]),
        .library(name: "CoreSpiceCompactModels", targets: ["CoreSpiceCompactModels"]),
        .library(name: "CoreSpiceIR", targets: ["CoreSpiceIR"]),
        .library(name: "CoreSpiceMOSContracts", targets: ["CoreSpiceMOSContracts"]),
        .library(name: "CoreSpiceMOSResolution", targets: ["CoreSpiceMOSResolution"]),
        .library(name: "CoreSpiceIO", targets: ["CoreSpiceIO"]),
        .library(name: "CoreSpiceProcessBackend", targets: ["CoreSpiceProcessBackend"]),
        .library(name: "PluginsPhotonic", targets: ["PluginsPhotonic"]),
        .executable(name: "corespice", targets: ["CoreSpiceCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/ToolQualification.git", revision: "7a69d2ba4e3c4c2262478312f9217de4293a7ab7"),
        circuiteFoundationDependency,
        signoffToolSupportDependency,
    ],
    targets: [
        // --- C module: Metal-compatible types ---
        .target(name: "SharedTypes", path: "Sources/SharedTypes", exclude: ["README.md"], publicHeadersPath: "include"),

        // --- Event, observer, and cancellation primitives ---
        .target(name: "CoreSpiceEvent", exclude: ["README.md"]),

        // --- Portable MOS interpretation boundary ---
        .target(name: "CoreSpiceMOSContracts", exclude: ["DESIGN.md", "Values/DESIGN.md", "Schema/DESIGN.md", "Preparation/DESIGN.md"]),
        .target(name: "CoreSpiceMOSResolution", dependencies: ["CoreSpiceMOSContracts"],
                exclude: ["DESIGN.md", "Declarations/DESIGN.md", "Evaluation/DESIGN.md", "Selection/DESIGN.md"]),

        // --- IR ---
        .target(name: "CoreSpiceIR", dependencies: ["CoreSpiceEvent", "CoreSpiceMOSContracts"], exclude: ["README.md", "DESIGN.md", "MOSInstances/DESIGN.md"]),

        // --- LAPACK ABI boundary ---
        .target(
            name: "CoreSpiceLAPACK",
            cSettings: [.define("ACCELERATE_NEW_LAPACK")],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),

        // --- Native compact-model evaluator ---
        .target(name: "CoreSpiceBSIM3", exclude: ["DESIGN.md", "NOTICE.md", "Kernel/DESIGN.md",
            "Kernel/B3TERMS_OF_USE", "Kernel/upstream.json", "Kernel/adapt_upstream.py"],
            publicHeadersPath: "include"),
        .target(name: "CoreSpiceBSIM4", exclude: ["DESIGN.md", "NOTICE.md", "LICENSE.txt", "ECL-2.0.txt", "Proof",
            "Kernel/DESIGN.md", "Kernel/upstream.json", "Kernel/adapt_upstream.py", "Kernel/noise_primitives.inc", "Kernel/NOISE_PRIMITIVE_LICENSE"],
            publicHeadersPath: "include"),
        .target(name: "CoreSpiceCompactModels", dependencies: ["CoreSpiceBSIM3", "CoreSpiceBSIM4", "CoreSpiceMOSContracts"],
            exclude: ["DESIGN.md", "BSIM3/DESIGN.md", "BSIM4/DESIGN.md", "PreparationStorage/DESIGN.md"]),

        // --- Devices ---
        .target(name: "CoreSpiceDevices", dependencies: ["CoreSpiceIR", "CoreSpiceEvent", "CoreSpiceCompactModels", "CoreSpiceMOSContracts"],
                exclude: ["README.md", "DESIGN.md", "Devices/DESIGN.md", "BSIM3/DESIGN.md", "BSIM4/DESIGN.md", "OutputReferredNoise/DESIGN.md", "MOSPreparation/DESIGN.md"]),

        // --- Compile ---
        .target(
            name: "CoreSpiceCompile",
            dependencies: ["CoreSpiceIR", "CoreSpiceLAPACK", "CoreSpiceMOSContracts"],
            exclude: ["README.md", "DESIGN.md"]
        ),

        // --- Backend ---
        .target(name: "CoreSpiceBackend", dependencies: ["CoreSpiceEvent", "SharedTypes"],
                exclude: ["README.md", "Shaders"]),

        // --- Analysis ---
        .target(name: "CoreSpiceAnalysis",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceLAPACK",
                               "CoreSpiceBackend", "CoreSpiceEvent"],
                exclude: ["README.md", "DESIGN.md"]),

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
                               "CoreSpiceOptoelectronics", "CoreSpiceIO", "CoreSpiceWaveform", "CoreSpiceMOSContracts", "CoreSpiceCompactModels", "CoreSpiceParsedIR",
                               .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                               .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                               .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation")],
                exclude: ["DESIGN.md", "NativeExecution/DESIGN.md"]),

        // --- Production external-process simulation backend ---
        .target(
            name: "CoreSpiceProcessBackend",
            dependencies: [
                "CoreSpice",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport")
            ]
        ),

        // ==========================================================================
        // I/O Architecture Modules
        // ==========================================================================

        // --- ParsedIR: AST types for parsed netlists ---
        .target(name: "CoreSpiceParsedIR", exclude: ["DESIGN.md"]),

        // --- Waveform: Waveform data IR and conversion ---
        .target(name: "CoreSpiceWaveform",
                dependencies: ["CoreSpiceIR", "CoreSpiceAnalysis", "CoreSpiceCompile"], exclude: ["DESIGN.md"]),

        // --- Parser: Parser protocols and registry ---
        .target(name: "CoreSpiceParser",
                dependencies: ["CoreSpiceParsedIR",
                    .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                    .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")], exclude: ["DESIGN.md"]),

        // --- ParserSPICE: SPICE netlist parser ---
        .target(name: "CoreSpiceParserSPICE",
                dependencies: ["CoreSpiceParsedIR", "CoreSpiceParser"], exclude: ["DESIGN.md"]),

        // --- Lowering: ParsedNetlist → CircuitIR conversion ---
        .target(name: "CoreSpiceLowering",
                dependencies: ["CoreSpiceParsedIR", "CoreSpiceIR", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution"], exclude: ["DESIGN.md", "Frontend/DESIGN.md"]),

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
                               "CoreSpiceMOSContracts", "CoreSpiceMOSResolution",
                               "CoreSpiceParsedIR", "CoreSpiceWaveform",
                               "CoreSpiceParser", "CoreSpiceParserSPICE",
                               "CoreSpiceLowering", "CoreSpiceExporter",
                               "CoreSpiceExporterRAW", "CoreSpiceExporterCSV",
                               "CoreSpiceExporterPSF",
                               .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                               .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")], exclude: ["DESIGN.md", "InitialConditions/DESIGN.md", "SimulationPreparation/DESIGN.md"]),

        // CLI core and executable entry
        .target(
            name: "CoreSpiceCLICore",
            dependencies: [
                .product(name: "ToolQualification", package: "ToolQualification"),
                .product(name: "ToolQualificationCLICore", package: "ToolQualification"),
                "CoreSpice",
                "CoreSpiceIO",
                "CoreSpiceLowering",
                "CoreSpiceMOSContracts",
                "CoreSpiceMOSResolution",
                "CoreSpiceAnalysis",
                "CoreSpiceDevices",
                "CoreSpiceCompactModels",
                "CoreSpiceOptoelectronics",
                "CoreSpiceCompile",
                "CoreSpiceExporter",
                "CoreSpiceExporterRAW",
                "CoreSpiceExporterCSV",
                "CoreSpiceExporterPSF",
                "CoreSpiceBackend",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation")
            ],
            path: "Sources/CoreSpiceCLI",
            exclude: ["README.md", "DESIGN.md"]
        ),
        .executableTarget(
            name: "CoreSpiceCLI",
            dependencies: ["CoreSpiceCLICore"],
            path: "Sources/CoreSpiceCLIEntry"
        ),

        // ==========================================================================
        // Tests
        // ==========================================================================

        .testTarget(name: "CoreSpiceBSIM3IntegrationTests", dependencies: ["CoreSpice", "CoreSpiceMOSContracts", "CoreSpiceParsedIR", "CoreSpiceParserSPICE", "CoreSpiceLowering", "CoreSpiceDevices", "CoreSpiceAnalysis", "CoreSpiceCompile", "CoreSpiceIR", "CoreSpiceEvent", "CoreSpiceCompactModels", "CoreSpiceIO"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CoreSpiceBSIM3NoiseTests", dependencies: ["CoreSpice", "CoreSpiceMOSContracts", "CoreSpiceParsedIR", "CoreSpiceParserSPICE", "CoreSpiceLowering", "CoreSpiceDevices", "CoreSpiceAnalysis", "CoreSpiceCompile", "CoreSpiceIR", "CoreSpiceEvent", "CoreSpiceCompactModels", "CoreSpiceIO"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CoreSpiceBSIM4IntegrationTests", dependencies: ["CoreSpice", "CoreSpiceMOSContracts", "CoreSpiceParsedIR", "CoreSpiceParserSPICE", "CoreSpiceLowering", "CoreSpiceDevices", "CoreSpiceAnalysis", "CoreSpiceCompile", "CoreSpiceIR", "CoreSpiceEvent", "CoreSpiceCompactModels", "CoreSpiceIO"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CoreSpiceBSIM4NoiseTests", dependencies: ["CoreSpice", "CoreSpiceMOSContracts", "CoreSpiceParsedIR", "CoreSpiceParserSPICE", "CoreSpiceLowering", "CoreSpiceDevices", "CoreSpiceCompactModels", "CoreSpiceAnalysis", "CoreSpiceCompile", "CoreSpiceIR", "CoreSpiceEvent", "CoreSpiceIO"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CoreSpiceBSIM4KernelTests", dependencies: ["CoreSpiceCompactModels"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CoreSpiceCompactModelsTests", dependencies: ["CoreSpiceCompactModels"],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "CoreSpiceMOSContractsTests", dependencies: ["CoreSpiceMOSContracts"]),
        .testTarget(name: "CoreSpiceMOSResolutionTests", dependencies: ["CoreSpiceMOSContracts", "CoreSpiceMOSResolution"]),
        .testTarget(name: "CoreSpiceMOSPreparationTests", dependencies: ["CoreSpiceDevices", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceIR", "CoreSpiceCompile", "CoreSpiceCompactModels"]),
        .testTarget(name: "CoreSpiceIRTests", dependencies: ["CoreSpiceIR", "CoreSpiceMOSContracts"]),
        .testTarget(
            name: "CoreSpiceDevicesTests",
            dependencies: [
                "CoreSpiceMOSContracts",
                "CoreSpiceMOSResolution",
                "CoreSpiceDevices",
                "CoreSpiceIR",
                "CoreSpiceCompile",
                "CoreSpiceAnalysis",
                "CoreSpiceEvent"
            ]
        ),
        .testTarget(name: "CoreSpiceCompileTests", dependencies: ["CoreSpiceCompile", "CoreSpiceMOSContracts"]),
        .testTarget(name: "CoreSpiceAnalysisTests", dependencies: ["CoreSpiceAnalysis", "CoreSpice", "CoreSpiceIO", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceParsedIR"]),
        .testTarget(name: "CoreSpiceBackendTests", dependencies: ["CoreSpiceBackend"]),
        .testTarget(name: "PluginsPhotonicTests", dependencies: ["PluginsPhotonic"]),
        .testTarget(
            name: "CoreSpiceTests",
            dependencies: [
                "CoreSpice",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            ]
        ),
        .testTarget(
            name: "CoreSpiceProcessBackendTests",
            dependencies: [
                "CoreSpiceProcessBackend",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation")
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "CoreSpiceOptoelectronicsTests",
                    dependencies: ["CoreSpiceOptoelectronics", "CoreSpiceDevices",
                                   "CoreSpiceIR", "CoreSpiceCompile", "CoreSpiceAnalysis",
                                   "CoreSpiceEvent"]),

        // Focused owned source-boundary tests; no numerical or GPU tests.
        .testTarget(name: "CoreSpiceSourceBoundaryTests", dependencies: ["CoreSpiceParsedIR", "CoreSpiceParser", "CoreSpiceIO",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")]),

        .testTarget(name: "CoreSpiceNativeExecutionTests", dependencies: ["CoreSpice", "CoreSpiceIO", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceIR", "CoreSpiceCompile", "CoreSpiceDevices",
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")]),

        .testTarget(name: "CoreSpiceInitialConditionTests", dependencies: ["CoreSpiceIO", "CoreSpiceIR", "CoreSpiceParsedIR", "CoreSpiceLowering", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution"]),

        .testTarget(name: "CoreSpiceProfileGrammarTests", dependencies: ["CoreSpiceParsedIR", "CoreSpiceParser", "CoreSpiceParserSPICE"]),

        // I/O Tests
        .testTarget(name: "CoreSpiceParsedIRTests", dependencies: ["CoreSpiceParsedIR"]),
        .testTarget(
            name: "CoreSpiceWaveformTests",
            dependencies: ["CoreSpiceWaveform", "CoreSpiceAnalysis", "CoreSpiceCompile"]
        ),
        .testTarget(name: "CoreSpiceParserSPICETests", dependencies: ["CoreSpiceParserSPICE"]),
        .testTarget(name: "CoreSpiceIOTests", dependencies: ["CoreSpiceIO", "CoreSpiceCompile", "CoreSpiceEvent", "CoreSpiceCompactModels", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution"]),
        .testTarget(name: "CoreSpiceLoweringTests", dependencies: ["CoreSpiceLowering", "CoreSpiceIR", "CoreSpiceParserSPICE", "CoreSpiceDevices", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution"]),
        .testTarget(name: "CoreSpiceExporterTests", dependencies: ["CoreSpiceExporterRAW", "CoreSpiceExporterCSV", "CoreSpiceExporterPSF", "CoreSpiceWaveform"]),
        .testTarget(
            name: "CoreSpiceCLITests",
            dependencies: [
                "CoreSpiceCLICore",
                "CoreSpice",
                "CoreSpiceIO",
                "CoreSpiceMOSContracts",
                "CoreSpiceMOSResolution",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation")
            ],
            path: "Tests/CoreSpiceCLITests",
            resources: [
                .copy("Fixtures"),
                .copy("../../validation"),
            ]
        ),
    ],
    cLanguageStandard: .c17
)
