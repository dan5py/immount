// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ImmountKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ImmountKit", targets: ["ImmountKit"]),
    ],
    targets: [
        .target(name: "ImmountKit"),
        .testTarget(name: "ImmountKitTests", dependencies: ["ImmountKit"]),
    ]
)
