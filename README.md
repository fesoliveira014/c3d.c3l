# c3d

[![ci](https://github.com/fesoliveira014/c3d.c3l/actions/workflows/ci.yml/badge.svg)](https://github.com/fesoliveira014/c3d.c3l/actions/workflows/ci.yml)

`c3d` is a scene-level 3D rendering library for [C3](https://c3-lang.org/). It provides an ECS scene, an asset store with
glTF and FBX import, animation and a Vulkan 1.3 renderer built on gpu.c3l. Add-on packages cover physics, navigation,
terrain and water, particles, UI and audio.

c3d is a base for a game engine, not an engine. It has no scheduler and does not run your game loop: the application
creates the window, the asset store, the renderer and the scene, and calls each system as a function, in the order it
chooses.

## Highlights

- a fixed-capacity node hierarchy over an ECS, with typed generational asset ids and glTF and FBX import;
- forward, deferred and path-traced shading over views and render targets;
- materials and custom shaders, lights and shadows, sky and fog, traced reflections and display processing;
- instancing, whole-object LOD, CPU picking and camera-relative large worlds;
- animation with clips, layers, blend spaces, root motion and inverse kinematics; and
- add-on packages for physics, navigation, character control, terrain, vegetation, water, particles, game UI, audio, a
  job pool, scene serialization and a profiler, each selected by the application in `project.json`.

## Requirements and status

The current release targets **C3 0.8.3** exactly, on `linux-x64` and `windows-x64`. The Vulkan device must support
`shaderClipDistance`; `create_renderer` faults `UNSUPPORTED` without it.

Other tools are Python 3.10 or newer, `glslangValidator` on `PATH`, the Vulkan loader and validation layer, a C compiler
and git. [Getting started](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/getting-started.md#requirements)
lists them and the Windows setup.

This project is pre-1.0.

## Start here

- [Getting started](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/getting-started.md): install, your own project, a first scene and the frame loop.
- [Documentation](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/README.md): every page by task and by subsystem, and the add-on READMEs.
- [Examples](https://github.com/fesoliveira014/c3d.c3l/blob/main/examples/README.md): every example with its options.
- [Architecture](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/architecture.md): layers, modules, add-ons and feature flags.
- [Releases](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md): the packed packages and what each needs in `project.json`.

## Install

Clone with submodules, fetch the native libraries once, then build and run an example:

```bash
git clone --recurse-submodules https://github.com/fesoliveira014/c3d.c3l
cd c3d.c3l
python3 scripts/build.py --init-deps --skip-build   # submodules, natives, generated files, shaders
python3 scripts/build.py --example hello            # build and run one example
python3 scripts/build.py                            # build every example
python3 scripts/build.py --test                     # then run every test target; what CI runs
```

`hello` prints the library version and opens no window. GPU examples open a window and run by hand; CI creates no GPU
device.

To use c3d in your own project, take a [release](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) or a checkout.
[Getting started](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/getting-started.md#use-c3d-in-your-project) shows the `project.json`.

## First program

A window, an asset store, a renderer, one box and a camera. Save it as `src/main.c3` of the project in getting started.

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
        Geometry box = geometry::box(allocator: tmem, width: 1, height: 1, depth: 1);
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

## Contributing and licence

Read [CONTRIBUTING.md](https://github.com/fesoliveira014/c3d.c3l/blob/main/CONTRIBUTING.md) before changing code. c3d is MIT licensed ([LICENSE](https://github.com/fesoliveira014/c3d.c3l/blob/main/LICENSE)). Third-party
notices sit beside the files they cover; the [example assets](https://github.com/fesoliveira014/c3d.c3l/blob/main/examples/README.md#example-assets) list theirs.
