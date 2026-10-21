Entry point for every agent session in this repository. Read it once at task start; reread changed or newly relevant sections when needed. The repository copy is canonical; its Notion mirror follows it.

# 1. Project facts

## 1.1 Facts

- **Project:** `c3d`, a scene-level 3D rendering library with an ECS scene, physics, animation, and asset import. Not a game engine; a base for one.
- **Language:** C3 **0.8.3**. C3 is pre-1.0. Verify syntax against the installed compiler and the `c3-expert` skill, never against memory of another version.
- **Shading language:** GLSL, Vulkan 1.3 semantics through gpu.c3l. Files are `<name>.<stage>.glsl`; shared includes are plain `.glsl`. The includes listed under `public_includes` in `shaders/variants.json` are the stable contract for custom and package stages. SPIR-V is built offline by `scripts/build_shaders.py`, for core and for every shader package (a directory with `shaders/shaders.json`), and embedded with `$embed`.
- **Module root:** `c3d`. Every module is `c3d` or a submodule of it (`c3d::render`, `c3d::asset::gltf`). The repository directory name never appears in source.
- **Build tooling:** `scripts/build.py` is the entry point; it drives ABI codegen, shader compilation, `c3c build`, and optionally `c3c test` and `c3c run`. Python 3.10+ standard library only, under `scripts/`, only for build orchestration and code generation.

## 1.2 Dependencies

Third-party libraries are git submodules under `lib/`, pinned, except stb, whose C sources sit in `csrc/`. Each is imported only by its owner.

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
| clay.c3l | `clay` | `c3d::ui`, in `addons/c3d_ui.c3l`; core never imports it |
| miniaudio.c3l | `ma` | `c3d::audio`, in `addons/c3d_audio.c3l`; core never imports it |

Boundaries are checked at review. No dependency is added without updating this table.

## 1.3 Add-on packages

Each add-on is a package under `addons/<name>.c3l/`. `std` is the standard library and `core` is `c3d`. An add-on imports only what its row lists; a feature-gated import exists only while its feature is selected.

| Package | Modules | Always imports | Never imports | Gated imports | Detail |
| --- | --- | --- | --- | --- | --- |
| `c3d_profile` | `c3d::profile`; private `c3d::render::profile_gpu` under `src/gpu/` | `std` | core types, in either module | `gpu` and neutral profile values, in `profile_gpu` only, under `C3D_PROFILE_GPU` | [README](addons/c3d_profile.c3l/README.md) |
| `c3d_profile_gui` | profiler additions to `c3d::gui` | `std`, `c3d::profile`, `imgui` | core | none | [README](addons/c3d_profile_gui.c3l/README.md) |
| `c3d_physics` | `c3d::physics`, `c3d::physics::collide`, `c3d::physics::cloth` | `std`, core, `b3`; `physics::cloth` imports `c3d::physics` and not `b3`, and `physics::collide` imports `std`, `c3d::maths` and `b3` only | `gpu`, `sdl`, `imgui`, `c3d::job` | `c3d::serial` under `C3D_PHYSICS_SERIAL` | [README](addons/c3d_physics.c3l/README.md) |
| `c3d_nav` | `c3d::nav`, a port of Recast/Detour | `std`, core | `gpu`, `sdl`, `imgui`, `b3`, `c3d::physics` | `c3d::serial` under `C3D_NAV_SERIAL` | [README](addons/c3d_nav.c3l/README.md) |
| `c3d_character` | `c3d::character` | `std`, core, `c3d::physics` | `b3`, `gpu`, `sdl`, `imgui` | `c3d::nav` under `C3D_CHARACTER_NAV`; `c3d::serial` under `C3D_CHARACTER_SERIAL` | [README](addons/c3d_character.c3l/README.md) |
| `c3d_physics_gui` | physics additions to `c3d::gui` | `std`, core, `c3d::physics`, `imgui` | `b3`, `gpu`, `sdl` | `c3d::character`, in `src/character/` alone, under `C3D_PHYSICS_GUI_CHARACTER` | [README](addons/c3d_physics_gui.c3l/README.md) |
| `c3d_job` | `c3d::job` | `std`, core | `gpu`, `sdl`, `imgui`, `b3`, another add-on | `c3d::profile`, in `src/profile.c3` alone, under `C3D_PROFILE_CPU` | [README](addons/c3d_job.c3l/README.md) |
| `c3d_landscape` | `c3d::landscape`, `::terrain`, `::foliage`, `::water`, `::water_gpu` | `std`, core, and the landscape modules named in the rule below | `gpu`, `sdl`, `imgui`, `b3`, `c3d::shader`, `c3d::render` outside `water_gpu`, another add-on | `c3d::serial` under `C3D_LANDSCAPE_SERIAL`; `c3d::render`, in `water_gpu` alone, under `C3D_LANDSCAPE_GPU` | [README](addons/c3d_landscape.c3l/README.md) |
| `c3d_particle` | `c3d::particle`, `c3d::particle::gpu` | `std`, core | `gpu`, `sdl`, `imgui`, `c3d::physics`, `c3d::job`, `c3d::profile`, `c3d::shader`, `c3d::render` outside `particle::gpu` | `c3d::serial` under `C3D_PARTICLE_SERIAL`; `c3d::render`, in `particle::gpu` alone, under `C3D_PARTICLE_GPU` | [README](addons/c3d_particle.c3l/README.md) |
| `c3d_serial` | `c3d::serial` | `std`, core | renderer and platform dependencies; GPU resources and native systems are never created | none | [README](addons/c3d_serial.c3l/README.md) |
| `c3d_ui` | `c3d::ui` | `std`, core (including `c3d::render` for the overlay list and `c3d::platform` for input), `clay` | `gpu`, `sdl`, `imgui`, another add-on | none | [README](addons/c3d_ui.c3l/README.md) |
| `c3d_audio` | `c3d::audio` | `std`, core, `ma` | `gpu`, `sdl`, `imgui`, another add-on | `c3d::serial` under `C3D_AUDIO_SERIAL` | [README](addons/c3d_audio.c3l/README.md) |

Rules for every package:

- **Selection.** Applications select an add-on explicitly in `project.json`; selecting the library is the gate. Core never imports an add-on and carries no feature flag for one, with one exception: the profiler. Core imports `c3d::profile` and `c3d::render::profile_gpu` only through two gated bridges, `c3d::instrumentation` under `C3D_PROFILE_CPU` with `C3D_PROFILE_INTERNAL` and `render/profile.c3` under `C3D_PROFILE_GPU`. Core has no unconditional profiler dependency.
- **Manifest.** An add-on's manifest owns its sources and dependencies; core never compiles add-on sources through its source glob. The manifests of `c3d_physics_gui` and `c3d_profile_gui` name no dependency; consumers select the packages they display, ImGui and the rest.
- **Features.** A module that needs an optional library, add-on or backend is gated by a `C3D_*` feature and is absent without it. A consumer that enables the feature also selects the dependency it names, and targets without the feature build without it. The flags are listed in [docs/architecture.md](docs/architecture.md#feature-flags).
- **Landscape modules.** Within `c3d_landscape`, the root `c3d::landscape` imports `std` and `c3d::asset` only; `terrain` imports the root; `foliage` imports the root and `terrain`; `water` imports the root and `terrain`; `water_gpu` imports the root and `water` and, under `C3D_LANDSCAPE_GPU`, `c3d::render`. No other landscape module imports `c3d::render`. The serial adapter, a root-module file under `C3D_LANDSCAPE_SERIAL`, also imports the submodules and `c3d::serial`.
- **Presentation adapters.** `c3d_profile_gui` and `c3d_physics_gui` extend `c3d::gui`. Every module of each exists only under its feature (`C3D_PROFILE_GUI` with a capture feature, `C3D_PHYSICS_GUI`), so the imports in their rows apply only while the feature is selected. Core and the packages they present never import them or reference their public types and functions.
- **Serial adapters.** Each of physics, nav, character, landscape, particle and audio keeps `src/serial/`, which imports `c3d::serial` only under `C3D_<PACKAGE>_SERIAL`; consumers select `c3d_serial` explicitly. A package's `<package>_serial_test` and the isolated `<package>_serial_policy_test` run beside its feature-off test in `scripts/build.py --test`; the character targets run with and without `C3D_CHARACTER_NAV`. `C3D_CHARACTER_SERIAL` requires `C3D_PHYSICS_SERIAL`, and with `C3D_CHARACTER_NAV` also `C3D_NAV_SERIAL`. A new core component needs a classified serialization policy, or `serial_core_policy_test` fails.
- **Profiler.** The collector's CPU builds need no native or shader setup. GUI consumers select ImGui and the Vulkan bindings explicitly, and GPU data tests also select the backend dependencies; neither data-test project creates a device.

# 2. Where truth lives

- Project root: [C3 Rendering Project](https://app.notion.com/p/3cfcb7903a5880fbba9bcdadb3bb61c3)
- Architecture (master and per subsystem): [Architecture](https://app.notion.com/p/3cfcb7903a58819dacdfdcf2492a7879), start at `00 Master Architecture`
- Milestones and tasks: [Milestones](https://app.notion.com/p/3cfcb7903a58810e9424f58b86397eda) under Development
- Style baseline (mandatory): [docs/style.md](docs/style.md), the single home of the code-style rules, ported from gpu.c3l's `docs/contributing/style.md` and extended with the allocator, initializer, contract, and docstring rules of the [Style Guide (docs/style.md)](https://app.notion.com/p/3bccb7903a5881089469c7001fa88d7c). Section 6 of this file refines it; nothing here relaxes it.
- Repository guides: [docs/architecture.md](docs/architecture.md) (module map, feature flags, directory map, and the index of subsystem contracts), [docs/development.md](docs/development.md) (build, shader pipeline, test targets), [docs/release.md](docs/release.md).
- Change records (OpenSpec mirrors, one page per change): [Changes](https://app.notion.com/p/3cfcb7903a5881da8d4cdc33909a6a24) under Development

Work items name the architecture sections to read. Read those and follow additional references only when the task requires them. Product documentation (`docs/`, the root README and the package READMEs) explains current behavior, contracts, limitations and usage. Proposals, test plans, validation results, review history and review receipts belong in the change artifacts described in section 13, never in product documentation; the exemption for development terminology in `docs/` ([docs/style.md](docs/style.md) section 14) does not make product documentation a destination for them.

# 3. Skills, mandatory

Load the applicable skills before reading, writing or reviewing code. Reuse already loaded guidance within the task; consult additional references when the touched language feature or dependency requires them. A code review or change without the applicable skills is invalid. Prose-only changes do not require unrelated language or binding references.

- `c3-expert`: any C3 reading, writing, or reasoning; `project.json`, `manifest.json`, build configuration; any `c3c` diagnostic. Threshold: more than about five lines of C3 read or written without it this session means stop and load it.
- `c3-style`: any `.c3` or `.c3i` file written or reviewed.
- `c3-bindings`: anything that crosses into gpu.c3l, sdl3.c3l, c3imgui.c3l, c3cg.c3l, box3d.c3l, cgltf.c3l, ufbx.c3l, shaderc.c3l, clay.c3l, miniaudio.c3l, or the `extern fn` declarations for stb_image and stb_truetype.
- `shader-dev`, when installed: GLSL technique (BRDF, shadows, post effects). Dispatch shape, barriers, and the binding contract stay with the style guide and gpu.c3l's `docs/shader_abi.md` and `docs/cookbook.md`.

The skills live in `.claude/skills/`, which is gitignored. Verify the required skills are available before code work.

# 4. Session protocol

1. Read this file; read `docs/style.md` for code work. Inspect the working tree and preserve unrelated changes.
2. Read the assigned milestone, its named architecture sections and the current change artifacts.
3. Load the applicable skills in section 3. Verify the toolchain and dependency pins once for the working environment; repeat only when they change or a failure requires it.
4. Follow the lifecycle in section 13. Tests land with the behavior they cover.
5. Run the scoped checks and required acceptance commands in section 5 and the approved tasks. If a required check fails and cannot be fixed in scope, report the failure.

Keep a short handoff with the active contract, checkout and commit, outstanding decisions, applicable check results and next action. It records decisions and exceptions, never a copy of this policy. Reuse it when resuming instead of reconstructing the entire conversation. Keep historical evidence in the change artifacts.

Use `gh` for GitHub operations. On Windows, a sandboxed authentication failure can reflect unavailable keyring access; use the approved execution context before treating credentials as invalid. Reuse a prepared checkout and pin-matched native artifacts where possible; keep mutable build outputs isolated. Use native shell path operations, verify cleanup targets, and remove only known task-owned files. Do not change global Git settings to inspect a checkout.

# 5. Build and verification

From the repository root:

```bash
python3 scripts/build.py                  # compile SPIR-V, verify committed generated files, build all examples
python3 scripts/build.py --test           # same, then run every test target; what CI runs
python3 scripts/build.py --regen          # rewrite the generated ABI twins and registry tables, then build
python3 scripts/build.py --example cube   # build and run one example
python3 scripts/build.py --init-deps      # first checkout: initialize submodules, download dependency natives
python3 scripts/build.py --clean
```

Steps run in this order and stop at the first failure: tools, deps, abi, shaders, build, test, run. Generated C3 and GLSL twins are committed and verified unless `--regen` is given; SPIR-V is never committed. The pipeline, the target inventory and the acceptance projects are in [docs/development.md](docs/development.md); releases are in [docs/release.md](docs/release.md). A release needs every submodule on a released tag first.

Local verification is scoped to the change. The full `scripts/build.py --test` is the CI integration gate, not a requirement before every local commit.

- During implementation, run the failing case and directly affected tests, using `--test-filter` where appropriate.
- Before review, build the changed consumers and run the affected subsystem targets and acceptance cases listed in `tasks.md`. Broaden local checks only for a demonstrated dependency or unresolved risk, or when the approved plan requires it.
- The reviewer runs broader suites and hardware acceptance when warranted.
- After a fix, rerun the checks affected by that fix. Repeat other checks only when their inputs changed or new evidence invalidates the earlier result. Prose-only changes need document, link and diff checks, not compilation or GPU runs.

Record the tested commit, compiler/options, commands, fixtures and results in change evidence and the PR. Compilation, CPU tests, native/GPU acceptance and performance measurements are distinct claims. When independent validators check the same corpus, use identical versioned fixtures.

Before committing, review the diff and pass the applicable local checks. Do not commit known build failures.

GPU examples run manually; every development GPU run enables Vulkan validation through gpu.c3l. CI runs the full `--test` sequence; cancel obsolete PR runs when supported. Real Vulkan acceptance projects are invoked separately, run manually and never in CI. An acceptance project run directly with `c3c test <target> --path <project>` gets no runtime copy from `build.py`, with one exception: a build of the default set or of the `profile_gpu` example places the library for `test/gpu/profile`. Every acceptance project lists shaderc as a dependency, but only an executable with code under `C3D_SHADER_COMPILER` needs the shared library at run time. When the project enables that feature, copy `lib/shaderc.c3l/linux/libshaderc_shared.so.1` or `lib/shaderc.c3l/windows/shaderc_shared.dll` next to its executable first.

# 6. Style

The baseline is [docs/style.md](docs/style.md), the single home of the code-style rules: naming and abbreviations, definition order, lifecycle and ownership (`create_x`/`destroy_x`, `X` owns and `XView` borrows), allocation, optionals and named faults, contracts and `assert`, ids and faults files, call and declaration formatting, initializers, braces, docstrings, comments and development terminology, signature hygiene, GLSL and the ABI twins, tunable constants, tests, and the ban on `c3fmt`. Read it before code work. The rules that stay here:

- **Checks.** On internal paths there are no defensive checks: a function trusts its contract and the invariants of the structs it receives. No null checks on pointers the contract says are non-null, no range checks on indices the module itself produced, no validation of data gpu.c3l already validates, no defensive copies. `try_get` exists at API entry points; inside the renderer, `get` with a contract.
- **Interfaces** only at user extension points named in the architecture. Everything hot is enums with `switch` or component stores.

# 7. Docstrings

The docstring rules, the directive set and the examples are in [docs/style.md](docs/style.md) section 12.

# 8. Comments and self-documentation

The comment rules and the ban on development terminology in code are in [docs/style.md](docs/style.md) sections 13 and 14.

# 9. KISS, checks, and tests

- Prefer the simplest implementation that satisfies the architecture. Fixed capacity over growth; one allocation per resource; enums and switch over dispatch. Add complexity only when a measurement on this codebase demands it, and record the measurement in the change evidence. The milestone records the accepted decision and links to that evidence.
- No per-frame allocation. A resource is allocated once when its owner is created and freed when the owner is destroyed; spawn and destroy may happen inside the frame loop. Never allocate and free the same thing within a frame, or rebuild it every frame. Derived data of asset size (cooked collision data, wireframes, packed vertex streams, baked tables) is built once at load or add time and owned by the resource that uses it; a cache with an identity (source id and revision) beats a rebuild. Per-frame recomputation is for values that are cheap and change every frame (transforms, interpolation, culling); recompute those rather than caching them.
- No speculative generality: no configuration for a case the milestones do not name, no abstraction with one implementor, no hooks nobody calls. This rejects shapes nobody has committed to, not supporting structure for a committed capability: when the engine already does something internally, or the architecture has committed to it, the application-facing form (its types, lifetimes, and entry points) is built then, in its right shape, without waiting for an example to need it.
- No over-testing. What tests cover, how they are named and the ban on GPU mocks and GPU tests in CI are in [docs/style.md](docs/style.md) section 18.
- A missing defensive check is not a bug. A suspected cost is not a bottleneck until measured.

# 10. Architecture rules

- Two layers, plus the UI add-on above the render layer. Scene-layer modules (`c3d`, `c3d::maths`, `c3d::ecs`, `c3d::describe`, `c3d::asset`, `c3d::scene`, `c3d::geometry`, `c3d::camera`, `c3d::material`, `c3d::light`, `c3d::anim`, `c3d::model`, `c3d::spatial`, `c3d::debug`, `c3d::physics`, `c3d::nav`, `c3d::character`, `c3d::job`, `c3d::landscape`, `c3d::particle`, `c3d::audio`) never import `gpu`. The render layer (`c3d::render`, `c3d::shader`, `c3d::render::post`, `c3d::gui`) owns every GPU object. `c3d::platform` imports `gpu::surface` alone, to hand native window handles to gpu.c3l; a bare `import gpu` there is a violation. `c3d::ui` fills `c3d::render`'s overlay list and creates no GPU object; it never imports `gpu`.
- Two add-on modules are render-layer code on the same terms: `c3d::landscape::water_gpu` (`C3D_LANDSCAPE_GPU`) records compute dispatches into store textures, and `c3d::particle::gpu` (`C3D_PARTICLE_GPU`) records compute dispatches over application buffers and creates buffers only through `Renderer.create_buffer`. Both record through `Renderer.dispatch`, create no GPU object and never import `gpu`. Without the feature, preparing a spectral water body or a GPU particle system faults `UNSUPPORTED`, and `c3d::landscape::water` stays scene-layer.
- No module declares system externs except `c3d_job`: its `src/affinity_linux.c3` and `src/affinity_win32.c3` declare `@private` externs for the libc and kernel32 calls the standard library already links (`sched_getaffinity`, `sched_setaffinity`, `SetThreadGroupAffinity`, `GetThreadGroupAffinity`, `GetActiveProcessorCount`, `GetActiveProcessorGroupCount`, `GetLogicalProcessorInformationEx`, `SetThreadInformation`), with their native structs pinned by `$assert`.
- The renderer reads the scene; the scene never calls the renderer. Loaders write the asset store and the scene; they never touch the renderer.
- All shader-visible data is std430 behind root pointers and defined once in `abi/c3d.abi`. Per-draw push data is exactly two root addresses.
- Depth is reverse-Z; the Vulkan Y flip is one negative-height viewport; shaders use GL conventions and never flip.
- Pass order is fixed; barriers are explicit; the renderer tracks `TextureState` only for targets it owns.
- Every entity is a node; everything else about a node is a component. Systems are functions the application calls; there is no scheduler.
- Reviewers check every new `import` against these rules and the tables of section 1.

# 11. Directory map

```
c3d.c3l/
├── AGENTS.md  CONTRIBUTING.md  README.md  manifest.json
├── abi/        c3d.abi: shared C3 and GLSL layouts
├── addons/     one <name>.c3l package per add-on (section 1.3)
├── csrc/       stb_image and stb_truetype sources
├── docs/       guides and references; style.md, architecture.md, development.md
├── examples/   example executables: project.json, src/, assets/
├── lib/        dependency submodules, plus symlinks to this repository and to every add-on so consumers resolve them
├── scripts/    build.py (entry point), gen_abi.py, build_shaders.py, package_release.py
├── shaders/    GLSL sources, variants.json, common/, generated/, gpu/; spv/ is build output
├── src/c3d/    core: types.c3 (ids), faults.c3, parallel.c3, pool.c3, one directory per area
└── test/       CPU tests, fixtures, and the manual acceptance projects under test/gpu/
```

The full map, with the add-on layout, is in [docs/architecture.md](docs/architecture.md#directory-map). `.claude/` is gitignored; the bootstrap in section 13 creates `.claude/skills/` and the link `.claude/CLAUDE.md` to this file.

# 12. Anti-patterns, rejected on sight

Each item names where its rule lives.

- `null`, `-1`, or `bool` out-parameters as error signals ([style](docs/style.md) 7).
- Runtime `assert` outside `test/`; `unreachable()` for a failure that can occur at runtime ([style](docs/style.md) 7).
- A `@require` that checks operational data (a file, a device, user input) instead of a programming error ([style](docs/style.md) 7, 12).
- Single-letter or abbreviated identifiers outside loop counters and coordinate math ([style](docs/style.md) 3).
- Docstrings that narrate the body, restate the name, or document parameters the name already explains ([style](docs/style.md) 12).
- Comments that say what; comments with milestone, ticket, or plan vocabulary ([style](docs/style.md) 13, 14).
- A GPU type or call outside the render layer; a `sdl::`, `imgui::`, `cg::`, or `b3::` reference outside its owning module; an import outside the section 1 tables (sections 1 and 10; [style](docs/style.md) 15).
- Hand edits to generated files; a layout change on one side of the ABI only ([style](docs/style.md) 16).
- Speculative abstractions, configuration, or hooks without a named consumer (section 9).
- Defensive checks on internal paths (section 6); tests for trivial code; GPU mocks ([style](docs/style.md) 18).
- `c3fmt` output; camelCase anywhere; `->` for pointer access; `sizeof` instead of `Type::size` ([style](docs/style.md) 3, 10, 19).

# 13. Change workflow, customized OpenSpec

The owner sets scope and resolves consequential design choices. A designated reviewer may act within the authority the owner delegates. The owner or an explicitly delegated agent implements the approved work. A request to implement a scoped task delegates that work; it does not require permission for each routine edit.

One milestone is active at a time; do not pull work from a later milestone into an idle lane. Every code change runs through the lifecycle below; no change exists outside one. Keep the proposal and tasks as the shared basis for implementation and review.

## Bootstrapping the harness

On a fresh checkout or a new machine, before the first session:

```bash
openspec init --tools none          # then add openspec/ to .gitignore
mkdir -p .claude/skills             # .claude/ is gitignored
ln -s ../AGENTS.md .claude/CLAUDE.md   # the harness reads this file through the link
cp -r <claude-skills>/c3-expert <claude-skills>/c3-style <claude-skills>/c3-bindings .claude/skills/
cp -r <minimax-skills>/skills/shader-dev .claude/skills/    # optional, GLSL technique
git submodule update --init --recursive
python3 scripts/build.py --init-deps
```

`--tools none` is mandatory: otherwise `openspec init` writes AI-tool instruction files and the `claude` profile overwrites this file. Verify skill availability directly. Bootstrap once per environment; do not repeat setup without a changed dependency or a concrete failure.

## The lifecycle

Every milestone task, or a tightly coupled group of tasks from one milestone, runs as one OpenSpec change through these steps in order:

1. **Brainstorm.** Read the assigned milestone, relevant architecture and code. Ask all known questions up front, grouped by topic, with options, tradeoffs and a recommendation where useful. Cover ownership, public contracts, compatibility, failure behavior, exclusions and acceptance. Raise follow-ups when answers or new evidence reveal another decision. Record decisions in `interview.md`; do not reopen settled choices without new evidence. Agree the shape before drafting the proposal.
2. **Propose.** Write `proposal.md` and `tasks.md`. The proposal defines scope, placement, contracts, ownership, invariants, faults and exclusions. Tasks define the implementation order, affected APIs, completion criteria and scoped validation commands. Specify tests in full in one canonical annex or executable test file referenced by the tasks. Include required spec deltas and a PR plan based on reviewable behavior. For uncertain numerical, performance or platform work, identify the assumptions and bounded prototypes needed before dependent implementation; record their evidence here. Obtain approval of the proposal and tasks from the owner or designated reviewer before production implementation.
3. **Apply.** Implement the approved tasks within the delegated scope. Tests are delegated to the agent by default. Keep artifacts current when implementation reveals a necessary change. Ask follow-up questions for unresolved contract, ownership or scope decisions; routine implementation choices within the approved contract do not need another approval.
4. **Review.** Review the diff against the approved artifacts, milestone exit criteria, style and applicable skills. Report actionable findings as `file:line:fix`. Distinguish defects and contract violations from optional improvements. Keep check results and reviewer responses in change evidence and PRs. Resolve findings, then obtain a `MERGE` verdict for the final head. Merge only with every required CI check passing at that head; a result from a superseded head never gates a merge.
5. **Sync.** Verify the PR is `MERGED` and record its merge commit before final close-out. Complete the change artifacts with delivered behavior, divergences, acceptance evidence and carried-forward work. Mirror proposal, tasks/specs and close-out to one Notion Changes page. Correct affected architecture and product documentation in place to describe current contracts and behavior; keep test logs, pass counts, validation receipts and review history in the change record. Update milestone status and affected downstream handoffs with links to the record. Read back the changed records once to verify the update; do not rewrite unchanged pages.
6. **Archive.** Archive the local OpenSpec change and mark its Notion record `[Archived]` after required work and synchronization are complete. Preserve intentionally deferred work as open items. Synchronize the checkout and remove only verified task-owned, merged branches and temporary checkouts. Report an archive-tool failure accurately and use a verified in-tree fallback when appropriate; do not claim a failed command succeeded.

Trivial corrections with already agreed scope may collapse to apply, review and sync. Milestones retain the interview and approved proposal/tasks stages unless the owner explicitly waives them. A waiver applies only to its stated task. Keep one current version of each artifact and link to it from review requests; avoid copying the full design into every comment or status update.

## Change artifacts

- `openspec/` is in `.gitignore`. No proposal, spec delta, or task list is committed or pushed.
- Notion is the durable record: Development, Milestones for the plan; Development, Changes for the per-change record.
- Validation reports, experiment logs, test receipts, proposal history and review discussions live in the change artifacts, their Notion mirror or PR evidence (section 2).

## Authoring

- Bound the change by approved behavior and acceptance. If investigation changes its scope materially, review the plan before expanding dependent work.
- Tests ship in the same change, written against the milestone's exit criteria.
- No drive-by refactors. A refactor is its own change, made on the second pain, with behavior unchanged.
- Read your own diff once, top to bottom, before committing (section 5).
- PR size is advisory. Roughly 500-line slices and the 1,000-line guideline are prompts to assess reviewability, never mandatory limits. Split at independently reviewable behavior or dependency boundaries. Keep tightly coupled implementation, tests and documentation together when splitting adds only review and CI cycles. Each slice builds and passes its scoped checks; each merge still requires final-head review and CI. Design the change as one unit and record the chosen PR boundaries in `tasks.md`.

## Reviewing

The reviewer uses `docs/style.md` and the applicable section 3 skills, reusing already loaded guidance. Review against the approved proposal/tasks/specs, milestone exit criteria, affected architecture and sections 6 to 9. Flag concrete correctness, contract and style violations; a missing defensive check is not automatically a defect (section 9). Review fixes against the finding and affected behavior; broaden the review when a fix changes the contract or exposes another problem. The review procedure (inputs, checkout, checks, runs, findings, verdict, authority) is in [REVIEW.md](REVIEW.md).

## Coordination

- When parallel agent work is authorized, give each participant a bounded assignment with inputs, owned files, expected output and completion criteria. Keep one owner for integration and shared files.
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
