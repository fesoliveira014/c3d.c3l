# Releases

Each c3d release publishes every package as a packed C3 library: a zip whose root holds `manifest.json`. All
packages share the release version.

| File | Library name | Holds |
| --- | --- | --- |
| `c3d_core-v<version>.c3l` | `c3d` | core sources, stb C sources, compiled SPIR-V and the GLSL includes |
| `c3d_<add-on>-v<version>.c3l` | `c3d_<add-on>` | one add-on's sources and, for landscape and particle, its SPIR-V |
| `c3d_shader_tools-v<version>.zip` | none | `build_shaders.py` and the GLSL includes, for an application's own shader packages |
| `SHA256SUMS` | none | checksums of every file above |

No c3d file contains a dependency. Each dependency publishes its own release, and the release notes list the exact
version of each one c3d was built and tested against. The same pins sit in the packed core manifest under
`vendor.c3d.requires`. c3c resolves a library by the name its manifest `provides`, not by the file name, so the
versioned file names need no renaming.

## Using a release

1. Download into your project's `lib/`, for one platform (`linux-x64` or `windows-x64`):
   - `c3d_core-v<version>.c3l` and the add-ons you use;
   - every dependency the release notes list for those packages, from its own repository's release. A dependency
     with native libraries ships `<name>-v<version>-<platform>.c3l`; one without ships `<name>-v<version>.c3l`.
   Keep one platform's files per directory: with two files providing the same name, c3c takes the first it finds.
2. List every library in `project.json`, the dependencies of your dependencies included; c3c does not follow a
   library's own dependency list. The table below gives the names per package.
3. Build as usual. c3c unpacks each library under the build output (`unpacked_c3l/`).

Example for core and physics:

```json
{
  "langrev": "1",
  "dependency-search-paths": ["lib"],
  "dependencies": [
    "c3d", "gpu", "vk", "vma", "spvreflect", "sdl3", "c3imgui", "c3cg", "cgltf", "ufbx",
    "c3d_physics", "b3"
  ],
  "targets": { "game": { "type": "executable", "sources": ["src/**"] } }
}
```

| Package | Also list | With a feature |
| --- | --- | --- |
| `c3d` (core) | `gpu`, `vk`, `vma`, `spvreflect`, `sdl3`, `c3imgui`, `c3cg`, `cgltf`, `ufbx` | `shaderc` with `C3D_SHADER_COMPILER`; `c3d_profile` with `C3D_PROFILE_CPU` or `C3D_PROFILE_GPU` |
| `c3d_physics` | core's list, `b3` | |
| `c3d_nav` | core's list | |
| `c3d_character` | core's list, `c3d_physics`, `b3` | `c3d_nav` with `C3D_CHARACTER_NAV` |
| `c3d_physics_gui` | core's list, `c3d_physics`, `b3` | requires `C3D_PHYSICS_GUI`; `c3d_character` with `C3D_PHYSICS_GUI_CHARACTER` |
| `c3d_job` | core's list | |
| `c3d_landscape` | core's list | |
| `c3d_particle` | core's list | |
| `c3d_serial` | core's list | |
| `c3d_ui` | core's list, `clay` | |
| `c3d_profile` | nothing for CPU capture | `gpu`, `vk`, `vma`, `spvreflect` with `C3D_PROFILE_GPU` |
| `c3d_profile_gui` | `c3d_profile`, `c3imgui`, `sdl3`, `vk` | requires `C3D_PROFILE_GUI` with a capture feature; `gpu`, `vma`, `spvreflect` with `C3D_PROFILE_GPU` |

## Runtime and toolchain

- The Vulkan loader comes from the system (`libvulkan.so.1`, `vulkan-1.dll`).
- SDL3 and Dear ImGui link statically on both platforms; nothing else is copied for them.
- With `C3D_SHADER_COMPILER`, copy the shaderc shared library next to your executable: after a build it is at
  `build/unpacked_c3l/shaderc-v<version>-<platform>.c3l/linux/libshaderc_shared.so.1` or
  `.../windows/shaderc_shared.dll`, or unzip it from the artifact. On Linux the shaderc library sets the runpath to
  `$ORIGIN`.
- c3c compiles the C sources some libraries carry (stb in core, cgltf, ufbx, clay) with the system C compiler;
  on Windows that is MSVC.
- Linux native libraries are built on Ubuntu 22.04 and need glibc 2.35 or newer.

## Shader packages

An application's own shader package (a directory with `shaders/shaders.json`, see
[custom shaders](custom_shaders.md#shader-packages)) compiles with the release's shader tools, which carry the
same includes core was built with:

```bash
unzip c3d_shader_tools-v<version>.zip
python3 c3d_shader_tools/scripts/build_shaders.py --package path/to/package
```

`--check` verifies the committed output instead of writing it. The tools need Python 3.10+ and `glslangValidator` on
`PATH`.

## Making a release

1. Every `lib/` submodule, and gpu.c3l's own `lib/` submodules, sits on a released tag of its repository.
2. `main` is green.
3. Push a tag `v<version>`. `.github/workflows/release.yml` runs CI on Linux and Windows, compiles SPIR-V,
   runs `scripts/package_release.py` and publishes the files above with the pin table as release notes.

`scripts/package_release.py --version <version> --out dist` refuses to pack when the tree has tracked modifications, `LICENSE` is empty,
a submodule is off a tag, SPIR-V has not been compiled, or a packed source embeds a file its artifact lacks. Equal
inputs give equal bytes: entries are sorted and dated 1980-01-01.
