module character_nav_example;

import std::io;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::character;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::nav;
import c3d::physics;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::spatial;
import imgui;

const uint  DRIVEN_COUNT @local = 10;
const uint  DRIVEN_COLUMNS @local = 5;
const Vec3  DRIVEN_ORIGIN @local = { 2, 0, 3 }; // feet of the first driven character; a grid toward +X and +Z
const float DRIVEN_SPACING @local = 2;
const uint  CROWD_CAPACITY @local = 16;
const uint  SCENE_NODE_CAPACITY @local = 96; // three nodes per character, one per crate, and the level
const float LEVEL_HALF_SIZE @local = 12;
const float LEVEL_TOP @local = 6; // metres above the floor the builder voxelizes
const float FLOOR_THICKNESS @local = 0.5f;
const uint  BUILD_BUDGET @local = 64; // tiles per nav_sync; the whole level fits in one call
const uint  BUILD_SYNCS @local = 4; // bounds the startup build; one sync normally builds and installs every tile
const float RAMP_ANGLE @local = 0.3f; // radians; 17 degrees, walkable for the crowd and the characters
const float STEEP_RAMP_ANGLE @local = 1.0f; // radians; 57 degrees, a wall for both
const float STEP_HEIGHT @local = 0.2f; // metres; under the 0.35 m character step and the 0.9 m crowd climb
const float STEP_DEPTH @local = 1.2f;
const Vec3  PLATFORM_POSITION @local = { 7, 0.5f, -6 };
const Vec3  PLATFORM_SIZE @local = { 4, 1, 4 }; // above both climbs, so only the links reach its top
const float LINK_RADIUS @local = 0.6f;
const Vec3  LADDER_BOTTOM @local = { 0, -0.5f, 3.5f }; // platform space; the floor on the +Z side
const Vec3  LADDER_TOP @local = { 0, 0.5f, 0 };
const Vec3  DROP_TOP @local = { 1.2f, 0.5f, 0 }; // platform space; one way down to the floor on the +X side
const Vec3  DROP_BOTTOM @local = { 3.5f, -0.5f, 0 };
const ulong CRATE_CATEGORY @local = 2; // left out of the player's mask, so its push body shoves crates
const Vec3  CRATE_SIZE @local = { 0.8f, 0.8f, 0.8f };
const Vec2[] CRATE_SPOTS @local = { // floor positions; none is a nav source, so the crowd plans through them
    { 3, 0.5f },
    { 5.5f, -0.5f },
    { 8.5f, 0.5f },
    { 10.5f, -0.5f },
    { 4, -2.5f },
    { 10, -2.5f },
    { -3, 5 },
    { -4, 0 },
};
const Vec3  PLAYER_SPAWN @local = { -3, 0, 2 };
const float WALK_SPEED @local = 4; // metres per second on foot
const float RUN_MULTIPLIER @local = 1.5f;
const float JUMP_SPEED @local = 5; // about 1.3 m of rise under default gravity
const float TURN_RATE @local = 8; // radians per second; a half turn in about 0.4 s
const float FACING_MIN_SPEED @local = 0.1f; // metres per second; slower characters keep their heading
const Vec3  NOSE_SIZE @local = { 0.25f, 0.15f, 0.3f };
const Vec3  NOSE_POSITION @local = { 0, 1.5f, -0.35f }; // on the capsule's front at eye height; forward is -Z
const float CENTER_HEIGHT @local = 1; // metres from the feet to the default capsule's center
const float MIN_STEP @local = 0.001f; // seconds; the crowd needs a positive step
const float MAX_STEP @local = 0.05f; // seconds; a stalled frame does not throw characters across the level
const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float ORBIT_PITCH @local = 0.7f;
const float ORBIT_YAW @local = 0.5f;
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE @local = 18;
const float ORBIT_DISTANCE_MIN @local = 2;
const float ORBIT_DISTANCE_MAX @local = 40;
const float MARKER_RADIUS @local = 0.35f;
const uint  GOAL_COLOR @local = 0xFF4040FF;
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 460, 470 };
const float REBASE_DISTANCE @local = 1000; // metres from the origin at which the player pulls the world back
const float KILOMETRE @local = 1000;

struct Orbit @local {
    float distance;
    float yaw;
    float pitch;
}

struct Level @local {
    GeometryId capsule_geometry;
    GeometryId nose_geometry;
    MaterialId driven_material;
    MaterialId nose_material;
    Node*      player;
    Node*      camera_node;
}

struct Driven @local {
    Node*[DRIVEN_COUNT] nodes;
    Vec3                goal;
    bool                has_goal;
}

struct Rebasing @local {
    Scene*            scene;
    PhysicsWorld*     physics;
    NavMesh*          mesh;
    NavBuilder*       builder;
    Crowd*            crowd;
    render::Renderer* renderer;
    Driven*           driven;
    uint              count;
}

struct Controls @local {
    CharacterDebugOptions character;
    NavMeshDebugOptions   mesh;
    CrowdDebugOptions     crowd;
}

fn MaterialId? add_colour(AssetStore* assets, Vec4 color, String key) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = 0.85f;
    return assets.add_material(material::standard(params), key);
}

fn GeometryId? add_box_geometry(AssetStore* assets, Vec3 size) @local {
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width:     size.x,
            height:    size.y,
            depth:     size.z,
        );
        return assets.add_geometry(&box);
    };
}

// A static box the crowd and the characters both see: a mesh for the navmesh, a body for the capsules.
fn Node*? add_block(
    Scene* scene,
    PhysicsWorld* physics,
    AssetStore* assets,
    MaterialId material,
    Vec3 size,
    Vec3 position,
    float pitch = 0,
) @local {
    Node* node = scene.add_mesh(add_box_geometry(assets, size)!, material)!;
    node.local.position = position;
    node.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, pitch);
    scene.update_world();
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = size * 0.5f;
    physics.add_body(node, physics::default_body_desc(STATIC), (&collider)[:1])!;
    return node;
}

// The crowd example's level without the door and the mud, every block also a physics body.
fn Level? build_level(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @local {
    Level level;
    MaterialId floor_material = add_colour(assets, { 0.55f, 0.58f, 0.55f, 1 }, "character_nav/floor")!;
    MaterialId block_material = add_colour(assets, { 0.75f, 0.62f, 0.45f, 1 }, "character_nav/block")!;
    MaterialId steep_material = add_colour(assets, { 0.8f, 0.35f, 0.3f, 1 }, "character_nav/steep")!;
    MaterialId platform_material = add_colour(assets, { 0.3f, 0.5f, 0.9f, 1 }, "character_nav/platform")!;

    add_block(
        scene:    scene,
        physics:  physics,
        assets:   assets,
        material: floor_material,
        size:     { LEVEL_HALF_SIZE * 2, FLOOR_THICKNESS, LEVEL_HALF_SIZE * 2 },
        position: { 0, -FLOOR_THICKNESS * 0.5f, 0 },
    )!;
    add_block(
        scene:    scene,
        physics:  physics,
        assets:   assets,
        material: block_material,
        size:     { 3, 0.2f, 6 },
        position: { -7, 0.85f, -5 },
        pitch:    RAMP_ANGLE,
    )!;
    add_block(
        scene:    scene,
        physics:  physics,
        assets:   assets,
        material: steep_material,
        size:     { 3, 0.2f, 3 },
        position: { -1, 1.2f, -6 },
        pitch:    STEEP_RAMP_ANGLE,
    )!;
    for (uint step = 1; step <= 3; step++) {
        add_block(
            scene:    scene,
            physics:  physics,
            assets:   assets,
            material: block_material,
            size:     { 4, step * STEP_HEIGHT, STEP_DEPTH },
            position: { -7, step * STEP_HEIGHT * 0.5f, 2 + step * STEP_DEPTH },
        )!;
    }
    add_block(
        scene:    scene,
        physics:  physics,
        assets:   assets,
        material: block_material,
        size:     { 16, 2, 0.4f },
        position: { 0, 1, 10 },
    )!;
    add_block(
        scene:    scene,
        physics:  physics,
        assets:   assets,
        material: block_material,
        size:     { 0.4f, 2, 7 },
        position: { 0, 1, 3 },
    )!;
    Node* platform = add_block(
        scene:    scene,
        physics:  physics,
        assets:   assets,
        material: platform_material,
        size:     PLATFORM_SIZE,
        position: PLATFORM_POSITION,
    )!;

    Node* ladder = scene.add_node(platform, "ladder")!;
    scene.add_nav_link(ladder, {
        .start         = LADDER_BOTTOM,
        .end           = LADDER_TOP,
        .radius        = LINK_RADIUS,
        .bidirectional = true,
        .area          = nav::WALKABLE_AREA,
    })!;
    Node* drop = scene.add_node(platform, "drop")!;
    scene.add_nav_link(drop, {
        .start  = DROP_TOP,
        .end    = DROP_BOTTOM,
        .radius = LINK_RADIUS,
        .area   = nav::WALKABLE_AREA,
    })!;

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    scene.update_world();
    scene.add_nav_sources(scene.root);
    return level;
}

// Added after the level's sources, so crates never reach the navmesh.
fn void? add_crates(AssetStore* assets, Scene* scene, PhysicsWorld* physics) @local {
    MaterialId crate_material = add_colour(assets, { 0.7f, 0.5f, 0.3f, 1 }, "character_nav/crate")!;
    GeometryId crate_geometry = add_box_geometry(assets, CRATE_SIZE)!;
    ColliderDesc collider = physics::default_collider_desc(BOX);
    collider.half_extents = CRATE_SIZE * 0.5f;
    collider.filter.category = CRATE_CATEGORY;
    foreach (spot : CRATE_SPOTS) {
        Node* crate = scene.add_mesh(crate_geometry, crate_material, name: "crate")!;
        crate.local.position = { spot.x, CRATE_SIZE.y * 0.5f, spot.y };
        scene.update_world();
        physics.add_body(crate, physics::default_body_desc(DYNAMIC), (&collider)[:1])!;
    }
}

// A capsule body and a nose on the node's -Z side, so the facing shows.
fn Node*? add_character_node(
    Scene* scene,
    Level* level,
    MaterialId body_material,
    Vec3 feet,
    String name,
) @local {
    CharacterDesc desc = character::default_character_desc();
    Node* node = scene.add_node(name: name)!;
    node.local.position = feet;
    Node* body = scene.add_mesh(
        geometry: level.capsule_geometry,
        material: body_material,
        parent:   node,
        name:     "body",
    )!;
    body.local.position = { 0, desc.half_height + desc.radius, 0 };
    Node* nose = scene.add_mesh(
        geometry: level.nose_geometry,
        material: level.nose_material,
        parent:   node,
        name:     "nose",
    )!;
    nose.local.position = NOSE_POSITION;
    return node;
}

fn void? spawn_characters(
    AssetStore* assets,
    Scene* scene,
    Level* level,
    Driven* driven,
) @local {
    CharacterDesc desc = character::default_character_desc();
    @pool() {
        Geometry capsule = geometry::capsule(tmem, desc.radius, desc.half_height * 2);
        level.capsule_geometry = assets.add_geometry(&capsule, "character_nav/capsule")!;
    };
    level.nose_geometry = add_box_geometry(assets, NOSE_SIZE)!;
    level.nose_material = add_colour(assets, { 0.15f, 0.15f, 0.18f, 1 }, "character_nav/nose")!;
    level.driven_material = add_colour(assets, { 0.2f, 0.7f, 0.35f, 1 }, "character_nav/driven")!;
    MaterialId player_material = add_colour(assets, { 0.95f, 0.6f, 0.25f, 1 }, "character_nav/player")!;

    level.player = add_character_node(
        scene:         scene,
        level:         level,
        body_material: player_material,
        feet:          PLAYER_SPAWN,
        name:          "player",
    )!;
    for (uint index = 0; index < DRIVEN_COUNT; index++) {
        Vec3 cell = { (float)(index % DRIVEN_COLUMNS), 0, (float)(index / DRIVEN_COLUMNS) };
        driven.nodes[index] = add_character_node(
            scene:         scene,
            level:         level,
            body_material: level.driven_material,
            feet:          DRIVEN_ORIGIN + cell * DRIVEN_SPACING,
            name:          "driven",
        )!;
    }
    scene.update_world();

    CharacterDesc player_desc = desc;
    player_desc.push_bodies = true;
    player_desc.filter.mask = ~CRATE_CATEGORY;
    scene.add_character(level.player, player_desc)!;
    foreach (node : driven.nodes) {
        scene.add_character(node, desc)!;
        scene.add_nav_agent(node, nav::default_nav_agent_params())!;
        scene.add_nav_driven(node)!;
    }
}

fn Vec3 orbit_offset(Orbit* orbit) @local {
    return {
        (float)math::cos(orbit.pitch) * (float)math::sin(orbit.yaw),
        (float)math::sin(orbit.pitch),
        (float)math::cos(orbit.pitch) * (float)math::cos(orbit.yaw),
    };
}

fn void orbit_input(Orbit* orbit, Input* input) @local {
    if (input.mouse_captured_by_gui) return;
    if (input.button_down(platform::MouseButton.RIGHT)) {
        orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
        orbit.pitch = math::clamp(
            orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
            -ORBIT_PITCH_LIMIT,
            ORBIT_PITCH_LIMIT,
        );
    }
    if (input.wheel != 0) {
        float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
        orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
    }
}

fn Vec3 desired_velocity(Orbit* orbit, Input* input) @local {
    if (input.keyboard_captured_by_gui) return {};
    Vec3 forward = { -(float)math::sin(orbit.yaw), 0, -(float)math::cos(orbit.yaw) };
    Vec3 right = forward.cross({ 0, 1, 0 });
    Vec3 direction;
    if (input.key_down(platform::Scancode.W)) direction += forward;
    if (input.key_down(platform::Scancode.S)) direction -= forward;
    if (input.key_down(platform::Scancode.D)) direction += right;
    if (input.key_down(platform::Scancode.A)) direction -= right;
    if (direction.length_sq() == 0) return {};
    float speed = input.key_down(platform::Scancode.LSHIFT) ? WALK_SPEED * RUN_MULTIPLIER : WALK_SPEED;
    return direction.normalize() * speed;
}

fn void follow(Orbit* orbit, Node* camera_node, Vec3 target) @local {
    Vec3 offset = orbit_offset(orbit);
    camera_node.local.position = target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn float wrap_angle(float angle) @local {
    if (angle > math::PI) return angle - (float)math::PI * 2;
    if (angle < -math::PI) return angle + (float)math::PI * 2;
    return angle;
}

// The character package leaves rotation to the application: yaw toward the horizontal velocity, rate-limited.
fn void face_velocity(Scene* scene, Node* node, float max_turn) @local {
    Vec3 velocity = scene.get(node, Character).velocity;
    Vec3 heading = { velocity.x, 0, velocity.z };
    if (heading.length() < FACING_MIN_SPEED) return;
    Vec3 forward = maths::transform_dir(node.world, { 0, 0, -1 });
    float yaw = (float)math::atan2(-forward.x, -forward.z);
    float turn = wrap_angle((float)math::atan2(-heading.x, -heading.z) - yaw);
    float turned = yaw + math::clamp(turn, -max_turn, max_turn);
    node.set_world_pose(node.world_position(), quaternion::from_axis_angle{float}({ 0, 1, 0 }, turned));
}

fn PickHit? pick(
    AssetStore* assets,
    Scene* scene,
    Node* camera_node,
    Vec2 pixel,
    Vec2 viewport,
) @local {
    camera::Camera* camera = scene.get(camera_node, camera::Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
    Ray ray = camera::screen_to_ray(&matrices, pixel, viewport);
    @pool() {
        PickHit[] hits = spatial::pick(
            allocator: tmem,
            assets:    assets,
            scene:     scene,
            ray:       ray,
            options:   { .precision = TRIANGLES, .faces = MATERIAL, .layers = camera::ALL_LAYERS },
        );
        if (!hits.len) return NOT_FOUND~;
        return hits[0];
    };
}

fn void send_driven(Scene* scene, Driven* driven, Vec3 goal) @local {
    driven.goal = goal;
    driven.has_goal = true;
    foreach (node : driven.nodes) scene.set_nav_target(node, goal);
}

// Between end_frame and the next simulation update, in the order every owner's shift expects.
fn void rebase(Rebasing* rebasing, Vec3 offset) @local {
    Scene* scene = rebasing.scene;
    scene.shift_origin(offset);
    scene.update_world();
    rebasing.physics.shift_origin(scene, offset);
    scene.shift_characters(offset);
    rebasing.mesh.shift_origin(offset);
    rebasing.builder.shift_origin(offset);
    rebasing.crowd.shift_origin(offset);
    scene.shift_navigation(offset);
    rebasing.renderer.shift_origin(scene, offset);
    rebasing.driven.goal -= offset;
    rebasing.count++;
}

fn Vec3 rebase_offset_for(Vec3 position) @local {
    Vec3 offset = render::frame_origin_for(position);
    offset.y = 0;
    return offset;
}

fn void draw_panel(
    Scene* scene,
    Crowd* crowd,
    Driven* driven,
    Controls* controls,
    uint rebases,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Driven characters", null, {})) {
        imgui::text("Left click sends the green characters");
        imgui::text("The crowd cannot see the crates; the player pushes them");
        imgui::text("WASD move the player, Shift run, Space jump");
        imgui::text("Right drag orbits, wheel zooms");
        imgui::text("R rebases the world to the player; past 1 km it happens on its own");
        imgui::text(
            "World shift %.0f %.0f %.0f m, %u rebases",
            scene.world_shift[0],
            scene.world_shift[1],
            scene.world_shift[2],
            rebases,
        );
        imgui::checkbox("Capsules", &controls.character.capsules);
        imgui::checkbox("Navmesh", &controls.mesh.polys);
        imgui::checkbox("Crowd agents", &controls.crowd.agents);
        imgui::separator();
        foreach (index, node : driven.nodes) {
            CrowdAgentRuntime* runtime = scene.get(node, CrowdAgentRuntime);
            if (!runtime) continue;
            CrowdAgent* agent = crowd.agent(runtime.index);
            bool traversing = scene.get(node, NavDriven).traversal.active;
            @pool() {
                imgui::text("Character %u: %s%s", (uint)index, string::tformat_zstr("%s", agent.target_state),
                    traversing ? "   traversing".ptr : "".ptr);
            };
        }
    }
    imgui::end();
}

fn void draw_debug(
    NavMesh* mesh,
    Crowd* crowd,
    CharacterSystem* system,
    Driven* driven,
    Controls* controls,
    debug::DebugDraw* sink,
) @local {
    sink.clear();
    mesh.debug_draw(sink, controls.mesh);
    crowd.debug_draw(sink, controls.crowd);
    system.debug_draw(sink, controls.character);
    if (driven.has_goal) {
        sink.circle(
            center: driven.goal,
            normal: { 0, 1, 0 },
            radius: MARKER_RADIUS,
            rgba:   GOAL_COLOR,
        );
    }
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    debug::DebugDraw* sink,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(
            scene:       scene,
            camera_node: camera_node,
            view:        renderer.default_view,
            debug:       sink,
        )!;
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
    AssetStore* assets,
    Scene* scene,
    PhysicsWorld* physics,
    float world_offset_km,
) @local {
    Level level = build_level(assets, scene, physics)!;
    NavBuilderDesc desc = nav::default_nav_builder_desc({
        .min = { -LEVEL_HALF_SIZE, -1, -LEVEL_HALF_SIZE },
        .max = { LEVEL_HALF_SIZE, LEVEL_TOP, LEVEL_HALF_SIZE },
    });
    NavBuilder builder = nav::create_nav_builder(mem, scene, desc)!;
    defer nav::destroy_nav_builder(&builder);
    NavMesh mesh = nav::create_nav_mesh_for(mem, &builder)!;
    defer nav::destroy_nav_mesh(&mesh);
    for (uint sync = 0; sync < BUILD_SYNCS; sync++) {
        NavSyncResult built = nav::nav_sync(
            builder: &builder,
            mesh:    &mesh,
            scene:   scene,
            assets:  assets,
            budget:  BUILD_BUDGET,
        );
        if (built.failed) return c3d::INVALID_ARGUMENT~;
        if (!built.pending) break;
    }

    add_crates(assets, scene, physics)!;
    Crowd crowd = nav::create_crowd(
        allocator: mem,
        desc:      { .max_agents = CROWD_CAPACITY, .max_agent_radius = nav::default_nav_agent_params().radius },
        mesh:      &mesh,
        scene:     scene,
    )!;
    defer nav::destroy_crowd(&crowd);
    Driven* driven = mem::new(Driven);
    defer free(driven);
    spawn_characters(
        assets: assets,
        scene:  scene,
        level:  &level,
        driven: driven,
    )!;
    CharacterSystem system = character::create_character_system(mem, physics, scene)!;
    defer character::destroy_character_system(&system);

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw sink = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&sink);

    Orbit orbit = { .distance = ORBIT_DISTANCE, .yaw = ORBIT_YAW, .pitch = ORBIT_PITCH };
    Controls controls = {
        .character = { .capsules = true },
        .mesh      = { .polys = true, .links = true },
        .crowd     = { .agents = true },
    };
    renderer.prepare_scene(scene)!;

    Rebasing rebasing = {
        .scene    = scene,
        .physics  = physics,
        .mesh     = &mesh,
        .builder  = &builder,
        .crowd    = &crowd,
        .renderer = renderer,
        .driven   = driven,
    };
    Vec3 start = -rebase_offset_for({ world_offset_km * KILOMETRE, 0, world_offset_km * KILOMETRE });
    if (start != (Vec3){}) {
        rebase(&rebasing, start);
        rebasing.count = 0;
    }

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        Vec3 player_position = level.player.world_position();
        float distance_from_origin = (float)math::hypot(player_position.x, player_position.z);
        bool requested = !input.keyboard_captured_by_gui && input.key_pressed(platform::Scancode.R);
        if (requested || distance_from_origin > REBASE_DISTANCE) {
            Vec3 offset = rebase_offset_for(player_position);
            if (offset != (Vec3){}) rebase(&rebasing, offset);
        }

        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        draw_panel(
            scene:    scene,
            crowd:    &crowd,
            driven:   driven,
            controls: &controls,
            rebases:  rebasing.count,
        );

        orbit_input(&orbit, input);
        scene.move_character(level.player, desired_velocity(&orbit, input));
        if (!input.keyboard_captured_by_gui && input.key_pressed(platform::Scancode.SPACE)) {
            scene.jump_character(level.player, JUMP_SPEED);
        }
        if (input.button_pressed(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
            PickHit? hit = pick(
                assets:      assets,
                scene:       scene,
                camera_node: level.camera_node,
                pixel:       input.mouse_position,
                viewport:    { (float)window.width, (float)window.height },
            );
            if (try hit) send_driven(scene, driven, hit.position);
        }

        float dt = math::clamp(window.clock.delta, MIN_STEP, MAX_STEP);
        scene.update_world();
        nav::crowd_update(scene, &crowd, dt);
        character::drive_characters(scene, &crowd);
        physics.update(dt);
        scene.update_world();
        float max_turn = TURN_RATE * dt;
        face_velocity(scene, level.player, max_turn);
        foreach (node : driven.nodes) face_velocity(scene, node, max_turn);
        scene.update_world();
        follow(&orbit, level.camera_node, level.player.world_position() + { 0, CENTER_HEIGHT, 0 });
        scene.update_world();

        draw_debug(
            mesh:     &mesh,
            crowd:    &crowd,
            system:   &system,
            driven:   driven,
            controls: &controls,
            sink:     &sink,
        );
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  level.camera_node,
            gui_renderer: &gui_renderer,
            sink:         &sink,
            info:         {
                .time               = window.clock.total,
                .delta              = window.clock.delta,
                .reference_position = level.camera_node.world_position(),
            },
        )!;
    }
}

fn float? parse_world_offset(String[] args) @local {
    float kilometres;
    for (usz index = 1; index < args.len; index++) {
        if (args[index] != "--world-offset" || index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
        kilometres = args[++index].to_float()!;
    }
    return kilometres;
}

fn int main(String[] args) {
    float? world_offset_km = parse_world_offset(args);
    if (catch excuse = world_offset_km) {
        io::eprintn("Use --world-offset <km>");
        return 1;
    }
    platform::Window window = platform::create_window(platform::default_window_desc("c3d character nav", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_character_nav" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    character::register_character(&scene)!!;
    nav::register_nav(&scene)!!;
    character::register_nav_driven(&scene)!!;

    PhysicsWorld physics = physics::create_physics_world(
        allocator: mem,
        assets:    &assets,
        scene:     &scene,
        desc:      physics::default_physics_desc(),
    )!!;
    defer physics::destroy_physics_world(&physics);

    if (catch excuse = run(
        window:          &window,
        renderer:        &renderer,
        assets:          &assets,
        scene:           &scene,
        physics:         &physics,
        world_offset_km: world_offset_km,
    )) {
        io::eprintfn("character nav example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
