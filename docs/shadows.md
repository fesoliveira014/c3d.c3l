# Shadows

Directional lights created with `light::directional` cast shadows by default.
Point and spot lights start with shadows disabled; set `light.shadow.enabled = true`
after construction to enable them. All three kinds use the same layered atlas.
Standard materials receive them through their direct lighting. Basic materials
remain unlit and can cast shadows onto Standard surfaces.

Shadow fitting uses the frame's [render origin](large_world.md). Camera/caster
bounds and punctual light positions share relative coordinates. Directional
cascade snapping keeps its texel lattice fixed in absolute world space across
reference changes. `draw_shadow_frusta` still emits absolute debug endpoints.
The `shadows` example includes a 0–50 km offset control and a cascade movement
readout in texels per frame.

## Add a sun

Given a live `Scene scene`, import `std::math`, `c3d::light`, `c3d::scene` and
`c3d::maths`:

```c3
Light sunlight = light::directional({ 1, 1, 1 }, 1);
sunlight.shadow.cascades = 4;
sunlight.shadow.max_distance = 100;
Node* sun = scene.add_light(sunlight)!;
sun.local.rotation = maths::look_rotation({ -0.5f, -1, -0.3f }, { 0, 1, 0 });
scene.update_world();
```

Light rays follow the node's world negative-Z direction. Moving a directional
light's position does not move its shadow projection. Edit its component to
change shadow settings; light edits need no asset dirty call. Update world
transforms before rendering after changing node transforms.

Pass `false` as the third argument to `light::directional` to start without
shadows, or set the component's `shadow.enabled` to false.

An `Atmosphere` on the sun's node ([sky](sky.md#the-sun)) attenuates its light by the air it crosses;
below the horizon the sun packs no light and casts no shadow.

## Add punctual shadows

Point shadows consume six contiguous atlas layers, one for each cube face. Spot
shadows consume one:

```c3
Light bulb = light::point({ 1, 0.85f, 0.7f }, 40, 12);
bulb.shadow.enabled = true;
Node* bulb_node = scene.add_light(bulb)!;
bulb_node.local.position = { 0, 4, 0 };

Light cone = light::spot(
    color: { 1, 1, 1 },
    intensity: 80,
    inner: math::deg_to_rad(20.0f),
    outer: math::deg_to_rad(35.0f),
    range: 20,
);
cone.shadow.enabled = true;
Node* cone_node = scene.add_light(cone)!;
cone_node.local.position = { 0, 8, 5 };
cone_node.local.rotation = maths::look_rotation({ 0, -0.8f, -0.6f }, { 0, 1, 0 });
scene.update_world();
```

For a finite punctual light, `Light.range` is both its illumination range and
shadow endpoint; `ShadowSettings.max_distance` is unused. A zero range means
unbounded illumination, and `max_distance` becomes the required finite positive
shadow fallback distance. Both use world units. The renderer chooses the shadow
near plane automatically as the smaller of 0.05 world units and one percent of
the effective shadow range. This keeps short ranges such as 0.01 valid.

A shadow-enabled spot requires a positive outer half-angle strictly below 90
degrees. Its inner half-angle must remain smaller than its outer angle. Spots
without shadows retain the constructor's inclusive 90-degree limit.

## Settings and capacity

| Setting | Default | Effect |
| --- | --- | --- |
| `enabled` | true for directional; false for point/spot | Requests shadow layers |
| `priority` | 0 | Higher values win when requests compete |
| `cascades` | 4 | One to four shadow maps over the camera's depth range |
| `cascade_lambda` | 0.8 | Perspective split distribution: 0 uniform, 1 logarithmic |
| `cascade_blend` | 0.1 | Blend band before each split, as a fraction of the cascade's depth span; 0 selects one cascade |
| `max_distance` | 100 | Directional depth endpoint or unbounded punctual fallback |
| `bias` | 0.0005 | Nonnegative slope-scaled depth-bias magnitude |
| `directional_normal_bias_texels` | 2 | Directional receiver offset along its normal, in texels of each cascade |
| `punctual_normal_bias` | 0.02 | Spot and point receiver offset along its normal, in metres |

Use `light::SHADOW_SETTINGS_DEFAULT` when constructing settings independently.
A zero-initialized settings record is disabled and does not contain those defaults.
Call `Light.validate_shadow()` after authored edits to check these programming
contracts in checked builds. Contract checks may be absent from optimized unchecked
builds, so applications must not rely on them as runtime validation. Enabled
directional settings require a finite positive `max_distance`, a finite nonnegative
`bias` and `directional_normal_bias_texels`, cascades in 1..4, split weight in 0..1
and blend band in 0..0.5. Enabled punctual settings require a finite nonnegative
`bias` and `punctual_normal_bias`, a finite nonnegative range, a positive finite
fallback when range is zero, and the spot cone rule above. Each kind ignores the
other kind's normal offset.

`RendererDesc.shadow_resolution` and `max_shadow_layers` set the atlas dimensions
at renderer creation. Zero selects 2048 and 4, respectively. A nonzero resolution
must exceed four texels. A directional light's normal offset must stay below half
the resolution less two texels. The device must support the requested dimensions
and allocation. Four 2048-square D32 layers contain **64 MiB of depth texels**; driver
allocation overhead is additional. The atlas is allocated when the first complete
request is accepted and retained until renderer destruction. Disabling shadows
after use keeps that allocation available for reuse. Window resizing does not
resize the atlas.

A light receives all its requested shadow layers or none. Requests are ordered by
descending priority, then ascending entity index and generation. A request that
does not fit is counted as one drop; the renderer continues trying later requests.
That light still illuminates its receivers without shadow attenuation. Shadow
priority operates on the lights already selected by the ordinary light budget.

For example, a four-layer atlas can hold one four-cascade sun or two two-cascade
suns, but cannot hold a point request. A point-shadow renderer needs at least six
layers. Six 2048-square D32 layers contain **96 MiB of depth texels** before driver
overhead. Insufficient capacity drops the whole point request and leaves that light
illuminating without shadows. Reducing a sun's cascades can make another complete
request fit without reallocating the atlas.

## Casting, receiving and layers

`Scene.add_mesh` enables both `Mesh.cast_shadow` and `Mesh.receive_shadow`.
They are independent: a mesh can receive illumination without shadow attenuation,
or cast onto another mesh without receiving shadows itself.

`Light.layers` selects which mesh-node layers receive that light's illumination.
Caster selection ignores this receiver mask and the camera's layer mask. A visible
mesh excluded from either mask can still block the light and cast onto a visible
receiver. This supports, for example, separately lit characters that still cast
sun shadows onto the environment.

A hidden node or hidden ancestor cannot cast. Turning `cast_shadow` off removes
only its casting. Casters with dead geometry/material ids are skipped through the
existing dangling-reference behavior. Geometry bounds and authored mesh bounds
overrides must conservatively contain the surface; objects outside the camera
frustum remain eligible when their light-space bounds affect the receiver region.

The light node's own visibility and camera-layer inclusion still determine whether
that light participates in the view. A zero receiver mask or zero intensity
produces no contribution or shadow request.

## Cascades and tuning

Perspective cameras blend uniform and logarithmic split distances. Orthographic
cameras use uniform splits; their split weight has no effect and their existing
nonpositive near-plane values remain supported. Coverage ends at the smaller of
`max_distance` and a finite camera far plane. An infinite camera far plane still
has finite shadow coverage. An empty capped interval produces no shadow request.
For scaled camera transforms, distance follows camera-space depth rather than
Euclidean distance through the world.

The renderer snaps a stable receiver projection to shadow texels and extends its
depth coverage for off-camera casters. Camera movement can therefore preserve
the shadow grid while the light, lens and coverage settings remain fixed.
Changing those settings can change the projection.

Each receiver selects one cascade by camera-space depth and uses a 3x3 comparison
filter. A receiver exactly at a split selects the nearer cascade; with a band its
weight there is one, so it shows the next cascade's visibility. Different cascade
resolutions change the softness at a boundary, so each cascade except the last ends
in a blend band: over the final `cascade_blend` fraction of its depth span a
receiver samples both that cascade and the next and interpolates their visibility
linearly with depth. The next cascade's receiver fit extends back over the band, so
both maps cover it; the extension costs the coarser map some resolution, and a
receiver in a band takes eighteen comparisons instead of nine. `cascade_blend = 0`
selects one cascade exactly as without the band. There is no fade at the end of
shadow coverage.

A receiver whose selected cascade does not hold it reads the next coarser cascade that does, and reads lit when none
does. With a view's own set this never happens inside its frustum; a set fitted to another camera
([shadow sets](#shadow-sets)) can rely on it.

## Shadow sets

Every forward or deferred view binds one shadow set: the atlas layers it samples, their `ShadowGpu` array and the
layers of each shadowing light. A view records a set, or binds the one an earlier view of the frame recorded.

```c3
renderer.render_view(
    scene:         &scene,
    camera_node:   mirror_node,
    view:          mirror_view,
    shadow_camera: camera_node,
)!;
renderer.finish_view(mirror_view)!;
renderer.render_view(&scene, camera_node, renderer.default_view)!;
```

- `render_view`'s `shadow_camera` is the camera the view's set is fitted to; null is the view's own camera. A node
  without a `Camera` faults `INVALID_ARGUMENT`.
- A set is a function of its key: the scene, the frame, the shadow camera's view matrix and its projection at the
  recording view's working extent, its `Camera.layers` and the view's
  `ray_tracing.shadows`. Keys compare bit for bit. Two camera nodes with equal values share a set; a camera moved
  between two views records twice.
- Light selection, the atmosphere sun's radiance and the distance fade of batches and LOD groups follow the shadow
  camera. Casters are every visible caster, as for any set. LOD groups cast with the levels the recording view
  selected; impostors keep light-relative frames.
- A view binds the published set when the keys match and its `ViewDesc.share_shadows` is on (both constructors set
  it). It records no atlas, and its lights take their layers from the set by light entity. A light the view lights
  that the set holds no layers for draws unshadowed and, when the set's camera is not the view's own, counts in
  `Stats.shadow_lights_unshared`.
- The renderer holds one set at a time. A view with another key records over it, so render views that share next to
  each other. With `share_shadows` off a view always records, never binds a set and leaves nothing for later views.
- Two views of one camera share automatically when their aspects match, for example a capture of the window view. The
  second view's `lod_bias` then does not change the casters' levels; turn `share_shadows` off to give it its own set.
- A camera whose `Camera.aspect` is zero takes its aspect from each view's working extent. A view at another render
  scale can round to another aspect, and then records its own set without notice; `shadow_sets_shared` and
  `ViewStats.shadow_set_shared` show it. Set `Camera.aspect` on cameras whose views should share.

A borrowed cascade fits the shadow camera's frustum, not the reading view's. A receiver outside every cascade reads lit,
so a borrowed shadow can end at a straight edge. For planar mirrors:

- Horizontal mirrors (water, floors) are valid. Modelled for a lake, the main camera's cascades hold every receiver
  from 1 to 1000 m in every pose except a steep look-down, 90.5 % at 300 m height; the coarser cascades hold the rest.
- Wall mirrors are valid only while the reflected receivers lie inside the shadow camera's shadow range. Under a
  vertical or side sun their shadows end beyond about 65 m.

`Stats.shadow_sets_recorded` and `shadow_sets_shared` count the frame's raster views by what they did; each adds one to
exactly one of them. `ViewStats.shadow_set_shared` tells whether the view's last raster rendering bound another view's
set, and `gui::view_stats_table` shows it. `shadow_layers` and `shadow_timings` count recordings: a shared atlas is
timed once, under the recording view's id. `draw_shadow_frusta` shows the last recorded set.

### Lookup cost

The coarser-cascade lookup costs every forward view, borrowing or not, because the fall-through changes the compiled
shader. RTX 4090, `sky --benchmark`, main view `FORWARD_OPAQUE`, ms, interleaved runs, three each:

| Segment | Before | With the lookup | With the old lookup |
| --- | ---: | ---: | ---: |
| twilight | 0.0461 | 0.0604 | 0.0461 |
| noon | 0.0686 | 0.0707 | 0.0666 |
| valley | 0.0942 | 0.1024 | 0.0911 |

Reverting only `shadows.glsl` returns twilight to its earlier time, so the growth is the lookup's code, not the shadow
data: twilight binds no layers in either build. The growth is +0.004 to +0.014 ms, under the 0.05 ms bar the change
set, and is accepted. A variant without the fall-through for views that never borrow is not built; it would be built
when the lookup costs more than 0.05 ms of `FORWARD_OPAQUE` in a forward-heavy scene on the 4090.

## Normal offset

A receiver looks up its shadow from a point moved along its normal. A directional
light moves the point by `directional_normal_bias_texels` texels of the cascade that
shades it. The renderer writes that offset in metres for each cascade, so it grows
with the cascade's coverage, and widens each cascade's fit to hold it. The default,
two texels, is the reach of the 3x3 filter and clears self-shadowing at any slope
and sun elevation. Four cascades over 400 m at 2048 texels with the sky example's
camera (60° vertical, 16:9) have texels of about 2.6, 5.3, 12 and 48 cm, so offsets
of about 5, 11, 24 and 96 cm.

The offset costs two things, and both grow with the cascade:

- A caster thinner than the offset casts no shadow on the surface it rests on: with
  the cascades above, a 4 cm board on the ground in the first, a 90 cm crate in the
  last.
- A shadow's tip moves toward its caster by the offset divided by the tangent of the
  sun's elevation.

A box standing on the ground keeps its contact shadow. Where either loss shows, use
[ray-traced shadows](#ray-traced-shadows), which apply no offset.

Forward shading moves the point along the face-corrected vertex normal. Deferred
shading moves it along a face normal rebuilt from depth: on each image axis, the
neighbour on the side whose two texels continue the centre's depth in a straight
line, turned toward the camera. Neither reads the normal map. A forward impostor
moves along its baked normal, a deferred one along the face of the depth it writes.

A spot or point light moves the point by `punctual_normal_bias` metres. The 0.02 m
default is about two texels of a 2048-texel spot with a 45° outer cone at 10 m;
longer ranges and wider cones need a larger value, set by hand.

`bias` scales the depth pass's slope-scaled depth bias.

## Punctual projection and filtering

Spot shadows project along the light node's world negative-Z direction. Point
shadows ignore node rotation and select faces by the dominant receiver direction,
with ties preferring X, then Y, then Z. Their local layer order is `+X`, `-X`,
`+Y`, `-Y`, `+Z`, `-Z`. Both kinds use the same 3x3 comparison filter as sun
shadows. Point filter taps clamp at the selected face edge; filtering does not
cross cube-face boundaries.

The renderer applies a radial far cutoff before sampling punctual shadows. A
receiver beyond the effective shadow range stays directly lit even when its
projection would fit inside a spot frustum or a point cube corner.

## Material and source behavior

Opaque casters do not sample material textures. Basic and Standard MASK casters
use their base alpha factor, base map, selected UV0/UV1, UV transform, sampler and
alpha cutoff. Alpha cutouts therefore follow the same material semantics as the
visible surface. Double-sided and reflected-model face handling are preserved.
Basic BLEND materials cast opaque shadows, matching their current opaque forward
rendering. Standard BLEND remains unsupported.

A shadow-only draw resolves the geometry and, for MASK, its base map. It does not
require Standard normal, metallic/roughness, occlusion or emissive sources.
`prepare_scene` retains its broader all-mesh/all-material preparation contract;
applications preparing only selected assets can use the existing explicit upload
operations instead.

`extract_lights` is infallible. It validates enabled shadow settings as programming
contracts and no longer returns `UNSUPPORTED` for selected point or spot lights.
Renderer entry points and `prepare_scene` remain optional because GPU, material,
asset-source and command-recording failures still propagate.

Texture/sampler revisions refresh shadow bindings without an unrelated material
edit. Material edits still require `mark_material_dirty`. A current uploaded
backing remains usable after explicit CPU source release. If a needed upload has
no source, the operation returns `c3d::ASSET_DATA_UNAVAILABLE`. Invalid alpha-map
UV selection or a comparison sampler returns `c3d::INVALID_ARGUMENT`; live cube
or render-target alpha references return `c3d::UNSUPPORTED`. Missing/stale texture
references use the existing absent-map behavior. Backend faults propagate unchanged.

Shadows attenuate each selected direct-light contribution. Ambient and emissive
terms retain their existing behavior.

## Ray-traced shadows

A light can resolve its shadow with one ray per shaded pixel instead of atlas layers:

```c3
Renderer renderer = render::create_renderer(mem, &assets, { .ray_queries = true })!;
Light sun = light::directional({ 1, 1, 1 }, 3);
sun.shadow.ray_traced = true;
ViewDesc desc = render::default_view_desc();
desc.ray_tracing.shadows = true;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

- `RendererDesc.ray_queries` requests ray queries. With no adapter that supports them, `create_renderer` faults `c3d::UNSUPPORTED`. A renderer created without them traces shadows through the software walk ([scene tracing](scene_trace.md)). On an RTX 4090, tracing Sponza's sun shadow at 2160p adds 5.8 ms to the deferred lighting pass in software against 0.33 ms on ray queries, about 18 times, measured against the atlas (GPU frames 6.8 and 1.3 ms; [benchmarking](benchmarking.md#traced-effects-in-software-and-on-ray-queries)).
- A light traces when `shadow.enabled`, `shadow.ray_traced` and the view's `ray_tracing.shadows` are all set. Every other light keeps the atlas, so a view can mix both.
- A traced light holds no atlas layer in that view.
- The ray starts `TRACE_SURFACE_OFFSET` (0.02 world units, shared with every traced effect) along the receiver's normal. The offset hides self-intersection at the cost of a small gap where a caster meets its receiver. `bias`, the normal offsets and `max_distance` do not apply; directional rays stop at `RT_SHADOW_FAR` (10000 world units), punctual rays at the light.
- A single-sided caster casts where its front faces the light, as in the atlas; a double-sided one casts from both faces ([facing](scene_trace.md#facing)).
- Casters are the traced scene (see [scene tracing](scene_trace.md#what-traces)): `cast_shadow = false` keeps a mesh out of shadow rays, `MASK` materials cast their alpha-tested coverage, and off-camera objects cast like any other. Skinned and morphed meshes cast at their raster pose; crowd instances, custom vertex stages and `BLEND` meshes do not cast traced shadows.
- Shadows are hard; the sun has no angular size.
- Custom forward stages receive traced shadows through `ShaderDesc.traced_fragment`, a form compiled with `RT_SHADOWS` for renderers with ray queries and one with `RT_SHADOWS` and `SCENE_TRACE_BVH` for the software walk ([custom shaders](custom_shaders.md#traced-shadows)). Without the form the view draws the plain stage, which a traced light reaches with `shadow_count == 0`: lit, without that shadow. Custom G-buffer stages are shadowed by the lighting resolve.

`examples/rt_shadows` shows a box behind the camera casting onto the ground. `T` switches between traced shadows and the atlas, `M` swaps the box to a masked checker material, `C` swaps the ground between its Standard material and a custom twin with traced forms (`--twin-ground` starts on the twin). `--software` creates the renderer without ray queries, and the Trace panel names the kind. Under WSL the only Vulkan 1.3 device is llvmpipe, which supports ray queries: use it for correctness and a hardware driver for timing.

## Example and timing

```bash
python3 scripts/build.py --example shadows
c3c build shadows --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL
./examples/build/shadows --gpu-timings
```

The example provides separate Sun, Spot and Point presets over ground, solid and
masked casters. Sun retains two directional lights competing by priority and the
off-camera receiver-mask demonstration. Point adds five receive-only panels and
small blockers around the light while the ground supplies the sixth direction. Its renderer explicitly
uses six 2048-square layers. The GUI restricts controls to the active light kind.
Drag outside the GUI to orbit, scroll to zoom, and release Escape outside keyboard
capture to close.

The example's suns use the default two-texel offset; its spot and point use the 0.02 m default.
The normal-offset control reads texels for the suns and metres for the spot and point.
The settings table above describes the library defaults. Its depth-bias control
spans 0..4 so the slope-factor tradeoff is visible at this scene scale.

`Stats.shadow_layers` counts recorded layer passes and `shadow_requests_dropped`
counts complete requests rejected by capacity. `shadow_sets_recorded`,
`shadow_sets_shared` and `shadow_lights_unshared` count the frame's
[shadow sets](#shadow-sets). Draw/triangle counts include the depth passes.
When GPU timestamps are enabled and supported, `shadow_timings`
exposes a delayed result for each layer, including its original view id and light entity,
`kind`, zero-based local `layer_index` and milliseconds. Directional indices are
cascades, spot index zero identifies its sole projection, and point indices follow
the six-face order above. Identity is captured when work is recorded, so delayed
results remain correct after preset changes. The aggregate shadow pass remains in
`gpu_pass_ms`.

Timing results are read when the owning frame slot completes. Results retain all
measured layers across views for `Stats.gpu_frame_index`; a later view without
shadows does not erase an earlier view's layers. The renderer owns the slice and
replaces it when a newer completed summary publishes. Destruction also invalidates
it. Without timestamp support the slice is empty; truncated timing is partial.
See [profiling](profiling.md) for the build flags required by `--gpu-timings`.

## Measured cost

### RTX 4090, driver 610.88, 2560 × 1440

`LIGHTING` pass of deferred views, `--opt O3` with GPU profiling, median of three runs of per-run medians, in ms.
Before: main `3f297f5`. After: this change, whose resolve reads up to eight more depth texels a pixel.

| Scene | Before | After |
| --- | ---: | ---: |
| Sponza, `gltf_viewer --benchmark --shading deferred --shadows on` (`gpu_lighting_ms`) | 0.211 | 0.281 |
| `sky --benchmark --shading deferred`, noon (`pass=LIGHTING`) | 0.072 | 0.100 |

Per-run medians were 0.211/0.209/0.213 against 0.280/0.281/0.405 for Sponza, and 0.075/0.072/0.071 against
0.099/0.100/0.100 for sky. Sponza grows by 0.070 ms.
