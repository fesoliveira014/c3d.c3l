# c3d

A scene-level 3D rendering library for [C3](https://c3-lang.org/): an ECS scene, physics,
animation, and asset import, on top of Vulkan 1.3 through gpu.c3l. Not a game engine; a base
for one.

Target platforms are linux-x64 and windows-x64. C3 0.8.3 exactly.

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
artifacts. c3imgui.c3l v0.1.1 downloads its
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

Install Visual Studio with the C++ desktop tools, CMake, Ninja, and Git for Windows. The native
Box3D build uses Git Bash and locates MSVC through `vswhere`. From PowerShell, make Git's shell
available for the current process before initializing dependencies:

```powershell
$env:PATH = 'C:\Program Files\Git\bin;' + $env:PATH
python scripts/build.py --init-deps --test
```

Box3D produces `lib/box3d.c3l/linked-libs/windows-x64/box3d.lib`. Windows consumers use
`"wincrt": "static"` to match that archive; the c3d manifest and bundled projects select it.
The pinned SDL3 binding ships its Windows library, so the Linux SDL3 installation steps above
do not apply. Keep `glslangValidator` from the Vulkan SDK on PATH.

## Build, test, run

```bash
python3 scripts/build.py                  # compile SPIR-V, verify committed generated C3, build examples
python3 scripts/build.py --test           # same, then run every test target; what CI runs
python3 scripts/build.py --regen          # rewrite the generated ABI twins and registry table, then build
python3 scripts/build.py --example hello  # build and run one example
python3 scripts/build.py --clean
```

`-v` prints every command. GPU examples are run by hand; CI has no GPU.

`cube` is the first-mesh example. `cube_gui` adds the [GUI overlay](docs/gui.md) to the
same scene, with transform/material editing, statistics and a Spin toggle that starts off:

```bash
python3 scripts/build.py --example cube
python3 scripts/build.py --example cube_gui
./examples/build/cube_gui --gpu-timings
```

`pbr` provides a static metallic/roughness sphere grid with directional, point
and spot lights, plus base-color, metallic/roughness, normal, occlusion and
emissive maps. Its GUI edits each selected map's UVs and sampler, switches between
supplied and derived tangent frames using two sphere assets, and offers mapped
and scalar-only presets. Material factors, lights, ambient, receiver layers and
camera projection remain editable:

```bash
python3 scripts/build.py --example pbr
./examples/build/pbr --gpu-timings
```

Drag outside the GUI to orbit, scroll to zoom, and release Escape to quit.
See [Materials and lighting](docs/materials.md) for factors, layer masks,
light capacity and current rendering limits.

`ibl` lights a metallic/roughness sphere grid with two bundled HDR environments.
Its controls independently select lighting and background, adjust rotation and
intensity, demonstrate diffuse-only occlusion, and apply per-environment processing
resolutions. Both sources are prepared before the first frame:

```bash
python3 scripts/build.py --example ibl
./examples/build/ibl --gpu-timings
```

See [Environments and image-based lighting](docs/environments.md) for defaults,
source ownership, preparation and current display limits. The
[bundled HDRs](examples/assets/ibl/README.md) are CC0 and require no runtime download.

`shadows` demonstrates sun cascades, spot projection and all six point faces with
solid, masked and off-camera casters. Its small GUI adjusts kind-specific coverage,
bias and whole-light atlas priority:

```bash
python3 scripts/build.py --example shadows
./examples/build/shadows --gpu-timings
```

Directional constructors enable shadows by default; point and spot shadows are
enabled explicitly. The example's six-layer atlas allocates 96 MiB of depth texels
on first accepted use. See [Shadows](docs/shadows.md) for sun, spot and point
casting/receiving, layer masks, capacity and per-layer timings.

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

Add c3d and its dependencies to your `project.json`, and list the feature flags you want. A C3
library manifest cannot declare features, so every consumer enables them itself. Declarations
guarded by a feature disappear when it is omitted; the image API and its C translation unit
are currently included regardless of the `C3D_STB_IMAGE` indicator:

```json
{
  "dependency-search-paths": [ "path/to/c3d.c3l/lib" ],
  "dependencies": [ "c3d", "gpu", "vk", "vma", "spvreflect", "sdl3", "c3imgui", "c3cg", "b3" ],
  "features": [ "C3D_GUI", "C3D_PHYSICS", "C3D_FBX", "C3D_RAY_TRACING", "C3D_STB_IMAGE" ]
}
```

| Feature | Enables |
| --- | --- |
| `C3D_GUI` | the developer GUI, and imgui |
| `C3D_PHYSICS` | physics, and box3d |
| `C3D_FBX` | the FBX importer |
| `C3D_RAY_TRACING` | ray tracing |
| `C3D_STB_IMAGE` | image support indicator; does not exclude the API or native decoder when absent |

## Contributing

`AGENTS.md` and `docs/style.md` are mandatory reading. See `CONTRIBUTING.md`.
