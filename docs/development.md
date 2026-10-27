# Development

How to build, test and run c3d from a checkout: the build pipeline, the shader pipeline, native libraries, test and example
targets, the manual GPU acceptance projects and headless runs. The binding verification policy (what to run before review and
merge) is [AGENTS.md](../AGENTS.md) section 5. Layers, packages and feature flags are in [architecture.md](architecture.md).

## Requirements

- c3c 0.8.5_1, exactly. The build refuses any other version.
- Python 3.10 or newer. The scripts use the standard library only.
- `glslangValidator` on `PATH` (a Vulkan SDK, or `glslang-tools` on Ubuntu), or pass `--glslang`.
- The system Vulkan loader. Every c3d executable, test binaries included, imports it at process start.
- A C compiler. c3c compiles `csrc/` and the C sources of cgltf, ufbx, clay and miniaudio; on Windows that is MSVC.
- git, to fetch the dependency submodules.

Windows commands in this repository use `python` where Linux uses `python3`.

## Build

Run from the repository root.

```bash
python3 scripts/build.py --init-deps      # first checkout: submodules and dependency natives
python3 scripts/build.py                  # compile SPIR-V, verify generated files, build every example
python3 scripts/build.py --test           # the same, then every test target; this is what CI runs
python3 scripts/build.py --regen          # rewrite the generated files, then build
python3 scripts/build.py --example cube   # build and run one example
python3 scripts/build.py --clean          # remove c3c build directories
```

Narrowing options: `--skip-abi`, `--skip-shaders`, `--skip-build`, `--target <name>` (build one example target),
`--opt O3`, `-v` (print each command). `--define <FLAG>` and `--lib <name>` add a feature and a library to a `--target`
build:

```bash
python3 scripts/build.py --target shadows --lib c3d_profile --define C3D_PROFILE_GPU --define C3D_PROFILE_INTERNAL
```

The steps run in this order and stop at the first failure.

| Step | What it does |
| --- | --- |
| tools | Checks Python and c3c 0.8.5_1, and glslang unless `--skip-shaders` is given. |
| deps | Checks that the submodules under `lib/` exist and that the ImGui native archive is present. With `--init-deps`, first updates the submodules and fetches the natives. |
| abi | Runs `scripts/gen_abi.py` to verify the C3 and GLSL twins of `abi/c3d.abi`. The first run builds gpu.c3l's `gpu_shaders` generator. |
| shaders | Runs `scripts/build_shaders.py --check`: compiles every stage, probe and shader package, then verifies the committed generated tables. |
| build | Builds every target of `examples/project.json` and every add-on example, or only `--target`. Places the shaderc shared library next to the executables. |
| test | With `--test`: runs the unit tests of the scripts (`scripts/test_*.py`), then every test target below. |
| run | With `--example`: runs that example. |

`--regen` makes the abi and shaders steps rewrite the committed generated files instead of verifying them (the shaders step then runs `build_shaders.py` without `--check`). An example name
resolves to its package project through the `ADDON_EXAMPLES` table in `scripts/build.py`.

Examples that use Vulkan open a window and a device. GPU examples set `validation = true` in their renderer description, so
every development run has the validation layer on.

## Native libraries

`--init-deps` runs `git submodule update --init --recursive`, then downloads the natives of sdl3, c3imgui, box3d, shaderc,
vma and spvreflect. Each comes from the release of its repository at the tag the submodule is pinned to, for the host
platform, and is checked against that release's `SHA256SUMS`. The files land in the `linux/`, `windows/` and `linked-libs/`
directories of the submodule. Nothing is compiled.

- SDL3 and Dear ImGui link statically on Linux and Windows.
- shaderc is a shared library. The build copies `libshaderc_shared.so.1` (Linux) or `shaderc_shared.dll` (Windows) next to the
  example and test executables; on Linux its manifest sets the runpath to `$ORIGIN`. Many projects list shaderc as a dependency, but only an
  executable with code under `C3D_SHADER_COMPILER` needs the library at run time.
- To build the ImGui natives locally instead of downloading them, see [Rebuild the native archive](gui.md#rebuild-the-native-archive).

## Shader pipeline

GLSL sources live in `shaders/` as `<name>.<stage>.glsl`; shared includes are plain `.glsl` under `shaders/common/`,
`shaders/generated/` and `shaders/gpu/`. `shaders/gpu/` is a committed copy of gpu.c3l's `include/shaders`, refreshed by
`--regen` and checked otherwise.

`shaders/variants.json` lists each stage source with its glslang stage and defines, and the `public_includes`: the includes
that custom and package stages may rely on. `scripts/build_shaders.py` does the following in one run:

1. Compiles every entry to `shaders/spv/<name>.spv`. SPIR-V is build output and is not committed.
2. Compiles one probe per `public_includes` row (include, stage and defines) after the two ABI headers alone, so each public
   include includes everything it uses.
3. Builds every shader package: a directory under `addons/*/` or `test/` with `shaders/shaders.json` (module, output file,
   flags, entries). A package compiles against core's include roots plus its own `shaders/include/<name>/`, and writes SPIR-V
   to its own `shaders/spv/` and a C3 file holding the `$embed` constants and, when it has includes, a public
   `<NAME>_SHADER_INCLUDES` table. The packages are `addons/c3d_landscape.c3l`, `addons/c3d_particle.c3l` and `test`
   (manifest `test/shaders/shaders.json`).
4. Verifies the committed tables, or writes them when `--check` is absent: `src/c3d/shader/variants.c3` (the `ShaderName`
   enum, flags and the embedded SPIR-V table), `src/c3d/shader/includes.c3` (the GLSL include set, which the in-process
   compiler resolves without a filesystem), the `shaders/gpu/` copy and each package's output file. `build.py` passes
   `--check` unless `--regen` is given. Without `--check`, the script refreshes the `shaders/gpu/` copy before the compiles.

Shared layouts live in `abi/c3d.abi`. `scripts/gen_abi.py` generates `src/c3d/shader/abi.c3` and
`shaders/generated/c3d_abi.glsl` from it. The generated C3 and GLSL files are committed and verified on every build; never
edit them by hand, and never change a layout on one side only.

An application outside the repository compiles its own shader package with the shader tools archive of a release (see
[release.md](release.md#shader-packages)) or, from a checkout, with:

```bash
python3 lib/c3d.c3l/scripts/build_shaders.py --package path/to/package
```

`--package` compiles only the named packages (repeatable) and needs only `scripts/build_shaders.py` and
`shaders/{common,generated,gpu}`. `--check` verifies the committed output instead of writing it.

## Examples in the default build

The default build builds every target of `examples/project.json` and every add-on example. Package examples are built
from their package project. Run any of them with `--example`, for instance `python3 scripts/build.py --example physics`.

| Project | Examples |
| --- | --- |
| `examples/` | every target in `examples/project.json`, including the four `profile_gui` feature targets and the root `profile_gpu` example |
| `addons/c3d_profile.c3l` | `capture` |
| `addons/c3d_physics.c3l` | `physics`, `physics_instanced`, `physics_components`, `vehicle`, `ragdoll`, `collision_math`, `breakable`, `cloth` |
| `addons/c3d_nav.c3l` | `navmesh`, `crowd`, `grid`, `nav_persistence` |
| `addons/c3d_character.c3l` | `character`, `character_nav`, `rebase_bench` |
| `addons/c3d_physics_gui.c3l` | `physics_inspector`, `physics_inspector_character` |
| `addons/c3d_job.c3l` | `job_bench` |
| `addons/c3d_landscape.c3l` | `terrain`, `vegetation`, `water`, `water_gpu` |
| `addons/c3d_particle.c3l` | `particles`, `particles_gpu` |
| `addons/c3d_ui.c3l` | `ui` |
| `addons/c3d_audio.c3l` | `audio` |

A new target in `examples/project.json` is built automatically. A new package example is added to `ADDON_EXAMPLES` in
`scripts/build.py`.

## Test targets

`--test` first runs `scripts/test_*.py` with `unittest`, then every target below with `c3c test <target> --path <project>`.
These targets never create a GPU device and run in CI. Each package keeps its tests in its own project.

| Project | Targets run by `--test` |
| --- | --- |
| `test/` | every target in `test/project.json`: `unit`, `describe`, `ecs_cap`, `gamepad` and the root profiler integration targets `profile_application`, `profile_internal`, `profile_off`, `profile_gpu`, `profile_gpu_internal`, `profile_cpu_gpu`, `profile_full` |
| `addons/c3d_profile.c3l` | `profile_off`, `profile_cpu`, `profile_internal`, `profile_gpu`, `profile_gpu_internal`, `profile_cpu_gpu`, `profile_full` |
| `addons/c3d_profile_gui.c3l` | `panel_off`, `panel_cpu`, `panel_gpu`, `panel_combined` |
| `addons/c3d_physics.c3l` | `physics_test`, `physics_serial_test`, `physics_serial_policy_test` |
| `addons/c3d_nav.c3l` | `nav_test`, `nav_serial_test`, `nav_serial_policy_test` |
| `addons/c3d_character.c3l` | `character_test`, `character_nav_test`, `character_serial_test`, `character_nav_serial_test`, `character_serial_policy_test`, `character_nav_serial_policy_test` |
| `addons/c3d_physics_gui.c3l` | `physics_panel_off`, `physics_panel`, `physics_panel_character` |
| `addons/c3d_job.c3l` | `job_test`, `job_profile_test` |
| `addons/c3d_landscape.c3l` | `landscape_test`, `landscape_gpu_test`, `landscape_serial_test`, `landscape_serial_policy_test` |
| `addons/c3d_particle.c3l` | `particle_test`, `particle_serial_test`, `particle_serial_policy_test` |
| `addons/c3d_serial.c3l` | `serial_test`, `serial_order_forward`, `serial_order_reverse`, `serial_text_test`, `serial_described_test`, `serial_core_policy_test`, `serial_all_test` |
| `addons/c3d_ui.c3l` | `ui_test` |
| `addons/c3d_audio.c3l` | `audio_test`, `audio_serial_test`, `audio_serial_policy_test` |

The feature targets enable the flags described in [architecture.md](architecture.md#feature-flags) in their `project.json`; the serialization adapter targets are described in [AGENTS.md](../AGENTS.md) section 1.3. The serial package's `serial_lookup_bench` and `serial_claims_bench` stay outside `--test`.
A new package test target is added to the matching `*_TEST_TARGETS` tuple in `scripts/build.py`. A direct
`c3c test profile_cpu --path addons/c3d_profile.c3l` exercises only the standalone collector package.

Run one target, or one test, directly:

```bash
c3c test physics_test --path addons/c3d_physics.c3l
c3c test unit --path test --test-filter test_remove_shader_makes_id_stale
```

## Acceptance projects

Acceptance projects exercise the renderer and the GPU add-on modules on a real Vulkan device. They are manual: they do not
run under `--test` or in CI, and they create a device with validation enabled. Build the repository once first, so
`shaders/spv/` and the generated tables exist.

| Project | Targets | Output directory | Needs the shaderc library at run time |
| --- | --- | --- | --- |
| `test/gpu/render` | `acceptance`; executables `origin_bench` and `posed_trace_bench`, built with `c3c build <name> --path test/gpu/render` and run from the repository root as `build/render_acceptance/<name>` | `build/render_acceptance` | yes |
| `test/gpu/profile` | `acceptance` | `build/profile_gpu` | yes; `build.py` places it |
| `test/gpu/animated_crowd` | `acceptance` | `test/gpu/animated_crowd/build` | yes |
| `test/gpu/animation_authoring` | `acceptance` | `test/gpu/animation_authoring/build` | yes |
| `addons/c3d_physics.c3l/test/gpu` | `cloth_acceptance` | `build/cloth_acceptance` | no |
| `addons/c3d_landscape.c3l/test/gpu` | `terrain_acceptance`, `water_acceptance`, `water_gpu_acceptance` | `addons/c3d_landscape.c3l/build/terrain_acceptance` | yes |
| `addons/c3d_particle.c3l/test/gpu` | `particle_acceptance`, `particle_gpu_acceptance` | `build/particle_acceptance` | `particle_gpu_acceptance` only |
| `addons/c3d_ui.c3l/test/gpu` | `ui_acceptance` | `build/ui_acceptance` | no |

Run a project with `c3c test <target> --path <project>`, for example `c3c test acceptance --path test/gpu/render`;
`--test-filter <name>` selects one test. Every project lists shaderc as a dependency, but only an executable with code under
`C3D_SHADER_COMPILER` needs the library at run time; the last column marks those projects. `build.py` places the library
only in the output directory of `test/gpu/profile`, when it builds the default set or the `profile_gpu` example. For every
other project marked yes, copy `lib/shaderc.c3l/linux/libshaderc_shared.so.1` (Linux) or
`lib/shaderc.c3l/windows/shaderc_shared.dll` (Windows) next to the built `testrun` executable before running. Build
without running by adding `--suppress-run`: `c3c test acceptance --path test/gpu/render --suppress-run`.

Each project's README, where it has one, lists what it covers and what it cannot show: [render](../test/gpu/render/README.md), [profile](../test/gpu/profile/README.md), [animated crowd](../test/gpu/animated_crowd/README.md) and [animation authoring](../test/gpu/animation_authoring/README.md). The [describe](../test/describe/README.md) README covers the `c3d::describe` test consumers, and the CPU tests' committed inputs are in the [fixtures](../test/fixtures/README.md) README.

## Headless and WSL runs

WSL and machines without a GPU run the acceptance projects on a software Vulkan driver (lavapipe, Mesa's CPU implementation).

On WSL, a wedged WSLg compositor blocks Vulkan device enumeration: Mesa's drivers wait on the Wayland socket, which accepts
the connection and never answers. `vulkaninfo --summary` and every device-creating test then hang with no error. Run headless
with the display variables unset and an empty private runtime directory, and bound the run on the built `testrun` itself,
because `timeout` on `c3c` does not stop its child:

```bash
mkdir -p /tmp/c3d-xdg && chmod 700 /tmp/c3d-xdg
c3c test acceptance --path test/gpu/render --suppress-run   # build only
cd test/gpu/render
env -u DISPLAY -u WAYLAND_DISPLAY XDG_RUNTIME_DIR=/tmp/c3d-xdg \
  VK_ICD_FILENAMES=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json) \
  timeout -k 5 300 ../../../build/render_acceptance/testrun --test-filter <name>
```

Windowed examples cannot run while the compositor is wedged. `wsl --shutdown` from Windows recovers it but ends every WSL
session on the host.

Also restrict the Vulkan loader to lavapipe on WSL: WSL's `dzn` driver and `libd3d12core` abort the process after a few
hundred instance creations, and every test fixture creates one. Set `VK_ICD_FILENAMES` as above, or
`VK_LOADER_DRIVERS_SELECT='*lvp*'` when `LD_LIBRARY_PATH` selects the SDK loader (the system loader 1.3.204 ignores the second
variable). Never set either on a native GPU host, where the suite must run on the GPU.

lavapipe applies the first attachment's blend equation to every attachment, so a case that checks weighted blending needs
a hardware run.

## Continuous integration

`.github/workflows/ci.yml` runs on every pull request and on pushes to `main`, on Ubuntu 24.04 and Windows 2022:

1. Check out with submodules.
2. Install c3c 0.8.5_1, glslang and the Vulkan loader (and the Vulkan SDK on Windows).
3. `python3 scripts/build.py --init-deps --skip-abi --skip-shaders --skip-build` to fetch the natives.
4. `python3 scripts/build.py --test`.

`.github/workflows/release.yml` reuses `ci.yml` on a `v*` tag, then packs and publishes the release; see
[release.md](release.md#making-a-release).

## See also

- [AGENTS.md](../AGENTS.md): the verification policy for changes.
- [architecture.md](architecture.md): packages, feature flags and the directory map.
- [style.md](style.md): the code style baseline.
- [REVIEW.md](../REVIEW.md): how a change is reviewed, including the runs a reviewer performs.
- [release.md](release.md): packages, dependencies and how to cut a release.
- [benchmarking.md](benchmarking.md) and [profiling.md](profiling.md): measurement tools.
