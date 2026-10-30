# Examples

Every example of the repository: what it shows, its options and the page that explains the feature. The core examples
live in `examples/src/` and are targets of `examples/project.json`. Each add-on owns the examples listed under its
name below, in `addons/<package>/examples/`.

## Run an example

```bash
python3 scripts/build.py --example cube
```

This checks the tools, dependencies and generated files, builds the one target and runs it; see
[getting-started](../docs/getting-started.md) for the first build. `python3 scripts/build.py` builds all of them.
`--example` passes no options to the program. To pass options, build the target and run its binary:

```bash
python3 scripts/build.py --target many_lights --opt O3
./examples/build/many_lights --benchmark --mode clustered --lights 256
```

- The core binaries are in `examples/build/`, add-on binaries in `addons/<package>/build/`. On Windows they end in
  `.exe`.
- `custom_shader`, `custom_compute`, `compute_textures`, `shading_paths`, `software_rt` and `asset_reload` read their GLSL
  and glTF files through paths relative to the working directory, which must be `examples/build`. `--example` starts a
  program in `examples/`, where those paths do not resolve; build the target and run the binary from `examples/build`:

  ```bash
  python3 scripts/build.py --target custom_shader
  cd examples/build && ./custom_shader
  ```

- `cloth`, `physics_inspector` and `physics_inspector_character` load a model through a path relative to their package.
  `--example` starts them in the package directory; run the binary from there too when you pass options, for example
  `cd addons/c3d_physics.c3l && ./build/cloth --scene contacts`.
- The other examples locate their files from their source path and run from any directory.
- Examples that render need a Vulkan device and the Khronos validation layer. Interactive runs create the device with
  validation on. In benchmark modes, the examples that accept `--validation` leave it off unless it is given; the others
  keep it on. Drag to orbit and use the wheel to zoom in most windowed examples; releasing Escape quits. Each example
  lists its other keys in its panel or in a start-up message.
- An option or combination of options that an example does not accept makes it print an error or its usage line and exit
  with status 1.
- The Sponza scene used by `ambient_occlusion`, `probe_volume` and `software_rt` is fetched once with
  `python3 scripts/fetch_benchmark_assets.py`; see [benchmarking](../docs/benchmarking.md#scene-benchmark).

### Common options

- `--gpu-timings` records per-pass GPU timings and needs the profiler add-on in the binary. A binary built without it
  exits with an error that names the build command (`deferred` points to [views](../docs/views.md) instead). Build the
  target with the add-on selected, then run the binary:

  ```bash
  python3 scripts/build.py --target views --lib c3d_profile --define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL
  ./examples/build/views --gpu-timings
  ```

  `lod`, `overlay`, `text`, `skinned_crowd`, `particles` and `cloth` select the add-on in their project target already.
  They always record GPU timings and reject `--gpu-timings`. See [profiling](../docs/profiling.md).
- `--benchmark` runs a fixed script without input and prints timings. `many_lights`, `gltf_viewer` and `instancing`
  share one set of benchmark options, listed in [benchmarking](../docs/benchmarking.md#options-of-every-benchmark-example).
- `--frames=N` or `--frames N` ends a run after N frames. Where an example accepts it, the row names the flag.

## Library basics

These run in a terminal. `upload` creates a device but no window.

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `hello` | Prints `c3d::VERSION`. | | [getting-started](../docs/getting-started.md) |
| `ecs` | A standalone entity world: component stores, entity removal and a remove hook that frees component memory. | | [scene](../docs/scene.md) |
| `assets` | Adding, editing, finding, releasing and removing a geometry in the asset store, and a built-in texture. | | [assets](../docs/assets.md) |
| `scene` | Node hierarchy, world transforms, visibility, reparenting that keeps the world pose and removal while iterating. | | [scene](../docs/scene.md) |
| `geometry` | Procedural primitives, tangents, merging and a half-edge round trip. | | [assets](../docs/assets.md) |
| `upload` | Geometry upload: first upload, in-place reuse after an edit, replacement after a layout change, removal and sweep. | | [preparation](../docs/preparation.md) |

## Window, input and overlays

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `window` | Opens a window and prints key, text, focus, resize, mouse and wheel events. | | [platform](../docs/platform.md) |
| `clear` | Clears the window to a color that changes with time. | | [platform](../docs/platform.md) |
| `fullscreen` | Draws a gradient with a fullscreen shader into the frame. | | [platform](../docs/platform.md) |
| `actions` | One action map bound to keyboard and gamepad at once, with the bound values in a panel. | | [actions](../docs/actions.md) |
| `cube` | The first scene: a spinning box and sphere, orbit camera, perspective and orthographic lens (`O`), arrow keys move the box, frame statistics on standard output. | | [getting-started](../docs/getting-started.md) |
| `cube_gui` | The same scene with the ImGui overlay: scene tree, material editing, statistics and a Spin toggle that starts off. | `--gpu-timings`, `--gui-settings PATH` | [gui](../docs/gui.md) |
| `inspector` | The Fox model, sun, spot and point lights under the scene, material, statistics, targets and post panels. | `--gpu-timings` | [gui panels](../docs/gui_panels.md) |
| `described_components` | A component with a registered type description in the Scene panel. | | [type descriptions](../docs/type_descriptions.md) |
| `overlay` | Overlay lists of rectangles, glyphs, shapes, gradients, clips, transforms and backdrops over the frame, in a render target and in the world; a panel toggles each part. | see below | [overlay](../docs/overlay.md) |
| `text` | Latin and other script samples placed and drawn as glyph runs at several sizes; Space pauses the zoom. | see below | [text](../docs/text.md) |

`overlay` options:

`--stress`, `--target`, `--transform`, `--shapes`, `--gradients`, `--backdrop` and `--world` each start the matching panel
toggle on.

| Option | Effect |
| --- | --- |
| `--stress [N]` | Stress rectangles; N sets their count. |
| `--target` | The portrait overlay, a list drawn into a render target. |
| `--transform` | The transformed panel. |
| `--shapes`, `--gradients`, `--backdrop` | The shapes, gradients and backdrop items. |
| `--world` | The world labels. |
| `--mirror` | Implies `--world` and adds the mirror view inset. |
| `--frames N` | Ends the run after N frames. |
| `--benchmark --rects N --frames F --size WxH` | Windowed run of N rectangles at the given window size: F warmup frames, then F measured frames, with timings printed. |

`text` options:

| Option | Effect |
| --- | --- |
| `--compare` | Draws each sample as glyph outlines and as stb_truetype bitmaps. |
| `--stats` | Prints placement and build statistics and exits; no window. |
| `--frames N` | Ends the run after N frames. |
| `--benchmark --glyphs N --frames F --size WxH` | Windowed run of N glyphs at the given window size: F warmup frames, then F measured frames, with timings printed. |

## Assets and models

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `gltf_viewer` | A glTF or GLB model instantiated twice under a studio environment with one sun; free camera on `F`; the Textures panel lists resident mips. | `[model]`, `--gpu-timings`, `--texture-budget MiB`, benchmark options below | [models](../docs/models.md) |
| `streaming` | A scene that keeps rendering while a glTF or GLB decodes on the loader's worker; the panel shows phases, counters and preparation progress, and loading can be cancelled. The default model is BoxTextured. | `[model]` | [asset loading](../docs/asset_loading.md) |
| `asset_reload` | A scene and a texture that reload when `examples/assets/reload/scene.gltf` or `panel.png` changes; `R` forces a reload. | | [assets](../docs/assets.md) |
| `serialize` | Saves a cell of model instances, a box batch and lights as a binary and a JSONC snapshot, restores it and checks both round trips. | `--cpu-only`, `--models=N`, `--frames=N`, `--export=PREFIX`, `--original`, `--acceptance` | [serialization](../docs/serialization.md) |
| `textured` | PNG and JPEG maps with mip filtering, UV transforms and alpha masking. `N`, `L`, `A` select nearest, trilinear and anisotropic filtering; `S`, `R`, `O` change scale, rotation and offset; `U` switches UV0 and UV1; Backspace resets. | `[image.png\|image.jpg]` | [textures](../docs/textures.md) |
| `texture_cube` | A native six-face cube texture with generated or supplied mips. `1`-`6` select a face, `C` the source, `L` and `+`/`-` the level. | `[six face files]` | [textures](../docs/textures.md#load-six-cube-faces) |
| `texture_bc` | A supplied BC1 chain with a different color at each mip level. | | [textures reference](../docs/textures_reference.md#supply-mip-levels) |

`gltf_viewer` takes the shared benchmark options below and these:

| Option | Effect |
| --- | --- |
| `--benchmark [model]` | Fixed offscreen scene. Without a model it renders Sponza, fetched as described above. The options below apply to it. |
| `--mode flat\|clustered`, `--lights N`, `--capacity N`, `--range R`, `--shading forward\|deferred\|path-traced` | Light selection, light count, per-cell capacity, light range as a fraction of the largest horizontal extent (0.08 by default) and shading path. |
| `--shadows on\|off\|traced` | Sun shadows from the atlas (`on`, the default), none, or traced. `traced` makes an automatic run request ray queries. |
| `--probe-volumes 0\|1\|8` | No [probe volume](../docs/probe_volumes.md), one over the model bounds, or one per octant. |
| `--probe-counts X,Y,Z` | Probes per volume; 16,8,8 by default. |
| `--probe-fill environment\|scene` | Fill from the environment (the default) or trace the scene every frame; the trace kind follows `--trace`. |
| `--probe-window N` | Probes per update; 0 updates every probe. |
| `--probe-rays N` | Rays per probe, 32 to 256; 128 by default. |
| `--point-shadows on\|off` | Shadows on the point lights. |
| `--reflection-probes 0\|1\|2\|16` | [Reflection probes](../docs/reflection_probes.md) with distinct solid-color environments: none, one box over the model bounds, two overlapping boxes, or a 4 x 2 x 2 grid. The asset store holds 32 environments when probes are on. |
| `--reflection-probe-placement inside\|outside` | `outside` sinks every box below the model, so each pixel tests every box and lies in none. |
| `--environment-refresh on\|off` | Marks the studio source texture dirty before every frame, so each frame regenerates the environment. |

## Materials, lights and shaders

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `pbr` | A metallic and roughness sphere grid under directional, point and spot lights, with base color, metallic and roughness, normal, occlusion and emissive maps; the panel edits UVs, samplers and tangent frames. | `--gpu-timings` | [materials](../docs/materials.md) |
| `materials` | Masked foliage, alpha blending, Toon, and Physical clearcoat, sheen, specular, anisotropy and transmission in one window. | `--gpu-timings`, `--toon-outline WIDTH` | [materials](../docs/materials.md) |
| `transparency` | A view that switches between blending, additive, weighted blended and transmission. `R` steps the glass roughness, `L` toggles the transmission layers. | | [transparency](../docs/transparency.md) |
| `ibl` | Two bundled HDR environments lighting a sphere grid; independent lighting and background selection, rotation, intensity and processing resolution. | `--gpu-timings` | [environments](../docs/environments.md) |
| `shadows` | Sun cascades, spot projection and the six faces of a point light over solid, masked and off-camera casters. | `--gpu-timings` | [shadows](../docs/shadows.md) |
| `many_lights` | Flat and clustered Forward+ in a hall with 64 to 4,096 point lights; targets panel with cluster-depth slices. | own and benchmark options below | [lights](../docs/lights.md) |
| `shading_paths` | One scene through every shading path and light selection pair in a 2x2 grid, with a stats table. | `--gpu-timings` | [shading paths](../docs/shading_paths.md) |
| `deferred` | One scene forward on the left and deferred on the right; `M` cycles the MSAA count. | `--msaa 1\|2\|4\|8`, `--effects` adds bloom, depth of field and motion blur to both halves, `--clustered`, `--dense-decals` raises the bullet decal count, `--gpu-timings` | [shading paths](../docs/shading_paths.md), [MSAA](../docs/msaa.md) |
| `custom_shader` | A tinted sphere and a pulsing box through custom GLSL in `examples/shaders/custom/`, reloaded on change or `R`; `P` pauses the pulse. | | [custom shaders](../docs/custom_shaders.md) |
| `custom_compute` | A GPU particle simulation: a compute stage advances a renderer-owned buffer and a custom material draws it; `R` reloads, Space reseeds. | `--gpu-timings` | [compute](../docs/compute.md) |
| `compute_textures` | A compute stage writes a noise texture every frame and a second dispatch fogs the view image; `F` toggles the fog, `N` freezes the noise, `R` reloads. | `--gpu-timings` | [compute](../docs/compute.md) |

`many_lights` options:

| Option | Effect |
| --- | --- |
| `--benchmark` | Fixed offscreen run without a window; the options below apply to it. |
| `--mode flat\|clustered` | Light selection. |
| `--lights N`, `--capacity N`, `--range R` | Light count, per-cell capacity and light range. |
| `--shading forward\|deferred\|path-traced` | Shading path of the measured view. |
| `--depth-pruning on\|off` | [Depth pruning](../docs/lights.md#depth-pruning) of cluster cells; off by default. |

The shared benchmark options of `many_lights`, `gltf_viewer` and `instancing` are in
[benchmarking](../docs/benchmarking.md#options-of-every-benchmark-example): `--frames`, `--warmup`, `--width`,
`--height`, `--gpu-timings`, `--validation`, `--capture`, `--window`, `--panel`, `--print-features`, `--anti-aliasing`,
`--msaa`, `--depth-prepass`, `--ambient-occlusion`, `--auto-exposure`, `--reflections`, `--screen-space-gi`,
`--ssgi-trace`, `--ssgi-steps` and `--trace`.

## Sky, post-processing and effects

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `sky` | A physical sky with sun, height fog, volumetric fog and clouds over a 4 km ground, glass panes, a pond and a planar mirror; time-of-day panel and presets. | see below | [sky](../docs/sky.md), [fog](../docs/fog.md), [clouds](../docs/clouds.md) |
| `post` | Display processing on a textured cube, a chrome sphere and an emissive sphere: tone mapping, FXAA, LUT, grading and exposure. | `--cube-lut`, `--cube-lut-file FILE`, `--gpu-timings` | [post](../docs/post.md) |
| `effects` | Bloom, depth of field and motion blur on an emissive lamp, marbles and a spinning cube; `F` switches to auto focus. | `--auto-focus`, `--focus-point X Y`, `--gpu-timings`, `--benchmark FRAMES` (needs `--gpu-timings`) | [post](../docs/post.md) |
| `taa` | Temporal anti-aliasing on fine texture, a thin fence, a spinning cube, a skinned model, a morphing cube and orbiting instances, through a full view and an inset. | `--no-aa`, `--fxaa`, `--freeze`, `--sweep`, `--debug-velocity`, `--debug-rejection`, `--debug-weight`, `--gpu-timings` | [anti-aliasing](../docs/anti_aliasing.md#temporal-anti-aliasing) |
| `ambient_occlusion` | Sponza on a forward and a deferred view side by side with screen-space ambient occlusion. | `--full`, `--temporal`, `--bent-normals`, `--gpu-timings` | [ambient occlusion](../docs/ambient_occlusion.md) |
| `probe_volume` | Sponza lit by one probe volume with probe markers: gray provisional, green eligible, red excluded. | `--fill none\|environment\|scene`, `--trace software\|hardware`, `--deferred`, `--gpu-timings` | [probe volumes](../docs/probe_volumes.md) |
| `reflection_probes` | Two rooms lit by captured reflection probes: metal spheres from mirror to rough, a clearcoat and a sheen sphere. | `--deferred`, `--reflections`, `--capture-size N`, `--gpu-timings`, `--validation`, `--benchmark [--frames N]` | [reflection probes](../docs/reflection_probes.md) |
| `views` | A producer camera writes a capture target that a monitor slab samples, beside the window camera; a planar mirror floor. | `--gpu-timings` | [views](../docs/views.md) |

`sky` options:

| Option | Effect |
| --- | --- |
| `--atmosphere on\|off\|dense\|empty` | Earth's air (default), no atmosphere, an opaque scattering atmosphere, or air with no scattering. |
| `--fog on\|off` | Height fog; on by default. |
| `--volumetric-fog`, `--fog-quality low\|medium\|high`, `--fog-temporal` | A fog volume on the main and mirror views, its grid and its temporal accumulation. |
| `--clouds`, `--cloud-temporal` | A cloud layer over a procedural weather map, and its temporal accumulation. |
| `--local-lights N`, `--lamp-range METRES`, `--lamps-in-fog on\|off` | Up to 128 point and spot lamps along the camera path, their range (14 m by default) and whether the fog scatters them. |
| `--shading forward\|deferred`, `--shadows atlas\|traced`, `--ssgi`, `--taa` | Shading path, shadow kind, screen-space GI and TAA. |
| `--reflections on\|off` | Traced reflections on the main view; needs `--shading deferred`. |
| `--path-traced` | Path-traced main view; rejects `--clouds` and `--reflections`. |
| `--auto-exposure`, `--pre-exposure off\|FACTOR` | Auto exposure instead of the exposure table; a forced pre-exposure: `off` is 1 and FACTOR must be a power of two, or view creation faults `INVALID_ARGUMENT`. |
| `--preset noon\|twilight\|dusk\|nautical\|valley\|pan\|orbit\|time-lapse` | Camera and sun pose. |
| `--benchmark [frames]`, `--validation`, `--width N`, `--height N`, `--gpu-timings` | Offscreen scripted benchmark and device options; see [the sky benchmark](../docs/benchmarking.md#sky-benchmark). |

## Ray tracing

These need a device with ray queries or ray-tracing pipelines, except where a software option is listed.

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `rt_shadows` | Traced shadows against the atlas: `T` toggles them, `M` swaps the box between opaque and masked. | `--software`, `--atlas-shadows`, `--twin-ground`, `--point-lamp`, `--taa`, `--extent X`, `--shadow-samples N`, `--gpu-timings`, `--benchmark FRAMES` (needs `--gpu-timings`) | [ray-traced shadows](../docs/ray_traced_shadows.md) |
| `rt_effects` | A mirror floor, a roughness ramp and Physical spheres beside their traced reflections; `A` cycles ambient occlusion, `R` reflections, `S` forward and deferred. | `--software`, `--forward`, `--no-reflections`, `--pre-exposure off\|P` (P a power of two from 2^-16 to 2^16), `--reflection-rays N`, `--reflection-resolution full\|half`, `--reflection-history`, `--gpu-timings`, `--benchmark FRAMES` (needs `--gpu-timings`) | [reflections](../docs/reflections.md) |
| `path_tracer` | A Cornell-style room rendered progressively; `Space` toggles the lamp. | `--headless`, `--samples N`, `--width W`, `--height H`, `--out FILE.png` | [path tracing](../docs/path_tracing.md) |
| `software_rt` | Sponza with the right half of the view replaced by one traced primary ray per pixel; `M` cycles distance, geometric normal and instance colors. | `--hardware` uses ray queries, `--gpu-timings`, `--benchmark FRAMES` (needs `--gpu-timings`) | [scene trace](../docs/scene_trace.md) |

`path_tracer` without `--headless` opens a window and ignores the other options; with it, the program renders the
still, writes the PNG and exits.

## Animation

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `animation` | Two instances of a glTF model, each playing a different clip, with cross-fades, a quarter-weight action and pause. The bundled Fox is the default; `BoxAnimated.glb` shows node animation and `AnimatedMorphCube.glb` morph targets. | `[model]`, `--frames=N`, `--acceptance`, `--gpu-timings` | [animation](../docs/animation.md) |
| `animation_authoring` | A crowd and an animator with a 2D blend space, feathered and multiplicative overlays, generalized jog and inertial turns. | | [animation](../docs/animation.md) |
| `mixamo` | An FBX character retargeted by name to Mixamo animation files, with masked and additive waves over locomotion. `1`-`9` cross-fade, `W`/`S` blend walk and run, `R` applies root motion, `Q` sets quarter weight, Space pauses, `G` and `A` toggle the waves. | `[character.fbx walk.fbx run.fbx ...]`, `--frames=N`, `--capture=PATH`, `--acceptance`, `--benchmark` (needs `--lib c3d_profile --define C3D_PROFILE_CPU --define C3D_PROFILE_INTERNAL` at build), `--gpu-timings` | [animation](../docs/animation.md), [models](../docs/models.md) |
| `retarget` | A Mixamo walk on the Quaternius rig in each retargeting mode. | `--frames=N` | [retargeting](../docs/animation_retargeting.md) |
| `ik` | Feet, look-at and a reaching hand on two characters on a moving support. | `--limits`, `--legacy`, `--frames=N` | [inverse kinematics](../docs/animation_ik.md) |
| `skinned_crowd` | 512 instances of the committed character through six clips; `B` switches to 512 animators for comparison, `K` toggles compute skinning, `F` freezes every other instance, Space pauses. | `--baseline`, `--compute-skinning`, `--traced-shadows`, `--ray-queries`, `--compress`, `--shared-phases`, `--frozen-percent=P`, `--compare` | [crowds](../docs/crowds.md) |

`mixamo` and `retarget` need Mixamo downloads that are not committed; [the README beside them](assets/mixamo/README.md)
lists the files and download settings. `mixamo` without arguments reads `character.fbx`, `walk.fbx` and `run.fbx` from
that directory.

## Scene scale

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `picking` | Mouse picking with bounds or triangle precision; a glTF model instantiated twice, and a pick through a monitor's capture camera. | `[model]`, `--crowd` starts with a crowd of boxes and an instance batch shown, `--gpu-timings` | [picking](../docs/picking.md) |
| `instancing` | Three colored cubes in one batch, a 99,856-prop batch, a blended glass cloud and eight pulsing spheres through a custom vertex stage; a click reports the picked batch and instance. | own and benchmark options below | [instancing](../docs/instancing.md) |
| `lod` | One baked prototype drawn as 5,000 placements with three mesh levels and a terminal impostor; near, middle and far camera buttons. | `--frames N`; `--benchmark` runs offscreen at three camera positions and prints counters and per-pass timings | [LOD](../docs/lod.md), [impostors](../docs/impostors.md) |

`instancing` options:

| Option | Effect |
| --- | --- |
| `--fade-field` | Adds a grid of 4,096 cell batches with a fade band. |
| `--instance-edit range\|whole` | Bobs one row of the big batch every frame and publishes it as a range or whole. |
| `--move-node` | Moves a batch node every frame. |
| `--benchmark` | Fixed offscreen run; the shared benchmark options apply. |

## Profiling and CPU benchmarks

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `cpu_bench` | CPU scene traversal, extraction, index and ECS cases without a GPU device. | `CASE [nodes] [iterations] [samples]`, or `texture_mips EXTENT rgba8\|srgb [iterations] [samples]` | [benchmarking](../docs/benchmarking.md#cpu-extraction-and-transforms) |
| `profile_gpu` | A headless CPU and GPU capture exported as JSON on standard output. | | [profiling](../docs/profiling.md) |
| `profile_gui_cpu`, `profile_gui_internal`, `profile_gui_gpu`, `profile_gui` | A windowed profiler panel over a moving scene, built with CPU, CPU and library scopes, GPU, or all features. | | [profiling](../docs/profiling.md) |

## Add-on examples

Package READMEs list each package's targets. All of these run with `python3 scripts/build.py --example <name>`.
In `terrain`, `vegetation` and `water`, `--volumetric-fog` needs `--sky`. In `terrain` and `vegetation`, `--workers`
needs `--benchmark`.

### Physics

Package: [c3d_physics](../addons/c3d_physics.c3l/README.md). Overview: [physics](../docs/physics.md).

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `physics` | Thrown boxes on ramps and a moving kinematic platform, contact highlights, ray picks and debug draw. | | [physics](../docs/physics.md) |
| `physics_instanced` | The same scene with every box drawn from one instanced batch. | | [physics](../docs/physics.md) |
| `physics_components` | A level and bodies built from components: wind, forces, explosions, surface materials and joints. | `--stress`, `--benchmark N`, `--debug-draw` and `--workers N` (both need `--benchmark N`) | [physics](../docs/physics.md) |
| `vehicle` | A chassis on wheel joints with steering, suspension and a drive motor. | | [physics](../docs/physics.md) |
| `ragdoll` | Simulated and animated bones, blending and physical get-up recovery. | `--acceptance DIR [--case supine\|prone\|blocked\|neighbour]`, `--cpu-observation` | [ragdolls](../docs/ragdoll.md) |
| `breakable` | A fractured wall with anchors, sampled strengths and reset; left click throws, right drag orbits. | `--model FILE`, `--walls N`, `--workers N`, `--frames=N`, `--capture=PATH`, `--pieces`, `--anchors`, `--sampled`, `--reset-at=N`, `--capture-before-reset=PATH`, `--acceptance`, `--benchmark` | [breakables](../docs/breakables.md) |
| `cloth` | Flags, capes, contacts, self-contact, crowds and tearing. | `--scene flag\|cape\|both\|contacts\|fold\|fast\|field\|crowd\|densities`, `--still`, `--tear`, `--hold` (field), `--count N` (field, crowd), `--workers N`, `--frames N`, `--publish whole\|streams`, `--capture FILE`, `--benchmark`; with `--benchmark` only: `--cells N`, `--ragdoll` (cape and both scenes), `--cpu-only`, `--validation`, `--trace software\|hardware` | [cloth](../docs/cloth.md#example) |
| `collision_math` | World-free collision queries on prepared shapes. | `--acceptance [--frames=N] [--capture=PATH]`, `--benchmark` | [collision queries](../docs/collision_queries.md) |
| `physics_inspector`, `physics_inspector_character` | The physics panel and component inspectors over a ragdoll; the second adds the characters table. | `--demo`, `--draw-all`, `--replay-default-mixes`, `--frames N` | [physics inspector](../docs/physics_inspector.md) |

### Navigation and characters

Packages: [c3d_nav](../addons/c3d_nav.c3l/README.md), [c3d_character](../addons/c3d_character.c3l/README.md).

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `navmesh` | A navigation mesh built from scene geometry and path queries over it. | `--cache`, `--detail`, `--sub-cell`, `--frames N` | [navigation](../docs/navigation.md) |
| `crowd` | A crowd steering over a navigation mesh. | `--cache`, `--direct`, `--detail`, `--sub-cell`, `--frames N` | [navigation](../docs/navigation.md) |
| `grid` | A tile map with a bridge, a steering crowd and tiles rebuilt after wall edits. | `--cache`, `--cache-demo`, `--fan-in`, `--detail`, `--sub-cell`, `--radius R`, `--clearance-error E`, `--frames N` | [navigation grids](../docs/navigation_grids.md) |
| `nav_persistence` | Saves, replaces and queries a baked snapshot; CPU only. | `--measure` | [baked snapshots](../docs/navigation_persistence.md) |
| `character` | A kinematic capsule on ground, steep slopes, a platform and pushable crates. `WASD` move, Shift runs, Space jumps, right drag orbits. | | [character package](../addons/c3d_character.c3l/README.md) |
| `character_nav` | The capsule beside a navigation crowd; a click sends the crowd, `R` rebases the world to the player. | `--world-offset KM` | [character package](../addons/c3d_character.c3l/README.md) |
| `rebase_bench` | Resting-stack position noise with and without origin rebasing; terminal output only. | | [origin rebasing](../docs/origin_rebasing.md) |

### Landscape

Package: [c3d_landscape](../addons/c3d_landscape.c3l/README.md).

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `terrain` | A generated ridged height map edited under a collider, with tile sets. | `--tiles 2x2`, `--size N`, `--layers 1\|4`, `--lod-threshold X`, `--morph`, `--triplanar`, `--shading forward\|deferred`, `--shadows atlas\|traced`, `--hide-terrain`, `--trace-level N`, `--collision-window N`, `--sky`, `--volumetric-fog`, `--benchmark [frames]`, `--workers N`, `--capture FILE`, `--gpu-timings`, `--validation`; `--tiles` and `--capture` reject `--benchmark` | [terrain](../docs/terrain.md) |
| `vegetation` | Grass and trees scattered over the terrain example's ground. | `--foliage both\|grass\|none`, `--tree-fade-end X`, `--size N`, `--shading forward\|deferred`, `--shadows atlas\|traced`, `--trace-sway` (needs traced shadows and `--foliage both`), `--trace-software` (needs traced shadows), `--sky`, `--volumetric-fog`, `--benchmark [frames]`, `--workers N`, `--capture FILE`, `--gpu-timings`, `--validation` | [vegetation](../docs/vegetation.md) |
| `water` | A lake, an ocean and floating crates. | `--waves gerstner\|simulated`, `--reflection planar\|march\|env`, `--ocean`, `--sea-state`, `--ripples on\|off`, `--wind SPEED`, `--crates 16\|256`, `--current X,Z`, `--dive [SHARE]`, `--split`, `--traced`, `--ssgi`, `--size N`, `--mirror-scale 0.5\|1`, `--shading forward\|deferred`, `--sky`, `--volumetric-fog`, `--benchmark [frames]`, `--shot FILE`, `--gpu-timings`, `--validation`; `--waves simulated` rejects `--ocean` and `--sea-state` | [water](../docs/water.md) |
| `water_gpu` | The `water` example built with `C3D_LANDSCAPE_GPU`, which adds the spectral wave model. | as `water`, plus `--waves spectral` | [water wave models](../docs/water_wave_models.md) |

### Particles, UI, audio and jobs

| Example | Shows | Options | Page |
| --- | --- | --- | --- |
| `particles` | Smoke, additive sparks, mesh debris and embers. | `--sparks`, `--smoke`, `--embers`, `--trails`, `--lit-smoke [--lighting NAME] [--normal NAME]`, `--collide`, `--debris-shadows`, `--drop-oldest` (needs `--stress` or `--benchmark`), `--workers N`, `--frames N`, `--stress`, `--benchmark [--views 1\|2] [--capacity N] [--capture-rgba PATH]` | [particles](../docs/particles.md) |
| `particles_gpu` | The `particles` example built with `C3D_PARTICLE_GPU`; `--gpu` selects device-stepped systems. | as `particles`, plus `--gpu` | [GPU particles](../docs/particles_gpu.md) |
| `ui` | A HUD and an inventory with drag and drop; the options add windows, rich text and transitions documents. | `--windows [N]`, `--rich-text`, `--transitions`, `--reload-scroll`, `--reduced-motion`, `--frames N`, `--benchmark --frames F [--labels N] [--windows N] [--rich N] [--transitions]` | [UI](../docs/ui.md) |
| `audio` | A looping emitter circling the listener, streamed music and one-shots. `1` and `2` play one-shots, `M` and `N` set music and effects volume, `S` toggles the orbiter. | `--null-device`, `--headless --frames N` | [audio](../docs/audio.md) |
| `job_bench` | Per-range overhead and parallel speedup of the job pool; `--crowd COUNT` times animated crowd sampling over the pool. | `--crowd COUNT [--shared-phases] [--compress]` | [jobs](../docs/jobs.md) |
| `capture` | A CPU capture printed as JSON; no renderer. | | [profiling](../docs/profiling.md) |

## Example assets

Five asset directories under `examples/assets/` keep their source and licence in a README: [glTF models](assets/gltf/README.md),
[HDR environments](assets/ibl/README.md), [fonts](assets/fonts/README.md), the [Quaternius character and
animations](assets/quaternius/README.md) and the [Mixamo downloads](assets/mixamo/README.md) that are not committed. The
`cube`, `lut`, `pbr` and `reload` directories have no README. The recipes for the `cube` and `pbr` files are in the
[fixtures README](../test/fixtures/README.md), and `reload/generate.py` writes the files of `asset_reload`.
