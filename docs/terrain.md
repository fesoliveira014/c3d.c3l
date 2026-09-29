# Terrain

The `c3d_landscape` add-on (`addons/c3d_landscape.c3l`, module `c3d::landscape::terrain`) draws a
height-mapped ground from an `R16_UINT` height map. A `Terrain` component on a node selects, once per frame,
the level of each chunk of a quadtree for one camera. The selected chunks are the instances of the node's own
`InstancedMesh`, drawn with a custom material from the package's shaders, so they take part in every view,
shadow layer, depth prepass, G-buffer and velocity pass through core's instanced path. Up to four `STANDARD`
layer materials blend through an RGBA control map. CPU height queries follow the physics height-field
convention, so a height-field collider on the same node touches the drawn surface.

The package imports only the standard library and `c3d`; core never imports it and has no terrain feature
flag. Its root module `c3d::landscape` holds the generated constants of its shader package, including
`LANDSCAPE_SHADER_INCLUDES` for `compile_glsl(includes:)`.

```bash
python3 scripts/build.py --example terrain
```

## Select the package

List `c3d_landscape` before `c3d` in the application's `project.json`, with c3d's own dependencies. The
example and the collider below also select `c3d_physics` and `b3`:

```json
{
  "dependency-search-paths": [ "path/to/c3d.c3l/lib" ],
  "dependencies": [ "c3d_landscape", "c3d", "gpu", "vk", "vma", "spvreflect", "sdl3", "c3imgui", "c3cg", "cgltf", "ufbx", "shaderc" ]
}
```

## Calling order

```c3
terrain::register_terrain(&scene, &assets)!;
terrain::add_terrain(
    scene:  &scene,
    assets: &assets,
    node:   ground,
    desc:   desc,
)!;

scene.update_world();
terrain::update(
    scene:                &scene,
    assets:               &assets,
    camera_node:          camera,
    output_height_pixels: (float)output_height,
)!;
renderer.render_view(&scene, camera, view)!;
```

- `register_terrain` runs once per scene after `create_scene`. It registers `Terrain` and `TerrainRuntime`
  and installs the runtime's remove hook with the store; the store outlives the scene.
- `add_terrain` attaches a terrain to an existing node that carries no `InstancedMesh` and no `Terrain`, and
  builds everything at once: the bounds tree, the owned material and the node's `InstancedMesh`, with room for
  the finest chunk count. It faults as listed under [Faults](#faults) and then leaves the node and store as they
  were.
- `update` runs every frame after the camera and the terrain nodes moved and before the frame's first
  `render_view`. It refreshes changed bounds, selects every terrain's chunks and writes them into each batch in
  place. It allocates nothing and marks a batch only when its selection or its bounds changed, so a still
  camera uploads nothing. A fault from one terrain does not stop the others; `update` returns the first one.

Every view and shadow layer of the frame draws the selection of the camera given to `update`.

## TerrainDesc

`terrain::default_terrain_desc()` sets `lod_threshold = 512`, `lod_hysteresis = 0.25` and both shadow flags;
the maps, scales and layers are the application's. Every value is checked by `add_terrain` and faults rather
than asserts, since descs also come from files.

| Field | Rule |
| --- | --- |
| `height_map` | `R16_UINT`, one mip, 2D, square, `CHUNK_CELLS · 2ⁿ + 1` texels per side: 129, 257, 513, 1025, 2049 or 4097 |
| `control_map` | Optional linear `RGBA8_UNORM` weights of layers 0 to 3 over the whole extent; unset shows layer 0 alone |
| `cell_size` | Metres between texel centres along x and z; positive |
| `height_scale` | Metres at texel 65535: `height = height_scale × texel / 65535`; positive |
| `layers` | Up to four live `STANDARD` materials, leading; zero ids after the last one |
| `lod_threshold` | Projected chunk diameter in output pixels above which a chunk splits; zero or more |
| `lod_hysteresis` | A split chunk merges below `lod_threshold / (1 + lod_hysteresis)`; zero or more |
| `cast_shadow`, `receive_shadow` | Copied onto the batch at every `update` |

**Height maps.** `image::load_texture_r16` loads a 16-bit PNG as `R16_UINT`; an 8-bit file widens by 257, so
255 becomes 65535. Generated heights go through `AssetStore.add_texture` with
`material::texture_2d_desc(side, side, R16_UINT)` and `generate_mips = false`. The integer texture is read in
shaders through `gpu_fetch_uint` only; it is never sampled with a filter. Normals are filtered by hand in the
fragment stage, a bilinear blend of the central differences of the four surrounding texels, so they do not
depend on a chunk's level.

**Control map.** Its resolution is independent of the height map; the stage samples it with the terrain's
UV over [0, 1], divides by the weight sum and shows layer 0 where every weight is zero. Load it linear: an sRGB
format would curve the weights, so it faults `UNSUPPORTED`.

**Layers.** Each layer is an ordinary `STANDARD` material, referenced through the custom material's
`references` (see [materials](materials.md)). The stage samples every set layer on every pixel and blends the
samples by weight; a layer without tangents takes derivative normals. Tiling comes from each layer's own
`TextureSlot` transforms over `uv0`, which is terrain-local metres: a `scale` of 0.25 repeats a map every 4 m.

## Level of detail

The extent is a quadtree of chunks of `CHUNK_CELLS` = 128 cells per side at every level; level 0 is the
finest, and a 2049 map has five levels. Every chunk draws the same shared grid of 129 × 129 vertices plus a
skirt ring that hangs from its edges down to the chunk's lowest height, so neighbours at different levels
leave no crack. Skirts shade with the normal of the edge they hang from.

Each `update` walks the tree from the root over the whole extent. A chunk's size is
`camera::projected_size` of its bounding sphere at `output_height_pixels`, from the camera node's position: it
reads no camera rotation, so turning in place never re-selects. A chunk splits above `lod_threshold` and
merges below `lod_threshold / (1 + lod_hysteresis)`; a camera resting at a boundary does not flicker. Pass the
height of the output the threshold is tuned for; a view of another height sees chunks of the same levels.

A selection partitions the extent, so it never holds more chunks than the finest level: 64, 256 and 1,024 at
1025, 2049 and 4097. That is the batch capacity fixed at `add_terrain`. `lod_threshold = 0` selects the finest
level everywhere, the full-resolution grid through the same chunk instances.

`TerrainRuntime.chunks_per_level` and `lod_switches` report the last selection; the batch's `count` is its
size.

## The node

The node's world transform places texel (0, 0) at its origin, with texel columns along its x axis and rows
along its z axis. Its translation is the height offset: there is no offset field, so one transform places the
drawn surface, the queries and a collider alike. Rendering takes any transform; queries need translation and
rotation about Y only (a `@require` of `height_view`).

Larger worlds are tiles: one terrain node each, with its own collider. Skirts cover the cracks between tiles
at different levels.

## Height queries

```c3
HeightView view = terrain::height_view(&scene, &assets, ground.id)!;
float height = terrain::sample_height(&view, x, z)!;
Vec3 normal = terrain::sample_normal(&view, x, z)!;
```

- `height_view` captures the texels, side, scales and the node's world matrix; it allocates nothing, so build
  one per frame. It faults `c3d::INVALID_ID` for a dead node, a node without `Terrain` or a dead height map,
  and `UNSUPPORTED` or `INVALID_ARGUMENT` for a map that no longer passes `add_terrain`'s checks (a released
  CPU copy included).
- `sample_height` returns the world height on the height field's triangles: each cell splits along its
  diagonal from `(x + 1, z)` to `(x, z + 1)`, as box3d's height field does. `sample_normal` returns the face
  normal of that triangle. A point outside the extent is `NOT_FOUND`, never a clamp.
- The view borrows the store's texels. In-place edits keep it valid and it reads the new heights; replacing,
  releasing or removing the height map, or removing the terrain, invalidates it. It keeps the node transform
  of the moment it was taken. Several threads may read one view while nothing edits the texels.

## Physics collider

The terrain follows the physics height field's conventions: the same origin corner, row order, spacing, split
and `texel / 65535` scaling. Build the collider on the terrain node as a static body:

```c3
ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
collider.height_field = { .source = TEXTURE, .texture = desc.height_map };
collider.local.scale = { desc.cell_size, desc.height_scale, desc.cell_size };
physics.add_body(terrain_node, physics::default_body_desc(STATIC), (&collider)[:1])!;
```

Physics refuses a collider-local offset on a height field, which is why the node's translation is the offset.
The landscape test builds its collider with the same code and checks that `sample_height` equals a downward
ray cast at 1,024 points, before and after an edit.

## Edits

```c3
// write texels in place, then:
assets.mark_texture_dirty(desc.height_map);
terrain::mark_dirty(&scene, ground, { .x = x, .z = z, .columns = columns, .rows = rows });
// once a stroke of edits ends:
scene.get(ground, PhysicsBody).mark_changed();
```

- `mark_dirty` unions the rectangle into the terrain's pending one; the union must cover every texel written
  since the last `update`. The next `update` sees the revision change and refreshes only the chunks the
  rectangle touches and their ancestors. A revision change without `mark_dirty` rebuilds the whole bounds
  tree, as does a new pixel array.
- The renderer re-uploads the whole height map on each revision (8 MiB at 2049², 32 MiB at 4097²).
- A live physics body is not re-cooked on a texture revision. `mark_changed` rebuilds the whole field on the
  next `PhysicsWorld.update`, so call it once when a stroke ends: collision is stale during the stroke and
  correct after it.
- A revision whose map fails the checks, or whose side differs from the accepted side, is rejected: `update`
  returns the fault, keeps the old bounds and hides the terrain (batch count 0) until a conforming revision,
  which rebuilds everything.

## Removal

Remove the `Terrain` component, or the node. The next `update` removes the node's `InstancedMesh` and
`TerrainRuntime` first thing, so a removed terrain never draws a stale frame; a removed node's batch goes with
the node. The runtime's remove hook frees its arrays and removes the terrain's own material. Removing
`TerrainRuntime` directly is not supported.

The shared shader (`"c3d_landscape/terrain_shader"`) and chunk grid (`"c3d_landscape/terrain_grid"`) are
added to the store by the first `add_terrain` and live as long as the store. Destroy physics worlds first, then
the scene, then the store.

**Serialisation.** `Terrain` is the authored component; `TerrainRuntime` and the terrain's `InstancedMesh` are
derived. Loading calls `add_terrain` with the stored desc.

## Picking

`spatial::pick` sees the terrain's chunk boxes, or the flat top of the unit grid at triangle precision, not the
drawn heights. The terrain's own queries are the supported hit. Give the terrain node its own layer bit and
leave it out of `PickOptions.layers`, as the example does; the scene index sees chunk boxes too.

## Shadows

At landscape shadow distances a cascade texel spans decimetres to metres, so the 2 cm default
`ShadowSettings.normal_bias` bands flat and gentle ground under atlas shadows; set the sun's normal bias to about
a cascade texel. The example uses 0.5 m at a 1500 m shadow distance, where its four cascades have texels of
about 0.1, 0.2, 0.46 and 1.8 m. The bias lifts the shadow lookup along the receiver's normal, so a 1 m crate's
contact shadow stays attached but shortens: at the example's 46° sun it reaches about 0.5 m past the crate's
base instead of 0.95 m. Traced shadows need no such bias.

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_terrain` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `add_terrain` | `c3d::INVALID_ID` | Dead height map, control map or set layer |
| `add_terrain`, `height_view`, `update` | `c3d::UNSUPPORTED` | Height map not `R16_UINT`, not a `MIP_ZERO` source, or a layered, 3D or cube texture |
| `add_terrain` | `c3d::UNSUPPORTED` | Control map not `RGBA8_UNORM` |
| `add_terrain`, `height_view`, `update` | `c3d::INVALID_ARGUMENT` | Not square, a side outside the list, pixel bytes not `side² × 2` |
| `add_terrain` | `c3d::INVALID_ARGUMENT` | A non-positive scale, a negative or NaN tunable, no layer 0, a layer after an unset one, a layer that is not `STANDARD`, a shared key naming another asset kind |
| `add_terrain` | `c3d::CAPACITY_EXCEEDED` | Store pool full or an allocation failed |
| `update` | `c3d::INVALID_ID` | The height map was removed |
| `update` | `c3d::INVALID_ARGUMENT` | A revision whose side differs from the accepted one |
| `sample_height`, `sample_normal` | `NOT_FOUND` | The point is outside the extent |

## Limits

- One selection per frame, for the camera given to `update`: a view far from it (a shadow cascade, a capture
  or mirror view) draws that camera's levels.
- The batch never traces (`trace = false`). Under traced shadows ridges do not shadow valleys, though other
  objects still cast onto the terrain; ray-traced ambient occlusion, reflections, probes and path tracing do
  not see it.
- Level changes pop and carry no motion vector; temporal history rejection handles them. The velocity forms
  ignore per-instance previous matrices: a re-selection reuses record indices for other chunks, so only node
  motion and the camera produce velocity.
- The velocity pass redraws every chunk on temporal views. A re-selection frame uploads 128 B per selected
  chunk and, on temporal views, 64 B per chunk of previous matrices the stage ignores.
- Normals at a tile border use one-sided differences, so matching edge texels still leave a shading seam.
- Every set layer is sampled on every pixel, whatever its weight; four layers is the limit.
- Edits re-upload the whole height map; with a collider, the end of a stroke re-cooks the whole field.
- Updates run on the calling thread and change scene structure, so they never run inside a job range;
  `sample_height` and `sample_normal` may.

## The example

`python3 scripts/build.py --example terrain` generates a ridged height map (1 m cells, 300 m height scale), a
control map from height and slope and four tiled layers, then walks the camera over it. F toggles flight, G
drops a crate onto the height-field collider, B held raises a bump under the camera at a fixed rate whatever
the frame rate and B released ends the stroke, P toggles the collider, and a click tosses the crate under the
cursor (a 6 m/s velocity change) through `spatial::pick` with the terrain's layer left out. The panel shows chunks per level, LOD switches, the height and normal under the
camera beside the physics ray height, and the LOD threshold.

`--benchmark [frames]` renders to an offscreen target without a window and runs a scripted, deterministic path
of four segments of `frames` steps (default 300) at 1/60 s after 60 warm-up frames: still, a low sweep across
level boundaries, a hover bobbing at a split threshold, and an edit line that stamps a 49 × 49 bump every 30
frames. It prints one line per metric and two gates, and exits 1 when a gate fails:

- `gate still_uploads`: the still segment uploads 0 bytes and never changes the batch revision after its first
  frame;
- `gate hover_switches`: the hover segment switches no level after its first second.

Switches: `--gpu-timings` (build with `python3 scripts/build.py --target terrain --opt O3 --define
C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile`), `--shading forward|deferred`,
`--shadows atlas|traced`, `--size 1025|2049|4097`, `--layers 1|4`, `--lod-threshold PIXELS`,
`--width W --height H` (2560 × 1440 by default in benchmark mode), `--hide-terrain` and `--validation`.
Interactive runs always validate; benchmark runs validate only with `--validation`.

## Measured cost

WSL numbers below come from llvmpipe, a CPU Vulkan implementation: frame and pass times are environment only,
never GPU numbers. CPU-side lines (bounds, edits, selection) are the terrain's own work on an i9-14900K.

Scripted benchmark, 1920 × 1080, atlas shadows, four layers, 300 frames per segment (2049 forward and
deferred, 4097 forward; `--opt O3`). Both gates pass in every run.

| Line | 2049 | 4097 |
| --- | ---: | ---: |
| `bounds_build_ms` (full rebuild, median of five) | 0.19 to 0.24 | 2.23 |
| `edit_update_ms` median / p99 (49 × 49 stamp) | 0.009 to 0.011 / 0.042 to 0.053 | 0.019 / 0.125 |
| `edit_upload_bytes` (whole height map plus records) | 8,414,978 | 33,600,514 |
| `physics_recook_ms` (whole field at stroke end) | 252 to 258 | 1,131 |
| `selection_us` median, still / sweep / hover / edit | 2.5 / 2.6 / 2.3 / 2.6 | 4.5 / 4.7 / 3.9 / 5.0 |
| `selection_us` p99, sweep / hover | 4.6 to 10.1 / 3.6 to 3.7 | 9.2 / 10.2 |
| `chunks` median, still / sweep / hover / edit | 130 / 145 / 79 / 142 | 193 / 229 / 124 / 232 |
| `lod_switches_per_second`, sweep / hover | 15.4 / 3.2 | 56.0 / 6.0 |
| `frame_ms` median, still (environment only) | 687 to 711 | 834 |

The still segment uploads nothing after its first frame and the hover segment switches no level after its
first second. A sweep frame that re-selects uploads 128 B per chunk (up to 21 KiB at 2049, 31 KiB at 4097). A
stamp frame's update, bounds refresh included, stays under 0.13 ms; the whole-texture re-upload and the
physics re-cook are the costs of an edit.

The RTX 4090 medians of the run matrix (2560 × 1440, forward and deferred, one and four layers, terrain
hidden, `--lod-threshold 0`) are recorded here when measured.
