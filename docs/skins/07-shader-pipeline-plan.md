# Plan — #5930: Port Ghostty's Shader Pipeline to Holoscape

> **Update 2026-04-15:** Re-carved the original 5-subtask split into **8 cards** after discovering the vendoring subtask was significantly larger than estimated. New tracker IDs:
>
> - **Card 1** — #5938: Vendoring prep (submodules + override header)
> - **Card 2** — #5939: Cspirv_cross SwiftPM target + smoke test (de-risking card)
> - **Card 3** — #5940: Cglslang SwiftPM target + smoke test
> - **Card 4** — #5941: ShaderCompiler full GLSL→MSL pipeline
> - **Card 5** — #5942: Metal compositor + identity render (biggest card)
> - **Card 6** — #5944: Config flag + scanlines demo (first user-visible effect)
> - **Card 7** — #5945: Agent-state reactivity + red-pulse demo
> - **Card 8** — #5946: Shader discovery, hot reload, compile-failure banner (closes #5930)
>
> Each card is 1–4 hours of focused work, single conceptual concern, build stays green after every one. The detailed "Implementation notes — vendoring recipe" section at the bottom of this plan captures the exact source-file lists and compile flags so cards 1–3 start with zero re-scout.

## Context

Tasks #5928 and #5929 shipped the design docs for Holoscape's skin system. The reactive-uniform design (`docs/skins/05-reactive-uniforms.md`) and the chrome-skinning design (`docs/skins/06-chrome-skinning.md`) are both merged. Task #5930 is the **first real implementation card**: bring Ghostty's GLSL → SPIR-V → MSL shader pipeline into Holoscape so that a user shader can render behind the terminal viewport and react to agent state.

Before committing, I scouted the build system, SwiftTerm's rendering stack, and glslang/spirv-cross integration options. Three findings reshape the original card scope:

1. **SwiftTerm already has a Metal renderer** — `MetalTerminalRenderer` with a glyph atlas and Metal shaders, enabled by setting `useMetalRenderer = true`. Holoscape has never enabled it and defaults to SwiftTerm's CoreGraphics path. We do not need to enable it for #5930; our shader compositor can coexist with either path.
2. **Vendoring glslang + spirv-cross as SwiftPM C++ targets is tractable.** Both libraries are BSD/Apache, compile cleanly on Apple Silicon, and exactly match what Ghostty does (vendored as `pkg/glslang` + `pkg/spirv-cross`). Apple's `metal-shader-converter` is a build-time tool only and does not support runtime recompile for live skin reload, so it is rejected.
3. **CI runs no tests and no build.** Only a PR-label check. Every PR is verified manually by Erik daily-driving the app. This means small PRs with clear, single-purpose diffs are significantly more important than in a normal repo — a regression in a fat PR hits Erik's daily driver immediately.

Consequence: #5930 is too large to ship as one PR. This plan slices it into **five subtasks**, each small enough to sub-agent-review and manually verify before merge.

## Scout findings, short version

- **Current terminal view hierarchy** (`Sources/Holoscape/Views/TerminalContainerView.swift:4`): a `wantsLayer=true` `NSView` that hosts one `currentContentView` (the `HoloscapeTerminalView`) via autolayout. Background is a hardcoded dark purple NSColor at `:10` and `:16` (already flagged for removal by `06-chrome-skinning.md` §2).
- **`HoloscapeTerminalView`** (`Sources/Holoscape/Views/HoloscapeTerminalView.swift:7`) is a thin subclass of SwiftTerm's `LocalProcessTerminalView` that adds unread-output notification and accessibility wiring. 40 lines total.
- **No Metal, no glslang, no C/C++ interop** anywhere in Holoscape's own code — `Package.swift` has no `cxxSettings`, no `.linkerSettings`. This PR introduces the first C++ target in the project.
- **Ghostty's pipeline** (`~/projects/github-repos/ghostty/src/renderer/shadertoy.zig`) is 427 lines. The core call sequence:
  - glslang: `glslang_shader_create` → `glslang_shader_preprocess` → `glslang_shader_parse` → `glslang_program_create` → `program.addShader` → `program.link` → `program.spirvGenerate` → `program.spirvGetPtr` / `spirvGetSize`
  - spirv-cross: `spvc_context_create` → `spvc_context_parse_spirv` → `spvc_context_create_compiler` → `spvc_compiler_create_compiler_options` → `spvc_compiler_install_compiler_options` → `spvc_compiler_compile`
  - Target: fragment shader, Vulkan 1.2 client, SPIR-V 1.5, GLSL version 430.
  - MSL options include `SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING = true`.
- **The Ghostty `shadertoy_prefix.glsl`** is 52 lines — we copy verbatim and append `05-reactive-uniforms.md` §5's extension block. See `04-ghostty-investigation.md` §A.2 for the complete uniform list.

## Architectural decisions locked in

These are my call and I'll proceed unless you override in review:

1. **Vendor glslang + spirv-cross as git submodules under `Vendor/`** at the repo root. Rationale: matches Ghostty's pattern, keeps updates trackable, reversible if we change our mind. Alternative considered and rejected: copying source into `Sources/` (hard to update) and Apple's `metal-shader-converter` (build-time only, no live reload).
2. **Compositor approach: `CAMetalLayer` sublayer on `TerminalContainerView`, sampling the terminal content view via per-frame `CARenderer` / `IOSurface` capture as `iChannel0`.** Rationale: this is the only approach that preserves Ghostty-compat shader authoring (the shader sees the terminal as a texture) without forking SwiftTerm or enabling its Metal renderer. Overhead is one GPU-side texture copy per frame, cheap on Apple Silicon's unified memory. Alternatives:
   - *Enable SwiftTerm's `useMetalRenderer` and overlay our own MTKView* — requires SwiftTerm internals that may not be public; forking SwiftTerm is off the table.
   - *Put our shader layer behind a transparent terminal view* — loses `iChannel0` semantics; shaders can't sample the terminal output.
3. **Shader reload on config change = full compositor tear-down and rebuild** in PR D. A proper FSEventStream-driven hot-swap is deferred to PR F. Rationale: tear-down/rebuild is bulletproof and small; hot-swap is a perf optimization we can add later without changing the external contract.
4. **Five subtasks of #5930**, each its own branch and PR. See below.
5. **Each PR runs the existing pre-push sub-agent review gate.** No bypass. The reviewer catches factual errors and tracker drift the way it did on PR #75.

## The five subtasks (sequence and acceptance criteria)

Filed as subtasks of #5930 before PR B starts. Card IDs assigned at filing time.

### Subtask B — Vendor glslang + spirv-cross as SwiftPM C++ targets
**Scope:** build-system only. Zero runtime behavior change.

- [ ] Add `Vendor/glslang/` and `Vendor/spirv-cross/` as git submodules pinned to specific tags (match Ghostty's pinned versions from `pkg/glslang/build.zig.zon` and `pkg/spirv-cross/build.zig.zon`).
- [ ] Add two new SwiftPM targets in `Package.swift`:
  - `.target(name: "Cglslang", path: "Vendor/glslang", cxxSettings: […], linkerSettings: […])`
  - `.target(name: "Cspirv_cross", path: "Vendor/spirv-cross", cxxSettings: […], linkerSettings: […])`
- [ ] Write `module.modulemap` files for each that expose the C headers (`glslang/Public/c_interface.h`, `spirv_cross/spirv_cross_c.h`).
- [ ] Add a unit test (`Tests/HoloscapeTests/ShaderCompilerBridgeTests.swift`) that does exactly one thing: `import Cglslang` + `import Cspirv_cross`, call `glslang_initialize_process()` and `spvc_context_create()`, assert the returned handles are non-null, tear down. This proves the link works.

**Acceptance:**
- `swift build` succeeds with no warnings.
- `swift test` passes, including the new bridge smoke test.
- `make bundle` produces a working `.app` (Erik can still launch Holoscape).
- No change to any `.swift` file under `Sources/Holoscape/` — this PR only touches `Package.swift`, `Vendor/`, `Tests/HoloscapeTests/ShaderCompilerBridgeTests.swift`, and adds new `.gitmodules` content.

### Subtask C — `ShaderCompiler` service (no rendering yet)
**Scope:** pure compilation pipeline. No Metal, no view changes.

- [ ] Create `Sources/Holoscape/Resources/ShaderPrefix/holoscape_prefix.glsl` — the Ghostty `shadertoy_prefix.glsl` verbatim + the `05-reactive-uniforms.md` §5 extension block.
- [ ] Create `Sources/Holoscape/Services/ShaderCompiler.swift` with:
  ```swift
  struct CompiledShader {
      let mslSource: String         // Metal Shading Language source text
      let uniformLayout: ShaderUniformLayout   // binding indices, byte offsets
  }
  enum ShaderCompileError: Error {
      case prefixMissing, readFailure, preprocessFailure(log: String),
           parseFailure(log: String), linkFailure(log: String),
           spirvGenerationFailed, mslTranslationFailed
  }
  @MainActor
  final class ShaderCompiler {
      func compile(glslPath: URL) throws -> CompiledShader
  }
  ```
- [ ] Implementation wraps the glslang + spirv-cross C APIs following the Ghostty sequence from the scout findings.
- [ ] Unit tests (`Tests/HoloscapeTests/ShaderCompilerTests.swift`):
  - Happy path: a trivial valid shader (`void mainImage(out vec4 f, in vec2 c) { f = vec4(1); }`) compiles and produces non-empty MSL.
  - Syntax error: intentionally broken shader returns `.parseFailure` with a non-empty log.
  - Prefix prepending: compiled output visibly contains the uniform block declarations.
- [ ] No `SkinEngine` or view wiring changes.

**Acceptance:**
- `swift test --filter HoloscapeTests.ShaderCompilerTests` passes.
- Running `ShaderCompiler().compile(...)` on the default identity shader from `05-reactive-uniforms.md` §8.1 succeeds and produces MSL text that mentions `iAgentState`.

### Subtask D — Metal compositor with `iChannel0` capture
**Scope:** the architecturally interesting PR. First pixels on screen.

- [ ] Create `Sources/Holoscape/Services/MetalCompositor.swift`:
  - Owns a `CAMetalLayer` added as a sublayer of `TerminalContainerView`.
  - Owns a `MTLDevice`, `MTLCommandQueue`, `MTLRenderPipelineState` built from the `CompiledShader.mslSource`.
  - Per-frame hook (via `CADisplayLink` started on `TerminalContainerView.viewDidMoveToWindow`): capture the terminal content view's `CALayer` to an `IOSurface`-backed `MTLTexture` via `CARenderer`, bind as `iChannel0`, run the shader as a fullscreen quad, present.
  - Populates Ghostty-compatible uniforms: `iTime`, `iResolution`, `iFrame`, and the cursor/focus/palette uniforms where SwiftTerm makes them readable. Agent-state uniforms are wired in subtask E — in this PR they are declared in the UBO but all-zero.
- [ ] Modify `TerminalContainerView` to own an optional `MetalCompositor?` and instantiate it when a shader is configured. The terminal content view renders on top of the compositor sublayer as usual; `iChannel0` capture snapshots it.
- [ ] Build-in demo shader: `Sources/Holoscape/Resources/ShaderPrefix/demos/identity.glsl` that returns `texture(iChannel0, fragCoord / iResolution.xy)` unchanged. Smoke-test target: Holoscape looks exactly the same with the compositor on as with it off.
- [ ] Second demo shader: `demos/scanlines.glsl` — CRT-style horizontal scanlines with an `iTime`-driven slow shimmer. This is the first "user-visible shader" Erik will dogfood.
- [ ] Config flag `AppearanceConfig.customShaderPath: String?` (added as optional for backward compat) points at a `.glsl` file; `nil` disables the compositor entirely.

**Acceptance:**
- With `customShaderPath = nil`, Holoscape renders identically to `main` before this PR (regression check: terminal looks normal, tab bar/sidebar/input box untouched).
- With `customShaderPath = "demos/identity.glsl"`, Holoscape renders identically to `nil` (proves the compositor is transparent when the shader is a no-op).
- With `customShaderPath = "demos/scanlines.glsl"`, Holoscape renders with CRT scanlines over the terminal text.
- Resize the window: shader keeps up, no tearing, no frozen frames.
- Switch tabs: shader continues rendering on the active channel.
- Split panes: each pane has its own compositor instance, no cross-talk.
- Erik daily-drives for a day with scanlines on. No perf regressions, no crashes.

### Subtask E — Agent-state uniforms end-to-end
**Scope:** connect the existing agent state to the shader UBO. First Holoscape-specific reactivity.

- [ ] Create `Sources/Holoscape/Services/ReactiveUniformSnapshot.swift` implementing the per-field atomic model from `05-reactive-uniforms.md` §6.2, with the upgrade-to-double-buffer code comment verbatim.
- [ ] Wire the existing agent idle/thinking/tool-use/error signal (already reported somewhere in `HoloscapeTerminalView` / channel controllers — exact path TBD during implementation) to `snapshot.agentState.store(...)` with an atomic bit-cast timestamp.
- [ ] `MetalCompositor` reads the snapshot once per frame in `updateCustomShaderUniformsForFrame`, applies the diff-and-stamp logic from `05-reactive-uniforms.md` §6.1 (every transition stamps, both directions).
- [ ] Ship `Sources/Holoscape/Resources/ShaderPrefix/demos/agent-pulse.glsl` — the red-pulse-on-error shader from `05-reactive-uniforms.md` §8.1.
- [ ] Dogfood acceptance test: trigger an agent error in a channel, verify a red pulse fades over ~0.6s.

**Acceptance:**
- `ReactiveUniformSnapshot` unit tests cover: write on one thread, read on another, transition stamps are monotonic.
- `agent-pulse.glsl` shader visibly responds to `agentState` transitions in real time.
- No chrome changes (chrome skinning is independent per `06-chrome-skinning.md` §15).

### Subtask F — Shader discovery, hot reload, compile-failure robustness
**Scope:** make the shader system usable outside the dogfood flow.

- [ ] `SkinEngine` gains shader-path resolution: `skin.json` references shaders by name, resolved against `~/.holoscape/skins/<name>/shaders/`.
- [ ] `FSEventStream` watcher on the active skin's shader directory. On file change (debounced 200ms): recompile the shader via `ShaderCompiler`. On success: atomically replace the `MTLRenderPipelineState` in the live `MetalCompositor`. On failure: log the error, post a `ShaderCompileFailed` notification, keep the previous shader running.
- [ ] In-app banner (reuses `BugReportDialog` chrome or a simpler toast) that shows shader compile errors inline so the author sees them live.
- [ ] Matches `04-ghostty-investigation.md` §A.7 robustness: log + skip, never crash, terminal still renders.

**Acceptance:**
- Edit a shader file in a text editor, save, see the change in Holoscape without restart.
- Introduce a syntax error, save, see the banner, see the previous shader still running underneath.
- Fix the error, save, banner disappears, new shader takes over.

## Critical files to modify

| File | Role | Subtask |
|---|---|---|
| `Package.swift` | Add `Cglslang`, `Cspirv_cross` C++ targets | B |
| `Vendor/glslang/` (submodule) | glslang source | B |
| `Vendor/spirv-cross/` (submodule) | spirv-cross source | B |
| `Tests/HoloscapeTests/ShaderCompilerBridgeTests.swift` | Smoke test | B |
| `Sources/Holoscape/Resources/ShaderPrefix/holoscape_prefix.glsl` | Extended prefix | C |
| `Sources/Holoscape/Services/ShaderCompiler.swift` | GLSL→MSL compiler | C |
| `Tests/HoloscapeTests/ShaderCompilerTests.swift` | Compiler tests | C |
| `Sources/Holoscape/Services/MetalCompositor.swift` | CAMetalLayer host | D |
| `Sources/Holoscape/Views/TerminalContainerView.swift` | Hosts the compositor | D |
| `Sources/Holoscape/Models/HoloscapeConfig.swift` | `customShaderPath` field | D |
| `Sources/Holoscape/Resources/ShaderPrefix/demos/*.glsl` | Demo shaders | D, E |
| `Sources/Holoscape/Services/ReactiveUniformSnapshot.swift` | Atomic snapshot | E |
| `Sources/Holoscape/Services/SkinEngine.swift` | Shader resolution + hot reload | F |

## Existing utilities / prior art to reuse

- **SwiftTerm's Metal infrastructure** (`.build/checkouts/SwiftTerm/Sources/SwiftTerm/Apple/Metal/`): *read for reference only*. We're not enabling it in #5930, but the code serves as a working example of Metal rendering inside a SwiftTerm-hosted AppKit view on macOS 15 arm64.
- **Ghostty's pipeline** (`~/projects/github-repos/ghostty/src/renderer/shadertoy.zig`): the canonical reference. Our `ShaderCompiler` follows the same call sequence and target versions. Any deviation from this needs explicit justification.
- **`SkinEngine`** (`Sources/Holoscape/Services/SkinEngine.swift`): already knows how to load skins from `~/.holoscape/skins/<name>/` with `$HOLOSCAPE_CONFIG_DIR` override. Extend it — don't create a parallel loader.
- **`AppearanceConfig`** (`Sources/Holoscape/Models/HoloscapeConfig.swift`): add `customShaderPath` here as optional, keep all existing fields untouched per the backward-compat rule in `06-chrome-skinning.md` §4.
- **The merged design docs**: `docs/skins/04-ghostty-investigation.md`, `docs/skins/05-reactive-uniforms.md`, `docs/skins/06-chrome-skinning.md`. These are authoritative — the implementation conforms to them, not the other way around.

## Verification strategy per PR

CI runs no tests, so every PR is verified manually by the sub-agent reviewer + Erik dogfooding. Standard smoke sequence for every PR:

```bash
# Build + unit tests
swift build                                                    # fast feedback
swift test                                                     # all unit tests green

# UI tests (PR D onward) — Mac Mini only, not local
ssh eriksjaastad@Eriks-Mac-mini.local 'cd holoscape && make test-ui-fast'

# App bundle sanity
make bundle
open build/Holoscape.app                                       # Erik eyeballs it

# Per-PR-specific verification (see each subtask's Acceptance section)
```

## Open questions (Erik only)

These are the decisions I want your sign-off on before PR B starts. Each can be answered with a single word or a short preference.

1. **Subtask / PR split: B → C → D → E → F as five separate PRs, each a subtask of #5930?** My strong preference. If you'd rather fuse any two (e.g. B+C into one "shader compilation" PR), say so now.
2. **Vendor layout: `Vendor/glslang/` and `Vendor/spirv-cross/` as git submodules at repo root?** Alternative: `Sources/Vendor/...` keeps everything under `Sources/` but mixes source with vendored code. Submodule-at-root matches Ghostty and is my default.
3. **Compositor approach D3 (IOSurface capture of terminal layer as `iChannel0`):** locked in per my architectural decision #2 above. Flagging for visibility — this is the biggest single commitment in the plan. If you'd rather defer this to a scope-doc-level decision (#5887), say so and I'll reshape the card scope.
4. **Should I enable SwiftTerm's `useMetalRenderer` as a separate follow-up card after #5930 ships?** Upside: lower CPU for terminal text rendering. Downside: unknown interaction with our compositor's `iChannel0` capture path. My default: **not now**, file a low-priority backlog card after the compositor is stable and measure before enabling.

## What happens after this plan is approved

1. Create subtasks B–F under parent #5930 via `pt tasks create ... --parent 5930`.
2. Start subtask B in a new branch `feat/shader-pipeline-B-vendor`.
3. Do the work, sub-agent review, PR, manual dogfood smoke test, merge.
4. Move to C. Repeat through F.
5. On F merge, close #5930 with a short summary PR that ties it all together (or mark #5930 Done with a link to the 5 constituent PRs — no extra PR needed).

---

## Implementation notes — vendoring recipe

**Captured 2026-04-15 after direct reading of `~/projects/github-repos/ghostty/pkg/glslang/build.zig` and `pkg/spirv-cross/build.zig`. These are the exact inputs cards 1–3 need, with zero re-scout required.**

### Version pinning

- **glslang**: Ghostty's `pkg/glslang/build.zig.zon` declares `.version = "14.2.0"` at the Ghostty-package level, but the override header at `pkg/glslang/override/glslang/build_info.h` pins `GLSLANG_VERSION_MAJOR = 13`, `_MINOR = 1`, `_PATCH = 1` — so the actual glslang API being compiled is **13.1.1**. Pin our submodule to the Khronos upstream tag that matches. (Verify the tag exists before filing the card — `git ls-remote https://github.com/KhronosGroup/glslang | grep 13.1.1`.)
- **spirv-cross**: Ghostty's `pkg/spirv-cross/build.zig.zon` says `.version = "13.1.1"` (coincidentally the same numeric as glslang, no relation). The upstream Khronos `SPIRV-Cross` tag is typically `sdk-1.3.xxx.y`. Cross-reference the tarball hash against upstream release notes.
- **Override header**: copy verbatim from `~/projects/github-repos/ghostty/pkg/glslang/override/glslang/build_info.h` into our repo at `Vendor/glslang-override/glslang/build_info.h`. 63 lines, just version macros.

### Exact source file lists

**spirv-cross — 7 files** (paths relative to the spirv-cross repo root):

```
spirv_cross.cpp
spirv_parser.cpp
spirv_cross_parsed_ir.cpp
spirv_cfg.cpp
spirv_cross_c.cpp
spirv_glsl.cpp
spirv_msl.cpp
```

**glslang — 41 files** (paths relative to the glslang repo root):

```
glslang/GenericCodeGen/CodeGen.cpp
glslang/GenericCodeGen/Link.cpp
glslang/MachineIndependent/glslang_tab.cpp
glslang/MachineIndependent/attribute.cpp
glslang/MachineIndependent/Constant.cpp
glslang/MachineIndependent/iomapper.cpp
glslang/MachineIndependent/InfoSink.cpp
glslang/MachineIndependent/Initialize.cpp
glslang/MachineIndependent/IntermTraverse.cpp
glslang/MachineIndependent/Intermediate.cpp
glslang/MachineIndependent/ParseContextBase.cpp
glslang/MachineIndependent/ParseHelper.cpp
glslang/MachineIndependent/PoolAlloc.cpp
glslang/MachineIndependent/RemoveTree.cpp
glslang/MachineIndependent/Scan.cpp
glslang/MachineIndependent/ShaderLang.cpp
glslang/MachineIndependent/SpirvIntrinsics.cpp
glslang/MachineIndependent/SymbolTable.cpp
glslang/MachineIndependent/Versions.cpp
glslang/MachineIndependent/intermOut.cpp
glslang/MachineIndependent/limits.cpp
glslang/MachineIndependent/linkValidate.cpp
glslang/MachineIndependent/parseConst.cpp
glslang/MachineIndependent/reflection.cpp
glslang/MachineIndependent/preprocessor/Pp.cpp
glslang/MachineIndependent/preprocessor/PpAtom.cpp
glslang/MachineIndependent/preprocessor/PpContext.cpp
glslang/MachineIndependent/preprocessor/PpScanner.cpp
glslang/MachineIndependent/preprocessor/PpTokens.cpp
glslang/MachineIndependent/propagateNoContraction.cpp
glslang/CInterface/glslang_c_interface.cpp
glslang/ResourceLimits/ResourceLimits.cpp
glslang/ResourceLimits/resource_limits_c.cpp
SPIRV/GlslangToSpv.cpp
SPIRV/InReadableOrder.cpp
SPIRV/Logger.cpp
SPIRV/SpvBuilder.cpp
SPIRV/SpvPostProcess.cpp
SPIRV/doc.cpp
SPIRV/disassemble.cpp
SPIRV/CInterface/spirv_c_interface.cpp
glslang/OSDependent/Unix/ossource.cpp
```

### Compile flags

**spirv-cross**:
- `-DSPIRV_CROSS_C_API_GLSL=1`
- `-DSPIRV_CROSS_C_API_MSL=1`
- `-fno-sanitize=undefined`
- `-fno-sanitize-trap=undefined`
- `-std=c++17` (implicit in SwiftPM when using `cxxLanguageStandard: .cxx17`)
- Include path: spirv-cross repo root.
- Link: libc, libc++.

**glslang**:
- `-std=c++17` (required for `std::variant`, `std::filesystem`)
- `-fno-sanitize=undefined`
- `-fno-sanitize-trap=undefined`
- Include paths, in this order (override shadows upstream):
  1. `Vendor/glslang-override/` (contains our pinned `glslang/build_info.h`)
  2. `Vendor/glslang/` (upstream root)
- Link: libc, libc++.
- Note: Ghostty explicitly does NOT link HLSL support. We can trim further if needed via `-DENABLE_HLSL=0`.

### SwiftPM C++ target skeleton (cards 2 and 3)

```swift
.target(
    name: "Cspirv_cross",
    path: "Vendor/spirv-cross",
    exclude: [ /* everything except the 7 sources and headers */ ],
    sources: [
        "spirv_cross.cpp",
        "spirv_parser.cpp",
        "spirv_cross_parsed_ir.cpp",
        "spirv_cfg.cpp",
        "spirv_cross_c.cpp",
        "spirv_glsl.cpp",
        "spirv_msl.cpp",
    ],
    publicHeadersPath: "include",  // directory we create containing only module.modulemap + a header
    cxxSettings: [
        .define("SPIRV_CROSS_C_API_GLSL", to: "1"),
        .define("SPIRV_CROSS_C_API_MSL", to: "1"),
        .headerSearchPath("."),
        .unsafeFlags(["-fno-sanitize=undefined", "-fno-sanitize-trap=undefined"]),
    ]
),
```

SwiftPM caveat: `publicHeadersPath` must be a directory *inside* the target's `path`, and it's used as the module's public header search path for dependents. The `module.modulemap` lives there. For glslang the override path is separate (`Vendor/glslang-override/`) and needs to be added via `.headerSearchPath("../glslang-override")` (SwiftPM resolves it relative to the target's source root).

**Module.modulemap example** (for `Cspirv_cross`):

```
module Cspirv_cross {
    header "spirv_cross_c.h"
    export *
}
```

**Package-level C++ setting**: add `cxxLanguageStandard: .cxx17` to the `Package(...)` call. Without it, SwiftPM defaults to whatever the clang toolchain picks, which may not be C++17.

### Known risks flagged for the cards

1. **`exclude:` list is mandatory** for any `path:` that contains files SwiftPM would otherwise pick up automatically (e.g. `.cpp` files in subdirectories we don't want compiled). If we don't exclude them, SwiftPM tries to compile them, and half of glslang's extra `.cpp` files (HLSL, DirectX backends) will fail to build because we excluded their supporting headers.
2. **`preprocessor/glslang.y`** is a yacc source file — Ghostty's comment notes this, and the pre-generated `glslang_tab.cpp` is what we actually compile. Make sure the submodule's preprocessor directory contains `glslang_tab.cpp` pre-generated; if upstream only ships the `.y` source, we need to generate it manually and vendor the result. Check before filing card 3.
3. **glslang's `OSDependent/Unix/ossource.cpp`** is the only platform file we compile. If the build complains about missing threading primitives, it's likely pulling from the wrong platform subdirectory.
4. **spirv-cross's `spirv_msl.cpp`** is ~20k lines and takes a noticeable fraction of build time. Not a correctness risk, just a "first compile is slow" note.
5. **Apple SDK paths**: SwiftPM with `.macOS(.v15)` should auto-inject the SDK into C++ targets, but Ghostty explicitly calls `apple_sdk.addPaths(b, lib)` in its Zig build, suggesting it isn't free in Zig-land. If our first SwiftPM C++ build fails with missing `<sys/types.h>` or similar, we need to investigate whether SwiftPM needs explicit `.linkerSettings(.unsafeFlags(["-isysroot", ...]))`.

### Ghostty's glslang target config (Vulkan 1.2 / SPIR-V 1.5 / GLSL 430)

When card 4 (ShaderCompiler) wires the compile call, these are the non-obvious parameters from `shadertoy.zig`:

```
// glslang_input_t
.language = GLSLANG_SOURCE_GLSL
.stage = GLSLANG_STAGE_FRAGMENT
.client = GLSLANG_CLIENT_VULKAN
.client_version = GLSLANG_TARGET_VULKAN_1_2
.target_language = GLSLANG_TARGET_SPV
.target_language_version = GLSLANG_TARGET_SPV_1_5
.default_version = 100
.default_profile = GLSLANG_NO_PROFILE
.force_default_version_and_profile = 0 (false)
.forward_compatible = 0 (false)
.messages = GLSLANG_MSG_DEFAULT_BIT
.resource = (default resource limits — use glslang_default_resource())
```

spirv-cross MSL options (the one that matters):
```
SPVC_COMPILER_OPTION_MSL_ENABLE_DECORATION_BINDING = 1
```

This makes spirv-cross honor `layout(binding = N)` from GLSL when emitting MSL buffer/texture indices — without it, MSL bindings get reassigned by spirv-cross and our Swift-side buffer binding code breaks.

---

## Tonight's session plan — Cards 1 + 2 only, with a hard stop rule

**Scope for this session:** execute **Card 1 (#5938 vendoring prep)** to completion, then execute **Card 2 (#5939 Cspirv_cross SwiftPM target)** with a hard "30-minute stop rule" on SwiftPM C++ build failures. Stop after Card 2 regardless of whether it succeeded.

Card 3 (#5940 Cglslang) explicitly **not** attempted tonight — too much surface area on top of a context window that's already deep from all the design-doc work earlier in the session.

### Upstream version pins (verified upstream)

- **glslang submodule**: pin to tag `13.1.1` = commit `36d08c0d940cf307a23928299ef52c7970d8cee6`. Verified via `git ls-remote https://github.com/KhronosGroup/glslang 13.1.1`. Also confirmed `glslang_tab.cpp` is pre-generated (Bison output committed) at this tag, so we do **not** need to run yacc/bison during card 3's build — one risk from the recipe notes is resolved.
- **spirv-cross submodule**: pin to **`sdk-1.3.239.0`** (or later stable). Ghostty's exact tarball hash doesn't map directly to an upstream tag, so pick the most recent stable SDK tag that's close in time to Ghostty's pin. If card 2 hits ABI compatibility issues with our source files, try an earlier or later SDK tag. **This is the one version decision I want to defer to card 1 execution** — I'll confirm the exact tag at commit time based on whatever upstream SDK release looks most robust.

### Card 1 — Vendoring prep (#5938)

**Target: under 1 hour, zero risk to `main`.**

Steps in order:

1. Branch: `feat/shader-pipeline-1-vendoring`.
2. `git submodule add https://github.com/KhronosGroup/glslang Vendor/glslang` then `cd Vendor/glslang && git checkout 13.1.1 && cd ../..`.
3. `git submodule add https://github.com/KhronosGroup/SPIRV-Cross Vendor/spirv-cross` then checkout the chosen `sdk-1.3.*` tag.
4. Create `Vendor/glslang-override/glslang/build_info.h` by copying verbatim from `~/projects/github-repos/ghostty/pkg/glslang/override/glslang/build_info.h`. Verify the copy is byte-identical with `diff`.
5. `swift build` — must still succeed unchanged. No Package.swift changes, so SwiftPM shouldn't even notice the new files.
6. `make bundle` — sanity check the app still assembles.
7. Commit, sub-agent review, push, PR, merge. Single-commit PR.

**Expected diff:** new `.gitmodules` file (2 entries), `Vendor/glslang-override/glslang/build_info.h` (63 lines). No other changes. The submodules themselves show up in git as `160000` gitlink entries but are not "copied" into the main repo tree.

**Failure modes I'll watch for:**
- glslang or spirv-cross tag pin failing to check out (should not happen — verified both tags exist).
- `.gitmodules` somehow interacting badly with the existing `.git` directory (unlikely, this repo has no prior submodules).
- `swift build` picking up the new files and trying to compile them (should not happen — the new targets aren't referenced in Package.swift). If this happens, investigate why SwiftPM auto-discovered them before adding explicit `exclude:` rules.

**Sub-agent review focus for card 1:** is the override header byte-identical to Ghostty's, are the submodule pins at resolvable upstream tags, does `swift build` really still work.

### Card 2 — Cspirv_cross SwiftPM target + smoke test (#5939)

**Target: under 2 hours, with a hard 30-minute stop rule on unresolved build failures.**

Steps in order:

1. Branch: `feat/shader-pipeline-2-cspirv-cross`.
2. Edit `Package.swift`: add `cxxLanguageStandard: .cxx17` at the package level if it's not already there.
3. Add a new `.target` entry for `Cspirv_cross` following the skeleton in the "SwiftPM C++ target skeleton" section above. Use `publicHeadersPath: "include"` and create `Vendor/spirv-cross/include/module.modulemap` alongside a forwarding header that re-exports `spirv_cross_c.h` from the repo root.
4. List exactly the 7 source files from the recipe. Add `exclude:` for any other `.cpp` in `Vendor/spirv-cross/` that SwiftPM would otherwise auto-compile — use `find Vendor/spirv-cross -name "*.cpp" -maxdepth 2` to enumerate.
5. Add `Cspirv_cross` to the `HoloscapeTests` target's dependencies list.
6. Write `Tests/HoloscapeTests/ShaderCompilerBridgeTests.swift` with one test: import `Cspirv_cross`, call `spvc_context_create(&ctx)`, assert non-null, call `spvc_context_destroy(ctx)`. 15 lines of Swift.
7. `swift build` — the first time it compiles 7 C++ files, expect slow. Watch the build log for warnings; silence non-fatal ones via `.unsafeFlags(["-Wno-..."])` only if absolutely necessary and document each suppression in the PR body.
8. `swift test --filter HoloscapeTests.ShaderCompilerBridgeTests` — must pass.
9. `make bundle` — must still produce a runnable `.app`.
10. Sub-agent review with special focus on: (a) the exclude list correctness, (b) any unsafe flags and whether they're justified, (c) the smoke test actually exercising the linked library.
11. Push, PR, merge. Erik dogfoods the merged `.app` briefly to confirm no regression.

**The 30-minute stop rule:**

If `swift build` fails on card 2 with a SwiftPM or clang error I can't resolve within **30 minutes of targeted poking**, I stop immediately. I do not loop on build-system errors.

"Stop" means:
- Keep the branch alive locally (no `git branch -d`) with whatever partial work is committed.
- Add a new subsection to this plan file at the bottom titled **"Card 2 stop notes — YYYY-MM-DD"** capturing:
  - The exact build command that failed
  - The exact error message (verbatim, with line numbers)
  - Every hypothesis I tried and why I rejected it
  - The current state of `Package.swift` and the modulemap
  - The hypothesis I'd test next in a fresh session
- Reset task #5939 to `To Do` status (not Done, not In Progress).
- Tell Erik I'm stopping card 2 at the 30-minute mark, surface the stop notes, and recommend a fresh session.
- Do **not** attempt any more work in the current session.

**Why the 30-minute rule:** SwiftPM C++ interop errors are notorious for looking fixable when they aren't, and for costing hours of trial-and-error before the actual root cause surfaces. A fresh session with a clean context can often solve in 15 minutes what a tired session takes 3 hours on. The rule protects against sunk-cost reasoning.

**What counts as "targeted poking"**: making one specific hypothesis-driven change to `Package.swift` or the modulemap, rebuilding, reading the error, forming a new hypothesis. At most 5-6 such cycles before the 30-minute timer fires.

**What does NOT count as "fixing"**: copying random `cxxSettings` from Stack Overflow, disabling errors with `-w`, excluding source files until the build passes but the smoke test fails. These are anti-patterns — if I'm tempted, the rule fires immediately.

### What I expect to report at end of session

**Best case** (both cards ship):
- PR N merged: #5938 vendoring prep
- PR N+1 merged: #5939 Cspirv_cross target, smoke test green
- The vendoring pattern is proven for card 3 next session
- Sub-agent reviews all PASS

**Likely case** (card 1 ships, card 2 hits some SwiftPM friction but resolves within the budget):
- Two PRs merged
- Plan file updated with any learnings about SwiftPM C++ target config that should inform card 3

**Worst-acceptable case** (card 1 ships, card 2 hits the stop rule):
- One PR merged (card 1)
- Card 2 branch preserved with partial work
- Plan file updated with "Card 2 stop notes" section
- Clean handoff for next session
- No damage to `main`

**Unacceptable outcomes to prevent:**
- Merging a broken Package.swift that breaks Erik's `swift build`.
- Spending >3 hours on card 2 without either shipping it or stopping cleanly.
- Suppressing real build errors with `-w` or exclusions to force a green test.
- Merging card 2 without a passing smoke test that actually links against the library.

### Post-session cleanup

Regardless of outcome, before ending the session:
- Working tree clean on `main` (or on the stopped card-2 branch if that's where we ended).
- All opened PRs either merged or closed with explanatory comment.
- Task tracker accurately reflects state (nothing stuck in "In Progress" that isn't actively being worked).
- This plan file captures anything learned that the next session needs.
