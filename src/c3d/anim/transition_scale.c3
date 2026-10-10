module c3d::anim;

import c3d;
import c3d::asset;
import std::math;

fn void transition_target_controls(
    AssetStore* assets,
    AnimationTransitionDesc desc,
    PreparedTransition* prepared,
    float[] weights,
    double[] speeds,
    float[] times,
) @local {
    foreach (index, target : desc.actions) {
        weights[index] = target.weight;
        speeds[index] = target.playing ? (double)target.speed : 0;
        times[index] = target.start_time;
    }

    foreach (space : prepared.spaces[:prepared.space_count]) {
        double[MAX_ACTIONS] normalized;
        switch (space.kind) {
            case ONE_DIMENSIONAL:
                float parameter = math::clamp(space.parameter, space.positions[0], space.positions[space.count - 1]);
                uint lower;
                while (lower + 2 < space.count && parameter >= space.positions[lower + 1]) lower++;
                double fraction = (double)(parameter - space.positions[lower])
                  / (double)(space.positions[lower + 1] - space.positions[lower]);
                normalized[lower] = 1 - fraction;
                normalized[lower + 1] = fraction;
            case TWO_DIMENSIONAL:
                BlendLayoutView layout = {
                    .points = space.points[:space.count],
                    .triangles = space.triangles[:space.layout.triangle_count],
                    .hull = space.hull[:space.layout.hull_count],
                    .reversed = space.layout.reversed,
                    .extent = space.layout.extent,
                };
                BlendLayoutSelection selected = select_blend_layout(layout, space.parameter_2d);
                foreach (index, member : selected.indices[:selected.count]) {
                    normalized[member] = selected.weights[index];
                }
        }

        double duration;
        foreach (index, ordinal : space.members[:space.count]) {
            duration += normalized[index] * (double)assets.clip(desc.actions[ordinal].clip).data.duration;
        }

        foreach (index, ordinal : space.members[:space.count]) {
            float clip_duration = assets.clip(desc.actions[ordinal].clip).data.duration;
            weights[ordinal] = (float)normalized[index] * space.weight;
            speeds[ordinal] = space.playing ? (double)space.speed * clip_duration / duration : 0;
            times[ordinal] = (float)(space.phase * clip_duration);
        }
    }
}

fn bool consumed_transition_node(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationTransitionDesc desc,
    uint node,
) @local {
    bool generalized;
    foreach (target : desc.actions) generalized |= target.play.extraction.generalized;
    foreach (id : playback.order[:*playback.action_count]) generalized |= playback.actions.get(id).motion_chain != null;
    if (!generalized) return false;

    ModelTemplate* template = &assets.model(playback.model).data;
    for (int current = (int)playback.root_node; current >= 0; current = template.nodes[current].parent) {
        if ((uint)current == node) return true;
    }

    return false;
}

fn void? validate_transition_scale_eligibility(
    PlaybackView* playback,
    AssetStore* assets,
    AnimationTransitionDesc desc,
    PreparedTransition* prepared,
    PoseDestination destination,
    bool source_history_current = true,
) @private {
    float[MAX_ACTIONS] weights;
    double[MAX_ACTIONS] speeds;
    float[MAX_ACTIONS] times;
    transition_target_controls(
        assets: assets,
        desc: desc,
        prepared: prepared,
        weights: weights[:desc.actions.len],
        speeds: speeds[:desc.actions.len],
        times: times[:desc.actions.len],
    );
    bool unsupported;

    foreach (uint node, base : destination.base_pose) {
        if (!consumed_transition_node(playback, assets, desc, node)) continue;
        AdmittedScaleExtrema[MAX_ACTIONS] domains;
        uint domain_count;
        InertialScalarState target = { .value = inertial_uniform_scale_mean(inertial_pose_vector(base.scale)) };

        target = transition_node_scale(
            assets: assets,
            desc: desc,
            node: node,
            base: base.scale,
            weights: weights[:desc.actions.len],
            speeds: speeds[:desc.actions.len],
            times: times[:desc.actions.len],
            domains: domains[..],
            domain_count: &domain_count,
        );

        InertialRow* row = playback.inertial;
        InertialScalarState source = {
            .value = inertial_uniform_scale_mean(inertial_pose_vector(destination.pose[node].scale)),
            .rate = source_history_current && row.control.history_valid
              ? inertial_uniform_scale_mean(row.velocity[node].scale) : 0,
        };
        if (!math::is_finite(source.value) || source.value <= 0
          || !math::is_finite(target.value) || target.value <= 0) {
            return c3d::INVALID_ARGUMENT~;
        }
        float[3] eligible_base = { base.scale.x, base.scale.y, base.scale.z };
        InertialScalarState residual = inertial_onset_scale_residual(source, target);
        ScaleEligibilityInput input = {
            .regular = domains[:domain_count],
            .base = eligible_base,
            .offset = residual.value,
            .velocity = residual.rate,
            .duration = desc.duration,
        };
        if (catch excuse = validate_scale_eligibility(&input)) {
            if (excuse != c3d::UNSUPPORTED) return excuse~;
            unsupported = true;
        }
    }

    if (unsupported) return c3d::UNSUPPORTED~;
}

fn InertialScalarState transition_node_scale(
    AssetStore* assets,
    AnimationTransitionDesc desc,
    uint node,
    Vec3 base,
    float[] weights,
    double[] speeds,
    float[] times,
    AdmittedScaleExtrema[] domains,
    uint* domain_count,
) @local {
    Vec3 target_scale = base;
    double[<3>] target_rate;
    for (uint layer = 0; layer < MAX_ANIMATION_LAYERS; layer++) {
        double[<3>] sum;
        double[<3>] sum_rate;
        float total;
        foreach (index, description : desc.actions) {
            if (description.play.additive || description.play.layer != layer) continue;
            AnimationClip* clip = &assets.clip(description.clip).data;
            foreach (&track : clip.tracks) {
                if (track.path != TargetPath.SCALE || clip.targets[track.target] != node) continue;
                if (domains.len) domains[(*domain_count)++] = collect_admitted_scale_extrema(track);
                float weight = weights[index];
                if (description.play.mask && !description.play.mask.nodes[node]) weight = 0;
                if (description.play.weighted_mask) weight *= description.play.weighted_mask.nodes[node];
                double[3] value;
                double[3] rate;
                uint cursor;
                sample_track_analytic(
                    track: track,
                    time: times[index],
                    cursor: &cursor,
                    value: value[..],
                    rate: rate[..],
                    side: speeds[index] < 0 ? StepSampleSide.LEFT
                      : speeds[index] > 0 ? StepSampleSide.RIGHT : StepSampleSide.EXACT,
                );
                Vec3 sampled = { (float)value[0], (float)value[1], (float)value[2] };
                sum += inertial_pose_vector(sampled) * (double)weight;
                sum_rate += (double[<3>]){ rate[0], rate[1], rate[2] } * (speeds[index] * (double)weight);
                total += weight;
            }
        }

        double below = (double)residual(total);
        double divisor = (double)math::max(1.0f, total);
        target_scale = inertial_publish_vector((sum + inertial_pose_vector(target_scale) * below) / divisor);
        target_rate = (sum_rate + target_rate * below) / divisor;
    }

    return {
        .value = inertial_uniform_scale_mean(inertial_pose_vector(target_scale)),
        .rate = inertial_uniform_scale_mean(target_rate),
    };
}
