module c3d::gui @feat(C3D_PHYSICS_GUI);

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::physics;
import c3d::scene;
import imgui;
import std::math;

const float FIXED_STEP_MIN @local = 1.0f / 480;
const float FIXED_STEP_MAX @local = 1.0f / 15;
const int   SUB_STEPS_MAX @local = 16;
const int   STEPS_PER_FRAME_MAX @local = 16;
const float CONTACT_HERTZ_MAX @local = 240;
const float DAMPING_RATIO_MAX @local = 20;
const float DRAW_SCALE_MAX @local = 10;          // 0 keeps box3d's scale
const float CAST_SIZE_MIN @local = 0.01f;
const float CAST_SIZE_MAX @local = 5;
const float CHARACTER_SIZE_MIN @private = 0.01f; // radius and half height stay above zero
const float CHARACTER_SIZE_MAX @private = 5;
const uint  KIBIBYTE @local = 1024;
const imgui::Vec4 WARNING_COLOR @private = { 1, 0.4f, 0.4f, 1 };
const ZString[PhysicsEventKind::len] EVENT_KIND_NAMES @local = {
    "contact begin", "contact end", "hit", "sensor begin", "sensor end", "joint", "build failure",
};
const ZString[3] CAST_KIND_NAMES @local = { "Sphere", "Capsule", "Box" };
const ColliderKind[3] CAST_KINDS @local = { SPHERE, CAPSULE, BOX };
const ZString[2] RAGDOLL_MODE_NAMES @local = { "animated", "simulated" };

<*
 Draw the physics window.
 @require imgui::get_current_context() != null
*>
fn void physics_panel(PhysicsPanel* panel) {
    clear_dead_selection(panel);
    bool visible = imgui::begin("Physics", null, {});
    defer imgui::end();
    if (!visible) return;
    @pool() {
        if (panel.last_failure) {
            ZString failure = string::tformat("%s", panel.last_failure).zstr_tcopy();
            imgui::text_colored(WARNING_COLOR, "Last action failed: %s", failure);
        }
        world_section(panel);
        counters_section(panel.physics);
        profile_section(panel.physics);
        draw_section(panel);
        bodies_section(panel);
        $if $feat(C3D_PHYSICS_GUI_CHARACTER):
            characters_section(panel);
        $endif
        selected_section(panel);
        events_section(panel);
        queries_section(panel);
        recording_section(panel);
    };
}

fn void world_section(PhysicsPanel* panel) @local {
    if (!imgui::collapsing_header("World", { .default_open = true })) return;
    imgui::push_id("world");
    defer imgui::pop_id();
    PhysicsWorld* physics = panel.physics;
    PhysicsTuning tuning = physics.desc.tuning;
    bool changed = imgui::drag_float3("Gravity", (float*)&tuning.gravity);
    changed |= imgui::slider_float_ex(
        label:  "Fixed step",
        v:      &tuning.fixed_dt,
        v_min:  FIXED_STEP_MIN,
        v_max:  FIXED_STEP_MAX,
        format: "%.4f s",
        flags:  {},
    );
    changed |= edit_count("Sub-steps", &tuning.sub_steps, SUB_STEPS_MAX);
    changed |= edit_count("Max steps per frame", &tuning.max_steps_per_frame, STEPS_PER_FRAME_MAX);
    changed |= imgui::checkbox("Interpolate", &tuning.interpolate);
    changed |= edit_positive("Hit speed threshold", &tuning.hit_speed_threshold);
    changed |= imgui::slider_float("Contact hertz", &tuning.contact_hertz, 1, CONTACT_HERTZ_MAX);
    changed |= imgui::slider_float("Contact damping ratio", &tuning.contact_damping_ratio, 0, DAMPING_RATIO_MAX);
    changed |= edit_positive("Contact speed", &tuning.contact_speed);
    changed |= edit_positive("Maximum linear speed", &tuning.maximum_linear_speed);
    changed |= edit_positive("Restitution threshold", &tuning.restitution_threshold);
    changed |= imgui::checkbox("Continuous", &tuning.continuous);
    changed |= imgui::checkbox("Sleep", &tuning.sleep);
    if (changed) physics.set_tuning(tuning);

    imgui::checkbox("Pause", &panel.paused);
    imgui::same_line();
    imgui::begin_disabled(!panel.paused);
    if (imgui::button("Step")) panel.single_step = true;
    imgui::end_disabled();
    imgui::text("Workers: %u", physics.worker_count());
    imgui::text("Steps last update: %u, alpha %.2f", physics.steps_last_update, physics.alpha);
    imgui::text("Dropped events: %u", physics.dropped_events);
    float sum;
    foreach (sample : panel.update_ms) sum += sample;
    imgui::text("Update: %.3f ms (mean of %u)", sum / PHYSICS_TIMING_WINDOW, PHYSICS_TIMING_WINDOW);
}

fn void counters_section(PhysicsWorld* physics) @local {
    if (!imgui::collapsing_header("Counters", {})) return;
    imgui::push_id("counters");
    defer imgui::pop_id();
    PhysicsCounters counters = physics.counters();
    if (!imgui::begin_table("physics_counters", 2, { .row_bg = true })) return;
    defer imgui::end_table();
    table_row_uint("Bodies", counters.bodies);
    table_row_uint("Awake bodies", counters.awake_bodies);
    table_row_uint("Shapes", counters.shapes);
    table_row_uint("Contacts", counters.contacts);
    table_row_uint("Awake contacts", counters.awake_contacts);
    table_row_uint("Joints", counters.joints);
    table_row_uint("Islands", counters.islands);
    table_row_uint("Tree height", counters.tree_height);
    table_row_uint("Static tree height", counters.static_tree_height);
    table_row_uint("Bytes", counters.bytes);
    table_row_uint("Occupied snapshots", counters.occupied_snapshots);
    table_row_uint("Snapshot capacity", counters.snapshot_capacity);
}

fn void profile_section(PhysicsWorld* physics) @local {
    if (!imgui::collapsing_header("Profile", {})) return;
    imgui::push_id("profile");
    defer imgui::pop_id();
    PhysicsProfile profile = physics.profile();
    if (!imgui::begin_table("physics_profile", 2, { .row_bg = true })) return;
    defer imgui::end_table();
    $foreach $member : PhysicsProfile::members:
        table_row_ms($member.name, *(float*)((char*)&profile + $member.offset));
    $endforeach
}

fn void draw_section(PhysicsPanel* panel) @local {
    if (!imgui::collapsing_header("Draw", {})) return;
    imgui::push_id("draw");
    defer imgui::pop_id();
    PhysicsDebugOptions* draw = &panel.draw;
    imgui::checkbox("Colliders", &draw.colliders);
    imgui::checkbox("Contacts", &draw.contacts);
    imgui::checkbox("Bounds", &draw.bounds);
    imgui::checkbox("Joints", &draw.joints);
    imgui::checkbox("Joint extras", &draw.joint_extras);
    imgui::checkbox("Mass frames", &draw.mass);
    imgui::checkbox("Islands", &draw.islands);
    imgui::checkbox("Replay queries", &draw.queries);
    imgui::begin_disabled(!draw.contacts);
    imgui::checkbox("Contact forces", &draw.contact_forces);
    imgui::checkbox("Graph colours", &draw.graph_colors);
    imgui::checkbox("Anchors on the first body", &draw.anchor_a);
    imgui::end_disabled();
    imgui::slider_float("Force scale (0 = box3d)", &draw.force_scale, 0, DRAW_SCALE_MAX);
    imgui::slider_float("Joint scale (0 = box3d)", &draw.joint_scale, 0, DRAW_SCALE_MAX);
    imgui::text("Sink: %llu of %llu segments", (ulong)panel.sink_segments, (ulong)panel.sink_capacity);
    if (panel.sink_dropped) imgui::text_colored(WARNING_COLOR, "Dropped: %llu segments", (ulong)panel.sink_dropped);
}

fn void bodies_section(PhysicsPanel* panel) @local {
    if (!imgui::collapsing_header("Bodies", {})) return;
    imgui::push_id("bodies");
    defer imgui::pop_id();
    if (!imgui::begin_table("physics_bodies", 7, { .row_bg = true, .resizable = true })) return;
    defer imgui::end_table();
    imgui::table_setup_column("Name", {});
    imgui::table_setup_column("Kind", {});
    imgui::table_setup_column("Status", {});
    imgui::table_setup_column("Enabled", {});
    imgui::table_setup_column("Awake", {});
    imgui::table_setup_column("Mass", {});
    imgui::table_setup_column("Speed", {});
    imgui::table_headers_row();
    Scene* scene = panel.scene;
    scene.@each(PhysicsBody; entity, body) {
        Node* node = scene.node(entity);
        imgui::table_next_row();
        (void)imgui::table_next_column();
        select_row(panel, node, body.body.name.len ? body.body.name : node.name);
        (void)imgui::table_next_column();
        imgui::text_unformatted(@enum_name(BodyKind, body.body.kind));
        (void)imgui::table_next_column();
        imgui::text_unformatted(@enum_name(BodyStatus, body.status));
        (void)imgui::table_next_column();
        imgui::text_unformatted(body.body.disabled ? (ZString)"no" : (ZString)"yes");
        if (scene.has(node, RigidBody)) {
            BodyState state = panel.physics.body_state(node);
            (void)imgui::table_next_column();
            imgui::text_unformatted(state.awake ? (ZString)"yes" : (ZString)"no");
            (void)imgui::table_next_column();
            imgui::text("%.2f", state.mass);
            (void)imgui::table_next_column();
            imgui::text("%.2f", state.linear_velocity.length());
        }
    };
}

fn void selected_section(PhysicsPanel* panel) @local {
    if (!imgui::collapsing_header("Selected", { .default_open = true })) return;
    imgui::push_id("selected");
    defer imgui::pop_id();
    Scene* scene = panel.scene;
    PhysicsSelectionBlocks blocks = physics_selection_blocks(scene, panel.selection.selected);
    if (!blocks) {
        imgui::text_unformatted("Nothing physical selected");
        return;
    }
    Node* node = scene.node(panel.selection.selected);
    imgui::text_unformatted(string::tformat("%s", node.name).zstr_tcopy());
    if (blocks.body) body_block(panel, node);
    if (blocks.joint) joint_block(panel, node);
    if (blocks.ragdoll) ragdoll_block(panel, node);
    $if $feat(C3D_PHYSICS_GUI_CHARACTER):
        if (blocks.character) character_block(panel, node);
    $endif
}

fn void body_block(PhysicsPanel* panel, Node* node) @local {
    imgui::separator_text("Body");
    imgui::push_id("body_block");
    defer imgui::pop_id();
    Scene* scene = panel.scene;
    PhysicsWorld* physics = panel.physics;
    if (scene.has(node, PhysicsBody)) {
        PhysicsBody* body = scene.get(node, PhysicsBody);
        imgui::text_unformatted(@enum_name(BodyStatus, body.status));
        if (body.status == FAILED) {
            imgui::text_colored(WARNING_COLOR, "%s", string::tformat("%s", body.failure).zstr_tcopy());
        }
        bool enabled = !body.body.disabled;
        if (scene.has(node, RigidBody) && imgui::checkbox("Enabled", &enabled)) physics.set_enabled(node, enabled);
        if (imgui::button("Rebuild")) body.mark_changed();
    }
    if (!scene.has(node, RigidBody)) return;

    BodyState state = physics.body_state(node);
    imgui::text("Awake: %s, mass %.3f", state.awake ? (ZString)"yes" : (ZString)"no", state.mass);
    Vec3 center = state.center_of_mass;
    imgui::text("Centre of mass: %.2f %.2f %.2f", center.x, center.y, center.z);
    imgui::same_line();
    if (imgui::button("Wake")) physics.wake(node);
    Vec3 linear = state.linear_velocity;
    Vec3 angular = state.angular_velocity;
    bool changed = imgui::drag_float3("Linear velocity", (float*)&linear);
    changed |= imgui::drag_float3("Angular velocity", (float*)&angular);
    if (changed) physics.set_velocity(node, linear, angular);
    if (imgui::button("Teleport to origin")) {
        physics.teleport(node, { 0, 0, 0 }, maths::transform_from_mat4(node.world).rotation);
    }

    ContactPoint[] contacts = physics.contact_points(tmem, node);
    imgui::text("Contacts: %u", (uint)contacts.len);
    foreach (index, contact : contacts) {
        imgui::push_id_int((int)index);
        select_row(panel, contact.other, contact.other.name);
        imgui::same_line();
        imgui::text("sep %.3f, impulse %.3f", contact.separation, contact.normal_impulse);
        imgui::pop_id();
    }
}

fn void joint_block(PhysicsPanel* panel, Node* node) @local {
    imgui::separator_text("Joint");
    imgui::push_id("joint_block");
    defer imgui::pop_id();
    JointState? state = panel.physics.joint_state(node);
    if (catch state) {
        imgui::text_unformatted("Not bound");
        return;
    }
    imgui::text("Force: %.2f %.2f %.2f", state.force.x, state.force.y, state.force.z);
    imgui::text("Torque: %.2f %.2f %.2f", state.torque.x, state.torque.y, state.torque.z);
    imgui::text("Separation: %.4f linear, %.4f angular", state.linear_separation, state.angular_separation);
}

fn void ragdoll_block(PhysicsPanel* panel, Node* node) @local {
    imgui::separator_text("Ragdoll");
    imgui::push_id("ragdoll_block");
    defer imgui::pop_id();
    Ragdoll* ragdoll = panel.scene.get(node, Ragdoll);
    imgui::slider_float("Weight", &ragdoll.weight, 0, 1);
    imgui::slider_float("Drive strength", &ragdoll.drive_strength, 0, 1);
    if (ragdoll.recoveries) {
        imgui::text("Last recovery: %s (%u)", @enum_name(RagdollFacing, ragdoll.last_facing), ragdoll.recoveries);
    } else {
        imgui::text_unformatted("Last recovery: none");
    }
    foreach (usz bone, bone_node : ragdoll.bone_nodes) {
        imgui::push_id_int((int)bone);
        int mode = (int)ragdoll.bone_modes[bone].ordinal;
        if (imgui::combo_char("##mode", &mode, &RAGDOLL_MODE_NAMES[0], RagdollMode::len)) {
            panel.physics.set_bone_mode(node, bone, RagdollMode::from_ordinal(mode));
        }
        imgui::same_line();
        imgui::slider_float(string::tformat("%s", bone_node.name).zstr_tcopy(), &ragdoll.bone_weights[bone], 0, 1);
        imgui::pop_id();
    }
}

fn void events_section(PhysicsPanel* panel) @local {
    if (!imgui::collapsing_header("Events", {})) return;
    imgui::push_id("events");
    defer imgui::pop_id();
    if (!imgui::begin_table("physics_events", 5, { .row_bg = true, .resizable = true })) return;
    defer imgui::end_table();
    imgui::table_setup_column("Update", {});
    imgui::table_setup_column("Kind", {});
    imgui::table_setup_column("A", {});
    imgui::table_setup_column("B", {});
    imgui::table_setup_column("Value", {});
    imgui::table_headers_row();
    Scene* scene = panel.scene;
    for (uint newest = 0; newest < panel.event_count; newest++) {
        PhysicsEventRow* row = physics_event_at(panel, newest);
        imgui::push_id_int((int)newest);
        imgui::table_next_row();
        (void)imgui::table_next_column();
        imgui::text("%llu", row.update);
        (void)imgui::table_next_column();
        imgui::text_unformatted(EVENT_KIND_NAMES[row.kind.ordinal]);
        (void)imgui::table_next_column();
        entity_cell(panel, row.a);
        (void)imgui::table_next_column();
        entity_cell(panel, row.b);
        (void)imgui::table_next_column();
        if (row.kind == HIT) imgui::text("%.2f", row.value);
        if (row.kind == BUILD_FAILURE) imgui::text("%s", string::tformat("%s", row.failure).zstr_tcopy());
        imgui::pop_id();
    }
}

fn void queries_section(PhysicsPanel* panel) @local {
    if (!imgui::collapsing_header("Queries", {})) return;
    imgui::push_id("queries");
    defer imgui::pop_id();
    imgui::checkbox("Show", &panel.show_queries);
    ColliderDesc* shape = &panel.cast_shape;
    int kind;
    foreach (index, candidate : CAST_KINDS) {
        if (candidate == shape.kind) kind = (int)index;
    }
    if (imgui::combo_char("Cast", &kind, &CAST_KIND_NAMES[0], CAST_KINDS.len)) shape.kind = CAST_KINDS[kind];
    switch (shape.kind) {
        case SPHERE:
            imgui::slider_float("Radius", &shape.radius, CAST_SIZE_MIN, CAST_SIZE_MAX);
        case CAPSULE:
            imgui::slider_float("Radius", &shape.radius, CAST_SIZE_MIN, CAST_SIZE_MAX);
            imgui::slider_float("Half height", &shape.half_height, CAST_SIZE_MIN, CAST_SIZE_MAX);
        default:
            imgui::drag_float3("Half extents", (float*)&shape.half_extents);
    }
    imgui::drag_float3("Start", (float*)&shape.local.position);
    imgui::drag_float3("Translation", (float*)&panel.cast_translation);
    foreach (index, hit : panel.physics.cast_shape(tmem, *shape, panel.cast_translation)) {
        imgui::push_id_int((int)index);
        select_row(panel, hit.node, hit.node.name);
        imgui::same_line();
        imgui::text("at %.3f", hit.fraction);
        imgui::pop_id();
    }
    imgui::separator();
    imgui::drag_float3("Box min", (float*)&panel.overlap_bounds.min);
    imgui::drag_float3("Box max", (float*)&panel.overlap_bounds.max);
    foreach (index, node : panel.physics.overlap_aabb(tmem, panel.overlap_bounds)) {
        imgui::push_id_int(-1 - (int)index);
        select_row(panel, node, node.name);
        imgui::pop_id();
    }
}

fn void recording_section(PhysicsPanel* panel) @local {
    if (!imgui::collapsing_header("Recording", { .default_open = true })) return;
    imgui::push_id("recording");
    defer imgui::pop_id();
    PhysicsWorld* physics = panel.physics;
    uint kibibytes = (uint)(panel.recording_capacity / KIBIBYTE);
    if (imgui::input_scalar("Start size (KiB)", imgui::DATA_TYPE_U32, &kibibytes)) {
        panel.recording_capacity = (usz)kibibytes * KIBIBYTE;
    }
    if (physics.recording_active()) {
        if (imgui::button("Stop")) panel.stop_recording();
    } else if (imgui::button("Start")) {
        panel.start_recording();
    }
    imgui::text("Last recording: %llu bytes", (ulong)panel.recording.len);

    imgui::checkbox("Replay with box3d's mixes", &panel.replay_default_mixes);
    imgui::begin_disabled(!panel.recording.len);
    if (imgui::button("Open replay")) panel.open_replay();
    imgui::end_disabled();
    if (!panel.has_replay) return;
    imgui::same_line();
    if (imgui::button("Close")) {
        physics::destroy_physics_replay(&panel.replay);
        panel.has_replay = false;
        return;
    }
    PhysicsReplay* replay = &panel.replay;
    if (imgui::button("Step replay")) (void)replay.step();
    imgui::same_line();
    if (imgui::button("Restart")) replay.restart();
    int frame = (int)replay.frame();
    if (imgui::slider_int("Frame", &frame, 0, (int)replay.frame_count())) replay.seek((uint)frame);
    imgui::text("Frame %u of %u", replay.frame(), replay.frame_count());
    if (try diverged = replay.diverge_frame()) {
        imgui::text_colored(WARNING_COLOR, "Diverged at frame %u", diverged);
    } else {
        imgui::text_unformatted("No divergence");
    }
}

<*
 Start recording the world and keep its mixes for the replay; a fault shows in the panel.
*>
fn void PhysicsPanel.start_recording(&self) {
    self.last_failure = {};
    PhysicsTuning tuning = self.physics.desc.tuning;
    if (catch failure = self.physics.start_recording(self.recording_capacity)) {
        self.last_failure = failure;
        return;
    }
    self.recording_friction_mix = tuning.friction_mix;
    self.recording_restitution_mix = tuning.restitution_mix;
}

<*
 Stop recording and keep the bytes as the last recording; a fault shows in the panel.
*>
fn void PhysicsPanel.stop_recording(&self) {
    self.last_failure = {};
    char[]? bytes = self.physics.stop_recording(self.allocator);
    if (catch failure = bytes) {
        self.last_failure = failure;
        return;
    }
    if (self.recording.len) alloc::free(self.allocator, self.recording.ptr);
    self.recording = bytes;
}

<*
 Open a replay of the last recording, replacing an open one; a fault shows in the panel.
*>
fn void PhysicsPanel.open_replay(&self) {
    self.last_failure = {};
    if (self.has_replay) physics::destroy_physics_replay(&self.replay);
    self.has_replay = false;
    FrictionMixFn friction_mix = self.replay_default_mixes ? null : self.recording_friction_mix;
    RestitutionMixFn restitution_mix = self.replay_default_mixes ? null : self.recording_restitution_mix;
    PhysicsReplay? replay = physics::create_physics_replay(
        allocator:       self.allocator,
        data:            self.recording,
        friction_mix:    friction_mix,
        restitution_mix: restitution_mix,
    );
    if (catch failure = replay) {
        self.last_failure = failure;
        return;
    }
    self.replay = replay;
    self.has_replay = true;
}

fn void select_row(PhysicsPanel* panel, Node* node, String name) @private {
    bool selected = c3d::same_id(node.id, panel.selection.selected);
    ZString label = string::tformat("%s##%d", name.len ? name : "(unnamed)", node.id.index).zstr_tcopy();
    if (imgui::selectable_ex(label, selected, 0, {})) panel.selection.selected = node.id;
}

fn void entity_cell(PhysicsPanel* panel, Entity entity) @local {
    if (!panel.scene.world.is_alive(entity)) {
        imgui::text_unformatted("-");
        return;
    }
    Node* node = panel.scene.node(entity);
    select_row(panel, node, node.name);
}

fn bool edit_count(ZString label, uint* value, int maximum) @local {
    int count = (int)*value;
    if (!imgui::slider_int(label, &count, 1, maximum)) return false;
    *value = (uint)count;
    return true;
}

fn bool edit_positive(ZString label, float* value) @local {
    if (!imgui::drag_float(label, value)) return false;
    *value = math::max(*value, 0.0f);
    return true;
}

fn void table_row_uint(ZString label, uint value) @local {
    imgui::table_next_row();
    (void)imgui::table_next_column();
    imgui::text_unformatted(label);
    (void)imgui::table_next_column();
    imgui::text("%u", value);
}

fn void table_row_ms(ZString label, float value) @local {
    imgui::table_next_row();
    (void)imgui::table_next_column();
    imgui::text_unformatted(label);
    (void)imgui::table_next_column();
    imgui::text("%.3f ms", value);
}
