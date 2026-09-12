module materials_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import sdl;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f; // Balances precise orbit control against pointer travel.
const float ORBIT_PITCH_LIMIT @local = 1.5f; // Avoids the look-rotation up-axis degeneracy.
const float ORBIT_ZOOM_STEP @local = 0.9f; // Keeps each wheel step visually useful.
const float ORBIT_DISTANCE_MIN @local = 3; // Keeps the camera outside the largest fixture.
const float ORBIT_DISTANCE_MAX @local = 32; // Keeps the fixture readable inside the far plane.
const usz MOUSE_BUTTON_LEFT @local = 1;
const uint ALPHA_TEXTURE_SIZE @local = 16; // Preserves a recognizable leaf silhouette at example scale.
const uint RAMP_TEXTURE_WIDTH @local = 8; // A 32-byte fixture keeps unequal band widths visible.
const uint RGBA8_BYTES @local = 4;
const float LIGHT_INTENSITY_MAX @local = 100; // Covers both direct-light controls without unwieldy dragging.
const float INDIRECT_INTENSITY_MAX @local = 2; // Keeps untone-mapped output readable while editing.
const float EDITOR_WIDTH @local = 170; // Leaves long labels readable in the controls panel.
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 }; // Keeps controls beside the central fixtures.
const Vec2 CONTROLS_PANEL_SIZE @local = { 420, 820 }; // Fits every preset control at the default height.
const Vec2 MATERIAL_PANEL_POSITION @local = { 1034, 332 }; // Places factor editing below frame statistics.
const Vec2 MATERIAL_PANEL_SIZE @local = { 390, 550 }; // Fits common and Toon factors without covering fixtures.
const Vec2 STATS_PANEL_POSITION @local = { 1034, 16 }; // Aligns diagnostics with the right window edge.
const Vec2 STATS_PANEL_SIZE @local = { 320, 300 }; // Holds the complete timing summary.

enum MaterialPreset @local {
    MASKED_FOLIAGE,
    ALPHA_BLEND,
    TOON_LIGHTING,
}

struct Orbit @local {
    Vec3 target;
    float distance;
    float yaw;
    float pitch;
}

struct ExampleTextures @local {
    TextureId alpha;
    TextureId ramp;
}

struct ExampleMaterials @local {
    MaterialId masked;
    MaterialId blend_red;
    MaterialId blend_blue;
    MaterialId toon_steps;
    MaterialId toon_ramp;
    MaterialId toon_rim;
}

struct ExampleNodes @local {
    Node* mask_ground;
    Node* leaf_first;
    Node* leaf_second;
    Node* blend_reference;
    Node* blend_red;
    Node* blend_blue;
    Node* toon_steps;
    Node* toon_ramp;
    Node* toon_rim;
}

struct Controls @local {
    MaterialPreset preset;
    MaterialId selected_material;
    bool environment_fill;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.mouse_buttons[MOUSE_BUTTON_LEFT]) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(
                x: orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                lower: -ORBIT_PITCH_LIMIT,
                upper: ORBIT_PITCH_LIMIT,
            );
        }
        if (input.wheel != 0) {
            float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
            orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
        }
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn void forward_gui_event(sdl::Event* event, void* user) @local {
    GuiRenderer* gui_renderer = (GuiRenderer*)user;
    gui_renderer.process_event(event);
}

fn void? draw_gui_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(scene, camera_node)!;
        renderer.composite_view()!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn bool edit_factor(
    ZString label,
    float* value,
    float minimum,
    float maximum,
) @local {
    float edited = *value;
    if (!imgui::drag_float_ex(
        label: label,
        v: &edited,
        v_speed: 0.01f,
        v_min: minimum,
        v_max: maximum,
        format: "%.3f",
        flags: imgui::SLIDER_FLAGS_ALWAYS_CLAMP,
    )) return false;
    if (!(edited >= minimum && edited <= maximum) || edited == *value) return false;
    *value = edited;
    return true;
}

fn void edit_light_color(ZString label, Vec3* color) @local {
    Vec3 edited = *color;
    if (!imgui::color_edit3(label, (float*)&edited, { .hdr = true, .float_ = true })) return;
    if (edited.x >= 0 && edited.x <= float::max
        && edited.y >= 0 && edited.y <= float::max
        && edited.z >= 0 && edited.z <= float::max) {
        *color = edited;
    }
}

fn bool same_texture_id(TextureId first, TextureId second) @local {
    return first.index == second.index && first.generation == second.generation;
}

fn bool same_material_id(MaterialId first, MaterialId second) @local {
    return first.index == second.index && first.generation == second.generation;
}

fn Vec4 material_color(Material* material) @local {
    switch (material.kind) {
        case BASIC: return material.basic.color;
        case STANDARD: return material.standard.base_color;
        case TOON: return material.toon.color;
    }
}

fn TextureSlot* material_base_slot(Material* material) @local {
    switch (material.kind) {
        case BASIC: return &material.basic.map;
        case STANDARD: return &material.standard.base_color_map;
        case TOON: return &material.toon.map;
    }
}

fn void select_material_kind(
    AssetStore* assets,
    MaterialId material_id,
    MaterialKind kind,
) @local {
    MaterialAsset* record = assets.material(material_id);
    if (record.data.kind == kind) return;

    Vec4 color = material_color(&record.data);
    MaterialCommon common = record.data.common;
    switch (kind) {
        case BASIC:
            BasicParams params = material::BASIC_PARAMS_DEFAULT;
            params.color = color;
            record.data = material::basic(params, common);
        case STANDARD:
            StandardParams params = material::STANDARD_PARAMS_DEFAULT;
            params.base_color = color;
            record.data = material::standard(params, common);
        case TOON:
            ToonParams params = material::TOON_PARAMS_DEFAULT;
            params.color = color;
            record.data = material::toon(params, common);
    }
    assets.mark_material_dirty(material_id);
}

fn void set_base_texture(
    AssetStore* assets,
    MaterialId material_id,
    TextureId texture,
) @local {
    MaterialAsset* record = assets.material(material_id);
    TextureSlot* slot = material_base_slot(&record.data);
    TextureId current = slot.texture.asset;
    if (same_texture_id(current, texture)) return;

    *slot = texture.index == 0
        ? (TextureSlot){ .transform = material::UV_TRANSFORM_IDENTITY }
        : material::texture_slot(texture, asset::SAMPLER_NEAREST);
    assets.mark_material_dirty(material_id);
}

fn void set_gradient_texture(
    AssetStore* assets,
    MaterialId material_id,
    TextureId texture,
) @local {
    MaterialAsset* record = assets.material(material_id);
    if (same_texture_id(record.data.toon.gradient_map, texture)) return;
    record.data.toon.gradient_map = texture;
    assets.mark_material_dirty(material_id);
}

fn void select_preset(
    MaterialPreset preset,
    ExampleMaterials materials,
    ExampleNodes nodes,
    Controls* controls,
) @local {
    bool masked = preset == MASKED_FOLIAGE;
    bool blended = preset == ALPHA_BLEND;
    bool toon = preset == TOON_LIGHTING;

    nodes.mask_ground.visible = masked;
    nodes.leaf_first.visible = masked;
    nodes.leaf_second.visible = masked;
    nodes.blend_reference.visible = blended;
    nodes.blend_red.visible = blended;
    nodes.blend_blue.visible = blended;
    nodes.toon_steps.visible = toon;
    nodes.toon_ramp.visible = toon;
    nodes.toon_rim.visible = toon;

    controls.preset = preset;
    switch (preset) {
        case MASKED_FOLIAGE: controls.selected_material = materials.masked;
        case ALPHA_BLEND: controls.selected_material = materials.blend_red;
        case TOON_LIGHTING: controls.selected_material = materials.toon_steps;
    }
}

fn void preset_controls(
    ExampleMaterials materials,
    ExampleNodes nodes,
    Controls* controls,
) @local {
    imgui::separator_text("Preset");
    if (imgui::radio_button("Masked foliage", controls.preset == MASKED_FOLIAGE)) {
        select_preset(
            preset: MASKED_FOLIAGE,
            materials: materials,
            nodes: nodes,
            controls: controls,
        );
    }
    if (imgui::radio_button("Alpha blend", controls.preset == ALPHA_BLEND)) {
        select_preset(
            preset: ALPHA_BLEND,
            materials: materials,
            nodes: nodes,
            controls: controls,
        );
    }
    if (imgui::radio_button("Toon lighting", controls.preset == TOON_LIGHTING)) {
        select_preset(
            preset: TOON_LIGHTING,
            materials: materials,
            nodes: nodes,
            controls: controls,
        );
    }

    imgui::separator_text("Editable surface");
    switch (controls.preset) {
        case MASKED_FOLIAGE:
            imgui::text_unformatted("Foliage");
        case ALPHA_BLEND:
            if (imgui::radio_button(
                "Red glass",
                same_material_id(controls.selected_material, materials.blend_red),
            )) {
                controls.selected_material = materials.blend_red;
            }
            imgui::same_line();
            if (imgui::radio_button(
                "Blue glass",
                same_material_id(controls.selected_material, materials.blend_blue),
            )) {
                controls.selected_material = materials.blend_blue;
            }
        case TOON_LIGHTING:
            if (imgui::radio_button(
                "Uniform steps##surface",
                same_material_id(controls.selected_material, materials.toon_steps),
            )) {
                controls.selected_material = materials.toon_steps;
            }
            if (imgui::radio_button(
                "Plateau ramp##surface",
                same_material_id(controls.selected_material, materials.toon_ramp),
            )) {
                controls.selected_material = materials.toon_ramp;
            }
            if (imgui::radio_button(
                "Rim surface##surface",
                same_material_id(controls.selected_material, materials.toon_rim),
            )) {
                controls.selected_material = materials.toon_rim;
            }
    }
}

fn void family_controls(AssetStore* assets, MaterialId material_id) @local {
    MaterialKind kind = assets.material(material_id).data.kind;
    imgui::separator_text("Family");
    if (imgui::radio_button("Basic", kind == BASIC)) {
        select_material_kind(assets, material_id, BASIC);
    }
    imgui::same_line();
    if (imgui::radio_button("Standard", kind == STANDARD)) {
        select_material_kind(assets, material_id, STANDARD);
    }
    imgui::same_line();
    if (imgui::radio_button("Toon", kind == TOON)) {
        select_material_kind(assets, material_id, TOON);
    }
}

fn void texture_controls(
    AssetStore* assets,
    MaterialId material_id,
    ExampleTextures textures,
) @local {
    MaterialAsset* record = assets.material(material_id);
    TextureId current = material_base_slot(&record.data).texture.asset;

    imgui::separator_text("Base texture");
    if (imgui::radio_button("None##base", current.index == 0)) {
        set_base_texture(assets, material_id, {});
    }
    imgui::same_line();
    if (imgui::radio_button("Alpha leaf##base", same_texture_id(current, textures.alpha))) {
        set_base_texture(assets, material_id, textures.alpha);
    }
    imgui::same_line();
    if (imgui::radio_button("Checker##base", same_texture_id(current, asset::TEXTURE_CHECKER))) {
        set_base_texture(assets, material_id, asset::TEXTURE_CHECKER);
    }

    if (record.data.kind == TOON) {
        TextureId gradient = record.data.toon.gradient_map;
        imgui::separator_text("Intensity ramp");
        if (imgui::radio_button("Uniform steps##ramp", gradient.index == 0)) {
            set_gradient_texture(assets, material_id, {});
        }
        imgui::same_line();
        if (imgui::radio_button("Plateaus##ramp", same_texture_id(gradient, textures.ramp))) {
            set_gradient_texture(assets, material_id, textures.ramp);
        }
        imgui::text_unformatted("Ramp uses red-channel intensity.");
    }
}

fn void lighting_controls(
    Scene* scene,
    Node* directional_node,
    Node* point_node,
    EnvironmentId environment,
    Controls* controls,
) @local {
    Light* directional = scene.get(directional_node, Light);
    Light* point = scene.get(point_node, Light);

    imgui::separator_text("Direct lights");
    edit_light_color("Warm directional", &directional.color);
    edit_factor(
        label: "Directional intensity",
        value: &directional.intensity,
        minimum: 0,
        maximum: LIGHT_INTENSITY_MAX,
    );
    edit_light_color("Cool point", &point.color);
    edit_factor(
        label: "Point intensity",
        value: &point.intensity,
        minimum: 0,
        maximum: LIGHT_INTENSITY_MAX,
    );

    imgui::separator_text("Indirect fill and sky");
    edit_factor(
        label: "Ambient intensity",
        value: &scene.ambient_intensity,
        minimum: 0,
        maximum: INDIRECT_INTENSITY_MAX,
    );
    if (imgui::checkbox("Environment fill", &controls.environment_fill)) {
        scene.environment = controls.environment_fill ? environment : (EnvironmentId){};
    }
    edit_factor(
        label: "Environment intensity",
        value: &scene.environment_intensity,
        minimum: 0,
        maximum: INDIRECT_INTENSITY_MAX,
    );
    edit_factor(
        label: "Sky intensity",
        value: &scene.background.intensity,
        minimum: 0,
        maximum: INDIRECT_INTENSITY_MAX,
    );
}

fn void controls_panel(
    AssetStore* assets,
    Scene* scene,
    ExampleMaterials materials,
    ExampleTextures textures,
    ExampleNodes nodes,
    Node* directional_node,
    Node* point_node,
    EnvironmentId environment,
    Controls* controls,
) @local {
    imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    bool visible = imgui::begin("Materials example", null, {});
    defer imgui::end();
    if (!visible) return;

    imgui::push_item_width(EDITOR_WIDTH);
    defer imgui::pop_item_width();

    imgui::text_unformatted("Drag outside panels to orbit; wheel to zoom.");
    imgui::text_unformatted("Release Escape outside text controls to close.");
    preset_controls(materials, nodes, controls);
    family_controls(assets, controls.selected_material);
    texture_controls(assets, controls.selected_material, textures);
    lighting_controls(
        scene: scene,
        directional_node: directional_node,
        point_node: point_node,
        environment: environment,
        controls: controls,
    );
}

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* directional_node,
    Node* point_node,
    EnvironmentId environment,
    ExampleMaterials materials,
    ExampleTextures textures,
    ExampleNodes nodes,
    Orbit* orbit,
    Controls* controls,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    bool escape_captured;

    while (window.poll(&forward_gui_event, &gui_renderer)) {
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        if (input.keys_pressed[(usz)sdl::Scancode.ESCAPE]
            || input.keys_released[(usz)sdl::Scancode.ESCAPE]) {
            escape_captured |= keyboard_was_captured || input.keyboard_captured_by_gui;
        }
        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) {
            bool quit = !escape_captured;
            escape_captured = false;
            if (quit) break;
        }

        controls_panel(
            assets: renderer.assets,
            scene: scene,
            materials: materials,
            textures: textures,
            nodes: nodes,
            directional_node: directional_node,
            point_node: point_node,
            environment: environment,
            controls: controls,
        );

        imgui::set_next_window_pos(MATERIAL_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(MATERIAL_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::material_panel(renderer.assets, controls.selected_material)!;

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        apply_orbit(orbit, input, camera_node);
        scene.update_world();
        gui_renderer.finish_frame();
        platform::sync_window(window, renderer);
        draw_gui_frame(
            renderer: renderer,
            scene: scene,
            camera_node: camera_node,
            gui_renderer: &gui_renderer,
            info: { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn TextureId? add_alpha_texture(AssetStore* assets) @local {
    TextureId texture;
    @pool() {
        char[] pixels = alloc::new_array(
            tmem,
            char,
            ALPHA_TEXTURE_SIZE * ALPHA_TEXTURE_SIZE * RGBA8_BYTES,
        );
        for (uint y = 0; y < ALPHA_TEXTURE_SIZE; y++) {
            for (uint x = 0; x < ALPHA_TEXTURE_SIZE; x++) {
                int leaf_x = (int)x - 7;
                int leaf_y = (int)y - 7;
                bool inside = leaf_x * leaf_x + leaf_y * leaf_y * 2 < 86;
                bool cutout = ((x + y) % 7 == 0) && leaf_y > -5;
                usz offset = (usz)(y * ALPHA_TEXTURE_SIZE + x) * RGBA8_BYTES;
                pixels[offset] = inside ? 74 : 12;
                pixels[offset + 1] = inside ? 190 : 24;
                pixels[offset + 2] = inside ? 58 : 12;
                pixels[offset + 3] = inside && !cutout ? 255 : 0;
            }
        }
        texture = assets.add_texture(
            desc: material::texture_2d_desc(
                width: ALPHA_TEXTURE_SIZE,
                height: ALPHA_TEXTURE_SIZE,
                format: RGBA8_SRGB,
                debug_name: "materials_alpha_leaf",
            ),
            pixels: pixels,
            key: "texture/materials/alpha_leaf",
        )!;
    };
    return texture;
}

fn TextureId? add_ramp_texture(AssetStore* assets) @local {
    char[RAMP_TEXTURE_WIDTH * RGBA8_BYTES] pixels;
    char[RAMP_TEXTURE_WIDTH] values = { 0, 48, 48, 112, 112, 112, 208, 255 };
    for (uint x = 0; x < RAMP_TEXTURE_WIDTH; x++) {
        usz offset = (usz)x * RGBA8_BYTES;
        pixels[offset] = values[x];
        pixels[offset + 1] = values[x];
        pixels[offset + 2] = values[x];
        pixels[offset + 3] = 255;
    }
    return assets.add_texture(
        desc: material::texture_2d_desc(
            width: RAMP_TEXTURE_WIDTH,
            height: 1,
            format: RGBA8_UNORM,
            debug_name: "materials_toon_ramp",
        ),
        pixels: pixels[..],
        key: "texture/materials/toon_ramp",
    );
}

fn ExampleMaterials create_materials(
    AssetStore* assets,
    ExampleTextures textures,
) @local {
    MaterialCommon masked_common = material::MATERIAL_COMMON_DEFAULT;
    masked_common.alpha_mode = MASK;
    masked_common.double_sided = true;
    masked_common.alpha_cutoff = 0.5f;

    MaterialCommon blend_common = material::MATERIAL_COMMON_DEFAULT;
    blend_common.alpha_mode = BLEND;
    blend_common.double_sided = true;

    ToonParams steps = material::TOON_PARAMS_DEFAULT;
    steps.color = { 1, 0.55f, 0.12f, 1 };

    ToonParams ramp = material::TOON_PARAMS_DEFAULT;
    ramp.color = { 0.25f, 0.9f, 0.42f, 1 };
    ramp.gradient_map = textures.ramp;

    ToonParams rim = material::TOON_PARAMS_DEFAULT;
    rim.color = { 0.2f, 0.45f, 0.95f, 1 };
    rim.rim_color = { 0.75f, 0.9f, 1 };
    rim.rim_strength = 0.7f;
    rim.rim_power = 2;

    return {
        .masked = assets.add_material(material::basic(
            params: {
                .color = { 1, 1, 1, 1 },
                .map = material::texture_slot(textures.alpha, asset::SAMPLER_NEAREST),
            },
            common: masked_common,
        ), "material/materials/masked_foliage")!!,
        .blend_red = assets.add_material(material::basic(
            { .color = { 0.95f, 0.12f, 0.08f, 0.48f } },
            blend_common,
        ), "material/materials/blend_red")!!,
        .blend_blue = assets.add_material(material::basic(
            { .color = { 0.08f, 0.35f, 1, 0.48f } },
            blend_common,
        ), "material/materials/blend_blue")!!,
        .toon_steps = assets.add_material(
            material::toon(steps),
            "material/materials/toon_steps",
        )!!,
        .toon_ramp = assets.add_material(
            material::toon(ramp),
            "material/materials/toon_ramp",
        )!!,
        .toon_rim = assets.add_material(
            material::toon(rim),
            "material/materials/toon_rim",
        )!!,
    };
}

fn ExampleNodes create_fixtures(
    Scene* scene,
    AssetStore* assets,
    ExampleMaterials materials,
) @local {
    GeometryId plane;
    GeometryId box;
    GeometryId sphere;
    @pool() {
        Geometry plane_data = geometry::plane(tmem, 1, 1);
        plane = assets.add_geometry(&plane_data, "geometry/materials/plane")!!;
        Geometry box_data = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        box = assets.add_geometry(&box_data, "geometry/materials/box")!!;
        Geometry sphere_data = geometry::sphere(tmem, 0.8f);
        sphere = assets.add_geometry(&sphere_data, "geometry/materials/sphere")!!;
    };

    MaterialId ground_material = assets.add_material(material::standard({
        .base_color = { 0.52f, 0.55f, 0.58f, 1 },
        .metallic = 0,
        .roughness = 0.85f,
    }), "material/materials/ground")!!;
    MaterialId reference_material = assets.add_material(material::basic({
        .color = { 0.1f, 0.75f, 0.32f, 1 },
    }), "material/materials/opaque_reference")!!;

    ExampleNodes nodes;
    nodes.mask_ground = scene.add_mesh(plane, ground_material, name: "masked_shadow_receiver")!!;
    nodes.mask_ground.local.scale = { 9, 1, 7 };
    nodes.leaf_first = scene.add_mesh(plane, materials.masked, name: "masked_leaf_first")!!;
    nodes.leaf_first.local.position = { -0.8f, 1.5f, 0 };
    nodes.leaf_first.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);
    nodes.leaf_first.local.scale = { 2.5f, 1, 3 };
    nodes.leaf_second = scene.add_mesh(plane, materials.masked, name: "masked_leaf_second")!!;
    nodes.leaf_second.local.position = { 0.8f, 1.5f, -0.4f };
    Quat leaf_tilt = quaternion::from_axis_angle{float}({ 1, 0, 0 }, math::PI / 2);
    Quat leaf_turn = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 2);
    nodes.leaf_second.local.rotation = leaf_tilt.mul(leaf_turn);
    nodes.leaf_second.local.scale = { 2.5f, 1, 3 };

    nodes.blend_reference = scene.add_mesh(box, reference_material, name: "opaque_blend_reference")!!;
    nodes.blend_reference.local.position = { 0, 0.6f, -1.7f };
    nodes.blend_reference.local.scale = { 4.4f, 2.8f, 0.25f };
    nodes.blend_red = scene.add_mesh(box, materials.blend_red, name: "red_blended_object")!!;
    nodes.blend_red.local.position = { -0.35f, 0.75f, 0.1f };
    nodes.blend_red.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.3f);
    nodes.blend_red.local.scale = { 1.2f, 1.8f, 0.35f };
    nodes.blend_blue = scene.add_mesh(box, materials.blend_blue, name: "blue_blended_object")!!;
    nodes.blend_blue.local.position = { 0.35f, 0.75f, 0.8f };
    nodes.blend_blue.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, -0.35f);
    nodes.blend_blue.local.scale = { 1.2f, 1.8f, 0.35f };

    nodes.toon_steps = scene.add_mesh(sphere, materials.toon_steps, name: "toon_uniform_steps")!!;
    nodes.toon_steps.local.position = { -1.9f, 0.9f, 0 };
    nodes.toon_ramp = scene.add_mesh(sphere, materials.toon_ramp, name: "toon_plateau_ramp")!!;
    nodes.toon_ramp.local.position = { 0, 0.9f, 0 };
    nodes.toon_rim = scene.add_mesh(sphere, materials.toon_rim, name: "toon_rim_surface")!!;
    nodes.toon_rim.local.position = { 1.9f, 0.9f, 0 };
    return nodes;
}

fn int main(String[] args) {
    bool gpu_timings;
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            gpu_timings = true;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d materials", 1440, 900))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: {
            .gpu_timings = gpu_timings,
            .validation = true,
            .application_name = "c3d_materials",
        },
    )!!;
    defer render::destroy_renderer(&renderer);

    ExampleTextures textures = {
        .alpha = add_alpha_texture(&assets)!!,
        .ramp = add_ramp_texture(&assets)!!,
    };
    TextureId environment_source;
    @pool() {
        Path source = path::tnew($$FILEPATH)!!;
        Path environment_directory = source.parent()!!.tappend("../assets/ibl")!!;
        environment_source = image::load_hdr(
            &assets,
            (String)environment_directory.tappend("studio_small_09_1k.hdr")!!,
            "materials/environment_source",
        )!!;
    };
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(environment_source),
        "materials/environment",
    )!!;
    renderer.upload_environment(environment)!!;

    ExampleMaterials materials = create_materials(&assets, textures);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_color = { 1, 1, 1 };
    scene.ambient_intensity = 0.12f;
    scene.ambient_add = true;
    scene.environment = environment;
    scene.environment_intensity = 0.25f;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = 0.3f;

    ExampleNodes nodes = create_fixtures(&scene, &assets, materials);

    Light directional = light::directional({ 1, 0.3f, 0.12f }, 2.8f);
    directional.shadow.normal_bias = 0.08f;
    Node* directional_node = scene.add_light(directional, name: "warm_directional")!!;
    directional_node.local.rotation = maths::look_rotation(
        (Vec3){ -0.6f, -1, -0.4f }.normalize(),
        { 0, 1, 0 },
    );
    Light point = light::point({ 0.15f, 0.45f, 1 }, 35, 10);
    Node* point_node = scene.add_light(point, name: "cool_point")!!;
    point_node.local.position = { 2.5f, 3.5f, 3 };

    Node* camera_node = scene.add_camera(camera::perspective_deg(55, 0.1f), name: "camera")!!;
    Orbit orbit = { .target = { 0, 0.8f, 0 }, .distance = 8, .yaw = 0.08f, .pitch = 0.12f };
    apply_orbit(&orbit, &window.input, camera_node);

    Controls controls = { .environment_fill = true };
    select_preset(
        preset: MASKED_FOLIAGE,
        materials: materials,
        nodes: nodes,
        controls: &controls,
    );
    scene.update_world();
    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run_gui(
        window: &window,
        renderer: &renderer,
        scene: &scene,
        camera_node: camera_node,
        directional_node: directional_node,
        point_node: point_node,
        environment: environment,
        materials: materials,
        textures: textures,
        nodes: nodes,
        orbit: &orbit,
        controls: &controls,
    )) {
        io::printfn("Materials example failed: %s", excuse);
        return 1;
    }
    return 0;
}
