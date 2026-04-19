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
        // Amplify Task 3.1 — pure-Swift ZIP reader/writer for `.wamp`
        // bundle loading (no native zlib bindings). MIT licensed.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0"),
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
        // Cglslang uses the same shim-directory pattern as Cspirv_cross, but
        // with directory-level symlinks because glslang's source tree uses
        // parent-relative quote-form includes like `#include "../Include/Common.h"`.
        // Clang resolves those relative to the source file's directory (the
        // symlink path, not the realpath — per card 2's finding), so the tree
        // structure must exist under Vendor/Cglslang/.
        //
        // Layout: `glslang/` and `SPIRV/` are directory symlinks into the
        // submodule at Vendor/glslang/. `include/` is a repo-owned directory
        // with the module.modulemap, `glslang_c_interface.h`, and its transitive
        // include `glslang_c_shader_types.h` (both symlinked).
        //
        // The override header path comes BEFORE the submodule in the header
        // search order so that `#include "glslang/build_info.h"` (which two
        // source files use) resolves to our pinned override file rather than
        // looking for an auto-generated file upstream doesn't ship.
        .target(
            name: "Cglslang",
            path: "Vendor/Cglslang",
            exclude: [
                // Everything under glslang/ and SPIRV/ that isn't in sources
                // below. SwiftPM walks the symlinked dirs and treats unlisted
                // files as unhandled, so we exclude the known-unused subtrees.
                "glslang/HLSL",
                "glslang/OSDependent/Web",
                "glslang/OSDependent/Windows",
                "SPIRV/SPVRemapper.cpp",
                "SPIRV/SpvTools.cpp",
                "SPIRV/spirv.hpp",
            ],
            sources: [
                "glslang/GenericCodeGen/CodeGen.cpp",
                "glslang/GenericCodeGen/Link.cpp",
                "glslang/MachineIndependent/glslang_tab.cpp",
                "glslang/MachineIndependent/attribute.cpp",
                "glslang/MachineIndependent/Constant.cpp",
                "glslang/MachineIndependent/iomapper.cpp",
                "glslang/MachineIndependent/InfoSink.cpp",
                "glslang/MachineIndependent/Initialize.cpp",
                "glslang/MachineIndependent/IntermTraverse.cpp",
                "glslang/MachineIndependent/Intermediate.cpp",
                "glslang/MachineIndependent/ParseContextBase.cpp",
                "glslang/MachineIndependent/ParseHelper.cpp",
                "glslang/MachineIndependent/PoolAlloc.cpp",
                "glslang/MachineIndependent/RemoveTree.cpp",
                "glslang/MachineIndependent/Scan.cpp",
                "glslang/MachineIndependent/ShaderLang.cpp",
                "glslang/MachineIndependent/SpirvIntrinsics.cpp",
                "glslang/MachineIndependent/SymbolTable.cpp",
                "glslang/MachineIndependent/Versions.cpp",
                "glslang/MachineIndependent/intermOut.cpp",
                "glslang/MachineIndependent/limits.cpp",
                "glslang/MachineIndependent/linkValidate.cpp",
                "glslang/MachineIndependent/parseConst.cpp",
                "glslang/MachineIndependent/reflection.cpp",
                "glslang/MachineIndependent/preprocessor/Pp.cpp",
                "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
                "glslang/MachineIndependent/preprocessor/PpContext.cpp",
                "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
                "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
                "glslang/MachineIndependent/propagateNoContraction.cpp",
                "glslang/CInterface/glslang_c_interface.cpp",
                "glslang/ResourceLimits/ResourceLimits.cpp",
                "glslang/ResourceLimits/resource_limits_c.cpp",
                "glslang/OSDependent/Unix/ossource.cpp",
                "SPIRV/GlslangToSpv.cpp",
                "SPIRV/InReadableOrder.cpp",
                "SPIRV/Logger.cpp",
                "SPIRV/SpvBuilder.cpp",
                "SPIRV/SpvPostProcess.cpp",
                "SPIRV/doc.cpp",
                "SPIRV/disassemble.cpp",
                "SPIRV/CInterface/spirv_c_interface.cpp",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                // Header search path ordering is load-bearing. All three
                // paths are required; do not delete any of them.
                //   1. `../glslang-override` — contains ONLY our pinned
                //      `glslang/build_info.h`. Must be first so it wins
                //      against any other root (upstream does not ship this
                //      file; it's normally CMake-generated).
                //   2. `.` (= `Vendor/Cglslang`) — resolves `glslang/...` and
                //      `SPIRV/...` rooted includes via the directory symlinks
                //      at the shim root. Needed by source files that do
                //      `#include "glslang/Include/Common.h"` style rooted
                //      quote-form includes.
                //   3. `../glslang` (= the submodule root) — resolves rooted
                //      includes like `#include "StandAlone/DirStackFileIncluder.h"`
                //      that point at subtrees we didn't symlink into the shim.
                .headerSearchPath("../glslang-override"),
                .headerSearchPath("."),
                .headerSearchPath("../glslang"),
                // Intentionally no ENABLE_HLSL define: glslang gates HLSL
                // code with `#ifdef ENABLE_HLSL`, so defining it to any
                // value (including 0) activates the branch. Leaving it
                // undefined keeps HLSL symbols out of the compiled objects,
                // which matches our source list (no glslang/HLSL/*.cpp).
                .unsafeFlags([
                    "-fno-sanitize=undefined",
                    "-fno-sanitize-trap=undefined",
                ]),
            ]
        ),
        .executableTarget(
            name: "Holoscape",
            dependencies: ["SwiftTerm", "Cglslang", "Cspirv_cross", "ZIPFoundation"],
            path: "Sources/Holoscape",
            resources: [
                // GLSL shader prefix prepended to every user shader before
                // compilation. See docs/skins/07-shader-pipeline-plan.md and
                // Sources/Holoscape/Services/ShaderCompiler.swift.
                .process("Resources/ShaderPrefix"),
                // Bundled reference skins (Task 13). `.copy` (not `.process`)
                // because we need the nested `Skins/<name>/{skin.json,
                // assets/*}` directory structure preserved. `.process`
                // flattens all files to the bundle root, which would
                // break both the dedup rule (multiple skins can't share
                // filenames) and the ninepatch sidecar lookup (which
                // keys on the image's manifest-relative path).
                // SkinEngine enumerates + resolves via
                // `Bundle.main.resourceURL/Skins/`.
                .copy("Resources/Skins"),
                // AppIcon.icns is consumed by the .app bundling step, not
                // SwiftPM's resource pipeline. Declaring it as .copy stops
                // the "unhandled file" warning without processing it.
                .copy("Resources/AppIcon.icns"),
            ]
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
            dependencies: ["Holoscape", "Cspirv_cross", "Cglslang"],
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
