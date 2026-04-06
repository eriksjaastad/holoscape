// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Holoscape",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0"),
        .package(url: "https://github.com/typelift/SwiftCheck.git", from: "0.12.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "Holoscape",
            dependencies: ["SwiftTerm"],
            path: "Sources/Holoscape"
        ),
        .executableTarget(
            name: "HoloscapeMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "Sources/HoloscapeMCP"
        ),
        .testTarget(
            name: "HoloscapeTests",
            dependencies: ["Holoscape"],
            path: "Tests/HoloscapeTests"
        ),
        .testTarget(
            name: "HoloscapePropertyTests",
            dependencies: ["Holoscape", "SwiftCheck"],
            path: "Tests/HoloscapePropertyTests"
        ),
    ]
)
