# Sky, atmosphere and height fog

Two components in `c3d::light` describe the outdoors. An `Atmosphere` on the node of a directional
`Light` turns that light into a sun seen through air: the renderer draws a physically based sky with
the sun's disc, attenuates the sun's light by the air it crosses, lights the scene from the sky and
adds aerial perspective to distant surfaces. A `HeightFog` on any node adds exponential height fog.
Either works without the other.

```c3
Light sunlight = light::directional({ 1, 1, 1 }, 3);
Node* sun = scene.add_light(sunlight, name: "sun")!;
sun.local.rotation = maths::look_rotation({ -0.3f, -0.8f, -0.5f }, { 0, 1, 0 });
scene.add(sun, light::ATMOSPHERE_EARTH);

Node* haze = scene.add_node(name: "haze")!;
scene.add(haze, light::HEIGHT_FOG_DEFAULT);
scene.update_world();
```

`create_scene` registers both components. Nothing else is needed: the renderer resolves them every
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
| `max_distance` | 200 | metres of view a volumetric fog would cover; validated, not yet read |

`light::atmosphere_valid` and `light::height_fog_valid` state what the renderer accepts. An
atmosphere needs finite positive radii, heights, scale heights, ozone width and sun radius (below
π/2), finite nonnegative coefficients, an albedo in [0, 1], `|mie_anisotropy| < 1` and an observer in
[0, atmosphere height). A fog needs finite nonnegative density, falloff and albedo and a finite
positive `max_distance`.

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

Everything is in metres, and world y = 0 is the planet's surface for both the camera's altitude and
`observer_altitude`; altitudes clamp into [0, atmosphere height]. There is no datum field: a world
whose ground sits elsewhere moves its content, not the atmosphere. The fog's density follows its own
node instead, so moving the fog node moves the fog.

The sky's tables are computed for a sun of unit illuminance. The drawn sky, the lighting, the fog's
in-scatter and aerial perspective all scale with the sun's `color × intensity`, so doubling the
intensity doubles every sky pixel. Exposure is the application's `Camera.exposure`; see
[Exposure](#exposure).

## The sun

Every light extraction (views, probe updates and the path tracer) attenuates the atmosphere's sun,
and only it: `sun_radiance` at the extracting camera's y (probe updates use `observer_altitude`)
becomes the packed light colour. Other directional lights pass unchanged. A sun whose radiance is
exactly zero, below the horizon, packs no light, requests no shadow layer and counts in the view's
`LightCounts.culled`; the shadow atlas stays allocated for its return. The sun's disc is drawn in the
background only, never in the lighting, and saturates at 60,000 (an intensity above about 4.1) to
stay inside `RGBA16F`.

## Lighting and regeneration

Each atmosphere owns its transmittance (256 × 64) and multiple-scattering (32 × 32) tables and a
64-texel source cube with its GGX cube, SH and, on first sheen use, a Charlie cube. The cubes are the
sky seen from `observer_altitude` with the sun's colour at unit intensity and no disc; the sun's
intensity scales them as the environment intensity. They light the scene through the ordinary
environment path: image-based lighting, reflections that miss, probe volumes filled from the
environment and the path tracer.

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

A view is fogged when its scene has an atmosphere or it sees a valid `HeightFog`. A fogged view runs
one compute pass, `Pass.FOG`, after the scene readers and before the blended draws: it fogs every
pixel from the camera to the depth it holds, so opaque, masked and custom opaque surfaces, the sky,
terrain, foliage and depth-writing readers such as water need no fog code. Blended draws, which write
no depth, fog themselves per fragment with `apply_fog`; the built-in Standard, Physical, Toon and
Basic materials do. A view with neither fog nor atmosphere records no fog pass and no split, and
costs what it did before.

- The fog is composed as aerial perspective behind the height fog:
  `(x·T_ap + S_ap)·T_h + S_h`.
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
  surface, so the reflection counts the reflected path's fog once.
- TAA history holds the fogged image. SSR, traced reflections and probe hits do not fog the
  surface-to-hit segment.

Pass order of a fogged raster view:

```
forward:   uploads, shadows, sky view, aerial perspective, [depth prepass], [ambient occlusion],
           [screen-space GI], forward opaque and sky, [scene snapshot, scene reads],
           [snapshot for blended readers], [SSGI colour copy], fog, [transparent], debug lines, post
deferred:  uploads, shadows, sky view, aerial perspective, depth prepass, G-buffer, [ambient occlusion],
           [screen-space GI], [reflections], lighting, forward opaque and sky, then as forward
```

The sky-view and aerial perspective tables record only when the scene has an atmosphere. The fog
pass samples depth at compute and rewrites `hdr_color` in place; the transparent pass reopens with
depth attached for testing.

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

## Exposure

The sky's radiance spans five orders of magnitude between noon and twilight, and c3d sets no
exposure: the application drives `Camera.exposure`. A table of sun elevations works well: exposure
proportional to 1 / (zenith sky luminance), interpolated in elevation on log₂ of the exposure. The
sky example's table, measured from its zenith luminance at sun intensity 3:

| Sun elevation | 60° | 30° | 10° | 5° | 2° | 0° | −2° | −4° |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `Camera.exposure` | 1 | 1.6 | 2.8 | 4 | 6.5 | 12 | 35 | 155 |

Below about intensity × 10⁻⁵ the sky sits in `RGBA16F`'s subnormal range, whose steps of 6 × 10⁻⁸
band after exposure. The table stops at −4°, above civil twilight, where the zenith leaves the normal
half-float range.

## Path tracing

A path-traced view lights with the atmosphere's cubes and shows its source cube as the background
(seen from `observer_altitude`, without the disc); the sun is attenuated at the path tracer's camera.
It has no fog and no aerial perspective. A sky or sun change does not restart accumulation, as no
light edit does: call `render::reset_view_history(&renderer, view)` when the time of day moves; the
sky example does under `--path-traced`.

## Limits

- One atmosphere per scene, lit from `observer_altitude`: a camera far above it sees a sky the
  lighting does not match.
- One fog medium per view, the first the view's layers see.
- Readers that write no depth take the fog of what is behind them; blended Physical transmission is
  one.
- Mirror views fog only behind their clip plane.
- SSR, traced reflections and probe hits do not fog the surface-to-hit segment.
- Opaque stages cannot opt out of the fog pass.
- Path-traced views are unfogged; a sky change does not restart their accumulation.
- Twilight bands below about intensity × 10⁻⁵; the example stops its exposure table at −4°.
- The sun's disc saturates at 60,000.
- Aerial perspective keeps one mean transmittance, covers 128 km and composes behind the height fog;
  a refracted segment through both media is approximate, and the refraction's bend is ignored for
  the fog distance.
- Screen-space GI gathers unfogged radiance without blended draws on fogged views.
- Memory: 418 KiB and two heap slots per raster view; about 0.6 MiB and 46 heap slots per atmosphere
  (0.85 MiB and 83 with sheen); four atmospheres at once.
- No clouds, no observers above the atmosphere, no volumetric fog or light shafts.

## Example

```bash
python3 scripts/build.py --example sky
```

`examples/sky` shows a 4 km ground with boxes and spheres from 10 to 800 m, a glass pane, a
transmissive sphere, a blended transmissive pane, a blended quad, a water pond (a scene reader) and a
planar mirror beside it. The panel sets the sun's elevation and azimuth, plays a time-lapse at 0.27° a
second, edits the fog, switches the exposure table and shows the sky's passes and stages and the
regeneration count; the presets noon, twilight, valley (300 m up, looking down into the fog) and
time-lapse pose the camera and the sun.

`--benchmark [frames]` renders offscreen at 2560 × 1440 through four segments (noon, twilight,
valley and a time-lapse four segments long, the sun rising 0.0045° a frame from 10°) and prints the
per-view passes, frame times, the refresh cost per stage, refreshes per minute and the CPU cost of
`sun_radiance`. Its gates: the time-lapse regenerates exactly `floor(sweep / period)` times, with
`period = (floor(0.5° / step) + 1) · step`, and the noon segment regenerates nothing after its first
frame. `--shading forward|deferred`, `--shadows atlas|traced`, `--ssgi`, `--path-traced`,
`--fog on|off`, `--atmosphere on|off`, `--preset`, `--gpu-timings` and `--validation` select the
configuration. See [benchmarking](benchmarking.md#sky-benchmark).

The landscape examples `terrain`, `vegetation` and `water` take `--sky`: an `ATMOSPHERE_EARTH` on
their sun and a haze pooling in the valleys.

## Measured cost

### WSL, llvmpipe

Environment only: a CPU rasterizer, not a GPU. `sky --benchmark 30 --width 256 --height 144
--gpu-timings`, forward, one run, medians in ms:

| Pass | Main view, noon |
| --- | --- |
| `SKY_VIEW` | 2.073 |
| `AERIAL_PERSPECTIVE` | 3.058 |
| `FOG` | 0.870 |
| `SKY` | 0.323 |

One refresh: `environment.sky` 4.93 ms, `environment.prefilter` 65.65 ms, `environment.irradiance`
1.29 ms, `ENVIRONMENT` total 71.84 ms. `sun_radiance` costs 0.78 µs.
