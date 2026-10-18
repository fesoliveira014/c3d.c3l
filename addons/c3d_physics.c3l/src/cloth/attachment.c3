module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import std::math;

<*
 Target attachment for one physical particle.
 A zero weight disables the entry without conflicting with other records on the same particle;
 a weight in (0, 1] scales positive compliance as compliance / weight, or selects a hard pin when compliance is zero.
*>
struct ClothAttachment {
    uint  particle;
    float weight;
    float compliance;
}

<* Prepared soft XPBD attachment record on a physical particle. *>
struct ClothSoftAttachment {
    uint  particle;
    float effective_compliance;
}

struct ClothAttachmentPlan @private {
    uint[]                pins;
    ClothSoftAttachment[] soft;
}

fn void? check_attachment_desc(ClothAttachment[] attachments) @private {
    foreach (attachment : attachments) {
        if (!unit_interval(attachment.weight)) return c3d::INVALID_ARGUMENT~;
        if (!(attachment.compliance >= 0) || !math::is_finite(attachment.compliance)) return c3d::INVALID_ARGUMENT~;
        if (attachment.weight > 0 && attachment.compliance > 0) {
            float effective = attachment.compliance / attachment.weight;
            if (!math::is_finite(effective) || !(effective > 0)) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn ClothAttachmentPlan? build_attachment_plan(
    uint[] legacy_pins,
    uint[] render_to_particle,
    ClothAttachment[] attachments,
    uint particle_count,
) @private {
    uint render_count = (uint)render_to_particle.len;
    bool[] has_hard = alloc::new_array(tmem, bool, (sz)particle_count);
    bool[] has_soft = alloc::new_array(tmem, bool, (sz)particle_count);
    float[] soft_effective = alloc::new_array(tmem, float, (sz)particle_count);

    foreach (pin : legacy_pins) {
        if (pin >= render_count) return c3d::INVALID_ARGUMENT~;
        has_hard[render_to_particle[pin]] = true;
    }

    foreach (attachment : attachments) {
        if (attachment.particle >= particle_count) return c3d::INVALID_ARGUMENT~;
        if (attachment.weight == 0) continue;

        uint particle = attachment.particle;
        if (attachment.compliance == 0) {
            if (has_soft[particle]) return c3d::INVALID_ARGUMENT~;
            has_hard[particle] = true;
            continue;
        }

        float effective = attachment.compliance / attachment.weight;
        if (has_hard[particle]) return c3d::INVALID_ARGUMENT~;
        if (has_soft[particle] && soft_effective[particle] != effective) return c3d::INVALID_ARGUMENT~;

        has_soft[particle] = true;
        soft_effective[particle] = effective;
    }

    usz hard_count;
    usz soft_count;
    for (uint particle = 0; particle < particle_count; particle++) {
        if (has_hard[particle]) hard_count++;
        if (has_soft[particle]) soft_count++;
    }

    ClothAttachmentPlan plan = {
        .pins = alloc::new_array(tmem, uint, (sz)hard_count),
        .soft = alloc::new_array(tmem, ClothSoftAttachment, (sz)soft_count),
    };

    usz next_hard;
    usz next_soft;
    for (uint particle = 0; particle < particle_count; particle++) {
        if (has_hard[particle]) plan.pins[next_hard++] = particle;
        if (has_soft[particle]) {
            plan.soft[next_soft++] = {
                .particle             = particle,
                .effective_compliance = soft_effective[particle],
            };
        }
    }

    return plan;
}

fn void? project_soft_attachments(
    ClothState* state,
    float dt,
    float progress,
    bool final_substep,
) @private {
    if (!state.soft_attachments.len) return;
    double step_squared = (double)dt * (double)dt;

    foreach (slot, attachment : state.soft_attachments) {
        uint particle = attachment.particle;
        double inverse_mass = (double)state.inverse_masses[particle];
        double alpha_h = (double)attachment.effective_compliance / step_squared;
        double denominator = inverse_mass + alpha_h;

        Vec3 target = final_substep
          ? state.soft_targets[slot]
          : state.soft_anchors[slot] + (state.soft_targets[slot] - state.soft_anchors[slot]) * progress;

        ContactVector residual = (ContactVector)state.predicted[particle] - (ContactVector)target;
        ContactVector lambda = (ContactVector)state.soft_lambdas[slot];
        ContactVector delta_lambda = -(residual + lambda * alpha_h) / denominator;
        ContactVector next_lambda = lambda + delta_lambda;
        ContactVector next_position = (ContactVector)state.predicted[particle] + delta_lambda * inverse_mass;

        Vec3 rounded_lambda = (Vec3)next_lambda;
        Vec3 rounded_position = (Vec3)next_position;
        if (!finite_vector(rounded_lambda) || !finite_vector(rounded_position)) {
            state.contact_result.stage = ClothContactStage.ATTACHMENT;
            return c3d::INVALID_ARGUMENT~;
        }

        state.soft_lambdas[slot] = rounded_lambda;
        state.predicted[particle] = rounded_position;
    }
}
