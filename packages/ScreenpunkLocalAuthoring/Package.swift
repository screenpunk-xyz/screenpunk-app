// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ScreenpunkLocalAuthoring", platforms: [.iOS(.v16), .macOS(.v13)], products: [.library(name: "ScreenpunkLocalAuthoring", targets: ["ScreenpunkLocalAuthoring"])], dependencies: [.package(path: "../ScreenpunkCore"), .package(path: "../ScreenpunkLocalTransport")], targets: [.target(name: "ScreenpunkLocalAuthoring", dependencies: ["ScreenpunkCore", "ScreenpunkLocalTransport"]), .testTarget(name: "ScreenpunkLocalAuthoringTests", dependencies: ["ScreenpunkLocalAuthoring"])], swiftLanguageModes: [.v5])
