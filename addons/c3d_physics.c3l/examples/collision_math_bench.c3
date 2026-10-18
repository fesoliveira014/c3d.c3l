module collision_math_example;

import std::core::mem::allocators;
import std::io;
import std::time;
import std::time::clock;
import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics;
import c3d::physics::collide;
import c3d::scene;
import b3;

const uint  BENCH_REPEATS @local = 3; // medians of three runs
const uint  BENCH_WARMUP_CALLS @local = 300;
const uint  BENCH_TIMED_CALLS @local = 1000;
const uint  BENCH_REUSE_OWNERS @local = 1000; // same-key owners created while the first stays alive
const uint  BENCH_FIELD_POINTS @local = 65; // grid points per side: 64 by 64 cells, 8,192 triangles
const uint  BENCH_FULL_SURFACE_POINTS @local = 257; // 256 by 256 cells, 131,072 triangles
const uint  BENCH_FULL_SURFACE_WARMUP_CALLS @local = 10; // distance scans every triangle, so this case is bounded
const uint  BENCH_FULL_SURFACE_TIMED_CALLS @local = 100;
const float BENCH_COLUMN_RISE @local = 0.1f; // raw height gained per column: the test corpus's slope with one hole
const Vec3  BENCH_FIELD_SCALE @local = { 1, 1, 1 };
const float BENCH_SEPARATED_GAP @local = 2; // probe base above the surface
const float BENCH_NEAR_OVERLAP @local = 0.01f; // probe base below the surface, inside the contact margin
const float BENCH_CAST_DISTANCE @local = 4;
const float BENCH_PROBE_POSITION @local = 0.3f; // fraction of the grid span where the probe stands, clear of the hole
const float BENCH_RAY_HEIGHT @local = 1000;
const usz   BENCH_CONTACT_CAPACITY @local = 64; // fixed and sufficient for one hull manifold per triangle
const double NANOSECONDS_PER_MICROSECOND @local = 1000;

enum BenchQuery @local {
    CONTACTS,
    DISTANCE,
    CAST,
}

enum BenchPlacement @local {
    SEPARATED,
    NEAR_SURFACE,
}

struct BenchField @local {
    uint                points;
    float[]             heights;
    char[]              cells;
    SurfaceMaterialDesc surface; // bodies index their cells into this one material
}

struct BenchRig @local {
    CollisionCache* cache;
    CollisionShape surface;
    CollisionShape probe;
    maths::Transform surface_pose;
    maths::Transform separated;
    maths::Transform near_surface;
    CollisionContact[BENCH_CONTACT_CAPACITY] contacts;
}

struct CacheRun @local {
    double query_prepare_us;
    double hull_body_us;
    double field_body_us;
    uint   entries;
    bool   shared_field_data;
    sz     c3_allocations;
    sz     c3_live_bytes;
    sz     c3_peak_bytes;
    int    native_query_bytes;
    int    native_hull_body_bytes;
    int    native_field_body_bytes;
}

struct ReuseRun @local {
    double first_us;
    double repeat_us;
    sz     first_allocations;
    sz     repeat_allocations;
}

fn BenchField make_bench_field(uint points) @local {
    usz sample_count = (usz)points * points;
    usz cell_count = (usz)(points - 1) * (usz)(points - 1);
    BenchField field = {
        .points = points,
        .heights = alloc::new_array(mem, float, (sz)sample_count),
        .cells = alloc::new_array(mem, char, (sz)cell_count),
    };
    for (uint row = 0; row < points; row++) {
        for (uint column = 0; column < points; column++) {
            field.heights[row * points + column] = BENCH_COLUMN_RISE * (float)column;
        }
    }
    uint middle = (points - 1) / 2;
    field.cells[middle * (points - 1) + middle] = physics::HEIGHT_FIELD_HOLE;

    return field;
}

fn void destroy_bench_field(BenchField* field) @local {
    alloc::free(mem, field.heights.ptr);
    alloc::free(mem, field.cells.ptr);
}

fn CollisionShapeDesc bench_field_desc(BenchField* field) @local {
    CollisionShapeDesc desc = physics::default_collision_shape_desc(physics::ColliderKind.HEIGHT_FIELD);
    desc.scale = BENCH_FIELD_SCALE;
    desc.height_field = { .heights = field.heights, .count_x = field.points, .count_z = field.points };
    desc.material_indices = field.cells;

    return desc;
}

fn CollisionShapeDesc bench_hull_desc(GeometryId cone) @local {
    CollisionShapeDesc desc = physics::default_collision_shape_desc(physics::ColliderKind.HULL);
    desc.geometry = cone;

    return desc;
}

fn ColliderDesc bench_field_collider(BenchField* field) @local {
    ColliderDesc collider = physics::default_collider_desc(physics::ColliderKind.HEIGHT_FIELD);
    collider.local.scale = BENCH_FIELD_SCALE;
    collider.height_field = { .heights = field.heights, .count_x = field.points, .count_z = field.points };
    collider.material_indices = field.cells;
    collider.face_materials = (&field.surface)[:1];

    return collider;
}

fn double microseconds_since(time::Clock started) @local {
    return (double)(clock::now() - started) / NANOSECONDS_PER_MICROSECOND;
}

fn double median_of(double[BENCH_REPEATS] values) @local {
    double[BENCH_REPEATS] sorted = values;
    for (usz outer = 1; outer < BENCH_REPEATS; outer++) {
        for (usz inner = outer; inner > 0 && sorted[inner - 1] > sorted[inner]; inner--) {
            double swapped = sorted[inner];
            sorted[inner] = sorted[inner - 1];
            sorted[inner - 1] = swapped;
        }
    }

    return sorted[BENCH_REPEATS / 2];
}

fn uint occupied_entries(SnapshotTable* table) @local {
    uint entries;
    foreach (slot : table.slots) {
        if (slot.generation % 2 == 1) entries++;
    }

    return entries;
}

fn CacheRun? measure_caches(
    AssetStore* assets,
    GeometryId cone,
    BenchField* field,
    bool shared,
) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    CollisionCacheDesc cache_desc = physics::default_collision_cache_desc();
    CollisionCache query_cache = physics::create_collision_cache(&tracker, assets, cache_desc)!;
    defer physics::destroy_collision_cache(&query_cache)!!;
    Scene scene = scene::create_scene(&tracker, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!;
    PhysicsWorld world = physics::create_physics_world(
        allocator: &tracker,
        assets: assets,
        scene: &scene,
        desc: physics::default_physics_desc(),
        cache: shared ? &query_cache : null,
    )!;
    defer physics::destroy_physics_world(&world);
    Node* hull_node = scene.add_node(name: "hull")!;
    Node* field_node = scene.add_node(name: "field")!;
    scene.update_world();

    sz start_allocations = tracker.total_allocation_count();
    sz start_live = tracker.allocated();
    int start_native = b3::byte_count();
    time::Clock started = clock::now();
    CollisionShape hull_owner = physics::create_collision_shape(&tracker, &query_cache, bench_hull_desc(cone))!;
    defer physics::destroy_collision_shape(&hull_owner);
    CollisionShape field_owner = physics::create_collision_shape(&tracker, &query_cache, bench_field_desc(field))!;
    defer physics::destroy_collision_shape(&field_owner);
    CacheRun run = {
        .query_prepare_us = microseconds_since(started),
        .native_query_bytes = b3::byte_count() - start_native,
    };

    ColliderDesc hull_collider = physics::default_collider_desc(physics::ColliderKind.HULL);
    hull_collider.geometry = cone;
    int before_hull = b3::byte_count();
    started = clock::now();
    world.add_body(hull_node, physics::default_body_desc(STATIC), (&hull_collider)[:1])!;
    run.hull_body_us = microseconds_since(started);
    run.native_hull_body_bytes = b3::byte_count() - before_hull;

    ColliderDesc field_collider = bench_field_collider(field);
    int before_field = b3::byte_count();
    started = clock::now();
    world.add_body(field_node, physics::default_body_desc(STATIC), (&field_collider)[:1])!;
    run.field_body_us = microseconds_since(started);
    run.native_field_body_bytes = b3::byte_count() - before_field;

    SnapshotHandle body_entry = scene.get(field_node, RigidBody).colliders[0].snapshot;
    SnapshotTable* world_table = world.snapshots;
    run.shared_field_data = world_table.slots[body_entry.index].height_field == field_owner.state.height_field;
    run.entries = occupied_entries(query_cache.state);
    if (!shared) run.entries += occupied_entries(world_table);
    run.c3_allocations = tracker.total_allocation_count() - start_allocations;
    run.c3_live_bytes = tracker.allocated() - start_live;
    run.c3_peak_bytes = tracker.max_allocated();

    return run;
}

fn ReuseRun? measure_reuse(AssetStore* assets, CollisionShapeDesc desc) @local {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    CollisionCache cache = physics::create_collision_cache(&tracker, assets, physics::default_collision_cache_desc())!;
    defer physics::destroy_collision_cache(&cache)!!;

    sz before = tracker.total_allocation_count();
    time::Clock started = clock::now();
    CollisionShape first = physics::create_collision_shape(&tracker, &cache, desc)!;
    defer physics::destroy_collision_shape(&first);
    ReuseRun run = {
        .first_us = microseconds_since(started),
        .first_allocations = tracker.total_allocation_count() - before,
    };

    before = tracker.total_allocation_count();
    started = clock::now();
    for (uint repeat = 0; repeat < BENCH_REUSE_OWNERS; repeat++) {
        CollisionShape owner = physics::create_collision_shape(&tracker, &cache, desc)!;
        physics::destroy_collision_shape(&owner);
    }
    run.repeat_us = microseconds_since(started) / BENCH_REUSE_OWNERS;
    run.repeat_allocations = (tracker.total_allocation_count() - before) / BENCH_REUSE_OWNERS;

    return run;
}

fn void? run_cache_benchmark(AssetStore* assets, GeometryId cone, BenchField* field) @local {
    foreach (shared : (bool[2]){ false, true }) {
        String label = shared ? "shared" : "separate";
        CacheRun[BENCH_REPEATS] runs;
        foreach (index, &run : runs) {
            *run = measure_caches(
                assets: assets,
                cone: cone,
                field: field,
                shared: shared,
            )!;
            io::printfn(
                "cache,%s,run,%d,query_prepare_us,%.1f,hull_body_us,%.1f,field_body_us,%.1f,entries,%d,"
                "shared_field_data,%s,c3_allocations,%d,c3_live_bytes,%d,c3_peak_bytes,%d,"
                "native_query_bytes,%d,native_hull_body_bytes,%d,native_field_body_bytes,%d",
                label,
                index,
                run.query_prepare_us,
                run.hull_body_us,
                run.field_body_us,
                run.entries,
                run.shared_field_data ? "true" : "false",
                run.c3_allocations,
                run.c3_live_bytes,
                run.c3_peak_bytes,
                run.native_query_bytes,
                run.native_hull_body_bytes,
                run.native_field_body_bytes,
            );
        }

        double[BENCH_REPEATS] prepare;
        double[BENCH_REPEATS] hull_body;
        double[BENCH_REPEATS] field_body;
        foreach (index, run : runs) {
            prepare[index] = run.query_prepare_us;
            hull_body[index] = run.hull_body_us;
            field_body[index] = run.field_body_us;
        }
        io::printfn(
            "cache_median,%s,query_prepare_us,%.1f,hull_body_us,%.1f,field_body_us,%.1f",
            label,
            median_of(prepare),
            median_of(hull_body),
            median_of(field_body),
        );
    }
}

fn void? run_reuse_benchmark(AssetStore* assets, GeometryId cone, BenchField* field) @local {
    String[2] labels = { "hull", "field" };
    CollisionShapeDesc[2] descriptions = { bench_hull_desc(cone), bench_field_desc(field) };
    foreach (kind, label : labels) {
        double[BENCH_REPEATS] first;
        double[BENCH_REPEATS] repeat;
        foreach (index, &slot : first) {
            ReuseRun run = measure_reuse(assets, descriptions[kind])!;
            *slot = run.first_us;
            repeat[index] = run.repeat_us;
            io::printfn(
                "reuse,%s,run,%d,first_us,%.1f,repeat_us,%.3f,first_c3_allocations,%d,repeat_c3_allocations,%d",
                label,
                index,
                run.first_us,
                run.repeat_us,
                run.first_allocations,
                run.repeat_allocations,
            );
        }
        io::printfn("reuse_median,%s,first_us,%.1f,repeat_us,%.3f", label, median_of(first), median_of(repeat));
    }
}

fn float? run_bench_query(BenchRig* rig, BenchQuery query, maths::Transform probe) @local {
    switch (query) {
        case CONTACTS:
            return (float)rig.surface.view().contacts(
                pose_a: rig.surface_pose,
                other: rig.probe.view(),
                pose_b: probe,
                output: rig.contacts[..],
            )!;
        case DISTANCE:
            return rig.probe.view().distance(probe, rig.surface.view(), rig.surface_pose)!.distance;
        case CAST:
            collide::Impact? hit = rig.probe.view().cast(
                pose_a: probe,
                other: rig.surface.view(),
                pose_b: rig.surface_pose,
                translation_a: { 0, -BENCH_CAST_DISTANCE, 0 },
                translation_b: {},
            );
            if (catch excuse = hit) {
                if (excuse == b3::NO_HIT) return -1;
                return excuse~;
            }
            return hit.time;
    }
}

fn double? measure_bench_query(
    BenchRig* rig,
    BenchQuery query,
    maths::Transform probe,
    uint warmup_calls,
    uint timed_calls,
    float* last_result,
) @local {
    for (uint call = 0; call < warmup_calls; call++) run_bench_query(rig, query, probe)!;

    time::Clock started = clock::now();
    for (uint call = 0; call < timed_calls; call++) *last_result = run_bench_query(rig, query, probe)!;

    return (double)(clock::now() - started) / timed_calls;
}

fn BenchRig? create_bench_rig(CollisionCache* cache, GeometryId cone, BenchField* field) @local {
    BenchRig rig = {
        .cache = cache,
        .surface_pose = { .position = {}, .rotation = { 0, 0, 0, 1 }, .scale = { 1, 1, 1 } },
    };
    rig.surface = physics::create_collision_shape(mem, cache, bench_field_desc(field))!;
    defer catch physics::destroy_collision_shape(&rig.surface);
    rig.probe = physics::create_collision_shape(mem, cache, bench_hull_desc(cone))!;
    defer catch physics::destroy_collision_shape(&rig.probe);

    float stand_x = BENCH_PROBE_POSITION * (float)(field.points - 1) * BENCH_FIELD_SCALE.x;
    float stand_z = BENCH_PROBE_POSITION * (float)(field.points - 1) * BENCH_FIELD_SCALE.z;
    collide::ShapeRayHit ground = rig.surface.view().ray_cast(
        pose: rig.surface_pose,
        origin: { stand_x, BENCH_RAY_HEIGHT, stand_z },
        direction: { 0, -1, 0 },
        max_distance: 2 * BENCH_RAY_HEIGHT,
    )!;
    float base = rig.probe.state.bounds.min.y;
    Vec3 standing = { stand_x, ground.point.y - base, stand_z };
    rig.separated = rig.surface_pose;
    rig.separated.position = standing + (Vec3){ 0, BENCH_SEPARATED_GAP, 0 };
    rig.near_surface = rig.surface_pose;
    rig.near_surface.position = standing - (Vec3){ 0, BENCH_NEAR_OVERLAP, 0 };

    return rig;
}

fn void destroy_bench_rig(BenchRig* rig) @local {
    physics::destroy_collision_shape(&rig.probe);
    physics::destroy_collision_shape(&rig.surface);
}

fn void? run_query_benchmark(
    CollisionCache* cache,
    GeometryId cone,
    BenchField* field,
    String name,
    uint warmup_calls,
    uint timed_calls,
    BenchQuery[] queries,
) @local {
    BenchRig rig = create_bench_rig(cache, cone, field)!;
    defer destroy_bench_rig(&rig);

    io::printfn(
        "fixture,%s,grid_points,%d,grid_cells,%d,triangles,%d,scale,%.3f,%.3f,%.3f,hull_vertices,%d,"
        "warmup_calls,%d,timed_calls,%d",
        name,
        field.points,
        field.points - 1,
        2 * (field.points - 1) * (field.points - 1),
        (double)BENCH_FIELD_SCALE.x,
        (double)BENCH_FIELD_SCALE.y,
        (double)BENCH_FIELD_SCALE.z,
        rig.probe.state.shape.hull.vertex_count,
        warmup_calls,
        timed_calls,
    );
    BenchPlacement[2] placements = { SEPARATED, NEAR_SURFACE };
    foreach (query : queries) {
        foreach (placement : placements) {
            maths::Transform probe = placement == SEPARATED ? rig.separated : rig.near_surface;
            double[BENCH_REPEATS] nanoseconds;
            float result;
            foreach (index, &slot : nanoseconds) {
                *slot = measure_bench_query(
                    rig: &rig,
                    query: query,
                    probe: probe,
                    warmup_calls: warmup_calls,
                    timed_calls: timed_calls,
                    last_result: &result,
                )!;
                io::printfn(
                    "query,%s,%s,%s,run,%d,ns_per_call,%.0f,result,%.4f",
                    name,
                    query,
                    placement,
                    index,
                    *slot,
                    (double)result,
                );
            }
            io::printfn("query_median,%s,%s,%s,ns_per_call,%.0f", name, query, placement, median_of(nanoseconds));
        }
    }
}

fn void? run_benchmark(AssetStore* assets, GeometryId cone) @private {
    BenchField field = make_bench_field(BENCH_FIELD_POINTS);
    defer destroy_bench_field(&field);
    BenchField large = make_bench_field(BENCH_FULL_SURFACE_POINTS);
    defer destroy_bench_field(&large);

    io::printfn("benchmark,length_units_per_meter,%.3f", (double)b3::length_units_per_meter());
    run_cache_benchmark(assets, cone, &field)!;
    run_reuse_benchmark(assets, cone, &field)!;

    CollisionCache cache = physics::create_collision_cache(mem, assets, physics::default_collision_cache_desc())!;
    defer physics::destroy_collision_cache(&cache)!!;
    BenchQuery[3] all_queries = { CONTACTS, DISTANCE, CAST };
    BenchQuery[1] distance_only = { DISTANCE };
    run_query_benchmark(
        cache: &cache,
        cone: cone,
        field: &field,
        name: "query_cost",
        warmup_calls: BENCH_WARMUP_CALLS,
        timed_calls: BENCH_TIMED_CALLS,
        queries: all_queries[..],
    )!;
    run_query_benchmark(
        cache: &cache,
        cone: cone,
        field: &large,
        name: "full_surface_distance",
        warmup_calls: BENCH_FULL_SURFACE_WARMUP_CALLS,
        timed_calls: BENCH_FULL_SURFACE_TIMED_CALLS,
        queries: distance_only[..],
    )!;
}
