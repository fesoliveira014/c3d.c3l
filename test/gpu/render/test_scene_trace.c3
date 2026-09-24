module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::maths;
import c3d::render @public;
import c3d::material;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import gpu;
import std::io;
import std::math;

const char[*] TRACE_GRID_SOURCE @private = $embed("trace_grid.comp.glsl");
const uint TRACE_GRID_SIZE @private = 64;
const uint TRACE_GROUP_SIZE @private = 8; // mirrored as local_size_x and local_size_y in trace_grid.comp.glsl
const Vec3 TRACE_ORIGIN @private = { 0, 2, 10 };
const Vec4 TRACE_RECTANGLE @private = { -6, -3, 6, 3 };
const float TRACE_PLANE_Z @private = -6;
const float TRACE_DISTANCE_TOLERANCE @private = 1e-4f;
const float TRACE_EDGE_WEIGHT @private = 1e-3f; // a ray this close to an edge may land on either side on CPU and GPU
const usz TRACE_EDGE_BUDGET @private = TRACE_GRID_SIZE * TRACE_GRID_SIZE / 100; // one percent of the rays
const usz TRACE_RESULT_BYTES @private = TRACE_GRID_SIZE * TRACE_GRID_SIZE * TraceGridResult::size;
const uint PARITY_CHECKER_SIZE @private = 4;
const float PARITY_BARYCENTRIC_TOLERANCE @private = 1e-3f;

struct TraceGridRoot @private {
    gpu::GpuAddress scene;
    gpu::GpuAddress output_address;
    Vec4            origin;
    Vec4            rectangle;
    float           plane_z;
    uint            grid_size;
    uint            instance_mask;
    uint            padding;
}
$assert TraceGridRoot::size == 64;

struct TraceGridResult @private {
    uint  hit;
    uint  primitive;
    float t;
    uint  geometry_low;
    Vec2  barycentrics;
    Vec2  padding;
}
$assert TraceGridResult::size == 32;

struct TraceScene @private {
    Scene           scene;
    ComputeShaderId shader;
    ComputeShaderId query_shader;
    BufferId        output;
    gpu::MappedGpuSpan readback;
}

fn void? create_trace_scene(Fixture* fixture, TraceScene* trace) @private {
    AssetStore* assets = &fixture.assets;
    trace.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&trace.scene);
    GeometryId sphere;
    GeometryId released;
    GeometryId ground;
    GeometryId malformed;
    @pool() {
        Geometry sphere_geometry = geometry::sphere(tmem, 1);
        sphere = assets.add_geometry(&sphere_geometry)!;
        released = assets.add_geometry(&sphere_geometry)!;
        Geometry plane = geometry::plane(tmem, 16, 16, 4, 4);
        plane.unindex(tmem);
        ground = assets.add_geometry(&plane)!;
        Geometry stray_index = geometry::box(tmem, 1, 1, 1);
        stray_index.indices = stray_index.indices[:stray_index.indices.len - 1];
        malformed = assets.add_geometry(&stray_index)!;
    };
    assets.release_geometry_cpu(released);

    Scene* scene = &trace.scene;
    scene.add_mesh(fixture.box, fixture.plain, name: "box")!;
    Node* sphere_node = scene.add_mesh(sphere, fixture.plain, name: "sphere")!;
    sphere_node.local.position = { 3, 0, 0 };
    Node* ground_node = scene.add_mesh(ground, fixture.plain, name: "ground")!;
    ground_node.local.position = { 0, -1.5f, 0 };
    Node* released_node = scene.add_mesh(released, fixture.plain, name: "released")!;
    released_node.local.position = { 0, 12, 0 };
    Node* malformed_node = scene.add_mesh(malformed, fixture.plain, name: "malformed")!;
    malformed_node.local.position = { 5, 12, 0 };
    Transform[3] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    foreach (index, &transform : transforms) transform.position = { (float)index * 2 - 2, 0, 0 };
    transforms[2].scale = { -1, 1, 1 };
    Node* batch = scene.add_instanced_mesh(fixture.box, fixture.plain, 3, transforms[..], name: "batch")!;
    batch.local.position = { 0, 0, -4 };
    scene.update_world();

    String[1] walk = { "SCENE_TRACE_BVH" };
    trace.shader = add_compute_shader(fixture, (String)TRACE_GRID_SOURCE[..], walk[..])!;
    if (fixture.renderer.caps.ray_queries.enabled) {
        String[1] query = { "SCENE_TRACE_RAY_QUERY" };
        trace.query_shader = add_compute_shader(fixture, (String)TRACE_GRID_SOURCE[..], query[..])!;
    }
    trace.output = fixture.renderer.create_buffer({ .size = TRACE_RESULT_BYTES, .debug_name = "trace_grid_output" })!;
    gpu::AllocationDesc readback_desc = {
        .size         = TRACE_RESULT_BYTES,
        .alignment    = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "trace_grid_readback",
    };
    trace.readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!;
}

fn void destroy_trace_scene(Fixture* fixture, TraceScene* trace) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = trace.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    scene::destroy_scene(&trace.scene);
}

fn Ray grid_ray(uint cell_x, uint cell_y) @private {
    Vec2 fraction = { ((float)cell_x + 0.5f) / TRACE_GRID_SIZE, ((float)cell_y + 0.5f) / TRACE_GRID_SIZE };
    Vec3 target = {
        TRACE_RECTANGLE.x + (TRACE_RECTANGLE.z - TRACE_RECTANGLE.x) * fraction.x,
        TRACE_RECTANGLE.y + (TRACE_RECTANGLE.w - TRACE_RECTANGLE.y) * fraction.y,
        TRACE_PLANE_Z,
    };
    return { .origin = TRACE_ORIGIN, .direction = (target - TRACE_ORIGIN).normalize() };
}

fn void? trace_grid(
    Fixture* fixture,
    TraceScene* trace,
    TraceGridResult[] results,
    TraceKind kind = TraceKind.SOFTWARE,
    uint instance_mask = shader::TRACE_MASK_ALL,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    TraceGridRoot root = {
        .scene          = renderer.prepare_scene_trace(&trace.scene, kind)!,
        .instance_mask  = instance_mask,
        .output_address = renderer.buffer_address(trace.output),
        .origin         = { TRACE_ORIGIN.x, TRACE_ORIGIN.y, TRACE_ORIGIN.z, 1 },
        .rectangle      = TRACE_RECTANGLE,
        .plane_z        = TRACE_PLANE_Z,
        .grid_size      = TRACE_GRID_SIZE,
    };
    BufferId[1] writes = { trace.output };
    uint groups = TRACE_GRID_SIZE / TRACE_GROUP_SIZE;
    renderer.dispatch({
        .shader = kind == TraceKind.HARDWARE ? trace.query_shader : trace.shader,
        .root   = ((char*)&root)[:TraceGridRoot::size],
        .groups = { groups, groups, 1 },
        .writes = writes[..],
    })!;
    gpu::Barrier written = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &written)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(trace.output).allocation)!,
        .dst = trace.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;

    gpu::invalidate_mapped_span(&renderer.device, trace.readback.span)!;
    mem::copy(results.ptr, trace.readback.bytes.ptr, (sz)TRACE_RESULT_BYTES);
}

fn GeometryId picked_geometry(Scene* scene, PickHit* hit) @private {
    if (hit.instanced) return scene.get(hit.node, InstancedMesh).geometry;
    return scene.get(hit.node, Mesh).geometry;
}

fn float min_weight(Vec3 weights) @private {
    return math::min(math::min(weights.x, weights.y), weights.z);
}

fn bool check_ray(
    Fixture* fixture,
    TraceScene* trace,
    Ray ray,
    TraceGridResult* result,
) @private {
    PickOptions options = {
        .precision = PickPrecision.TRIANGLES,
        .faces     = PickFaces.BOTH,
        .layers    = camera::ALL_LAYERS,
    };
    PickHit[] hits = spatial::pick(
        allocator: tmem,
        assets:    &fixture.assets,
        scene:     &trace.scene,
        ray:       ray,
        options:   options,
    );
    bool picked = hits.len > 0 && hits[0].triangle_hit;
    Vec3 traced_weights = {
        1 - result.barycentrics.x - result.barycentrics.y,
        result.barycentrics.x,
        result.barycentrics.y,
    };
    if (!picked || !result.hit) {
        float edge_weight = picked ? min_weight(hits[0].barycentric) : min_weight(traced_weights);
        assert((!picked && !result.hit) || edge_weight < TRACE_EDGE_WEIGHT);
        return picked != (bool)result.hit;
    }

    PickHit* nearest = &hits[0];
    float tolerance = TRACE_DISTANCE_TOLERANCE * math::max(1.0f, nearest.distance);
    assert(math::abs(result.t - nearest.distance) <= tolerance);
    if (result.primitive != nearest.triangle_index) {
        assert(math::min(min_weight(nearest.barycentric), min_weight(traced_weights)) < TRACE_EDGE_WEIGHT);
        return true;
    }
    GeometryId geometry = picked_geometry(&trace.scene, nearest);
    assert(result.geometry_low == (uint)(ulong)fixture.renderer.geometries[geometry.index].root);
    return false;
}

fn void test_bvh_traversal_matches_cpu_picking() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    TraceScene trace;
    create_trace_scene(&fixture, &trace)!!;
    defer destroy_trace_scene(&fixture, &trace);

    TraceGridResult[] first = alloc::new_array(mem, TraceGridResult, TRACE_GRID_SIZE * TRACE_GRID_SIZE);
    defer alloc::free(mem, first.ptr);
    trace_grid(&fixture, &trace, first)!!;
    assert(fixture.renderer.stats.trace_instances == 6 && fixture.renderer.stats.trace_skipped == 2);

    usz edges;
    usz hits;
    @pool() {
        for (uint cell_y = 0; cell_y < TRACE_GRID_SIZE; cell_y++) {
            for (uint cell_x = 0; cell_x < TRACE_GRID_SIZE; cell_x++) {
                TraceGridResult* result = &first[cell_y * TRACE_GRID_SIZE + cell_x];
                bool at_edge = check_ray(
                    fixture: &fixture,
                    trace:   &trace,
                    ray:     grid_ray(cell_x, cell_y),
                    result:  result,
                );
                if (at_edge) edges++;
                if (result.hit) hits++;
            }
        }
    };
    io::eprintfn("Scene trace grid: %d of %d rays hit, %d at an edge", hits, first.len, edges);
    assert(edges <= TRACE_EDGE_BUDGET && hits > first.len / 4);

    foreach (&mirror : fixture.renderer.geometries) {
        if (mirror.allocation.is_valid()) fixture.assets.release_geometry_cpu(mirror.asset);
    }
    TraceGridResult[] second = alloc::new_array(mem, TraceGridResult, TRACE_GRID_SIZE * TRACE_GRID_SIZE);
    defer alloc::free(mem, second.ptr);
    trace_grid(&fixture, &trace, second)!!;
    assert(mem::equals(first.ptr, second.ptr, (sz)TRACE_RESULT_BYTES));
    assert(fixture.renderer.stats.trace_instances == 6 && fixture.renderer.stats.trace_skipped == 2);
}

struct ParityNodes @private {
    Node*      masked;
    Node*      receiver;
    GeometryId masked_geometry;
    GeometryId receiver_geometry;
}

fn ParityNodes? add_parity_nodes(Fixture* fixture, TraceScene* trace) @private {
    ParityNodes nodes;
    TextureId checker;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, PARITY_CHECKER_SIZE * PARITY_CHECKER_SIZE * 4);
        for (uint y = 0; y < PARITY_CHECKER_SIZE; y++) {
            for (uint x = 0; x < PARITY_CHECKER_SIZE; x++) {
                usz offset = (usz)(y * PARITY_CHECKER_SIZE + x) * 4;
                pixels[offset:3] = (char)255;
                pixels[offset + 3] = ((x + y) & 1) == 0 ? 255 : 0;
            }
        }
        checker = fixture.assets.add_texture(
            desc:   material::texture_2d_desc(
                width:      PARITY_CHECKER_SIZE,
                height:     PARITY_CHECKER_SIZE,
                format:     PixelFormat.RGBA8_UNORM,
                debug_name: "parity_checker",
            ),
            pixels: pixels,
        )!;
        Geometry box = geometry::box(tmem, 1, 1, 1);
        nodes.masked_geometry = fixture.assets.add_geometry(&box)!;
        nodes.receiver_geometry = fixture.assets.add_geometry(&box)!;
    };
    MaterialCommon cutout = material::MATERIAL_COMMON_DEFAULT;
    cutout.alpha_mode = AlphaMode.MASK;
    cutout.alpha_cutoff = 0.5f;
    MaterialId masked = fixture.assets.add_material(material::standard(
        params: {
            .base_color     = { 1, 1, 1, 1 },
            .roughness      = 1,
            .base_color_map = material::texture_slot(checker, asset::SAMPLER_NEAREST),
        },
        common: cutout,
    ))!;
    nodes.masked = trace.scene.add_mesh(nodes.masked_geometry, masked, name: "masked")!;
    nodes.masked.local.position = { -3, 0, 0 };
    nodes.receiver = trace.scene.add_mesh(nodes.receiver_geometry, fixture.plain, name: "receiver")!;
    nodes.receiver.local.position = { 0, 0, 2 };
    trace.scene.get(nodes.receiver, Mesh).cast_shadow = false;
    trace.scene.update_world();
    return nodes;
}

fn uint geometry_low(Fixture* fixture, GeometryId geometry) @private {
    return (uint)(ulong)fixture.renderer.geometries[geometry.index].root;
}

fn usz compare_branches(TraceGridResult[] walked, TraceGridResult[] queried, uint masked_low) @private {
    usz edges;
    foreach (index, &walk : walked) {
        TraceGridResult* query = &queried[index];
        Vec3 walk_weights = { 1 - walk.barycentrics.x - walk.barycentrics.y, walk.barycentrics.x, walk.barycentrics.y };
        Vec3 query_weights = { 1 - query.barycentrics.x - query.barycentrics.y, query.barycentrics.x, query.barycentrics.y };
        float edge_weight = math::min(
            walk.hit ? min_weight(walk_weights) : 1.0f,
            query.hit ? min_weight(query_weights) : 1.0f,
        );
        bool agree = walk.hit == query.hit;
        if (agree && walk.hit) {
            agree = walk.geometry_low == query.geometry_low && walk.primitive == query.primitive
                && math::abs(walk.t - query.t) <= TRACE_DISTANCE_TOLERANCE * math::max(1.0f, walk.t)
                && (walk.barycentrics - query.barycentrics).length() <= PARITY_BARYCENTRIC_TOLERANCE;
        }
        if (agree) continue;
        // A ray at a checker texel boundary may read either texel, so a masked surface can differ like an edge.
        bool masked = (walk.hit && walk.geometry_low == masked_low) || (query.hit && query.geometry_low == masked_low);
        assert(masked || edge_weight < TRACE_EDGE_WEIGHT);
        edges++;
    }
    return edges;
}

fn void test_hardware_and_software_hits_agree() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    TraceScene trace;
    create_trace_scene(&fixture, &trace)!!;
    defer destroy_trace_scene(&fixture, &trace);
    ParityNodes nodes = add_parity_nodes(&fixture, &trace)!!;

    sz cells = TRACE_GRID_SIZE * TRACE_GRID_SIZE;
    TraceGridResult[] walked = alloc::new_array(mem, TraceGridResult, cells);
    defer alloc::free(mem, walked.ptr);
    TraceGridResult[] queried = alloc::new_array(mem, TraceGridResult, cells);
    defer alloc::free(mem, queried.ptr);

    trace_grid(&fixture, &trace, walked, TraceKind.SOFTWARE)!!;
    assert(fixture.renderer.stats.trace_instances == 8 && fixture.renderer.stats.trace_skipped == 2);
    trace_grid(&fixture, &trace, queried, TraceKind.HARDWARE)!!;
    assert(fixture.renderer.stats.trace_instances == 8 && fixture.renderer.stats.trace_skipped == 2);
    uint masked_low = geometry_low(&fixture, nodes.masked_geometry);
    usz edges = compare_branches(walked, queried, masked_low);
    Aabb masked_bounds = { .min = { -3.5f, -0.5f, -0.5f }, .max = { -2.5f, 0.5f, 0.5f } };
    usz through_holes;
    usz masked_hits;
    for (uint cell_y = 0; cell_y < TRACE_GRID_SIZE; cell_y++) {
        for (uint cell_x = 0; cell_x < TRACE_GRID_SIZE; cell_x++) {
            TraceGridResult* query = &queried[cell_y * TRACE_GRID_SIZE + cell_x];
            if (query.hit && query.geometry_low == masked_low) masked_hits++;
            float entry;
            if (!maths::ray_intersects_aabb(grid_ray(cell_x, cell_y), masked_bounds, &entry)) continue;
            if (!query.hit || query.t > entry + 1) through_holes++;
        }
    }
    io::eprintfn("Parity grid: %d rays differ at an edge, %d masked hits, %d through holes", edges, masked_hits, through_holes);
    assert(edges <= TRACE_EDGE_BUDGET && masked_hits > 0 && through_holes > 0);

    uint receiver_low = geometry_low(&fixture, nodes.receiver_geometry);
    trace_grid(&fixture, &trace, walked, TraceKind.SOFTWARE, shader::TRACE_MASK_SHADOW_CASTER)!!;
    trace_grid(&fixture, &trace, queried, TraceKind.HARDWARE, shader::TRACE_MASK_SHADOW_CASTER)!!;
    assert(compare_branches(walked, queried, masked_low) <= TRACE_EDGE_BUDGET);
    foreach (index, &walk : walked) {
        assert(!walk.hit || walk.geometry_low != receiver_low);
        assert(!queried[index].hit || queried[index].geometry_low != receiver_low);
    }
}
