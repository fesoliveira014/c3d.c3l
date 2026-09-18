module c3d::test::render;

import c3d;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::pool;
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

fn ulong key_of(uint fragment, uint material, uint geometry, float depth, uint vertex_flags = 0) @local {
    return render::draw_sort_key(
        vertex:    { .shader = MESH, .flags = vertex_flags },
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
    assert(key_of(1, 0, 0, 1.0f, shader::SHADER_FLAG_SKINNED) > key_of(1, 9, 9, 0.0f));
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
    render::write_material_block(block, &masked, {});
    shader::BasicMaterialGpu* packed = (shader::BasicMaterialGpu*)block.ptr;
    assert(packed.kind == 0 && packed.flags == 3);
    assert(packed.alpha_cutoff == 0.3f);
    assert(packed.color == (Vec4){ 0.1f, 0.2f, 0.3f, 0.4f });

    Material plain = material::basic({ .color = { 1, 1, 1, 1 } });
    render::write_material_block(block, &plain, {});
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
    assert((ulong)root.shadows == 0 && root.shadow_count == 0);
}

fn void test_draw_root_packs_normal_columns() @test {
    shader::DrawRoot* root = mem::new(shader::DrawRoot);
    defer free(root);
    Transform transform = { .position = { 1, 2, 3 }, .rotation = quaternion::IDENTITY, .scale = { 2, 1, 1 } };
    render::write_draw_root(
        root:      root,
        world:     transform.to_mat4(),
        prev_world: matrix::IDENTITY4,
        frame:     (gpu::GpuAddress)0x100,
        geometry:  (gpu::GpuAddress)0x200,
        material:  (gpu::GpuAddress)0x300,
        object_id: 9,
    );
    assert(root.model[3] == (Vec4){ 1, 2, 3, 1 });
    assert(root.normal_0.x == 0.5f && root.normal_1.y == 1 && root.normal_2.z == 1);
    assert(root.prev_model[3] == (Vec4){ 0, 0, 0, 1 });
    assert((ulong)root.frame == 0x100 && (ulong)root.geometry == 0x200 && (ulong)root.material == 0x300);
    assert(root.object_id == 9 && (ulong)root.skin == 0);
    assert(root.flags == 0);
}

fn Geometry skinned_triangle(Allocator allocator, ushort[<4>] highest) @local {
    Geometry triangle = {
        .topology  = Topology.TRIANGLES,
        .positions = alloc::new_array(allocator, Vec3, 3),
        .joints    = alloc::new_array(allocator, ushort[<4>], 3),
        .weights   = alloc::new_array(allocator, Vec4, 3),
    };
    triangle.joints[0] = { 0, 1, 2, 3 };
    triangle.joints[1] = highest;
    triangle.joints[2] = { 5, 6, 7, 8 };
    return triangle;
}

fn void test_joints_pack_as_u16_when_any_index_exceeds_255() @test {
    @pool() {
        Geometry narrow = skinned_triangle(tmem, { 255, 1, 0, 0 });
        render::GeometryLayout narrow_layout = render::geometry_layout(&narrow);
        assert(narrow_layout.flags.skinned && !narrow_layout.flags.joints_u16);
        assert(narrow_layout.weights - narrow_layout.joints == 16);

        Geometry wide = skinned_triangle(tmem, { 300, 1, 0, 65535 });
        render::GeometryLayout layout = render::geometry_layout(&wide);
        assert(layout.flags.joints_u16 && layout.weights - layout.joints == 32);
        char[] block = alloc::new_array(tmem, char, (sz)layout.total_bytes);
        render::write_geometry_block(block: block, geometry: &wide, layout: &layout, base: (gpu::GpuAddress)0x1000);
        uint* packed = (uint*)&block[layout.joints];
        assert(packed[0] == 1u << 16 && packed[1] == (2u | 3u << 16));
        assert(packed[2] == (300u | 1u << 16) && packed[3] == 65535u << 16);
        assert(((shader::GeometryRoot*)block.ptr).flags == (uint)layout.flags);
    };
}

fn void test_mesh_vertex_variant_follows_geometry_flags() @test {
    render::GeometryFlags skinned = { .skinned = true };
    render::GeometryFlags wide = { .skinned = true, .joints_u16 = true };
    render::GeometryFlags morphs = { .has_morphs = true };
    assert(render::mesh_vertex_variant(skinned, false).flags == shader::SHADER_FLAG_SKINNED);
    assert(render::mesh_vertex_variant(wide, false).flags == shader::SHADER_FLAG_SKINNED_U16);
    assert(render::mesh_vertex_variant(morphs, true).flags == shader::SHADER_FLAG_MORPH);
    assert(render::mesh_vertex_variant(morphs, false).flags == 0);
    shader::ShaderVariant depth = render::mesh_vertex_variant(skinned, true, shader::SHADER_FLAG_DEPTH_ONLY);
    assert(depth.shader == shader::ShaderName.MESH);
    assert(depth.flags == (shader::SHADER_FLAG_DEPTH_ONLY | shader::SHADER_FLAG_SKINNED));
}

fn void test_morph_selection_keeps_largest_eight_by_magnitude() @test {
    float[12] weights = { 0.1f, 0, 0.5f, -0.9f, 0.05f, 0.3f, 0.2f, 0, 0.7f, 0.15f, 0.25f, 0.6f };
    shader::MorphWeightsGpu block = render::select_morph_targets((MorphChannel[]){}, weights[..]);
    assert(block.count == 8);
    float kept_minimum = 1;
    foreach (slot, index : block.indices[:block.count]) {
        assert(block.weights[slot] == weights[index]);
        kept_minimum = math::min(kept_minimum, math::abs(block.weights[slot]));
    }
    assert(block.indices[0] == 3 && block.weights[0] == -0.9f);
    assert(kept_minimum == 0.15f);
    foreach (index, weight : weights) {
        bool kept;
        foreach (kept_index : block.indices[:block.count]) kept |= kept_index == index;
        if (!kept) assert(math::abs(weight) <= kept_minimum);
    }
    float[3] none = { 0, 0, 0 };
    assert(render::select_morph_targets((MorphChannel[]){}, none[..]).count == 0);
}

fn float selected_weight(shader::MorphWeightsGpu block, uint target) @local {
    foreach (slot, index : block.indices[:block.count]) {
        if (index == target) return block.weights[slot];
    }
    return 0;
}

fn void test_morph_selection_maps_channels_to_targets() @test {
    float[1] blink_keys = { 1 };
    float[2] smile_keys = { 0.5f, 1 };
    MorphChannel[2] channels = {
        { .name = "blink", .first_target = 0, .full_weights = blink_keys[..] },
        { .name = "smile", .first_target = 1, .full_weights = smile_keys[..] },
    };
    float[2] weights = { 0.3f, 0.75f };
    shader::MorphWeightsGpu block = render::select_morph_targets(channels[..], weights[..]);
    assert(block.count == 3);
    assert(math::abs(selected_weight(block, 0) - 0.3f) < 0.0005f);
    assert(math::abs(selected_weight(block, 1) - 0.5f) < 0.0005f);
    assert(math::abs(selected_weight(block, 2) - 0.5f) < 0.0005f);

    float[2] at_key = { 0, 0.5f };
    shader::MorphWeightsGpu keyed = render::select_morph_targets(channels[..], at_key[..]);
    assert(keyed.count == 1 && keyed.indices[0] == 1 && math::abs(keyed.weights[0] - 1) < 0.0005f);
}

fn void test_render_preview_request_rejects_oversized_and_out_of_range() @test {
    PreviewParams valid = { .width = 128, .height = 128, .exposure = 1, .range = 1 };

    assert(@ok(render::validate_preview_request(
        source:          { .kind = VIEW_COLOR },
        params:          valid,
        layer_count:     0,
        bloom_levels:    0,
        texture_is_cube: false,
        texture_depth:   0,
    )));

    if (catch excuse = render::validate_preview_request(
        source:          { .kind = VIEW_COLOR },
        params:          { .width = 0, .height = 128 },
        layer_count:     0,
        bloom_levels:    0,
        texture_is_cube: false,
        texture_depth:   0,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "zero extent must fault");
    }

    if (catch excuse = render::validate_preview_request(
        source:          { .kind = VIEW_COLOR },
        params:          { .width = render::PREVIEW_MAX_SIZE + 1, .height = 128 },
        layer_count:     0,
        bloom_levels:    0,
        texture_is_cube: false,
        texture_depth:   0,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "oversized extent must fault");
    }

    if (catch excuse = render::validate_preview_request(
        source:          { .kind = SHADOW_LAYER, .layer = 4 },
        params:          valid,
        layer_count:     4,
        bloom_levels:    0,
        texture_is_cube: false,
        texture_depth:   0,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a layer beyond the atlas must fault");
    }

    if (catch excuse = render::validate_preview_request(
        source:          { .kind = TEXTURE },
        params:          valid,
        layer_count:     0,
        bloom_levels:    0,
        texture_is_cube: true,
        texture_depth:   0,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a cube texture must fault");
    }

    uint[2] slices = { 0, 3 };
    foreach (slice : slices) {
        assert(@ok(render::validate_preview_request(
            source:          { .kind = VIEW_CLUSTERS, .level = slice },
            params:          valid,
            layer_count:     0,
            bloom_levels:    0,
            texture_is_cube: false,
            texture_depth:   0,
            cluster_slices:  4,
        )));
    }
    if (catch excuse = render::validate_preview_request(
        source:          { .kind = VIEW_CLUSTERS, .level = 4 },
        params:          valid,
        layer_count:     0,
        bloom_levels:    0,
        texture_is_cube: false,
        texture_depth:   0,
        cluster_slices:  4,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "A slice beyond the cluster grid must fault");
    }
    if (catch excuse = render::validate_preview_request(
        source:          { .kind = VIEW_CLUSTERS },
        params:          valid,
        layer_count:     0,
        bloom_levels:    0,
        texture_is_cube: false,
        texture_depth:   0,
        cluster_slices:  0,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "An unavailable cluster grid must fault");
    }
}

fn void test_render_preview_cube_face_directions() @test {
    Vec2 center = { 0.5f, 0.5f };
    Vec3[6] axes = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } };
    foreach (index, axis : axes) {
        Vec3 direction = render::preview_face_direction(CubeFace::from_ordinal(index), center);
        assert((direction - axis).length() <= 0.0001f);
    }

    Vec3 corner = render::preview_face_direction(CubeFace.POSITIVE_X, { 0, 0 });
    assert(corner.x == 1 && corner.y == 1 && corner.z == 1, "top-left of +X looks up and toward +Z");
}

fn render::PipelineKey custom_key(uint shader_index, uint revision) @local {
    render::PipelineKey key = gradient_key();
    key.shader = { .index = shader_index, .generation = 1 };
    key.shader_revision = revision;
    key.custom = { .fragment = true };
    return key;
}

fn void test_pipeline_key_hash_and_equality_include_shader() @test {
    render::PipelineKey first = custom_key(3, 1);
    render::PipelineKey same = custom_key(3, 1);
    assert(first.equals(same));
    assert(first.hash() == same.hash());

    render::PipelineKey other_revision = custom_key(3, 2);
    assert(!first.equals(other_revision));
    render::PipelineKey other_shader = custom_key(4, 1);
    assert(!first.equals(other_shader));
    render::PipelineKey other_stages = custom_key(3, 1);
    other_stages.custom = { .vertex = true, .fragment = true };
    assert(!first.equals(other_stages));
    assert(!first.equals(gradient_key()));
}

fn void test_pipeline_cache_keys_of_selects_id_and_revision() @test {
    render::PipelineCache cache = render::create_pipeline_cache(mem, shader::BUILTIN_REGISTRY);
    defer cache.pipelines.free();
    defer cache.rejected.free();
    ShaderId first = { .index = 3, .generation = 1 };
    ShaderId second = { .index = 4, .generation = 1 };
    cache.pipelines.set(custom_key(3, 1), {});
    render::PipelineKey depth_form = custom_key(3, 1);
    depth_form.vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_DEPTH_ONLY };
    cache.pipelines.set(depth_form, {});
    cache.pipelines.set(custom_key(3, 2), {});
    cache.pipelines.set(custom_key(4, 1), {});
    cache.pipelines.set(gradient_key(), {});

    @pool() {
        assert(cache.keys_of(tmem, first, 1).len == 2);
        assert(cache.keys_of(tmem, first, 2).len == 1);
        assert(cache.keys_of(tmem, second, 1).len == 1);
        assert(cache.keys_of(tmem, second, 2).len == 0);
        assert(cache.remove_shader(tmem, first).len == 3);
        assert(cache.keys_of(tmem, first, 1).len == 0);
        assert(cache.keys_of(tmem, second, 1).len == 1);
        assert(cache.pipelines.has_key(gradient_key()));
    };
}

fn void test_compute_pipeline_key_differs_by_id_revision_and_from_graphics() @test {
    ComputeShaderId shader = { .index = 3, .generation = 1 };
    render::PipelineKey first = render::compute_pipeline_key(shader, 1);
    render::PipelineKey same = render::compute_pipeline_key(shader, 1);
    assert(first.equals(same) && first.hash() == same.hash());
    assert(first.custom.compute && !first.custom.vertex && !first.custom.fragment);

    assert(!first.equals(render::compute_pipeline_key(shader, 2)));
    assert(!first.equals(render::compute_pipeline_key({ .index = 4, .generation = 1 }, 1)));
    assert(!first.equals(render::compute_pipeline_key({ .index = 3, .generation = 2 }, 1)));
    assert(!first.equals(custom_key(3, 1)));
}

fn void test_pipeline_cache_separates_compute_and_graphics_keys_of_one_slot() @test {
    render::PipelineCache cache = render::create_pipeline_cache(mem, shader::BUILTIN_REGISTRY);
    defer cache.pipelines.free();
    defer cache.rejected.free();
    ShaderId graphics = { .index = 3, .generation = 1 };
    ComputeShaderId compute = { .index = 3, .generation = 1 };
    cache.pipelines.set(custom_key(3, 1), {});
    cache.pipelines.set(custom_key(3, 2), {});
    cache.pipelines.set(render::compute_pipeline_key(compute, 1), {});
    cache.pipelines.set(render::compute_pipeline_key(compute, 2), {});

    @pool() {
        assert(cache.keys_of(tmem, graphics, 1).len == 1);
        assert(cache.compute_keys_of(tmem, compute, 1).len == 1);
        assert(cache.compute_keys_of(tmem, compute, 3).len == 0);
        assert(cache.remove_compute_shader(tmem, compute).len == 2);
        assert(cache.keys_of(tmem, graphics, 1).len == 1 && cache.keys_of(tmem, graphics, 2).len == 1);
        assert(cache.remove_shader(tmem, graphics).len == 2);
        assert(cache.pipelines.len() == 0);
    };
}

fn void test_dispatch_root_size_rounds_to_stream_alignment() @test {
    assert(render::dispatch_root_size(0) == 0);
    assert(render::dispatch_root_size(1) == render::STREAM_ALIGNMENT);
    assert(render::dispatch_root_size(render::STREAM_ALIGNMENT) == render::STREAM_ALIGNMENT);
    assert(render::dispatch_root_size(render::STREAM_ALIGNMENT + 1) == 2 * render::STREAM_ALIGNMENT);
}

fn void test_dispatch_rejects_more_textures_than_the_binding_block() @test {
    render::Renderer renderer;
    renderer.frame_open = true;
    render::DispatchTexture[render::MAX_DISPATCH_TEXTURES + 1] textures;
    if (catch excuse = renderer.dispatch({ .groups = { 1, 1, 1 }, .textures = textures[..] })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a dispatch with nine textures was accepted");
    }
}

fn void test_dispatch_texture_constructors_set_kind_access_and_ids() @test {
    TextureId texture = { .index = 2, .generation = 1 };
    RenderTargetId target = { .index = 3, .generation = 1 };
    ViewId view = { .index = 4, .generation = 1 };
    SamplerId sampler = { .index = 1, .generation = 1 };

    render::DispatchTexture read = render::read_texture(texture, sampler);
    assert(read.kind == render::DispatchTextureKind.ASSET && read.access == render::DispatchAccess.READ);
    assert(read.texture.index == 2 && read.sampler.index == 1);
    render::DispatchTexture write = render::write_texture(texture, 2, 5);
    assert(write.access == render::DispatchAccess.WRITE && write.mip == 2 && write.layer == 5);
    assert(!write.sampler.generation);
    render::DispatchTexture in_place = render::write_view_color(view, render::DispatchAccess.READ_WRITE);
    assert(in_place.kind == render::DispatchTextureKind.VIEW_COLOR && in_place.view.index == 4);
    assert(in_place.access == render::DispatchAccess.READ_WRITE);
    assert(render::read_target(target).kind == render::DispatchTextureKind.RENDER_TARGET);
    assert(render::write_target(target).access == render::DispatchAccess.WRITE);
    assert(render::read_view_depth(view).kind == render::DispatchTextureKind.VIEW_DEPTH);
    assert(render::read_view_color(view).access == render::DispatchAccess.READ);
}

fn void test_storage_view_slot_orders_layers_then_mips() @test {
    assert(render::storage_view_slot(1, 0, 0) == 0);
    assert(render::storage_view_slot(4, 0, 3) == 3);
    assert(render::storage_view_slot(4, 1, 0) == 4);
    assert(render::storage_view_slot(4, 5, 2) == 22);
}

fn void test_finish_view_requires_a_rendered_view() @test {
    render::Renderer renderer;
    renderer.frame_open = true;
    renderer.has_output = true;
    renderer.views = pool::create_pool{render::ViewRecord, ViewId}(mem, 1);
    defer pool::destroy_pool{render::ViewRecord, ViewId}(&renderer.views);
    ViewId view = renderer.views.add({ .live = true })!!;
    if (catch excuse = renderer.finish_view(view)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "finish_view accepted a view that was not rendered");
    }
}

fn void test_buffer_pool_reuses_a_slot_with_a_new_generation() @test {
    render::BufferPool buffers = pool::create_pool{render::BufferRecord, BufferId}(mem, 2);
    defer pool::destroy_pool{render::BufferRecord, BufferId}(&buffers);
    BufferId first = buffers.add({ .size = 16 })!!;
    buffers.remove(first);
    BufferId second = buffers.add({ .size = 32 })!!;
    assert(second.index == first.index && second.generation != first.generation);
    assert(!buffers.is_live(first) && buffers.get(second).size == 32);
}

fn void test_custom_stage_source_selects_depth_form_for_depth_only_keys() @test {
    char[4] fragment = { 1, 1, 1, 1 };
    char[4] shaded = { 2, 2, 2, 2 };
    char[4] depth = { 3, 3, 3, 3 };
    asset::ShaderDesc stages = { .fragment = fragment[..], .vertex = { .shaded = shaded[..], .depth = depth[..] } };
    render::PipelineKey key = custom_key(3, 1);
    key.custom = { .vertex = true, .fragment = true };
    key.vertex = { .shader = MESH };
    render::CustomStageSource shaded_source = render::custom_stage_source(&stages, key);
    assert(shaded_source.vertex.ptr == &shaded[0] && shaded_source.fragment.ptr == &fragment[0]);

    key.vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_DEPTH_ONLY };
    render::CustomStageSource depth_source = render::custom_stage_source(&stages, key);
    assert(depth_source.vertex.ptr == &depth[0]);
}

fn void test_custom_material_block_packs_slots_and_payload_address() @test {
    char[] block = mem::new_array(char, render::MATERIAL_STRIDE);
    defer free(block.ptr);
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
    slots[3].uv_set = 1;
    slots[3].transform.offset = { 0.25f, 0.5f };
    Material custom = material::custom({ .index = 1, .generation = 1 }, {}, slots);
    render::MaterialBindings bindings;
    bindings.custom[0] = { .present = true, .texture_index = (gpu::TextureIndex)5, .sampler_index = (gpu::SamplerIndex)2 };
    bindings.custom[3] = { .present = true, .texture_index = (gpu::TextureIndex)7, .sampler_index = (gpu::SamplerIndex)1 };
    render::write_material_block(
        block:      block,
        material:   &custom,
        bindings:   bindings,
        parameters: (gpu::GpuAddress)0x1000,
    );

    shader::CustomMaterialGpu* packed = (shader::CustomMaterialGpu*)block.ptr;
    assert(packed.kind == (uint)MaterialKind.CUSTOM.ordinal);
    assert(packed.map_flags == (1 | 8 | 8 << shader::CUSTOM_MAP_UV1_SHIFT));
    assert((uint)packed.slots[0].texture_index == 5 && (uint)packed.slots[0].sampler_index == 2);
    assert((uint)packed.slots[3].texture_index == 7);
    assert(packed.slots[3].uv_offset == (Vec2f){ 0.25f, 0.5f });
    assert(packed.slots[1].uv_linear == (Vec4f){ 1, 0, 0, 1 });
    assert((ulong)packed.parameters == 0x1000);
}

fn ulong custom_key_of(ShaderId shader, uint slot, float depth) @local {
    return render::draw_sort_key(
        vertex:    { .shader = MESH },
        fragment:  {},
        material:  { .index = slot, .generation = 1 },
        geometry:  { .index = slot, .generation = 1 },
        ndc_depth: depth,
        custom:    shader,
    );
}

fn void test_draw_sort_key_groups_custom_by_shader() @test {
    ShaderId shader_a = { .index = 5, .generation = 1 };
    ShaderId shader_b = { .index = 6, .generation = 1 };
    ulong a_first = custom_key_of(shader_a, 9, 0);
    ulong a_second = custom_key_of(shader_a, 1, 1);
    ulong b = custom_key_of(shader_b, 0, 1);
    assert(a_first >> 48 == a_second >> 48);
    assert(b > a_first);
    assert(key_of(5, 9, 9, 0) == a_first);
}
