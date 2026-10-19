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
const usz QUADTREE_TIGHT_ARENA_BYTES @private = 256; // the counter, then room for one of three passes
const Vec3 QUADTREE_PROBE @private = { 0.5f, 0.5f, 0.05f }; // centre of a grandchild on the front face

const char[*] SELECTION_PROBE_SOURCE @private = $embed("selection_probe.vert.glsl");
const uint RANGE_DEPTHS @private = 6;
const uint RANGE_NODES @private = 1365; // 1 + 4 + 16 + 64 + 256 + 1024
const float RANGE_SIDE @private = 32; // of the root, so the finest nodes are one unit wide
const float RANGE_THICKNESS @private = 0.1f;
const float RANGE_HYSTERESIS @private = 0.25f;
const float RANGE_BAND @private = 0.25f;
const uint RANGE_WIDE_VIEW @private = 512;
const float RANGE_WIDE_SPLIT_PIXELS @private = 74; // about 6 pixels per extent: the natural ranges already hold the bound
const uint RANGE_SMALL_VIEW @private = 128;
const float RANGE_SMALL_SPLIT_PIXELS @private = 222; // about half a pixel per extent: only the clamp holds the bound
const Vec3 RANGE_CAMERA @private = { -10, -10, 1 }; // beside a corner of the plane, so the drawn depths span the tree
const float RANGE_ADJACENT_TOLERANCE @private = 1e-3f;
const uint RANGE_MINIMUM_DEPTH_SPAN @private = 2; // a pass needs drawn depths a violation could separate
const uint PROBE_NODE_FIRST @private = 8; // mirrored as NODE_FIRST in selection_probe.vert.glsl; the frame vectors come first
const uint PROBE_DEPTH_FIRST @private = 4; // mirrored as FRAME_VECTORS in selection_probe.vert.glsl; the depth form's vectors follow the shaded form's
const uint PROBE_FLAGS @private = 3; // in a form's vectors: x is the selection flag, y whether the frame's own projection is orthographic
const uint PROBE_VECTORS @private = PROBE_NODE_FIRST + QUADTREE_NODES;
const uint CHAIN_NODES @private = 5; // a single path of nodes, each the child of the one before
const usz PROBE_BYTES @private = PROBE_VECTORS * Vec4::size;

struct QuadtreeScene @private {
    Scene scene;
    Node* mesh;
    Node* near_camera;
    Node* far_camera;
    uint[QUADTREE_NODES] parents;
}

struct RangeScene @private {
    Scene scene;
    Node* mesh;
    Node* camera;
    uint[RANGE_NODES] depths;
    Vec2[RANGE_NODES] centers;
    float[RANGE_NODES] extents;
}

struct SelectionProbeBlock @private {
    Vec4 color;
    Vec4 motion;
    gpu::GpuAddress output_address;
}

struct SelectionProbe @private {
    BufferId           output;
    gpu::MappedGpuSpan readback;
    MaterialId         material;
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
    result.scene.get(result.mesh, InstancedMesh).trace = false;
    result.scene.set_instance_quadtree(
        node:         result.mesh,
        parents:      result.parents[..],
        split_pixels: QUADTREE_SPLIT_PIXELS,
        hysteresis:   QUADTREE_HYSTERESIS,
    )!;
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

fn gpu::MappedGpuSpan? create_quadtree_readback(Renderer* renderer, uint nodes = QUADTREE_NODES) @private {
    gpu::AllocationDesc desc = {
        .size         = nodes * uint::size,
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

fn void? record_selection_readback(Renderer* renderer, ViewId view, Node* mesh, gpu::MappedGpuSpan readback) @private {
    render::QuadtreeHistoryEntry* history = &renderer.views.get(view).quadtree_history.entries[mesh.id.index];
    if (!history.allocation.is_valid()) return;

    usz offset = (usz)(history.committed_slot ^ 1) * history.capacity * uint::size;
    gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, history.allocation)!;
    gpu::Barrier produced = { .before = { .compute, .vertex_shader }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &produced)!;
    gpu::BufferCopyDesc copy = { .src = source.checked_subspan(offset, readback.bytes.len)!, .dst = readback.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier copied = { .before = { .transfer }, .after = { .host } };
    return gpu::cmd_barrier(&renderer.commands, &copied);
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
    record_selection_readback(renderer, view, target.mesh, readback)!;
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

    target.scene.set_instance_quadtree(
        node:         target.mesh,
        parents:      target.parents[..],
        split_pixels: QUADTREE_SPLIT_PIXELS,
        hysteresis:   QUADTREE_HYSTERESIS,
    )!!;
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

fn void test_quadtree_arena_overflow_draws_the_leaves() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, instance_cull_bytes: QUADTREE_TIGHT_ARENA_BYTES)!!;
    defer destroy_fixture(&fixture);
    QuadtreeScene target = create_quadtree_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    gpu::MappedGpuSpan readback = create_quadtree_readback(&fixture.renderer)!!;
    defer free_quadtree_readback(&fixture.renderer, readback);
    Renderer* renderer = &fixture.renderer;

    uint far_pixel = settle_quadtree_view(
        fixture:  &fixture,
        target:   &target,
        view:     fixture.view,
        camera:   target.far_camera,
        readback: readback,
        uv:       quadtree_probe_uv(&target, target.far_camera),
    )!!;
    assert(renderer.stats.quadtree_fallbacks == 1);
    assert(renderer.stats.cull_dispatches == 0 && renderer.stats.instances_tested == 0);
    check_channels(far_pixel, BLUE);
    check_validation(renderer);
}

fn float range_extent(uint depth) @private {
    return RANGE_SIDE / (float)(1u << depth);
}

fn RangeScene*? create_range_scene(Fixture* fixture) @private {
    RangeScene* result = mem::new(RangeScene);
    defer catch free(result);
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);

    Transform[] transforms = alloc::new_array(tmem, Transform, RANGE_NODES);
    uint[] parents = alloc::new_array(tmem, uint, RANGE_NODES);
    uint first;
    for (uint depth = 0; depth < RANGE_DEPTHS; depth++) {
        uint side = 1u << depth;
        float extent = range_extent(depth);
        for (uint row = 0; row < side; row++) {
            for (uint column = 0; column < side; column++) {
                uint node = first + row * side + column;
                Vec2 center = {
                    -RANGE_SIDE / 2 + ((float)column + 0.5f) * extent,
                    -RANGE_SIDE / 2 + ((float)row + 0.5f) * extent,
                };
                result.depths[node] = depth;
                result.centers[node] = center;
                result.extents[node] = extent;
                uint parent_first = first - (side / 2) * (side / 2);
                parents[node] = depth ? parent_first + (row / 2) * (side / 2) + column / 2 : scene::QUADTREE_ROOT;
                transforms[node] = {
                    .position = { center.x, center.y, 0 },
                    .rotation = maths::TRANSFORM_IDENTITY.rotation,
                    .scale    = { extent, extent, RANGE_THICKNESS },
                };
            }
        }
        first += side * side;
    }

    result.mesh = result.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.plain,
        capacity:   RANGE_NODES,
        transforms: transforms,
    )!;
    result.scene.get(result.mesh, InstancedMesh).trace = false;
    result.scene.set_instance_quadtree(
        node:         result.mesh,
        parents:      parents,
        split_pixels: RANGE_WIDE_SPLIT_PIXELS,
        hysteresis:   RANGE_HYSTERESIS,
    )!;
    QuadtreeLevel[RANGE_DEPTHS] levels;
    foreach (depth, &level : levels) {
        float extent = range_extent((uint)depth);
        *level = { .extent = extent, .diagonal = math::sqrt(2 * extent * extent + RANGE_THICKNESS * RANGE_THICKNESS) };
    }
    result.scene.set_quadtree_ranges(result.mesh, levels[..], RANGE_BAND)!;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = RANGE_CAMERA;
    result.scene.update_world();
    return result;
}

fn void destroy_range_scene(RangeScene* target) @private {
    scene::destroy_scene(&target.scene);
    free(target);
}

fn ViewId? create_range_view(Fixture* fixture, uint size) @private {
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(size, size),
    )!;
    return render::create_view(&fixture.renderer, render::texture_view_desc(target));
}

fn void? render_range_frames(Fixture* fixture, RangeScene* target, ViewId view, gpu::MappedGpuSpan readback) @private {
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        target.scene.update_world();
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&target.scene, target.camera, view)!;
        record_selection_readback(renderer, view, target.mesh, readback)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
    }
    render::wait_frames(renderer)!;
    return gpu::invalidate_mapped_span(&renderer.device, readback.span);
}

// Two drawn nodes touch when their rectangles share an edge of positive length.
fn bool range_nodes_touch(RangeScene* target, uint first, uint second) @private {
    Vec2 offset = target.centers[second] - target.centers[first];
    float reach = (target.extents[first] + target.extents[second]) / 2;
    float overlap = reach - RANGE_ADJACENT_TOLERANCE;
    bool along_x = math::abs(math::abs(offset.x) - reach) < RANGE_ADJACENT_TOLERANCE && math::abs(offset.y) < overlap;
    bool along_y = math::abs(math::abs(offset.y) - reach) < RANGE_ADJACENT_TOLERANCE && math::abs(offset.x) < overlap;
    return along_x || along_y;
}

// Asserts that drawn nodes sharing an edge differ by at most one depth and returns the span of the drawn depths.
fn uint check_range_level_difference(RangeScene* target, gpu::MappedGpuSpan readback) @private {
    uint[] words = ((uint*)readback.bytes.ptr)[:RANGE_NODES];
    uint[] drawn = alloc::new_array(tmem, uint, RANGE_NODES);
    uint drawn_count;
    uint shallowest = RANGE_DEPTHS;
    uint deepest;
    foreach (uint node, word : words) {
        if (!(word & shader::QUADTREE_DRAW)) continue;

        drawn[drawn_count++] = node;
        shallowest = math::min(shallowest, target.depths[node]);
        deepest = math::max(deepest, target.depths[node]);
    }
    foreach (first : drawn[:drawn_count]) {
        foreach (second : drawn[:drawn_count]) {
            if (first == second || !range_nodes_touch(target, first, second)) continue;

            uint difference = target.depths[first] > target.depths[second]
              ? target.depths[first] - target.depths[second] : target.depths[second] - target.depths[first];
            assert(difference <= 1);
        }
    }
    return deepest - shallowest;
}

fn void test_box_ranges_bound_the_level_difference() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    RangeScene* target = create_range_scene(&fixture)!!;
    defer destroy_range_scene(target);
    gpu::MappedGpuSpan readback = create_quadtree_readback(&fixture.renderer, RANGE_NODES)!!;
    defer free_quadtree_readback(&fixture.renderer, readback);

    ViewId wide = create_range_view(&fixture, RANGE_WIDE_VIEW)!!;
    render_range_frames(&fixture, target, wide, readback)!!;
    assert(check_range_level_difference(target, readback) >= RANGE_MINIMUM_DEPTH_SPAN);

    ViewId small = create_range_view(&fixture, RANGE_SMALL_VIEW)!!;
    target.scene.get(target.mesh, InstancedMesh).quadtree.split_pixels = RANGE_SMALL_SPLIT_PIXELS;
    render_range_frames(&fixture, target, small, readback)!!;
    assert(check_range_level_difference(target, readback) >= RANGE_MINIMUM_DEPTH_SPAN);
    check_validation(&fixture.renderer);
}

fn ShaderId? add_selection_probe_shader(Fixture* fixture) @private {
    String[1] depth_only = { "DEPTH_ONLY" };
    String[1] instanced = { "INSTANCED" };
    String[2] instanced_depth = { "DEPTH_ONLY", "INSTANCED" };
    asset::ShaderDesc desc = {
        .fragment = compile_pulse_stage(fixture, PULSE_FRAGMENT, ShaderStage.FRAGMENT)!,
        .vertex   = {
            .shaded           = compile_selection_probe(fixture, {})!,
            .depth            = compile_selection_probe(fixture, depth_only[..])!,
            .instanced_shaded = compile_selection_probe(fixture, instanced[..])!,
            .instanced_depth  = compile_selection_probe(fixture, instanced_depth[..])!,
        },
        .param_block_size = SelectionProbeBlock::size,
    };
    defer {
        alloc::free(fixture.allocator, desc.fragment.ptr);
        alloc::free(fixture.allocator, desc.vertex.shaded.ptr);
        alloc::free(fixture.allocator, desc.vertex.depth.ptr);
        alloc::free(fixture.allocator, desc.vertex.instanced_shaded.ptr);
        alloc::free(fixture.allocator, desc.vertex.instanced_depth.ptr);
    }
    return fixture.assets.add_shader(&desc);
}

fn char[]? compile_selection_probe(Fixture* fixture, String[] defines) @private {
    return compile::compile_glsl(
        allocator: fixture.allocator,
        source:    (String)SELECTION_PROBE_SOURCE[..],
        stage:     ShaderStage.VERTEX,
        defines:   defines,
    );
}

fn SelectionProbe? create_selection_probe(Fixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;
    SelectionProbe probe;
    probe.output = renderer.create_buffer({ .size = PROBE_BYTES, .debug_name = "selection_probe" })!;
    gpu::AllocationDesc readback_desc = {
        .size         = PROBE_BYTES,
        .alignment    = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "selection_probe_readback",
    };
    probe.readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
    defer catch {
        gpu::GpuAllocation allocation = probe.readback.span.allocation();
        (void)gpu::free_allocation(&renderer.device, &allocation);
    }

    ShaderId shader = add_selection_probe_shader(fixture)!;
    SelectionProbeBlock block = { .color = { 1, 1, 1, 1 }, .output_address = renderer.buffer_address(probe.output) };
    probe.material = fixture.assets.add_material(material::custom(shader, material::@as_bytes(block)))!;
    return probe;
}

fn void destroy_selection_probe(Fixture* fixture, SelectionProbe* probe) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = probe.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
}

// Clears the probe, renders the view, and returns the vectors the vertex stages wrote.
fn Vec4[]? render_selection_probe(
    Fixture* fixture,
    SelectionProbe* probe,
    Scene* scene,
    Node* camera,
    ViewId view,
) @private {
    Renderer* renderer = &fixture.renderer;
    scene.update_world();
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);

    gpu::GpuSpan output = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(probe.output).allocation)!;
    gpu::cmd_fill_buffer(&renderer.commands, output, 0)!;
    gpu::Barrier cleared = { .before = { .transfer }, .after = { .vertex_shader } };
    gpu::cmd_barrier(&renderer.commands, &cleared)!;

    renderer.render_view(scene, camera, view)!;
    renderer.finish_view(view)!;

    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = { .src = output, .dst = probe.readback.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;

    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, probe.readback.span)!;
    return ((Vec4*)probe.readback.bytes.ptr)[:PROBE_VECTORS];
}

fn void test_selection_camera_follows_the_owning_view() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    SelectionProbe probe = create_selection_probe(&fixture)!!;
    defer destroy_selection_probe(&fixture, &probe);
    DeformedScene target = create_single_box_scene(&fixture, fixture.box, probe.material, sunlit: true)!!;
    defer scene::destroy_scene(&target.scene);

    ViewDesc desc = render::texture_view_desc(fixture.hdr_target);
    desc.depth_prepass = false;
    render::configure_view(renderer, fixture.view, desc)!!;
    Vec4[] vectors = render_selection_probe(&fixture, &probe, &target.scene, target.camera, fixture.view)!!;

    float pixel_scale = (float)TARGET_SIZE / (2 * math::tan(math::deg_to_rad(60.0f) * 0.5f));
    Vec4 expected = { CAMERA_POSITION.x, CAMERA_POSITION.y, CAMERA_POSITION.z, pixel_scale };
    assert(vectors[0] == expected && vectors[1] == expected);
    assert(vectors[PROBE_DEPTH_FIRST] == expected && vectors[PROBE_DEPTH_FIRST + 1] == expected);
    assert(vectors[PROBE_DEPTH_FIRST + 2].xyz != expected.xyz);
    assert(vectors[PROBE_FLAGS] == (Vec4){ 0, 0, 0, 0 });
    assert(vectors[PROBE_DEPTH_FIRST + PROBE_FLAGS] == (Vec4){ 0, 1, 0, 0 });
    check_validation(renderer);
}

fn void test_selection_flag_follows_the_owning_views_projection() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    SelectionProbe probe = create_selection_probe(&fixture)!!;
    defer destroy_selection_probe(&fixture, &probe);
    DeformedScene target = create_single_box_scene(&fixture, fixture.box, probe.material, sunlit: true)!!;
    defer scene::destroy_scene(&target.scene);
    *target.scene.get(target.camera, Camera) = camera::orthographic(ORTHOGRAPHIC_HEIGHT, 0.1f, 100);

    ViewDesc desc = render::texture_view_desc(fixture.hdr_target);
    desc.depth_prepass = false;
    render::configure_view(&fixture.renderer, fixture.view, desc)!!;
    Vec4[] vectors = render_selection_probe(&fixture, &probe, &target.scene, target.camera, fixture.view)!!;

    float pixel_scale = (float)TARGET_SIZE / ORTHOGRAPHIC_HEIGHT;
    assert(vectors[0].w == pixel_scale && vectors[PROBE_DEPTH_FIRST].w == pixel_scale);
    assert(vectors[PROBE_FLAGS] == (Vec4){ 1, 1, 0, 0 });
    assert(vectors[PROBE_DEPTH_FIRST + PROBE_FLAGS] == (Vec4){ 1, 1, 0, 0 });
    check_validation(&fixture.renderer);
}

fn void test_vertex_stage_reads_the_quadtree_block() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    SelectionProbe probe = create_selection_probe(&fixture)!!;
    defer destroy_selection_probe(&fixture, &probe);
    QuadtreeScene target = create_quadtree_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.get(target.mesh, InstancedMesh).material = probe.material;
    QuadtreeLevel[3] levels = {
        { .extent = 4, .diagonal = 5.7f },
        { .extent = 2, .diagonal = 2.9f },
        { .extent = 1, .diagonal = 1.5f },
    };
    target.scene.set_quadtree_ranges(target.mesh, levels[..], 0.25f)!!;

    Vec4[] vectors = render_selection_probe(&fixture, &probe, &target.scene, target.near_camera, fixture.view)!!;
    uint seen;
    for (uint node = 0; node < QUADTREE_NODES; node++) {
        Vec4 written = vectors[PROBE_NODE_FIRST + node];
        if (written == (Vec4){}) continue;

        seen++;
        uint depth = node == 0 ? 0 : (node < 5 ? 1 : 2);
        assert(written.x == (float)depth);
        assert(written.y == (depth ? 1.0f : 0.0f) && written.z == 0);
    }

    assert(seen >= QUADTREE_NEAR_DRAWN);
    check_validation(&fixture.renderer);
}

fn void test_smaller_batch_on_a_surviving_slot_reads_its_own_depths() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    SelectionProbe probe = create_selection_probe(&fixture)!!;
    defer destroy_selection_probe(&fixture, &probe);
    QuadtreeScene target = create_quadtree_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    target.scene.get(target.mesh, InstancedMesh).material = probe.material;
    render_selection_probe(&fixture, &probe, &target.scene, target.near_camera, fixture.view)!!;

    target.scene.remove_component(target.mesh, InstancedMesh);
    Allocator allocator = target.scene.allocator;
    InstancedMesh chain = {
        .geometry       = fixture.box,
        .material       = probe.material,
        .transforms     = alloc::new_array(allocator, Transform, CHAIN_NODES),
        .colors         = alloc::new_array(allocator, Vec4, CHAIN_NODES),
        .count          = CHAIN_NODES,
        .cast_shadow    = true,
        .receive_shadow = true,
        .revision       = 7,
    };
    chain.transforms[..] = maths::TRANSFORM_IDENTITY;
    chain.colors[..] = WARM;
    target.scene.add(target.mesh, chain);
    uint[CHAIN_NODES] parents = { scene::QUADTREE_ROOT, 0, 1, 2, 3 };
    target.scene.set_instance_quadtree(target.mesh, parents[..], 1, 0.5f)!!;
    QuadtreeLevel[CHAIN_NODES] levels = {
        { .extent = 4, .diagonal = 5.7f },
        { .extent = 3, .diagonal = 4.3f },
        { .extent = 2, .diagonal = 2.9f },
        { .extent = 1, .diagonal = 1.5f },
        { .extent = 0.5f, .diagonal = 0.8f },
    };
    target.scene.set_quadtree_ranges(target.mesh, levels[..], 0.25f)!!;

    Vec4[] vectors = render_selection_probe(&fixture, &probe, &target.scene, target.near_camera, fixture.view)!!;
    assert(vectors[PROBE_NODE_FIRST + CHAIN_NODES - 1].x == (float)(CHAIN_NODES - 1));
    check_validation(&fixture.renderer);
}
