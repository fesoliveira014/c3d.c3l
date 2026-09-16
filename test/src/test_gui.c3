module c3d::test::gui;

import c3d;
import c3d::gui;
import c3d::gui::backend;
import c3d::gui::inspect;
import c3d::maths;
import c3d::platform;
import c3d::shader;
import gpu;
import imgui;
import std::math;

const float TOLERANCE @local = 0.00001f;

fn void test_gui_clip_applies_origin_density_and_pixel_coverage() @test {
    gpu::ScissorRect clipped = backend::gui_scissor(
        clip:              { 90.25f, 40.25f, 170.75f, 95.5f },
        display_position:  { 100, 50 },
        framebuffer_scale: { 2, 1.5f },
        width:             400,
        height:            150,
    );
    assert(clipped.x == 0 && clipped.y == 0);
    assert(clipped.width == 142 && clipped.height == 69);

    gpu::ScissorRect interior = backend::gui_scissor(
        clip:              { 110.25f, 60.5f, 130.75f, 80.25f },
        display_position:  { 100, 50 },
        framebuffer_scale: { 2, 1.5f },
        width:             400,
        height:            150,
    );
    assert(interior.x == 20 && interior.y == 15);
    assert(interior.width == 42 && interior.height == 31);
}

fn void test_gui_clip_preserves_empty_intersections() @test {
    Vec4[4] clips = {
        { 80, 60, 90, 80 },
        { 310, 60, 320, 80 },
        { 110, 160, 130, 170 },
        { 110.2f, 60, 110.2f, 80 },
    };

    foreach (clip : clips) {
        gpu::ScissorRect clipped = backend::gui_scissor(
            clip:              clip,
            display_position:  { 100, 50 },
            framebuffer_scale: { 2, 1.5f },
            width:             400,
            height:            150,
        );

        assert(clipped.width == 0 && clipped.height == 0);
    }
}

fn void test_gui_root_preserves_vertex_stride_and_display_corners() @test {
    GuiVertexRoot root;
    backend::write_gui_vertex_root(
        root:             &root,
        vertices:         (gpu::GpuAddress)0x1000,
        vertex_offset:    3,
        display_position: { 100, 50 },
        display_size:     { 200, 100 },
    );

    assert((ulong)root.vertices == 0x103c);

    Vec2 top_left = (Vec2){ 100, 50 } * root.scale + root.translate;
    Vec2 bottom_right = (Vec2){ 300, 150 } * root.scale + root.translate;

    assert(math::abs(top_left.x + 1) < TOLERANCE);
    assert(math::abs(top_left.y - 1) < TOLERANCE);
    assert(math::abs(bottom_right.x - 1) < TOLERANCE);
    assert(math::abs(bottom_right.y + 1) < TOLERANCE);
}

enum ProbeMode @local {
    FIRST,
    SECOND,
}

struct InspectProbe @local {
    float     speed;
    int       count;
    uint      flags;
    bool      on;
    Vec3      direction;
    Quat      rotation;
    ProbeMode mode;
    c3d::Id   asset;
    float[]   weights;
    Aabb      bounds;
    void*     owner;
}

fn void test_gui_generic_inspector_accepts_every_supported_kind() @test {
    InspectFn probe = &gui::inspect::inspect{InspectProbe};
    assert(probe != null);
}

fn void test_imgui_key_table_maps_named_scancodes() @test {
    assert(gui::imgui_key_of(platform::Scancode.A) == imgui::KEY_A);
    assert(gui::imgui_key_of(platform::Scancode.Z) == imgui::KEY_Z);
    assert(gui::imgui_key_of(platform::Scancode.CODE_1) == imgui::KEY_1);
    assert(gui::imgui_key_of(platform::Scancode.CODE_0) == imgui::KEY_0);
    assert(gui::imgui_key_of(platform::Scancode.F1) == imgui::KEY_F1);
    assert(gui::imgui_key_of(platform::Scancode.F12) == imgui::KEY_F12);
    assert(gui::imgui_key_of(platform::Scancode.RETURN) == imgui::KEY_ENTER);
    assert(gui::imgui_key_of(platform::Scancode.ESCAPE) == imgui::KEY_ESCAPE);
    assert(gui::imgui_key_of(platform::Scancode.SPACE) == imgui::KEY_SPACE);
    assert(gui::imgui_key_of(platform::Scancode.BACKSPACE) == imgui::KEY_BACKSPACE);
    assert(gui::imgui_key_of(platform::Scancode.TAB) == imgui::KEY_TAB);
    assert(gui::imgui_key_of(platform::Scancode.LEFT) == imgui::KEY_LEFT_ARROW);
    assert(gui::imgui_key_of(platform::Scancode.RIGHT) == imgui::KEY_RIGHT_ARROW);
    assert(gui::imgui_key_of(platform::Scancode.UP) == imgui::KEY_UP_ARROW);
    assert(gui::imgui_key_of(platform::Scancode.DOWN) == imgui::KEY_DOWN_ARROW);
    assert(gui::imgui_key_of(platform::Scancode.KP_ENTER) == imgui::KEY_KEYPAD_ENTER);
    assert(gui::imgui_key_of(platform::Scancode.LCTRL) == imgui::KEY_LEFT_CTRL);
    assert(gui::imgui_key_of(platform::Scancode.RGUI) == imgui::KEY_RIGHT_SUPER);
    assert(gui::imgui_key_of(platform::Scancode.UNKNOWN) == imgui::KEY_NONE);
    assert(gui::imgui_key_of((platform::Scancode)1) == imgui::KEY_NONE);
}

fn void test_imgui_button_indices_follow_imgui_order() @test {
    int index;
    assert(gui::imgui_button_of(platform::MouseButton.LEFT, &index) && index == 0);
    assert(gui::imgui_button_of(platform::MouseButton.RIGHT, &index) && index == 1);
    assert(gui::imgui_button_of(platform::MouseButton.MIDDLE, &index) && index == 2);
    assert(gui::imgui_button_of(platform::MouseButton.X1, &index) && index == 3);
    assert(gui::imgui_button_of(platform::MouseButton.X2, &index) && index == 4);
    assert(!gui::imgui_button_of((platform::MouseButton)7, &index) && index == 4);
}
