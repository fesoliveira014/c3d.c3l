module actions_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import imgui;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;

const float WALK_SPEED @local = 2.5f;
const float RUN_SPEED @local = 6.0f;
const float JUMP_SPEED @local = 5.0f;
const float GRAVITY @local = 12.0f;
const float PLAYER_HALF_HEIGHT @local = 0.5f;
const float ARENA_HALF_EXTENT @local = 10.0f;
const Vec3 CAMERA_OFFSET @local = { 0, 6, 9 };
const Vec2 ACTIONS_PANEL_POSITION @local = { 16, 16 };
const Vec2 ACTIONS_PANEL_SIZE @local = { 420, 420 };

struct Player @local {
    Node* node;
    float vertical_speed;
}

struct Controls @local {
    ActionMap map;
    ActionId  move;
    ActionId  jump;
    ActionId  sprint;
}

fn Controls? create_controls() @local {
    Controls controls = { .map = platform::default_action_map() };
    ActionMap* map = &controls.map;
    controls.move = map.add("move", ActionKind.AXIS_2D)!;
    controls.jump = map.add("jump", ActionKind.BUTTON)!;
    controls.sprint = map.add("sprint", ActionKind.AXIS_1D)!;

    map.bind(controls.move, platform::key_binding(Scancode.W, { 0, 1 }))!;
    map.bind(controls.move, platform::key_binding(Scancode.S, { 0, -1 }))!;
    map.bind(controls.move, platform::key_binding(Scancode.A, { -1, 0 }))!;
    map.bind(controls.move, platform::key_binding(Scancode.D, { 1, 0 }))!;
    map.bind(controls.move, platform::gamepad_stick_binding(GamepadStick.LEFT))!;
    map.bind(controls.jump, platform::key_binding(Scancode.SPACE))!;
    map.bind(controls.jump, platform::gamepad_button_binding(GamepadButton.SOUTH))!;
    map.bind(controls.sprint, platform::key_binding(Scancode.LSHIFT))!;
    map.bind(controls.sprint, platform::gamepad_axis_binding(GamepadAxis.RIGHT_TRIGGER))!;
    return controls;
}

fn void move_player(Player* player, Controls* controls, float delta) @local {
    ActionMap* map = &controls.map;
    float speed = WALK_SPEED + (RUN_SPEED - WALK_SPEED) * map.value(controls.sprint);
    Vec2 direction = map.vector(controls.move);
    Vec3* position = &player.node.local.position;
    position.x = math::clamp(position.x + direction.x * speed * delta, -ARENA_HALF_EXTENT, ARENA_HALF_EXTENT);
    position.z = math::clamp(position.z - direction.y * speed * delta, -ARENA_HALF_EXTENT, ARENA_HALF_EXTENT);

    bool grounded = position.y <= PLAYER_HALF_HEIGHT;
    if (grounded && map.pressed(controls.jump)) player.vertical_speed = JUMP_SPEED;
    player.vertical_speed -= GRAVITY * delta;
    position.y += player.vertical_speed * delta;
    if (position.y < PLAYER_HALF_HEIGHT) {
        position.y = PLAYER_HALF_HEIGHT;
        player.vertical_speed = 0;
    }
}

fn ZString key_name(Scancode key) @local {
    switch (key) {
        case Scancode.W: return "W";
        case Scancode.A: return "A";
        case Scancode.S: return "S";
        case Scancode.D: return "D";
        case Scancode.SPACE: return "Space";
        case Scancode.LSHIFT: return "Left Shift";
        default: return "key";
    }
}

fn ZString label_name(GamepadLabel label) @local {
    switch (label) {
        case UNKNOWN: return "";
        case A: return "A";
        case B: return "B";
        case X: return "X";
        case Y: return "Y";
        case CROSS: return "Cross";
        case CIRCLE: return "Circle";
        case SQUARE: return "Square";
        case TRIANGLE: return "Triangle";
    }
}

fn ZString axis_name(GamepadAxis axis) @local {
    switch (axis) {
        case GamepadAxis.LEFT_TRIGGER: return "left trigger";
        case GamepadAxis.RIGHT_TRIGGER: return "right trigger";
        default: return "axis";
    }
}

fn void binding_row(Binding* binding) @local {
    switch (binding.source) {
        case KEY:
            imgui::bullet_text("Key %s", key_name(binding.key));
        case MOUSE_BUTTON:
            imgui::bullet_text("Mouse button %d", (int)binding.mouse_button);
        case GAMEPAD_BUTTON:
            ZString label = label_name(platform::gamepad_button_label(binding.gamepad_slot, binding.gamepad_button));
            imgui::bullet_text("Pad %d button %d %s", (int)binding.gamepad_slot, (int)binding.gamepad_button, label);
        case GAMEPAD_AXIS:
            imgui::bullet_text("Pad %d %s", (int)binding.gamepad_slot, axis_name(binding.gamepad_axis));
        case GAMEPAD_STICK:
            imgui::bullet_text("Pad %d %s stick", (int)binding.gamepad_slot,
                binding.gamepad_stick == GamepadStick.LEFT ? "left" : "right");
    }
}

fn void actions_panel(Controls* controls, Input* input) @local {
    imgui::set_next_window_pos(ACTIONS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(ACTIONS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Actions", null, {})) {
        ActionMap* map = &controls.map;
        for (uint index = 0; index < map.action_count; index++) {
            ActionState* action = &map.actions[index];
            @pool() {
                imgui::separator_text(action.name.zstr_tcopy());
            };
            switch (action.kind) {
                case BUTTON: imgui::text("button: %s", action.down ? "down" : "up");
                case AXIS_1D: imgui::text("axis: %.2f", (double)action.value.x);
                case AXIS_2D: imgui::text("vector: %.2f %.2f", (double)action.value.x, (double)action.value.y);
            }
            for (uint binding = 0; binding < map.binding_count; binding++) {
                if ((uint)map.binding_actions[binding] == index) binding_row(&map.bindings[binding]);
            }
        }
        imgui::separator_text("Gamepads");
        for (usz slot = 0; slot < platform::GAMEPAD_COUNT; slot++) {
            if (input.gamepads[slot].connected) {
                imgui::text("Slot %d: %s", (int)slot, platform::gamepad_name(slot));
            } else {
                imgui::text("Slot %d: not connected", (int)slot);
            }
        }
    }
    imgui::end();
}

fn void follow(Node* camera_node, Node* target) @local {
    camera_node.local.position = target.local.position + CAMERA_OFFSET;
    camera_node.local.rotation = maths::look_rotation(-CAMERA_OFFSET, { 0, 1, 0 });
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn void? run(
    platform::Window* window,
    render::Renderer* renderer,
    Scene* scene,
    Player* player,
    Node* camera_node,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    Controls controls = create_controls()!;

    while (window.poll()) {
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        if (input.key_released(Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;

        controls.map.update(input);
        move_player(player, &controls, window.clock.delta);
        follow(camera_node, player.node);
        actions_panel(&controls, input);
        gui::stats_panel(renderer)!;

        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main(String[] args) {
    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d actions", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_actions" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId box;
    GeometryId ground;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, 1, 1, 1);
        box = assets.add_geometry(&box_geometry, "actions/box")!!;

        Geometry ground_geometry = geometry::plane(tmem, ARENA_HALF_EXTENT * 2, ARENA_HALF_EXTENT * 2);
        ground = assets.add_geometry(&ground_geometry, "actions/ground")!!;
    };

    MaterialId orange = assets.add_material(material::basic({ .color = { 0.95f, 0.55f, 0.15f, 1 } }), "actions/player_material")!!;
    MaterialId grey = assets.add_material(material::basic({ .color = { 0.35f, 0.38f, 0.4f, 1 } }), "actions/ground_material")!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    scene.add_mesh(ground, grey, name: "ground")!!;
    Player player = { .node = scene.add_mesh(box, orange, name: "player")!! };
    player.node.local.position = { 0, PLAYER_HALF_HEIGHT, 0 };
    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!!;
    follow(camera_node, player.node);

    renderer.prepare_scene(&scene)!!;

    if (catch excuse = run(
        window:      &window,
        renderer:    &renderer,
        scene:       &scene,
        player:      &player,
        camera_node: camera_node,
    )) {
        io::printfn("Actions example failed: %s", excuse);
        return 1;
    }
    return 0;
}
