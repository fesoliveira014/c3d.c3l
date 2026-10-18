# Terrain

Terrain chunks use core [camera-relative instance packing](large_world.md).
Supply the camera's absolute position in `FrameInfo.reference_position`; height
queries and terrain selection retain their existing CPU coordinate contracts.
Reference changes preserve temporal motion for unchanged chunks.

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

- `register_terrain` runs once per scene after `create_scene`. It registers `Terrain`, `TerrainRuntime`,
  `TerrainSet` and `TerrainTile`, and installs their remove hooks. The store outlives the scene, and the scene
  stays at its address: the tile hooks hold it.
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

Larger worlds are [tile sets](#tile-sets): a grid of terrain nodes under one parent, each with its own collider.
Skirts cover the cracks between tiles at different levels.

## Tile sets

A `TerrainSet` on a parent node holds the settings shared by a grid of tiles. Each tile is a child node that
carries an ordinary `Terrain` and a `TerrainTile { x, z }` with its grid coordinates:

```c3
float extent = (float)(texels - 1) * cell_size; // TerrainSet.tile_extent()
scene.add(set_node, (TerrainSet){ .texels = texels, .cell_size = cell_size, .height_scale = height_scale });
foreach (tile : tiles) {
    Node* node = scene.add_node(set_node)!;
    node.local.position = { (float)tile.x * extent, 0, (float)tile.z * extent };
    scene.add(node, (TerrainTile){ .x = tile.x, .z = tile.z });
    terrain::add_terrain(
        scene:  &scene,
        assets: &assets,
        node:   node,
        desc:   tile.desc,
    )!;
}
```

`TerrainSet.tile_extent()` is `(texels - 1) · cell_size`, the side of one tile in metres.

**Validation.** `prepare` (and so `add_terrain`) checks a tile that carries `TerrainTile` and faults
`INVALID_ARGUMENT` on any mismatch, leaving it pending and never linked. A tile must:

- be a direct child of a node that carries `TerrainSet`;
- have a height map of exactly the set's `texels`, and the set's `cell_size` and `height_scale`;
- have the same `lod_threshold`, `lod_hysteresis` and `layers` as every tile already linked;
- have a `PARENT`-space transform relative to the set node that is a pure translation to
  `(x · tile_extent, 0, z · tile_extent)`: no rotation and unit scale, within 1e-4;
- not share its `(x, z)` with a linked tile. The first tile prepared at a coordinate keeps it.

Floats compare exactly. Tiles may differ in height map, control map and shadow flags.

**Links.** A tile that passes links to its present neighbours at that `prepare`, edges and diagonals. The set
records the linked tiles; `TerrainSet.is_linked(tile)` and `TerrainSet.neighbour(tile, direction)` read them, with
eight `TerrainNeighbour` directions (north is toward lower z) and `NOT_FOUND` for a missing neighbour. A
neighbour that prepares later links to the tiles already there, so load order does not matter.

- Removing a tile's node, its `TerrainTile` or its `Terrain` unlinks it through a removal hook. The tile's former
  neighbours then see no neighbour there. Removing the `TerrainSet` frees the table and leaves the tiles as
  ordinary terrains.
- Changing a linked tile's transform or `TerrainTile` is unsupported until its next `prepare`. `prepare` on a
  prepared tile re-validates it and relinks it; on a mismatch it faults, leaves the terrain drawing and leaves the
  tile unlinked.
- A parent change does not recover. `Scene.reparent` runs no hook, so the tile would stay in its old set's links.
  Unlink a linked tile before reparenting it, by removing its `TerrainTile` while it is still under the set, then
  add the `TerrainTile` again under the new set and `prepare`.
- The set creates no terrain, loads nothing and unloads nothing. Streaming stays with the application: it adds
  tiles when their data arrives and removes them when it leaves.

**Foliage.** A tile takes one [foliage layer](vegetation.md#tiled-worlds). Its candidates are keyed by the
set's grid, so placement does not depend on the order tiles are added, and its `cell_size` must divide
`tile_extent()`.

**Authoring contract.** Neighbouring tiles duplicate their shared edge row and column, so the edge texels of two
neighbours are equal. Cut tiles from one map with an overlap of one row or column, as the example does. Nothing
checks the texels; [`TerrainSet.propagate_edit`](#edits) keeps them equal across an edit.

**Border ring.** A tile shades its edge texels from central differences, so it needs the texel just outside its
border. Each tile owns a `R16_UINT` texture of `texels × 4` in material slot 2, one row for each edge neighbour in the
order north, south, west and east. A row holds the neighbour's texels one step inside the neighbour's own border: the
shared edge is duplicated, so that is the texel outside this tile. `TerrainParams.border_edges` is a four-bit mask of
the rows that are valid.

- The fragment stage reads a ring row only where a central difference crosses a present edge. An edge without a
  linked neighbour stays one-sided, and every other pixel shades as before. The ring has no corners: the stage
  never samples diagonally.
- The ring is created with the tile at `prepare` and removed with its terrain. A terrain without `TerrainTile` has
  no ring: slot 2 is empty and the mask is zero. The 1,032 bytes at 129 texels and 8,200 bytes at 1,025 live on the
  CPU and on the GPU.
- A ring is rebuilt from the neighbours' height texels when an edge neighbour links or unlinks; a diagonal link
  leaves it alone. A tile that leaves its set, by removing its `TerrainTile` or its set, gets an empty ring. A
  neighbour whose height map no longer conforms counts as missing.
- `terrain::refresh_neighbour_rings(scene, assets, tile, rect)` rebuilds the rings that read an edit of the tile's
  texels. It reaches only the neighbours across an edge whose outer two texel bands, the shared edge and the row
  inside it, the rectangle intersects. Each rebuild changes the ring's revision only when a texel or the mask
  changed.
- After editing a set tile, call [`TerrainSet.propagate_edit`](#edits), which refreshes the rings.
  `refresh_neighbour_rings` alone is for an application that keeps the neighbours' edge texels equal itself. A bare
  `mark_dirty` on a set tile leaves the neighbours' rings stale.

CPU queries (`height_view`, `sample_height`, `sample_normal`) stay within one tile; a point outside it is
`NOT_FOUND`. Each tile keeps its own collider, height map revision and `mark_dirty` rectangle: an edit of one tile
does not reach its neighbours' texels.

Serialization stores the set's `texels`, `cell_size` and `height_scale` and each tile's coordinates; the links are
rebuilt when the tiles prepare (see [serialization](serialization.md#landscape-particle-and-audio-adapters)).

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
- On a [set tile](#tile-sets), `mark_dirty` reaches neither the neighbours' duplicated edge texels nor their border
  rings. After it, call `TerrainSet.propagate_edit`:

  ```c3
  uint changed = set.propagate_edit(scene: &scene, assets: &assets, tile: tile.id, rect: rect)!;
  foreach (direction : TerrainNeighbour::values) {
      if (changed & ((uint)1 << direction.ordinal)) {
          Entity neighbour = set.neighbour(tile.id, direction)!;
          // mark_changed on its body once the stroke ends
      }
  }
  ```

  - It copies the rectangle's edge rows and columns, corners included, into the duplicated texels of each
    neighbour, edges and diagonals. A corner texel reaches all three tiles that share it.
  - A neighbour whose texels change gets `mark_texture_dirty` and a `mark_dirty` rectangle of the copied strip, so
    its bounds refresh at the next `update`. A neighbour that already holds the values keeps its revision.
  - It then refreshes the [border rings](#tile-sets) that read the changed texels: those of the tile's own
    neighbours, and those beside each neighbour it changed.
  - Only edge strips are copied, so retained state does not grow, and each tile keeps its own revision and
    `mark_dirty` rectangle.
  - A tile that is not linked to the set faults `INVALID_ARGUMENT`. A tile whose height map no longer passes the
    checks faults like `height_view`; a neighbour whose map does not conform is skipped.
  - The result is a mask: bit `n` is set when the neighbour of `TerrainNeighbour` ordinal `n` had texels change
    (`WEST` 0, `EAST` 1, `NORTH` 2, `SOUTH` 3, then `NORTH_WEST`, `NORTH_EAST`, `SOUTH_WEST`, `SOUTH_EAST`).
    `set.neighbour(tile, direction)` names the tile. A neighbour that was skipped or already held the values has
    no bit, and a repeated call returns 0.
  - A live collider is not re-cooked: call `mark_changed` on the body of the edited tile and of each tile in the
    mask, and on no other tile.
- The renderer re-uploads the whole height map on each revision (8 MiB at 2049², 32 MiB at 4097²).
- A live physics body is not re-cooked on a texture revision. `mark_changed` rebuilds the whole field on the
  next `PhysicsWorld.update`, so call it once when a stroke ends: collision is stale during the stroke and
  correct after it.
- A revision whose map fails the checks, or whose side differs from the accepted side, is rejected: `update`
  returns the fault, keeps the old bounds and hides the terrain (batch count 0) until a conforming revision,
  which rebuilds everything.
- `TerrainRuntime.last_refresh` keeps the last accepted refresh until the next one: the height-map revisions
  before and after it and the rectangle it covered, the whole map unless it took a `mark_dirty` rectangle. A
  rejected revision leaves it. Consumers that follow the ground, such as [vegetation](vegetation.md), read it.

## Removal

Remove the `Terrain` component, or the node. A [tile](#tile-sets) also leaves its set's links. The next `update` removes the node's `InstancedMesh` and
`TerrainRuntime` first thing, so a removed terrain never draws a stale frame; a removed node's batch goes with
the node. The runtime's remove hook frees its arrays and removes the terrain's own material and border ring. Removing
`TerrainRuntime` directly is not supported.

The shared shader (`"c3d_landscape/terrain_shader"`) and chunk grid (`"c3d_landscape/terrain_grid"`) are
added to the store by the first `add_terrain` and live as long as the store. Destroy physics worlds first, then
the scene, then the store.

**Serialisation.** `Terrain` is the authored component; `TerrainRuntime` and the terrain's `InstancedMesh` are
derived. `attach_terrain` attaches validated authoring without generating either.
Use `is_prepared`, `prepare` or `prepare_subtree` to complete pending terrain;
ordinary updates skip it until preparation succeeds. A pending terrain produces
no generated draws. The [landscape preparation contract](../addons/c3d_landscape.c3l/README.md#pending-authoring-and-preparation)
defines retries, subtree selection and ownership.

## Picking

`spatial::pick` sees the terrain's chunk boxes, or the flat top of the unit grid at triangle precision, not the
drawn heights. The terrain's own queries are the supported hit. Give the terrain node its own layer bit and
leave it out of `PickOptions.layers`, as the example does; the scene index sees chunk boxes too.

## Shadows

The sun keeps the default normal offset of two texels of each cascade ([normal offset](shadows.md#normal-offset)),
which clears flat and gentle ground at landscape distances without tuning. At the example's 1500 m shadow distance
the four cascades have texels of about 0.1, 0.2, 0.46 and 1.8 m, so the offset is about 0.2, 0.4, 0.9 and 3.6 m. A 1 m
crate keeps its contact shadow in the first two cascades; at the example's 46° sun the shadow reaches about 0.76 and
0.57 m past its base instead of 0.95 m. From the third cascade on the offset nears or passes the crate's height and
the crate casts little or no shadow. Traced shadows apply no offset.

## Decals

Terrain receives material decals ([decals](materials.md#decals)) on the forward and deferred paths. Every decal whose
`receiver_layers` include the terrain node's `layers` blends into the terrain's completed layer sample before
lighting or G-buffer output, with the core ordering, angle fade and clustered-overflow rules. The two paths agree
within the G-buffer quantization. Traced terrain, as used by reflections, GI and path tracing, applies no decals.

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_terrain` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `add_terrain` | `c3d::INVALID_ID` | Dead height map, control map or set layer |
| `add_terrain`, `height_view`, `update` | `c3d::UNSUPPORTED` | Height map not `R16_UINT`, not a `MIP_ZERO` source, or a layered, 3D or cube texture |
| `add_terrain` | `c3d::UNSUPPORTED` | Control map not `RGBA8_UNORM` |
| `add_terrain`, `height_view`, `update` | `c3d::INVALID_ARGUMENT` | Not square, a side outside the list, pixel bytes not `side² × 2` |
| `add_terrain` | `c3d::INVALID_ARGUMENT` | A non-positive scale, a negative or NaN tunable, no layer 0, a layer after an unset one, a layer that is not `STANDARD`, a shared key naming another asset kind |
| `add_terrain`, `prepare` | `c3d::INVALID_ARGUMENT` | A tile that does not match its set, or shares a coordinate with a linked tile ([tile sets](#tile-sets)) |
| `add_terrain` | `c3d::CAPACITY_EXCEEDED` | Store pool full or an allocation failed |
| `TerrainSet.neighbour` | `NOT_FOUND` | The tile is not linked, or has no linked neighbour in the direction |
| `update` | `c3d::INVALID_ID` | The height map was removed |
| `update` | `c3d::INVALID_ARGUMENT` | A revision whose side differs from the accepted one |
| `sample_height`, `sample_normal` | `NOT_FOUND` | The point is outside the extent |

## Limits

- One selection per frame, for the camera given to `update`: a view far from it (a shadow cascade, a capture
  or mirror view) draws that camera's levels.
- The batch never traces (`trace = false`, and its custom vertex stage keeps it out whatever `trace` says). Under traced
  shadows ridges do not shadow valleys, though other
  objects still cast onto the terrain; ray-traced ambient occlusion, reflections, probes and path tracing do
  not see it.
- Level changes pop and carry no motion vector; temporal history rejection handles them. The velocity forms
  ignore per-instance previous matrices: a re-selection reuses record indices for other chunks, so only node
  motion and the camera produce velocity.
- The velocity pass redraws every chunk on temporal views. A re-selection frame uploads 128 B per selected
  chunk and, on temporal views, 64 B per chunk of previous matrices the stage ignores.
- Normals at a map border with no linked neighbour use one-sided differences. Between linked tiles they are central
  differences through the [border ring](#tile-sets), as current as its last refresh.
- Every set layer is sampled on every pixel, whatever its weight; four layers is the limit.
- Layers are projected from above: `uv0` is terrain-local x and z, so on steep slopes and cliffs the layer
  textures stretch along the fall line.
- Edits re-upload the whole height map; with a collider, the end of a stroke re-cooks the whole field.
- Updates run on the calling thread and change scene structure, so they never run inside a job range;
  `sample_height` and `sample_normal` may.

## The example

`python3 scripts/build.py --example terrain` generates a ridged height map (1 m cells, 300 m height scale), a
control map from height and slope and four tiled layers, then walks the camera over it. F toggles flight, G
drops a crate onto the height-field collider, B held raises a bump under the camera at a fixed rate whatever
the frame rate and B released ends the stroke, P toggles the collider, T toggles a decal on the ground ahead of the start pose, and a click tosses the crate under the
cursor (a 6 m/s velocity change) through `spatial::pick` with the terrain's layer left out. The panel shows chunks per level, LOD switches, the height and normal under the
camera beside the physics ray height, and the LOD threshold.

`--tiles 2x2` builds the same landscape as a [tile set](#tile-sets) of four tiles cut from the map with a one-texel
overlap, each with its own control map and collider. B paints across tile edges: the brush stamps every tile its
square reaches, leaves a tile's shared west column and north row to the neighbour that owns them, and calls
`propagate_edit` for each stamped tile. The end of a stroke re-cooks the colliders of the stamped tiles and of the
neighbours in the returned masks only. The benchmark is unavailable with it, since it measures the one terrain node's
batch and runtime.

`--capture FILE.png` renders one frame without a window, from a fixed camera straight above a point of the tile
seam where the default map's edge texels bend most, and writes it as a PNG. It is meant for `--tiles 2x2` at the
default size and takes `--width`, `--height`, `--shading` and `--shadows`; it excludes `--benchmark`.

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
`--width W --height H` (2560 × 1440 by default in benchmark mode), `--hide-terrain`, `--validation` and `--sky`
(an [atmosphere](sky.md) on the sun and a haze pooling in the valleys, off by default; with `--gpu-timings` the
pass lines add `SKY_VIEW`, `AERIAL_PERSPECTIVE` and `FOG`) and, with `--sky`, `--volumetric-fog` (a
[froxel volume](sky.md#volumetric-fog) for the haze; the pass lines add `FOG_SCATTERING` and `FOG_INTEGRATION`).
Interactive runs always validate; benchmark runs validate only with `--validation`.

## Measured cost

### RTX 4090, driver 610.88, 2560 × 1440

Windows host, `--opt O3` with GPU timings, atlas shadows, three runs of each case (48 in all); medians, and
per-pass run-to-run ranges within ±1 %. Both gates pass in every run. GPU pass medians of the still segment,
in ms:

| Case | Prepass | G-buffer | Shadow atlas | Forward opaque | Lighting | Velocity | Instance cull |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 2049 forward | 0.095 | | 0.463 | 0.406 | | 0.112 | 0.023 |
| 2049 forward, 1 layer | 0.095 | | 0.463 | 0.204 | | 0.113 | 0.023 |
| 2049 forward, hidden | 0.001 | | 0.013 | 0.004 | | 0.022 | |
| 2049 forward, finest | 0.161 | | 0.587 | 0.473 | | 0.178 | 0.023 |
| 2049 deferred | 0.095 | 0.289 | 0.462 | | 0.073 | 0.112 | 0.023 |
| 2049 deferred, 1 layer | 0.095 | 0.161 | 0.463 | | 0.071 | 0.112 | 0.023 |
| 2049 deferred, finest | 0.161 | 0.345 | 0.587 | | 0.073 | 0.178 | 0.023 |
| 4097 forward | 0.134 | | 0.636 | 0.355 | | 0.155 | 0.023 |
| 4097 forward, 1 layer | 0.133 | | 0.634 | 0.221 | | 0.155 | 0.023 |
| 4097 forward, finest | 0.561 | | 1.418 | 0.776 | | 0.583 | 0.023 |
| 4097 deferred | 0.134 | 0.280 | 0.634 | | 0.076 | 0.155 | 0.023 |
| 4097 deferred, 1 layer | 0.134 | 0.186 | 0.635 | | 0.074 | 0.155 | 0.023 |
| 4097 deferred, finest | 0.561 | 0.706 | 1.418 | | 0.074 | 0.583 | 0.023 |

- **Terrain cost.** Visible against hidden, about 1.06 ms at 2049 and 1.25 ms at 4097; the shadow atlas is the
  largest share.
- **What LOD saves.** Against the finest level everywhere (`--lod-threshold 0`), the default threshold saves
  23 % of the GPU total at 2049 (1.42 to 1.10 ms) and 61 % at 4097 (3.36 to 1.30 ms).
- **Four layers against one.** Forward opaque +0.20 ms at 2049 and +0.13 ms at 4097; G-buffer +0.13 and
  +0.09 ms.

CPU, Windows host, median of three runs (range):

| Line | 2049 | 4097 |
| --- | --- | --- |
| `bounds_build_ms` | 0.24 (0.18 to 0.29) | 2.8 to 3.3 |
| `edit_update_ms` median / p99 | 0.0064 / 0.0095 | 0.0100 / 0.019 |
| `physics_recook_ms` | 239 to 243 | 1,026 to 1,028 |
| `selection_us` median, still | 1.9 | 3.4 to 3.6 |
| `selection_us` p99, sweep | 3.0 to 3.2 | 6.0 to 6.2 |

The full bounds build runs at load, not per frame. The edit an application pays for is the whole-texture
re-upload and, with a collider, the physics re-cook at the end of a stroke.

### WSL, llvmpipe, 1920 × 1080

llvmpipe is a CPU Vulkan implementation: its frame and pass times are environment only, never GPU numbers.
CPU-side lines (bounds, edits, selection) are the terrain's own work on an i9-14900K.

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

Preparation order and pending draw behavior are listed in the [owner readiness table](owner_readiness.md).
