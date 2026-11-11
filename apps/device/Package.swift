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
                exclude: ["WeatherLocationService.swift", "DevicePublicDataDetails.swift", "CloudClient.swift", "DeviceBillingCloudBackend.swift", "DeviceBillingSettings.swift", "DeviceBillingStore.swift", "DeviceDisplaySettings.swift", "DeviceGestures.swift", "DeviceModel.swift", "LocalAgentSettingsModel.swift", "LocalAgentSetupView.swift", "ScreenpunkApp.swift", "SpeechCapture.swift"],
                sources: ["DeviceSwipeTransition.swift", "DeviceBillingWire.swift", "ScreenLibrary.swift", "DeviceAuthoringTypes.swift", "LocalAgentMacSetup.swift", "NewRequestRoutePolicy.swift", "LocalComputerDiscovery.swift", "StarterScreens.swift", "StarterWeather.swift", "PublicDataApprovalStore.swift"], resources: [.copy("StarterScreens")]),
        .testTarget(name: "DeviceAuthoringTests", dependencies: ["DeviceAuthoring", "ScreenpunkCore", "ScreenpunkApple"], path: "Tests")
    ]
)
