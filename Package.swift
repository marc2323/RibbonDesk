// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RibbonDesk",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RibbonCore", targets: ["RibbonCore"]),
        .executable(name: "RibbonDesk", targets: ["RibbonDesk"])
    ],
    targets: [
        .target(name: "RibbonCore"),
        .target(name: "SpaceInterop", publicHeadersPath: "include"),
        .executableTarget(name: "RibbonDesk", dependencies: ["RibbonCore", "SpaceInterop"]),
        .executableTarget(name: "RibbonCoreChecks", dependencies: ["RibbonCore"], path: "Tests/RibbonCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
