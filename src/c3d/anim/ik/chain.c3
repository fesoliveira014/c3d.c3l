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
 twist_axis is unit and perpendicular to axis, both in the reference frame.
*>
struct IkLimit {
    IkLimitKind kind;
    Quat        reference;   // local rotation the bound is centred on
    Vec3        axis;        // unit, in the reference frame: hinge axis or cone axis
    Vec3        twist_axis;  // HINGE: kept bone twist axis; zero drops it
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
    Quat root_delta = maths::rotation_between(
        (middle_position - root_position).normalize(),
        (middle_solved - root_position).normalize(),
    );
    Quat root_world_solved = root_delta * root_world;
    Quat root_local = parent_rotation(root).conjugate() * root_world_solved;

    Vec3 carried = root_delta * (end_position - middle_position);
    Quat middle_delta = maths::rotation_between(carried.normalize(), (end_solved - middle_solved).normalize());
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
 @param twist_axis : "Unit bone axis perpendicular to axis; zero drops the twist."
 @require min_angle <= max_angle
 @pure
*>
fn IkLimit hinge_limit(
    Quat reference,
    Vec3 axis,
    float min_angle,
    float max_angle,
    Vec3 twist_axis = {},
) {
    return {
        .kind       = HINGE,
        .reference  = reference,
        .axis       = axis,
        .twist_axis = twist_axis,
        .min_angle  = min_angle,
        .max_angle  = max_angle,
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
 Whether live joints form an articulated chain with nonzero segments.
 @param [&in] chain : "Chain to check before a solve."
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
        && chain.joints[1].transform_space == TransformSpace.PARENT
        && chain.joints[2].transform_space == TransformSpace.PARENT
        && chain.joints[1].local.position.length() > IK_EPSILON
        && chain.joints[2].local.position.length() > IK_EPSILON;
}

fn Quat world_rotation(Node* node) @private {
    return maths::transform_from_mat4(node.world).rotation;
}

fn Quat parent_rotation(Node* node) @private {
    return maths::transform_from_mat4(node.transform_basis()).rotation;
}

fn Vec3 off_axis(Vec3 vector, Vec3 axis) @local {
    return vector - axis * vector.dot(axis);
}

fn float hinge_angle(Quat rotation, Vec3 axis) @local {
    Vec3 imaginary = { rotation.v.x, rotation.v.y, rotation.v.z };
    float angle = 2 * math::atan2(imaginary.dot(axis), rotation.v.w);
    if (angle > math::PI) angle -= 2 * (float)math::PI;
    if (angle < -math::PI) angle += 2 * (float)math::PI;
    return angle;
}

// The part of the rotation about the axis; a half-turn swing leaves no twist to measure.
fn Quat bone_twist(Quat rotation, Vec3 axis) @local {
    Vec3 imaginary = { rotation.v.x, rotation.v.y, rotation.v.z };
    Vec3 along = axis * imaginary.dot(axis);
    float length = math::sqrt(along.dot(along) + rotation.v.w * rotation.v.w);
    if (length < IK_EPSILON) return quaternion::IDENTITY;
    return { .v = { along.x / length, along.y / length, along.z / length, rotation.v.w / length } };
}

fn Quat apply_limit(IkLimit* limit, Quat local) @private {
    Quat relative = limit.reference.conjugate() * local;
    switch (limit.kind) {
        case NONE:
            return local;
        case HINGE:
            if (limit.twist_axis.length() < IK_EPSILON) {
                float angle = hinge_angle(relative, limit.axis);
                angle = math::clamp(angle, limit.min_angle, limit.max_angle);
                return limit.reference * quaternion::from_axis_angle{float}(limit.axis, angle);
            }
            Quat twist = bone_twist(relative, limit.twist_axis);
            float angle = hinge_angle(relative * twist.conjugate(), limit.axis);
            angle = math::clamp(angle, limit.min_angle, limit.max_angle);
            return limit.reference * quaternion::from_axis_angle{float}(limit.axis, angle) * twist;
        case CONE:
            Vec3 rotated = (relative * limit.axis).normalize();
            float angle = math::acos(math::clamp(rotated.dot(limit.axis), -1.0f, 1.0f));
            if (angle <= limit.max_angle) return local;
            Vec3 swing_axis = limit.axis.cross(rotated);
            swing_axis = swing_axis.length() < IK_EPSILON ? maths::perpendicular(limit.axis) : swing_axis.normalize();
            Quat swing = quaternion::from_axis_angle{float}(swing_axis, limit.max_angle);
            Quat twist = maths::rotation_between(limit.axis, rotated).conjugate() * relative;
            return limit.reference * swing * twist;
    }
}
