// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SafelyCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SafelyCore", targets: ["SafelyCore"]),
        .executable(name: "safely-host", targets: ["safely-host"]),
        .executable(name: "safely-simphone", targets: ["safely-simphone"]),
    ],
    targets: [
        .target(name: "SafelyCore"),
        .executableTarget(name: "safely-host", dependencies: ["SafelyCore"]),
        .executableTarget(name: "safely-simphone", dependencies: ["SafelyCore"]),
        .testTarget(name: "SafelyCoreTests", dependencies: ["SafelyCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
