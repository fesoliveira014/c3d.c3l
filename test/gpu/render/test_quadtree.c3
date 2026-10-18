module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const uint QUADTREE_NODES @private = 21; // one root, four children and sixteen grandchildren
const uint QUADTREE_NEAR_DRAWN @private = 16;
const uint QUADTREE_FAR_DRAWN @private = 4;
const float QUADTREE_SPLIT_PIXELS @private = 15; // in a 32-pixel view the root and the children split at 4 units, only the root at 7
const float QUADTREE_HYSTERESIS @private = 0.5f; // a child 7 units away spans 11 pixels, above the 10-pixel merge size
const float QUADTREE_NEAR @private = 4;
const float QUADTREE_FAR @private = 7;
const uint QUADTREE_PASSES @private = 3; // shadow layer, depth prepass and view
const Vec3 QUADTREE_PROBE @private = { 0.5f, 0.5f, 0.05f }; // centre of a grandchild on the front face

struct QuadtreeScene @private {
    Scene scene;
    Node* mesh;
    Node* near_camera;
    Node* far_camera;
    uint[QUADTREE_NODES] parents;
}

fn QuadtreeScene? create_quadtree_scene(Fixture* fixture, bool sunlit = false) @private {
    QuadtreeScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    Transform[QUADTREE_NODES] transforms;
    Vec4[QUADTREE_NODES] colors;
    transforms[0] = { .position = {}, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 4, 4, 0.1f } };
    colors[0] = RED;
    result.parents[0] = scene::QUADTREE_ROOT;
    for (uint child = 0; child < 4; child++) {
        Vec3 center = { child % 2 ? 1.0f : -1.0f, child / 2 ? 1.0f : -1.0f, 0 };
        uint child_index = 1 + child;
        transforms[child_index] = { .position = center, .rotation = maths::TRANSFORM_IDENTITY.rotation, .scale = { 2, 2, 0.1f } };
        colors[child_index] = GREEN;
        result.parents[child_index] = 0;
        for (uint grandchild = 0; grandchild < 4; grandchild++) {
            Vec3 offset = { grandchild % 2 ? 0.5f : -0.5f, grandchild / 2 ? 0.5f : -0.5f, 0 };
            uint index = 5 + 4 * child + grandchild;
            transforms[index] = {
                .position = center + offset,
                .rotation = maths::TRANSFORM_IDENTITY.rotation,
                .scale    = { 1, 1, 0.1f },
            };
            colors[index] = BLUE;
            result.parents[index] = child_index;
        }
    }
    result.mesh = result.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.plain,
        capacity:   QUADTREE_NODES,
        transforms: transforms[..],
        colors:     colors[..],
    )!;
    InstancedMesh* batch = result.scene.get(result.mesh, InstancedMesh);
    batch.trace = false;
    batch.set_quadtree(result.scene.allocator, result.parents[..], QUADTREE_SPLIT_PIXELS, QUADTREE_HYSTERESIS)!;
    result.near_camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.near_camera.local.position = { 0, 0, QUADTREE_NEAR };
    result.far_camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.far_camera.local.position = { 0, 0, QUADTREE_FAR };
    if (sunlit) {
        Light sunlight = light::directional({ 1, 1, 1 }, 2);
        sunlight.shadow.cascades = 1;
        sunlight.shadow.max_distance = 20;
        result.scene.add_light(sunlight)!;
    }
    result.scene.update_world();
    return result;
}

fn gpu::MappedGpuSpan? create_quadtree_readback(Renderer* renderer) @private {
    gpu::AllocationDesc desc = {
        .size         = QUADTREE_NODES * uint::size,
        .alignment    = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "quadtree_readback",
    };
    return gpu::allocate_mapped_memory(&renderer.device, &desc);
}

fn void free_quadtree_readback(Renderer* renderer, gpu::MappedGpuSpan readback) @private {
    render::wait_frames(renderer)!!;
    gpu::GpuAllocation allocation = readback.span.allocation();
    gpu::free_allocation(&renderer.device, &allocation)!!;
}

fn uint? render_quadtree_frame(
    Fixture* fixture,
    QuadtreeScene* target,
    ViewId view,
    Node* camera,
    gpu::MappedGpuSpan readback,
    Vec2 uv = CENTER_UV,
) @private {
    Renderer* renderer = &fixture.renderer;
    target.scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&target.scene, camera, view)!;
    render::QuadtreeHistoryEntry* history = &renderer.views.get(view).quadtree_history.entries[target.mesh.id.index];
    usz offset = (usz)(history.committed_slot ^ 1) * history.capacity * uint::size;
    gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, history.allocation)!;
    gpu::Barrier produced = { .before = { .compute, .vertex_shader }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &produced)!;
    gpu::BufferCopyDesc copy = { .src = source.checked_subspan(offset, readback.bytes.len)!, .dst = readback.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &copied)!;
    sample(fixture, render::read_view_color(view), uv)!;
    record_readback(fixture)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    uint pixel = read_pixel(fixture);
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    return pixel;
}

fn uint? settle_quadtree_view(
    Fixture* fixture,
    QuadtreeScene* target,
    ViewId view,
    Node* camera,
    gpu::MappedGpuSpan readback,
    Vec2 uv = CENTER_UV,
) @private {
    uint pixel;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        pixel = render_quadtree_frame(
            fixture:  fixture,
            target:   target,
            view:     view,
            camera:   camera,
            readback: readback,
            uv:       uv,
        )!;
    }
    return pixel;
}

// Counts the drawn nodes and asserts that every leaf area has exactly one drawn node on its path to the root.
fn uint check_quadtree_selection(gpu::MappedGpuSpan readback, uint[] parents) @private {
    uint[] words = ((uint*)readback.bytes.ptr)[:QUADTREE_NODES];
    uint drawn;
    foreach (uint node, word : words) {
        if (word & shader::QUADTREE_DRAW) drawn++;

        bool leaf = true;
        foreach (parent : parents) {
            if (parent == node) leaf = false;
        }
        if (!leaf) continue;

        uint covering;
        for (uint ancestor = node; ancestor != scene::QUADTREE_ROOT; ancestor = parents[ancestor]) {
            if (words[ancestor] & shader::QUADTREE_DRAW) covering++;
        }
        assert(covering == 1);
    }
    return drawn;
}

fn Vec2 quadtree_probe_uv(QuadtreeScene* target, Node* camera) @private {
    CameraMatrices matrices = camera::derive_matrices(
        *target.scene.get(camera, Camera),
        camera.world,
        { TARGET_SIZE, TARGET_SIZE },
    );
    return projected_uv(&matrices, QUADTREE_PROBE);
}

fn void test_quadtree_views_select_independently() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    QuadtreeScene target = create_quadtree_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    gpu::MappedGpuSpan readback = create_quadtree_readback(&fixture.renderer)!!;
    defer free_quadtree_readback(&fixture.renderer, readback);

    uint near_pixel = settle_quadtree_view(
        fixture:  &fixture,
        target:   &target,
        view:     fixture.view,
        camera:   target.near_camera,
        readback: readback,
        uv:       quadtree_probe_uv(&target, target.near_camera),
    )!!;
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_NEAR_DRAWN);
    check_channels(near_pixel, BLUE);
    assert(fixture.renderer.stats.instances_visible == 2 * QUADTREE_NEAR_DRAWN);

    uint far_pixel = settle_quadtree_view(
        fixture:  &fixture,
        target:   &target,
        view:     fixture.second_view,
        camera:   target.far_camera,
        readback: readback,
        uv:       quadtree_probe_uv(&target, target.far_camera),
    )!!;
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_FAR_DRAWN);
    check_channels(far_pixel, GREEN);
    assert(fixture.renderer.stats.instances_visible == 2 * QUADTREE_FAR_DRAWN);

    render_quadtree_frame(
        fixture:  &fixture,
        target:   &target,
        view:     fixture.view,
        camera:   target.near_camera,
        readback: readback,
    )!!;
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_NEAR_DRAWN);
    check_validation(&fixture.renderer);
}

fn void test_quadtree_history_follows_the_topology_revision() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    QuadtreeScene target = create_quadtree_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    gpu::MappedGpuSpan readback = create_quadtree_readback(&fixture.renderer)!!;
    defer free_quadtree_readback(&fixture.renderer, readback);
    InstancedMesh* batch = target.scene.get(target.mesh, InstancedMesh);

    settle_quadtree_view(&fixture, &target, fixture.view, target.near_camera, readback)!!;
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_NEAR_DRAWN);
    settle_quadtree_view(&fixture, &target, fixture.view, target.far_camera, readback)!!;
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_NEAR_DRAWN);

    ViewDesc desc = fixture.renderer.views.get(fixture.view).desc;
    desc.lod_bias = 1;
    render::configure_view(&fixture.renderer, fixture.view, desc)!!;
    render_quadtree_frame(&fixture, &target, fixture.view, target.far_camera, readback)!!;
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_NEAR_DRAWN);

    batch.colors[0] = WARM;
    target.scene.mark_instances_dirty(target.mesh);
    uint revision = batch.quadtree.revision;
    render_quadtree_frame(&fixture, &target, fixture.view, target.far_camera, readback)!!;
    assert(batch.quadtree.revision == revision);
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_NEAR_DRAWN);

    batch.set_quadtree(target.scene.allocator, target.parents[..], QUADTREE_SPLIT_PIXELS, QUADTREE_HYSTERESIS)!!;
    render_quadtree_frame(&fixture, &target, fixture.view, target.far_camera, readback)!!;
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_FAR_DRAWN);
    render_quadtree_frame(&fixture, &target, fixture.view, target.far_camera, readback)!!;
    assert(check_quadtree_selection(readback, target.parents[..]) == QUADTREE_FAR_DRAWN);
    check_validation(&fixture.renderer);
}

fn void test_quadtree_shadow_layer_draws_the_views_selection() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    QuadtreeScene target = create_quadtree_scene(&fixture, sunlit: true)!!;
    defer scene::destroy_scene(&target.scene);
    gpu::MappedGpuSpan readback = create_quadtree_readback(&fixture.renderer)!!;
    defer free_quadtree_readback(&fixture.renderer, readback);
    Renderer* renderer = &fixture.renderer;

    settle_quadtree_view(&fixture, &target, fixture.view, target.near_camera, readback)!!;
    assert(renderer.stats.shadow_layers == 1);
    assert(renderer.stats.instances_tested == QUADTREE_PASSES * QUADTREE_NODES);
    assert(renderer.stats.instances_visible == QUADTREE_PASSES * QUADTREE_NEAR_DRAWN);

    settle_quadtree_view(&fixture, &target, fixture.second_view, target.far_camera, readback)!!;
    assert(renderer.stats.shadow_layers == 1);
    assert(renderer.stats.instances_visible == QUADTREE_PASSES * QUADTREE_FAR_DRAWN);
    check_validation(renderer);
}

fn void test_quadtree_with_lod_group_faults() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    QuadtreeScene target = create_quadtree_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    LodLevel[1] levels = {{ .first_part = 0, .part_count = 1, .min_screen_size = 0 }};
    LodPart[1] parts = {{ .geometry = fixture.box, .material = fixture.plain, .local = matrix::IDENTITY4 }};
    LodGroup group = scene::create_lod_group(
        allocator: fixture.allocator,
        assets:    &fixture.assets,
        desc:      { .levels = levels[..], .parts = parts[..] },
    )!!;
    target.scene.add(target.mesh, group);
    target.scene.update_world();

    fixture.renderer.begin_frame()!!;
    assert(@catch(fixture.renderer.render_view(&target.scene, target.near_camera, fixture.view)) == c3d::UNSUPPORTED);
    render::abort_frame(&fixture.renderer);
    check_validation(&fixture.renderer);
}
