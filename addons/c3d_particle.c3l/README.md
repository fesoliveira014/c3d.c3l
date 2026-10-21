# Particle add-on

`c3d_particle` adds fixed-pool particle simulation and particle effect materials to c3d. A `ParticleSystem` component on a node simulates a pool on the CPU, or on the GPU under `C3D_PARTICLE_GPU`, and publishes ordinary core billboard batches, mesh instances and ribbon trails. Core owns rendering, culling and sorting.

| Module | Provides |
| --- | --- |
| `c3d::particle` | Systems, emitters, sub-emitters, collision, flipbooks, turbulence, trails and the effect material |
| `c3d::particle::gpu` | Device-stepped systems; present only under `C3D_PARTICLE_GPU` |

## Boundaries

`c3d::particle` imports the standard library and core, and `c3d::serial` only under `C3D_PARTICLE_SERIAL`. It never imports `gpu`, `sdl`, `imgui`, `c3d::physics`, `c3d::job`, `c3d::profile` or `c3d::shader`, and imports `c3d::render` only in `particle::gpu`. Core never imports it. The collision callback and the `ParallelFor` hook let an application connect physics and a job pool without the package importing them.

## Select the package

List `c3d_particle` next to `c3d` and core's dependencies in `project.json`; the [release guide](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/release.md) lists the names.

| Feature | Effect | Also select |
| --- | --- | --- |
| `C3D_PARTICLE_GPU` | Enables `c3d::particle::gpu`; without it, preparing a GPU system faults `UNSUPPORTED` | core's GPU dependencies |
| `C3D_PARTICLE_SERIAL` | Registers particle authoring codecs | `c3d_serial` |

## Quick start

```c3
particle::register_particles(&scene)!;
ShaderId shader = particle::add_particle_shader(&assets)!;
MaterialId material = particle::add_particle_material(
    assets: &assets,
    shader: shader,
    params: { .color = { 1, 0.6f, 0.1f, 1 } },
    blend:  BlendMode.ADDITIVE,
)!;

ParticleSystemDesc desc = particle::default_particle_system_desc();
desc.material = material;
desc.rate = 200;
desc.speed = { .min = 3, .max = 6 };
desc.lifetime = { .min = 1, .max = 2 };
Node* emitter = scene.add_particle_system(desc, name: "sparks")!;

// every frame, after update_world
particle::update(&scene, delta_seconds, wind_velocity);
```

## Targets and examples

| Target | Kind |
| --- | --- |
| `particle_test` | CPU tests |
| `particle_serial_test`, `particle_serial_policy_test` | Serialization adapter tests under `C3D_PARTICLE_SERIAL` |
| `particle_acceptance`, `particle_gpu_acceptance` | Manual Vulkan acceptance in `test/gpu`; not part of CI |
| `particles`, `particles_gpu` | Examples; both select `c3d_physics`, `c3d_job` and `c3d_profile` for their collision, worker and GPU timing options |

```bash
python3 scripts/build.py --example particles
```

## Guides

- [Particles](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/particles.md) and its [reference](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/particles_reference.md)
- [GPU particles](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/particles_gpu.md)
- [Serialization](https://github.com/fesoliveira014/c3d.c3l/blob/main/docs/serialization.md#landscape-particle-and-audio-adapters)
