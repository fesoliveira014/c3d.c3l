# Particles reference

Reference for the `c3d::particle` module: the descriptor tables with their rules, the runtime controls and counters, the constants, the functions and the faults. The [particles guide](particles.md) explains how to use them and [GPU particles](particles_gpu.md) covers `execution = GPU`.

## ParticleSystemDesc

`default_particle_system_desc()` returns a white point emitter: `capacity` 1,024, `seed` 1, `BILLBOARD`, `POINT`, `radius` 1, `half_extents` (1, 1, 1), `cone_angle` π/6, `lifetime` and `size` of 1, white colours, unit lifetime tables, no gravity, drag or rate, and the collision defaults below. The descriptor is captured at creation and immutable. `add_particle_system`, `attach_particle_system` and `prepare` check every rule and fault `INVALID_ARGUMENT`, because descriptors also come from files.

| Field | Meaning and rule |
| --- | --- |
| `capacity` | Particles in the pool; at least 1. The pool allocation, including the event queue and trail streams, must fit a signed size |
| `saturation` | `REFUSE` (default) or `DROP_OLDEST` |
| `seed` | Stream of every spawn draw; equal seeds emit equal particles |
| `render_mode` | `BILLBOARD`, `STRETCHED` or `MESH` |
| `material` | The draw material, normally from `add_particle_material` |
| `geometry` | The mesh of `MESH` systems |
| `shape` | `POINT`, `SPHERE`, `BOX` or `CONE` |
| `radius` | Metres; the sphere radius or the cone's disk radius; at least 0 |
| `half_extents` | Metres per axis for `BOX`; at least 0 |
| `cone_angle` | Radians, in [0, π] |
| `rate` | Particles per second; at least 0 |
| `lifetime` | `ParticleRange` seconds; `min` above 0 |
| `speed` | `ParticleRange` m/s along the emission direction; `min` at least 0 |
| `size` | `ParticleRange` metres; `min` at least 0 |
| `rotation`, `spin` | `ParticleRange` radians and radians per second |
| `color_min`, `color_max` | RGBA endpoints; RGB non-negative and finite, alpha in [0, 1] |
| `size_over_life` | Eight non-negative samples multiplied onto `size` over normalised age |
| `color_over_life` | Eight RGBA samples multiplied onto the colour over normalised age; same colour rule |
| `gravity_scale` | Finite multiple of `PARTICLE_GRAVITY` |
| `drag` | Share per second of the velocity pulled toward the air velocity; at least 0; zero ignores wind and turbulence |
| `stretch` | Seconds of motion added to a `STRETCHED` quad's length; at least 0 |
| `sub_emitters`, `sub_emitter_count` | At most `MAX_SUB_EMITTERS`; see below |
| `max_events` | Event queue entries; at least 1 with sub-emitters; 0 disables events |
| `collision`, `flipbook`, `turbulence`, `trail` | See the sub-tables |
| `mesh_cast_shadow`, `mesh_trace` | `MESH` only; fault `INVALID_ARGUMENT` otherwise |
| `execution` | `CPU` (default) or `GPU`; `GPU` needs `C3D_PARTICLE_GPU`, else `prepare` faults `UNSUPPORTED` |

A `ParticleRange` is a closed interval `{ min, max }`; both must be finite with `min <= max`.

### Sub-emitters

| Field | Meaning |
| --- | --- |
| `trigger` | `DEATH` fires when a particle expires, is evicted or dies on impact. `BIRTH` fires when a particle is emitted. `IMPACT` fires when a particle hits a surface |
| `target` | The node of the particle system that receives the children; it may be the same system. In a serialized subtree it must lie inside the subtree |
| `count` | Particles spawned per event |
| `inherit_velocity` | Share of the parent particle's velocity added to each child, in [0, 1] |
| `on_evict` | Lets `DEATH` fire for evicted particles as well. Off by default |

A descriptor with more than `MAX_SUB_EMITTERS` sub-emitters, an `inherit_velocity` outside [0, 1], or sub-emitters with `max_events` of zero faults `INVALID_ARGUMENT`. Each event uses 48 bytes of the pool.

### Collision

| Field | Default | Meaning and rule |
| --- | --- | --- |
| `response` | `NONE` | `NONE` disables collision. `BOUNCE` reflects the particle. `STICK` stops it. `DIE` removes it |
| `restitution` | 0.5 | Share of the normal speed a bounce keeps, in [0, 1] |
| `friction` | 0 | Share of the tangent speed a bounce loses, in [0, 1] |
| `radius_scale` | 0.5 | Collision radius is the drawn size (`size` times the size table) times this scale; at least 0 |
| `ground_plane` | false | Collide with the plane `y = ground_height`, with no callback |
| `ground_height` | 0 | World height of the plane; finite |
| `max_queries` | 256 | Callback casts per step; a response other than `NONE` with no plane needs a non-zero value |
| `impact_speed` | 1 | Least speed into the surface, in m/s, that raises an `IMPACT` event; at least 0 |

### Flipbook

| Field | Meaning and rule |
| --- | --- |
| `columns`, `rows` | Grid of the sheet; 0 columns disables the flipbook |
| `frame_count` | Frames played, 1 to `columns · rows` |
| `inset` | UV units cut from each cell edge; half a texel of the sheet; not negative, finite and under half a cell |
| `mode` | `OVER_LIFE` spreads the frames over a particle's lifetime. `FPS` plays them at `fps` frames per second of age |
| `fps` | Frames per second in `FPS` mode; finite and above 0 |
| `random_start` | Each particle starts on a frame chosen from its seed |
| `blend` | Writes fractional frames that blend toward the next frame. Off writes whole frames |

A flipbook in `MESH` mode, or a layout that breaks the [billboard sprite-sheet rules](billboards.md#sprite-sheets), faults `INVALID_ARGUMENT`. A disabled flipbook reads only its `inset`.

### Turbulence

| Field | Meaning and rule |
| --- | --- |
| `strength` | Metres per second of air velocity at the first octave; 0 disables turbulence; not negative |
| `frequency` | Lattice cells per metre; above 0 while `strength` is above 0 |
| `octaves` | 1 to `MAX_TURBULENCE_OCTAVES`. Each octave doubles the frequency and halves the speed |
| `period` | Lattice cells per tile, 1 to `MAX_TURBULENCE_PERIOD`; the field repeats every `period / frequency` metres |
| `scroll` | `Vec3` metres per second that the pattern drifts |

All values must be finite. A disabled turbulence reads only the finiteness and sign rules.

### Trail

| Field | Meaning and rule |
| --- | --- |
| `max_points` | Stored points per particle, 2 to `MAX_TRAIL_POINTS`; 0 disables the trail. The live position is one more point and is not stored |
| `point_interval` | Seconds of particle age between recorded points; above 0 |
| `lifetime` | Seconds a recorded point lives; above 0 |
| `width` | Metres across the strip at the live position; at least 0 |
| `width_over_trail` | Eight samples of width multiplier by point age over `lifetime`. They may end at 0 |
| `color_over_trail` | Eight RGBA samples multiplied onto the particle's colour by point age over `lifetime` |
| `uv` | `STRETCH` or `TILE` |
| `tile_length` | Metres of path per texture coordinate unit under `TILE`; above 0 there |
| `material` | Blended material of the trail batch, as for [ribbons](ribbons.md#materials-and-supported-paths) |

All scalars must be finite. `capacity · (max_points + 1)` must fit the 32-bit ribbon capacity. A disabled trail reads only the finiteness and sign rules.

## ParticleMaterialParams

`add_particle_material(assets, shader, params, map, blend = PREMULTIPLIED_ALPHA, key)` copies a 32-byte `ParticleMaterialParams`. The shader must come from `add_particle_shader`, or another fragment-only shader with a 32-byte parameter block that reads scene depth; otherwise the call faults `INVALID_ARGUMENT`. A dead shader faults `INVALID_ID`.

| Field | Meaning and rule |
| --- | --- |
| `color` | Multiplies the particle and texture colour; RGB non-negative and finite, alpha in [0, 1] |
| `soft_distance` | Metres of scene-depth gap over which coverage fades; 0 disables; not negative |
| `lighting` | `UNLIT`, `AMBIENT`, `DIRECT` or `DIRECT_SHADOWED` |
| `normal` | `CAMERA`, `SPHERICAL` or `VOLUME` |
| `anisotropy` | Henyey-Greenstein asymmetry for `VOLUME`; in (−1, 1) |

## ParticleSystem

Public fields and methods of the component:

| Member | Meaning |
| --- | --- |
| `desc` | The captured descriptor |
| `emitting` | Whether rate emission runs; application-settable; true after attachment |
| `emit_burst(count)` | Queues a burst for the next step; stays effective while `emitting` is false |
| `set_collision(cast, context)` | Installs the callback of a prepared CPU system; a null cast removes it |
| `is_prepared()` | Whether the pool and draw child exist |
| `alive` | Live particles (CPU systems) |
| `draw_node`, `trail_node` | The owned draw and trail children |
| `turbulence_time` | Seconds the system has stepped; restarts at 0 when the system is created or read |
| `dropped`, `evicted`, `dropped_events`, `skipped_events`, `collision_skips` | Counters, below |
| `spawn` | Per-particle spawn ordinals (the stream that orders eviction) |

### Counters

| Counter | Counts |
| --- | --- |
| `dropped` | Requested particles refused for lack of room, including children refused by a target |
| `evicted` | Live particles removed to make room |
| `dropped_events` | Events lost to a full queue |
| `skipped_events` | Deliveries whose target was unavailable |
| `collision_skips` | Particles that waited out a step because the callback budget ran out |

All are cumulative, start at zero, saturate instead of wrapping and restart when a system is read from serialized data. A GPU system's counters reach the CPU `FRAMES_IN_FLIGHT` frames late.

## Constants

| Constant | Value | Meaning |
| --- | --- | --- |
| `LIFETIME_TABLE_ENTRIES` | 8 | Samples in an over-lifetime table |
| `MAX_TURBULENCE_OCTAVES` | 3 | Octaves a turbulence field sums |
| `MAX_TURBULENCE_PERIOD` | `uint::max >> MAX_TURBULENCE_OCTAVES` | Lattice cells per tile |
| `MAX_TRAIL_POINTS` | 64 | Points a trail stores per particle |
| `MAX_PARTICLE_STEP_SECONDS` | 0.1 | Longest simulated time of one update |
| `PARTICLE_GRAVITY` | (0, −9.81, 0) | Acceleration at unit `gravity_scale` |
| `MAX_SUB_EMITTERS` | 4 | Sub-emitters per system |
| `REACH_SLOTS` | 8 | Time slices of the GPU draw bound |
| `gpu::DEFAULT_MAX_SYSTEMS` | 16 | GPU systems per context |

## Functions

| Function | Purpose |
| --- | --- |
| `register_particles(scene)` | Register `ParticleSystem` and its draw-owner marker, once per scene |
| `default_particle_system_desc()` | A white point emitter |
| `Scene.add_particle_system(desc, parent = null, name = "")` | Create and prepare an emitter with its draw child |
| `Scene.attach_particle_system(node, desc)` | Attach pending authoring |
| `prepare(scene, node)`, `prepare_subtree(scene, root = null)` | Complete pending systems |
| `update(scene, dt, wind = {}, parallel = {})` | Step every prepared CPU system and publish draws; skips pending and GPU systems |
| `step(system, emitter_world, dt, wind, world_shift, parallel)` | Step one system |
| `Scene.shift_particles(offset)` | Apply an origin rebase; `offset.y` must be 0 |
| `add_particle_shader(assets, key = "")`, `add_particle_material(...)` | The effect shader and material |
| `gpu::create_gpu_particles(allocator, assets, max_systems)`, `gpu::destroy_gpu_particles(particles, renderer)`, `gpu::update(particles, renderer, scene, dt, wind = {}, depth = {})` | The GPU context ([GPU particles](particles_gpu.md)) |

`update` requires a finite non-negative `dt` and a finite `wind`.

## Faults

| Where | Fault | When |
| --- | --- | --- |
| `register_particles` | `c3d::CAPACITY_EXCEEDED` | No component type slot left |
| `add_particle_system`, `attach_particle_system` | `c3d::INVALID_ARGUMENT` | A descriptor value outside the rules above |
| `add_particle_system`, `prepare`, `prepare_subtree` | `c3d::INVALID_ARGUMENT` | The same checks at preparation |
| `add_particle_system`, `prepare`, `prepare_subtree` | `c3d::CAPACITY_EXCEEDED` | The pool or a draw child cannot be allocated, or the scene has no node left |
| `add_particle_system`, `prepare`, `prepare_subtree` | `c3d::UNSUPPORTED` | `execution = GPU` in a build without `C3D_PARTICLE_GPU` |
| `add_particle_shader` | `c3d::CAPACITY_EXCEEDED`, `c3d::INVALID_ARGUMENT` | The asset store refuses the shader |
| `add_particle_material` | `c3d::INVALID_ID` | A dead shader |
| `add_particle_material` | `c3d::INVALID_ARGUMENT` | A shader other than the particle shader's shape; a colour, `soft_distance` or `anisotropy` outside its rule |
| `gpu::create_gpu_particles` | `c3d::CAPACITY_EXCEEDED` | `max_systems` reaches the renderer's buffer capacity, or the store cannot hold the stages |
| `gpu::update` | `c3d::CAPACITY_EXCEEDED`, `c3d::INVALID_ID`, `c3d::INVALID_ARGUMENT` | Context or depth-collision arguments; see [GPU particles](particles_gpu.md#depth-collision) |
| `gpu::update` | those of `Renderer.create_buffer`, `Renderer.dispatch` and `Renderer.read_buffer` | Inherited unchanged |

## See also

- [Particles](particles.md) and [GPU particles](particles_gpu.md).
- [Serialization](serialization.md#landscape-particle-and-audio-adapters) for the saved descriptor.
