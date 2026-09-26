module c3d::anim::ik;

import c3d::maths;
import c3d::scene;
import std::math;

<*
 Joints of the analytic chain: root, middle, end.
*>
const uint TWO_BONE_JOINTS = 3;

<*
 Distance below which a direction or reach counts as degenerate.
*>
const float IK_EPSILON = 1e-5f; // metres and unit-vector lengths; guards normalizations, never validates input

const float PERPENDICULAR_HELPER_LIMIT @local = 0.9f; // an axis this close to X takes Y as its cross-product partner

<*
 Shape of the rotation bound on one joint.
*>
enum IkLimitKind {
    NONE,
    HINGE,
    CONE,
}

<*
 Rotation bound of one joint relative to a reference local rotation.
*>
struct IkLimit {
    IkLimitKind kind;
    Quat        reference;   // local rotation the bound is centred on
    Vec3        axis;        // unit, in the reference frame: hinge axis or cone axis
    float       min_angle;   // HINGE lower bound, radians
    float       max_angle;   // HINGE upper bound or CONE half-angle, radians
}

<*
 Three scene joints whose end reaches a target.
 Joints, target and pole outlive the chain.
*>
struct IkChain {
    Node*[TWO_BONE_JOINTS]   joints;   // each the parent of the next
    Node*                    target;
    Node*                    pole;     // optional; picks the bend side
    float                    weight;   // 0 keeps the incoming pose, 1 applies the solve
    IkLimit[TWO_BONE_JOINTS] limits;   // limits[2] is unused by the two-bone solve
}

<*
 Rotate the root and middle joints so the end reaches the target.
 Writes two local rotations; reads world matrices as left by the last update.
 @require ik_chain_valid(self)
*>
fn void IkChain.solve(&self) {
    if (self.weight == 0) return;

    Node* root = self.joints[0];
    Node* middle = self.joints[1];
    Vec3 root_position = root.world_position();
    Vec3 middle_position = middle.world_position();
    Vec3 end_position = self.joints[2].world_position();

    Vec3 reach = self.target.world_position() - root_position;
    float reach_length = reach.length();
    if (reach_length < IK_EPSILON) return;
    float upper_length = (middle_position - root_position).length();
    float lower_length = (end_position - middle_position).length();
    float target_distance = math::clamp(
        reach_length,
        math::abs(upper_length - lower_length) + IK_EPSILON,
        upper_length + lower_length - IK_EPSILON,
    );
    Vec3 direction = reach / reach_length;

    Vec3 incoming_bend = off_axis(middle_position - root_position, direction);
    Vec3 bend = self.pole ? off_axis(self.pole.world_position() - root_position, direction) : incoming_bend;
    if (bend.length() < IK_EPSILON) bend = incoming_bend;
    if (bend.length() < IK_EPSILON) return;
    bend = bend.normalize();

    float along = (upper_length * upper_length - lower_length * lower_length + target_distance * target_distance)
        / (2 * target_distance);
    float across = math::sqrt(math::max(upper_length * upper_length - along * along, 0.0f));
    Vec3 middle_solved = root_position + direction * along + bend * across;
    Vec3 end_solved = root_position + direction * target_distance;

    Quat root_world = world_rotation(root);
    Quat root_delta = rotation_between(
        (middle_position - root_position).normalize(),
        (middle_solved - root_position).normalize(),
    );
    Quat root_world_solved = root_delta * root_world;
    Quat root_local = parent_rotation(root).conjugate() * root_world_solved;

    Vec3 carried = root_delta * (end_position - middle_position);
    Quat middle_delta = rotation_between(carried.normalize(), (end_solved - middle_solved).normalize());
    Quat middle_world_solved = middle_delta * root_delta * world_rotation(middle);
    Quat middle_local = root_world_solved.conjugate() * middle_world_solved;

    root.local.rotation = root.local.rotation.slerp(apply_limit(&self.limits[0], root_local), self.weight);
    middle.local.rotation = middle.local.rotation.slerp(apply_limit(&self.limits[1], middle_local), self.weight);
}

<*
 Chain with unit weight and no limits.
*>
fn IkChain ik_chain(
    Node* root,
    Node* middle,
    Node* end,
    Node* target,
    Node* pole = null,
) {
    return {
        .joints = { root, middle, end },
        .target = target,
        .pole   = pole,
        .weight = 1,
    };
}

<*
 One-axis bound; angles are signed about the axis.
 @param axis : "Unit, in the reference frame."
 @require min_angle <= max_angle
 @pure
*>
fn IkLimit hinge_limit(
    Quat reference,
    Vec3 axis,
    float min_angle,
    float max_angle,
) {
    return {
        .kind      = HINGE,
        .reference = reference,
        .axis      = axis,
        .min_angle = min_angle,
        .max_angle = max_angle,
    };
}

<*
 Bound on the angle between the rotated axis and the reference axis.
 @param axis : "Unit, in the reference frame."
 @require half_angle >= 0
 @pure
*>
fn IkLimit cone_limit(Quat reference, Vec3 axis, float half_angle) {
    return {
        .kind      = CONE,
        .reference = reference,
        .axis      = axis,
        .max_angle = half_angle,
    };
}

<*
 Whether the joints form a live parent chain with nonzero segments.
 @param [&in] chain
*>
fn bool ik_chain_valid(IkChain* chain) {
    foreach (joint : chain.joints) {
        if (!joint) return false;
    }
    if (!chain.target || !chain.target.parent) return false;
    if (chain.pole && !chain.pole.parent) return false;
    return chain.joints[0].parent != null
        && chain.joints[1].parent == chain.joints[0]
        && chain.joints[2].parent == chain.joints[1]
        && chain.joints[1].local.position.length() > IK_EPSILON
        && chain.joints[2].local.position.length() > IK_EPSILON;
}

fn Quat world_rotation(Node* node) @private {
    return maths::transform_from_mat4(node.world).rotation;
}

fn Quat parent_rotation(Node* node) @private {
    return world_rotation(node.parent);
}

fn Quat rotation_between(Vec3 from, Vec3 to) @private {
    if (from.dot(to) < -1 + IK_EPSILON) return quaternion::from_axis_angle{float}(perpendicular(from), (float)math::PI);
    return quaternion::from_normalized_rotation{float}(from, to);
}

fn Vec3 perpendicular(Vec3 axis) @private {
    Vec3 helper = math::abs(axis.x) < PERPENDICULAR_HELPER_LIMIT ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
    return axis.cross(helper).normalize();
}

fn Vec3 off_axis(Vec3 vector, Vec3 axis) @local {
    return vector - axis * vector.dot(axis);
}

fn Quat apply_limit(IkLimit* limit, Quat local) @private {
    Quat relative = limit.reference.conjugate() * local;
    Vec3 imaginary = { relative.v.x, relative.v.y, relative.v.z };
    switch (limit.kind) {
        case NONE:
            return local;
        case HINGE:
            float signed_sine = imaginary.dot(limit.axis);
            float angle = 2 * math::atan2(signed_sine, relative.v.w);
            if (angle > math::PI) angle -= 2 * (float)math::PI;
            if (angle < -math::PI) angle += 2 * (float)math::PI;
            angle = math::clamp(angle, limit.min_angle, limit.max_angle);
            return limit.reference * quaternion::from_axis_angle{float}(limit.axis, angle);
        case CONE:
            Vec3 rotated = (relative * limit.axis).normalize();
            float angle = math::acos(math::clamp(rotated.dot(limit.axis), -1.0f, 1.0f));
            if (angle <= limit.max_angle) return local;
            Vec3 swing_axis = limit.axis.cross(rotated);
            swing_axis = swing_axis.length() < IK_EPSILON ? perpendicular(limit.axis) : swing_axis.normalize();
            Quat swing = quaternion::from_axis_angle{float}(swing_axis, limit.max_angle);
            Quat twist = rotation_between(limit.axis, rotated).conjugate() * relative;
            return limit.reference * swing * twist;
    }
}
