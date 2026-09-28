module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::debug;
import c3d::maths;
import b3;
import b3::draw;
import b3::record;

const uint REPLAY_COLOR @local = 0xFFFF66CC;  // magenta over the live world's greens and greys
const int  REPLAY_WORKERS @local = 1;
const usz  CAPSULE_WIRE_POINTS @local = 2 * COMPOUND_RING_SEGMENTS * 2 + 8;
const usz  SPHERE_WIRE_POINTS @local = 3 * COMPOUND_RING_SEGMENTS * 2;
const b3::Transform IDENTITY_POSE @local = { .q = quaternion::IDENTITY };

<*
 Player over recorded world mutations, drawing its own box3d world.
*>
struct PhysicsReplay {
    record::Player*  player;
    ReplayContext*   context;          // heap, so box3d's callback context keeps its address
    FrictionMixFn    friction_mix;
    RestitutionMixFn restitution_mix;
}

struct ReplayContext @private {
    Allocator allocator;               // the replay's; cooks and frees the shape wires
}

struct ReplayShape @private {
    Vec3[]      wire;                  // segment pairs in shape space
    maths::Aabb bounds;                // shape space; drawn for kinds without a wire
    bool        has_bounds;
}

<*
 Start recording world mutations.
 @param byte_capacity : "Starting buffer size; the buffer grows."
 @return? RECORDING_ACTIVE, b3::NOT_A_RECORDING
*>
fn void? PhysicsWorld.start_recording(&self, usz byte_capacity) {
    if (self.recording) return RECORDING_ACTIVE~;
    record::Recording* recording = record::create_recording((int)byte_capacity);
    defer catch record::destroy_recording(recording);
    record::world_start_recording(self.world, recording)!;
    self.recording = recording;
}

<*
 Stop recording and copy the bytes into the allocator.
 @return? NOT_RECORDING
*>
fn char[]? PhysicsWorld.stop_recording(&self, Allocator allocator) {
    if (!self.recording) return NOT_RECORDING~;
    record::world_stop_recording(self.world);
    char[] data = self.recording.data();
    char[] bytes = alloc::new_array(allocator, char, (sz)data.len);
    bytes[..] = data[..];
    record::destroy_recording(self.recording);
    self.recording = null;
    return bytes;
}

<*
 Whether a recording is in progress.
*>
fn bool PhysicsWorld.recording_active(&self) => self.recording != null;

<*
 Open a replay; the player copies the bytes.
 @param friction_mix : "The recorded world's mix; null for box3d's."
 @param restitution_mix : "The recorded world's mix; null for box3d's."
 @return? b3::NOT_A_RECORDING
*>
fn PhysicsReplay? create_physics_replay(
    Allocator allocator,
    char[] data,
    FrictionMixFn friction_mix,
    RestitutionMixFn restitution_mix,
) {
    ReplayContext* context = alloc::new(allocator, ReplayContext);
    context.allocator = allocator;
    defer catch alloc::free(allocator, context);
    record::Player* player = record::create_player(data, REPLAY_WORKERS)!;
    player.set_debug_shape_callbacks(&create_replay_shape, &destroy_replay_shape, context);
    PhysicsReplay replay = {
        .player          = player,
        .context         = context,
        .friction_mix    = friction_mix,
        .restitution_mix = restitution_mix,
    };
    install_replay_mixes(&replay);
    return replay;
}

<*
 Destroy the player, its world and the cooked wires.
*>
fn void destroy_physics_replay(PhysicsReplay* replay) {
    record::destroy_player(replay.player);
    alloc::free(replay.context.allocator, replay.context);
    *replay = {};
}

<*
 Replay one recorded frame; false at the end.
*>
fn bool PhysicsReplay.step(&self) => record::player_step_frame(self.player);

<*
 Rewind to frame 0 and clear the divergence.
*>
fn void PhysicsReplay.restart(&self) {
    record::player_restart(self.player);
}

<*
 Replay to the frame; a backward seek restores a keyframe.
*>
fn void PhysicsReplay.seek(&self, uint frame) {
    record::player_seek_frame(self.player, (int)frame);
}

<*
 Last fully replayed frame; 0 before the first step.
*>
fn uint PhysicsReplay.frame(&self) => (uint)self.player.frame();

<*
 Recorded frames.
*>
fn uint PhysicsReplay.frame_count(&self) => (uint)self.player.frame_count();

<*
 First frame whose state did not match the recording.
 @return? b3::NO_HIT
*>
fn uint? PhysicsReplay.diverge_frame(&self) => (uint)self.player.diverge_frame()!;

<*
 Append the replay world: shape wires, and bounds for mesh and height-field shapes.
 @param [&inout] sink : "Cleared by the application."
*>
fn void PhysicsReplay.debug_draw(&self, debug::DebugDraw* sink, PhysicsDebugOptions options) {
    if (!options.colliders && !draws_through_box3d(options)) return;
    b3::WorldId world = self.player.world_id();
    draw::DebugDraw draw = box3d_draw(sink, options);
    draw.draw_shapes = options.colliders;
    draw.draw_shape_fcn = &draw_replay_shape;
    draw.drawing_bounds = world.bounds();
    draw::world_draw(world, &draw, ulong::max);
}

fn void install_replay_mixes(PhysicsReplay* replay) @local {
    b3::WorldId world = replay.player.world_id();
    world.set_friction_callback((b3::FrictionFn)replay.friction_mix);
    world.set_restitution_callback((b3::RestitutionFn)replay.restitution_mix);
}

fn void* create_replay_shape(draw::DebugShape* shape, void* context) @local {
    ReplayContext* replay = context;
    ReplayShape* cooked = alloc::new(replay.allocator, ReplayShape);
    *cooked = cook_replay_shape(replay.allocator, shape);
    return cooked;
}

fn void destroy_replay_shape(void* shape, void* context) @local {
    ReplayContext* replay = context;
    ReplayShape* cooked = shape;
    alloc::free(replay.allocator, cooked.wire.ptr);
    alloc::free(replay.allocator, cooked);
}

fn void draw_replay_shape(
    void* shape,
    b3::WorldTransform transform,
    draw::HexColor color,
    void* context,
) @local {
    debug::DebugDraw* sink = context;
    ReplayShape* cooked = shape;
    maths::Transform pose = { .position = transform.p, .rotation = transform.q, .scale = { 1, 1, 1 } };
    Mat4 world = pose.to_mat4();
    for (usz index = 0; index + 1 < cooked.wire.len; index += 2) {
        sink.line(
            maths::transform_point(world, cooked.wire[index]),
            maths::transform_point(world, cooked.wire[index + 1]),
            REPLAY_COLOR,
        );
    }
    if (cooked.has_bounds) sink.box(world, cooked.bounds, REPLAY_COLOR);
}

fn ReplayShape cook_replay_shape(Allocator allocator, draw::DebugShape* shape) @private {
    switch (shape.type) {
        case SPHERE:
            WireWriter writer = { .points = alloc::new_array(allocator, Vec3, SPHERE_WIRE_POINTS) };
            write_sphere(&writer, *shape.sphere);
            return { .wire = writer.points };
        case CAPSULE:
            WireWriter writer = { .points = alloc::new_array(allocator, Vec3, CAPSULE_WIRE_POINTS) };
            write_capsule(&writer, *shape.capsule);
            return { .wire = writer.points };
        case HULL:
            return { .wire = hull_wire(allocator, shape.hull) };
        case MESH:
            b3::Aabb bounds = shape.mesh.data.compute_aabb(IDENTITY_POSE, shape.mesh.scale);
            return { .bounds = aabb_of(bounds), .has_bounds = true };
        case HEIGHT_FIELD:
            b3::Aabb bounds = shape.height_field.compute_aabb(IDENTITY_POSE);
            return { .bounds = aabb_of(bounds), .has_bounds = true };
        case COMPOUND:
            return cook_compound(allocator, shape.compound);
    }
}

fn ReplayShape cook_compound(Allocator allocator, b3::CompoundData* compound) @local {
    usz length = (usz)compound.sphere_count * SPHERE_WIRE_POINTS + (usz)compound.capsule_count * CAPSULE_WIRE_POINTS;
    for (int child = 0; child < compound.hull_count; child++) {
        length += (usz)compound.hull(child)!!.hull.edge_count;
    }

    ReplayShape cooked;
    WireWriter writer = { .points = alloc::new_array(allocator, Vec3, (sz)length) };
    for (int child = 0; child < compound.sphere_count; child++) {
        write_sphere(&writer, compound.sphere(child)!!.sphere);
    }
    for (int child = 0; child < compound.capsule_count; child++) {
        write_capsule(&writer, compound.capsule(child)!!.capsule);
    }
    for (int child = 0; child < compound.hull_count; child++) {
        b3::CompoundHull hull = compound.hull(child)!!;
        maths::Transform placement = {
            .position = hull.transform.p,
            .rotation = hull.transform.q,
            .scale    = { 1, 1, 1 },
        };
        write_hull(&writer, hull.hull, placement.to_mat4());
    }
    cooked.wire = writer.points;

    for (int child = 0; child < compound.mesh_count; child++) {
        b3::CompoundMesh mesh = compound.mesh(child)!!;
        maths::Aabb bounds = aabb_of(mesh.mesh_data.compute_aabb(mesh.transform, mesh.scale));
        cooked.bounds = cooked.has_bounds ? maths::aabb_merge(cooked.bounds, bounds) : bounds;
        cooked.has_bounds = true;
    }
    return cooked;
}

fn void write_sphere(WireWriter* writer, b3::Sphere sphere) @local {
    foreach (axis : (Vec3[3]){ { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } }) {
        write_ring(
            writer: writer,
            center: sphere.center,
            axis:   axis,
            radius: sphere.radius,
        );
    }
}

fn maths::Aabb aabb_of(b3::Aabb bounds) @local => { .min = bounds.lower_bound, .max = bounds.upper_bound };
