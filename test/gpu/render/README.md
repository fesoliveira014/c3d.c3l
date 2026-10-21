# Render acceptance

Manual acceptance tests for the renderer on a real Vulkan device. They cover frame submission, shadows, lights,
instancing and level of detail, probes and reflections, tracing, textures, custom shaders, sky and large worlds. The
tests are their own documentation: each file's `@test` functions name what they check. The project does not run under
`python3 scripts/build.py --test` or in CI, because it needs a device.

## Run

Build the repository once so `shaders/spv/` and the generated tables exist, then build and run the project:

```bash
python3 scripts/build.py --target compute_textures
c3c test acceptance --path test/gpu/render --suppress-run   # build only
cp lib/shaderc.c3l/linux/libshaderc_shared.so.1 build/render_acceptance/
c3c test acceptance --path test/gpu/render
```

- The executable is `build/render_acceptance/testrun`. The project compiles shaders in process (`C3D_SHADER_COMPILER`),
  so the shaderc shared library must sit beside it: `libshaderc_shared.so.1` from `lib/shaderc.c3l/linux/` on Linux, or
  `shaderc_shared.dll` from `lib/shaderc.c3l/windows/` on Windows. `build.py` copies runtimes into the example build
  directories and `build/profile_gpu`, not into this project's output.
- `--test-filter <name>` runs one test. When you start `testrun` by hand, start it from `test/gpu/render`: some tests
  open `../../../examples/...` relative to it.
- Headless and WSL runs need a software Vulkan driver and a few environment variables; see
  [Headless and WSL runs](../../../docs/development.md#headless-and-wsl-runs).

## Harness

- Every fixture creates a renderer with Vulkan validation enabled. Tests read the debug log and fail on a backend
  validation error.
- A test whose assertion fails skips its `defer destroy_fixture`. The harness records the live fixture and, when the
  test ends, prints which function created it and destroys it, so the next test starts without a leaked runtime. If the
  test also holds device allocations only it can free, the harness prints that the runtime is still alive.
- `selection_probe.vert.glsl` stores from the vertex stage through a device address, without
  `vertexPipelineStoresAndAtomics`, which the library does not enable. Library shaders must not use that pattern.
- A test that needs a capability the machine lacks prints a `skipped` or `SKIP` line instead of failing: a window, ray
  queries, ray-tracing pipelines or block-compressed sampling.

## Coverage

| Area | Files |
| --- | --- |
| Frame submission, preparation, capacities | `test_submission.c3`, `test_prepare.c3`, `test_prepare_assets.c3`, `test_prepare_pipelines.c3`, `test_prepare_textures.c3`, `test_post_tiles.c3`, `test_capacities.c3`, `test_resize_faults.c3`, `test_asset_replace.c3` |
| Lights, shadows, exposure | `test_light_spatial.c3`, `test_cascade_blend.c3`, `test_shadow_bias.c3`, `test_shadow_sets.c3`, `test_colored_shadows.c3`, `test_decals.c3`, `test_msaa_edges.c3`, `test_manual_exposure.c3`, `test_auto_exposure.c3` |
| Instancing, level of detail, billboards, ribbons | `test_instance_cull.c3`, `test_device_instances.c3`, `test_instance_sort.c3`, `test_instance_effects.c3`, `test_crowd_variants.c3`, `test_lod.c3`, `test_quadtree.c3`, `test_impostor.c3`, `test_billboards.c3`, `test_ribbons.c3` |
| Probes and reflections | `test_probe_volume.c3`, `test_probe_update.c3`, `test_probe_classification.c3`, `test_probe_classification_lifetime.c3`, `test_probe_sampling.c3`, `test_reflection_probe.c3`, `test_reflection_capture.c3` |
| Tracing and traced effects | `test_scene_trace.c3`, `test_ray_tracing.c3`, `test_ray_traced_effects.c3`, `test_ambient_occlusion.c3`, `test_screen_space_gi.c3`, `test_path_tracing.c3`, `test_posed_trace.c3`, `test_custom_trace_pose.c3` |
| Materials and custom shaders | `test_custom_shading.c3`, `test_custom_velocity.c3`, `test_vertex_motion.c3`, `test_vertex_fetch.c3`, `test_geometry_write.c3`, `test_clip_plane.c3`, `test_published_stages.c3`, `test_material_references.c3`, `test_material_blend.c3`, `test_weighted_blend.c3`, `test_scene_reads.c3`, `test_view_textures.c3` |
| Textures | `test_r16_texture.c3`, `test_texture_containers.c3`, `test_texture_residency.c3`, `test_texture_fidelity.c3`, `test_texture_regions.c3` |
| Sky, media, large worlds | `test_sky.c3`, `test_medium.c3`, `test_large_world.c3` |

The `.glsl` files beside the tests are probe shaders that the tests compile in process. Image comparisons read back
small targets and compare with tolerances stated in the test. Fixtures come from `test/fixtures/` and
`examples/assets/`; see [fixtures](../../fixtures/README.md).

## Benchmarks

Two executables in the project time the renderer. Build them with `c3c build <name> --path test/gpu/render` and run them
from the repository root. Both print CSV to standard output.

- `origin_bench [zero|grid|exact] [population]` times origin rebasing for a shadow scene or a 2,048-instance population;
  [large worlds](../../../docs/large_world.md) describes the policies. It needs ray queries.
- `posed_trace_bench mannequin <count> <software|hardware> <rest|strong|animate> [fresh] [novalidation]` and
  `posed_trace_bench crowd <count> <software|hardware> [novalidation]` time posed trace instances with a 1920 x 1080
  primary-ray dispatch per frame. Columns are the pose, acceleration build and trace GPU times, `trace_build_ms`,
  `posed_bytes` and the pose, refit, update and build counts; hardware runs also print the bottom-level storage with and
  without `allow_update`. `fresh` aborts every other frame
  so each sampled frame builds every posed bottom level. Validation is on unless `novalidation` is the last argument.

## Limits

- Frames with only a clear or only GUI draws need a window. Run the `clear` and `cube_gui` examples with validation.
- A presentation failure after submission needs a hardware observation.
- Software rasterizers (lavapipe) apply the first attachment's blend equation to every attachment, so the weighted
  blending pass renders wrongly there and needs a hardware run.
- Timings from a software rasterizer measure the harness only.
