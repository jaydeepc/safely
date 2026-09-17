// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SafelyCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "SafelyCore", targets: ["SafelyCore"]),
        .executable(name: "safely-host", targets: ["safely-host"]),
        .executable(name: "shhlock-keytest", targets: ["shhlock-keytest"]),
        .executable(name: "ShhlockMac", targets: ["ShhlockMac"]),
    ],
    targets: [
        .target(name: "SafelyCore"),
        .executableTarget(name: "safely-host", dependencies: ["SafelyCore"]),
        .executableTarget(name: "shhlock-keytest", dependencies: ["SafelyCore"]),
        .executableTarget(name: "ShhlockMac", dependencies: ["SafelyCore"]),
        .testTarget(name: "SafelyCoreTests", dependencies: ["SafelyCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
