// swift-tools-version: 6.4
import PackageDescription

let package = Package(name: "MOSPerformanceEvidence", platforms: [.macOS(.v27)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(name: "NativeHeapMetrics", publicHeadersPath: "include"),
        .executableTarget(name: "MOSPerformanceProbe", dependencies: [
            "NativeHeapMetrics",
            .product(name: "CoreSpice", package: "CoreSpice"),
            .product(name: "CoreSpiceIO", package: "CoreSpice"),
            .product(name: "CoreSpiceMOSContracts", package: "CoreSpice"),
            .product(name: "CoreSpiceMOSResolution", package: "CoreSpice")
        ])
    ])
