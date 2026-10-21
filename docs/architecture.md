# Architecture

c3d is a scene-level 3D rendering library: an ECS scene, an asset store, animation, a renderer over Vulkan 1.3 and optional
add-on packages for physics, navigation, UI, audio and more. It is a base for a game engine, not an engine. This page maps
the layers, the modules, the add-on packages, the feature flags and the directory layout. The binding import rules are in
[AGENTS.md](../AGENTS.md) sections 1 and 10; the build is in [development.md](development.md).

## Layers

| Layer | Modules | Role |
| --- | --- | --- |
| Scene | `c3d`, `c3d::maths`, `c3d::ecs`, `c3d::describe`, `c3d::asset`, `c3d::scene`, `c3d::geometry`, `c3d::camera`, `c3d::material`, `c3d::light`, `c3d::anim`, `c3d::model`, `c3d::spatial`, `c3d::debug` and the CPU add-ons | CPU data and systems. Holds no GPU object and runs without a device. |
| Platform | `c3d::platform` | Window, input, events, gamepads and actions over SDL3. |
| Render | `c3d::render`, `c3d::render::post`, `c3d::shader`, `c3d::gui` | Owns every GPU object. Reads the scene and the asset store; mirrors assets in renderer-owned records. |
| UI | `c3d::ui` (add-on) | Draws game UI into the renderer's overlay list. |

Data flows one way. The application edits the scene and the asset store, and calls systems (animation update, physics step,
navigation, particles) as plain functions; there is no scheduler. `Renderer.render` then runs `begin_frame`, `render_view`,
`finish_view` and `end_frame`: the renderer reads the scene, uploads what changed and records the passes. The scene never
calls the renderer, and loaders write the asset store and the scene without touching the renderer. Pass order is fixed and
barriers are explicit.

An asset reaches the GPU through a typed generational id. The store owns the CPU data and bumps a revision when it changes;
the renderer resolves the id to its mirror, uploading on first use or when the revision moved. Frames are recorded against
camera-relative origins; see [large worlds](large_world.md).

## Core modules

| Module | Contents |
| --- | --- |
| `c3d` | Ids (`types.c3`), root faults (`faults.c3`), the neutral `ParallelFor` hook (`parallel.c3`) and `VERSION`. |
| `c3d::pool <Type, IdType>` | The generic generational pool. |
| `c3d::maths` | Transforms, bounds, frustum, projection and sampling helpers over `std::math`. |
| `c3d::ecs`, `c3d::ecs::store` | The entity world and component stores. |
| `c3d::describe` | Type descriptions and synchronous field visitors; see [type descriptions](type_descriptions.md). |
| `c3d::asset` | The asset store and its asset kinds. Submodules: `gltf`, `fbx`, `image`, `truetype`, `loader`, `custom`. |
| `c3d::scene` | The node hierarchy and the built-in components. |
| `c3d::geometry` | Procedural geometry and tangent generation, over the geometry library. |
| `c3d::camera`, `c3d::material`, `c3d::light` | Camera, material and light descriptions, including atmosphere, fog, cloud layers, medium volumes and probes. |
| `c3d::anim`, `anim::ik`, `anim::retarget` | Clips, animators, blending, skinning, inverse kinematics and retargeting. |
| `c3d::model` | Model instantiation, crowds and animated LOD. |
| `c3d::spatial`, `spatial::bvh` | Bounding volume trees, the scene index, CPU picking and LOD selection. |
| `c3d::debug` | The `DebugDraw` line list. |
| `c3d::platform` | Window, input, events, gamepads and actions over SDL3. |
| `c3d::render`, `render::post` | The renderer, its passes and display post-processing. |
| `c3d::shader`, `shader::compile` | The shader registry and ABI constants; `compile` is the in-process GLSL compiler, present under `C3D_SHADER_COMPILER`. |
| `c3d::gui`, `gui::backend`, `gui::inspect` | The ImGui overlay, its renderer backend and the inspector helpers. |
| `c3d::instrumentation` | Core's private scope bridge to the profiler add-on. |

Module naming and file layout follow [style.md](style.md) section 2.

## Third-party libraries

| Library | Used for |
| --- | --- |
| gpu.c3l | Vulkan device, memory, commands and surfaces. Its backend bindings are the libraries `vk`, `vma` and `spvreflect`, which a consumer lists too. |
| sdl3.c3l | Windows, input and events. |
| c3imgui.c3l | Dear ImGui. |
| c3cg.c3l | Procedural geometry generation. |
| box3d.c3l | Rigid-body physics, used by `c3d_physics`. |
| cgltf.c3l, ufbx.c3l | glTF and FBX import. |
| stb_image, stb_truetype | PNG, JPEG and HDR decoding; font parsing. Vendored in `csrc/`. |
| shaderc.c3l | In-process GLSL compilation under `C3D_SHADER_COMPILER`. |
| clay.c3l | UI layout, used by `c3d_ui`. |
| miniaudio.c3l | Audio, used by `c3d_audio`. |

Which module may import which library is the table in [AGENTS.md](../AGENTS.md) section 1.

## Add-on packages

An add-on is a packed library under `addons/<name>.c3l/` with its own `manifest.json`, `project.json`, sources, tests and
examples. Applications select it explicitly in `project.json`. Core never imports an add-on and has no flag for one. The
import sets are in [AGENTS.md](../AGENTS.md) section 1; the dependencies to list per package are in [release.md](release.md).

| Package | Modules | Owned targets (see [development.md](development.md)) | Detail |
| --- | --- | --- | --- |
| `c3d_profile` | `c3d::profile`, private `c3d::render::profile_gpu` | tests `profile_off`, `profile_cpu`, `profile_internal`, `profile_gpu`, `profile_gpu_internal`, `profile_cpu_gpu`, `profile_full`; example `capture` | [profiling](profiling.md) |
| `c3d_profile_gui` | profiler panel in `c3d::gui` | tests `panel_off`, `panel_cpu`, `panel_gpu`, `panel_combined`; the `profile_gui` examples live in `examples/` | [profiling](profiling.md) |
| `c3d_physics` | `c3d::physics`, `physics::collide`, `physics::cloth` | tests `physics_test`, `physics_serial_test`, `physics_serial_policy_test`; acceptance `cloth_acceptance`; examples `physics`, `physics_instanced`, `physics_components`, `vehicle`, `ragdoll`, `collision_math`, `breakable`, `cloth` | [README](../addons/c3d_physics.c3l/README.md) |
| `c3d_nav` | `c3d::nav` | tests `nav_test`, `nav_serial_test`, `nav_serial_policy_test`; examples `navmesh`, `crowd`, `grid`, `nav_persistence` | [README](../addons/c3d_nav.c3l/README.md) |
| `c3d_character` | `c3d::character` | tests `character_test`, `character_nav_test`, `character_serial_test`, `character_nav_serial_test`, `character_serial_policy_test`, `character_nav_serial_policy_test`; examples `character`, `character_nav`, `rebase_bench` | [README](../addons/c3d_character.c3l/README.md) |
| `c3d_physics_gui` | physics panel and inspectors in `c3d::gui` | tests `physics_panel_off`, `physics_panel`, `physics_panel_character`; examples `physics_inspector`, `physics_inspector_character` | [physics inspector](physics_inspector.md) |
| `c3d_job` | `c3d::job` | tests `job_test`, `job_profile_test`; example `job_bench` | [jobs](jobs.md) |
| `c3d_landscape` | `c3d::landscape`, `landscape::terrain`, `landscape::foliage`, `landscape::water`, `landscape::water_gpu` | tests `landscape_test`, `landscape_gpu_test`, `landscape_serial_test`, `landscape_serial_policy_test`; acceptance `terrain_acceptance`, `water_acceptance`, `water_gpu_acceptance`; examples `terrain`, `vegetation`, `water`, `water_gpu` | [README](../addons/c3d_landscape.c3l/README.md) |
| `c3d_particle` | `c3d::particle`, `particle::gpu` | tests `particle_test`, `particle_serial_test`, `particle_serial_policy_test`; acceptance `particle_acceptance`, `particle_gpu_acceptance`; examples `particles`, `particles_gpu` | [particles](particles.md) |
| `c3d_serial` | `c3d::serial` | tests `serial_test`, `serial_order_forward`, `serial_order_reverse`, `serial_text_test`, `serial_described_test`, `serial_core_policy_test`, `serial_all_test`; benchmarks `serial_lookup_bench`, `serial_claims_bench` | [README](../addons/c3d_serial.c3l/README.md) |
| `c3d_ui` | `c3d::ui` | test `ui_test`; acceptance `ui_acceptance`; example `ui` | [README](../addons/c3d_ui.c3l/README.md) |
| `c3d_audio` | `c3d::audio` | tests `audio_test`, `audio_serial_test`, `audio_serial_policy_test`; example `audio` | [README](../addons/c3d_audio.c3l/README.md) |

Module notes:

- A module with faults of its own declares them in its `faults.c3`: `c3d::physics`, `physics::cloth`, `c3d::nav`,
  `c3d::character`, `c3d::ui`, `c3d::profile`, the profiler panel, `c3d::serial`, `c3d::landscape` and `landscape::terrain`.
  The other add-on modules use the root faults of `c3d`.
- `c3d::physics::collide` is world-free; it shares the names `Sweep`, `Manifold` and `ManifoldPoint` with `b3`, so a module
  importing both qualifies them. `physics::cloth` opens `c3d::physics` with `@public` for its private helpers.
- `c3d::landscape` holds the generated constants of the package's shader package, the shared `STALE` fault and the hash and
  Gaussian helpers its submodules share; they read it with `import c3d::landscape @public;`. `foliage` and `water` open
  `terrain` with `@public` for its placement and query predicates. `terrain` declares `NOT_PREPARED`.
- `c3d::job` declares its libc and kernel32 externs in `src/affinity_linux.c3` (`@feat(LINUX)`) and `src/affinity_win32.c3`
  (`@feat(WIN32)`). Under `C3D_PROFILE_CPU`, `src/profile.c3` alone imports `c3d::profile`.
- `c3d::character` under `C3D_CHARACTER_NAV` adds `NavDriven` and `drive_characters` in `src/nav/`.
- `c3d::gui` is extended by `c3d_profile_gui` and `c3d_physics_gui`. A presentation adapter extends an existing public module and
  depends on the APIs it displays. Its public declarations are absent unless its feature is selected, and neither core nor the
  collector it displays references it.
- The profiler's GPU part is render-layer code that ships in the add-on: `c3d::render::profile_gpu` is private, and core's
  `render/profile.c3` copies core identities into neutral profile values. GPU resources stay in the render namespace. CPU-only
  consumers select no backend dependencies; GPU-enabled consumers select them explicitly. Standalone CPU collector builds
  need no native or shader setup.
- A package's examples and tests may select packages its sources never import: `c3d_job` for worker options, `c3d_physics`
  for collision options, `c3d_profile` for GPU timing, `c3d_nav` and `c3d_physics` in the landscape setup tests. Each
  `project.json` lists what its targets select.
- An add-on that ships GLSL keeps `shaders/shaders.json`, its sources and `shaders/include/<name>/` under its own
  `shaders/`, and a generated, committed `src/shaders.c3`. See [development.md](development.md).

## Feature flags

A feature gates optional modules, or optional code in a module. Select one with `--define` on a `--target` build, or in the
`features` list of a `project.json` target.

| Flag | Gates | Also select |
| --- | --- | --- |
| `C3D_SHADER_COMPILER` | `c3d::shader::compile`, the in-process GLSL compiler | `shaderc`, and its shared library beside the executable |
| `C3D_PROFILE_CPU` | CPU capture in `c3d_profile`; core's `c3d::instrumentation` scopes (with `C3D_PROFILE_INTERNAL`); worker range records in `c3d_job` | `c3d_profile` |
| `C3D_PROFILE_GPU` | GPU capture in `c3d_profile`, `c3d::render::profile_gpu`, core's `render/profile.c3` bridge | `c3d_profile`, `gpu`, `vk`, `vma`, `spvreflect` |
| `C3D_PROFILE_INTERNAL` | Library scopes inside the renderer; needs `C3D_PROFILE_CPU` or `C3D_PROFILE_GPU` | `c3d_profile` |
| `C3D_PROFILE_GUI` | The profiler panel in `c3d_profile_gui`; needs `C3D_PROFILE_CPU` or `C3D_PROFILE_GPU` | `c3d_profile_gui`, `c3d_profile`, `c3imgui`, `sdl3`, `vk` |
| `C3D_PHYSICS_SERIAL` | The `src/serial/` adapter of `c3d_physics` | `c3d_serial` |
| `C3D_PHYSICS_GUI` | The physics panel and component inspectors in `c3d_physics_gui` | `c3d_physics_gui`, `c3d_physics`, `b3` |
| `C3D_PHYSICS_GUI_CHARACTER` | The `src/character/` additions of `c3d_physics_gui`; needs `C3D_PHYSICS_GUI` | `c3d_character` |
| `C3D_NAV_SERIAL` | The `src/serial/` adapter of `c3d_nav` | `c3d_serial` |
| `C3D_CHARACTER_NAV` | The `src/nav/` crowd binding of `c3d_character` | `c3d_nav` |
| `C3D_CHARACTER_SERIAL` | The `src/serial/` adapter of `c3d_character`; needs `C3D_PHYSICS_SERIAL`, and `C3D_NAV_SERIAL` when `C3D_CHARACTER_NAV` is on | `c3d_serial` |
| `C3D_LANDSCAPE_SERIAL` | The `src/serial/` adapter of `c3d_landscape` | `c3d_serial` |
| `C3D_LANDSCAPE_GPU` | `c3d::landscape::water_gpu`, spectral water; without it, preparing a spectral body faults `UNSUPPORTED` | core's GPU dependencies |
| `C3D_PARTICLE_SERIAL` | The `src/serial/` adapter of `c3d_particle` | `c3d_serial` |
| `C3D_PARTICLE_GPU` | `c3d::particle::gpu`, device-stepped systems; without it, preparing a GPU system faults `UNSUPPORTED` | core's GPU dependencies |
| `C3D_AUDIO_SERIAL` | The `src/serial/` adapter of `c3d_audio` | `c3d_serial` |

The serialization flags share one pattern, described in [AGENTS.md](../AGENTS.md) section 1.3.

## Package contracts

Each contract is stated once, on the page named. Contracts that no package page states are kept here.

- **Prepared collision shapes.** `CollisionShape` owners and borrowed `CollisionShapeView` values are world-free and sit over
  an explicit `CollisionCache` bound to one asset store. A world borrows the cache through the optional fifth argument of
  `create_physics_world`; a default world keeps private cooking. Native length units stay fixed through the cache, the
  prepared owners and the world lifetimes. See [collision queries](collision_queries.md).
- **Breakable.** `Breakable` is a pointer-sized component. Its state block owns the captured piece ids, the graph edges and
  the runtime storage. Static anchor bodies belong to the application; the `Breakable` owns the anchor welds.
- **Fracture generation** lives in the standalone [c3d_fracture.c3l](https://github.com/fesoliveira014/c3d_fracture.c3l)
  project, which depends on c3d. The physics package keeps the generic authored pieces, multi-hull collision, preparation,
  welds and read-only authoring views; core keeps store-free glTF source inspection. See [fracture](fracture.md) and
  [glTF source inspection](gltf_source.md).
- **Type descriptions.** `c3d::describe` imports only the standard library and core. Struct descriptions are registered
  explicitly, and only component descriptions use ECS slots. `register_core_components` installs the built-in component
  descriptions idempotently. The serialization add-on reads descriptions through its own codec registry. See
  [type descriptions](type_descriptions.md).
- **Serialization.** `c3d_serial` creates no GPU resources and no native systems. Described values hold references to
  custom asset kinds by key. The core policy inventory test fails on a component with no classified policy. See
  [serialization](serialization.md).
- **LOD.** `LodGroup` is a pointer-sized core component holding copied, rigid whole-object alternatives. Picking, the
  spatial index and tracing use the level-zero parts. Landscape foliage may own a copied descriptor and create LOD cells;
  core does not import landscape. See [LOD](lod.md).
- **Instance quadtrees.** An `InstancedMesh` may carry an `InstanceQuadtree` that the renderer selects per view on the GPU.
  See [instancing](instancing.md) and [views](views.md).
- **Audio threads.** See [audio](audio.md#threads-and-allocation).
- **UI and ImGui input.** See [platform](platform.md) and the [UI README](../addons/c3d_ui.c3l/README.md).

## Directory map

```
c3d.c3l/
├── manifest.json            the core package manifest
├── AGENTS.md                the agent contract (also .claude/CLAUDE.md, a gitignored symlink)
├── CONTRIBUTING.md          the human entry point
├── README.md  LICENSE  LICENSE-slug.txt
├── .github/workflows/       ci.yml (build and test, Linux and Windows) and release.yml
├── abi/c3d.abi              shared C3 and GLSL layouts
├── addons/<name>.c3l/       one directory per add-on package, as listed above
│   ├── manifest.json  project.json  README.md
│   ├── src/                 the package sources; src/serial/ holds the serialization adapter
│   ├── test/  examples/     CPU tests and example executables; serial_test/ and serial_policy_test/ where it has an adapter
│   ├── test/gpu/            the manual acceptance project, where the package has one
│   └── shaders/             the shader package, where the package ships GLSL
├── csrc/                    stb_image and stb_truetype sources
├── docs/                    guides and references; style.md is the code style baseline
├── examples/                project.json, src/ (one file or small group per executable), common/ and assets/
├── lib/                     dependency submodules, plus symlinks to this repository and its add-ons so consumers resolve them
├── linked-libs/             empty; every dependency ships its own native libraries
├── scripts/                 build.py, gen_abi.py, build_shaders.py, package_release.py, benchmark.py and their tests
├── shaders/                 GLSL sources, variants.json, common/, generated/ and gpu/; spv/ is build output
├── src/c3d/
│   ├── c3d.c3  types.c3  faults.c3  parallel.c3  pool.c3  instrumentation.c3
│   ├── maths/ ecs/ describe/ asset/ scene/ geometry/ camera/ material/ light/ anim/ model/ spatial/ debug/
│   ├── platform/            window, input and events
│   ├── render/ shader/      the renderer and the shader registry; render/post/ holds display post-processing
│   └── gui/                 the ImGui overlay; gui/backend draws it through the renderer
└── test/
    ├── project.json         the root test targets
    ├── src/                 CPU unit tests, one file per group
    ├── describe/ cap/ gamepad/ profile/   further root test groups
    ├── shaders/             the shader package the unit tests read
    ├── fixtures/            fixture data and its licences
    └── gpu/                 manual acceptance projects: render, profile, animated_crowd, animation_authoring
```

## See also

- [AGENTS.md](../AGENTS.md): import boundaries, layer rules and the change workflow.
- [development.md](development.md): build, shader pipeline, test targets and acceptance projects.
- [style.md](style.md): the code style baseline.
- [release.md](release.md): packages, dependencies and releases.
