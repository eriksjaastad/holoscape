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
        // Vendored C++ libraries for shader pipeline (#5930).
        // See docs/skins/04-ghostty-investigation.md §E.1 for the committed
        // decision to adopt Ghostty's GLSL→SPIR-V→MSL pipeline.
        // Cspirv_cross uses a shim directory with symlinks pointing into the
        // spirv-cross submodule. This keeps the modulemap and public header
        // layout tracked in our repo while leaving the submodule pristine.
        // Source files under Vendor/Cspirv_cross/*.cpp are symlinks to
        // Vendor/spirv-cross/*.cpp. Public header under
        // Vendor/Cspirv_cross/include/spirv_cross_c.h is a symlink to the
        // submodule's header. Clang follows the symlinks and resolves
        // transitive #includes via the real file path in Vendor/spirv-cross/.
        .target(
            name: "Cspirv_cross",
            path: "Vendor/Cspirv_cross",
            sources: [
                "spirv_cross.cpp",
                "spirv_parser.cpp",
                "spirv_cross_parsed_ir.cpp",
                "spirv_cfg.cpp",
                "spirv_cross_c.cpp",
                "spirv_glsl.cpp",
                "spirv_msl.cpp",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .define("SPIRV_CROSS_C_API_GLSL", to: "1"),
                .define("SPIRV_CROSS_C_API_MSL", to: "1"),
                .headerSearchPath("../spirv-cross"),
                .unsafeFlags([
                    "-fno-sanitize=undefined",
                    "-fno-sanitize-trap=undefined",
                ]),
            ]
        ),
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
            dependencies: ["Holoscape", "Cspirv_cross"],
            path: "Tests/HoloscapeTests"
        ),
        .testTarget(
            name: "HoloscapePropertyTests",
            dependencies: ["Holoscape", "SwiftCheck"],
            path: "Tests/HoloscapePropertyTests"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
