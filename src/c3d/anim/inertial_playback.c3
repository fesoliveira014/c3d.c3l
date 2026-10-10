module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

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

<* @require playback.inertial != null && scratch.derivative != null *>
fn InstalledTransition begin_prepared_inertial_transition(
    PlaybackView* playback,
    AssetStore* assets,
    PreparedTransition* prepared,
    PoseDestination destination,
    PoseScratch scratch,
) @private {
    InertialRow* row = playback.inertial;
    row.previous_pose[..] = destination.pose[..];
    read_inertial_morphs(destination.morph_weights, row.previous_morph);

    InstalledTransition installed = install_animation_transition(playback, assets, prepared);
    capture_consumed_scale_nodes(playback, scratch.derivative.consumed_scale);
    blend_pose(
        playback: playback,
        assets: assets,
        destination: destination,
        scratch: scratch,
        onset: true,
    );

    if (playback.generalized && generalized_playback_chain(playback)) {
        GeneralizedMotionFrame target_onset = generalized_playback_pose_endpoint(playback, destination.pose);
        PoseDestination source = destination;
        source.pose = row.previous_pose;
        (void)initialize_transition_anchor(
            state: playback.generalized,
            playback: playback,
            target_onset: target_onset,
            destination_source: source,
        );
        compensate_generalized_playback_target(
            state: playback.generalized,
            playback: playback,
            destination: destination,
            velocity: scratch.derivative.velocity,
        );
    }

    read_inertial_morphs(destination.morph_weights, scratch.derivative.morph_values);

    capture_inertial_pose_residuals(
        row: row,
        source_pose: row.previous_pose,
        source_morph: row.previous_morph,
        target_pose: destination.pose,
        target_velocity: scratch.derivative.velocity,
        target_morph: scratch.derivative.morph_values,
        target_morph_rate: scratch.derivative.morph_rates,
        consumed_scale: scratch.derivative.consumed_scale,
    );

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
    PoseDerivativeScratch* derivative = scratch.derivative;
    capture_consumed_scale_nodes(playback, derivative.consumed_scale);
    read_inertial_morphs(destination.morph_weights, derivative.morph_values);

    advance_inertial_elapsed(row, dt);

    apply_inertial_pose(
        row: row,
        target_pose: destination.pose,
        target_velocity: derivative.velocity,
        target_morph: derivative.morph_values,
        target_morph_rate: derivative.morph_rates,
        consumed_scale: derivative.consumed_scale,
        duration: row.control.duration,
        elapsed: row.control.elapsed,
    );
    row.control.active = row.control.elapsed < row.control.duration;

    write_inertial_morphs(derivative.morph_values, destination.morph_weights);
}

fn void record_playback_inertial_history(
    PlaybackView* playback,
    PoseDestination destination,
    PoseScratch scratch,
    double dt,
) @private {
    if (!playback.inertial) return;

    read_inertial_morphs(destination.morph_weights, scratch.derivative.morph_values);
    record_inertial_pose_history(
        row: playback.inertial,
        published_pose: destination.pose,
        published_morph: scratch.derivative.morph_values,
        dt: dt,
    );
}

fn void advance_inertial_elapsed(InertialRow* row, double dt) @private {
    if (!row.control.active) return;

    row.control.elapsed = math::min(row.control.duration, row.control.elapsed + dt);
    row.control.active = row.control.elapsed < row.control.duration;
}
