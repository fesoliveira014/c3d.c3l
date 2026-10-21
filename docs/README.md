# Documentation

The index of every page under `docs/` and of every add-on package README. A topic has a guide page, and a long topic has
a reference page beside it (`<topic>_reference.md`) with the tables of fields, defaults and faults. The
[repository README](../README.md) introduces c3d; [getting started](getting-started.md) installs and builds it.

## Start here

- [Getting started](getting-started.md): install, build, use c3d in your project, a first scene and the frame loop.
- [Examples](../examples/README.md): every example, its options and the page that explains it.
- [Architecture](architecture.md): layers, modules, add-on packages, feature flags and the directory map.
- [Development](development.md): the build and shader pipelines, native libraries, test targets and acceptance projects.
- [Releases](release.md): the packed packages, their dependencies and how a release is made.
- [Code style](style.md): the code style baseline for every `.c3`, `.c3i` and `.glsl` file.
- [Contributing](../CONTRIBUTING.md): the rules for a change, and [how a change is reviewed](../REVIEW.md).

## By task

| I want to | Read |
| --- | --- |
| Build and run c3d | [getting started](getting-started.md), [development](development.md) |
| Use c3d in my own project | [getting started](getting-started.md#use-c3d-in-your-project), [releases](release.md) |
| Open a window and read input | [platform](platform.md), [action maps](actions.md) |
| Build a scene and load a model | [scene](scene.md), [asset store](assets.md), [models](models.md), [asset loading](asset_loading.md) |
| Light a scene | [lights](lights.md), [shadows](shadows.md), [environments](environments.md), [lighting techniques](lighting_techniques.md) |
| Draw with my own shader | [custom shaders](custom_shaders.md), [shader packages](shader_packages.md), [compute dispatch](compute.md) |
| Tune how the image looks | [display processing](post.md), [anti-aliasing](anti_aliasing.md), [sky](sky.md), [fog](fog.md), [transparency](transparency.md) |
| Draw many objects | [instancing](instancing.md), [LOD](lod.md), [crowds](crowds.md), [particles](particles.md) |
| Animate characters | [animation](animation.md), [inverse kinematics](animation_ik.md), [retargeting](animation_retargeting.md) |
| Simulate physics | [physics](physics.md), [ragdolls](ragdoll.md), [cloth](cloth.md), [collision queries](collision_queries.md) |
| Move agents over a level | [navigation](navigation.md), [navigation grids](navigation_grids.md), [character package](../addons/c3d_character.c3l/README.md) |
| Build terrain, vegetation and water | [terrain](terrain.md), [vegetation](vegetation.md), [water](water.md) |
| Draw text, overlays and game UI | [text](text.md), [overlay](overlay.md), [UI](ui.md), [GUI](gui.md) |
| Play sound | [audio](audio.md) |
| Save and load a scene | [serialization](serialization.md) |
| Run work on worker threads | [job pool](jobs.md) and its [`ParallelFor` hook](jobs.md#parallelfor-hook) |
| Measure performance | [profiling](profiling.md), [benchmarking](benchmarking.md) |
| Extend c3d | [custom asset kinds](custom_assets.md), [type descriptions](type_descriptions.md), [custom shaders reference](custom_shaders_reference.md) |

## By subsystem

### Scene, assets and loading

- [Scene nodes](scene.md): the node hierarchy, transform spaces, visibility and explicit updates.
- [Asset store](assets.md): the CPU store, typed ids, revisions and keys.
- [Geometry edits](geometry_edits.md): edit vertex arrays in place and publish the changed vertices.
- [Asset loading](asset_loading.md): decode and publish, background loading and cancellation.
- [Models, glTF and FBX import](models.md): load a model once and instantiate it many times.
- [glTF source inspection](gltf_source.md): source metadata beside a decoded model, for tools.
- [Custom asset kinds](custom_assets.md): register an asset kind of your own.
- [Type descriptions](type_descriptions.md): one field walk for application data and inspectors.
- [Owner readiness](owner_readiness.md): components that finish after attachment or load.
- [CPU picking](picking.md): rays against meshes and the scene index.
- [Camera-relative rendering](large_world.md): the frame origin for large worlds.
- [Origin rebasing](origin_rebasing.md): move the origin between frames across scene, renderer and simulation.

### Platform and tooling UI

- [Windows and input](platform.md): windows, events, keyboard, mouse, gamepads, clipboard and text input.
- [Action maps](actions.md): controls as named actions bound to devices.
- [GUI overlay](gui.md): the Dear ImGui adapter and how to rebuild its native archive.
- [GUI panels](gui_panels.md): scene, material, statistics, targets and post panels.
- [Debug lines](debug_draw.md): bounds, frusta, volumes and skeletons as lines.

### Renderer

- [Views and render targets](views.md) and [reference](views_reference.md): views, outputs, targets and capacities.
- [Preparation](preparation.md): upload assets and build pipelines before the first frame.
- [Shading paths](shading_paths.md): forward, deferred and path-traced shading.
- [Multisample anti-aliasing](msaa.md) and [anti-aliasing](anti_aliasing.md): FXAA, TAA and MSAA.
- [Transparency](transparency.md): blending, weighted blended transparency and transmission.
- [Decals](decals.md): project a material onto surfaces.
- [Display processing](post.md) and [reference](post_reference.md): tone mapping, grading, bloom, depth of field and motion blur.

### Materials, textures and shaders

- [Materials](materials.md) and [reference](materials_reference.md): the built-in families, factors and maps.
- [Textures and images](textures.md) and [reference](textures_reference.md): load images, supply mips, compressed formats.
- [Texture streaming](texture_streaming.md): region edits, content replacement and residency budgets.
- [Custom shaders](custom_shaders.md) and [reference](custom_shaders_reference.md): your own SPIR-V as a material.
- [Shader packages](shader_packages.md): compile your GLSL offline into embedded constants.
- [Compute dispatch](compute.md): your own compute stages inside a frame.

### Lighting and environment

- [Lights and light selection](lights.md): directional, point and spot lights, flat and clustered selection.
- [Shadows](shadows.md): atlas shadows for directional, spot and point lights.
- [Ray-traced shadows](ray_traced_shadows.md): one ray per pixel toward the light.
- [Environments and image-based lighting](environments.md): lighting and background from an environment asset.
- [Reflection probes](reflection_probes.md): captured cube reflections for boxed regions.
- [Probe volumes](probe_volumes.md): diffuse indirect light on a probe grid.
- [Ray-traced reflections](reflections.md), [ambient occlusion](ambient_occlusion.md) and [screen-space indirect diffuse](screen_space_gi.md).
- [Path tracing](path_tracing.md): a progressive reference image.
- [Scene tracing](scene_trace.md) and [reference](scene_trace_reference.md): trace data and the shader API for rays against the scene.
- [Lighting techniques](lighting_techniques.md): how the lighting terms compare and which features each needs.

### Sky and atmosphere

- [Sky and atmosphere](sky.md) and [reference](sky_reference.md): a physical sky with a sun.
- [Fog and medium volumes](fog.md): height fog, volumetric fog and medium volumes.
- [Clouds](clouds.md): a raymarched cloud deck.

### Instancing, LOD and sprites

- [Explicit instancing](instancing.md) and [instance quadtrees](instancing_quadtree.md): many copies in one draw.
- [Animated crowds](crowds.md): independent playback in one draw per mesh part.
- [Whole-object LOD](lod.md), [animated LOD](lod_animated.md) and [static impostors](impostors.md).
- [Billboards](billboards.md) and [ribbons](ribbons.md): view-facing quads and strips.

### 2D, text and overlays

- [Overlay list](overlay.md) and [world-space overlay items](overlay_world.md): application-owned 2D items.
- [Text](text.md): fonts, placement and glyph runs.

### Animation

- [Animation](animation.md) and [reference](animation_reference.md): clips, layers, blend spaces, root motion and events.
- [Animation deformation](animation_deformation.md): skinning, morphs, bounds and animated LOD in the renderer.
- [Inverse kinematics](animation_ik.md): limbs, feet and looking.
- [Animation retargeting](animation_retargeting.md): rebind a clip onto another model.
- [Animation performance](animation_performance.md): worker threads, shared samples and compressed clips.

### Physics

- [Physics](physics.md): rigid bodies, colliders, events and queries on scene nodes.
- [Ragdolls](ragdoll.md), [breakables](breakables.md) and [cloth](cloth.md) with its [reference](cloth_reference.md).
- [Collision queries](collision_queries.md) and [reference](collision_queries_reference.md): world-free shape queries.
- [Buoyancy](buoyancy.md): lift bodies out of a fluid.
- [Physics inspector](physics_inspector.md): the physics panel and component inspectors.

### Navigation

- [Navigation](navigation.md): navigation meshes, path queries and crowds.
- [Navigation grids](navigation_grids.md): tile maps, voxel grids and height fields as mesh sources.
- [Baked navigation snapshots](navigation_persistence.md) and [snapshot format](navigation_snapshot_format.md).
- [Recast and Detour port](navigation_recast_port.md): what the port keeps and changes.

### Landscape

- [Terrain](terrain.md), [reference](terrain_reference.md) and [terrain with physics and navigation](terrain_integration.md).
- [Vegetation](vegetation.md): scatter foliage over terrain.
- [Water](water.md), [reference](water_reference.md) and [wave models](water_wave_models.md).

### Particles, UI and audio

- [Particles](particles.md), [reference](particles_reference.md) and [GPU particles](particles_gpu.md).
- [Game UI](ui.md) and [reference](ui_reference.md): JSONC documents laid out with Clay.
- [Audio](audio.md): clips, buses, emitters and a listener.

### Serialization, jobs and profiling

- [Serialization](serialization.md) and [reference](serialization_reference.md): scene subtrees as binary or JSONC.
- [Job pool](jobs.md): fork-join over index ranges, and the `ParallelFor` hook.
- [Profiling](profiling.md) and [reference](profiling_reference.md): CPU and GPU capture and the profiler panel.
- [Benchmarking](benchmarking.md): the benchmark runner, the CSV it writes and the profiling configurations.

## Add-on packages

Each package README states its boundaries, quick start and targets.

| Package | README | Guide |
| --- | --- | --- |
| `c3d_physics` | [README](../addons/c3d_physics.c3l/README.md) | [physics](physics.md) |
| `c3d_nav` | [README](../addons/c3d_nav.c3l/README.md) | [navigation](navigation.md) |
| `c3d_character` | [README](../addons/c3d_character.c3l/README.md) | [physics](physics.md), [navigation](navigation.md) |
| `c3d_physics_gui` | [README](../addons/c3d_physics_gui.c3l/README.md) | [physics inspector](physics_inspector.md) |
| `c3d_landscape` | [README](../addons/c3d_landscape.c3l/README.md) | [terrain](terrain.md), [vegetation](vegetation.md), [water](water.md) |
| `c3d_particle` | [README](../addons/c3d_particle.c3l/README.md) | [particles](particles.md) |
| `c3d_ui` | [README](../addons/c3d_ui.c3l/README.md) | [UI](ui.md) |
| `c3d_audio` | [README](../addons/c3d_audio.c3l/README.md) | [audio](audio.md) |
| `c3d_job` | [README](../addons/c3d_job.c3l/README.md) | [job pool](jobs.md) |
| `c3d_serial` | [README](../addons/c3d_serial.c3l/README.md) | [serialization](serialization.md) |
| `c3d_profile` | [README](../addons/c3d_profile.c3l/README.md) | [profiling](profiling.md) |
| `c3d_profile_gui` | [README](../addons/c3d_profile_gui.c3l/README.md) | [profiling](profiling.md) |
