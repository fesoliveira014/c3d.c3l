# Getting started

Install c3d from a checkout, build it, use it from your own project and write a first scene with its frame loop. The
build pipeline in full is [development](development.md); the packages and their dependencies for an application are
[releases](release.md).

## Requirements

| Tool | Version | Notes |
| --- | --- | --- |
| c3c | 0.8.3 | `scripts/build.py` refuses any other version. |
| Python | 3.10 or newer | Standard library only. |
| glslang | any | `glslangValidator` on `PATH`, from `glslang-tools` or a Vulkan SDK; or pass `--glslang`. |
| Vulkan loader | any | `libvulkan.so.1` or `vulkan-1.dll`. Every c3d executable imports it at start. |
| Khronos validation layer | any | Needed whenever `validation` is on, as in every program below: `vulkan-validationlayers` or the Vulkan SDK. |
| C compiler | any | c3c compiles the vendored C sources (`csrc/`, cgltf, ufbx, clay, miniaudio) with it; MSVC on Windows. |
| git | any | Fetches the dependency submodules. |

The Vulkan device must support `shaderClipDistance`; `create_renderer` faults `UNSUPPORTED` without it. The target
platforms are linux-x64 and windows-x64; the Linux natives need glibc 2.35 or newer. SDL3, Dear ImGui and the other native libraries need no install: `--init-deps`
downloads them.

On Debian or Ubuntu:

```bash
sudo apt-get install -y glslang-tools libvulkan1 vulkan-validationlayers libgl1-mesa-dev build-essential
```

## Install and build

Keep the `lib/c3d.c3l` symlink: the example and test projects resolve the library through it (see Windows).

```bash
git clone --recurse-submodules https://github.com/fesoliveira014/c3d.c3l
cd c3d.c3l
python3 scripts/build.py --init-deps --skip-build
python3 scripts/build.py --example hello
```

`--init-deps` initializes the submodules itself, so a clone without `--recurse-submodules` works too. It then downloads
the native libraries of sdl3, c3imgui, box3d, shaderc, vma and spvreflect from each repository's release at the pinned
tag, and checks each against that release's `SHA256SUMS`. The natives are prebuilt and later builds download nothing. With
`--skip-build` the run stops after verifying the generated files, which builds gpu.c3l's `gpu_shaders` generator on first
use, and compiling the shaders.

`--example hello` builds one target and runs it. It prints the library version and opens no window. These commands cover
the rest:

```bash
python3 scripts/build.py                  # compile SPIR-V, verify generated files, build every example
python3 scripts/build.py --test           # the same, then every test target; what CI runs
python3 scripts/build.py --example cube   # build and run the first-mesh example
```

`--example` runs the example without options; to pass options, run its binary, as described in the
[examples](../examples/README.md#run-an-example). The example list is there too.

### Windows

- Install Visual Studio 2022 with the C++ desktop workload, Git for Windows, the Vulkan SDK (`glslangValidator` and the
  loader), Python 3.10 or newer and c3c 0.8.3 on `PATH`. Use `python` where this page says `python3`.
- Clone under a short path with symlinks enabled. `lib/c3d.c3l` is a symlink that the projects resolve through, and Git
  creates a real link only with Developer Mode on or in an elevated shell:

  ```powershell
  git clone -c core.symlinks=true --recurse-submodules https://github.com/fesoliveira014/c3d.c3l C:\repos\c3d.c3l
  ```

- Every Windows native library links the static CRT, and the c3d manifest and projects declare `"wincrt": "static"`. A
  consumer on the dynamic CRT fails at link with `lld-link: error: /failifmismatch: mismatch detected for 'RuntimeLibrary'`.
- SDL3 links statically. The build copies `shaderc_shared.dll` next to the executables.
- Third-party Vulkan layers with broken manifests print `loader_get_json` errors at start; they are harmless.

## Use c3d in your project

From a release, download the packages and list them in `project.json` as [releases](release.md#using-a-release) describes.

From a checkout, point `dependency-search-paths` at the checkout's `lib/` and at `lib/gpu.c3l/lib/` (the Vulkan
bindings), and list core with its dependencies:

```json
{
  "langrev": "1",
  "dependency-search-paths": [ "path/to/c3d.c3l/lib", "path/to/c3d.c3l/lib/gpu.c3l/lib" ],
  "dependencies": [
    "c3d", "gpu", "vk", "vma", "spvreflect", "sdl3", "c3imgui", "c3cg", "cgltf", "ufbx"
  ],
  "wincrt": "static",
  "targets": { "first_scene": { "type": "executable", "sources": [ "src/**" ] } }
}
```

- Run `python3 scripts/build.py --skip-build` in the checkout once. It compiles the SPIR-V that core embeds; without it
  `c3c build` fails with `Failed to load '.../shaders/spv/fullscreen.spv'`.
- c3c does not follow a library's own dependency list, so every dependency appears in your `project.json`.
- Each add-on is a library beside the others in `lib/`: list it, and what it needs, as the table in
  [releases](release.md#using-a-release) shows. Optional features, such as `C3D_SHADER_COMPILER`, are `features` of your
  target; see [architecture](architecture.md#feature-flags).

## A first scene

The program opens a window, creates the renderer and shows a spinning box under a sun. Save it as `src/main.c3` of the
project above.

```c3
module first_scene;

import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;

fn int main() {
    platform::Window window = platform::create_window(
        platform::default_window_desc("first scene", 1280, 720))!!;
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
    MaterialId red = assets.add_material(
        material::standard({ .base_color = { 0.9f, 0.2f, 0.2f, 1 }, .metallic = 0, .roughness = 0.5f }),
        "red",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = 0.1f;

    Node* cube = scene.add_mesh(box_geometry, red, name: "cube")!!;
    Node* sun = scene.add_light(light::directional({ 1, 1, 1 }, 3), name: "sun")!!;
    sun.local.rotation = maths::look_rotation({ -0.5f, -1, -0.3f }, { 0, 1, 0 });
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    camera_node.local.position = { 0, 1.5f, 4 };
    camera_node.local.rotation = maths::look_rotation({ 0, -0.3f, -1 }, { 0, 1, 0 });

    renderer.prepare_scene(&scene)!!;

    while (window.poll()) {
        if (window.input.key_released(platform::Scancode.ESCAPE)) break;

        cube.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)window.clock.total);
        scene.update_world();

        platform::sync_window(&window, &renderer);
        renderer.render(&scene, camera_node, { .time = window.clock.total, .delta = window.clock.delta })!!;
    }
    return 0;
}
```

Build and run it with `c3c run first_scene` from the project directory. Releasing Escape or closing the window quits.

- **Ownership.** The application owns the window, the asset store, the renderer and the scene, and destroys them in
  reverse order with `defer`. The store owns the CPU data of every asset. The renderer owns every GPU object and mirrors
  assets lazily. The scene owns its nodes; a node pointer stays valid until the node is removed.
- **Ids.** `add_geometry` and `add_material` return typed generational ids. Nodes reference assets by id, so one geometry
  serves any number of nodes. See [assets](assets.md) and [scene](scene.md).
- **Faults.** Every operational failure is a fault. The example unwraps with `!!` and exits on the first one; an
  application usually handles the faults of file loading and capacity limits. `validation` requests the Khronos
  validation layer, which every development run of the repository's examples uses. Without the layer installed,
  creation faults `UNSUPPORTED_FEATURE`; set it to `false` to run without.
- **Lights.** A `Light` is a component on a node and a directional light points along the node's negative Z axis. See
  [lights](lights.md).
- **Preparation.** `prepare_scene` uploads the assets the scene references and builds the pipelines, so the first frame
  does not stall. See [preparation](preparation.md).

## The frame loop

c3d has no scheduler. The application calls each system as a function, in the order it chooses. A frame of the program
above runs these steps:

1. `window.poll()` drains events, updates `window.input` and the clock, and returns false when the application should
   quit.
2. The application reads input and edits nodes and components. Systems that write node transforms, such as the animation
   update, run here.
3. `scene.update_world()` publishes world matrices and visibility. Call it after edits and before anything reads them.
4. Systems that read world matrices (physics, navigation and particles) run after it. Each writer (animation, physics and
   IK) is followed by another `update_world` before rendering; [animation](animation.md#update-sequence) gives the full
   order, and [physics](physics.md), [navigation](navigation.md) and [particles](particles.md) state theirs.
5. `platform::sync_window` hands the window's pixel size and minimized state to the renderer, so a resize takes effect
   on the next frame.
6. `renderer.render` records, submits and presents the frame for the default view and one camera.

`render` is shorthand for four calls. Use them directly when a frame has several views or render targets:

```c3
renderer.begin_frame({ .time = window.clock.total, .delta = window.clock.delta })!!;
renderer.render_view(&scene, camera_node, renderer.default_view)!!;
renderer.finish_view(renderer.default_view)!!;
renderer.end_frame()!!;
```

`begin_frame` opens the frame. `render_view` extracts the scene and records the passes of one view, and may run once per
view. `finish_view` writes the view's output, and `end_frame` submits and presents. The renderer reads the scene; the
scene never calls the renderer. See [views](views.md) for several views and [architecture](architecture.md) for how
the layers fit together.

## Troubleshooting

| Message or symptom | Cause and fix |
| --- | --- |
| `c3c 0.8.3 required, found ...` | Install c3c 0.8.3; the build refuses other versions. |
| `'glslangValidator' not found on PATH` | Install `glslang-tools` or a Vulkan SDK, or pass `--glslang <path>`. |
| `missing dependencies under lib/` or `missing c3imgui native archive` | Run `python3 scripts/build.py --init-deps`. |
| `create_renderer` faults `UNSUPPORTED` | The device lacks `shaderClipDistance`, or the description asks for GPU timings in a build without `C3D_PROFILE_GPU`. |
| `create_window_renderer` faults `UNSUPPORTED_FEATURE` with `validation` on | The validation layer is missing. Install `vulkan-validationlayers` or the Vulkan SDK, or set `.validation = false`. |
| `Failed to load '.../shaders/spv/...'` in your project | Run `python3 scripts/build.py --skip-build` in the checkout. |

## See also

- [Examples](../examples/README.md): every example, its options and the page that explains it.
- [Documentation index](README.md): the pages by task and by subsystem.
- [Scene nodes](scene.md), [asset store](assets.md), [materials](materials.md), [lights](lights.md) and
  [models and glTF import](models.md): the next things a scene needs.
- [Development](development.md): the build pipeline, test targets and acceptance projects.
