# GPU particles

`ParticleSystemDesc.execution` selects the processor that steps a [particle system](particles.md): `CPU` (default) or `GPU`. A GPU system keeps its pool in a renderer buffer and steps, collides and publishes it with compute stages, so the CPU never reads or copies a particle, except through the `mesh_trace` host mirror. Use it for large pools whose per-frame CPU cost or upload would dominate. `execution` is immutable after `prepare`.

The GPU path exists in builds that enable `C3D_PARTICLE_GPU`, which adds the module `c3d::particle::gpu`. Without the feature, preparing a GPU system faults `c3d::UNSUPPORTED`. The module imports `c3d::render`, records through `Renderer.dispatch`, creates buffers only through `Renderer.create_buffer` and never imports `gpu`. The `particles_gpu` example builds with the feature, and `particles_gpu --gpu` selects GPU execution for every system the subset below supports.

## Quick start

```c3
GpuParticles gpu = gpu::create_gpu_particles(mem, &assets)!;
defer gpu::destroy_gpu_particles(&gpu, &renderer);

// every frame
scene.update_world();
particle::update(&scene, delta_seconds, wind_velocity);   // steps the CPU systems
renderer.begin_frame()!;
gpu::update(
    particles: &gpu,
    renderer:  &renderer,
    scene:     &scene,
    dt:        delta_seconds,
    wind:      wind_velocity,
)!;
// render_view and finish_view for each camera, then end_frame
```

`create_gpu_particles(allocator, assets, max_systems = DEFAULT_MAX_SYSTEMS)` adds the seven compute stages to the store once per store and takes the number of systems the context simulates (`DEFAULT_MAX_SYSTEMS` is 16). Each GPU system owns one renderer buffer, created at its first update, and the context owns one more for the counters. The renderer holds 64 application buffers in all; a system past the context's limit faults `CAPACITY_EXCEEDED`. `update` retires the buffer of a system whose node died, and `destroy_gpu_particles` retires the rest, so destroy the context before the renderer.

## Frame order

Call `gpu::update` once per frame, after `update_world` and `particle::update` and inside the open frame, before the views render. Each system records one step: the queued origin shift, expiry, a prefix scan, admission with spawning, advance and collision, a second scan and publication. After every system has stepped, each sub-emitter records one delivery. Every dispatch covers the system's capacity (or `max_events` for a delivery); there is no indirect dispatch. The pool stays in spawn order.

A system's buffer holds, per particle of `capacity`, two 64-byte state copies, a 16-byte scan entry and one draw record (64 bytes for a billboard, 128 for a mesh instance). A [trail](#trails) adds `80 + 88 · max_points` bytes per particle and [sub-emitters](#sub-emitters) 96 bytes per event of `max_events`. The draw child is a core `DEVICE` [billboard batch](billboards.md#device-batches) over the same buffer, or for `MESH` a `DEVICE` [instanced batch](instancing.md#device-batches), so every view culls and sorts the records the compute stages wrote.

- **Aborted frames.** A step's CPU bookkeeping (emission accumulator, consumed burst, queued shift, bound) commits only when `Renderer.frame_was_submitted` confirms the frame, so an aborted frame is stepped again by the next `update` with the same burst. The renderer stops reporting a frame after `FRAMES_IN_FLIGHT` frames, so an `update` that follows an aborted frame after a longer gap loses that step's burst and shift. If that frame was the system's first, the system then steps from an uninitialized device state until its particles expire.

## Supported subset

- Supported: every emitter shape, rate and bursts; gravity, drag, wind and turbulence; lifetime tables, colour and flipbooks; `BILLBOARD`, `STRETCHED` and `MESH` draw modes; trails; sub-emitters between GPU systems; `REFUSE` and `DROP_OLDEST` saturation; and `CollisionResponse` `BOUNCE`, `STICK` or `DIE` against `ground_plane` and a view's [depth](#depth-collision).
- `ParticleSystem.set_collision` requires a CPU system, because the callback is application code.

## Counters and latency

The simulation state lives on the device. `alive`, `dropped`, `evicted`, `dropped_events` and `skipped_events` are read back from a `READBACK` buffer and reach the CPU `FRAMES_IN_FLIGHT` frames late. They read 0 before the first copy, and a frame without a copy keeps the previous values. A delivery's `dropped` and `skipped_events` arrive one update later than the rest. Nothing waits for the device.

## Trails

A trail's ring lives with its particle in the same ping-pong buffers as the state, and compaction moves it with the particle. Advance records points after collision with the CPU's rules: at most one point per step, the oldest dropped once older than `trail.lifetime`. The trail child is a core `DEVICE` [ribbon batch](ribbons.md#device-batches) over the same buffer. Publication writes `max_points + 1` records for every live particle, in spawn order, so a particle with no stored point draws nothing. The origin shift moves the stored points with the particles. Widths, colours and texture coordinates follow the [CPU rules](particles.md#trails).

## Mesh debris

A `MESH` system publishes one instance record per drawn particle in spawn order: the matrix the CPU path publishes (position, a turn of `rotation` about +Y and a uniform scale of the drawn size) and the particle's colour. The batch node keeps the identity pose of a world child. One difference from the CPU path: the instance seed, which sway and fade read, hashes the particle's seed, so it does not change as the particle moves.

- `mesh_cast_shadow` copies to the batch, and the shadow layers cull the device records with the same count as the view, so shadows appear in the frame that spawns the debris.
- A device batch has no per-instance history, so motion vectors follow the batch node alone: debris shows no object motion in a temporal view. Picking and `SceneIndex` skip the batch.
- `mesh_trace` is served by a host mirror, because the scene trace reads CPU transforms. A traced system owns a second `READBACK` buffer (16 bytes plus 48 bytes per particle of `capacity`) and takes two of the renderer's 64 application buffers. Each `update` copies the snapshot that is `FRAMES_IN_FLIGHT` frames old into the batch, so the scene trace sees debris as it was that many frames earlier and sees none until the first snapshot arrives. A system without `mesh_trace` has no mirror and is not traced.

## Sub-emitters

A step appends an event for each birth, death and impact that a sub-emitter of the system accepts, with the particle's position, velocity and seed. Events go to one of two halves of `max_events` entries, so the deliveries that follow a step read its half while the next step fills the other. An event past `max_events` is dropped and counted in `dropped_events` when the step publishes.

After every system has stepped, `update` records one delivery per sub-emitter. An invocation per event slot claims up to `count` free slots in the target and spawns children at the event position through the target's own descriptor and orientation, with the parent's velocity times `inherit_velocity` added. Children that do not fit are counted in the target's `dropped`, whatever its saturation policy: [DROP_OLDEST](#drop_oldest) evicts only for the target's own emitter. The target may be the same system. Differences from the CPU path:

- A delivery between a GPU system and a CPU system is skipped and counted in the source's `skipped_events`, as is one to a dead or unprepared target or one past the context's `max_systems`. Keep a sub-emitter's target on the processor of its source.
- Children draw from the next `update`: a delivery writes the target's pool after the target's step, so the next step ages, moves and publishes them. A delivered child raises its own `BIRTH` event at that step.
- A child's hash stream comes from the parent's seed, a key (the parent's spawn ordinal, the steps the system has taken and the trigger) and the sub-emitter index, where the CPU uses the event index, so the two paths do not spawn identical children. Replay on one device is deterministic; the order of children in the pool, and so which a full target drops, is not.
- The target's [bound](#bounds) includes the box of every source that delivers to it and grows by the velocity the children inherit, so a source with large or fast particles widens its targets' bounds.

## DROP_OLDEST

The pool stays in spawn order, so the oldest particles come first. When a step's requests exceed the free slots, admission leaves out the first `min(survivors, requests − free)` survivors, where survivors are the particles that outlived the step's expiry (delivered children included). It then admits the newborns as `REFUSE` does and counts what still does not fit in `dropped`. Newborns are never evicted; a request larger than the capacity evicts every survivor, emits `capacity` particles and refuses the rest. `evicted` counts the evictions.

An evicted particle raises a `DEATH` event that only sub-emitters with `on_evict` accept, with the position, velocity and seed it had before the step moved it, counted against `max_events`. A trail leaves with its particle. A delivery to a target that saturates does not evict: the children that find no free slot are counted in the target's `dropped`, which differs from the CPU.

## Depth collision

`gpu::update` takes a `DepthCollision { view, camera }` as its last argument. A GPU system with a collision response other than `NONE` then also collides with the depth that `view` last rendered, in the same step as its `ground_plane` and under the same response; when both offer a hit, the nearer along the move answers. A zero `view` disables it. `camera` is the node the application passes to `render_view` for that view. One view serves every GPU system of the update, so name the main camera's view; other views never affect the simulation. A response with no `ground_plane` still needs `max_queries` above zero, because the descriptor check requires it.

```c3
gpu::update(
    particles: &gpu,
    renderer:  &renderer,
    scene:     &scene,
    dt:        delta_seconds,
    depth:     { .view = main_view, .camera = camera_node.id },
)!;
renderer.render_view(&scene, camera_node, main_view)!;
```

A dead `view` or `camera` faults `c3d::INVALID_ID`, and a `camera` node without a `Camera` faults `c3d::INVALID_ARGUMENT`, both before any dispatch is recorded.

- **Which depth.** `update` records before `render_view`, so the step reads the view's previous rendering, one frame old (see [dispatch textures](compute.md#textures)). The package derives the camera's matrices from the camera node and the view's working extent and commits them once `Renderer.frame_was_submitted` confirms the frame. The step collides only when `Renderer.view_depth_frame(view)` equals the frame of the committed matrices, and skips depth collision on the first frame and after a `configure_view` that recreated the view's images, when the view was not rendered in the previous frame or the frame aborted, for a path-traced view (which writes no depth), and in a step that applies a queued origin shift. The camera node must not move between `update` and `render_view`. TAA jitter is ignored.
- **The test.** A particle collides with the move from its previous position to its position. A point behind the camera, outside the image or over a background texel has no surface. A hit needs the end behind the sampled surface along the view's forward axis, the start in front of it or on it, and the end no deeper than the move's length plus the collision radius; a deeper point counts as occluded and is left alone.
- **The normal.** The stage rebuilds the surface position of the hit texel and its four neighbours and, on each screen axis, uses the neighbour whose distance differs least, so a silhouette edge does not tilt the normal. A texel with no usable neighbour answers with the direction toward the camera.
- **The response.** As on the ground plane. Blended particles write no depth, so a system never hits itself.
- **Cost.** Each colliding system names the depth in its advance dispatch and records one barrier to the sampled compute state, so an update with N colliding systems records N barriers.
- **Limits.** Geometry off-screen, hidden behind other surfaces or drawn by another view is missed, so a surface the named camera cannot see does not stop a particle. Contact lags one frame. The view must render every frame that should collide, because a stale depth is not used. Mesh particles write depth, so a mesh particle can meet another's previous rendering when its move away from the camera is longer than its half-depth. A particle that starts a step behind a surface is not pulled out of it, so one rising through the underside of a surface the camera sees from above passes through.

## Bounds

The CPU never reads the device records, so it bounds them from the descriptor. A `ParticleReach` keeps the union of the emitter's placed shape for each of `REACH_SLOTS` (8) slices of the last `lifetime.max` seconds, and `update` sets the draw child's bounds override to that union grown by the reach of speed, gravity fall, bounce, drag winds, turbulence, drawn size and the ground plane. The trail child takes the same box grown by half the widest strip. The box is conservative and grows with lifetime and turbulence strength. It only decides whether core culls the whole batch; each billboard is still culled on the GPU, while a trail draws every segment of a visible batch. Moving the emitter widens it over the next lifetime.

## Rebasing

`Scene.shift_particles(offset)` queues the shift for a GPU system; the next `update` subtracts it from every live particle before the step. Turbulence stays fixed to world points.

## Determinism and tolerance

Both paths draw every spawned value from `spawn_hash`, so a CPU and a GPU system with one descriptor spawn the same particles. They differ only by floating-point order: the stages use float where the CPU uses double for the spawn samples and the flipbook, and the device's own sine, cosine and fused operations. Replay is deterministic on one device and driver; there is no bit equality across devices, drivers or compilers.

## See also

- [Particles](particles.md) and the [reference](particles_reference.md).
- [Billboards](billboards.md#device-batches), [ribbons](ribbons.md#device-batches), [instancing](instancing.md#device-batches), [custom shaders](compute.md#textures).
