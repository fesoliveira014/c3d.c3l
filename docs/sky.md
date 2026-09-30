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
| `max_distance` | 200 | metres of view the [volumetric fog](#volumetric-fog) covers; the analytic fog continues past it |
| `anisotropy` | 0.3 | Henyey-Greenstein `g` of the volumetric fog's sun light, in (-1, 1) |

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
  atlas's cascades is unshadowed. Local lights are not scattered.
- The grid is one froxel per 16 × 16 pixels of the view's working image by 64 slices, squared toward the camera
  and ending at `max_distance`: 160 × 90 × 64 at 2560 × 1440. It is RGBA16F, 7.03 MiB at 2560 × 1440 and
  3.98 MiB at 1920 × 1080, one heap slot, allocated with the view and freed with it.
- Two compute passes record after the sky tables and before the fog pass: `FOG_SCATTERING` (one thread per froxel)
  and `FOG_INTEGRATION` (one thread per column, accumulating in-scatter and transmittance along the slices).
- Volume then analytic: inside `max_distance` a pixel takes the volume's in-scatter and transmittance; past it the
  analytic fog continues from the volume's end, so the fog is continuous there. The in-scatter's slope changes at
  `max_distance`, where the sun's shadowing stops.
- A view with a clip plane (a planar mirror) needs the switch of its own; its volume starts at the plane.
- Custom stages need no change: `fog_terms`, `fog_background_terms`, `apply_fog`, `fog_behind` and
  `apply_fog_refracted` include the volume when the view has one.
- The volume is recomputed every frame from one shadow sample per froxel and is not reprojected or jittered.
- The volume changes the haze's colour, not only its shadows. Inside `max_distance` the in-scatter is lit by the
  sun and the ambient, while the analytic fog takes the sky's colour, so the same fog looks brighter and warmer
  with the switch: the upper sky at noon at the default density goes from (31, 60, 100) to (76, 91, 117). Views of
  one scene with and without the switch show two haze colours.

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
half-float range. On an RTX 4090 the −4° sky shows no banding: a zenith-to-horizon column holds 270
distinct values over 430 rows, with no run longer than 5 rows and no step above 2 levels.

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
- Volumetric fog has no temporal reprojection or jitter, scatters only the sun, is unshadowed past the shadow
  atlas, changes its in-scatter slope at `max_distance` and does not exist on path-traced views.
- The analytic fog has no direct-sun phase term, so a view with volumetric fog and a view without it show
  different haze colours.
- No clouds, no observers above the atmosphere.

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

`--volumetric-fog` gives the main and mirror views a fog volume, `--taa` turns on TAA, and the `pan` preset and
segment sweep the camera's yaw 8° a second from −20° with the sun 15° up. The fog panel edits density, falloff,
anisotropy and `max_distance`. Under `--path-traced` the switch is ignored.

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

One refresh of the 64-texel sky cube (the time-lapse's 11 refreshes a run): `environment.sky` 0.015,
`environment.prefilter` 0.813, `environment.irradiance` 0.011, `ENVIRONMENT` total 0.840, max 0.862 (1.06
once in deferred). The prefilter is 97 % of it. At 0.27° a second the sky regenerates 30.0 times a
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

A refresh (0.84 ms) is far under the 4.2 ms at which refreshes would be time-sliced; a second view's
tables (0.035 ms) do not call for a per-view switch; the −4° twilight does not call for pre-exposure.

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

With the switch at noon: deferred 0.654, `--shadows traced` 0.487, `--taa` 0.707. The environment refresh stays
at 0.842 ms and `sun_radiance` at 0.90 µs. Sponza without fog: `cpu_record_ms` 0.1444 (0.1429 to 0.1638) before
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
