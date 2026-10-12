module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

const float INERTIAL_ONSET_LEAD @local = 1.0f / 256; // Short against key spacing; long against float time rounding.

struct InertialScratch @private {
    Transform[] lead_pose;
    PoseVelocity[] velocity;
    float[] lead_morph;
    float[] morph;
    double[] morph_rate;
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

    evaluate_onset_target(
        playback: playback,
        assets: assets,
        destination: destination,
        scratch: scratch,
        lead: INERTIAL_ONSET_LEAD,
    );
    inertial.lead_pose[..] = destination.pose[..];
    read_inertial_morphs(destination.morph_weights, inertial.lead_morph);

    evaluate_onset_target(
        playback: playback,
        assets: assets,
        destination: destination,
        scratch: scratch,
        lead: 0,
    );
    read_inertial_morphs(destination.morph_weights, inertial.morph);

    foreach (index, target : destination.pose) {
        inertial.velocity[index] = inertial_pose_rate(target, inertial.lead_pose[index], INERTIAL_ONSET_LEAD);
    }
    foreach (index, target : inertial.morph) {
        inertial.morph_rate[index] = ((double)inertial.lead_morph[index] - (double)target) / INERTIAL_ONSET_LEAD;
    }

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

fn void evaluate_onset_target(
    PlaybackView* playback,
    AssetStore* assets,
    PoseDestination destination,
    PoseScratch scratch,
    float lead,
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
