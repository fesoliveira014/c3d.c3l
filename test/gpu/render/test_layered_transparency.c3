module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import c3d::test::transparency_fixtures;
import gpu;
import std::math;

const uint LAYERED_IMAGE_SIZE @private = transparency_fixtures::PLANAR_EXTENT;
const uint LAYERED_INTERIOR_BEGIN @private = 18;
const uint LAYERED_INTERIOR_END @private = LAYERED_IMAGE_SIZE - LAYERED_INTERIOR_BEGIN;
const double LAYERED_COLOR_ABSOLUTE_TOLERANCE @private = 0.003;
const double LAYERED_COLOR_RELATIVE_TOLERANCE @private = 0.005;
const uint LAYERED_SAMPLE_ROW @private = 47;
const uint LAYERED_SAMPLE_COLUMN @private = 69;
const char[*] LAYERED_READER_SOURCE @private = $embed("material_blend.frag.glsl");
const char[*] LAYERED_OPAQUE_READER_SOURCE @private = $embed("fog_reader.frag.glsl");

struct LayeredScene @private {
    Scene scene;
    Node* camera;
}

struct LayeredView @private {
    ViewId view;
    RenderTargetId target;
}

struct LayeredReaderParams @private {
    Vec4 color;
}
$assert LayeredReaderParams::size == 16;

fn GeometryId? add_layered_sheet_geometry(Fixture* fixture, float depth, float slope = 0) @private {
    @pool() {
        Vec3[4] positions = {
            { -0.75f, -0.75f, 8 * depth - 9 - 0.75f * slope },
            { 0.75f, -0.75f, 8 * depth - 9 + 0.75f * slope },
            { 0.75f, 0.75f, 8 * depth - 9 + 0.75f * slope },
            { -0.75f, 0.75f, 8 * depth - 9 - 0.75f * slope },
        };
        Geometry geometry = {
            .positions = positions[..],
            .indices = transparency_fixtures::QUAD_INDICES[..],
        };
        geometry.finalize();
        return fixture.assets.add_geometry(&geometry);
    };
}

fn MaterialId? add_layered_basic(Fixture* fixture, Vec4 color, bool blended = true) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = blended ? AlphaMode.BLEND : AlphaMode.OPAQUE;
    common.double_sided = true;
    return fixture.assets.add_material(material::basic({ .color = color }, common));
}

fn LayeredScene? create_layered_scene(Fixture* fixture) @private {
    LayeredScene target = { .scene = scene::create_scene(fixture.allocator, scene::default_scene_desc()) };
    defer catch scene::destroy_scene(&target.scene);
    target.camera = target.scene.add_camera(camera::orthographic(
        height: 2,
        near: transparency_fixtures::PLANAR_NEAR,
        far: transparency_fixtures::PLANAR_FAR,
    ))!;
    GeometryId geometry = add_layered_sheet_geometry(fixture, 0.0625f)!;
    MaterialId material = add_layered_basic(fixture, { 0.125f, 0.25f, 0.5f, 1 }, false)!;
    target.scene.add_mesh(geometry, material)!;
    target.scene.update_world();
    return target;
}

fn LayeredView? create_layered_view(
    Fixture* fixture,
    uint capacity = 4,
    ShadingPath shading = ShadingPath.FORWARD,
) @private {
    LayeredView view;
    view.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(LAYERED_IMAGE_SIZE, LAYERED_IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    defer catch render::destroy_render_target(&fixture.renderer, view.target)!!;
    ViewDesc desc = render::texture_view_desc(view.target);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    desc.depth_prepass = false;
    desc.shading = shading;
    desc.transparency = render::TRANSPARENCY_LAYERED_DEFAULT;
    desc.transparency.layer_capacity = capacity;
    view.view = render::create_view(&fixture.renderer, desc)!;
    return view;
}

fn void destroy_layered_view(Fixture* fixture, LayeredView* view) @private {
    render::destroy_view(&fixture.renderer, view.view)!!;
    render::destroy_render_target(&fixture.renderer, view.target)!!;
}

fn Vec4[]? render_layered_pixels(Fixture* fixture, LayeredScene* target, LayeredView* view) @private {
    target.scene.update_world();
    fixture.renderer.begin_frame()!;
    defer catch render::abort_frame(&fixture.renderer);
    fixture.renderer.render_view(&target.scene, target.camera, view.view)!;
    fixture.renderer.finish_view(view.view)!;
    fixture.renderer.end_frame()!;
    Target* output = &fixture.renderer.targets.get(view.target).target;
    Vec4[] pixels = mem::new_array(Vec4, (usz)output.width * output.height);
    defer catch free(pixels);
    fixture.renderer.read_render_target(view.target, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
    return pixels;
}

fn uint[]? read_layered_depth(Fixture* fixture, LayeredView* view, uint group) @private {
    Renderer* renderer = &fixture.renderer;
    Target* depth = &renderer.views.get(view.view).transparency.depths[group];
    render::wait_frames(renderer)!;
    render::open_closed_frame_slot(renderer)!;
    gpu::AllocationDesc desc = {
        .size = (usz)depth.width * depth.height * uint::size,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "layered_depth_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    defer {
        gpu::GpuAllocation allocation = readback.span.allocation();
        (void)gpu::free_allocation(&renderer.device, &allocation);
    }
    TextureReadback copy = { .target = depth, .destination = readback.span };
    render::submit_pending(renderer, &copy)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    uint[] bits = mem::new_array(uint, (usz)depth.width * depth.height);
    bits[..] = ((uint*)readback.bytes.ptr)[:bits.len];
    return bits;
}

fn void check_layered_color(Vec4 actual, transparency_fixtures::Color expected) @private {
    for (uint channel = 0; channel < 3; channel++) {
        double error = math::abs((double)actual[channel] - expected[channel]);
        double bound = LAYERED_COLOR_ABSOLUTE_TOLERANCE
          + LAYERED_COLOR_RELATIVE_TOLERANCE * math::abs(expected[channel]);
        assert(math::is_finite(actual[channel]) && error <= bound,
          "channel %s: actual=%s expected=%s", channel, actual[channel], expected[channel]);
    }
    assert(math::abs(actual.w - 1) <= LAYERED_COLOR_ABSOLUTE_TOLERANCE);
}

fn void check_layered_interior(Vec4[] pixels, transparency_fixtures::Color expected) @private {
    for (uint row = LAYERED_INTERIOR_BEGIN; row < LAYERED_INTERIOR_END; row++) {
        for (uint column = LAYERED_INTERIOR_BEGIN; column < LAYERED_INTERIOR_END; column++) {
            check_layered_color(pixels[row * LAYERED_IMAGE_SIZE + column], expected);
        }
    }
}

fn void test_layered_crossing_sheets_follow_per_pixel_order_in_both_shading_paths() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (shading : (ShadingPath[2]){ FORWARD, DEFERRED }) {
        foreach (reversed : (bool[2]){ false, true }) {
            LayeredScene target = create_layered_scene(&fixture)!!;
            defer scene::destroy_scene(&target.scene);
            LayeredView view = create_layered_view(&fixture, 4, shading)!!;
            defer destroy_layered_view(&fixture, &view);
            MaterialId red = add_layered_basic(&fixture, { 1, 0, 0, 0.25f })!!;
            MaterialId green = add_layered_basic(&fixture, { 0, 1, 0, 0.5f })!!;
            GeometryId rising = add_layered_sheet_geometry(&fixture, 0.5f, 0.5f)!!;
            GeometryId falling = add_layered_sheet_geometry(&fixture, 0.5f, -0.5f)!!;
            if (reversed) {
                target.scene.add_mesh(falling, green)!!;
                target.scene.add_mesh(rising, red)!!;
            } else {
                target.scene.add_mesh(rising, red)!!;
                target.scene.add_mesh(falling, green)!!;
            }
            Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
            defer free(pixels);
            for (uint row = LAYERED_INTERIOR_BEGIN; row < LAYERED_INTERIOR_END; row++) {
                for (uint column = LAYERED_INTERIOR_BEGIN; column < LAYERED_INTERIOR_END; column++) {
                    double world_x = -1 + 2 * ((double)column + 0.5) / LAYERED_IMAGE_SIZE;
                    double rising_depth = 0.5 + world_x / 16;
                    double falling_depth = 0.5 - world_x / 16;
                    transparency_fixtures::Color expected = transparency_fixtures::PLANAR_BACKGROUND;
                    if (rising_depth < falling_depth) {
                        expected = transparency_fixtures::compose_over(expected, { 1, 0, 0 }, 0.25);
                        expected = transparency_fixtures::compose_over(expected, { 0, 1, 0 }, 0.5);
                    } else {
                        expected = transparency_fixtures::compose_over(expected, { 0, 1, 0 }, 0.5);
                        expected = transparency_fixtures::compose_over(expected, { 1, 0, 0 }, 0.25);
                    }
                    check_layered_color(pixels[row * LAYERED_IMAGE_SIZE + column], expected);
                }
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_layered_exact_ties_share_one_group_and_adjacent_depth_bits_use_two() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView view = create_layered_view(&fixture, 2)!!;
    defer destroy_layered_view(&fixture, &view);
    MaterialId green = add_layered_basic(&fixture, { 0, 1, 0, 0.5f })!!;
    MaterialId red = add_layered_basic(&fixture, { 1, 0, 0, 0.5f })!!;
    GeometryId first = add_layered_sheet_geometry(&fixture, 0.5f)!!;
    GeometryId second = add_layered_sheet_geometry(&fixture, 0.5f)!!;
    Node* green_node = target.scene.add_mesh(first, green)!!;
    Node* red_node = target.scene.add_mesh(second, red)!!;
    assert(green_node.id.index < red_node.id.index);
    transparency_fixtures::Color tied_background = transparency_fixtures::compose_over(
        behind: transparency_fixtures::PLANAR_BACKGROUND,
        radiance: { 0, 1, 0 },
        coverage: 0.5,
    );
    transparency_fixtures::Color tied = transparency_fixtures::compose_over(tied_background, { 1, 0, 0 }, 0.5);
    Vec4[] tied_pixels = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(tied_pixels);
    check_layered_interior(tied_pixels, tied);
    uint[] tied_first = read_layered_depth(&fixture, &view, 0)!!;
    defer free(tied_first);
    uint[] tied_second = read_layered_depth(&fixture, &view, 1)!!;
    defer free(tied_second);
    uint sample = LAYERED_SAMPLE_ROW * LAYERED_IMAGE_SIZE + LAYERED_SAMPLE_COLUMN;
    assert(tied_first[sample] == bitcast(0.5f, uint));
    assert(tied_second[sample] == 0);

    float adjacent = bitcast(bitcast(0.5f, uint) + 1, float);
    Geometry* moved = &fixture.assets.geometry(first).data;
    foreach (&position : moved.positions) position.z = 8 * adjacent - 9;
    moved.finalize();
    fixture.assets.mark_geometry_dirty(first);
    transparency_fixtures::Color separated_background = transparency_fixtures::compose_over(
        behind: transparency_fixtures::PLANAR_BACKGROUND,
        radiance: { 1, 0, 0 },
        coverage: 0.5,
    );
    transparency_fixtures::Color separated = transparency_fixtures::compose_over(
        behind: separated_background,
        radiance: { 0, 1, 0 },
        coverage: 0.5,
    );
    Vec4[] adjacent_pixels = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(adjacent_pixels);
    check_layered_interior(adjacent_pixels, separated);
    uint[] adjacent_first = read_layered_depth(&fixture, &view, 0)!!;
    defer free(adjacent_first);
    uint[] adjacent_second = read_layered_depth(&fixture, &view, 1)!!;
    defer free(adjacent_second);
    assert(adjacent_first[sample] == bitcast(adjacent, uint));
    assert(adjacent_second[sample] == bitcast(0.5f, uint));
    assert(math::abs(tied.x - separated.x) > 0.1);
    check_validation(&fixture.renderer);
}

fn void test_layered_mirrored_instances_keep_logical_tie_order_with_culling_and_fallback() @test {
    foreach (arena_bytes : (usz[2]){ 0, render::CULL_COUNTER_BYTES }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        Fixture fixture;
        create_fixture(
            allocator: &tracker,
            fixture: &fixture,
            instance_cull_bytes: arena_bytes,
        )!!;
        defer destroy_fixture(&fixture);
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        LayeredView view = create_layered_view(&fixture, 2)!!;
        defer destroy_layered_view(&fixture, &view);
        GeometryId geometry = add_layered_sheet_geometry(&fixture, 0.5f)!!;
        MaterialId blue = add_layered_basic(&fixture, { 0, 0, 1, 0.25f })!!;
        Node* ordinary = target.scene.add_mesh(geometry, blue)!!;
        MaterialId white = add_layered_basic(&fixture, { 1, 1, 1, 0.5f })!!;
        Node* node = target.scene.add_instanced_mesh(geometry, white, 4)!!;
        assert(ordinary.id.index < node.id.index);
        target.scene.resize_instances(node, 4)!!;
        InstancedMesh* batch = target.scene.get(node, InstancedMesh);
        Vec4[4] colors = { { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 }, { 1, 1, 0, 1 } };
        foreach (uint logical, &transform : batch.transforms[:4]) {
            *transform = maths::TRANSFORM_IDENTITY;
            transform.scale.x = logical % 2 == 0 ? -1 : 1;
            batch.colors[logical] = colors[logical];
        }
        target.scene.mark_instances_dirty(node);
        transparency_fixtures::Color expected = transparency_fixtures::compose_over(
            behind: transparency_fixtures::PLANAR_BACKGROUND,
            radiance: { 0, 0, 1 },
            coverage: 0.25,
        );
        foreach (color : colors) {
            expected = transparency_fixtures::compose_over(expected, { color.x, color.y, color.z }, 0.5);
        }
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        check_layered_interior(pixels, expected);
        uint[] first = read_layered_depth(&fixture, &view, 0)!!;
        defer free(first);
        uint[] second = read_layered_depth(&fixture, &view, 1)!!;
        defer free(second);
        uint sample = LAYERED_SAMPLE_ROW * LAYERED_IMAGE_SIZE + LAYERED_SAMPLE_COLUMN;
        assert(first[sample] == bitcast(0.5f, uint) && second[sample] == 0);
        if (arena_bytes) assert(fixture.renderer.stats.sort_overflows > 0);
        check_validation(&fixture.renderer);
    }
}

fn void test_layered_neutral_opaque_and_blended_physical_glass_keeps_homogeneous_fog_once() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView view = create_layered_view(&fixture)!!;
    defer destroy_layered_view(&fixture, &view);
    target.scene.ambient_color = { 1, 1, 1 };
    target.scene.ambient_intensity = 1;
    Node* fog = target.scene.add_node()!!;
    target.scene.add(fog, (HeightFog){
        .density = (float)transparency_fixtures::FOG_EXTINCTION,
        .falloff = 0,
        .albedo = { 0.1f, 0.2f, 0.4f },
        .max_distance = 9,
    });
    double attenuation = math::exp(-transparency_fixtures::FOG_EXTINCTION * 8.5);
    transparency_fixtures::Color expected = attenuation * transparency_fixtures::PLANAR_BACKGROUND
      + (1 - attenuation) * transparency_fixtures::FOG_COLOR;
    Vec4[] baseline = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(baseline);
    check_layered_interior(baseline, expected);
    GeometryId geometry = add_layered_sheet_geometry(&fixture, 0.75f)!!;
    Node* glass;
    foreach (alpha_mode : (AlphaMode[2]){ OPAQUE, BLEND }) {
        PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
        params.standard.base_color = { 1, 1, 1, 0.25f };
        params.standard.metallic = 0;
        params.standard.roughness = 0;
        params.ior = 1;
        params.specular = 0;
        params.transmission = 1;
        params.thickness = 0;
        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
        common.alpha_mode = alpha_mode;
        common.double_sided = true;
        common.depth_write = false;
        MaterialId material = fixture.assets.add_material(material::physical(params, common))!!;
        if (glass) {
            target.scene.get(glass, Mesh).material = material;
        } else {
            glass = target.scene.add_mesh(geometry, material)!!;
        }
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        check_layered_interior(pixels, expected);
        uint[] depth = read_layered_depth(&fixture, &view, 0)!!;
        defer free(depth);
        uint sample = LAYERED_SAMPLE_ROW * LAYERED_IMAGE_SIZE + LAYERED_SAMPLE_COLUMN;
        assert(depth[sample] == bitcast(0.75f, uint));
    }
    check_validation(&fixture.renderer);
}

fn Vec4 layered_center(Vec4[] pixels, uint width, uint height) @private {
    return pixels[(height / 2) * width + width / 2];
}

fn void test_layered_view_resize_toggle_and_aborted_retry_preserve_independent_resources() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView first = create_layered_view(&fixture, 2)!!;
    defer destroy_layered_view(&fixture, &first);
    LayeredView second = create_layered_view(&fixture, 1)!!;
    defer destroy_layered_view(&fixture, &second);
    GeometryId near_geometry = add_layered_sheet_geometry(&fixture, 0.75f)!!;
    GeometryId far_geometry = add_layered_sheet_geometry(&fixture, 0.5f)!!;
    MaterialId red = add_layered_basic(&fixture, { 1, 0, 0, 0.5f })!!;
    MaterialId green = add_layered_basic(&fixture, { 0, 1, 0, 0.5f })!!;
    Node* near = target.scene.add_mesh(near_geometry, red)!!;
    target.scene.add_mesh(far_geometry, green)!!;
    transparency_fixtures::Color rear = transparency_fixtures::compose_over(
        behind: transparency_fixtures::PLANAR_BACKGROUND,
        radiance: { 0, 1, 0 },
        coverage: 0.5,
    );
    transparency_fixtures::Color expected = transparency_fixtures::compose_over(rear, { 1, 0, 0 }, 0.5);
    Vec4[] initial = render_layered_pixels(&fixture, &target, &first)!!;
    defer free(initial);
    check_layered_interior(initial, expected);
    ViewRecord* first_record = fixture.renderer.views.get(first.view);
    gpu::TextureHandle first_depth = first_record.transparency.depths[0].texture;
    render::resize_render_target(
        renderer: &fixture.renderer,
        target: second.target,
        width: 257,
        height: 129,
    )!!;
    assert(first_record.transparency.depths[0].texture == first_depth);
    foreach (mode : (TransparencyMode[3]){ SORTED, LAYERED, SORTED }) {
        ViewDesc desc = fixture.renderer.views.get(second.view).desc;
        desc.transparency = mode == LAYERED ? render::TRANSPARENCY_LAYERED_DEFAULT : (TransparencyDesc){};
        render::configure_view(&fixture.renderer, second.view, desc)!!;
        Vec4[] other = render_layered_pixels(&fixture, &target, &second)!!;
        defer free(other);
        check_layered_color(layered_center(other, 257, 129), expected);
        assert(first_record.transparency.depths[0].texture == first_depth);
        assert(fixture.renderer.views.get(second.view).transparency.layer_capacity == (mode == LAYERED ? 4 : 0));
    }

    gpu::TextureState[render::TRANSPARENCY_TARGET_COUNT] states;
    foreach (index, image : render::transparency_targets(&first_record.transparency)) states[index] = image.state;
    near.local.position.z = -3;
    target.scene.update_world();
    fixture.renderer.begin_frame()!!;
    fixture.renderer.render_view(&target.scene, target.camera, first.view)!!;
    render::abort_frame(&fixture.renderer);
    foreach (index, image : render::transparency_targets(&first_record.transparency)) {
        assert(render::same_texture_state(image.state, states[index]));
    }
    Vec4[] untouched = mem::new_array(Vec4, 257 * 129);
    defer free(untouched);
    fixture.renderer.read_render_target(second.target, ((char*)untouched.ptr)[:untouched.len * Vec4::size])!!;
    check_layered_color(layered_center(untouched, 257, 129), expected);
    transparency_fixtures::Color retry_rear = transparency_fixtures::compose_over(
        behind: transparency_fixtures::PLANAR_BACKGROUND,
        radiance: { 1, 0, 0 },
        coverage: 0.5,
    );
    transparency_fixtures::Color retry_expected = transparency_fixtures::compose_over(retry_rear, { 0, 1, 0 }, 0.5);
    Vec4[] retry = render_layered_pixels(&fixture, &target, &first)!!;
    defer free(retry);
    check_layered_interior(retry, retry_expected);
    assert(first_record.transparency.depths[0].texture == first_depth);
    check_validation(&fixture.renderer);
}

fn void test_layered_capacity_one_keeps_the_complete_sorted_remainder() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView view = create_layered_view(&fixture, 1)!!;
    defer destroy_layered_view(&fixture, &view);
    transparency_fixtures::Color expected = transparency_fixtures::PLANAR_BACKGROUND;
    for (uint index = 0; index < transparency_fixtures::PLANAR_DEPTHS.len; index++) {
        transparency_fixtures::Color color = transparency_fixtures::PLANAR_COLORS[index];
        float coverage = (float)transparency_fixtures::PLANAR_COVERAGES[index];
        MaterialId material = add_layered_basic(&fixture, {
            (float)color.x, (float)color.y, (float)color.z, coverage,
        })!!;
        GeometryId geometry = add_layered_sheet_geometry(&fixture, transparency_fixtures::PLANAR_DEPTHS[index])!!;
        target.scene.add_mesh(geometry, material)!!;
    }
    for (usz index = transparency_fixtures::PLANAR_COLORS.len; index > 0; index--) {
        expected = transparency_fixtures::compose_over(
            behind: expected,
            radiance: transparency_fixtures::PLANAR_COLORS[index - 1],
            coverage: transparency_fixtures::PLANAR_COVERAGES[index - 1],
        );
    }
    Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(pixels);
    check_layered_interior(pixels, expected);
    uint[] retained = read_layered_depth(&fixture, &view, 0)!!;
    defer free(retained);
    uint[] overflow = read_layered_depth(&fixture, &view, 1)!!;
    defer free(overflow);
    uint sample = LAYERED_SAMPLE_ROW * LAYERED_IMAGE_SIZE + LAYERED_SAMPLE_COLUMN;
    assert(retained[sample] == bitcast(0.75f, uint));
    assert(overflow[sample] == bitcast(0.625f, uint));
    transparency_fixtures::Color dropped = transparency_fixtures::compose_over(
        behind: transparency_fixtures::PLANAR_BACKGROUND,
        radiance: transparency_fixtures::PLANAR_COLORS[0],
        coverage: transparency_fixtures::PLANAR_COVERAGES[0],
    );
    assert(math::abs(expected.y - dropped.y) > 0.05);
    check_validation(&fixture.renderer);
}

fn MaterialId? add_layered_reader(Fixture* fixture, bool declared) @private {
    @pool() {
        String source = (String)LAYERED_READER_SOURCE[..];
        source = source.treplace(
            needle: "#include \"fog.glsl\"",
            new_str: "#include \"fog.glsl\"\n#include \"scene_snapshot.glsl\"",
        );
        source = source.treplace(
            needle: "out_color = material_output(",
            new_str: "color.rgb = 0.5 * color.rgb + 0.5 * scene_color_at(frame, scene_uv(frame, gl_FragCoord.xy));\n",
        );
        source = source.treplace(
            needle: "        apply_material_fog(frame, v_world_pos, color.rgb, material.flags),",
            new_str: "    out_color = material_output(\n        color.rgb,",
        );
        String[1] defines = { "LAYERED" };
        if (declared) {
            source = source.treplace(
                needle: "#include \"fog.glsl\"\n#include \"scene_snapshot.glsl\"",
                new_str: "#include \"transparency.glsl\"",
            );
            source = source.treplace(
                needle: "CustomMaterialGpu material =",
                new_str: "if (!layered_transparency_accept(frame, gl_FragCoord.z)) discard;\nCustomMaterialGpu material =",
            );
            source = source.treplace(
                needle: "    vec4 color =",
                new_str: "    out_color = vec4(gl_FragCoord.z, 0.0, 0.0, 1.0);\n    vec4 color =",
            );
            source = source.treplace(
                needle: "    color.rgb =",
                new_str: "    if (layered_transparency_capture(frame)) return;\n    color.rgb =",
            );
        }
        asset::ShaderDesc desc = {
            .fragment = compile::compile_glsl(
                allocator: tmem,
                source: source,
                stage: ShaderStage.FRAGMENT,
                defines: declared ? defines[..] : (String[]){},
            )!,
            .param_block_size = LayeredReaderParams::size,
            .scene_reads = { .color = true },
            .layered_transparency = declared,
        };
        ShaderId shader = fixture.assets.add_shader(&desc)!;
        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
        common.alpha_mode = AlphaMode.BLEND;
        common.double_sided = true;
        LayeredReaderParams params = { .color = { 0, 1, 0, 0.5f } };
        return fixture.assets.add_material(material::custom(
            shader: shader,
            param_block: material::@as_bytes(params),
            common: common,
        ));
    };
}

fn void test_layered_declared_custom_reader_reads_behind_its_group_and_undeclared_reads_opaque() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (declared : (bool[2]){ true, false }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        LayeredView view = create_layered_view(&fixture, 4)!!;
        defer destroy_layered_view(&fixture, &view);
        MaterialId red = add_layered_basic(&fixture, { 1, 0, 0, 0.5f })!!;
        MaterialId blue = add_layered_basic(&fixture, { 0, 0, 1, 0.5f })!!;
        GeometryId front = add_layered_sheet_geometry(&fixture, 0.75f)!!;
        GeometryId back = add_layered_sheet_geometry(&fixture, 0.5f)!!;
        GeometryId rear_geometry = add_layered_sheet_geometry(&fixture, 0.25f)!!;
        target.scene.add_mesh(front, red)!!;
        target.scene.add_mesh(back, add_layered_reader(&fixture, declared)!!)!!;
        target.scene.add_mesh(rear_geometry, blue)!!;
        transparency_fixtures::Color rear = transparency_fixtures::compose_over(
            behind: transparency_fixtures::PLANAR_BACKGROUND,
            radiance: { 0, 0, 1 },
            coverage: 0.5,
        );
        transparency_fixtures::Color reader_snapshot = declared ? rear : transparency_fixtures::PLANAR_BACKGROUND;
        transparency_fixtures::Color reader_color = 0.5 * (transparency_fixtures::Color){ 0, 1, 0 }
          + 0.5 * reader_snapshot;
        transparency_fixtures::Color expected = rear;
        if (declared) {
            expected = transparency_fixtures::compose_over(expected, reader_color, 0.5);
            expected = transparency_fixtures::compose_over(expected, { 1, 0, 0 }, 0.5);
        } else {
            expected = transparency_fixtures::compose_over(expected, { 1, 0, 0 }, 0.5);
            expected = transparency_fixtures::compose_over(expected, reader_color, 0.5);
        }
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        check_layered_interior(pixels, expected);
        uint[] first = read_layered_depth(&fixture, &view, 0)!!;
        defer free(first);
        uint[] second = read_layered_depth(&fixture, &view, 1)!!;
        defer free(second);
        uint[] third = read_layered_depth(&fixture, &view, 2)!!;
        defer free(third);
        uint sample = LAYERED_SAMPLE_ROW * LAYERED_IMAGE_SIZE + LAYERED_SAMPLE_COLUMN;
        assert(first[sample] == bitcast(0.75f, uint));
        assert(second[sample] == bitcast(declared ? 0.5f : 0.25f, uint));
        assert(third[sample] == (declared ? bitcast(0.25f, uint) : 0));
    }
    check_validation(&fixture.renderer);
}

fn void test_layered_opaque_custom_scene_reader_applies_fog_before_transparent_fallback() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredScene target = create_layered_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LayeredView view = create_layered_view(&fixture, 2)!!;
    defer destroy_layered_view(&fixture, &view);
    target.scene.ambient_color = { 1, 1, 1 };
    target.scene.ambient_intensity = 1;
    Node* fog = target.scene.add_node()!!;
    target.scene.add(fog, (HeightFog){
        .density = (float)transparency_fixtures::FOG_EXTINCTION,
        .falloff = 0,
        .albedo = { 0.1f, 0.2f, 0.4f },
        .max_distance = 9,
    });
    MaterialId red = add_layered_basic(&fixture, { 1, 0, 0, 0.5f })!!;
    target.scene.add_mesh(add_layered_sheet_geometry(&fixture, 0.75f)!!, red)!!;
    MaterialId reader;
    @pool() {
        asset::ShaderDesc desc = {
            .fragment = compile::compile_glsl(
                allocator: tmem,
                source: (String)LAYERED_OPAQUE_READER_SOURCE[..],
                stage: ShaderStage.FRAGMENT,
            )!!,
            .scene_reads = { .color = true, .depth = true },
        };
        ShaderId shader = fixture.assets.add_shader(&desc)!!;
        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
        common.double_sided = true;
        reader = fixture.assets.add_material(material::custom(shader: shader, common: common))!!;
    };
    target.scene.add_mesh(add_layered_sheet_geometry(&fixture, 0.5f)!!, reader)!!;
    MaterialCommon overlay_common = material::MATERIAL_COMMON_DEFAULT;
    overlay_common.alpha_mode = AlphaMode.BLEND;
    overlay_common.double_sided = true;
    overlay_common.depth_test = false;
    Material overlay_material = material::basic({ .color = { 0, 0, 1, 0.25f } }, overlay_common);
    MaterialId overlay = fixture.assets.add_material(overlay_material)!!;
    target.scene.add_mesh(add_layered_sheet_geometry(&fixture, 0.875f)!!, overlay)!!;
    double reader_transmission = math::exp(-transparency_fixtures::FOG_EXTINCTION * 5);
    double overlay_transmission = math::exp(-transparency_fixtures::FOG_EXTINCTION * 2);
    transparency_fixtures::Color reader_observed = reader_transmission * (transparency_fixtures::Color){ 0.9, 0.3, 0.1 }
      + (1 - reader_transmission) * transparency_fixtures::FOG_COLOR;
    transparency_fixtures::Color overlay_observed = overlay_transmission * (transparency_fixtures::Color){ 0, 0, 1 }
      + (1 - overlay_transmission) * transparency_fixtures::FOG_COLOR;
    transparency_fixtures::Color expected = transparency_fixtures::compose_over(
        reader_observed,
        overlay_observed,
        0.25,
    );
    Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
    defer free(pixels);
    check_layered_interior(pixels, expected);
    uint[] retained = read_layered_depth(&fixture, &view, 0)!!;
    defer free(retained);
    uint[] second = read_layered_depth(&fixture, &view, 1)!!;
    defer free(second);
    uint sample = LAYERED_SAMPLE_ROW * LAYERED_IMAGE_SIZE + LAYERED_SAMPLE_COLUMN;
    assert(retained[sample] == bitcast(0.75f, uint) && second[sample] == 0);
    check_validation(&fixture.renderer);
}
