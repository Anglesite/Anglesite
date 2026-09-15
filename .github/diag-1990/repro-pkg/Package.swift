// swift-tools-version: 5.10
import PackageDescription

let strict: [SwiftSetting] = [.enableUpcomingFeature("StrictConcurrency")]
let package = Package(
    name: "repro1990",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Lib", swiftSettings: strict),
        .executableTarget(name: "App", dependencies: ["Lib"], swiftSettings: strict),
        .testTarget(name: "LibTests", dependencies: ["Lib"], swiftSettings: strict),
    ]
)
