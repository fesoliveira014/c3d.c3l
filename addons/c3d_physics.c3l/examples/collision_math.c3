module collision_math_example;

import std::io;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::maths;
import c3d::physics::collide;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::spatial::bvh;
import imgui;

alias Quat @private = Quaternionf;

const float MOVE_SPEED @local = 2;
const float SPIN_SPEED @local = 0.6f;
const Vec3  SPIN_AXIS @local = { 0.3f, 1, 0.2f };
const float SWEEP_LENGTH @local = 6;
const float MARKER_SIZE @local = 0.06f;
const Vec3  SHAPE_A_POSITION @local = { 0, 1, 0 };
const Vec3  SHAPE_B_START @local = { -2.5f, 1.2f, 0.3f };
const Vec3  CAMERA_POSITION @local = { 0, 4, 8 };
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 380, 300 };
const Vec2  STATS_PANEL_POSITION @local = { 16, 332 };
const Vec2  STATS_PANEL_SIZE @local = { 380, 360 };
const int   SHAPE_KIND_COUNT @local = 4;
const uint  SCATTER_BOXES @local = 64;
const uint  SCATTER_SEED @local = 0x2545f491;
const Vec3  SCATTER_MIN @local = { -6, 0, -7 }; // behind the shapes, in view of the camera
const Vec3  SCATTER_MAX @local = { 6, 3, -2 };
const float SCATTER_HALF_MIN @local = 0.1f;
const float SCATTER_HALF_MAX @local = 0.35f;

struct Demo @local {
    Shape[SHAPE_KIND_COUNT] shapes;
    int                     kind_a;
    int                     kind_b;
    maths::Transform        pose_a;
    maths::Transform        pose_b;
    float                   spin;
}

struct Scatter @local {
    Aabb[] boxes;
    Bvh    tree;
    bool   picked;
    uint   picked_box;
}

fn float next_unit(uint* state) @local {
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return (float)(*state >> 8) / (float)(1u << 24);
}

fn Scatter? create_scatter() @local {
    Aabb[] boxes = alloc::new_array(mem, Aabb, (sz)SCATTER_BOXES);
    defer catch alloc::free(mem, boxes.ptr);
    uint state = SCATTER_SEED;
    foreach (&box : boxes) {
        Vec3 center;
        Vec3 half;
        for (usz axis = 0; axis < 3; axis++) {
            center[axis] = SCATTER_MIN[axis] + (SCATTER_MAX[axis] - SCATTER_MIN[axis]) * next_unit(&state);
            half[axis] = SCATTER_HALF_MIN + (SCATTER_HALF_MAX - SCATTER_HALF_MIN) * next_unit(&state);
        }
        *box = { .min = center - half, .max = center + half };
    }
    return { .boxes = boxes, .tree = bvh::build_box_bvh(mem, boxes)! };
}

fn void destroy_scatter(Scatter* scatter) @local {
    bvh::free_bvh(mem, &scatter.tree);
    alloc::free(mem, scatter.boxes.ptr);
}

fn void pick_scatter_box(Scatter* scatter, Ray ray) @local {
    float nearest = math::FLOAT_MAX;
    scatter.picked = false;
    scatter.tree.@each_ray_hit(ray, math::FLOAT_MAX; uint primitive) {
        float distance;
        if (maths::ray_intersects_aabb(ray, scatter.boxes[primitive], &distance) && distance < nearest) {
            nearest = distance;
            scatter.picked = true;
            scatter.picked_box = primitive;
        }
    };
}

fn void draw_scatter(debug::DebugDraw* draw, Scatter* scatter) @local {
    foreach (uint index, box : scatter.boxes) {
        bool picked = scatter.picked && scatter.picked_box == index;
        draw.box(matrix::IDENTITY4, box, picked ? debug::COLOR_YELLOW : debug::rgba(0.6f, 0.6f, 0.6f));
    }
}

fn Ray cursor_ray(
    Scene* scene,
    Node* camera_node,
    Input* input,
    Vec2 viewport,
) @local {
    camera::Camera* camera = scene.get(camera_node, camera::Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
    return camera::screen_to_ray(&matrices, input.mouse_position, viewport);
}

fn Shape[SHAPE_KIND_COUNT] make_shapes(Hull* hull) @local {
    return {
        collide::sphere_shape(0.6f),
        collide::capsule_shape(0.5f, 0.35f),
        collide::box_shape({ 0.8f, 0.4f, 0.5f }),
        collide::hull_shape(hull),
    };
}

fn void draw_shape(debug::DebugDraw* draw, Shape shape, maths::Transform pose, uint rgba) @local {
    switch (shape.kind) {
        case SPHERE:
            draw.circle(pose.position, { 1, 0, 0 }, shape.radius, rgba);
            draw.circle(pose.position, { 0, 1, 0 }, shape.radius, rgba);
            draw.circle(pose.position, { 0, 0, 1 }, shape.radius, rgba);
        case CAPSULE:
            Vec3 axis = pose.rotation.rotate_vec3({ 0, 1, 0 });
            draw.capsule(
                center:      pose.position,
                axis:        axis,
                half_height: shape.half_height,
                radius:      shape.radius,
                rgba:        rgba,
            );
        case BOX:
            draw.box(pose.to_mat4(), { .min = -shape.half_extents, .max = shape.half_extents }, rgba);
        case HULL:
            foreach (local_point : collide::hull_points(shape)) {
                Vec3 point = pose.rotation.rotate_vec3(local_point) + pose.position;
                draw.line(point - (Vec3){ MARKER_SIZE, 0, 0 }, point + (Vec3){ MARKER_SIZE, 0, 0 }, rgba);
                draw.line(point - (Vec3){ 0, MARKER_SIZE, 0 }, point + (Vec3){ 0, MARKER_SIZE, 0 }, rgba);
                draw.line(point - (Vec3){ 0, 0, MARKER_SIZE }, point + (Vec3){ 0, 0, MARKER_SIZE }, rgba);
            }
    }
}

fn void draw_marker(debug::DebugDraw* draw, Vec3 point, uint rgba) @local {
    draw.circle(point, { 0, 1, 0 }, MARKER_SIZE, rgba);
    draw.circle(point, { 1, 0, 0 }, MARKER_SIZE, rgba);
}

fn void move_shape_b(Demo* demo, Input* input, float delta) @local {
    if (input.keyboard_captured_by_gui) return;
    Vec3 direction;
    if (input.key_down(Scancode.LEFT)) direction.x -= 1;
    if (input.key_down(Scancode.RIGHT)) direction.x += 1;
    if (input.key_down(Scancode.UP)) direction.z -= 1;
    if (input.key_down(Scancode.DOWN)) direction.z += 1;
    if (input.key_down(Scancode.PAGEUP)) direction.y += 1;
    if (input.key_down(Scancode.PAGEDOWN)) direction.y -= 1;
    demo.pose_b.position += direction * (MOVE_SPEED * delta);
}

fn void draw_queries(debug::DebugDraw* draw, Demo* demo) @local {
    Shape shape_a = demo.shapes[demo.kind_a];
    Shape shape_b = demo.shapes[demo.kind_b];
    draw_shape(draw, shape_a, demo.pose_a, debug::rgba(0.3f, 0.7f, 1));
    draw_shape(draw, shape_b, demo.pose_b, debug::rgba(1, 0.8f, 0.3f));

    collide::Manifold contact = collide::manifold(
        a:      shape_a,
        pose_a: demo.pose_a,
        b:      shape_b,
        pose_b: demo.pose_b,
    );
    for (uint index = 0; index < contact.count; index++) {
        Vec3 point = contact.points[index].point;
        draw_marker(draw, point, debug::rgba(1, 0.2f, 0.2f));
        draw.line(point, point + contact.normal * 0.5f, debug::rgba(1, 0.2f, 0.2f));
    }

    Distance closest = collide::distance(
        a:      shape_a,
        pose_a: demo.pose_a,
        b:      shape_b,
        pose_b: demo.pose_b,
    );
    if (closest.distance > 0) draw.line(closest.point_a, closest.point_b, debug::rgba(0.3f, 1, 0.3f));

    Vec3 sweep = (demo.pose_a.position - demo.pose_b.position).normalize() * SWEEP_LENGTH;
    maths::Transform end = demo.pose_b;
    end.position += sweep;
    draw.line(demo.pose_b.position, end.position, debug::rgba(0.7f, 0.7f, 0.7f));
    maths::Transform spun = demo.pose_a;
    spun.rotation = quaternion::from_axis_angle{float}(SPIN_AXIS.normalize(), demo.spin + SPIN_SPEED);
    collide::Sweep sweep_a = { .start = demo.pose_a, .end = spun };
    collide::Sweep sweep_b = { .start = demo.pose_b, .end = end };
    if (try impact = collide::time_of_impact(
        a:       shape_a,
        sweep_a: sweep_a,
        b:       shape_b,
        sweep_b: sweep_b,
    )) {
        maths::Transform touching = demo.pose_b;
        touching.position += sweep * impact.time;
        draw_shape(draw, shape_b, touching, debug::rgba(1, 1, 1, 0.5f));
        draw_marker(draw, impact.point, debug::rgba(1, 1, 1));
    }
}

fn void shape_picker(String suffix, int* kind) @local {
    ZString[SHAPE_KIND_COUNT] names = { "Sphere", "Capsule", "Box", "Hull" };
    for (int index = 0; index < SHAPE_KIND_COUNT; index++) {
        @pool() {
            ZString label = string::tformat("%s##%s", names[index], suffix).zstr_tcopy();
            if (imgui::radio_button(label, *kind == index)) *kind = index;
        };
        if (index + 1 < SHAPE_KIND_COUNT) imgui::same_line();
    }
}

fn void draw_panel(Demo* demo, render::Renderer* renderer) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Collision queries", null, {})) {
        imgui::text("Arrows and Page Up/Down move shape B");
        imgui::text("Left click highlights the nearest grey box");
        imgui::separator_text("Shape A");
        shape_picker("a", &demo.kind_a);
        imgui::separator_text("Shape B");
        shape_picker("b", &demo.kind_b);
        collide::Manifold contact = collide::manifold(
            a:      demo.shapes[demo.kind_a],
            pose_a: demo.pose_a,
            b:      demo.shapes[demo.kind_b],
            pose_b: demo.pose_b,
        );
        Distance closest = collide::distance(
            a:      demo.shapes[demo.kind_a],
            pose_a: demo.pose_a,
            b:      demo.shapes[demo.kind_b],
            pose_b: demo.pose_b,
        );
        imgui::separator_text("Results");
        imgui::text("Manifold points: %u", contact.count);
        imgui::text("Distance: %.3f", (double)closest.distance);
    }
    imgui::end();
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    debug::DebugDraw* debug,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view, debug)!;
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
    Hull* hull,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw draw = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&draw);

    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    camera_node.local.position = CAMERA_POSITION;
    camera_node.local.rotation = maths::look_rotation(SHAPE_A_POSITION - CAMERA_POSITION, { 0, 1, 0 });

    Demo demo = {
        .shapes = make_shapes(hull),
        .kind_a = 2,
        .kind_b = 1,
        .pose_a = { .position = SHAPE_A_POSITION, .rotation = { 0, 0, 0, 1 }, .scale = { 1, 1, 1 } },
        .pose_b = { .position = SHAPE_B_START, .rotation = { 0, 0, 0, 1 }, .scale = { 1, 1, 1 } },
    };
    renderer.prepare_scene(scene)!;
    Scatter scatter = create_scatter()!;
    defer destroy_scatter(&scatter);

    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        float delta = window.clock.delta;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        demo.spin += delta * SPIN_SPEED;
        demo.pose_a.rotation = quaternion::from_axis_angle{float}(SPIN_AXIS.normalize(), demo.spin);
        move_shape_b(&demo, input, delta);
        if (input.button_pressed(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
            Vec2 viewport = { (float)window.width, (float)window.height };
            Ray ray = cursor_ray(
                scene:       scene,
                camera_node: camera_node,
                input:       input,
                viewport:    viewport,
            );
            pick_scatter_box(&scatter, ray);
            if (scatter.picked) io::printfn("picked box %d", scatter.picked_box);
        }
        draw_panel(&demo, renderer);
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        scene.update_world();
        draw.clear();
        draw_queries(&draw, &demo);
        draw_scatter(&draw, &scatter);
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  camera_node,
            gui_renderer: &gui_renderer,
            debug:        &draw,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
    }
}

fn int main() {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d collision math", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_collision_math" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    Hull hull;
    @pool() {
        Geometry cone = geometry::cone(tmem, 0.6f, 1.2f, 12);
        hull = collide::create_hull(cone.positions)!!;
    };
    defer collide::destroy_hull(&hull);

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        scene:    &scene,
        hull:     &hull,
    )) {
        io::eprintfn("collision math example failed: %s", excuse);
        return 1;
    }
    return 0;
}
