module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::debug;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import b3;
import b3::draw;

const uint  COLLIDER_STATIC @local = 0xFF999999;
const uint  COLLIDER_KINEMATIC @local = 0xFFFF804D;
const uint  COLLIDER_DYNAMIC @local = 0xFF4DFF4D;
const uint  COLLIDER_SLEEPING @local = 0xFF80B3CC;
const uint  COLLIDER_SENSOR @local = 0xFF33FFFF;
const float CONTACT_POINT_SIZE @local = 0.05f;
const float TRANSFORM_AXIS_LENGTH @local = 0.25f; // metres at joint_scale 1; visible beside a unit body
const float HEX_CHANNEL_SCALE @local = 1.0f / 255;
const uint  PARALLEL_BODY_CHUNK @local = 256; // bodies per range, about 25 us of box lines; a scene of one chunk draws serially
const usz   BOX_LINES @local = 12; // the edges of one DebugDraw.box
const usz   SPHERE_LINES @local = 3 * debug::DEBUG_CIRCLE_SEGMENTS; // three DebugDraw.circle calls
const usz   CAPSULE_LINES @local = 6 * debug::DEBUG_CIRCLE_SEGMENTS + 4; // six DebugDraw.circle calls and four side lines

struct ParallelDraw @local {
    RigidBody**         bodies;
    uint                body_count;
    uint                chunk_count;
    usz*                chunk_lines; // lines before each chunk of bodies, then the total
    debug::DebugVertex* vertices;    // the sink's storage from its current end
}

<*
 Append collider wireframes, contacts, bounds and joints to the sink.
 @param [&inout] sink : "Cleared by the application."
*>
fn void PhysicsWorld.debug_draw(&self, debug::DebugDraw* sink, PhysicsDebugOptions options) {
    if (options.colliders) draw_colliders(self, sink);
    if (!draws_through_box3d(options)) return;

    draw::DebugDraw draw = box3d_draw(sink, options);
    draw.drawing_bounds = self.world.bounds();
    draw::world_draw(self.world, &draw, ulong::max);
}

fn bool draws_through_box3d(PhysicsDebugOptions options) @private {
    return options.contacts || options.bounds || options.joints || options.joint_extras || options.mass
        || options.islands;
}

fn draw::DebugDraw box3d_draw(debug::DebugDraw* sink, PhysicsDebugOptions options) @private {
    draw::DebugDraw draw = draw::default_debug_draw();
    draw.draw_segment_fcn = &draw_segment;
    draw.draw_point_fcn = &draw_point;
    draw.draw_bounds_fcn = &draw_bounds;
    draw.draw_box_fcn = &draw_box;
    draw.draw_transform_fcn = &draw_transform;
    draw.draw_sphere_fcn = &draw_sphere;
    draw.draw_capsule_fcn = &draw_capsule;
    draw.context = sink;
    draw.draw_contacts = options.contacts;
    draw.draw_contact_normals = options.contacts;
    draw.draw_bounds = options.bounds;
    draw.draw_joints = options.joints;
    draw.draw_joint_extras = options.joint_extras;
    draw.draw_mass = options.mass;
    draw.draw_anchor_a = options.anchor_a;
    draw.draw_contact_forces = options.contact_forces;
    draw.draw_graph_colors = options.graph_colors;
    draw.draw_islands = options.islands;
    if (options.force_scale > 0) draw.force_scale = options.force_scale;
    if (options.joint_scale > 0) draw.joint_scale = options.joint_scale;
    return draw;
}

fn void draw_colliders(PhysicsWorld* world, debug::DebugDraw* sink) @local {
    if (world.parallel.run && draw_colliders_parallel(world, sink)) return;

    world.scene.@each(RigidBody; entity, body) {
        if (sink_is_full(sink)) {
            foreach (&collider : body.colliders) sink.dropped += collider_line_count(collider);
        } else {
            draw_body(sink, body);
        }
    };
}

fn bool draw_colliders_parallel(PhysicsWorld* world, debug::DebugDraw* sink) @local {
    uint body_count = world.scene.count(RigidBody);
    uint chunk_count = (body_count + PARALLEL_BODY_CHUNK - 1) / PARALLEL_BODY_CHUNK;
    if (chunk_count < 2) return false;

    @pool() {
        ParallelDraw draw = {
            .bodies      = alloc::new_array(tmem, RigidBody*, (sz)body_count),
            .body_count  = body_count,
            .chunk_count = chunk_count,
            .chunk_lines = alloc::new_array(tmem, usz, (sz)chunk_count + 1),
        };
        usz remaining = sink.capacity - (usz)sink.vertices.len() / 2;
        if (!collect_bodies(world, &draw, remaining)) return false;

        draw.vertices = sink.vertices.entries + sink.vertices.len();
        world.parallel.run(
            context: world.parallel.context,
            range:   &draw_chunk_range,
            data:    &draw,
            count:   chunk_count,
            batch:   1,
        );
        sink.vertices.size += (sz)draw.chunk_lines[chunk_count] * 2;
        return true;
    };
}

fn bool collect_bodies(PhysicsWorld* world, ParallelDraw* draw, usz remaining) @local {
    usz total;
    uint position;
    bool fits = true;
    world.scene.@each(RigidBody; entity, body) {
        if (fits) {
            if (position % PARALLEL_BODY_CHUNK == 0) draw.chunk_lines[position / PARALLEL_BODY_CHUNK] = total;
            draw.bodies[position++] = body;
            foreach (&collider : body.colliders) total += collider_line_count(collider);
            fits = total <= remaining;
        }
    };
    draw.chunk_lines[draw.chunk_count] = total;
    return fits;
}

fn void draw_chunk_range(void* data, uint first, uint count) @local {
    ParallelDraw* draw = data;
    for (uint chunk = first; chunk < first + count; chunk++) {
        uint first_body = chunk * PARALLEL_BODY_CHUNK;
        uint chunk_bodies = math::min(PARALLEL_BODY_CHUNK, draw.body_count - first_body);
        usz first_line = draw.chunk_lines[chunk];
        usz lines = draw.chunk_lines[chunk + 1] - first_line;

        // The exact capacity keeps push off the null allocator.
        debug::DebugDraw slice = {
            .capacity = lines,
            .vertices = { .capacity = (sz)lines * 2, .entries = draw.vertices + first_line * 2 },
        };
        foreach (body : draw.bodies[first_body:chunk_bodies]) draw_body(&slice, body);
    }
}

fn void draw_body(debug::DebugDraw* sink, RigidBody* body) @local {
    uint color = body_color(body);
    Mat4 body_world = body.current.to_mat4();
    foreach (&collider : body.colliders) {
        if (sink_is_full(sink)) {
            sink.dropped += collider_line_count(collider);
            continue;
        }

        switch (collider.kind) {
            case BOX:
                Mat4 shape_world = body_world.mul(collider.local.to_mat4());
                sink.box(shape_world, { .min = -collider.half_extents, .max = collider.half_extents }, color);
            case SPHERE:
                Vec3 center = maths::transform_point(body_world, collider.local.position);
                sink.circle(center, { 1, 0, 0 }, collider.radius, color);
                sink.circle(center, { 0, 1, 0 }, collider.radius, color);
                sink.circle(center, { 0, 0, 1 }, collider.radius, color);
            case CAPSULE:
                Vec3 center = maths::transform_point(body_world, collider.local.position);
                Vec3 axis = maths::transform_dir(body_world, collider.local.rotation.rotate_vec3({ 0, 1, 0 })).normalize();
                sink.capsule(
                    center:      center,
                    axis:        axis,
                    half_height: collider.half_height,
                    radius:      collider.radius,
                    rgba:        color,
                );
            case HULL:
            case MESH:
                draw_wire(
                    sink:  sink,
                    world: body_world.mul(collider.local.to_mat4()),
                    wire:  collider.wire,
                    color: color,
                );
            case HEIGHT_FIELD:
            case COMPOUND:
                draw_wire(
                    sink:  sink,
                    world: body_world,
                    wire:  collider.wire,
                    color: color,
                );
        }
    }
}

fn bool sink_is_full(debug::DebugDraw* sink) @local {
    return (usz)sink.vertices.len() / 2 >= sink.capacity;
}

fn usz collider_line_count(Collider* collider) @local {
    switch (collider.kind) {
        case BOX:     return BOX_LINES;
        case SPHERE:  return SPHERE_LINES;
        case CAPSULE: return CAPSULE_LINES;
        case HULL:
        case MESH:
        case HEIGHT_FIELD:
        case COMPOUND:
            return collider.wire.len / 2;
    }
}

fn void draw_wire(
    debug::DebugDraw* sink,
    Mat4 world,
    Vec3[] wire,
    uint color,
) @local {
    for (usz index = 0; index + 1 < wire.len; index += 2) {
        sink.line(maths::transform_point(world, wire[index]), maths::transform_point(world, wire[index + 1]), color);
    }
}

fn uint body_color(RigidBody* body) @local {
    foreach (&collider : body.colliders) {
        if (collider.shape.is_sensor()) return COLLIDER_SENSOR;
    }
    switch (body.kind) {
        case STATIC:    return COLLIDER_STATIC;
        case KINEMATIC: return COLLIDER_KINEMATIC;
        case DYNAMIC:   return body.body.is_awake() ? COLLIDER_DYNAMIC : COLLIDER_SLEEPING;
    }
}

fn void draw_segment(
    b3::Pos from,
    b3::Pos to,
    draw::HexColor color,
    void* context,
) @local {
    debug::DebugDraw* sink = context;
    sink.line(from, to, sink_color(color));
}

fn void draw_point(
    b3::Pos point,
    float size,
    draw::HexColor color,
    void* context,
) @local {
    debug::DebugDraw* sink = context;
    uint rgba = sink_color(color);
    Vec3 center = point;
    sink.line(center - (Vec3){ CONTACT_POINT_SIZE, 0, 0 }, center + (Vec3){ CONTACT_POINT_SIZE, 0, 0 }, rgba);
    sink.line(center - (Vec3){ 0, CONTACT_POINT_SIZE, 0 }, center + (Vec3){ 0, CONTACT_POINT_SIZE, 0 }, rgba);
    sink.line(center - (Vec3){ 0, 0, CONTACT_POINT_SIZE }, center + (Vec3){ 0, 0, CONTACT_POINT_SIZE }, rgba);
}

fn void draw_bounds(b3::Aabb bounds, draw::HexColor color, void* context) @local {
    debug::DebugDraw* sink = context;
    sink.aabb({ .min = bounds.lower_bound, .max = bounds.upper_bound }, sink_color(color));
}

fn void draw_box(
    Vec3 extents,
    b3::WorldTransform transform,
    draw::HexColor color,
    void* context,
) @local {
    debug::DebugDraw* sink = context;
    maths::Transform pose = { .position = transform.p, .rotation = transform.q, .scale = { 1, 1, 1 } };
    sink.box(pose.to_mat4(), { .min = -extents, .max = extents }, sink_color(color));
}

fn void draw_transform(b3::WorldTransform transform, void* context) @local {
    debug::DebugDraw* sink = context;
    maths::Transform pose = { .position = transform.p, .rotation = transform.q, .scale = { 1, 1, 1 } };
    sink.axes(pose.to_mat4(), TRANSFORM_AXIS_LENGTH);
}

fn void draw_sphere(
    b3::Pos center,
    float radius,
    draw::HexColor color,
    float alpha,
    void* context,
) @local {
    debug::DebugDraw* sink = context;
    uint rgba = sink_color(color);
    sink.circle(center, { 1, 0, 0 }, radius, rgba);
    sink.circle(center, { 0, 1, 0 }, radius, rgba);
    sink.circle(center, { 0, 0, 1 }, radius, rgba);
}

fn void draw_capsule(
    b3::Pos first,
    b3::Pos second,
    float radius,
    draw::HexColor color,
    float alpha,
    void* context,
) @local {
    debug::DebugDraw* sink = context;
    Vec3 start = first;
    Vec3 end = second;
    Vec3 segment = end - start;
    sink.capsule(
        center:      (start + end) * 0.5f,
        axis:        segment.normalize(),
        half_height: segment.length() * 0.5f,
        radius:      radius,
        rgba:        sink_color(color),
    );
}

fn uint sink_color(draw::HexColor color) @local {
    uint packed = color;
    return debug::rgba(
        red:   ((packed >> 16) & 0xFF) * HEX_CHANNEL_SCALE,
        green: ((packed >> 8) & 0xFF) * HEX_CHANNEL_SCALE,
        blue:  (packed & 0xFF) * HEX_CHANNEL_SCALE,
    );
}
