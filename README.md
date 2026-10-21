# c3d

c3d is a scene-level 3D rendering library for [C3](https://c3-lang.org/). It provides an ECS scene, an asset store with
glTF and FBX import, animation and a Vulkan 1.3 renderer (through gpu.c3l), plus add-on packages for physics, navigation,
terrain and water, particles, UI and audio. It is a base for a game engine, not an engine.

The target platforms are linux-x64 and windows-x64, with C3 0.8.3 exactly. The Vulkan device must support
`shaderClipDistance`; `create_renderer` faults `UNSUPPORTED` without it.

## Features

- **Scene and assets.** A fixed-capacity [node hierarchy](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/scene.md) over an ECS; an [asset store](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/assets.md) with typed generational ids; [glTF and FBX import](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/models.md); [CPU picking](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/picking.md); [camera-relative large worlds](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/large_world.md).
- **Rendering.** [Views and render targets](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/views.md) with forward, deferred and path-traced [shading paths](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/shading_paths.md); [materials](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/materials.md) and [custom shaders](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/custom_shaders.md); [lights](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/lights.md) and [shadows](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/shadows.md); [sky, fog](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/sky.md) and clouds; [display processing](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/post.md); traced [reflections](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/reflections.md) and [path tracing](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/path_tracing.md); [instancing](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/instancing.md) and [LOD](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/lod.md).
- **Animation.** [Clips, layers, blend spaces and root motion](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/animation.md), [inverse kinematics](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/animation_ik.md) and [crowds](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/crowds.md).
- **Add-ons.** [Physics](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/physics.md), [navigation](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/navigation.md), [terrain](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/terrain.md), [particles](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/particles.md), [UI](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/ui.md), [audio](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/audio.md), a [job pool](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/jobs.md), [serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md) and a [profiler](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/profiling.md). Each is a separate package that an application selects in `project.json`; core never imports one. The [index](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/README.md#add-on-packages) links each package's README.

## Requirements

c3c 0.8.3, Python 3.10 or newer, `glslangValidator` on `PATH`, the Vulkan loader, a C compiler and git. The build script
downloads SDL3, Dear ImGui and the other native libraries. The
[getting-started page](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/getting-started.md#requirements) has the
details and the Windows setup.

## Build

The checkout directory must keep the name `c3d.c3l`.

```bash
git clone --recurse-submodules https://github.com/fesoliveira014/c3d.c3l
cd c3d.c3l
python3 scripts/build.py --init-deps --skip-build   # submodules, natives, generated files, shaders
python3 scripts/build.py --example hello            # build and run one example
python3 scripts/build.py                            # build every example
python3 scripts/build.py --test                     # then run every test target; what CI runs
```

GPU examples run by hand; CI has no GPU. [Development](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/development.md)
describes the build pipeline, the test targets and the manual GPU acceptance projects.

## First program

A window, an asset store, a renderer, one box and a camera. `python3 scripts/build.py --example cube` runs a similar
scene with an orbit camera.

```c3
module first_program;

import c3d::asset, c3d::camera, c3d::geometry, c3d::material, c3d::platform, c3d::render, c3d::scene;

fn int main() {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d", 1280, 720))!!;
    defer platform::destroy_window(&window);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId box_geometry;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        box_geometry = assets.add_geometry(&box, "box")!!;
    };
    MaterialId red = assets.add_material(material::basic({ .color = { 0.9f, 0.2f, 0.2f, 1 } }), "red")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.add_mesh(box_geometry, red, name: "cube")!!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    camera_node.local.position = { 0, 1, 3 };
    renderer.prepare_scene(&scene)!!;

    while (window.poll()) {
        scene.update_world();
        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;
    }
    return 0;
}
```

## Use c3d in your project

Each release publishes core as `c3d_core-v<version>.c3l` and every add-on as its own packed library. The
[releases page](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the files, the libraries each
package needs in `project.json`, the feature flags and the shader tools. The
[getting-started page](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/getting-started.md#use-c3d-in-your-project)
shows a project that builds this program against a checkout and explains the frame loop.

## Where next

- [Documentation index](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/README.md): every page by task and by subsystem, and the add-on READMEs.
- [Getting started](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/getting-started.md): install, your own project, a first scene and the frame loop.
- [Examples](https://github.com/fesoliveira014/c3d.c3l/blob/main/examples/README.md): every example with its options.
- [Architecture](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/architecture.md): layers, modules, add-ons and feature flags.

## Contributing and licence

Read [CONTRIBUTING.md](https://github.com/fesoliveira014/c3d.c3l/blob/main/CONTRIBUTING.md), then
[AGENTS.md](https://github.com/fesoliveira014/c3d.c3l/blob/main/AGENTS.md) and
[docs/style.md](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/style.md). c3d is MIT licensed (`LICENSE`). The
glyph shader port is covered by `LICENSE-slug.txt`; test fixture and example asset notices are in
[`test/fixtures/LICENSES.md`](https://github.com/fesoliveira014/c3d.c3l/blob/main/test/fixtures/LICENSES.md).
