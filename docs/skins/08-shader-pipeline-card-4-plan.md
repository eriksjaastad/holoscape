# Plan — Card #5941: ShaderCompiler Service (Shader Pipeline 4)

## Context

Card #5941 is Subtask C of the holoscape shader pipeline (#5930). Cards 1–3 (#5938, #5939, #5940, merged in PRs #76, #77, #79) vendored glslang 13.1.1 and spirv-cross sdk-1.3.239.0 as git submodules and wrapped each in a SwiftPM C target (`Cglslang`, `Cspirv_cross`) using a "shim directory" pattern — repo-owned dirs with symlinks into the submodules plus a real modulemap. Both C targets currently link only from `HoloscapeTests` via a bridge smoke test; nothing under `Sources/Holoscape/` imports either one yet.

Card #5941 is the first card that wires the shader toolchain into the Holoscape app target. Its output is a single Swift service — `ShaderCompiler` — that accepts a user GLSL fragment shader path, prepends the Holoscape shader prefix, runs it through glslang → SPIR-V → spirv-cross, and returns Metal Shading Language text. **No Metal renderer, no view changes, no config wiring.** Those land in cards #5942 / #5944 / #5946 respectively.

The plan for the whole shader pipeline lives at `docs/skins/07-shader-pipeline-plan.md` (see §"Subtask C — ShaderCompiler service"). The canonical reference for the glslang + spirv-cross call sequence is Ghostty's `~/projects/github-repos/ghostty/src/renderer/shadertoy.zig`. Shader authoring reference is `docs/skins/05-reactive-uniforms.md` §5, §7, §8.1.

**Heads up for Erik before approval:** card #5941's Kanban `Notes` field describes ReactiveUniformSnapshot work (that belongs to #5945). The `Agent Prompt` field is correct and matches Subtask C in the plan file. This plan follows the Agent Prompt. Fix-up `pt tasks update 5941` after routing.

---

## The §5 "append to the UBO" ambiguity (resolve before implementing)

`05-reactive-uniforms.md` §5 lists the extension uniforms as bare GLSL declarations:

```glsl
uniform int   iOutputEventCount;
uniform float iTimeLastOutput;
uniform int   iCommandState;
...
```

Ghostty's `shadertoy_prefix.glsl` puts all uniforms inside a single `std140` UBO at `binding = 1`:

```glsl
layout(binding = 1, std140) uniform Globals {
    uniform vec3  iResolution;
    uniform float iTime;
    ...
};
```

Vulkan GLSL (our target — `GLSLANG_CLIENT_VULKAN`, SPIR-V 1.5) **does not allow bare opaque-type uniforms outside a uniform block**. Fragment shader uniforms must live in a UBO or push constant block. Taking §5 verbatim as standalone `uniform` declarations would parse-error at `glslang_shader_parse`.

**Recommendation:** merge the §5 declarations *into* the existing `Globals` UBO block — drop the per-line `uniform` keyword, keep the types and names, append them before the closing `};`. This matches Ghostty's single-UBO style, keeps binding=1, and is the only reading consistent with Vulkan GLSL.

If Erik prefers a second UBO at `binding = 2, std140` (e.g. for a cleaner separation between "shadertoy-compatible" and "holoscape-specific" fields), flag that here and I'll produce `Globals` and `HoloscapeGlobals` as two UBOs. I recommend the single-merge approach for card 4; a later card can split if needed.

---

## Extending the `Cglslang` modulemap for `glslang_default_resource()`

The Ghostty call sequence needs `glslang_input_t.resource` to be non-null. Upstream provides `glslang_default_resource()` in `glslang/Public/resource_limits_c.h`. The current `Vendor/Cglslang/include/module.modulemap` exposes only `glslang_c_interface.h`.

The simplest, lowest-risk way to expose `glslang_default_resource()` is a **forwarding header** — a real file in the shim that re-declares just the two symbols we need, backed by the already-symlinked interface header:

```
Vendor/Cglslang/include/glslang_resource_limits.h   (new, real file)
-----------------------------------------------------------------
#ifndef HOLOSCAPE_CGLSLANG_RESOURCE_LIMITS_H
#define HOLOSCAPE_CGLSLANG_RESOURCE_LIMITS_H
#include "glslang_c_interface.h"
const glslang_resource_t* glslang_default_resource(void);
const char* glslang_default_resource_string(void);
#endif
```

Why a forwarding header instead of symlinking `resource_limits_c.h` directly: that file does `#include "../Include/glslang_c_interface.h"` (relative quote-form), and clang resolves relative includes against the symlink path. Card 2's finding. A flat symlink in `include/` would look for `Vendor/Cglslang/include/Include/glslang_c_interface.h`, which doesn't exist. A forwarding header sidesteps the whole resolution problem by re-declaring the function prototypes we actually need.

`resource_limits_c.cpp` is already in `Cglslang`'s sources list (line 89 of `Package.swift`), so the symbols are compiled in — we just need Swift-visible declarations.

`module.modulemap` grows by one line:

```
module Cglslang {
    header "glslang_c_interface.h"
    header "glslang_resource_limits.h"
    export *
}
```

This keeps the `Cglslang` target structure intact and requires zero changes to `headerSearchPath` ordering (which is load-bearing per card 3's comment).

---

## Critical files to modify

| File | Role | New / Modified |
|---|---|---|
| `Sources/Holoscape/Resources/ShaderPrefix/holoscape_prefix.glsl` | 52 Ghostty lines + `#define HOLOSCAPE 1` at top + §5 fields merged into the `Globals` UBO | **New** |
| `Sources/Holoscape/Services/ShaderCompiler.swift` | `@MainActor final class ShaderCompiler` wrapping the glslang → SPIR-V → spirv-cross pipeline | **New** |
| `Vendor/Cglslang/include/glslang_resource_limits.h` | Forwarding header declaring `glslang_default_resource()` | **New** |
| `Vendor/Cglslang/include/module.modulemap` | Add the forwarding header line | Modified |
| `Package.swift` | `resources: [.process("Resources/ShaderPrefix")]` on Holoscape target; handle `AppIcon.icns` warning (see §Package.swift note below) | Modified |
| `Tests/HoloscapeTests/ShaderCompilerTests.swift` | Three unit tests: happy path, syntax error, prefix prepending | **New** |

---

## Package.swift — the Holoscape target resources change

Current state: `Holoscape` executable target has no `resources:` declaration. `AppIcon.icns` currently produces an "unhandled file" warning on every build.

Add:

```swift
.executableTarget(
    name: "Holoscape",
    dependencies: ["SwiftTerm"],
    path: "Sources/Holoscape",
    resources: [
        .process("Resources/ShaderPrefix"),
        .copy("Resources/AppIcon.icns"),
    ]
),
```

Using `.copy` for `AppIcon.icns` because icns files should not be processed by SwiftPM's resource pipeline — they're consumed at bundle time. This also clears the pre-existing unhandled-file warning as a side benefit. If Erik prefers to leave the AppIcon warning exactly as it was (separate concern from card 4), swap `.copy` to an `exclude:` entry instead. I'll default to `.copy` since it's strictly cleaner.

`Bundle.module` access: SwiftPM auto-synthesizes this for any target with resources. No additional opt-in needed.

---

## ShaderCompiler.swift — service shape

```swift
import Foundation
import Cglslang
import Cspirv_cross

struct CompiledShader {
    let mslSource: String
}

enum ShaderCompileError: Error {
    case prefixMissing
    case readFailure(path: String, underlying: Error)
    case preprocessFailure(log: String)
    case parseFailure(log: String)
    case linkFailure(log: String)
    case spirvGenerationFailed(log: String)
    case mslTranslationFailed(log: String)
}

@MainActor
final class ShaderCompiler {
    private static var glslangInitialized = false

    init() {
        if !Self.glslangInitialized {
            _ = glslang_initialize_process()
            Self.glslangInitialized = true
        }
    }

    func compile(glslPath: URL) throws -> CompiledShader { ... }
}
```

**Lifecycle note:** `glslang_initialize_process()` is reference-counted upstream but Swift callers have no reason to finalize — a second compiler in the same process would re-init unnecessarily. Using a `static var` one-shot latch avoids that. No `deinit` finalizer; the process exits cleanly. This matches Ghostty's pattern.

**Why `@MainActor`:** per the card's explicit instruction. It's a design-document constraint, not a technical one — the compiler is CPU-bound and could run off-main, but card 4's contract says MainActor. Keep it.

**Implementation sketch:**

1. **Read prefix** via `Bundle.module.url(forResource: "holoscape_prefix", withExtension: "glsl", subdirectory: "ShaderPrefix")` → `String(contentsOf:)`. On failure → `.prefixMissing`.
2. **Read user GLSL** via `String(contentsOf: glslPath, encoding: .utf8)`. On failure → `.readFailure`.
3. **Concatenate**: `prefix + "\n" + userSource`.
4. **glslang path:**
   - Build `glslang_input_t` with: `language = GLSLANG_SOURCE_GLSL`, `stage = GLSLANG_STAGE_FRAGMENT`, `client = GLSLANG_CLIENT_VULKAN`, `client_version = GLSLANG_TARGET_VULKAN_1_2`, `target_language = GLSLANG_TARGET_SPV`, `target_language_version = GLSLANG_TARGET_SPV_1_5`, `default_version = 100`, `default_profile = GLSLANG_NO_PROFILE`, `messages = GLSLANG_MSG_DEFAULT_BIT`, `resource = glslang_default_resource()` (via the forwarding header), `code = <concatenated source as C string>`.
   - `glslang_shader_create(&input)` → `glslang_shader_preprocess(shader, &input)` → on 0 return: `.preprocessFailure(log: glslang_shader_get_info_log(shader))`.
   - `glslang_shader_parse(shader, &input)` → on 0: `.parseFailure`.
   - `glslang_program_create()` → `glslang_program_add_shader` → `glslang_program_link(program, GLSLANG_MSG_DEFAULT_BIT)` → on 0: `.linkFailure`.
   - `glslang_program_SPIRV_generate(program, GLSLANG_STAGE_FRAGMENT)`.
   - `glslang_program_SPIRV_get_size(program)` → check > 0, else `.spirvGenerationFailed(log: glslang_program_SPIRV_get_messages(program))`.
   - `glslang_program_SPIRV_get_ptr(program)` → buffer pointer + size = SPIR-V word stream.
   - `defer` delete the shader and program handles.
5. **spirv-cross path:**
   - `spvc_context_create(&ctx)` (already proven in card 2's smoke test).
   - `spvc_context_parse_spirv(ctx, spvPtr, spvWordCount, &parsedIR)`.
   - `spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, parsedIR, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler)`.
   - `spvc_compiler_create_compiler_options(compiler, &options)`.
   - `spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING, SPVC_TRUE)`.
   - `spvc_compiler_install_compiler_options(compiler, options)`.
   - `spvc_compiler_compile(compiler, &mslCString)`.
   - On any non-`SPVC_SUCCESS`: collect `spvc_context_get_last_error_string(ctx)` into `.mslTranslationFailed`.
   - Convert `mslCString` to Swift `String` via `String(cString:)`.
   - `defer spvc_context_destroy(ctx)`.
6. Return `CompiledShader(mslSource: mslString)`.

**Swift/C interop helpers needed:**
- `String.withCString { ... }` for passing GLSL source to `glslang_input_t.code`.
- `.init(cString:)` for reading info logs and MSL output.
- `UnsafePointer<glslang_input_t>` — build the struct on the stack and pass its address.

No C header imports beyond `Cglslang` and `Cspirv_cross`. No direct C++ access.

---

## ShaderCompilerTests.swift — three tests

Following the repo's `do`/`catch` + case-pattern-matching style (per the Explore agent's findings — repo does not use `XCTAssertThrowsError` with closures).

```swift
@MainActor
final class ShaderCompilerTests: XCTestCase {

    // (a) happy path — trivial identity, MSL contains iAgentState reference
    func testHappyPathCompilesTrivialShader() throws {
        let path = try writeTempShader("""
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            fragColor = vec4(1);
        }
        """)
        let result = try ShaderCompiler().compile(glslPath: path)
        XCTAssertFalse(result.mslSource.isEmpty)
        XCTAssertTrue(result.mslSource.contains("iAgentState"),
                      "MSL should contain the iAgentState uniform declaration from the Holoscape prefix")
    }

    // (b) syntax error — broken shader throws .parseFailure with non-empty log
    func testSyntaxErrorThrowsParseFailure() throws {
        let path = try writeTempShader("void mainImage() { !!! garbage }")
        do {
            _ = try ShaderCompiler().compile(glslPath: path)
            XCTFail("Expected ShaderCompileError.parseFailure")
        } catch let error as ShaderCompileError {
            if case .parseFailure(let log) = error {
                XCTAssertFalse(log.isEmpty, "Parse failure log should carry glslang's info log")
            } else {
                XCTFail("Expected .parseFailure, got \(error)")
            }
        }
    }

    // (c) prefix prepending — MSL output contains the UBO declaration for iAgentState
    func testPrefixIsPrependedToUserSource() throws {
        let path = try writeTempShader("""
        void mainImage(out vec4 fragColor, in vec2 fragCoord) {
            fragColor = vec4(float(iAgentState));
        }
        """)
        let result = try ShaderCompiler().compile(glslPath: path)
        // iAgentState appears as a struct field in the generated MSL Globals UBO
        XCTAssertTrue(result.mslSource.contains("iAgentState"))
    }

    private func writeTempShader(_ source: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("shader_\(UUID().uuidString).glsl")
        try source.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
```

Test (c) is load-bearing: it proves the prefix is being prepended, not just that the user source compiles. If the prefix weren't prepended, `iAgentState` would be an undeclared identifier and `glslang_shader_parse` would throw.

---

## Verification plan

Run in order:

1. `swift build` — must compile clean. First build of `ShaderCompiler.swift` + the forwarding header. **30-minute hard stop** on SwiftPM/clang errors per card 3's rule; if it blows, capture "Card 4 stop notes" at the bottom of `docs/skins/07-shader-pipeline-plan.md`, reset #5941 to To Do, surface the state.
2. `swift test --filter HoloscapeTests.ShaderCompilerTests` — all three tests green.
3. `swift test` — full suite: 261 existing + 3 new = 264, zero failures.
4. `make bundle` — `Holoscape.app` assembles cleanly; `AppIcon.icns` warning should be gone as a side effect of the `.copy` entry.
5. `/sharp` on the diff — no CRITICAL/MAJOR findings.
6. `/pr` skill → creates PR with `--label feature`, arms `gha pr merge <N> --auto --merge` for merge-commit strategy, watches until merged.

**Existing symbol verification to run BEFORE writing code (5 min):**
- `nm -D` or `objdump --syms` on the test binary to confirm `glslang_default_resource` is actually in the linked objects — since `resource_limits_c.cpp` is in our source list, it should be, but confirm before blindly declaring the extern.
- Read `Vendor/glslang/glslang/MachineIndependent/ShaderLang.cpp` around `glslang_shader_parse` to confirm what it returns on failure (0 or non-zero). Same for `_preprocess` and `_link`. The C interface docs say "non-zero on success" but I want to verify against the code, not assume.

---

## Critical reused utilities

- **`Cglslang`** (`Package.swift:61`) — the C target from card 3. Forwarding header added in `Vendor/Cglslang/include/`; modulemap grows by one line.
- **`Cspirv_cross`** (`Package.swift:28`) — the C target from card 2. No modulemap changes needed; `spirv_cross_c.h` already exposes the symbols we need.
- **Ghostty's `shadertoy.zig`** (`~/projects/github-repos/ghostty/src/renderer/shadertoy.zig`) — canonical reference for call sequence, target version constants, and MSL option settings. Read §§lines with `glslang_input_t` and `spvc_compiler_options_set_bool`.
- **Design docs** — `docs/skins/05-reactive-uniforms.md` §5, §7, §8.1 (UBO fields, `#define HOLOSCAPE 1`, reference shader). `docs/skins/07-shader-pipeline-plan.md` §"Subtask C — ShaderCompiler service" and §"Ghostty's glslang target config (Vulkan 1.2 / SPIR-V 1.5 / GLSL 430)".

## Non-goals (explicit scope fence)

- **No Metal code.** No `MetalCompositor`, no `CAMetalLayer`, no `MTLRenderPipelineState`. Card #5942.
- **No view changes.** `TerminalContainerView`, `HoloscapeTerminalView`, and all view files untouched. Card #5942.
- **No config wiring.** `AppearanceConfig.customShaderPath` does not exist yet. Card #5944.
- **No `ReactiveUniformSnapshot`.** Atomics, agent-state wiring, `@MainActor` bridging to the runtime agent state — card #5945.
- **No hot reload, no discovery, no compile-failure banner.** Card #5946.
- **`SkinEngine` untouched.** Card #5946.
- **No runtime invocation of `ShaderCompiler` from the app binary.** The service exists in `Sources/Holoscape/Services/` but is only exercised by tests. Wiring happens in card #5942.

## Open questions (need Erik before implementing)

1. **§5 UBO merge vs. second UBO.** My recommendation: merge §5 fields into the existing `Globals` UBO at `binding = 1` (drop the per-field `uniform` keyword, append before `};`). This is the only reading consistent with Vulkan GLSL. Confirm or override.
2. **AppIcon.icns handling.** My recommendation: `.copy("Resources/AppIcon.icns")` alongside the new `.process` directive — clears the warning as a bonus. Alternative: `exclude:` entry instead (stricter "no behavior change outside card 4 scope"). Pick one.
3. **Single-session pacing.** Card 4 is the biggest card so far by code volume (new service, new tests, new forwarding header, new prefix file, Package.swift changes). Likely 2–3 hours of focused work plus the SHARP + PR + watch loop on top. Erik is daily-driving this build, so a mid-card stop would leave `main` fine (branch is isolated) but would park a half-done service. Confirm you want to push through in one session, or should I set a "if we're past the build-green milestone within X minutes, keep going; otherwise stop at a branch-clean checkpoint" rule?
