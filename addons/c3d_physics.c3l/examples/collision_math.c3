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
import c3d::physics;
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
const Vec3  CAST_A_TRANSLATION @local = { 0, 0.4f, 0 }; // shape A drifts while B closes on it
const Vec3  RAY_ORIGIN @local = { -1.5f, 4, 0 };
const Vec3  RAY_DIRECTION @local = { 0, -1, 0 };
const float RAY_LENGTH @local = 8;
const float MARKER_SIZE @local = 0.06f;
const float NORMAL_TICK @local = 0.3f;
const Vec3  SHAPE_A_POSITION @local = { 0, 1, 0 };
const Vec3  SHAPE_B_START @local = { -2.5f, 1.2f, 0.3f };
const Vec3  CAMERA_POSITION @local = { 0, 4, 8 };
const Vec2  PANEL_POSITION @local = { 16, 16 };
const Vec2  PANEL_SIZE @local = { 440, 700 };
const Vec2  STATS_PANEL_POSITION @local = { 884, 16 };
const Vec2  STATS_PANEL_SIZE @local = { 380, 360 };
const Vec4  FAULT_COLOR @local = { 1, 0.4f, 0.4f, 1 };
const int   SHAPE_KIND_COUNT @local = 5;
const int   UNIFORM_SCALE_KIND_COUNT @local = 2; // sphere and capsule take one scale for every axis
const int   MESH_KIND @local = 4;
const float SCALE_MIN @local = 0.001f; // under the capsule, box, hull and mesh minimums, so their refusals can be shown
const float SCALE_MAX @local = 4;
const usz   CONTACT_CAPACITY @local = 64; // one hull manifold fits per triangle; more contacts report CAPACITY_EXCEEDED
const usz   CONTACT_ROWS_SHOWN @local = 6;
const uint  RAMP_SEGMENTS @local = 4;
const float RAMP_SEGMENT_RUN @local = 1;
const float RAMP_SLOPE @local = 0.5f;
const float RAMP_HALF_WIDTH @local = 1;
const uint  SCATTER_BOXES @local = 64;
const uint  SCATTER_SEED @local = 0x2545f491;
const Vec3  SCATTER_MIN @local = { -6, 0, -7 }; // behind the shapes, in view of the camera
const Vec3  SCATTER_MAX @local = { 6, 3, -2 };
const float SCATTER_HALF_MIN @local = 0.1f;
const float SCATTER_HALF_MAX @local = 0.35f;
const uint  VIEW_WIDTH @local = 1280;
const uint  VIEW_HEIGHT @local = 720;
const uint  CAPTURE_CHANNELS @local = 4;
const uint  ACCEPTANCE_FRAMES @local = 180;
const uint  ACCEPTANCE_DESCENT_FRAMES @local = 120; // shape B settles over the mesh, then rests until the capture
const float ACCEPTANCE_STEP @local = 1.0f / 60;
const Vec3  ACCEPTANCE_B_START @local = { 1.04f, 3, 0 };
const Vec3  ACCEPTANCE_B_REST @local = { 1.04f, 1.35f, 0 }; // 0.3 above the reflected ramp's surface
const Vec3  ACCEPTANCE_MESH_SCALE @local = { 1, 1.5f, 1 }; // the slot reflects X, so the mesh is also non-uniform
const Vec3  ACCEPTANCE_CAMERA_POSITION @local = { 0.4f, 2.4f, 5.5f };
const Vec3  ACCEPTANCE_CAMERA_TARGET @local = { 0.2f, 1.3f, 0 };
const int   ACCEPTANCE_KIND_A @local = 4;
const int   ACCEPTANCE_KIND_B @local = 0;
const String[SHAPE_KIND_COUNT] KIND_NAMES @local = { "Sphere", "Capsule", "Box", "Hull", "Mesh" };

struct Options @local {
    bool   acceptance;
    uint   frames;
    String capture_path;
}

struct ShapeSlot @local {
    int                kind;
    float              uniform_scale;
    Vec3               axis_scale;
    bool               reflected;
    CollisionShape     shape;
    CollisionShapeDesc description;
    fault              refusal;
}

struct Demo @local {
    CollisionShapeDesc[SHAPE_KIND_COUNT] descriptions;
    Vec3[] hull_points;
    Vec3[] mesh_points;
    uint[] mesh_indices;
    ShapeSlot               slot_a;
    ShapeSlot               slot_b;
    maths::Transform        pose_a;
    maths::Transform        pose_b;
    float                   spin;
}

struct QueryResults @local {
    CollisionContact[CONTACT_CAPACITY] contacts;
    usz              contact_count;
    fault            contacts_fault;
    Distance         closest;
    fault            distance_fault;
    Vec3             closing;
    Impact           cast_impact;
    fault            cast_fault;
    Impact           sweep_impact;
    fault            sweep_fault;
    ShapeRayHit      ray_hit;
    fault            ray_fault;
}

struct Scatter @local {
    Aabb[] boxes;
    Bvh    tree;
    bool   picked;
    uint   picked_box;
}

fn Options? parse_options(String[] args) @local {
    Options options;
    for (usz index = 1; index < args.len; index++) {
        String arg = args[index];
        if (arg == "--acceptance") {
            options.acceptance = true;
        } else if (arg.starts_with("--frames=")) {
            options.frames = arg[9..].to_uint()!;
        } else if (arg.starts_with("--capture=")) {
            options.capture_path = arg[10..];
        } else {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    if ((options.capture_path.len || options.frames) && !options.acceptance) return c3d::INVALID_ARGUMENT~;
    if (options.acceptance && !options.frames) options.frames = ACCEPTANCE_FRAMES;

    return options;
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

fn Geometry make_ramp(Allocator allocator) @local {
    Geometry ramp = {
        .positions = alloc::new_array(allocator, Vec3, (RAMP_SEGMENTS + 1) * 2),
        .indices = alloc::new_array(allocator, uint, RAMP_SEGMENTS * 6),
    };
    float centre = RAMP_SEGMENTS * RAMP_SEGMENT_RUN / 2;

    for (uint column = 0; column <= RAMP_SEGMENTS; column++) {
        float run = (float)column * RAMP_SEGMENT_RUN;
        ramp.positions[2 * column] = { run - centre, RAMP_SLOPE * (run - centre), -RAMP_HALF_WIDTH };
        ramp.positions[2 * column + 1] = { run - centre, RAMP_SLOPE * (run - centre), RAMP_HALF_WIDTH };
    }

    for (uint segment = 0; segment < RAMP_SEGMENTS; segment++) {
        uint near_back = 2 * segment;
        uint near_front = near_back + 1;
        uint far_back = near_back + 2;
        uint far_front = near_back + 3;
        uint[6] quad = { near_back, near_front, far_front, near_back, far_front, far_back };
        ramp.indices[6 * segment:6] = quad[..];
    }
    ramp.finalize();

    return ramp;
}

fn CollisionShapeDesc[SHAPE_KIND_COUNT] make_shape_descriptions(GeometryId cone, GeometryId ramp) @local {
    CollisionShapeDesc[SHAPE_KIND_COUNT] descriptions = {
        physics::default_collision_shape_desc(physics::ColliderKind.SPHERE),
        physics::default_collision_shape_desc(physics::ColliderKind.CAPSULE),
        physics::default_collision_shape_desc(physics::ColliderKind.BOX),
        physics::default_collision_shape_desc(physics::ColliderKind.HULL),
        physics::default_collision_shape_desc(physics::ColliderKind.MESH),
    };
    descriptions[0].radius = 0.6f;
    descriptions[1].radius = 0.35f;
    descriptions[1].half_height = 0.5f;
    descriptions[2].half_extents = { 0.8f, 0.4f, 0.5f };
    descriptions[3].geometry = cone;
    descriptions[4].geometry = ramp;

    return descriptions;
}

fn void draw_mesh(
    debug::DebugDraw* draw,
    Demo* demo,
    Vec3 scale,
    maths::Transform pose,
    uint rgba,
) @local {
    bool mirrored = scale.x * scale.y * scale.z < 0;
    for (usz index = 0; index + 2 < demo.mesh_indices.len; index += 3) {
        Vec3[3] corners;
        for (usz corner = 0; corner < 3; corner++) {
            Vec3 local_point = demo.mesh_points[demo.mesh_indices[index + corner]] * scale;
            corners[corner] = pose.rotation.rotate_vec3(local_point) + pose.position;
        }

        if (mirrored) {
            Vec3 swapped = corners[1];
            corners[1] = corners[2];
            corners[2] = swapped;
        }
        draw.line(corners[0], corners[1], rgba);
        draw.line(corners[1], corners[2], rgba);
        draw.line(corners[2], corners[0], rgba);

        Vec3 centre = (corners[0] + corners[1] + corners[2]) / 3;
        Vec3 front = (corners[1] - corners[0]).cross(corners[2] - corners[0]).normalize();
        draw.line(centre, centre + front * NORMAL_TICK, rgba);
    }
}

fn void draw_shape(
    debug::DebugDraw* draw,
    Demo* demo,
    CollisionShapeDesc shape,
    maths::Transform pose,
    uint rgba,
) @local {
    Vec3 magnitude = math::abs(shape.scale);

    switch (shape.kind) {
        case SPHERE:
            foreach (axis : (Vec3[3]){ { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }) {
                draw.circle(
                    center: pose.position,
                    normal: axis,
                    radius: shape.radius * magnitude.x,
                    rgba: rgba,
                );
            }
        case CAPSULE:
            Vec3 axis = pose.rotation.rotate_vec3({ 0, 1, 0 });
            draw.capsule(
                center:      pose.position,
                axis:        axis,
                half_height: shape.half_height * magnitude.x,
                radius:      shape.radius * magnitude.x,
                rgba:        rgba,
            );
        case BOX:
            Vec3 half = shape.half_extents * magnitude;
            draw.box(pose.to_mat4(), { .min = -half, .max = half }, rgba);
        case HULL:
            foreach (local_point : demo.hull_points) {
                Vec3 point = pose.rotation.rotate_vec3(local_point * shape.scale) + pose.position;
                draw.line(point - (Vec3){ MARKER_SIZE, 0, 0 }, point + (Vec3){ MARKER_SIZE, 0, 0 }, rgba);
                draw.line(point - (Vec3){ 0, MARKER_SIZE, 0 }, point + (Vec3){ 0, MARKER_SIZE, 0 }, rgba);
                draw.line(point - (Vec3){ 0, 0, MARKER_SIZE }, point + (Vec3){ 0, 0, MARKER_SIZE }, rgba);
            }
        case MESH:
            draw_mesh(
                draw: draw,
                demo: demo,
                scale: shape.scale,
                pose: pose,
                rgba: rgba,
            );
        case HEIGHT_FIELD:
        case COMPOUND:
            unreachable();
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

fn void evaluate_queries(Demo* demo, QueryResults* results) @local {
    CollisionShapeView shape_a = demo.slot_a.shape.view();
    CollisionShapeView shape_b = demo.slot_b.shape.view();
    *results = {};

    usz? count = shape_a.contacts(
        pose_a: demo.pose_a,
        other: shape_b,
        pose_b: demo.pose_b,
        output: results.contacts[..],
    );
    if (catch excuse = count) {
        results.contacts_fault = excuse;
    } else {
        results.contact_count = count;
    }

    Distance? closest = shape_a.distance(
        pose_a: demo.pose_a,
        other: shape_b,
        pose_b: demo.pose_b,
    );
    if (catch excuse = closest) {
        results.distance_fault = excuse;
    } else {
        results.closest = closest;
    }

    results.closing = (demo.pose_a.position - demo.pose_b.position).normalize() * SWEEP_LENGTH;
    Impact? impact = shape_a.cast(
        pose_a: demo.pose_a,
        other: shape_b,
        pose_b: demo.pose_b,
        translation_a: CAST_A_TRANSLATION,
        translation_b: results.closing,
    );
    if (catch excuse = impact) {
        results.cast_fault = excuse;
    } else {
        results.cast_impact = impact;
    }

    maths::Transform end = demo.pose_b;
    end.position += results.closing;
    maths::Transform spun = demo.pose_a;
    spun.rotation = quaternion::from_axis_angle{float}(SPIN_AXIS.normalize(), demo.spin + SPIN_SPEED);
    Impact? swept = shape_a.time_of_impact(
        sweep_a: { .start = demo.pose_a, .end = spun },
        other: shape_b,
        sweep_b: { .start = demo.pose_b, .end = end },
    );
    if (catch excuse = swept) {
        results.sweep_fault = excuse;
    } else {
        results.sweep_impact = swept;
    }

    ShapeRayHit? ray = shape_a.ray_cast(
        pose: demo.pose_a,
        origin: RAY_ORIGIN,
        direction: RAY_DIRECTION,
        max_distance: RAY_LENGTH,
    );
    if (catch excuse = ray) {
        results.ray_fault = excuse;
    } else {
        results.ray_hit = ray;
    }
}

fn void draw_queries(debug::DebugDraw* draw, Demo* demo, QueryResults* results) @local {
    draw_shape(
        draw: draw,
        demo: demo,
        shape: demo.slot_a.description,
        pose: demo.pose_a,
        rgba: debug::rgba(0.3f, 0.7f, 1),
    );
    draw_shape(
        draw: draw,
        demo: demo,
        shape: demo.slot_b.description,
        pose: demo.pose_b,
        rgba: debug::rgba(1, 0.8f, 0.3f),
    );

    foreach (contact : results.contacts[:results.contact_count]) {
        draw_marker(draw, contact.point, debug::rgba(1, 0.2f, 0.2f));
        draw.line(contact.point, contact.point + contact.normal * NORMAL_TICK, debug::rgba(1, 0.2f, 0.2f));
    }

    if (!results.distance_fault && results.closest.distance > 0) {
        draw.line(results.closest.point_a, results.closest.point_b, debug::rgba(0.3f, 1, 0.3f));
    }

    draw.line(demo.pose_a.position, demo.pose_a.position + CAST_A_TRANSLATION, debug::rgba(0.7f, 0.7f, 0.7f));
    draw.line(demo.pose_b.position, demo.pose_b.position + results.closing, debug::rgba(0.7f, 0.7f, 0.7f));
    if (!results.cast_fault) {
        maths::Transform ghost_a = demo.pose_a;
        ghost_a.position += CAST_A_TRANSLATION * results.cast_impact.time;
        maths::Transform ghost_b = demo.pose_b;
        ghost_b.position += results.closing * results.cast_impact.time;
        uint ghost_color = debug::rgba(1, 1, 1, 0.5f);
        draw_shape(
            draw: draw,
            demo: demo,
            shape: demo.slot_a.description,
            pose: ghost_a,
            rgba: ghost_color,
        );
        draw_shape(
            draw: draw,
            demo: demo,
            shape: demo.slot_b.description,
            pose: ghost_b,
            rgba: ghost_color,
        );
        draw_marker(draw, results.cast_impact.point, debug::rgba(1, 1, 1));
        draw.line(
            results.cast_impact.point,
            results.cast_impact.point + results.cast_impact.normal * NORMAL_TICK,
            debug::rgba(1, 1, 1),
        );
    }

    if (!results.sweep_fault) {
        maths::Transform touching = demo.pose_b;
        touching.position += results.closing * results.sweep_impact.time;
        draw_shape(
            draw: draw,
            demo: demo,
            shape: demo.slot_b.description,
            pose: touching,
            rgba: debug::rgba(1, 0.5f, 0.1f, 0.5f),
        );
        draw_marker(draw, results.sweep_impact.point, debug::rgba(1, 0.5f, 0.1f));
    }

    draw.line(RAY_ORIGIN, RAY_ORIGIN + RAY_DIRECTION * RAY_LENGTH, debug::rgba(0.6f, 0.4f, 1, 0.6f));
    if (!results.ray_fault) {
        draw_marker(draw, results.ray_hit.point, debug::rgba(0.8f, 0.6f, 1));
        draw.line(
            results.ray_hit.point,
            results.ray_hit.point + results.ray_hit.normal * NORMAL_TICK,
            debug::rgba(0.8f, 0.6f, 1),
        );
    }
}

fn Vec3 slot_scale(ShapeSlot* slot) @local {
    Vec3 scale = slot.axis_scale;
    if (slot.kind < UNIFORM_SCALE_KIND_COUNT) scale = { slot.uniform_scale, slot.uniform_scale, slot.uniform_scale };
    if (slot.reflected) scale.x = -scale.x;

    return scale;
}

fn void prepare_slot(ShapeSlot* slot, CollisionShapeDesc base, CollisionCache* cache) @local {
    CollisionShapeDesc description = base;
    description.scale = slot_scale(slot);
    CollisionShape? prepared = physics::create_collision_shape(mem, cache, description);
    if (catch excuse = prepared) {
        slot.refusal = excuse;
        return;
    }

    physics::destroy_collision_shape(&slot.shape);
    slot.shape = prepared;
    slot.description = description;
    slot.refusal = {};
}

fn bool shape_picker(String suffix, int* kind) @local {
    bool changed;
    for (int index = 0; index < SHAPE_KIND_COUNT; index++) {
        @pool() {
            ZString label = string::tformat("%s##%s", KIND_NAMES[index], suffix).zstr_tcopy();
            if (imgui::radio_button(label, *kind == index)) {
                *kind = index;
                changed = true;
            }
        };
        if (index + 1 < SHAPE_KIND_COUNT) imgui::same_line();
    }

    return changed;
}

fn bool scale_slider(String name, String suffix, float* value) @local {
    bool changed;
    @pool() {
        ZString label = string::tformat("%s##%s", name, suffix).zstr_tcopy();
        changed = imgui::slider_float_ex(
            label:  label,
            v:      value,
            v_min:  SCALE_MIN,
            v_max:  SCALE_MAX,
            format: "%.4f",
            flags:  { .logarithmic = true },
        );
    };

    return changed;
}

fn void shape_controls(
    ShapeSlot* slot,
    String suffix,
    CollisionShapeDesc[SHAPE_KIND_COUNT] descriptions,
    CollisionCache* cache,
) @local {
    bool changed = shape_picker(suffix, &slot.kind);

    if (slot.kind < UNIFORM_SCALE_KIND_COUNT) {
        changed |= scale_slider("Scale", suffix, &slot.uniform_scale);
    } else {
        changed |= scale_slider("Scale X", suffix, &slot.axis_scale.x);
        changed |= scale_slider("Scale Y", suffix, &slot.axis_scale.y);
        changed |= scale_slider("Scale Z", suffix, &slot.axis_scale.z);
    }

    @pool() {
        ZString label = string::tformat("Reflect X##%s", suffix).zstr_tcopy();
        changed |= imgui::checkbox(label, &slot.reflected);
    };

    if (changed) prepare_slot(slot, descriptions[slot.kind], cache);
    if (slot.refusal) show_fault("Scale refused", slot.refusal);
}

fn void show_fault(String label, fault excuse) @local {
    @pool() {
        imgui::text_colored(
            FAULT_COLOR,
            "%s: %s",
            label.zstr_tcopy(),
            string::tformat_zstr("%s", excuse),
        );
    };
}

fn void show_contacts(QueryResults* results) @local {
    if (results.contacts_fault) {
        show_fault("Contacts", results.contacts_fault);
        return;
    }

    imgui::text("Contact points: %llu", results.contact_count);
    foreach (contact : results.contacts[:math::min(results.contact_count, CONTACT_ROWS_SHOWN)]) {
        if (contact.triangle_index == physics::NO_COLLISION_TRIANGLE) {
            imgui::text(
                "  normal %.2f %.2f %.2f, separation %.3f",
                (double)contact.normal.x,
                (double)contact.normal.y,
                (double)contact.normal.z,
                (double)contact.separation,
            );
        } else {
            imgui::text(
                "  normal %.2f %.2f %.2f, separation %.3f, triangle %u",
                (double)contact.normal.x,
                (double)contact.normal.y,
                (double)contact.normal.z,
                (double)contact.separation,
                contact.triangle_index,
            );
        }
    }
}

fn void show_impact(String label, Impact impact, fault excuse) @local {
    if (excuse) {
        show_fault(label, excuse);
        return;
    }

    @pool() {
        imgui::text(
            "%s: time %.3f, normal %.2f %.2f %.2f",
            label.zstr_tcopy(),
            (double)impact.time,
            (double)impact.normal.x,
            (double)impact.normal.y,
            (double)impact.normal.z,
        );
    };
}

fn void show_results(QueryResults* results) @local {
    show_contacts(results);

    if (results.distance_fault) {
        show_fault("Distance", results.distance_fault);
    } else {
        imgui::text("Distance: %.3f", (double)results.closest.distance);
    }

    show_impact("Cast, both moving", results.cast_impact, results.cast_fault);
    show_impact("Sweep, spinning A", results.sweep_impact, results.sweep_fault);

    if (results.ray_fault) {
        show_fault("Ray", results.ray_fault);
    } else {
        imgui::text(
            "Ray: fraction %.3f, normal %.2f %.2f %.2f",
            (double)results.ray_hit.fraction,
            (double)results.ray_hit.normal.x,
            (double)results.ray_hit.normal.y,
            (double)results.ray_hit.normal.z,
        );
    }
}

fn void draw_panel(Demo* demo, QueryResults* results, CollisionCache* cache) @local {
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Collision queries", null, {})) {
        imgui::text("Arrows and Page Up/Down move shape B");
        imgui::text("Left click highlights the nearest grey box");
        imgui::separator_text("Shape A");
        shape_controls(
            slot:         &demo.slot_a,
            suffix:       "a",
            descriptions: demo.descriptions,
            cache:        cache,
        );
        imgui::separator_text("Shape B");
        shape_controls(
            slot:         &demo.slot_b,
            suffix:       "b",
            descriptions: demo.descriptions,
            cache:        cache,
        );
        imgui::separator_text("Results");
        show_results(results);
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

fn Demo make_demo(AssetStore* assets, GeometryId cone, GeometryId ramp) @local {
    return {
        .descriptions = make_shape_descriptions(cone, ramp),
        .hull_points = assets.geometry(cone).data.positions,
        .mesh_points = assets.geometry(ramp).data.positions,
        .mesh_indices = assets.geometry(ramp).data.indices,
        .slot_a = { .kind = 2, .uniform_scale = 1, .axis_scale = { 1, 1, 1 } },
        .slot_b = { .kind = 1, .uniform_scale = 1, .axis_scale = { 1, 1, 1 } },
        .pose_a = { .position = SHAPE_A_POSITION, .rotation = { 0, 0, 0, 1 }, .scale = { 1, 1, 1 } },
        .pose_b = { .position = SHAPE_B_START, .rotation = { 0, 0, 0, 1 }, .scale = { 1, 1, 1 } },
    };
}

fn void? prepare_demo_slots(Demo* demo, CollisionCache* cache) @local {
    prepare_slot(&demo.slot_a, demo.descriptions[demo.slot_a.kind], cache);
    prepare_slot(&demo.slot_b, demo.descriptions[demo.slot_b.kind], cache);
    if (demo.slot_a.refusal) return demo.slot_a.refusal~;
    if (demo.slot_b.refusal) return demo.slot_b.refusal~;
}

fn void? run_window(
    platform::Window* window,
    render::Renderer* renderer,
    Scene* scene,
    AssetStore* assets,
    CollisionCache* cache,
    GeometryId cone,
    GeometryId ramp,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw draw = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&draw);

    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    camera_node.local.position = CAMERA_POSITION;
    camera_node.local.rotation = maths::look_rotation(SHAPE_A_POSITION - CAMERA_POSITION, { 0, 1, 0 });

    Demo demo = make_demo(assets, cone, ramp);
    defer physics::destroy_collision_shape(&demo.slot_a.shape);
    defer physics::destroy_collision_shape(&demo.slot_b.shape);
    prepare_demo_slots(&demo, cache)!;

    renderer.prepare_scene(scene)!;
    Scatter scatter = create_scatter()!;
    defer destroy_scatter(&scatter);

    QueryResults results;
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
        evaluate_queries(&demo, &results);
        draw_panel(&demo, &results, cache);
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        scene.update_world();
        draw.clear();
        draw_queries(&draw, &demo, &results);
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

fn void print_results(Demo* demo, QueryResults* results) @local {
    io::printfn(
        "shapes,%s,%s,mesh_scale,%.3f,%.3f,%.3f",
        KIND_NAMES[demo.slot_a.kind],
        KIND_NAMES[demo.slot_b.kind],
        (double)demo.slot_a.description.scale.x,
        (double)demo.slot_a.description.scale.y,
        (double)demo.slot_a.description.scale.z,
    );

    if (results.contacts_fault) {
        io::printfn("contacts,fault,%s", results.contacts_fault);
    } else {
        io::printfn("contacts,%d", results.contact_count);
    }

    if (results.distance_fault) {
        io::printfn("distance,fault,%s", results.distance_fault);
    } else {
        io::printfn("distance,%.4f", (double)results.closest.distance);
    }

    if (results.cast_fault) {
        io::printfn("cast,fault,%s", results.cast_fault);
    } else {
        Impact impact = results.cast_impact;
        io::printfn(
            "cast,time,%.4f,point,%.3f,%.3f,%.3f,normal,%.3f,%.3f,%.3f",
            (double)impact.time,
            (double)impact.point.x,
            (double)impact.point.y,
            (double)impact.point.z,
            (double)impact.normal.x,
            (double)impact.normal.y,
            (double)impact.normal.z,
        );
    }

    if (results.sweep_fault) {
        io::printfn("sweep,fault,%s", results.sweep_fault);
    } else {
        io::printfn("sweep,time,%.4f", (double)results.sweep_impact.time);
    }

    if (results.ray_fault) {
        io::printfn("ray,fault,%s", results.ray_fault);
    } else {
        ShapeRayHit hit = results.ray_hit;
        io::printfn(
            "ray,fraction,%.4f,normal,%.3f,%.3f,%.3f",
            (double)hit.fraction,
            (double)hit.normal.x,
            (double)hit.normal.y,
            (double)hit.normal.z,
        );
    }
}

fn void? save_capture(render::Renderer* renderer, RenderTargetId target, String path) @local {
    char[] pixels = alloc::new_array(mem, char, VIEW_WIDTH * VIEW_HEIGHT * CAPTURE_CHANNELS);
    defer alloc::free(mem, pixels.ptr);
    renderer.read_render_target(target, pixels)!;
    file::save(path, pixels)!;
}

fn void? run_acceptance(
    Options options,
    Scene* scene,
    AssetStore* assets,
    CollisionCache* cache,
    GeometryId cone,
    GeometryId ramp,
) @local {
    render::Renderer renderer = render::create_renderer(
        allocator: mem,
        assets: assets,
        desc: { .validation = true, .application_name = "c3d_collision_math" },
    )!;
    defer render::destroy_renderer(&renderer);

    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc: render::render_target_desc(VIEW_WIDTH, VIEW_HEIGHT, PixelFormat.RGBA8_SRGB),
    )!;
    ViewDesc view_desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = render::create_view(&renderer, view_desc)!;
    debug::DebugDraw draw = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&draw);

    Node* camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    camera_node.local.position = ACCEPTANCE_CAMERA_POSITION;
    Vec3 view_direction = ACCEPTANCE_CAMERA_TARGET - ACCEPTANCE_CAMERA_POSITION;
    camera_node.local.rotation = maths::look_rotation(view_direction, { 0, 1, 0 });

    Demo demo = make_demo(assets, cone, ramp);
    defer physics::destroy_collision_shape(&demo.slot_a.shape);
    defer physics::destroy_collision_shape(&demo.slot_b.shape);
    demo.slot_a = {
        .kind = ACCEPTANCE_KIND_A,
        .uniform_scale = 1,
        .axis_scale = ACCEPTANCE_MESH_SCALE,
        .reflected = true,
    };
    demo.slot_b = { .kind = ACCEPTANCE_KIND_B, .uniform_scale = 1, .axis_scale = { 1, 1, 1 } };
    prepare_demo_slots(&demo, cache)!;
    renderer.prepare_scene(scene)!;
    io::printfn("adapter,%s,viewport,%d,%d,validation,true", renderer.adapter_name, VIEW_WIDTH, VIEW_HEIGHT);

    QueryResults results;
    for (uint frame = 0; frame < options.frames; frame++) {
        float descent = math::min((float)frame / (float)ACCEPTANCE_DESCENT_FRAMES, 1.0f);
        demo.pose_b.position = ACCEPTANCE_B_START + (ACCEPTANCE_B_REST - ACCEPTANCE_B_START) * descent;
        scene.update_world();
        evaluate_queries(&demo, &results);
        draw.clear();
        draw_queries(&draw, &demo, &results);

        renderer.begin_frame({ .time = (double)frame * ACCEPTANCE_STEP, .delta = ACCEPTANCE_STEP })!;
        defer catch render::abort_frame(&renderer);
        renderer.render_view(
            scene: scene,
            camera_node: camera_node,
            view: view,
            debug: &draw,
        )!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
    }

    if (options.capture_path.len) save_capture(&renderer, target, options.capture_path)!;
    renderer.log.check_validation()!;
    print_results(&demo, &results);
}

fn int main(String[] args) {
    Options? options = parse_options(args);
    if (catch excuse = options) {
        io::eprintn("Use collision_math [--acceptance [--frames=count] [--capture=path.rgba]]");
        return 1;
    }

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);

    GeometryId cone;
    GeometryId ramp;
    @pool() {
        Geometry cone_source = geometry::cone(
            allocator: tmem,
            radius: 0.6f,
            height: 1.2f,
            slices: 12,
        );
        cone = assets.add_geometry(&cone_source)!!;

        Geometry ramp_source = make_ramp(tmem);
        ramp = assets.add_geometry(&ramp_source)!!;
    };
    CollisionCache cache = physics::create_collision_cache(mem, &assets, physics::default_collision_cache_desc())!!;
    defer physics::destroy_collision_cache(&cache)!!;

    if (options.acceptance) {
        if (catch excuse = run_acceptance(
            options: options,
            scene: &scene,
            assets: &assets,
            cache: &cache,
            cone: cone,
            ramp: ramp,
        )) {
            io::eprintfn("collision math acceptance failed: %s", excuse);
            return 1;
        }
        return 0;
    }

    platform::WindowDesc window_desc = platform::default_window_desc("c3d collision math", VIEW_WIDTH, VIEW_HEIGHT);
    platform::Window window = platform::create_window(window_desc)!!;
    defer platform::destroy_window(&window);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_collision_math" },
    )!!;
    defer render::destroy_renderer(&renderer);

    if (catch excuse = run_window(
        window:   &window,
        renderer: &renderer,
        scene:    &scene,
        assets:   &assets,
        cache:    &cache,
        cone:     cone,
        ramp:     ramp,
    )) {
        io::eprintfn("collision math example failed: %s", excuse);
        return 1;
    }
    return 0;
}
