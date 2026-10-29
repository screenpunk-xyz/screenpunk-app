// swift-tools-version: 5.9
import PackageDescription

// Exercises the actual device library without UIKit, authentication, or a Simulator.
let package = Package(
    name: "ScreenpunkDeviceAuthoring",
    platforms: [.macOS(.v13), .iOS(.v16)],
    dependencies: [
        .package(path: "../../packages/ScreenpunkCore"),
        .package(path: "../../packages/ScreenpunkApple")
    ],
    targets: [
        .target(name: "DeviceAuthoring", dependencies: ["ScreenpunkCore", "ScreenpunkApple"], path: "Sources",
                exclude: ["CloudClient.swift", "DeviceDisplaySettings.swift", "DeviceGestures.swift", "DeviceModel.swift", "LocalAgentSettingsModel.swift", "LocalAgentSetupView.swift", "ScreenpunkApp.swift", "SpeechCapture.swift"],
                sources: ["ScreenLibrary.swift", "DeviceAuthoringTypes.swift", "LocalAgentMacSetup.swift", "NewRequestRoutePolicy.swift", "LocalComputerDiscovery.swift"]),
        .testTarget(name: "DeviceAuthoringTests", dependencies: ["DeviceAuthoring", "ScreenpunkCore", "ScreenpunkApple"], path: "Tests")
    ]
)
