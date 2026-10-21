# Clouds

A `CloudLayer` on any node adds a raymarched deck of clouds between two altitudes. The application owns the weather: it
supplies the coverage map, places the layer and advances its wind. The renderer owns the noise and the lighting. The
layer works with or without an [atmosphere](sky.md). It lives in `c3d::light`; there is no feature flag. Field tables
and validity rules are in the [reference](sky_reference.md#cloudlayer).

## Quick start

```c3
import c3d;
import c3d::light;
import c3d::material;
import c3d::scene;

char[256 * 256 * 4] pixels;
// Fill R with the coverage and G with the share of the layer a cloud fills.
TextureDesc weather_desc = material::texture_2d_desc(
    width:      256,
    height:     256,
    format:     RGBA8_UNORM,
    debug_name: "weather",
);
TextureId weather = assets.add_texture(weather_desc, pixels[..])!;

CloudLayer layer = light::CLOUD_LAYER_DEFAULT;
layer.coverage = weather;
Node* clouds = scene.add_node(name: "clouds")!;
scene.add(clouds, layer);

// Every frame: the application advances the wind.
scene.get(clouds, CloudLayer).wind_offset.x += wind_speed * delta;
```

`create_scene` registers the component. The renderer draws the layer in every raster view whose camera sees its node.
Mirror and clip-plane views include it, and the plane does not clip it. Reflection captures and path-traced views draw no
clouds.

## Concepts

- **One layer per view.** The first valid `CloudLayer` whose node is visible and shares a layer with the view's camera
  wins. Later and invalid ones the view sees count in `Stats.clouds_ignored`. Invalid layers are ignored and never
  fault.
- **Weather map.** `coverage` is a 2D texture: R is the coverage, G the share of the layer a cloud fills. Unset is full
  cover. Replace the texture's pixels with `AssetStore.replace_texture` to change the weather; the renderer caches
  nothing about it, so edits show on the next frame. A dangling `coverage` counts in `Stats.dangling_refs` and the view
  draws no clouds. A cube, array, 3D or `R16_UINT` map faults `c3d::UNSUPPORTED` in `prepare_scene`, which checks every valid layer without a
  visibility test, and when a view draws the layer.
- **Wind.** The map and the noise slide with `wind_offset`: a feature at `p` sits at `p + wind_offset`. The application
  advances it.
- **Noise.** The renderer owns one 128³ `RGBA8` volume that repeats on every axis. A compute pass generates it once, the
  first time `prepare_scene` or a frame sees a valid `CloudLayer`, so an application without clouds pays nothing and the
  first frame of one that prepares its scene does not hitch. It is never rebuilt.
- **Geometry.** With an atmosphere the layer is the shell between `bottom` and `top` above the planet; without one it is
  the slab between two planes. A ray marches from where it enters the layer, at most 60 km of it, and stops at the
  scene depth. A ray that meets the planet before the layer sees none. The march takes `shader::CLOUD_STEPS` (64)
  steps at half resolution, each jittered, and stops early once its transmittance is under 2 %.
- **Lighting.** The sun is the atmosphere's sun or, without one, the scene's first directional light. The ambient is the
  atmosphere's sky at the zenith times the sun's illuminance, or the scene's ambient. Both come from the view, so
  [pre-exposure](post.md#pre-exposure) applies. The march shadows the deck itself with multiple scattering over
  `shader::CLOUD_LIGHT_STEPS` (6) samples toward the sun. The scene's shadow is the [cloud shadow map](#cloud-shadows).
- **Composition.** `Pass.CLOUDS` follows the forward or deferred pass and its sky, so the scene readers' snapshots hold
  the clouds. It marches the half-resolution target, then composites it into `hdr_color` with a depth-aware upsample.
  The aerial perspective is carried to the cloud's distance. The fog pass then applies the height fog to the
  composite, so the order is cloud, aerial perspective, height fog. A view with a cloud layer splits its blended draws
  after the pass, as a fogged view does.

## Cloud shadows

A layer with `cast_shadows` multiplies the sun's visibility by the transmittance the layer lets through. `Pass.CLOUD_SHADOWS`
writes one map per view every frame, before the fog volume and the forward or deferred pass, from the layer as it is
that frame, so wind and weather edits show at once. A view with no layer, or whose layer has `cast_shadows` false,
records no pass and allocates no map. A bare `CloudLayer{}` casts none; `CLOUD_LAYER_DEFAULT` does.

- **Map.** `shader::CLOUD_SHADOW_SIZE` (512) texels of `R16F` cover `shader::CLOUD_SHADOW_EXTENT` (16,384 m) of the
  layer's bottom plane: 32 m a texel. The extent is the lever for reach against sharpness. The layer is taken as flat
  over the map, also under an atmosphere.
- **Placement.** The map is centred on the camera's footprint along the sun and snapped to the world's 32 m grid, so the
  content stays where it is in the world while the camera moves. The ground under a camera between the datum and the
  layer's bottom sits off the centre by `altitude · |sun.xz| / max(sun_up, 0.1)`, and beyond the map's half extent for a
  low enough sun. At or above the bottom, and below the datum, the ground under the camera sits at the centre.
- **Light.** The sun is the one the cloud march uses. No map exists while the sun is at or below the horizon, and the
  sun's visibility is then unchanged.
- **Receivers.** The sun's packed light carries `LIGHT_CLOUD_SHADOW`, and `FrameRoot.cloud_shadow` addresses the
  `CloudShadowRoot`; it is zero without a map. `shadow_visibility` and `shadow_transmittance` multiply that light's
  visibility, so forward Standard, Physical and Toon, the deferred lighting resolve, the volumetric fog's sun term and
  custom stages that call them receive it, as does a sun with traced shadows. `light_casts_shadow` is true for the
  flagged light even when it has no shadow layers, so a custom stage may gate its shadow call on it. A draw that does not
  receive shadows receives none. The volumetric fog's froxels take it too, so gaps between clouds light shafts.
- **Projection.** A receiver at altitude `y` goes along the sun to the bottom plane and reads the map there. A receiver
  inside the layer reads the transmittance raised to the share of the layer above it. A receiver above the layer gets 1.
- **Edge.** Outside the map the transmittance is 1. It fades to 1 over the outer 10 % of the map's half extent, so the
  border never shows as a seam.
- **Fog history.** The map's motion is not part of the temporal fog history's rejection key, so wind and camera motion
  do not reset it.
- **Not shadowed.** The path tracer, traced reflection and probe-update hits, and the atmosphere's lighting cubes do not
  see the map, as they do not see the clouds. Reflection captures render without clouds and so without their shadow.

## Cloud temporal accumulation

`ViewDesc.cloud_temporal` accumulates the layer over frames, so the jitter of one frame's march averages out. The switch
is per view, as `fog_temporal` is: the history lives in the view's own images, and a mirror and the main view differ in
size and camera. A view without it runs the plain march.

- **Jitter.** Each submitted march advances the view through a cycle of 16 jitter points. One moves each pixel's march
  start within its first step, and two move the ray within its half-resolution pixel by up to half a pixel each way. An
  orthographic view takes neither offset nor history.
- **Reprojection.** A pixel is traced back from the cloud's opacity-weighted distance, moved back by the wind the layer
  drifted since the previous frame, and read from the previous frame's images. A pixel whose previous position lies
  outside the previous frustum takes no history. Camera motion and wind reproject and do not reject.
- **Blend.** The history's radiance and transmittance are clamped, per channel, to the range of this frame's values over
  the pixel's 3 × 3 neighbours, then blended with `shader::CLOUD_HISTORY_WEIGHT` (0.9), a memory of about ten frames.
  History the neighbours no longer support, such as a cloud the wind moved on or a weather map that was edited, goes to
  their range at once. An exposure change rescales the history instead of rejecting it.
- **Rejection.** The history of a view is dropped, and the next frame marches without it, when:
  - `render::reset_view_history` ran, the view was created or configured (a resize reallocates the images), the switch
    was turned on, or the scene changed;
  - any `CloudLayer` field except `wind_offset` changed, the atmosphere's planet radius changed, or the frame origin
    changed;
  - the sun's direction moved more than 0.1° since the previous frame.

  The sun's colour and intensity, the ambient light and the contents of the weather map are not triggers; they converge
  through the blend. A layer that changes every frame, or a sun turning faster than the threshold, gets no convergence.
- **Aborted frames.** An aborted frame neither swaps nor commits the history. A view that was not rendered, or drew no
  layer, in a submitted frame starts again without history, and a second recording in one frame takes none.
- **Cost.** The memory doubles. The march adds the reprojection, the filtered read of the history and a fetch of its
  distance per pixel, and a one-pixel border march per 16 × 16 group (about 1.27 times the marches) on frames that take
  history.
- **Orbit.** From orbit a pixel spans kilometres of the deck, more than the size of its features, so one ray per pixel
  point-samples them and the whole disc shows the aliasing as speckle that is the same every frame. The offset within
  the pixel averages it, so a still camera's disc settles within about ten frames. A camera or a sun that moves faster
  than the history converges shows the plain march's speckle.

## Costs

- Per view, `12 · ceil(w / 2) · ceil(h / 2)` bytes: a half-resolution `RGBA16F` target (8 B, scattered radiance and
  transmittance) and an `R32F` target (4 B, the distance). The view allocates them the first frame it draws a layer and
  keeps them until the view is destroyed or its working size changes. The renderer adds one 8 MiB noise volume.
- The shadow map adds `CLOUD_SHADOW_SIZE² × 2` bytes per view (512 KiB), allocated the first frame the view casts the
  shadow and kept until the view is destroyed or its images are reallocated.
- The march costs `CLOUD_STEPS` samples per half-resolution pixel and `CLOUD_LIGHT_STEPS` light samples per step.

## Limits

- One deck per view. The march covers at most 60 km of the deck from its entry.
- The path tracer, traced reflection and probe hits and misses, and the atmosphere's lighting cubes do not see clouds or
  their shadow. An overcast sky still lights the scene, its reflections and its probes as a clear one.
- Clouds write no depth and the transparent pass draws after them. A blended surface farther than a cloud draws over it,
  and so does a scene reader, which draws after the composite and tests against the scene's depth alone. At cloud
  altitudes the case is rare.
- The height fog covers the composite as it covers any pixel: over the sky it takes the fog to infinity, so a camera
  above the fog layer looking down sees the fog in front of the clouds below it.
- Without `cloud_temporal` one ray per pixel point-samples the deck and shows as grain, most where a pixel's footprint
  spans many features. From orbit that is the whole disc, because each pixel covers many repeats of the coverage map and
  the noise.
- The cloud shadow map treats the layer as flat over its extent.

## See also

- [Sky and atmosphere](sky.md), [fog and medium volumes](fog.md)
- [Sky, fog and cloud reference](sky_reference.md)
- [Views](views.md) for `ViewDesc.cloud_temporal`
