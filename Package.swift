// swift-tools-version: 6.4
import PackageDescription

let circuiteFoundationDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/CircuiteFoundation.git",
    exact: "26.1021.0"
)

let signoffToolSupportDependency: Package.Dependency = .package(
    url: "https://github.com/1amageek/SignoffToolSupport.git",
    exact: "26.1018.0"
)

let package = Package(
    name: "CoreSpice",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "CoreSpice", targets: ["CoreSpice"]),
        .library(name: "CoreSpiceOSDIContracts", targets: ["CoreSpiceOSDIContracts"]),
        .library(name: "CoreSpiceOSDI", targets: ["CoreSpiceOSDI"]),
        .library(name: "CoreSpiceIR", targets: ["CoreSpiceIR"]),
        .library(name: "CoreSpiceEvaluationContracts", targets: ["CoreSpiceEvaluationContracts"]),
        .library(name: "CoreSpiceDiodeContracts", targets: ["CoreSpiceDiodeContracts"]),
        .library(name: "CoreSpiceMOSContracts", targets: ["CoreSpiceMOSContracts"]),
        .library(name: "CoreSpiceMOSResolution", targets: ["CoreSpiceMOSResolution"]),
        .library(name: "CoreSpiceIO", targets: ["CoreSpiceIO"]),
        .library(name: "CoreSpiceProcessBackend", targets: ["CoreSpiceProcessBackend"]),
        .library(name: "CoreSpiceBackend", targets: ["CoreSpiceBackend"]),
        .library(name: "PluginsPhotonic", targets: ["PluginsPhotonic"]),
        .executable(name: "corespice", targets: ["CoreSpiceCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/1amageek/swift-osdi.git", exact: "1.2.1"),
        .package(url: "https://github.com/1amageek/ToolQualification.git", exact: "26.1021.0"),
        circuiteFoundationDependency,
        signoffToolSupportDependency,
    ],
    targets: [
        .executableTarget(name: "CoreSpiceSparseQualification", dependencies: [
            "CoreSpice", "CoreSpiceCompile", "CoreSpiceAnalysis", "CoreSpiceIO", "CoreSpiceMOSContracts", "CoreSpiceWaveform",
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")
        ], path: "tools/SparseQualification", exclude: ["DESIGN.md", "prepare.py", "cold_run.py", "verify.py", "transient_oracle.py", "test_prepare.py"],
            sources: ["QualificationTool.swift", "SparseMatrixQualification.swift"]),
        // --- C module: Metal-compatible types ---
        .target(name: "SharedTypes", path: "Sources/SharedTypes", exclude: ["README.md"], publicHeadersPath: "include"),

        // --- Event, observer, and cancellation primitives ---
        .target(name: "CoreSpiceEvent", exclude: ["README.md"]),

        // --- Portable evaluation and diode input contracts ---
        .target(name: "CoreSpiceEvaluationContracts", exclude: ["DESIGN.md", "Environment/DESIGN.md"]),
        .target(name: "CoreSpiceDiodeContracts", dependencies: ["CoreSpiceEvaluationContracts"],
                exclude: ["DESIGN.md", "Input/DESIGN.md", "Preparation/DESIGN.md"]),

        // --- Portable MOS interpretation boundary ---
        .target(name: "CoreSpiceMOSContracts", dependencies: ["CoreSpiceEvaluationContracts"], exclude: ["DESIGN.md", "Values/DESIGN.md", "Schema/DESIGN.md", "Preparation/DESIGN.md"]),
        .target(name: "CoreSpiceMOSResolution", dependencies: ["CoreSpiceMOSContracts", "CoreSpiceEvaluationContracts"],
                exclude: ["DESIGN.md", "Declarations/DESIGN.md", "Evaluation/DESIGN.md", "Selection/DESIGN.md"]),

        // --- Portable OSDI circuit binding values ---
        .target(name: "CoreSpiceOSDIContracts", dependencies: [
            .product(name: "OSDIContracts", package: "swift-osdi"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation")
        ], exclude: ["DESIGN.md", "Binding/DESIGN.md"]),

        // --- IR ---
        .target(name: "CoreSpiceIR", dependencies: ["CoreSpiceOSDIContracts", "CoreSpiceEvent", "CoreSpiceMOSContracts", "CoreSpiceEvaluationContracts", "CoreSpiceDiodeContracts"], exclude: ["README.md", "DESIGN.md", "MOSInstances/DESIGN.md", "DiodeInstances/DESIGN.md", "OSDIInstances/DESIGN.md"]),

        // Compact-model physics is provided exclusively through swift-osdi.

        // --- Devices ---
        .target(name: "CoreSpiceDevices", dependencies: ["CoreSpiceIR", "CoreSpiceEvent", "CoreSpiceMOSContracts", "CoreSpiceEvaluationContracts", "CoreSpiceDiodeContracts"],
                exclude: ["README.md", "DESIGN.md", "Devices/DESIGN.md", "OutputReferredNoise/DESIGN.md", "MOSPreparation/DESIGN.md", "Diode/DESIGN.md", "ResidualNoise/DESIGN.md", "TransientLifecycle/DESIGN.md", "NumericalState/DESIGN.md", "ContinuousEquationStructure/DESIGN.md"]),

        // --- Compile ---
        .target(
            name: "CoreSpiceCompile",
            dependencies: ["CoreSpiceIR", "CoreSpiceMOSContracts", "CoreSpiceDiodeContracts"],
            exclude: ["README.md", "DESIGN.md", "SparseFactorization/DESIGN.md", "SparseOrdering/DESIGN.md"]
        ),

        // --- Backend ---
        .target(name: "CoreSpiceBackend", dependencies: ["CoreSpiceEvent", "SharedTypes"],
                exclude: ["README.md", "Shaders", "DESIGN.md", "MetalExecution/DESIGN.md"]),

        // --- Native OSDI model-to-circuit adapter ---
        .target(name: "CoreSpiceOSDI", dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile", "CoreSpiceOSDIContracts",
            .product(name: "OSDIContracts", package: "swift-osdi"),
            .product(name: "OSDIRuntime", package: "swift-osdi"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation")
        ], exclude: ["DCExecution/DESIGN.md", "DESIGN.md", "Preparation/DESIGN.md", "Topology/DESIGN.md", "RangeExecution/DESIGN.md"], swiftSettings: [.enableExperimentalFeature("Lifetimes"), .enableExperimentalFeature("LifetimeDependence")]),

        // --- Analysis ---
        .target(name: "CoreSpiceAnalysis",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceDiodeContracts", "CoreSpiceEvaluationContracts",
                               "CoreSpiceEvent"],
                exclude: ["README.md", "DESIGN.md", "EquationConvergence/DESIGN.md", "Completion/DESIGN.md", "TransientValidation/DESIGN.md", "FrequencyNoise/DESIGN.md", "CompensatedTransient/DESIGN.md", "CompensatedDC/DESIGN.md", "NewtonVoltageLimiting/DESIGN.md", "SparseExecution/DESIGN.md", "ValidatedTransient/DESIGN.md", "ValidatedMatrixRegularity/DESIGN.md", "ValidatedParametricRoot/DESIGN.md", "NetworkParameters/DESIGN.md", "ExactRowAlgebra/DESIGN.md", "PrescribedVoltageReduction/DESIGN.md", "GeneralizedSchur/DESIGN.md", "GeneralizedSchur/THIRD_PARTY_NOTICES.txt"]),

        // --- Photonic Plugin ---
        // Note: Photonic shaders are provided by CoreSpiceBackend
        .target(name: "PluginsPhotonic",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceBackend", "CoreSpiceEvent", "SharedTypes"],
                exclude: ["README.md", "DESIGN.md", "IR/DESIGN.md", "Compiler/DESIGN.md", "GPU/DESIGN.md", "Execution/DESIGN.md"]),

        // --- Optoelectronic Device Models ---
        .target(name: "CoreSpiceOptoelectronics",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceEvent"]),

        // --- Umbrella ---
        .target(name: "CoreSpice",
                dependencies: ["CoreSpiceOSDI", "CoreSpiceOSDIContracts", "CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceAnalysis", "CoreSpiceEvent",
                               "CoreSpiceOptoelectronics", "CoreSpiceIO", "CoreSpiceWaveform", "CoreSpiceMOSContracts", "CoreSpiceParsedIR", "CoreSpiceEvaluationContracts", "CoreSpiceDiodeContracts",
                               .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                               .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                               .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                               .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
                               .product(name: "OSDIContracts", package: "swift-osdi"),
                               .product(name: "OSDIRuntime", package: "swift-osdi")],
                exclude: ["DESIGN.md", "NativeExecution/DESIGN.md", "NativeExecution/GlobalChargeKernel/DESIGN.md", "NativeExecution/PrescribedVoltageValues/DESIGN.md", "NativeExecution/PrescribedVoltageReconstruction/DESIGN.md", "NativeExecution/PrescribedVoltageMass/DESIGN.md", "NativeExecution/PrescribedVoltageChart/DESIGN.md", "NativeExecution/PrescribedVoltageInitialCover/DESIGN.md", "NativeExecution/PrescribedVoltageEvolution/DESIGN.md", "NativeExecution/PrescribedVoltageFlow/DESIGN.md"],
                swiftSettings: [.enableExperimentalFeature("Lifetimes"), .enableExperimentalFeature("LifetimeDependence")]),

        // --- Production external-process simulation backend ---
        .target(
            name: "CoreSpiceProcessBackend",
            dependencies: [
                "CoreSpice",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport")
            ],
            exclude: ["DESIGN.md"]
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
                dependencies: ["CoreSpiceOSDIContracts","CoreSpiceParsedIR", "CoreSpiceIR", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceEvaluationContracts", "CoreSpiceDiodeContracts",
                               .product(name: "OSDIContracts", package: "swift-osdi")], exclude: ["DESIGN.md", "Frontend/DESIGN.md", "DiodeResolution/DESIGN.md"]),

        // --- Exporter: Exporter protocols and registry ---
        .target(name: "CoreSpiceExporter",
                dependencies: ["CoreSpiceWaveform"], exclude: ["DESIGN.md"]),

        // --- ExporterRAW: RAW format exporter ---
        .target(name: "CoreSpiceExporterRAW",
                dependencies: ["CoreSpiceWaveform", "CoreSpiceExporter"], exclude: ["DESIGN.md"]),

        // --- ExporterCSV: CSV format exporter ---
        .target(name: "CoreSpiceExporterCSV",
                dependencies: ["CoreSpiceWaveform", "CoreSpiceExporter"], exclude: ["DESIGN.md"]),

        // --- ExporterPSF: PSF format exporter (Cadence) ---
        .target(name: "CoreSpiceExporterPSF",
                dependencies: ["CoreSpiceWaveform", "CoreSpiceExporter"], exclude: ["DESIGN.md"]),

        // --- I/O Umbrella: Re-exports all I/O modules ---
        .target(name: "CoreSpiceIO",
                dependencies: ["CoreSpiceCompile", "CoreSpiceEvent", "CoreSpiceOSDIContracts","CoreSpiceEvaluationContracts", "CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceAnalysis",
                               "CoreSpiceMOSContracts", "CoreSpiceMOSResolution",
                               "CoreSpiceParsedIR", "CoreSpiceWaveform",
                               "CoreSpiceParser", "CoreSpiceParserSPICE",
                               "CoreSpiceLowering", "CoreSpiceDiodeContracts", "CoreSpiceExporter",
                               "CoreSpiceExporterRAW", "CoreSpiceExporterCSV",
                               "CoreSpiceExporterPSF",
                               .product(name: "OSDIContracts", package: "swift-osdi"),
                               .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                               .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")], exclude: ["DESIGN.md", "InitialConditions/DESIGN.md", "SimulationPreparation/DESIGN.md", "Touchstone/DESIGN.md", "ExternalModelPreparation/DESIGN.md", "ExternalModelPreparation/MOSBinPreparation/DESIGN.md"]),

        // CLI core and executable entry
        .target(
            name: "CoreSpiceCLICore",
            dependencies: [
                "CoreSpiceOSDI", "CoreSpiceOSDIContracts",
                .product(name: "OSDIContracts", package: "swift-osdi"),
                .product(name: "OSDIRuntime", package: "swift-osdi"),
                .product(name: "ToolQualification", package: "ToolQualification"),
                .product(name: "ToolQualificationCLICore", package: "ToolQualification"),
                "CoreSpice",
                "CoreSpiceIO",
                "CoreSpiceLowering",
                "CoreSpiceDiodeContracts",
                "CoreSpiceEvaluationContracts",
                "CoreSpiceMOSContracts",
                "CoreSpiceMOSResolution",
                "CoreSpiceAnalysis",
                "CoreSpiceDevices",
                "CoreSpiceOptoelectronics",
                "CoreSpiceCompile",
                "CoreSpiceExporter",
                "CoreSpiceExporterRAW",
                "CoreSpiceExporterCSV",
                "CoreSpiceExporterPSF",
                .product(name: "CircuiteFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation"),
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation")
            ],
            path: "Sources/CoreSpiceCLI",
            exclude: ["README.md", "DESIGN.md", "DiodeEvidence/DESIGN.md", "MetricEvidence/DESIGN.md", "PrecisionEvidence/DESIGN.md", "ExecutionPolicy/DESIGN.md"]
        ),
        .executableTarget(
            name: "CoreSpiceCLI",
            dependencies: ["CoreSpiceCLICore"],
            path: "Sources/CoreSpiceCLIEntry"
        ),

        // ==========================================================================
        // Tests
        // ==========================================================================

        .target(name: "CoreSpiceOSDITestSupport", dependencies: ["CoreSpiceOSDI", .product(name: "CircuiteFoundation", package: "CircuiteFoundation"), .product(name: "OSDIContracts", package: "swift-osdi")], path: "Tests/CoreSpiceOSDITestSupport", exclude: ["DESIGN.md"]),
        .testTarget(name: "CoreSpiceOSDITests", dependencies: ["CoreSpiceOSDITestSupport","CoreSpiceOSDI", "CoreSpiceOSDIContracts", "CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile", "CoreSpiceAnalysis", "CoreSpiceEvent",
            .product(name: "OSDIContracts", package: "swift-osdi"), .product(name: "OSDIRuntime", package: "swift-osdi"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation")
        ], exclude: ["DESIGN.md", "Fixtures"], swiftSettings: [.enableExperimentalFeature("Lifetimes"), .enableExperimentalFeature("LifetimeDependence")]),
        .testTarget(name: "CoreSpiceOSDINativeTests", dependencies: ["CoreSpiceExporterCSV", "CoreSpiceExporter", "CoreSpice", "CoreSpiceIO", "CoreSpiceLowering", "CoreSpiceMOSContracts", "CoreSpiceParsedIR", "CoreSpiceOSDI", "CoreSpiceOSDIContracts", "CoreSpiceOSDITestSupport", "CoreSpiceAnalysis", "CoreSpiceCompile", "CoreSpiceDevices", "CoreSpiceIR", "CoreSpiceEvent", "CoreSpiceWaveform",
            .product(name: "OSDIContracts", package: "swift-osdi"), .product(name: "OSDIRuntime", package: "swift-osdi"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation")]),
        .testTarget(name: "CoreSpiceOSDICLITests", dependencies: ["CoreSpiceAnalysis", "CoreSpiceDevices", "CoreSpiceIR", "CoreSpiceEvent", "CoreSpiceExporterCSV", "CoreSpiceCLICore", "CoreSpice", "CoreSpiceIO", "CoreSpiceWaveform", "CoreSpiceOSDI", "CoreSpiceOSDIContracts", "CoreSpiceOSDITestSupport",
            .product(name: "OSDIContracts", package: "swift-osdi"), .product(name: "OSDIRuntime", package: "swift-osdi"),
            .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
            .product(name: "ToolQualification", package: "ToolQualification"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation"),
            .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationFoundation", package: "CircuiteFoundation")], exclude: ["DESIGN.md"]),
        .testTarget(name: "CoreSpiceOSDIAnalysisTests", dependencies: ["CoreSpiceAnalysis", "CoreSpiceCompile", "CoreSpiceDevices", "CoreSpiceIR", "CoreSpiceEvent"]),
        .testTarget(name: "CoreSpiceOSDIFrontendTests", dependencies: ["CoreSpiceParserSPICE", "CoreSpiceParser", "CoreSpiceParsedIR", "CoreSpiceLowering", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceIR", "CoreSpiceIO", "CoreSpiceOSDIContracts",
            .product(name: "OSDIContracts", package: "swift-osdi"), .product(name: "CircuiteFoundation", package: "CircuiteFoundation"), .product(name: "CircuiteFoundationCrypto", package: "CircuiteFoundation")]),
        .testTarget(name: "CoreSpiceOSDIContractsTests", dependencies: ["CoreSpiceOSDIContracts", "CoreSpiceIR",
            .product(name: "OSDIContracts", package: "swift-osdi"),
            .product(name: "CircuiteFoundation", package: "CircuiteFoundation")]),
        .testTarget(name: "CoreSpiceConditionEvaluationTests", dependencies: ["CoreSpiceLowering", "CoreSpiceIR", "CoreSpiceParsedIR", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceEvaluationContracts"]),
        .testTarget(name: "CoreSpiceEvaluationContractsTests", dependencies: ["CoreSpiceEvaluationContracts"]),
        .testTarget(name: "CoreSpiceDiodeIntegrationTests", dependencies: ["CoreSpiceIO", "CoreSpiceLowering", "CoreSpiceMOSContracts", "CoreSpiceDiodeContracts", "CoreSpiceIR", "CoreSpiceCompile", "CoreSpiceDevices", "CoreSpiceEvent"]),
        .testTarget(name: "CoreSpiceDiodeResolutionTests", dependencies: ["CoreSpiceParser", "CoreSpiceLowering", "CoreSpiceIR", "CoreSpiceParsedIR", "CoreSpiceParserSPICE", "CoreSpiceDiodeContracts", "CoreSpiceEvaluationContracts", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution"]),
        .testTarget(name: "CoreSpiceDiodeContractsTests", dependencies: ["CoreSpiceDiodeContracts", "CoreSpiceEvaluationContracts"]),
        .testTarget(name: "CoreSpiceMOSContractsTests", dependencies: ["CoreSpiceMOSContracts"]),
        .testTarget(name: "CoreSpiceMOSResolutionTests", dependencies: ["CoreSpiceMOSContracts", "CoreSpiceMOSResolution"]),
        .testTarget(name: "CoreSpiceMOSPreparationTests", dependencies: ["CoreSpiceDevices", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceIR", "CoreSpiceCompile"]),
        .testTarget(name: "CoreSpiceIRTests", dependencies: ["CoreSpiceIR", "CoreSpiceMOSContracts"]),
        .testTarget(
            name: "CoreSpiceDevicesTests",
            dependencies: [
                "CoreSpiceDiodeContracts",
                "CoreSpiceEvaluationContracts",
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
        .testTarget(name: "CoreSpiceAnalysisTests", dependencies: ["CoreSpiceAnalysis", "CoreSpice", "CoreSpiceIO", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceParsedIR", "CoreSpiceDiodeContracts", "CoreSpiceEvaluationContracts"], resources: [.copy("Fixtures")]),
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
                .product(name: "CircuiteFoundationFileSystem", package: "CircuiteFoundation"),
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport")
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

        .testTarget(name: "CoreSpiceNativeExecutionTests", dependencies: ["CoreSpiceDiodeContracts", "CoreSpiceEvaluationContracts", "CoreSpice", "CoreSpiceAnalysis", "CoreSpiceLowering", "CoreSpiceIO", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution", "CoreSpiceIR", "CoreSpiceCompile", "CoreSpiceDevices",
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
        .testTarget(name: "CoreSpiceIOTests", dependencies: ["CoreSpiceIO", "CoreSpiceCompile", "CoreSpiceEvent", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution"]),
        .testTarget(name: "CoreSpiceLoweringTests", dependencies: ["CoreSpiceDiodeContracts", "CoreSpiceLowering", "CoreSpiceIR", "CoreSpiceParserSPICE", "CoreSpiceDevices", "CoreSpiceMOSContracts", "CoreSpiceMOSResolution"]),
        .testTarget(name: "CoreSpiceExporterTests", dependencies: ["CoreSpiceExporterRAW", "CoreSpiceExporterCSV", "CoreSpiceExporterPSF", "CoreSpiceWaveform"]),
        .testTarget(
            name: "CoreSpiceCLITests",
            dependencies: [
                "CoreSpiceCLICore",
                "CoreSpice",
                "CoreSpiceIO",
                "CoreSpiceMOSContracts",
                "CoreSpiceMOSResolution",
                "CoreSpiceExporterCSV",
                .product(name: "SignoffToolSupport", package: "SignoffToolSupport"),
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
