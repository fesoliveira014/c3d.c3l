# Vegetation

The `c3d_landscape` add-on's `c3d::landscape::foliage` module scatters one geometry and material per layer
over a terrain node. A `Foliage` component on a node covers the ground terrain's extent with a fixed grid of
cells; each non-empty cell is a child node with its own `InstancedMesh`. Placement is deterministic: a
stateless hash of the seed, the cell and the candidate picks each position, yaw, scale and tint, a channel of
an `RGBA8_UNORM` density map decides which candidates grow, and a slope limit and an altitude band remove the
rest. Drawing is core's: cells are ordinary instanced batches with the built-in sway and distance fade, so
they take part in every view, shadow layer, depth prepass and velocity pass, with per-instance GPU culling and
the whole-batch fade skip. The module has no GLSL and no custom material.

The module imports the standard library, core (`c3d`) and `c3d::landscape::terrain`; core never imports it.

```bash
python3 scripts/build.py --example vegetation
```

## Select the package

Select `c3d_landscape` as for [terrain](terrain.md#select-the-package); foliage needs nothing else.

## Calling order

```c3
terrain::register_terrain(&scene, &assets)!;
foliage::register_foliage(&scene)!;
// ... terrain::add_terrain on ground ...
grass_node.local = ground.local;
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
terrain::update(
    scene:                &scene,
    assets:               &assets,
    camera_node:          camera,
    output_height_pixels: (float)output_height,
)!;
foliage::update(&scene, &assets, wind_velocity)!;
renderer.render_view(&scene, camera, view)!;
```

- `register_foliage` runs once per scene. It registers `Foliage` and `FoliageRuntime` and installs the
  runtime's remove hook.
- `add_foliage` attaches a layer to an existing node without `Foliage` whose world matrix is current and holds
  a translation and a rotation about Y only (a `@require`). It checks the desc, scatters every cell and adds
  the cell nodes, all or nothing: a fault leaves the node, the scene, the store and the allocator as they were.
  It runs once, at load; its time is a load time.
- `update` runs every frame after `terrain::update`. The terrain's last refresh record is what tells foliage
  which cells an edit touched, and `terrain::update` writes it; called before it, a layer re-places one frame
  late. `update` visits every layer; a fault from one layer does not stop the others, and the first fault
  returns after the loop.

## FoliageDesc

`foliage::default_foliage_desc()` returns grass settings: 32 m cells, a 60 to 90 m fade, no shadow, no
tracing, no slope or altitude limit, scale and tint 1, and a sway template of 0.15 m at 12 m/s. The ids, the
ground, the spacing and the seed are the application's. `add_foliage` checks every value and faults
`INVALID_ARGUMENT` rather than asserting, since descs also come from files.

| Field | Rule |
| --- | --- |
| `geometry`, `material` | Live; one pair per layer |
| `ground` | A node carrying `Terrain`; the layer grows on its height field |
| `cell_size` | Metres along a cell edge; positive; at most `MAX_CELLS_PER_SIDE` (1024) cells per side over the ground |
| `rules.density_map` | Linear `RGBA8_UNORM`, one mip, 2D, over the ground's extent in terrain UV [0, 1] |
| `rules.density_channel` | 0 to 3: red, green, blue, alpha |
| `rules.spacing` | Metres between candidate strata; positive; at most `MAX_STRATA_PER_SIDE` (1024) strata per cell edge |
| `rules.seed` | Any value; two layers with one seed place the same candidates |
| `rules.max_slope` | Radians between up and the ground's face normal, in [0, π/2] |
| `rules.min_altitude`, `rules.max_altitude` | World y after the terrain node's placement; `min <= max` |
| `rules.min_scale`, `rules.max_scale` | Uniform scale; `0 < min <= max`, finite |
| `rules.min_tint`, `rules.max_tint` | Instance colour, multiplying the material's base colour; finite |
| `sway` | The wind template, below; amplitude, frequency, wavelength and variation non-negative and finite, `full_bend_speed` positive, `lean` in [0, 1] |
| `fade` | Core's `InstanceFade`; zero is off, else `0 <= start < end` |
| `cast_shadow`, `receive_shadow`, `trace` | Copied onto every cell's `InstancedMesh` |

The desc is read by `add_foliage` only: `FoliageRuntime.desc` keeps the checked copy the cells follow, so an edit
of `Foliage.desc` has no effect. To change a seed, a rule, the template, the fade or the shadow and trace flags,
remove `Foliage`, call `update` and add the layer again.

## Scatter

**Grid.** The grid is square in the layer node's frame from its origin: `ceil(extent / cell_size)` cells per
side, with `extent = (texels - 1) · terrain cell_size`. Cell `(column, row)` covers layer-local x in
`[column · cell_size, (column + 1) · cell_size)` and z likewise. Placing the layer node at the ground node's
pose covers the terrain exactly; cells past the ground's extent are clipped by rejection.

**Candidates.** A cell has `strata = max(round(cell_size / spacing), 1)` strata per side and one candidate
per stratum, jittered inside it. A candidate's key is `pcg(pcg(pcg(pcg(seed) ^ column) ^ row) ^ candidate)`
(the permutation of `noise.glsl`'s `pcg_hash`), and each random value is its own channel of that key. Nothing
carries state between candidates or cells, so a cell places the same instances in any order.

**Stages.** Each candidate passes, in order:

1. **Density** (sets the cell's capacity): its terrain-local position must lie in the extent, and a hash
   channel must fall below the density map's selected channel, sampled bilinearly between texel centres with
   clamped edges. That is the rule the GPU uses for the terrain's control map at terrain UV, so a splat channel
   and its foliage line up.
2. **Height**: `terrain::sample_height` at its world x and z.
3. **Altitude**: `min_altitude <= height <= max_altitude`, in world y.
4. **Slope**: `terrain::sample_normal(...).y >= cos(max_slope)`. This is the face normal of the height field's
   triangle, so the limit follows the faceted surface, not the smooth normals the terrain draws with.
5. **Instance**: on the ground, turned about Y, uniformly scaled, tinted, all from hash channels.

Stages 2 to 4 only remove, so a cell never holds more instances than its density-stage count.

## Cells and re-placement

A cell is a child of the layer node at the identity transform, with the layer node's `layers`, the desc's
fade, shadow and trace flags and the layer's current sway. Its arrays hold its density-stage count; no cell
sets a bounds override, because core grows each batch bound and each instance cull test by the sway reach.
Cells are library-owned: do not edit, remove or reparent them.

`update` compares, per layer, both nodes' world matrices, the ground's height-map revision and the density
map's revision with those the cells were placed against:

| Observed | Work |
| --- | --- |
| Ground dead or without `TerrainRuntime`; density map dead | `INVALID_ID`; nothing changes |
| A pose or the density revision changed | Whole re-scatter: count, node budget, staged arrays, commit |
| The ground's last refresh follows the placed revision | Re-place the cells meeting its rectangle, widened by two texels |
| Any other height-map gap (two refreshes since the last update) | Re-place every cell |

`TerrainRuntime.last_refresh` keeps the revisions around the terrain's last accepted refresh and its rectangle
(the whole map unless the refresh took a `mark_dirty` rectangle). A re-place writes arrays in place, never
allocates, keeps every node and capacity and marks the batch. A re-scatter may change counts: cells that
empty lose their node, cells that fill gain one, a cell whose count grew gets new arrays in its existing node,
and capacity never shrinks while a cell is non-empty. It is all or nothing: the node budget is checked before
any node is created, and every array and node is staged before any cell changes.

A re-scatter that faults (`CAPACITY_EXCEEDED` past the node budget, a density map that turned unsupported)
keeps the layer's cells as they were and remembers the attempt: later updates return the same fault without
counting again until a pose, a revision or the scene's free node count changes. A layer whose ground was
removed or rejected keeps drawing its last cells; the fault tells the application why.

## Wind

The application owns one wind velocity, in world metres per second, and passes it to every consumer's update;
nothing is stored in the scene. Each layer maps it onto its cells' `InstanceSway` through its `SwayTemplate`:

- `speed = |wind|`. At zero speed, or with a zero template amplitude, the sway is `{ .weight = template.weight }`:
  a `VERTEX_ALPHA` layer keeps consuming its vertex alpha, so the alpha never starts cutting a masked material.
- Otherwise the direction is the wind's, the amplitude is `template.amplitude · min(speed / full_bend_speed, 1)`,
  and frequency, lean, wavelength, variation and weight come from the template. Frequency does not follow the
  wind: a frequency edit moves the phase at once.
- `update` rewrites every cell's sway only when the velocity changed (exact comparison). A gusting wind costs
  one store per cell per frame and uploads nothing: sway edits need no mark. Crests run across cells as one
  field, since every cell of a layer carries the same sway and the phase follows world position.

## Grass and trees

The example's two layers show the intended settings:

- **Grass.** 32 m cells, a 60 to 90 m fade, no shadow, untraced; `STANDARD`, opaque, double-sided blades;
  `SwayWeight.HEIGHT`, which weighs vertices by their squared height within the geometry bound, so the base
  stays planted.
- **Trees.** 64 m cells, a 250 to 400 m fade, casting, traced; one `STANDARD` `MASK` double-sided material
  whose atlas holds bark at alpha 1 and cut-out leaves; `SwayWeight.VERTEX_ALPHA`, with vertex alpha 0 at the
  base rising up the canopy.
- **Rocks.** A layer with a zero template amplitude, faded like grass.

## Removal

Remove `Foliage` from a live node, or remove the node. Removing the node removes its cells first, then the
runtime, whose hook frees the cell table. Removing only `Foliage` leaves the runtime until the next `update`,
which removes the layer's cell nodes and then the runtime before anything else. Removing `FoliageRuntime` or a
cell node directly is not supported. The layer owns no assets; destroy the scene before the store.

**Serialisation.** `Foliage` is authored, including its ground node reference; the cell nodes under a layer
node and their `InstancedMesh` components are derived. Loading calls `add_foliage` with the stored desc.

## Budgets

- **Nodes**, checked by `add_foliage` and every re-scatter against the scene's free nodes: each non-empty cell
  is one node, so a layer needs up to `cells_per_side²`, with
  `cells_per_side = ceil((texels - 1) · terrain cell_size / cell_size)`. Size `SceneDesc.max_nodes` for every
  layer's cells plus the rest of the scene. At a 2049 map with 1 m texels: 4,096 cells at 32 m, 1,024 at
  64 m; at 4097, 16,384 and 4,096.
- **Renderer batch slots** (`RendererDesc.max_instance_batches`, 1,024 by default). A cell holds a slot while a
  view or shadow layer drew it within the last `INSTANCE_ABSENCE_FRAMES + 1` frames; a cell wholly past its
  fade band is skipped and releases its slot like a culled one. Per layer and view camera a faded layer holds
  at most `(ceil(2R / cell_size) + 1)²` slots, with `R = fade.end + m + v`: `m` is how far an instance
  reaches past its cell (the geometry's horizontal radius at `max_scale` plus the sway amplitude) and `v` the
  camera travel over `INSTANCE_ABSENCE_FRAMES + 1` frames. Casting cells fall within the same `R`, since shadow
  layers skip from the view camera too. A layer without fade can hold every cell. Past the limit
  `render_view` faults `CAPACITY_EXCEEDED` (`InstanceTable.acquire` in `src/c3d/render/instances.c3`,
  propagated from the view and the shadow pass); nothing is skipped. The safe setting is every cell of every
  layer plus the scene's other batches, at 120 B of CPU per slot and no GPU memory until a slot is used; the
  example uses it.
- **Traced layers.** Every instance of a traced cell is an entry of the scene trace:
  `RendererDesc.max_trace_instances` (4,096 by default) must hold them with the scene's other traced
  instances, or traced views fault `CAPACITY_EXCEEDED`.
- **CPU memory**: 8 B per grid cell for the runtime's table, 56 B per instance of capacity for the arrays, and
  a scene node per non-empty cell.

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_foliage` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `add_foliage` | `c3d::INVALID_ARGUMENT` | A desc value outside its rule (NaN included) or more than `MAX_CELLS_PER_SIDE` cells per side |
| `add_foliage` | `c3d::INVALID_ID` | Dead geometry or material |
| `add_foliage`, `update` | `c3d::INVALID_ID` | Ground dead or without `Terrain`; density map dead; ground height map dead |
| `add_foliage`, `update` | `c3d::UNSUPPORTED` | Density map not `RGBA8_UNORM`, not a `MIP_ZERO` source, or layered, 3D or cube; ground height map as `terrain::height_view` |
| `add_foliage`, `update` | `c3d::INVALID_ARGUMENT` | Density pixel bytes not `width × height × 4` (a released CPU copy included); ground height map as `terrain::height_view` |
| `add_foliage`, `update` | `c3d::CAPACITY_EXCEEDED` | New cells past the scene's free nodes; an array allocation failed |

## Limits

- One sway direction per batch: every cell of a layer bends one way.
- The amplitude is in world units, the same for every instance whatever its scale.
- Normals are not bent: a bent blade or canopy shades as its rest pose.
- Traced views see a layer only with `trace` set, and then in its rest pose: under a ray-traced sun a swaying
  tree casts a still shadow while atlas shadows sway, and ray-traced ambient occlusion, reflections, probes and
  path tracing see the rest pose too. Grass stays untraced by default, so it casts no traced shadow. A traced
  layer's cells walk every instance each frame in a view that traces.
- One material per layer: merge bark and leaves into one masked atlas with bark alpha at 1.
- One terrain node per layer; a tiled world needs one layer per tile. Candidates outside the ground's extent
  are rejected.
- One density channel per layer, `RGBA8_UNORM` only.
- The slope limit reads the height field's faceted face normal, not the smooth drawn normal.
- `VERTEX_ALPHA` layers consume vertex alpha whether or not the wind blows.
- No level of detail: every layer draws one level and relies on its fade.
- The desc is fixed after `add_foliage`; so are the cells' layer bits, taken from the layer node at creation.
  Change either by removing `Foliage` and adding the layer again.
- A density revision, a layer move or a ground move re-scatters the whole layer; a moving layer node also
  re-uploads every cell's records, which are world-space.
- An edit that changes which candidates of a cell pass, at an equal count, gives that cell one rendering of
  wrong motion vectors: previous matrices pair by record index.
- Placement runs on the calling thread and changes scene structure, so it never runs inside a job range.

## The example

`python3 scripts/build.py --example vegetation` builds the [terrain](terrain.md#the-example) example's ground
(`--size 1025|2049|4097`, 1 m cells, a 300 m height scale, four layers and their control map) and grows two
layers on it, both from the control map's grass channel:

- **Grass**: clumps of five tapered 0.5 m blades; 32 m cells; spacing set from the channel's mean so the layer
  holds about 200,000 instances at every map size; a 45° slope limit; scale 0.7 to 1.3; tint 0.8 to 1; the
  default fade and template.
- **Trees**: a tapered trunk and four crossed canopy quads over a generated 256² bark-and-leaf atlas; 64 m
  cells; spacing for about 5,000 candidates at the density stage; a 30° slope limit; below 55 % of the height
  scale; scale 0.8 to 1.3; a 250 to 400 m fade (`--tree-fade-end` sets the end, the start at 0.625 of it);
  casting and traced; a `VERTEX_ALPHA` template of 0.3 m at 15 m/s.

`max_nodes` and `max_instance_batches` are set to every cell plus the fixed nodes and the terrain batch, and
`max_trace_instances` to 16,384 under traced shadows. Right drag looks, WASD moves, F flies, and B raises the
ground under the camera; the frame's `terrain::update` and `foliage::update` re-place the touched cells. The
panel shows, per layer, cells with a node against the grid, instances and cells placed by the last update,
then the renderer's faded and culled batches, tested and visible instances, upload bytes and record time, and
the wind heading, speed (0 to 25 m/s) and gust toggle.

`--benchmark [frames]` renders offscreen without a window and runs six segments of `frames` steps (default
300) at 1/60 s after 60 warm-up frames, with a steady 6 m/s wind except in `gust`:

| Segment | Camera |
| --- | --- |
| still | 1.7 m above the grassiest meadow of the map, fixed |
| spin | the same place, one turn about Y |
| gust | still; the wind speed changes every frame |
| walk | 1.7 m, 8 m/s towards the middle of the map |
| far | 60 m above a corner, looking across the terrain |
| edit | 20 m above, a 49 × 49 brush stamp every 30 frames |

It prints the load-time scatter per layer (`scatter_ms load`), one whole re-scatter of both layers after a
density revision (`rescatter_ms`), the first frame's record time (`first_pack_ms`), the peak batch slots the
cells held against the formula above (`batch_slots`), the re-place time and placed cells per stamp
(`replace_ms`), and per segment the record time, faded batches, `update` time, upload bytes and frames,
tested and visible instances, GPU pass times with `--gpu-timings`, and frame time. Two gates exit 1 when they
fail:

- `gate steady_wind_uploads`: the still segment uploads nothing and changes no cell revision after its first
  frame, and the spin segment changes no cell revision after its first frame (cells turned away from and
  back into view re-upload their records; the wind never does);
- `gate faded_cells_exact`: on every frame of `far`, the view skipped faded batches, a CPU replay of the
  view's extraction counts the same faded batches, and every cell with an instance whose fade anchor lies
  within the fade end is among the view's candidates when its bound meets the frustum, and among the shadow
  candidates when it casts. A run without a faded layer passes it vacuously.

Switches: `--gpu-timings` (build with `python3 scripts/build.py --target vegetation --opt O3 --define
C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL --lib c3d_profile`), `--shading forward|deferred`,
`--shadows atlas|traced`, `--size`, `--foliage both|grass|none`, `--tree-fade-end METRES`,
`--width W --height H` (2560 × 1440 by default in benchmark mode) and `--validation`. Interactive runs always
validate; benchmark runs validate only with `--validation`. The tree layer's prepass and shadow-atlas cost is
the `both` against `grass` difference; the grass layer's is `grass` against `none`.

## Measured cost

### RTX 4090, driver 610.88, 2560 × 1440

Windows host, `--opt O3` with GPU timings, atlas shadows, three runs of each of eight cases (24 runs); medians,
forward shading at `--size 2049` unless named. Both gates pass in every run, and every `batch_slots` peak is
under its formula. A `--benchmark 60 --validation --shadows traced` run is validation-clean with both gates.

Load and edit, per map size:

| Line | 1025 | 2049 | 4097 |
| --- | ---: | ---: | ---: |
| Grass: instances, cells with a node | 198,207, 995 | 195,188, 3,895 | 173,585, 14,540 |
| Trees: instances, cells with a node | 4,049, 249 | 3,351, 898 | 4,514, 2,814 |
| `scatter_ms load`, grass / trees | 63.4 / 2.0 | 66.7 / 2.0 | 60.7 / 3.0 |
| `rescatter_ms`, both layers | 61.0 | 65.0 | 58.9 |
| `replace_ms` median / p99 per 49 × 49 stamp (cells placed) | 0.294 / 0.421 (10) | 0.095 / 0.099 (10) | 0.026 / 0.034 (10) |
| `update_us`, steady / gusting wind | 0.2 / 2.2 | 0.3 / 8.4 | 0.4 / 49.9 |
| `first_pack_ms` | 9.8 | 10.0 | 9.6 |
| `batch_slots` max / formula | 177 / 245 | 171 / 245 | 142 / 245 |

The still segment by layer set and tree fade end, ms:

| Line | none | grass | both | both, deferred | trees fade at 250 m | trees fade at 600 m |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `cpu_record` | 0.074 | 0.218 | 0.414 | 0.394 | 0.316 | 0.502 |
| `DEPTH_PREPASS` | 0.102 | 0.101 | 0.119 | 0.117 | 0.118 | 0.119 |
| `SHADOW_ATLAS` | 0.460 | 0.460 | 0.462 | 0.463 | 0.462 | 0.465 |
| `FORWARD_OPAQUE`, or `GBUFFER` deferred | 0.309 | 0.305 | 0.267 | 0.221 | 0.267 | 0.267 |
| `VELOCITY` | 0.117 | 0.116 | 0.120 | 0.122 | 0.120 | 0.120 |
| `INSTANCE_CULL` | 0.023 | 0.029 | 0.075 | 0.075 | 0.053 | 0.108 |
| `batch_slots` max / formula | 0 / 0 | 19 / 49 | 171 / 245 | 171 / 245 | 87 / 130 | 338 / 449 |

- **Grass** adds nothing measurable to the GPU passes at this density; its cost is `cpu_record` (+0.14 ms).
- **Trees** add +0.018 ms of depth prepass and +0.002 ms of shadow atlas: masked bark is not a measurable cost.
  Forward opaque falls as foliage covers terrain pixels, which cost more to shade. The tree layer's cost is per
  batch, not per instance: `INSTANCE_CULL` +0.046 ms and `cpu_record` +0.20 ms at a 400 m fade, both growing with
  the tree cells in range (cull 0.053, 0.075 and 0.108 ms at 250, 400 and 600 m).
- **Segments** at 2049, both layers: the spin uploads on 22 frames, at most 50.7 KB, with `cpu_record` 0.374 ms,
  below still; the far view skips 4,306 faded batches, with prepass 0.132, forward opaque 0.404 and shadow atlas
  0.285 ms. The frame's wall time stays about 1.2 ms throughout.
- **Loads and edits.** `scatter_ms load` is a load time. A whole re-scatter costs 59 to 65 ms, a one-off hitch
  that nothing in the example triggers during play; a stamp re-places its cells in under 0.5 ms.

### WSL, llvmpipe

llvmpipe is a CPU Vulkan implementation: frame and pass times there are environment only, never GPU numbers.
The CPU-side lines below are the layer's own work on an i9-14900K, from `--opt O3` smoke runs of 2 to 5 frames
per segment at 640 × 360 (320 × 180 at 4097); the full 300-frame runs take far longer than the environment
allows. Both gates pass in every run, `--foliage grass` and `none` and tree fade ends of 250 and 600 m
included.

| Line | 1025 | 2049 | 4097 |
| --- | ---: | ---: | ---: |
| Grass: instances, cells with a node, spacing | 198,207, 995, 0.98 m | 195,188, 3,895, 1.91 m | 173,585, 14,540, 3.90 m |
| Trees: instances, cells with a node, spacing | 4,049, 249, 6.19 m | 3,351, 898, 12.08 m | 4,514, 2,814, 24.66 m |
| `scatter_ms load`, grass / trees | 59.0 / 1.7 | 62.7 / 1.8 | 56.1 / 2.8 |
| `rescatter_ms`, both layers | 57.4 to 60.3 | 58.2 to 61.7 | 54.7 |
| `replace_ms` per 49 × 49 stamp (cells placed) | 0.28 (10) | 0.056 to 0.069 (4 to 8) | 0.019 (8) |
| `update_us` median, steady / gusting wind | 0.72 / 2.99 | 1.17 / 10.6 | 1.25 / 58.3 |
| `first_pack_ms` | 10.7 | 11.0 | 11.1 |
| `batch_slots` max against the formula | 169 / 245 | 175 / 245 | 147 / 245 |

`scatter_ms load` is a load time: `add_foliage` runs once. `rescatter_ms` is the hitch a density revision, a
layer move or a ground move would cost at run time; the example has none of them during play. A stamp
re-places only the cells it reaches, well under a millisecond. A gusting wind costs one sway store per cell,
2 to 4 ns each. At 2049 the peak batch slots were 32 against 49 with grass alone, 85 against 130 with a
250 m tree fade and 340 against 449 with 600 m.
