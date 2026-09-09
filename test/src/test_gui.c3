module c3d::test::gui;

import c3d::gui::backend;
import c3d::shader;
import gpu;
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
