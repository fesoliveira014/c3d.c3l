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
const uint DEFAULT_MAX_SYSTEMS = 16; // a buffer each at its first update and one for counters, of the renderer's 64

const String SHIFT_KEY @private = "c3d_particle/particle_shift";
const String EXPIRE_KEY @private = "c3d_particle/particle_expire";
const String SCAN_KEY @private = "c3d_particle/particle_scan";
const String ADMIT_KEY @private = "c3d_particle/particle_admit";
const String ADVANCE_KEY @private = "c3d_particle/particle_advance";
const String PUBLISH_KEY @private = "c3d_particle/particle_publish";

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
}

<*
 Buffer a GPU system owns, and the emitter it belongs to.
*>
struct GpuSystemSlot {
    Entity emitter; // a zero generation marks a free slot
    BufferId buffer;
    uint stamp; // the update that last saw the emitter
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

fn void? ChainRecorder.run(&self, ComputeShaderId shader, uint groups) {
    self.renderer.dispatch({
        .shader = shader,
        .root = ((char*)self.root)[:StepRoot::size],
        .groups = { groups, 1, 1 },
        .writes = self.writes,
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
 @param [&inout] particles : "Retires the buffers of systems that died."
 @param [&inout] renderer : "Frame open, no overlay open."
 @param [&inout] scene : "Registered; matrices current."
 @param dt : "Finite nonnegative seconds."
 @param wind : "Finite world-space air velocity in metres per second."
 @return? c3d::CAPACITY_EXCEEDED, Renderer.create_buffer!, Renderer.dispatch!, Renderer.read_buffer!
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
) {
    particles.stamp++;
    if (!particles.counters.generation) {
        particles.counters = renderer.create_buffer({
            .size = particles.slots.len * COUNTER_BYTES,
            .usage = BufferUsage.READBACK,
            .debug_name = "particle_counters",
        })!;
    }
    char[] counters = read_counters(renderer, particles.counters)!;

    fault failure;
    scene.@each(ParticleSystem; entity, system) {
        if (system.is_prepared() && system.desc.execution == ParticleExecution.GPU) {
            if (catch excuse = step_system(
                particles: particles,
                renderer: renderer,
                scene: scene,
                entity: entity,
                system: system,
                counters: counters,
                dt: dt,
                wind: wind,
            )) {
                if (!failure) failure = excuse;
            }
        }
    };
    retire_unseen(particles, renderer)!;
    if (failure) return failure~;
}

fn ComputeShaderId? stage(AssetStore* assets, String key, char[] spirv) @private {
    if (try found = assets.find_compute_shader(key)) return found;

    ComputeShaderDesc desc = { .compute = spirv };
    return assets.add_compute_shader(&desc, key);
}

fn char[]? read_counters(Renderer* renderer, BufferId counters) @private {
    char[]? bytes = renderer.read_buffer(counters);
    if (catch excuse = bytes) {
        if (excuse == render::NOT_READY) return (char[]){};
        return excuse~;
    }
    return bytes;
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

    SystemLayout layout = system_layout(system.desc.capacity, system.desc.trail.max_points);
    if (!slot.buffer.generation) {
        slot.buffer = renderer.create_buffer({
            .size = layout.size,
            .usage = BufferUsage.GPU_PRIVATE,
            .debug_name = "particle_system",
        })!;
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
    SystemAddresses addresses = {
        .base = (ulong)renderer.buffer_address(slot.buffer),
        .counters = (ulong)renderer.buffer_address(particles.counters) + slot_index * COUNTER_BYTES,
    };
    StepRoot root = step_root(
        system: system,
        plan: &plan,
        layout: &layout,
        addresses: addresses,
        emitter_world: emitter.world,
        wind: wind,
        origin: renderer.frame_origin,
    );
    BufferId[2] writes = { slot.buffer, particles.counters };
    record_chain(
        renderer: renderer,
        stages: &particles.stages,
        root: &root,
        groups: layout.groups,
        shifted: !plan.first && plan.shift != (Vec3){},
        writes: writes[..],
    )!;

    BillboardDevice device = {
        .buffer = slot.buffer,
        .records_offset = layout.records,
        .count_offset = layout.count,
        .capacity = system.desc.capacity,
    };
    scene.set_billboard_device(scene.node(system.draw_node), device, state.pending.reach.bound(&system.desc));
    if (!system.desc.trail.max_points) return;

    RibbonDevice ribbons = {
        .buffer = slot.buffer,
        .records_offset = layout.ribbons,
        .count_offset = layout.ribbon_count,
        .capacity = system.desc.capacity * (system.desc.trail.max_points + 1),
    };
    scene.set_ribbon_device(scene.node(system.trail_node), ribbons, state.pending.reach.trail_bound(&system.desc));
}

fn void? record_chain(
    Renderer* renderer,
    GpuStages* stages,
    StepRoot* root,
    uint groups,
    bool shifted,
    BufferId[] writes,
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
    chain.run(stages.advance, groups)!;
    chain.scan(stages.scan)!;
    chain.run(stages.publish, groups)!;
}
