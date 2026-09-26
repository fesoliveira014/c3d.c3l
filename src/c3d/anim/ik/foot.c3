module c3d::anim::ik;

import c3d::maths;
import c3d::scene;
import std::math;

const float FOOT_HEIGHT_DEFAULT @local = 0.08f; // ankle above the sole of an adult human rig, metres
const float LIFT_FADE_DEFAULT @local = 0.1f;    // a heel-off lift; swinging feet rise well above it
const float RAY_HEIGHT_DEFAULT @local = 0.5f;   // covers a step up the height of a stair
const float RAY_LENGTH_DEFAULT @local = 1.5f;   // ray height plus a one-metre drop
const Vec3 WORLD_UP @local = { 0, 1, 0 };

<*
 Ground contact the application found for a foot.
*>
struct GroundHit {
    Vec3 point;
    Vec3 normal;   // unit
}

<*
 Leg chain placed on the ground under its ankle, relative to the character's floor.
*>
struct FootIk {
    IkChain   leg;             // end joint is the ankle; its target must not descend from the leg or pelvis
    float     foot_height;     // ankle height above the sole in the authored stance, metres
    float     lift_fade;       // ankle lift over which foot alignment fades out, metres, positive
    float     ray_height;      // ray start above the ankle, metres
    float     ray_length;      // metres
    GroundHit ground;          // valid while grounded
    float     ground_offset;   // ground height below the ankle minus floor height, metres
    float     align_weight;    // leg weight scaled by the lift fade
    bool      grounded;
}

<*
 Downward ray from above the ankle, for the application's ground query.
 @require ik_chain_valid(&self.leg)
*>
fn Ray FootIk.ground_ray(&self) {
    return {
        .origin    = self.leg.joints[2].world_position() + WORLD_UP * self.ray_height,
        .direction = -WORLD_UP,
    };
}

<*
 Move the target by the ground's offset from the floor and record the hit.
 @param floor_height : "World height the clip's feet stand on."
 @require ik_chain_valid(&self.leg), self.lift_fade > 0, hit.normal.is_normalized()
*>
fn void FootIk.place(&self, GroundHit hit, float floor_height) {
    Vec3 ankle = self.leg.joints[2].world_position();
    self.ground_offset = hit.point.y - floor_height;
    move_target(&self.leg, ankle + WORLD_UP * self.ground_offset);

    float lift = ankle.y - floor_height - self.foot_height;
    self.align_weight = self.leg.weight * math::clamp(1 - lift / self.lift_fade, 0.0f, 1.0f);
    self.ground = hit;
    self.grounded = true;
}

<*
 Put the target on the incoming ankle; the leg keeps its clip pose.
 @require ik_chain_valid(&self.leg)
*>
fn void FootIk.release(&self) {
    move_target(&self.leg, self.leg.joints[2].world_position());
    self.ground_offset = 0;
    self.align_weight = 0;
    self.grounded = false;
}

<*
 Tilt the ankle from world up onto the ground normal at align_weight.
 Writes the ankle's local rotation only; run after the solve and an update.
 @require ik_chain_valid(&self.leg)
*>
fn void FootIk.align(&self) {
    if (!self.grounded || self.align_weight == 0) return;

    Node* ankle = self.leg.joints[2];
    Quat tilt = rotation_between(WORLD_UP, self.ground.normal);
    Quat aligned = parent_rotation(ankle).conjugate() * tilt * world_rotation(ankle);
    ankle.local.rotation = ankle.local.rotation.slerp(aligned, self.align_weight);
}

<*
 Foot with a leg chain and the default ray and fade.
*>
fn FootIk foot_ik(
    Node* hip,
    Node* knee,
    Node* ankle,
    Node* target,
    Node* pole = null,
) {
    return {
        .leg         = ik_chain(hip, knee, ankle, target, pole),
        .foot_height = FOOT_HEIGHT_DEFAULT,
        .lift_fade   = LIFT_FADE_DEFAULT,
        .ray_height  = RAY_HEIGHT_DEFAULT,
        .ray_length  = RAY_LENGTH_DEFAULT,
    };
}

<*
 Lower the pelvis by the largest downhill offset of the grounded feet.
 @param [&inout] pelvis : "Parent chain above every leg; uniform scale."
 @return "The world-space drop applied, metres."
 @require pelvis.parent != null
*>
fn float lower_pelvis(Node* pelvis, FootIk*[] feet) {
    float drop;
    foreach (foot : feet) {
        if (foot.grounded) drop = math::max(drop, -foot.ground_offset * foot.leg.weight);
    }
    if (drop > 0) {
        Mat4 parent_inverse = maths::inverse_affine(pelvis.parent.world);
        pelvis.local.position += maths::transform_dir(parent_inverse, WORLD_UP * -drop);
    }
    return drop;
}

fn void move_target(IkChain* chain, Vec3 world_position) @local {
    Node* target = chain.target;
    target.local.position = maths::transform_point(maths::inverse_affine(target.parent.world), world_position);
}
