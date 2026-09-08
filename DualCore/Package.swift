// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DualCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DualCore", targets: ["DualCore"]),
    ],
    targets: [
        .target(
            name: "DualCore",
            path: "Sources/DualCore"
        ),
        .testTarget(
            name: "DualCoreTests",
            dependencies: ["DualCore"],
            path: "Tests/DualCoreTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
