# Path tracing

A view with `shading = PATH_TRACED` renders a progressive, unbiased reference image with one ray-tracing pipeline dispatch
per frame. It accumulates while the camera and scene stay still and feeds the ordinary display route, so tone mapping,
exposure, bloom, grading and FXAA apply as on any view. The settings are `ViewDesc.path_trace`, a `PathTraceDesc` in
`c3d::render`. The renderer needs `RendererDesc.ray_tracing_pipelines`.

## Quick start

```c3
Renderer renderer = render::create_renderer(mem, &assets, { .ray_tracing_pipelines = true })!;

RenderTargetId still = render::create_render_target(
    &renderer,
    render::render_target_desc(1280, 720, PixelFormat.RGBA8_SRGB),
)!;
ViewDesc desc = render::texture_view_desc(still, OutputMode.DISPLAY_LDR);
desc.shading = ShadingPath.PATH_TRACED;
desc.post.anti_aliasing = AntiAliasing.NONE;
desc.path_trace = { .max_bounces = 6, .samples_per_frame = 4, .max_samples = 1024 };
ViewId view = render::create_view(&renderer, desc)!;
```

Path-traced views use the shared [frame origin](large_world.md). An origin change resets accumulation even when the absolute
scene and camera are unchanged. Supply `FrameInfo.reference_position` near the camera; the 256 m cell avoids resetting
accumulation for every small reference movement.

## Concepts

### Enabling

`RendererDesc.ray_tracing_pipelines` requests ray-tracing pipelines and implies ray queries. The renderer asks the device
for both, and adapter selection keeps only adapters with both. Otherwise `create_renderer` faults `c3d::UNSUPPORTED`. The path
tracer traces bounce rays through the pipeline and shadow rays through ray queries. It always traces hardware data; see
[software and hardware kinds](scene_trace.md#software-and-hardware-kinds).

### Accumulation and resets

The view owns an `RGBA32_FLOAT` accumulation image holding the running mean. The displayed mean is also written to
`hdr_color`. The image restarts automatically when:

- the camera's view-projection changes (orbit, zoom, projection);
- the scene changes (`Scene.identity`);
- any traced record changes: a node moves, a mesh appears or disappears, its visibility or material assignment changes, or
  its geometry is edited;
- the frame origin changes.

Material factor, light, environment and sky edits do not restart it: a moving sun under an [atmosphere](sky.md#path-tracing)
keeps its old samples. Call `render::reset_view_history(&renderer, view)` after such an edit. A material, texture or
environment replacement behaves like an edit: call it after the replacement. `configure_view` and a resize also restart
accumulation.

`Renderer.view_stats(view).accumulated_samples` reports the samples in the image, and `Stats.path_trace_samples` counts the
samples traced in the frame.

Accumulation resets leave [auto exposure](post.md#auto-exposure) alone; `reset_view_history` restarts both, so after a light
or sky edit the exposure snaps to the next 1-spp image. Once the camera stops, exposure drifts to the converged value at the
adaptation rate. A headless still at constant time snaps on every rendering and ends on the target of its last image.

### What the integrator models

- **Materials.** Standard, and Physical through its Standard prefix, scatter with Lambert plus GGX. Toon scatters as Lambert
  over its color, without its outline hull, and Custom as Lambert over neutral grey. Basic is unlit in raster and acts as an
  emitter here: a path that hits it gains its color and ends. Emission, base color, metallic-roughness and normal maps are
  read at every hit; alpha-masked surfaces are tested in the any-hit stage.
- **Lights.** The scene's punctual lights, up to the renderer's `max_lights`, form a no-frustum list. At every bounce its
  [spatial lookup](lights.md#spatial-light-lookup) selects finite-range candidates and all global lights for next-event
  estimation. A contributing light is sampled with a shadow ray; a light with a source extent takes one point of its source
  for each ray. A light with shadows disabled is unoccluded, and a mesh with `cast_shadow` off does not block light, as in
  raster. Light nodes are gated by the camera's `layers`, and a light skips a hit whose node `layers` do not intersect
  `Light.layers` (the [receiver mask](lights.md#concepts)); emission is unmasked. Camera layers do not hide geometry from the
  trace.
- **Emitters and the environment** are reached by bounce rays only. A camera ray that misses shows the scene background. A
  bounce ray that misses reads the lighting environment, or the ambient color without one. An [atmosphere](sky.md) lights the
  view through its cubes and shows its source cube as the background, without the sun's disc.
- **Faces.** Camera and bounce rays pass the back of a single-sided surface, as raster culls it, and shadow rays keep the
  faces the light sees ([facing](scene_trace.md#facing)).
- **Sampling.** Pixel positions follow a Halton sequence. Lobe choice and bounce directions hash the pixel, sample and
  bounce, so a frame of four samples equals four frames of one. Russian roulette may end a path after three bounces. A NaN or
  infinite sample counts as black.
- **Geometry.** Paths hit what [the scene trace contains](scene_trace.md#what-traces). Custom shader code does not run at
  hits.

## Configure the view

`ViewDesc.path_trace` is read only when `shading == PATH_TRACED`. Both view constructors set `PATH_TRACE_DEFAULT` (6 bounces,
1 sample per frame, no cap).

| Field | Meaning |
| --- | --- |
| `max_bounces` | Bounces per path, `[1, PATH_TRACE_BOUNCES_MAX]` (16); 1 is direct light only |
| `samples_per_frame` | Samples each frame folds into the image, `[1, PATH_TRACE_SAMPLES_PER_FRAME_MAX]` (16) |
| `max_samples` | Samples after which the view stops tracing and keeps showing the image; 0 is unlimited |

`create_view` and `configure_view` fault:

| Fault | Cause |
| --- | --- |
| `c3d::UNSUPPORTED` | A path-traced view on a renderer without ray-tracing pipelines |
| `c3d::UNSUPPORTED` | `ray_tracing.reflections` set on a path-traced view |
| `c3d::INVALID_ARGUMENT` | `max_bounces` or `samples_per_frame` outside its range |
| `c3d::INVALID_ARGUMENT` | TAA, motion blur, depth of field, ambient occlusion, screen-space GI, `ray_tracing.shadows` or `CLUSTERED` lights |
| `c3d::INVALID_ARGUMENT` | A non-zero `clip_plane` or `volumetric_fog` |
| `c3d::INVALID_ARGUMENT` | `msaa` above `ONE` |

`depth_prepass` is ignored. The view has no depth image, so debug lines are not drawn on it. FXAA and the rest of the display
stage work as usual.

## Read the image back

For a still, render into an `RGBA8_SRGB` target through `DISPLAY_LDR`, render frames until `accumulated_samples` reaches the
count, then read the target and write a PNG:

```c3
while (renderer.view_stats(view)!.accumulated_samples < samples) {
    renderer.begin_frame()!;
    renderer.render_view(&scene, camera_node, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
}
char[] pixels = mem::new_array(char, width * height * 4);
defer free(pixels);
renderer.read_render_target(still, pixels)!;
image::write_png(
    path:   "still.png",
    width:  width,
    height: height,
    pixels: pixels,
)!;
```

The display route writes linear values and relies on an sRGB format to encode them, so an `RGBA8_UNORM` target would write
a dark PNG. See [read a target back](views.md#read-a-target-back).

## Statistics and tools

The trace records under `Pass.PATH_TRACE`. The benchmarks report it as `gpu_path_trace_ms` (`--shading path-traced`). The
targets panel offers a "Path traced" shading choice and a reset button, and the post panel's "Path tracing" header edits
bounces, samples per frame and the cap.

Run `python3 scripts/build.py --example path_tracer` for a Cornell-style room. Drag to orbit (accumulation restarts) and
press `Space` to toggle the lamp. `--headless --samples N --out still.png [--width W --height H]` renders a still without a
window. `gltf_viewer` offers the same "Path traced" choice in its targets panel when the adapter has ray-tracing pipelines.

## Limits

- No emitter or environment importance sampling and no multiple importance sampling: small bright emitters and bright
  environment texels converge slowly and show as isolated bright pixels at low sample counts. No denoiser.
- Physical lobes beyond the Standard prefix (clearcoat, sheen, specular, anisotropy, transmission) are not sampled.
- Path-traced views have no fog, no aerial perspective and no clouds.
- The sun's disc is not drawn in the background.
- Any movement restarts accumulation.

## See also

- [Scene tracing](scene_trace.md) for what the trace contains.
- [Views](views.md) and [views reference](views_reference.md#faults) for views and their faults.
- [Sky](sky.md#path-tracing) for atmosphere handling.
- [Lighting techniques](lighting_techniques.md) for choosing between effects.
- [Post](post.md) for display processing.
