Entry point for every agent session in this repository. Read it once at task start; reread changed or newly relevant sections when needed. The repository copy is canonical; its Notion mirror follows it. Task handoffs record decisions and exceptions instead of copying this policy.

# 1. Project facts

- **Project:** `c3d`, a scene-level 3D rendering library with an ECS scene, physics, animation, and asset import. Not a game engine; a base for one.
- **Language:** C3 **0.8.3**. C3 is pre-1.0. Verify syntax against the installed compiler and the `c3-expert` skill, never against memory of another version.
- **Shading language:** GLSL, Vulkan 1.3 semantics through gpu.c3l. Files are `<name>.<stage>.glsl`; shared includes are plain `.glsl`. The includes listed under `public_includes` in `shaders/variants.json` are the stable contract for custom and package stages. SPIR-V is built offline by `scripts/build_shaders.py`, for core and for every shader package (a directory with `shaders/shaders.json`), and embedded with `$embed`.
- **Module root:** `c3d`. Every module is `c3d` or a submodule of it (`c3d::render`, `c3d::asset::gltf`). The repository directory name never appears in source.
- **Build tooling:** `scripts/build.py` is the entry point; it drives ABI codegen, shader compilation, `c3c build`, and optionally `c3c test` and `c3c run`. Python 3.10+ standard library only, under `scripts/`, only for build orchestration and code generation.
- **Dependencies** (git submodules under `lib/`, pinned, plus project add-ons linked there):

| Library | Module | Imported only by |
| --- | --- | --- |
| gpu.c3l | `gpu` | `c3d::render` and its submodules, including the gated add-on `c3d::render::profile_gpu`, `c3d::shader`, `c3d::gui::backend`; `c3d::platform` may import `gpu::surface` only |
| sdl3.c3l | `sdl` | `c3d::platform` |
| c3imgui.c3l | `imgui` | `c3d::gui` |
| c3cg.c3l | `cg` | `c3d::geometry` |
| box3d.c3l | `b3` | `c3d::physics` and its submodule `c3d::physics::collide`, which live in `addons/c3d_physics.c3l`; core never imports it |
| cgltf.c3l | `gltf` | `c3d::asset::gltf` |
| stb_image (C source) | `c3d::asset::image` bindings | `c3d::asset::image` |
| stb_truetype (C source) | `c3d::asset::truetype` bindings | `c3d::asset` |
| ufbx.c3l | `ufbx` | `c3d::asset::fbx` |
| shaderc.c3l | `shaderc` | `c3d::shader::compile` (`src/c3d/shader/compile.c3`), compiled only under the `C3D_SHADER_COMPILER` feature |
| c3d_profile.c3l | `c3d::profile`, private `c3d::render::profile_gpu` | Applications select it explicitly; core imports it only through the gated CPU and GPU bridges; `c3d::job` imports it only under `C3D_PROFILE_CPU` |
| c3d_profile_gui.c3l | profiler additions to `c3d::gui` | Applications select it explicitly; it imports only the standard library, `c3d::profile` and `imgui` |
| c3d_physics.c3l | `c3d::physics`, `c3d::physics::collide`, `c3d::physics::cloth` | Applications select it explicitly; it imports the standard library, `c3d` and `b3`, plus `c3d::serial` under `C3D_PHYSICS_SERIAL` |
| c3d_nav.c3l | `c3d::nav` | Applications select it explicitly; it imports the standard library and `c3d`, plus `c3d::serial` under `C3D_NAV_SERIAL` |
| c3d_character.c3l | `c3d::character` | Applications select it explicitly; it imports the standard library, `c3d` and `c3d::physics`, and `c3d::nav` under `C3D_CHARACTER_NAV`, plus `c3d::serial` under `C3D_CHARACTER_SERIAL` |
| c3d_physics_gui.c3l | physics additions to `c3d::gui` | Applications select it explicitly; it imports the standard library, `c3d`, `c3d::physics` and `imgui`, and `c3d::character` only under `C3D_PHYSICS_GUI_CHARACTER` |
| c3d_job.c3l | `c3d::job` | Applications select it explicitly; it imports the standard library and `c3d`, and `c3d::profile` only under `C3D_PROFILE_CPU`, and declares `@private` externs for libc and kernel32 processor-affinity calls |
| c3d_landscape.c3l | `c3d::landscape`, `c3d::landscape::terrain`, `c3d::landscape::foliage`, `c3d::landscape::water` | Applications select it explicitly; it imports the standard library, `c3d` and `c3d::serial` only under `C3D_LANDSCAPE_SERIAL` |
| c3d_particle.c3l | `c3d::particle` | Applications select it explicitly; it imports the standard library, `c3d` and `c3d::serial` only under `C3D_PARTICLE_SERIAL` |
| c3d_serial.c3l | `c3d::serial` | Applications select it explicitly; it imports the standard library and core, never renderer or platform dependencies directly; `c3d::particle` imports it only under `C3D_PARTICLE_SERIAL`, and `c3d::landscape` only under `C3D_LANDSCAPE_SERIAL` |
| clay.c3l | `clay` | `c3d::ui`, in `addons/c3d_ui.c3l`; core never imports it |
| c3d_ui.c3l | `c3d::ui` | Applications select it explicitly; it imports the standard library, `c3d` and `clay` |
| miniaudio.c3l | `ma` | `c3d::audio`, in `addons/c3d_audio.c3l`; core never imports it |
| c3d_audio.c3l | `c3d::audio` | Applications select it explicitly; it imports the standard library, `c3d` and `ma` |

Boundaries are checked at review. No dependency is added without updating this table.

`c3d::asset::gltf` provides opt-in source inspection alongside its store-free document: independent encoded images, source indices, sampler values and extension names. Ordinary decoding is unchanged. See `docs/gltf_source.md` for ownership and fidelity.

The `addons/c3d_profile.c3l` package bundles CPU/GPU capture, history and export. Its neutral `c3d::profile` module imports only the standard library. Its private `c3d::render::profile_gpu` module, under `src/gpu/` and gated by `C3D_PROFILE_GPU`, imports only the standard library, gpu.c3l and neutral profile values; it never imports core types. Core's approved profiler bridges are `c3d::instrumentation` for CPU+INTERNAL and `render/profile.c3` for GPU. Core has no unconditional profiler dependency; instrumented consumers select the collector add-on explicitly. The `addons/c3d_profile_gui.c3l` presentation adapter extends `c3d::gui` under `C3D_PROFILE_GUI`; it consumes neutral capture data and ImGui and is never imported by core or the collector. Standalone CPU collector builds need no native/shader setup. GUI consumers select ImGui and Vulkan bindings explicitly, while GPU data tests additionally select backend dependencies; neither data-test project creates a device.

The `addons/c3d_physics.c3l` package owns rigid-body physics: the box3d world, bodies bound to scene nodes, cooked collision data and frame event lists, pre-fractured hull assemblies with owned breakable welds, explicit physical pieces with multiple hulls and indexed read-only piece/weld authoring views, position-based cloth over owned geometry copies with one-way sphere and capsule contacts against listed bodies (`c3d::physics::cloth`, which imports the standard library, core and `c3d::physics`), buoyancy against a fluid surface the application installs (`set_fluid_surface`), and the world-free collision queries of `c3d::physics::collide` (manifolds, distance, casts, time of impact, ray casts against one shape). Its `c3d::physics` module imports the standard library, core (`c3d`) and `b3`, never `gpu`, `sdl` or `imgui`. Core never imports it and carries no physics feature flag; selecting the library is the gate. Its `src/serial/` adapter imports `c3d::serial` only under `C3D_PHYSICS_SERIAL`; consumers select `c3d_serial` explicitly. `physics_serial_test` and the isolated `physics_serial_policy_test` run alongside the feature-off tests in `scripts/build.py --test`. The package owns its `project.json`, `physics_test` target, the manual `test/gpu` acceptance project with its `cloth_acceptance` target, and `physics`, `physics_instanced`, `physics_components`, `vehicle`, `ragdoll`, `collision_math`, `breakable` and `cloth` examples.

Fracture generation is maintained in the standalone [c3d_fracture.c3l](https://github.com/fesoliveira014/c3d_fracture.c3l) project under the `fracture` namespace, with c3d as a dependency. The physics package retains generic authored Breakable pieces, multi-hull collision, preparation, welds and read-only authoring views. Core retains store-free glTF source inspection. See `docs/fracture.md` for the project boundary.

`Breakable` is a pointer-sized physics component whose state block owns captured piece IDs, graph edges and runtime storage. Its public `Weld.joint` is an approved read-only `b3::JointId` escape hatch alongside the existing physics body/joint handles; applications do not mutate owned welds through it. The package README documents fracture authoring, lifetime, wake and reporting contracts.

The `addons/c3d_nav.c3l` package owns navigation meshes, a port of Recast/Detour (`recastnavigation` at `9f4ce64`, zlib; the notice ships in the package). Its `c3d::nav` module imports the standard library and core (`c3d`), never `gpu`, `sdl`, `imgui`, `b3` or `c3d::physics`. Core never imports it and carries no navigation feature flag; selecting the library is the gate. Its `src/serial/` adapter imports `c3d::serial` only under `C3D_NAV_SERIAL`; consumers select `c3d_serial` explicitly. `nav_serial_test` and the isolated `nav_serial_policy_test` run alongside the feature-off `nav_test` in `scripts/build.py --test`. The package owns its `project.json`, `nav_test` target and `navmesh`, `crowd` and `grid` examples.

The `addons/c3d_character.c3l` package owns the kinematic capsule character controller built on the physics package's mover primitives: the `Character` component, the `CharacterSystem` that installs the physics world's mover pass, the kinematic push body and debug drawing. Its `c3d::character` module imports the standard library, core (`c3d`) and `c3d::physics`, never `b3`, `gpu`, `sdl` or `imgui`. Under `C3D_CHARACTER_NAV`, `src/nav/` adds the crowd binding (`NavDriven`, `drive_characters`) and imports `c3d::nav`; a consumer that enables the feature also selects `c3d_nav`, and the plain targets build without it. Core, the physics package and the nav package never import it and core carries no character feature flag; selecting the library is the gate. Its `src/serial/` adapter imports `c3d::serial` only under `C3D_CHARACTER_SERIAL`, which requires `C3D_PHYSICS_SERIAL`; navigation-enabled serialization also requires `C3D_NAV_SERIAL`. Consumers select `c3d_serial` explicitly. Feature-on adapter and independent policy targets run with and without navigation in `scripts/build.py --test`. The package owns its `project.json`, `character_test` and `character_nav_test` targets and `character` and `character_nav` examples.

The `addons/c3d_physics_gui.c3l` package is the physics inspector: under `C3D_PHYSICS_GUI` it extends `c3d::gui` with the physics panel (world tuning, pause and step, counters, step profile, debug-draw flags, bodies, the selected node, events, queries, recording and replay) and the inspectors of the physics components. It imports the standard library, core (`c3d`), `c3d::physics` and `imgui`, never `b3`, `gpu` or `sdl`. Under `C3D_PHYSICS_GUI_CHARACTER`, `src/character/` adds the characters table, the character block and the `Character` inspector and alone imports `c3d::character`; a consumer that enables that feature also selects `c3d_character`. Its manifest names no dependency; consumers select `c3d_physics`, ImGui and the rest. Core, the physics package and the character package never import it. The package owns its `project.json`, the `physics_panel_off`, `physics_panel` and `physics_panel_character` targets and the `physics_inspector` and `physics_inspector_character` examples.

The `addons/c3d_job.c3l` package owns the fork-join job pool: a fixed set of worker threads running a function over index ranges in frame and background classes, with inline execution at zero workers, and the processor sets its workers bind to. Its `c3d::job` module imports the standard library and core (`c3d`), never `gpu`, `sdl`, `imgui`, `b3` or another add-on, except `c3d::profile` under `C3D_PROFILE_CPU`. Its platform files (`src/affinity_linux.c3`, `src/affinity_win32.c3`) declare `@private` externs for the libc and kernel32 calls the standard library already links (`sched_getaffinity`, `sched_setaffinity`, `SetThreadGroupAffinity`, `GetThreadGroupAffinity`, `GetActiveProcessorCount`, `GetActiveProcessorGroupCount`, `GetLogicalProcessorInformationEx`), with their native structs pinned by `$assert`; no other module declares system externs. Under `C3D_PROFILE_CPU`, `src/profile.c3` adds the worker range records and their forwarding into a recorder and alone imports `c3d::profile`; a consumer that enables the feature also selects `c3d_profile`. Core never imports it and carries no job feature flag; selecting the library is the gate. The package owns its `project.json`, `job_test` and `job_profile_test` targets and `job_bench` example.

The `addons/c3d_landscape.c3l` package owns height-field terrain: the `Terrain` component over an `R16_UINT` height map, drawn as the node's own instanced batch of quadtree chunks through a custom material, with CPU height queries on the physics height-field convention. Its root module `c3d::landscape` holds the generated constants of its shader package and the optional `src/serial/` adapter, which imports `c3d::serial` only under `C3D_LANDSCAPE_SERIAL`; `c3d::landscape::terrain` imports the standard library and core (`c3d`), never `gpu`, `sdl`, `imgui`, `b3`, `c3d::shader`, `c3d::render` or another add-on. It also owns vegetation: `c3d::landscape::foliage` scatters one geometry and material per `Foliage` layer over a terrain node into per-cell instanced batches drawn with core sway and fade, and imports the standard library, core and `c3d::landscape::terrain`, never `gpu`, `sdl`, `imgui`, `b3`, `c3d::shader`, `c3d::render` or another add-on. It also owns water: `c3d::landscape::water` draws a Gerstner surface through an owned custom material with scene reads, places a mirror camera per water body for the application's mirror view, and answers CPU height queries; it imports the standard library, core and `c3d::landscape::terrain`, never `c3d::physics`. Core never imports it and carries no terrain feature flag; selecting the library is the gate. The package owns its `project.json`, `landscape_test` target (which selects `c3d_physics` for the height equality test), the manual `test/gpu` acceptance project with its `terrain_acceptance` and `water_acceptance` targets, and the `terrain`, `vegetation` and `water` examples. Serialization consumers also select `c3d_serial`; `landscape_serial_test` and the isolated `landscape_serial_policy_test` run alongside the unchanged feature-off `landscape_test` in `scripts/build.py --test`.

The `addons/c3d_particle.c3l` package owns fixed-pool CPU particle simulation, emitters, lifetime tables and depth-reading effect materials. Its `c3d::particle` module imports the standard library and core, never `gpu`, `sdl`, `imgui`, physics or the render/shader-compiler modules. Core supplies generic billboard and mesh batches and never imports the particle package. The package owns `particle_test`, the `particles` example and a separate manual `test/gpu` acceptance target. The example selects the profiler collector explicitly for GPU timing; the simulation package does not depend on it. Its `src/serial/` adapter imports `c3d::serial` only under `C3D_PARTICLE_SERIAL`; consumers select `c3d_serial` explicitly. `particle_serial_test` and the isolated `particle_serial_policy_test` run alongside the unchanged feature-off `particle_test` in `scripts/build.py --test`.

The `addons/c3d_serial.c3l` package owns the portable subtree container and explicit component codec registry. It imports the standard library and core and never creates GPU resources or native systems. Core never imports it. The particle, landscape, physics, navigation and character packages import it only through their `C3D_PARTICLE_SERIAL`, `C3D_LANDSCAPE_SERIAL`, `C3D_PHYSICS_SERIAL`, `C3D_NAV_SERIAL` and `C3D_CHARACTER_SERIAL` adapters. The package owns `serial_test`, `serial_order_forward`, `serial_order_reverse`, `serial_text_test`, `serial_described_test`, `serial_core_policy_test` and `serial_all_test`; `scripts/build.py --test` runs them. Its explicit `serial_lookup_bench` target stays outside that test sequence. `register_core_codecs` installs all 18 built-in component policies and their description/default prerequisites idempotently; the independent policy target first checks registration without a Scene, then creates a Scene and classifies every assigned slot against the expected policies. New unclassified core components fail the inventory. The combined target selects every serialization adapter and checks all 50 registered policies alongside the existing independent package inventories. See `docs/serialization.md` for the wire format, ownership, rollback and current codec coverage.

Core `c3d::describe` owns synchronous field visitors and process-lifetime type descriptions. It imports only the standard library and core, never GUI, serialization or backend libraries. Struct descriptions are registered explicitly; only component descriptions consume ECS slots. The Scene panel consumes their slot table in `c3d::gui`, with custom inspectors taking precedence. `register_core_components` idempotently installs the Mesh, Camera, Light, ProbeVolume, Atmosphere, HeightFog, ReflectionProbe and Decal descriptions and their nested types. The serialization add-on consumes descriptions through its separate codec registry; core never imports it. See `docs/type_descriptions.md` for registration, fresh-read ownership, reconstruction hooks and schema traversal.

The `addons/c3d_ui.c3l` package owns game UI: retained JSONC documents with styles (single inheritance, state blocks, ordered sheets), data bindings that code registers (getters, member tags, list scopes) and named actions, laid out with Clay every frame, routed against the previous frame's layout, and drawn into an `OverlayList` as rectangles and glyph runs. Its `c3d::ui` module imports the standard library, core (`c3d`, including `c3d::render` for the overlay list and `c3d::platform` for input and events) and `clay`, never `gpu`, `sdl`, `imgui` or another add-on. ImGui and the UI share the GUI capture flags and `Input.text_input_wanted_by_gui`; a frame without ImGui calls `Input.clear_gui_flags()` first. Core never imports it and carries no UI feature flag; selecting the library is the gate. The package owns its `project.json`, `ui_test` target, the manual `test/gpu` acceptance project with its `ui_acceptance` target, and the `ui` example. See `addons/c3d_ui.c3l/README.md` for the document schema and frame order.

The `addons/c3d_audio.c3l` package owns audio playback over miniaudio: the `AudioClip` store kind (encoded WAV, FLAC, MP3 or Ogg Vorbis bytes with a probed format), the `AudioSystem` with its named buses, voice table and per-clip mirrors, the `AudioEmitter` and `AudioListener` scene components with remove hooks bound to the system, and the null-device `mix` path that tests use. Its `c3d::audio` module imports the standard library, core (`c3d`) and `ma`, never `gpu`, `sdl`, `imgui` or another add-on. Every miniaudio allocation goes through the system allocator on the owner thread; the audio thread reads only system-owned mirrors. Core never imports it and carries no audio feature flag; selecting the library is the gate. The package owns its `project.json`, `audio_test` target and `audio` example. See `docs/audio.md` for the threading and ownership rules.

Core `c3d::scene` also owns pointer-sized `LodGroup` components: copied rigid
whole-object alternatives with ordinary or fixed-capacity instanced placement.
Renderer-owned per-view histories select ordinary groups on the CPU and instanced
groups on the GPU. Picking, spatial indexing and tracing use level-zero parts.
The landscape foliage package may own a copied descriptor and create LOD cells;
core does not import landscape. The `lod` example explicitly selects the profiler
add-on and its CPU/GPU/internal features. See `docs/lod.md` for the contract.

# 2. Where truth lives

- Project root: [C3 Rendering Project](https://app.notion.com/p/3cfcb7903a5880fbba9bcdadb3bb61c3)
- Architecture (master and per subsystem): [Architecture](https://app.notion.com/p/3cfcb7903a58819dacdfdcf2492a7879), start at `00 Master Architecture`
- Milestones and tasks: [Milestones](https://app.notion.com/p/3cfcb7903a58810e9424f58b86397eda) under Development
- Style baseline (mandatory): `docs/style.md` in the repository, ported from gpu.c3l's `docs/contributing/style.md` and extended with the allocator, initializer, contract, and docstring rules of the [Style Guide (docs/style.md)](https://app.notion.com/p/3bccb7903a5881089469c7001fa88d7c). Section 6 of this file refines it; nothing here relaxes it.
- Change records (OpenSpec mirrors, one page per change): [Changes](https://app.notion.com/p/3cfcb7903a5881da8d4cdc33909a6a24) under Development

Work items name the architecture sections to read. Read those and follow additional references only when the task requires them. Product documentation describes current behavior, contracts and usage. Proposals, test plans, validation results and review history belong in the change artifacts described in section 13.

# 3. Skills, mandatory

Load the applicable skills before reading, writing or reviewing code. Reuse already loaded guidance within the task; consult additional references when the touched language feature or dependency requires them. A code review or change without the applicable skills is invalid. Prose-only changes do not require unrelated language or binding references.

- `c3-expert`: any C3 reading, writing, or reasoning; `project.json`, `manifest.json`, build configuration; any `c3c` diagnostic. Threshold: more than about five lines of C3 read or written without it this session means stop and load it.
- `c3-style`: any `.c3` or `.c3i` file written or reviewed.
- `c3-bindings`: anything that crosses into gpu.c3l, sdl3.c3l, c3imgui.c3l, c3cg.c3l, box3d.c3l, cgltf.c3l, ufbx.c3l, shaderc.c3l, clay.c3l, miniaudio.c3l, or the `extern fn` declarations for stb_image and stb_truetype.
- `shader-dev`, when installed: GLSL technique (BRDF, shadows, post effects). Dispatch shape, barriers, and the binding contract stay with the style guide and gpu.c3l's `docs/shader_abi.md` and `docs/cookbook.md`.

The skills live in `.claude/skills/`, which is gitignored. Verify the required skills are available before code work.

# 4. Session protocol

1. Read this file; read `docs/style.md` for code work. Inspect the working tree and preserve unrelated changes.
2. Read the assigned milestone, its named architecture sections and the current change artifacts. Collect all known design questions before requesting answers.
3. Load the applicable skills in section 3. Verify the toolchain and dependency pins once for the working environment; repeat only when they change or a failure requires it.
4. Follow the proposal, approval and implementation stages in section 13. Tests land with the behavior they cover.
5. Run the scoped checks and required acceptance commands in section 5 and the approved tasks. If a required check fails and cannot be fixed in scope, report the failure.

One milestone is active at a time. Do not pull work from a later milestone into an idle lane. Every code change runs through the change lifecycle in section 13; no change exists outside one.

Keep a short handoff with the active contract, checkout and commit, outstanding decisions, applicable check results and next action. Reuse it when resuming instead of reconstructing the entire conversation. Keep historical evidence in the change artifacts.

Use `gh` for GitHub operations. On Windows, a sandboxed authentication failure can reflect unavailable keyring access; use the approved execution context before treating credentials as invalid. Reuse a prepared checkout and pin-matched native artifacts where possible; keep mutable build outputs isolated. Use native shell path operations, verify cleanup targets, and remove only known task-owned files. Do not change global Git settings to inspect a checkout.

# 5. Build and verification

From the repository root:

```bash
python3 scripts/build.py                  # compile SPIR-V, verify committed generated C3, build all examples
python3 scripts/build.py --test           # same, then run every test target; what CI runs
python3 scripts/build.py --regen          # rewrite the generated ABI twins and registry table, then build
python3 scripts/build.py --example cube   # build and run one example
python3 scripts/build.py --init-deps      # first checkout: submodules and native dependency builds
python3 scripts/build.py --clean
```

Steps run in this order and stop at the first failure: tools (c3c 0.8.3, glslang), deps (submodules present), abi (`gen_abi.py`, which builds gpu.c3l's `gpu_shaders` tool with `c3c build --path lib/gpu.c3l/tools/gpu_shaders` on first use), shaders (`build_shaders.py`: core's `shaders/variants.json`, its public-include probes, then every shader package, `addons/*/` and `test/` with a `shaders/shaders.json`), build (every target in `examples/project.json`, or `--target`), test (every target in `test/project.json`), run. `build_shaders.py` also embeds the GLSL include set as `src/c3d/shader/includes.c3` for the in-process compiler, compiles one probe per public include so each compiles after the ABI headers alone, and writes each package's `output` C3 file (its SPIR-V as `@private` `$embed` constants and, when it has `shaders/include/<name>/`, a public `<NAME>_SHADER_INCLUDES` table); the build copies the shaderc shared library (`shaderc_shared.dll`, `libshaderc_shared.so.1`) next to example and test executables, and shaderc's own Linux manifest sets the runpath to `$ORIGIN`; SDL3 links statically on both platforms. `--init-deps` downloads each dependency's natives from its release at the submodule's tag (sdl3, c3imgui, box3d, shaderc, vma, spvreflect), checked against `SHA256SUMS`. SPIR-V is compiled into `shaders/spv/` and each package's `shaders/spv/` (not committed) on every run; the generated C3 (`src/c3d/shader/*.c3` and every package `output`) and GLSL twins are committed and verified unless `--regen` is given, which rewrites them. A consumer outside the repository compiles its own package with `python3 lib/c3d.c3l/scripts/build_shaders.py --package <dir>`, which compiles only the named packages and needs only `scripts/build_shaders.py` and `shaders/{common,generated,gpu}`; `shaders/gpu/` is a committed copy of gpu.c3l's `include/shaders`, refreshed by `--regen` and checked otherwise. The test step first runs the scripts' unit tests (`scripts/test_*.py`). `--skip-abi`, `--skip-shaders`, `--skip-build`, and `--opt O3` narrow a run; `-v` prints each command.

Releases: a `v*` tag runs `.github/workflows/release.yml`, which reuses `ci.yml`, compiles SPIR-V, packs every package with `scripts/package_release.py` (core as `c3d_core-v<version>.c3l`, each add-on as `<provides>-v<version>.c3l`, `c3d_shader_tools-v<version>.zip`, `SHA256SUMS`) and publishes them with the dependency pins read from the submodules' release tags. Every submodule must sit on a released tag first. Consumer setup and the per-package dependency list are in `docs/release.md`.

Local verification is scoped to the change. The full `scripts/build.py --test` is the CI integration gate, not a requirement before every local commit.

- During implementation, run the failing case and directly affected tests, using `--test-filter` where appropriate.
- Before review, build the changed consumers and run the affected subsystem targets and acceptance cases listed in `tasks.md`. Broaden local checks only for a demonstrated dependency or unresolved risk, or when the approved plan requires it.
- The reviewer runs broader suites and hardware acceptance when warranted. Final merge requires the reviewer's `MERGE` verdict at the final head and all required CI checks passing at that head.
- After a fix, rerun the checks affected by that fix. Repeat other checks only when their inputs changed or new evidence invalidates the earlier result. Prose-only changes need document, link and diff checks, not compilation or GPU runs.

Record the tested commit, compiler/options, commands, fixtures and results in change evidence and the PR. Compilation, CPU tests, native/GPU acceptance and performance measurements are distinct claims. When independent validators check the same corpus, use identical versioned fixtures. Do not add validation reports or review receipts to product documentation.

Before committing, review the diff and pass the applicable local checks. Do not commit known build failures. GPU examples run manually; every development GPU run enables Vulkan validation through gpu.c3l. CI runs the full `--test` sequence. Cancel obsolete PR runs when supported; never use a result from a superseded head as the merge gate.

The default build also builds the collector's `capture` example, the physics package's `physics`, `physics_instanced`, `physics_components`, `vehicle`, `ragdoll`, `collision_math`, `breakable` and `cloth` examples, the nav package's `navmesh`, `crowd` and `grid` examples, the character package's `character` and `character_nav` examples, the physics GUI package's `physics_inspector` and `physics_inspector_character` examples, the job package's `job_bench` example, the landscape package's `terrain`, `vegetation` and `water` examples, the particle package's `particles` example, the UI package's `ui` example, the audio package's `audio` example, the root `profile_gpu` example and all four `profile_gui` feature targets; `--target` and `--example` resolve add-on examples to their package project. `--test` runs the collector's off, CPU, internal CPU, GPU, internal GPU, CPU+GPU and full CPU+GPU+INTERNAL targets, the presentation add-on's off, CPU, GPU and combined data targets, the physics package's `physics_test` target, the nav package's `nav_test` target, the character package's `character_test` and `character_nav_test` targets, the physics GUI package's `physics_panel_off`, `physics_panel` and `physics_panel_character` targets, the job package's `job_test` and `job_profile_test` targets, the landscape package's `landscape_test` target, the particle package's `particle_test` target, the UI package's `ui_test` target, the audio package's `audio_test` target, and the root integration targets. These tests never create a GPU device. Direct `c3c test profile_cpu --path addons/c3d_profile.c3l` exercises only the standalone collector package. Real Vulkan acceptance lives in the separately invoked `test/gpu/profile` project and the manually run profiler GUI examples; neither runs in CI. An acceptance project run directly with `c3c test <target> --path <project>` gets no runtime copy from `build.py`: when it links shaderc (`test/gpu/render`, the landscape package's `terrain_acceptance`), copy `lib/shaderc.c3l/linux/libshaderc_shared.so.1` or `lib/shaderc.c3l/windows/shaderc_shared.dll` next to its executable first.

# 6. Style

The baseline is `docs/style.md`: naming, K&R braces, four-space indentation, one parameter per line in function/method signatures with more than three parameters (four-space indentation and trailing comma), two-space continuation for other declarations, blank lines between logical blocks, named arguments at four or more call arguments with a trailing comma, `.field = value` in every struct initializer, definition order (typedefs, aliases, constants, enums and bitstructs, structs, struct methods, free functions), optionals and named faults for every operational failure, `defer` for cleanup, one `faultdef` file per domain with one fault per line, never `c3fmt`, no development terminology in code.

Project refinements:

- **Names are descriptive.** `Renderer renderer`, `AssetStore assets`, `GeometryId geometry_id`. Single letters only for loop counters and coordinate math in scopes under ten lines. No abbreviations that are not already in the architecture vocabulary (`rt`, `gpu`, `uv`, `sh`, `ik` are vocabulary; `r`, `mgr`, `ctx`, `tmp` are not).
- **Contracts are the precondition mechanism.** A precondition that only a programming error can violate is a `@require` in the docstring, not a runtime branch. An operational failure (input data, capacity, I/O, device, a dead id at an API entry point) returns a named fault. Runtime `assert` appears only under `test/`. `$assert` layout pins are required on every ABI-visible struct.
- **Happy path.** No defensive checks on internal paths. A function trusts its contract and the invariants of the structs it receives. `try_get` exists at API entry points; inside the renderer, `get` with a contract.
- **Ids** live in `src/c3d/types.c3`; an add-on declares its own ids in its package; `std::math` supplies the vector, matrix and quaternion types, and c3d declares no aliases for them. Faults for the root module live in `src/c3d/faults.c3`; a module with its own faults has its own `faults.c3`.
- **Ownership.** Free functions `create_x` and `destroy_x` own project resources. `X` owns, `XView` borrows, views have no destructor. GPU objects live only in `c3d::render` mirrors; the store owns CPU assets; the scene owns nodes.
- **Interfaces** only at user extension points named in the architecture. Everything hot is enums with `switch` or component stores.
- **Tunable constants** state their why and cost in a trailing comment: `const uint MAX_LIGHTS = 256; // 16 KiB per frame in the ring; the flat light loop's cost lever`.
- **GLSL mirrors C3** through `abi/c3d.abi` and `gen_abi.py`. A constant mirrored by hand names its twin: `// mirrored as SHADOW_CASCADES in shadows.glsl`. Never hand-edit generated files.

# 7. Docstrings

Every public function, method, macro, constant, and type carries a `<* ... *>` docstring. Nothing else does.

Rules:

- The description is one line: the purpose of the entity, nothing about how it does it. No "this function", no "returns" as the first word, no restatement of the name. Under about twelve words.
- Use only the official directives: `@param [mode] name : "..."`, `@return "..."`, `@return? FAULT_A, FAULT_B`, `@require`, `@ensure`, `@pure`, `@deprecated`.
- `@param` for every pointer parameter, with its mode (`[&in]`, `[in]`, `[&out]`, `[&inout]`, `[inout]`), and for any parameter whose meaning or unit is not already in its name and type. Do not document a parameter the name already explains.
- `@return "..."` only when the name does not make the value obvious. `@return?` lists every fault the function can produce; it is mandatory on every optional return.
- `@require` for preconditions that are programming errors. `@ensure` only for an invariant the caller relies on. `@pure` where true.
- Descriptions are quoted phrases that start with a capital and end with a period, under about ten words.
- One dangerous property, when there is one, goes in the description: "exits without running defers", "invalidates component pointers of the same store".
- Narration is a defect: no step lists, no history, no rationale essays, no examples in docstrings. Rationale lives in the architecture pages.

Example:

```c3
<*
 Add a geometry asset and return its id.
 @param [&in] geometry : "Arrays are copied into the store allocator."
 @return? CAPACITY_EXCEEDED, INVALID_ARGUMENT
*>
fn GeometryId? AssetStore.add_geometry(&self, Geometry* geometry, String key = "")

<*
 Solve the chain so its end joint reaches the target.
 Invalidates nothing; writes local rotations only.
 @require self.joints.len >= 2
*>
fn void IkChain.solve(&self)

<*
 Slot size of one material block in the material heap.
*>
const usz MATERIAL_STRIDE = 256;
```

Counter-example, rejected on review:

```c3
<*
 This function adds a new geometry to the asset store. It first checks the
 capacity, then copies the arrays, registers the key, and finally returns
 the new id which callers can use later to reference the geometry.
 @param geometry : "the geometry to add"
 @param key : "the key"
 @return "the id"
*>
```

# 8. Comments and self-documentation

- Code is self-documenting: names carry meaning, structure carries flow.
- A `//` comment is allowed only on non-trivial code and only to state a why that the code cannot: an invariant, a deliberate asymmetry, a hardware or backend quirk, a layout requirement that `$assert` cannot express. As short as possible while conveying the message.
- A comment that says what the code does is a defect: delete it and improve the names.
- No development terminology anywhere in code: no milestone numbers, ticket or PR references, "TODO for M12", change ids, or plan vocabulary in identifiers, filenames, comments, docstrings, test names, or string literals. `AGENTS.md`, `docs/`, and `scripts/` are exempt.
- If a comment is needed to explain a number, the number becomes a named constant instead.

# 9. KISS, checks, and tests

- Prefer the simplest implementation that satisfies the architecture. Fixed capacity over growth; one allocation per resource; enums and switch over dispatch. Add complexity only when a measurement on this codebase demands it, and record the measurement in the change evidence. The milestone records the accepted decision and links to that evidence.
- No per-frame allocation. A resource is allocated once when its owner is created and freed when the owner is destroyed; spawn and destroy may happen inside the frame loop. Never allocate and free the same thing within a frame, or rebuild it every frame. Derived data of asset size (cooked collision data, wireframes, packed vertex streams, baked tables) is built once at load or add time and owned by the resource that uses it; a cache with an identity (source id and revision) beats a rebuild. Per-frame recomputation is for values that are cheap and change every frame (transforms, interpolation, culling); recompute those rather than caching them.
- No speculative generality: no configuration for a case the milestones do not name, no abstraction with one implementor, no hooks nobody calls. This rejects shapes nobody has committed to, not supporting structure for a committed capability: when the engine already does something internally, or the architecture has committed to it, the application-facing form (its types, lifetimes, and entry points) is built then, in its right shape, without waiting for an example to need it.
- No over-checking: no null checks on pointers the contract says are non-null, no range checks on indices produced by the module itself, no validation of data that gpu.c3l already validates, no defensive copies.
- No over-testing: tests cover contracts and invariants that can break (math identities, pool generations, ECS store invariants, transform hierarchies, geometry packing, animation sampling, parser output, the asset revision protocol). No tests for trivial accessors, no tests that restate the implementation, no mocks of the GPU device, no GPU tests in CI. One test file per group under `test/`, ordinary `@test` functions named `test_<what_it_checks>`. Fault-path tests assert the specific fault.
- A missing defensive check is not a bug. A suspected cost is not a bottleneck until measured.

# 10. Architecture rules

- Two layers, plus the UI add-on above the render layer. Scene-layer modules (`c3d`, `c3d::maths`, `c3d::ecs`, `c3d::describe`, `c3d::asset`, `c3d::scene`, `c3d::geometry`, `c3d::camera`, `c3d::material`, `c3d::light`, `c3d::anim`, `c3d::model`, `c3d::spatial`, `c3d::physics`, `c3d::nav`, `c3d::character`, `c3d::job`, `c3d::landscape`, `c3d::particle`, `c3d::audio`) never import `gpu`. The render layer (`c3d::render`, `c3d::shader`, `c3d::render::post`, `c3d::gui`) owns every GPU object. `c3d::platform` imports `gpu::surface` alone, to hand native window handles to gpu.c3l; a bare `import gpu` there is a violation. `c3d::ui` fills `c3d::render`'s overlay list and creates no GPU object; it never imports `gpu`.
- The renderer reads the scene; the scene never calls the renderer. Loaders write the asset store and the scene; they never touch the renderer.
- All shader-visible data is std430 behind root pointers and defined once in `abi/c3d.abi`. Per-draw push data is exactly two root addresses.
- Depth is reverse-Z; the Vulkan Y flip is one negative-height viewport; shaders use GL conventions and never flip.
- Pass order is fixed; barriers are explicit; the renderer tracks `TextureState` only for targets it owns.
- Every entity is a node; everything else about a node is a component. Systems are functions the application calls; there is no scheduler.
- Reviewers check every new `import` against these rules and the dependency table of section 1.

# 11. Directory map

```
c3d.c3l/
├── manifest.json
├── addons/c3d_profile.c3l/ CPU/GPU capture package, standalone data tests and CPU example
├── addons/c3d_profile_gui.c3l/ ImGui presentation package and standalone data tests
├── addons/c3d_physics.c3l/ box3d rigid bodies, colliders, events; owns its tests and example
├── addons/c3d_nav.c3l/     Recast/Detour port: tiled navmesh build, tile cache, store, path queries and crowds; owns its tests and examples
├── addons/c3d_character.c3l/ capsule character controller on the physics mover primitives, crowd binding under C3D_CHARACTER_NAV; owns its tests and examples
├── addons/c3d_physics_gui.c3l/ physics inspector panel and component inspectors, characters under C3D_PHYSICS_GUI_CHARACTER; owns its tests and examples
├── addons/c3d_job.c3l/     fork-join job pool over index ranges; owns its tests and benchmark example
├── addons/c3d_landscape.c3l/ height-field terrain, vegetation and water, its shader package, tests and examples
├── addons/c3d_particle.c3l/ fixed-pool CPU particles, effect materials, tests and example
├── addons/c3d_serial.c3l/ portable subtree format, explicit codecs and CPU tests
├── addons/c3d_ui.c3l/      game UI: JSONC documents, styles, bindings and actions over Clay; owns its tests, acceptance project and example
├── addons/c3d_audio.c3l/   audio over miniaudio: clips, buses, voices, emitters and a listener; owns its tests and example
│                           an add-on that ships GLSL keeps shaders/shaders.json, its sources and shaders/include/<name>/ under its own shaders/, and a generated, committed src/shaders.c3
├── abi/c3d.abi             shared C3 and GLSL layouts
├── docs/style.md           mandatory style baseline
├── lib/                    gpu.c3l · sdl3.c3l · c3imgui.c3l · c3cg.c3l · box3d.c3l · cgltf.c3l · ufbx.c3l · shaderc.c3l · clay.c3l · miniaudio.c3l (submodules)
│                           plus c3d.c3l, a symlink to the root, so consumers resolve c3d here
│                           plus c3d_profile.c3l, c3d_profile_gui.c3l, c3d_physics.c3l, c3d_nav.c3l, c3d_character.c3l, c3d_physics_gui.c3l, c3d_job.c3l, c3d_landscape.c3l, c3d_particle.c3l, c3d_serial.c3l, c3d_ui.c3l and c3d_audio.c3l symlinks to the add-ons
├── linked-libs/            empty; every dependency ships its own native artifacts
├── csrc/                   stb_image, stb_truetype
├── src/c3d/
│   ├── types.c3            ids
│   ├── faults.c3           root-module faults
│   ├── pool.c3             the generic pool, module c3d::pool <Type, IdType>
│   ├── maths/ ecs/ describe/ asset/ scene/ geometry/ camera/ material/ light/ anim/ model/ spatial/
│   ├── platform/           the only sdl importer
│   ├── render/  shader/                            the gpu importers; render/post/ holds display processing
│   └── gui/                the only imgui importer; gui/backend imports gpu
├── shaders/                GLSL sources, variants.json (registry entries and public includes), common/, generated/; spv/ is build output
├── scripts/                build.py (entry point) · gen_abi.py · build_shaders.py
├── examples/               one executable per milestone
└── test/                   CPU tests, one file per group; test/shaders/ is the shader package the unit tests read
```

# 12. Anti-patterns, rejected on sight

- `null`, `-1`, or `bool` out-parameters as error signals.
- Runtime `assert` outside `test/`; `unreachable()` for a failure that can occur at runtime.
- A `@require` that checks operational data (a file, a device, user input) instead of a programming error.
- Single-letter or abbreviated identifiers outside loop counters and coordinate math.
- Docstrings that narrate the body, restate the name, or document parameters the name already explains.
- Comments that say what; comments with milestone, ticket, or plan vocabulary.
- A GPU type or call outside the render layer; a `sdl::`, `imgui::`, `cg::`, or `b3::` reference outside its owning module.
- Hand edits to generated files; a layout change on one side of the ABI only.
- Speculative abstractions, configuration, or hooks without a named consumer.
- Defensive checks on internal paths; tests for trivial code; GPU mocks.
- `c3fmt` output; camelCase anywhere; `->` for pointer access; `sizeof` instead of `Type::size`.

# 13. Change workflow, customized OpenSpec

The owner sets scope and resolves consequential design choices. A designated reviewer may act within the authority the owner delegates. The owner or an explicitly delegated agent implements the approved work. A request to implement a scoped task delegates that work; it does not require permission for each routine edit.

Ask all known questions up front, then raise follow-ups when answers or new evidence reveal another decision. Keep the proposal and tasks as the shared basis for implementation and review.

## Bootstrapping the harness

On a fresh checkout or a new machine, before the first session:

```bash
openspec init --tools none          # then add openspec/ to .gitignore
mkdir -p .claude/skills             # .claude/ is gitignored
cp -r <claude-skills>/c3-expert <claude-skills>/c3-style <claude-skills>/c3-bindings .claude/skills/
cp -r <minimax-skills>/skills/shader-dev .claude/skills/    # optional, GLSL technique
git submodule update --init --recursive
python3 scripts/build.py --init-deps
```

`--tools none` is mandatory: otherwise `openspec init` writes AI-tool instruction files and the `claude` profile overwrites this file. Verify skill availability directly. Bootstrap once per environment; do not repeat setup without a changed dependency or a concrete failure.

## The lifecycle

Every milestone task, or a tightly coupled group of tasks from one milestone, runs as one OpenSpec change through these steps in order:

1. **Brainstorm.** Read the assigned milestone, relevant architecture and code. Present all known questions together, grouped by topic, with options, tradeoffs and a recommendation where useful. Cover ownership, public contracts, compatibility, failure behavior, exclusions and acceptance. Resolve dependent follow-ups after the initial answers. Record decisions in `interview.md`; do not reopen settled choices without new evidence. Agree the shape before drafting the proposal.
2. **Propose.** Write `proposal.md` and `tasks.md`. The proposal defines scope, placement, contracts, ownership, invariants, faults and exclusions. Tasks define the implementation order, affected APIs, completion criteria and scoped validation commands. Specify tests in full in one canonical annex or executable test file referenced by the tasks. Include required spec deltas and a PR plan based on reviewable behavior. For uncertain numerical, performance or platform work, identify the assumptions and bounded prototypes needed before dependent implementation; record their evidence here. Obtain approval of the proposal and tasks from the owner or designated reviewer before production implementation.
3. **Apply.** Implement the approved tasks within the delegated scope. Tests are delegated to the agent by default. Keep artifacts current when implementation reveals a necessary change. Ask follow-up questions for unresolved contract, ownership or scope decisions; routine implementation choices within the approved contract do not need another approval.
4. **Review.** Review the diff against the approved artifacts, milestone exit criteria, style and applicable skills. Report actionable findings as `file:line:fix`. Distinguish defects and contract violations from optional improvements. Keep check results and reviewer responses in change evidence and PRs. Resolve findings, then obtain a `MERGE` verdict for the final head and passing required CI before merging.
5. **Sync.** Verify the PR is `MERGED` and record its merge commit before final close-out. Complete the change artifacts with delivered behavior, divergences, acceptance evidence and carried-forward work. Mirror proposal, tasks/specs and close-out to one Notion Changes page. Correct affected architecture and product documentation in place to describe current contracts and behavior; keep test logs, pass counts, validation receipts and review history in the change record. Update milestone status and affected downstream handoffs with links to the record. Read back the changed records once to verify the update; do not rewrite unchanged pages.
6. **Archive.** Archive the local OpenSpec change and mark its Notion record `[Archived]` after required work and synchronization are complete. Preserve intentionally deferred work as open items. Synchronize the checkout and remove only verified task-owned, merged branches and temporary checkouts. Report an archive-tool failure accurately and use a verified in-tree fallback when appropriate; do not claim a failed command succeeded.

Trivial corrections with already agreed scope may collapse to apply, review and sync. Milestones retain the interview and approved proposal/tasks stages unless the owner explicitly waives them. A waiver applies only to its stated task. Keep one current version of each artifact and link to it from review requests; avoid copying the full design into every comment or status update.

## Change artifacts and product documentation

- `openspec/` is in `.gitignore`. No proposal, spec delta, or task list is committed or pushed.
- Notion is the durable record: Development, Milestones for the plan; Development, Changes for the per-change record.
- Keep validation reports, experiment logs, test receipts, proposal history and review discussions in the change artifacts, their Notion mirror or PR evidence. Product documentation explains behavior, limitations and usage. The section 8 exemptions permit development terminology where needed; they do not make `docs/` a destination for validation reports.

## Authoring

- Bound the change by approved behavior and acceptance. If investigation changes its scope materially, review the plan before expanding dependent work.
- Tests ship in the same change, written against the milestone's exit criteria.
- No drive-by refactors. A refactor is its own change, made on the second pain, with behavior unchanged.
- Read your own diff once, top to bottom, before committing and pass the applicable section 5 checks.
- PR size is advisory. Roughly 500-line slices and the 1,000-line guideline are prompts to assess reviewability, never mandatory limits. Split at independently reviewable behavior or dependency boundaries. Keep tightly coupled implementation, tests and documentation together when splitting adds only review and CI cycles. Each slice builds and passes its scoped checks; each merge still requires final-head review and CI. Design the change as one unit and record the chosen PR boundaries in `tasks.md`.

## Reviewing

The reviewer uses `docs/style.md` and the applicable section 3 skills, reusing already loaded guidance. Review against the approved proposal/tasks/specs, milestone exit criteria, affected architecture and sections 6 to 9. Flag concrete correctness, contract and style violations. A missing defensive check is not automatically a defect. Review fixes against the finding and affected behavior; broaden the review when a fix changes the contract or exposes another problem.

## Coordination

- When parallel agent work is authorized, give each participant a bounded assignment with inputs, owned files, expected output and completion criteria. Keep one owner for integration and shared files. Do not start work from a later milestone to occupy an idle agent.
- Agree a communication venue with the owner and reviewer at task start. Use direct, event-driven messages when available. Keep accepted design decisions in the change artifacts and final review verdicts in GitHub at the reviewed commit; a notification or transport acknowledgement is not approval.
- Send a complete question set or review request with artifact links, the relevant commit and the requested decision. Send further messages for new findings, blockers, changed readiness or completion. Avoid repeated status requests while the state is unchanged.
- Prefer bounded waits or notifications to repeated full comment-history reads. When polling is necessary, use one coordinator and fetch only changes since the last observation. Continue independent work within the approved change while waiting.

## Project-instructions block

Paste into `openspec/config.yaml` under `context` after `openspec init`:

```markdown
# c3d, OpenSpec customizations

Follow the canonical repository AGENTS.md: section 4 for session setup,
section 5 for scoped validation, sections 6 to 9 for code conventions,
and section 13 for questions, approved proposal/tasks/specs, coordination,
review, merge verification and close-out. Record task-specific decisions
in this change instead of duplicating those policies here.
openspec/ is gitignored; never commit or push its contents.
```
