# Terrain

Terrain chunks use core [camera-relative instance packing](large_world.md).
Supply the camera's absolute position in `FrameInfo.reference_position`; height
queries keep their CPU coordinate contracts. A reference change keeps every view's level
selection and preserves temporal motion for unchanged chunks.

The `c3d_landscape` add-on (`addons/c3d_landscape.c3l`, module `c3d::landscape::terrain`) draws a
height-mapped ground from an `R16_UINT` height map. A `Terrain` component on a node builds a quadtree of
chunks as the instances of the node's own `InstancedMesh`, drawn with a custom material from the package's
shaders, so they take part in every view, shadow layer, depth prepass, G-buffer and velocity pass through
core's instanced path. The renderer selects the levels per view on the GPU ([quadtree
selection](instancing_quadtree.md)): every view and every shadow layer draws the levels its own
camera asks for. Up to four `STANDARD` layer materials blend through an RGBA control map. CPU height queries
follow the physics height-field convention, so a height-field collider on the same node touches the drawn
surface.

The package imports only the standard library and `c3d`; core never imports it and has no terrain feature
flag. Its root module `c3d::landscape` holds the generated constants of its shader package, including
`LANDSCAPE_SHADER_INCLUDES` for `compile_glsl(includes:)`.

```bash
python3 scripts/build.py --example terrain
```

## Select the package

List `c3d_landscape` before `c3d` in the application's `project.json`, with c3d's own dependencies. The
example and the collider below also select `c3d_physics` and `b3`, and a navigation grid selects `c3d_nav`:

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
terrain::update(&scene, &assets)!;
renderer.render_view(&scene, camera, view)!;
```

- `register_terrain` runs once per scene after `create_scene`. It registers `Terrain`, `TerrainRuntime`,
  `TerrainSet` and `TerrainTile`, and installs their remove hooks. The store outlives the scene, and the scene
  stays at its address: the tile hooks hold it.
- `add_terrain` attaches a terrain to an existing node that carries no `InstancedMesh` and no `Terrain`, and
  builds everything at once: the bounds tree, the owned material and the node's `InstancedMesh`, with one
  instance for every quadtree node and the [quadtree](#level-of-detail) installed. It faults as listed under
  [Faults](#faults) and then leaves the node and store as they were.
- `update` runs every frame before the frame's first `render_view`, after height edits. It refreshes changed
  bounds, rewrites the node records when the bounds changed and applies the `lod_threshold`, `lod_hysteresis`,
  `morph_band` and shadow fields of `Terrain`. It takes no camera and no output size: the views select their own levels. It
  allocates nothing on an ordinary frame and marks a batch only when its bounds changed, so a still frame
  uploads nothing. A fault from one terrain does not stop the others; `update` returns the first one.

`update(scene, assets)` replaces the four-argument form: callers drop `camera_node` and
`output_height_pixels`, and `TerrainRuntime.chunks_per_level` and `lod_switches` no longer exist.

## TerrainDesc

`terrain::default_terrain_desc()` sets `lod_threshold = 512`, `lod_hysteresis = 0.25`, `morph_band = 0`,
`slope_projection = TOP`, `triplanar_sharpness = 4`, both shadow flags and `trace = false`; the maps, scales and layers are the application's. Every value is checked by `add_terrain` and faults rather
than asserts, since descs also come from files.

| Field | Rule |
| --- | --- |
| `height_map` | `R16_UINT`, one mip, 2D, square, `CHUNK_CELLS · 2ⁿ + 1` texels per side: 129, 257, 513, 1025, 2049 or 4097 |
| `control_map` | Optional linear `RGBA8_UNORM` weights of layers 0 to 3 over the whole extent; unset shows layer 0 alone |
| `cell_size` | Metres between texel centres along x and z; positive |
| `height_scale` | Metres at texel 65535: `height = height_scale × texel / 65535`; positive |
| `layers` | Up to four live `STANDARD` materials, leading; zero ids after the last one |
| `lod_threshold` | Projected node diameter, in pixels of the view's working extent, above which a node splits; finite, zero or more |
| `lod_hysteresis` | A split node merges below `lod_threshold / (1 + lod_hysteresis)`; finite, zero or more |
| `morph_band` | Share of each selection range over which chunk vertices morph toward their parent level ([morphing](#morphing)); finite, zero or more, and at most `(1 - lod_hysteresis) / 2`. Zero keeps level changes abrupt; above zero it also needs a `lod_threshold` above zero |
| `slope_projection` | `TOP` projects the layers from above; `TRIPLANAR` projects them along all three axes ([slope projection](#slope-projection)) |
| `triplanar_sharpness` | Exponent of the plane weights: `MIN_TRIPLANAR_SHARPNESS` (1) to `MAX_TRIPLANAR_SHARPNESS` (64), finite; read and checked only under `TRIPLANAR` |
| `cast_shadow`, `receive_shadow` | Copied onto the batch at every `update`; `cast_shadow` also onto the [trace grid](#scene-traces) |
| `trace` | Adds a trace-only grid, so [scene traces](scene_trace.md) see the terrain; baked at preparation |
| `trace_level` | Grid cells span `2^trace_level` texels: 0 is one vertex per texel. It stays below the map's level count (1 at 257 texels, 3 at 1025); read and checked only with `trace`, baked at preparation |

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
`references` (see [material references](custom_shaders.md#material-references)). The stage samples every set layer on every pixel and blends the
samples by weight; a layer without tangents takes derivative normals, and a `TRIPLANAR` terrain gives it the plane's
frame instead. Tiling comes from each layer's own `TextureSlot` transforms over `uv0`, which is terrain-local metres:
a `scale` of 0.25 repeats a map every 4 m.

## Slope projection

With `TOP`, every layer samples its maps at terrain-local `x` and `z`, so a steep slope stretches the textures along the
fall line. `TRIPLANAR` projects the layers along the terrain's three axes and blends the results by the surface normal.

- The planes are X (`uv` = local `z`, `y`), Y (local `x`, `z`, the `TOP` coordinates) and Z (local `x`, `y`), all in
  terrain-local metres. A layer's own `TextureSlot` transforms apply to each plane as they do to `uv0`. The maps'
  UV-set selection is ignored: the projection replaces both sets.
- The weight of a plane is the matching component of the smooth local normal, the one lighting uses, raised to
  `triplanar_sharpness` and normalised. Higher values narrow the blends: the transition between two planes spans about
  30 degrees of slope at 4 and 2 degrees at 64. A flat surface weighs only the Y plane, so it shades as with `TOP`.
- Each plane has its own tangent frame, so normal maps keep their orientation: `+u` and `+v` of the map follow the
  plane's axes projected onto the surface, as the derivative frames of `TOP` do on the Y plane. The planes' world
  normals blend and the sum is normalised.
- Every layer is sampled on every plane in every pixel, three times the layer samples of `TOP`, with gradients taken
  from the projected coordinates, so the blend has no seams. `triplanar_sharpness` does not change the cost.
- `slope_projection` and `triplanar_sharpness` are baked into the terrain's material when it is prepared. Changing
  them afterwards needs the `Terrain` component removed and added again.

## Level of detail

The extent is a quadtree of chunks of `CHUNK_CELLS` = 128 cells per side at every level; level 0 is the
finest, and a 2049 map has five levels. Every chunk draws the same shared grid of 129 × 129 vertices plus a
skirt ring that hangs from its edges down to the chunk's lowest height, so neighbours at different levels
leave no crack. Skirts shade with the normal of the edge they hang from.

**The batch.** Every node of the tree is an instance, finest level first: 85 at 1025 texels, 341 at 2049 and
1,365 at 4097, which is 170 KiB of 128 B records on the GPU. The instance matrix maps the grid's unit box onto the
node's box, its footprint and its lowest and highest height; the colour carries the chunk record: the texel
origin, the span in texels and the height the skirts hang down to. `add_terrain` gives each instance its parent
once, with `Scene.set_instance_quadtree`; `update` changes the topology only to hide the batch after a
rejected height-map revision and to install it again. Each tile of a [set](#tile-sets) is a batch of its own.

**Selection.** Each view, its depth prepass and each of its shadow layers select on the GPU from the node
records. A node splits when its size exceeds `lod_threshold`, and a node that split in the view's previous
rendering stays split until its size falls below `lod_threshold / (1 + lod_hysteresis)`. A node draws when every
ancestor splits and it does not, so the drawn nodes partition the extent. The size is the projected height of
the sphere through the corners of the node's box, in pixels of the view's working extent with `render_scale`
included. The sphere does not depend on the node's rotation: a terrain turned about Y selects the levels it
selected unturned. The selection reads no camera rotation, so turning in place never re-selects. A change of
`lod_threshold`, `lod_hysteresis` or `morph_band` keeps every view's history. `update` checks the edited values: when
`lod_threshold` or `lod_hysteresis` is negative or not finite, or `morph_band` is outside its limit, it faults
`INVALID_ARGUMENT` and leaves the terrain as it was, so the batch never holds a value the [quadtree
contract](instancing_quadtree.md#constraints) rejects. The sphere rule above is the one of a terrain with `morph_band`
zero; above zero, selection follows [box ranges](#morphing).

- Two views of one terrain, such as a split screen or a mirror, draw different levels when their cameras are at
  different distances, and a shadow layer draws the levels of the view it belongs to.
- The history is per view and lives in the renderer. A height edit rewrites the records and keeps it; a new
  topology, which only a rejected height-map revision causes, drops it once.
- `lod_threshold = 0` selects the finest level everywhere, the full-resolution grid through the same chunk
  instances.
- A pixel is a pixel of the view that selects: a view of another height, or a `render_scale` below 1, sees the
  levels of its own pixel count.
- The renderer reports the drawn nodes of a frame, over all its passes, as `Stats.instances_visible`, and
  `Stats.quadtree_fallbacks` counts batches that drew their finest level because the culling arena had no room.

## Scene traces

Traced shadows, reflections, ambient occlusion, probe updates and path tracing read the [scene trace](scene_trace.md),
not the drawn chunks, whose levels each view selects for itself. With `trace` set, `prepare` adds one trace-only grid
of the whole extent, built from the same height map and independent of any view.

- **The grid.** A child node named `terrain_trace` carries a `Mesh` with `trace` and `trace_only` set, the terrain's
  material and its `cast_shadow` and the node's `layers`, which `update` keeps current. The grid has one vertex per
  `2^trace_level` texels along each side, ends included: `(texels - 1) / 2^trace_level + 1`, which is 257 at 1025 texels
  and level 2. Its triangles split each cell along the diagonal from `(x + 1, z)` to `(x, z + 1)`, as the drawn chunks
  and the physics height field do. The geometry is shared by every terrain of that side length in a store.
- **The stage.** The terrain shader carries a `trace_pose.single` form, `terrain_trace_pose.comp.glsl`
  ([trace pose](custom_shaders_reference.md#trace-pose)) with `trace_pose_grid` declared, so a grid of any size poses in one
  dispatch. Each vertex takes the height of the texel it stands on from the height
  map, and its normal from the central differences the fragment stage uses, through the [border ring](#tile-sets) at a
  linked tile's edge. It reads no time, so the pose runs again only when the height map, the border ring or the
  material changes.
- **The error bound.** The grid keeps the heights of every `2^trace_level`-th texel, so it leaves the drawn full
  resolution surface by a vertical gap that is largest at a texel: both surfaces are linear on each triangle of the
  texels' own triangulation, which the grid's triangles refine. `TerrainRuntime.trace_error` is that largest gap in
  metres over the whole map; it is 0 at `trace_level` 0 and on a map that is linear over each grid cell. Each finest chunk
  keeps its own maximum, in `TerrainRuntime.trace_deviation` as height texels, so a `mark_dirty` rectangle recomputes
  only the chunks it touches before the new global maximum is taken.
- **A drawn level.** A view that draws a coarser chunk level than 0 differs from the full resolution surface by that
  level's own error, and the grid does not follow the selection. The bounds build measures that error for every level the
  same way (`TerrainRuntime.drawn_deviation`, in metres per level). Cells of every level tile a finest chunk, so each
  finest chunk keeps its gap per level in `drawn_chunk_deviation` (height texels), and a dirty rectangle recomputes only
  the chunks it touches before the per-level maxima are taken. `lod_threshold = 0` draws the full resolution surface.
- **Edits.** A height-map revision poses the whole grid again: one dispatch and, on the hardware trace kind, one new
  bottom level, because a first pose from flat geometry would leave a poor tree to update; the software kind refits.
  A frame with no revision poses nothing. A tile's ring revision does the same for its own grid.
- **Hidden and rejected.** The grid follows the terrain node's visibility. A rejected height-map revision hides it with
  the batch until a conforming revision.
- **Cost.** One posed slot, one bottom level or tree copy, one dispatch of one thread per vertex. The posed streams
  hold 24 B per vertex (position and normal): 1.6 MB at 257 vertices a side, 6.3 MB at 513, and 25 MB for level 0 of a
  1025 map. The software kind adds a copy of the tree's nodes and the hardware kind a bottom level;
  `Stats.trace_posed_bytes` totals the slot. The shared rest geometry adds about 48 B per vertex on the CPU and on the
  GPU. A terrain that finds no posed slot is left out of the trace and counted in `Stats.trace_deform_overflow`
  ([capacity](scene_trace_reference.md#custom-trace-poses)). `update` does one error pass over the texels of the chunks it
  refreshes for the grid and one for each coarser level; at preparation that is every chunk, so preparing a traced
  terrain costs one pass over the map per level.
- **Proxy skip.** The grid is a [trace proxy](scene_trace.md#trace-proxies). A traced ray still starts a fixed 0.02 m
  above the drawn surface, so where the grid sits higher the surface would shadow itself. The fragment stage raises
  `trace_proxy_skip_height` to the larger of `trace_error` and `drawn_deviation` of the chunk's level, and of the parent
  level while the chunk morphs toward it; the stage takes the level from the chunk record's span. A traced ray then
  ignores the grid's hits that lie less than that above the plane of the surface it left. The terrain's occlusion lower
  than that above the surface is lost, and its own shadows from taller ridges stay. Contact shadows from other objects
  stay too: a box on the terrain keeps its shadow at its base, since only the grid is skipped. The values reach the stage
  through the material's parameter block, which an edit republishes only when a gap changed; an untraced terrain writes
  zero. The deferred path carries the height per pixel in the G-buffer flags (centimetres, rounded up), so the lighting
  resolve and the ray-traced ambient occlusion and reflections of a deferred view apply the same rule. A forward view
  with ray-traced ambient occlusion gets it from the terrain's prepass fragment, the shader's
  [prepass stage](custom_shaders_reference.md#prepass-stage), and a multisampled view reads sample 0 of either word. A forward
  view's reflections never trace from terrain pixels: a custom material draws with zero specular weight.
- **Hits.** Traced terrain shades grey and ignores layers, the control map and decals, like any custom material hit.
- **Lifetime.** The grid is runtime-owned: removing the `Terrain` component or the node removes it at the next `update`
  or with the node. It is never serialized; `prepare` creates it again after a read. Each tile of a [set](#tile-sets)
  owns its grid. A terrain takes two scene nodes and one `Mesh`.

## Morphing

With `morph_band` above zero a level change neither pops nor leaves a seam: a chunk's vertices move onto the surface of
the level that will replace it before it is replaced. `add_terrain` and `update` switch the batch to the
[box-range](instancing_quadtree.md#box-ranges) metric, with the extent of a node of each depth and the largest diagonal of the
boxes of that depth, so every node of a depth shares one selection range and the vertex stage computes the morph from
the same ranges. The ranges keep two conditions: a node merges only once its vertices have fully morphed, and nodes
that touch differ by at most one level. `morph_band <= (1 - lod_hysteresis) / 2` is what keeps them.

- **What moves.** Only the height of a vertex whose position in the chunk's 129 × 129 grid is odd along `x`, `z` or
  both; the even vertices are the parent level's. An edge-odd vertex moves to the mean height of its two even neighbours
  along that axis. A doubly-odd vertex lies at the centre of a parent cell and moves to the mean of the cell's
  `(+x, -z)` and `(-x, +z)` corners, the diagonal the chunk index buffer splits every cell along, so the morphed chunk
  and the parent level draw one surface. `x` and `z` never change. Skirts hang from the edge vertices and follow them.
- **How much.** A vertex of a chunk is unmorphed up to `(1 - morph_band)` of its parent depth's range from the view's
  selection camera and fully morphed at the range, measured to the vertex on its own texel height. A view, its depth
  prepass and its shadow layers read the same camera from `FrameRoot.selection_camera`, so they draw one surface.
- **Bounds.** A morphed height lies between the fine and parent surfaces, which the texel minimum and maximum of the
  chunk already contain. Nothing about culling, picking or the queries changes: the CPU queries keep the full-resolution
  surface.
- **Motion vectors.** The velocity forms run the same morph against `FrameRoot.previous_selection_camera`, so a split, a
  merge and a steady morph carry no motion beyond the camera's. A camera cut makes the previous camera the current one.
  The node's own motion moves the previous position but not the previous morph amount. A height edit, and an edit of
  `lod_threshold`, `lod_hysteresis` or `morph_band`, give one frame of approximate motion, since no previous height
  texture or previous parameters are kept.
- **Selection.** The ranges follow the largest diagonal of the boxes of a depth, so a height edit that raises a level's
  tallest box lengthens that level's ranges: `update` sets them again, only when a value changed. A tile of a
  [set](#tile-sets) follows the largest diagonal over the whole set. The batch returns to
  the sphere rule when `morph_band` is edited to zero. The ranges are set again whenever the quadtree is installed
  again, after a rejected height-map revision.
- **Cost.** About three quarters of a chunk's vertices are odd. With a band above zero each reads the quadtree block
  and the depth of its node, and a vertex inside a morph reads two more heights. With the band at zero an odd vertex of
  a quadtree draw still loads the effects block and the batch's quadtree block and returns before any morph work; its
  output is what it was.

**Limits.** Selection and morph measure distance, which an orthographic view does not have: every node of a depth takes
the level its extent gives and the stage morphs nothing in any of the view's passes. The stage reads
`FRAME_SELECTION_ORTHOGRAPHIC` from the frame, which a shadow layer carries from its owning view, so the layers of an
orthographic view skip the morph too and the layers of a perspective view keep it. Tiles of a [set](#tile-sets) morph
each in their own quadtree and share one `morph_band`. They also share one set of ranges: every linked tile takes the
largest box diagonal of each depth over the set, so the edge vertices of neighbouring tiles morph alike. A height edit,
a link or an unlink in the set sets the ranges of every linked tile again.

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
- have the same `lod_threshold`, `lod_hysteresis`, `morph_band` and `layers` as every tile already linked;
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
- `TerrainRuntime.ring_edges` mirrors the mask for CPU reads, and `terrain::ring_strips(texels, edges)` returns
  the one-texel strip along each masked border: the texels whose smooth normals read the ring.
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

CPU queries (`height_view`, `sample_height`, `sample_normal`, `sample_smooth_normal`) stay within one tile; a
point outside it is `NOT_FOUND`. Each tile keeps its own collider, height map revision and `mark_dirty` rectangle:
an edit of one tile does not reach its neighbours' texels.

Serialization stores the set's `texels`, `cell_size` and `height_scale` and each tile's coordinates; the links are
rebuilt when the tiles prepare (see [serialization](serialization_reference.md#landscape)).

## Height queries

```c3
HeightView view = terrain::height_view(&scene, &assets, ground.id)!;
float height = terrain::sample_height(&view, x, z)!;
Vec3 normal = terrain::sample_normal(&view, x, z)!;
Vec3 smooth = terrain::sample_smooth_normal(&view, x, z)!;
TerrainHeightRange range = terrain::height_range(&scene, ground.id)!;
```

- `height_view` captures the texels, side, scales, the tile's [border ring](#tile-sets) and the node's world
  matrix; it allocates nothing, so build one per frame. It faults `c3d::INVALID_ID` for a dead node, a node
  without `Terrain` or a dead height map, and `UNSUPPORTED` or `INVALID_ARGUMENT` for a map that no longer
  passes `add_terrain`'s checks (a released CPU copy included).
- `sample_height` returns the world height on the height field's triangles: each cell splits along its
  diagonal from `(x + 1, z)` to `(x, z + 1)`, as box3d's height field does. `sample_normal` returns the face
  normal of that triangle, the physics convention. A point outside the extent is `NOT_FOUND`, never a clamp.
- `sample_smooth_normal` returns the normal the fragment stage shades with at the point: the gradients of the
  four surrounding texels, blended bilinearly. A gradient is a central difference, taking the ring's texel
  across an edge that has a linked neighbour and a one-sided difference at any other map edge. It reads the
  same texels as the shader and agrees to float rounding, so the two tiles of a linked seam give the same
  normal there.
- `height_range` returns the lowest and highest height of a prepared terrain in world metres, the node's world Y
  included, from the texel bounds of the quadtree's root. It reflects the last accepted refresh, so it is current
  after `update`. It faults `c3d::INVALID_ID` for a dead node and a node without `Terrain`, and `NOT_PREPARED` for a
  pending terrain. It takes the same node transforms as `height_view`.
- The view borrows the store's texels. In-place edits keep it valid and it reads the new heights; replacing,
  releasing or removing the height map, or removing the terrain, invalidates it. It keeps the node transform
  and the ring's edge mask of the moment it was taken, and reads the ring in place: take a new view after a
  tile links or unlinks. Several threads may read one view while nothing edits the texels.

## Physics collider

The terrain follows the physics height field's conventions: the same origin corner, row order, spacing, split
and `texel / 65535` scaling. Build the collider on the terrain node as a static body, from the values
`collision_input` returns ([setup](#physics-and-navigation-setup)):

```c3
TerrainCollisionInput input = terrain::collision_input(&scene, terrain_node.id)!;
ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
collider.height_field = { .source = TEXTURE, .texture = input.height_map };
foreach (side, neighbour : input.neighbours) collider.height_field.neighbours[side].texture = neighbour;
collider.local.scale = input.scale;
physics.add_body(terrain_node, physics::default_body_desc(STATIC), (&collider)[:1])!;
```

Physics refuses a collider-local offset on a height field, which is why the node's translation is the offset.
The landscape test builds its collider from `collision_input` and checks that `sample_height` equals a downward
ray cast at 1,024 points, before and after an edit.

A terrain that is edited tiles the collider into windows, so a stroke re-cooks the part it touched and not the
whole map:

```c3
physics::add_height_field_windows(
    scene:        &scene,
    assets:       &assets,
    node:         terrain_node.id,
    collider:     &collider,
    window_cells: 256,
)!;
```

- Each window is a static body on a child node of the terrain node, cooked from its own `window_cells`-square
  part of the height map. Windows quantize over the full height range, `0` to `height_scale`, so they meet
  exactly at their seams and an edit never changes the quantization of another window.
- [Tiles](#tile-sets) of one set each get their own windows. Tiles with equal `height_scale` quantize over the same
  range, so they meet exactly at the tile seam too.
- Each window reads one sample of its neighbours past a shared edge, so a body crosses a window seam as it crosses
  the interior of a whole field. The package README lists the window contracts.
- A tile of a set passes its linked neighbours' maps: `input.neighbours` holds the west, east, north and south
  tiles' maps, empty where a side has none, in the order of `HeightFieldSide`. Where the tile's map ends the
  collider reads the neighbour's second column or row in, since the first duplicates the shared edge, so a body
  crosses a tile seam as it crosses the interior of one field. A side without a neighbour repeats the border
  sample. The corners are not read.
- A collider with a neighbour quantizes over the format's full range, like a window: its height step is
  `height_scale / 65535` for `R16_UINT`. A set has one `height_scale` and tiles of different sets never link, so
  linked tiles quantize alike.
- A link or an unlink changes `input.neighbours`. `mark_changed` rebuilds from the description the body holds, and
  windows copy their neighbours when added, so rebuild the colliders of both tiles from `collision_input`: remove
  the body or the windows and add them again.

## Edits

```c3
// write texels in place, then:
terrain::mark_dirty(&scene, &assets, ground, { .x = x, .z = z, .columns = columns, .rows = rows })!;
```

The collider and a navigation grid follow in the order given under [Physics and navigation
setup](#physics-and-navigation-setup).

- `mark_dirty` marks the rectangle as a region of the height map, so it replaces `assets.mark_texture_dirty`
  after an in-place edit. It advances the height map's revision once and unions the rectangle into the
  terrain's pending one; the union must cover every texel written since the last `update`. It faults
  `INVALID_ID` when the height map was removed and `INVALID_ARGUMENT` when a replacement of another side length
  is in place; neither changes any state.
- The next `update` sees the revision change and refreshes only the chunks the rectangle touches and their
  ancestors, then rewrites the node records and marks the batch, which uploads its records again, up to 170 KiB
  at 4097 texels. A revision change without `mark_dirty` rebuilds the whole bounds tree, as does a new pixel
  array. The quadtree keeps its topology, so no view loses its history.
- **Region uploads.** The renderer copies only the marked texels of the height map into its image, so a
  49 × 49 stamp stages 4,802 B where the whole map is 8 MiB at 2049² and 32 MiB at 4097². Two marks between
  frames upload the union of their rectangles. A mark followed by `assets.mark_texture_dirty`, a replacement or
  a pixel release uploads the map whole; see [editing a region](textures.md#editing-a-region) for the
  conditions and the log each texture keeps.
- **Control map.** Terrain never reads the control map, so the application marks its edits itself, in control-map
  texels: `assets.mark_texture_region_dirty(control_map, 0, region)!`. The control map keeps its generated mips.
  Its first region upload filters every level on the CPU and keeps them; each later one filters only the boxes the
  edit reaches before it copies them. [Region uploads](#region-uploads) gives the cost.
- On a [set tile](#tile-sets), `mark_dirty` reaches neither the neighbours' duplicated edge texels nor their border
  rings. After it, call `TerrainSet.propagate_edit`:

  ```c3
  uint changed = set.propagate_edit(scene: &scene, assets: &assets, tile: tile.id, rect: rect)!;
  foreach (direction : TerrainNeighbour::values) {
      if (changed & ((uint)1 << direction.ordinal)) {
          Entity neighbour = set.neighbour(tile.id, direction)!;
          // mark the windows its copied strip touches once the stroke ends
      }
  }
  ```

  - It copies the rectangle's edge rows and columns, corners included, into the duplicated texels of each
    neighbour, edges and diagonals. A corner texel reaches all three tiles that share it.
  - A neighbour whose texels change gets a `mark_dirty` rectangle of the copied strip, so its bounds refresh at
    the next `update` and only the strip uploads. A neighbour that already holds the values keeps its revision.
  - It then refreshes the [border rings](#tile-sets) that read the changed texels: those of the tile's own
    neighbours, and those beside each neighbour it changed.
  - Only edge strips are copied, so retained state does not grow, and each tile keeps its own revision and
    `mark_dirty` rectangle.
  - A tile that is not linked to the set faults `INVALID_ARGUMENT`. A tile whose height map no longer passes the
    checks faults like `height_view`; a neighbour whose map does not conform is skipped.
  - The result is a mask: bit `n` is set when the neighbour of `TerrainNeighbour` ordinal `n` had texels change,
    or when its [collider](#physics-collider) apron reads the rectangle, that is, when the rectangle meets the shared
    edge or the row or column inside it toward a linked edge neighbour
    (`WEST` 0, `EAST` 1, `NORTH` 2, `SOUTH` 3, then `NORTH_WEST`, `NORTH_EAST`, `SOUTH_WEST`, `SOUTH_EAST`).
    `set.neighbour(tile, direction)` names the tile. A neighbour that was skipped has no bit, and a repeated call
    returns the bits of the neighbours whose apron reads the rectangle.
  - A live collider is not re-cooked: mark the windows (or call `mark_changed` on the body) of the edited tile
    and of each tile in the mask, and of no other tile. The strip to mark is the neighbour's edge row or column
    across the side, over the same texels as the rectangle along it; a neighbour that only reads the rectangle
    through its apron has no copied texels there, and the strip still marks its collider.
- A live physics body is not re-cooked on a texture revision. `mark_changed` rebuilds the whole field on the
  next `PhysicsWorld.update`; `mark_height_field_windows_changed` rebuilds only the windows whose samples meet the
  rectangle, and a rectangle on a window edge marks both windows. Mark once when a stroke ends: collision is stale
  during the stroke and correct after it, and a body resting on an unmarked window keeps its contact.
- A revision whose map fails the checks, or whose side differs from the accepted side, is rejected: `update`
  returns the fault, keeps the old bounds and hides the terrain (batch count 0, quadtree disabled) until a
  conforming revision, which rebuilds everything and installs the quadtree again; each view then selects
  without hysteresis for one frame.
- **Refresh log.** `TerrainRuntime.refreshes` keeps the last `REFRESH_HISTORY` (4) in-place refreshes, each with
  the height-map revision it produced and the rectangle it covered, 88 B per terrain.
  `terrain::refreshed_since(&scene, node, revision)` returns the union of the rectangles of the refreshes after
  a revision: an empty rectangle (`columns` 0) when none followed, and `NOT_FOUND` when the log does not reach
  back to it.
  - When the log is full, the two oldest marks merge into their bounding box, so a reader older than the merge
    still gets a rectangle that covers what changed.
  - A whole-map refresh empties the log: a new pixel array, a replacement, a revision with no `mark_dirty`, or
    a map that was rejected in between. Every reader older than it gets `NOT_FOUND`.
  - A rejected revision leaves the log. Consumers that follow the ground, such as [vegetation](vegetation.md),
    read it.

## Detached bounds build

A terrain's whole bounds build can run as ranges on any scheduler: at load, for a terrain attached but not
prepared, or after a height-map replacement or a revision advanced without `mark_dirty`, for a prepared one. The
owner thread takes a snapshot, any thread runs the ranges, and the owner thread publishes. `add_terrain`,
`prepare` and `update` stay serial and unchanged; the library never imports `c3d_job`, and the
[example](#detached-bounds-in-the-example) drives the ranges with a `JobPool`.

```c3
BoundsJob job = terrain::bounds_job(&scene, &assets, ground, scratch)!;
// run_range over disjoint ranges of [0, job.range_count()), on any threads, joined
terrain::commit_bounds(&scene, &assets, &job)!;
```

- **Snapshot.** `bounds_job` records the height map's revision, replacement and pixel array, the terrain's own
  revision, pending rectangle and trace shape. The texels are borrowed. A prepared
  terrain with nothing to rebuild, or whose only change is a [`mark_dirty`](#edits) rectangle, which `update`
  refreshes serially, faults `INVALID_ARGUMENT`. A height map the checks refuse faults with the checks' fault and
  changes nothing; `update` then reports it and hides the batch.
- **Ranges.** `run_range(first, count)` takes positions in the finest chunks, row by row, `range_count()` of them,
  in any order and on any thread, as long as no two running ranges overlap. A range builds each of its chunks'
  bounds and, under `trace`, its gaps at every level. It writes only those chunks' entries in the job's own arrays,
  so the terrain's runtime and the scene are untouched until the commit. While a range runs, nothing may edit,
  replace or remove the height map; that is a programming error.
- **Scratch.** The job takes 4 bytes per finest chunk from the `scratch` allocator for the bounds and, under
  `trace`, 4 bytes per chunk and level for the gaps (28 KiB at 4097 texels), and holds nothing else; it never
  frees them. Dropping the job cancels it.
- **Commit.** `commit_bounds` runs on the owner thread. It copies the job's chunks into the runtime, then runs what
  `prepare` (a pending terrain) or `update` (a prepared one, for this node alone) runs after the leaf bounds: the
  gap and level reductions, the node records, the quadtree and tile set ranges and the trace grid. The bounds,
  gaps and records equal a serial build of the same texels bit for bit. It faults as `prepare` or `update` does and
  leaves the scene as that call would; after a fault in publishing the records, `update` publishes them again.
  Afterwards `update` has nothing left to rebuild.
- **Staleness.** `commit_bounds` faults `landscape::STALE` and changes nothing if any of these changed since
  `bounds_job`:
  - the node died or lost `Terrain`, or was prepared or torn down;
  - the height map's id, revision, replacement or pixel array;
  - the terrain's own revision, so an `update` that rebuilt it first makes the job stale; its pending rectangle; or
    its trace shape (`trace` and `trace_level`).

  Commit before `update`. The application drops a stale job and takes a new one. A moved node or an origin shift
  does not make a job stale: the ranges write texel-space results only, and the commit builds the records, ranges
  and trace grid from the live node and desc.

## Physics and navigation setup

The package imports neither `c3d::physics` nor `c3d::nav`. It supplies two neutral values, `collision_input` and
`height_range`, and the application writes the few lines that put them into the other package's types.

### Collider

`terrain::collision_input(&scene, node.id)` returns a `TerrainCollisionInput { height_map, scale, neighbours }`: the
terrain's own map, `{ cell_size, height_scale, cell_size }` and the maps of the linked tiles on the west, east, north
and south, empty where the tile has none or the terrain is not linked. The application copies them into
`ColliderDesc.height_field.texture`, `ColliderDesc.local.scale` and `ColliderDesc.height_field.neighbours[side].texture`,
as under [Physics collider](#physics-collider), for one body or for `add_height_field_windows`. It supplies any
neighbour `material_indices` itself.

- A scaled terrain node draws a different surface from its collider: physics builds the body from the node's world
  position and rotation and drops its scale, and rendering keeps it. `collision_input` therefore faults `UNSUPPORTED`
  when a world axis length of the node differs from 1 by more than 1e-4, the rounding that composing transforms
  leaves, so a rebase does not fault. Rotation is not checked: physics honours it.
- It reads the node's world matrix: call it after `update_world`.
- It faults `INVALID_ID` for a dead node and a node without `Terrain`. It does not read the asset store: physics checks
  the map's format and pixels when the body builds. It works on a pending terrain.

### Navigation

A navigation grid reads heights through `grid_sampled_source` and a `GridHeightSampler` callback. The callback over
`sample_height` is the whole adapter; a point outside the map is `NOT_FOUND`, which the grid reads as absent:

```c3
fn GridHeightSample? terrain_height(void* context, float world_x, float world_z) {
    HeightView* view = context;
    float? height = terrain::sample_height(view, world_x, world_z);
    if (catch height) return {};

    return { .height = height, .present = true };
}
```

```c3
HeightView view = terrain::height_view(&scene, &assets, ground.id)!;
TerrainHeightRange range = terrain::height_range(&scene, ground.id)!;
GridHeightSampler sampler = {
    .origin    = origin,
    .cell_size = cell_size,
    .sample    = &terrain_height,
    .context   = &view,
    .diagonal  = MAX_MIN_TO_MIN_MAX,
    .area      = nav::WALKABLE_AREA,
};
GridSourceDesc source = nav::grid_sampled_source(
    sampler:    &sampler,
    min_height: range.minimum - padding,
    max_height: range.maximum + padding,
)!;
```

The landscape tests build their navigation grid from this code.

- **Lattice.** The grid is axis-aligned in world XZ, whatever the terrain's yaw. `origin` is the world XZ of the
  lattice vertex (0, 0), a corner of the walkable area, and `cell_size` is `NavBuildConfig.cell_size`; neither has to
  match the terrain's. `view` and `sampler` must outlive the cache and stay at their addresses.
- **Surface.** At a lattice vertex the grid's height is `sample_height`. Between vertices it interpolates the sampled
  heights over its own triangles, so it differs from the terrain by the terrain's curvature over one grid cell. With
  an unrotated terrain, the same cell size, an origin on a texel corner and `MAX_MIN_TO_MIN_MAX`, the terrain's split,
  the two surfaces coincide. At twice the terrain's cell size, along a grid edge that lies on a texel row, the error is
  at most half the largest second difference of the row's texel heights. `DetailMode.BOUNDED` keeps the sampled
  surface inside each polygon, within `detail_max_error` metres vertically.
- **Live texels.** The callback reads the map in place, so a texel write must not overlap a call of the sampler.
  `GridCache.update` and `GridCache.capture_next`, like `GridTileBuilder.build`, call it on the thread that calls them,
  while they copy a tile's cells and their halo into a build slot. A worker running `build_grid_cache_job` reads only
  that copy and never calls the sampler. Edits and cache updates from one thread cannot overlap.
- **Height range.** `grid_sampled_source` takes the range every sampled height lies in, and a cache refuses a source
  whose `1 + round((max_height - min_height) / cell_height)` reaches 8191, with `INVALID_ARGUMENT`. That is about
  409 m at the grid default `cell_height` of 0.05. A terrain whose `height_scale` fits can use
  `[world_y, world_y + height_scale]` with `world_y` the node's world Y, which no edit can leave. Otherwise pad
  `height_range` by the headroom the edits need, and keep the padded span under the same limit.
- **Retaking the range.** A floor outside the declared range fails its tile build with `INVALID_ARGUMENT`.
  `set_source` refuses a change of range, and the mesh's origin Y is the range's minimum. When `height_range`, read
  after `update`, leaves the range of the source, create a new `GridCache` and a new `NavMesh` from its `mesh_desc()`
  with the new range, at the cost of a full rebuild.

**Tile sets.** Keep one `HeightView` per tile, the set's world origin and its tile extent, and pick the tile of a point
with `floor((world - set_origin) / tile_extent)`:

```c3
fn GridHeightSample? tile_height(void* context, float world_x, float world_z) {
    TileHeights* tiles = context;
    int column = (int)math::floor((world_x - tiles.origin.x) / tiles.tile_extent);
    int row = (int)math::floor((world_z - tiles.origin.z) / tiles.tile_extent);
    column = math::clamp(column, 0, (int)tiles.columns - 1);
    row = math::clamp(row, 0, (int)tiles.rows - 1);

    HeightView* view = &tiles.views[(uint)row * tiles.columns + (uint)column];
    float? height = terrain::sample_height(view, world_x, world_z);
    if (catch height) return {};

    return { .height = height, .present = true };
}
```

`TileHeights` holds `HeightView[] views` in row-major order, `Vec3 origin`, `float tile_extent` and the `uint`
`columns` and `rows`.

- Neighbouring tiles duplicate their shared edge, so both give the same height on the seam, and one source covers the
  set.
- The pick assumes a set node without rotation or scale. The clamp keeps a point on the set's outer edge on the last
  tile; it is present only while float rounding keeps it inside that tile's map, and an absent vertex drops the cells
  that touch it.
- The source takes the union of the tiles' `height_range` values, padded once.

### Ordered recipes

**Height edit.**

1. Write the texels in place.
2. `terrain::mark_dirty(&scene, &assets, node, rect)!`, which marks the height map's region and the terrain's
   pending rectangle.
3. Physics, once the stroke ends: with windows,

   ```c3
   SampleRect samples = { .x = rect.x, .z = rect.z, .columns = rect.columns, .rows = rect.rows };
   physics::mark_height_field_windows_changed(&scene, node.id, samples)!;
   ```

   or, with one collider, `scene.get(node, PhysicsBody).mark_changed()`.
4. Navigation: `grid.mark_dirty(cells, revision)`, where `revision` is a `ulong` the application advances with every
   edit. `cells` is a `GridRange` of every grid cell the change reaches. When the grid lattice is the texel lattice
   shifted by `(first_x, first_z)` texels, it is `nav::grid_vertex_cells` of the rectangle's vertex range minus that
   shift. Otherwise it is `nav::grid_world_cells` of the world bounds of the rectangle grown by one texel.
5. On a tile set, repeat 3 and 4 for the neighbour strips that `propagate_edit` reports. Navigation needs one world
   rectangle that covers both tiles.

After `terrain::update`, compare `height_range` with the range of the navigation source (see Retaking the range).

**Link or unlink.** Rebuild the colliders of both tiles from a new `collision_input`: remove the body or the windows
and add them again. `PhysicsBody.mark_changed()` keeps the neighbours of the stored description.

**Replacement.** A new pixel array behind the height map, a replaced or restored map:

1. Retake the views.
2. `PhysicsBody.mark_changed()`, or remove and add the windows again.
3. Navigation: `grid.set_source(source, identity, revision)` with a new revision, over the retaken views.

**Removal.** The navigation cache first, because its sampler borrows the views and the views borrow the texels, then
the collider, then the terrain.

**Pending preparation.** `collision_input` and the sampler work on a pending terrain. `terrain::mark_dirty` and
`height_range` need it prepared.

**Origin rebasing.**

1. `scene.shift_origin(offset)`.
2. `scene.update_world()`.
3. `physics.shift_origin(&scene, offset)`.
4. Retake the views: their world matrices predate the shift.
5. Navigation: `NavMesh.shift_origin`, `NavQuery.shift_origin` and `Crowd.shift_origin`, then
   `GridCache.shift_origin(offset)`, which rebuilds no tile. Subtract the offset from `sampler.origin`; the view it reads
   is the one retaken in step 4, at the same address. A later `set_source` takes `GridCache.source_origin()` as its origin.

See [large worlds](origin_rebasing.md#navigation-grid-caches) for the rebase order and offsets.

## Removal

Remove the `Terrain` component, or the node. A [tile](#tile-sets) also leaves its set's links. The next `update` removes the node's `InstancedMesh`,
its [trace grid](#scene-traces) node and `TerrainRuntime` first thing, so a removed terrain never draws a stale frame; a
removed node's batch and grid go with the node. The runtime's remove hook frees its arrays and removes the terrain's own material and border ring. Removing
`TerrainRuntime` directly is not supported.

The shared shader (`"c3d_landscape/terrain_shader"`), chunk grid (`"c3d_landscape/terrain_grid"`) and each trace grid
(`"c3d_landscape/terrain_trace_grid/<side>"`, one per side length) are added to the store by the first `add_terrain`
that needs them and live as long as the store. Destroy physics worlds first, then
the scene, then the store.

**Serialisation.** `Terrain` is the authored component; `TerrainRuntime`, the terrain's `InstancedMesh` and its
[trace grid](#scene-traces) node are derived. `attach_terrain` attaches validated authoring without generating either.
Use `is_prepared`, `prepare` or `prepare_subtree` to complete pending terrain;
ordinary updates skip it until preparation succeeds. A pending terrain produces
no generated draws. The [landscape preparation contract](../addons/c3d_landscape.c3l/README.md#pending-authoring-and-preparation)
defines retries, subtree selection and ownership.

## Picking

`spatial::pick` sees the leaves of the quadtree, the finest chunk boxes, or the flat top of the unit grid at
triangle precision, not the drawn heights; the larger nodes are views' selections and take no part. The terrain's
own queries are the supported hit. Give the terrain node its own layer bit and leave it out of
`PickOptions.layers`, as the example does; the scene index sees the finest chunk boxes too.

## Shadows

The sun keeps the default normal offset of two texels of each cascade ([normal offset](shadows.md#normal-offset)),
which clears flat and gentle ground at landscape distances without tuning. At the example's 1500 m shadow distance
the four cascades have texels of about 0.1, 0.2, 0.46 and 1.8 m, so the offset is about 0.2, 0.4, 0.9 and 3.6 m. A 1 m
crate keeps its contact shadow in the first two cascades; at the example's 46° sun the shadow reaches about 0.76 and
0.57 m past its base instead of 0.95 m. From the third cascade on the offset nears or passes the crate's height and
the crate casts little or no shadow. Traced shadows apply no offset.

## Decals

Terrain receives material decals ([decals](decals.md)) on the forward and deferred paths. Every decal whose
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
| `add_terrain` | `c3d::INVALID_ARGUMENT` | A non-positive scale, a negative or non-finite tunable, a `morph_band` that is negative, not finite or above `(1 - lod_hysteresis) / 2`, a positive `morph_band` with a zero `lod_threshold`, a `TRIPLANAR` terrain with a `triplanar_sharpness` outside its range or not finite, a `trace` terrain whose `trace_level` is not below the level count, no layer 0, a layer after an unset one, a layer that is not `STANDARD`, a shared key naming another asset kind |
| `add_terrain`, `prepare` | `c3d::INVALID_ARGUMENT` | A tile that does not match its set, or shares a coordinate with a linked tile ([tile sets](#tile-sets)) |
| `add_terrain`, `prepare`, `update` | `c3d::UNSUPPORTED` | The node carries a `LodGroup`, which cannot share a batch with a quadtree |
| `add_terrain` | `c3d::CAPACITY_EXCEEDED` | Store pool full or an allocation failed |
| `TerrainSet.neighbour` | `NOT_FOUND` | The tile is not linked, or has no linked neighbour in the direction |
| `update` | `c3d::INVALID_ID` | The height map was removed |
| `update` | `c3d::INVALID_ARGUMENT` | A revision whose side differs from the accepted one; an edited `lod_threshold` or `lod_hysteresis` that is negative or not finite, or an edited `morph_band` outside the limits above |
| `sample_height`, `sample_normal`, `sample_smooth_normal` | `NOT_FOUND` | The point is outside the extent |
| `collision_input` | `c3d::INVALID_ID` | A dead node or a node without `Terrain` |
| `collision_input` | `c3d::UNSUPPORTED` | A world axis length of the node differs from 1 by more than 1e-4 |
| `height_range` | `c3d::INVALID_ID` | A dead node or a node without `Terrain` |
| `height_range` | `NOT_PREPARED` | A pending terrain |
| `bounds_job` | the faults of `add_terrain` (pending) or `update` (prepared) | The value and height-map checks that precede the leaf bounds |
| `bounds_job` | `c3d::INVALID_ARGUMENT` | A prepared terrain with nothing to rebuild, or with only a `mark_dirty` rectangle |
| `bounds_job` | `c3d::CAPACITY_EXCEEDED` | The scratch allocator failed |
| `commit_bounds` | `landscape::STALE` | A source the job read changed ([above](#detached-bounds-build)) |
| `commit_bounds` | the faults of `prepare` or `update` | The call the commit stands in for |

## Limits

- The batch never traces (`trace = false`, and its custom vertex stage keeps it out whatever `trace` says). Without
  `trace`, ridges do not shadow valleys under traced shadows, though other objects still cast onto the terrain, and
  ray-traced ambient occlusion, reflections, probes and path tracing do not see it. With `trace` they see the
  [trace grid](#scene-traces) at `trace_level`.
- With `morph_band` zero, level changes pop and carry no motion vector; temporal history rejection handles them.
  [Morphing](#morphing) removes both. The velocity forms ignore per-instance previous matrices: a chunk's shape
  comes from its record, so only node motion, the camera and the morph produce velocity.
- The velocity pass redraws every chunk on temporal views. A frame after a bounds change uploads 128 B per node
  and, on temporal views, 48 B per node of previous matrices the stage ignores: up to 170 KiB and 64 KiB at 4097
  texels.
- Normals at a map border with no linked neighbour use one-sided differences. Between linked tiles they are central
  differences through the [border ring](#tile-sets), as current as its last refresh.
- Every set layer is sampled on every pixel, whatever its weight; four layers is the limit. `TRIPLANAR` samples each
  on three planes.
- Under `TOP`, layers are projected from above: `uv0` is terrain-local x and z, so on steep slopes and cliffs the layer
  textures stretch along the fall line. Use [`TRIPLANAR`](#slope-projection) for them.
- Edits upload only the marked texels of the height map; with a collider, the end of a stroke re-cooks the whole
  field, or only the windows it touched when the collider is tiled into [windows](#physics-collider).
- `update`, `prepare` and publication run on the owner thread and change scene structure, so they never run inside a
  job range. The bounds kernels of a whole build may, through the [job API](#detached-bounds-build);
  `sample_height` and `sample_normal` may too.

## The example

`python3 scripts/build.py --example terrain` generates a ridged height map (1 m cells, 300 m height scale), a
control map from height and slope and four tiled layers, then walks the camera over it. F toggles flight, G
drops a crate onto the height-field collider, B held raises a bump under the camera at a fixed rate whatever
the frame rate and B released ends the stroke, P toggles the collider, T toggles a decal on the ground ahead of the start pose, and a click tosses the crate under the
cursor (a 6 m/s velocity change) through `spatial::pick` with the terrain's layer left out. The panel shows the node count, the instances drawn over all passes, the height and normal under the
camera beside the physics ray height, and the LOD threshold.

`--shadows traced` sets `trace` on the ground, so ridges shadow valleys. `--trace-level LEVEL` sets the grid's level; the
default is the finest whose grid has at most 2^22 vertices: 0 at 1025 texels, 1 at 2049 and 2 at 4097. `--trace-level 0`
traces one vertex per texel at any size.

The collider is tiled into 256-cell windows, and the end of a stroke re-cooks only the windows it touched.
`--collision-window CELLS` sets the window size; 0 builds one collider over the whole map. With `--tiles 2x2` each
collider, windowed or not, reads its linked neighbours' maps from `collision_input`, so a crate crosses a tile seam as it
crosses the interior of a tile; P builds the colliders again from the links.

`--morph` sets `morph_band` to 0.25 and `--triplanar` selects `TRIPLANAR` projection; the panel's slider changes the
band while running, and the slope projection is chosen at start. Both apply to `--tiles` and `--capture` too.

`--tiles 2x2` builds the same landscape as a [tile set](#tile-sets) of four tiles cut from the map with a one-texel
overlap, each with its own control map and collider. B paints across tile edges: the brush stamps every tile its
square reaches, leaves a tile's shared west column and north row to the neighbour that owns them, and calls
`propagate_edit` for each stamped tile. The end of a stroke re-cooks the windows of the stamped tiles and of the
neighbours in the returned masks that the edited texels touch. The benchmark is unavailable with it, since it measures the one terrain node's
batch and runtime.

`--capture FILE.png` renders one frame without a window, from a fixed camera straight above a point of the tile
seam where the default map's edge texels bend most, and writes it as a PNG. It is meant for `--tiles 2x2` at the
default size and takes `--width`, `--height`, `--shading` and `--shadows`; it excludes `--benchmark`.

`--benchmark [frames]` renders to an offscreen target without a window and runs a scripted, deterministic path
of four segments of `frames` steps (default 300) at 1/60 s after 60 warm-up frames: still, a low sweep across
level boundaries, a hover bobbing at a split threshold, and an edit line that stamps a 49 × 49 bump every 30
frames. It prints one line per metric and one gate, and exits 1 when the gate fails:

- `gate still_uploads`: the still segment uploads 0 bytes and never changes the batch revision after its first
  frame.

`update_us` times `terrain::update` and `drawn` is `Stats.instances_visible`. The selection runs on the GPU and
the renderer reports no per-level counts, so the benchmark prints no level or switch lines; the hysteresis is
tested in the core quadtree acceptance.

Switches: `--gpu-timings` (build with `python3 scripts/build.py --target terrain --opt O3 --define
C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile`), `--shading forward|deferred`,
`--shadows atlas|traced`, `--size 1025|2049|4097`, `--layers 1|4`, `--lod-threshold PIXELS`,
`--width W --height H` (2560 × 1440 by default in benchmark mode), `--hide-terrain`, `--workers N` (with `--benchmark`:
rebuild the bounds again through the [job API](#detached-bounds-in-the-example)), `--validation` and `--sky`
(an [atmosphere](sky.md) on the sun and a haze pooling in the valleys, off by default; with `--gpu-timings` the
pass lines add `SKY_VIEW`, `AERIAL_PERSPECTIVE` and `FOG`) and, with `--sky`, `--volumetric-fog` (a
[froxel volume](fog.md#volumetric-fog) for the haze; the pass lines add `FOG_SCATTERING` and `FOG_INTEGRATION`).
Interactive runs always validate; benchmark runs validate only with `--validation`.

### Detached bounds in the example

`--workers N` needs `--benchmark`. The `terrain` target links `c3d_job`; the trampoline from the job ranges to a
`JobPool` lives in `examples/landscape_bounds.c3`. After the serial `bounds_build_ms` rebuilds, the example copies
the serial result, then rebuilds the whole map five times per mode through the job API, commits, and compares the
bounds, gaps, trace error and published node records with the copy bit for bit:

| `mode` | Ranges |
| --- | --- |
| `inline` | A pool without workers: the trampoline runs its ranges on the owner thread |
| `workers` | A pool with `N` workers, for `N > 0` |

It prints `bounds_job` (the map size, the finest chunks and `serial_ms`, the `terrain::update` of one whole
rebuild), `bounds_job_timing` per mode (medians of `leaf_ms` for the ranges, `commit_ms` for the owner thread, and
`identical`) and, for `workers` in a build with `--define C3D_PROFILE_CPU --lib c3d_profile`, `bounds_job_ranges`
from the pool's worker range records: ranges and busy time per run and the workers that ran them.
`gate bounds_job_identical` fails the run when any rebuild differs from the serial bounds.

## Cost

The shadow atlas is the largest GPU share of a terrain, followed by the forward opaque or G-buffer pass, where four
layers cost more than one because every set layer is sampled on every pixel. Level selection saves most on large
maps: the finest level everywhere costs more than twice the default threshold at 4097 texels. The selection runs on
the GPU inside the instance cull, once per view and batch.

On the CPU an ordinary `update` is a revision compare. After an edit it refreshes the touched bounds and rewrites
the node records, which takes microseconds; the full bounds build, milliseconds at 4097 texels, runs at load. The
edit an application pays for is the upload of the marked texels and, with a collider, the physics re-cook at the end
of a stroke: the windows it touched, or the whole field when the collider is not tiled.

`--benchmark` prints `update_us`, the instances drawn and the upload bytes per segment, and the
`control_region_upload_ms`, `height_region_upload_ms` and `control_filter_ms` lines of
[region uploads](#region-uploads); with `--gpu-timings` it adds the GPU pass times.

### Region uploads

The benchmark's edit stroke stamps a 49 × 49 bump every 30 frames. WSL on the i9-14900K, `--opt O3`, a 160 × 90
viewport (these lines do not depend on it), 300 frames per segment, three runs each:

| Line | 2049 | 4097 |
| --- | ---: | ---: |
| `edit_upload_bytes` median (a stamp frame) | 48,450 | 179,522 |
| of which the height-map region | 4,802 | 4,802 |
| of which the node records | 43,648 | 174,720 |

`control_filter_ms` is the CPU time of a control-map region upload at the example's 1024² `RGBA8_UNORM` map with
generated mips, less the same measurement on a height-map region: `control_region_upload_ms` less
`height_region_upload_ms`, each the median of five marks and uploads. The first region upload of a texture filters
every level whole and keeps the generated levels, about a third of the map's mip 0; each later one filters only the
boxes its edit reaches. The median therefore measures a later stroke, and it does not depend on the height-map
size. A stroke that also paints the control map pays that band on each frame it marks one.

### Collision re-cook

Collision re-cook at the end of the benchmark's edit stroke, WSL on the i9-14900K, `--opt O3`, a 160 × 90 viewport
(these lines do not depend on it), 300 frames per segment. The default collider is tiled into 256-cell windows;
`--collision-window 0` builds one collider over the whole map:

| Line | 2049 | 4097 |
| --- | ---: | ---: |
| `physics_recook_windows` (windows the stroke touched) | 2 | 4 |
| `physics_recook_ms` (those windows) | 7.4 to 10.3 | 17.5 to 20.6 |
| `physics_recook_window_ms` | 3.7 to 5.2 | 4.4 to 5.2 |
| `physics_whole_recook_ms` (one cook of the whole field) | 292 to 347 | 1,106 to 1,114 |
| `physics_recook_ms` with `--collision-window 0` (`mark_changed`) | 321 to 454 | 1,180 to 1,224 |

A window costs by its samples: on the 2049 map and one stamp, 0.9 ms at 128 cells, 3.7 to 5.2 ms at 256 and
16 ms at 512. The ranges are three to five runs on a shared host.

Preparation order and pending draw behavior are listed in the [owner readiness table](owner_readiness.md).
