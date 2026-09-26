module c3d::gui;

import c3d;
import c3d::anim;
import c3d::anim::ik;
import c3d::camera;
import c3d::ecs;
import c3d::ecs::store;
import c3d::gui::inspect;
import c3d::light;
import c3d::maths;
import c3d::scene;
import imgui;
import std::math;

<*
 Draw widgets for one component and report whether any edited it.
*>
alias InspectFn = fn bool (void* component);

<*
 Registered inspector of one component type.
*>
struct Inspector {
    ZString   name;
    InspectFn inspect;
}

const float CAMERA_FOV_MIN_DEGREES @local = 1;
const float CAMERA_FOV_MAX_DEGREES @local = 179;
const float CONE_MAX_DEGREES @local = 90;
const float IK_ANGLE_MAX_DEGREES @local = 180;
const float CAMERA_MIN_NEAR @local = 0.0001f;
const float MIN_POSITIVE @local = 0.0001f;

Inspector[ecs::MAX_COMPONENT_TYPES] inspectors @local;

<*
 Register an inspector for a registered component type; later calls replace earlier ones.
 @param override : "Replaces the generic reflected inspector when non-null."
 @require store::slot{$Type} != 0
*>
macro void expose($Type, InspectFn override = null) {
    inspectors[store::slot{$Type} - 1] = {
        .name    = $Type::name,
        .inspect = override ? override : &inspect::inspect{$Type},
    };
}

<*
 Registered inspector of a type slot; a zero function means none.
*>
fn Inspector inspector_of(uint slot) {
    return inspectors[slot];
}

<*
 Name of an enum value at runtime.
*>
macro ZString @enum_name($Enum, value) {
    ZString[$Enum::len] names;
    $foreach $index, $name : $Enum::names:
        names[$index] = $name;
    $endforeach
    return names[value.ordinal];
}

<*
 Draw the widget of one reflected struct member and report whether it changed.
 @param [&inout] raw : "Points at the struct that owns the member."
*>
macro bool @field_widget($member, void* raw) {
    void* field = (char*)raw + $member.offset;
    ZString label = $member.name;
    $switch:
        $case $member.type == Quat::typeid:
            return quat_widget(label, (Quat*)field);
        $case $member.type == Aabb::typeid:
            Aabb* bounds = (Aabb*)field;
            bool changed = imgui::drag_float3(label, (float*)&bounds.min);
            imgui::same_line();
            return imgui::drag_float3("max", (float*)&bounds.max) || changed;
        $case $member.type.kind == TypeKind.TYPEDEF && $member.type.size == c3d::Id::size:
            id_text(label, *(c3d::Id*)field);
            return false;
        $case $member.type.kind == TypeKind.FLOAT:
            return imgui::drag_float(label, (float*)field);
        $case $member.type.kind == TypeKind.BOOL:
            return imgui::checkbox(label, (bool*)field);
        $case $member.type.kind == TypeKind.SIGNED_INT && $member.type.size == int::size:
            return imgui::input_scalar(label, imgui::DATA_TYPE_S32, field);
        $case $member.type.kind == TypeKind.SIGNED_INT && $member.type.size == long::size:
            return imgui::input_scalar(label, imgui::DATA_TYPE_S64, field);
        $case $member.type.kind == TypeKind.UNSIGNED_INT && $member.type.size == uint::size:
            return imgui::input_scalar(label, imgui::DATA_TYPE_U32, field);
        $case $member.type.kind == TypeKind.UNSIGNED_INT && $member.type.size == ulong::size:
            return imgui::input_scalar(label, imgui::DATA_TYPE_U64, field);
        $case $member.type.kind == TypeKind.VECTOR:
            var $Inner = $member.type.inner;
            $switch:
                $case $Inner::typeid == float::typeid && $member.type.len == 2:
                    return imgui::drag_float2(label, (float*)field);
                $case $Inner::typeid == float::typeid && $member.type.len == 3:
                    return imgui::drag_float3(label, (float*)field);
                $case $Inner::typeid == float::typeid && $member.type.len == 4:
                    return imgui::drag_float4(label, (float*)field);
                $default:
                    return false;
            $endswitch
        $case $member.type.kind == TypeKind.ENUM && $member.type.size == int::size:
            ZString[$member.type.len] names;
            $foreach $index, $name : $member.type.names:
                names[$index] = $name;
            $endforeach
            return imgui::combo_char(label, (int*)field, &names, (int)names.len);
        $case $member.type.kind == TypeKind.SLICE:
            var $Element = $member.type.inner;
            $if $Element::typeid == float::typeid:
                return weight_sliders(label, *(float[]*)field);
            $else
                imgui::text("%s: %llu entries", label, (ulong)(*(void*[]*)field).len);
                return false;
            $endif
        $default:
            return false;
    $endswitch
}

fn bool quat_widget(ZString label, Quat* rotation) @local {
    Vec3 angles = rotation.to_euler();
    Vec3 degrees = { math::rad_to_deg(angles.x), math::rad_to_deg(angles.y), math::rad_to_deg(angles.z) };
    if (!imgui::drag_float3(label, (float*)&degrees)) return false;
    *rotation = quaternion::from_euler{float}(
        math::deg_to_rad(degrees.x),
        math::deg_to_rad(degrees.y),
        math::deg_to_rad(degrees.z)
    ).normalize();
    return true;
}

fn void id_text(ZString label, c3d::Id id) @local {
    imgui::text("%s: %u:%u", label, id.index, id.generation);
}

fn bool weight_sliders(ZString label, float[] weights) @local {
    bool changed;
    imgui::push_id_str(label, null);
    defer imgui::pop_id();
    foreach (index, &weight : weights) {
        imgui::push_id_int((int)index);
        defer imgui::pop_id();
        changed = imgui::slider_float(label, weight, 0, 1) || changed;
    }
    return changed;
}

fn bool camera_inspector(void* component) @local {
    Camera* camera = (Camera*)component;
    bool changed;

    int projection = camera.projection.ordinal;
    ZString[2] projections = { "Perspective", "Orthographic" };
    if (imgui::combo_char("Projection", &projection, &projections, 2)) {
        camera.projection = Projection::from_ordinal((usz)projection);
        changed = true;
    }

    float fov_degrees = math::rad_to_deg(camera.fov_y);
    if (imgui::slider_float("Vertical fov (deg)", &fov_degrees, CAMERA_FOV_MIN_DEGREES, CAMERA_FOV_MAX_DEGREES)) {
        camera.fov_y = math::deg_to_rad(fov_degrees);
        changed = true;
    }
    changed = positive_drag("Orthographic height", &camera.ortho_height) || changed;
    changed = positive_drag("Near", &camera.near, CAMERA_MIN_NEAR) || changed;
    if (imgui::drag_float("Far (0 = infinite)", &camera.far)) {
        camera.far = math::max(camera.far, 0.0f);
        changed = true;
    }
    changed = positive_drag("Exposure", &camera.exposure) || changed;
    changed = imgui::input_scalar("Layers", imgui::DATA_TYPE_U32, &camera.layers) || changed;
    return changed;
}

fn bool light_inspector(void* component) @local {
    Light* light = (Light*)component;
    bool changed;

    imgui::text("Kind: %s", @enum_name(LightKind, light.kind));
    changed = imgui::color_edit3("Color", (float*)&light.color, {}) || changed;
    changed = nonnegative_drag("Intensity", &light.intensity) || changed;
    changed = nonnegative_drag("Range (0 = unbounded)", &light.range) || changed;

    if (light.kind == LightKind.SPOT) {
        float inner = math::rad_to_deg(light.inner_cone);
        float outer = math::rad_to_deg(light.outer_cone);
        bool cones = imgui::slider_float("Inner cone (deg)", &inner, 0, CONE_MAX_DEGREES);
        cones = imgui::slider_float("Outer cone (deg)", &outer, 0, CONE_MAX_DEGREES) || cones;
        if (cones) {
            outer = math::clamp(outer, 0.0f, CONE_MAX_DEGREES);
            inner = math::clamp(inner, 0.0f, outer);
            light.inner_cone = math::deg_to_rad(inner);
            light.outer_cone = math::deg_to_rad(outer);
            changed = true;
        }
    }
    changed = imgui::input_scalar("Layers", imgui::DATA_TYPE_U32, &light.layers) || changed;

    imgui::separator_text("Shadow");
    changed = imgui::checkbox("Enabled", &light.shadow.enabled) || changed;
    changed = imgui::input_scalar("Priority", imgui::DATA_TYPE_S32, &light.shadow.priority) || changed;
    changed = nonnegative_drag("Bias", &light.shadow.bias) || changed;
    changed = nonnegative_drag("Normal bias", &light.shadow.normal_bias) || changed;
    if (light.kind == LightKind.DIRECTIONAL) {
        int cascades = (int)light.shadow.cascades;
        if (imgui::slider_int("Cascades", &cascades, 1, (int)light::MAX_SHADOW_CASCADES)) {
            light.shadow.cascades = (uint)cascades;
            changed = true;
        }
        changed = imgui::slider_float("Cascade lambda", &light.shadow.cascade_lambda, 0, 1) || changed;
    }
    changed = nonnegative_drag("Max distance", &light.shadow.max_distance) || changed;
    return changed;
}

fn bool ik_chain_inspector(void* component) @local {
    return chain_widgets((IkChain*)component);
}

fn bool foot_ik_inspector(void* component) @local {
    FootIk* foot = (FootIk*)component;
    bool changed = chain_widgets(&foot.leg);

    imgui::separator_text("Foot");
    changed = nonnegative_drag("Foot height", &foot.foot_height) || changed;
    changed = positive_drag("Lift fade", &foot.lift_fade) || changed;
    changed = nonnegative_drag("Ray height", &foot.ray_height) || changed;
    changed = positive_drag("Ray length", &foot.ray_length) || changed;
    imgui::text("Grounded: %s", foot.grounded ? "yes" : "no");
    imgui::text("Ground offset: %.3f", foot.ground_offset);
    imgui::text("Align weight: %.2f", foot.align_weight);
    return changed;
}

fn bool look_at_inspector(void* component) @local {
    LookAt* look_at = (LookAt*)component;
    bool changed;

    node_name_text("Node", look_at.node);
    node_name_text("Target", look_at.target);
    if (imgui::drag_float3("Forward", (float*)&look_at.forward) && look_at.forward.length() > 0) {
        look_at.forward = look_at.forward.normalize();
        changed = true;
    }
    changed = degrees_slider("Max angle (deg)", &look_at.max_angle, 0) || changed;
    changed = imgui::slider_float("Weight", &look_at.weight, 0, 1) || changed;
    return changed;
}

fn bool chain_widgets(IkChain* chain) @local {
    bool changed;
    ZString[ik::TWO_BONE_JOINTS] joint_labels = { "Root", "Middle", "End" };
    foreach (index, joint : chain.joints) node_name_text(joint_labels[index], joint);
    node_name_text("Target", chain.target);
    node_name_text("Pole", chain.pole);
    changed = imgui::slider_float("Weight", &chain.weight, 0, 1) || changed;

    ZString[ik::TWO_BONE_JOINTS - 1] limit_labels = { "Root limit", "Middle limit" };
    foreach (index, label : limit_labels) {
        imgui::push_id_int((int)index);
        defer imgui::pop_id();
        changed = limit_widgets(label, &chain.limits[index]) || changed;
    }
    return changed;
}

fn bool limit_widgets(ZString label, IkLimit* limit) @local {
    imgui::separator_text(label);
    bool changed;

    int kind = limit.kind.ordinal;
    ZString[IkLimitKind::len] kinds = { "None", "Hinge", "Cone" };
    if (imgui::combo_char("Kind", &kind, &kinds, IkLimitKind::len)) {
        limit.kind = IkLimitKind::from_ordinal((usz)kind);
        changed = true;
    }
    if (limit.kind == IkLimitKind.NONE) return changed;

    if (imgui::drag_float3("Axis", (float*)&limit.axis) && limit.axis.length() > 0) {
        limit.axis = limit.axis.normalize();
        changed = true;
    }
    if (limit.kind == IkLimitKind.CONE) {
        return degrees_slider("Half angle (deg)", &limit.max_angle, 0) || changed;
    }
    changed = degrees_slider("Min angle (deg)", &limit.min_angle, -IK_ANGLE_MAX_DEGREES) || changed;
    changed = degrees_slider("Max angle (deg)", &limit.max_angle, -IK_ANGLE_MAX_DEGREES) || changed;
    return changed;
}

fn bool degrees_slider(ZString label, float* radians, float minimum_degrees) @local {
    float degrees = math::rad_to_deg(*radians);
    if (!imgui::slider_float(label, &degrees, minimum_degrees, IK_ANGLE_MAX_DEGREES)) return false;
    *radians = math::deg_to_rad(degrees);
    return true;
}

fn void node_name_text(ZString label, Node* node) @local {
    ZString name = !node ? "(none)" : node.name.len ? node.name.zstr_tcopy() : "(unnamed)";
    imgui::text("%s: %s", label, name);
}

fn bool positive_drag(ZString label, float* value, float minimum = MIN_POSITIVE) @local {
    if (!imgui::drag_float(label, value)) return false;
    *value = math::max(*value, minimum);
    return true;
}

fn bool nonnegative_drag(ZString label, float* value) @local {
    if (!imgui::drag_float(label, value)) return false;
    *value = math::max(*value, 0.0f);
    return true;
}

fn void expose_builtin_components() @private {
    expose(Mesh);
    expose(Camera, &camera_inspector);
    expose(Light, &light_inspector);
    expose(ModelInstance);
    expose(SkinBinding);
    expose(Animator);
    expose(IkChain, &ik_chain_inspector);
    expose(FootIk, &foot_ik_inspector);
    expose(LookAt, &look_at_inspector);
}
