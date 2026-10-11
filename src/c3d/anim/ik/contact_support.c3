module c3d::anim::ik;

import c3d;
import c3d::maths;
import std::math;

<* Default contact timing and ankle-local sole axes. *>
const FootPlantConfig FOOT_PLANT_DEFAULT = {
    .acquire_seconds = 0.12f,
    .release_seconds = 0.20f,
    .sole_up = { 0, 1, 0 },
    .sole_forward = { 0, 0, -1 },
};

const float CONTACT_FRAME_TOLERANCE @private = 1e-5f; // bounds frame orthonormality and uniformity, allowing float decomposition roundoff
const float CONTACT_POSITION_TOLERANCE @private = 1e-6f; // bounds identical capture points in metres, allowing transform roundoff
const float CONTACT_RESIDUAL_TOLERANCE @private = 0.001f; // bounds reached ankle distance in metres, allowing finite-precision IK error
const float CONTACT_ANGLE_TOLERANCE @private = 1.0f; // bounds reached sole-axis angles in degrees, allowing finite-precision alignment error

<* Frame owner of a retained contact. *>
enum FootSupportKind {
    WORLD_STATIC,
    SUPPORT,
}

<* Caller-selected stance transition. *>
enum FootContactPhase {
    INACTIVE,
    ACQUIRING,
    PLANTED,
    RELEASING,
}

<* Final pose agreement with the requested contact. *>
enum FootContactStatus {
    NO_TARGET,
    REACHED,
    MISSED,
}

<* Timing and ankle-local orthonormal sole directions. *>
struct FootPlantConfig {
    float acquire_seconds;
    float release_seconds;
    Vec3 sole_up;
    Vec3 sole_forward;
}

<* Opaque identity and current positive-uniform support frame. *>
struct FootSupport {
    ulong identity;
    FootSupportKind kind;
    Transform transform;
}

<* Residual and sole-axis errors measured after final world updates. *>
struct FootContactResult {
    FootContactPhase phase;
    FootContactStatus status;
    float residual;
    float normal_error_degrees;
    float heading_error_degrees;
}

<*
 Validate captured contact timing and sole axes without modifying authoring.
 @return? c3d::INVALID_ARGUMENT
*>
fn void? FootPlantConfig.validate(&self) {
    (void)validate_foot_plant(*self)!;
}

<* Identity frame for caller-selected static ground. *>
fn FootSupport world_static_support(ulong identity = 0) {
    return { .identity = identity, .kind = WORLD_STATIC, .transform = maths::TRANSFORM_IDENTITY };
}

fn bool finite_contact_vec(Vec3 value) @private {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn bool unit_contact_vec(Vec3 value) @private {
    return finite_contact_vec(value) && math::abs(value.length() - 1) <= CONTACT_FRAME_TOLERANCE;
}

fn bool unit_contact_quat(Quat rotation) @private {
    foreach (value : rotation.v) {
        if (!math::is_finite(value)) return false;
    }
    return math::abs(rotation.v.length() - 1) <= CONTACT_FRAME_TOLERANCE;
}

fn bool uniform_contact_scale(Vec3 scale) @private {
    float largest = math::max(scale.x, math::max(scale.y, scale.z));
    return math::abs(scale.x - scale.y) / largest <= CONTACT_FRAME_TOLERANCE
        && math::abs(scale.x - scale.z) / largest <= CONTACT_FRAME_TOLERANCE
        && math::abs(scale.y - scale.z) / largest <= CONTACT_FRAME_TOLERANCE;
}

fn Transform? validate_foot_support(FootSupport support) @private {
    Transform frame = support.transform;
    bool valid = finite_contact_vec(frame.position) && finite_contact_vec(frame.scale)
        && frame.scale.x > 0 && frame.scale.y > 0 && frame.scale.z > 0
        && uniform_contact_scale(frame.scale) && unit_contact_quat(frame.rotation);
    if (!valid) return c3d::INVALID_ARGUMENT~;

    frame.rotation = frame.rotation.normalize();
    frame.scale = { frame.scale.x, frame.scale.x, frame.scale.x };
    switch (support.kind) {
        case WORLD_STATIC:
            if (frame.position != (Vec3){ 0, 0, 0 } || frame.scale != (Vec3){ 1, 1, 1 }
                || math::abs(frame.rotation.v.w) != 1) {
                return c3d::INVALID_ARGUMENT~;
            }
        case SUPPORT:
    }
    return frame;
}

fn FootPlantConfig? validate_foot_plant(FootPlantConfig config) @private {
    bool valid = math::is_finite(config.acquire_seconds) && math::is_finite(config.release_seconds)
        && config.acquire_seconds > 0 && config.release_seconds > 0
        && unit_contact_vec(config.sole_up) && unit_contact_vec(config.sole_forward)
        && math::abs(config.sole_up.dot(config.sole_forward)) <= CONTACT_FRAME_TOLERANCE;
    if (!valid) return c3d::INVALID_ARGUMENT~;

    config.sole_up = config.sole_up.normalize();
    config.sole_forward = (config.sole_forward - config.sole_up * config.sole_up.dot(config.sole_forward)).normalize();
    return config;
}

fn Transform? validate_foot_incoming(Transform incoming) @private {
    if (!finite_contact_vec(incoming.position) || !unit_contact_quat(incoming.rotation)) {
        return c3d::INVALID_ARGUMENT~;
    }
    incoming.rotation = incoming.rotation.normalize();
    return incoming;
}
