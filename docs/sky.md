# Sky, atmosphere, height fog and clouds

Three components in `c3d::light` describe the outdoors. An `Atmosphere` on the node of a directional
`Light` turns that light into a sun seen through air: the renderer draws a physically based sky with
the sun's disc, attenuates the sun's light by the air it crosses, lights the scene from the sky and
adds aerial perspective to distant surfaces. A `HeightFog` on any node adds exponential height fog. A `CloudLayer` on any node adds a raymarched
layer of [clouds](#clouds). Each works without the others. A `MediumVolume` on any node adds a box of
[participating medium](#medium-volumes), such as water, that the view ray crosses.

[Frame origins](large_world.md) change packed coordinates, not physical altitude.
Height fog's base and view camera move together. Atmosphere lighting cache keys
retain absolute physical inputs, and an origin change alone does not regenerate
the sky or restart a probe sweep.

```c3
Light sunlight = light::directional({ 1, 1, 1 }, 3);
Node* sun = scene.add_light(sunlight, name: "sun")!;
sun.local.rotation = maths::look_rotation({ -0.3f, -0.8f, -0.5f }, { 0, 1, 0 });
scene.add(sun, light::ATMOSPHERE_EARTH);

Node* haze = scene.add_node(name: "haze")!;
scene.add(haze, light::HEIGHT_FOG_DEFAULT);
scene.update_world();
```

`create_scene` registers every component of the page. Nothing else is needed: the renderer resolves them every
frame, allocates what they need once and draws them in every raster view.

## Components

`Atmosphere` holds the planet, the air and the sun's disc, in metres:

| Field | `ATMOSPHERE_EARTH` | Meaning |
| --- | --- | --- |
| `planet_radius` | 6,360,000 | world y = 0 lies on the surface |
| `atmosphere_height` | 100,000 | metres above the surface |
| `rayleigh_scattering`, `rayleigh_scale_height` | (5.802, 13.558, 33.1) × 10⁻⁶, 8,000 | per metre at the surface; metres |
| `mie_scattering`, `mie_absorption`, `mie_scale_height`, `mie_anisotropy` | 3.996 × 10⁻⁶, 0.444 × 10⁻⁶, 1,200, 0.8 | per metre; metres; phase asymmetry |
| `ozone_absorption`, `ozone_center_altitude`, `ozone_half_width` | (0.650, 1.881, 0.085) × 10⁻⁶, 25,000, 15,000 | per metre at the layer centre; a tent profile |
| `ground_albedo` | 0.3 | the lit ground seen below the horizon and bounced into the lighting |
| `sun_angular_radius` | 0.004675 | radians |
| `observer_altitude` | 0 | metres; the scene's lighting is the sky seen from here |

`HeightFog` holds one fog medium; its density is referenced to its node's world y, and the node's
rotation and scale are ignored:

| Field | `HEIGHT_FOG_DEFAULT` | Meaning |
| --- | --- | --- |
| `density` | 0.002 | extinction per metre at the node's world y |
| `falloff` | 0.02 | per metre of height; the density halves every 35 m above the node; 0 is uniform fog |
| `albedo` | 1 | scattered share of the extinction, per channel |
| `max_distance` | 200 | metres of view the [volumetric fog](#volumetric-fog) covers; the analytic fog continues past it |
| `anisotropy` | 0.3 | Henyey-Greenstein `g` of the volumetric fog's sun light, in (-1, 1) |

`MediumVolume` holds one box of medium; see [medium volumes](#medium-volumes) for its fields.

`light::atmosphere_valid` and `light::height_fog_valid` state what the renderer accepts. An
atmosphere needs finite positive radii, heights, scale heights, ozone width and sun radius (below
π/2), finite nonnegative coefficients, an albedo in [0, 1], `|mie_anisotropy| < 1` and an observer in
[0, atmosphere height). A fog needs finite nonnegative density, falloff and albedo and a finite
positive `max_distance` and an `anisotropy` with `|anisotropy| < 1`.

`light::sun_radiance(atmosphere, sun, to_sun, altitude)` and `light::atmosphere_transmittance` are the
CPU twins of the sun's attenuation (a 64-step march, within 0.35 % of a 100,000-step double
reference); `light::height_fog_transmittance`, `height_fog_optical_depth`,
`height_fog_limit_transmittance` and `fog_rise_factor` are the twins of the fog integral. All are pure
and callable from any thread.

## Resolution

- **One atmosphere per scene.** The first `Atmosphere` in component order that is valid and whose
  node carries a directional `Light` wins. Every other one, an invalid one and one without a
  directional light are ignored and counted in `Stats.atmospheres_ignored`. Every view of the scene,
  its probe volumes and the path tracer share it.
- **One fog per view.** The first valid `HeightFog` whose node is visible and shares a layer with the
  view's camera wins; later and invalid ones the view sees count in `Stats.fogs_ignored`. A fog
  outside the camera's layers is skipped without counting, so a minimap camera can leave the fog out
  or see its own.
- **Up to `shader::MAX_VIEW_MEDIA` (4) media per view.** Every valid `MediumVolume` whose node is visible,
  shares a layer with the view's camera and has an invertible world matrix is a candidate. The four nearest to the
  camera by distance to the box are kept; the rest count in `Stats.media_dropped`. Invalid ones are skipped without
  counting. A camera with `height_fog` off (a reflection capture) takes none.
- **One cloud layer per view.** The first valid `CloudLayer` whose node is visible and shares a layer with
  the view's camera wins; later and invalid ones the view sees count in `Stats.clouds_ignored`.
- Invalid components are data, not programming errors: they are ignored, never faulted.
- While an atmosphere resolves it replaces the scene's lighting and background:
  `scene.environment`, `scene.background` (its kind, intensity and rotation) and
  `scene.environment_rotation` do not apply, and `scene.environment_intensity` scales the sky's
  lighting as it scales any environment. The ambient term follows the environment rule: zero unless
  `scene.ambient_add`.
- The renderer keeps `render::ATMOSPHERE_CAPACITY` (4) atmospheres of different scenes at once. A
  fifth scene's atmosphere renders as absent (no sky, no attenuation, the scene's own environment and
  background) and counts in `Stats.atmospheres_dropped`; a slot unused for more than
  `FRAMES_IN_FLIGHT + 1` frames is reused.

## Units and the altitude datum

Everything is in metres, and world y = 0 is the planet's surface. A camera's altitude is its y plus the
frame origin's y: unbounded above, and zero below zero. `observer_altitude` stays in [0, atmosphere height).
There is no datum field: a world whose ground sits elsewhere moves its content, not the atmosphere. The
fog's density follows its own node instead, so moving the fog node moves the fog.

The sky's tables are computed for a sun of unit illuminance and stored times a power-of-two scale that the lookups
divide out ([Sky table scale](#sky-table-scale)). The drawn sky, the lighting, the fog's
in-scatter and aerial perspective all scale with the sun's `color × intensity`, so doubling the
intensity doubles every sky pixel. Exposure is the application's `Camera.exposure`; see
[Exposure](#exposure).

## The sun

Every light extraction (views, probe updates and the path tracer) attenuates the atmosphere's sun,
and only it: `sun_radiance` at the extracting camera's altitude (probe updates use `observer_altitude`)
becomes the packed light colour. Other directional lights pass unchanged. A sun whose radiance is
exactly zero, below the horizon, packs no light, requests no shadow layer and counts in the view's
`LightCounts.culled`; the shadow atlas stays allocated for its return. The sun's disc is drawn in the
background only, never in the lighting, and saturates at 60,000 (an intensity above about 4.1) to
stay inside `RGBA16F`.

## Above the atmosphere

A camera's altitude is not clamped. A ray from above the atmosphere's top starts where it enters the shell,
the near root against the sphere of radius `planet_radius + atmosphere_height`; a ray that misses the shell
sees space, with transmittance 1 and no in-scatter. At or below the top the entry is the ray's origin, so a
camera inside the atmosphere renders as it did before. `light::atmosphere_transmittance` and the shaders'
`atmosphere_entry` use the same formula.

- **Sky.** The per-view sky-view table keeps its mapping about the planet's horizon at the camera's altitude and
  integrates from the entry. Below the horizon it shows the planet's ground, lit and shaded with `ground_albedo`;
  rays that miss the shell hold zero. The scene's geometry is the application's and does not curve.
- **Sun.** `sun_radiance` follows each view's camera altitude, so a sun ray that misses the shell is
  unattenuated and one that meets the planet is zero. The sun's disc is attenuated from the entry, whole where
  its ray misses the shell, and absent behind the planet.
- **Aerial perspective.** Each pixel's slices count from the distance at which its ray enters the shell, so the
  volume covers `[entry, entry + 128 km]` along the ray, as it covers `[0, 128 km]` from the surface. Geometry
  beyond that range reads the far slice, as geometry beyond 128 km does from the surface; the analytic
  segment is not used for it. A ray that misses the shell reads no aerial perspective.
- **Traced hits.** A segment's air starts at its ray's entry; a hit that lies before the entry takes none.
- **Regeneration.** The camera's altitude keys no table and no cube, so rising through the top regenerates
  nothing.
- **Lighting.** The cubes and SH, the path tracer's background and the probe update's sun stay at
  `observer_altitude`. A camera above the atmosphere, or far from the observer, sees a sky they do not match.

## Lighting and regeneration

Each atmosphere owns its transmittance (256 × 64) and multiple-scattering (32 × 32) tables and a
64-texel source cube with its GGX cube, SH and, on first sheen use, a Charlie cube. The cubes are the
sky seen from `observer_altitude` with the sun's colour at unit intensity and no disc; the sun's
intensity scales them as the environment intensity. They light the scene through the ordinary
environment path: image-based lighting, reflections that miss, probe volumes filled from the
environment and the path tracer.

The multiple-scattering table sums the orders after the second as a geometric series truncated at 32 terms.
However thick and scattering the air, a texel is finite, non-negative and at most 33 times its second-order
light; where the series ratio is within 1e-4 of 1 the sum takes its limit of 33 terms.

The lighting regenerates, in place, when compared with the last generation the sun has turned by
more than `render::SKY_REGENERATION_SUN_ANGLE` (0.5°), `observer_altitude` has moved by more than
`render::SKY_REGENERATION_ALTITUDE` (500 m), the sun's colour changed or any air field changed (the
tables regenerate too). Slow drift accumulates against the last generation: a slowly moving sun
regenerates on the first frame past 0.5°. An intensity change regenerates nothing. A regeneration writes
the cubes, the SH and their views in place, advances the lighting revision, so probe volumes filled
from the environment refill, and counts `Stats.sky_regenerations`. The first generation happens in
`prepare_scene` or the first view that sees the atmosphere; a second view of the same frame finds it
pending. At the sky example's time-lapse speed of 0.27° a second the sky regenerates 32 times a
minute.

Each raster view owns a 192 × 108 sky-view table (the sky around the camera) and a 32³ aerial
perspective volume (in-scatter and transmittance over 128 km), recomputed every frame the view
renders an atmosphere; mirror and capture views have their own. A view allocates them with its other
working images whether or not its scene has an atmosphere.

Timing: `Pass.SKY_VIEW` and `Pass.AERIAL_PERSPECTIVE` per view; the atmosphere's tables and cube in
`Pass.ENVIRONMENT` as the stages `environment.sky_transmittance`, `environment.sky_multi_scattering`
and `environment.sky`, followed by `environment.prefilter`, `environment.irradiance` and
`environment.sheen` as for any environment.

## Where fog applies

A view is fogged when its scene has an atmosphere, it sees a valid `HeightFog` or it keeps a
[medium volume](#medium-volumes). A fogged view runs
one compute pass, `Pass.FOG`, after the scene readers and before the blended draws: it fogs every
pixel from the camera to the depth it holds, so opaque, masked and custom opaque surfaces, the sky,
terrain, foliage and depth-writing readers such as water need no fog code. Blended draws, which write
no depth, fog themselves per fragment with `apply_fog`; the built-in Standard, Physical, Toon and
Basic materials do. A view with neither fog nor atmosphere records no fog pass and no split, and
costs what it did before.

- The fog is composed as aerial perspective behind the height fog:
  `(x·T_ap + S_ap)·T_h + S_h`. Where a medium covers the ray, the medium replaces both: see [medium
  volumes](#medium-volumes).
- Background pixels take height fog to infinity and no aerial perspective: the sky already holds the
  atmosphere. Looking up through the fog the background keeps a share `T∞ = e^(−ρ / (falloff · v.y))`;
  at and below the horizon it takes the fog's colour, and uniform fog (falloff 0) covers it.
- The fog's in-scatter is its albedo times the sky-view table at the view direction, clamped to the
  horizon so valley fog seen from a ridge takes the horizon's colour, times the sun; without an
  atmosphere, the environment's SH at the view direction; without either, the scene's ambient.
- Scene readers sample snapshots taken before the fog; on a fogged view a colour read also takes a
  depth snapshot, so refracted samples can be fogged to their own depth.
- Screen-space GI copies its bounce source at the fog split, unfogged; on fogged views blended draws
  are not in it.
- A view with a clip plane (a planar mirror) fogs only the part of each ray inside the kept
  half-space: the path from the plane to the surface. The main view fogs the path to the reflecting
  surface, so the reflection counts the reflected path's fog once. The medium follows the same cut: it applies only
  to the part of the ray on the kept side, so a mirror camera inside the box of its own body is not darkened by it.
- TAA history holds the fogged image.
- Traced hits take the air and the media of their own segment. A traced reflection takes the view's height fog and the scene's
  atmosphere from the reflecting surface to the hit, and a probe ray takes the scene's from the probe to the hit. The
  two compose as the fog pass composes a camera ray, the atmosphere behind the height fog:
  `(x·T_air + S_air)·T_h + S_h`, which `apply_fog_segment` applies. The atmosphere is marched in
  `ATMOSPHERE_SEGMENT_STEPS` (8, in `atmosphere.glsl`) steps of single scattering over the transmittance and
  multiple-scattering tables, with the sun's `color × intensity` and one mean transmittance, the units of the aerial
  perspective table. That table is indexed by the camera's screen and is never read at hits. A step reads both tables,
  so the step count is the cost lever of hit atmosphere, and a probe update marches one segment per ray. A ray that
  leaves the scene takes the height fog to infinity, as a background pixel does, and no atmosphere: the sky it reads
  already holds it. The result is `x·T + S` before exposure, like everything the fog pass fogs. The pass still fogs
  the camera to the reflecting surface, so no part of a path is fogged twice. The froxel volume is not applied at
  hits: it is indexed by the camera's screen, so a view with `volumetric_fog` fogs its hits with the analytic fog and
  a reflection's haze can differ in colour from the haze around it (see [Volumetric fog](#volumetric-fog)). The path
  tracer stays unfogged.
- A reflection hit uses the view's own fog selection, in-scatter colour and atmosphere. A probe update has no camera,
  so its frame carries the first valid `HeightFog` on a visible node of any layer, the way its light list takes every
  layer, whatever a camera's `height_fog` switch says, and the scene's atmosphere: the one every view of the scene
  resolves, with the sun's `color × intensity` and the tables of its mirror. A segment's air is sampled at the
  segment's world altitude, the packed y plus `FrameRoot.origin.y` and zero below zero, the datum the camera
  uses; `observer_altitude` still sets the altitude at which the probe update's sun is attenuated
  ([The sun](#the-sun)), and the march does not read it. Probes have no sky-view table, so under an atmosphere a
  fog's in-scatter is the environment's SH, else the ambient. A fog or atmosphere change reaches the atlases at the
  blend rate of the updates.

Pass order of a fogged raster view:

```
forward:   uploads, shadows, sky view, aerial perspective, [depth prepass], [ambient occlusion],
           [screen-space GI], forward opaque and sky, [clouds], [scene snapshot, scene reads],
           [snapshot for blended readers], [SSGI colour copy], fog, [transparent], debug lines, post
deferred:  uploads, shadows, sky view, aerial perspective, depth prepass, G-buffer, [ambient occlusion],
           [screen-space GI], [reflections], lighting, forward opaque and sky, then as forward
```

The sky-view and aerial perspective tables record only when the scene has an atmosphere. The fog
pass samples depth at compute and rewrites `hdr_color` in place; the transparent pass reopens with
depth attached for testing.

## Volumetric fog

`ViewDesc.volumetric_fog` gives a raster view a froxel volume of its `HeightFog`: the fog's optical depth and the
light it scatters, computed per view every frame. The view keeps the fog pass of [Where fog
applies](#where-fog-applies); the pass reads the volume where the analytic fog would integrate a closed form, so
the sun's light in the haze is shadowed and shows shafts. A view without the switch, without a valid `HeightFog`
or with a `PATH_TRACED` shading path (`create_view` and `configure_view` fault `INVALID_ARGUMENT` for that
combination) records nothing extra.

- The medium is the `HeightFog`: `density`, `falloff`, `albedo`, `max_distance` (metres the volume covers) and
  `anisotropy`, the Henyey-Greenstein `g` of the sun's scattering in (-1, 1); 0 is isotropic, positive favours
  looking toward the sun.
- The fog's sun is the atmosphere's sun. Without an atmosphere it is the first directional light in component
  order. With an atmosphere whose sun is below the horizon the fog has no sun, even when another directional
  light exists; the volume then scatters the ambient only.
- The sun's light is shadowed by the shadow atlas, or by rays under `RayTracingDesc.shadows`. A froxel has no
  surface, so its shadow lookup passes a zero normal and `ShadowGpu.normal_bias` does not move it. Fog past the
  atlas's cascades is unshadowed.
- Every other light with `Light.volumetric` scatters too, directional lights included. A froxel takes the light list of
  its cluster cell at its midpoint, the lookup a surface uses, and for each light but the sun adds
  `albedo × phase × radiance × visibility`: the Henyey-Greenstein phase at `anisotropy` between the ray and the
  direction to the light, the light's radiance at the midpoint (`range` and the spot cone apply) and one shadow sample
  with a zero normal when the light casts a shadow, else 1. A light with no radiance at the froxel adds nothing and
  takes no shadow sample. `light::directional`, `light::point` and `light::spot` set `volumetric`, so a fogged scene
  with lights scatters them by default; set it to false to opt a light out. A zero-initialized `Light` has it false
  and does not scatter. A scene with no light besides the sun, or none with `volumetric`, renders as it did before.
- The cost is the froxels times the lights in their cluster cell: the lookup, then for each light its radiance and,
  for a shadowed one, a 3 × 3 shadow filter. A view with `LightSelection.FLAT`, a froxel outside the cluster grid
  and a cell with more than `ClusterDesc.lights_per_cluster` lights take every light of the view instead. The grid
  spans view depths from the camera's near plane to `ClusterDesc.far_distance` (100 by default) while the volume
  reaches `max_distance`, so a froxel whose midpoint is that deep falls outside it: at 16:9 with a 60° vertical field
  of view, 22.6% of the froxels at a `max_distance` of 200 and 65.4% at 1000, whatever the quality or view size, and
  none once `far_distance` reaches `max_distance`. Raise `far_distance` with `max_distance` and keep few lights in a
  cell. A light with `volumetric` false still sits in its cell's list: it saves the radiance and the shadow sample,
  not the read of the list.
- The grid is chosen by `ViewDesc.fog_quality`, one froxel per `px` × `px` pixels of the view's working image by
  `slices` slices, squared toward the camera and ending at `max_distance`:

  | `FogQuality` | `px` | `slices` |
  | --- | --- | --- |
  | `LOW` | 16 | 32 |
  | `MEDIUM` | 16 | 64 |
  | `HIGH` | 8 | 128 |

  `MEDIUM` is the zero value, so an unset desc has it. The volume is RGBA16F, one heap slot, allocated with the
  view and freed with it; its size is `ceil(w / px) × ceil(h / px) × slices × 8` bytes per view for a working
  image of `w` × `h` pixels, times 2 when `fog_temporal` is on. `HIGH` has eight times the froxels of `MEDIUM`,
  so it is opt-in. A view, including a mirror view with a clip plane, takes its own `fog_quality`.
  `configure_view` with another `fog_quality` reallocates the volume as a resize does, and `FOG_SCATTERING` and
  `FOG_INTEGRATION` read the view's slice count
  from `SkyFogGpu.fog_slices` and `FogVolumeRoot.slices`; no more than `FOG_VOLUME_MAX_SLICES` (128) fit.
- Two compute passes record after the sky tables and before the fog pass: `FOG_SCATTERING` (one thread per froxel,
  or per chunk of a column's slices with `fog_temporal`) and `FOG_INTEGRATION` (one thread per column, accumulating
  in-scatter and transmittance along the slices).
- Volume then analytic: inside `max_distance` a pixel takes the volume's in-scatter and transmittance; past it the
  analytic fog continues from the volume's end, so the fog is continuous there. The in-scatter's slope changes at
  `max_distance`, where the sun's shadowing stops.
- A view with a clip plane (a planar mirror) needs the switch of its own; its volume starts at the plane.
- Custom stages need no change: `fog_terms`, `fog_background_terms`, `apply_fog`, `fog_behind` and
  `apply_fog_refracted` include the volume when the view has one.
- Without `ViewDesc.fog_temporal` the volume is recomputed every frame from one shadow sample per froxel and light,
  taken at the slice midpoint, and is not reprojected or jittered. The switch is off by default and does nothing
  without `volumetric_fog`.
- The volume changes the haze's colour, not only its shadows. Inside `max_distance` the in-scatter is lit by the
  sun and the ambient, while the analytic fog takes the sky's colour, so the same fog looks brighter and warmer
  with the switch: the upper sky at noon at the default density goes from (31, 60, 100) to (76, 91, 117). Views of
  one scene with and without the switch show two haze colours.

### Temporal accumulation

`ViewDesc.fog_temporal` accumulates the in-scatter over frames, so the shadow sample of one frame is spread over
the slice's depth and over time. Optical depth is analytic and carries no history.

- **Jitter.** `FOG_SCATTERING` takes each froxel's light and shadow samples at a depth within its slice, the
  Halton base-2 point of the view's frame counter over `FOG_TEMPORAL_SAMPLES` (16) positions.
- **Reprojection.** The froxel's centre is projected through the view's previous view-projection and read at its
  previous slice, from the previous frame's scattering volume, with trilinear filtering. A froxel whose previous
  position lies outside the previous frustum or beyond `max_distance` takes no history. Camera motion reprojects
  and does not reject. An orthographic view takes neither jitter nor history.
- **Blend.** A froxel's in-scatter is mixed with `FOG_HISTORY_WEIGHT` (0.9) of its history, so the history
  remembers about ten frames. The history's colour is first multiplied by the ratio of the view's current
  pre-exposure to the one it was injected under, so an exposure change rescales it instead of rejecting it. The
  volume keeps that factor itself, so the ratio holds without TAA, motion blur or screen-space GI on the view.
  Optical depth is not radiance and is not scaled.
- **Clamp.** Before the blend, each channel of the history is clamped to the range of this frame's in-scatter at
  the froxel and at the froxels just in front of and behind it in the same column. History that the current
  depth neighbours no longer support, such as the shadow a moving caster left in a shaft, goes to their range at
  once instead of fading, and a moving shadow edge lags by about the depth of a slice. The jitter spreads the
  samples along depth, so a still shaft keeps its history inside the range and settles. The volumetric lights other
  than the sun are sampled at a second depth, half a slice on and wrapped into the slice, and averaged, because a
  lamp's falloff is narrow along depth and a single sample would leave its glow outside the range. The second
  sample shares the first one's light list and shadow visibility; the sun and the ambient take one sample.
- **Rejection.** The history of a view is dropped, and the next frame injects without it, when:
  - `reset_view_history` ran, the view was created or configured (a resize and a `fog_quality` change reallocate
    the volumes), the switch was turned on, or the scene changed;
  - any `HeightFog` field, the fog node's height or the frame origin changed;
  - the sun's direction moved more than `FOG_HISTORY_SUN_DEGREES` (0.1°) since the previous frame;
  - the hash of the light set changed. It covers every light with `Light.volumetric` and the sun: position,
    direction, range, cone, layers, colour and intensity, and its shadow state, which is whether it has atlas
    layers or traces rays. The sun's direction, and its colour under an atmosphere, are left out of the hash: the
    angle test above covers them. The pre-exposure is divided out of each intensity.
  A light that moves every frame therefore gets no temporal convergence, as does a sun turning faster than the
  threshold: correctness wins over convergence. A change of ambient light or of the lighting environment is not a
  trigger; it converges through the blend.
- **Ownership.** The view keeps two volumes. `FOG_SCATTERING` reads one as history and writes the other, and
  `FOG_INTEGRATION` reads the written one and integrates into the first, which the fog pass samples. They swap
  only when the frame is submitted; an aborted frame neither swaps nor commits, so the next frame continues from
  the last submitted one. The history is valid only if the view's own last submitted frame wrote it: a view that
  was not rendered, or rendered no fog, in a submitted frame starts again without history, and a second recording
  of the volume in one frame takes none. A mirror or clip-plane view keeps its own pair and history.
- **Cost.** The memory is twice the volume's (see the grid above). `FOG_SCATTERING` adds a reprojection and one
  trilinear read of the history volume per froxel. One thread injects a chunk of `FOG_SCATTERING_CHUNK` slices of
  a column, so it also evaluates the slice just outside each end of the chunk for the clamp, and every quality's
  slice count is a multiple of the chunk. The lamps' falloff is evaluated twice per froxel in one loop over the
  lights. The CPU hashes the volumetric lights once per frame. `FOG_INTEGRATION` is unchanged but for writing the
  other volume. A view without the switch runs the plain inject, a separate shader variant with none of this.

## Medium volumes

A `MediumVolume` is a box of participating medium that the view ray crosses: water, murk, smoke. It hangs below its
node. In the node's local frame it covers `[center.x ± half_extent.x] × [−depth, 0] × [center.y ± half_extent.y]`, so
the local XZ plane at y = 0 is its top face. The node's world matrix may be any affine transform without shear; the
box moves, turns and scales with it.

| Field | Meaning |
| --- | --- |
| `absorption`, `scattering` | per metre, per channel |
| `anisotropy` | Henyey-Greenstein `g` of the sun term, in (-1, 1) |
| `center`, `half_extent` | local x and z of the box centre and of its half sizes, metres |
| `depth` | local metres below the top face |

`light::medium_volume_valid` states what the renderer accepts: finite nonnegative coefficients, a finite centre, finite
positive extents and depth, and `|anisotropy| < 1`. A scene registers the component with `create_scene`, and
`describe::register_core_components` and `serial::register_core_codecs` describe and serialize it.

**Which views take media.** Main, split and mirror views take the media they keep ([resolution](#resolution)).
Probe updates, reflection captures and the path tracer take none.

**Integration.** The view ray of every fogged pixel is split at each box's entry and exit, at most eight boundaries
sorted along the ray. On each sub-interval the coefficients of the boxes covering it add, so overlapping media sum.
The air (height fog and aerial perspective) applies only on the sub-intervals outside every box, through the same
sub-range helpers the fog pass uses, so each point of the ray is integrated once. The froxel volume keeps its air; the
box ranges are never read from it. Inside the boxes:

- The transmittance of a sub-interval of length `d` is `exp(−(σa + σs) · d)` per channel.
- The ambient scatters in every direction: `σs` times the environment's mean radiance (the first coefficient of its SH),
  or the scene's ambient without an environment.
- The sun scatters through the box's phase: `σs · HG(g, v · s) · E · exp(−σt · column)`. `s` is the direction to the
  view's fog sun, the atmosphere's sun or else the first directional light, `E` its `color × intensity`, `v` the view
  direction and the column the optical depth from the point to the box's top face along `s`, `h / (n · s)` metres for a
  point `h` metres below the face with normal `n`. The term is zero when `n · s ≤ 0`. Both terms integrate in closed
  form along a straight ray.

**Clip planes.** In a view with a clip plane the box spans start at the plane's crossing, so the medium applies only on
the kept side and the segment before the plane gets neither medium nor air, as for the fog.

**Cost.** Each fogged pixel does one box test per kept volume and up to nine sub-intervals, five of them air.
`MAX_VIEW_MEDIA` is the lever. A traced hit marches the atmosphere on each air sub-interval, twice for those that do
not start at the origin.

## Clouds

A `CloudLayer` holds one deck of clouds between two altitudes. The application owns the weather: it
supplies the coverage map, places the layer and advances its wind. The renderer owns the noise and
the lighting.

| Field | `CLOUD_LAYER_DEFAULT` | Meaning |
| --- | --- | --- |
| `bottom`, `top` | 1,500, 3,000 | altitudes in metres above the y = 0 datum; `top` is above `bottom` |
| `density` | 0.04 | extinction per metre where the weather is full |
| `coverage` | unset | a 2D `TextureId`: R is coverage, G the share of the layer a cloud fills; unset is full cover |
| `coverage_extent` | 20,000 | metres one repeat of the map spans |
| `noise_scale` | 8,000 | metres one repeat of the noise spans |
| `erosion` | 0.3 | detail noise strength, 0 to 1 |
| `wind_offset` | 0 | metres the clouds have drifted along each axis; the application advances it |
| `albedo` | 1 | single-scattering albedo, 0 to 1 |
| `anisotropy` | 0.6 | Henyey-Greenstein `g` of the forward lobe; the back lobe takes −g / 2 |
| `cast_shadows` | true | the layer shadows the sun's light on the scene ([cloud shadows](#cloud-shadows)); a bare `CloudLayer{}` casts none, `CLOUD_LAYER_DEFAULT` does |

`light::cloud_layer_valid` states what the renderer accepts. A dangling `coverage` counts in
`Stats.dangling_refs` and the view draws no clouds; a cube, array, 3D or integer map faults
`UNSUPPORTED`. The layer is drawn in every raster view whose camera sees its node; mirror and clip-plane views
include it, and the plane does not clip it.

**Noise.** The renderer owns one 128³ `RGBA8` volume that repeats on every axis: R holds Perlin noise
lifted by Worley noise, G, B and A hold Worley noise at 4, 8 and 16 cells per repeat. A compute pass
generates it once, the first time `prepare_scene` or a frame sees a valid `CloudLayer`, so an
application without clouds pays nothing and the first frame of one that prepares its scene does not
hitch. It is never rebuilt; the device lives as long as the renderer.

**Density.** At a point of the layer, with `h` the height over the layer's thickness, `(c, g)` the map's
R and G channels and `w` the noise volume at the point over `noise_scale`:

```
profile = clamp(h / 0.1) · clamp((g − h) / (0.4 g))
low     = 0.625 w.g + 0.25 w.b + 0.125 w.a
base    = clamp((w.r − (low − 1)) / (2 − low))
body    = clamp((base · profile − (1 − c)) / c) · c
```

and the detail pass takes the same noise at 8 times the frequency, `t = erosion · 0.5 · (0.625 d.g + 0.25 d.b + 0.125 d.a)`,
`body = clamp((body − t) / (1 − t))`. The extinction is `σ = density · body`. The map and the noise slide with
`wind_offset`: a feature at `p` sits at `p + wind_offset`.

**Geometry.** With an atmosphere the layer is the shell between `bottom` and `top` above the planet, around
the centre below the camera, as the atmosphere's own tables are; without one it is the slab between two
planes. A ray marches from where it enters the layer, at most 60 km of it, and stops at the scene depth;
a ray that meets the planet before the layer sees none. The march takes `CLOUD_STEPS` (64) steps
at half resolution, each jittered by interleaved gradient noise, and stops early once its transmittance
is under 2 %.

**Lighting.** The sun is the atmosphere's sun or, without one, the scene's first directional light; the
ambient is the sky-view table at the zenith times the sun's illuminance, or the scene's ambient. Both come
from the view, so [pre-exposure](#exposure) applies. Each step adds, with `T` the transmittance so far,
`Δ` the step and `h` the height over the layer's thickness:

```
S += T · (1 − e^(−σΔ)) · albedo · (E · T_air · W + L_amb · mix(0.4, 1, h))
W  = (1 − 0.5 e^(−400 σ)) · Σ_i 2^−i · e^(−2^−i τ) · phase(cos θ, g 2^−i),   i < 3
phase(cos θ, g) = mix(HG(cos θ, g), HG(cos θ, −g / 2), 0.3)
```

`E` is the sun's `color × intensity`, `T_air` the atmosphere's transmittance from the sample's altitude along
the sun, and `τ` the optical depth toward the sun: `CLOUD_LIGHT_STEPS` (6) samples without detail over the
sun's path out of the layer, at most 4 km. The sum is Wrenninge's octaves of multiple scattering, the
factor before it a Beer-powder darkening of the thin fringe. The march shadows the deck itself; the scene's shadow is
the [cloud shadow map](#cloud-shadows).

**Composition.** `Pass.CLOUDS` follows the forward or deferred pass and its sky, so the scene readers'
snapshots hold the clouds. It marches the half-resolution target, then a second dispatch composites it into
`hdr_color` in place with a depth-aware 4 × 4 upsample that weights taps as the AO blur does. A pixel becomes
`x · T + S'`, with the aerial perspective carried to the cloud's opacity-weighted distance `d_c`, and the
pixel's own distance `d` (infinite over the sky, where the table adds nothing):

```
S' = (A_T(d_c) · S + (1 − T) · (A_S(d_c) − A_S(d))) / A_T(d)
```

The fog pass then applies the height fog to the composite, so the order is cloud, aerial perspective,
height fog. A view with a cloud layer splits its blended draws after the pass, as a fogged view does.

**Memory.** Per view, `12 · ceil(w / 2) · ceil(h / 2)` bytes: a half-resolution `RGBA16F` target (8 B,
scattered radiance and transmittance) and an `R32F` target (4 B, the distance), allocated the first
frame the view draws a layer and kept until the view is destroyed or its working size changes; twice that with
[`cloud_temporal`](#cloud-temporal-accumulation). The renderer adds one 128³ `RGBA8`
volume, 8 MiB. The [cloud shadow map](#cloud-shadows) adds `CLOUD_SHADOW_SIZE² × 2 B` per view.

### Cloud shadows

A layer with `cast_shadows` multiplies the sun's visibility by the transmittance the layer lets through. `Pass.CLOUD_SHADOWS`
writes one map per view every frame, before the fog volume and the forward or deferred pass, from the layer as it is that
frame: nothing is cached, so wind and weather edits show at once. A view with no layer, or whose layer has `cast_shadows` false,
records no pass and allocates no map.

- **Map.** `CLOUD_SHADOW_SIZE` (512) texels, `R16F`, cover `CLOUD_SHADOW_EXTENT` (16,384 m) of the layer's bottom plane: 32 m a
  texel, finer than the soft edge of a shadow, with the extent the lever for reach against sharpness. A texel holds `e^−τ`, `τ` the
  optical depth along the sun from that point of the plane up through the layer, taken in `CLOUD_SHADOW_STEPS` (16) samples with
  the detail octave. The layer is taken as flat over the map, also under an atmosphere, where the shell drops about 5 m over the
  map's half extent. The path leans along the sun by `1 / max(sun_up, CLOUD_SUN_FLOOR)`, with `CLOUD_SUN_FLOOR` (0.1) the floor the
  cloud march's own light march uses, so a low sun shortens the path and shifts the shadow instead of dividing by zero.
- **Placement.** The map is centred on the camera's footprint along the sun. Between the datum and the layer's bottom that is the
  point of the bottom plane the camera's own position reaches, so surfaces at the camera's altitude sit at the centre, and the
  ground under a camera at altitude `a` sits `a · |sun.xz| / max(sun_up, CLOUD_SUN_FLOOR)` off it: about 6.9 km for `a` = 1,400 m
  at 11.5°, and beyond the half extent for a low enough sun. At or above the bottom, and below the datum (a reflected mirror
  camera counts as on it), it is the point the datum under the camera reaches, so the ground under the camera sits at the centre
  at any sun. The centre is snapped to the world's 32 m grid, so the content stays where it is in the world while the camera
  moves and only the corner steps, by whole texels. When the camera crosses the bottom or the datum the window steps from one
  centre to the other: a receiver inside both windows reads the same value, and only the region the map covers moves.
- **Light.** The sun is the one the cloud march uses: the atmosphere's sun, otherwise the scene's first directional light. Its
  packed light carries `LIGHT_CLOUD_SHADOW`, and `FrameRoot.cloud_shadow` addresses the `CloudShadowRoot`; it is zero without a map.
  No map exists while the sun is at or below the horizon, and the sun's visibility is then unchanged.
- **Receivers.** `shadow_visibility` and `shadow_transmittance` multiply that light's visibility, so forward Standard, Physical
  and Toon, the deferred lighting resolve, the volumetric fog's sun term and custom stages that call them receive it, as does a
  sun with traced shadows. `light_casts_shadow` is true for the flagged light even when it has no shadow layers. A draw that does
  not receive shadows receives none. The volumetric fog's froxels take it too, so gaps between clouds light shafts.
- **Projection.** A receiver at altitude `y` goes along the sun to the bottom plane and reads the map there. A receiver inside
  the layer reads `T^s`, with `s` the share of the layer above it, which treats the density as uniform along the way; a receiver
  above the layer gets 1.
- **Edge.** Outside the map the transmittance is 1. It fades to 1 over the outer `CLOUD_SHADOW_EDGE_BAND` (10 %) of the map's half
  extent, so the border never shows as a seam; a narrower band shows it on the ground.
- **Temporal fog.** The map's motion is not part of the fog history's rejection key. It changes the in-scatter the clamp sees, as
  a moving shadow edge does, so wind and camera motion do not reset the history.
- **Memory.** `CLOUD_SHADOW_SIZE² × 2 B` per view, 512 KiB, allocated the first frame the view casts the shadow and kept until the
  view is destroyed or its images are reallocated.
- **Not shadowed.** The path tracer, traced reflection and probe-update hits, and the atmosphere's lighting cubes do not see the
  map, as they do not see the clouds. Reflection captures render without clouds and so without their shadow. Mirror and
  clip-plane views have a map of their own.

### Cloud temporal accumulation

`ViewDesc.cloud_temporal` accumulates the layer over frames, so the jitter of one frame's march averages out. The switch is
per view, as `fog_temporal` is: the history lives in the view's own images, a mirror and the main view differ in size and
camera, and the layer is a scene component the views share. A view without it runs the plain march, a separate shader variant
with none of what follows.

- **Jitter.** Each submitted march advances the view's index into `CLOUD_TEMPORAL_SAMPLES` (16) Halton points. Base 2 moves each
  pixel's march start within its first step, added to the pixel's interleaved gradient value and wrapped, so neighbouring pixels
  sample different depths in the same frame. Bases 3 and 5 move the ray within its half-resolution pixel, by up to half a pixel
  each way. The first averages the sampling along the ray and the second the pixel's footprint across it. The history belongs to
  the pixel's centre, from which the reprojection starts. An orthographic view takes neither offset nor history.
- **Reprojection.** A pixel is traced back from the cloud's opacity-weighted distance: the point at that distance on its ray,
  moved back by the wind the layer drifted since the previous frame, is projected through the view's previous view-projection and
  read there from the previous frame's images with the five-tap Catmull-Rom filter TAA uses. A pixel with no cloud, whose distance is 0, goes back as
  its direction, a point at infinity. A pixel whose previous position lies outside the previous frustum takes no history.
  Camera motion and wind reproject and do not reject.
- **Clamp.** The history's radiance and transmittance are clamped, per channel, to the range of this frame's values over the
  pixel's 3 × 3 neighbours, then blended with `CLOUD_HISTORY_WEIGHT` (0.9), a memory of about ten frames. History the neighbours
  no longer support, such as a cloud the wind moved on or a weather map that was edited, goes to their range at once. A group
  of 16 × 16 pixels also marches a border of one pixel around it, so every pixel has its neighbours: 1.27 times the marches,
  and the border is skipped on frames that take no history. The distance blends with the same weight where the frame and its history both have a
  cloud, and takes whichever has one otherwise.
- **Pre-exposure.** The history's radiance is multiplied by the ratio of the view's current pre-exposure to the one it was
  marched under, so an exposure change rescales it instead of rejecting it; transmittance is not scaled. The images keep the
  factor themselves, so the ratio holds without TAA, motion blur or screen-space GI on the view.
- **Rejection.** The history of a view is dropped, and the next frame marches without it, when:
  - `reset_view_history` ran, the view was created or configured (a resize reallocates the images), the switch was turned on, or
    the scene changed;
  - any `CloudLayer` field except `wind_offset` changed, the atmosphere's planet radius changed, or the frame origin changed;
  - the sun's direction moved more than `CLOUD_HISTORY_SUN_DEGREES` (0.1°) since the previous frame.
  The sun's colour and intensity, the ambient light and the contents of the weather map are not triggers; they converge through
  the blend. A layer that changes every frame, or a sun turning faster than the threshold, gets no convergence.
- **Ownership.** The view keeps two pairs of images. The march reads one pair as history and writes the other, which the composite
  reads, and they swap only when the frame is submitted; an aborted frame neither swaps nor commits, so the next frame continues
  from the last submitted one. The history is valid only if the view's own last submitted frame wrote it: a view that was not
  rendered, or drew no layer, in a submitted frame starts again without history, and a second recording in one frame takes none.
  A mirror or clip-plane view keeps its own pairs and history.
- **Cost.** The memory is twice the layer's (see [Clouds](#clouds)). The march adds the reprojection, the filtered read of the
  history and a fetch of its distance per pixel, and the border pixels' marches.
- **Orbit.** From orbit a pixel spans kilometres of the deck, more than the size of its features, so one ray per pixel point-samples
  them and the whole disc shows the aliasing as speckle that is the same every frame. The offset along the ray cannot average it;
  the offset within the pixel does, so a still camera's disc settles within about ten frames to the footprint's average. A camera
  or a sun that moves faster than the history converges shows the plain march's speckle.

**Not drawn.**

- The path tracer, traced reflection and probe hits and misses, and the atmosphere's lighting cubes do not
  see clouds or their shadow: an overcast sky still lights the scene, its reflections and its probes as a clear one.
  Reflection captures render without clouds (`ViewCamera.clouds`, the way `height_fog` is switched).
- Clouds write no depth and the transparent pass draws after them. A blended surface farther than a cloud
  draws over it, and so does a scene reader, which draws after the composite and tests against the scene's
  depth alone. At cloud altitudes the case is rare.
- The height fog covers the composite as it covers any pixel: over the sky it takes the fog to infinity, so
  a camera above the fog layer looking down sees the fog in front of the clouds below it.
- Without `cloud_temporal` one ray per pixel point-samples the deck and shows as grain, most where a pixel's footprint spans many
  features. From orbit that is the whole disc, not only the limb, because each pixel covers many repeats of
  the coverage map and the noise. [Temporal accumulation](#cloud-temporal-accumulation) averages it over frames.

## Custom stages

`fog.glsl` is a public include:

| Function | Use |
| --- | --- |
| `FogTerms { transmittance; inscatter; }` | radiance `x` seen through fog is `x · transmittance + inscatter` |
| `fog_terms(frame, uv, position)` | the fog from the camera (or a clipped view's plane) to a surface |
| `fog_background_terms(frame, uv)` | the fog in front of a background pixel |
| `apply_fog(frame, world_position, color)` | a blended fragment's fog; returns `color` when `frame.sky_fog` is zero |
| `fog_behind(frame, surface_position, behind, behind_depth)` | the fog between a surface and a depth sample behind it; depth 0 is the background |
| `apply_fog_refracted(frame, surface_position, transmittance, refracted, refracted_depth, surface_radiance)` | a depth-writing refracting surface's output |
| `apply_fog_segment(frame, origin, hit_position, radiance)` | the height fog and, behind it, the marched atmosphere over the segment from a ray's origin to its hit, for a ray cast from elsewhere than the camera; returns `radiance` when `frame.sky_fog` is zero |
| `apply_fog_to_infinity(frame, origin, direction, radiance)` | the height fog from a point to infinity, for a ray that leaves the scene; no atmosphere |
| `fog_phase(cos_angle, anisotropy)` | the Henyey-Greenstein phase, per steradian |
| `atmosphere_segment(sky, altitude, direction, distance)` | the `FogTerms` of the marched atmosphere over `distance` of a unit ray from a world altitude; none without an atmosphere |

- Every helper above that fogs a ray includes the view's [medium volumes](#medium-volumes), with the same signature: a
  segment through a box takes the medium's absorption and in-scatter in place of the air.
- An opaque custom stage needs nothing: the pass fogs it at its depth. It cannot opt out.
- A blended custom stage calls `apply_fog` on its output, unconditionally.
- A depth-writing reader that refracts returns
  `apply_fog_refracted(frame, position, t, scene_color_at(frame, uv), scene_depth_at(frame, uv), own)`;
  the pass then fogs the pixel from the camera to the surface, so the result is
  `t · fog(refracted over its depth) + own · T + (1 − t) · S`. Its `scene_reads` needs `depth` on a
  view without fog; a fogged view adds it.
- A blended reader draws after the pass and composes `apply_fog(frame, position,
  apply_fog_refracted(...))`.
- A reader that writes no depth takes the fog of what lies behind it. Built-in Physical transmission
  drawn with `AlphaMode.BLEND` is such a reader and does not fog behind its surface.
- A custom twin of Standard keeps matching it: opaque twins are fogged by the pass, a blended twin
  calls `apply_fog` as Standard does.
- The lookups `fog.glsl` brings in, `sky_view_radiance`, `sky_aerial_perspective` and `sky_multi_scattering`, return
  luminance for unit sun illuminance. The tables' storage scale is divided out inside them, so a stage that multiplies
  their result by `sun_illuminance` needs no change.

## Exposure

The sky's radiance spans five orders of magnitude between noon and twilight, and c3d sets no
exposure: the application drives `Camera.exposure`. A table of sun elevations works well: exposure
proportional to 1 / (zenith sky luminance), interpolated in elevation on log₂ of the exposure. The
sky example's table, measured from its zenith luminance at sun intensity 3:

| Sun elevation | 60° | 30° | 10° | 5° | 2° | 0° | −2° | −4° | −6° | −8° |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `Camera.exposure` | 1 | 1.6 | 2.8 | 4 | 6.5 | 12 | 35 | 155 | 2050 | 13500 |

`--auto-exposure` sets `Camera.exposure` to 1 and turns on [auto exposure](post.md#auto-exposure) on the main view
instead of the table; the panel shows the table's value beside the adapted one. Converged on the RTX 4090, ten
seconds after setting the elevation:

| Sun elevation | Table stops | Adapted stops | Difference |
| --- | --- | --- | --- |
| 60° | 0.00 | −0.20 | −0.20 |
| 5° | 2.00 | 2.22 | +0.22 |
| −4° | 7.28 | 8.24 | +0.96 |

At −4° the main view applies 301.5 while its `LINEAR_HDR` mirror stays at 1.000.

The table stays the manual default.

### Pre-exposure

Every view stores its sky and its lighting multiplied by a power of two near its exposure, and post divides it
out ([pre-exposure](post.md#pre-exposure)). The sky pixel, the fog and the lights then sit near display scale in
`RGBA16F` at every elevation, where unscaled radiance below about intensity × 10⁻⁵ would sit in the subnormal
range, whose steps are 6 × 10⁻⁸. The shared environment and sky cubes stay physical and reach a view through its
per-view intensity. The atmosphere's tables follow the same rule through their own scales, described in
[Sky table scale](#sky-table-scale).

- A clamp that shapes the image acts on physical radiance: the sun's disc is limited to 60,000 first, and then
  scaled.
- A clamp that keeps half-float finite acts on the stored value after the scale: the sky pixel at 65,504 (a bright
  disc under a high factor is cut at 65,504 divided by the factor), the sky tables' texels, the weighted blend's
  accumulation, and the path tracer's copy into the view's image.
- The brightest sun disc the half-float target can hold shrinks as the pre-exposure factor grows, so a disc dimmed by
  fog can clip at high factors, and a disc clipped by the storage guard also weakens its bloom.
- The weighted blend's colour limit of 64 is in stored units, about 64 times display white at every exposure.
- TAA's `1 / (1 + luma)` weights and its variance clip work in stored units, so they follow the exposed image
  rather than absolute radiance.

### Sky table scale

The atmosphere's tables are `RGBA16F`, and twilight luminance per unit sun illuminance sits in that format's
subnormal range, so three of them hold scaled values:

- The view's sky-view table and the in-scatter of its aerial-perspective table hold the luminance times
  `SkyFogGpu.sky_table_scale`: a power of two, `2^round(log2(m))` for the largest channel `m` of the view's sun
  illuminance (`color × intensity × pre-exposure`), clamped to 2^0 to 2^16, and 1 for an illuminance that is zero or
  not finite. The aerial-perspective opacity is not scaled. Both tables are rewritten every frame the view renders the
  atmosphere, with that frame's scale, so a change of sun or exposure regenerates nothing extra.
- The multi-scattering table holds its luminance times 2^10, whatever the sun. It is shared per atmosphere and
  rewritten only when the atmosphere changes.
- The transmittance table is unscaled.
- A table texel saturates at 65,504 instead of becoming infinite, as a stored sky pixel does.
- The lookups divide the scale out, so a texel that was normal in the unscaled table reads back unchanged.

## Path tracing

A path-traced view lights with the atmosphere's cubes and shows its source cube as the background
(seen from `observer_altitude`, without the disc); the sun is attenuated at the path tracer's camera.
It has no fog, no aerial perspective and no clouds. A sky or sun change does not restart accumulation, as no
light edit does: call `render::reset_view_history(&renderer, view)` when the time of day moves; the
sky example does under `--path-traced`.

## Limits

- One atmosphere per scene, lit from `observer_altitude`: the lighting, the path tracer's background and the
  probe update's sun do not follow a camera above the atmosphere or far from the observer.
- Above the atmosphere the limb is as sharp as the 192 × 108 sky-view table: its edge blurs over about one texel.
- One fog medium per view, the first the view's layers see.
- At most four medium volumes per view; the nearest are kept and the rest count in `Stats.media_dropped`.
- No underwater light shafts: media are analytic with no froxel scattering, and the air composed behind a dense medium
  is approximate, because the froxel sub-range divides by a transmittance floored at 1e-4.
- The medium's sun term has no occluder shadowing, and the column ignores rays that leave through a side face near the
  box edges. Each box's column counts that box's extinction only, so an overlap does not attenuate the other box's sun.
- Surfaces inside a medium are lit as in air; the medium attenuates the view path only.
- Probe updates, reflection captures and the path tracer take no media.
- Readers that write no depth take the fog of what is behind them; blended Physical transmission is
  one.
- Mirror views fog only behind their clip plane.
- Traced reflection and probe hits take the analytic height fog and a marched atmosphere over their segment, with no
  froxel volume and no aerial perspective table; a miss takes the height fog alone.
- Opaque stages cannot opt out of the fog pass.
- Path-traced views are unfogged; a sky change does not restart their accumulation.
- Twilight precision is bounded by `RGBA16F`: the tables keep a half float's 11-bit significand, and the
  transmittance table holds physical values, some of which are subnormal on the grazing paths of deep twilight.
- The sun's disc saturates at 60,000 physical radiance.
- Aerial perspective keeps one mean transmittance, covers 128 km (from the shell above it) and composes behind
  the height fog;
  a refracted segment through both media is approximate, and the refraction's bend is ignored for
  the fog distance.
- Screen-space GI gathers unfogged radiance without blended draws on fogged views.
- Memory: 418 KiB and two heap slots per raster view; about 0.7 MiB and 82 heap slots per atmosphere
  (0.9 MiB and 119 with sheen); four atmospheres at once.
- Volumetric fog without `fog_temporal` has no reprojection or jitter. It is unshadowed past the shadow atlas,
  changes its in-scatter slope at `max_distance` and does not exist on path-traced views.
- The analytic fog has no direct-sun phase term, so a view with volumetric fog and a view without it show
  different haze colours.
- Clouds: see [Clouds](#clouds) for what they leave out; the layer is one deck, and its [shadow map](#cloud-shadows) is flat over
  its extent.

## Example

```bash
python3 scripts/build.py --example sky
```

`examples/sky` shows a 4 km ground with boxes and spheres from 10 to 800 m, a glass pane, a
transmissive sphere, a blended transmissive pane, a blended quad, a water pond (a scene reader) and a
planar mirror beside it. The panel sets the sun's elevation and azimuth, plays a time-lapse at 0.27° a
second, edits the fog, switches the exposure table and shows the sky's passes and stages and the
regeneration count; the presets noon, twilight, valley (300 m up, looking down into the fog), pan, orbit and
time-lapse pose the camera and the sun. The mirror pad renders with the main camera as its shadow camera, so the
frame records one shadow atlas, the mirror's, and the main view binds it ([shadow sets](shadows.md#shadow-sets)).

`--auto-exposure` replaces the exposure table with auto exposure on the main view. `--pre-exposure off|FACTOR`
forces the main and mirror views' [pre-exposure](#pre-exposure) to 1 or to a power of two from 2⁻¹⁶ to 2¹⁶. The presets
`dusk` and `nautical` set the sun to −6° and −8°.

The `orbit` preset puts the camera 400 km up, pitched 10° down, with the sun 12° up: the limb curves 9.8° below the
view's axis and the sun's disc stands against space. The sun slider reaches −25°; near −19.4° the disc is seen through
the limb, reddened, and below −19.8° the planet hides it. Above 50 km the example gives the camera a
1,000 km far plane, sets `FrameInfo.reference_position` to it and uses an exposure of 1, because the exposure table
describes a sun over an observer on the surface.

`--benchmark [frames]` renders offscreen at 2560 × 1440 through the noon, twilight, valley, pan, orbit and ascent
segments (the ascent raises the camera 4 km a second from 90 km to 110 km, the sun 9° below the horizontal, seen
through the limb) and a time-lapse four segments long (the sun rising 0.0045° a frame from 10°) and prints the
per-view passes, frame times, the refresh cost per stage, refreshes per minute and the CPU cost of
`sun_radiance`. Its gates: the time-lapse regenerates exactly `floor(sweep / period)` times, with
`period = (floor(0.5° / step) + 1) · step`, and the noon and ascent segments regenerate nothing after their
first frames. `--shading forward|deferred`, `--shadows atlas|traced`, `--ssgi`, `--path-traced`, `--reflections on|off`,
`--fog on|off`, `--atmosphere on|off|dense|empty`, `--clouds`, `--preset`, `--gpu-timings` and `--validation` select
the configuration. See [benchmarking](benchmarking.md#sky-benchmark).

`--atmosphere` takes `on` (`ATMOSPHERE_EARTH`), `off`, `dense` (Earth's air with a Rayleigh scattering of 0.5 per
metre on every channel, opaque to the sun) and `empty` (Earth's air with no Rayleigh or Mie scattering). They are
the limits of the [multiple-scattering table](#lighting-and-regeneration): a series ratio of 1 and no scattering.

`--reflections on` needs `--shading deferred`. It gives the main view [traced reflections](reflections.md) and the
ground a roughness under their threshold, so the boxes and spheres show in it; each reflected path takes the
[atmosphere and the fog](#where-fog-applies) between the ground and the hit, as the direct view takes them.

`--volumetric-fog` gives the main and mirror views a fog volume, `--fog-quality low|medium|high` picks its grid
(`medium` by default), `--fog-temporal` turns on its [temporal accumulation](#temporal-accumulation), `--taa` turns
on TAA, and the `pan` preset and segment sweep the camera's yaw 8° a second from −20° with the sun 15° up. The fog
panel edits density, falloff, anisotropy and `max_distance`, and with `--volumetric-fog` a volume quality combo and
a "Temporal accumulation" checkbox. Under `--path-traced` the switch is ignored.

`--local-lights N` (at most 128) lines the path ahead of the camera with `N` point and spot lamps, alternating and
placed in pairs either side of it. The first eight cast shadows; the main and mirror views select clustered lights.
`--lamp-range METRES` sets their range (14 by default, so about three overlap at any point; a range of 400 puts
every lamp in every cluster cell), and `--lamps-in-fog off` sets their `Light.volumetric` to false. With
`--volumetric-fog` the fog panel has a "Lamps in fog" checkbox for it. The lamps are tuned to the twilight
exposure; at noon the sun outshines them.

`--clouds` adds a `CloudLayer` over a procedural coverage map the example builds on the CPU as the application's
weather, lifts the noon and twilight presets 15° so the deck fills the view and advances `wind_offset` along +x every
frame. Its panel section edits the coverage, which rebuilds the map, the density, the two altitudes and the wind speed, and
switches the layer's shadows with a "Cloud shadows" checkbox; the wind moves them. `--cloud-temporal` turns on the views'
[temporal accumulation](#cloud-temporal-accumulation) of the layer, and the panel has a "Cloud temporal accumulation" checkbox for it.
It is rejected under `--path-traced`.

The landscape examples `terrain`, `vegetation` and `water` take `--sky`: an `ATMOSPHERE_EARTH` on
their sun and a haze pooling in the valleys, and `--volumetric-fog` with it.

## Measured cost

### RTX 4090, driver 610.88, 2560 × 1440

`--opt O3` with GPU profiling, medians of three runs of per-run medians, ms. The mirror view renders at
half size.

| Sky tables and fog, per view | Main | Mirror |
| --- | ---: | ---: |
| `SKY_VIEW` | 0.013 | 0.014 |
| `AERIAL_PERSPECTIVE` | 0.020 | 0.020 |
| `FOG`, forward | 0.037 | 0.012 |
| `FOG`, deferred | 0.037 | 0.012 |
| `water --sky`: `SKY_VIEW`, `AERIAL_PERSPECTIVE`, `FOG` | 0.014, 0.020, 0.041 | 0.015, 0.020, 0.014 |

The time-lapse refreshes the 64-texel sky cube 11 times a run. At 0.27° a second the sky regenerates 30.0 times a
minute (period 0.504°). `sun_radiance` costs 0.90 µs on the CPU.

| `sky` frame, ms | Noon | Twilight | Valley | Time-lapse |
| --- | ---: | ---: | ---: | ---: |
| forward | 0.492 | 0.354 | 0.430 | 0.500 |
| deferred | 0.558 | 0.419 | 0.515 | 0.564 |
| `--shadows traced` | 0.397 | 0.381 | 0.345 | 0.406 |
| `--ssgi` | 1.355 | 1.220 | 1.292 | 1.361 |
| `--fog off --atmosphere off` | 0.324 | 0.248 | 0.275 | 0.323 |

`--path-traced`: `PATH_TRACE` 0.424, frame 0.614 at noon.

Fog off costs nothing: Sponza in `gltf_viewer --benchmark` records `cpu_record_ms` 0.1437 before this
change and 0.1431 after, and its six largest passes overlap before and after.

| Landscape `still` frame, ms | Without `--sky` | With `--sky` |
| --- | ---: | ---: |
| `terrain` | 1.313 | 1.434 |
| `vegetation` | 1.228 | 1.355 |
| `water` | 2.233 | 2.362 |
| `water` mirror view total | 0.721 | 0.772 |

Terrain's +0.121 ms is `FOG` 0.038, the tables 0.035 and 0.049 more `FORWARD_OPAQUE` for the sky's
image-based lighting.

Judged on the 4090: the lighting's regeneration steps at 0.27° a second stay under one 8-bit level on an
image-lit face (+0.47 to +0.61 against −0.05 a frame between) and are not visible; the −4° twilight
shows no banding; valley haze seen from 300 m up takes the warm horizon colour; the blended
transmission pane shows no double fog; the water's reflections of far peaks are no hazier than the
peaks seen directly.

A second view's tables do not call for a per-view switch.

### Volumetric fog, RTX 4090, 2560 × 1440

Same build and method; the fog's density raised to 0.01 for the judgements below.

| Volume passes, `FOG_SCATTERING` + `FOG_INTEGRATION`, ms | Main | Mirror |
| --- | ---: | ---: |
| forward, noon | 0.0266 + 0.0164 = 0.043 | 0.0181 + 0.0205 = 0.039 |
| deferred, noon | 0.0276 + 0.0174 = 0.045 | 0.0174 + 0.0205 = 0.038 |
| `--shadows traced`, noon | 0.0266 + 0.0141 = 0.041 | 0.0133 + 0.0209 = 0.034 |
| forward, pan / valley / twilight (no sun) | 0.048 / 0.044 / 0.027 | 0.040 / 0.039 / 0.029 |

At 160 × 90 × 64 with a four-cascade sun the passes cost 0.043 ms, about a tenth of a 0.5 ms budget; traced
shadows cost 0.95 times the atlas. The fog pass reads the volume's lookup even without the switch: `FOG` goes
from 0.0369 to 0.0410 ms on the main view and from 0.0123 to 0.0133 ms on the mirror; with the switch it is
0.0430 ms.

| `sky` frame, forward, ms | Before | Without the switch | With it |
| --- | ---: | ---: | ---: |
| noon | 0.501 | 0.506 | 0.586 |
| twilight | 0.360 | 0.369 | 0.432 |
| valley | 0.429 | 0.436 | 0.522 |
| time-lapse | 0.504 | 0.512 | 0.597 |
| pan | | 0.513 | 0.597 |

With the switch at noon: deferred 0.654, `--shadows traced` 0.487, `--taa` 0.707. `sun_radiance` stays at 0.90 µs. Sponza without fog: `cpu_record_ms` 0.1444 (0.1429 to 0.1638) before
and 0.1518 (0.1424 to 0.1661) after, with its six largest passes overlapping.

| Landscape `still` frame, ms | `--sky` | `--sky --volumetric-fog` | Volume passes |
| --- | ---: | ---: | --- |
| `terrain` | 1.464 | 1.488 | 0.0307 + 0.0154 |
| `vegetation` | 1.377 | 1.407 | 0.0314 + 0.0154 |
| `water` | 2.369 | 2.489 | main 0.0297 + 0.0152, mirror 0.0184 + 0.0205 |

Memory: 7.03 MiB per 2560 × 1440 view.

Judged on the 4090: across 12 frames of a slow pan, with and without `--taa`, the haze near the horizon changes
by at most 2 levels a frame and the shadowed fog behind the boxes moves with them, so the volume needs no
reprojection; at `max_distance` 200 and 500 m a ground column steps at most 2 levels a row (1 in the valley at
500 m), so 64 slices suffice; shadowed-fog edges are soft at 16 px, the only stair-step being the atlas's own;
no ring shows at `max_distance`; twilight shows no banding; the water's reflections are no hazier than the peaks
seen directly and no veil sits in front of the mirror plane.

### Shared mirror shadow set, RTX 4090, 2560 × 1440

Same build and method. Before: the mirror and the main view each record an atlas. After: the mirror records the
main camera's set and the main view binds it.

| `sky` frame, forward, ms | Before | After |
| --- | ---: | ---: |
| noon | 0.513 | 0.462 |
| twilight | 0.373 | 0.389 |
| valley | 0.434 | 0.389 |
| time-lapse | 0.519 | 0.469 |
| noon, `--volumetric-fog` | 0.596 | 0.542 |

Before and after were measured in one session. Twilight records no atlas in either build (the sun is below the
horizon), so its sets are empty and nothing is shared. It is slower by 0.014 ms of `FORWARD_OPAQUE` because the
forward shader's coarser-cascade lookup compiles larger for every view; see the
[lookup cost](shadows.md#lookup-cost).

### WSL, llvmpipe

Environment only: a CPU rasterizer, not a GPU. `sky --benchmark 30 --width 256 --height 144
--gpu-timings`, forward, one run, medians in ms:

| Pass | Main view, noon |
| --- | --- |
| `SKY_VIEW` | 2.073 |
| `AERIAL_PERSPECTIVE` | 3.058 |
| `FOG` | 0.870 |
| `SKY` | 0.323 |

`sun_radiance` costs 0.78 µs.
