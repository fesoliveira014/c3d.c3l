module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import b3;

const float RECOVERY_MIN_ROTATION @local = 0.0000001f;
const float RECOVERY_HEADING_LENGTH @local = 0.3f;
const float RECOVERY_SCALE_TOLERANCE @local = 0.0001f;

<* Current physical recovery state. *>
enum RagdollRecoveryPhase {
    INACTIVE,
    TRACKING,
    BLOCKED,
    READY,
    COMPLETING,
}

<*
 Per-bone recovery gains, tolerances, and actuator caps.
 Caps include gravity compensation; invalid settings fault on recovery entry.
*>
struct RagdollRecoverySettings {
    float position_hertz;
    float angular_hertz;
    float damping_ratio;
    float max_force;
    float max_torque;
    float entry_position_tolerance;
    float entry_angle_tolerance;
    float tracking_position_tolerance;
    float tracking_angle_tolerance;
    float finish_position_tolerance;
    float finish_angle_tolerance;
    float finish_linear_speed;
    float finish_angular_speed;
}

<*
 Latest recovery phase, residuals, speeds, and applied actuator magnitudes.
 Invalid animation or arithmetic sets failure; obstruction alone does not.
*>
struct RagdollRecoveryStatus {
    RagdollRecoveryPhase phase;
    uint participating;
    float position_error;
    float angle_error;
    float linear_speed;
    float angular_speed;
    float force;
    float torque;
    fault failure;
}

struct RecoveryBone @private {
    Entity entity;
    b3::BodyId body;
    b3::JointId joint;
    JointKind joint_kind;
    maths::Transform target;
    float weight;
    bool active;
    bool completing;
}

struct RagdollRecovery @private {
    RecoveryBone[] bones;
    maths::Transform[] animation;
    maths::Transform[] targets;
    RagdollRecoverySettings settings;
    RagdollRecoveryStatus status;
    ulong captured_update;
    bool captured;
}

<*
 Read transient recovery state; serialization does not retain this value.
 @param [in] self : "Ragdoll whose recovery state is read."
*>
fn RagdollRecoveryStatus Ragdoll.recovery_status(&self) => self.recovery.status;

<*
 Begin physical recovery from the preceding final joint worlds.
 Call before fresh animation; bodies remain dynamic.
 @param [inout] self : "World whose ragdoll begins recovery."
 @param [inout] skin_node : "Node carrying the ragdoll."
 @param [&inout] character : "Ancestor repositioned horizontally using the physical hips."
 @return "Facing of the selected get-up animation."
 @return? NO_BODY, NO_JOINT, RECOVERY_POSE_MISMATCH, c3d::INVALID_ARGUMENT
 @require self.scene.has(skin_node, Ragdoll)
*>
fn RagdollFacing? PhysicsWorld.recover_ragdoll(
    &self,
    Node* skin_node,
    Node* character,
    RagdollRecoverySettings settings = default_ragdoll_recovery_settings(),
) {
    Scene* scene = self.scene;
    Ragdoll* ragdoll = scene.get(skin_node, Ragdoll);
    validate_recovery_entry(self, skin_node, settings)!;
    if (ragdoll.bone_modes[0] != SIMULATED || !valid_recovery_transform(maths::transform_from_mat4(character.world))) {
        return c3d::INVALID_ARGUMENT~;
    }

    maths::Transform hips = recovery_body_pose(scene.get(ragdoll.bone_nodes[0], RigidBody).body);
    maths::Transform pose = maths::transform_from_mat4(character.world);
    Quat standing = maths::transform_from_mat4(skin_node.world).rotation.mul(ragdoll.hips_bind_rotation);
    Quat fall = pose.rotation.conjugate().mul(hips.rotation).mul(standing.conjugate()).mul(pose.rotation);
    Vec3 forward = fall.rotate_vec3({ 0, 0, 1 });
    Vec3 head = fall.rotate_vec3({ 0, 1, 0 });
    RagdollFacing facing = forward.y < 0 ? FACE_DOWN : FACE_UP;
    Vec3 heading = facing == FACE_DOWN ? head : -head;
    heading.y = 0;
    if (heading.length() <= RECOVERY_HEADING_LENGTH) heading = { forward.x, 0, forward.z };
    pose.position.x = hips.position.x;
    pose.position.z = hips.position.z;
    if (heading.length() > RECOVERY_HEADING_LENGTH) {
        Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::atan2(heading.x, heading.z));
        pose.rotation = pose.rotation.mul(yaw).normalize();
    }
    if (!valid_recovery_transform(pose)) return c3d::INVALID_ARGUMENT~;

    capture_recovery_source(scene, skin_node, ragdoll);
    character.set_world_pose(pose.position, pose.rotation);
    scene.update_world();
    start_ragdoll_recovery(self, skin_node, settings);
    ragdoll.last_facing = facing;
    ragdoll.recoveries++;

    return facing;
}

<*
 Begin physical recovery of currently simulated bones.
 Call before fresh animation, using preceding final joint worlds.
 @param [inout] self : "World whose bones begin recovery."
 @param [inout] skin_node : "Node carrying the ragdoll."
 @return? NO_BODY, NO_JOINT, RECOVERY_POSE_MISMATCH, c3d::INVALID_ARGUMENT
 @require self.scene.has(skin_node, Ragdoll)
*>
fn void? PhysicsWorld.recover_bones(
    &self,
    Node* skin_node,
    RagdollRecoverySettings settings = default_ragdoll_recovery_settings(),
) {
    validate_recovery_entry(self, skin_node, settings)!;

    Ragdoll* ragdoll = self.scene.get(skin_node, Ragdoll);
    capture_recovery_source(self.scene, skin_node, ragdoll);
    start_ragdoll_recovery(self, skin_node, settings);
}

<*
 Finish settled recovery after update and before update_ragdolls.
 Captured weights must be zero; native publication lasts this update.
 @param [inout] self : "World whose recovery is finished."
 @param [inout] skin_node : "Node carrying the ragdoll."
 @return? NO_RECOVERY, RECOVERY_NOT_READY
 @require self.scene.has(skin_node, Ragdoll)
*>
fn void? PhysicsWorld.finish_ragdoll_recovery(&self, Node* skin_node) {
    Ragdoll* ragdoll = self.scene.get(skin_node, Ragdoll);
    reconcile_recovery(self.scene, ragdoll);
    if (ragdoll.recovery.status.participating == 0) return NO_RECOVERY~;
    if (!ragdoll.recovery.captured
        || ragdoll.recovery.captured_update != self.update_serial) return RECOVERY_NOT_READY~;

    observe_ragdoll_recovery(ragdoll);
    if (ragdoll.recovery.status.phase != READY) return RECOVERY_NOT_READY~;

    RagdollRecoveryStatus status = ragdoll.recovery.status;
    foreach (usz index, &bone : ragdoll.recovery.bones) {
        if (!bone.active) continue;
        switch_bone(
            scene: self.scene,
            ragdoll: ragdoll,
            bone: index,
            mode: ANIMATED,
        );
        bone.completing = true;
    }

    status.phase = COMPLETING;
    status.participating = 0;
    ragdoll.recovery.status = status;
}

<*
 Publish physical recovery and ordinary ragdoll blending.
 Refresh scene worlds afterward; repeated recovery publication is idempotent.
 @param [inout] self : "World whose ragdolls are published."
*>
fn void PhysicsWorld.update_ragdolls(&self) {
    Scene* scene = self.scene;
    float alpha = self.desc.tuning.interpolate ? self.alpha : 1;

    scene.@each(Ragdoll; entity, ragdoll) {
        reconcile_recovery(scene, ragdoll);
        if (recovery_has_publication(ragdoll)) {
            publish_ragdoll_recovery(
                scene: scene,
                skin_node: scene.node(entity),
                ragdoll: ragdoll,
                alpha: alpha,
            );
        } else if (ragdoll.weight > 0) {
            blend_ragdoll(
                scene: scene,
                skin_node: scene.node(entity),
                ragdoll: ragdoll,
                alpha: alpha,
            );
        }
    };
}

<*
 Default critically damped recovery gains and per-bone actuator caps.
*>
fn RagdollRecoverySettings default_ragdoll_recovery_settings() {
    return {
        .position_hertz = 4,
        .angular_hertz = 4,
        .damping_ratio = 1,
        .max_force = 200,
        .max_torque = 20,
        .entry_position_tolerance = 0.01f,
        .entry_angle_tolerance = 0.01f,
        .tracking_position_tolerance = 0.15f,
        .tracking_angle_tolerance = 0.3f,
        .finish_position_tolerance = 0.015f,
        .finish_angle_tolerance = 0.02f,
        .finish_linear_speed = 0.03f,
        .finish_angular_speed = 0.05f,
    };
}

fn void? validate_recovery_settings(RagdollRecoverySettings settings) @local {
    float[13] values = {
        settings.position_hertz, settings.angular_hertz, settings.damping_ratio,
        settings.max_force, settings.max_torque, settings.entry_position_tolerance,
        settings.entry_angle_tolerance, settings.tracking_position_tolerance,
        settings.tracking_angle_tolerance, settings.finish_position_tolerance,
        settings.finish_angle_tolerance, settings.finish_linear_speed, settings.finish_angular_speed,
    };

    foreach (value : values) if (!math::is_finite(value) || value < 0) return c3d::INVALID_ARGUMENT~;
    if (settings.position_hertz == 0 || settings.angular_hertz == 0
        || settings.max_force == 0 || settings.max_torque == 0) {
        return c3d::INVALID_ARGUMENT~;
    }

    float position_frequency = 2 * math::PI * settings.position_hertz;
    float angular_frequency = 2 * math::PI * settings.angular_hertz;
    if (!math::is_finite(position_frequency * position_frequency)
        || !math::is_finite(angular_frequency * angular_frequency)
        || !math::is_finite(2 * settings.damping_ratio * position_frequency)
        || !math::is_finite(2 * settings.damping_ratio * angular_frequency)) return c3d::INVALID_ARGUMENT~;
}

fn bool valid_recovery_transform(maths::Transform pose) @local {
    return b3::is_valid_vec3(pose.position) && b3::is_valid_quat(pose.rotation)
      && b3::is_valid_vec3(pose.scale) && (pose.scale - (Vec3){ 1, 1, 1 }).length() <= RECOVERY_SCALE_TOLERANCE;
}

fn void? validate_recovery_entry(
    PhysicsWorld* world,
    Node* skin_node,
    RagdollRecoverySettings settings,
) @local {
    validate_recovery_settings(settings)!;
    Scene* scene = world.scene;
    Ragdoll* ragdoll = scene.get(skin_node, Ragdoll);
    Node*[] joints = scene.get(skin_node, SkinBinding).joints;
    if (!math::is_finite(ragdoll.weight) || ragdoll.weight < 0) return c3d::INVALID_ARGUMENT~;
    foreach (joint : joints)
        if (!valid_recovery_transform(maths::transform_from_mat4(joint.world))) return c3d::INVALID_ARGUMENT~;

    uint participants;

    foreach (usz index, mode : ragdoll.bone_modes) {
        if (!math::is_finite(ragdoll.bone_weights[index]) || ragdoll.bone_weights[index] < 0) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (mode != SIMULATED) continue;
        participants++;

        Node* node = ragdoll.bone_nodes[index];
        if (!scene.has(node, RigidBody) || !scene.has(node, PhysicsBody)) return NO_BODY~;
        RigidBody* body = scene.get(node, RigidBody);
        if (!body.body.is_valid()) return NO_BODY~;
        if (body.kind != DYNAMIC || scene.get(node, PhysicsBody).body.kind != DYNAMIC) return c3d::INVALID_ARGUMENT~;
        if (ragdoll.bone_parents[index] >= 0) {
            if (!scene.has(node, Joint) || !scene.get(node, Joint).joint.is_valid()) return NO_JOINT~;
        }
        if (!valid_recovery_transform(ragdoll.joint_in_bone[index])) return c3d::INVALID_ARGUMENT~;

        maths::Transform physical = recovery_body_pose(body.body);
        if (!valid_recovery_transform(physical)) return c3d::INVALID_ARGUMENT~;
        maths::Transform mapped =
          maths::transform_from_mat4(physical.to_mat4().mul(ragdoll.joint_in_bone[index].to_mat4()));
        maths::Transform visible = maths::transform_from_mat4(joints[ragdoll.bone_joints[index]].world);
        if ((mapped.position - visible.position).length() > settings.entry_position_tolerance
            || recovery_rotation_error(mapped.rotation, visible.rotation).length() > settings.entry_angle_tolerance) {
            return RECOVERY_POSE_MISMATCH~;
        }
    }

    if (participants == 0) return c3d::INVALID_ARGUMENT~;
}

fn void capture_recovery_source(Scene* scene, Node* skin_node, Ragdoll* ragdoll) @local {
    Node*[] joints = scene.get(skin_node, SkinBinding).joints;
    foreach (usz index, node : joints) ragdoll.joint_worlds[index] = node.world;

    foreach (usz index, mode : ragdoll.bone_modes) {
        if (mode != SIMULATED) continue;
        b3::BodyId body = scene.get(ragdoll.bone_nodes[index], RigidBody).body;
        ragdoll.joint_worlds[ragdoll.bone_joints[index]] =
          recovery_body_pose(body).to_mat4().mul(ragdoll.joint_in_bone[index].to_mat4());
    }
}

fn void start_ragdoll_recovery(
    PhysicsWorld* world,
    Node* skin_node,
    RagdollRecoverySettings settings,
) @local {
    Ragdoll* ragdoll = world.scene.get(skin_node, Ragdoll);
    cancel_ragdoll_recovery(ragdoll);
    freeze_joints(ragdoll, world.scene.get(skin_node, SkinBinding).joints);
    ragdoll.recovery.animation[..] = ragdoll.frozen[..];
    ragdoll.recovery.targets[..] = ragdoll.frozen[..];
    ragdoll.recovery.settings = settings;
    ragdoll.recovery.captured = false;

    foreach (usz index, mode : ragdoll.bone_modes) {
        if (mode != SIMULATED) continue;

        Node* node = ragdoll.bone_nodes[index];
        RecoveryBone* bone = &ragdoll.recovery.bones[index];
        *bone = { .entity = node.id, .body = world.scene.get(node, RigidBody).body, .active = true };
        bone.target = recovery_body_pose(bone.body);
        if (ragdoll.bone_parents[index] >= 0) {
            Joint* joint = world.scene.get(node, Joint);
            bone.joint = joint.joint;
            bone.joint_kind = joint.kind;
            set_recovery_spring(
                ragdoll: ragdoll,
                index: index,
                joint: bone.joint,
                kind: bone.joint_kind,
                masked: true,
            );
        }
        ragdoll.recovery.status.participating++;
    }

    ragdoll.recovery.status.phase = TRACKING;
}

fn bool recovery_has_publication(Ragdoll* ragdoll) @local {
    foreach (bone : ragdoll.recovery.bones) if (bone.active || bone.completing) return true;

    return false;
}

fn maths::Transform recovery_body_pose(b3::BodyId body) @local {
    b3::WorldTransform pose = body.transform();
    return { .position = pose.p, .rotation = pose.q, .scale = { 1, 1, 1 } };
}

fn Vec3 recovery_rotation_error(Quat target, Quat current) @local {
    Quat difference = target.mul(current.conjugate()).normalize();
    if (difference.l < 0) difference = -difference;

    Vec3 axis = { difference.i, difference.j, difference.k };
    float sine = axis.length();
    if (sine < RECOVERY_MIN_ROTATION) return axis * 2;
    return axis * (2 * math::atan2(sine, difference.l) / sine);
}

fn maths::Transform recovery_blend(maths::Transform animation, maths::Transform source, float weight) @local {
    if (animation.rotation.v.dot(source.rotation.v) < 0) source.rotation = -source.rotation;
    return {
        .position = animation.position + (source.position - animation.position) * weight,
        .rotation = animation.rotation.nlerp(source.rotation, weight),
        .scale = animation.scale,
    };
}

fn void capture_ragdoll_recovery(PhysicsWorld* world) @private {
    world.scene.@each(Ragdoll; entity, ragdoll) {
        foreach (usz index, &bone : ragdoll.recovery.bones) {
            if (bone.completing) cancel_recovery_bone(ragdoll, index);
        }
        reconcile_recovery(world.scene, ragdoll);
        if (ragdoll.recovery.status.participating > 0) {
            capture_recovery_inputs(world, world.scene.node(entity), ragdoll);
        }
    };
}

fn void capture_recovery_inputs(PhysicsWorld* world, Node* skin_node, Ragdoll* ragdoll) @local {
    Node*[] joints = world.scene.get(skin_node, SkinBinding).joints;
    ragdoll.recovery.status = { .phase = TRACKING, .participating = ragdoll.recovery.status.participating };
    ragdoll.recovery.captured_update = world.update_serial;
    bool valid = math::is_finite(ragdoll.weight) && ragdoll.weight >= 0;
    foreach (weight : ragdoll.bone_weights) valid &= math::is_finite(weight) && weight >= 0;
    foreach (node : joints) valid &= valid_recovery_transform(node.local);

    if (!valid) {
        ragdoll.recovery.status.failure = c3d::INVALID_ARGUMENT;
        push_failure(world, skin_node, c3d::INVALID_ARGUMENT);
        return;
    }

    ragdoll.recovery.captured = true;
    foreach (usz index, &bone : ragdoll.recovery.bones)
        bone.weight = math::min(ragdoll.weight, 1.0f) * ragdoll.bone_weights[index];

    foreach (joint : ragdoll.joint_order) {
        maths::Transform animation = joints[joint].local;
        ragdoll.recovery.animation[joint] = animation;
        uint owner = ragdoll.joint_owner[joint];
        maths::Transform source = ragdoll.frozen[joint];
        Mat4 parent = parent_world_of(ragdoll, joints, joint);
        if (!ragdoll.recovery.bones[owner].active && ragdoll.bone_modes[owner] == SIMULATED) {
            float alpha = world.desc.tuning.interpolate ? world.alpha : 1;
            if (try physical = joint_target_world(
                scene: world.scene,
                ragdoll: ragdoll,
                joint: joint,
                alpha: alpha,
            )) {
                source = relative(parent, physical);
            } else {
                source = animation;
            }
        }

        maths::Transform target = recovery_blend(animation, source, ragdoll.recovery.bones[owner].weight);
        ragdoll.recovery.targets[joint] = target;
        ragdoll.joint_worlds[joint] = parent.mul(target.to_mat4());
        valid &= valid_recovery_transform(maths::transform_from_mat4(ragdoll.joint_worlds[joint]));
        int mapped = ragdoll.joint_bone[joint];
        if (mapped >= 0 && ragdoll.recovery.bones[mapped].active) {
            Mat4 inverse_mapping = maths::inverse_affine(ragdoll.joint_in_bone[mapped].to_mat4());
            ragdoll.recovery.bones[mapped].target =
              maths::transform_from_mat4(ragdoll.joint_worlds[joint].mul(inverse_mapping));
            valid &= valid_recovery_transform(ragdoll.recovery.bones[mapped].target);
        }
    }

    if (!valid) {
        ragdoll.recovery.status.failure = c3d::INVALID_ARGUMENT;
        push_failure(world, skin_node, c3d::INVALID_ARGUMENT);
    }
}

fn void mask_ragdoll_recovery(PhysicsWorld* world) @private {
    world.scene.@each(Ragdoll; entity, ragdoll) {
        reconcile_recovery(world.scene, ragdoll);
        foreach (usz index, bone : ragdoll.recovery.bones) {
            if (bone.active && bone.joint.is_valid()) set_recovery_spring(
                ragdoll: ragdoll,
                index: index,
                joint: bone.joint,
                kind: bone.joint_kind,
                masked: true,
            );
        }
    };
}

fn Vec3 capped_recovery_vector(Vec3 value, float cap) @local {
    float maximum = math::max(math::abs(value.x), math::abs(value.y), math::abs(value.z));
    if (maximum == 0) return value;
    Vec3 unit = value / maximum;
    float scaled_length = unit.length();
    return maximum > cap / scaled_length ? unit * (cap / scaled_length) : value;
}

fn void? apply_recovery_bone(
    PhysicsWorld* world,
    Ragdoll* ragdoll,
    RecoveryBone* bone,
) @local {
    RagdollRecoverySettings settings = ragdoll.recovery.settings;
    b3::BodyId body = bone.body;

    float position_frequency = 2 * math::PI * settings.position_hertz;
    float angular_frequency = 2 * math::PI * settings.angular_hertz;
    Vec3 target_center = bone.target.position + bone.target.rotation.rotate_vec3(body.local_center());
    Vec3 acceleration = (target_center - (Vec3)body.world_center()) * position_frequency * position_frequency
      - body.linear_velocity() * (2 * settings.damping_ratio * position_frequency)
      - world.desc.tuning.gravity * body.gravity_scale();
    Vec3 force = acceleration * body.mass();

    Vec3 angular_acceleration = recovery_rotation_error(bone.target.rotation, body.rotation())
      * angular_frequency * angular_frequency
      - body.angular_velocity() * (2 * settings.damping_ratio * angular_frequency);
    Quat rotation = body.rotation();
    Vec3 torque =
      rotation.rotate_vec3(body.local_rotational_inertia() * rotation.conjugate().rotate_vec3(angular_acceleration));
    if (!b3::is_valid_vec3(force) || !b3::is_valid_vec3(torque)) return c3d::INVALID_ARGUMENT~;

    force = capped_recovery_vector(force, settings.max_force);
    torque = capped_recovery_vector(torque, settings.max_torque);
    ragdoll.recovery.status.force = math::max(ragdoll.recovery.status.force, force.length());
    ragdoll.recovery.status.torque = math::max(ragdoll.recovery.status.torque, torque.length());

    b3::body_apply_force_to_center(body, force, true);
    b3::body_apply_torque(body, torque, true);
}

fn void apply_ragdoll_recovery(PhysicsWorld* world) @private {
    mask_ragdoll_recovery(world);

    world.scene.@each(Ragdoll; entity, ragdoll) {
        if (!ragdoll.recovery.status.failure) {
            foreach (&bone : ragdoll.recovery.bones) {
                if (!bone.active) continue;
                if (catch excuse = apply_recovery_bone(world, ragdoll, bone)) {
                    ragdoll.recovery.status.failure = excuse;
                    push_failure(world, world.scene.node(entity), excuse);
                    break;
                }
            }
        }
    };
}

fn void observe_ragdoll_recovery(Ragdoll* ragdoll) @local {
    RagdollRecoveryStatus* status = &ragdoll.recovery.status;
    if (status.participating == 0) return;
    if (status.failure) {
        status.phase = BLOCKED;
        return;
    }

    RagdollRecoverySettings settings = ragdoll.recovery.settings;
    status.position_error = 0;
    status.angle_error = 0;
    status.linear_speed = 0;
    status.angular_speed = 0;
    bool zero_weight = true;

    foreach (usz index, bone : ragdoll.recovery.bones) {
        if (!bone.active) continue;
        maths::Transform pose = recovery_body_pose(bone.body);
        Vec3 mapping = ragdoll.joint_in_bone[index].position;
        Vec3 target_joint = bone.target.position + bone.target.rotation.rotate_vec3(mapping);
        Vec3 native_joint = bone.body.world_point(mapping);
        status.position_error = math::max(status.position_error, (target_joint - native_joint).length());
        status.angle_error = math::max(
            status.angle_error,
            recovery_rotation_error(bone.target.rotation, pose.rotation).length(),
        );
        status.linear_speed = math::max(status.linear_speed, bone.body.linear_velocity().length());
        status.angular_speed = math::max(status.angular_speed, bone.body.angular_velocity().length());
        zero_weight &= bone.weight == 0;
    }

    bool settled = status.position_error <= settings.finish_position_tolerance
      && status.angle_error <= settings.finish_angle_tolerance
      && status.linear_speed <= settings.finish_linear_speed && status.angular_speed <= settings.finish_angular_speed;
    status.phase = zero_weight && settled && !status.failure ? READY : TRACKING;
    if (status.phase != READY && (status.position_error > settings.tracking_position_tolerance
        || status.angle_error > settings.tracking_angle_tolerance)) {
        status.phase = BLOCKED;
    }
}

fn void observe_ragdoll_recoveries(PhysicsWorld* world) @private {
    world.scene.@each(Ragdoll; entity, ragdoll) {
        observe_ragdoll_recovery(ragdoll);
    };
}

fn void publish_ragdoll_recovery(
    Scene* scene,
    Node* skin_node,
    Ragdoll* ragdoll,
    float alpha,
) @local {
    Node*[] joints = scene.get(skin_node, SkinBinding).joints;

    foreach (usz index, bone : ragdoll.recovery.bones) {
        if (!bone.active && !bone.completing) continue;
        maths::Transform pose = recovery_body_pose(bone.body);
        ragdoll.bone_nodes[index].set_world_pose(pose.position, pose.rotation);
    }

    foreach (joint : ragdoll.joint_order) {
        Node* node = joints[joint];
        Mat4 parent = parent_world_of(ragdoll, joints, joint);
        uint owner = ragdoll.joint_owner[joint];
        RecoveryBone* bone = &ragdoll.recovery.bones[owner];
        int mapped = ragdoll.joint_bone[joint];
        if (mapped >= 0 && (bone.active || bone.completing)) {
            Mat4 world = recovery_body_pose(bone.body).to_mat4().mul(ragdoll.joint_in_bone[mapped].to_mat4());
            node.local = relative(parent, world);
        } else if (bone.active || bone.completing) {
            node.local = ragdoll.recovery.captured ? ragdoll.recovery.targets[joint] : ragdoll.frozen[joint];
        } else {
            maths::Transform animation = ragdoll.recovery.captured ? ragdoll.recovery.animation[joint] : node.local;
            maths::Transform target = ragdoll.frozen[joint];
            if (ragdoll.bone_modes[owner] == SIMULATED) {
                if (try world = joint_target_world(
                    scene: scene,
                    ragdoll: ragdoll,
                    joint: joint,
                    alpha: alpha,
                )) {
                    target = relative(parent, world);
                } else {
                    target = animation;
                }
            }

            float weight = math::min(ragdoll.weight, 1.0f) * ragdoll.bone_weights[owner];
            node.local = recovery_blend(animation, target, weight);
        }

        ragdoll.joint_worlds[joint] = parent.mul(node.local.to_mat4());
    }
}

fn bool same_recovery_body(b3::BodyId first, b3::BodyId second) @local {
    return first.index1 == second.index1 && first.world0 == second.world0 && first.generation == second.generation;
}

fn bool same_recovery_joint(b3::JointId first, b3::JointId second) @local {
    return first.index1 == second.index1 && first.world0 == second.world0 && first.generation == second.generation;
}

fn void reconcile_recovery(Scene* scene, Ragdoll* ragdoll) @local {
    foreach (usz index, &bone : ragdoll.recovery.bones) {
        if (!bone.active && !bone.completing) continue;

        Node* node = ragdoll.bone_nodes[index];
        bool matching = scene.world.is_alive(bone.entity) && c3d::same_id(node.id, bone.entity)
          && scene.has(node, RigidBody) && bone.body.is_valid();
        if (matching) matching = same_recovery_body(scene.get(node, RigidBody).body, bone.body);
        if (matching && ragdoll.bone_parents[index] >= 0) {
            matching = scene.has(node, Joint) && bone.joint.is_valid();
            if (matching) matching = same_recovery_joint(scene.get(node, Joint).joint, bone.joint);
        }

        if (!matching) {
            bone.joint = {};
            cancel_recovery_bone(ragdoll, index);
        }
    }
}

fn void set_recovery_spring(
    Ragdoll* ragdoll,
    usz index,
    b3::JointId joint,
    JointKind kind,
    bool masked,
) @private {
    JointSpring drive = ragdoll.bone_drives[index];
    float hertz = drive.hertz * ragdoll.drive_strength;
    if (kind == SPHERICAL) {
        b3::SphericalJointId spherical = (b3::SphericalJointId)joint;
        spherical.enable_spring(!masked && drive.enabled);
        spherical.set_spring_hertz(masked ? 0 : hertz);
        spherical.set_spring_damping_ratio(drive.damping_ratio);
    } else if (kind == REVOLUTE) {
        b3::RevoluteJointId revolute = (b3::RevoluteJointId)joint;
        revolute.enable_spring(!masked && drive.enabled);
        revolute.set_spring_hertz(masked ? 0 : hertz);
        revolute.set_spring_damping_ratio(drive.damping_ratio);
    }
}

fn void cancel_recovery_bone(Ragdoll* ragdoll, usz index) @private {
    RecoveryBone* bone = &ragdoll.recovery.bones[index];
    if (!bone.active && !bone.completing) return;
    if (bone.body.is_valid() && bone.joint.is_valid()) set_recovery_spring(
        ragdoll: ragdoll,
        index: index,
        joint: bone.joint,
        kind: bone.joint_kind,
        masked: false,
    );

    if (bone.active) ragdoll.recovery.status.participating--;
    bone.active = false;
    bone.completing = false;
    if (!recovery_has_publication(ragdoll)) ragdoll.recovery.status = {};
}

fn void cancel_ragdoll_recovery(Ragdoll* ragdoll) @private {
    foreach (usz index, bone : ragdoll.recovery.bones) cancel_recovery_bone(ragdoll, index);
    ragdoll.recovery.status = {};
}

fn void cancel_ragdoll_recovery_for_node(PhysicsWorld* world, Node* node) @private {
    world.scene.@each(Ragdoll; entity, ragdoll) {
        foreach (usz index, bone : ragdoll.recovery.bones) {
            if ((bone.active || bone.completing)
                && c3d::same_id(bone.entity, node.id)) cancel_recovery_bone(ragdoll, index);
        }
    };
}

fn void suspend_ragdoll_recovery(PhysicsWorld* world) @private {
    world.scene.@each(Ragdoll; entity, ragdoll) {
        cancel_ragdoll_recovery(ragdoll);
    };
}

fn void shift_ragdoll_recovery(Scene* scene, Vec3 offset) @private {
    scene.@each(Ragdoll; entity, ragdoll) {
        foreach (&bone : ragdoll.recovery.bones) {
            if (bone.active || bone.completing) bone.target.position -= offset;
        }
        if (recovery_has_publication(ragdoll)) {
            Node*[] joints = scene.get(scene.node(entity), SkinBinding).joints;
            foreach (index, joint : joints) {
                if (joint.transform_space != TransformSpace.WORLD && joint.parent != scene.root) continue;
                ragdoll.frozen[index].position -= offset;
                ragdoll.recovery.animation[index].position -= offset;
                ragdoll.recovery.targets[index].position -= offset;
            }
        }
    };
}
