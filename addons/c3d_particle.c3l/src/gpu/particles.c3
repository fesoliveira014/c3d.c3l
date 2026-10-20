module c3d::particle::gpu @feat(C3D_PARTICLE_GPU);

import c3d;
import c3d::asset;
import c3d::particle @public;
import c3d::render;
import c3d::scene;
import std::math;

<*
 GPU particle systems one context simulates by default.
*>
const uint DEFAULT_MAX_SYSTEMS = 16; // a buffer each, two for a traced mesh, and one for counters, of the renderer's 64

const String SHIFT_KEY @private = "c3d_particle/particle_shift";
const String EXPIRE_KEY @private = "c3d_particle/particle_expire";
const String SCAN_KEY @private = "c3d_particle/particle_scan";
const String ADMIT_KEY @private = "c3d_particle/particle_admit";
const String ADVANCE_KEY @private = "c3d_particle/particle_advance";
const String PUBLISH_KEY @private = "c3d_particle/particle_publish";
const String DELIVER_KEY @private = "c3d_particle/particle_deliver";

<*
 Compute stages of one chain.
*>
struct GpuStages {
    ComputeShaderId shift;
    ComputeShaderId expire;
    ComputeShaderId scan;
    ComputeShaderId admit;
    ComputeShaderId advance;
    ComputeShaderId publish;
    ComputeShaderId deliver;
}

<*
 Buffers a GPU system owns, and the emitter it belongs to.
*>
struct GpuSystemSlot {
    Entity emitter; // a zero generation marks a free slot
    BufferId buffer;
    BufferId mirror; // READBACK; only a mesh system with mesh_trace has one
    uint stamp; // the update that last saw the emitter
    uint chained; // the update that last recorded the emitter's step
}

<*
 View whose previous rendering GPU particles collide with, and the camera node it renders from.
 A zero view disables depth collision.
*>
struct DepthCollision {
    ViewId view;
    Entity camera; // the node the application passes to render_view for the view
}

<*
 Camera of one update, with the depth extent and the frame origin it pairs with.
*>
struct DepthCamera {
    bool valid;
    ulong frame; // Renderer.frame_index while the update derived it
    Mat4 view_proj;
    Mat4 inv_view_proj;
    Vec4 distance; // xyz: forward axis; w: offset; the distance of a point is dot(xyz, point) + w
    Vec4 position; // xyz: camera position relative to origin; w: 1 when orthographic
    Vec3 origin; // Renderer.frame_origin
    uint width;
    uint height;
}

<*
 Compute stages, per-system buffers and the shared counters buffer of the application's GPU particle systems.
*>
struct GpuParticles {
    Allocator allocator;
    GpuStages stages;
    GpuSystemSlot[] slots;
    BufferId counters; // READBACK; one entry per slot, created at the first update
    uint stamp;
    DepthCamera depth_pending; // of the last update; a camera commits once its frame was submitted
    DepthCamera depth_committed; // of the last submitted update; pairs with the depth that frame rendered
}

struct SystemRef @private {
    Entity entity;
    ParticleSystem* system;
    GpuSystemSlot* slot;
}

struct DepthUse @private {
    ViewId view;
    DepthCamera* camera; // null while the update has no camera that pairs with the view's depth
}

struct ChainRecorder @private {
    Renderer* renderer;
    StepRoot* root;
    BufferId[] writes;
    uint groups;
}

fn void? ChainRecorder.scan(&self, ComputeShaderId shader) {
    self.root.mode = ScanMode.BLOCKS;
    self.run(shader, self.groups)!;
    self.root.mode = ScanMode.TOTALS;
    self.run(shader, 1)!;
}

fn void? ChainRecorder.run(&self, ComputeShaderId shader, uint groups, DispatchTexture[] textures = {}) {
    self.renderer.dispatch({
        .shader = shader,
        .root = ((char*)self.root)[:StepRoot::size],
        .groups = { groups, 1, 1 },
        .writes = self.writes,
        .textures = textures,
    })!;
}

<*
 Create a context and add its compute stages to the store.
 @param [&inout] assets : "The store the renderer draws from."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require max_systems > 0
*>
fn GpuParticles? create_gpu_particles(
    Allocator allocator,
    AssetStore* assets,
    uint max_systems = DEFAULT_MAX_SYSTEMS,
) {
    if (max_systems >= render::BUFFER_CAPACITY) return c3d::CAPACITY_EXCEEDED~;

    GpuStages stages = {
        .shift = stage(assets, SHIFT_KEY, particle::PARTICLE_SHIFT_SPIRV[..])!,
        .expire = stage(assets, EXPIRE_KEY, particle::PARTICLE_EXPIRE_SPIRV[..])!,
        .scan = stage(assets, SCAN_KEY, particle::PARTICLE_SCAN_SPIRV[..])!,
        .admit = stage(assets, ADMIT_KEY, particle::PARTICLE_ADMIT_SPIRV[..])!,
        .advance = stage(assets, ADVANCE_KEY, particle::PARTICLE_ADVANCE_SPIRV[..])!,
        .publish = stage(assets, PUBLISH_KEY, particle::PARTICLE_PUBLISH_SPIRV[..])!,
        .deliver = stage(assets, DELIVER_KEY, particle::PARTICLE_DELIVER_SPIRV[..])!,
    };
    return {
        .allocator = allocator,
        .stages = stages,
        .slots = alloc::new_array(allocator, GpuSystemSlot, (sz)max_systems),
    };
}

<*
 Retire every buffer of the context after its last submitted use.
 @param [&inout] particles : "Left zeroed."
 @param [&inout] renderer : "The renderer every update recorded into."
*>
fn void destroy_gpu_particles(GpuParticles* particles, Renderer* renderer) {
    foreach (&slot : particles.slots) {
        if (slot.buffer.generation) (void)renderer.destroy_buffer(slot.buffer);
        if (slot.mirror.generation) (void)renderer.destroy_buffer(slot.mirror);
    }
    if (particles.counters.generation) (void)renderer.destroy_buffer(particles.counters);
    alloc::free(particles.allocator, particles.slots.ptr);
    *particles = {};
}

<*
 Record one step of every prepared GPU system and publish its draw.
 Call once per frame after update_world and before the views render.
 An aborted frame followed by FRAMES_IN_FLIGHT or more frames without an update loses that step's burst and shift.
 If that frame was the system's first, the system then steps from an uninitialized device state.
 A fault that aborts the frame ends the update there and returns the first fault.
 @param [&inout] particles : "Retires the buffers of systems that died."
 @param [&inout] renderer : "Frame open, no overlay open."
 @param [&inout] scene : "Registered; matrices current."
 @param dt : "Finite nonnegative seconds."
 @param wind : "Finite world-space air velocity in metres per second."
 @param depth : "Systems with a collision response also collide with this view's depth."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? Renderer.create_buffer!, Renderer.dispatch!, Renderer.read_buffer!
 @require renderer.frame_open
 @require dt >= 0 && math::is_finite(dt)
 @require math::is_finite(wind.x) && math::is_finite(wind.y) && math::is_finite(wind.z)
*>
fn void? update(
    GpuParticles* particles,
    Renderer* renderer,
    Scene* scene,
    float dt,
    Vec3 wind = {},
    DepthCollision depth = {},
) {
    DepthUse depth_use = prepare_depth(particles, renderer, scene, depth)!;

    particles.stamp++;
    if (!particles.counters.generation) {
        particles.counters = renderer.create_buffer({
            .size = particles.slots.len * COUNTER_BYTES,
            .usage = BufferUsage.READBACK,
            .debug_name = "particle_counters",
        })!;
    }
    char[] counters = read_snapshot(renderer, particles.counters)!;

    fault failure;
    scene.@each(ParticleSystem; entity, system) {
        if (renderer.frame_open && system.is_prepared() && system.desc.execution == ParticleExecution.GPU) {
            if (catch excuse = step_system(
                particles: particles,
                renderer: renderer,
                scene: scene,
                entity: entity,
                system: system,
                counters: counters,
                dt: dt,
                wind: wind,
                depth: depth_use,
            )) {
                if (!failure) failure = excuse;
            }
        }
    };
    if (catch excuse = deliver_events(particles, renderer, scene)) {
        if (!failure) failure = excuse;
    }
    if (renderer.frame_open) retire_unseen(particles, renderer)!;
    if (failure) return failure~;
}

fn ComputeShaderId? stage(AssetStore* assets, String key, char[] spirv) @private {
    if (try found = assets.find_compute_shader(key)) return found;

    ComputeShaderDesc desc = { .compute = spirv };
    return assets.add_compute_shader(&desc, key);
}

fn char[]? read_snapshot(Renderer* renderer, BufferId buffer) @private {
    char[]? bytes = renderer.read_buffer(buffer);
    if (catch excuse = bytes) {
        if (excuse == render::NOT_READY) return (char[]){};
        return excuse~;
    }
    return bytes;
}

fn DepthUse? prepare_depth(
    GpuParticles* particles,
    Renderer* renderer,
    Scene* scene,
    DepthCollision depth,
) @private {
    DepthCamera* pending = &particles.depth_pending;
    if (pending.valid && renderer.frame_was_submitted(pending.frame)) particles.depth_committed = *pending;

    *pending = {};
    if (!depth.view.generation) return {};

    uint[<2>] extent = renderer.view_extent(depth.view)!;
    if (!scene.world.is_alive(depth.camera)) return c3d::INVALID_ID~;

    Node* camera_node = scene.node(depth.camera);
    Camera* camera = scene.get(camera_node, Camera);
    if (!camera) return c3d::INVALID_ARGUMENT~;
    if (extent.x == 0 || extent.y == 0) return {};

    CameraMatrices matrices = camera::derive_matrices(
        camera: *camera,
        camera_world: maths::rebase(camera_node.world, renderer.frame_origin),
        viewport: { (float)extent.x, (float)extent.y },
    );
    *pending = {
        .valid = true,
        .frame = renderer.frame_index,
        .view_proj = matrices.view_proj,
        .inv_view_proj = matrices.inv_view_proj,
        .distance = { -matrices.view.m20, -matrices.view.m21, -matrices.view.m22, -matrices.view.m23 },
        .position = {
            matrices.position.x,
            matrices.position.y,
            matrices.position.z,
            matrices.projection == Projection.ORTHOGRAPHIC ? 1.0f : 0.0f,
        },
        .origin = renderer.frame_origin,
        .width = extent.x,
        .height = extent.y,
    };

    DepthCamera* committed = &particles.depth_committed;
    if (try rendered = renderer.view_depth_frame(depth.view)) {
        if (committed.valid && committed.frame == rendered) return { .view = depth.view, .camera = committed };
    }
    return {};
}

fn GpuSystemSlot*? claim_slot(GpuParticles* particles, Entity emitter) @private {
    GpuSystemSlot* free_slot;
    foreach (&slot : particles.slots) {
        if (slot.emitter.generation && c3d::same_id(slot.emitter, emitter)) return slot;
        if (!slot.emitter.generation && !free_slot) free_slot = slot;
    }
    if (!free_slot) return c3d::CAPACITY_EXCEEDED~;

    free_slot.emitter = emitter;
    return free_slot;
}

fn void? retire_unseen(GpuParticles* particles, Renderer* renderer) @private {
    foreach (&slot : particles.slots) {
        if (!slot.emitter.generation || slot.stamp == particles.stamp) continue;

        if (slot.buffer.generation) renderer.destroy_buffer(slot.buffer)!;
        if (slot.mirror.generation) renderer.destroy_buffer(slot.mirror)!;
        *slot = {};
    }
}

fn void adopt_counters(
    ParticleSystem* system,
    Renderer* renderer,
    char[] counters,
    usz slot_index,
) @private {
    GpuStepState* state = particle::gpu_step_state(system);
    bool counted = state.started && renderer.frame_index >= state.started_frame + render::FRAMES_IN_FLIGHT;
    if (!counted || counters.len < (slot_index + 1) * COUNTER_BYTES) return;

    uint* words = (uint*)counters.ptr + slot_index * (COUNTER_BYTES / uint::size);
    system.alive = words[0];
    system.dropped = (ulong)words[1] | ((ulong)words[2] << 32);
    system.dropped_events = (ulong)words[4] | ((ulong)words[5] << 32);
    system.skipped_events = (ulong)words[6] | ((ulong)words[7] << 32);
    system.evicted = (ulong)words[8] | ((ulong)words[9] << 32);
}

fn void? step_system(
    GpuParticles* particles,
    Renderer* renderer,
    Scene* scene,
    Entity entity,
    ParticleSystem* system,
    char[] counters,
    float dt,
    Vec3 wind,
    DepthUse depth,
) @private {
    GpuSystemSlot* slot = claim_slot(particles, entity)!;
    slot.stamp = particles.stamp;
    usz slot_index = slot - particles.slots.ptr;

    GpuStepState* state = particle::gpu_step_state(system);
    bool settled = renderer.frame_was_submitted(state.pending.frame)
        || renderer.frame_index - state.pending.frame > render::FRAMES_IN_FLIGHT;
    particle::settle_gpu_step(system, settled);
    adopt_counters(
        system: system,
        renderer: renderer,
        counters: counters,
        slot_index: slot_index,
    );

    SystemLayout layout = system_layout(&system.desc);
    if (!slot.buffer.generation) {
        slot.buffer = renderer.create_buffer({
            .size = layout.size,
            .usage = BufferUsage.GPU_PRIVATE,
            .debug_name = "particle_system",
        })!;
    }
    if (mirrors_instances(&system.desc)) {
        if (!slot.mirror.generation) {
            slot.mirror = renderer.create_buffer({
                .size = mirror_bytes(system.desc.capacity),
                .usage = BufferUsage.READBACK,
                .debug_name = "particle_mirror",
            })!;
        }
        adopt_mirror(
            scene: scene,
            renderer: renderer,
            system: system,
            mirror: slot.mirror,
        )!;
    }

    Node* emitter = scene.node(entity);
    GpuStepPlan plan = particle::plan_gpu_step(
        system: system,
        emitter_world: emitter.world,
        dt: dt,
        wind: wind,
        frame: renderer.frame_index,
        world_shift: scene.world_shift,
    );
    bool collides_with_depth = depth.camera
        && system.desc.collision.response != CollisionResponse.NONE
        && plan.shift == (Vec3){};
    StepRoot root = step_root(
        system: system,
        plan: &plan,
        layout: &layout,
        addresses: system_addresses(particles, renderer, slot),
        emitter_world: emitter.world,
        wind: wind,
        origin: renderer.frame_origin,
        depth: collides_with_depth ? *depth.camera : (DepthCamera){},
    );
    BufferId[3] writes = { slot.buffer, particles.counters, slot.mirror };
    DispatchTexture[1] depth_views = { render::read_view_depth(depth.view, asset::SAMPLER_NEAREST) };
    record_chain(
        renderer: renderer,
        stages: &particles.stages,
        root: &root,
        groups: layout.groups,
        shifted: !plan.first && plan.shift != (Vec3){},
        writes: writes[:slot.mirror.generation ? 3 : 2],
        advance_textures: collides_with_depth ? depth_views[..] : (DispatchTexture[]){},
    )!;
    slot.chained = particles.stamp;

    Aabb bound = state.pending.reach.bound(&system.desc, mesh_bound_radius(renderer.assets, &system.desc));
    Node* draw = scene.node(system.draw_node);
    if (system.desc.render_mode == ParticleRenderMode.MESH) {
        InstanceDevice instances = {
            .buffer = slot.buffer,
            .records_offset = layout.records,
            .count_offset = layout.count,
            .capacity = system.desc.capacity,
        };
        scene.set_instance_device(draw, instances, bound);
    } else {
        BillboardDevice billboards = {
            .buffer = slot.buffer,
            .records_offset = layout.records,
            .count_offset = layout.count,
            .capacity = system.desc.capacity,
        };
        scene.set_billboard_device(draw, billboards, bound);
    }
    if (!system.desc.trail.max_points) return;

    RibbonDevice ribbons = {
        .buffer = slot.buffer,
        .records_offset = layout.ribbons,
        .count_offset = layout.ribbon_count,
        .capacity = system.desc.capacity * (system.desc.trail.max_points + 1),
    };
    scene.set_ribbon_device(scene.node(system.trail_node), ribbons, state.pending.reach.trail_bound(&system.desc));
}

fn SystemAddresses system_addresses(GpuParticles* particles, Renderer* renderer, GpuSystemSlot* slot) @private {
    usz slot_index = slot - particles.slots.ptr;
    return {
        .base = (ulong)renderer.buffer_address(slot.buffer),
        .counters = (ulong)renderer.buffer_address(particles.counters) + slot_index * COUNTER_BYTES,
        .mirror = slot.mirror.generation ? (ulong)renderer.buffer_address(slot.mirror) : 0,
    };
}

fn float mesh_bound_radius(AssetStore* assets, ParticleSystemDesc* desc) @private {
    if (desc.render_mode != ParticleRenderMode.MESH || !assets.geometries.is_live(desc.geometry)) return 0;

    return particle::bound_radius(assets.geometry(desc.geometry).data.bounds);
}

fn void? adopt_mirror(
    Scene* scene,
    Renderer* renderer,
    ParticleSystem* system,
    BufferId mirror,
) @private {
    char[] snapshot = read_snapshot(renderer, mirror)!;
    if (snapshot.len < MIRROR_HEADER_BYTES) return;

    Node* node = scene.node(system.draw_node);
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    uint count = math::min(*(uint*)snapshot.ptr, system.desc.capacity);
    MirrorRecord[] records = ((MirrorRecord*)(snapshot.ptr + MIRROR_HEADER_BYTES))[:count];
    foreach (index, record : records) {
        float size = record.position_size.w;
        batch.transforms[index] = {
            .position = { record.position_size.x, record.position_size.y, record.position_size.z },
            .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, record.rotation),
            .scale = { size, size, size },
        };
        batch.colors[index] = record.color;
    }

    bool changed = count || batch.count;
    batch.count = count;
    if (changed) scene.mark_instances_dirty(node);
}

fn GpuSystemSlot* find_slot(GpuParticles* particles, Entity emitter) @private {
    foreach (&slot : particles.slots) {
        if (slot.emitter.generation && c3d::same_id(slot.emitter, emitter)) return slot;
    }
    return null;
}

fn void? deliver_events(GpuParticles* particles, Renderer* renderer, Scene* scene) @private {
    fault failure;
    scene.@each(ParticleSystem; entity, system) {
        GpuSystemSlot* slot;
        if (system.is_prepared() && system.desc.execution == ParticleExecution.GPU) slot = find_slot(particles, entity);
        if (renderer.frame_open && slot && slot.chained == particles.stamp) {
            foreach (sub_index, &sub_emitter : system.desc.sub_emitters[:system.desc.sub_emitter_count]) {
                if (!renderer.frame_open) break;
                if (catch excuse = deliver_sub_emitter(
                    particles: particles,
                    renderer: renderer,
                    scene: scene,
                    source: { .entity = entity, .system = system, .slot = slot },
                    sub_index: (uint)sub_index,
                )) {
                    if (!failure) failure = excuse;
                }
            }
        }
    };
    if (failure) return failure~;
}

fn void? deliver_sub_emitter(
    GpuParticles* particles,
    Renderer* renderer,
    Scene* scene,
    SystemRef source,
    uint sub_index,
) @private {
    SubEmitter* sub_emitter = &source.system.desc.sub_emitters[sub_index];
    SystemRef receiver = source;
    bool delivers;
    if (scene.world.is_alive(sub_emitter.target)) {
        Node* node = scene.node(sub_emitter.target);
        ParticleSystem* target = scene.get(node, ParticleSystem);
        GpuSystemSlot* target_slot;
        if (target && target.is_prepared() && target.desc.execution == ParticleExecution.GPU) {
            target_slot = find_slot(particles, sub_emitter.target);
        }
        if (target_slot && target_slot.chained == particles.stamp) {
            receiver = { .entity = sub_emitter.target, .system = target, .slot = target_slot };
            delivers = true;
        }
    }

    SystemLayout layout = system_layout(&receiver.system.desc);
    GpuStepPlan idle;
    StepRoot root = step_root(
        system: receiver.system,
        plan: &idle,
        layout: &layout,
        addresses: system_addresses(particles, renderer, receiver.slot),
        emitter_world: scene.node(receiver.entity).world,
        wind: {},
        origin: renderer.frame_origin,
        depth: {},
    );
    ulong source_base = (ulong)renderer.buffer_address(source.slot.buffer);
    root.source_control = source_base;
    root.source_events = source_base + system_layout(&source.system.desc).events;
    root.source_event_capacity = source.system.desc.max_events;
    root.delivery_sub = sub_index;
    root.delivery_count = sub_emitter.count;
    root.delivery_inherit = sub_emitter.inherit_velocity;
    root.delivery_valid = delivers ? 1 : 0;

    if (delivers) {
        ParticleReach* source_reach = &particle::gpu_step_state(source.system).pending.reach;
        particle::gpu_step_state(receiver.system).pending.reach.record_origins(
            origins: source_reach.bound(&source.system.desc),
            inherited_speed: sub_emitter.inherit_velocity * source_reach.speed_bound(&source.system.desc),
        );
    }
    BufferId[2] writes = { receiver.slot.buffer, source.slot.buffer };
    uint events = source.system.desc.max_events;
    renderer.dispatch({
        .shader = particles.stages.deliver,
        .root = ((char*)&root)[:StepRoot::size],
        .groups = { (events + GROUP_SIZE - 1) / GROUP_SIZE, 1, 1 },
        .writes = writes[..],
    })!;
}

fn void? record_chain(
    Renderer* renderer,
    GpuStages* stages,
    StepRoot* root,
    uint groups,
    bool shifted,
    BufferId[] writes,
    DispatchTexture[] advance_textures,
) @private {
    ChainRecorder chain = {
        .renderer = renderer,
        .root = root,
        .writes = writes,
        .groups = groups,
    };
    if (shifted) chain.run(stages.shift, groups)!;
    chain.run(stages.expire, groups)!;
    chain.scan(stages.scan)!;
    chain.run(stages.admit, groups)!;
    chain.run(stages.advance, groups, advance_textures)!;
    chain.scan(stages.scan)!;
    chain.run(stages.publish, groups)!;
}
