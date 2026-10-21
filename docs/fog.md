# Fog and medium volumes

A `HeightFog` adds exponential height fog to a view, `ViewDesc.volumetric_fog` adds sun shafts and lit haze through a
froxel volume, and a `MediumVolume` adds a box of water, murk or smoke that the view ray crosses. A fog pass applies them
together with the [atmosphere's](sky.md) aerial perspective. The components live in `c3d::light`; there is no feature
flag. Field tables, validity rules and counters are in the [reference](sky_reference.md).

## Quick start

```c3
Node* haze = scene.add_node(name: "haze")!;
scene.add(haze, light::HEIGHT_FOG_DEFAULT);
scene.update_world();
```

`create_scene` registers the components. The renderer resolves them every frame and fogs every raster view that sees
them. Set `ViewDesc.volumetric_fog` on a view for [shafts](#volumetric-fog), and add a `MediumVolume` for
[water or smoke](#medium-volumes).

## Concepts

### Which components a view takes

- **One fog per view.** The first valid `HeightFog` whose node is visible and shares a layer with the view's camera
  wins. Later and invalid ones the view sees count in `Stats.fogs_ignored`. A fog outside the camera's layers is skipped
  without counting, so a minimap camera can leave the fog out or see its own.
- **Up to `shader::MAX_VIEW_MEDIA` (4) media per view.** Every valid `MediumVolume` whose node is visible, shares a layer
  with the view's camera and has an invertible world matrix is a candidate. The four nearest to the camera by distance
  to the box are kept, and the rest count in `Stats.media_dropped`. Invalid ones are skipped without counting.
- Invalid components are data, not programming errors: they are ignored and never fault.
- Reflection captures take no fog and no media. Probe updates and the path tracer take no media.

The fog's density is referenced to its node's world y, so moving the fog node moves the fog. A [frame origin](large_world.md)
change moves the fog's base and the view's camera together.

### Where fog applies

A view is fogged when its scene has an atmosphere, it sees a valid `HeightFog` or it keeps a medium volume. A fogged view
runs one compute pass, `Pass.FOG`, after the scene readers and before the blended draws. It fogs every pixel from the
camera to the depth it holds. Opaque, masked and custom opaque surfaces, the sky, terrain, foliage and depth-writing
readers such as water need no fog code. A view with neither fog nor atmosphere records no fog pass.

- **Blended draws** write no depth, so they fog themselves per fragment with `apply_fog`. The built-in Standard,
  Physical, Toon and Basic materials do.
- **Composition.** The atmosphere's aerial perspective composes behind the height fog. Where a medium covers the ray, the
  medium replaces both ([medium volumes](#medium-volumes)).
- **Background pixels** take height fog to infinity and no aerial perspective, because the sky already holds the
  atmosphere. Looking up through the fog the background keeps a share of its colour; at and below the horizon it takes
  the fog's colour, and uniform fog (falloff 0) covers it.
- **In-scatter colour.** The fog's in-scatter is its albedo times the atmosphere's sky at the view direction, clamped to
  the horizon so valley fog seen from a ridge takes the horizon's colour, times the sun. Without an atmosphere it is the
  environment's SH at the view direction, and without either the scene's ambient.
- **Scene readers** sample snapshots taken before the fog. On a fogged view a colour read also takes a depth snapshot, so
  refracted samples can be fogged to their own depth.
- **Screen-space GI** copies its bounce source at the fog split, unfogged. On fogged views blended draws are not in it.
- **TAA history** holds the fogged image.
- **Clip planes.** A view with a clip plane (a planar mirror) fogs only the part of each ray inside the kept half-space,
  the path from the plane to the surface. The main view fogs the path to the reflecting surface, so the reflection
  counts the reflected path's fog once. The medium follows the same cut, so a mirror camera inside the box of its own
  body is not darkened by it.

#### Traced hits

A [traced](scene_trace.md) reflection takes the view's height fog and the scene's atmosphere from the reflecting surface
to the hit, and a probe ray takes the scene's from the probe to the hit. A ray that leaves the scene takes the height
fog to infinity and no atmosphere, because the sky it reads already holds it. The fog pass fogs the camera to the
reflecting surface, so no part of a path is fogged twice.

- The atmosphere over a segment is marched in 8 steps (`ATMOSPHERE_SEGMENT_STEPS` in `atmosphere.glsl`), each reading two
  tables: the step count is the cost lever of hit atmosphere. A segment through a medium takes the medium's coefficients
  in place of the air.
- The froxel volume is indexed by the camera's screen and is not applied at hits. A view with `volumetric_fog` fogs its
  hits with the analytic fog, so a reflection's haze can differ in colour from the haze around it.
- A probe update has no camera, so it takes the first valid `HeightFog` on a visible node of any layer and the scene's
  atmosphere. Probes have no sky-view table, so under an atmosphere a fog's in-scatter is the environment's SH, else the
  ambient. A fog or atmosphere change reaches the atlases at the blend rate of the updates.
- The path tracer stays unfogged.

## Volumetric fog

`ViewDesc.volumetric_fog` gives a raster view a froxel volume of its `HeightFog`: the fog's optical depth and the light
it scatters, computed per view every frame. The fog pass reads the volume where the analytic fog would integrate a closed
form, so the sun's light in the haze is shadowed and shows shafts. A view without the switch or without a valid
`HeightFog` records nothing extra. `create_view` and `configure_view` fault `INVALID_ARGUMENT` for the switch on a
`PATH_TRACED` view.

```c3
ViewDesc desc = render::default_view_desc();
desc.volumetric_fog = true;
desc.fog_quality = FogQuality.MEDIUM;
render::configure_view(&renderer, renderer.default_view, desc)!;
```

- **The fog's sun** is the atmosphere's sun. Without an atmosphere it is the first directional light in component
  order. With an atmosphere whose sun is below the horizon the fog has no sun, even when another directional light
  exists, and the volume scatters the ambient only.
- **Sun shadows.** The sun's light is shadowed by the shadow atlas, or by rays under `RayTracingDesc.shadows`. A froxel
  has no surface, so its shadow lookup passes a zero normal and `ShadowGpu.normal_bias` does not move it. Fog past the
  atlas's cascades is unshadowed.
- **Other lights.** Every other light with `Light.volumetric` scatters too, directional lights included. A froxel takes
  the light list of its cluster cell at its midpoint and adds each light's radiance, phase and, for a shadowed light, one
  shadow sample. `light::directional`, `light::point` and `light::spot` set `volumetric`, so a fogged scene with lights
  scatters them by default. Set it to false to opt a light out. A zero-initialized `Light` has it false and does not
  scatter.
- **Volume, then analytic.** Inside `max_distance` a pixel takes the volume's in-scatter and transmittance. Past it the
  analytic fog continues from the volume's end, so the fog is continuous there. The in-scatter's slope changes at
  `max_distance`, where the sun's shadowing stops.
- **Haze colour.** The volume lights the haze with the sun and the ambient, while the analytic fog takes the sky's
  colour, so the same fog looks brighter and warmer inside `max_distance`. Views of one scene with and without the
  switch show two haze colours.
- **Clip planes.** A view with a clip plane (a planar mirror) needs the switch of its own, and its volume starts at the
  plane.
- **Custom stages** need no change: `fog_terms`, `fog_background_terms`, `apply_fog`, `fog_behind` and
  `apply_fog_refracted` include the volume when the view has one.

### Quality

`ViewDesc.fog_quality` chooses one froxel per `px` × `px` pixels of the view's working image by `slices` slices, squared
toward the camera and ending at `max_distance`:

| `FogQuality` | `px` | `slices` |
| --- | --- | --- |
| `LOW` | 16 | 32 |
| `MEDIUM` | 16 | 64 |
| `HIGH` | 8 | 128 |

`MEDIUM` is the zero value, so an unset desc has it. `HIGH` has eight times the froxels of `MEDIUM`, so it is opt-in. A
view, including a mirror view with a clip plane, takes its own `fog_quality`. `configure_view` with another
`fog_quality` reallocates the volume as a resize does. The volume is `RGBA16F`, one heap slot, allocated with the view
and freed with it; [memory](sky_reference.md#memory) gives its size.

### Cost

Two compute passes record after the sky tables and before the fog pass: `Pass.FOG_SCATTERING` (one thread per froxel) and
`Pass.FOG_INTEGRATION` (one thread per column). The cost is the froxels times the lights in their cluster cell: the
lookup, then for each light its radiance and, for a shadowed one, a 3 × 3 shadow filter.

- A view with `LightSelection.FLAT`, a froxel outside the cluster grid and a cell with more than
  `ClusterDesc.lights_per_cluster` lights take every light of the view instead.
- The cluster grid spans view depths from the camera's near plane to `ClusterDesc.far_distance` (100 by default) while
  the volume reaches `max_distance`. A froxel whose midpoint lies deeper than `far_distance` falls outside the grid.
  Raise `far_distance` with `max_distance`, and keep few lights in a cell. See [lights](many_lights.md).
- A light with `volumetric` false still sits in its cell's list. It saves the radiance and the shadow sample, not the read
  of the list.

### Temporal accumulation

Without `ViewDesc.fog_temporal` the volume is recomputed every frame from one shadow sample per froxel and light, taken
at the slice midpoint, with no reprojection or jitter. `fog_temporal` accumulates the in-scatter over frames, so the
shadow sample of one frame is spread over the slice's depth and over time. Optical depth is analytic and carries no
history. The switch is off by default and does nothing without `volumetric_fog`.

- **Jitter and reprojection.** Each froxel takes its light and shadow samples at a jittered depth within its slice. The
  froxel's centre is projected through the view's previous view-projection and read from the previous frame's
  volume. A froxel whose previous position lies outside the previous frustum or beyond `max_distance` takes no history.
  Camera motion reprojects and does not reject. An orthographic view takes neither jitter nor history.
- **Blend.** A froxel's in-scatter is mixed with `shader::FOG_HISTORY_WEIGHT` (0.9) of its history, so the history
  remembers about ten frames. An exposure change rescales the history instead of rejecting it.
- **Clamp.** Before the blend, the history is clamped to the range of this frame's in-scatter at the froxel and its
  neighbours along the column. History that the current neighbours no longer support, such as the shadow a moving
  caster left in a shaft, goes to their range at once, and a moving shadow edge lags by about the depth of a slice.
- **Rejection.** The history of a view is dropped, and the next frame injects without it, when:
  - `render::reset_view_history` ran, the view was created or configured (a resize and a `fog_quality` change reallocate
    the volumes), the switch was turned on, or the scene changed;
  - any `HeightFog` field, the fog node's height or the frame origin changed;
  - the sun's direction moved more than 0.1° since the previous frame;
  - a light with `Light.volumetric` changed in position, direction, range, cone, layers, colour, intensity or shadow
    state, or the sun changed in anything but its direction and, under an atmosphere, its colour.

  A light that moves every frame gets no temporal convergence, and neither does a sun turning faster than the
  threshold. A change of ambient light or of the lighting environment is not a trigger; it converges through the blend.
  An aborted frame neither swaps nor commits the history.
- **Cost.** The volume's memory doubles, `FOG_SCATTERING` adds a reprojection and one trilinear read of the history per
  froxel, and lights other than the sun are sampled at two depths. A view with the switch runs a separate shader
  variant.

## Medium volumes

A `MediumVolume` is a box of participating medium that the view ray crosses: water, murk, smoke. It hangs below its node.
In the node's local frame it covers `[center.x ± half_extent.x] × [−depth, 0] × [center.y ± half_extent.y]`, so the
local XZ plane at y = 0 is its top face. The node's world matrix moves, turns and scales the box, and a matrix that is
not invertible makes the medium invalid. A [water body](water.md#underwater) writes one from its desc.

```c3
MediumVolume murk = {
    .absorption = { 0.4f, 0.08f, 0.04f },
    .scattering = { 0.02f, 0.03f, 0.04f },
    .anisotropy = 0.6f,
    .half_extent = { 50, 50 },
    .depth = 20,
};
Node* pond = scene.add_node(name: "pond")!;
scene.add(pond, murk);
```

Main, split and mirror views take the media they keep. Probe updates, reflection captures and the path tracer take none.
`MAX_VIEW_MEDIA` is the cost lever.

- **Integration.** The view ray of every fogged pixel is split at each box's entry and exit, at most eight boundaries
  sorted along the ray. On each sub-interval the coefficients of the boxes covering it add, so overlapping media sum. The
  air (height fog and aerial perspective) applies only on the sub-intervals outside every box, so each point of the ray is
  integrated once. The froxel volume keeps its air; the box ranges are never read from it.
- **Inside a box** the ray's transmittance is `exp(−(σa + σs) · d)` per channel. The ambient scatters in every direction:
  `σs` times the environment's mean radiance, or the scene's ambient without an environment. The sun scatters through
  the box's phase, attenuated by the optical depth from the point to the box's top face along the sun direction. The sun
  term is zero when the sun is at or below the plane of the top face. Both terms integrate in closed form along a
  straight ray.
- **Clip planes.** In a view with a clip plane the box spans start at the plane's crossing, so the medium applies only on
  the kept side.

### Sun on surfaces

A surface inside a box takes the sun through the medium. When the view keeps a medium, the fog sun's packed light carries
`LIGHT_MEDIUM_SHADOW`, and the light counts as shadow-casting even without shadow layers. `shadow_visibility` and
`shadow_transmittance` multiply that light's visibility by the medium's transmittance along the sun's column to the
box's top face, per channel, summed over the kept boxes that hold the point. A point outside every box gets 1. A sun at
or below a box's top face lets nothing through in a channel that absorbs. The water surface sits above its box and
gets 1.

- **Receivers.** Callers of `shadow_transmittance` get the column per channel, so a surface darkens with the medium's
  tint: forward Standard, Physical and Toon, the deferred lighting resolve, terrain, water, impostors and custom stages
  built on `shade_standard_surface` or `evaluate_standard_lights`.
- **Channel mean.** Callers of the float `shadow_visibility` get the mean of the three channels, so they darken without
  the tint. The built-in one is the `DIRECT_SHADOWED` particle stage, and custom stages that call it are the others.
- **Conditions.** Only a surface that receives shadows gets the term: a draw without `DRAW_RECEIVE_SHADOW` is lit as in
  air, and `DIRECT_SHADOWED` particles ignore the flag. Only a view that takes height fog gets it, which is every view
  but a reflection capture, and no `HeightFog` component is needed. Only the media the view keeps count.
- **No term.** The froxel volume clears the flag from its copy of the sun, because media replace the air in their boxes.
  Traced reflection and probe hits and the path tracer call neither shadow function. `DIRECT` particles call neither, so
  they are lit as in air.

### Cost

Each fogged pixel does one box test per kept volume and up to nine sub-intervals, five of them air. A traced hit marches
the atmosphere on each air sub-interval. In a view that keeps a medium, each shaded fragment that receives the fog sun's
shadow also runs up to four box tests, one column per box holding it and one `exp`, whether or not the sun has a shadow
map. A view without media pays one flag test per light that casts shadows.

## Custom stages

`fog.glsl` is a public include:

| Function | Use |
| --- | --- |
| `FogTerms { transmittance; inscatter; }` | Radiance `x` seen through fog is `x · transmittance + inscatter` |
| `fog_terms(frame, uv, position)` | The fog from the camera (or a clipped view's plane) to a surface |
| `fog_background_terms(frame, uv)` | The fog in front of a background pixel |
| `apply_fog(frame, world_position, color)` | A blended fragment's fog; returns `color` when `frame.sky_fog` is zero |
| `fog_behind(frame, surface_position, behind, behind_depth)` | The fog between a surface and a depth sample behind it; depth 0 is the background |
| `apply_fog_refracted(frame, surface_position, transmittance, refracted, refracted_depth, surface_radiance)` | A depth-writing refracting surface's output |
| `apply_fog_segment(frame, origin, hit_position, radiance)` | The height fog and, behind it, the marched atmosphere over the segment from a ray's origin to its hit, for a ray cast from elsewhere than the camera; returns `radiance` when `frame.sky_fog` is zero |
| `apply_fog_to_infinity(frame, origin, direction, radiance)` | The height fog from a point to infinity, for a ray that leaves the scene; no atmosphere, except the marched atmosphere in front of a [medium volume](#medium-volumes) |
| `fog_phase(cos_angle, anisotropy)` | The Henyey-Greenstein phase, per steradian |
| `atmosphere_segment(sky, altitude, direction, distance)` | The `FogTerms` of the marched atmosphere over `distance` of a unit ray from a world altitude; none without an atmosphere |

- Every helper above that fogs a ray includes the view's medium volumes, with the same signature: a segment through a box
  takes the medium's absorption and in-scatter in place of the air.
- An opaque custom stage needs nothing: the pass fogs it at its depth. It cannot opt out.
- A blended custom stage calls `apply_fog` on its output, unconditionally.
- A depth-writing reader that refracts returns
  `apply_fog_refracted(frame, position, t, scene_color_at(frame, uv), scene_depth_at(frame, uv), own)`. The pass then
  fogs the pixel from the camera to the surface. Its `scene_reads` needs `depth` on a view without fog; a fogged view
  adds it.
- A blended reader draws after the pass and composes `apply_fog(frame, position, apply_fog_refracted(...))`.
- A reader that writes no depth takes the fog of what lies behind it. Built-in Physical transmission drawn with
  `AlphaMode.BLEND` is such a reader and does not fog behind its surface.
- A custom twin of Standard keeps matching it: opaque twins are fogged by the pass, a blended twin calls `apply_fog` as
  Standard does.
- The lookups `fog.glsl` brings in, `sky_view_radiance`, `sky_aerial_perspective` and `sky_multi_scattering`, return
  luminance for unit sun illuminance. The tables' storage scale is divided out inside them, so a stage that multiplies
  their result by `sun_illuminance` needs no change.

## Limits

- One fog medium and at most four medium volumes per view; probe updates, reflection captures and the path tracer take no
  media, and path-traced views are unfogged.
- No underwater light shafts: media are analytic with no froxel scattering, and the air composed behind a dense medium is
  approximate.
- The medium's sun term has no occluder shadowing, and the column ignores rays that leave through a side face near the
  box edges, so it over-attenuates there. Each box's column counts that box's extinction only, so an overlap does not
  attenuate the other box's sun.
- Volumetric fog is unshadowed past the shadow atlas, changes its in-scatter slope at `max_distance`, and without
  `fog_temporal` has no reprojection or jitter.
- The analytic fog has no direct-sun phase term, so a view with volumetric fog and a view without it show different haze
  colours.
- Opaque stages cannot opt out of the fog pass, and readers that write no depth take the fog of what is behind them.
- Screen-space GI gathers unfogged radiance, without blended draws on fogged views.

## See also

- [Sky and atmosphere](sky.md) and [clouds](clouds.md)
- [Sky, fog and cloud reference](sky_reference.md) for fields, constants and counters
- [Water](water.md#underwater) for the medium a water body writes
- [Custom shaders](custom_shaders.md) for stage authoring
- [Views](views.md) for `ViewDesc`
