// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ScreenpunkApple",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "ScreenpunkApple", targets: ["ScreenpunkApple"])
    ],
    dependencies: [
        .package(path: "../ScreenpunkCore")
    ],
    targets: [
        .target(
            name: "ScreenpunkApple",
            dependencies: ["ScreenpunkCore"],
            exclude: ["Resources/README.md"],
            resources: [
                .copy("Resources/offline-fixture"),
                .copy("Resources/runtime-sdk.js"),
                .copy("Resources/ADB-LICENSE.txt")
            ]
        ),
        .testTarget(
            name: "ScreenpunkAppleTests",
            dependencies: ["ScreenpunkApple"]
        )
    ]
)
