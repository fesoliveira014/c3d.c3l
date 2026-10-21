# Shadows

Atlas shadows give directional, spot and point lights a shadow map: one layered depth atlas holds every light's
layers, and every Standard, Physical and Toon material receives them through its direct lighting. Settings live on the
light (`Light.shadow`, a `ShadowSettings` in `c3d::light`); the atlas is sized by `RendererDesc.shadow_resolution` and
`max_shadow_layers` (`c3d::render`). A light can also resolve its shadow with rays instead of atlas layers; see
[ray-traced shadows](ray_traced_shadows.md).

Directional lights made with `light::directional` cast shadows by default. Point and spot lights start with shadows
disabled; set `light.shadow.enabled = true` after construction. Basic materials stay unlit but cast shadows onto
Standard surfaces.

## Quick start

Given a live `Scene scene`, import `std::math`, `c3d::light`, `c3d::scene` and `c3d::maths`:

```c3
Light sunlight = light::directional({ 1, 1, 1 }, 1);
sunlight.shadow.cascades = 4;
sunlight.shadow.max_distance = 100;
Node* sun = scene.add_light(sunlight)!;
sun.local.rotation = maths::look_rotation({ -0.5f, -1, -0.3f }, { 0, 1, 0 });
scene.update_world();
```

Run `python3 scripts/build.py --example shadows`. It has Sun, Spot and Point presets over ground, solid and masked
casters, a normal-offset control and a 0 to 50 km origin offset. For `--gpu-timings`, build it with the profiler
add-on (`c3c build shadows --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL`).

## Concepts

- **Layered atlas.** One `D32_FLOAT` texture array holds every shadow layer. A directional light uses one layer per
  cascade, a spot light one, and a point light six (one per cube face).
- **Request, priority and capacity.** Each shadow-enabled light that the view selects requests all its layers. A light
  receives all its layers or none. Requests are ordered by descending `priority`, then ascending entity index and
  generation. A request that does not fit counts as one drop and the renderer tries later requests. A dropped light
  still illuminates its receivers, without shadow attenuation. Shadow priority operates on the lights the ordinary
  [light budget](lights.md#concepts) already selected.
- **Cascades.** A directional light splits the camera's depth range into up to four shadow maps, and each receiver
  selects one by camera-space depth.
- **Frame origin.** Shadow fitting uses the frame's [render origin](large_world.md). Camera and caster bounds and
  punctual light positions share relative coordinates, and directional cascade snapping keeps its texel lattice fixed
  in absolute world space across reference changes.
- **Shadows attenuate direct light.** Each selected direct-light contribution is attenuated; ambient and emissive
  terms are not.

## Add a sun

Light rays follow the node's world negative-Z direction. Moving a directional light's position does not move its shadow
projection. Edit the light component to change shadow settings; light edits need no asset dirty call. Update world
transforms before rendering after changing node transforms.

Pass `false` as the third argument to `light::directional` to start without shadows, or set `shadow.enabled` to
false. An `Atmosphere` on the sun's node ([sky](sky.md#the-sun)) attenuates its light by the air it crosses; below the
horizon the sun packs no light and casts no shadow.

## Add spot and point shadows

Point shadows consume six contiguous atlas layers and spot shadows one:

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

- For a finite punctual light, `Light.range` is both its illumination range and its shadow endpoint, and
  `ShadowSettings.max_distance` is unused. A zero range means unbounded illumination, and `max_distance` becomes the
  required finite positive shadow fallback distance. Both are world units.
- The renderer chooses the shadow near plane as the smaller of 0.05 world units and one percent of the effective
  shadow range, so short ranges such as 0.01 stay valid.
- A shadow-enabled spot needs a positive outer half-angle strictly below 90 degrees, with the inner half-angle smaller
  than the outer. A spot without shadows keeps the constructor's inclusive 90-degree limit.
- Spot shadows project along the light node's world negative-Z direction. Point shadows ignore node rotation and
  select the face by the receiver's dominant direction, with ties preferring X, then Y, then Z. The local layer order
  is `+X`, `-X`, `+Y`, `-Y`, `+Z`, `-Z`.
- Both kinds use the same 3x3 comparison filter as sun shadows. Point filter taps clamp at the selected face edge and
  never cross a face boundary.
- A radial far cutoff applies before sampling: a receiver beyond the effective shadow range stays directly lit, even
  when its projection would fit inside a spot frustum or a point cube corner.

## Size the atlas

`RendererDesc.shadow_resolution` and `max_shadow_layers` set the atlas dimensions at renderer creation. Zero selects
`DEFAULT_SHADOW_RESOLUTION` (2048) and `DEFAULT_MAX_SHADOW_LAYERS` (4).

- A nonzero resolution must exceed four texels. A directional light's normal offset must stay below half the
  resolution less two texels. The device must support the requested dimensions and allocation.
- Four 2048-square `D32` layers hold 64 MiB of depth texels, six hold 96 MiB, before driver overhead.
- The atlas is allocated when the first complete request is accepted and kept until renderer destruction.
  Disabling shadows afterwards keeps the allocation for reuse. Window resizing does not resize the atlas.
- A four-layer atlas holds one four-cascade sun or two two-cascade suns, but no point request: a point-shadow
  renderer needs at least six layers. Insufficient capacity drops the whole point request and the light illuminates
  without shadows. Reducing a sun's cascades can make another complete request fit without reallocating the atlas.

## Tune cascades

- Perspective cameras blend uniform and logarithmic split distances with `cascade_lambda` (0 uniform, 1
  logarithmic). Orthographic cameras use uniform splits and ignore it; their nonpositive near-plane values stay
  supported.
- Coverage ends at the smaller of `max_distance` and a finite camera far plane. An infinite far plane still has
  finite shadow coverage. An empty capped interval produces no request. For scaled camera transforms, distance
  follows camera-space depth rather than Euclidean distance through the world.
- The renderer snaps a stable receiver projection to shadow texels and extends its depth coverage for off-camera
  casters, so camera movement can preserve the shadow grid while the light, lens and coverage settings stay fixed.
  Changing those settings can change the projection.
- Receivers filter with a 3x3 comparison. A receiver exactly at a split selects the nearer cascade; with a band its
  blend weight there is one, so it shows the next cascade's visibility. Each cascade except the last ends in a blend
  band: over the final `cascade_blend` fraction of its depth span a
  receiver samples that cascade and the next and interpolates their visibility linearly with depth. The next
  cascade's receiver fit extends back over the band, which costs the coarser map some resolution, and a receiver in a
  band takes 18 comparisons instead of 9. `cascade_blend = 0` selects one cascade exactly. There is no fade at the
  end of shadow coverage.
- A receiver whose selected cascade does not hold it reads the next coarser cascade that does, and reads lit when none
  does. With a view's own set this never happens inside its frustum; a set fitted to another camera
  ([shadow sets](#shadow-sets)) can rely on it. The lookup is compiled into every forward view's shader, borrowing
  or not, and adds a small per-fragment cost.

## Normal offset

A receiver looks up its shadow from a point moved along its normal; `bias` scales the depth pass's slope-scaled depth
bias.

- **Directional.** The point moves by `directional_normal_bias_texels` texels of the cascade that shades it. The
  renderer writes that offset in metres per cascade, so it grows with the cascade's coverage, and widens each
  cascade's fit to hold it. The default of two texels is the reach of the 3x3 filter and clears self-shadowing at any
  slope and sun elevation.
- **Punctual.** A spot or point light moves the point by `punctual_normal_bias` metres. The 0.02 m default is about
  two texels of a 2048-texel spot with a 45 degree outer cone at 10 m. Longer ranges and wider cones need a larger
  value, set by hand.
- **Direction of the offset.** Forward shading moves the point along the face-corrected vertex normal. Deferred
  shading moves it along a face normal rebuilt from depth: on each image axis, the neighbour on the side whose two
  texels continue the centre's depth in a straight line, turned toward the camera. The rebuild reads up to eight extra
  depth texels a pixel. Neither reads the normal map. A forward impostor moves along its baked normal, a deferred one
  along the face of the depth it writes. On curved surfaces the two directions differ slightly.

The offset costs two things, and both grow with the cascade. Four cascades over 400 m at 2048 texels, with a 60 degree
vertical, 16:9 camera and a 0.1 near plane, have texels of about 2.6, 5.3, 12 and 48 cm and so offsets of about 5, 11,
24 and 96 cm.

- A caster thinner than the offset casts no shadow on the surface it rests on: a 4 cm board on the ground in the first
  cascade, a 90 cm crate in the last.
- A shadow's tip moves toward its caster by the offset divided by the tangent of the sun's elevation.

A box standing on the ground keeps its contact shadow. Where either loss shows, use
[ray-traced shadows](ray_traced_shadows.md), which ignore `bias` and the normal-offset settings.

## Choose casters and receivers

`Scene.add_mesh` enables both `Mesh.cast_shadow` and `Mesh.receive_shadow`. They are independent: a mesh can receive
illumination without shadow attenuation, or cast onto another mesh without receiving shadows itself.

- `Light.layers` selects which mesh-node layers receive that light's illumination. Caster selection ignores this
  receiver mask and the camera's layer mask, so a visible mesh excluded from either mask can still block the light
  and cast onto a visible receiver. This supports separately lit characters that still cast sun shadows onto the
  environment.
- A hidden node or hidden ancestor cannot cast. Turning `cast_shadow` off removes only casting. Casters with dead
  geometry or material ids are skipped.
- Geometry bounds and authored mesh bounds overrides must conservatively contain the surface. Objects outside the
  camera frustum stay eligible when their light-space bounds affect the receiver region.
- A light takes part in a view only when it is eligible ([lights](lights.md#concepts)); a zero receiver mask or zero
  intensity produces no contribution and no shadow request.
- Opaque casters do not sample material textures. Basic, Standard, Physical and Toon `MASK` casters use their base
  alpha factor, base map, selected UV set, UV transform, sampler and alpha cutoff, so cut-outs follow the same
  semantics as the visible surface. Double-sided and reflected-model face handling are preserved.
- A `BLEND` mesh, batch or LOD part casts no shadow, whatever its family, unless [colored shadows](#colored-shadows)
  are on. A custom `MASK` material casts through its own depth vertex stage, when it has one, and the built-in depth
  fragment stage, which tests slot 0's alpha against `alpha_cutoff` ([custom shaders](custom_shaders.md)).
- A shadow-only draw resolves the geometry and, for `MASK`, its base map. It does not need the normal,
  metallic-roughness, occlusion or emissive sources. `prepare_scene` still prepares every mesh and material; an
  application that prepares selected assets uses the explicit upload operations.
- Texture and sampler revisions refresh shadow bindings without a material edit; material edits still need
  `mark_material_dirty`. A current uploaded backing stays usable after explicit CPU source release. A needed upload with
  no source faults `c3d::ASSET_DATA_UNAVAILABLE`. An invalid alpha-map UV selection or a comparison sampler faults
  `c3d::INVALID_ARGUMENT`. A cube or `R16_UINT` alpha map and a view-texture reference fault `c3d::UNSUPPORTED`; a
  live render target is accepted. A missing or stale texture reference reads as the absent map.
- `extract_lights` does not fault: it validates enabled shadow settings as programming contracts. Renderer entry points
  and `prepare_scene` stay optional because GPU, material, asset-source and command-recording faults propagate.

## Shadow sets

Every forward or deferred view binds one shadow set: the atlas layers it samples, their `ShadowGpu` array and the layers
of each shadowing light. A view records a set, or binds the one an earlier view of the frame recorded.

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
  without a `Camera` faults `c3d::INVALID_ARGUMENT`.
- A set is a function of its key: the scene, the frame, the shadow camera's view matrix and projection at the recording
  view's working extent, its `Camera.layers` and the view's `ray_tracing.shadows`. Keys compare bit for bit. Two
  camera nodes with equal values share a set; a camera moved between two views records twice.
- Light selection, the atmosphere sun's radiance and the distance fade of batches and LOD groups follow the shadow
  camera. Casters are every visible caster, as for any set. LOD groups cast with the levels the recording view
  selected; impostors keep light-relative frames.
- A view binds the published set when the keys match and its `ViewDesc.share_shadows` is on (both constructors set
  it). It records no atlas, and its lights take their layers from the set by light entity. A light the view lights that
  the set holds no layers for draws unshadowed and, when the set's camera is not the view's own, counts in
  `Stats.shadow_lights_unshared`.
- The renderer holds one set at a time. A view with another key records over it, so render views that share next to
  each other. With `share_shadows` off a view always records, never binds a set and leaves nothing for later views.
- Two views of one camera share automatically when their aspects match, for example a capture of the window view. The
  second view's `lod_bias` then does not change the casters' levels; turn `share_shadows` off to give it its own set.
- A camera whose `Camera.aspect` is zero takes its aspect from each view's working extent. A view at another render
  scale can round to another aspect and then records its own set without notice; `shadow_sets_shared` and
  `ViewStats.shadow_set_shared` show it. Set `Camera.aspect` on cameras whose views should share.

A borrowed cascade fits the shadow camera's frustum, not the reading view's. A receiver outside every cascade reads lit,
so a borrowed shadow can end at a straight edge. For planar mirrors, horizontal mirrors (water, floors) are valid: the
main camera's cascades hold the reflected receivers in every pose except a steep look-down, where the coarser
cascades hold the rest. Wall mirrors are valid only while the reflected receivers lie inside the shadow camera's shadow
range. See [planar reflections](views.md#planar-reflections).

## Colored shadows

`Renderer.set_colored_shadows(true)` lets translucent casters tint the light behind them. The switch is renderer-wide,
off by default and takes effect at the next `begin_frame`. While it is off the renderer allocates nothing for it and
records no extra passes; receivers keep one branch per shadow lookup. It adds no field to `ShadowSettings`, so lights
and their serialization are unaffected.

```c3
renderer.set_colored_shadows(true);
```

**Casters.** With the switch on:

- A Physical material with `transmission > 0`, in any alpha mode, casts into the translucent maps instead of the opaque
  atlas.
- A Basic, Standard, Physical or Toon `BLEND` mesh, batch or LOD part with `cast_shadow` casts into them too.
  `ADDITIVE` materials emit light rather than block it, so they stay out unless they are transmissive.
- A custom `BLEND` material never casts: its alpha is the stage's own, which the shadow pass cannot know.
- Every other `OPAQUE` and `MASK` caster casts into the opaque atlas.

With the switch off, a transmissive `OPAQUE` or `MASK` Physical caster still casts an opaque shadow and a `BLEND` one
casts nothing.

**Tint.** A caster passes `T = (1 - a) + a * t * base * attenuation ^ (thickness / distance)` of the light, per channel:

| Term | Value |
| --- | --- |
| `a` | Coverage. `BLEND`: the base color factor's alpha times the base map's alpha and the vertex or instance color's alpha. `OPAQUE` and `MASK`: 1, and `MASK` discards below its cutoff |
| `t` | The Physical `transmission` factor; 0 for Basic, Standard and Toon, which pass `1 - a` of the light with no color |
| `base` | The base color factor times the base map and the vertex or instance color |
| `thickness` | The `thickness` factor times the model scale along the light's axis, as the surface's own refraction measures it |
| `attenuation`, `distance` | `attenuation_color` and `attenuation_distance`; a zero distance, or a zero thickness, applies no attenuation |

`transmission_map`, `thickness_map` and metallic are ignored.

**Receivers.** `shadows.glsl` provides `vec3 shadow_transmittance(frame, light, position, normal, view_depth)`: the
opaque visibility times the tint `T` of the translucent casters behind the receiver. Standard, Physical and Toon forward
shading, `shade_standard_surface`, `evaluate_standard_lights` and the deferred lighting resolve use it, so forward and
deferred views and views that share a [shadow set](#shadow-sets) read the same tint. `shadow_visibility` keeps its
float form and ignores the tint, as do volumetric fog, probe updates and the stages that call it.

**Passes and memory.** Each layer that holds a visible translucent caster records two extra passes after its opaque
depth, inside the `SHADOW_ATLAS` timing: a translucent depth pass and a transmittance pass that multiplies each
caster's `T` into the texel. Their draws count in `Stats.draws`. A layer without a translucent caster records neither;
its `ShadowGpu.colored_transmittance`, `colored_depth` and `colored_sampler` stay 0 and `shadow_transmittance` returns
the opaque visibility, which custom receivers can rely on.
Single-sided casters cull back faces as the light sees them, and a double-sided caster draws both faces, so a closed
double-sided mesh tints twice. The pipelines are built at first use, and `prepare_scene` does not build them. The
`RGBA8_UNORM` transmittance image and the `D32_FLOAT` translucent depth are atlas-shaped, `shadow_resolution² * 8` bytes
per layer together: 128 MiB at the default 2048² x 4 layers and 512 MiB at 4096² x 4, on top of the atlas's own depth.
They are allocated on the first frame the switch is on and a translucent caster shadows a light, and kept until the
renderer is destroyed, so toggling never reallocates.

**Limits.**

- Each texel holds one translucent depth, so a receiver between two panes takes both tints.
- The transmittance is 8 bits per channel.
- Traced shadows keep their own rule: the switch does not affect them, `OPAQUE` and `MASK` glass cast opaque shadows and
  `BLEND` casts nothing.
- Volumetric fog and probe updates see the opaque shadow only.
- Transmission and thickness maps are ignored.

Run `python3 scripts/build.py --example transparency`: a sun, a tinted blended Physical pane and a thick absorbing
slab; `C` toggles the switch.

## Reference

`ShadowSettings` (use `light::SHADOW_SETTINGS_DEFAULT` to construct settings independently; a zero-initialized record
is disabled and holds no defaults):

| Setting | Default | Effect |
| --- | --- | --- |
| `enabled` | true for directional; false for point and spot | Requests shadow layers |
| `priority` | 0 | Higher values win when requests compete |
| `bias` | 0.0005 | Nonnegative slope-scaled depth-bias magnitude |
| `directional_normal_bias_texels` | 2 | Directional receiver offset along its normal, in texels of each cascade |
| `punctual_normal_bias` | 0.02 | Spot and point receiver offset along its normal, in metres |
| `cascades` | 4 | One to four shadow maps over the camera's depth range (directional) |
| `cascade_lambda` | 0.8 | Perspective split distribution: 0 uniform, 1 logarithmic |
| `cascade_blend` | 0.1 | Blend band before each split, as a fraction of the cascade's depth span, 0 to 0.5; 0 selects one cascade |
| `max_distance` | 100 | Directional depth endpoint, or the unbounded punctual fallback |
| `ray_traced` | false | Resolves the light's shadow with rays instead of atlas layers ([ray-traced shadows](ray_traced_shadows.md)) |

Each kind ignores the other kind's normal offset. Call `Light.validate_shadow()` after authored edits to check the
contracts in checked builds; contract checks can be absent from optimized builds, so do not use them as runtime
validation. Enabled directional settings need a finite positive `max_distance`, a finite nonnegative `bias` and
`directional_normal_bias_texels`, cascades in 1 to 4, `cascade_lambda` in 0 to 1 and `cascade_blend` in 0 to 0.5.
Enabled punctual settings need a finite nonnegative `bias` and `punctual_normal_bias`, a finite nonnegative range, a
positive finite `max_distance` when the range is zero, and the spot cone rule above.

`RendererDesc`: `shadow_resolution` (default 2048) and `max_shadow_layers` (default 4); `ray_queries` or
`ray_tracing_pipelines` for [ray-traced shadows](ray_traced_shadows.md).

### Shadow counters

| Counter | Meaning |
| --- | --- |
| `Stats.shadow_layers` | Opaque layer passes recorded this frame; the colored passes are not counted (they count in `Stats.draws`) |
| `Stats.shadow_requests_dropped` | Complete requests rejected by atlas capacity |
| `Stats.shadow_sets_recorded`, `Stats.shadow_sets_shared` | The frame's raster views by what they did; each view adds one to exactly one |
| `Stats.shadow_lights_unshared` | Lights drawn unshadowed because the bound set lacks them, in views whose shadow camera is not their own |
| `ViewStats.shadow_set_shared` | The view's last raster rendering bound another view's set |
| `Stats.shadow_timings` | Delayed GPU time per layer (below) |

Draw and triangle counts include the depth passes. `gui::view_stats_table` shows `shadow_set_shared`, and
`Renderer.draw_shadow_frusta(draw, rgba)` draws the last recorded set's frusta in absolute coordinates.

`shadow_timings` needs GPU timestamps (`C3D_PROFILE_GPU`, see [profiling](profiling.md)). Each entry holds the layer's
original view id, the light entity, its `kind`, a zero-based local `layer_index` and milliseconds. Directional indices
are cascades, a spot's index zero is its sole projection, and point indices follow the six-face order above. A shared
atlas is timed once, under the recording view's id. Results arrive when the owning frame slot completes and retain all
measured layers across views for `Stats.gpu_frame_index`; a later view without shadows does not erase an earlier
view's layers. The renderer owns the slice, replaces it when a newer completed summary publishes and invalidates it on
destruction. Without timestamp support the slice is empty, and a truncated summary is partial. The aggregate shadow
pass stays in `gpu_pass_ms`.

## Limits

- Atlas shadows are hard-edged; soft penumbrae need [ray-traced shadows](ray_traced_shadows.md).
- Capacity is fixed at creation: a light that does not fit gets no shadow while others do.
- The normal offset hides self-shadowing at the cost of thin casters and contact detail.
- Colored shadows hold one translucent depth per texel and 8 bits of transmittance.
- A view-fitted cascade set borrowed by another view ends at the shadow camera's coverage.

## See also

- [Lights](lights.md) for the light budget, receiver masks and light selection.
- [Ray-traced shadows](ray_traced_shadows.md) for per-pixel rays and soft shadows.
- [Views](views.md#planar-reflections) for mirror views that share shadow sets.
- [Scene tracing](scene_trace.md), [sky](sky.md) and [materials](materials.md).
