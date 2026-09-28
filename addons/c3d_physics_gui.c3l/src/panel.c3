module c3d::gui;

$assert !$feat(C3D_PHYSICS_GUI_CHARACTER) || $feat(C3D_PHYSICS_GUI)
  : "C3D_PHYSICS_GUI_CHARACTER requires C3D_PHYSICS_GUI.";

module c3d::gui @feat(C3D_PHYSICS_GUI);

import c3d;
import c3d::debug;
import c3d::ecs;
import c3d::maths;
import c3d::physics;
import c3d::scene;
import std::math;

<*
 Updates the panel's mean update time spans.
*>
const uint PHYSICS_TIMING_WINDOW = 60;       // one second of updates at 60 Hz; the mean's smoothing lever

<*
 Rows the event log keeps unless create_physics_panel is told otherwise.
*>
const uint PHYSICS_EVENT_CAPACITY = 256;     // 12 KiB of rows; the event log's depth lever
const usz  PHYSICS_RECORDING_CAPACITY @private = 1 << 20; // starting size of a recording; box3d grows it
const float SELECTED_AXES_SIZE @local = 0.5f;    // metres; the selected node's frame beside a unit body
const float CONTACT_MARK_SIZE @local = 0.05f;
const float CONTACT_NORMAL_LENGTH @local = 0.3f;
const uint  SELECTED_COLOR @local = 0xFF00FFFF;
const uint  QUERY_COLOR @local = 0xFFFFFF00;
const uint  HIT_COLOR @local = 0xFF0080FF;

<*
 Kind of one logged physics event.
*>
enum PhysicsEventKind {
    CONTACT_BEGIN,
    CONTACT_END,
    HIT,
    SENSOR_BEGIN,
    SENSOR_END,
    JOINT,
    BUILD_FAILURE,
}

<*
 Blocks the selected-node section draws.
*>
bitstruct PhysicsSelectionBlocks : char {
    bool body      : 0;  // PhysicsBody or RigidBody
    bool joint     : 1;  // PhysicsJoint
    bool ragdoll   : 2;
    bool character : 3;  // set only under C3D_PHYSICS_GUI_CHARACTER
}

<*
 One event of one update, kept in the panel's log.
*>
struct PhysicsEventRow {
    ulong            update;   // the panel's update counter
    PhysicsEventKind kind;
    Entity           a;
    Entity           b;        // zero for a build failure
    float            value;    // approach speed of a hit
    fault            failure;  // reason of a build failure
}

<*
 Physics panel state over a borrowed world, scene and selection.
*>
struct PhysicsPanel {
    Allocator                     allocator;
    PhysicsWorld*                 physics;
    Scene*                        scene;
    GuiPanelState*                selection;
    PhysicsDebugOptions           draw;
    bool                          paused;
    bool                          single_step;
    ulong                         updates;
    PhysicsEventRow[]             events;         // ring of the event capacity
    uint                          event_head;
    uint                          event_count;
    float[PHYSICS_TIMING_WINDOW]  update_ms;
    uint                          timing_cursor;
    usz                           recording_capacity;
    char[]                        recording;      // bytes of the last stopped recording; empty when none
    FrictionMixFn                 recording_friction_mix;     // the live tuning's at Start
    RestitutionMixFn              recording_restitution_mix;
    bool                          replay_default_mixes;       // open with box3d's mixes; provokes a divergence
    PhysicsReplay                 replay;
    bool                          has_replay;
    usz                           sink_segments;  // read by debug_draw; one frame old when the panel draws
    usz                           sink_capacity;
    usz                           sink_dropped;
    ColliderDesc                  cast_shape;     // the query tool's primitive; local is its start pose
    Vec3                          cast_translation;
    maths::Aabb                   overlap_bounds;
    bool                          show_queries;
    fault                         last_failure;   // shown until the next edit
}

<*
 Panel over a world, its scene and the scene panel's selection; borrows all three.
 @param allocator : "Outlives the panel; the event log, recording bytes and replays come from it, never tmem."
 @param [&inout] physics : "Its tuning is edited through set_tuning."
 @param [&inout] scene : "Components are edited through their owners' calls."
 @param [&inout] selection : "The panel writes selected only."
 @param event_capacity : "Rows the event log keeps."
 @require event_capacity > 0
*>
fn PhysicsPanel create_physics_panel(
    Allocator allocator,
    PhysicsWorld* physics,
    Scene* scene,
    GuiPanelState* selection,
    uint event_capacity = PHYSICS_EVENT_CAPACITY,
) {
    ColliderDesc cast = physics::default_collider_desc(SPHERE);
    cast.radius = 0.25f;
    cast.half_height = 0.25f;
    cast.half_extents = { 0.25f, 0.25f, 0.25f };
    cast.local.position = { 0, 1, 5 };
    return {
        .allocator          = allocator,
        .physics            = physics,
        .scene              = scene,
        .selection          = selection,
        .draw               = { .colliders = true },
        .events             = alloc::new_array(allocator, PhysicsEventRow, event_capacity),
        .recording_capacity = PHYSICS_RECORDING_CAPACITY,
        .cast_shape         = cast,
        .cast_translation   = { 0, 0, -10 },
        .overlap_bounds     = { .min = { -1, 0, -1 }, .max = { 1, 2, 1 } },
    };
}

<*
 Free the event log, the last recording and an open replay.
*>
fn void destroy_physics_panel(PhysicsPanel* panel) {
    if (panel.has_replay) physics::destroy_physics_replay(&panel.replay);
    if (panel.recording.len) alloc::free(panel.allocator, panel.recording.ptr);
    alloc::free(panel.allocator, panel.events.ptr);
    *panel = {};
}

<*
 Time to hand physics.update: 0 while paused, one fixed step after Step, else dt.
*>
fn float PhysicsPanel.step_dt(&self, float dt) {
    if (!self.paused) return dt;
    if (!self.single_step) return 0;
    self.single_step = false;
    return self.physics.desc.tuning.fixed_dt;
}

<*
 Log this update's events and its duration; call after physics.update, before flush_removals.
*>
fn void PhysicsPanel.record_events(&self, float update_ms) {
    self.update_ms[self.timing_cursor] = update_ms;
    self.timing_cursor = (self.timing_cursor + 1) % PHYSICS_TIMING_WINDOW;
    PhysicsWorld* physics = self.physics;
    foreach (event : physics.contacts_begin()) {
        append_physics_event(self, { .kind = CONTACT_BEGIN, .a = event.a.id, .b = event.b.id });
    }
    foreach (event : physics.contacts_end()) {
        append_physics_event(self, { .kind = CONTACT_END, .a = event.a.id, .b = event.b.id });
    }
    foreach (event : physics.hits()) {
        append_physics_event(self, { .kind = HIT, .a = event.a.id, .b = event.b.id, .value = event.approach_speed });
    }
    foreach (event : physics.sensors_begin()) {
        append_physics_event(self, { .kind = SENSOR_BEGIN, .a = event.sensor.id, .b = event.visitor.id });
    }
    foreach (event : physics.sensors_end()) {
        append_physics_event(self, { .kind = SENSOR_END, .a = event.sensor.id, .b = event.visitor.id });
    }
    foreach (event : physics.joint_events()) {
        append_physics_event(self, { .kind = JOINT, .a = event.node.id, .b = event.other.id });
    }
    foreach (failure : physics.build_failures()) {
        append_physics_event(self, { .kind = BUILD_FAILURE, .a = failure.node.id, .failure = failure.reason });
    }
    self.updates++;
}

<*
 Append the selection, the query overlay, the live world and an open replay to the sink.
 @param [&inout] sink : "Cleared by the application; drawn in that order, so a full sink loses the replay first."
*>
fn void PhysicsPanel.debug_draw(&self, debug::DebugDraw* sink) {
    clear_dead_selection(self);
    @pool() {
        if (self.scene.world.is_alive(self.selection.selected)) {
            draw_selected_node(self, sink, self.scene.node(self.selection.selected));
        }
        if (self.show_queries) draw_queries(self, sink);
    };
    self.physics.debug_draw(sink, self.draw);
    if (self.has_replay) self.replay.debug_draw(sink, self.draw);
    self.sink_segments = (usz)sink.vertices.len() / 2;
    self.sink_capacity = sink.capacity;
    self.sink_dropped = sink.dropped;
}

fn void append_physics_event(PhysicsPanel* panel, PhysicsEventRow row) @private {
    row.update = panel.updates;
    panel.events[panel.event_head] = row;
    panel.event_head = (panel.event_head + 1) % (uint)panel.events.len;
    if (panel.event_count < panel.events.len) panel.event_count++;
}

fn PhysicsEventRow* physics_event_at(PhysicsPanel* panel, uint newest) @private {
    uint capacity = (uint)panel.events.len;
    return &panel.events[(panel.event_head + capacity - 1 - newest) % capacity];
}

fn PhysicsSelectionBlocks physics_selection_blocks(Scene* scene, Entity entity) @private {
    PhysicsSelectionBlocks blocks;
    if (!scene.world.is_alive(entity)) return blocks;
    Node* node = scene.node(entity);
    blocks.body = scene.has(node, PhysicsBody) || scene.has(node, RigidBody);
    blocks.joint = scene.has(node, PhysicsJoint);
    blocks.ragdoll = scene.has(node, Ragdoll);
    $if $feat(C3D_PHYSICS_GUI_CHARACTER):
        blocks.character = has_character(scene, node);
    $endif
    return blocks;
}

fn void clear_dead_selection(PhysicsPanel* panel) @private {
    if (!panel.scene.world.is_alive(panel.selection.selected)) panel.selection.selected = {};
}

fn void draw_selected_node(PhysicsPanel* panel, debug::DebugDraw* sink, Node* node) @local {
    sink.axes(node.world, SELECTED_AXES_SIZE);
    if (!panel.scene.has(node, RigidBody)) return;
    foreach (contact : panel.physics.contact_points(tmem, node)) {
        draw_mark(sink, contact.point, SELECTED_COLOR);
        sink.line(contact.point, contact.point + contact.normal * CONTACT_NORMAL_LENGTH, SELECTED_COLOR);
    }
}

fn void draw_queries(PhysicsPanel* panel, debug::DebugDraw* sink) @local {
    ColliderDesc shape = panel.cast_shape;
    Vec3 start = shape.local.position;
    sink.line(start, start + panel.cast_translation, QUERY_COLOR);
    draw_primitive(
        sink:   sink,
        shape:  shape,
        center: start,
        rgba:   QUERY_COLOR,
    );
    foreach (hit : panel.physics.cast_shape(tmem, shape, panel.cast_translation)) {
        draw_primitive(
            sink:   sink,
            shape:  shape,
            center: start + panel.cast_translation * hit.fraction,
            rgba:   HIT_COLOR,
        );
        draw_mark(sink, hit.point, HIT_COLOR);
        sink.line(hit.point, hit.point + hit.normal * CONTACT_NORMAL_LENGTH, HIT_COLOR);
    }
    sink.aabb(panel.overlap_bounds, QUERY_COLOR);
    foreach (node : panel.physics.overlap_aabb(tmem, panel.overlap_bounds)) sink.axes(node.world, SELECTED_AXES_SIZE);
}

fn void draw_primitive(
    debug::DebugDraw* sink,
    ColliderDesc shape,
    Vec3 center,
    uint rgba,
) @local {
    switch (shape.kind) {
        case SPHERE:
            sink.circle(center, { 1, 0, 0 }, shape.radius, rgba);
            sink.circle(center, { 0, 1, 0 }, shape.radius, rgba);
            sink.circle(center, { 0, 0, 1 }, shape.radius, rgba);
        case CAPSULE:
            sink.capsule(
                center:      center,
                axis:        shape.local.rotation.rotate_vec3({ 0, 1, 0 }),
                half_height: shape.half_height,
                radius:      shape.radius,
                rgba:        rgba,
            );
        default:
            maths::Transform pose = { .position = center, .rotation = shape.local.rotation, .scale = { 1, 1, 1 } };
            sink.box(pose.to_mat4(), { .min = -shape.half_extents, .max = shape.half_extents }, rgba);
    }
}

fn void draw_mark(debug::DebugDraw* sink, Vec3 point, uint rgba) @local {
    sink.line(point - (Vec3){ CONTACT_MARK_SIZE, 0, 0 }, point + (Vec3){ CONTACT_MARK_SIZE, 0, 0 }, rgba);
    sink.line(point - (Vec3){ 0, CONTACT_MARK_SIZE, 0 }, point + (Vec3){ 0, CONTACT_MARK_SIZE, 0 }, rgba);
    sink.line(point - (Vec3){ 0, 0, CONTACT_MARK_SIZE }, point + (Vec3){ 0, 0, CONTACT_MARK_SIZE }, rgba);
}
