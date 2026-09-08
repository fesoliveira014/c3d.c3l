module c3d::test::render;

import c3d;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render;
import c3d::shader;
import gpu;
import std::io;
import std::math;

fn gpu::DebugMessage diagnostic(ZString operation, ZString backend_text) @local {
    return {
        .severity             = gpu::DebugMessageSeverity.ERROR,
        .category             = { .validation = true },
        .operation            = operation,
        .has_fault            = true,
        .public_fault         = gpu::INVALID_HANDLE,
        .resource             = {
            .kind       = gpu::DebugResourceKind.TEXTURE,
            .index      = 7,
            .debug_name = "hdr_color",
        },
        .backend_text         = backend_text,
        .validation_id_number = 1234,
    };
}

fn String entry_text(render::DebugEntry* entry) @local {
    return ((ZString)&entry.text[0]).str_view();
}

fn void test_growth_keeps_capacity_when_demand_fits() @test {
    assert(render::grown_capacity(32, 0) == 32);
    assert(render::grown_capacity(32, 31) == 32);
    assert(render::grown_capacity(32, 32) == 32);
}

fn void test_growth_doubles_until_demand_fits() @test {
    assert(render::grown_capacity(32, 33) == 64);
    assert(render::grown_capacity(32, 64) == 64);
    assert(render::grown_capacity(32, 65) == 128);
    assert(render::grown_capacity(32, 100) == 128);
}

fn void test_growth_from_smallest_capacity_terminates() @test {
    assert(render::grown_capacity(1, 1000) == 1024);
}

fn void test_debug_entry_copies_message_fields() @test {
    render::DebugLog log;
    gpu::DebugMessage message = diagnostic("cmd_texture_barrier", "layout mismatch");
    log.record(&message);

    render::DebugEntry[1] recent;
    assert(log.recent(recent[..]) == 1);
    render::DebugEntry* entry = &recent[0];
    assert(entry.severity == gpu::DebugMessageSeverity.ERROR);
    assert(entry.category.validation);
    assert(entry.resource_kind == gpu::DebugResourceKind.TEXTURE);
    assert(entry.resource_index == 7);
    assert(entry.validation_id_number == 1234);
    assert(entry.has_fault);
    assert(entry.public_fault == gpu::INVALID_HANDLE);
    assert(((ZString)&entry.operation[0]).str_view() == "cmd_texture_barrier");
    assert(entry_text(entry) == "layout mismatch");
}

fn void test_debug_text_is_truncated_and_terminated() @test {
    char[render::DEBUG_TEXT_BYTES * 2] long_text;
    for (usz index = 0; index < long_text.len - 1; index++) long_text[index] = 'x';
    long_text[long_text.len - 1] = 0;

    render::DebugLog log;
    gpu::DebugMessage message = diagnostic("submit", (ZString)&long_text[0]);
    log.record(&message);

    render::DebugEntry[1] recent;
    assert(log.recent(recent[..]) == 1);
    assert(entry_text(&recent[0]).len == render::DEBUG_TEXT_BYTES - 1);
}

fn void test_debug_text_of_a_null_string_is_empty() @test {
    render::DebugLog log;
    gpu::DebugMessage message = diagnostic("submit", null);
    message.invariant = null;
    log.record(&message);

    render::DebugEntry[1] recent;
    assert(log.recent(recent[..]) == 1);
    assert(entry_text(&recent[0]).len == 0);
}

fn void test_debug_log_recent_before_first_wrap() @test {
    render::DebugLog log;
    @pool() {
        for (usz index = 0; index < 3; index++) {
            gpu::DebugMessage message = diagnostic("submit", string::tformat("%d", index).zstr_tcopy());
            log.record(&message);
        }
    };

    render::DebugEntry[render::DEBUG_LOG_ENTRIES] recent;
    assert(log.recent(recent[..]) == 3);
    assert(entry_text(&recent[0]) == "0");
    assert(entry_text(&recent[2]) == "2");
}

fn void test_debug_log_wraps_and_reports_recent_oldest_first() @test {
    render::DebugLog log;
    usz total = render::DEBUG_LOG_ENTRIES + 3;
    @pool() {
        for (usz index = 0; index < total; index++) {
            gpu::DebugMessage message = diagnostic("submit", string::tformat("%d", index).zstr_tcopy());
            log.record(&message);
        }
    };

    render::DebugEntry[render::DEBUG_LOG_ENTRIES] recent;
    assert(log.recent(recent[..]) == render::DEBUG_LOG_ENTRIES);
    assert(entry_text(&recent[0]) == "3");
    assert(entry_text(&recent[render::DEBUG_LOG_ENTRIES - 1]) == "66");
}

fn void test_debug_log_recent_is_limited_by_the_destination() @test {
    render::DebugLog log;
    @pool() {
        for (usz index = 0; index < 10; index++) {
            gpu::DebugMessage message = diagnostic("submit", string::tformat("%d", index).zstr_tcopy());
            log.record(&message);
        }
    };

    render::DebugEntry[2] recent;
    assert(log.recent(recent[..]) == 2);
    assert(entry_text(&recent[0]) == "8");
    assert(entry_text(&recent[1]) == "9");
}

fn void test_timestamp_slots_do_not_overlap_between_frames() @test {
    bool[render::FRAMES_IN_FLIGHT * render::PASS_COUNT * render::TIMESTAMPS_PER_PASS] claimed;
    for (ulong frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) {
        for (usz pass = 0; pass < render::PASS_COUNT; pass++) {
            uint first = render::pass_timestamp_slot(frame, pass);
            for (uint half = 0; half < render::TIMESTAMPS_PER_PASS; half++) {
                assert(!claimed[first + half]);
                claimed[first + half] = true;
            }
        }
    }
    foreach (slot : claimed) assert(slot);
}

fn void test_routine_faults_are_still_recorded_in_the_log() @test {
    render::DebugLog log;
    gpu::DebugMessage message = diagnostic("present", "swapchain is out of date");
    message.public_fault = gpu::SWAPCHAIN_OUT_OF_DATE;
    log.record(&message);

    render::DebugEntry[1] recent;
    assert(log.recent(recent[..]) == 1);
    assert(recent[0].public_fault == gpu::SWAPCHAIN_OUT_OF_DATE);
}

fn void test_flipped_viewport_covers_the_area_upside_down() @test {
    gpu::Viewport viewport = render::flipped_viewport(1280, 720);
    assert(viewport.x == 0.0f);
    assert(viewport.y == 720.0f);
    assert(viewport.width == 1280.0f);
    assert(viewport.height == -720.0f);
    assert(viewport.min_depth == 0.0f);
    assert(viewport.max_depth == 1.0f);
}

fn render::PipelineKey gradient_key() @local {
    return {
        .vertex        = { .shader = shader::ShaderName.FULLSCREEN },
        .fragment      = { .shader = shader::ShaderName.GRADIENT },
        .color_formats = { [0] = gpu::Format.RGBA16_FLOAT },
        .color_count   = 1,
        .depth_format  = gpu::Format.UNDEFINED,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
}

fn void test_pipeline_keys_with_equal_fields_match() @test {
    render::PipelineKey first = gradient_key();
    render::PipelineKey second = gradient_key();
    assert(first.equals(second));
    assert(first.hash() == second.hash());
}

fn void test_pipeline_key_differs_by_any_field() @test {
    render::PipelineKey base = gradient_key();

    render::PipelineKey other_fragment = gradient_key();
    other_fragment.fragment = { .shader = shader::ShaderName.COMPOSITE };
    assert(!base.equals(other_fragment));

    render::PipelineKey other_format = gradient_key();
    other_format.color_formats[0] = gpu::Format.BGRA8_UNORM;
    assert(!base.equals(other_format));

    render::PipelineKey more_targets = gradient_key();
    more_targets.color_count = 2;
    assert(!base.equals(more_targets));

    render::PipelineKey with_depth = gradient_key();
    with_depth.depth_format = gpu::Format.D32_FLOAT;
    assert(!base.equals(with_depth));
}

fn Geometry make_quad(Allocator allocator) @local {
    Vec3[] positions = alloc::new_array(allocator, Vec3, 4);
    positions[0] = { 0, 0, 0 };
    positions[1] = { 1, 0, 0 };
    positions[2] = { 1, 1, 0 };
    positions[3] = { 0, 1, 0 };
    Vec3[] normals = alloc::new_array(allocator, Vec3, 4);
    normals[..] = (Vec3){ 0, 0, 1 };
    Vec2[] uv0 = alloc::new_array(allocator, Vec2, 4);
    foreach (index, position : positions) uv0[index] = { position.x, position.y };
    uint[] indices = alloc::new_array(allocator, uint, 6);
    indices[..] = (uint[6]){ 0, 1, 2, 0, 2, 3 }[..];
    return {
        .topology  = Topology.TRIANGLES,
        .positions = positions,
        .normals   = normals,
        .uv0       = uv0,
        .indices   = indices,
    };
}

fn void test_geometry_layout_aligns_every_stream() @test {
    @pool() {
        Geometry quad = make_quad(tmem);
        render::GeometryLayout layout = render::geometry_layout(&quad);

        assert(layout.positions == 112 && layout.normals == 160 && layout.uv0 == 208 && layout.indices == 240);
        assert(layout.total_bytes == 252);
        assert(layout.tangents == 0 && layout.uv1 == 0 && layout.colors == 0 && layout.joints == 0);
        assert(layout.flags.has_normals && layout.flags.has_uv0 && layout.flags.indices_u16);
        assert(!layout.flags.has_tangents && !layout.flags.skinned && !layout.flags.has_morphs);
        assert(layout.vertex_count == 4 && layout.index_count == 6 && layout.index_stride == 2);
    };
}

fn void test_geometry_layout_widens_indices_past_ushort() @test {
    @pool() {
        Geometry wide = {
            .topology  = Topology.TRIANGLES,
            .positions = alloc::new_array(tmem, Vec3, 65536),
            .indices   = alloc::new_array(tmem, uint, 3),
        };
        render::GeometryLayout layout = render::geometry_layout(&wide);

        assert(!layout.flags.indices_u16 && layout.index_stride == 4);
        assert(layout.total_bytes - layout.indices == 12);
    };
}

fn void test_layouts_compare_whole() @test {
    @pool() {
        Geometry quad = make_quad(tmem);
        render::GeometryLayout first = render::geometry_layout(&quad);
        render::GeometryLayout second = render::geometry_layout(&quad);
        assert(mem::equals(&first, &second, render::GeometryLayout::size));

        quad.uv1 = quad.uv0;
        render::GeometryLayout changed = render::geometry_layout(&quad);
        assert(!mem::equals(&first, &changed, render::GeometryLayout::size));
        assert(changed.uv1 == 240 && changed.indices == 272);
    };
}

fn void test_write_geometry_block_fills_the_root() @test {
    @pool() {
        Geometry quad = make_quad(tmem);
        render::GeometryLayout layout = render::geometry_layout(&quad);
        char[] block = alloc::new_array(tmem, char, (sz)layout.total_bytes);
        render::write_geometry_block(
            block:    block,
            geometry: &quad,
            layout:   &layout,
            base:     (gpu::GpuAddress)0x1000,
        );

        shader::GeometryRoot* root = (shader::GeometryRoot*)block.ptr;
        assert((ulong)root.positions == 0x1070 && (ulong)root.normals == 0x10A0 && (ulong)root.uv0 == 0x10D0);
        assert((ulong)root.tangents == 0 && (ulong)root.colors == 0 && (ulong)root.custom_data == 0);
        assert(root.vertex_count == 4 && root.morph_target_count == 0 && root.custom_stride == 0);
        assert(root.flags == (uint)layout.flags);

        float* positions = (float*)&block[layout.positions];
        assert(positions[3] == 1 && positions[4] == 0 && positions[5] == 0);
        ushort* indices = (ushort*)&block[layout.indices];
        assert(indices[0] == 0 && indices[1] == 1 && indices[2] == 2 && indices[5] == 3);
    };
}

fn ulong key_of(uint fragment, uint material, uint geometry, float depth) @local {
    return render::draw_sort_key(
        fragment:  { .shader = (shader::ShaderName)fragment },
        material:  { .index = material, .generation = 1 },
        geometry:  { .index = geometry, .generation = 1 },
        ndc_depth: depth,
    );
}

fn void test_sort_key_orders_pipeline_material_geometry_then_depth() @test {
    ulong base = key_of(1, 5, 7, 0.5f);
    assert(base == key_of(1, 5, 7, 0.5f));
    assert(key_of(2, 0, 0, 1.0f) > key_of(1, 9, 9, 0.0f));
    assert(key_of(1, 6, 0, 1.0f) > key_of(1, 5, 9, 0.0f));
    assert(key_of(1, 5, 8, 1.0f) > key_of(1, 5, 7, 0.0f));
}

fn void test_sort_key_depth_is_front_to_back() @test {
    assert(key_of(1, 5, 7, 1.0f) < key_of(1, 5, 7, 0.5f));
    assert(key_of(1, 5, 7, 0.5f) < key_of(1, 5, 7, 0.0f));
}

fn void test_material_block_packs_flags_and_color() @test {
    char[] block = mem::new_array(char, render::MATERIAL_STRIDE);
    defer free(block.ptr);
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.MASK;
    common.double_sided = true;
    common.alpha_cutoff = 0.3f;
    Material masked = material::basic({ .color = { 0.1f, 0.2f, 0.3f, 0.4f } }, common);
    render::write_material_block(block, &masked);
    shader::BasicMaterialGpu* packed = (shader::BasicMaterialGpu*)block.ptr;
    assert(packed.kind == 0 && packed.flags == 3);
    assert(packed.alpha_cutoff == 0.3f);
    assert(packed.color == (Vec4){ 0.1f, 0.2f, 0.3f, 0.4f });

    Material plain = material::basic({ .color = { 1, 1, 1, 1 } });
    render::write_material_block(block, &plain);
    assert(packed.flags == 0);
}

fn void test_frame_root_packs_camera() @test {
    shader::FrameRoot* root = mem::new(shader::FrameRoot);
    defer free(root);
    Camera camera = camera::perspective_deg(60, 0.1f, 100);
    camera.exposure = 2;
    Transform transform = maths::TRANSFORM_IDENTITY;
    transform.position = { 0, 0, 5 };
    CameraMatrices matrices = camera::derive_matrices(camera, transform.to_mat4(), { 1600, 900 });
    render::write_frame_root(
        root:        root,
        matrices:    &matrices,
        camera:      &camera,
        viewport:    { 1600, 900 },
        info:        { .time = 12.5, .delta = 0.25f },
        frame_index: 42,
    );
    assert(root.view[3] == (Vec4){ 0, 0, -5, 1 });
    assert(root.camera_position == (Vec4){ 0, 0, 5, 2 });
    assert(root.camera_params == (Vec4){ 0.1f, 100, 1600, 900 });
    assert(root.jitter_time.z == 12.5f && root.jitter_time.w == 0.25f);
    assert(root.frame_index == 42);
    assert((ulong)root.lights == 0 && root.light_count == 0);
}

fn void test_draw_root_packs_normal_columns() @test {
    shader::DrawRoot* root = mem::new(shader::DrawRoot);
    defer free(root);
    Transform transform = { .position = { 1, 2, 3 }, .rotation = quaternion::IDENTITY, .scale = { 2, 1, 1 } };
    render::write_draw_root(
        root:      root,
        world:     transform.to_mat4(),
        frame:     (gpu::GpuAddress)0x100,
        geometry:  (gpu::GpuAddress)0x200,
        material:  (gpu::GpuAddress)0x300,
        object_id: 9,
    );
    assert(root.model[3] == (Vec4){ 1, 2, 3, 1 });
    assert(root.normal_0.x == 0.5f && root.normal_1.y == 1 && root.normal_2.z == 1);
    assert((ulong)root.frame == 0x100 && (ulong)root.geometry == 0x200 && (ulong)root.material == 0x300);
    assert(root.object_id == 9 && (ulong)root.skin == 0);
}
