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

const float CONTACT_FRAME_TOLERANCE @private = 1e-5f;
const float CONTACT_POSITION_TOLERANCE @private = 1e-6f;
const float CONTACT_RESIDUAL_TOLERANCE @private = 0.001f;
const float CONTACT_ANGLE_TOLERANCE @private = 1.0f;

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

<* Invalid external contact input. *>
enum FootContactReason {
    NONE,
    SUPPORT_CHANGED,
    NONFINITE_SUPPORT,
    NONAFFINE_SUPPORT,
    NONPOSITIVE_SUPPORT_SCALE,
    NONUNIFORM_SUPPORT_SCALE,
    REFLECTED_SUPPORT,
    SHEARED_SUPPORT,
    INVALID_SUPPORT_ROTATION,
    INVALID_STATIC_FRAME,
    INVALID_HIT,
    INVALID_NORMAL,
    DEGENERATE_HEADING,
    INVALID_SOLE_AXES,
    INVALID_DURATION,
    INVALID_FOOT_HEIGHT,
    INVALID_DELTA_TIME,
    INVALID_INCOMING_POSE,
    INVALID_FLOOR_HEIGHT,
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

<* Caller-owned context for an invalid contact operation. *>
struct FootDiagnostic {
    FootContactReason reason;
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
 @param [out] diagnostic : "Optional invalid-input context."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? FootPlantConfig.validate(&self, FootDiagnostic* diagnostic = null) {
    clear_foot_diagnostic(diagnostic);
    (void)validate_foot_plant(*self, diagnostic)!;
}

<*
 Validate an affine support before extracting its proper rotation.
 @param [out] diagnostic : "Optional invalid-input context."
 @return? c3d::INVALID_ARGUMENT
*>
fn FootSupport? foot_support_from_mat4(
    ulong identity,
    FootSupportKind kind,
    Mat4 frame,
    FootDiagnostic* diagnostic = null,
) {
    clear_foot_diagnostic(diagnostic);
    float[16] values = {
        frame.m00, frame.m01, frame.m02, frame.m03,
        frame.m10, frame.m11, frame.m12, frame.m13,
        frame.m20, frame.m21, frame.m22, frame.m23,
        frame.m30, frame.m31, frame.m32, frame.m33,
    };
    foreach (value : values) {
        if (!math::is_finite(value)) return invalid_foot_input(diagnostic, NONFINITE_SUPPORT)~;
    }
    if (frame.m30 != 0 || frame.m31 != 0 || frame.m32 != 0 || frame.m33 != 1) {
        return invalid_foot_input(diagnostic, NONAFFINE_SUPPORT)~;
    }

    Vec3 x = { frame.m00, frame.m10, frame.m20 };
    Vec3 y = { frame.m01, frame.m11, frame.m21 };
    Vec3 z = { frame.m02, frame.m12, frame.m22 };
    Vec3 lengths = { contact_axis_length(x), contact_axis_length(y), contact_axis_length(z) };
    if (!finite_contact_vec(lengths)) return invalid_foot_input(diagnostic, NONFINITE_SUPPORT)~;
    if (lengths.x <= 0 || lengths.y <= 0 || lengths.z <= 0) {
        return invalid_foot_input(diagnostic, NONPOSITIVE_SUPPORT_SCALE)~;
    }
    x /= lengths.x;
    y /= lengths.y;
    z /= lengths.z;
    if (x.dot(y.cross(z)) <= 0) return invalid_foot_input(diagnostic, REFLECTED_SUPPORT)~;
    if (math::abs(x.dot(y)) > CONTACT_FRAME_TOLERANCE
        || math::abs(x.dot(z)) > CONTACT_FRAME_TOLERANCE
        || math::abs(y.dot(z)) > CONTACT_FRAME_TOLERANCE) {
        return invalid_foot_input(diagnostic, SHEARED_SUPPORT)~;
    }
    if (!uniform_contact_scale(lengths)) return invalid_foot_input(diagnostic, NONUNIFORM_SUPPORT_SCALE)~;

    Mat4 rotation_frame = {
        .m00 = x.x, .m01 = y.x, .m02 = z.x,
        .m10 = x.y, .m11 = y.y, .m12 = z.y,
        .m20 = x.z, .m21 = y.z, .m22 = z.z,
        .m33 = 1,
    };
    FootSupport support = {
        .identity = identity,
        .kind = kind,
        .transform = {
            .position = { frame.m03, frame.m13, frame.m23 },
            .rotation = maths::transform_from_mat4(rotation_frame).rotation,
            .scale = lengths,
        },
    };
    support.transform = validate_foot_support(support, diagnostic)!;
    return support;
}

<* Identity frame for caller-selected static ground. *>
fn FootSupport world_static_support(ulong identity = 0) {
    return { .identity = identity, .kind = WORLD_STATIC, .transform = maths::TRANSFORM_IDENTITY };
}

fn void clear_foot_diagnostic(FootDiagnostic* diagnostic) @private {
    if (diagnostic) *diagnostic = {};
}

fn fault invalid_foot_input(FootDiagnostic* diagnostic, FootContactReason reason) @private {
    if (diagnostic) diagnostic.reason = reason;
    return c3d::INVALID_ARGUMENT;
}

fn bool finite_contact_vec(Vec3 value) @private {
    return math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
}

fn float contact_axis_length(Vec3 axis) @private {
    float largest = math::max(math::abs(axis.x), math::max(math::abs(axis.y), math::abs(axis.z)));
    if (largest == 0) return 0;
    return (axis / largest).length() * largest;
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

fn Transform? validate_foot_support(FootSupport support, FootDiagnostic* diagnostic) @private {
    Transform frame = support.transform;
    if (!finite_contact_vec(frame.position) || !finite_contact_vec(frame.scale)) {
        return invalid_foot_input(diagnostic, NONFINITE_SUPPORT)~;
    }
    if (frame.scale.x <= 0 || frame.scale.y <= 0 || frame.scale.z <= 0) {
        return invalid_foot_input(diagnostic, NONPOSITIVE_SUPPORT_SCALE)~;
    }
    if (!uniform_contact_scale(frame.scale)) return invalid_foot_input(diagnostic, NONUNIFORM_SUPPORT_SCALE)~;
    if (!unit_contact_quat(frame.rotation)) return invalid_foot_input(diagnostic, INVALID_SUPPORT_ROTATION)~;
    frame.rotation = frame.rotation.normalize();
    frame.scale = { frame.scale.x, frame.scale.x, frame.scale.x };
    switch (support.kind) {
        case WORLD_STATIC:
            if (frame.position != (Vec3){ 0, 0, 0 } || frame.scale != (Vec3){ 1, 1, 1 }
                || math::abs(frame.rotation.v.w) != 1) {
                return invalid_foot_input(diagnostic, INVALID_STATIC_FRAME)~;
            }
        case SUPPORT:
    }
    return frame;
}

fn FootPlantConfig? validate_foot_plant(FootPlantConfig config, FootDiagnostic* diagnostic) @private {
    if (!math::is_finite(config.acquire_seconds) || !math::is_finite(config.release_seconds)
        || config.acquire_seconds <= 0 || config.release_seconds <= 0) {
        return invalid_foot_input(diagnostic, INVALID_DURATION)~;
    }
    if (!unit_contact_vec(config.sole_up) || !unit_contact_vec(config.sole_forward)
        || math::abs(config.sole_up.dot(config.sole_forward)) > CONTACT_FRAME_TOLERANCE) {
        return invalid_foot_input(diagnostic, INVALID_SOLE_AXES)~;
    }
    config.sole_up = config.sole_up.normalize();
    config.sole_forward = (config.sole_forward - config.sole_up * config.sole_up.dot(config.sole_forward)).normalize();
    return config;
}

fn Transform? validate_foot_incoming(Transform incoming, FootDiagnostic* diagnostic) @private {
    if (!finite_contact_vec(incoming.position) || !unit_contact_quat(incoming.rotation)) {
        return invalid_foot_input(diagnostic, INVALID_INCOMING_POSE)~;
    }
    incoming.rotation = incoming.rotation.normalize();
    return incoming;
}
