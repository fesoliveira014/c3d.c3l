module c3d::gui @feat(C3D_PHYSICS_GUI & C3D_PHYSICS_GUI_CHARACTER);

import c3d;
import c3d::character;
import c3d::scene;
import imgui;
import std::math;

const float SLOPE_DEGREES_MAX @local = 89;

fn void expose_character_inspector() @private {
    expose(Character, &character_inspector);
}

fn bool has_character(Scene* scene, Node* node) @private => scene.has(node, Character);

fn void characters_section(PhysicsPanel* panel) @private {
    if (!imgui::collapsing_header("Characters", {})) return;
    if (!imgui::begin_table("physics_characters", 3, { .row_bg = true, .resizable = true })) return;
    defer imgui::end_table();
    imgui::table_setup_column("Name", {});
    imgui::table_setup_column("Grounded", {});
    imgui::table_setup_column("Speed", {});
    imgui::table_headers_row();
    Scene* scene = panel.scene;
    scene.@each(Character; entity, character) {
        Node* node = scene.node(entity);
        imgui::table_next_row();
        (void)imgui::table_next_column();
        select_row(panel, node, node.name);
        (void)imgui::table_next_column();
        imgui::text_unformatted(character.grounded ? (ZString)"yes" : (ZString)"no");
        (void)imgui::table_next_column();
        imgui::text("%.2f", character.velocity.length());
    };
}

fn void character_block(PhysicsPanel* panel, Node* node) @private {
    imgui::separator_text("Character");
    Character* character = panel.scene.get(node, Character);
    CharacterDesc desc = character.desc;
    bool changed = imgui::slider_float("Radius", &desc.radius, CHARACTER_SIZE_MIN, CHARACTER_SIZE_MAX);
    changed |= imgui::slider_float("Half height", &desc.half_height, CHARACTER_SIZE_MIN, CHARACTER_SIZE_MAX);
    changed |= imgui::slider_float("Step height", &desc.step_height, 0, CHARACTER_SIZE_MAX);
    changed |= imgui::slider_float("Max slope (deg)", &desc.max_slope_degrees, 0, SLOPE_DEGREES_MAX);
    changed |= imgui::drag_float("Skin", &desc.skin);
    changed |= imgui::checkbox("Push bodies", &desc.push_bodies);
    changed |= imgui::input_scalar("Category", imgui::DATA_TYPE_U64, &desc.filter.category);
    changed |= imgui::input_scalar("Mask", imgui::DATA_TYPE_U64, &desc.filter.mask);
    changed |= imgui::input_scalar("Group", imgui::DATA_TYPE_S32, &desc.filter.group);
    if (changed) {
        desc.radius = math::max(desc.radius, CHARACTER_SIZE_MIN);
        desc.half_height = math::max(desc.half_height, CHARACTER_SIZE_MIN);
        desc.skin = math::max(desc.skin, 0.0f);
        panel.last_failure = {};
        if (catch failure = panel.scene.set_character_desc(node, desc)) panel.last_failure = failure;
    }
    draw_character_state(panel.scene.get(node, Character));
}

fn bool character_inspector(void* component) @private {
    Character* character = component;
    CharacterDesc desc = character.desc;
    imgui::text("Radius %.3f, half height %.3f, step %.3f", desc.radius, desc.half_height, desc.step_height);
    imgui::text("Max slope %.1f deg, skin %.4f, push bodies %s", desc.max_slope_degrees, desc.skin,
        desc.push_bodies ? (ZString)"yes" : (ZString)"no");
    draw_character_state(character);
    imgui::text_unformatted(EDITED_IN_PANEL);
    return false;
}

fn void draw_character_state(Character* character) @local {
    Vec3 velocity = character.velocity;
    imgui::text("Velocity: %.2f %.2f %.2f", velocity.x, velocity.y, velocity.z);
    Vec3 normal = character.ground_normal;
    imgui::text("Grounded: %s, normal %.2f %.2f %.2f", character.grounded ? (ZString)"yes" : (ZString)"no",
        normal.x, normal.y, normal.z);
    imgui::text("Planes last step: %u", character.plane_count);
}
