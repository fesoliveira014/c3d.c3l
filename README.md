# c3d

A scene-level 3D rendering library for [C3](https://c3-lang.org/): an ECS scene, physics,
animation, and asset import, on top of Vulkan 1.3 through gpu.c3l. Not a game engine; a base
for one.

Target platforms are linux-x64 and windows-x64. C3 0.8.3 exactly.

See [Benchmarking](docs/benchmarking.md) for CPU extraction profiles, headless many-light
sweeps and reproducible CSV measurements. The Sponza scene suite needs
`python3 scripts/fetch_benchmark_assets.py` once.

## Prerequisites

| Tool | Version | Notes |
| --- | --- | --- |
| c3c | 0.8.3 | `scripts/build.py` refuses any other version |
| Python | 3.10 or newer | standard library only |
| glslang | any | `glslangValidator` on PATH, from `glslang-tools` or a Vulkan SDK |
| Vulkan loader | any | `libvulkan.so.1`, from `libvulkan1` |
| SDL3 | 3.4.16 or newer | not packaged by Ubuntu 24.04; build it, see below |
| CMake and a C compiler | any | native dependencies; the image decoder also compiles during ordinary builds |
| Bash, curl, tar and sha256sum (or shasum) | any | fetch and verify ImGui release archives |

On Debian or Ubuntu:

```bash
sudo apt-get install -y glslang-tools libvulkan1 libgl1-mesa-dev cmake ninja-build build-essential
```

## Clone

The checkout directory must keep the name `c3d.c3l`; the example and test projects resolve the
library by that name.

```bash
git clone --recurse-submodules https://github.com/fesoliveira014/c3d.c3l
cd c3d.c3l
```

If you cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

## Native dependencies

VMA native archives are fetched for its pinned release; spvreflect.c3l carries prebuilt
artifacts. c3imgui.c3l v0.1.2 downloads its
Linux/Windows archives from release assets and verifies their checksums. box3d is built from
its vendored sources, and SDL3 comes from source because Ubuntu 24.04 does not package it.

Initialize native dependencies:

```bash
python3 scripts/build.py --init-deps --skip-abi --skip-shaders --skip-build
```

That installs the ImGui archives under `lib/c3imgui.c3l/linked-libs/` and leaves `libbox3d.a`
in `lib/box3d.c3l/linked-libs/linux-x64/`. Ordinary builds do not download archives.
They compile the vendored `csrc/stb_image.c` with c3c's selected C compiler.

The released Linux ImGui archive references `__isoc23_sscanf`, unavailable on the verified
Ubuntu 22.04/glibc 2.35 host. On that host, build the matching native package from source
after initialization as described in [GUI native builds](docs/gui_native_build.md). Re-running
`--init-deps` downloads the release archive again.

SDL3, pinned at `release-3.4.16`:

```bash
git clone --depth 1 --branch release-3.4.16 https://github.com/libsdl-org/SDL .deps/SDL
cmake -S .deps/SDL -B .deps/SDL/build -DCMAKE_BUILD_TYPE=Release
cmake --build .deps/SDL/build
sudo cmake --install .deps/SDL/build
sudo ldconfig
```

`.deps/` is gitignored. Installing into the default prefix is what lets the linker find `SDL3`
without extra link arguments; a private prefix needs a `-L` in `examples/project.json`.

### Windows

Prerequisites: Visual Studio 2022 with the C++ desktop workload, CMake, Ninja, Git for Windows,
the Vulkan SDK (`glslangValidator` and the loader), Python 3.10 or newer, and c3c 0.8.3 on PATH.
c3c compiles `csrc/stb_image.c` itself; no separate C compiler setting is needed.

Clone under a short path with symlinks enabled. `lib/c3d.c3l` is a symlink the projects resolve
through, and Git only creates it as a real link when Developer Mode is on or the shell is elevated:

```powershell
git clone -c core.symlinks=true --recurse-submodules https://github.com/fesoliveira014/c3d.c3l C:\repos\c3d.c3l
cd C:\repos\c3d.c3l
```

Dependency initialization locates Git Bash beside the Git installation on PATH and loads
its Unix tools. The Box3D build locates MSVC through `vswhere`:

```powershell
python scripts\build.py --init-deps --skip-abi --skip-shaders --skip-build
python scripts\build.py --test
c3c run cube --path examples
```

`--init-deps` fetches the VMA and ImGui archives with checksums and builds
`lib/box3d.c3l/linked-libs/windows-x64/box3d.lib` with MSVC. Every Windows archive is built
against the static CRT, and the c3d manifest and bundled projects declare `"wincrt": "static"`
to match; a consumer on the dynamic CRT fails at link with
`lld-link: error: /failifmismatch: mismatch detected for 'RuntimeLibrary'`.

No `SDL3.dll` is deployed: the static SDL3 inside the ImGui package is what the linker resolves.
The Vulkan loader `vulkan-1.dll`, installed by GPU drivers and the SDK, is required at process
start by every example and by the test binary. Third-party Vulkan layers with broken manifests
print `loader_get_json` errors at startup; they are harmless.

Half-precision conversions do not link on Windows with c3c 0.8.3, so the library converts
`RGBA16_FLOAT` texels in software; see the
[issue record](https://app.notion.com/p/3dacb7903a588141bbb2f208b0f8cccd). No user action is needed.

## Build, test, run

```bash
python3 scripts/build.py                  # compile SPIR-V, verify committed generated C3, build examples
python3 scripts/build.py --test           # same, then run every test target; what CI runs
python3 scripts/build.py --regen          # rewrite the generated ABI twins and registry table, then build
python3 scripts/build.py --example hello  # build and run one example
python3 scripts/build.py --clean
```

`-v` prints every command. GPU examples are run by hand; CI has no GPU.

The ordinary builds below leave profiling out. Before using an example's
`--gpu-timings` option, compile that target with the add-on selected (replace
`shadows` with the desired target):

```bash
c3c build shadows --path examples --lib c3d_profile -D C3D_PROFILE_GPU -D C3D_PROFILE_INTERNAL
```

See [profiling](docs/profiling.md) for capture configuration and the headless
`profile_gpu` example.

`cube` is the first-mesh example. `cube_gui` adds the [GUI overlay](docs/gui.md) to the
same scene, with transform/material editing, statistics and a Spin toggle that starts off:

```bash
python3 scripts/build.py --example cube
python3 scripts/build.py --example cube_gui
```

`pbr` provides a static metallic/roughness sphere grid with directional, point
and spot lights, plus base-color, metallic/roughness, normal, occlusion and
emissive maps. Its GUI edits each selected map's UVs and sampler, switches between
supplied and derived tangent frames using two sphere assets, and offers mapped
and scalar-only presets. Material factors, lights, ambient, receiver layers and
camera projection remain editable:

```bash
python3 scripts/build.py --example pbr
```

Drag outside the GUI to orbit, scroll to zoom, and release Escape to quit.
See [Materials and lighting](docs/materials.md) for factors, layer masks,
light capacity and current rendering limits.

`many_lights` compares flat and clustered Forward+ on a fixed procedural hall with
64, 256, 1024 or 4096 point lights. The targets panel switches selection modes and
shows a selected cluster-depth slice; workload controls adjust range and per-cell
capacity, including deliberate overflow with complete flat fallback:

```bash
python3 scripts/build.py --example many_lights
```

See [Many lights](docs/many_lights.md) for controls, buffer ownership, material
exceptions and separate wall/CPU/GPU comparison measurements.

`materials` combines masked foliage, ordinary premultiplied alpha blending, Toon
lighting and Physical clearcoat/sheen/specular/anisotropy/transmission in one
interactive window. Its controls switch presets, active families, base and layer
maps, two colored lights, ambient fill and either bundled HDR environment:

```bash
python3 scripts/build.py --example materials
```

The example generates its alpha, nonuniform ramp and Physical map fixtures in
memory. It reuses both bundled CC0 HDRs, so it requires no runtime download.

`post` shows [display processing](docs/post.md) on a rolled textured cube, a
chrome sphere and an emissive sphere under a bright sun. Its panel switches the
tone mapping operator, FXAA and an identity LUT, and edits contrast, saturation,
white balance and lift-gamma-gain; the controls panel drives camera exposure:

```bash
python3 scripts/build.py --example post
```

`effects` adds the [post-processing effects](docs/post.md) to the same kind of scene: an
emissive lamp under bloom, a row of marbles for focus pulling, a fast-spinning cube and a camera
sweep. Effects start enabled; the post panel's sections toggle and tune each one:

```bash
python3 scripts/build.py --example effects
```

`deferred` renders one scene forward on the left and deferred on the right, switches either
half at runtime and shows the G-buffer channels through the targets panel; see the
[shading path](docs/views.md#shading-path) section.

`shading_paths` renders one scene with many lights and two custom materials through every
shading path and light selection pair in a 2x2 grid, with a per-view switch and a side-by-side
stats table:

```bash
python3 scripts/build.py --example shading_paths
```

`views` renders the same kind of scene twice per frame through [views and render
targets](docs/views.md): a producer camera writes a capture target that a monitor slab samples
through its material, while the window camera shows the whole scene. Its panel resizes the
capture, switches it between display LDR and linear HDR output, and scales the window view:

```bash
python3 scripts/build.py --example views
```

`picking` selects meshes with the mouse through [CPU picking](docs/picking.md): two transformed
boxes are picked before the first frame, a glTF model is instantiated twice and either instance
is selected by click, and a click on the monitor slab picks again through the capture camera it
shows. Its panel switches between bounds and triangle precision and between face policies, and
reports the hit's distance, triangle and barycentric weights:

```bash
python3 scripts/build.py --example picking
./examples/build/picking [model.glb]
```

`custom_shader` draws a tinted sphere and a pulsing box through [custom shaders](docs/custom_shaders.md):
their GLSL lives in `examples/shaders/custom/`, is compiled in process, and is reloaded when a file
changes or on R. The box's vertex deformation is shared by its shadow, P pauses the pulse, and a
broken edit is rejected by the backend while the previous shader keeps drawing:

```bash
python3 scripts/build.py --example custom_shader
```

`custom_compute` runs a particle simulation on the GPU through [compute dispatch](docs/custom_shaders.md#compute-dispatch):
a compute stage advances a renderer-owned buffer every frame and a custom material draws it from the
same buffer, with the emitter fed through an upload buffer. All three GLSL files reload on change or
R, Space reseeds, and a broken compute push block is rejected while the previous revision keeps running:

```bash
python3 scripts/build.py --example custom_compute
```

`compute_textures` writes a noise texture on the GPU every frame and fogs the view in place: an empty
storage texture is filled by a compute stage and bound as a material map, and a second dispatch
between `render_view` and `finish_view` samples the view's depth and blends fog into its scene image.
F toggles the fog, N freezes the noise, both GLSL files reload on change or R:

```bash
python3 scripts/build.py --example compute_textures
```

`ibl` lights a metallic/roughness sphere grid with two bundled HDR environments.
Its controls independently select lighting and background, adjust rotation and
intensity, demonstrate diffuse-only occlusion, and apply per-environment processing
resolutions. Both sources are prepared before the first frame:

```bash
python3 scripts/build.py --example ibl
```

See [Environments and image-based lighting](docs/environments.md) for defaults,
source ownership, preparation and current display limits. The
[bundled HDRs](examples/assets/ibl/README.md) are CC0 and require no runtime download.

`shadows` demonstrates sun cascades, spot projection and all six point faces with
solid, masked and off-camera casters. Its small GUI adjusts kind-specific coverage,
bias and whole-light atlas priority:

```bash
python3 scripts/build.py --example shadows
```

Directional constructors enable shadows by default; point and spot shadows are
enabled explicitly. The example's six-layer atlas allocates 96 MiB of depth texels
on first accepted use. See [Shadows](docs/shadows.md) for sun, spot and point
casting/receiving, layer masks, capacity and per-layer timings.

`gltf_viewer` loads a glTF or GLB file once and instantiates it twice under a
studio environment with one directional light. The bundled
[BoxTextured](examples/assets/gltf/README.md) sample is the default; a path
argument selects another model:

```bash
python3 scripts/build.py --example gltf_viewer
./examples/build/gltf_viewer path/to/model.glb
```

See [Models, glTF and FBX import](docs/models.md) for keys, options, the material
mapping and the supported extension subset.

`animation` instantiates a model twice and plays a different clip on each
instance through `c3d::anim`, with cross-fades, a quarter-weight action and
pausing on keys. The bundled [Fox](examples/assets/gltf/README.md) is the
default; `BoxAnimated.glb` shows node animation and `AnimatedMorphCube.glb`
morph targets:

```bash
python3 scripts/build.py --example animation
./examples/build/animation examples/assets/gltf/BoxAnimated.glb
```

See [Animation](docs/animation.md) for the update sequence, blending and the
borrowed-pointer rules.

`mixamo` loads an FBX character through ufbx, instantiates it twice and plays
Mixamo animation files retargeted onto it by name: keys `1`-`9` cross-fade the
left instance between clips, the right instance loops the first at half speed,
`R` toggles between the in-place and the kept-root-motion variant. Without
arguments it reads `character.fbx`, `walk.fbx` and `run.fbx` from
`examples/assets/mixamo/`, which are not committed;
[the README there](examples/assets/mixamo/README.md) gives the Mixamo download
settings:

```bash
python3 scripts/build.py --target mixamo
./examples/build/mixamo path/to/character.fbx path/to/walk.fbx path/to/run.fbx
```

See [Models, glTF and FBX import](docs/models.md) for the FBX conversion.

`textured` adds PNG/JPEG maps, mip filtering, UV transforms and alpha masking in a
standalone scene with validation enabled. The default image is embedded:

```bash
python3 scripts/build.py --example textured
./examples/build/textured path/to/albedo.jpg
```

Press N/L/A for nearest/trilinear/anisotropic filtering, S for repeat scale,
R for rotation, O for offset, U for UV0/UV1 and Backspace to reset. Drag to orbit,
scroll to zoom, and release Escape to quit. See [Textures and images](docs/textures.md)
for loading, material slots, HDR data, pixel edits and CPU source release.

`texture_cube` previews a native six-face cube with generated or supplied mips;
`texture_bc` displays a supplied BC1 chain with a different color at each level:

```bash
python3 scripts/build.py --example texture_cube
python3 scripts/build.py --example texture_bc
```

The cube preview selects faces with 1–6, switches generated/supplied sources with
C, and controls LOD with L and +/−. The BC example uses N/L/A filtering, mouse
orbit and wheel zoom. Both enable full validation. See
[cube loading](docs/textures.md#load-six-cube-faces) and
[supplied mip data](docs/textures.md#supply-mip-levels) for source ownership and
the remaining unsupported texture forms.

## Using c3d from your own project

The optional `c3d_profile` add-on bundles CPU and GPU capture with JSON export.
CPU-only use needs no renderer or native dependencies; GPU profiling selects its
backend module explicitly. Core does not require the package in ordinary builds.
See [profiling](docs/profiling.md) for capture lifetimes, feature selection and
frame-wide GPU pass summaries. Run its CPU-only example with
`c3c run capture --path addons/c3d_profile.c3l`.

Add c3d and its dependencies to your `project.json`, and list the feature flags you want. A C3
library manifest cannot declare features, so every consumer enables them itself. Declarations
guarded by a feature disappear when it is omitted; the native libraries a feature's module links
stay declared dependencies of the package whether or not the feature is selected, and the image
API and its C translation unit are included regardless of the `C3D_STB_IMAGE` indicator. The
`*_ENABLED` constants in `c3d` exist exactly when their feature was selected:

```json
{
  "dependency-search-paths": [ "path/to/c3d.c3l/lib" ],
  "dependencies": [ "c3d", "gpu", "vk", "vma", "spvreflect", "sdl3", "c3imgui", "c3cg", "b3", "shaderc" ],
  "features": [ "C3D_GUI", "C3D_PHYSICS", "C3D_FBX", "C3D_RAY_TRACING", "C3D_STB_IMAGE", "C3D_SHADER_COMPILER" ]
}
```

| Feature | Enables |
| --- | --- |
| `C3D_GUI` | the developer GUI declarations (imgui stays a declared dependency) |
| `C3D_PHYSICS` | the physics declarations (box3d stays a declared dependency) |
| `C3D_FBX` | the FBX importer declarations (ufbx stays a declared dependency) |
| `C3D_RAY_TRACING` | the ray tracing declarations |
| `C3D_STB_IMAGE` | indicator only; the image API and native decoder compile when absent |
| `C3D_SHADER_COMPILER` | in-process GLSL compilation (`shader::compile`), and shaderc; custom shaders from SPIR-V bytes work without it |

## Contributing

`AGENTS.md` and `docs/style.md` are mandatory reading. See `CONTRIBUTING.md`.
