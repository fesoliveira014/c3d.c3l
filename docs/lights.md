# Lights and light selection

Lights are scene components: a `Light` on a node emits as a directional, point or spot source. The renderer
gathers the eligible lights of each view up to a per-view budget, then shades every pixel from either the
complete list (`FLAT`) or a per-cell list of a view-space grid (`CLUSTERED`). Light values live in `c3d::light`;
the node and `Scene.add_light` live in `c3d::scene`; selection settings are part of the view
(`c3d::render`, see [views](views.md)).

Shadows are configured on the light and covered in [shadows](shadows.md).

## Quick start

Import `std::math`, `c3d::light`, `c3d::scene` and `c3d::maths`.

```c3
Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 1))!;
sun.local.rotation = maths::look_rotation({ -0.5f, -1, -0.3f }, { 0, 1, 0 });

Node* bulb = scene.add_light(light::point({ 1, 0.85f, 0.7f }, 10, 10))!;
bulb.local.position = { -3, 2, 4 };

Node* spot = scene.add_light(light::spot(
    color: { 1, 1, 1 },
    intensity: 20,
    inner: 0.3f,
    outer: 0.6f,
    range: 12,
))!;
spot.local.position = { 3, 3, 5 };
spot.local.rotation = maths::look_rotation((-spot.local.position).normalize(), { 0, 1, 0 });

scene.update_world();
```

Edit the `Light` component in place (`scene.get(node, Light)`). Light values are gathered anew for every view and
need no dirty call. Call `scene.update_world()` after transform changes, before rendering.

## Concepts

- **Emission.** Directional and spot lights emit along the node's world negative Z axis. Point and spot positions
  come from the node's world transform. Parenting moves and rotates a light; scale does not change intensity or
  range. The transformed direction must stay nonzero.
- **Eligibility.** A light is eligible for a view when its node is visible (the node and every ancestor), its node
  `layers` intersect the camera's `layers`, its receiver mask `Light.layers` is nonzero and its intensity is
  positive. An ineligible light consumes no budget.
- **Budget.** A view keeps at most `RendererDesc.max_lights` eligible lights. Finite point and spot lights whose
  range sphere lies outside the view frustum are culled first. The first remaining lights in the scene's dense
  component order fill the budget and the rest are dropped. Removing components can change that order; selection
  is neither brightness ranked nor stable under insertion order. Directional and range-zero lights are never
  frustum culled.
- **Receiver mask.** `Light.layers` selects which mesh-node layers the light illuminates. It is independent of the
  camera mask, so a mesh seen through camera layer 1 with node layers `1|2` can receive a light whose mask is
  only 2. Ambient and emissive terms ignore it. Traced hits (reflections, probe updates and the path tracer) apply
  the same mask through the hit row's node layers.
- **Selection.** `FLAT` evaluates every selected light at every shaded point. `CLUSTERED` evaluates the lights of
  the point's grid cell plus the globals. Selection changes which lights a pixel visits, not the budget, the
  receiver masks, the shadow mapping or the BRDF.

## Add lights

| Constructor | Parameters |
| --- | --- |
| `light::directional(color, intensity, shadow = true)` | `intensity` is an irradiance scale; `shadow` enables the default directional shadow settings |
| `light::point(color, intensity, range = 0)` | `intensity` is a radiant-intensity scale; `range` in world units |
| `light::spot(color, intensity, inner, outer, range = 0)` | `inner` and `outer` are cone half-angles in radians, `0 <= inner < outer <= PI/2` |

- Color and intensity are finite and nonnegative.
- Point and spot lights fall off with the inverse square of the distance. A positive `range` is a world-space
  cutoff with a smooth window inside it and zero contribution at and beyond it. Range 0 is unbounded.
- A spot has full angular weight inside the inner cone, zero at the outer cone, and a smooth ramp between. The
  renderer floors the inner-to-outer cosine difference at 0.001, so a very narrow cone can lose some weight inside
  its inner angle.
- `Light.volumetric` makes the light scatter in the [volumetric fog](sky.md#volumetric-fog) of a view that has one
  and does nothing else. The three constructors set it; set it to false to opt a light out. A zero-initialized
  `Light` does not scatter.
- `Light.source_radius` (point and spot, metres) and `Light.source_angle` (directional, half-angle in radians) size
  the source that [ray-traced shadows](ray_traced_shadows.md#soft-shadows) sample. Both are zero by default (a point
  source) and must be finite and not negative; the angle must stay below `PI / 2`. Atlas shadows ignore them.
- `Scene.add_light` faults `c3d::CAPACITY_EXCEEDED` when the node capacity is full.

## Set ambient

A scene starts with white `ambient_color` and zero `ambient_intensity`; both stay finite and nonnegative. Ambient
adds a diffuse term, `ambient_color * ambient_intensity * base_color.rgb * (1 - metallic)`, using the mapped
base color and metallic values and the occlusion multiplier. It adds no specular reflection.

A selected lighting environment replaces the constant term unless `scene.ambient_add` is true. Environments supply
spherical-harmonic diffuse lighting and filtered specular reflection; the occlusion map affects only the diffuse
part. See [environments](environments.md) for source selection and preparation. Emissive color times strength
stays visible without direct or ambient light.

## Set the light budget

`RendererDesc.max_lights` sets the per-view budget at renderer creation. Zero selects `DEFAULT_MAX_LIGHTS` (256);
`Renderer.max_lights` holds the resolved value. The budget sizes the per-view light array and the flat fragment
loop. A clustered view keeps its own copy of the selected lights inside its cluster buffer.

## Select lights with clusters

Both view constructors choose `FORWARD` and `FLAT` and set `clusters` to `default_cluster_desc()`. Enable clustering
by changing the view between frames:

```c3
ViewDesc desc = render::default_view_desc();
desc.lights = LightSelection.CLUSTERED;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

`ClusterDesc` fields (all mutable between frames):

| Field | Default | Meaning |
| --- | --- | --- |
| `tiles_x`, `tiles_y` | 16, 9 | Grid tiles across the view |
| `depth_slices` | 24 | Slices along camera depth |
| `lights_per_cluster` | 64 | Finite lights stored per cell; a storage capacity, not a selection budget |
| `far_distance` | 100 | Clustering far distance in camera-view depth units |
| `depth_pruning` | false | Skips cells no opaque surface can occupy; see [depth pruning](#depth-pruning) |

- `CLUSTERED` needs nonzero dimensions and capacity, a positive finite `far_distance` and representable storage
  sizes, else `c3d::INVALID_ARGUMENT`. A grid beyond the device's compute dispatch limits faults
  `c3d::UNSUPPORTED`.
- `FLAT` neither validates nor allocates from `clusters`, even when its fields are zero.
- A zero-initialized `ViewDesc` has no cluster defaults. Start from a constructor, or assign
  `default_cluster_desc()` next to `lights = CLUSTERED`.
- `PATH_TRACED` views reject `CLUSTERED` with `c3d::INVALID_ARGUMENT`.

### Coverage and fallback

- Selection uses the view's unjittered camera projection and each shaded position, not the opaque depth buffer.
- Perspective depth slices are logarithmic and orthographic slices are linear.
- Coverage ends at the lesser of `far_distance` and the camera's finite far plane. A perspective far of zero means
  infinity; an orthographic far of zero does not. An empty depth interval disables clustering for that rendering.
- Finite point and spot lights enter a cell when their range sphere reaches it. Directional and range-zero lights
  are globals, evaluated once beside the cell's list.
- Indices refer to the original selected light array, so receiver masks and shadow mappings are preserved.
- A cell over capacity, a position outside the grid or the depth interval, and inactive coverage all use the
  complete flat list. The fallback is neither a truncated list nor a clamped edge cell, and globals are not added
  twice. A small `lights_per_cluster` trades savings for fallback; it never drops light contributions.

### Materials

Standard, Toon and non-transmitting Physical materials use the selector, including ordinary alpha-blended
surfaces. Physical materials with nonzero transmission use the flat list for their whole direct-light loop,
because the exit point can lie outside the surface cell. Custom shaders stay flat until they opt in; see the
[shared light selector](custom_shaders.md#light-selection).

### Storage

Each clustered view owns one private device buffer for its selected light and decal arrays, the per-cell ranges and
fixed-capacity index segments, and an overflow counter. It uses no application `BufferId` slot. Changing `tiles_x`,
`tiles_y`, `depth_slices` or `lights_per_cluster` replaces the buffer; changing `far_distance` or `depth_pruning`
does not. Switching to `FLAT`, resizing or destroying a view, and renderer teardown retire the buffer after
submitted work completes.

The index segment dominates: `tiles_x * tiles_y * depth_slices * lights_per_cluster * 4` bytes, 884,736 at the
default grid of 3,456 cells. Decal storage adds 256 records, 8 indices per cell and a range per cell (175 KiB at
the default grid), and the pruning bound adds 4 bytes per tile whether pruning is on or off.

### Decals

Decals use the same grid and the same cull. The per-view limit is `MAX_DECALS` (256) and each cell stores at most
`MAX_CLUSTER_DECALS` (8) indices. Indices keep the complete decal array's `(order, entity)` order. Past the per-view
limit, selection keeps the lowest-order base layers and drops higher-order overlays first. A cell over its decal
capacity, inactive coverage or a position outside the grid uses the complete ordered decal list. Decal and light
overflow are independent. `FLAT` views upload the selected decal records through the frame ring and allocate no
cluster regions. See [decals](materials.md#decals).

### Depth pruning

With `ClusterDesc.depth_pruning` set, the view reduces its depth image to the farthest view depth of each tile
before the cull; a tile with any pixel that shows no geometry is unbounded. A cell whose near boundary lies beyond
that depth holds no opaque point, so the cull skips it: it writes an empty, overflowing range for lights and decals
and runs neither loop. Any reader that reaches a skipped cell takes the complete flat list, so no light is dropped
and shading is unchanged. Fog froxels behind the farthest surface and draws without a depth test sum the same
lights in a different order.

- Only the far side is pruned. Cells in front of a tile's nearest surface keep their lists, because fog froxels and
  blended surfaces read them.
- A tile with a single background pixel (sky, or depth never drawn) is never pruned, so open horizons prune little.
  The savings are the cells behind the visible geometry of each tile.
- The reduction adds one dispatch and a barrier to `LIGHT_CULL`. Compare the completed `LIGHT_CULL` time with the
  setting off.
- Pruning needs depth before any pass reads the cell lists. A forward view without a depth prepass (and without
  ambient occlusion or screen-space GI, which imply one) ignores the field, and so does a forward view with traced
  reflections, whose thin reflection prepass is both the depth producer and a reader of the decal lists. Neither is
  a fault. Deferred views always have depth.
- On a pruned view the reduction, the cull and the [volumetric fog](sky.md#volumetric-fog) volume run after the
  depth prepass instead of before every other pass. On a deferred view that is between the prepass and the G-buffer
  pass.
- Tiles map from the unjittered view. Under TAA a pixel within half a pixel of a tile edge can shade with the
  neighbouring tile's lists; when that tile's bound is nearer, the point takes the flat list.
- On a view with [`msaa`](msaa.md) above `ONE` the reduction reads the depth resolved from sample 0. A sample
  farther than its tile's resolved depth reaches a skipped cell and takes the flat list.

## Spatial light lookup

Traced hits select lights through a bounding-volume hierarchy built from the lights accepted for that rendering:
reflection hits, path-traced bounces and probe updates each upload one. A hit visits every global once, then
every light of each leaf whose box contains the hit position; the light's range attenuation decides its
contribution. The hierarchy lives in frame-upload storage, is rebuilt every rendering and adds no cache and no
light budget. An empty or all-global list uses the flat path, as do degenerate ranges (subnormal squared range,
non-finite bounds).

Cluster construction builds the same hierarchy over the packed finite lights of a clustered view when the list is
large and its ranges overlap little; otherwise it tests every light against each cell. Raster `FLAT` selection, the
public `LightList` helpers, transmitting Physical lighting and the fog selector do not use it.

## Diagnostics

- `Stats.lights` and `Stats.lights_dropped` sum the packed lights and budget drops over the recorded views and reset
  at `begin_frame`. `ViewStats.lights` and `ViewStats.lights_dropped` describe one view.
- `Stats.cluster_view`, `cluster_count`, `cluster_overflows`, `cluster_skipped` and `decal_overflows` are completed
  results read when the reused frame slot completes, `FRAMES_IN_FLIGHT` frames late, with or without GPU
  timestamps. `cluster_view` names the view they describe; with several clustered views read the same fields on
  `ViewStats`. The readback adds no wait to `render_view`.
- `cluster_count` is the grid's cell total. `cluster_overflows` and `decal_overflows` count overflowing cells, not
  dropped lights. `cluster_skipped` counts cells depth pruning skipped and is not part of `cluster_overflows`.
- `Pass.LIGHT_CULL` times the cull, including the tile-depth reduction on a pruned view. Decal sampling is timed in
  the receiver's draw pass.
- `gui::targets_panel` switches `FLAT` and `CLUSTERED` and shows a cluster-slice occupancy heatmap; see
  [GUI diagnostics](gui.md#cluster-diagnostics). `gui::stats_panel` and `gui::view_stats_table` print the counters.
- `render::cluster_cell` and `render::cluster_index` are the C3 twins of the shader selection, for tools and tests.

To compare `FLAT` and `CLUSTERED`, keep light count, range, capacity, camera and working extent fixed and compare
the completed `LIGHT_CULL` and opaque pass times. Dense overlap and overflow fallback can remove the advantage. See
[benchmarking](benchmarking.md#headless-many-light-rendering) and [profiling](profiling.md#capture-gpu-work).

Run `python3 scripts/build.py --example many_lights`. It lights a procedural hall with 64 to 4096 point lights; its
panel switches selection mode, light range, cell capacity and depth pruning. The benchmark mode takes `--mode`,
`--lights`, `--range`, `--capacity` and `--depth-pruning`.

## Limits

- Custom shaders select lights only when they opt in.
- Physical transmission evaluates the flat list.
- The budget caps the lights a view considers; `lights_per_cluster` caps only the per-cell storage.
- Depth pruning does nothing on views without depth before shading.
- Atlas shadows ignore source extents.

## See also

- [Views](views.md) for `ViewDesc` and `configure_view`.
- [Shadows](shadows.md) and [ray-traced shadows](ray_traced_shadows.md).
- [Materials](materials.md) for how light terms combine with material factors.
- [Custom shaders](custom_shaders.md#light-selection) for the light selector helpers.
- [Environments](environments.md) for image-based lighting.
