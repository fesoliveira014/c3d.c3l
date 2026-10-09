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
    FootPlantConfig plant;
    FootContact contact;
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
    Quat tilt = maths::rotation_between(WORLD_UP, self.ground.normal);
    Quat aligned = parent_rotation(ankle).conjugate() * tilt * world_rotation(ankle);
    ankle.local.rotation = ankle.local.rotation.slerp(aligned, self.align_weight);
}

<*
 Capture caller-selected support from the incoming ankle world pose.
 @param floor_height : "World height the clip's feet stand on."
 @param [out] diagnostic : "Optional invalid-input context."
 @return? c3d::INVALID_ARGUMENT
 @require ik_chain_valid(&self.leg)
*>
fn void? FootIk.begin_contact(
    &self,
    GroundHit hit,
    FootSupport support,
    float floor_height = 0,
    FootDiagnostic* diagnostic = null,
) {
    clear_foot_diagnostic(diagnostic);
    if (!math::is_finite(floor_height)) return invalid_foot_input(diagnostic, INVALID_FLOOR_HEIGHT)~;
    self.contact.begin_contact(
        hit: hit,
        support: support,
        incoming: maths::transform_from_mat4(self.leg.joints[2].world),
        config: self.plant,
        foot_height: self.foot_height,
        diagnostic: diagnostic,
    )!;
    publish_foot_contact(self, floor_height);
}

<*
 Update the requested target before pelvis adjustment and leg solving.
 @param dt : "Finite nonnegative seconds."
 @param floor_height : "World height the clip's feet stand on."
 @param [out] diagnostic : "Optional invalid-input context."
 @return? c3d::INVALID_ARGUMENT
 @require ik_chain_valid(&self.leg)
*>
fn void? FootIk.update_contact(
    &self,
    FootSupport support,
    float dt,
    float floor_height = 0,
    FootDiagnostic* diagnostic = null,
) {
    clear_foot_diagnostic(diagnostic);
    if (!math::is_finite(floor_height)) return invalid_foot_input(diagnostic, INVALID_FLOOR_HEIGHT)~;
    self.contact.update_contact(
        support: support,
        incoming: maths::transform_from_mat4(self.leg.joints[2].world),
        dt: dt,
        diagnostic: diagnostic,
    )!;
    publish_foot_contact(self, floor_height);
}

<*
 Begin controlled release using the fresh incoming ankle pose.
 @param floor_height : "World height the clip's feet stand on."
 @param [out] diagnostic : "Optional invalid-input context."
 @return? c3d::INVALID_ARGUMENT
 @require ik_chain_valid(&self.leg)
*>
fn void? FootIk.end_contact(
    &self,
    FootSupport support,
    float floor_height = 0,
    FootDiagnostic* diagnostic = null,
) {
    clear_foot_diagnostic(diagnostic);
    if (!math::is_finite(floor_height)) return invalid_foot_input(diagnostic, INVALID_FLOOR_HEIGHT)~;
    self.contact.end_contact(
        support: support,
        incoming: maths::transform_from_mat4(self.leg.joints[2].world),
        diagnostic: diagnostic,
    )!;
    publish_foot_contact(self, floor_height);
}

<*
 Clear runtime contact and immediately restore the incoming ankle target.
 @require ik_chain_valid(&self.leg)
*>
fn void FootIk.reset_contact(&self) {
    self.contact.reset_contact();
    move_target(&self.leg, self.leg.joints[2].world_position());
    self.ground = {};
    self.ground_offset = 0;
    self.align_weight = 0;
    self.grounded = false;
}

<*
 Apply requested ankle orientation after solving and refreshing worlds.
 @require ik_chain_valid(&self.leg)
*>
fn void FootIk.align_contact(&self) {
    if (self.contact.phase == INACTIVE || self.leg.weight == 0) return;
    Node* ankle = self.leg.joints[2];
    Quat actual = world_rotation(ankle);
    Quat requested = actual.slerp(self.contact.requested.rotation, self.leg.weight).normalize();
    ankle.local.rotation = (parent_rotation(ankle).conjugate() * requested).normalize();
}

<*
 Measure final ankle residual after alignment and world refresh.
 @require ik_chain_valid(&self.leg)
*>
fn FootContactResult FootIk.contact_result(&self) {
    return self.contact.contact_result(maths::transform_from_mat4(self.leg.joints[2].world));
}

<*
 Shift every component-owned contact once after the scene world refresh.
 @param offset : "Same horizontal metres passed to Scene.shift_origin."
 @require offset.y == 0, finite_contact_vec(offset)
*>
fn void Scene.shift_foot_contacts(&self, Vec3 offset) {
    self.@each(FootIk; entity, foot) {
        foot.contact.shift_origin(offset);
        if (foot.grounded) foot.ground.point -= offset;
    };
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
        .plant       = FOOT_PLANT_DEFAULT,
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
        Mat4 basis_inverse = maths::inverse_affine(pelvis.transform_basis());
        pelvis.local.position += maths::transform_dir(basis_inverse, WORLD_UP * -drop);
    }
    return drop;
}

fn void move_target(IkChain* chain, Vec3 world_position) @local {
    chain.target.set_world_position(world_position);
}

fn void publish_foot_contact(FootIk* foot, float floor_height) @local {
    move_target(&foot.leg, foot.contact.requested.position);
    foot.grounded = foot.contact.phase != INACTIVE;
    foot.align_weight = foot.grounded ? foot.leg.weight : 0;
    if (!foot.grounded) {
        foot.ground = {};
        foot.ground_offset = 0;
        return;
    }
    Transform locked = locked_foot_pose(&foot.contact);
    Vec3 normal = (foot.contact.support_frame.rotation * foot.contact.local_normal).normalize();
    foot.ground = {
        .point = locked.position - normal * foot.contact.foot_height,
        .normal = normal,
    };
    Vec3 requested_sole = foot.contact.requested.position
        - foot.contact.requested.rotation * foot.contact.config.sole_up * foot.contact.foot_height;
    foot.ground_offset = requested_sole.y - floor_height;
}
