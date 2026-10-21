# Vegetation

The `c3d::landscape::foliage` module of the `c3d_landscape` add-on scatters one geometry and material per layer over a terrain node. A `Foliage` component on a node covers the ground terrain's extent with a fixed grid of cells; each non-empty cell is a child node with its own `InstancedMesh`. Placement is deterministic: a stateless hash of the seed, the cell and the candidate picks each position, yaw, scale and tint; a channel of an `RGBA8_UNORM` density map decides which candidates grow; a slope limit and an altitude band remove the rest. Drawing is core's: cells are ordinary instanced batches with the built-in sway and distance fade, so they take part in every view, shadow layer, depth prepass and velocity pass, with per-instance GPU culling. The module has no GLSL and no custom material.

The module imports the standard library, core (`c3d`), `c3d::landscape::terrain` and the package root (for `STALE`). Core never imports it.

Foliage cells use the shared [frame origin](large_world.md), with origin-compensated sway phase and camera-relative fade distances. Scattering, seeds and retained local placements keep their coordinates.

## Quick start

Select `c3d_landscape` in `project.json` as [release.md](release.md) lists. Foliage needs a prepared [terrain](terrain.md) under it.

```c3
terrain::register_terrain(&scene, &assets)!;
foliage::register_foliage(&scene)!;
// ... terrain::add_terrain on ground ...

FoliageDesc grass = foliage::default_foliage_desc();
grass.geometry = blade_geometry;
grass.material = blade_material;
grass.ground = ground.id;
grass.rules.density_map = density_map;   // RGBA8_UNORM over the ground's extent
grass.rules.spacing = 0.5f;
grass.rules.seed = 1;

grass_node.local = ground.local;         // the layer sits at the ground's pose
grass_node.layers = FOLIAGE_LAYER;
scene.update_world();
foliage::add_foliage(
    scene:  &scene,
    assets: &assets,
    node:   grass_node,
    desc:   grass,
)!;

// every frame
scene.update_world();
terrain::update(&scene, &assets)!;
foliage::update(&scene, &assets, wind_velocity)!;
renderer.render_view(&scene, camera, view)!;
```

- `register_foliage` runs once per scene. It registers `Foliage` and `FoliageRuntime` and installs the authoring and runtime removal hooks.
- `add_foliage` attaches a layer to a node without `Foliage`. The node's world matrix must be current and hold a translation and a rotation about Y only. It checks the desc, scatters every cell and adds the cell nodes, all or nothing: a fault leaves the node, scene, store and allocator as they were. It runs once, at load.
- `update` runs every frame after `terrain::update`. The terrain's refresh log tells foliage which cells an edit touched, and `terrain::update` writes it, so a layer re-places one frame late if `update` runs first. A fault from one layer does not stop the others; the first fault returns after the loop.
- `attach_foliage`, `is_prepared`, `prepare` and `prepare_subtree(scene, assets, root = null)` split authoring and runtime. Prepare the ground terrain first; otherwise they return `terrain::NOT_PREPARED` and keep the foliage pending. Pending foliage draws nothing and `update` skips it. [Owner readiness](owner_readiness.md) states the shared rules; the [landscape package README](../addons/c3d_landscape.c3l/README.md) lists the landscape ownership rules.

## Concepts

- **Grid.** The grid is square in the layer node's frame from its origin: `ceil(extent / cell_size)` cells per side, with `extent = (texels − 1) · terrain cell_size`. Cell `(column, row)` covers layer-local x in `[column · cell_size, (column + 1) · cell_size)` and z likewise. Place the layer node at the ground node's pose to cover the terrain exactly; cells past the extent are clipped by rejection.
- **Candidates.** A cell has `strata = max(round(cell_size / spacing), 1)` strata per side and one candidate per stratum, jittered inside it. A candidate's key hashes the seed, the cell's column and row and the candidate index. Nothing carries state between candidates or cells, so a cell places the same instances in any order.
- **Cells.** A cell is a child of the layer node at the identity transform, with the layer's `layers`, the desc's fade, shadow and trace flags and the layer's current sway. Cells are library-owned: do not edit, remove or reparent them. No cell sets a bounds override; core grows each batch bound and cull test by the sway reach.
- **Captured desc.** `FoliageRuntime.desc` keeps the checked copy the cells follow, so editing `Foliage.desc` has no effect. To change a seed, rule, template, fade or shadow or trace flag, remove `Foliage`, call `update` and add the layer again.

### Scatter stages

Each candidate passes, in order:

1. **Density.** Its terrain-local position must lie in the extent, and a hash channel must fall below the density map's selected channel, sampled bilinearly between texel centres with clamped edges. The terrain's control map follows the same rule at terrain UV, so a splat channel and its foliage line up. This stage sets the cell's capacity.
2. **Height.** `terrain::sample_height` at its world x and z.
3. **Altitude.** `min_altitude <= height <= max_altitude`, in world y.
4. **Slope.** The selected normal's `y >= cos(max_slope)`. `FACE` (default) reads `terrain::sample_normal`, the face normal of the height field's triangle. `SMOOTH` reads `terrain::sample_smooth_normal`, the normal the terrain draws with, including the border ring at a tile edge.
5. **Instance.** The candidate stands on the ground, turned about Y, uniformly scaled and tinted, all from hash channels.

Stages 2 to 4 only remove, so a cell never holds more instances than its density-stage count.

## Create a layer

`foliage::default_foliage_desc()` returns grass settings: 32 m cells (`DEFAULT_CELL_SIZE`), a 60 to 90 m fade (`DEFAULT_FADE`), no shadow, no tracing, no slope or altitude limit, scale and tint 1 and a sway template of 0.15 m at 12 m/s. The ids, the ground, the spacing and the seed are the application's. `add_foliage` checks every value and faults `INVALID_ARGUMENT` rather than asserting.

| Field | Rule |
| --- | --- |
| `geometry`, `material` | Live; one pair per layer. Used only when `lod` is null |
| `lod` | A borrowed `LodDesc*`; scatters [whole-object groups](#whole-object-lod) instead |
| `ground` | A node carrying `Terrain`; the layer grows on its height field |
| `cell_size` | Metres along a cell edge; positive; at most `MAX_CELLS_PER_SIDE` (1024) cells per side over the ground; a divisor of `tile_extent()` on a [tile](#place-on-a-tile-set) |
| `rules.density_map` | Linear `RGBA8_UNORM`, one mip, 2D, over the ground's extent in terrain UV [0, 1] |
| `rules.density_channel` | 0 to 3: red, green, blue, alpha |
| `rules.spacing` | Metres between candidate strata; positive; at most `MAX_STRATA_PER_SIDE` (1024) strata per cell edge |
| `rules.seed` | Any value; two layers with one seed place the same candidates |
| `rules.max_slope` | Radians between up and the selected normal, in [0, π/2] |
| `rules.slope_normal` | `FACE` (default) or `SMOOTH` |
| `rules.min_altitude`, `rules.max_altitude` | World y after the terrain node's placement; `min <= max` |
| `rules.min_scale`, `rules.max_scale` | Uniform scale; `0 < min <= max`, finite |
| `rules.min_tint`, `rules.max_tint` | Instance colour, multiplying the material's base colour; finite |
| `sway` | The wind template; amplitude, frequency, wavelength and variation non-negative and finite, `full_bend_speed` positive, `lean` in [0, 1] |
| `fade` | Core's `InstanceFade`; zero is off, else `0 <= start < end` |
| `cast_shadow`, `receive_shadow`, `trace` | Copied onto every cell's `InstancedMesh` |
| `trace_sway` | With `trace`: traced views see each swaying instance at its swayed pose ([below](#trace-swaying-layers)); inert without `trace` |

**Recipes.** Grass: 32 m cells, a 60 to 90 m fade, no shadow, untraced, double-sided blades with `SwayWeight.HEIGHT` (the base stays planted). Trees: 64 m cells, a 250 to 400 m fade, casting and traced, one `STANDARD` `MASK` material whose atlas holds bark at alpha 1 and cut-out leaves, with `SwayWeight.VERTEX_ALPHA` (alpha 0 at the base rising up the canopy). Rocks: a template amplitude of zero, faded like grass.

## Place on a tile set

A layer grows on one terrain node. A world built as a [tile set](terrain.md#tile-sets) takes one layer per tile: a child of the set node at its tile's local transform, with `ground` naming the tile node.

- **Keys.** When the ground carries `TerrainTile { x, z }`, a candidate's `column` and `row` are the cell's indices in the set's grid, `tile · cells_per_tile + local` on each axis, with `cells_per_tile = tile_extent() / cell_size`. One seed on every tile gives each tile its own candidates, and a tile places the same instances whatever order tiles are added, loaded or prepared in. Tile (0, 0) has the keys of a terrain outside a set; a negative coordinate indexes modulo 2^32.
- **Divisibility.** `cell_size` must divide `tile_extent()` within 1e-4 relative to the ratio. Otherwise `add_foliage` and `prepare` fault `INVALID_ARGUMENT`. The grid then has exactly `cells_per_tile` cells per side and its cell edges fall on the tile's edges.
- **Edge ownership.** Cells are half-open ranges of the set's grid, so no two tiles share a cell and exactly one tile places each candidate. A position on a shared edge belongs to the higher-index tile.
- The layer must sit at its tile's pose. At another pose its cells do not line up and the candidates outside the tile are rejected.
- Change a tile's coordinates only by removing its layer and adding it again.
- A ground that carries `TerrainTile` without a `TerrainSet` parent faults `INVALID_ARGUMENT` at `prepare` and `update`; a prepared layer keeps its cells.

## Edit the ground and the density map

`update` compares, per layer, both nodes' world matrices, the ground's height-map revision, the density map's revision and, for a `SMOOTH` layer, the ground's border ring with those the cells were placed against.

| Observed | Work |
| --- | --- |
| Ground dead or without `TerrainRuntime`; density map dead | `INVALID_ID`; nothing changes |
| A pose changed, or a density change that is not a set of region marks | Whole re-scatter |
| The density map changed by region marks since placement | Re-scatter the cells meeting the marked region, widened by two density texels |
| The ground refreshed in place after the placed revision | Re-place the cells meeting the union of those refreshes, widened by two texels |
| The refresh log does not reach back to the placed revision | Re-place every cell |
| A `SMOOTH` layer's ground ring changed (a neighbour's edit, a link or an unlink) | Re-place the cells meeting the one-texel strip along each affected border, widened by two texels |

Edits stay local. A stroke that edits both maps, and a ring change, re-place the union of their cells once. A `FACE` layer never reads the ring.

- **Ground edits.** [`terrain::refreshed_since`](terrain.md#edit-the-height-map) names the texels refreshed since the cells were placed. The terrain keeps its last four refreshes; a whole-map refresh empties them and re-places every cell.
- **Density edits.** Mark the texels written with `assets.mark_texture_region_dirty(density_map, 0, region)`, in density-map texels. A region maps through the map's span of the ground to a range of cells. `assets.mark_texture_dirty`, a replacement or a log that no longer reaches back re-scatter the whole layer.
- A re-place writes arrays in place, never allocates and keeps every node. A re-scatter may change counts: cells that empty lose their node, cells that fill gain one, and capacity never shrinks while a cell is non-empty. It is all or nothing: the node budget is checked before any node is created and every array and node is staged before any cell changes.
- A re-scatter that faults (`CAPACITY_EXCEEDED` past the node budget, a density map that turned unsupported) keeps the layer's cells and remembers the attempt: later updates return the same fault until a pose, a revision or the scene's free node count changes. A layer whose ground was removed or rejected keeps drawing its last cells.
- **Rebasing.** After `scene.shift_origin`, call `scene.shift_foliage()` once the shifted scene's world matrices are current (after `update_world`). It stores the current layer and ground poses as the poses the cells were scattered against, so the next `update` does not re-scatter. Cells keep their local records.

## Wind

The application owns one wind velocity, in world m/s, and passes it to every consumer's update; nothing is stored in the scene. Each layer maps it onto its cells' `InstanceSway` through its `SwayTemplate`:

- `speed = |wind|`. At zero speed, or with a zero template amplitude, the sway is `{ .weight = template.weight }`: a `VERTEX_ALPHA` layer keeps consuming its vertex alpha, so the alpha never starts cutting a masked material.
- Otherwise the direction is the wind's, the amplitude is `template.amplitude · min(speed / full_bend_speed, 1)`, and frequency, lean, wavelength, variation and weight come from the template. Frequency does not follow the wind.
- `update` rewrites every cell's sway only when the velocity changed. A gusting wind costs one store per cell per frame and uploads nothing: sway edits need no mark. Every cell of a layer carries the same sway, so crests run across cells as one field.

## Trace swaying layers

A traced layer shows its cells to traced views in their rest pose, so a ray-traced shadow of a swaying tree stays still while the drawn tree moves. `FoliageDesc.trace_sway` poses each instance of a swaying cell for the trace the way the vertex stage poses it for the draw ([custom trace poses](scene_trace.md#custom-trace-poses)), so ray-traced shadows, ambient occlusion, reflections, probe updates and path tracing follow the wind. The pose takes the layer's sway at the frame's time and applies no fade, so every instance of the layer traces.

- **Cost.** Each instance takes one posed slot of the renderer, with its own posed vertex streams, 256 bytes of the frame's upload ring and a refit copy of the geometry's triangle tree (software kind) or a bottom level (hardware kind). While wind blows, every slot poses again every frame. A calm layer, or a template amplitude of zero, poses nothing. A layer of 1,536 trees takes 1,536 slots.
- **Capacity.** Slots are `RendererDesc.max_posed_trace_instances` (64 by default), shared with skinned and morphed meshes and crowds, so size it for the instances that must follow the wind. Instances are admitted in collection order, not by distance. The device's allocation and acceleration structure tables also bound it, and `create_renderer` refuses a capacity they cannot hold ([scene trace](scene_trace.md#posed-instances)).
- **At capacity.** An instance without a slot traces at rest, and each cell holding such an instance counts once in `Stats.trace_sway_at_rest`. `Stats.trace_posed_instances` counts the posed instances.
- **Alpha.** Coverage tests the material's cut-out with the instance's own texture coordinates: sway moves positions only. A `VERTEX_ALPHA` layer ignores vertex alpha for coverage on every row, as the draw does.

## Whole-object LOD

Set `FoliageDesc.lod` to a borrowed `LodDesc*` to scatter [whole-object groups](lod.md). `attach_foliage` copies the descriptor into authored component storage; preparation creates a separate frozen runtime copy; `add_foliage` does both. Each occupied cell owns one instanced group with shared placements, tint, sway and fade across every part. The descriptor supplies the geometry and material assets; the plain `geometry` and `material` fields are used only when `lod` is null.

Seed, scatter rules and terrain produce the same placements as the single-mesh path. Effect changes preserve slot identity; rescattering replaces placements. Removing the foliage node releases its children and the copied descriptor. The copied pointer and slices belong to the library: do not replace or free them. A layer without `lod` draws one level and relies on its fade.

## Scatter on a job pool

A layer's whole scatter can run as ranges on any scheduler: at load for a pending layer, or after a pose or density change for a prepared one. The owner thread takes a snapshot, any thread runs the ranges, and the owner thread publishes. `add_foliage`, `prepare` and `update` stay serial and unchanged; the library never imports `c3d_job`. The [job pool](jobs.md) drives the ranges.

```c3
ScatterJob job = foliage::scatter_job(&scene, &assets, layer.id, scratch)!;
// count_range over disjoint ranges of [0, job.cell_count()), on any threads, joined
job.reserve_output(transforms, colors)!; // each of job.instance_count() slots
// place_range over disjoint ranges of the same cells, on any threads, joined
foliage::commit_scatter(&scene, &assets, &job)!;
```

- **Snapshot.** `scatter_job` copies the rules, both poses, the grid and the strata, and flattens the cells to scatter into a list in which each cell appears once. The height texels, the border ring and the density pixels are borrowed. A layer with nothing pending, or only a ground or ring edit (which `update` re-places in place), faults `INVALID_ARGUMENT`. A ground that is not prepared, or whose height map has a refresh pending, faults `terrain::NOT_PREPARED`: run `terrain::update` first.
- **Ranges.** `count_range(first, count)` and `place_range(first, count)` take positions in the job's cell list, in any order and on any thread, as long as no two running ranges overlap. While a range runs, nothing may edit, link, replace or remove the ground's height map, its border ring or the density map, nor remove the ground or the layer. The scene is never touched off the owner thread.
- **Output.** `reserve_output(transforms, colors)` runs on the owner thread after every count range. It assigns each cell its slots in two caller arrays of at least `instance_count()` entries and faults `CAPACITY_EXCEEDED` for smaller ones. The arrays must outlive `commit_scatter`.
- **Scratch.** The job takes 16 bytes per listed cell from the `scratch` allocator and never frees them. Dropping the job cancels it. The output arrays are the caller's, about 56 bytes per instance.
- **Commit.** `commit_scatter` publishes on the owner thread exactly as a serial scatter does, and a fault leaves the scene as it was. The layer's cells and instance count match a serial scatter of the same inputs bit for bit. A layer attached but not prepared becomes prepared.
- **Staleness.** `commit_scatter` faults `landscape::STALE` and publishes nothing if the layer or its ground died or lost `Foliage` or `Terrain`, was prepared or torn down; the layer's rules, ground or cell size changed; the height map's revision, replacement or pixel array changed; the density map's revision changed; a `SMOOTH` layer's border ring changed; either node's world matrix changed (unless both moved by the origin shift alone, which commits shifted as `scene.shift_foliage()` would); or `FoliageRuntime.scatter_revision` advanced. Commit before `update`: an `update` that scatters the layer first makes the job stale. Drop a stale job and take a new one.

## Budgets

- **Scene nodes.** Each non-empty cell is one node, so a layer needs up to `cells_per_side²` nodes, with `cells_per_side = ceil((texels − 1) · terrain cell_size / cell_size)`. `add_foliage` and every re-scatter check the scene's free nodes. Size `SceneDesc.max_nodes` for every layer's cells plus the rest of the scene. At a 2049 map with 1 m texels: 4,096 cells at 32 m and 1,024 at 64 m; at 4097, 16,384 and 4,096.
- **Renderer batch slots** (`RendererDesc.max_instance_batches`, 1,024 by default). A cell holds a slot while a view or shadow layer drew it within the last `INSTANCE_ABSENCE_FRAMES + 1` frames; a cell wholly past its fade band is skipped and releases its slot. Per layer and view camera, a faded layer holds at most `(ceil(2R / cell_size) + 1)²` slots, with `R = fade.end + m + v`: `m` is how far an instance reaches past its cell (the geometry's horizontal radius at `max_scale` plus the sway amplitude) and `v` the camera travel over `INSTANCE_ABSENCE_FRAMES + 1` frames. Casting cells fall within the same `R`. A layer without fade can hold every cell. Past the limit `render_view` faults `CAPACITY_EXCEEDED`. The safe setting is every cell of every layer plus the scene's other batches, at about 120 bytes of CPU per slot and no GPU memory until a slot is used.
- **Traced layers.** Every instance of a traced cell is an entry of the scene trace: `RendererDesc.max_trace_instances` (4,096 by default) must hold them with the scene's other traced instances, or traced views fault `CAPACITY_EXCEEDED`. With `trace_sway`, instances also take posed slots.
- **CPU memory.** 8 bytes per grid cell for the runtime's table, about 56 bytes per instance of capacity, and a scene node per non-empty cell.

## Remove

Remove `Foliage` from a live node, or remove the node. Removing the node removes its cells first, then the runtime, whose hook frees the cell table and the runtime LOD copy; the `Foliage` hook frees the authoring LOD copy. Removing only `Foliage` leaves the runtime until the next `update`, which removes the layer's cell nodes and then the runtime. Removing `FoliageRuntime` or a cell node directly is unsupported. The layer owns no assets. Destroy the scene before the store.

`Foliage` is the authored component, including its ground node reference. The cell nodes and their `InstancedMesh` or `LodGroup` components are derived. [Serialization](serialization.md#landscape-particle-and-audio-adapters) saves the authoring and `prepare` regenerates the cells.

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_foliage` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `add_foliage` | `c3d::INVALID_ARGUMENT` | A desc value outside its rule (NaN included) or more than `MAX_CELLS_PER_SIDE` cells per side |
| `add_foliage`, `prepare`, `update` | `c3d::INVALID_ARGUMENT` | A tile ground whose `cell_size` does not divide `tile_extent()`, or without a `TerrainSet` parent |
| `add_foliage` | `c3d::INVALID_ID` | Dead geometry or material |
| `add_foliage`, `prepare`, `prepare_subtree` | `terrain::NOT_PREPARED` | Ground authoring exists but its runtime is pending; prepare terrain and retry |
| `add_foliage`, `update` | `c3d::INVALID_ID` | Ground dead or without `Terrain`; density map dead; ground height map dead |
| `add_foliage`, `update` | `c3d::UNSUPPORTED` | Density map not `RGBA8_UNORM`, not a `MIP_ZERO` source, or layered, 3D or cube; ground height map as `terrain::height_view` |
| `add_foliage`, `update` | `c3d::INVALID_ARGUMENT` | Density pixel bytes not `width × height × 4`; ground height map as `terrain::height_view` |
| `add_foliage`, `update` | `c3d::CAPACITY_EXCEEDED` | New cells past the scene's free nodes; an array allocation failed |
| `scatter_job` | `c3d::INVALID_ARGUMENT` | Nothing pending: the layer is prepared and neither moved nor changed density |
| `scatter_job` | `terrain::NOT_PREPARED` | The ground is not prepared, or its height map has a refresh pending |
| `scatter_job` | `c3d::CAPACITY_EXCEEDED` | The scratch allocator failed |
| `scatter_job`, `commit_scatter` | the faults of `add_foliage` | The checks `add_foliage` makes of a layer not yet prepared |
| `reserve_output` | `c3d::CAPACITY_EXCEEDED` | An output array holds fewer than `instance_count()` entries |
| `commit_scatter` | `landscape::STALE` | A source the job read changed |
| `commit_scatter` | `c3d::CAPACITY_EXCEEDED` | New cells past the scene's free nodes; an array allocation failed |

## Limits

- One sway direction per batch: every cell of a layer bends one way. The amplitude is in world units, the same for every instance whatever its scale. Normals are not bent.
- Traced views see a layer only with `trace` set, and then in its rest pose unless `trace_sway` is set. A swaying `LodGroup` with `trace` set traces at rest the same way. Grass stays untraced by default, so it casts no traced shadow.
- One material per layer: merge bark and leaves into one masked atlas with bark alpha at 1.
- One terrain node per layer; a [tiled world](#place-on-a-tile-set) takes one layer per tile. Candidates outside the ground's extent are rejected.
- One density channel per layer, `RGBA8_UNORM` only.
- `VERTEX_ALPHA` layers consume vertex alpha whether or not the wind blows.
- The desc and the cells' layer bits are fixed after `add_foliage`; change either by removing `Foliage` and adding the layer again.
- A whole density mark, a layer move or a ground move re-scatters the whole layer, and a moving layer node re-uploads every cell's records, which are world-space. Region marks re-scatter only the cells they reach.
- An edit that changes which candidates of a cell pass, at an equal count, gives that cell one frame of wrong motion vectors.
- Publication changes scene structure and stays on the owner thread; only the placement kernels may run in job ranges.

## See also

- [Terrain](terrain.md#tile-sets) for tile sets and the refresh log; [water](water.md); [landscape package](../addons/c3d_landscape.c3l/README.md).
- [Whole-object LOD](lod.md), [instancing](instancing.md), [scene tracing](scene_trace.md), [job pool](jobs.md), [large worlds](large_world.md), [owner readiness](owner_readiness.md).
- The `vegetation` example (`python3 scripts/build.py --example vegetation`) grows grass and trees on the terrain example's ground.
