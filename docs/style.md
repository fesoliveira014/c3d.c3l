The code style baseline, mandatory for every `.c3`, `.c3i` and `.glsl` file in this repository, and the single home of the code-style rules. Based on gpu.c3l's `docs/contributing/style.md`, extended with the allocator, initializer, contract and docstring rules of this project. [AGENTS.md](../AGENTS.md) sections 6 to 9 point here and add nothing that relaxes it; the module map is in [architecture.md](architecture.md).

# 1. Language target

C3 0.8.3. C3 is pre-1.0; check syntax against the installed compiler and the `c3-expert` skill, not memory.

# 2. Modules and files

| Module | Contents |
| --- | --- |
| `module c3d;` | Ids, root faults and the neutral `ParallelFor` hook. `src/c3d/types.c3`, `src/c3d/faults.c3`, `src/c3d/parallel.c3`. |
| `module c3d::pool <Type, IdType>;` | The generic pool, `src/c3d/pool.c3`. A generic module rather than a generic struct, because C3 rejects methods on a generic struct declared in a non-generic module. |
| `module c3d::<area>;` | One directory per architecture area, listed in [architecture.md](architecture.md). Public declarations in `<area>.c3i` where an interface file helps; otherwise one `.c3` per topic. |
| `module c3d::<area>::<sub>;` | Submodules named in the architecture: `asset::gltf`, `asset::fbx`, `asset::image`, `asset::custom <Type>`, `anim::ik`, `anim::retarget`, `spatial::bvh`, `render::post`, `gui::backend`, `ecs::store`, `shader::compile` (gated by `@feat(C3D_SHADER_COMPILER)`). A submodule that records with the renderer's private helpers opens them with `import c3d::render @public;`. |
| `module c3d::<area>::internal @private;` | Implementation that must not be visible outside the area. Use only when a symbol would otherwise leak into the public surface. |
| `module c3d::<package>[::<sub>] [@feat(FLAG)];` | A module of an add-on package, under the `c3d` root, in `addons/<name>.c3l/src/`. A module that exists only under a feature carries `@feat(FLAG)` in its declaration. A package module that needs another module's private helpers opens that module with `@public`, as `c3d::physics::cloth` does with `c3d::physics`. |

The module root, the rule that the repository directory name never appears in source, and the import boundaries are in [AGENTS.md](../AGENTS.md) section 1.

`import c3d;` imports every `c3d` submodule recursively, so a name declared in one area can collide inside another. Qualify the module when it does: `time::Clock` inside `c3d::render`, because `c3d::platform` declares a `Clock` of its own.

# 3. Naming

| Kind | Case | Examples |
| --- | --- | --- |
| Variables, fields, parameters | `snake_case`, descriptive | `renderer`, `assets`, `geometry_id`, `upload_ring` |
| Functions, methods, macros | `snake_case` | `create_scene`, `resolve_geometry`, `@each` |
| Structs, enums, typedefs, aliases | `PascalCase` | `AssetStore`, `TextureRes`, `GeometryId` |
| Constants and enum values | `SCREAMING_SNAKE_CASE` | `FRAMES_IN_FLIGHT`, `MATERIAL_STRIDE`, `DYNAMIC` |
| Modules | lowercase, `::`-separated | `c3d::asset::gltf` |
| Files | `snake_case.c3` | `upload_ring.c3`, `shadow_atlas.c3` |

`fault` is a reserved type keyword, so it is never an identifier: bind a caught value as `excuse`, the term the C3 docs use. Single-letter names only for loop counters and coordinate math inside scopes under ten lines. Abbreviations are allowed only from the architecture vocabulary (`rt`, `gpu`, `uv`, `sh`, `ik`, `abi`, `hdr`); `r`, `mgr`, `ctx`, `tmp`, `buf` are rejected. Ids end in `Id`, GPU-layout structs end in `Gpu`, root structs end in `Root`, and renderer mirrors usually end in `Res` (`TextureRes`). camelCase appears nowhere. `std::math` supplies the vector, matrix and quaternion types; c3d declares no public aliases for them, and a module may declare a `@private` alias for its own use.

# 4. Definition order

Within a file, or within each banner section of a file grouped by domain:

```
1. Typedefs
2. Aliases
3. Constants
4. Enums / bitstructs
5. Structs
6. Struct methods
7. Free functions
```

# 5. Lifecycle functions

Project-owned resources use free functions: `create_x` / `destroy_x`. Not `Scene.create` or `Renderer.destroy`.

```c3
Scene scene = scene::create_scene(mem, scene::default_scene_desc());
defer scene::destroy_scene(&scene);
```

Methods are for operations on an existing receiver that are not lifecycle operations: `scene.add_mesh`, `renderer.render`, `window.poll`, `assets.mark_geometry_dirty`. Container operations on a receiver (`add_*`, `remove_*`, `get`) are methods; they do not create or destroy the receiver.

`X` owns; `XView` borrows and has no destructor. GPU objects live only in `c3d::render` mirrors; the asset store owns CPU assets; the scene owns nodes.

Inside the renderer, two verbs name idempotent first-use work; neither validates anything:

- `resolve_x` returns the current GPU record for an asset id, uploading on first sight or when the asset revision moved: `resolve_geometry`, `resolve_texture`, `resolve_palette`.
- `acquire_x` creates a renderer- or view-owned resource once and returns silently when it already exists; its counterpart is `retire_x`, `release_x` or `destroy_x`: `acquire_ao_images` / `release_ao_history_images`, `acquire_shadow_atlas` / `destroy_shadow_atlas`.

# 6. Allocation and memory

- Every `create_x` takes an `Allocator` first and stores it; the matching `destroy_x` frees with it. No hidden global allocation.
- Per-frame temporaries use `tmem` inside `@pool()`; the scope is owned by the function that begins the frame or the load.
- Fixed capacity over growth. Pools and mirror tables are sized at creation from a `Desc`; growth is a deliberate later change with a measurement behind it.
- `add_*` on the asset store copies arrays into the store allocator so callers may build in `tmem`; `add_*_owned` transfers ownership without a copy.

# 7. Errors and contracts

Fallible operations return `T?` or `void?` and fail with a named fault:

```c3
fn GeometryId? AssetStore.add_geometry(&self, Geometry* geometry, String key = "");
return CAPACITY_EXCEEDED~;
```

- Do not use bool out-parameters, null returns, `-1` sentinels, or global error state. `unreachable()` never stands in for a failure that can occur at runtime.
- Use the most specific fault that fits. gpu.c3l faults propagate unchanged with `!`; they are never wrapped.
- One `faultdef` per domain, one fault per line, in `faults.c3` for the root module, and in a module's own `faults.c3` when the module has faults of its own.
- A precondition only a programming error can violate is a `@require` contract, never a runtime branch. An operational failure (input data, capacity, I/O, device, a dead id at an API entry point) is a fault. Runtime `assert` appears only under `test/`.
- `$assert` layout pins are required on every ABI-visible struct.

# 8. Handles and ids

Ids live in `src/c3d/types.c3`; an add-on declares its own ids in its package. Use the typed id: `GeometryId geometry`, not `uint geometry`; `gpu::TextureHandle texture`, not `ulong texture`. Ids are generational distinct typedefs of `Id` (never `inline`); a stale id resolves to nothing. Every pool is `Pool{Type, IdType}` and takes only its own id type; `Id` and an id type meet only inside `pool.c3` and in the `AssetStore.find_*` adapters that unpack an `AssetRef`, and no cast between them appears anywhere else. A custom asset kind's id is `custom::CustomId{T}`, a struct rather than a typedef so that ids of two kinds cannot be cast into each other; `asset::custom_ref` and `asset::custom_id` are its `AssetRef` adapters. A model document holds references to its own entries as typed ids with the entry index plus one at generation 0, built and read only by the two reference helpers in `asset/document.c3`.

# 9. Call formatting

A call with four or more arguments, or wider than 120 columns, uses named arguments, one per line, trailing comma:

```c3
gpu::cmd_draw_indexed(
    commands:       &commands,
    vertex_root:    root,
    fragment_root:  root,
    index_span:     geometry.indices,
    index_count:    geometry.index_count,
    instance_count: 1,
    index_type:     geometry.index_type,
)!;
```

Calls with three or fewer arguments may stay positional.

# 10. Declarations and initializers

- Function and method signatures with more than three parameters, including an explicit receiver, put one parameter per line, indented four spaces. Keep `(` on the declaration line, use a trailing comma after the last parameter, and put `)` on its own line with the opening brace and any attributes.
- Other wrapped declarations continue with two spaces of indentation past the declaration start.
- Every supplied field in a struct initializer uses `.field = value`. Positional initialization is allowed only for vectors and for arrays of scalars.
- `defer` follows the acquisition it releases, on the next line.
- Prefer `switch` over `if` chains on an enum; every `switch` on an enum is exhaustive without `default`.
- Member access on a pointer uses `.`, never `->`. A type's size is `Type::size`, never `sizeof`.

# 11. Braces and indentation

K&R, four spaces, no tabs:

```c3
fn GpuGeometry*? resolve_geometry(Renderer* renderer, GeometryId geometry) {
    GpuGeometry* mirror = &renderer.geometries[geometry.index];
    if (geometry_current(renderer, geometry)) {
        return mirror;
    }

    renderer.upload_geometry(geometry)!;
    return mirror;
}
```

Separate logical blocks within a function with blank lines: setup, resource acquisition, data preparation, recording, and return or cleanup. Keep related statements together and keep an acquisition adjacent to its cleanup `defer`; do not insert a blank line after every statement.

# 12. Docstrings

Every public function, method, macro, constant, and type carries a `<* ... *>` docstring. Nothing else does. The order is:

```
summary line
@param entries in declaration order
@return or @return? entry
@require, @ensure, @pure, @deprecated
```

- The summary is one line, the purpose of the entity, not how it does it. No "this function", no "returns" as the first word, no restatement of the name. Under about twelve words. One dangerous property, when there is one, goes in the description as a second line, and a second line holds nothing else: "Invalidates component pointers of the same store.", "Exits without running defers."
- Use only the official directives: `@param [mode] name : "..."`, `@return "..."`, `@return? FAULT_A, FAULT_B`, `@require`, `@ensure`, `@pure`, `@deprecated`.
- `@param [mode] name : "Phrase."` for every pointer parameter, with its mode (`[&in]`, `[in]`, `[&out]`, `[&inout]`, `[inout]`), and for any parameter whose meaning or unit is not already in its name and type. A parameter the name explains is not documented.
- `@return "Phrase."` only when the name does not make the value obvious. `@return? FAULT_A, FAULT_B` lists every fault the function can produce and is mandatory on every optional return.
- `@require` for preconditions that are programming errors. `@require` is executable; never put a recoverable condition in it: invalid handles, missing capabilities, resources in use, exhaustion, timeouts, device loss. Those are faults.
- `@ensure` only for an invariant the caller relies on. `@pure` where true.
- Phrases are quoted, start with a capital, end with a period, and stay under about ten words.
- Narration is a defect: no step lists, history, rationale, or examples. Rationale lives in the architecture pages.

```c3
<*
 Add a geometry asset and return its id.
 @param [&in] geometry : "Arrays are copied into the store allocator."
 @return? CAPACITY_EXCEEDED, INVALID_ARGUMENT
*>
fn GeometryId? AssetStore.add_geometry(&self, Geometry* geometry, String key = "")

<*
 Solve the chain so its end joint reaches the target.
 Writes local rotations only.
 @require ik_chain_valid(self)
*>
fn void IkChain.solve(&self)

<*
 Slot size of one material block in the material heap.
*>
const usz MATERIAL_STRIDE = 256;
```

Rejected on review:

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

# 13. Comments

Code is self-documenting: names carry meaning, structure carries flow. An inline `//` comment is allowed only on non-trivial code and only to state a why that the code cannot: an invariant, a deliberate asymmetry, a hardware or backend quirk, a layout requirement that `$assert` cannot express. As short as possible. A comment that says what the code does is a defect: delete it and improve the names. A field or block that needs a comment to be understood is renamed or restructured instead. A number that needs a comment becomes a named constant.

A tunable constant states its why and cost in a trailing comment:

```c3
const uint DEFAULT_CLOTH_SUBSTEPS = 4; // solve cost grows linearly; fewer substeps lag fast pins
```

# 14. Current state only

Code and shipped documentation describe current behavior. No development terminology anywhere in code: no schedules, roadmap labels, milestone names or numbers, ticket or PR references, `TODO` notes that name a milestone, change ids, plan vocabulary, or history in identifiers, file names, comments, docstrings, test names, string literals, or `debug_name` values. `AGENTS.md`, `docs/`, and `scripts/` are exempt.

# 15. Public signature hygiene

Public `c3d` signatures never contain `gpu::`, `sdl::`, `imgui::`, `cg::`, `b3::`, or C-binding types except where the architecture names an escape hatch: `PhysicsWorld.world` (a `b3::WorldId`), `PhysicsWorld.body` (a `b3::BodyId`), `PhysicsWorld.joint` (a `b3::JointId`), the `b3` ids the physics components hold (`RigidBody.body`, `Collider.shape`, `Joint.joint`), `Weld.joint` (a `b3::JointId`, read-only: applications do not mutate owned welds through it), `collide::Hull.data` and `collide::Shape.hull` (a `b3::HullData*`), custom-shader SPIR-V, the `gpu::GpuAddress` values a custom material root receives, and `c3d::platform`, whose `sdl::Window*` and `sdl::Event*` are exposed on purpose so an application can drive its own SDL loop. Scene-layer modules never import `gpu`.

# 16. Shaders

Explicit `set`/`binding` and `location`. `std430` for root and table data. Shared structs come from `abi/c3d.abi` through `gen_abi.py`; never hand-edit a generated file, and never change a layout on one side of the ABI only. A constant mirrored by hand names its twin on both sides, as in `// mirrored as SHADOW_CASCADES in shadows.glsl`. No `vec3` in shared structs. Vertex outputs use the fixed locations from 08 Shader System. Shaders use GL conventions; no shader flips Y. A public include (listed under `public_includes` in `shaders/variants.json`) includes every include it uses; the build compiles each after the two ABI headers alone.

# 17. Debug names

Every resource descriptor accepts `debug_name`. Use descriptive `snake_case`: `hdr_color`, `shadow_atlas`, `upload_ring_0`, `material_heap`, `imgui_font_atlas`.

# 18. Tests

Ordinary `@test` functions named `test_<what_it_checks>`, in `snake_case`, with a name that states the behavior: `test_stale_id_does_not_resolve`, `test_reparent_keeps_world_position`. Assert the specific fault on fault paths. One file per group under `test/`.

Tests cover contracts and invariants that can break: math identities, pool generations, ECS store invariants, transform hierarchies, geometry packing, animation sampling, parser output, the asset revision protocol. No tests for trivial accessors, none that restate the implementation, no mocks of the GPU device, and no GPU tests in CI.

# 19. Formatting tools

No whole-tree auto-formatting and no `c3fmt`: it is line-length aware but not argument aware, so it breaks the named-argument call format and the one-fault-per-line `faultdef`s. Hand-format to this guide. Avoid whitespace-only rewrites.

# 20. Checklist

A change is style-compliant when:

- names follow the table in section 3 and are descriptive;
- public lifecycle uses `create_x` / `destroy_x` free functions;
- every `create_x` takes an allocator and its `destroy_x` frees with it;
- faults are specific, contracts hold only programming-error preconditions, no `assert` outside `test/`, no `unreachable()` for a runtime failure;
- public signatures leak no bindings beyond the named escape hatches;
- calls with four or more arguments use the named multiline form;
- initializers use `.field = value`;
- docstrings follow section 12 and comments explain why;
- no development labels appear in code;
- no camelCase, no `->`, no `sizeof`, no `c3fmt` output, and no hand-edited generated file;
- the scoped validation required by `AGENTS.md` section 5 is green.
