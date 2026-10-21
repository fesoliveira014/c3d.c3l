# Particles

Particle rendering shares the [frame origin](large_world.md) selected through
`FrameInfo.reference_position`. Billboard/mesh packing, soft depth and fog use
relative shader coordinates. Simulation positions, seeds and emitter state keep
their existing spaces; changing the reference does not move the simulation.

The optional `c3d_particle` package supplies fixed-pool particle simulation, on the CPU or, in a build that enables
`C3D_PARTICLE_GPU`, on the [GPU](#gpu-execution), and particle effect materials. It publishes ordinary core
[billboard batches](billboards.md) or [mesh instances](instancing.md). Core owns rendering, culling and sorting.

Select `c3d_particle` alongside core in the consumer project, with the normal
renderer/platform dependencies needed by the application. The package itself
imports only core and the standard library.

## Create an emitter

Inside a fallible function with live `assets` and `scene`, importing
`c3d`, `c3d::particle`, `c3d::scene`, `c3d::asset` and `c3d::material`:

```c3
particle::register_particles(&scene)!;
ShaderId shader = particle::add_particle_shader(&assets)!;
MaterialId sparks = particle::add_particle_material(
    assets: &assets,
    shader: shader,
    params: { .color = { 1, 0.6f, 0.1f, 1 }, .soft_distance = 0.2f },
    blend: BlendMode.ADDITIVE,
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
scene.update_world();
```

Register once before adding systems. Registration can fault `CAPACITY_EXCEEDED`;
destroy the scene after a partial registration failure. Emitter creation itself
is atomic: it validates the descriptor, allocates one pool and creates the
emitter plus one draw child, and a trail child when [trails](#trails) are on, rolling back on failure. Invalid descriptors return
`INVALID_ARGUMENT`; scene capacity failure returns `CAPACITY_EXCEEDED`.

## Pending authoring

`scene.attach_particle_system(node, desc)` validates and attaches authoring to
an existing node. It allocates no pool or draw child and leaves the system
pending. `ParticleSystem.is_prepared()` reports whether both are installed.
The shared [owner readiness table](owner_readiness.md) defines preparation and
removal behavior. Attachment starts with `emitting = true`; this flag remains
application-settable. A codec must restore its authored `emitting` value after
attachment, before preparation, instead of inheriting the attachment default.
`particle::prepare(&scene, node)` prepares one owner.
`particle::prepare_subtree(&scene, root)` attempts every pending system in a
subtree, including its root.
Omit the root or pass null to select the whole scene.

Preparation is a no-op for an already-prepared system. A failure returns
`INVALID_ARGUMENT` or `CAPACITY_EXCEEDED`, retaining pending authoring and
releasing staged pool storage. A subtree pass continues after a failure and
returns the first fault; successful owners remain prepared. Retry individual
owners or the subtree after correcting the cause.

`particle::update` skips pending systems without changing their authoring,
queued bursts or emission controls. They have no generated draw child and draw
nothing. `particle::step` requires a prepared system. The existing
`scene.add_particle_system` combines attachment and preparation and still
returns a ready emitter or removes the incomplete emitter on failure.

## Frame order and ownership

After animation/physics and any emitter edits:

```c3
scene.update_world();
particle::update(&scene, delta_seconds, wind_velocity);
```

Update steps every CPU system, runs the [sub-emitters](#events-and-sub-emitters), then publishes the
draws and trails, so particles spawned by events are drawn in the same update. A trailing
`ParallelFor` runs the [range kernels](#parallel-update) on worker threads.
A system whose `execution` is `GPU` is not stepped here; [`particle::gpu::update`](#gpu-execution) steps it after
`begin_frame`. Render every camera afterward. Rendering does not advance the simulation.
`wind_velocity` is application-owned world-space air velocity in metres/second.
Hidden emitters continue simulating. Their WORLD/identity draw child inherits
visibility and subtree lifetime; update explicitly copies the emitter's layer
mask because layers are not inherited.

After an origin rebase, call `scene.shift_particles(offset)` after `Scene.shift_origin` and before `update_world`. It
subtracts the offset from every live particle position, every stored trail point and every queued event position, and
resets each draw and trail child, which is world-space and was moved by the scene shift, to the identity transform. The next `update_world` and `particle::update` publish the draws.

The descriptor is captured at creation and remains immutable. Runtime controls
are `ParticleSystem.emitting`, `emit_burst(count)`, emitter transforms and wind.
Material values use the ordinary asset revision API. Recreate a system to change
its capacity, emission configuration, render mode or asset references.

The library owns the pool arrays, counters and draw child. Inspect
them as short-lived component borrows; do not resize/edit the arrays or remove,
reparent or replace the owned child independently. Removing the emitter or scene
releases pool and draw storage immediately. Removing only ParticleSystem frees
the pool; the next `particle::update` removes the orphan draw and trail children, so run that
update before rendering. Shared materials, shaders, textures and mesh geometry
remain in the asset store.

## Emission and simulation

Positions and velocities are world-space after emission. Emitter scale affects
spawn volume, while sampled speed remains in world metres/second. Subsequent
emitter motion does not carry existing particles.

- POINT uses the origin and uniform sphere directions.
- BOX samples its volume and independent sphere directions.
- SPHERE samples uniform volume and outward directions.
- CONE samples a disk at local Y=0 and a uniform solid angle about +Y.

Rate emission retains a fractional accumulator. Bursts are queued and remain
effective while `emitting` is false. A request past the free capacity follows the
[saturation policy](#saturation). Refused requests accumulate in `dropped`; the
counters saturate instead of wrapping. Refused requests take no spawn ordinal
and never cause work proportional to their count.

Each update clamps simulated time to 0.1 seconds, expiring existing particles
before accepting emission. Accepted newborns participate in that step's
integration and leave it with age equal to the clamped duration. Newborns with
already-exhausted lifetime expire without a replacement in the same step. A
zero-duration update consumes bursts and publishes age-zero particles.

Velocity receives gravity, then drag toward the air velocity, which is wind plus
[turbulence](#turbulence); position uses that updated velocity. Expiry swap-removes every stream together. Equal seeds/configuration
and identical emitter-pose, delta and wind sequences replay identically within
the same build. There is no cross-compiler/version bitwise guarantee.

Emission keeps no generator state. Every value a particle draws is `spawn_hash(stream, ordinal, draw)`: three
rounds of the PCG output hash over the system `seed` (the stream), the particle's spawn ordinal (the value stored in
`spawn[]`) and the `ParticleDraw` being drawn. The draws are the shape's position and direction, then lifetime, speed,
size, rotation, spin and the particle's colour seed. Unit samples use the high 24 bits of the hash. A particle's values
depend on its ordinal alone, not on how many particles a step admits, the order they are emitted in or the requests
that were refused. Equal scalar endpoints still compute a draw.

One fixed integer hash of the stored seed supplies a single fraction for the RGBA lerp between `color_min` and
`color_max`, then the result is multiplied by the eight-sample colour table. Colour endpoints may descend in any
channel; each endpoint still requires nonnegative finite RGB and alpha in [0,1]. Scalar and colour tables linearly
interpolate normalized age/lifetime.

## Parallel update

`particle::update` and `step` take a trailing `ParallelFor`, the neutral fork-join hook declared by core and shared
with the physics package. A zero value runs every range inline on the calling thread.

The pool splits into blocks of 1,024 particles, and each fork runs one block per range:

- integration of velocity, position and rotation, including drag and turbulence;
- ground-plane collision, for a system with no collision callback and no sub-emitters;
- trail recording;
- publication of billboard records and mesh instances, with colour and flipbook frame.

Collision raises events in visit order, so a callback or a sub-emitter keeps collision serial. Publication counts the
particles each block draws, prefixes the counts serially, then writes each block into its own range of the draw
array, which keeps the compaction and order of a serial pass. A zero hook, or a pool of one block, runs every block in
one call and in order, so publication skips the counting and carries the draw slot from block to block. Expiry,
admission, emission, events, sub-emitter deliveries and trail publication stay serial, as does everything outside
`update`. A range reads and writes only its own blocks, so every hook, partition and range order produces the same
pools, counters and draw arrays byte for byte. The hook must return only after every range has finished, and the data
it hands to each range lives until it returns.

## GPU execution

`ParticleSystemDesc.execution` selects the processor that steps a system: `CPU`, the default, or `GPU`. It is
immutable after `prepare`. The GPU path exists in builds that enable `C3D_PARTICLE_GPU`, which adds the module
`c3d::particle::gpu`; without the feature, preparing a GPU system faults `c3d::UNSUPPORTED`. The module imports `c3d::render` and records through `Renderer.dispatch`; it creates buffers only through
`Renderer.create_buffer` and never imports `gpu`. The `particles_gpu` example builds with the feature, and
`particles --gpu` selects GPU execution for every system the subset below supports.

```c3
GpuParticles gpu = gpu::create_gpu_particles(mem, &assets)!;
defer gpu::destroy_gpu_particles(&gpu, &renderer);

scene.update_world();
particle::update(&scene, delta_seconds, wind_velocity);
renderer.begin_frame()!;
gpu::update(&gpu, &renderer, &scene, delta_seconds, wind_velocity)!;
// render_view and finish_view for each camera, then end_frame
```

`create_gpu_particles` adds the seven compute stages to the store, once per store, and takes the number of systems the
context simulates, `DEFAULT_MAX_SYSTEMS` (16) by default. Each GPU system owns one renderer buffer, created at its
first update, and the context owns one more for the counters; the renderer holds 64 application buffers in all, and a
system past the context's limit faults `CAPACITY_EXCEEDED`. `update` retires the buffer of a system whose node died;
`destroy_gpu_particles` retires the rest, so destroy the context before the renderer.

The application calls `update` once per frame, after `update_world` and before the views render. Each system records
one step: the queued origin shift (only after a rebase), expiry, a prefix scan, admission with spawning, advance and
collision, a second scan, and publication. Once every system has recorded its step, each sub-emitter records one
[delivery](#gpu-sub-emitters). Every dispatch covers the system's capacity, or the system's `max_events` for a
delivery; there is no indirect dispatch.
The pool stays in spawn order. A system's buffer holds 208 bytes per particle: two copies of the particle state, the
scan scratch and one billboard record, or one 128-byte instance record for MESH; a [trail](#gpu-trails) adds `80 + 88 x max_points` bytes, and
[sub-emitters](#gpu-sub-emitters) add 96 bytes per event of `max_events`. The draw child is a
core `DEVICE` [billboard batch](billboards.md#device-batches) over the same buffer, or for MESH a `DEVICE`
[instanced batch](instancing.md#device-batches), so every view culls and sorts the records the compute stages wrote, and
no record is uploaded or copied by the CPU.

### Supported subset

- Supported: every emitter shape, rate and bursts; gravity, drag, wind and turbulence; lifetime tables, colour and
  flipbooks; BILLBOARD, STRETCHED and MESH draw modes; trails; sub-emitters between GPU systems; REFUSE and DROP_OLDEST
  saturation; and `CollisionResponse` BOUNCE, STICK or DIE against `ground_plane` and against a view's
  [depth](#gpu-depth-collision).
- `ParticleSystem.set_collision` requires a CPU system, because the callback is application code. A GPU system
  collides with a view's depth instead.

### GPU trails

A trail's ring lives with its particle, in the same ping-pong buffers as the state, and compaction moves it with the
particle. Each particle has a header (the ring cursor, the stored count, the clock and the path length) and
`max_points` slots of position, age stamp and path length. Advance records points after collision with the CPU's
rules: a clock that gains the step, at most one point per step, the oldest dropped once older than `trail.lifetime` by
particle age. The origin shift moves the stored points with the particles.

The trail child is a core `DEVICE` [ribbon batch](ribbons.md#device-batches) over the same buffer. Publication writes
`max_points + 1` records for every live particle, in spawn order: the live position carrying `RIBBON_BREAK`, the stored
points from newest to oldest, and a break with no width for each unused slot, so a particle with no stored point draws
nothing. A terminating break follows the last strip. The count word is the number of live particles times
`max_points + 1`, which the CPU never reads; the renderer turns it into the draw's segment count on the device. Widths,
colours and texture coordinates follow [Publication](#publication).

### GPU mesh debris

A MESH system publishes one `InstanceGpu` record for each drawn particle, in spawn order, with the count word after the
records. The record holds the matrix the CPU publishes (the position, a turn of `rotation` about +Y and a uniform scale
of the drawn size) packed by core's `pack_instance_record`, and the particle's colour. The batch node keeps the identity
pose of a WORLD child, so the records are in scene space. The records come out as the CPU's within the
[tolerance](#determinism-and-tolerance) below, with one difference: the instance seed, which sway and fade read, is a
hash of the particle's seed, where the CPU path hashes the position, so it does not change as the particle moves.

The draw child is a core `DEVICE` [instanced batch](instancing.md#device-batches). The batch's `cast_shadow` is
`mesh_cast_shadow`, and the shadow layers cull the device records with the same count word as the view, so shadows
appear in the frame that spawns the debris. A device batch has no per-instance history, so motion vectors follow the
batch node alone: debris shows no object motion in a temporal view. Picking and `SceneIndex` skip the batch.

`mesh_trace` is served by a host mirror, because the scene trace reads CPU transforms. A traced system owns a second
`READBACK` buffer of 16 bytes and 48 bytes per particle of `capacity`, which the renderer copies to the host every frame. Publication writes each drawn particle's
position, size, rotation and colour there, and each `update` copies the snapshot that is `FRAMES_IN_FLIGHT` frames old
into the batch's `transforms` and `colors`, sets `count` and marks the batch dirty. The scene trace therefore sees
debris as it was that many frames earlier, and sees none until the first snapshot arrives. A rebase within those frames
moves the traced debris once. The copy is the only per-particle readback; a system without `mesh_trace` has no mirror
and is not traced. A traced system takes two of the renderer's 64 application buffers.

### GPU sub-emitters

A step appends an event for each birth, death and impact that a sub-emitter of the system accepts, with the particle's
position, velocity and seed. Events go to one of two halves of `max_events` entries, so the deliveries that follow a
step read its half while the next step fills the other. An event past `max_events` is dropped, and counted in
`dropped_events` when the step publishes. Birth events come from admission, death events from expiry, from a newborn
that expires in its first step and from a `DIE` response, and impact events from the ground plane, all by the CPU's
rules for the position and velocity they carry.

After every system has recorded its step, `update` records one delivery per sub-emitter of every system that stepped.
It runs one invocation per event slot. An invocation whose event the sub-emitter accepts claims up to `count` free
slots in the target and spawns the children there, at the event position, through the target's own descriptor and
emitter orientation, with the parent's velocity times `inherit_velocity` added. Children that do not fit are counted in
the target's `dropped`, whatever its saturation policy; [DROP_OLDEST](#gpu-drop_oldest) evicts only for the target's own
emitter. The target may be the same system.

Differences from the CPU path:

- A delivery between a GPU system and a CPU system is skipped and counted in the source's `skipped_events`, as is one
  to a target that is dead, not prepared or past the context's `max_systems`. Keep a sub-emitter's target on the
  processor of its source.
- The children are drawn from the next `update`: a delivery writes the target's pool after the target's step, so the
  next step ages them, moves them and publishes them. A delivered child raises its own `BIRTH` event at that step,
  as the CPU does at the next update.
- A child draws `spawn_hash` with a stream hashed from the parent's seed, a key and the sub-emitter index, and its index
  in the delivery as the ordinal. The key hashes the parent's spawn ordinal, the number of steps the system has taken
  and the trigger, where the CPU uses the index of the event, so the two paths do not spawn identical children. Replay
  on one device is deterministic; the order of the children in the pool, and so which of them a full target drops, is
  not.
- The target's [bound](#bounds) includes the box of every source that delivers to it, and grows by the velocity the
  children inherit. A source with large or fast particles therefore widens its targets' bounds.

### GPU DROP_OLDEST

The pool stays in spawn order, so the oldest particles are the first ones in it. When the requests of a step exceed the
free slots, admission leaves out the first `min(survivors, requests - free)` survivors, where the survivors are the
particles that outlived the step's expiry, the children delivered since the last step included. It then admits the
newborns as `REFUSE` does, into the room the eviction frees, and counts what still does not fit in `dropped`. The
newborns of the step are never among the evicted, and a request larger than the capacity evicts every survivor, emits
`capacity` particles and refuses the rest, as on the CPU. `evicted` counts the particles left out.

An evicted particle raises a `DEATH` event, which only the sub-emitters with `on_evict` accept, as on the CPU. The
event takes the position, velocity and seed the particle had before the step moved it, and it counts against
`max_events` like any other. A trail leaves with its particle.

A delivery to a target that saturates does not evict, which differs from the CPU. The children that find no free slot
are counted in the target's `dropped`, as with `REFUSE`. The target's next step can evict the children it did take like
any other survivor.

### GPU depth collision

`update` takes a `DepthCollision { view, camera }` as its last argument. A GPU system with a collision response other
than `NONE` then also collides with the depth that `view` last rendered, in the same step as its `ground_plane` and
under the same `BOUNCE`, `STICK` or `DIE` response; when both offer a hit, the nearer along the move answers. A zero
`view` disables it. `camera` is the node the application passes to `render_view` for that view. The recommended view is
the main camera: one view serves every GPU system of the update, and the other views never affect the simulation.
A GPU system uses no `max_queries`, but a response with no `ground_plane` still needs it non-zero, because
`check_particle_collision` faults `INVALID_ARGUMENT` otherwise; the default is non-zero.

```c3
gpu::update(
    particles: &gpu,
    renderer: &renderer,
    scene: &scene,
    dt: delta_seconds,
    depth: { .view = main_view, .camera = camera_node.id },
)!;
renderer.render_view(&scene, camera_node, main_view)!;
```

A dead `view` or `camera` faults `c3d::INVALID_ID`, and a `camera` node without a `Camera` faults
`c3d::INVALID_ARGUMENT`, both before any dispatch is recorded.

**Which depth.** `update` records before `render_view`, so a dispatch that names `read_view_depth(view)` reads the view's
previous rendering, one frame old (see [dispatch textures](custom_shaders.md#textures)). The package derives the
camera's matrices with `camera::derive_matrices` from the camera node's world matrix relative to the frame origin and
the view's working extent, the same inputs the view renders with, and keeps them with the frame index. The matrices
commit once `Renderer.frame_was_submitted` confirms the frame, so an aborted frame never replaces the camera of an
earlier rendering. The step collides only when `Renderer.view_depth_frame(view)` equals the frame of the committed
matrices; it skips depth collision otherwise:

- on the first frame, and after a `configure_view` that recreated the view's images;
- when the view was not rendered in the previous frame, or the frame was aborted;
- for a path-traced view, which writes no depth;
- in a step that applies a queued origin shift, because the committed camera predates it.

The camera node must not move between `update` and `render_view`. TAA jitter is ignored; the error is sub-pixel.

**The test.** A particle collides with the move from its previous position (`position - velocity * dt`) to its
position. The end is projected to the view. A point behind the camera, outside the image, or over a background texel
(depth 0) has no surface. Otherwise the stage reads the texel with `texelFetch` through `SAMPLER_NEAREST`, sample 0 for
a multisample view, and rebuilds the surface point from it. A hit needs all three:

- the end lies behind the sampled surface, along the view's forward axis;
- the start lies in front of it, or on it;
- the end is no deeper behind the surface than the length of the move plus the collision radius. A deeper point counts as
  occluded, as when a particle passes behind a wall, and is left alone.

**The normal.** The stage rebuilds the position of the hit texel and of its four neighbours. On each screen axis it takes
the neighbour whose distance along the view differs least, so a silhouette edge does not tilt the normal; a background
or off-image neighbour yields to the opposite side. The cross product of the two tangents, turned to face the camera, is
the normal. A texel with no usable neighbour on either axis answers with the direction toward the camera.

**The response.** As on the ground plane: the contact point is the closest approach of the sphere to the surface plane,
the particle ends `radius` along the normal from it, `IMPACT` events follow `impact_speed`, and `DIE` raises `DEATH`.
Blended particles write no depth, so a system never hits itself.

**Cost.** Each system that collides names the depth in its advance dispatch, and each such dispatch records one
barrier to the sampled compute state, so an update with N colliding systems records N barriers, N - 1 of them from
sampled to sampled. A system or step that skips records none. The step's root grows from 896 to 1,088 bytes in the
upload ring for every dispatch of every GPU system.

**Limits.** The view's depth is all the stage knows:

- geometry off-screen, hidden behind other surfaces, or drawn by a view other than the named one is missed;
- the result depends on the view: a surface the named camera cannot see does not stop a particle;
- contact lags one frame: a surface that moved since the depth was rendered is still where it was;
- the view must render every frame that should collide, because a stale depth is not used;
- mesh particles write depth, so a mesh particle can meet another one's previous rendering when its move away from the
  camera is longer than that particle's half-depth and no nearer surface covers the texel; a fast diagonal stream can
  show it;
- a particle that starts a step behind a surface is not pulled out of it, so one that rises through the underside of a
  surface the camera sees from above passes through.

### Counters and latency

The simulation state lives on the device. `alive`, `dropped`, `evicted`, `dropped_events` and `skipped_events` are read
back from a `READBACK` buffer and reach the CPU `FRAMES_IN_FLIGHT` frames late; all read 0 before the first copy, and a
frame without a copy keeps the previous values. A traced mesh system's [mirror](#gpu-mesh-debris) arrives the same
way. A delivery's `dropped` and `skipped_events` reach the buffer with the target's or source's next step, one update
later than the rest. Nothing waits for the device.

### Aborted frames

A step's CPU bookkeeping (the emission accumulator, the consumed burst, the queued shift and the bound) commits only
when `Renderer.frame_was_submitted` confirms the frame that recorded it. A frame that aborts never runs its
dispatches, so the next `update` steps again from the committed state and takes the same burst. Call `update` once per
frame.

The renderer stops reporting a frame once `FRAMES_IN_FLIGHT` frames have passed. An `update` that comes later than that,
after a pause or a loading screen, therefore commits the step, because only an aborted frame is not submitted. The
residual case is an aborted frame followed by such a gap: the step never ran, but its burst and queued shift count as
consumed, and the burst is lost. If that frame was the system's first, the committed step also marks the device state
live, so the next step reads a control block that no dispatch initialized, and the system draws garbage particles until
they expire. The two cases cannot be told apart, since a first step that ran and one that aborted look the same after the
gap, and treating the first as the second would discard a step that did run.

### Rebasing

`Scene.shift_particles(offset)` queues the shift for a GPU system. The next `update` subtracts it from every live
particle before the step. Turbulence stays fixed to world points: the CPU reduces the world shift and the scroll drift
to one tile in double precision, and the stages evaluate the field in float.

### Determinism and tolerance

Both paths draw every spawned value from `spawn_hash`, which `particle_random.glsl` mirrors by name, so a CPU and a GPU
system with one descriptor spawn the same particles. They differ only by floating-point order: the stages use float
where the CPU uses double for the spawn samples and the flipbook, and the device's sine, cosine and fused operations.
Replay is deterministic on one device and driver; there is no bit equality across devices, drivers or compilers.
The acceptance case compares positions within 1e-3 m and sizes within 1e-5 m, the stored points of a trail within
1e-3 m, and the matrix elements of a mesh record within 1e-3 and its colour within 1e-4.

### Bounds

The CPU never reads the device records, so it bounds them from the descriptor. A `ParticleReach` keeps the union of
the emitter's placed shape for each of `REACH_SLOTS` (8) slices of the last `lifetime.max` seconds, and `update`
sets the draw child's bounds override to that union grown by:

- `speed.max` times `lifetime.max`;
- the fall `½·|g|·T·(T + 0.1 s)` along gravity, one-sided;
- for a `BOUNCE` response, the speed bound times `T` on every axis in place of the first term, where the bound adds the
  inherited speed, `|g|·T`, the winds and the turbulence to `speed.max`: a bounce off a sloped surface in a depth turns
  the fall sideways and never speeds a particle up, and the plane's own bounces are widened too because the reach cannot
  know whether `update` receives a depth;
- with non-zero drag, the winds of the last lifetime times `T`, one-sided, and the turbulence speed bound times `T`,
  where the bound is the curl supremum 8.5 times the octave amplitudes;
- the largest drawn half-extent, from the size tables and the stretch, or for MESH the largest size times the distance
  from the origin of the geometry to the farthest corner of its bound;
- for a ground-plane response, the plane's height and one collision radius above it.

The trail child takes the same box grown by half the widest strip on every axis, because a stored point is a past
position of a living particle and lies inside the box. The box is conservative and grows with lifetime and turbulence
strength. It only decides whether core culls the whole batch; each billboard is still culled on the GPU, while a trail
draws every segment of a visible batch. Moving the emitter widens it over the next lifetime.

## Saturation

`ParticleSystemDesc.saturation` selects what a step does when the burst and rate
requests exceed the free capacity.

- `REFUSE`, the default, emits what fits. The rest is refused and counted in
  `dropped`.
- `DROP_OLDEST` evicts the oldest live particles to make room, then emits.

A step runs in this order: expire, compute the request (queued bursts plus rate
credit), evict, emit. Under `DROP_OLDEST` with `alive + request > capacity`, the
step evicts `min(alive, alive + request - capacity)` particles with the smallest
`ParticleSystem.spawn` values. Each particle takes its spawn value from the
system's `next_spawn` counter at birth, so values are unique and "oldest" has no
ties. Particles born in the step do not exist yet when eviction runs, so same-step
births are never evicted. A request larger than the capacity still emits
`capacity` particles and refuses the excess into `dropped`.

`dropped` counts requested particles that were refused for lack of room.
`evicted` counts live particles removed to make room. Both are cumulative, start
at zero, saturate instead of wrapping, and restart when a system is read from
serialized data. Neither eviction nor refusal consumes PRNG draws, so emission
draws are the same under both policies.

Eviction runs only on a saturated step and selects the victims in one pass over
the pool. The pivot is the median of three fixed slots, never random, so equal
seeds and call sequences evict the same particles and leave the same pool. The
selection reorders the pool in place; pool order carries no meaning, as expiry
already swap-removes. The `spawn` stream adds 8 bytes per particle to the pool
under either policy. A [GPU system](#gpu-drop_oldest) keeps its pool in spawn
order and evicts its first survivors, the same particles.

## Events and sub-emitters

A sub-emitter spawns particles in another particle system where a particle of this one is born or dies.
`ParticleSystemDesc.sub_emitters` holds up to `MAX_SUB_EMITTERS` entries, `sub_emitter_count` of them in use.
`max_events` sizes the event queue; it must be at least 1 when sub-emitters are present.
A `SubEmitter` has these fields:

| Field | Meaning |
| --- | --- |
| `trigger` | `DEATH` fires when a particle expires, is evicted or dies on impact. `BIRTH` fires when a particle is emitted. `IMPACT` fires when a particle hits a surface, see [Collision](#collision). |
| `target` | The node of the particle system that receives the children; it may be the same system. |
| `count` | Particles spawned per event. |
| `inherit_velocity` | Share of the parent particle's velocity added to each child, in [0, 1]. |
| `on_evict` | Lets `DEATH` fire for evicted particles as well. Off by default, which bounds cascades under `DROP_OLDEST`. |

### Events

A step raises `DEATH` events with cause `EXPIRED`, `EVICTED` or `IMPACT`, `BIRTH` events, and `IMPACT` events. An event is queued only if
some sub-emitter of that system accepts it, so events nobody listens for neither occupy the queue nor count as
dropped. An event records the particle's position, velocity and seed, and its index in the system's event sequence.

The queue has `max_events` entries of 48 bytes each, inside the pool allocation. An event raised into a full queue
is lost and counted in `dropped_events`. Size the queue for the most events one update can raise: the deaths and
births of one step, plus events carried over from the previous update.

### Delivery

After every system has stepped, `particle::update` processes the queues in store order, then queue order, and
delivers each event to each accepting sub-emitter in index order. A delivery spawns `count` particles in the
target, at the event position, through the target's own emission shape and descriptor. The target's world matrix
supplies the orientation and scale; its translation is replaced by the event position. A child's velocity is
its emitted velocity plus the parent's velocity times `inherit_velocity`. Children start at age zero and are first
integrated by the next update.

The children draw `spawn_hash` with a stream hashed from the parent particle's seed, the event index and the
sub-emitter index, and with their index in the delivery as the ordinal. They use none of the target's own `seed`,
and equal inputs replay equal children.

A target that is not alive, is not a particle system, is not prepared, or runs on the other processor than the source
is skipped, and each skipped delivery is counted in the source system's `skipped_events`. A GPU source delivers as
[GPU sub-emitters](#gpu-sub-emitters) describe. Update adds and removes no nodes, so targets must exist and be
prepared before the update runs; attach pending systems and call `prepare_subtree` first.

A delivery requests `count` particles from the target as a burst would, so the target's
[saturation policy](#saturation) applies. With `REFUSE`, children that do not fit are counted in the target's
`dropped`. With `DROP_OLDEST`, the target evicts its oldest particles to make room, counted in its `evicted`, and
raises `EVICTED` events for its own sub-emitters; children beyond its capacity are counted in its `dropped`.

### Recursion

Events raised while events are being delivered wait for the next update. These are `BIRTH` events of children
and `EVICTED` events in a target. A chain from A to B to A therefore advances one level per update, and the work of
one update is bounded by the queue capacities.

### Counters

| Counter | Counts |
| --- | --- |
| `dropped` | Requested particles refused for lack of room. |
| `evicted` | Live particles removed to make room. |
| `dropped_events` | Events lost to a full queue. |
| `skipped_events` | Deliveries whose target was unavailable. |
| `collision_skips` | Particles that waited out a step because the callback budget ran out. |

All five are cumulative, start at zero, saturate instead of wrapping, and restart when a system is read from
serialized data. A descriptor with more than `MAX_SUB_EMITTERS` sub-emitters, an `inherit_velocity` outside
[0, 1], or sub-emitters with `max_events` of zero fails `INVALID_ARGUMENT`.

## Collision

`ParticleSystemDesc.collision` makes a system's particles meet surfaces. The default response is `NONE`. A GPU system has
no callback: it meets the ground plane and, when `gpu::update` receives a `DepthCollision`, a view's
[depth](#gpu-depth-collision). A
`ParticleCollision` has these fields:

| Field | Meaning |
| --- | --- |
| `response` | `NONE` disables collision. `BOUNCE` reflects the particle. `STICK` stops it. `DIE` removes it. |
| `restitution` | Share of the normal speed a bounce keeps, in [0, 1]. |
| `friction` | Share of the tangent speed a bounce loses, in [0, 1]. |
| `radius_scale` | The collision radius is the drawn size, `size` times the size table, times this scale. |
| `ground_plane` | Collide with the plane `y = ground_height`, with no callback. |
| `ground_height` | Height of the plane, in world metres. |
| `max_queries` | Callback casts per step. |
| `impact_speed` | Least speed into the surface, in metres per second, that raises an `IMPACT` event. |

A step runs in this order: expire, evict, emit, integrate, collide. After integration each particle's last move is
tested as the segment from `position - velocity * dt` to `position`. A segment of zero length, as in a
zero-duration update or for a particle at rest, is not tested. Newborns are tested over their first move. Children
spawned by event delivery are tested from the next step.

### Ground plane

`ground_height` is a world height; the origin rebase moves nodes horizontally only, so it never moves the plane. The
plane needs no callback and is tested for every particle in every step.
A particle hits it when its segment ends with the centre less than one radius above the plane while moving down.
A segment that starts at or below that height hits at its start, so a particle resting on the plane cannot fall
through it by rounding, and a particle that starts under the plane and moves down is placed on it.

### Callback

`ParticleSystem.set_collision(cast, context)` installs a `ParticleCollisionFn` on a CPU system. The system calls it with the
segment of a particle's move in scene space and the collision radius, and it fills a `ParticleHit` and returns
true when a sphere of that radius meets a surface. `point` is the contact point on the surface, `normal` has unit
length and faces the particle, and `fraction` is the position of the hit along the segment. The package does not
import physics or any other query provider; the application adapts one.

- The cast runs on the owner thread inside `particle::update`. A physics world must not be stepping then: call
  its update before `particle::update`, as the `particles --collide` example does.
- `context` is passed unchanged to every call. It must outlive the system, or the application clears the cast
  first with `set_collision(null, null)`. A null `cast` removes it.
- The cast and context are not serialized. A system that was loaded, or prepared again, needs `set_collision`
  again. `set_collision` requires a prepared system.
- When both the plane and the cast are active, a particle takes the hit with the smaller fraction.

A physics adapter casts a ray along the segment:

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

`PhysicsWorld.cast_shape` with a sphere collider of `radius` also honours the radius, and `spatial::pick` serves
scene meshes without physics; both allocate per call, so give them a small `max_queries`.

### Budget

At most `max_queries` casts run per step. The step starts at `query_cursor`, a pool index, and visits the pool in
order, wrapping at the end. When the budget runs out, the remaining particles skip the callback that step and
are counted in `collision_skips`; the plane still applies to them. The next step starts at the first particle
that was skipped, so no particle is skipped every step, and with a steady pool each is queried at least once every
`ceil(alive / max_queries)` steps. A step that fits in the budget leaves the cursor unchanged. `max_queries = 0`
disables the callback. The pool order changes when particles die, so the cursor is a rotation, not a fixed assignment.

### Responses

A `BOUNCE` or `STICK` hit places the particle at `point + normal * radius` and drops the rest of that step's move.

- `BOUNCE` splits the velocity into a part along the normal and a part across it. The normal part is reversed and
  scaled by `restitution`; the tangent part is scaled by `1 - friction`. A hit on a particle that is moving away
  from the surface leaves its velocity alone.
- `STICK` sets the velocity to zero.
- `DIE` removes the particle. Its `DEATH` event has cause `IMPACT`, and `on_evict` does not apply to it.

A hit raises an `IMPACT` event, for `IMPACT` sub-emitters, when the speed into the surface before the response is
at least `impact_speed`. The event is at `point` and carries the velocity from before the response. The default
speed is 1 m/s, above the 0.98 m/s that gravity adds over the longest step, so a particle that sticks or settles on
a surface stops raising events once its speed into it falls below that. Zero raises an event for every hit. The response
applies to every hit, and a `DIE` hit raises its `DEATH` event whatever its speed.

A particle pressed against a surface still hits it on every step, so it spends one callback query per step.

Collision takes no spawn draws, and its results follow the cast's answers in pool order.
A descriptor with `restitution` or `friction` outside [0, 1], a negative or non-finite `radius_scale` or
`impact_speed`, a non-finite `ground_height`, or a response other than `NONE` with no plane and `max_queries` of
zero fails `INVALID_ARGUMENT`.

## Draw modes and materials

BILLBOARD uses square camera-facing quads. STRETCHED supplies core with the unit
world velocity as direction and full dimensions `(size, size + speed * stretch)`;
core handles per-camera projection and the zero/parallel-direction fallback. Both
write world-space `BillboardRecord` values into a `RECORDS` [batch](billboards.md#sources)
that core copies relative to the frame origin, so no per-particle conversion runs in the renderer.
Rotation is an extra in-plane turn. MESH publishes the supplied geometry/material
with uniform scale and rotation about world +Y; a GPU system publishes [device records](#gpu-mesh-debris) instead. Mesh particles inherit that
material's alpha/depth behaviour. Zero-area/zero-scale output is omitted without removing the simulated
particle. Pick indices identify compacted draw records, not stable particles.

`mesh_cast_shadow` and `mesh_trace` apply to MESH systems and default to false, so debris neither casts
shadows nor enters the scene trace. Both are copied to the owned `InstancedMesh` child when the system is prepared,
and core's rules for instanced batches apply to them:

- Debris shadows need an opaque or masked material. A blended Standard material casts only into the translucent
  maps of [colored shadows](shadows.md#colored-shadows), and a custom blended material never casts.
- `mesh_trace` adds one trace instance per live particle, taken from `RendererDesc.max_trace_instances`
  (4,096 when zero) with the scene's other traced meshes. A scene past that capacity faults
  `c3d::CAPACITY_EXCEEDED` when the renderer prepares the trace; see [scene tracing](scene_trace.md#what-traces).
  Only opaque and masked materials trace.
- Setting either field outside MESH mode fails `INVALID_ARGUMENT`.

`add_particle_shader` creates a shared fragment-only shader using core's depth
snapshot, with its [weighted form](custom_shaders.md#weighted-transparency), so source-over
particles take part in a view with `transparency = WEIGHTED`. `add_particle_material` copies a 32-byte payload and creates a blended,
depth-tested, double-sided material with depth writes off. Slot 0 is an optional
sprite map. `ParticleMaterialParams.color` multiplies particle/texture colour.

`soft_distance > 0` fades coverage over the scene-depth gap. Zero disables the
fade, retaining hardware depth testing. The shader still declares depth reads,
so setting soft distance to zero does not remove its snapshot requirement.
Empty/hidden batches make no draw or snapshot request.

`ParticleMaterialParams.lighting` selects the illumination:

- **UNLIT** keeps the input radiance.
- **AMBIENT** multiplies it by scene ambient plus core diffuse indirect
  illumination, including the environment or selected probe volume.
- **DIRECT** adds every punctual and directional light that shares a layer with
  the particle system, on top of AMBIENT. The stage walks the clustered light
  list when the frame has clusters and the flat list otherwise.
- **DIRECT_SHADOWED** is DIRECT with each light multiplied by its shadow-map and
  cloud-shadow visibility at the particle's position, and, for the sun in a view
  with a [medium](fog.md#medium-volumes), by the mean of the medium's sun column
  there.

`ParticleMaterialParams.normal` selects what a lit particle presents to the
lights and to the indirect illumination. AMBIENT, DIRECT and DIRECT_SHADOWED read
it; UNLIT ignores it.

- **CAMERA** is the billboard's facing axis, so every pixel has the same normal.
- **SPHERICAL** bulges the normal toward the camera across the quad, as on a
  sphere inscribed in it. It is built in the quad's own frame, so the particle's
  rotation and the STRETCHED axis turn it with the quad, and the sphere's top is
  the quad's top edge.
- **VOLUME** has no surface. Each light scatters through the Henyey-Greenstein
  phase function with `ParticleMaterialParams.anisotropy`, the asymmetry
  `HeightFog.anisotropy` and `MediumVolume.anisotropy` use: positive values
  scatter forward, so the particle brightens when the camera looks toward the
  light. The angle is taken between the view ray from the camera and the
  direction to the light.

`anisotropy` applies to VOLUME only; other normals ignore it. `add_particle_material`
faults `INVALID_ARGUMENT` for a value that is not finite or lies outside (-1, 1).
The normal and the anisotropy can change at runtime with the other parameters.
`@set_custom_params` bypasses the check, so the application keeps |anisotropy| below one.

Each light adds `albedo * response * radiance` to the AMBIENT term, where albedo
is the particle colour times the material colour times the map in slot 0 and
radiance is the light's colour, intensity and attenuation. The response is
`max(N.L, 0) / pi` for CAMERA and SPHERICAL, the Lambert convention core
materials use. For VOLUME it is the phase function, which integrates to one over
the sphere: at zero anisotropy it is `1 / (4 pi)`, a quarter of Lambert's
response at normal incidence, so a light meant to read on smoke needs a
correspondingly higher intensity. The indirect term of AMBIENT, DIRECT and
DIRECT_SHADOWED uses the SPHERICAL normal under SPHERICAL and the camera axis under
CAMERA and VOLUME.

DIRECT_SHADOWED reads the shadow atlas, the cloud shadows and the medium's sun
column only. The column takes the mean of its channels, so a particle inside a
medium dims without taking the medium's tint. A DIRECT particle inside a medium
is lit as in air. The stage is compiled without ray-traced shadows, so a light
whose only shadow is ray traced contributes unshadowed, in views that trace
shadows too. Particles cast no shadow, and the stage ignores the receive-shadow
flag, which billboard draws never carry: the lighting mode is the opt-in.

DIRECT adds one light loop per covered pixel, and DIRECT_SHADOWED adds a shadow
lookup per shadow-casting light in that loop. The cost therefore grows with the
pixels a system covers and with the lights that reach them, which is why the
modes are opt-in.

Fog uses `apply_material_fog` on the lit colour before coverage is premultiplied
exactly once. ADDITIVE adds the lit, coverage-scaled RGB and preserves
destination alpha. The ordinary and the weighted-transparency forms light alike.

Simulation is inline, with no allocation during normal step/update. The pool is
one aligned allocation of nine capacity-sized streams, the event queue and, with [trails](#trails), the trail
streams; core separately owns draw arrays and persistent GPU records. GPU simulation, particle-particle collision
and parallel execution are outside this delivery. Core
billboard material restrictions are documented separately.

### Mixed transparency

Core sorts the instances of a blended batch within that batch, not across batches, so overlapping smoke and
sparks systems draw in scene order. A view with `transparency = WEIGHTED` records source-over particle batches in the
[weighted pass](materials.md#weighted-transparency) and skips their sort, because the particle shader has a weighted
form; additive batches, such as sparks and embers, keep their sort in that view. There is no global sort across
batches.

## Flipbooks

`ParticleSystemDesc.flipbook` plays a sprite sheet on BILLBOARD and STRETCHED particles. It is off while `columns`
is 0. The system copies the layout to its draw child's [sprite sheet](billboards.md#sprite-sheets) when it is
prepared, so frames run row-major from the top-left cell of the image as stored. A `ParticleFlipbook` has these fields:

| Field | Meaning |
| --- | --- |
| `columns`, `rows` | Grid of the sheet; 0 columns disables the flipbook. |
| `frame_count` | Frames played, 1 to `columns` x `rows`. |
| `inset` | UV units cut from each cell edge; half a texel of the sheet texture. |
| `mode` | `OVER_LIFE` spreads the frames over a particle's lifetime. `FPS` plays them at `fps` frames per second of age. |
| `fps` | Frames per second of age in `FPS` mode; finite and above 0. |
| `random_start` | Each particle starts on a frame chosen from its seed. |
| `blend` | Writes fractional frames that blend toward the next frame. Off writes whole frames. |

Each update writes `Billboard.frame` for every published particle. Let t be age divided by lifetime, clamped to
[0, 1], and s the start frame: 0, or with `random_start` the frame chosen below. Let n be `frame_count`.

| Mode | Frame |
| --- | --- |
| `OVER_LIFE`, `blend` | s + t x (n - 1) |
| `OVER_LIFE`, whole frames | s + min(floor(t x n), n - 1) |
| `FPS` | s + age x `fps`, floored when whole frames are written |

The value is written modulo n, so floats stay small. A fractional frame blends toward the next one, and the last
frame blends toward frame 0. Under `OVER_LIFE` a particle with a start frame plays n - 1 frames on from it, wrapping
past the last frame.

The start frame is the fraction of a second hash of the particle's seed, times n, rounded down. It takes no spawn
draw, so equal seeds emit equal particles with or without a flipbook.

`add_particle_shader` samples slot 0 at the current cell through UV0. On a draw with a sprite sheet it also samples the
next cell through UV1 and mixes the two by `v_billboard.z`, the fraction of `frame`, whichever UV set the slot names.
A draw without a sprite sheet samples once. A flipbook draw therefore takes two texture samples per fragment, also
for whole frames. Other fragment stages read the sheet as described in [billboards](billboards.md#sprite-sheets).

`add_particle_system` and `attach_particle_system` fault `INVALID_ARGUMENT` for a flipbook in MESH mode, a layout that
breaks the [billboard sprite-sheet rules](billboards.md#sprite-sheets) (`frame_count` outside 1 to `columns` x `rows`,
`rows` of 0, an `inset` that is negative, not finite or at least half a cell), and an `fps` that is not finite or not
above 0 in `FPS` mode. A disabled flipbook reads only its `inset`.

Neighbouring cells meet at a texel boundary, so filtering can mix their colours. The
[edge rules](billboards.md#edges-and-mipmaps) apply: set `inset` to half a texel of the sheet, pad each cell of a
mipmapped sheet with 2^(m-1) texels for m sampled levels, and expect no guarantee under anisotropic filtering.

## Turbulence

`ParticleSystemDesc.turbulence` adds a swirling, divergence-free air motion to the air that drag pulls particles
toward. It is off while `strength` is 0. A `ParticleTurbulence` has these fields:

| Field | Meaning |
| --- | --- |
| `strength` | Metres per second of air velocity at the first octave; 0 disables turbulence. |
| `frequency` | Lattice cells per metre. |
| `octaves` | 1 to `MAX_TURBULENCE_OCTAVES`. Each octave doubles the frequency and halves the speed. |
| `period` | Lattice cells per tile, 1 to `MAX_TURBULENCE_PERIOD`. |
| `scroll` | Metres per second that the pattern drifts; the pattern moves with `scroll`. |

The field is the curl of three tiled 3D gradient (Perlin) potentials with a quintic fade and analytic derivatives, so
it has no sources or sinks. The potentials read disjoint bits of one lattice hash. Octave k uses `period` x 2^k cells
over the same length as the first, so every octave tiles. The first octave's root-mean-square speed is about
`strength`; the sum of octaves is somewhat faster. Because the field is periodic, it repeats every
`period` / `frequency` metres along each axis. Choose a period length that exceeds the extent of the effect, or the
repeat shows.

The sample point is `position` + `Scene.world_shift` - `scroll` x t, in double, where t is
`ParticleSystem.turbulence_time`: the seconds the system has stepped, restarting at 0 whenever the system is created
or read. The point is reduced modulo the period length in double and then evaluated in float. A particle at the same
world point therefore sees the same air velocity before and after an origin rebase, up to the float rounding of its
shifted position. `Scene.shift_particles` needs no further call.

Drag blends the velocity toward `wind` + the turbulence velocity, by the same `min(1, drag x dt)` share as before.
**A system with zero drag ignores turbulence** and wind alike. A higher drag follows the swirl more closely.
The blend is convex, so turbulence alone never takes a particle faster than the air.

The field takes no spawn draw and depends only on position and time, so equal seeds emit
equal particles with or without turbulence, and replays repeat.

`add_particle_system` and `attach_particle_system` fault `INVALID_ARGUMENT` for a `strength`, `frequency` or `scroll`
value that is not finite, a negative `strength`, and, while `strength` is above 0, a `frequency` of 0 or less, an
`octaves` outside 1 to `MAX_TURBULENCE_OCTAVES` and a `period` of 0 or above `MAX_TURBULENCE_PERIOD`. A disabled
turbulence reads only the finiteness rules.

Cost falls on `particle::update`, not on rendering, and grows linearly with the live particles and the octaves. Each
octave is one curl evaluation per particle per step: eight lattice hashes and three analytic gradients. The tile
reduction runs once per particle in double. A system with zero strength, or with zero drag, evaluates nothing.

## Trails

`ParticleSystemDesc.trail` records the path of every particle and draws it as a camera-facing strip through a core
[ribbon batch](ribbons.md). It is off while `max_points` is 0. A `ParticleTrail` has these fields:

| Field | Meaning |
| --- | --- |
| `max_points` | Stored points per particle, 2 to `MAX_TRAIL_POINTS`; 0 disables the trail. The live position is one more point and is not stored. |
| `point_interval` | Seconds of particle age between recorded points; above 0. |
| `lifetime` | Seconds a recorded point lives; above 0. |
| `width` | Metres across the strip at the live position; 0 or more. |
| `width_over_trail` | Width multiplier by point age over `lifetime`. It may end at 0, which narrows the strip to nothing. |
| `color_over_trail` | Colour multiplier by point age over `lifetime`; it multiplies the particle's colour. |
| `uv` | `STRETCH` or `TILE`, see below. |
| `tile_length` | Metres of path per texture coordinate unit under `TILE`; above 0 there. |
| `material` | Blended material of the trail batch, as for [ribbons](ribbons.md#materials-and-supported-paths). |

The trail does not change the simulation or take any spawn draw, so equal seeds emit equal
particles with or without a trail. A system with GPU execution records and publishes its trail on the device, see
[GPU trails](#gpu-trails).

### Recording

At the end of each update, after collision, a particle's clock gains the step. When the clock reaches `point_interval`
the particle's position is stored and one interval is taken off the clock; a step of two intervals or more clears the
rest. A particle therefore stores at most one point per update, and a `point_interval` shorter than the step stores one
per step. When `max_points` are stored, the next point overwrites the oldest. A stored point older than `lifetime`, by
particle age, is dropped from the tail. A new particle draws no trail until its first point is stored.

### Publication

The system owns a second world-space child with a ribbon batch of `capacity` x (`max_points` + 1) points. Each update
writes one strip per particle that has a stored point: the live position first, carrying `RIBBON_BREAK`, then the stored
points from newest to oldest. Other particles contribute nothing. A particle whose size table reaches 0 still draws its
trail. The batch is not sorted by depth within itself, so overlapping source-over trails blend in strip order; additive
or weighted blending is order-independent, see the [ribbon material rules](ribbons.md#materials-and-supported-paths).

Let f be a point's age divided by `lifetime`, in [0, 1], with the live position at 0. A point's width is `width` x
`width_over_trail`(f). Its colour is the particle's current colour, `color_over_life` included, x `color_over_trail`(f), so
every point of a strip shares one base colour.

The strip runs from the head to the tail, so by the [ribbon orientation](ribbons.md#texture-coordinates) the texture
coordinate v rises from the head to the tail in both modes: the top row of the image is at the head.

| `uv` | v of a point |
| --- | --- |
| `STRETCH` | f. The head is 0 and the oldest point approaches 1, so the image spans the trail and travels with it. |
| `TILE` | minus the path length, divided by `tile_length`. The path is measured along the recorded points; the live position adds its distance from the newest one. The coordinate of a stored point never changes, so the image stays fixed along the path and the head slides over it. |

`TILE` coordinates are negative and fall without bound as a particle travels, so the material's sampler needs a
repeating address mode.

### Lifetime

A trail is removed with its particle, on expiry, eviction or a `DIE` impact, and its removal is abrupt: the whole
trail disappears in the update that removes the particle. To fade the end, let `color_over_life` reach alpha 0 as the
particle expires, which fades every point of its trail, and end `width_over_trail` and `color_over_trail` at 0 so that
the older points narrow and fade.

### Cost and validation

On the CPU, a trail adds about 20 bytes per stored point to the pool: 12 for the position, 4 for the age stamp and 4 for
the path length. It adds 16 bytes per particle for the ring cursor, the stored count, the clock and the path length. The
ribbon batch holds (`max_points` + 1) points of 40 bytes for each particle of `capacity`, and core packs them into
48-byte GPU records. Core re-packs the batch and recomputes its bounds in every update that changes it, so a system with
live trails does so every update. Recording is a constant amount of work per live particle, publication costs per drawn
point, and removing a particle copies its ring.

`add_particle_system` and `attach_particle_system` fault `INVALID_ARGUMENT` for a `point_interval`, `lifetime`, `width` or
`tile_length` that is not finite, a negative `width`, a table entry that is not finite or is negative, and, while
`max_points` is above 0, a `max_points` of 1 or above `MAX_TRAIL_POINTS`, a `point_interval` or `lifetime` of 0 or
less, a `tile_length` of 0 or less under `TILE`, and a `capacity` x (`max_points` + 1) beyond the 32-bit ribbon capacity.
A disabled trail reads only the finiteness and sign rules.

## Example and measurements

```powershell
python scripts/build.py --example particles
python scripts/build.py --target particles --opt O3
python scripts/build.py --target particles_gpu --opt O3
addons/c3d_particle.c3l/build/particles_gpu.exe --benchmark --gpu --frames 300
addons/c3d_particle.c3l/build/particles.exe --benchmark --frames 300
addons/c3d_particle.c3l/build/particles.exe --stress --frames 300
```

Linux uses `build/particles` without `.exe`. The window shows smoke, additive
stretched sparks and mesh debris, with emitting/burst controls, wind, smoke
lighting/soft distance, spark blending and a second camera. Validation is always
enabled. `--frames N` closes an interactive smoke test after N frames.

`--gpu` gives the smoke, sparks, debris and embers systems, and the smoke that `--sparks` feeds, GPU execution where the
[subset](#supported-subset) allows it. `--capacity` scales the debris pool and rate with the spark pool, from 1,024 and
450 per second at the default 4,096 sparks. It needs the
`particles_gpu` build, which enables `C3D_PARTICLE_GPU`, and applies to the window and to `--benchmark`, which then
prints `execution,gpu`, the `gpu_particle_ms` of the custom compute pass, and `not_applicable` for the CPU-only
`sparks_bounds_ms` and `sparks_copy_ms`. With `--collide` the GPU sparks collide with the ground plane and with the
[depth](#gpu-depth-collision) of the main camera's view, so they meet the canopy and the crates where that camera sees
them. The CPU sparks meet them from every side through the physics ray cast: sparks that rise from below the canopy pass
through its underside on the GPU. The flag does not combine with `--stress`.

`--sparks` adds a smoke system that each dying spark feeds through a `DEATH`
sub-emitter, and shows its live count with the event counters. It applies to the
window and to `--benchmark`, which also prints them. The smoke pool and the event queue grow with `--capacity`. Under
`--gpu` the sparks and the smoke both run on the GPU, so the sub-emitter delivers on the device.

`--smoke` plays a generated 4x4 sprite sheet on the smoke system, in `FPS` mode with `random_start` and `blend`.
Each 64-texel cell holds one puff inside an 8-texel border at zero alpha, and the batch `inset` is half a texel, so the
sheet follows the edge rules for four sampled mip levels. It applies to the window and to `--benchmark`, which can
save the image with `--capture-rgba`. The inspector's smoke controls drive both smoke materials. The flag does not
combine with `--stress`.

`--embers` adds a system of rising additive embers whose drag follows a three-octave turbulence field that scrolls
upward. It applies to the window, which shows the live count, and to `--benchmark`, which prints `embers,alive`. With
`--stress` it gives the stress system the same turbulence, and each segment prints `turbulence_octaves`; run `--stress`
with and without `--embers` to compare the update cost.

`--trails` gives the sparks a trail of 24 points, one per rendered frame at the fixed benchmark step, fading and
narrowing to nothing over 0.4 seconds, drawn additively with a generated soft-edged streak texture. Combine it with
`--collide` for sharp turns at the bounces. It applies to the window and to `--benchmark`, and to the GPU sparks under
`--gpu`. With `--stress` it gives the stress system the same trail, and each segment prints `trail_points`,
`trail_draw_count` and the core `ribbon_bounds_ms` and `ribbon_pack_ms` beside the billboard timings; run `--stress`
with and without `--trails` to compare the update cost.

`--lit-smoke` shows only the smoke, lit: a plume with a point light circling it, under a directional light
whose shadow an overhead slab casts across part of the plume. The L key cycles the lighting through its four
modes and the N key cycles the normal through its three. `--lighting` and `--normal` set the starting modes
by lowercase name, for example `--lighting direct_shadowed --normal volume`. With `--benchmark`, the run
reports the transparent pass for AMBIENT, DIRECT and DIRECT_SHADOWED as the segments `ambient`, `direct`
and `direct_shadowed`, or for the `--lighting` mode alone. Sparks and debris do not emit, and the flag does
not combine with `--stress`, `--sparks`, `--smoke`, `--embers`, `--trails` or `--collide`.

`--debris-shadows` sets `mesh_cast_shadow` on the debris system, gives the sun a shadow map and draws the ground
with a Standard material, which receives the shadows. It applies to the window and to `--benchmark`, and does not
combine with `--stress` or `--lit-smoke`.

`--collide` makes the sparks bounce on the ground plane and, through a physics
ray cast, on a canopy and two crates that are static physics bodies. It applies
to the window and to `--benchmark`, and `--benchmark` prints `collision_skips`.
The `particles` target selects `c3d_physics` for this; the particle package never imports physics.

`--workers N` runs the [range kernels](#parallel-update) on a `c3d_job` pool of N workers; the `particles` target
selects `c3d_job` for this, and the particle package never imports it. It applies to the window, `--benchmark` and
`--stress`, which prints the worker count of each segment. `--views 2` and `--capacity N` apply to `--benchmark`: the
first renders the second camera into its own target, and the second sets the spark pool, with the emission rate
scaled to keep it full. The benchmark prints `upload_bytes`, the mean bytes uploaded per frame, which do not depend
on the number of views, and `sparks_bounds_ms` and `sparks_copy_ms`, the CPU cost of the spark batch's bounds and
record copy over the final pool.

The example reads `Renderer.adapter_name`, borrowed until renderer destruction,
and calls `renderer.log.check_validation()` through core. The latter reports a
backend validation error retained in the recent diagnostic ring; overwritten
entries are no longer checked. Neither operation requires importing gpu.c3l.

`--stress` runs only CPU work: one seeded system with 100,000 stretched
billboards, emitted before timing, 60 warm-up updates and the requested number
of measured updates. It reports simulation/publication, uncached
`billboard_world_bounds` and `copy_billboard_records` separately, the latter
printed as `billboard_pack_ms`. Every update
advances the batch revision, so the bounds measurement rebuilds it. The copy
writes a preallocated CPU array; upload and GPU execution are excluded. The
printed checksum consumes bounds and copied output. `--stress` and
`--benchmark` are separate modes.

`--stress` prints two segments. `stress` is the full pool with no emission;
`saturated` is the same pool with a rate that requests a tenth of the capacity
every step. Each segment reports `refused` (the system's `dropped`) and `evicted`.
`--drop-oldest` selects `DROP_OLDEST` for both segments; the default is `REFUSE`.
Only the `saturated` segment differs between the two policies.

`--drop-oldest` also applies to `--benchmark`, with or without `--gpu`. It selects `DROP_OLDEST` for the sparks and
doubles their rate, so the pool is full and every step evicts, and the run ends with `sparks,refused` and
`sparks,evicted`, the totals over the prewarm and the measured frames. The totals of a GPU system lag by
`FRAMES_IN_FLIGHT` frames.

The headless benchmark uses one 1920x1080 display-output view without AA, 60
rendered warm-up frames and 300 measured frames per segment. Active simulation
is prewarmed for twenty simulated seconds. It reports actual live counts and
matches delayed GPU results to the measured frame range. `--capture-rgba path`
saves the last display-encoded RGBA8 image for inspection.

Baseline measured before the palette interpolation correction on September 30,
2026: Windows x64, NVIDIA GeForce RTX 4090, C3 0.8.3
`-O3`, Vulkan validation on, GPU+INTERNAL profiling, inline simulation. Means over
300 frames; GPU measurements also contain 300 matched samples.

| Metric | Empty systems | Active systems |
| --- | ---: | ---: |
| Particle update CPU | 0.000326 ms | 0.108573 ms |
| Whole frame CPU | 1.035607 ms | 1.436521 ms |
| Instance sort GPU | Not recorded | 0.055815 ms |
| Transparent pass GPU | Not recorded | 0.185436 ms |
| Live smoke, mean / capacity | 0 / 8192 | 8169.7 / 8192 |
| Live sparks, mean / capacity | 0 / 4096 | 4083.2 / 4096 |
| Live debris, mean / capacity | 0 / 1024 | 1020.9 / 1024 |

These are this scene's measurements, not a general performance guarantee. The
measured CPU update is below the 1 ms executor follow-up threshold. The stress
measurements further down time the range kernels.

The 100,000-particle CPU stress baseline at `0e9cd0d` on an Intel Core i9-14900K, Windows x64,
C3 0.8.3 `-O3`, produced the following medians of three runs. Each run measured
300 updates after 60 warm-up updates, with 100,000 live and published particles
throughout. Emission and allocation occur before timing.

| CPU operation | Median | Range of run means |
| --- | ---: | ---: |
| Simulation and draw publication | 0.776409 ms | 0.767330–0.780976 ms |
| Uncached billboard bounds | 0.267105 ms | 0.264326–0.272588 ms |
| Billboard record packing | 0.600191 ms | 0.592434–0.604158 ms |

Bounds and packing together cost about 0.867 ms in this stress case. Both
convert every record to world space after a revision change; unchanged bounds
are cached. This records the cost of that shared conversion without adding a
second representation or an executor. It excludes emission, upload, sorting
and rendering, and does not replace the default-scene measurement above.

The same stress case with the [range kernels](#parallel-update), at 100,000 live particles on a native Windows x64
host with an NVIDIA GeForce RTX 4090, C3 0.8.3 `-O3`. "Before" is the build without the range kernels and the counter
draws. The other columns run the kernels inline or on a `c3d_job` pool. "Update, bounds and copy" adds the uncached
billboard bounds and the record copy (the record packing, in the "Before" column) to the update.

| CPU operation | Before | Inline | 4 workers | 8 workers |
| --- | ---: | ---: | ---: | ---: |
| Update alone | 0.605 ms | 0.860 ms | 0.272 ms | 0.235 ms |
| Update, bounds and copy | 1.460 ms | 1.430 ms | 0.793 ms | 0.755 ms |

The Inline column was measured with the two-pass publication. The single-pass inline publication cuts the inline update by
about a fifth: 1.058 ms to 0.823 ms, alternating builds in one session on the native Windows x64 RTX 4090 host while
WSL jobs loaded it. The table's own figures are not remeasured.

Bounds are not forked. The serial passes (expiry and admission) and the cost of each fork bound the gain from more
workers; they are not measured separately. A pool of at most one block runs inline whatever the hook. In the default
`--benchmark` scene, with about 4.1k sparks, the update costs 0.088 ms before the kernels, 0.118 ms inline and 0.089 ms
with 8 workers. The example checksum is identical for every worker count.

Windows acceptance passed all 17 particle CPU tests and six Vulkan cases, with
validation. Native Linux compilation and the earlier 16 CPU tests passed in WSL
before the palette regression test was added.
WSL verification is limited to builds and CPU tests. GPU acceptance runs on
Windows.

![Smoke, stretched sparks and mesh debris](images/particles.png)

## Serialization

Select `c3d_serial` and enable `C3D_PARTICLE_SERIAL` to register particle authoring codecs. Reads create pending systems; prepare them before ordinary updates. The description is version 9. Version 2 added `saturation`, version 3 added `sub_emitters`, `sub_emitter_count` and `max_events`, version 4 added `collision`, version 5 added `flipbook`, version 6 added `turbulence`, version 7 added `trail`, version 8 added `mesh_cast_shadow` and `mesh_trace`, and version 9 adds `execution`; older payloads in both encodings read the defaults, which is no collision, no flipbook, no turbulence, no trail, debris that casts no shadow and does not trace, and CPU execution. The trail child is generated, so it is not written; preparation creates it again. The collision callback is not serialized. A sub-emitter target is an entity reference and must lie inside the exported subtree. See [the serialization contract](../addons/c3d_particle.c3l/src/serial/README.md) for ownership, restart behavior and the feature-on test targets.
