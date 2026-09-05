Entry point for every agent session in this repository. Read it fully before reading or writing code. The repository copy is canonical; this Notion mirror follows it.

# 1. Project facts

- **Project:** `c3d`, a scene-level 3D rendering library with an ECS scene, physics, animation, and asset import. Not a game engine; a base for one.
- **Language:** C3 **0.8.3**. C3 is pre-1.0. Verify syntax against the installed compiler and the `c3-expert` skill, never against memory of another version.
- **Shading language:** GLSL, Vulkan 1.3 semantics through gpu.c3l. Files are `<name>.<stage>.glsl`; shared includes are plain `.glsl`. SPIR-V is built offline by `scripts/build_shaders.py` and embedded with `$embed`.
- **Module root:** `c3d`. Every module is `c3d` or a submodule of it (`c3d::render`, `c3d::asset::gltf`). The repository directory name never appears in source.
- **Build tooling:** `scripts/build.py` is the entry point; it drives ABI codegen, shader compilation, the import-boundary check, `c3c build`, and optionally `c3c test` and `c3c run`. Python 3.10+ standard library only, under `scripts/`, only for build orchestration and code generation.
- **Dependencies** (git submodules under `lib/`, pinned):

| Library | Module | Imported only by |
| --- | --- | --- |
| gpu.c3l | `gpu` | `c3d::render`, `c3d::shader`, `c3d::post`, `c3d::rt`, `c3d::gui::backend`; `c3d::platform` may import `gpu::surface` only |
| sdl3.c3l | `sdl` | `c3d::platform` |
| c3imgui.c3l | `imgui` | `c3d::gui` |
| c3cg.c3l | `cg` | `c3d::geometry` |
| box3d.c3l | `b3` | `c3d::physics` |
| stb_image (C source) | `c3d::asset::image` bindings | `c3d::asset::image` |
| ufbx (C source) | `c3d::asset::fbx` bindings | `c3d::asset::fbx` |

Boundaries are enforced by grep in CI. No dependency is added without updating this table.

# 2. Where truth lives

- Project root: [C3 Rendering Project](https://app.notion.com/p/3cfcb7903a5880fbba9bcdadb3bb61c3)
- Architecture (master and per subsystem): [Architecture](https://app.notion.com/p/3cfcb7903a58819dacdfdcf2492a7879), start at `00 Master Architecture`
- Milestones and tasks: [Milestones](https://app.notion.com/p/3cfcb7903a58810e9424f58b86397eda) under Development
- Style baseline (mandatory): `docs/style.md` in the repository, ported from gpu.c3l's `docs/contributing/style.md` and extended with the allocator, initializer, contract, and docstring rules of the [Style Guide (docs/style.md)](https://app.notion.com/p/3bccb7903a5881089469c7001fa88d7c). Section 6 of this file refines it; nothing here relaxes it.
- Change records (OpenSpec mirrors, one page per change): [Changes](https://app.notion.com/p/3cfcb7903a5881da8d4cdc33909a6a24) under Development

Work items name the architecture sections to read. Read those and nothing else until the item says otherwise.

# 3. Skills, mandatory

Load before reading or writing a line of code. A review or change made without them is invalid.

- `c3-expert`: any C3 reading, writing, or reasoning; `project.json`, `manifest.json`, build configuration; any `c3c` diagnostic. Threshold: more than about five lines of C3 read or written without it this session means stop and load it.
- `c3-style`: any `.c3` or `.c3i` file written or reviewed.
- `c3-bindings`: anything that crosses into gpu.c3l, sdl3.c3l, c3imgui.c3l, c3cg.c3l, box3d.c3l, or the `extern fn` declarations for stb_image and ufbx.
- `shader-dev`, when installed: GLSL technique (BRDF, shadows, post effects). Dispatch shape, barriers, and the binding contract stay with the style guide and gpu.c3l's `docs/shader_abi.md` and `docs/cookbook.md`.

The skills live in `.claude/skills/`, which is gitignored. A session that cannot list them is not a working session.

# 4. Session protocol

1. Read this file and `docs/style.md`.
2. Read the milestone page for the assigned work and the architecture sections it names.
3. Load the skills in section 3.
4. Implement the scoped task. Tests land in the same change where the milestone lists them.
5. Run the milestone's acceptance commands. Not green and not fixable in scope: report, do not force.

One milestone is active at a time. Do not pull work from a later milestone into an idle lane. Every code change runs through the change lifecycle in section 13; no change exists outside one.

# 5. Build and verification

From the repository root:

```bash
python3 scripts/build.py                  # regenerate ABI and shaders, check boundaries, build all examples
python3 scripts/build.py --test           # same, then run every test target
python3 scripts/build.py --check --test   # CI: generated files must be current; build; test
python3 scripts/build.py --example cube   # build and run one example
python3 scripts/build.py --init-deps      # first checkout: submodules and native dependency builds
python3 scripts/build.py --clean
```

Steps run in this order and stop at the first failure: tools (c3c 0.8.3, glslang), deps (submodules present), abi (`gen_abi.py`, which builds gpu.c3l's `gen_shader_abi` tool with `c3c build --path lib/gpu.c3l/tools/gen_shader_abi` on first use), shaders (`build_shaders.py`), boundaries (the section 10 import rules), build (every target in `examples/project.json`, or `--target`), test (every target in `test/project.json`), run. `--skip-abi`, `--skip-shaders`, `--skip-build`, and `--opt O3` narrow a run; `-v` prints each command.

Before every commit: `scripts/build.py --test`. Broken builds are never committed. GPU examples run manually; CI runs `--check --test`. Every development run of a GPU example uses gpu.c3l full validation.

# 6. Style

The baseline is `docs/style.md`: naming, K&R braces, four-space indentation, two-space wrapped declarations, named arguments at four or more call arguments with a trailing comma, `.field = value` in every struct initializer, definition order (typedefs, aliases, constants, enums and bitstructs, structs, struct methods, free functions), optionals and named faults for every operational failure, `defer` for cleanup, one `faultdef` file per domain with one fault per line, never `c3fmt`, no development terminology in code.

Project refinements:

- **Names are descriptive.** `Renderer renderer`, `AssetStore assets`, `GeometryId geometry_id`. Single letters only for loop counters and coordinate math in scopes under ten lines. No abbreviations that are not already in the architecture vocabulary (`rt`, `gpu`, `uv`, `sh`, `ik` are vocabulary; `r`, `mgr`, `ctx`, `tmp` are not).
- **Contracts are the precondition mechanism.** A precondition that only a programming error can violate is a `@require` in the docstring, not a runtime branch. An operational failure (input data, capacity, I/O, device, a dead id at an API entry point) returns a named fault. Runtime `assert` appears only under `test/`. `$assert` layout pins are required on every ABI-visible struct.
- **Happy path.** No defensive checks on internal paths. A function trusts its contract and the invariants of the structs it receives. `try_get` exists at API entry points; inside the renderer, `get` with a contract.
- **Ids** live in `src/c3d/types.c3`; `std::math` supplies the vector, matrix and quaternion types, and c3d declares no aliases for them. Faults for the root module live in `src/c3d/faults.c3`; a module with its own faults has its own `faults.c3`.
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

- Prefer the simplest implementation that satisfies the architecture. Recompute over cache; fixed capacity over growth; one allocation per resource; enums and switch over dispatch. Add complexity only when a measurement on this codebase demands it, and record the measurement in the milestone page.
- No speculative generality: no configuration for a case the milestones do not name, no abstraction with one implementor, no hooks nobody calls.
- No over-checking: no null checks on pointers the contract says are non-null, no range checks on indices produced by the module itself, no validation of data that gpu.c3l already validates, no defensive copies.
- No over-testing: tests cover contracts and invariants that can break (math identities, pool generations, ECS store invariants, transform hierarchies, geometry packing, animation sampling, parser output, the asset revision protocol). No tests for trivial accessors, no tests that restate the implementation, no mocks of the GPU device, no GPU tests in CI. One test file per group under `test/`, ordinary `@test` functions named `test_<what_it_checks>`. Fault-path tests assert the specific fault.
- A missing defensive check is not a bug. A suspected cost is not a bottleneck until measured.

# 10. Architecture rules

- Two layers. Scene-layer modules (`c3d`, `c3d::maths`, `c3d::ecs`, `c3d::asset`, `c3d::scene`, `c3d::geometry`, `c3d::camera`, `c3d::material`, `c3d::light`, `c3d::anim`, `c3d::physics`) never import `gpu`. The render layer (`c3d::render`, `c3d::shader`, `c3d::post`, `c3d::rt`, `c3d::gui`) owns every GPU object. `c3d::platform` imports `gpu::surface` alone, to hand native window handles to gpu.c3l; a bare `import gpu` there is a violation.
- The renderer reads the scene; the scene never calls the renderer. Loaders write the asset store and the scene; they never touch the renderer.
- All shader-visible data is std430 behind root pointers and defined once in `abi/c3d.abi`. Per-draw push data is exactly two root addresses.
- Depth is reverse-Z; the Vulkan Y flip is one negative-height viewport; shaders use GL conventions and never flip.
- Pass order is fixed; barriers are explicit; the renderer tracks `TextureState` only for targets it owns.
- Every entity is a node; everything else about a node is a component. Systems are functions the application calls; there is no scheduler.
- `scripts/build.py` enforces these boundaries on every run (the `boundaries` step); the equivalent greps are:

```bash
grep -rn 'import gpu' src/c3d --include='*.c3' | grep -vE 'src/c3d/(render|shader|post|rt|gui)/'
grep -rn 'import sdl' src/c3d --include='*.c3' | grep -v 'src/c3d/platform/'
grep -rn 'import imgui' src/c3d --include='*.c3' | grep -v 'src/c3d/gui/'
grep -rn 'import cg' src/c3d --include='*.c3' | grep -v 'src/c3d/geometry/'
grep -rn 'import b3' src/c3d --include='*.c3' | grep -v 'src/c3d/physics/'
```

# 11. Directory map

```
c3d.c3l/
├── manifest.json
├── abi/c3d.abi             shared C3 and GLSL layouts
├── docs/style.md           mandatory style baseline
├── lib/                    gpu.c3l · sdl3.c3l · c3imgui.c3l · c3cg.c3l · box3d.c3l (submodules)
│                           plus c3d.c3l, a symlink to the root, so consumers resolve c3d here
├── linked-libs/            empty; every dependency ships its own native artifacts
├── csrc/                   stb_image · ufbx
├── src/c3d/
│   ├── types.c3            ids
│   ├── faults.c3           root-module faults
│   ├── pool.c3             the generic pool, module c3d::pool <Type, IdType>
│   ├── maths/ ecs/  asset/  scene/  geometry/  camera/  material/  light/  anim/  physics/
│   ├── platform/           the only sdl importer
│   ├── render/  shader/  post/  rt/                the gpu importers
│   └── gui/                the only imgui importer; gui/backend imports gpu
├── shaders/                GLSL sources, common/, generated/, variants.json
├── scripts/                build.py (entry point) · gen_abi.py · build_shaders.py
├── examples/               one executable per milestone
└── test/                   CPU tests, one file per group
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

Solo development runs OpenSpec customized around the human driving. The agent's output is understanding, documents, tests, and planned code; the human puts production code into files. One question at a time; options before recommendations; chunks over walls.

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

`--tools none` is mandatory: otherwise `openspec init` writes AI-tool instruction files and the `claude` profile overwrites this file. Verify a session by asking which skills are available; every skill in section 3 must list.

## The lifecycle

Every milestone task, or a tightly coupled group of tasks from one milestone, runs as one OpenSpec change through these steps in order:

1. **Brainstorm.** The agent reads the milestone page, the architecture sections it names, and the relevant code, then interviews the human one question at a time while the human shapes the design. Open decisions end as two or three options with tradeoffs, never a lone recommendation. No proposal is drafted before the shape is agreed.
2. **Propose.** Two documents. `proposal.md`: the design and its contracts: signatures, structs, invariants, faults, and where each lives. `tasks.md`: ordered tasks with implementation guidance: file placements, declarations, commands to run, and for every API the change touches what it expects, what it returns, which faults it can produce and what each means, and any precondition or ordering it imposes. Guidance, not prescription: the human may take a different shape or decomposition where they see a better one, and the close-out records where they did. Exception: tests are specified in full; test design and coverage are the agent's job, within the section 9 limits.
3. **Apply.** The human implements `tasks.md`. The agent advises (API lookups, math checks, fault diagnosis) and edits files only on explicit delegation of a named chunk. Tests are delegated to the agent by default.
4. **Review.** The agent diffs the work against `proposal.md` and `tasks.md` with `docs/style.md` and the section 3 skills loaded. Findings are `file:line:fix`, focused on divergences and discoveries; style was settled at proposal time. The review also checks the milestone's exit criteria and sections 6 to 9 of this file.
5. **Sync.** `proposal.md`, `tasks.md`, and a close-out (what changed, where reality diverged from the proposal, and why) are mirrored to Notion under Development, Changes, as one child page named after the change id.
6. **Archive.** `openspec archive`; the Notion page title gains `[Archived]`.

Steps 1 and 2 are one working session, 3 is the human's time, 4 to 6 are minutes. Trivial work collapses to 3 to 5; a milestone task never skips 1 and 2. The proposal and tasks pair is a decision record corrected by reality, not a spec the code must be synchronized to; divergences update the record.

## Artifacts never enter the repository

- `openspec/` is in `.gitignore`. No proposal, spec delta, or task list is committed or pushed.
- Notion is the durable record: Development, Milestones for the plan; Development, Changes for the per-change record.
- The only committed process artifacts are the ones section 8 exempts: `AGENTS.md`, `docs/`, and `scripts/`.

## Authoring

- One change is an evening to a weekend. If it grows past that, split it and land the first half.
- Tests ship in the same change, written against the milestone's exit criteria.
- No drive-by refactors. A refactor is its own change, made on the second pain, with behavior unchanged.
- Read your own diff once, top to bottom, before committing. `scripts/build.py --test` is green.

## Reviewing

The reviewer loads `docs/style.md` and every section 3 skill before reading a line; a review without them is not valid. Review against: the style guide, the change's `proposal.md` and `tasks.md`, the milestone's exit criteria, the architecture sections the milestone names, and sections 6 to 9 of this file. Flag every style violation, every docstring that narrates, every defensive check on an internal path, and every test that restates its implementation.

## Project-instructions block

Paste into `openspec/config.yaml` under `context` after `openspec init`:

```markdown
# c3d, OpenSpec customizations

- Replace the explore phase with an interview: read the milestone page,
  the architecture sections it names, and the code, then ask the human
  questions one at a time; end open decisions as two or three options
  with tradeoffs. Do not draft a proposal before the shape is agreed.
- proposal.md = design plus contracts (signatures, structs, invariants,
  faults, placement). tasks.md = ordered tasks with implementation
  guidance: placements, declarations, commands, and for every API the
  change touches what it expects, what it returns, which faults it can
  produce and what each means, plus preconditions and ordering.
  Guidance, not prescription. Tests are specified in full, within the
  AGENTS.md section 9 limits: no over-testing.
- The human implements. Do not edit source files unless a named chunk
  is explicitly delegated. Tests are delegated to you by default.
- All code anywhere, including skeletons in tasks.md, follows the
  repository AGENTS.md sections 6 to 9 (style, docstrings, comments,
  KISS) and is written with c3-expert, c3-style, c3-bindings, and
  shader-dev when installed, loaded.
- Sync = mirror proposal.md, tasks.md, and the close-out (divergences
  and why) to Notion under Development, Changes. Archive = openspec
  archive plus retitle the Notion page with [Archived]. openspec/ is
  gitignored; never commit or push its contents.
```
