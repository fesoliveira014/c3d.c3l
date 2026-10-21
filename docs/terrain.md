# Terrain

The `c3d::landscape::terrain` module of the `c3d_landscape` add-on draws a height-mapped ground. A `Terrain` component on a node reads an `R16_UINT` height map and builds a quadtree of chunks as the instances of the node's own `InstancedMesh`. The chunks draw through a custom material from the package's shaders, so they take part in every view, shadow layer, depth prepass, G-buffer and velocity pass through core's instanced path. The renderer selects the levels per view on the GPU ([quadtree selection](instancing.md#quadtree-selection)). Up to four `STANDARD` layer materials blend through an RGBA control map. CPU height queries follow the physics height-field convention, so a height-field collider on the same node touches the drawn surface.

The module imports only the standard library and core (`c3d`); core never imports it and has no terrain feature flag. The package root `c3d::landscape` holds the generated constants of its shader package, including `LANDSCAPE_SHADER_INCLUDES` for `compile_glsl(includes:)`.

Terrain uses the shared [frame origin](large_world.md): put the camera's absolute position in `FrameInfo.reference_position`. A reference change keeps every view's level selection and preserves temporal motion for unchanged chunks. Height queries keep their CPU coordinate contracts.

## Quick start

Select `c3d_landscape` in `project.json` as [release.md](release.md) lists, then register, add and update:

```c3
terrain::register_terrain(&scene, &assets)!;

TerrainDesc desc = terrain::default_terrain_desc();
desc.height_map = height_map;      // R16_UINT, 1025 x 1025 texels
desc.control_map = control_map;    // optional RGBA8_UNORM layer weights
desc.cell_size = 1;                // metres between texels
desc.height_scale = 300;           // metres at texel 65535
desc.layers = { rock, grass, sand, snow };
terrain::add_terrain(
    scene:  &scene,
    assets: &assets,
    node:   ground,
    desc:   desc,
)!;

// every frame, after height edits and before the frame's first render_view
scene.update_world();
terrain::update(&scene, &assets)!;
renderer.render_view(&scene, camera, view)!;
```

- `register_terrain` runs once per scene. It registers `Terrain`, `TerrainRuntime`, `TerrainSet` and `TerrainTile` and installs their remove hooks. The store outlives the scene, and the scene stays at its address because the tile hooks hold it.
- `add_terrain` attaches a terrain to an existing node without `InstancedMesh` or `Terrain`. It builds the bounds tree, the owned material and the `InstancedMesh` with one instance per quadtree node, all or nothing: a fault leaves the node and the store as they were.
- `update` takes no camera and no output size, because the views select their own levels. On a still frame it uploads nothing. A fault from one terrain does not stop the others; `update` returns the first one. It invalidates `InstancedMesh` and `TerrainRuntime` pointers when a `Terrain` was removed.
- `attach_terrain`, `is_prepared`, `prepare` and `prepare_subtree(scene, assets, root = null)` split `add_terrain` into authoring and runtime. A pending terrain draws nothing and `update` skips it. [Owner readiness](owner_readiness.md) states the shared rules.

## Concepts

- **The node.** The node's world transform places texel (0, 0) at its origin, with texel columns along its x axis and rows along its z axis. The node's translation is the height offset: one transform places the drawn surface, the queries and a collider. Rendering takes any transform; queries need translation and rotation about Y only.
- **Height map.** A square `R16_UINT` texture of `CHUNK_CELLS · 2ⁿ + 1` texels per side (129, 257, 513, 1025, 2049 or 4097). `height = height_scale × texel / 65535`. `image::load_texture_r16` loads a 16-bit PNG; an 8-bit file widens by 257. Generated heights go through `AssetStore.add_texture` with `material::texture_2d_desc(side, side, R16_UINT)` and `generate_mips = false`.
- **Chunk quadtree.** The extent is a quadtree of chunks of `CHUNK_CELLS` (128) cells per side; level 0 is the finest. Every chunk draws the same shared 129 × 129 grid with a skirt that hangs to the chunk's lowest height, so neighbours at different levels leave no crack. A 1025-texel map has 85 nodes and a 4097-texel map 1,365.
- **Per-view levels.** Each view, depth prepass and shadow layer selects levels for its own camera ([Level of detail](#level-of-detail)).
- **Library-owned parts.** The material, the border ring of a tile and the optional trace grid belong to the terrain. The height map and the control map belong to the application.
- **Layers.** Each layer is an ordinary `STANDARD` material. The shader samples every set layer on every pixel and blends the samples by the control map's weights, so four layers cost more than one. Tiling comes from each layer's own `TextureSlot` transforms over `uv0`, which is terrain-local metres: a `scale` of 0.25 repeats a map every 4 m.
- **Control map.** Linear `RGBA8_UNORM` weights of layers 0 to 3 over the whole extent, at any resolution. The shader divides by the weight sum and shows layer 0 where every weight is zero. An sRGB format faults `UNSUPPORTED`.

The [reference](terrain_reference.md) lists the `TerrainDesc` rules, the tile-set types, the constants and the faults.

## Slope projection

With `slope_projection = TOP` every layer samples its maps at terrain-local x and z, so a steep slope stretches textures along the fall line. `TRIPLANAR` projects the layers along the terrain's three axes and blends the results by the surface normal.

- The planes are X (`uv` = local z, y), Y (local x, z) and Z (local x, y), in terrain-local metres. A layer's `TextureSlot` transforms apply to each plane as they do to `uv0`. The projection replaces both UV sets, so each map's UV-set selection is ignored.
- The plane weights are the components of the smooth local normal raised to `triplanar_sharpness` (1 to 64, default 4) and normalised. At 4 the transition between two planes spans about 30 degrees of slope, at 64 about 2 degrees. A flat surface weighs only the Y plane.
- Each plane has its own tangent frame, so normal maps keep their orientation.
- `TRIPLANAR` samples every layer on three planes in every pixel, three times the layer samples of `TOP`.
- `slope_projection` and `triplanar_sharpness` are baked into the material at preparation. To change them, remove the `Terrain` and add it again.

## Level of detail

A node splits when its projected size exceeds `lod_threshold` (default 512 px). A node that split in the view's previous rendering stays split until its size falls below `lod_threshold / (1 + lod_hysteresis)` (hysteresis 0.25 by default). A node draws when every ancestor splits and it does not, so the drawn nodes partition the extent. The size is the projected height of the sphere through the corners of the node's box, in pixels of the view's working extent with `render_scale` included. It does not depend on the node's rotation or on camera rotation.

- Two views of one terrain, such as a split screen or a mirror, draw different levels when their cameras are at different distances. A shadow layer draws the levels of the view it belongs to.
- The history is per view and lives in the renderer. A height edit rewrites the records and keeps it.
- `lod_threshold = 0` selects the finest level everywhere.
- Edits of `lod_threshold`, `lod_hysteresis` and `morph_band` take effect at the next `update` and keep every view's history. `update` faults `INVALID_ARGUMENT` and leaves the terrain as it was for a negative or non-finite `lod_threshold` or `lod_hysteresis`, or a `morph_band` outside its limit.
- `Stats.instances_visible` reports the drawn nodes of a frame over all its passes. `Stats.quadtree_fallbacks` counts batches that drew their finest level because the culling arena had no room.

### Morphing

With `morph_band` above zero, a chunk's vertices move onto the surface of the level that will replace it before it is replaced, so a level change shows neither a pop nor a seam. A vertex is unmorphed up to `(1 − morph_band)` of its parent depth's range from the view's selection camera and fully morphed at the range. `morph_band` must be at most `(1 − lod_hysteresis) / 2`, and a positive band needs a `lod_threshold` above zero. Selection then follows [box ranges](instancing.md#box-ranges).

Only heights morph; x and z never change, and skirts follow. Velocity passes run the same morph against the previous selection camera, so a split, a merge and a steady morph carry no motion beyond the camera's. A height edit, or an edit of the three LOD values, gives one frame of approximate motion. The CPU queries keep the full-resolution surface. Orthographic views have no distance, so they skip the morph. Tiles of a [set](#tile-sets) share one `morph_band` and one set of ranges, so the edge vertices of neighbouring tiles morph alike.

With `morph_band` zero, level changes pop and carry no motion vector; temporal history rejection handles them.

## Create a terrain

Layers, the control map and the LOD values go in `TerrainDesc`; [the reference](terrain_reference.md#terraindesc) lists every rule. `default_terrain_desc()` sets `lod_threshold` 512, `lod_hysteresis` 0.25, `morph_band` 0, `slope_projection` `TOP`, `triplanar_sharpness` 4, both shadow flags and `trace` off; the maps, scales and layers are the application's.

`cast_shadow` and `receive_shadow` are copied onto the batch at every `update`. `trace` adds a trace-only grid ([Scene traces](#scene-traces)).

Remove the `Terrain` component or the node. The next `update` removes the node's `InstancedMesh`, its trace grid node and `TerrainRuntime` first, so a removed terrain never draws a stale frame; a removed node's batch and grid go with the node. The remove hook frees the runtime's arrays, the owned material and the border ring. Removing `TerrainRuntime` directly is unsupported. The shared shader, chunk grid and trace grids (`c3d_landscape/terrain_shader`, `c3d_landscape/terrain_grid`, `c3d_landscape/terrain_trace_grid/<side>`) are added by the first terrain that needs them and live as long as the store. Destroy physics worlds first, then the scene, then the store.

## Query heights

```c3
HeightView view = terrain::height_view(&scene, &assets, ground.id)!;
float height = terrain::sample_height(&view, x, z)!;
Vec3 normal = terrain::sample_normal(&view, x, z)!;
Vec3 smooth = terrain::sample_smooth_normal(&view, x, z)!;
TerrainHeightRange range = terrain::height_range(&scene, ground.id)!;
```

- `height_view` captures the texels, side, scales, the tile's [border ring](#tile-sets) and the node's world matrix. It allocates nothing, so build one per frame. It faults `INVALID_ID` for a dead node, a node without `Terrain` or a dead height map, and `UNSUPPORTED` or `INVALID_ARGUMENT` for a map that no longer passes the checks of `add_terrain`.
- `sample_height` returns the world height on the height field's triangles: each cell splits along the diagonal from `(x + 1, z)` to `(x, z + 1)`, as box3d's height field does. `sample_normal` returns the face normal of that triangle. A point outside the extent faults `NOT_FOUND`; there is no clamp.
- `sample_smooth_normal` returns the normal the fragment stage shades with: the bilinear blend of the central differences of the four surrounding texels. Across an edge with a linked neighbour it reads the ring's texel; at any other map edge it uses a one-sided difference. The two tiles of a linked seam give the same normal.
- `height_range` returns the lowest and highest world height of a prepared terrain, the node's world Y included. It is current after `update`. It faults `INVALID_ID` for a dead node or one without `Terrain`, and `NOT_PREPARED` for a pending terrain.
- The view borrows the store's texels. In-place edits keep it valid and it reads the new heights. Replacing or releasing the height map, or removing the terrain, invalidates it. It keeps the node transform and the ring's edge mask of the moment it was taken, so take a new view after a tile links or unlinks. Several threads may read one view while nothing edits the texels.

## Edit the height map

```c3
// write texels in place, then:
terrain::mark_dirty(
    scene:  &scene,
    assets: &assets,
    node:   ground,
    rect:   { .x = x, .z = z, .columns = columns, .rows = rows },
)!;
```

- `mark_dirty` marks the rectangle as a region of the height map. It advances the height map's revision once and unions the rectangle into the terrain's pending one. The union must cover every texel written since the last `update`. It faults `INVALID_ID` when the height map was removed and `INVALID_ARGUMENT` when a replacement of another side length is in place.
- The next `update` refreshes only the chunks the rectangle touches and their ancestors, rewrites the node records and uploads them. The quadtree keeps its topology, so no view loses its history. A revision change without `mark_dirty`, or a new pixel array, rebuilds the whole bounds tree.
- **Region uploads.** The renderer copies only the marked texels into its image. Two marks between frames upload the union of their rectangles. A mark followed by `assets.mark_texture_dirty`, a replacement or a pixel release uploads the map whole; see [editing a region](textures.md#editing-a-region).
- **Control map.** The terrain never reads the control map, so the application marks its edits in control-map texels with `assets.mark_texture_region_dirty(control_map, 0, region)!`. The first region upload of a map with generated mips filters every level on the CPU and keeps them; later uploads filter only the boxes the edit reaches.
- **Rejected revisions.** A revision whose map fails the checks, or whose side differs from the accepted side, is rejected. `update` returns the fault, keeps the old bounds and hides the terrain until a conforming revision rebuilds everything.
- **Refresh log.** `TerrainRuntime.refreshes` keeps the last `REFRESH_HISTORY` (4) in-place refreshes. `terrain::refreshed_since(&scene, node, revision)` returns the union of the rectangles of the refreshes after a revision: an empty rectangle (`columns` 0) when none followed, and `NOT_FOUND` when the log does not reach back to it. When the log is full, the two oldest marks merge into their bounding box. A whole-map refresh (a new pixel array, a replacement, a revision with no `mark_dirty`, a rejected map in between) empties the log, so every older reader gets `NOT_FOUND`. [Vegetation](vegetation.md) reads the log to follow the ground.
- **Collision.** A live physics body is not re-cooked on a texture revision. See [Add a collider](#add-a-collider).

## Tile sets

A `TerrainSet` on a parent node holds the settings shared by a grid of tiles. Each tile is a child node that carries an ordinary `Terrain` and a `TerrainTile { x, z }` with its grid coordinates. `TerrainSet.tile_extent()` is `(texels − 1) · cell_size`, the side of one tile in metres.

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

`prepare` checks a tile against its set and faults `INVALID_ARGUMENT` on a mismatch, leaving the tile pending and unlinked ([tile rules](terrain_reference.md#tile-rules)). `add_terrain` faults the same way and leaves the node without `Terrain`. A tile that passes links to its present neighbours, edges and diagonals. A neighbour that prepares later links to the tiles already there, so load order does not matter. `TerrainSet.is_linked(tile)` and `TerrainSet.neighbour(tile, direction)` read the links, with eight `TerrainNeighbour` directions (north is toward lower z) and `NOT_FOUND` for a missing neighbour.

- Tiles duplicate their shared edge row and column, so the edge texels of two neighbours are equal. Cut tiles from one map with an overlap of one row or column. Nothing checks the texels; `propagate_edit` keeps them equal across an edit.
- Removing a tile's node, its `TerrainTile` or its `Terrain` unlinks it. Removing the `TerrainSet` frees the table and leaves the tiles as ordinary terrains.
- Changing a linked tile's transform or `TerrainTile` is unsupported until its next `prepare`.
- `Scene.reparent` runs no hook. Unlink a linked tile before reparenting it: remove its `TerrainTile` while it is still under the set, then add it again under the new set and `prepare`.
- The set creates, loads and unloads nothing. Streaming stays with the application.
- A tile takes one [foliage layer](vegetation.md#place-on-a-tile-set), whose placement does not depend on the order tiles are added.
- Each tile has its own collider, height-map revision and `mark_dirty` rectangle. CPU queries stay within one tile; a point outside it faults `NOT_FOUND`.
- A tile shades its edge texels through a border ring, a small texture the terrain owns that holds the neighbour's texels just outside the tile's border. The ring rebuilds when an edge neighbour links or unlinks, and `terrain::refresh_neighbour_rings(scene, assets, tile, rect)` rebuilds the rings that read an edit. A bare `mark_dirty` on a set tile leaves the neighbours' rings stale.
- Serialization stores the set's `texels`, `cell_size` and `height_scale` and each tile's coordinates; the links rebuild when the tiles prepare ([serialization](serialization_reference.md#landscape)).

### Propagate an edit

After editing a set tile, call `TerrainSet.propagate_edit`:

```c3
uint changed = set.propagate_edit(scene: &scene, assets: &assets, tile: tile.id, rect: rect)!;
foreach (direction : TerrainNeighbour::values) {
    if (changed & ((uint)1 << direction.ordinal)) {
        Entity neighbour = set.neighbour(tile.id, direction)!;
        // mark the neighbour's windows once the stroke ends
    }
}
```

It copies the rectangle's edge rows and columns, corners included, into the duplicated texels of each neighbour, marks the copied strips dirty (so only the strips upload) and refreshes the border rings that read them. The result is a mask: bit `n` is set when the neighbour of `TerrainNeighbour` ordinal `n` had texels change or its collider apron reads the rectangle. A live collider is not re-cooked: mark the windows of the edited tile and of each tile in the mask, and of no other tile. In a neighbour, mark the strip along its edge row or column across the shared side, over the rectangle's texels along that side; a neighbour flagged only because its collider apron reads the rectangle has no copied texels there, and the strip still marks its collider. A tile that is not linked faults `INVALID_ARGUMENT`. It faults like `height_view` when the edited tile's own map is dead, fails the checks or has another side. A neighbour whose map does not conform is skipped.

## Add a collider

`terrain::collision_input(&scene, node.id)` returns the values for a static height-field collider that reproduces the drawn surface: the terrain's map, its scale and the maps of the linked tiles. An edited terrain tiles the collider into windows, so a stroke re-cooks the part it touched. [Terrain with physics and navigation](terrain_integration.md#add-a-collider) shows the setup and the edit order.

## Navigation

A navigation grid reads terrain heights through a sampler callback over `terrain::sample_height`. [Terrain with physics and navigation](terrain_integration.md#build-a-navigation-grid) has the adapter, the lattice and height-range rules.

## Detached bounds build

A terrain's whole bounds build can run as ranges on any scheduler: at load for a pending terrain, or after a height-map replacement or a revision advanced without `mark_dirty` for a prepared one. The owner thread takes a snapshot, any thread runs the ranges, and the owner thread publishes. `add_terrain`, `prepare` and `update` stay serial and unchanged; the library never imports `c3d_job`. The [job pool](jobs.md) drives the ranges.

```c3
BoundsJob job = terrain::bounds_job(
    scene:   &scene,
    assets:  &assets,
    node:    ground,
    scratch: scratch,
)!;
// run_range over disjoint ranges of [0, job.range_count()), on any threads, joined
terrain::commit_bounds(&scene, &assets, &job)!;
```

- **Snapshot.** `bounds_job` borrows the texels. A prepared terrain with nothing to rebuild, or whose only change is a `mark_dirty` rectangle (which `update` refreshes serially), faults `INVALID_ARGUMENT`. A height map the checks refuse faults with the checks' fault.
- **Ranges.** `run_range(first, count)` takes positions in the finest chunks, row by row, in any order and on any thread, as long as no two running ranges overlap. A range writes only its chunks' entries in the job's arrays. While a range runs, nothing may edit, replace or remove the height map.
- **Scratch.** The job takes 4 bytes per finest chunk from the `scratch` allocator (plus 4 bytes per chunk and level under `trace`) and never frees them. Dropping the job cancels it.
- **Commit.** `commit_bounds` runs on the owner thread, publishes what `prepare` or `update` would, and leaves bounds, gaps and records equal to a serial build of the same texels bit for bit. It faults as `prepare` or `update` does. Afterwards `update` has nothing left to rebuild.
- **Staleness.** `commit_bounds` faults `landscape::STALE` and changes nothing if the node died, lost `Terrain` or was prepared or torn down since the snapshot, or if the height map's id, revision, replacement or pixel array, or the terrain's own revision, pending rectangle or trace shape changed. Commit before `update`: an `update` that rebuilt the bounds first makes the job stale. Drop a stale job and take a new one. A moved node or an origin shift does not make a job stale.

## Scene traces

Traced shadows, reflections, ambient occlusion, probe updates and path tracing read the [scene trace](scene_trace.md), not the drawn chunks. Without `trace`, ridges do not shadow valleys under traced shadows (other objects still cast onto the terrain), and ray-traced ambient occlusion, reflections, probes and path tracing do not see the terrain. With `trace` set, `prepare` adds one trace-only grid of the whole extent, built from the same height map and independent of any view.

- **The grid.** A child node named `terrain_trace` carries a `Mesh` with `trace` and `trace_only` set, the terrain's material and `cast_shadow`, and the node's layers. It has one vertex per `2^trace_level` texels along each side (`trace_level` 0 is one vertex per texel; it must be below the map's level count, so at most 1 at 257 texels and 3 at 1025). Its triangles split like the drawn chunks and the physics height field. Each tile of a set owns its grid. The grid follows the terrain node's visibility, and a rejected revision hides it with the batch.
- **Updates.** The trace pose reads no time, so the grid poses again only when the height map, the border ring or the material changes.
- **Error bound.** The grid leaves the drawn surface by a vertical gap. `TerrainRuntime.trace_error` is the largest gap in metres (0 at `trace_level` 0), and `TerrainRuntime.drawn_deviation` is the gap of each coarser drawn level. The shader raises the trace proxy skip height to the larger of the two, so a traced ray ignores the grid's hits less than that above the surface it left. The terrain's occlusion lower than that is lost; its shadows from taller ridges and the contact shadows of other objects stay.
- **Cost.** One posed slot, one bottom level or tree copy and one dispatch with a thread per vertex. A finer `trace_level` costs more: the posed streams hold 24 bytes per vertex, 1.6 MB at 257 vertices a side and 25 MB at 1025. `Stats.trace_posed_bytes` totals the slots. The rest geometry of the grid, shared by every terrain of one side length in a store, takes about 48 bytes per vertex on the CPU and the same on the GPU, about 800 MB each at `trace_level` 0 on a 4097-texel map. A terrain that finds no posed slot is left out of the trace and counted in `Stats.trace_deform_overflow` ([capacity](scene_trace_reference.md#custom-trace-poses)).
- **Hits.** Traced terrain shades grey and ignores layers, the control map and decals, like any custom material hit.
- **Lifetime.** The grid is runtime-owned and never serialized; `prepare` creates it again after a read.

## Decals

Terrain receives material decals ([decals](materials.md#decals)) on the forward and deferred paths. Every decal whose `receiver_layers` include the terrain node's `layers` blends into the terrain's layer sample before lighting or G-buffer output, with the core ordering, angle fade and clustered-overflow rules. Traced terrain applies no decals.

## Picking and shadows

`spatial::pick` sees the finest chunk boxes or the flat top of the unit grid at triangle precision, not the drawn heights. The terrain's own queries are the supported hit. Give the terrain node its own layer bit and leave it out of `PickOptions.layers`.

The sun keeps the default normal offset of two texels of each cascade ([normal offset](shadows.md#normal-offset)), which clears flat and gentle ground at landscape distances. In the far cascades the offset nears the height of small objects, so a 1 m crate loses its contact shadow there. Traced shadows apply no offset.

## Limits

- Level changes pop and carry no motion vector with `morph_band` zero.
- The velocity pass redraws every chunk on temporal views, with previous matrices the stage ignores.
- Normals at a map border with no linked neighbour use one-sided differences.
- Four layers is the limit and every set layer is sampled on every pixel. `TRIPLANAR` samples each on three planes. Under `TOP`, `uv0` is terrain-local x and z, so steep slopes stretch textures.
- Edits upload only the marked texels. With a collider, the end of a stroke re-cooks the whole field, or only the touched windows when the collider is tiled.
- `update`, `prepare` and publication run on the owner thread and change scene structure, so they never run inside a job range.
- The batch never traces by itself (`trace = false` on the `InstancedMesh`); the `trace` option adds a grid.
- A node with a `LodGroup` cannot carry a terrain (`UNSUPPORTED`).

## See also

- [Terrain reference](terrain_reference.md): `TerrainDesc`, tile rules, constants and faults.
- [Terrain with physics and navigation](terrain_integration.md): colliders, navigation grids and edit order.
- [Vegetation](vegetation.md) and [water](water.md): the other landscape modules; [landscape package](../addons/c3d_landscape.c3l/README.md).
- [Collision queries](collision_queries.md), [instancing](instancing.md), [scene tracing](scene_trace.md), [large worlds](large_world.md), [owner readiness](owner_readiness.md).
- The `terrain` example (`python3 scripts/build.py --example terrain`) generates a ridged map, edits it under a collider and shows tile sets with `--tiles 2x2`.
