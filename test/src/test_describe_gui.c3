module c3d::test::describe_gui;

import c3d;
import c3d::anim;
import c3d::anim::ik;
import c3d::camera;
import c3d::describe;
import c3d::ecs;
import c3d::gui @public;
import c3d::gui::inspect;
import c3d::light;
import c3d::scene;
import imgui;
import std::core::mem;
import std::core::mem::allocators;
import std::math;

faultdef EDIT_REJECTED;

enum InspectorChoice : ushort @private {
    FIRST,
    SECOND,
    THIRD,
}

struct InspectorChild @private {
    bool enabled;
}

struct InspectorFields @private {
    InspectorChild child;
    int signed_value;
    uint unsigned_value;
    long signed_wide;
    ulong unsigned_wide;
    float bounded @tag("display", "Speed") @tag("range", { 0.0, 1.0 }) @tag("unit", "m/s");
    double precise;
    Vec2 planar;
    Vec3 position;
    Vec4 color;
    Quat rotation;
    InspectorChoice choice;
    int[2] fixed_values @tag("range", { 0.0, 4.0 });
    float[] values @tag("range", { 0.0, 2.0 }) @tag("unit", "kg");
    Entity target;
    GeometryId geometry;
    String title;
    int hidden_value @tag("transient", true);
}

struct DescriptionOnly @private {
    float value @tag("display", "Description only");
}

struct DescriptionPreferred @private {
    float value @tag("display", "Preferred description");
}

struct CustomPreferred @private {
    float value @tag("display", "Hidden description");
}

struct ReflectionFallback @private {
    float fallback_value;
}

struct ToggleChild @private {
    bool enabled;
    bool derived @tag("transient", true);
}

struct ToggleParent @private {
    ToggleChild child;
    bool derived @tag("transient", true);
}

struct RejectedToggle @private {
    bool reject;
}

struct RejectedContainer @private {
    RejectedToggle child;
}

struct CaptureState @private {
    gui::DescriptionInspector inspector;
    void* watched;
    imgui::Vec2 position;
}

uint[8] hook_order @private;
usz hook_count @private;
char[8192] logged_text @private;
usz logged_size @private;
uint custom_calls @private;

fn imgui::Context create_context() @private {
    imgui::Context context = imgui::create_context((imgui::FontAtlas)null);
    assert(context != null);
    imgui::set_current_context(context);
    imgui::io_set_ini_filename(null);
    imgui::io_set_display_size(1200, 1000);
    imgui::io_set_delta_time(1.0f / 60);
    imgui::io_set_config_flags({ .nav_enable_keyboard = true });
    imgui::platform_io_set_clipboard_handlers(&get_logged_text, &capture_logged_text, null);
    assert(imgui::fonts_build(imgui::io_get_fonts()));
    return context;
}

fn void begin_frame(bool capture = false) @private {
    imgui::new_frame();
    imgui::set_next_window_pos({ 0, 0 }, imgui::COND_ALWAYS);
    imgui::set_next_window_size({ 1100, 950 }, imgui::COND_ALWAYS);
    assert(imgui::begin("Description test", null, {
        .no_title_bar = true,
        .no_move = true,
        .no_resize = true,
    }));
    if (capture) {
        logged_size = 0;
        imgui::log_to_clipboard(-1);
    }
}

fn void end_frame(bool capture = false) @private {
    if (capture) imgui::log_finish();
    imgui::end();
    imgui::render();
}

fn ZString get_logged_text(imgui::Context context) @private {
    return (ZString)&logged_text;
}

fn void capture_logged_text(imgui::Context context, ZString text) @private {
    String source = text.str_view();
    assert(source.len < logged_text.len);
    mem::copy(&logged_text, source.ptr, source.len);
    logged_text[source.len] = 0;
    logged_size = source.len;
}

fn bool custom_inspector(void* value) @private {
    custom_calls++;
    imgui::text_unformatted("Custom inspector");
    return false;
}

fn void? rebuild_toggle_child(void* raw) @private {
    ToggleChild* value = raw;
    value.derived = value.enabled;
    hook_order[hook_count++] = 1;
}

fn void? rebuild_toggle_parent(void* raw) @private {
    ToggleParent* value = raw;
    value.derived = value.child.derived;
    hook_order[hook_count++] = 2;
}

fn void? reject_toggle(void* raw) @private {
    if (((RejectedToggle*)raw).reject) return EDIT_REJECTED~;
}

fn bool? capture_field(describe::Visitor* visitor, describe::Info* info, void* value) @private {
    CaptureState* state = (CaptureState*)visitor.user;
    if (value == state.watched) state.position = imgui::get_cursor_screen_pos() + (imgui::Vec2){ 8, 8 };
    return gui::description_field(visitor, info, value);
}

fn bool? capture_inspector(describe::Descriptor* descriptor, void* value, CaptureState* capture) @private {
    describe::Visitor visitor = {
        .mode = EDIT,
        .field = &capture_field,
        .begin = &gui::description_begin,
        .end = &gui::description_end,
        .user = capture,
    };
    return describe::walk_descriptor(descriptor, &visitor, value);
}

fn bool? value_frame(describe::Descriptor* descriptor, void* value, CaptureState* capture = null) @private {
    begin_frame();
    defer end_frame();
    if (capture) return capture_inspector(descriptor, value, capture);
    return gui::inspect_description(descriptor, value);
}

fn void mouse_input(imgui::Vec2 position, bool down) @private {
    imgui::Io input = imgui::get_io();
    imgui::io::add_mouse_pos_event(input, position.x, position.y);
    imgui::io::add_mouse_button_event(input, 0, down);
}

fn void component_frame(
    Scene* scene,
    Entity entity,
    GuiPanelState* panel,
    bool capture = false,
) @private {
    begin_frame(capture);
    gui::inspect_components(scene, entity, panel);
    end_frame(capture);
}

fn void test_description_inspector_preserves_exposed_builtin_paths() @test {
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    gui::expose_builtin_components();

    @assert_builtin(Mesh, false);
    @assert_builtin(LodGroup, true);
    @assert_builtin(Camera, true);
    @assert_builtin(Light, true);
    @assert_builtin(Decal, true);
    @assert_builtin(ModelInstance, false);
    @assert_builtin(SkinBinding, false);
    @assert_builtin(Animator, true);
    @assert_builtin(IkChain, true);
    @assert_builtin(FootIk, true);
    @assert_builtin(LookAt, true);
    @assert_builtin(ProbeVolume, true);
    @assert_builtin(ReflectionProbe, true);
}

fn void test_description_inspector_uses_custom_description_reflection_precedence() @test {
    describe::register_reflected_component(DescriptionOnly)!!;
    describe::register_reflected_component(DescriptionPreferred)!!;
    describe::register_reflected_component(CustomPreferred)!!;
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.register(DescriptionOnly)!!;
    scene.register(DescriptionPreferred)!!;
    scene.register(CustomPreferred)!!;
    scene.register(ReflectionFallback)!!;
    gui::expose(DescriptionPreferred);
    gui::expose(CustomPreferred, &custom_inspector);
    gui::expose(ReflectionFallback);
    assert(gui::inspector_of(ecs::assigned_slot(DescriptionOnly)!!).inspect == null);
    Node* node = scene.add_node(name: "Inspected")!!;
    scene.add(node, (DescriptionOnly){});
    scene.add(node, (DescriptionPreferred){});
    scene.add(node, (CustomPreferred){});
    scene.add(node, (ReflectionFallback){});
    GuiPanelState panel;
    imgui::Context context = create_context();
    defer imgui::destroy_context(context);
    custom_calls = 0;
    begin_frame(true);
    @open_component(CustomPreferred);
    @open_component(ReflectionFallback);
    gui::inspect_components(&scene, node.id, &panel);
    end_frame(true);
    String output = (String)logged_text[:logged_size];
    assert(output.contains("Description only"));
    assert(output.contains("Preferred description"));
    assert(!output.contains("Hidden description"));
    assert(output.contains("Custom inspector"));
    assert(output.contains("fallback_value"));
    assert(custom_calls == 1);
}

fn void test_description_inspector_metadata_and_traversal_use_no_c3_allocations() @test {
    describe::register_reflected(InspectorChild)!!;
    describe::register_reflected(InspectorFields)!!;
    float[2] elements = { 0.25f, 0.75f };
    InspectorFields value = {
        .signed_value = int::min,
        .unsigned_value = uint::max,
        .signed_wide = long::max,
        .unsigned_wide = ulong::max,
        .bounded = 0.5f,
        .precise = 1.25,
        .rotation = quaternion::IDENTITY,
        .choice = SECOND,
        .fixed_values = { 3, 4 },
        .values = elements[..],
        .target = { .index = 7, .generation = 2 },
        .geometry = { .index = 9, .generation = 3 },
        .title = "Read-only text",
        .hidden_value = 123,
    };
    describe::Descriptor* descriptor = describe::get(InspectorFields)!!;
    imgui::Context context = create_context();
    defer imgui::destroy_context(context);
    begin_frame();
    assert(!gui::inspect_description(descriptor, &value)!!);
    end_frame();

    begin_frame(true);
    allocators::NullAllocator rejecting;
    Allocator previous_temp = allocators::current_temp;
    allocators::current_temp = &rejecting;
    mem::@scoped(&rejecting) {
        assert(!gui::inspect_description(descriptor, &value)!!);
    };
    allocators::current_temp = previous_temp;
    end_frame(true);
    String output = (String)logged_text[:logged_size];
    assert(output.contains("Speed"));
    assert(output.contains("m/s"));
    assert(output.contains("SECOND"));
    assert(output.contains("Entity 7:2"));
    assert(output.contains("GEOMETRY 9:3"));
    assert(output.contains("Read-only text"));
    assert(!output.contains("hidden_value"));
    assert(value.unsigned_value == uint::max);
    assert(value.signed_wide == long::max);
    assert(value.unsigned_wide == ulong::max);
    assert(value.values.ptr == &elements[0] && value.values.len == elements.len);
}

macro void @assert_builtin($Type, bool custom) @private {
    uint slot = ecs::assigned_slot($Type)!!;
    Inspector inspector = gui::inspector_of(slot);
    assert(inspector.inspect != null);
    assert(inspector.custom == custom);
    if (catch excuse = describe::component(slot)) {
        assert(excuse == describe::MISSING_DESCRIPTION);
    } else {
        assert(false, "Built-in unexpectedly has a description.");
    }
    if (!custom) assert(inspector.inspect == &gui::inspect::inspect{$Type});
    return;
}

macro void @open_component($Type) @private {
    uint slot = ecs::assigned_slot($Type)!!;
    imgui::push_id_int((int)slot);
    defer imgui::pop_id();
    imgui::storage::set_int(imgui::get_state_storage(), imgui::get_id(gui::inspector_of(slot).name), 1);
    return;
}

fn void test_description_inspector_runs_hooks_once_after_actual_nested_edits() @test {
    describe::register_reflected(ToggleChild, &rebuild_toggle_child)!!;
    describe::register_reflected(ToggleParent, &rebuild_toggle_parent)!!;
    ToggleParent value;
    describe::Descriptor* descriptor = describe::get(ToggleParent)!!;
    imgui::Context context = create_context();
    defer imgui::destroy_context(context);
    hook_count = 0;
    CaptureState capture = { .watched = &value.child.enabled };
    assert(!value_frame(descriptor, &value, &capture)!!);
    assert(hook_count == 0);
    mouse_input(capture.position, false);
    assert(!value_frame(descriptor, &value)!!);
    mouse_input(capture.position, true);
    assert(!value_frame(descriptor, &value)!!);
    mouse_input(capture.position, false);
    assert(value_frame(descriptor, &value)!!);
    assert(value.child.enabled && value.child.derived && value.derived);
    assert(hook_count == 2 && hook_order[0] == 1 && hook_order[1] == 2);
    hook_count = 0;
    assert(!value_frame(descriptor, &value)!!);
    assert(hook_count == 0);
}

fn void test_description_inspector_clamps_ranges_and_edits_existing_sequence_elements() @test {
    describe::register_reflected(InspectorChild)!!;
    describe::register_reflected(InspectorFields)!!;
    float[2] elements = { 0.25f, 0.75f };
    InspectorFields value = {
        .bounded = 0.5f,
        .rotation = quaternion::IDENTITY,
        .values = elements[..],
    };
    describe::Descriptor* descriptor = describe::get(InspectorFields)!!;
    imgui::Context context = create_context();
    defer imgui::destroy_context(context);
    CaptureState capture = { .watched = &value.bounded };
    assert(!value_frame(descriptor, &value, &capture)!!);
    mouse_input(capture.position, false);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position, true);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position + (imgui::Vec2){ 500, 0 }, true);
    assert(value_frame(descriptor, &value)!!);
    mouse_input(capture.position + (imgui::Vec2){ 500, 0 }, false);
    (void)value_frame(descriptor, &value)!!;
    assert(value.bounded == 1);

    capture.watched = &value.fixed_values[0];
    (void)value_frame(descriptor, &value, &capture)!!;
    mouse_input(capture.position, false);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position, true);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position + (imgui::Vec2){ 100, 0 }, true);
    assert(value_frame(descriptor, &value)!!);
    mouse_input(capture.position + (imgui::Vec2){ 100, 0 }, false);
    (void)value_frame(descriptor, &value)!!;
    assert(value.fixed_values[0] == 4 && value.fixed_values[1] == 0);

    capture.watched = &elements[1];
    (void)value_frame(descriptor, &value, &capture)!!;
    mouse_input(capture.position, false);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position, true);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position + (imgui::Vec2){ 100, 0 }, true);
    assert(value_frame(descriptor, &value)!!);
    mouse_input(capture.position + (imgui::Vec2){ 100, 0 }, false);
    (void)value_frame(descriptor, &value)!!;
    assert(elements[0] == 0.25f && elements[1] == 2);
    assert(value.values.ptr == &elements[0] && value.values.len == elements.len);
}

fn void test_description_inspector_keeps_failed_edit_and_inline_fault_until_success() @test {
    describe::register_reflected(RejectedToggle, &reject_toggle)!!;
    describe::register_reflected_component(RejectedContainer)!!;
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.register(RejectedContainer)!!;
    Node* node = scene.add_node(name: "Rejected edit")!!;
    RejectedContainer* value = scene.add(node, (RejectedContainer){});
    uint slot = ecs::assigned_slot(RejectedContainer)!!;
    describe::Descriptor* descriptor = describe::get(RejectedContainer)!!;
    GuiPanelState panel;
    imgui::Context context = create_context();
    defer imgui::destroy_context(context);
    CaptureState capture = { .watched = &value.child.reject };
    begin_frame();
    imgui::push_id_int((int)slot);
    assert(!capture_inspector(descriptor, value, &capture)!!);
    imgui::pop_id();
    end_frame();
    mouse_input(capture.position, false);
    component_frame(&scene, node.id, &panel);
    mouse_input(capture.position, true);
    component_frame(&scene, node.id, &panel);
    mouse_input(capture.position, false);
    component_frame(
        scene: &scene,
        entity: node.id,
        panel: &panel,
        capture: true,
    );
    assert(value.child.reject);
    assert(panel.description_errors[slot] == EDIT_REJECTED);
    assert(((String)logged_text[:logged_size]).contains("Edit failed:"));
    assert(((String)logged_text[:logged_size]).contains("EDIT_REJECTED"));
    component_frame(
        scene: &scene,
        entity: node.id,
        panel: &panel,
        capture: true,
    );
    assert(panel.description_errors[slot] == EDIT_REJECTED);
    assert(((String)logged_text[:logged_size]).contains("EDIT_REJECTED"));
    mouse_input(capture.position, true);
    component_frame(&scene, node.id, &panel);
    mouse_input(capture.position, false);
    component_frame(
        scene: &scene,
        entity: node.id,
        panel: &panel,
        capture: true,
    );
    assert(!value.child.reject);
    assert(!panel.description_errors[slot]);
    assert(!((String)logged_text[:logged_size]).contains("Edit failed:"));
}

fn void test_description_inspector_selects_declared_enum_values_and_normalizes_quaternion_edits() @test {
    describe::register_reflected(InspectorChild)!!;
    describe::register_reflected(InspectorFields)!!;
    InspectorFields value = { .rotation = quaternion::IDENTITY };
    describe::Descriptor* descriptor = describe::get(InspectorFields)!!;
    imgui::Context context = create_context();
    defer imgui::destroy_context(context);
    CaptureState capture = { .watched = &value.choice };
    assert(!value_frame(descriptor, &value, &capture)!!);
    mouse_input(capture.position, false);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position, true);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position, false);
    (void)value_frame(descriptor, &value)!!;
    begin_frame(true);
    (void)gui::inspect_description(descriptor, &value)!!;
    end_frame(true);
    String choices = (String)logged_text[:logged_size];
    assert(choices.contains("FIRST") && choices.contains("SECOND") && choices.contains("THIRD"));
    imgui::Io input = imgui::get_io();
    imgui::io::add_key_event(input, imgui::KEY_DOWN_ARROW, true);
    (void)value_frame(descriptor, &value)!!;
    imgui::io::add_key_event(input, imgui::KEY_DOWN_ARROW, false);
    (void)value_frame(descriptor, &value)!!;
    imgui::io::add_key_event(input, imgui::KEY_ENTER, true);
    (void)value_frame(descriptor, &value)!!;
    imgui::io::add_key_event(input, imgui::KEY_ENTER, false);
    (void)value_frame(descriptor, &value)!!;
    assert(value.choice == SECOND);

    capture.watched = &value.rotation;
    (void)value_frame(descriptor, &value, &capture)!!;
    mouse_input(capture.position, false);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position, true);
    (void)value_frame(descriptor, &value)!!;
    mouse_input(capture.position + (imgui::Vec2){ 40, 0 }, true);
    assert(value_frame(descriptor, &value)!!);
    mouse_input(capture.position + (imgui::Vec2){ 40, 0 }, false);
    (void)value_frame(descriptor, &value)!!;
    assert(value.rotation.v != (Vec4){ 0, 0, 0, 1 });
    assert(math::abs(value.rotation.length() - 1) < 0.00001f);
}
