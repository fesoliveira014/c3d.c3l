module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import c3d::serial;

struct BodyAuthoring @private {
    BodyDesc body;
    ColliderDesc[] colliders;
}

struct JointAuthoring @private {
    JointKind kind;
    serial::NodeReference other;
    maths::Transform anchor_frame;
    maths::Transform frame;
    bool collide_connected;
    float force_threshold;
    float torque_threshold;
    DistanceJoint[] distance;
    RevoluteJoint[] revolute;
    SphericalJoint[] spherical;
    PrismaticJoint[] prismatic;
    WeldJoint[] weld;
    WheelJoint[] wheel;
    MotorJoint[] motor;
    ParallelJoint[] parallel;
}

struct BuoyancyAuthoring @private {
    float fluid_density;
    float linear_drag;
}

<*
 Register physics authoring codecs and transient native mirrors.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? register_serial_codecs() {
    register_serial_value_types()!;
    describe::register_reflected(BodyAuthoring)!;
    describe::register_reflected(JointAuthoring)!;
    describe::register_reflected(BuoyancyAuthoring)!;
    register_physics_value(BodyAuthoring, 0xed9972ba2248fa8b, &defaults_body_authoring)!;
    register_physics_value(JointAuthoring, 0x448b33882e32ee3e, &defaults_joint_authoring)!;
    register_physics_value(BuoyancyAuthoring, 0xf4af0c421ff3e4fa, &defaults_buoyancy_authoring)!;
    serial::register_described_owner(PhysicsBody, BodyAuthoring, {
        .name = "physics_body",
        .phase = VALUE,
        .project = &project_body,
        .validate = &validate_body,
        .attach = &attach_body,
    })!;
    serial::register_described_owner(PhysicsJoint, JointAuthoring, {
        .name = "physics_joint",
        .phase = REFERENCES,
        .project = &project_joint,
        .validate = &validate_joint,
        .attach = &attach_joint,
    })!;
    serial::register_described_owner(Buoyancy, BuoyancyAuthoring, {
        .name = "buoyancy",
        .project = &project_buoyancy,
        .attach = &attach_buoyancy,
    })!;
    serial::register_described(Wind, { .name = "wind" })!;
    serial::register_described(Force, { .name = "force" })!;
    serial::register_transient(RigidBody)!;
    serial::register_transient(Joint)!;
    register_cloth_codec()!;
    register_ragdoll_codec()!;
    register_breakable_codec()!;
}

fn void defaults_body_authoring(void* value) @private {
    *(BodyAuthoring*)value = { .body = default_body_desc() };
}

fn void defaults_joint_authoring(void* value) @private {
    JointDesc defaults = default_joint_desc(DISTANCE, {});
    *(JointAuthoring*)value = {
        .other = { .template_index = serial::INDEX_NONE },
        .anchor_frame = defaults.anchor_frame,
        .frame = defaults.frame,
        .collide_connected = defaults.collide_connected,
        .force_threshold = defaults.force_threshold,
        .torque_threshold = defaults.torque_threshold,
    };
}

fn void defaults_buoyancy_authoring(void* value) @private {
    *(BuoyancyAuthoring*)value = { .fluid_density = DEFAULT_FLUID_DENSITY };
}

fn void? project_body(void* component, void* value, serial::WriteContext* context) @private {
    PhysicsBody* body = component;
    if (!body.colliders.len) return c3d::INVALID_ARGUMENT~;
    BodyAuthoring* authoring = value;
    *authoring = { .body = body.body, .colliders = body.colliders };
}

fn void? validate_body(void* value, serial::ReadContext* context) @private {
    if (!((BodyAuthoring*)value).colliders.len) return c3d::INVALID_ARGUMENT~;
}

fn void? attach_body(void* value, serial::ReadContext* context) @private {
    BodyAuthoring* source = value;
    context.scene.add(context.node, try_copy_physics_body(context.scene.allocator, source.body, source.colliders)!);
}

fn void? project_joint(void* component, void* value, serial::WriteContext* context) @private {
    JointDesc* source = &((PhysicsJoint*)component).desc;
    if (c3d::same_id(source.other, context.node.id)) return c3d::INVALID_ARGUMENT~;
    JointAuthoring* joint = value;
    *joint = {
        .kind = source.kind,
        .other = context.make_entity_reference(source.other, true, NO_BODY)!,
        .anchor_frame = source.anchor_frame,
        .frame = source.frame,
        .collide_connected = source.collide_connected,
        .force_threshold = source.force_threshold,
        .torque_threshold = source.torque_threshold,
    };
    switch (source.kind) {
        case DISTANCE: joint.distance = (&source.distance)[:1];
        case REVOLUTE: joint.revolute = (&source.revolute)[:1];
        case SPHERICAL: joint.spherical = (&source.spherical)[:1];
        case PRISMATIC: joint.prismatic = (&source.prismatic)[:1];
        case WELD: joint.weld = (&source.weld)[:1];
        case WHEEL: joint.wheel = (&source.wheel)[:1];
        case MOTOR: joint.motor = (&source.motor)[:1];
        case PARALLEL: joint.parallel = (&source.parallel)[:1];
        case FILTER: break;
    }
}

fn JointDesc? restore_joint(JointAuthoring* value, serial::ReadContext* context) @private {
    Node* other = context.resolve_node_reference(value.other, true, NO_BODY)!;
    if (other == context.node) return c3d::INVALID_ARGUMENT~;
    JointDesc joint = default_joint_desc(value.kind, other.id);
    joint.anchor_frame = value.anchor_frame;
    joint.frame = value.frame;
    joint.collide_connected = value.collide_connected;
    joint.force_threshold = value.force_threshold;
    joint.torque_threshold = value.torque_threshold;
    if (value.distance.len > 1 || (value.distance.len && value.kind != DISTANCE)) return c3d::INVALID_ARGUMENT~;
    if (value.revolute.len > 1 || (value.revolute.len && value.kind != REVOLUTE)) return c3d::INVALID_ARGUMENT~;
    if (value.spherical.len > 1 || (value.spherical.len && value.kind != SPHERICAL)) return c3d::INVALID_ARGUMENT~;
    if (value.prismatic.len > 1 || (value.prismatic.len && value.kind != PRISMATIC)) return c3d::INVALID_ARGUMENT~;
    if (value.weld.len > 1 || (value.weld.len && value.kind != WELD)) return c3d::INVALID_ARGUMENT~;
    if (value.wheel.len > 1 || (value.wheel.len && value.kind != WHEEL)) return c3d::INVALID_ARGUMENT~;
    if (value.motor.len > 1 || (value.motor.len && value.kind != MOTOR)) return c3d::INVALID_ARGUMENT~;
    if (value.parallel.len > 1 || (value.parallel.len && value.kind != PARALLEL)) return c3d::INVALID_ARGUMENT~;
    switch (value.kind) {
        case DISTANCE: if (value.distance.len) joint.distance = value.distance[0];
        case REVOLUTE: if (value.revolute.len) joint.revolute = value.revolute[0];
        case SPHERICAL: if (value.spherical.len) joint.spherical = value.spherical[0];
        case PRISMATIC: if (value.prismatic.len) joint.prismatic = value.prismatic[0];
        case WELD: if (value.weld.len) joint.weld = value.weld[0];
        case WHEEL: if (value.wheel.len) joint.wheel = value.wheel[0];
        case MOTOR: if (value.motor.len) joint.motor = value.motor[0];
        case PARALLEL: if (value.parallel.len) joint.parallel = value.parallel[0];
        case FILTER: break;
    }
    return joint;
}

fn void? validate_joint(void* value, serial::ReadContext* context) @private {
    (void)restore_joint((JointAuthoring*)value, context)!;
}

fn void? attach_joint(void* value, serial::ReadContext* context) @private {
    context.scene.add_physics_joint(context.node, restore_joint((JointAuthoring*)value, context)!)!;
}

fn void? project_buoyancy(void* component, void* value, serial::WriteContext* context) @private {
    Buoyancy* buoyancy = component;
    *(BuoyancyAuthoring*)value = { .fluid_density = buoyancy.fluid_density, .linear_drag = buoyancy.linear_drag };
}

fn void? attach_buoyancy(void* value, serial::ReadContext* context) @private {
    BuoyancyAuthoring* source = value;
    context.scene.add(context.node, (Buoyancy){ .fluid_density = source.fluid_density, .linear_drag = source.linear_drag });
}
