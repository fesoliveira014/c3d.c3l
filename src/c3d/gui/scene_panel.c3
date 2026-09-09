module c3d::gui;

import c3d::ecs;
import c3d::scene;
import imgui;
import std::math;

<*
 Persistent selection and rotation editing state for a scene panel.
*>
struct GuiPanelState {
    Entity selected;
    Entity rotation_node;
    Vec3 rotation_degrees;
    bool rotation_active;
}

<*
 Inspect the node hierarchy and edit local transforms.
 @param [&inout] scene : "Edited before the final update_world traversal."
 @param [&inout] state : "Selection and active rotation edit retained between frames."
*>
fn void scene_panel(Scene* scene, GuiPanelState* state) {
    if (!scene.world.is_alive(state.selected)) state.selected = {};
    bool visible = imgui::begin("Scene", null, {});
    defer imgui::end();
    if (!visible) return;
    @pool() {
        for (Node* node = scene.root.first_child; node; node = node.next_sibling) {
            node_tree(node, state);
        }
        if (scene.world.is_alive(state.selected)) {
            edit_transform(scene.node(state.selected), state);
        }
    };
}

fn bool same_entity(Entity first, Entity second) @local {
    return first.index == second.index && first.generation == second.generation;
}

fn void node_tree(Node* node, GuiPanelState* state) @local {
    imgui::push_id_int(bitcast(node.id.index, int));
    defer imgui::pop_id();
    imgui::push_id_int(bitcast(node.id.generation, int));
    defer imgui::pop_id();
    imgui::TreeNodeFlags flags = {
        .selected = same_entity(node.id, state.selected),
        .leaf = node.first_child == null,
        .open_on_arrow = true,
    };
    ZString name = node.name.len ? node.name.zstr_tcopy() : "(unnamed)";
    bool open = imgui::tree_node_ex(name, flags);
    if (imgui::is_item_clicked()) state.selected = node.id;
    if (open) {
        defer imgui::tree_pop();
        for (Node* child = node.first_child; child; child = child.next_sibling) {
            node_tree(child, state);
        }
    }
}

fn void edit_transform(Node* node, GuiPanelState* state) @local {
    imgui::checkbox("Visible", &node.visible);
    imgui::input_scalar("Layers", imgui::DATA_TYPE_U32, &node.layers);
    imgui::drag_float3("Position", (float*)&node.local.position);
    if (!same_entity(state.rotation_node, node.id) || !state.rotation_active) {
        Vec3 angles = node.local.rotation.to_euler();
        state.rotation_degrees = {
            math::rad_to_deg(angles.x),
            math::rad_to_deg(angles.y),
            math::rad_to_deg(angles.z),
        };
        state.rotation_node = node.id;
    }
    bool rotation_changed = imgui::drag_float3("Rotation (deg)", (float*)&state.rotation_degrees);
    state.rotation_active = imgui::is_item_active();
    if (rotation_changed) {
        node.local.rotation = quaternion::from_euler{float}(
            math::deg_to_rad(state.rotation_degrees.x),
            math::deg_to_rad(state.rotation_degrees.y),
            math::deg_to_rad(state.rotation_degrees.z)
        ).normalize();
    }
    Vec3 scale = node.local.scale;
    if (imgui::drag_float3("Scale", (float*)&scale)) {
        if (scale.x != 0 && scale.y != 0 && scale.z != 0) {
            node.local.scale = scale;
        } else {
            imgui::text_unformatted("Scale components must be nonzero.");
        }
    }
}
