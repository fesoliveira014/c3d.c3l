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
| CMake and a C compiler | any | for SDL3 and box3d |

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

vma.c3l, c3imgui.c3l and spvreflect.c3l ship prebuilt artifacts. box3d is built from its vendored
sources, and SDL3 comes from source because Ubuntu 24.04 does not package it.

box3d:

```bash
python3 scripts/build.py --init-deps --skip-abi --skip-shaders --skip-boundaries --skip-build
```

That leaves `libbox3d.a` in `lib/box3d.c3l/linked-libs/linux-x64/`.

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
python3 scripts/build.py                  # regenerate ABI and shaders, check boundaries, build examples
python3 scripts/build.py --test           # same, then run every test target
python3 scripts/build.py --check --test   # what CI runs: generated files must be current
python3 scripts/build.py --example hello  # build and run one example
python3 scripts/build.py --clean
```

`-v` prints every command. GPU examples are run by hand; CI has no GPU.

## Using c3d from your own project

Add c3d and its dependencies to your `project.json`, and list the feature flags you want. A C3
library manifest cannot declare features, so **every consumer enables them itself** — omit one and
the declarations behind it do not exist:

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
| `C3D_STB_IMAGE` | image decoding, and stb_image |

## Contributing

`AGENTS.md` and `docs/style.md` are mandatory reading. See `CONTRIBUTING.md`.
