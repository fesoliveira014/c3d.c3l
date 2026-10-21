# Sky and atmosphere

An `Atmosphere` on the node of a directional `Light` turns that light into a sun seen through air. The renderer draws a
physically based sky with the sun's disc, attenuates the sun's light by the air it crosses, lights the scene from the
sky and adds aerial perspective to distant surfaces. The component lives in `c3d::light`; there is no feature flag.

[Height fog and medium volumes](fog.md) and [clouds](clouds.md) are separate components. Each works without the
others. [Sky, fog and cloud reference](sky_reference.md) holds the field tables, validity rules, constants and counters.

## Quick start

```c3
Light sunlight = light::directional({ 1, 1, 1 }, 3);
Node* sun = scene.add_light(sunlight, name: "sun")!;
sun.local.rotation = maths::look_rotation({ -0.3f, -0.8f, -0.5f }, { 0, 1, 0 });
scene.add(sun, light::ATMOSPHERE_EARTH);
scene.update_world();
```

`create_scene` registers the component. The renderer resolves it every frame, allocates what it needs once and draws it
in every raster view. Add a [`HeightFog`](fog.md) on any node for haze.

## Concepts

### One atmosphere per scene

The first `Atmosphere` in component order that is valid and whose node carries a directional `Light` wins. Every other
one, an invalid one and one without a directional light are ignored and counted in `Stats.atmospheres_ignored`.
Invalid components are data, not programming errors: they are ignored and never fault. Every view of the scene, its
probe volumes and the path tracer share the atmosphere.

The renderer keeps `render::ATMOSPHERE_CAPACITY` (4) atmospheres of different scenes at once. A fifth scene's
atmosphere renders as absent (no sky, no attenuation, the scene's own environment and background) and counts in
`Stats.atmospheres_dropped`. A slot unused for more than `FRAMES_IN_FLIGHT + 1` frames is reused.

### Units and the altitude datum

Everything is in metres, and world y = 0 is the planet's surface. A camera's altitude is its y plus the frame origin's y:
unbounded above, and zero below zero. `observer_altitude` stays in [0, atmosphere height). There is no datum field: a
world whose ground sits elsewhere moves its content, not the atmosphere.

A [frame origin](large_world.md) change alone neither regenerates the sky nor restarts a probe sweep, because it changes
packed coordinates and not physical altitude.

The drawn sky, the lighting, the fog's in-scatter and aerial perspective all scale with the sun's `color × intensity`,
so doubling the intensity doubles every sky pixel. Exposure is the application's `Camera.exposure`; see
[Exposure](#exposure).

### What the atmosphere replaces

While an atmosphere resolves it replaces the scene's lighting and background. `scene.environment`, `scene.background`
(its kind, intensity and rotation) and `scene.environment_rotation` do not apply. `scene.environment_intensity` scales
the sky's lighting as it scales any environment. The ambient term follows the environment rule: zero unless
`scene.ambient_add`. See [environments](environments.md).

## Usage

### The sun

Every light extraction (views, probe updates and the path tracer) attenuates the atmosphere's sun, and only it. The
renderer packs `sun_radiance` at the extracting camera's altitude as the light colour; probe updates use
`observer_altitude`. Other directional lights pass unchanged.

A sun whose radiance is exactly zero, below the horizon, packs no light and requests no shadow layer. The sun's disc is
drawn in the background only, never in the lighting, and saturates at a luminance of 60,000 (an intensity above about
4.1).

### Above the atmosphere

A camera's altitude is not clamped. A ray from above the atmosphere's top starts where it enters the shell, the near
root against the sphere of radius `planet_radius + atmosphere_height`. A ray that misses the shell sees space, with
transmittance 1 and no in-scatter. At or below the top the entry is the ray's origin.

- **Sky.** The per-view sky-view table keeps its mapping about the planet's horizon at the camera's altitude and
  integrates from the entry. Below the horizon it shows the planet's ground, lit and shaded with `ground_albedo`. The
  scene's geometry is the application's and does not curve.
- **Sun.** `sun_radiance` follows each view's camera altitude. A sun ray that misses the shell is unattenuated, one that
  meets the planet is zero, and the disc is absent behind the planet.
- **Aerial perspective.** Each pixel's slices count from the distance at which its ray enters the shell, so the volume
  covers 128 km from the entry. Geometry beyond that range reads the far slice. A ray that misses the shell reads no
  aerial perspective.
- **Traced hits.** A segment's air starts at its ray's entry. A hit that lies before the entry takes none.
- **Lighting.** The camera's altitude keys no table and no cube, so rising through the top regenerates nothing. The
  cubes and SH, the path tracer's background and the probe update's sun stay at `observer_altitude`. A camera above the
  atmosphere, or far from the observer, sees a sky they do not match.

### Time of day and regeneration

Each atmosphere owns a transmittance table, a multiple-scattering table and a 64-texel source cube with its GGX cube,
SH and, on first sheen use, a Charlie cube. The cubes are the sky seen from `observer_altitude` with the sun's colour at
unit intensity and no disc. The sun's intensity scales them as the environment intensity. They light the scene through
the ordinary environment path: image-based lighting, reflections that miss, probe volumes filled from the environment
and the path tracer.

The lighting regenerates in place when, compared with the last generation:

- the sun has turned by more than `render::SKY_REGENERATION_SUN_ANGLE` (0.0087 rad, 0.5°);
- `observer_altitude` has moved by more than `render::SKY_REGENERATION_ALTITUDE` (500 m);
- the sun's colour changed;
- any air field changed (the tables regenerate too).

A slow drift accumulates against the last generation, so a slowly moving sun regenerates on the first frame past 0.5°.
An intensity change regenerates nothing. A regeneration writes the cubes and SH in place, advances the lighting
revision so that probe volumes filled from the environment refill, and counts in `Stats.sky_regenerations`. The first
generation happens in `prepare_scene` or in the first view that sees the atmosphere.

Each raster view also owns a 192 × 108 sky-view table and a 32³ aerial perspective volume, recomputed every frame the
view renders an atmosphere. A view allocates them with its other working images whether or not its scene has an
atmosphere. See [memory](sky_reference.md#memory) and [passes](sky_reference.md#passes).

### Exposure

The sky's radiance spans five orders of magnitude between noon and twilight, and c3d sets no exposure: the application
drives `Camera.exposure`. A table of sun elevations works well: exposure proportional to 1 / (zenith sky luminance),
interpolated in elevation on log₂ of the exposure. The sky example uses this table, measured from its zenith luminance
at sun intensity 3:

| Sun elevation | 60° | 30° | 10° | 5° | 2° | 0° | −2° | −4° | −6° | −8° |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `Camera.exposure` | 1 | 1.6 | 2.8 | 4 | 6.5 | 12 | 35 | 155 | 2050 | 13500 |

[Auto exposure](post.md#auto-exposure) replaces the table; the main view then adapts to the sky. Every view stores its
sky and its lighting multiplied by a power of two near its exposure, and post divides it out; see
[pre-exposure](post.md#pre-exposure). Two clamps are specific to the sky:

- The sun's disc is limited to 60,000 on physical radiance first, then scaled. The brightest disc the half-float target
  can hold shrinks as the pre-exposure factor grows, so a disc dimmed by fog can clip at high factors, and a clipped
  disc also weakens its bloom.
- Sky pixels and the sky tables' texels saturate at 65,504 instead of becoming infinite.

### Path tracing

A path-traced view lights with the atmosphere's cubes and shows its source cube as the background, seen from
`observer_altitude` and without the disc. The sun is attenuated at the path tracer's camera. The view has no fog, no
aerial perspective and no clouds. A sky or sun change does not restart accumulation, as no light edit does: call
`render::reset_view_history(&renderer, view)` when the time of day moves. See [path tracing](path_tracing.md).

## Example

```bash
python3 scripts/build.py --example sky
```

`examples/sky` shows a 4 km ground with boxes and spheres from 10 to 800 m, glass and transmissive panes, a water pond
and a planar mirror. Its panel sets the sun's elevation and azimuth, plays a time-lapse, edits the fog and the clouds,
switches the exposure table and shows the sky's passes and the regeneration count. The presets pose the camera and the
sun. The options are listed in the [examples](../examples/README.md#sky-post-processing-and-effects); the benchmark and its
output are in [benchmarking](benchmarking.md#sky-benchmark).

The `orbit` preset puts the camera 400 km up, pitched 10° down, with the sun 12° up. Above 50 km the example gives the
camera a 1,000 km far plane, sets `FrameInfo.reference_position` to it and uses an exposure of 1, because the exposure
table describes a sun over an observer on the surface.

The landscape examples `terrain`, `vegetation` and `water` take `--sky`: an `ATMOSPHERE_EARTH` on their sun and a haze
pooling in the valleys, and `--volumetric-fog` with it.

## Limits

- One atmosphere per scene, lit from `observer_altitude`: the lighting, the path tracer's background and the probe
  update's sun do not follow a camera above the atmosphere or far from the observer.
- Above the atmosphere the limb is as sharp as the 192 × 108 sky-view table: its edge blurs over about one texel.
- Twilight precision is bounded by `RGBA16F`: the tables keep a half float's 11-bit significand, and the transmittance
  table holds physical values, some of which are subnormal on the grazing paths of deep twilight.
- The sun's disc saturates at a luminance of 60,000.
- Aerial perspective keeps one mean transmittance, covers 128 km (from the shell above it) and composes behind the
  height fog. A refracted segment through both media is approximate, and the refraction's bend is ignored for the fog
  distance.
- Each raster view allocates 418 KiB for the sky tables, and each atmosphere about 0.6 MiB; four atmospheres fit at once.

## See also

- [Fog and medium volumes](fog.md) for the fog pass, volumetric fog and `fog.glsl`
- [Clouds](clouds.md)
- [Sky, fog and cloud reference](sky_reference.md)
- [Environments](environments.md), [post](post.md), [path tracing](path_tracing.md), [shadows](shadows.md)
