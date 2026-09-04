Mirror of `docs/style.md`. The repository copy is canonical. Mandatory for every `.c3`, `.c3i`, and `.glsl` file. Based on gpu.c3l's `docs/contributing/style.md`; sections 5, 6, 10, 11, 12, 18, and 19 carry the c3d-specific rules. `AGENTS.md` sections 6 to 9 reference this file and add nothing that relaxes it.

# 1. Language target

C3 0.8.3. C3 is pre-1.0; check syntax against the installed compiler and the `c3-expert` skill, not memory.

# 2. Modules and files

| Module | Contents |
| --- | --- |
| `module c3d;` | Ids and root faults. `src/c3d/types.c3`, `src/c3d/faults.c3`. |
| `module c3d::pool <Type, IdType>;` | The generic pool, `src/c3d/pool.c3`. A generic module rather than a generic struct, because C3 rejects methods on a generic struct declared in a non-generic module. |
| `module c3d::<area>;` | One directory per architecture module: `maths`, `ecs`, `asset`, `scene`, `geometry`, `camera`, `material`, `light`, `anim`, `physics`, `platform`, `render`, `shader`, `post`, `rt`, `gui`. Public declarations in `<area>.c3i` where an interface file helps; otherwise one `.c3` per topic. |
| `module c3d::<area>::<sub>;` | Submodules named in the architecture: `asset::gltf`, `asset::fbx`, `asset::image`, `anim::ik`, `anim::retarget`, `gui::backend`, `ecs::store`. |
| `module c3d::<area>::internal @private;` | Implementation that must not be visible outside the area. Use only when a symbol would otherwise leak into the public surface. |

Every module is `c3d` or a submodule of it. The repository directory name never appears in source. Dependency imports are confined per `AGENTS.md` section 1; `scripts/build.py` checks them.

# 3. Naming

| Kind | Case | Examples |
| --- | --- | --- |
| Variables, fields, parameters | `snake_case`, descriptive | `renderer`, `asset_store`, `geometry_id`, `upload_ring` |
| Functions, methods, macros | `snake_case` | `create_scene`, `ensure_geometry`, `@each` |
| Structs, enums, typedefs, aliases | `PascalCase` | `AssetStore`, `TextureRes`, `GeometryId` |
| Constants and enum values | `SCREAMING_SNAKE_CASE` | `FRAMES_IN_FLIGHT`, `MATERIAL_STRIDE`, `DYNAMIC` |
| Modules | lowercase, `::`-separated | `c3d::asset::gltf` |
| Files | `snake_case.c3` | `upload_ring.c3`, `shadow_atlas.c3` |

Single-letter names only for loop counters and coordinate math inside scopes under ten lines. Abbreviations are allowed only from the architecture vocabulary (`rt`, `gpu`, `uv`, `sh`, `ik`, `abi`, `hdr`); `r`, `mgr`, `ctx`, `tmp`, `buf` are rejected. Ids end in `Id`, GPU-layout structs end in `Gpu`, root structs end in `Root`, renderer mirrors end in `Res`.

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
Scene scene = scene::create_scene(mem);
defer scene::destroy_scene(&scene);
```

Methods are for operations on an existing receiver that are not lifecycle operations: `scene.add_mesh`, `renderer.render`, `window.poll`, `assets.mark_dirty`. Container operations on a receiver (`add_*`, `remove_*`, `get`) are methods; they do not create or destroy the receiver.

`X` owns; `XView` borrows and has no destructor. GPU objects live only in `c3d::render` mirrors; the asset store owns CPU assets; the scene owns nodes.

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

- Do not use bool out-parameters, null returns, `-1` sentinels, or global error state.
- Use the most specific fault that fits. gpu.c3l faults propagate unchanged with `!`; they are never wrapped.
- One `faultdef` per domain, one fault per line, in `faults.c3` for the root module and in the area's own `faults.c3` when it has faults of its own.
- A precondition only a programming error can violate is a `@require` contract, never a runtime branch. An operational failure (input data, capacity, I/O, device, a dead id at an API entry point) is a fault. Runtime `assert` appears only under `test/`.
- `$assert` layout pins are required on every ABI-visible struct.

# 8. Handles and ids

Use the typed id: `GeometryId geometry`, not `uint geometry`; `gpu::TextureHandle texture`, not `ulong texture`. Ids are generational distinct typedefs of `Id` (never `inline`); a stale id resolves to nothing. Every pool is `Pool{Type, IdType}` and takes only its own id type; `Id` and an id type meet only inside `pool.c3`, and no cast between them appears anywhere else.

# 9. Call formatting

A call with four or more arguments, or wider than 120 columns, uses named arguments, one per line, trailing comma:

```c3
gpu::cmd_draw_indexed(
    commands:       &commands,
    vertex_root:    root,
    fragment_root:  root,
    indices:        geometry.indices,
    index_type:     geometry.index_type,
    index_count:    geometry.index_count,
    instance_count: 1,
)!;
```

Calls with three or fewer arguments may stay positional.

# 10. Declarations and initializers

- Wrapped declarations continue with two spaces of indentation past the declaration start.
- Every supplied field in a struct initializer uses `.field = value`. Positional initialization is allowed only for vectors and for arrays of scalars.
- `defer` follows the acquisition it releases, on the next line.
- Prefer `switch` over `if` chains on an enum; every `switch` on an enum is exhaustive without `default`.

# 11. Braces and indentation

K&R, four spaces, no tabs:

```c3
fn void? ensure_geometry(Renderer* renderer, GeometryId id) {
    GpuGeometry* mirror = &renderer.geometries[id.index];
    if (mirror.asset != id) {
        return upload_geometry(renderer, id);
    }
    return {};
}
```

# 12. Docstrings

Every public function, method, macro, constant, and type carries a `<* ... *>` docstring. Nothing private does. The order is:

```
summary line
@param entries in declaration order
@return or @return? entry
@require, @ensure, @pure, @deprecated
```

- The summary is one line, the purpose of the entity, not how it does it. No "this function", no "returns" as the first word, no restatement of the name. Under about twelve words. A second line is allowed only for one dangerous property: "Invalidates component pointers of the same store."
- `@param [mode] name : "Phrase."` for every pointer parameter, with its mode (`[&in]`, `[in]`, `[&out]`, `[&inout]`, `[inout]`), and for any parameter whose meaning or unit is not already in its name and type. A parameter the name explains is not documented.
- `@return "Phrase."` only when the name does not make the value obvious. `@return? FAULT_A, FAULT_B` lists every fault the function can produce and is mandatory on every optional return.
- `@require` for preconditions that are programming errors. `@require` is executable; never put a recoverable condition in it: invalid handles, missing capabilities, resources in use, exhaustion, timeouts, device loss. Those are faults.
- `@ensure` only for an invariant the caller relies on. `@pure` where true.
- Phrases are quoted, start with a capital, end with a period, and stay under about ten words.
- No step lists, history, rationale, or examples. Rationale lives in the architecture pages.

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
 @require self.joints.len >= 2
*>
fn void IkChain.solve(&self)

// Slot size of one material block in the material heap.
const usz MATERIAL_STRIDE = 256;
```

# 13. Comments

Inline comments explain why, not what: an invariant, a deliberate asymmetry, a hardware or backend quirk, a layout requirement that `$assert` cannot express. As short as possible. A field or block that needs a comment to be understood is renamed or restructured instead. A number that needs a comment becomes a named constant; a tunable constant states its why and cost in a trailing comment.

# 14. Current state only

Code and shipped documentation describe current behavior. No schedules, roadmap labels, ticket ids, milestone names, change ids, or history in identifiers, file names, comments, docstrings, test names, string literals, or `debug_name` values. `AGENTS.md`, `docs/`, and `scripts/` are exempt.

# 15. Public signature hygiene

Public `c3d` signatures never contain `gpu::`, `sdl::`, `imgui::`, `cg::`, `b3::`, or C-binding types except where the architecture names an escape hatch: `PhysicsWorld.world` (a `b3::WorldId`), `PhysicsWorld.body` (a `b3::BodyId`), custom-shader SPIR-V, and the `gpu::GpuAddress` values a custom material root receives. Scene-layer modules never import `gpu`.

# 16. Shaders

Explicit `set`/`binding` and `location`. `std430` for root and table data. Shared structs come from `abi/c3d.abi` through `gen_abi.py`; a constant mirrored by hand names its twin on both sides. No `vec3` in shared structs. Vertex outputs use the fixed locations from 08 Shader System. Shaders use GL conventions; no shader flips Y.

# 17. Debug names

Every resource descriptor accepts `debug_name`. Use descriptive `snake_case`: `hdr_color`, `shadow_atlas`, `upload_ring_0`, `material_heap`, `imgui_font_atlas`.

# 18. Tests

`@test` functions with `snake_case` names that state the behavior: `test_stale_id_does_not_resolve`, `test_reparent_keeps_world_position`. Assert the specific fault on fault paths. Tests cover contracts and invariants that can break; no tests for trivial accessors, none that restate the implementation, no GPU mocks, no GPU tests in CI. One file per group under `test/`.

# 19. Formatting tools

No whole-tree auto-formatting and no `c3fmt`. Hand-format to this guide. Avoid whitespace-only rewrites.

# 20. Checklist

A change is style-compliant when:

- names follow the table in section 3 and are descriptive;
- public lifecycle uses `create_x` / `destroy_x` free functions;
- every `create_x` takes an allocator and its `destroy_x` frees with it;
- faults are specific, contracts hold only programming-error preconditions, no `assert` outside `test/`;
- public signatures leak no bindings beyond the named escape hatches;
- calls with four or more arguments use the named multiline form;
- initializers use `.field = value`;
- docstrings follow section 12 and comments explain why;
- no development labels appear in code;
- `scripts/build.py --test` is green.
