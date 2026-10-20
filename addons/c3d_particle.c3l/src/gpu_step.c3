module c3d::particle;

import c3d;
import std::math;

struct GpuPendingStep @private {
    bool recorded;
    ulong frame; // Renderer.frame_index while the step was recorded
    double emit_accumulator;
    double turbulence_time;
    ulong consumed_burst;
    double[3] shift_applied; // the shift total the step consumed
    ParticleReach reach;
}

struct GpuStepState @private {
    double[3] shift_requested; // sum of the offsets given to shift_particles; no vector, the block is 16-aligned
    double[3] shift_applied; // the part of it the committed steps have consumed
    ParticleReach reach;
    GpuPendingStep pending;
    bool started; // a step has committed, so the device control block is live
    ulong started_frame; // frame of the first committed step
}

struct GpuStepPlan @private {
    float seconds;
    uint requested; // particles asked for this step, saturated
    Vec3 shift; // subtracted from every live particle first
    Vec3 turbulence_offset; // world shift and scroll drift, reduced to one tile
    bool first; // no step has committed: the device control block is uninitialized
}

<*
 @require system.is_prepared() && system.desc.execution == ParticleExecution.GPU
*>
fn GpuStepState* gpu_step_state(ParticleSystem* system) @private => (GpuStepState*)system.block;

fn void shift_gpu_step(GpuStepState* state, Vec3 offset) @private {
    for (usz axis = 0; axis < 3; axis++) state.shift_requested[axis] += offset[axis];
    state.reach.shift(offset);
    state.pending.reach.shift(offset);
}

<*
 @require system.is_prepared() && system.desc.execution == ParticleExecution.GPU
 @require dt >= 0 && math::is_finite(dt)
*>
fn GpuStepPlan plan_gpu_step(
    ParticleSystem* system,
    Mat4 emitter_world,
    float dt,
    Vec3 wind,
    ulong frame,
    double[<3>] world_shift,
) @private {
    GpuStepState* state = gpu_step_state(system);
    float seconds = math::min(dt, MAX_PARTICLE_STEP_SECONDS);
    double accumulator = system.emit_accumulator;
    if (system.emitting) accumulator += (double)system.desc.rate * seconds;
    double whole = math::floor(accumulator);
    uint128 requested = (uint128)whole + system.pending_burst;

    state.pending = {
        .recorded = true,
        .frame = frame,
        .emit_accumulator = accumulator - whole,
        .turbulence_time = system.turbulence_time + seconds,
        .consumed_burst = system.pending_burst,
        .shift_applied = state.shift_requested,
        .reach = state.reach,
    };
    state.pending.reach.record(
        desc: &system.desc,
        emitter_world: emitter_world,
        wind: wind,
        seconds: seconds,
    );

    Vec3 shift;
    for (usz axis = 0; axis < 3; axis++) shift[axis] = (float)(state.shift_requested[axis] - state.shift_applied[axis]);
    double[<3>] drift = (double[<3>]){
        (double)system.desc.turbulence.scroll.x,
        (double)system.desc.turbulence.scroll.y,
        (double)system.desc.turbulence.scroll.z,
    } * state.pending.turbulence_time;

    return {
        .seconds = seconds,
        .requested = (uint)math::min(requested, (uint128)uint::max),
        .shift = shift,
        .turbulence_offset = tile_offset(system, world_shift - drift),
        .first = !state.started,
    };
}

<*
 @require system.is_prepared() && system.desc.execution == ParticleExecution.GPU
*>
fn void settle_gpu_step(ParticleSystem* system, bool submitted) @private {
    GpuStepState* state = gpu_step_state(system);
    GpuPendingStep* pending = &state.pending;
    if (!pending.recorded) return;

    pending.recorded = false;
    if (!submitted) return;

    if (!state.started) {
        state.started = true;
        state.started_frame = pending.frame;
    }
    system.emit_accumulator = pending.emit_accumulator;
    system.turbulence_time = pending.turbulence_time;
    system.pending_burst -= pending.consumed_burst;
    state.shift_applied = pending.shift_applied;
    state.reach = pending.reach;
}

fn Vec3 tile_offset(ParticleSystem* system, double[<3>] offset) @private {
    ParticleTurbulence* turbulence = &system.desc.turbulence;
    if (turbulence.strength <= 0) return {};

    double length = (double)turbulence.period / turbulence.frequency;
    return {
        (float)wrap_to_tile(offset.x, length),
        (float)wrap_to_tile(offset.y, length),
        (float)wrap_to_tile(offset.z, length),
    };
}
