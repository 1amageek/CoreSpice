// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CoreSpiceBenchmarks",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "corespice-benchmarks", targets: ["CoreSpiceBenchmarks"])
    ],
    dependencies: [
        .package(path: "..")
    ],
    targets: [
        .target(
            name: "CoreSpiceBenchmarkSupport",
            dependencies: [
                .product(name: "CoreSpiceIO", package: "CoreSpice")
            ],
            path: "CoreSpiceBenchmarkSupport"
        ),
        .executableTarget(
            name: "CoreSpiceBenchmarks",
            dependencies: [
                "CoreSpiceBenchmarkSupport"
            ],
            path: "CoreSpiceBenchmarks"
        )
    ]
)
