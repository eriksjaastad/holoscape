# Holoscape — Session Handoff (2026-04-15 early AM)

## Read this first
- Branch: `main` at `f565d79`. Working tree clean.
- 260 tests pass. `make bundle` produces a working `.app`.
- Erik is dogfooding Holoscape as his daily driver. Every merge hits production. Small PRs, single concern, sub-agent review before every push.
- The full implementation plan for the shader pipeline lives at `~/.claude/plans/immutable-jingling-brooks.md`. **Read that plan before touching the shader work.** It has:
  - The 8-card carve of #5930 with exact sources lists and compile flags.
  - The vendoring recipe with verified upstream pins.
  - Tonight's session plan with the architectural lessons learned in cards 1 and 2.

## What shipped this session

### Design docs (morning)
- PR #72 — `04-ghostty-investigation.md` second pass + A.4 agent-state uniform design
- `1bbc3e0` direct to main — `DIRECTION.md`
- PR #73 — `01-research` §6 correction (drops the "scene graph / reactivity" framing)
- PR #74 — `05-reactive-uniforms.md` (graduated from A.4)
- PR #75 — `06-chrome-skinning.md` (the real Winamp layer, v2 of the existing shallow SkinEngine)

### Shader pipeline implementation (evening)
- PR #76 — **Card 1 #5938 Done** — vendoring prep: glslang + spirv-cross as submodules + override header
- PR #77 — **Card 2 #5939 Done** — `Cspirv_cross` SwiftPM target + link smoke test (first C++ in the project)

## Where the #5930 shader pipeline stands

| # | Card | State | Notes |
|---|---|---|---|
| 1 | #5938 — Vendoring prep | ✅ Done (PR #76) | Submodules at `Vendor/glslang` (13.1.1) and `Vendor/spirv-cross` (sdk-1.3.239.0); override header at `Vendor/glslang-override/glslang/build_info.h` |
| 2 | #5939 — Cspirv_cross target | ✅ Done (PR #77) | First C++ target, 7 sources, smoke test links |
| 3 | #5940 — Cglslang target | 🔜 **Ready to start** | Pattern from card 2 applies. See below. |
| 4 | #5941 — ShaderCompiler service | Blocked on #5940 | GLSL→SPIR-V→MSL wrapped in Swift |
| 5 | #5942 — Metal compositor + identity | Blocked | First pixels on screen; biggest card (~3-4h) |
| 6 | #5944 — Config + scanlines demo | Blocked | First user-visible effect |
| 7 | #5945 — Agent-state reactivity + red-pulse | Blocked | ReactiveUniformSnapshot + demo shader |
| 8 | #5946 — Discovery + hot reload + banner | Blocked | Closes #5930 |

## Start-of-day procedure for tomorrow

1. `git status && git log --oneline -5` — confirm main at `f565d79`, clean tree.
2. `pt tasks -p holoscape | grep "Shader pipeline"` — confirm 5938 and 5939 are Done, 5940 is the next ready card.
3. **Read `~/.claude/plans/immutable-jingling-brooks.md` from top to bottom.** It has everything. Especially:
   - §"Implementation notes — vendoring recipe" for glslang's 41 source files and compile flags
   - §"Card 3 — Cglslang SwiftPM target" for the specific steps
   - The "Architectural lessons from cards 1 and 2" (captured below — if those haven't been added to the plan by morning, they should be)
4. Start card 3 via `pt tasks update 5940 --status "To Do" && pt tasks start 5940`.
5. Branch: `feat/shader-pipeline-3-cglslang`.

## Architectural lessons from cards 1 and 2 (read before card 3)

These were discovered experimentally during card 2. Card 3 reuses the same pattern.

### The symlink shim directory pattern

**Why a shim exists.** SwiftPM requires a target's sources and modulemap to live under its `path:`. Git refuses to track files inside a submodule from the outer repo (`fatal: Pathspec is in submodule` — verified). So we can't just put the modulemap at `Vendor/spirv-cross/module.modulemap` and commit it. The solution is a repo-owned directory (`Vendor/Cspirv_cross/`) full of symlinks pointing into the submodule, plus a real modulemap.

**Layout for card 2:**
```
Vendor/Cspirv_cross/          ← committed repo-owned dir
├── spirv_*.cpp                 ← 7 symlinks into ../spirv-cross/
└── include/
    ├── module.modulemap        ← real file, 4 lines
    ├── spirv_cross_c.h         ← symlink
    └── spirv.h                 ← symlink (transitive include)
```

**Card 3 needs the same structure** at `Vendor/Cglslang/` with 41 source symlinks plus however many transitive headers glslang's C API pulls in. Start with `glslang/Public/ShaderLang.h` and `glslang/Public/resource_limits_c.h` at minimum, then add more as compile errors surface.

### Clang's symlink-path quirk

When processing quote-form `#include "foo.h"`, clang uses **the symlink path, not the realpath**, as the "current file's directory" for the first-search. This bit us on card 2: `spirv_cross_c.h` was symlinked into `include/`, clang processed it via the symlink path, then looked for `spirv.h` next to the symlink — not next to the realpath. Result: "`spirv.h` file not found."

**Fix: every transitively-referenced header must also be symlinked into the same shim `include/` directory as the entry-point header.** No shortcuts. Card 3 may need to symlink several glslang headers.

### SwiftPM `publicHeadersPath` is the only include path for Swift consumers

`cxxSettings.headerSearchPath(...)` affects only the C++ target's own compilation. When Swift imports the module, clang uses only the `publicHeadersPath` as the include root. That's why the shim pattern needs transitive headers symlinked — we can't rely on a `headerSearchPath` workaround for consumer builds.

### `.headerSearchPath("../...")` is allowed

`cxxSettings.headerSearchPath("../spirv-cross")` does work — SwiftPM allows parent-directory escapes in `cxxSettings` even though they look like they violate the target path. This lets the C++ target reach into the real submodule for its own internal transitive includes during compilation. Card 3 will want `.headerSearchPath("../glslang")` and `.headerSearchPath("../glslang-override")` (in that order, override first so `build_info.h` shadows).

### `cxxLanguageStandard: .cxx17` at package level

Both glslang and spirv-cross require C++17. Set this once at the `Package(...)` level, not per-target. Already set in `Package.swift` from card 2.

### Known risks re-confirmed for card 3

- `glslang_tab.cpp` is **pre-generated** at upstream tag 13.1.1 (I verified via `curl` during planning). No yacc/bison runtime dependency.
- glslang's source tree has many `.cpp` files NOT in our 41-file list (HLSL backends, DirectX, Windows ossource, tests, etc.). We likely don't even need an `exclude:` list if the shim directory strategy works — only the 41 symlinked files exist in `Vendor/Cglslang/`. But if SwiftPM somehow finds auto-discovered sources, add excludes.
- Apple SDK paths: not an issue on card 2, so probably fine for card 3. If not, add `.linkerSettings(.unsafeFlags(["-isysroot", ...]))`.

## Other work parked (do not pivot without Erik's say-so)

- **2026-04-12 backlog cluster** — New Channel UX (#5862–#5868), permissions audit (#5870–#5871), notifications (#5873), etc. Still valid as a backlog map but we're in skin-system mode until #5930 wraps.
- **General-bucket spikes (Low priority Backlog)** — #5931 Command Palette, #5932 Global Keybinds, #5933 Splits, #5934 NSTextInputClient, #5935 threading audit, #5936 stale-tab badge. All sitting in Backlog. They are follow-ups to the ghostty investigation's Part B; none feed #5930.

## Housekeeping

- No open PRs.
- No stale branches.
- No in-progress cards (5939 just moved to Done).
- Task tracker shows 5940 as ready-to-pick-up (`[B:5940]` blocker cleared when 5939 went Done).

## First moves tomorrow

1. Confirm clean state (step 1 above).
2. Re-read the plan file (step 3 above).
3. Pre-flight card 3:
   - What does the code do now? Cspirv_cross compiles and links. Nothing for Cglslang yet.
   - Why? Card 2 proved the pattern; card 3 applies it to the bigger library.
   - What am I changing? Adding `Vendor/Cglslang/` shim with symlinks to 41 glslang sources, plus `include/` with modulemap and transitive headers. New SwiftPM target. New test method in `ShaderCompilerBridgeTests.swift` that calls `glslang_initialize_process()`.
4. Start the branch, proceed through the plan, sub-agent review, push, merge.
5. After card 3 merges, move to card 4 (ShaderCompiler — that's where Swift code finally starts wrapping the C APIs).
