module c3d::anim;

import c3d;
import c3d::asset;
import c3d::maths;
import std::math;

<* Copied transition state; it exposes no owned history or writable playback storage. *>
struct AnimationInertialStatus {
    bool enabled;
    bool active;
    double elapsed;
    double duration;
}

struct PoseVelocity @private {
    double[<3>] translation;
    double[<3>] angular;
    double[<3>] scale;
}

struct InertialControl @private {
    uint model_revision;
    bool history_valid;
    bool active;
    bool onset_pending;
    double duration;
    double elapsed;
}

struct RootInertialState @private {
    double[<3>] published_translation;
    double[<3>] translation_rate;
    double twist_rate;
    double[<3>] latest_up;
    double[<3>] source_up;
    double[<3>] source_translation_rate;
    double source_twist_rate;
    double[<3>] residual_translation_rate;
    double residual_twist_rate;
    bool target_rate_pending;
}

struct InertialRow @private {
    Transform[] previous_pose;
    PoseVelocity[] velocity;
    PoseVelocity[] offset;
    PoseVelocity[] offset_velocity;
    float[] previous_morph;
    double[] morph_velocity;
    double[] morph_offset;
    double[] morph_offset_velocity;
    bool[] consumed_scale;
    InertialControl control;
    RootInertialState root;
}

struct InertialStorage @private {
    Allocator allocator;
    InertialRow[] rows;
}

struct InertialScratch @private {
    Transform[] lead_pose;
    PoseVelocity[] velocity;
    float[] lead_morph;
    float[] morph;
    double[] morph_rate;
}

// Regions follow in this order, so each one starts aligned without padding.
$assert InertialStorage::size % InertialRow::alignment == 0;
$assert InertialRow::size % PoseVelocity::alignment == 0;
$assert PoseVelocity::size % double::alignment == 0;
$assert double::size % Transform::alignment == 0;
$assert Transform::size % float::alignment == 0;
$assert InertialRow::alignment >= InertialStorage::alignment && InertialRow::alignment >= PoseVelocity::alignment;

<* Read this Animator's prepared inertia and current transition state. *>
fn AnimationInertialStatus Animator.inertial_status(&self) {
    if (!self.inertial_storage) return {};

    InertialControl* control = &self.inertial_storage.rows[0].control;
    return {
        .enabled = true,
        .active = control.active,
        .elapsed = control.elapsed,
        .duration = control.duration,
    };
}

<* @require capacity > 0 *>
fn InertialStorage*? create_inertial_storage(
    Allocator allocator,
    uint nodes,
    uint morphs,
    uint capacity,
) @private {
    usz bytes = inertial_storage_bytes(nodes, morphs, capacity);
    char* block = (char*)(allocator.acquire((sz)bytes, AllocInitType.ZERO, InertialRow::alignment)
      ?? c3d::CAPACITY_EXCEEDED~!);

    InertialStorage* storage = (InertialStorage*)block;
    storage.allocator = allocator;
    storage.rows = ((InertialRow*)(storage + 1))[:capacity];

    usz node_count = (usz)capacity * nodes;
    usz morph_count = (usz)capacity * morphs;
    PoseVelocity* velocities = (PoseVelocity*)(storage.rows.ptr + capacity);
    double* morph_rates = (double*)(velocities + 3 * node_count);
    Transform* poses = (Transform*)(morph_rates + 3 * morph_count);
    float* morph_values = (float*)(poses + node_count);
    bool* consumed = (bool*)(morph_values + morph_count);

    foreach (usz index, &row : storage.rows) {
        usz node = index * nodes;
        usz morph = index * morphs;
        row.velocity = velocities[node:nodes];
        row.offset = velocities[node_count + node:nodes];
        row.offset_velocity = velocities[2 * node_count + node:nodes];
        row.morph_velocity = morph_rates[morph:morphs];
        row.morph_offset = morph_rates[morph_count + morph:morphs];
        row.morph_offset_velocity = morph_rates[2 * morph_count + morph:morphs];
        row.previous_pose = poses[node:nodes];
        row.previous_morph = morph_values[morph:morphs];
        row.consumed_scale = consumed[node:nodes];

        reset_inertial_row(storage, (uint)index);
    }

    return storage;
}

fn usz inertial_storage_bytes(usz nodes, usz morphs, usz capacity) @private {
    usz node_bytes = 3 * PoseVelocity::size + Transform::size + bool::size;
    usz morph_bytes = 3 * double::size + float::size;

    return InertialStorage::size + capacity * (InertialRow::size + nodes * node_bytes + morphs * morph_bytes);
}

fn void destroy_inertial_storage(InertialStorage* storage) @private {
    Allocator allocator = storage.allocator;
    allocator.release(storage, true);
}

<* @require index < storage.rows.len *>
fn void reset_inertial_row(InertialStorage* storage, uint index) @private {
    InertialRow* row = &storage.rows[index];
    row.previous_pose[..] = maths::TRANSFORM_IDENTITY;
    row.velocity[..] = (PoseVelocity){};
    row.offset[..] = (PoseVelocity){};
    row.offset_velocity[..] = (PoseVelocity){};
    row.previous_morph[..] = 0;
    row.morph_velocity[..] = 0;
    row.morph_offset[..] = 0;
    row.morph_offset_velocity[..] = 0;
    row.consumed_scale[..] = false;

    row.control = {};
    row.root = {
        .latest_up = { 0, 1, 0 },
        .source_up = { 0, 1, 0 },
    };
}

fn InertialScratch*? create_inertial_scratch(Allocator allocator, usz nodes, usz morphs) @private {
    InertialScratch* scratch = alloc::new_try(allocator, InertialScratch) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch destroy_inertial_scratch(allocator, scratch);

    scratch.lead_pose = alloc::new_array_try(allocator, Transform, (sz)nodes) ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.velocity = alloc::new_array_try(allocator, PoseVelocity, (sz)nodes) ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.lead_morph = alloc::new_array_try(allocator, float, (sz)morphs) ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.morph = alloc::new_array_try(allocator, float, (sz)morphs) ?? c3d::CAPACITY_EXCEEDED~!;
    scratch.morph_rate = alloc::new_array_try(allocator, double, (sz)morphs) ?? c3d::CAPACITY_EXCEEDED~!;

    return scratch;
}

fn void destroy_inertial_scratch(Allocator allocator, InertialScratch* scratch) @private {
    alloc::free(allocator, scratch.lead_pose.ptr);
    alloc::free(allocator, scratch.velocity.ptr);
    alloc::free(allocator, scratch.lead_morph.ptr);
    alloc::free(allocator, scratch.morph.ptr);
    alloc::free(allocator, scratch.morph_rate.ptr);
    alloc::free(allocator, scratch);
}

fn void read_inertial_morphs(float[][] rows, float[] values) @private {
    usz offset;
    foreach (row : rows) {
        values[offset:row.len] = row[..];
        offset += row.len;
    }
}

fn void write_inertial_morphs(float[] values, float[][] rows) @private {
    usz offset;
    foreach (row : rows) {
        row[..] = values[offset:row.len];
        offset += row.len;
    }
}

fn void capture_consumed_scale_nodes(PlaybackView* playback, bool[] consumed) @private {
    consumed[..] = false;
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (!action.motion_chain) continue;
        foreach (node : action.motion_chain.nodes) consumed[node.model_node] = true;
    }
}

<* @require playback.inertial != null && scratch.inertial != null *>
fn AnimationTransitionResult begin_prepared_inertial_transition(
    PlaybackView* playback,
    AssetStore* assets,
    PreparedTransition* prepared,
    PoseDestination destination,
    PoseScratch scratch,
) @private {
    InertialRow* row = playback.inertial;
    InertialScratch* inertial = scratch.inertial;
    row.previous_pose[..] = destination.pose[..];
    read_inertial_morphs(destination.morph_weights, row.previous_morph);

    AnimationTransitionResult installed = install_animation_transition(playback, assets, prepared);
    capture_consumed_scale_nodes(playback, row.consumed_scale);

    evaluate_onset_target_rates(
        playback: playback,
        assets: assets,
        destination: destination,
        scratch: scratch,
    );

    capture_inertial_pose_residuals(
        row: row,
        source_pose: row.previous_pose,
        source_morph: row.previous_morph,
        target_pose: destination.pose,
        target_velocity: inertial.velocity,
        target_morph: inertial.morph,
        target_morph_rate: inertial.morph_rate,
        consumed_scale: row.consumed_scale,
    );

    row.control.onset_pending = true;
    row.control.duration = prepared.duration;
    row.control.elapsed = 0;
    row.control.active = prepared.duration > 0;
    row.root.source_translation_rate = row.control.history_valid ? row.root.translation_rate : (double[<3>]){};
    row.root.source_twist_rate = row.control.history_valid ? row.root.twist_rate : 0;
    row.root.source_up = row.root.latest_up;
    row.root.target_rate_pending = row.control.active;

    correct_inertial_pose(
        playback: playback,
        destination: destination,
        scratch: scratch,
        dt: 0,
    );

    return installed;
}

fn void correct_inertial_pose(
    PlaybackView* playback,
    PoseDestination destination,
    PoseScratch scratch,
    double dt,
) @private {
    InertialRow* row = playback.inertial;
    float[] morph = scratch.inertial.morph;
    read_inertial_morphs(destination.morph_weights, morph);

    advance_inertial_elapsed(row, dt);

    apply_inertial_pose(
        row: row,
        target_pose: destination.pose,
        target_morph: morph,
        consumed_scale: row.consumed_scale,
        duration: row.control.duration,
        elapsed: row.control.elapsed,
    );
    row.control.active = row.control.elapsed < row.control.duration;

    write_inertial_morphs(morph, destination.morph_weights);
}

fn void record_playback_inertial_history(
    PlaybackView* playback,
    PoseDestination destination,
    PoseScratch scratch,
    double dt,
) @private {
    if (!playback.inertial) return;

    read_inertial_morphs(destination.morph_weights, scratch.inertial.morph);
    record_inertial_pose_history(
        row: playback.inertial,
        published_pose: destination.pose,
        published_morph: scratch.inertial.morph,
        dt: dt,
    );
}

fn void advance_inertial_elapsed(InertialRow* row, double dt) @private {
    if (!row.control.active) return;

    row.control.elapsed = math::min(row.control.duration, row.control.elapsed + dt);
    row.control.active = row.control.elapsed < row.control.duration;
}

fn void invalidate_inertial_history(PlaybackView* playback) @private {
    if (playback.inertial) playback.inertial.control.history_valid = false;
}

// Leaves the onset target in the destination and its rates, from one-step differences, in the scratch.
fn void evaluate_onset_target_rates(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    PoseScratch scratch,
) @local {
    InertialScratch* inertial = scratch.inertial;
    evaluate_onset_target(
        playback: playback,
        assets: assets,
        destination: destination,
        scratch: scratch,
        lead: LeadStep.FORWARD,
    );
    inertial.lead_pose[..] = destination.pose[..];
    read_inertial_morphs(destination.morph_weights, inertial.lead_morph);

    evaluate_onset_target(
        playback: playback,
        assets: assets,
        destination: destination,
        scratch: scratch,
        lead: LeadStep.NONE,
    );
    read_inertial_morphs(destination.morph_weights, inertial.morph);

    inertial.velocity[..] = (PoseVelocity){};
    inertial.morph_rate[..] = 0;
    add_onset_rates(
        inertial: inertial,
        from: destination.pose,
        from_morph: inertial.morph,
        to: inertial.lead_pose,
        to_morph: inertial.lead_morph,
    );

    // Looping clocks that would cross their clip end take their rate from a step backward instead.
    if (onset_lead_crosses_clip_end(playback, assets)) {
        inertial.lead_pose[..] = destination.pose[..];
        evaluate_onset_target(
            playback: playback,
            assets: assets,
            destination: destination,
            scratch: scratch,
            lead: LeadStep.BACKWARD,
        );
        read_inertial_morphs(destination.morph_weights, inertial.lead_morph);
        add_onset_rates(
            inertial: inertial,
            from: destination.pose,
            from_morph: inertial.lead_morph,
            to: inertial.lead_pose,
            to_morph: inertial.morph,
        );

        destination.pose[..] = inertial.lead_pose[..];
        write_inertial_morphs(inertial.morph, destination.morph_weights);
    }
}

fn bool onset_lead_crosses_clip_end(PlaybackView* playback, AssetStore* assets) @local {
    foreach (id : playback.order[:*playback.action_count]) {
        Action* action = playback.actions.get(id);
        if (lead_crosses_clip_end(action, &assets.clip(action.clip).data)) return true;
    }

    return false;
}

fn void add_onset_rates(
    InertialScratch* inertial,
    Transform[] from,
    float[] from_morph,
    Transform[] to,
    float[] to_morph,
) @local {
    foreach (index, &rate : inertial.velocity) {
        PoseVelocity step = inertial_pose_rate(from[index], to[index], LEAD_SECONDS);
        rate.translation += step.translation;
        rate.angular += step.angular;
        rate.scale += step.scale;
    }

    foreach (index, &rate : inertial.morph_rate) {
        *rate += ((double)to_morph[index] - (double)from_morph[index]) / LEAD_SECONDS;
    }
}

fn void evaluate_onset_target(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    PoseScratch scratch,
    LeadStep lead,
) @local {
    CapturedMotionChain* chain = generalized_playback_chain(playback);
    blend_pose(
        playback: playback,
        assets: assets,
        destination: destination,
        scratch: scratch,
        onset: true,
        consumed_chain: chain,
        lead: lead,
    );

    if (!chain) return;

    (void)evaluate_generalized_playback_motion(
        playback: playback,
        assets: assets,
        destination: destination,
        chain: chain,
        dt: 0,
        onset: true,
        lead: lead,
    );
}

fn RootMotionDelta publish_root_motion(
    PlaybackView* playback,
    PoseReport* report,
    Vec3 reference,
    double dt,
) @private {
    if (!report.generalized) {
        RootMotionDelta delta = root_motion_delta(report.motion, reference);
        if (!playback.inertial) return delta;

        return publish_inertial_root_motion(
            row: playback.inertial,
            target: delta,
            translation: inertial_pose_vector(delta.translation),
            twist: (double)report.motion.yaw,
            up: inertial_publication_up(playback.inertial),
            dt: dt,
        );
    }

    GeneralizedMotion motion = report.generalized_motion;
    double[<3>] up = generalized_chain_up(report.consumed_chain);
    RootMotionDelta delta = {
        .translation = inertial_publish_vector(motion.translation),
        .rotation = inertial_publish_rotation(inertial_rotation_exp(up * motion.twist)),
    };
    if (!playback.inertial) return delta;

    return publish_inertial_root_motion(
        row: playback.inertial,
        target: delta,
        translation: motion.translation,
        twist: motion.twist,
        up: up,
        dt: dt,
    );
}

// The double translation and twist of the target keep the residual sum to one rounding.
fn RootMotionDelta publish_inertial_root_motion(
    InertialRow* row,
    RootMotionDelta target,
    double[<3>] translation,
    double twist,
    double[<3>] up,
    double dt,
) @private {
    if (dt == 0) return target;

    if (row.control.active) {
        if (row.root.target_rate_pending) {
            row.root.residual_translation_rate = row.root.source_translation_rate - translation / dt;
            row.root.residual_twist_rate = row.root.source_twist_rate - twist / dt;
            row.root.target_rate_pending = false;
        }

        InertialQuinticBasis basis = inertial_quintic_basis(row.control.elapsed / row.control.duration);
        translation += row.root.residual_translation_rate * (basis.value * dt);
        twist += row.root.residual_twist_rate * (basis.value * dt);

        target = {
            .translation = inertial_publish_vector(translation),
            .rotation = inertial_publish_rotation(inertial_rotation_exp(up * twist)),
        };
    } else {
        row.root.target_rate_pending = false;
    }

    row.root.published_translation = inertial_pose_vector(target.translation);
    row.root.latest_up = up;
    row.root.translation_rate = row.root.published_translation / dt;
    row.root.twist_rate = twist / dt;

    return target;
}

fn double[<3>] inertial_publication_up(InertialRow* row) @private {
    if (row.control.active) return row.root.source_up;

    return { 0, 1, 0 };
}
