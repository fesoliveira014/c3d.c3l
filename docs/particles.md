# Particles

The `c3d_particle` add-on (module `c3d::particle`) supplies fixed-pool particle simulation and particle effect materials. A `ParticleSystem` component on a node simulates a pool of particles on the CPU, or on the GPU in a build that enables `C3D_PARTICLE_GPU` ([GPU particles](particles_gpu.md)), and publishes the result as ordinary core [billboard batches](billboards.md), [mesh instances](instancing.md) and [ribbon trails](ribbons.md). Core owns rendering, culling and sorting. The package imports only core and the standard library; core never imports it.

Particle rendering shares the [frame origin](large_world.md) selected through `FrameInfo.reference_position`. Billboard and mesh packing, soft depth and fog use relative shader coordinates. Simulation positions, seeds and emitter state keep their own spaces, so changing the reference does not move the simulation.

## Quick start

Select `c3d_particle` next to core in `project.json` (the [release guide](release.md) lists the names), then register the module, add a shader and material, and create an emitter:

```c3
particle::register_particles(&scene)!;
ShaderId shader = particle::add_particle_shader(&assets)!;
MaterialId sparks = particle::add_particle_material(
    assets: &assets,
    shader: shader,
    params: { .color = { 1, 0.6f, 0.1f, 1 }, .soft_distance = 0.2f },
    blend:  BlendMode.ADDITIVE,
)!;

ParticleSystemDesc desc = particle::default_particle_system_desc();
desc.capacity = 4096;
desc.material = sparks;
desc.render_mode = ParticleRenderMode.STRETCHED;
desc.shape = EmitterShape.CONE;
desc.radius = 0.1f;
desc.rate = 200;
desc.speed = { .min = 3, .max = 6 };
desc.lifetime = { .min = 1, .max = 2 };
desc.gravity_scale = 1;
desc.stretch = 0.05f;
Node* emitter = scene.add_particle_system(desc, name: "sparks")!;
emitter.local.position = { 0, 1, 0 };

// every frame, after animation, physics and emitter edits
scene.update_world();
particle::update(&scene, delta_seconds, wind_velocity);
// render every camera afterwards
```

![Smoke, stretched sparks and mesh debris](images/particles.png)

`register_particles` runs once per scene. It can fault `CAPACITY_EXCEEDED`; destroy the scene after a partial registration failure. `add_particle_system` is atomic: it validates the descriptor, allocates one pool, and creates the emitter plus one draw child (and a trail child when [trails](#trails) are on), rolling back on failure. An invalid descriptor returns `INVALID_ARGUMENT`; a full scene returns `CAPACITY_EXCEEDED`.

## Concepts

- **Pool.** A system owns one fixed allocation, sized by `capacity` (and the event queue and trail points). Nothing allocates during `update`. The pool holds positions, velocities and per-particle values in separate streams; expiry swap-removes every stream together.
- **Immutable descriptor.** `ParticleSystemDesc` is captured at creation and stays fixed. Runtime controls are `ParticleSystem.emitting`, `emit_burst(count)`, the emitter's transform and the wind passed to `update`. Material values change through the ordinary asset revision API. Recreate a system to change its capacity, emission, render mode, execution or asset references.
- **Ownership.** The library owns the pool arrays, counters and draw children. Inspect them as short-lived borrows; do not resize the arrays or remove, reparent or replace the owned children. Removing the emitter or the scene releases the pool at once. Removing only `ParticleSystem` frees the pool, and the next `particle::update` removes the orphaned draw and trail children, so run that update before rendering. Shared materials, shaders, textures and geometry stay in the asset store.
- **World space.** Positions and velocities are world-space after emission. Emitter scale affects spawn volume, while sampled speed stays in world m/s. Emitter motion after emission does not carry existing particles. Draw children are world-space nodes; hidden emitters keep simulating, and `update` copies the emitter's layer mask to its children because layers are not inherited.
- **Determinism.** Every value a particle draws comes from a hash of the system `seed`, the particle's spawn ordinal and the quantity drawn, so a particle's values depend on its ordinal alone, not on how many particles a step admits or refuses. Equal seeds, configuration and identical sequences of emitter poses, deltas and winds replay identically within one build. There is no cross-compiler or cross-version bitwise guarantee.
- **Pending and prepared.** `scene.attach_particle_system(node, desc)` validates and attaches authoring and leaves the system pending, with `emitting = true`: no pool, no draw child, nothing drawn. `particle::prepare(&scene, node)` and `particle::prepare_subtree(&scene, root)` complete one owner or every pending system under a root (null selects the scene). A failed preparation keeps the authoring and can be retried. `particle::update` skips pending systems; `particle::step` needs a prepared system. [Owner readiness](owner_readiness.md) states the shared rules. A codec restores the authored `emitting` after attachment instead of inheriting the default.

## Frame order

```c3
scene.update_world();
particle::update(&scene, delta_seconds, wind_velocity);
```

`update` steps every CPU system, runs the [sub-emitters](#events-and-sub-emitters), then publishes draws and trails, so particles spawned by events draw in the same update. A system whose `execution` is `GPU` is not stepped here; [`particle::gpu::update`](particles_gpu.md#frame-order) steps it after `begin_frame`. Rendering does not advance the simulation. `wind_velocity` is application-owned world air velocity in m/s.

After an origin rebase, call `scene.shift_particles(offset)` after `Scene.shift_origin` and before `update_world`. It subtracts the offset from every live particle position, stored trail point and queued event position, and resets each draw and trail child to the identity transform. The offset's `y` must be 0. Turbulence stays fixed to world points.

## Emit and simulate

Emission shapes:

| Shape | Spawn position and direction |
| --- | --- |
| `POINT` | The emitter origin; uniform sphere directions |
| `BOX` | Uniform in the box of `half_extents`; independent sphere directions |
| `SPHERE` | Uniform in the sphere of `radius`; outward directions |
| `CONE` | A disk of `radius` at local Y = 0; a uniform solid angle of `cone_angle` about +Y |

Rate emission keeps a fractional accumulator. `emit_burst(count)` queues a burst, which stays effective while `emitting` is false. A request past the free capacity follows the [saturation policy](#saturation); refused requests take no spawn ordinal and cost no work in proportion to their count.

Each update clamps simulated time to `MAX_PARTICLE_STEP_SECONDS` (0.1 s), expires existing particles, then accepts emission. Accepted newborns take part in that step's integration. A zero-duration update consumes bursts and publishes age-zero particles. Velocity receives gravity (`gravity_scale` times `PARTICLE_GRAVITY`), then drag toward the air velocity, which is wind plus [turbulence](#turbulence); position uses the updated velocity. A system with zero `drag` ignores wind and turbulence.

Size, colour, rotation and spin follow the descriptor: scalar ranges draw once per particle, `size_over_life` and `color_over_life` are eight-sample tables that interpolate linearly over normalised age, and the particle's colour is a seeded blend of `color_min` and `color_max` times the colour table. Colour endpoints need non-negative finite RGB and alpha in [0, 1] and may descend in any channel.

## Saturation

`ParticleSystemDesc.saturation` selects what a step does when burst and rate requests exceed the free capacity.

- `REFUSE` (default) emits what fits and counts the rest in `dropped`.
- `DROP_OLDEST` evicts the oldest live particles, those with the smallest `ParticleSystem.spawn` values, then emits. Newborns of the same step are never evicted. A request larger than the capacity still emits `capacity` particles and refuses the excess.

A step runs expire, request, evict, emit. `dropped` counts refused particles and `evicted` counts evicted ones; both are cumulative, saturate instead of wrapping and restart when a system is read from serialized data. Neither policy changes the spawn draws. Eviction selects its victims deterministically, so equal seeds and call sequences leave the same pool. Eviction reorders the pool in place; pool order carries no meaning.

## Events and sub-emitters

A sub-emitter spawns particles in another system where a particle of this one is born, dies or hits a surface. `ParticleSystemDesc.sub_emitters` holds up to `MAX_SUB_EMITTERS` (4) entries, `sub_emitter_count` of them in use, and `max_events` sizes the queue (at least 1 when sub-emitters exist). The [reference](particles_reference.md#sub-emitters) lists the fields.

- A step raises `DEATH` events (cause `EXPIRED`, `EVICTED` or `IMPACT`), `BIRTH` events and `IMPACT` events. An event is queued only if some sub-emitter of the system accepts it. An event past `max_events` is lost and counted in `dropped_events`. Size the queue for the most events one update can raise.
- After every system has stepped, `update` delivers each event to each accepting sub-emitter in store order, then queue order, then sub-emitter index. A delivery spawns `count` particles in the target at the event position, through the target's own emission shape; the target's world matrix supplies orientation and scale. A child's velocity is its emitted velocity plus the parent's velocity times `inherit_velocity`. Children start at age zero and integrate from the next update. They draw their values from a hash of the parent's seed, the event index and the sub-emitter index, not from the target's `seed`.
- A delivery requests `count` particles as a burst would, so the target's [saturation policy](#saturation) applies. With `DROP_OLDEST` the target evicts to make room and raises `EVICTED` events for its own sub-emitters.
- A target that is dead, not a particle system, not prepared or on the other processor than the source is skipped and counted in the source's `skipped_events`. `update` adds and removes no nodes, so attach and prepare targets first.
- Events raised during delivery wait for the next update, so a chain A to B to A advances one level per update and one update's work is bounded by the queue capacities.
- `on_evict` lets `DEATH` fire for evicted particles; it is off by default to bound cascades under `DROP_OLDEST`.

## Collision

`ParticleSystemDesc.collision` makes particles meet surfaces. The default response is `NONE`. The [reference](particles_reference.md#collision) lists the fields.

A step runs expire, evict, emit, integrate, collide. After integration each particle's last move, the segment from `position − velocity · dt` to `position`, is tested. A zero-length segment is not tested. Newborns are tested over their first move; delivered children from the next step. A `BOUNCE` or `STICK` hit places the particle at `point + normal · radius` and drops the rest of that step's move.

- **Ground plane.** `ground_plane = true` collides with the world plane `y = ground_height` and needs no callback. A particle hits it when a downward segment ends with its centre less than one radius above the plane. A segment that starts at or below that height hits at its start, so a resting particle cannot fall through by rounding. The origin rebase moves nodes horizontally only, so it never moves the plane.
- **Callback.** `ParticleSystem.set_collision(cast, context)` installs a `ParticleCollisionFn` on a prepared CPU system. The system calls it with the scene-space segment and the collision radius; it fills a `ParticleHit` (`point`, unit `normal` facing the particle, `fraction` along the segment) and returns true on a hit. The package imports no physics; the application adapts a query. The cast runs on the owner thread inside `particle::update`, so a physics world must not be stepping then. `context` must outlive the system or be cleared with `set_collision(null, null)`. The cast and context are not serialized. When the plane and the cast both hit, the smaller fraction wins.
- **Budget.** At most `max_queries` casts run per step. The step starts at `query_cursor` and visits the pool in order, wrapping. Particles past the budget skip the callback that step and count in `collision_skips`; the plane still applies. The next step starts at the first skipped particle, so no particle is skipped every step. `max_queries = 0` disables the callback.
- **Responses.** `BOUNCE` reverses the normal part of the velocity scaled by `restitution` and scales the tangent part by `1 − friction`; a hit on a particle moving away leaves its velocity alone. `STICK` zeroes the velocity. `DIE` removes the particle, raising `DEATH` with cause `IMPACT`.
- **Impact events.** A hit raises `IMPACT` when the speed into the surface before the response is at least `impact_speed` (default 1 m/s; zero raises one for every hit). A `DIE` hit raises `DEATH` whatever its speed.

```c3
fn bool cast_physics(void* context, Vec3 from, Vec3 to, float radius, ParticleHit* out) {
    PhysicsWorld* physics = context;
    Vec3 path = to - from;
    float length = path.length();
    RayHit? hit = physics.raycast(from, path / length, length);
    if (catch hit) return false;
    *out = { .point = hit.point, .normal = hit.normal, .fraction = hit.fraction };
    return true;
}

system.set_collision(&cast_physics, &physics);
```

`PhysicsWorld.cast_shape` with a sphere of `radius` also honours the radius, and `spatial::pick` serves scene meshes without physics. Both allocate per call, so give them a small `max_queries`. A GPU system has no callback; it collides with the ground plane and a view's depth ([GPU depth collision](particles_gpu.md#depth-collision)).

## Draw modes and materials

| `render_mode` | Draws |
| --- | --- |
| `BILLBOARD` | Square camera-facing quads |
| `STRETCHED` | Quads along the world velocity, with dimensions `(size, size + speed · stretch)` |
| `MESH` | The supplied geometry and material, with uniform scale and rotation about world +Y |

Billboard modes write world-space `BillboardRecord` values into a `RECORDS` [batch](billboards.md#sources) that core copies relative to the frame origin. `rotation` is an extra in-plane turn. Zero-area output is omitted without removing the simulated particle. Pick indices identify compacted draw records, not stable particles. Mesh particles take their alpha and depth behavior from the supplied material.

`mesh_cast_shadow` and `mesh_trace` apply to `MESH` systems, default to false, and fault `INVALID_ARGUMENT` elsewhere. Both are copied to the owned `InstancedMesh` child at preparation. Debris shadows need an opaque or masked material. `mesh_trace` adds one trace instance per live particle from `RendererDesc.max_trace_instances` (4,096 when zero) and only opaque and masked materials trace; a scene past capacity faults `CAPACITY_EXCEEDED` when the renderer prepares the trace ([scene tracing](scene_trace.md#what-traces)).

**Effect material.** `add_particle_shader` creates a shared fragment-only shader that reads core's depth snapshot and has a [weighted form](custom_shaders.md#weighted-transparency), so source-over particles take part in a view with `transparency = WEIGHTED`. `add_particle_material` copies a 32-byte `ParticleMaterialParams` and creates a blended, depth-tested, double-sided material with depth writes off. Slot 0 is an optional sprite map. `color` multiplies the particle and texture colour. `soft_distance > 0` fades coverage over the scene-depth gap; zero keeps hardware depth testing only. Empty or hidden batches make no draw or snapshot request.

`lighting` selects the illumination:

| `ParticleLighting` | Adds |
| --- | --- |
| `UNLIT` | Nothing: the input radiance |
| `AMBIENT` | Scene ambient and core diffuse indirect (environment or selected probe volume) |
| `DIRECT` | Every punctual and directional light that shares a layer with the system, on top of `AMBIENT` |
| `DIRECT_SHADOWED` | `DIRECT` with each light times its shadow-map and cloud-shadow visibility, and for the sun in a view with a [medium](sky.md#medium-volumes) the mean of the medium's sun column |

`normal` selects what a lit particle presents: `CAMERA` is the facing axis; `SPHERICAL` bulges toward the camera across the quad as on an inscribed sphere; `VOLUME` has no surface and scatters each light through the Henyey-Greenstein phase function with `anisotropy` in (−1, 1), so a positive value brightens the particle when the camera looks toward the light. The volume response integrates to one over the sphere, a quarter of Lambert's response at normal incidence when `anisotropy` is 0, so a light meant for smoke needs more intensity.

`DIRECT_SHADOWED` reads the shadow atlas, cloud shadows and the medium's sun column; a light whose only shadow is ray traced contributes unshadowed. Particles cast no shadow and ignore the receive-shadow flag; the lighting mode is the opt-in. `DIRECT` adds a light loop per covered pixel and `DIRECT_SHADOWED` a shadow lookup per shadow-casting light, so the cost grows with covered pixels and reaching lights. Fog applies to the lit colour before coverage is premultiplied.

Core sorts the instances of a blended batch within that batch, not across batches, so overlapping smoke and sparks systems draw in scene order. A view with `transparency = WEIGHTED` records source-over particle batches in the [weighted pass](materials.md#weighted-transparency) and skips their sort; additive batches keep theirs.

## Flipbooks

`ParticleSystemDesc.flipbook` plays a sprite sheet on `BILLBOARD` and `STRETCHED` particles. It is off while `columns` is 0. The system copies the layout to its draw child's [sprite sheet](billboards.md#sprite-sheets) at preparation; frames run row-major from the top-left cell. Each update writes `Billboard.frame` for every published particle. With `t` the age over lifetime in [0, 1], `s` the start frame (0, or from the seed under `random_start`) and `n` = `frame_count`:

| Mode | Frame |
| --- | --- |
| `OVER_LIFE` with `blend` | `s + t · (n − 1)` |
| `OVER_LIFE`, whole frames | `s + min(floor(t · n), n − 1)` |
| `FPS` | `s + age · fps`, floored when whole frames are written |

The value is written modulo `n`; a fractional frame blends toward the next, and the last blends toward frame 0. The start frame takes no spawn draw, so equal seeds emit equal particles with or without a flipbook. The particle shader samples the current cell through UV0 and, on a draw with a sprite sheet, the next cell through UV1, so a flipbook takes two texture samples per fragment. Other fragment stages read the sheet as [billboards](billboards.md#sprite-sheets) describes, including its [edge rules](billboards.md#edges-and-mipmaps): set `inset` to half a texel and pad each cell of a mipmapped sheet.

## Turbulence

`ParticleSystemDesc.turbulence` adds a swirling, divergence-free air motion to the air that drag pulls particles toward. It is off while `strength` is 0. The field is the curl of tiled 3D gradient noise with up to `MAX_TURBULENCE_OCTAVES` (3) octaves, each doubling the frequency and halving the speed. The first octave's RMS speed is about `strength`.

- The field is periodic: it repeats every `period / frequency` metres along each axis, so choose a period length that exceeds the extent of the effect.
- The sample point is `position + Scene.world_shift − scroll · t` in double, where `t` is `ParticleSystem.turbulence_time`, reduced modulo the period and evaluated in float. A particle at one world point sees the same air before and after a rebase.
- Drag blends the velocity toward wind plus turbulence by `min(1, drag · dt)`. A system with zero drag ignores turbulence, and a higher drag follows the swirl more closely. The blend is convex, so turbulence alone never takes a particle faster than the air.
- The field takes no spawn draw, so equal seeds emit equal particles with or without turbulence.
- The cost falls on `update`, linearly in live particles and octaves: one curl evaluation per octave per particle per step. A system with zero strength or zero drag evaluates nothing.

## Trails

`ParticleSystemDesc.trail` records every particle's path and draws it as a camera-facing strip through a core [ribbon batch](ribbons.md). It is off while `max_points` is 0. The [reference](particles_reference.md#trail) lists the fields.

- **Recording.** At the end of each update, after collision, a particle's clock gains the step. When it reaches `point_interval` the particle's position is stored and one interval is taken off, so a particle stores at most one point per update. When `max_points` are stored, the next overwrites the oldest. A stored point older than `lifetime` (by particle age) is dropped. A new particle draws no trail until its first point is stored.
- **Publication.** The system owns a second world-space child with a ribbon batch. Each update writes one strip per particle that has a stored point: the live position first (carrying `RIBBON_BREAK`), then the stored points from newest to oldest. A point's width is `width · width_over_trail(f)` and its colour is the particle's current colour times `color_over_trail(f)`, with `f` the point's age over `lifetime`. The batch is not depth sorted within itself, so overlapping source-over trails blend in strip order; additive or weighted blending is order independent ([ribbon material rules](ribbons.md#materials-and-supported-paths)).
- **Texture coordinates.** The strip runs from head to tail, so v rises from the head to the tail in both modes ([ribbon orientation](ribbons.md#texture-coordinates)). `STRETCH` maps v to `f`, so the image spans the trail and travels with it. `TILE` maps v to the negative path length over `tile_length`, so the image stays fixed along the path; its coordinates fall without bound as a particle travels, so the sampler needs a repeating address mode.
- **Lifetime.** A trail is removed with its particle, abruptly. To fade the end, let `color_over_life` reach alpha 0 as the particle expires and end `width_over_trail` and `color_over_trail` at 0.
- **Cost.** A trail adds about 20 bytes per stored point to the pool plus 16 bytes per particle. The ribbon batch holds `max_points + 1` points of 40 bytes per particle of `capacity`, which core packs into 48-byte records and re-packs, with its bounds, in every update that changes it, so a system with live trails does so every update.

The trail does not change the simulation or take any spawn draw.

## Update on a job pool

`particle::update` and `particle::step` take a trailing `ParallelFor`, the neutral fork-join hook that core declares and the [job pool](jobs.md) and the physics package use. A zero value runs every range inline on the calling thread. The package never imports `c3d_job`; the `particles` example adapts a `JobPool` to the hook for its `--workers` option.

The pool splits into blocks of 1,024 particles, and each fork runs one block per range for:

- integration of velocity, position and rotation, including drag and turbulence;
- ground-plane collision, for a system with no collision callback and no sub-emitters;
- trail recording;
- publication of billboard records and mesh instances.

Collision raises events in visit order, so a callback or a sub-emitter keeps collision serial. Expiry, admission, emission, events, sub-emitter deliveries and trail publication stay serial, as does everything outside `update`. A range reads and writes only its own blocks, so every hook, partition and range order produces the same pools, counters and draw arrays byte for byte. The hook must return only after every range has finished. A pool of at most one block runs inline whatever the hook.

## Large worlds

Rendering follows the [frame origin](large_world.md). After `Scene.shift_origin`, call `scene.shift_particles(offset)` ([Frame order](#frame-order)). Turbulence reduces the world shift and its scroll to one tile in double precision, so the field stays fixed to world points.

## Serialization

Select `c3d_serial` and enable `C3D_PARTICLE_SERIAL` to register particle authoring codecs. Reads create pending systems; prepare them before ordinary updates. Older payloads read the defaults for fields they lack. The trail child is generated, so it is not written. The collision callback is not serialized. A sub-emitter target is an entity reference and must lie inside the exported subtree. [Serialization](serialization.md#landscape-particle-and-audio-adapters) states the format and versions.

## Limits

- Particle-particle collision does not exist.
- The simulation runs inline with no allocation during `update`; draw arrays and persistent GPU records belong to core.
- A CPU callback or a sub-emitter keeps collision on one thread.
- Pool order carries no meaning; pick indices identify draw records, not particles.
- There is no cross-compiler or cross-version bitwise replay.
- `ParticleSystem.set_collision` needs a prepared CPU system.

## See also

- [Particle reference](particles_reference.md): descriptor tables, counters, constants and faults.
- [GPU particles](particles_gpu.md).
- [Billboards](billboards.md), [ribbons](ribbons.md), [instancing](instancing.md), [custom shaders](custom_shaders.md), [owner readiness](owner_readiness.md), [job pool](jobs.md).
- The `particles` example (`python3 scripts/build.py --example particles`) shows smoke, additive sparks and mesh debris; `particles_gpu` builds it with GPU execution.
