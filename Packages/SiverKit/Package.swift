// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiverKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SiverCore", targets: ["SiverCore"]),
        .library(name: "SiverNotify", targets: ["SiverNotify"]),
        .library(name: "SiverInput", targets: ["SiverInput"]),
        .library(name: "SiverVision", targets: ["SiverVision"]),
        .library(name: "SiverMacro", targets: ["SiverMacro"]),
        .library(name: "SiverEngine", targets: ["SiverEngine"]),
        .library(name: "SiverSky", targets: ["SiverSky"]),
        .executable(name: "siversolctl", targets: ["siversolctl"]),
    ],
    targets: [
        .target(name: "SiverCore", resources: [.process("Resources")]),
        .target(name: "SiverNotify", dependencies: ["SiverCore", "SiverSky"]),
        .target(name: "SiverVision", dependencies: ["SiverCore"]),
        .target(name: "SiverSky", dependencies: ["SiverCore"]),
        .target(name: "SiverInput", dependencies: ["SiverCore", "SiverVision"]),
        .target(name: "SiverMacro", dependencies: ["SiverCore", "SiverVision", "SiverInput"]),
        .target(name: "SiverEngine", dependencies: ["SiverCore", "SiverNotify", "SiverInput", "SiverVision", "SiverMacro", "SiverSky"]),
        .executableTarget(
            name: "siversolctl",
            dependencies: ["SiverCore", "SiverNotify", "SiverInput", "SiverVision", "SiverMacro", "SiverEngine", "SiverSky"]
        ),
        .testTarget(name: "SiverCoreTests", dependencies: ["SiverCore"]),
        .testTarget(name: "SiverVisionTests", dependencies: ["SiverVision", "SiverCore"]),
        .testTarget(name: "SiverSkyTests", dependencies: ["SiverSky", "SiverCore"]),
        .testTarget(name: "SiverNotifyTests", dependencies: ["SiverNotify", "SiverSky", "SiverCore"]),
        .testTarget(name: "SiverInputTests", dependencies: ["SiverInput", "SiverVision", "SiverCore"]),
        .testTarget(name: "SiverMacroTests", dependencies: ["SiverMacro", "SiverInput", "SiverVision", "SiverCore"]),
        .testTarget(name: "SiverEngineTests", dependencies: ["SiverEngine", "SiverMacro", "SiverInput", "SiverNotify", "SiverVision", "SiverSky", "SiverCore"]),
    ],
    swiftLanguageModes: [.v5]
)
