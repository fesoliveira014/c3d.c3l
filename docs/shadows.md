# Shadows

Directional lights created with `light::directional` cast shadows by default.
Point and spot lights start with shadows disabled; set `light.shadow.enabled = true`
after construction to enable them. All three kinds use the same layered atlas.
Standard materials receive them through their direct lighting. Basic materials
remain unlit and can cast shadows onto Standard surfaces.

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
| `max_distance` | 100 | Directional depth endpoint or unbounded punctual fallback |
| `bias` | 0.0005 | Nonnegative slope-scaled depth-bias magnitude |
| `normal_bias` | 0.02 | Nonnegative receiver displacement in world units |

Use `light::SHADOW_SETTINGS_DEFAULT` when constructing settings independently.
A zero-initialized settings record is disabled and does not contain those defaults.
Call `Light.validate_shadow()` after authored edits to check these programming
contracts in checked builds. Contract checks may be absent from optimized unchecked
builds, so applications must not rely on them as runtime validation. Enabled
directional settings require a finite positive `max_distance`, finite nonnegative
biases, cascades in 1..4 and split weight in 0..1. Enabled punctual settings require
a finite nonnegative range, a positive finite fallback when range is zero, and the
spot cone rule above.

`RendererDesc.shadow_resolution` and `max_shadow_layers` set the atlas dimensions
at renderer creation. Zero selects 2048 and 4, respectively. A nonzero resolution
must exceed four texels. The device must support the requested dimensions and
allocation. Four 2048-square D32 layers contain **64 MiB of depth texels**; driver
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
filter. A receiver exactly at a split uses the nearer cascade. Different cascade
resolutions can produce a visible change in softness at a boundary; there is no
cross-cascade blend or fade at the end of shadow coverage.

Bias reduces self-shadowing artifacts but can separate a shadow from its caster.
Normal offset moves the receiver along its unperturbed, face-corrected surface
normal. Tune both values for the scene scale, slopes and shadow resolution. No
single setting guarantees artifact-free contact at every scale.

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

## Example and timing

```bash
python3 scripts/build.py --example shadows
./examples/build/shadows --gpu-timings
```

The example provides separate Sun, Spot and Point presets over ground, solid and
masked casters. Sun retains two directional lights competing by priority and the
off-camera receiver-mask demonstration. Point adds five receive-only panels and
small blockers around the light while the ground supplies the sixth direction. Its renderer explicitly
uses six 2048-square layers. The GUI restricts controls to the active light kind.
Drag outside the GUI to orbit, scroll to zoom, and release Escape outside keyboard
capture to close.

The example uses a 0.16-world-unit normal offset for its 28-unit ground plane.
The settings table above describes the library defaults. Its depth-bias control
spans 0..4 so the slope-factor tradeoff is visible at this scene scale.

`Stats.shadow_layers` counts recorded layer passes and `shadow_requests_dropped`
counts complete requests rejected by capacity. Draw/triangle counts include the
depth passes. When GPU timestamps are enabled and supported, `shadow_timings`
exposes a delayed result for each layer, including its original light entity,
`kind`, zero-based local `layer_index` and milliseconds. Directional indices are
cascades, spot index zero identifies its sole projection, and point indices follow
the six-face order above. Identity is captured when work is recorded, so delayed
results remain correct after preset changes. The aggregate shadow pass remains in
`gpu_pass_ms`.

Timing results are read when the owning frame slot completes. If a frame records
multiple views, shadow timings describe its last recorded view; frame counters
still accumulate across views. A last view without shadows produces an empty
timing slice. The renderer owns that slice and invalidates it on the next
`begin_frame` or destruction. Without timestamp support the slice is empty.
