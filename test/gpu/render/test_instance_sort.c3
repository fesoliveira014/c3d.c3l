module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader;

const uint SORTED_COUNT @private = 5000;
const uint SORTED_STRIDE @private = 7919; // prime, so storage order is a scrambled permutation of depth order
const float SORTED_SPACING @private = 0.001f; // the farthest box, 8 units out, still covers the sampled pixels
const uint SORTED_STEPS @private = 10; // capacity 8192: one block step, then stages of 2, 3 and 4 steps
const uint LINE_SORT_STEPS @private = 2; // two parity ranges of one step each
const usz SORT_OVERFLOW_ARENA_BYTES @private = render::CULL_COUNTER_BYTES + 112; // two commands and the mirrored list and keys; the unmirrored range's 176 bytes do not fit
const String SORT_ORDER_VERTEX @private = "sort_order.vert.glsl";
const String SORT_ORDER_FRAGMENT @private = "sort_order.frag.glsl";

struct SortOrderParams @private {
    uint count;
    uint stride;
}

fn char[]? compile_sort_order_vertex(Fixture* fixture, String[] defines = {}) @private {
    return compile_pulse_stage(
        fixture:  fixture,
        relative: SORT_ORDER_VERTEX,
        stage:    ShaderStage.VERTEX,
        defines:  defines,
    );
}

fn MaterialId? add_sort_order_material(Fixture* fixture) @private {
    String[1] depth_only = { "DEPTH_ONLY" };
    String[1] instanced = { "INSTANCED" };
    String[2] instanced_depth = { "DEPTH_ONLY", "INSTANCED" };
    ShaderDesc desc = {
        .fragment = compile_pulse_stage(fixture, SORT_ORDER_FRAGMENT, ShaderStage.FRAGMENT)!,
        .vertex   = {
            .shaded           = compile_sort_order_vertex(fixture)!,
            .depth            = compile_sort_order_vertex(fixture, depth_only[..])!,
            .instanced_shaded = compile_sort_order_vertex(fixture, instanced[..])!,
            .instanced_depth  = compile_sort_order_vertex(fixture, instanced_depth[..])!,
        },
        .param_block_size = SortOrderParams::size,
    };
    defer {
        alloc::free(fixture.allocator, desc.fragment.ptr);
        alloc::free(fixture.allocator, desc.vertex.shaded.ptr);
        alloc::free(fixture.allocator, desc.vertex.depth.ptr);
        alloc::free(fixture.allocator, desc.vertex.instanced_shaded.ptr);
        alloc::free(fixture.allocator, desc.vertex.instanced_depth.ptr);
    }
    ShaderId shader = fixture.assets.add_shader(&desc, "sort_order")!;
    MaterialCommon blended = material::MATERIAL_COMMON_DEFAULT;
    blended.alpha_mode = AlphaMode.BLEND;
    SortOrderParams params = { .count = SORTED_COUNT, .stride = SORTED_STRIDE };
    return fixture.assets.add_material(material::custom(
        shader:      shader,
        param_block: material::@as_bytes(params),
        common:      blended,
    ));
}

fn DeformedScene? create_depth_line_scene(Fixture* fixture, MaterialId material) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.mesh = result.scene.add_instanced_mesh(fixture.box, material, SORTED_COUNT)!;
    result.scene.resize_instances(result.mesh, SORTED_COUNT)!;
    InstancedMesh* batch = result.scene.get(result.mesh, InstancedMesh);
    foreach (uint source, &transform : batch.transforms[:SORTED_COUNT]) {
        transform.position = { 0, 0, -(float)(source * SORTED_STRIDE % SORTED_COUNT) * SORTED_SPACING };
    }
    result.scene.mark_instances_dirty(result.mesh);
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn void test_blended_batch_draws_far_to_near() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    MaterialId order;
    @pool() {
        order = add_sort_order_material(&fixture)!!;
    };
    DeformedScene depth_line = create_depth_line_scene(&fixture, order)!!;
    defer scene::destroy_scene(&depth_line.scene);

    check_channels(settle_and_sample(&fixture, &depth_line)!!, GREEN);
    assert(renderer.stats.sort_dispatches == SORTED_STEPS);
    assert(renderer.stats.instances_visible == SORTED_COUNT);

    set_view_culling(&fixture, false)!!;
    check_channels(settle_and_sample(&fixture, &depth_line)!!, GREEN);
    assert(renderer.stats.sort_dispatches == SORTED_STEPS);
    assert(renderer.stats.cull_dispatches == 1);
    check_validation(renderer);
}

fn void test_culled_blended_batch_sorts_survivors() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene line = create_line_scene(&fixture, fixture.translucent)!!;
    defer scene::destroy_scene(&line.scene);
    uint survivors = line_survivors(&fixture, &line);

    uint culled_pixel = settle_and_sample(&fixture, &line)!!;
    assert(renderer.stats.instances_tested == LINE_COUNT);
    assert(renderer.stats.instances_visible == survivors);
    assert(renderer.stats.sort_dispatches == LINE_SORT_STEPS);

    set_view_culling(&fixture, false)!!;
    assert(settle_and_sample(&fixture, &line)!! == culled_pixel);
    assert(renderer.stats.instances_tested == LINE_COUNT);
    assert(renderer.stats.instances_visible == LINE_COUNT);
    assert(renderer.stats.sort_dispatches == LINE_SORT_STEPS);
    check_validation(renderer);
}

fn void test_sort_overflow_draws_unsorted() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, instance_cull_bytes: SORT_OVERFLOW_ARENA_BYTES)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    DeformedScene line = create_line_scene(&fixture, fixture.translucent)!!;
    defer scene::destroy_scene(&line.scene);

    uint pixel = settle_and_sample(&fixture, &line)!!;
    assert(renderer.stats.sort_overflows == 1 && renderer.stats.cull_overflows == 0);
    assert(renderer.stats.sort_dispatches == 1 && renderer.stats.cull_dispatches == 1);
    check_rgb(pixel, { 0.5f, 0.5f, 0.5f, 0 });
    check_validation(renderer);
}
