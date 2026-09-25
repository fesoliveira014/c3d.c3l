# Path tracing

A view with `shading = PATH_TRACED` renders a progressive, unbiased reference image with one
ray-tracing pipeline dispatch per frame. It accumulates while the camera and scene stay still and
feeds the ordinary display route, so tone mapping, exposure, bloom, grading and FXAA apply as on
any view.

```c3
Renderer renderer = render::create_renderer(mem, &assets, { .ray_tracing_pipelines = true })!;

ViewDesc desc = render::texture_view_desc(still, OutputMode.DISPLAY_LDR);
desc.shading = ShadingPath.PATH_TRACED;
desc.post.anti_aliasing = AntiAliasing.NONE;
desc.path_trace = { .max_bounces = 6, .samples_per_frame = 4, .max_samples = 1024 };
ViewId view = render::create_view(&renderer, desc)!;
```

## Enabling

`RendererDesc.ray_tracing_pipelines` requests ray-tracing pipelines and implies ray queries: the
renderer asks the device for both, and adapter selection keeps only adapters with both, otherwise
`create_renderer` faults `c3d::UNSUPPORTED`. The path tracer traces bounce rays through the
pipeline and shadow rays through ray queries.

## Settings

`ViewDesc.path_trace` is read only when `shading == PATH_TRACED`:

| Field | Meaning |
| --- | --- |
| `max_bounces` | Bounces per path, `[1, PATH_TRACE_BOUNCES_MAX]` (16); 1 is direct light only |
| `samples_per_frame` | Samples each frame folds into the image, `[1, PATH_TRACE_SAMPLES_PER_FRAME_MAX]` (16) |
| `max_samples` | Samples after which the view stops tracing and keeps showing the image; 0 is unlimited |

Both view constructors set `PATH_TRACE_DEFAULT` (6 bounces, 1 sample per frame, no cap).
`create_view` and `configure_view` fault `c3d::UNSUPPORTED` for a path-traced view on a renderer
without ray-tracing pipelines, and `c3d::INVALID_ARGUMENT` for a range violation or for a setting a
path-traced view cannot honour: TAA, motion blur, depth of field, ambient occlusion, ray-traced
shadows or `CLUSTERED` lights. Ray-traced reflections fault `UNSUPPORTED` (they need a deferred
view). `depth_prepass` is ignored. The view has no depth image, so debug lines are not drawn on it.

## Accumulation and resets

The view owns an RGBA32F accumulation image holding the running mean; the displayed mean is also
written to `hdr_color`. The image restarts automatically when:

- the camera's view-projection changes (orbit, zoom, projection);
- the scene changes (`Scene.identity`);
- any traced record changes: a node moves, a mesh appears or disappears, its visibility or
  material assignment changes, or its geometry is edited.

Material factor, light and environment edits do not restart it. Call
`render::reset_view_history(&renderer, view)` after such an edit. `configure_view` and a resize
also restart it. `Renderer.view_stats(view).accumulated_samples` reports the samples in the image;
`Stats.path_trace_samples` counts the samples traced in the frame.

## What the integrator models

- **Materials.** Standard, and Physical through its Standard prefix, scatter with Lambert plus
  GGX; Toon scatters as Lambert over its colour and Custom as Lambert over neutral grey. Basic is
  unlit in raster and acts as an emitter here: a path that hits it gains its colour and ends.
  Emission, base colour, metallic-roughness and normal maps are read at every hit; alpha-masked
  surfaces are tested in the any-hit stage.
- **Lights.** Every punctual light in the scene, up to the renderer's `max_lights`, is sampled at
  every bounce with a shadow ray (next-event estimation), whether or not it lies in the camera
  frustum. A light with shadows
  disabled is unoccluded, and a mesh with `cast_shadow` off does not block light, as in raster.
- **Emitters and the environment** are reached by bounce rays only. A camera ray that misses shows
  the scene background; a bounce ray that misses reads the lighting environment, or the ambient
  colour without one.
- **Sampling.** Pixel positions follow a Halton sequence; the lobe choice and bounce directions use
  a hash of pixel, sample and bounce, so a frame of four samples equals four frames of one.
  Russian roulette may end a path after three bounces. A NaN or infinite sample counts as black.

## Reading the image back

For a still, render into an `RGBA8_SRGB` target through `DISPLAY_LDR`, render frames until
`accumulated_samples` reaches the count, then read the target and write a PNG:

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

The display route writes linear values and relies on an sRGB format to encode them, so an
`RGBA8_UNORM` target would write a dark PNG. See [reading a target back](views.md#reading-a-target-back).

## Pass and statistics

The trace records under `Pass.PATH_TRACE`; the benchmarks report it as `gpu_path_trace_ms`
(`--shading path-traced`). The targets panel offers a "Path traced" shading choice and a reset
button, and the post panel's "Path tracing" header edits bounces, samples per frame and the cap.

## Limits

- No emitter or environment importance sampling and no multiple importance sampling: small bright
  emitters and bright environment texels converge slowly and show as isolated bright pixels at low
  sample counts. No denoiser.
- Physical lobes beyond the Standard prefix (clearcoat, sheen, specular, anisotropy, transmission)
  are not sampled; `BLEND` surfaces, skinned and morphed meshes are not traced; custom shader code
  does not run at hits.
- Light layers and camera layers are not applied.
- The back of a single-sided surface renders black where raster culls it and shows what lies
  behind it.

## Example

`examples/path_tracer` renders a Cornell-style room with a metal sphere, a rough dielectric sphere,
an emissive ceiling panel, a point light and the studio environment through the open front. Drag
to orbit (accumulation restarts), `Space` toggles the lamp and resets.
`--headless --samples N --out still.png [--width W --height H]` renders a still without a window
and prints samples per second.

```bash
python3 scripts/build.py --example path_tracer
./examples/build/path_tracer --headless --samples 1024 --out still.png
```

`examples/gltf_viewer model.gltf` offers the same "Path traced" choice in its targets panel when the
adapter has ray-tracing pipelines, for example on Sponza after `python3 scripts/fetch_benchmark_assets.py`:
`./examples/build/gltf_viewer examples/assets/benchmark/sponza/glTF/Sponza.gltf`. The spinning instance
holds still while the view is path traced, because any movement restarts accumulation.
