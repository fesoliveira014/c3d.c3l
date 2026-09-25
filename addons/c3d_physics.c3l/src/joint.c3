module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import b3;

<*
 Kind of a joint, one per box3d joint type.
*>
enum JointKind {
    DISTANCE,
    REVOLUTE,
    SPHERICAL,
    PRISMATIC,
    WELD,
    WHEEL,
    MOTOR,
    PARALLEL,
    FILTER,
}

<*
 Range a joint may not leave; radians for angles, meters for lengths.
*>
struct JointLimit {
    bool  enabled;
    float lower;
    float upper;
}

<*
 Spring toward a target; per-kind docstrings say what disabled means.
*>
struct JointSpring {
    bool  enabled;
    float hertz;
    float damping_ratio;
}

<*
 Drive toward a speed under a cap; force for linear kinds, torque for angular.
*>
struct JointMotor {
    bool  enabled;
    float speed;
    float max_force;
}

<*
 Rope or rod between two anchor points.
*>
struct DistanceJoint {
    float       length;
    JointLimit  range;
    JointSpring spring;
    float       lower_spring_force;
    float       upper_spring_force;
    JointMotor  motor;
}

<*
 Hinge about the anchor frame's z axis.
*>
struct RevoluteJoint {
    float       target_angle;
    JointLimit  angle;
    JointSpring spring;
    JointMotor  motor;
}

<*
 Ball joint; cone about the anchor frame's z, twist about the node frame's z.
*>
struct SphericalJoint {
    JointSpring spring;
    Quat        target_rotation;
    bool        enable_cone;
    float       cone_angle;
    JointLimit  twist;
    bool        enable_motor;
    Vec3        motor_velocity;
    float       max_motor_torque;
}

<*
 Slider along the anchor frame's x axis.
*>
struct PrismaticJoint {
    float       target_translation;
    JointLimit  translation;
    JointSpring spring;
    JointMotor  motor;
}

<*
 Attachment; a disabled spring is fully rigid.
*>
struct WeldJoint {
    JointSpring linear;
    JointSpring angular;
}

<*
 Wheel: suspension along and steering about the anchor x axis, spin about the node z.
 Steering disabled holds the wheel straight.
*>
struct WheelJoint {
    JointSpring suspension;
    JointLimit  suspension_limit;
    JointMotor  spin;
    JointSpring steering;
    float       target_steering_angle;
    float       max_steering_torque;
    JointLimit  steering_limit;
}

<*
 Drive the attached body's velocity relative to the anchor.
*>
struct MotorJoint {
    Vec3        linear_velocity;
    float       max_velocity_force;
    Vec3        angular_velocity;
    float       max_velocity_torque;
    JointSpring linear;
    float       max_spring_force;
    JointSpring angular;
    float       max_spring_torque;
}

<*
 Keep the two bodies' z axes parallel; a disabled spring constrains nothing.
*>
struct ParallelJoint {
    JointSpring spring;
    float       max_torque;
}

<*
 Joint attaching this node's body to the anchor body other; the member of kind applies.
*>
struct JointDesc {
    JointKind        kind;
    Entity           other;
    maths::Transform anchor_frame;      // in other's body space; unit scale
    maths::Transform frame;             // in this node's body space; unit scale
    bool             collide_connected;
    float            force_threshold;   // joint events above it
    float            torque_threshold;
    union {
        DistanceJoint  distance;
        RevoluteJoint  revolute;
        SphericalJoint spherical;
        PrismaticJoint prismatic;
        WeldJoint      weld;
        WheelJoint     wheel;
        MotorJoint     motor;
        ParallelJoint  parallel;
    }
}

<*
 Authored joint on the attached node; status is world-written.
*>
struct PhysicsJoint {
    JointDesc  desc;
    BodyStatus status;
    fault      failure;
}

<*
 Joint bound in the world; the removal hook destroys it.
*>
struct Joint {
    b3::JointId joint;
    JointKind   kind;
    Entity      other;
}

<*
 A joint whose force or torque crossed its threshold; nodes are frame borrows.
*>
struct JointEvent {
    Node* node;
    Node* other;
}

<*
 Constraint load and drift of a bound joint, world space.
 box3d's shared readings; per-kind getters through joint(node) are exact.
*>
struct JointState {
    Vec3  force;
    Vec3  torque;
    float linear_separation;
    float angular_separation;
}

<*
 Request a rebind from the current desc on the next update.
*>
fn void PhysicsJoint.mark_changed(&self) {
    self.status = PENDING;
}

<*
 Attach the joint; the next world update binds it once both bodies are live.
 @param [&in] node : "The attached body's node."
 @return? JOINT_EXISTS
 @require self.world.is_registered(PhysicsJoint), !same_entity(desc.other, node.id)
*>
fn void? Scene.add_physics_joint(&self, Node* node, JointDesc desc) {
    if (self.has(node, PhysicsJoint)) return JOINT_EXISTS~;
    self.add(node, (PhysicsJoint){ .desc = desc, .status = PENDING });
}

<*
 Attach the joint and bind it now; transactional.
 @param [&in] node : "The attached body's node."
 @return? JOINT_EXISTS, NO_BODY, b3::INVALID_DEFINITION, b3::INVALID_HANDLE
 @require !same_entity(desc.other, node.id)
*>
fn void? PhysicsWorld.add_joint(&self, Node* node, JointDesc desc) {
    Scene* scene = self.scene;
    scene.add_physics_joint(node, desc)!;
    defer catch scene.remove_component(node, PhysicsJoint);
    if (!scene.world.is_alive(desc.other)) return NO_BODY~;
    if (!scene.has(node, RigidBody) || !scene.has(scene.node(desc.other), RigidBody)) return NO_BODY~;
    bind_joint(self, node, scene.get(node, PhysicsJoint))!;
}

<*
 Remove the authored joint and its bound joint now.
 Invalidates PhysicsJoint and Joint pointers.
 @param [&in] node : "Carries the authored joint."
 @require self.scene.has(node, PhysicsJoint)
*>
fn void PhysicsWorld.remove_joint(&self, Node* node) {
    if (self.scene.has(node, Joint)) self.scene.remove_component(node, Joint);
    self.scene.remove_component(node, PhysicsJoint);
}

<*
 Push the node's joint desc into its bound joint.
 A changed kind or other rebinds on the next update instead.
 @param [&in] node : "Carries the authored joint."
 @require self.scene.has(node, PhysicsJoint)
*>
fn void PhysicsWorld.apply_joint(&self, Node* node) {
    Scene* scene = self.scene;
    if (!scene.has(node, Joint)) return;
    PhysicsJoint* physics_joint = scene.get(node, PhysicsJoint);
    Joint* joint = scene.get(node, Joint);
    // A removed anchor destroys the joint before the next update notices.
    bool stale = !joint.joint.is_valid();
    if (stale || physics_joint.desc.kind != joint.kind || !same_entity(physics_joint.desc.other, joint.other)) {
        scene.remove_component(node, Joint);
        physics_joint.status = PENDING;
        return;
    }
    push_joint(joint.joint, &physics_joint.desc);
    b3::joint_wake_bodies(joint.joint);
}

<*
 Constraint load and drift of the node's joint.
 @param [&in] node : "Carries the bound joint."
 @return? NO_JOINT
*>
fn JointState? PhysicsWorld.joint_state(&self, Node* node) {
    b3::JointId joint = self.joint(node)!;
    return {
        .force              = joint.constraint_force(),
        .torque             = joint.constraint_torque(),
        .linear_separation  = joint.linear_separation(),
        .angular_separation = joint.angular_separation(),
    };
}

<*
 The box3d joint of the node.
 @param [&in] node : "Carries the bound joint."
 @return? NO_JOINT
*>
fn b3::JointId? PhysicsWorld.joint(&self, Node* node) {
    if (!self.scene.has(node, Joint)) return NO_JOINT~;
    b3::JointId joint = self.scene.get(node, Joint).joint;
    if (!joint.is_valid()) return NO_JOINT~;
    return joint;
}

<*
 Joint of the kind toward other with box3d's defaults and identity frames.
*>
fn JointDesc default_joint_desc(JointKind kind, Entity other) {
    b3::JointDef base = b3::default_filter_joint_def().base;
    JointDesc desc = {
        .kind              = kind,
        .other             = other,
        .anchor_frame      = maths::TRANSFORM_IDENTITY,
        .frame             = maths::TRANSFORM_IDENTITY,
        .collide_connected = base.collide_connected,
        .force_threshold   = base.force_threshold,
        .torque_threshold  = base.torque_threshold,
    };
    switch (kind) {
        case DISTANCE:
            b3::DistanceJointDef def = b3::default_distance_joint_def();
            desc.distance = {
                .length             = def.length,
                .range              = { .enabled = def.enable_limit, .lower = def.min_length, .upper = def.max_length },
                .spring             = {
                    .enabled       = def.enable_spring,
                    .hertz         = def.hertz,
                    .damping_ratio = def.damping_ratio,
                },
                .lower_spring_force = def.lower_spring_force,
                .upper_spring_force = def.upper_spring_force,
                .motor              = {
                    .enabled   = def.enable_motor,
                    .speed     = def.motor_speed,
                    .max_force = def.max_motor_force,
                },
            };
        case REVOLUTE:
            b3::RevoluteJointDef def = b3::default_revolute_joint_def();
            desc.revolute = {
                .target_angle = def.target_angle,
                .angle        = { .enabled = def.enable_limit, .lower = def.lower_angle, .upper = def.upper_angle },
                .spring       = {
                    .enabled       = def.enable_spring,
                    .hertz         = def.hertz,
                    .damping_ratio = def.damping_ratio,
                },
                .motor        = {
                    .enabled   = def.enable_motor,
                    .speed     = def.motor_speed,
                    .max_force = def.max_motor_torque,
                },
            };
        case SPHERICAL:
            b3::SphericalJointDef def = b3::default_spherical_joint_def();
            desc.spherical = {
                .spring           = {
                    .enabled       = def.enable_spring,
                    .hertz         = def.hertz,
                    .damping_ratio = def.damping_ratio,
                },
                .target_rotation  = def.target_rotation,
                .enable_cone      = def.enable_cone_limit,
                .cone_angle       = def.cone_angle,
                .twist            = {
                    .enabled = def.enable_twist_limit,
                    .lower   = def.lower_twist_angle,
                    .upper   = def.upper_twist_angle,
                },
                .enable_motor     = def.enable_motor,
                .motor_velocity   = def.motor_velocity,
                .max_motor_torque = def.max_motor_torque,
            };
        case PRISMATIC:
            b3::PrismaticJointDef def = b3::default_prismatic_joint_def();
            desc.prismatic = {
                .target_translation = def.target_translation,
                .translation        = {
                    .enabled = def.enable_limit,
                    .lower   = def.lower_translation,
                    .upper   = def.upper_translation,
                },
                .spring             = {
                    .enabled       = def.enable_spring,
                    .hertz         = def.hertz,
                    .damping_ratio = def.damping_ratio,
                },
                .motor              = {
                    .enabled   = def.enable_motor,
                    .speed     = def.motor_speed,
                    .max_force = def.max_motor_force,
                },
            };
        case WELD:
            b3::WeldJointDef def = b3::default_weld_joint_def();
            desc.weld = {
                .linear  = spring_of(def.linear_hertz, def.linear_damping_ratio),
                .angular = spring_of(def.angular_hertz, def.angular_damping_ratio),
            };
        case WHEEL:
            b3::WheelJointDef def = b3::default_wheel_joint_def();
            desc.wheel = {
                .suspension            = {
                    .enabled       = def.enable_suspension_spring,
                    .hertz         = def.suspension_hertz,
                    .damping_ratio = def.suspension_damping_ratio,
                },
                .suspension_limit      = {
                    .enabled = def.enable_suspension_limit,
                    .lower   = def.lower_suspension_limit,
                    .upper   = def.upper_suspension_limit,
                },
                .spin                  = {
                    .enabled   = def.enable_spin_motor,
                    .speed     = def.spin_speed,
                    .max_force = def.max_spin_torque,
                },
                .steering              = {
                    .enabled       = def.enable_steering,
                    .hertz         = def.steering_hertz,
                    .damping_ratio = def.steering_damping_ratio,
                },
                .target_steering_angle = def.target_steering_angle,
                .max_steering_torque   = def.max_steering_torque,
                .steering_limit        = {
                    .enabled = def.enable_steering_limit,
                    .lower   = def.lower_steering_limit,
                    .upper   = def.upper_steering_limit,
                },
            };
        case MOTOR:
            b3::MotorJointDef def = b3::default_motor_joint_def();
            desc.motor = {
                .linear_velocity     = def.linear_velocity,
                .max_velocity_force  = def.max_velocity_force,
                .angular_velocity    = def.angular_velocity,
                .max_velocity_torque = def.max_velocity_torque,
                .linear              = spring_of(def.linear_hertz, def.linear_damping_ratio),
                .max_spring_force    = def.max_spring_force,
                .angular             = spring_of(def.angular_hertz, def.angular_damping_ratio),
                .max_spring_torque   = def.max_spring_torque,
            };
        case PARALLEL:
            b3::ParallelJointDef def = b3::default_parallel_joint_def();
            desc.parallel = {
                .spring     = spring_of(def.hertz, def.damping_ratio),
                .max_torque = def.max_torque,
            };
        case FILTER:
            break;
    }
    return desc;
}

fn void sync_joints(PhysicsWorld* world) @private {
    Scene* scene = world.scene;
    usz orphan_count;
    scene.@each(Joint; entity, joint) {
        bool orphan = !joint.joint.is_valid() || !scene.world.has(entity, PhysicsJoint);
        if (orphan) world.orphan_scratch[orphan_count++] = entity;
    };
    foreach (entity : world.orphan_scratch[:orphan_count]) {
        Node* node = scene.node(entity);
        scene.remove_component(node, Joint);
        if (scene.has(node, PhysicsJoint)) scene.get(node, PhysicsJoint).status = PENDING;
    }

    scene.@each(PhysicsJoint; entity, physics_joint) {
        if (physics_joint.status == PENDING) try_bind(world, scene.node(entity), physics_joint);
    };
}

fn void try_bind(PhysicsWorld* world, Node* node, PhysicsJoint* physics_joint) @local {
    Scene* scene = world.scene;
    Entity other = physics_joint.desc.other;
    if (!scene.world.is_alive(other)) {
        fail_joint(world, node, physics_joint, NO_BODY);
        return;
    }
    // RigidBody implies PhysicsBody once sync_bodies has run; a missing one means not yet built.
    if (!scene.has(node, RigidBody) || !scene.has(scene.node(other), RigidBody)) return;
    if (catch excuse = bind_joint(world, node, physics_joint)) fail_joint(world, node, physics_joint, excuse);
}

fn void fail_joint(
    PhysicsWorld* world,
    Node* node,
    PhysicsJoint* physics_joint,
    fault excuse,
) @local {
    physics_joint.status = FAILED;
    physics_joint.failure = excuse;
    push_failure(world, node, excuse);
}

// Replaces any joint still on the node, so mark_changed rebinds in place.
fn void? bind_joint(PhysicsWorld* world, Node* node, PhysicsJoint* physics_joint) @local {
    Scene* scene = world.scene;
    if (scene.has(node, Joint)) scene.remove_component(node, Joint);
    JointDesc* desc = &physics_joint.desc;
    // Every typed default shares one base, so a filter def's base is valid for all kinds.
    b3::JointDef base = b3::default_filter_joint_def().base;
    base.body_id_a = scene.get(scene.node(desc.other), RigidBody).body;
    base.body_id_b = scene.get(node, RigidBody).body;
    base.local_frame_a = body_frame(desc.anchor_frame);
    base.local_frame_b = body_frame(desc.frame);
    base.collide_connected = desc.collide_connected;
    base.force_threshold = desc.force_threshold;
    base.torque_threshold = desc.torque_threshold;
    base.user_data = pack_entity(node.id);

    b3::JointId joint;
    switch (desc.kind) {
        case DISTANCE:
            b3::DistanceJointDef def = b3::default_distance_joint_def();
            def.base = base;
            DistanceJoint* distance = &desc.distance;
            def.length = distance.length;
            def.enable_limit = distance.range.enabled;
            def.min_length = distance.range.lower;
            def.max_length = distance.range.upper;
            def.enable_spring = distance.spring.enabled;
            def.hertz = distance.spring.hertz;
            def.damping_ratio = distance.spring.damping_ratio;
            def.lower_spring_force = distance.lower_spring_force;
            def.upper_spring_force = distance.upper_spring_force;
            def.enable_motor = distance.motor.enabled;
            def.motor_speed = distance.motor.speed;
            def.max_motor_force = distance.motor.max_force;
            joint = b3::create_distance_joint(world.world, &def)!;
        case REVOLUTE:
            b3::RevoluteJointDef def = b3::default_revolute_joint_def();
            def.base = base;
            RevoluteJoint* revolute = &desc.revolute;
            def.target_angle = revolute.target_angle;
            def.enable_limit = revolute.angle.enabled;
            def.lower_angle = revolute.angle.lower;
            def.upper_angle = revolute.angle.upper;
            def.enable_spring = revolute.spring.enabled;
            def.hertz = revolute.spring.hertz;
            def.damping_ratio = revolute.spring.damping_ratio;
            def.enable_motor = revolute.motor.enabled;
            def.motor_speed = revolute.motor.speed;
            def.max_motor_torque = revolute.motor.max_force;
            joint = b3::create_revolute_joint(world.world, &def)!;
        case SPHERICAL:
            b3::SphericalJointDef def = b3::default_spherical_joint_def();
            def.base = base;
            SphericalJoint* spherical = &desc.spherical;
            def.enable_spring = spherical.spring.enabled;
            def.hertz = spherical.spring.hertz;
            def.damping_ratio = spherical.spring.damping_ratio;
            def.target_rotation = spherical.target_rotation;
            def.enable_cone_limit = spherical.enable_cone;
            def.cone_angle = spherical.cone_angle;
            def.enable_twist_limit = spherical.twist.enabled;
            def.lower_twist_angle = spherical.twist.lower;
            def.upper_twist_angle = spherical.twist.upper;
            def.enable_motor = spherical.enable_motor;
            def.motor_velocity = spherical.motor_velocity;
            def.max_motor_torque = spherical.max_motor_torque;
            joint = b3::create_spherical_joint(world.world, &def)!;
        case PRISMATIC:
            b3::PrismaticJointDef def = b3::default_prismatic_joint_def();
            def.base = base;
            PrismaticJoint* prismatic = &desc.prismatic;
            def.target_translation = prismatic.target_translation;
            def.enable_limit = prismatic.translation.enabled;
            def.lower_translation = prismatic.translation.lower;
            def.upper_translation = prismatic.translation.upper;
            def.enable_spring = prismatic.spring.enabled;
            def.hertz = prismatic.spring.hertz;
            def.damping_ratio = prismatic.spring.damping_ratio;
            def.enable_motor = prismatic.motor.enabled;
            def.motor_speed = prismatic.motor.speed;
            def.max_motor_force = prismatic.motor.max_force;
            joint = b3::create_prismatic_joint(world.world, &def)!;
        case WELD:
            b3::WeldJointDef def = b3::default_weld_joint_def();
            def.base = base;
            def.linear_hertz = spring_hertz(desc.weld.linear);
            def.linear_damping_ratio = desc.weld.linear.damping_ratio;
            def.angular_hertz = spring_hertz(desc.weld.angular);
            def.angular_damping_ratio = desc.weld.angular.damping_ratio;
            joint = b3::create_weld_joint(world.world, &def)!;
        case WHEEL:
            b3::WheelJointDef def = b3::default_wheel_joint_def();
            def.base = base;
            WheelJoint* wheel = &desc.wheel;
            def.enable_suspension_spring = wheel.suspension.enabled;
            def.suspension_hertz = wheel.suspension.hertz;
            def.suspension_damping_ratio = wheel.suspension.damping_ratio;
            def.enable_suspension_limit = wheel.suspension_limit.enabled;
            def.lower_suspension_limit = wheel.suspension_limit.lower;
            def.upper_suspension_limit = wheel.suspension_limit.upper;
            def.enable_spin_motor = wheel.spin.enabled;
            def.spin_speed = wheel.spin.speed;
            def.max_spin_torque = wheel.spin.max_force;
            def.enable_steering = wheel.steering.enabled;
            def.steering_hertz = wheel.steering.hertz;
            def.steering_damping_ratio = wheel.steering.damping_ratio;
            def.target_steering_angle = wheel.target_steering_angle;
            def.max_steering_torque = wheel.max_steering_torque;
            def.enable_steering_limit = wheel.steering_limit.enabled;
            def.lower_steering_limit = wheel.steering_limit.lower;
            def.upper_steering_limit = wheel.steering_limit.upper;
            joint = b3::create_wheel_joint(world.world, &def)!;
        case MOTOR:
            b3::MotorJointDef def = b3::default_motor_joint_def();
            def.base = base;
            MotorJoint* motor = &desc.motor;
            def.linear_velocity = motor.linear_velocity;
            def.max_velocity_force = motor.max_velocity_force;
            def.angular_velocity = motor.angular_velocity;
            def.max_velocity_torque = motor.max_velocity_torque;
            def.linear_hertz = spring_hertz(motor.linear);
            def.linear_damping_ratio = motor.linear.damping_ratio;
            def.max_spring_force = motor.max_spring_force;
            def.angular_hertz = spring_hertz(motor.angular);
            def.angular_damping_ratio = motor.angular.damping_ratio;
            def.max_spring_torque = motor.max_spring_torque;
            joint = b3::create_motor_joint(world.world, &def)!;
        case PARALLEL:
            b3::ParallelJointDef def = b3::default_parallel_joint_def();
            def.base = base;
            def.hertz = spring_hertz(desc.parallel.spring);
            def.damping_ratio = desc.parallel.spring.damping_ratio;
            def.max_torque = desc.parallel.max_torque;
            joint = b3::create_parallel_joint(world.world, &def)!;
        case FILTER:
            b3::FilterJointDef def = b3::default_filter_joint_def();
            def.base = base;
            joint = b3::create_filter_joint(world.world, &def)!;
    }

    scene.add(node, (Joint){ .joint = joint, .kind = desc.kind, .other = desc.other });
    physics_joint.status = LIVE;
}

// Joint.kind matches the box3d joint type, so each typed cast below is exact.
fn void push_joint(b3::JointId joint, JointDesc* desc) @local {
    joint.set_local_frame_a(body_frame(desc.anchor_frame));
    joint.set_local_frame_b(body_frame(desc.frame));
    joint.set_collide_connected(desc.collide_connected);
    joint.set_force_threshold(desc.force_threshold);
    joint.set_torque_threshold(desc.torque_threshold);

    switch (desc.kind) {
        case DISTANCE:
            b3::DistanceJointId distance = (b3::DistanceJointId)joint;
            DistanceJoint* values = &desc.distance;
            distance.set_length(values.length);
            distance.enable_limit(values.range.enabled);
            distance.set_length_range(values.range.lower, values.range.upper);
            distance.enable_spring(values.spring.enabled);
            distance.set_spring_hertz(values.spring.hertz);
            distance.set_spring_damping_ratio(values.spring.damping_ratio);
            distance.set_spring_force_range(values.lower_spring_force, values.upper_spring_force);
            distance.enable_motor(values.motor.enabled);
            distance.set_motor_speed(values.motor.speed);
            distance.set_max_motor_force(values.motor.max_force);
        case REVOLUTE:
            b3::RevoluteJointId revolute = (b3::RevoluteJointId)joint;
            RevoluteJoint* values = &desc.revolute;
            revolute.set_target_angle(values.target_angle);
            revolute.enable_limit(values.angle.enabled);
            revolute.set_limits(values.angle.lower, values.angle.upper);
            revolute.enable_spring(values.spring.enabled);
            revolute.set_spring_hertz(values.spring.hertz);
            revolute.set_spring_damping_ratio(values.spring.damping_ratio);
            revolute.enable_motor(values.motor.enabled);
            revolute.set_motor_speed(values.motor.speed);
            revolute.set_max_motor_torque(values.motor.max_force);
        case SPHERICAL:
            b3::SphericalJointId spherical = (b3::SphericalJointId)joint;
            SphericalJoint* values = &desc.spherical;
            spherical.enable_spring(values.spring.enabled);
            spherical.set_spring_hertz(values.spring.hertz);
            spherical.set_spring_damping_ratio(values.spring.damping_ratio);
            spherical.set_target_rotation(values.target_rotation);
            spherical.enable_cone_limit(values.enable_cone);
            spherical.set_cone_limit(values.cone_angle);
            spherical.enable_twist_limit(values.twist.enabled);
            spherical.set_twist_limits(values.twist.lower, values.twist.upper);
            spherical.enable_motor(values.enable_motor);
            spherical.set_motor_velocity(values.motor_velocity);
            spherical.set_max_motor_torque(values.max_motor_torque);
        case PRISMATIC:
            b3::PrismaticJointId prismatic = (b3::PrismaticJointId)joint;
            PrismaticJoint* values = &desc.prismatic;
            prismatic.set_target_translation(values.target_translation);
            prismatic.enable_limit(values.translation.enabled);
            prismatic.set_limits(values.translation.lower, values.translation.upper);
            prismatic.enable_spring(values.spring.enabled);
            prismatic.set_spring_hertz(values.spring.hertz);
            prismatic.set_spring_damping_ratio(values.spring.damping_ratio);
            prismatic.enable_motor(values.motor.enabled);
            prismatic.set_motor_speed(values.motor.speed);
            prismatic.set_max_motor_force(values.motor.max_force);
        case WELD:
            b3::WeldJointId weld = (b3::WeldJointId)joint;
            weld.set_linear_hertz(spring_hertz(desc.weld.linear));
            weld.set_linear_damping_ratio(desc.weld.linear.damping_ratio);
            weld.set_angular_hertz(spring_hertz(desc.weld.angular));
            weld.set_angular_damping_ratio(desc.weld.angular.damping_ratio);
        case WHEEL:
            b3::WheelJointId wheel = (b3::WheelJointId)joint;
            WheelJoint* values = &desc.wheel;
            wheel.enable_suspension(values.suspension.enabled);
            wheel.set_suspension_hertz(values.suspension.hertz);
            wheel.set_suspension_damping_ratio(values.suspension.damping_ratio);
            wheel.enable_suspension_limit(values.suspension_limit.enabled);
            wheel.set_suspension_limits(values.suspension_limit.lower, values.suspension_limit.upper);
            wheel.enable_spin_motor(values.spin.enabled);
            wheel.set_spin_motor_speed(values.spin.speed);
            wheel.set_max_spin_torque(values.spin.max_force);
            wheel.enable_steering(values.steering.enabled);
            wheel.set_steering_hertz(values.steering.hertz);
            wheel.set_steering_damping_ratio(values.steering.damping_ratio);
            wheel.set_target_steering_angle(values.target_steering_angle);
            wheel.set_max_steering_torque(values.max_steering_torque);
            wheel.enable_steering_limit(values.steering_limit.enabled);
            wheel.set_steering_limits(values.steering_limit.lower, values.steering_limit.upper);
        case MOTOR:
            b3::MotorJointId motor = (b3::MotorJointId)joint;
            MotorJoint* values = &desc.motor;
            motor.set_linear_velocity(values.linear_velocity);
            motor.set_max_velocity_force(values.max_velocity_force);
            motor.set_angular_velocity(values.angular_velocity);
            motor.set_max_velocity_torque(values.max_velocity_torque);
            motor.set_linear_hertz(spring_hertz(values.linear));
            motor.set_linear_damping_ratio(values.linear.damping_ratio);
            motor.set_max_spring_force(values.max_spring_force);
            motor.set_angular_hertz(spring_hertz(values.angular));
            motor.set_angular_damping_ratio(values.angular.damping_ratio);
            motor.set_max_spring_torque(values.max_spring_torque);
        case PARALLEL:
            b3::ParallelJointId parallel = (b3::ParallelJointId)joint;
            parallel.set_spring_hertz(spring_hertz(desc.parallel.spring));
            parallel.set_spring_damping_ratio(desc.parallel.spring.damping_ratio);
            parallel.set_max_torque(desc.parallel.max_torque);
        case FILTER:
            break;
    }
}

// A destroyed body has already destroyed its joints.
fn void remove_joint_component(Entity entity, void* component, void* user) @private {
    Joint* joint = component;
    if (joint.joint.is_valid()) b3::destroy_joint(joint.joint, true);
}

fn b3::Transform body_frame(maths::Transform frame) @local => { .p = frame.position, .q = frame.rotation };

// WELD, MOTOR and PARALLEL have no enable flag: hertz 0 is their off switch.
fn float spring_hertz(JointSpring spring) @local => spring.enabled ? spring.hertz : 0;

fn JointSpring spring_of(float hertz, float damping_ratio) @local {
    return { .enabled = hertz > 0, .hertz = hertz, .damping_ratio = damping_ratio };
}

fn bool same_entity(Entity first, Entity second) @local {
    return first.index == second.index && first.generation == second.generation;
}
