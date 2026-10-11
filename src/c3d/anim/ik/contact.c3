module c3d::anim::ik;

import c3d;
import c3d::maths;
import std::math;

<* Inline retained contact with no borrowed support or allocated resources. *>
struct FootContact {
    FootContactPhase phase;
    ulong support_identity;
    Transform support_frame;
    FootPlantConfig config;
    float foot_height;
    float elapsed;
    double[<3>] local_point;
    Vec3 local_normal;
    Vec3 local_heading;
    Vec3 acquire_correction_position;
    Quat acquire_correction_rotation;
    double[<3>] release_local_sole;
    Quat release_local_rotation;
    Transform requested;
    Vec3 correction_position;
    Quat correction_rotation;
}

<*
 Capture an explicit contact while preserving the current requested correction.
 @param incoming : "Fresh animated ankle world pose."
 @param foot_height : "Sole-to-ankle distance in scene metres."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? FootContact.begin_contact(
    &self,
    GroundHit hit,
    FootSupport support,
    Transform incoming,
    FootPlantConfig config = FOOT_PLANT_DEFAULT,
    float foot_height = FOOT_HEIGHT_DEFAULT,
) {
    Transform frame = validate_foot_support(support)!;
    incoming = validate_foot_incoming(incoming)!;
    config = validate_foot_plant(config)!;
    if (!math::is_finite(foot_height) || foot_height < 0 || !finite_contact_vec(hit.point)
        || !unit_contact_vec(hit.normal)) {
        return c3d::INVALID_ARGUMENT~;
    }
    hit.normal = hit.normal.normalize();

    FootContact next = *self;
    bool same_support = next.phase != INACTIVE && support.identity == next.support_identity;
    if (same_support) next.support_frame = frame;
    evaluate_foot_contact(&next, incoming);

    double[<3>] local_point = contact_local_point(frame, hit.point);
    Vec3 local_normal = (frame.rotation.conjugate() * hit.normal).normalize();
    bool same_intent = same_support && next.phase != RELEASING && next.foot_height == foot_height
        && same_contact_config(next.config, config)
        && (local_point - next.local_point).length() * frame.scale.x <= CONTACT_POSITION_TOLERANCE
        && (local_normal - next.local_normal).length() <= CONTACT_POSITION_TOLERANCE;
    if (same_intent) {
        *self = next;
        return;
    }

    Vec3 forward = incoming.rotation * config.sole_forward;
    Vec3 heading = forward - hit.normal * forward.dot(hit.normal);
    if (heading.length() <= CONTACT_FRAME_TOLERANCE) return c3d::INVALID_ARGUMENT~;

    next.acquire_correction_position = next.requested.position - incoming.position;
    next.acquire_correction_rotation = (next.requested.rotation * incoming.rotation.conjugate()).normalize();
    next.support_identity = support.identity;
    next.support_frame = frame;
    next.config = config;
    next.foot_height = foot_height;
    next.local_point = local_point;
    next.local_normal = local_normal;
    next.local_heading = (frame.rotation.conjugate() * heading.normalize()).normalize();
    next.phase = ACQUIRING;
    next.elapsed = 0;
    evaluate_foot_contact(&next, incoming);
    *self = next;
}

<*
 Publish the retained target from fresh animation and current support.
 @param incoming : "Fresh animated ankle world pose."
 @param dt : "Finite nonnegative seconds."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? FootContact.update_contact(
    &self,
    FootSupport support,
    Transform incoming,
    float dt,
) {
    Transform frame = validate_foot_support(support)!;
    incoming = validate_foot_incoming(incoming)!;
    if (!math::is_finite(dt) || dt < 0) return c3d::INVALID_ARGUMENT~;
    validate_contact_identity(self, support)!;

    FootContact next = *self;
    next.support_frame = frame;
    switch (next.phase) {
        case ACQUIRING:
            next.elapsed = math::min(next.config.acquire_seconds, next.elapsed + dt);
            if (next.elapsed == next.config.acquire_seconds) next.phase = PLANTED;
        case RELEASING:
            next.elapsed = math::min(next.config.release_seconds, next.elapsed + dt);
            if (next.elapsed == next.config.release_seconds) next.phase = INACTIVE;
        case INACTIVE:
        case PLANTED:
    }
    evaluate_foot_contact(&next, incoming);
    *self = next;
}

<*
 Release through the retained sole pivot without advancing its clock.
 @param incoming : "Fresh animated ankle world pose."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? FootContact.end_contact(&self, FootSupport support, Transform incoming) {
    Transform frame = validate_foot_support(support)!;
    incoming = validate_foot_incoming(incoming)!;
    validate_contact_identity(self, support)!;

    FootContact next = *self;
    next.support_frame = frame;
    evaluate_foot_contact(&next, incoming);
    if (next.phase == INACTIVE || next.phase == RELEASING) {
        *self = next;
        return;
    }
    Vec3 sole = next.requested.position - next.requested.rotation * next.config.sole_up * next.foot_height;
    next.release_local_sole = contact_local_point(frame, sole);
    next.release_local_rotation = (frame.rotation.conjugate() * next.requested.rotation).normalize();
    next.phase = RELEASING;
    next.elapsed = 0;
    evaluate_foot_contact(&next, incoming);
    *self = next;
}

<* Clear retained runtime intent for an explicit teleport or removal. *>
fn void FootContact.reset_contact(&self) {
    *self = {};
}

<*
 Shift retained world positions once, preserving support-local values.
 @param offset : "Same horizontal metres passed to Scene.shift_origin."
 @require offset.y == 0, finite_contact_vec(offset)
*>
fn void FootContact.shift_origin(&self, Vec3 offset) {
    self.support_frame.position -= offset;
    self.requested.position -= offset;
}

fn void? validate_contact_identity(FootContact* contact, FootSupport support) @private {
    if (contact.phase != INACTIVE && contact.support_identity != support.identity) return c3d::INVALID_ARGUMENT~;
}

fn bool same_contact_config(FootPlantConfig first, FootPlantConfig second) @private {
    return first.acquire_seconds == second.acquire_seconds && first.release_seconds == second.release_seconds
        && first.sole_up == second.sole_up && first.sole_forward == second.sole_forward;
}

fn double[<3>] contact_local_point(Transform frame, Vec3 point) @private {
    Quaternion rotation = { .v = (double[<4>])frame.rotation.v };
    rotation = rotation.normalize();
    return rotation.conjugate() * ((double[<3>])point - (double[<3>])frame.position) / (double)frame.scale.x;
}

fn Vec3 contact_world_point(Transform frame, double[<3>] point) @private {
    Quaternion rotation = { .v = (double[<4>])frame.rotation.v };
    rotation = rotation.normalize();
    return (Vec3)((double[<3>])frame.position + rotation * (point * (double)frame.scale.x));
}

fn float contact_smoothstep(float elapsed, float duration) @private {
    float fraction = math::clamp(elapsed / duration, 0.0f, 1.0f);
    return fraction * fraction * (3 - 2 * fraction);
}

fn Transform locked_foot_pose(FootContact* contact) @private {
    Vec3 normal = (contact.support_frame.rotation * contact.local_normal).normalize();
    Vec3 heading = (contact.support_frame.rotation * contact.local_heading).normalize();
    Quat local_basis = maths::look_rotation(contact.config.sole_forward, contact.config.sole_up);
    Quat world_basis = maths::look_rotation(heading, normal);
    return {
        .position = contact_world_point(contact.support_frame, contact.local_point) + normal * contact.foot_height,
        .rotation = (world_basis * local_basis.conjugate()).normalize(),
        .scale = { 1, 1, 1 },
    };
}

fn void evaluate_foot_contact(FootContact* contact, Transform incoming) @private {
    Transform requested = incoming;
    switch (contact.phase) {
        case INACTIVE:
            break;
        case ACQUIRING:
            Transform locked = locked_foot_pose(contact);
            float weight = contact_smoothstep(contact.elapsed, contact.config.acquire_seconds);
            Vec3 corrected = incoming.position + contact.acquire_correction_position;
            Quat rotation = (contact.acquire_correction_rotation * incoming.rotation).normalize();
            requested.position = corrected + (locked.position - corrected) * weight;
            requested.rotation = rotation.slerp(locked.rotation, weight).normalize();
        case PLANTED:
            requested = locked_foot_pose(contact);
        case RELEASING:
            Quat carried_rotation = (contact.support_frame.rotation * contact.release_local_rotation).normalize();
            Vec3 carried = contact_world_point(contact.support_frame, contact.release_local_sole)
                + carried_rotation * contact.config.sole_up * contact.foot_height;
            float weight = contact_smoothstep(contact.elapsed, contact.config.release_seconds);
            requested.position = carried + (incoming.position - carried) * weight;
            requested.rotation = carried_rotation.slerp(incoming.rotation, weight).normalize();
    }
    contact.requested = requested;
    contact.correction_position = requested.position - incoming.position;
    contact.correction_rotation = (requested.rotation * incoming.rotation.conjugate()).normalize();
}
