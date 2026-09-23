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
const float AXIS_PARALLEL_THRESHOLD @local = 0.99f; // a capsule axis this close to Y takes X as its basis reference
const float HEX_CHANNEL_SCALE @local = 1.0f / 255;

<*
 Append collider wireframes, contacts and bounds to the sink.
 @param [&inout] sink : "Cleared by the application."
*>
fn void PhysicsWorld.debug_draw(&self, debug::DebugDraw* sink, PhysicsDebugOptions options) {
    if (options.colliders) draw_colliders(self, sink);
    if (!options.contacts && !options.bounds) return;

    draw::DebugDraw draw = draw::default_debug_draw();
    draw.draw_segment_fcn = &draw_segment;
    draw.draw_point_fcn = &draw_point;
    draw.draw_bounds_fcn = &draw_bounds;
    draw.context = sink;
    draw.drawing_bounds = self.world.bounds();
    draw.draw_contacts = options.contacts;
    draw.draw_contact_normals = options.contacts;
    draw.draw_bounds = options.bounds;
    draw::world_draw(self.world, &draw, ulong::max);
}

fn void draw_colliders(PhysicsWorld* world, debug::DebugDraw* sink) @local {
    world.scene.@each(RigidBody; entity, body) {
        uint color = body_color(body);
        Mat4 body_world = body.current.to_mat4();
        foreach (&collider : body.colliders) {
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
                    draw_capsule(
                        sink:       sink,
                        body_world: body_world,
                        collider:   collider,
                        color:      color,
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
    };
}

fn void draw_capsule(
    debug::DebugDraw* sink,
    Mat4 body_world,
    Collider* collider,
    uint color,
) @local {
    Vec3 center = maths::transform_point(body_world, collider.local.position);
    Vec3 axis = maths::transform_dir(body_world, collider.local.rotation.rotate_vec3({ 0, 1, 0 })).normalize();
    Vec3 reference = math::abs(axis.y) < AXIS_PARALLEL_THRESHOLD ? (Vec3){ 0, 1, 0 } : (Vec3){ 1, 0, 0 };
    Vec3 side = axis.cross(reference).normalize();
    Vec3 forward = axis.cross(side);
    Vec3 top = center + axis * collider.half_height;
    Vec3 bottom = center - axis * collider.half_height;
    float radius = collider.radius;

    sink.circle(top, axis, radius, color);
    sink.circle(bottom, axis, radius, color);
    sink.circle(top, side, radius, color);
    sink.circle(top, forward, radius, color);
    sink.circle(bottom, side, radius, color);
    sink.circle(bottom, forward, radius, color);
    sink.line(top + side * radius, bottom + side * radius, color);
    sink.line(top - side * radius, bottom - side * radius, color);
    sink.line(top + forward * radius, bottom + forward * radius, color);
    sink.line(top - forward * radius, bottom - forward * radius, color);
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

fn uint sink_color(draw::HexColor color) @local {
    uint packed = color;
    return debug::rgba(
        red:   ((packed >> 16) & 0xFF) * HEX_CHANNEL_SCALE,
        green: ((packed >> 8) & 0xFF) * HEX_CHANNEL_SCALE,
        blue:  (packed & 0xFF) * HEX_CHANNEL_SCALE,
    );
}
