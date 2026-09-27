module crowd_example;

import std::io;
import std::math;
import std::math::quaternion;
import std::math::random;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::nav;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::spatial;
import imgui;

const uint  AGENT_COUNT @local = 40;
const uint  CROWD_CAPACITY @local = 64;
const uint  SCENE_NODE_CAPACITY @local = 160; // two nodes per agent plus the level
const float FLOOR_SIZE @local = 24;
const float LEVEL_HALF_SIZE @local = 12;
const float LEVEL_TOP @local = 6; // metres above the floor the builder voxelizes
const uint  BUILD_BUDGET @local = 64; // tiles and layer rebuilds per nav_sync; the whole level fits in one call
const uint  BUILD_SYNCS @local = 4; // bounds the startup build; one sync normally builds and installs every layer
const uint  TILES_PER_FRAME @local = 4;
const char  MUD_AREA @local = 2;
const float MUD_COST @local = 3;
const Vec3  DOOR_POSITION @local = { 0, 1, 8.15f }; // fills the gap between the two walls
const Vec3  DOOR_SIZE @local = { 0.4f, 2, 3.3f };
const Aabb  DOOR_OBSTACLE @local = { // node space; reaches below the floor
    .min = { -0.3f, -1.5f, -1.65f },
    .max = { 0.3f, 1, 1.65f },
};
const float DOOR_SINK @local = 2.5f; // metres the open door sinks into the floor
const float RAMP_ANGLE @local = 0.3f; // radians; 17 degrees, under the 45 degree slope limit
const float STEEP_RAMP_ANGLE @local = 1.0f; // radians; 57 degrees, over the slope limit
const float STEP_HEIGHT @local = 0.2f; // metres; within the 0.9 m climb
const float STEP_DEPTH @local = 1.2f;
const Vec3  PLATFORM_POSITION @local = { 7, 0.5f, -6 };
const float LINK_RADIUS @local = 0.6f;
const Vec3  LADDER_BOTTOM @local = { 0, -0.5f, 3.5f }; // platform space; the floor on the +Z side
const Vec3  LADDER_TOP @local = { 0, 0.5f, 0 };
const Vec3  DROP_TOP @local = { 1.2f, 0.5f, 0 }; // platform space; one way down to the floor on the +X side
const Vec3  DROP_BOTTOM @local = { 3.5f, -0.5f, 0 };
const float AGENT_BODY_RADIUS @local = 0.6f; // the default agent's radius, so drawn bodies show real overlap
const float AGENT_BODY_HEIGHT @local = 0.8f; // between the hemisphere centres; two metres tall in all
const float AGENT_BODY_LIFT @local = 1; // metres from the agent's floor point to the capsule's centre
const float RETARGET_SECONDS @local = 6; // each agent draws a new goal this often
const float RETARGET_JITTER @local = 3; // seconds of spread, so agents do not all turn at once
const float MIN_STEP @local = 0.001f; // seconds; the crowd needs a positive step
const float MAX_STEP @local = 0.05f; // seconds; a stalled frame does not throw agents across walls
const ulong RANDOM_SEED @local = 0xc40d;
const usz   SAMPLE_CAPACITY @local = 256; // avoidance samples of the selected agent; the default pattern tries 75
const float SAMPLE_MARK_SCALE @local = 0.5f; // of a sample's size, drawn around its velocity
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float FREE_SPEED @local = 8;
const float FREE_FAST_MULTIPLIER @local = 4;
const float FREE_SPEED_WHEEL_STEP @local = 1.25f;
const Vec3  CAMERA_START @local = { 0, 18, 22 };
const float CAMERA_START_PITCH @local = -0.75f;
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 430, 420 };
const float MARKER_RADIUS @local = 0.35f;
const uint  GOAL_COLOR @local = 0xFF4040FF;
const uint  SELECTED_COLOR @local = 0xFF00C0FF;
const uint  LOW_PENALTY_COLOR @local = 0xFF40FF40;
const uint  HIGH_PENALTY_COLOR @local = 0xFF4040FF;

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    float speed;
}

struct Controls @local {
    CrowdDebugOptions   draw;
    NavMeshDebugOptions mesh;
    bool                wander;         // agents draw random goals; a click turns it off
    bool                samples;        // the selected agent's avoidance samples
}

struct Level @local {
    Node*      camera_node;
    Node*      door;
    bool       door_open;
    MaterialId agent_material;
    MaterialId selected_material;
}

struct Agents @local {
    Node*[AGENT_COUNT] nodes;
    Node*[AGENT_COUNT] bodies;
    float[AGENT_COUNT] retarget_at;
    uint               selected;
    Vec3               goal;
    bool               has_goal;
    Lcg64Random        generator;
}

fn Vec3 free_forward(FreeCamera* camera) @local {
    return {
        math::cos(camera.pitch) * math::sin(camera.yaw),
        math::sin(camera.pitch),
        math::cos(camera.pitch) * math::cos(camera.yaw),
    };
}

fn void apply_free_camera(
    FreeCamera* camera,
    Input* input,
    Node* camera_node,
    float delta_seconds,
) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.RIGHT)) {
            camera.yaw -= input.mouse_delta.x * FREE_LOOK_RADIANS_PER_PIXEL;
            camera.pitch = math::clamp(
                camera.pitch - input.mouse_delta.y * FREE_LOOK_RADIANS_PER_PIXEL,
                -FREE_PITCH_LIMIT,
                FREE_PITCH_LIMIT,
            );
        }
        if (input.wheel != 0) camera.speed *= math::pow(FREE_SPEED_WHEEL_STEP, input.wheel);
    }
    Vec3 forward = free_forward(camera);
    Vec3 up = { 0, 1, 0 };
    Vec3 right = forward.cross(up).normalize();
    if (!input.keyboard_captured_by_gui) {
        Vec3 direction;
        if (input.key_down(platform::Scancode.W)) direction += forward;
        if (input.key_down(platform::Scancode.S)) direction -= forward;
        if (input.key_down(platform::Scancode.D)) direction += right;
        if (input.key_down(platform::Scancode.A)) direction -= right;
        if (input.key_down(platform::Scancode.E)) direction += up;
        if (input.key_down(platform::Scancode.Q)) direction -= up;
        float speed = camera.speed * (input.key_down(platform::Scancode.LSHIFT) ? FREE_FAST_MULTIPLIER : 1);
        camera.position += direction * (speed * delta_seconds);
    }
    camera_node.local.position = camera.position;
    camera_node.local.rotation = maths::look_rotation(forward, up);
}

fn MaterialId? add_colour(AssetStore* assets, Vec4 color, String key) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = 0.85f;
    return assets.add_material(material::standard(params), key);
}

fn Node*? add_block(
    Scene* scene,
    AssetStore* assets,
    MaterialId material,
    Vec3 size,
    Vec3 position,
    float pitch = 0,
) @local {
    GeometryId block;
    @pool() {
        Geometry geometry = geometry::box(tmem, size.x, size.y, size.z);
        block = assets.add_geometry(&geometry)!;
    };
    Node* node = scene.add_mesh(block, material)!;
    node.local.position = position;
    node.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, pitch);
    return node;
}

// The navmesh example's level: ramps, a stair, two walls, a platform with a ladder and a drop, and mud.
fn Level? build_level(AssetStore* assets, Scene* scene) @local {
    Level level;
    MaterialId floor_material = add_colour(assets, { 0.55f, 0.58f, 0.55f, 1 }, "crowd/floor")!;
    MaterialId block_material = add_colour(assets, { 0.75f, 0.62f, 0.45f, 1 }, "crowd/block")!;
    MaterialId steep_material = add_colour(assets, { 0.8f, 0.35f, 0.3f, 1 }, "crowd/steep")!;
    MaterialId platform_material = add_colour(assets, { 0.3f, 0.5f, 0.9f, 1 }, "crowd/platform")!;
    level.agent_material = add_colour(assets, { 0.2f, 0.7f, 0.35f, 1 }, "crowd/agent")!;
    level.selected_material = add_colour(assets, { 1, 0.75f, 0.1f, 1 }, "crowd/selected")!;

    GeometryId floor_geometry;
    @pool() {
        Geometry floor = geometry::plane(tmem, FLOOR_SIZE, FLOOR_SIZE);
        floor_geometry = assets.add_geometry(&floor, "crowd/floor_plane")!;
    };
    scene.add_mesh(floor_geometry, floor_material, name: "floor")!;

    add_block(
        scene:    scene,
        assets:   assets,
        material: block_material,
        size:     { 3, 0.2f, 6 },
        position: { -7, 0.85f, -5 },
        pitch:    RAMP_ANGLE,
    )!;
    add_block(
        scene:    scene,
        assets:   assets,
        material: steep_material,
        size:     { 3, 0.2f, 3 },
        position: { -1, 1.2f, -6 },
        pitch:    STEEP_RAMP_ANGLE,
    )!;
    for (uint step = 1; step <= 3; step++) {
        add_block(
            scene:    scene,
            assets:   assets,
            material: block_material,
            size:     { 4, step * STEP_HEIGHT, STEP_DEPTH },
            position: { -7, step * STEP_HEIGHT * 0.5f, 2 + step * STEP_DEPTH },
        )!;
    }
    add_block(
        scene:    scene,
        assets:   assets,
        material: block_material,
        size:     { 16, 2, 0.4f },
        position: { 0, 1, 10 },
    )!;
    add_block(
        scene:    scene,
        assets:   assets,
        material: block_material,
        size:     { 0.4f, 2, 7 },
        position: { 0, 1, 3 },
    )!;
    Node* platform = add_block(
        scene:    scene,
        assets:   assets,
        material: platform_material,
        size:     { 4, 1, 4 },
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
    Node* mud = scene.add_node(name: "mud")!;
    scene.add_nav_volume(mud, {
        .kind = BOX,
        .area = MUD_AREA,
        .box  = { .min = { 3, -0.5f, 2 }, .max = { 9, 0.5f, 8 } },
    })!;

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    scene.update_world();
    scene.add_nav_sources(scene.root);
    return level;
}

// Added after the level's sources, so the door is an obstacle and never rasterized; it starts open.
fn void? add_door(AssetStore* assets, Scene* scene, Level* level) @local {
    MaterialId door_material = add_colour(assets, { 0.55f, 0.3f, 0.2f, 1 }, "crowd/door")!;
    level.door = add_block(
        scene:    scene,
        assets:   assets,
        material: door_material,
        size:     DOOR_SIZE,
        position: DOOR_POSITION - { 0, DOOR_SINK, 0 },
    )!;
    level.door_open = true;
}

// A closed door is a cache obstacle; its tiles rebuild from their layers and the crowd replans through them.
fn void? toggle_door(Scene* scene, Level* level) @local {
    level.door_open = !level.door_open;
    if (level.door_open) {
        scene.remove_component(level.door, NavObstacle);
        level.door.local.position.y = DOOR_POSITION.y - DOOR_SINK;
        return;
    }
    level.door.local.position.y = DOOR_POSITION.y;
    scene.add_nav_obstacle(level.door, { .kind = BOX, .box = DOOR_OBSTACLE })!;
}

fn float next_random(void* context) @local => random::next_float((Lcg64Random*)context);

fn Vec3? random_goal(Crowd* crowd, Agents* agents) @local {
    RandomPoint point = crowd.query.find_random_point(crowd.filter(0), &next_random, &agents.generator)!;
    return point.point;
}

fn void? spawn_agents(
    AssetStore* assets,
    Scene* scene,
    Crowd* crowd,
    Level* level,
    Agents* agents,
) @local {
    GeometryId body;
    @pool() {
        Geometry capsule = geometry::capsule(tmem, AGENT_BODY_RADIUS, AGENT_BODY_HEIGHT);
        body = assets.add_geometry(&capsule, "crowd/agent_body")!;
    };
    NavAgentParams params = nav::default_nav_agent_params();
    for (uint index = 0; index < AGENT_COUNT; index++) {
        Node* node = scene.add_node(name: "agent")!;
        node.local.position = random_goal(crowd, agents)!;
        Node* mesh = scene.add_mesh(body, level.agent_material, parent: node)!;
        mesh.local.position = { 0, AGENT_BODY_LIFT, 0 };
        agents.nodes[index] = node;
        agents.bodies[index] = mesh;
        agents.retarget_at[index] = random::next_float(&agents.generator) * RETARGET_JITTER;
    }
    scene.update_world();
    foreach (node : agents.nodes) scene.add_nav_agent(node, params)!;
    select_agent(scene, level, agents, 0);
}

fn void select_agent(
    Scene* scene,
    Level* level,
    Agents* agents,
    uint index,
) @local {
    scene.get(agents.bodies[agents.selected], scene::Mesh).material = level.agent_material;
    agents.selected = index;
    scene.get(agents.bodies[index], scene::Mesh).material = level.selected_material;
}

fn void retarget_agents(
    Scene* scene,
    Crowd* crowd,
    Agents* agents,
    float now,
) @local {
    foreach (index, node : agents.nodes) {
        if (now < agents.retarget_at[index]) continue;
        agents.retarget_at[index] = now + RETARGET_SECONDS + random::next_float(&agents.generator) * RETARGET_JITTER;
        if (try goal = random_goal(crowd, agents)) scene.set_nav_target(node, goal);
    }
}

fn void move_all(Scene* scene, Agents* agents, Vec3 goal) @local {
    agents.goal = goal;
    agents.has_goal = true;
    foreach (node : agents.nodes) scene.set_nav_target(node, goal);
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

// A click on an agent's body selects it; anywhere else sends every agent there.
fn void click(
    Scene* scene,
    Level* level,
    Agents* agents,
    Controls* controls,
    PickHit hit,
) @local {
    foreach (index, body : agents.bodies) {
        if (hit.node != body) continue;
        select_agent(scene, level, agents, (uint)index);
        return;
    }
    controls.wander = false;
    move_all(scene, agents, hit.position);
}

fn uint mix_color(uint low, uint high, float t) @local {
    uint mixed;
    for (uint shift = 0; shift < 32; shift += 8) {
        float from = (float)((low >> shift) & 0xFF);
        float to = (float)((high >> shift) & 0xFF);
        mixed |= (uint)(from + (to - from) * t) << shift;
    }
    return mixed;
}

// Each scored sample as a ring at the agent plus its velocity, green for the lowest penalty and red for the highest.
fn void draw_samples(debug::DebugDraw* sink, CrowdAgent* agent, AvoidanceSample[] samples) @local {
    if (!samples.len) return;
    float lowest = float::max;
    float highest = -float::max;
    foreach (sample : samples) {
        lowest = math::min(lowest, sample.penalty);
        highest = math::max(highest, sample.penalty);
    }
    float range = math::max(highest - lowest, 0.001f);
    Vec3 up = { 0, 1, 0 };
    Vec3 origin = agent.position + { 0, 0.1f, 0 };
    foreach (sample : samples) {
        uint color = mix_color(LOW_PENALTY_COLOR, HIGH_PENALTY_COLOR, (sample.penalty - lowest) / range);
        sink.circle(origin + sample.velocity, up, math::max(sample.size * SAMPLE_MARK_SCALE, 0.02f), color);
    }
}

// The agent the slider selects.
fn uint draw_panel(
    Crowd* crowd,
    Level* level,
    Agents* agents,
    Controls* controls,
    CrowdDebugInfo* debug,
) @local {
    int selected = (int)agents.selected;
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Crowd", null, {})) {
        imgui::text("Click sends every agent; click an agent to select it");
        imgui::text("O opens and closes the door, C shows corridors, R resumes random goals");
        imgui::text("Right drag looks, WASDQE move");
        imgui::checkbox("Random goals", &controls.wander);
        imgui::checkbox("Agents", &controls.draw.agents);
        imgui::checkbox("Corridors", &controls.draw.corridors);
        imgui::checkbox("Boundaries", &controls.draw.boundaries);
        imgui::checkbox("Neighbours", &controls.draw.neighbours);
        imgui::checkbox("Avoidance samples", &controls.samples);
        imgui::checkbox("Polygons", &controls.mesh.polys);
        imgui::separator();
        CrowdAgent*[CROWD_CAPACITY] active;
        imgui::text("Agents: %u active, %u unbound", (uint)crowd.active_agents(active[..]), crowd.unbound);
        imgui::text("Velocity samples this update: %u", crowd.velocity_sample_count);
        imgui::text("Door: %s", level.door_open ? "open".ptr : "closed".ptr);
        imgui::separator();
        imgui::slider_int("Agent", &selected, 0, (int)AGENT_COUNT - 1);
        CrowdAgent* agent = crowd.agent(debug.index);
        @pool() {
            imgui::text("State: %s   target: %s", string::tformat_zstr("%s", agent.state),
                string::tformat_zstr("%s", agent.target_state));
        };
        imgui::text("Corners: %u   corridor: %u polygons   partial: %s", agent.corner_count, (uint)agent.corridor.count,
            agent.partial ? "yes".ptr : "no".ptr);
        imgui::text("Speed: %.2f of %.2f m/s   neighbours: %u", agent.velocity.length(), agent.desired_speed,
            agent.neighbour_count);
        imgui::text("Avoidance samples: %u   walls: %u", (uint)debug.sample_count, agent.boundary.segment_count);
    }
    imgui::end();
    return (uint)selected;
}

fn void draw_debug(
    NavMesh* mesh,
    Crowd* crowd,
    Level* level,
    Agents* agents,
    Controls* controls,
    debug::DebugDraw* sink,
    CrowdDebugInfo* debug,
) @local {
    sink.clear();
    mesh.debug_draw(sink, controls.mesh);
    crowd.debug_draw(sink, controls.draw);
    CrowdAgent* selected = crowd.agent(debug.index);
    Vec3 up = { 0, 1, 0 };
    sink.circle(selected.position + { 0, 0.05f, 0 }, up, selected.params.radius * 1.4f, SELECTED_COLOR);
    if (controls.samples) draw_samples(sink, selected, debug.samples[:debug.sample_count]);
    if (agents.has_goal && !controls.wander) sink.circle(agents.goal, up, MARKER_RADIUS, GOAL_COLOR);
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
        renderer.render_view(scene, camera_node, renderer.default_view, sink)!;
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
) @local {
    Level level = build_level(assets, scene)!;
    add_door(assets, scene, &level)!;
    NavBuilderDesc desc = nav::default_nav_builder_desc({
        .min = { -LEVEL_HALF_SIZE, -1, -LEVEL_HALF_SIZE },
        .max = { LEVEL_HALF_SIZE, LEVEL_TOP, LEVEL_HALF_SIZE },
    });
    desc.cache_layers = true;
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
        if (!built.pending && !builder.cache.update_count) break;
    }

    Crowd crowd = nav::create_crowd(
        allocator: mem,
        desc:      { .max_agents = CROWD_CAPACITY, .max_agent_radius = AGENT_BODY_RADIUS },
        mesh:      &mesh,
        scene:     scene,
    )!;
    defer nav::destroy_crowd(&crowd);
    crowd.filter(0).area_cost[MUD_AREA] = MUD_COST;
    Agents* agents = mem::new(Agents);
    defer free(agents);
    random::seed(&agents.generator, RANDOM_SEED);
    spawn_agents(
        assets: assets,
        scene:  scene,
        crowd:  &crowd,
        level:  &level,
        agents: agents,
    )!;
    AvoidanceSample[SAMPLE_CAPACITY] samples;
    CrowdDebugInfo debug = { .samples = samples[..] };

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw sink = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&sink);

    FreeCamera camera = {
        .position = CAMERA_START,
        .yaw      = (float)math::PI,
        .pitch    = CAMERA_START_PITCH,
        .speed    = FREE_SPEED,
    };
    Controls controls = {
        .draw    = { .agents = true },
        .mesh    = { .polys = true, .links = true },
        .wander  = true,
        .samples = true,
    };
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        uint selected = draw_panel(
            crowd:    &crowd,
            level:    &level,
            agents:   agents,
            controls: &controls,
            debug:    &debug,
        );
        if (selected != agents.selected) select_agent(scene, &level, agents, selected);

        if (!input.keyboard_captured_by_gui) {
            if (input.key_pressed(platform::Scancode.O)) toggle_door(scene, &level)!;
            if (input.key_pressed(platform::Scancode.R)) controls.wander = true;
            if (input.key_pressed(platform::Scancode.C)) controls.draw.corridors = !controls.draw.corridors;
        }
        if (input.button_pressed(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
            PickHit? hit = pick(
                assets:      assets,
                scene:       scene,
                camera_node: level.camera_node,
                pixel:       input.mouse_position,
                viewport:    { (float)window.width, (float)window.height },
            );
            if (try hit) {
                click(
                    scene:    scene,
                    level:    &level,
                    agents:   agents,
                    controls: &controls,
                    hit:      hit,
                );
            }
        }
        if (controls.wander) {
            retarget_agents(
                scene:  scene,
                crowd:  &crowd,
                agents: agents,
                now:    (float)window.clock.total,
            );
        }
        apply_free_camera(
            camera:        &camera,
            input:         input,
            camera_node:   level.camera_node,
            delta_seconds: window.clock.delta,
        );
        scene.update_world();

        // A rebuilt layer retires its polygon refs; the crowd replans the corridors through it.
        nav::nav_sync(
            builder: &builder,
            mesh:    &mesh,
            scene:   scene,
            assets:  assets,
            budget:  TILES_PER_FRAME,
        );
        debug.index = agents.selected;
        nav::crowd_update(
            scene: scene,
            crowd: &crowd,
            dt:    math::clamp(window.clock.delta, MIN_STEP, MAX_STEP),
            debug: &debug,
        );
        scene.update_world();

        draw_debug(
            mesh:     &mesh,
            crowd:    &crowd,
            level:    &level,
            agents:   agents,
            controls: &controls,
            sink:     &sink,
            debug:    &debug,
        );
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  level.camera_node,
            gui_renderer: &gui_renderer,
            sink:         &sink,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main() {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d crowd", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_crowd" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    nav::register_nav(&scene)!!;

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
    )) {
        io::eprintfn("crowd example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
