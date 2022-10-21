// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "fltrJET",
    platforms: [.iOS(.v14), .macOS(.v11)],
    products: [
        .library(
            name: "fltrJET",
            targets: ["fltrJET"]),
    ],
    dependencies: [
        .package(url: "https://github.com/fltrWallet/FastrangeSipHash", branch: "main"),
        .package(url: "https://github.com/fltrWallet/fltrECC", branch: "main"),
        .package(url: "https://github.com/fltrWallet/fltrWAPI", branch: "main"),
        .package(url: "https://github.com/fltrWallet/fltrTx", branch: "main"),
        .package(url: "https://github.com/fltrWallet/HaByLo", branch: "main"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "fltrJET",
            dependencies: [
                "CfltrJET",
                "fltrWAPI",
                "HaByLo",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
            ]),
        .target(
            name: "CfltrJET",
            dependencies: [],
            publicHeadersPath: ".",
            cSettings: [ .headerSearchPath("."), ]),
        .testTarget(
            name: "fltrJETTests",
            dependencies: [
                "FastrangeSipHash",
                "fltrECC",
                .product(name: "fltrECCTesting", package: "fltrECC"),
                "fltrJET",
                "fltrTx"
            ]),
    ]
)
