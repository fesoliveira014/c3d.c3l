module navmesh_example;

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

const uint  SCENE_NODE_CAPACITY @local = 64;
const float FLOOR_SIZE @local = 24;
const uint  FLOOR_SEGMENTS @local = 24; // 1152 floor triangles, so a low rasterization budget spans frames
const float LEVEL_HALF_SIZE @local = 12;
const float LEVEL_TOP @local = 6; // metres above the floor the builder voxelizes
const uint  TILES_PER_FRAME @local = 4;
const uint  RASTERIZE_BUDGET @local = 96; // triangles per call; low enough that a slot's spans stay on screen
const char  MUD_AREA @local = 2;
const float RAMP_ANGLE @local = 0.3f; // radians; 17 degrees, under the 45 degree slope limit
const float STEEP_RAMP_ANGLE @local = 1.0f; // radians; 57 degrees, over the slope limit
const float STEP_HEIGHT @local = 0.2f; // metres; the flight stays within the 0.9 m climb, so its sides are no ledge
const float STEP_DEPTH @local = 1.2f;
const Vec3  PLATFORM_HOME @local = { 7, 0.5f, -6 };
const float PLATFORM_SHIFT @local = 4; // metres along X each press of M
const uint  SPAN_COLOR @local = 0xFF40FFFF;
const float FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float FREE_SPEED @local = 8;
const float FREE_FAST_MULTIPLIER @local = 4;
const float FREE_SPEED_WHEEL_STEP @local = 1.25f;
const Vec3  CAMERA_START @local = { 0, 14, 20 };
const float CAMERA_START_PITCH @local = -0.6f;
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 430, 380 };
const uint  QUERY_NODES @local = 2048; // 64 KiB of search nodes; the level's whole graph fits
const usz   CORRIDOR_CAPACITY @local = 256;
const usz   POINT_CAPACITY @local = 64;
const Vec3  WALKER_START @local = { -9, 0, 8 };
const Vec3  SNAP_EXTENTS @local = { 2, 4, 2 }; // metres; finds the floor or the platform under a pick
const float WALK_SPEED @local = 3; // metres per second
const float LINK_RADIUS @local = 0.6f;
const Vec3  LADDER_BOTTOM @local = { 0, -0.5f, 3.5f }; // platform space; the floor on the +Z side
const Vec3  LADDER_TOP @local = { 0, 0.5f, 0 };
const Vec3  DROP_TOP @local = { 1.2f, 0.5f, 0 }; // platform space; one way down to the floor on the +X side
const Vec3  DROP_BOTTOM @local = { 3.5f, -0.5f, 0 };
const Vec3  PLATFORM_GOAL @local = { 7, 1, -6 };
const Vec3  FLOOR_GOAL @local = { 9, 0, 9 };
const uint  PATH_COLOR @local = 0xFF20E0FF;
const uint  WALKER_COLOR @local = 0xFFFFFF40;
const uint  GOAL_COLOR @local = 0xFF4040FF;
const float MARKER_RADIUS @local = 0.35f;
const float WANDER_RADIUS @local = 8; // metres around the walker a wander goal is drawn from
const float WANDER_ARRIVAL @local = 0.3f; // metres; this close to its goal the walker draws a new one
const float STUCK_FRACTION @local = 0.1f; // a step covering less than this share of its length is blocked
const float WALL_SEARCH_RADIUS @local = 3; // metres; the wall circle never grows past it
const usz   MOVE_VISITED_CAPACITY @local = 16;
const ulong WANDER_SEED @local = 0x3a11;
const uint  WALL_COLOR @local = 0xFF40A0FF;

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    float speed;
}

struct Controls @local {
    NavDebugOptions     draw;
    NavMeshDebugOptions mesh;
    bool                spans;
}

struct BuildTotals @local {
    uint built;
    uint skipped;
    uint failed;
}

struct Level @local {
    Node* platform;
    Node* ladder;             // two-way NavLink up the platform's +Z side; L makes it one-way up
    Node* drop;               // one-way NavLink down the platform's +X side
    Node* camera_node;
    bool  platform_shifted;
}

struct Walker @local {
    Vec3                          position;
    Vec3                          goal;
    bool                          has_goal;
    bool                          replan;
    bool                          wander;
    PolyRef                       ref;           // polygon under the walker while wandering
    WallHit                       wall;
    bool                          has_wall;
    Lcg64Random                   generator;
    PolyRef[CORRIDOR_CAPACITY]    corridor;
    StraightPoint[POINT_CAPACITY] points;
    PathResult                    path;
    PathResult                    straight;
    usz                           next_point;
    float                         length;
    uint                          nodes_used;
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

fn Level? build_level(AssetStore* assets, Scene* scene) @local {
    Level level;
    MaterialId floor_material = add_colour(assets, { 0.55f, 0.58f, 0.55f, 1 }, "navmesh/floor")!;
    MaterialId block_material = add_colour(assets, { 0.75f, 0.62f, 0.45f, 1 }, "navmesh/block")!;
    MaterialId steep_material = add_colour(assets, { 0.8f, 0.35f, 0.3f, 1 }, "navmesh/steep")!;
    MaterialId platform_material = add_colour(assets, { 0.3f, 0.5f, 0.9f, 1 }, "navmesh/platform")!;

    GeometryId floor_geometry;
    @pool() {
        Geometry floor = geometry::plane(tmem, FLOOR_SIZE, FLOOR_SIZE, FLOOR_SEGMENTS, FLOOR_SEGMENTS);
        floor_geometry = assets.add_geometry(&floor, "navmesh/floor_plane")!;
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
    level.platform = add_block(
        scene:    scene,
        assets:   assets,
        material: platform_material,
        size:     { 4, 1, 4 },
        position: PLATFORM_HOME,
    )!;

    level.ladder = scene.add_node(level.platform, "ladder")!;
    scene.add_nav_link(level.ladder, {
        .start         = LADDER_BOTTOM,
        .end           = LADDER_TOP,
        .radius        = LINK_RADIUS,
        .bidirectional = true,
        .area          = nav::WALKABLE_AREA,
    })!;
    level.drop = scene.add_node(level.platform, "drop")!;
    scene.add_nav_link(level.drop, {
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

fn void move_platform(Scene* scene, Level* level) @local {
    level.platform_shifted = !level.platform_shifted;
    level.platform.local.position.x = PLATFORM_HOME.x - (level.platform_shifted ? PLATFORM_SHIFT : 0);
    scene.update_world();
    scene.get(level.platform, NavSource).mark_changed();
    scene.get(level.ladder, NavLink).mark_changed();
    scene.get(level.drop, NavLink).mark_changed();
}

fn void toggle_ladder(Scene* scene, Level* level) @local {
    NavLink* ladder = scene.get(level.ladder, NavLink);
    ladder.bidirectional = !ladder.bidirectional;
    ladder.mark_changed();
}

fn void set_goal(Walker* walker, Vec3 goal) @local {
    walker.goal = goal;
    walker.has_goal = true;
    walker.replan = true;
}

fn Vec3? pick_goal(
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
        return hits[0].position;
    };
}

// Snaps the walker and the goal onto the mesh, then plans the corridor and its straight points.
fn void plan_walk(Walker* walker, NavQuery* query, QueryFilter* filter) @local {
    walker.replan = false;
    walker.path = {};
    walker.straight = {};
    walker.next_point = 0;
    walker.length = 0;
    NearestPoly? start = query.find_nearest_poly(walker.position, SNAP_EXTENTS, filter);
    NearestPoly? goal = query.find_nearest_poly(walker.goal, SNAP_EXTENTS, filter);
    if (catch start, goal) return;
    walker.position = start.point;
    PathResult? corridor = query.find_path(
        start_ref: start.ref,
        end_ref:   goal.ref,
        start:     start.point,
        end:       goal.point,
        filter:    filter,
        out_path:  walker.corridor[..],
    );
    if (catch corridor) return;
    walker.path = corridor;
    walker.nodes_used = query.nodes.count;
    PathResult? straight = query.straight_path(
        start:      start.point,
        end:        goal.point,
        path:       walker.corridor[:corridor.count],
        out_points: walker.points[..],
    );
    if (catch straight) return;
    walker.straight = straight;
    walker.next_point = 1;
    for (usz index = 1; index < straight.count; index++) {
        walker.length += (walker.points[index].position - walker.points[index - 1].position).length();
    }
}

fn void advance_walker(Walker* walker, float delta_seconds) @local {
    float step = WALK_SPEED * delta_seconds;
    while (walker.next_point < walker.straight.count && step > 0) {
        Vec3 target = walker.points[walker.next_point].position;
        Vec3 offset = target - walker.position;
        float distance = offset.length();
        if (distance <= step) {
            walker.position = target;
            step -= distance;
            walker.next_point++;
        } else {
            walker.position += offset * (step / distance);
            step = 0;
        }
    }
}

fn float next_wander_random(void* context) @local => random::next_float((Lcg64Random*)context);

fn void toggle_wander(Walker* walker) @local {
    walker.wander = !walker.wander;
    walker.has_goal = false;
    walker.has_wall = false;
    walker.path = {};
    walker.straight = {};
    walker.ref = (PolyRef)0;
}

// A walker whose polygon went away with a reinstalled tile is snapped onto the mesh again.
fn void? snap_walker(Walker* walker, NavQuery* query, QueryFilter* filter) @local {
    if (query.is_valid_ref(walker.ref, filter)) return;
    NearestPoly nearest = query.find_nearest_poly(walker.position, SNAP_EXTENTS, filter)!;
    walker.ref = nearest.ref;
    walker.position = nearest.point;
}

// Draws goals within reach, slides toward them along the surface and measures the room to the nearest wall.
fn void wander(
    Walker* walker,
    NavQuery* query,
    QueryFilter* filter,
    float delta_seconds,
) @local {
    if (catch snap_walker(walker, query, filter)) return;
    if (!walker.has_goal) {
        RandomPoint? goal = query.find_random_point_around_circle(
            start_ref:  walker.ref,
            center:     walker.position,
            max_radius: WANDER_RADIUS,
            filter:     filter,
            random:     &next_wander_random,
            context:    &walker.generator,
        );
        if (catch goal) return;
        walker.goal = goal.point;
        walker.has_goal = true;
    }
    Vec3 offset = walker.goal - walker.position;
    offset.y = 0;
    float distance = offset.length();
    if (distance < WANDER_ARRIVAL) {
        walker.has_goal = false;
        return;
    }

    float step = math::min(WALK_SPEED * delta_seconds, distance);
    PolyRef[MOVE_VISITED_CAPACITY] visited;
    MoveResult? moved = query.move_along_surface(
        start_ref:   walker.ref,
        start:       walker.position,
        end:         walker.position + offset * (step / distance),
        filter:      filter,
        out_visited: visited[..],
    );
    if (catch moved) return;
    Vec3 travelled = moved.position - walker.position;
    travelled.y = 0;
    if (moved.visited_count) walker.ref = visited[moved.visited_count - 1];
    walker.position = moved.position;
    walker.position.y = query.poly_height(walker.ref, walker.position) ?? walker.position.y;
    // A wall between the walker and its goal leaves it sliding in place, so it draws another goal.
    if (travelled.length() < step * STUCK_FRACTION) walker.has_goal = false;

    WallHit? wall = query.find_distance_to_wall(
        start_ref:  walker.ref,
        center:     walker.position,
        max_radius: WALL_SEARCH_RADIUS,
        filter:     filter,
    );
    walker.has_wall = @ok(wall);
    if (try wall) walker.wall = wall;
}

fn void draw_walker(Walker* walker, debug::DebugDraw* sink) @local {
    Vec3 up = { 0, 1, 0 };
    sink.circle(walker.position, up, MARKER_RADIUS, WALKER_COLOR);
    sink.line(walker.position, walker.position + up, WALKER_COLOR);
    if (walker.wander && walker.has_wall) {
        // A walker slid flush against a wall has no room left to draw.
        if (walker.wall.distance > 0) sink.circle(walker.position, up, walker.wall.distance, WALL_COLOR);
        sink.line(walker.position, walker.wall.point, WALL_COLOR);
    }
    if (!walker.has_goal) return;
    sink.circle(walker.goal, up, MARKER_RADIUS, GOAL_COLOR);
    nav::debug_draw_path(sink, walker.points[:walker.straight.count], PATH_COLOR);
}

fn void draw_panel(
    NavBuilder* builder,
    Controls* controls,
    BuildTotals* totals,
    Walker* walker,
    NavLink* ladder,
) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Navmesh", null, {})) {
        imgui::text("Click, 1 or 2 sets the goal; L toggles the ladder");
        imgui::text("M moves the platform; right drag looks, WASDQE move");
        imgui::text("R wanders: random goals, sliding moves, the wall circle");
        imgui::checkbox("Tiles", &controls.draw.tiles);
        imgui::checkbox("Polygons", &controls.mesh.polys);
        imgui::checkbox("Links", &controls.mesh.links);
        imgui::checkbox("Spans of the rasterizing slot", &controls.spans);
        imgui::separator();
        imgui::text("Tiles: %u x %u   dirty: %u", builder.tiles_x, builder.tiles_z, builder.dirty_count);
        imgui::text("Built: %u   skipped sources: %u   failed: %u", totals.built, totals.skipped, totals.failed);
        imgui::separator();
        imgui::text("Ladder: %s", ladder.bidirectional ? "two-way".ptr : "one-way up".ptr);
        imgui::text("Path: %u polygons, %u points, %.1f m", (uint)walker.path.count, (uint)walker.straight.count, walker.length);
        imgui::text("Partial: %s   truncated: %s", walker.path.partial ? "yes".ptr : "no".ptr,
            walker.path.truncated || walker.straight.truncated ? "yes".ptr : "no".ptr);
        imgui::text("Nodes: %u of %u", walker.nodes_used, QUERY_NODES);
        imgui::text("Wander: %s   wall: %.2f m", walker.wander ? "on".ptr : "off".ptr,
            walker.has_wall ? walker.wall.distance : WALL_SEARCH_RADIUS);
        if (totals.failed) {
            TileFailure failure = builder.last_failure;
            @pool() {
                imgui::text("Last failure: tile %d %d, %s at %s", failure.tile_x, failure.tile_z,
                    string::tformat_zstr("%s", failure.reason), string::tformat_zstr("%s", failure.stage));
            };
        }
    }
    imgui::end();
}

fn void draw_debug(
    NavBuilder* builder,
    NavMesh* mesh,
    debug::DebugDraw* sink,
    Controls* controls,
) @local {
    sink.clear();
    builder.debug_draw(sink, controls.draw);
    mesh.debug_draw(sink, controls.mesh);
    if (!controls.spans) return;
    foreach (&job : builder.jobs) {
        if (job.state == RASTERIZING) nav::debug_draw_heightfield(&job.heightfield, sink, SPAN_COLOR);
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
    NavBuilderDesc desc = nav::default_nav_builder_desc({
        .min = { -LEVEL_HALF_SIZE, -1, -LEVEL_HALF_SIZE },
        .max = { LEVEL_HALF_SIZE, LEVEL_TOP, LEVEL_HALF_SIZE },
    });
    desc.rasterize_budget = RASTERIZE_BUDGET;
    NavBuilder builder = nav::create_nav_builder(mem, scene, desc)!;
    defer nav::destroy_nav_builder(&builder);
    NavMesh mesh = nav::create_nav_mesh_for(mem, &builder)!;
    defer nav::destroy_nav_mesh(&mesh);
    NavQuery query = nav::create_nav_query(mem, &mesh, QUERY_NODES)!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    Walker* walker = mem::new(Walker);
    defer free(walker);
    walker.position = WALKER_START;
    random::seed(&walker.generator, WANDER_SEED);

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
    Controls controls = { .draw = { .tiles = true }, .mesh = { .polys = true, .links = true }, .spans = true };
    BuildTotals totals;
    renderer.prepare_scene(scene)!;

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        draw_panel(
            builder:  &builder,
            controls: &controls,
            totals:   &totals,
            walker:   walker,
            ladder:   scene.get(level.ladder, NavLink),
        );

        if (!input.keyboard_captured_by_gui) {
            if (input.key_pressed(platform::Scancode.M)) move_platform(scene, &level);
            if (input.key_pressed(platform::Scancode.L)) toggle_ladder(scene, &level);
            if (input.key_pressed(platform::Scancode.CODE_1)) set_goal(walker, PLATFORM_GOAL);
            if (input.key_pressed(platform::Scancode.CODE_2)) set_goal(walker, FLOOR_GOAL);
            if (input.key_pressed(platform::Scancode.R)) toggle_wander(walker);
        }
        if (input.button_pressed(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
            Vec3? picked = pick_goal(
                assets:      assets,
                scene:       scene,
                camera_node: level.camera_node,
                pixel:       input.mouse_position,
                viewport:    { (float)window.width, (float)window.height },
            );
            if (try picked) set_goal(walker, picked);
        }
        apply_free_camera(
            camera:        &camera,
            input:         input,
            camera_node:   level.camera_node,
            delta_seconds: window.clock.delta,
        );
        scene.update_world();

        NavSyncResult result = nav::nav_sync(
            builder: &builder,
            mesh:    &mesh,
            scene:   scene,
            assets:  assets,
            budget:  TILES_PER_FRAME,
        );
        totals.built += result.built;
        totals.skipped += result.skipped;
        totals.failed += result.failed;
        if (walker.wander) {
            wander(
                walker:        walker,
                query:         &query,
                filter:        &filter,
                delta_seconds: window.clock.delta,
            );
        } else {
            // An install invalidates the refs of the tiles it replaced, so the walk is planned again.
            if (walker.has_goal && (walker.replan || result.installed)) plan_walk(walker, &query, &filter);
            advance_walker(walker, window.clock.delta);
        }
        draw_debug(
            builder:  &builder,
            mesh:     &mesh,
            sink:     &sink,
            controls: &controls,
        );
        draw_walker(walker, &sink);
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
    platform::Window window = platform::create_window(platform::default_window_desc("c3d navmesh", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_navmesh" },
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
        io::eprintfn("navmesh example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
