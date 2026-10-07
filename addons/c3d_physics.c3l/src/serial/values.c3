module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::describe;
import c3d::serial;

<*
 Register shared physics field layouts and semantic defaults.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION, c3d::INVALID_ARGUMENT
*>
fn void? register_serial_value_types() {
    serial::register_core_value_types()!;
    describe::register_reflected(CollisionFilter)!;
    describe::register_reflected(HeightField)!;
    describe::register_type(SurfaceMaterialDesc, &describe_surface_material)!;
    describe::register_reflected(MotionLocks)!;
    describe::register_reflected(CompoundChild)!;
    describe::register_reflected(ColliderDesc)!;
    describe::register_reflected(BodyDesc)!;
    describe::register_reflected(JointLimit)!;
    describe::register_reflected(JointSpring)!;
    describe::register_reflected(JointMotor)!;
    describe::register_reflected(DistanceJoint)!;
    describe::register_reflected(RevoluteJoint)!;
    describe::register_reflected(SphericalJoint)!;
    describe::register_reflected(PrismaticJoint)!;
    describe::register_reflected(WeldJoint)!;
    describe::register_reflected(WheelJoint)!;
    describe::register_reflected(MotorJoint)!;
    describe::register_reflected(ParallelJoint)!;
    describe::register_reflected(Wind)!;
    describe::register_reflected(Force)!;
    register_physics_value(CollisionFilter, 0xada86db77bf9d58b, &defaults_collision_filter)!;
    register_physics_value(HeightField, 0x103663e5d599fb64, &defaults_height_field)!;
    register_physics_value(SurfaceMaterialDesc, 0xe6419631c7d375d7, &defaults_surface_material_desc)!;
    register_physics_value(MotionLocks, 0x9b64713c5cbd30ad, &defaults_motion_locks)!;
    register_physics_value(CompoundChild, 0x8be77500d57a8de3, &defaults_compound_child)!;
    register_physics_value(ColliderDesc, 0xdd2a19f055eaf423, &defaults_collider_desc)!;
    register_physics_value(BodyDesc, 0x9774ae43021a41d2, &defaults_body_desc)!;
    register_physics_value(JointLimit, 0xdb2af63ad71e7cd9, &defaults_joint_limit)!;
    register_physics_value(JointSpring, 0x3c184d0bf17ef2c3, &defaults_joint_spring)!;
    register_physics_value(JointMotor, 0x76ed03e3dd552785, &defaults_joint_motor)!;
    register_physics_value(DistanceJoint, 0x1f60cf568207d230, &defaults_distance_joint)!;
    register_physics_value(RevoluteJoint, 0xa94827628aeec608, &defaults_revolute_joint)!;
    register_physics_value(SphericalJoint, 0x5bea356af92f0d09, &defaults_spherical_joint)!;
    register_physics_value(PrismaticJoint, 0x4b63122b5e28dae8, &defaults_prismatic_joint)!;
    register_physics_value(WeldJoint, 0x7c18523f40d823db, &defaults_weld_joint)!;
    register_physics_value(WheelJoint, 0x72f6d91e7ea37971, &defaults_wheel_joint)!;
    register_physics_value(MotorJoint, 0x7fd568aecd165537, &defaults_motor_joint)!;
    register_physics_value(ParallelJoint, 0x1e3e56ae30f683c2, &defaults_parallel_joint)!;
    register_physics_value(Wind, 0xbab297950692c4a2, &defaults_wind)!;
    register_physics_value(Force, 0x6333ff51fe9956a4, &defaults_force)!;
}

macro void? register_physics_value($Type, ulong layout, serial::DefaultsFn defaults) @private {
    serial::register_described_type(
        $Type: $Type,
        version: 1,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void defaults_collision_filter(void* value) @private => *(CollisionFilter*)value = FILTER_ALL;
fn void defaults_height_field(void* value) @private => *(HeightField*)value = {};
fn void defaults_surface_material_desc(void* value) @private => *(SurfaceMaterialDesc*)value = default_surface_material();
fn void defaults_motion_locks(void* value) @private => *(MotionLocks*)value = {};
fn void defaults_compound_child(void* value) @private => *(CompoundChild*)value = default_compound_child(SPHERE);
fn void defaults_collider_desc(void* value) @private => *(ColliderDesc*)value = default_collider_desc(SPHERE);
fn void defaults_body_desc(void* value) @private => *(BodyDesc*)value = default_body_desc();
fn void defaults_joint_limit(void* value) @private => *(JointLimit*)value = {};
fn void defaults_joint_spring(void* value) @private => *(JointSpring*)value = {};
fn void defaults_joint_motor(void* value) @private => *(JointMotor*)value = {};
fn void defaults_distance_joint(void* value) @private => *(DistanceJoint*)value = default_joint_desc(DISTANCE, {}).distance;
fn void defaults_revolute_joint(void* value) @private => *(RevoluteJoint*)value = default_joint_desc(REVOLUTE, {}).revolute;
fn void defaults_spherical_joint(void* value) @private => *(SphericalJoint*)value = default_joint_desc(SPHERICAL, {}).spherical;
fn void defaults_prismatic_joint(void* value) @private => *(PrismaticJoint*)value = default_joint_desc(PRISMATIC, {}).prismatic;
fn void defaults_weld_joint(void* value) @private => *(WeldJoint*)value = default_joint_desc(WELD, {}).weld;
fn void defaults_wheel_joint(void* value) @private => *(WheelJoint*)value = default_joint_desc(WHEEL, {}).wheel;
fn void defaults_motor_joint(void* value) @private => *(MotorJoint*)value = default_joint_desc(MOTOR, {}).motor;
fn void defaults_parallel_joint(void* value) @private => *(ParallelJoint*)value = default_joint_desc(PARALLEL, {}).parallel;
fn void defaults_wind(void* value) @private => *(Wind*)value = {};
fn void defaults_force(void* value) @private => *(Force*)value = {};

fn bool? describe_surface_material(describe::Visitor* visitor, void* raw) @private {
    SurfaceMaterialDesc* value = raw;
    bool changed;
    changed = describe::@field(visitor, "friction", value.friction)! || changed;
    changed = describe::@field(visitor, "restitution", value.restitution)! || changed;
    changed = describe::@field(visitor, "rolling_resistance", value.rolling_resistance)! || changed;
    changed = describe::@field(visitor, "tangent_velocity", value.tangent_velocity)! || changed;
    changed = describe::@field(visitor, "id", *(ulong*)&value.id)! || changed;
    return changed;
}
