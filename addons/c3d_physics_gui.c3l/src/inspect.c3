module c3d::gui @feat(C3D_PHYSICS_GUI);

import c3d;
import c3d::gui::inspect;
import c3d::physics;
import imgui;
import std::math;

const float COLLIDER_SIZE_MIN @local = 0.001f;
const ZString EDITED_IN_PANEL @private = "Edit in the Physics panel.";
const ZString[3] BODY_KIND_NAMES @local = { "static", "kinematic", "dynamic" };

<*
 Register the physics component inspectors; call after register_physics and create_gui_renderer.
*>
fn void expose_physics_components() {
    expose(PhysicsBody, &physics_body_inspector);
    expose(RigidBody, &rigid_body_inspector);
    expose(PhysicsJoint, &physics_joint_inspector);
    expose(Joint, &joint_inspector);
    expose(Ragdoll, &ragdoll_inspector);
    expose(Wind);
    expose(Force);
    $if $feat(C3D_PHYSICS_GUI_CHARACTER):
        expose_character_inspector();
    $endif
}

fn bool physics_body_inspector(void* component) @local {
    PhysicsBody* body = component;
    bool changed = edit_body_desc(&body.body);
    foreach (index, &collider : body.colliders) {
        imgui::push_id_int((int)index);
        imgui::separator_text(@enum_name(ColliderKind, collider.kind));
        changed |= edit_collider(collider);
        imgui::pop_id();
    }
    if (changed) body.mark_changed();
    imgui::text("Status: %s", @enum_name(BodyStatus, body.status));
    return changed;
}

fn bool edit_body_desc(BodyDesc* desc) @local {
    int kind = (int)desc.kind.ordinal;
    bool changed = imgui::combo_char("Kind", &kind, &BODY_KIND_NAMES[0], BodyKind::len);
    if (changed) desc.kind = BodyKind::from_ordinal(kind);
    changed |= imgui::drag_float3("Linear velocity", (float*)&desc.linear_velocity);
    changed |= imgui::drag_float3("Angular velocity", (float*)&desc.angular_velocity);
    changed |= imgui::drag_float("Linear damping", &desc.linear_damping);
    changed |= imgui::drag_float("Angular damping", &desc.angular_damping);
    changed |= imgui::drag_float("Gravity scale", &desc.gravity_scale);
    changed |= imgui::checkbox("Allow sleep", &desc.allow_sleep);
    changed |= imgui::checkbox("Bullet", &desc.bullet);
    return changed;
}

fn bool edit_collider(ColliderDesc* collider) @local {
    bool changed;
    switch (collider.kind) {
        case SPHERE:
            changed |= edit_size("Radius", &collider.radius);
        case CAPSULE:
            changed |= edit_size("Radius", &collider.radius);
            changed |= edit_size("Half height", &collider.half_height);
        case BOX:
            changed |= imgui::drag_float3("Half extents", (float*)&collider.half_extents);
        default:
            break;
    }
    changed |= imgui::drag_float3("Offset", (float*)&collider.local.position);
    changed |= imgui::drag_float("Density", &collider.density);
    changed |= imgui::drag_float("Friction", &collider.material.friction);
    changed |= imgui::drag_float("Restitution", &collider.material.restitution);
    changed |= imgui::checkbox("Sensor", &collider.sensor);
    changed |= imgui::input_scalar("Category", imgui::DATA_TYPE_U64, &collider.filter.category);
    changed |= imgui::input_scalar("Mask", imgui::DATA_TYPE_U64, &collider.filter.mask);
    changed |= imgui::input_scalar("Group", imgui::DATA_TYPE_S32, &collider.filter.group);
    return changed;
}

fn bool edit_size(ZString label, float* value) @local {
    if (!imgui::drag_float(label, value)) return false;
    *value = math::max(*value, COLLIDER_SIZE_MIN);
    return true;
}

fn bool rigid_body_inspector(void* component) @local {
    RigidBody* body = component;
    imgui::text("Kind: %s", @enum_name(BodyKind, body.kind));
    Vec3 position = body.current.position;
    imgui::text("Position: %.3f %.3f %.3f", position.x, position.y, position.z);
    imgui::text("Colliders: %u", (uint)body.colliders.len);
    return false;
}

fn bool physics_joint_inspector(void* component) @local {
    PhysicsJoint* joint = component;
    JointDesc* desc = &joint.desc;
    imgui::text("Kind: %s", @enum_name(JointKind, desc.kind));
    bool changed = imgui::checkbox("Collide connected", &desc.collide_connected);
    changed |= imgui::drag_float("Force threshold", &desc.force_threshold);
    changed |= imgui::drag_float("Torque threshold", &desc.torque_threshold);
    switch (desc.kind) {
        case DISTANCE:  changed |= inspect::inspect{DistanceJoint}(&desc.distance);
        case REVOLUTE:  changed |= inspect::inspect{RevoluteJoint}(&desc.revolute);
        case SPHERICAL: changed |= inspect::inspect{SphericalJoint}(&desc.spherical);
        case PRISMATIC: changed |= inspect::inspect{PrismaticJoint}(&desc.prismatic);
        case WELD:      changed |= inspect::inspect{WeldJoint}(&desc.weld);
        case WHEEL:     changed |= inspect::inspect{WheelJoint}(&desc.wheel);
        case MOTOR:     changed |= inspect::inspect{MotorJoint}(&desc.motor);
        case PARALLEL:  changed |= inspect::inspect{ParallelJoint}(&desc.parallel);
        case FILTER:    break;
    }
    if (changed) joint.mark_changed();
    imgui::text("Status: %s", @enum_name(BodyStatus, joint.status));
    return changed;
}

fn bool joint_inspector(void* component) @local {
    Joint* joint = component;
    imgui::text("Kind: %s", @enum_name(JointKind, joint.kind));
    imgui::text("Other: %u", joint.other.index);
    return false;
}

fn bool ragdoll_inspector(void* component) @local {
    Ragdoll* ragdoll = component;
    imgui::text("Bones: %u", (uint)ragdoll.bone_nodes.len);
    imgui::text("Weight %.2f, drive strength %.2f", ragdoll.weight, ragdoll.drive_strength);
    foreach (bone, mode : ragdoll.bone_modes) {
        imgui::text("Bone %u: %s at %.2f", (uint)bone, @enum_name(RagdollMode, mode), ragdoll.bone_weights[bone]);
    }
    if (ragdoll.recoveries) {
        imgui::text("Last recovery: %s (%u)", @enum_name(RagdollFacing, ragdoll.last_facing), ragdoll.recoveries);
    }
    imgui::text_unformatted(EDITED_IN_PANEL);
    return false;
}
