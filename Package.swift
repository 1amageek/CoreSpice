// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoreSpice",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CoreSpice", targets: ["CoreSpice"]),
        .library(name: "PluginsPhotonic", targets: ["PluginsPhotonic"]),
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
        .target(name: "PluginsPhotonic",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceBackend", "CoreSpiceEvent", "SharedTypes"],
                resources: [.process("Shaders")]),

        // --- Umbrella ---
        .target(name: "CoreSpice",
                dependencies: ["CoreSpiceIR", "CoreSpiceDevices", "CoreSpiceCompile",
                               "CoreSpiceAnalysis", "CoreSpiceBackend", "CoreSpiceEvent"]),

        // --- Tests ---
        .testTarget(name: "CoreSpiceIRTests", dependencies: ["CoreSpiceIR"]),
        .testTarget(name: "CoreSpiceDevicesTests", dependencies: ["CoreSpiceDevices"]),
        .testTarget(name: "CoreSpiceCompileTests", dependencies: ["CoreSpiceCompile"]),
        .testTarget(name: "CoreSpiceAnalysisTests", dependencies: ["CoreSpiceAnalysis"]),
        .testTarget(name: "CoreSpiceBackendTests", dependencies: ["CoreSpiceBackend"]),
        .testTarget(name: "PluginsPhotonicTests", dependencies: ["PluginsPhotonic"]),
        .testTarget(name: "CoreSpiceTests", dependencies: ["CoreSpice"]),
    ]
)
