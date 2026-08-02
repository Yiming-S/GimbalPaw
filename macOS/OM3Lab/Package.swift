// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "OM3Lab",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "OM3Lab", targets: ["OM3Lab"]),
    ],
    targets: [
        .executableTarget(
            name: "OM3Lab",
            path: "Sources/OM3Lab"
        ),
        .testTarget(
            name: "OM3LabTests",
            dependencies: ["OM3Lab"],
            path: "Tests/OM3LabTests"
        ),
    ]
)
