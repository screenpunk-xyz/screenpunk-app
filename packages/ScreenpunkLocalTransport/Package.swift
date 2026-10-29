// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenpunkLocalTransport",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "ScreenpunkLocalTransport", targets: ["ScreenpunkLocalTransport"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3")
    ],
    targets: [
        .target(name: "ScreenpunkLocalTransport", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .testTarget(name: "ScreenpunkLocalTransportTests", dependencies: ["ScreenpunkLocalTransport"])
    ],
    swiftLanguageModes: [.v5]
)
