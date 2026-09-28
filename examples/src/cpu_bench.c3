module cpu_bench_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render;
import c3d::scene;
import c3d::spatial;
import c3d::spatial::bvh;
import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;

const uint WARMUP_BATCHES @local = 5; // populate temporary allocator pages before collecting samples
const uint MAX_NODES @local = 65536; // bounds command-line allocation without changing library capacities
const uint DEFAULT_NODES @local = 4096;
const uint DEFAULT_PLANE_SEGMENTS @local = 128; // 32,768 triangles: the default run stays under a minute in a debug build
const uint MAX_PLANE_SEGMENTS @local = 1024; // 2.1 million triangles; bounds the temporary memory of one build
const double NANOSECONDS_PER_MICROSECOND @local = 1000;
const float BOX_FIELD_SIZE @local = 100; // metres of the cube the bvh_top boxes scatter in
const float PLANE_SIZE @local = 100;
const BvhBuildDesc TOP_LEVEL_BUILD @local = { .bins = 12, .leaf_size = 1 }; // the renderer's top-level settings
const uint CROWD_MESHES @local = 2000;
const uint CROWD_INSTANCES @local = 4096;
const uint BATCH_INSTANCES @local = 65536;
const uint CROWD_ROW @local = 50; // meshes per grid row
const float GRID_SPACING @local = 2;
const float INSTANCE_SPACING @local = 1.5f;
const float INSTANCE_HEIGHT @local = 5; // the crowd's batch floats above its meshes
const uint PICK_RAYS @local = 64;
const uint PICK_SEED @local = 0x2545f491;
const float RAY_FIELD @local = 60; // rays start this far out on x and z and aim within the grid
const float RAY_HEIGHT @local = 25;

enum Work @local {
    WORLD,
    HIDDEN_WORLD,
    MESHES,
    CULLED_MESHES,
    HIDDEN_MESHES,
    SHADOWS,
    LIGHTS,
    HIDDEN_LIGHTS,
    SORT,
    BVH_TRIANGLES,
    BVH_TOP,
    INDEX_REFRESH_CROWD,
    INDEX_REFRESH_BATCH,
    INDEX_BUILD_CROWD,
    INDEX_BUILD_BATCH,
    INDEX_PICK_CROWD,
    SCAN_PICK_CROWD,
    INDEX_PICK_TRIANGLES,
    SCAN_PICK_TRIANGLES,
    TRIANGLE_WARMUP,
}

enum IndexScene @local {
    NONE,
    CROWD,
    BATCH,
    PLANE,
}

struct BvhInput @local {
    Vec3[] positions;
    uint[] indices;
    Aabb[] boxes;
}

struct IndexInput @local {
    SceneIndex index;
    Ray[]      rays;
    GeometryId plane;
}

struct Sample @local {
    double microseconds;
    double checksum;
}

fn Work? parse_work(String name) @local {
    switch (name) {
        case "world": return WORLD;
        case "hidden_world": return HIDDEN_WORLD;
        case "meshes": return MESHES;
        case "culled_meshes": return CULLED_MESHES;
        case "hidden_meshes": return HIDDEN_MESHES;
        case "shadows": return SHADOWS;
        case "lights": return LIGHTS;
        case "hidden_lights": return HIDDEN_LIGHTS;
        case "sort": return SORT;
        case "bvh_triangles": return BVH_TRIANGLES;
        case "bvh_top": return BVH_TOP;
        case "index_refresh_crowd": return INDEX_REFRESH_CROWD;
        case "index_refresh_batch": return INDEX_REFRESH_BATCH;
        case "index_build_crowd": return INDEX_BUILD_CROWD;
        case "index_build_batch": return INDEX_BUILD_BATCH;
        case "index_pick_crowd": return INDEX_PICK_CROWD;
        case "scan_pick_crowd": return SCAN_PICK_CROWD;
        case "index_pick_triangles": return INDEX_PICK_TRIANGLES;
        case "scan_pick_triangles": return SCAN_PICK_TRIANGLES;
        case "triangle_warmup": return TRIANGLE_WARMUP;
        default: return c3d::INVALID_ARGUMENT~;
    }
}

fn double run_iteration(
    Work work,
    Scene* scene,
    AssetStore* assets,
    CameraMatrices* matrices,
    BvhInput* bvh_input,
    IndexInput* index_input,
) @local @noinline {
    switch (work) {
        case WORLD:
        case HIDDEN_WORLD:
            scene.update_world();
            return scene.root.first_child.world.m03;
        case MESHES:
        case CULLED_MESHES:
        case HIDDEN_MESHES:
        case SORT:
            @pool() {
                ExtractCounts counts;
                MeshCandidate[] candidates = render::extract_candidates(
                    allocator: tmem,
                    scene: scene,
                    assets: assets,
                    camera: matrices,
                    layers: camera::ALL_LAYERS,
                    counts: &counts,
                );
                if (work == SORT) sort::quicksort(candidates, &render::compare_transparent_candidates);
                return (double)counts.visible + counts.culled
                    + (candidates.len ? (double)candidates[0].view_depth : 0);
            };
        case SHADOWS:
            @pool() {
                ExtractCounts counts;
                MeshCandidate[] candidates = render::extract_shadow_candidates(
                    allocator: tmem,
                    scene: scene,
                    assets: assets,
                    counts: &counts,
                );
                return (double)candidates.len + (candidates.len ? (double)candidates[0].world_bounds.min.x : 0);
            };
        case LIGHTS:
        case HIDDEN_LIGHTS:
            @pool() {
                LightCounts counts;
                LightExtraction extracted = render::extract_lights(
                    allocator: tmem,
                    scene: scene,
                    frustum: &matrices.frustum,
                    view_layers: camera::ALL_LAYERS,
                    capacity: scene.count(Light),
                    counts: &counts,
                );
                return (double)counts.packed + counts.culled
                    + (extracted.lights.len ? (double)extracted.lights[0].position_range.x : 0);
            };
        case BVH_TRIANGLES:
            @pool() {
                Bvh tree = bvh::build_triangle_bvh(tmem, bvh_input.positions, bvh_input.indices)!!;
                return (double)tree.nodes.len;
            };
        case BVH_TOP:
            @pool() {
                Bvh tree = bvh::build_box_bvh(tmem, bvh_input.boxes, TOP_LEVEL_BUILD)!!;
                return (double)tree.nodes.len;
            };
        case INDEX_REFRESH_CROWD:
        case INDEX_REFRESH_BATCH:
            index_input.index.refresh(assets, scene)!!;
            return (double)index_input.index.count + index_input.index.revision;
        case INDEX_BUILD_CROWD:
        case INDEX_BUILD_BATCH:
            // A cleared tree revision makes the next pick rebuild the tree over unchanged entries.
            index_input.index.tree_revision = 0;
            @pool() {
                return (double)index_input.index.pick(tmem, assets, index_input.rays[0]).len;
            };
        case INDEX_PICK_CROWD:
        case SCAN_PICK_CROWD:
        case INDEX_PICK_TRIANGLES:
        case SCAN_PICK_TRIANGLES:
            return pick_checksum(
                work:        work,
                scene:       scene,
                assets:      assets,
                index_input: index_input,
            );
        case TRIANGLE_WARMUP:
            assets.mark_geometry_dirty(index_input.plane);
            spatial::prepare_triangle_picks(assets, scene);
            return (double)assets.geometry(index_input.plane).triangles.nodes.len;
    }
}

fn double pick_checksum(
    Work work,
    Scene* scene,
    AssetStore* assets,
    IndexInput* index_input,
) @local {
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    if (work == INDEX_PICK_TRIANGLES || work == SCAN_PICK_TRIANGLES) options.precision = PickPrecision.TRIANGLES;
    bool indexed = work == INDEX_PICK_CROWD || work == INDEX_PICK_TRIANGLES;
    double checksum;
    foreach (ray : index_input.rays) {
        @pool() {
            PickHit[] hits;
            if (indexed) {
                hits = index_input.index.pick(
                    allocator: tmem,
                    assets:    assets,
                    ray:       ray,
                    options:   options,
                );
            } else {
                hits = spatial::pick(
                    allocator: tmem,
                    assets:    assets,
                    scene:     scene,
                    ray:       ray,
                    options:   options,
                );
            }
            checksum += hits.len;
            if (hits.len) checksum += (double)hits[0].node.id.index + hits[0].instance_index;
        };
    }
    return checksum;
}

fn IndexScene index_scene_of(Work work) @local {
    switch (work) {
        case INDEX_REFRESH_CROWD:
        case INDEX_BUILD_CROWD:
        case INDEX_PICK_CROWD:
        case SCAN_PICK_CROWD:
        case INDEX_PICK_TRIANGLES:
        case SCAN_PICK_TRIANGLES:
            return CROWD;
        case INDEX_REFRESH_BATCH:
        case INDEX_BUILD_BATCH:
            return BATCH;
        case TRIANGLE_WARMUP:
            return PLANE;
        default:
            return NONE;
    }
}

fn bool holds_index(IndexScene index_scene) @local {
    return index_scene == IndexScene.CROWD || index_scene == IndexScene.BATCH;
}

fn void? add_crowd_scene(Scene* scene, GeometryId box, MaterialId material) @local {
    for (uint index = 0; index < CROWD_MESHES; index++) {
        Node* node = scene.add_mesh(box, material)!;
        node.local.position = {
            (float)(index % CROWD_ROW) * GRID_SPACING - CROWD_ROW,
            0,
            (float)(index / CROWD_ROW) * GRID_SPACING - CROWD_MESHES / CROWD_ROW,
        };
    }
    add_grid_batch(
        scene:    scene,
        box:      box,
        material: material,
        count:    CROWD_INSTANCES,
        height:   INSTANCE_HEIGHT,
    )!;
}

fn void? add_grid_batch(
    Scene* scene,
    GeometryId box,
    MaterialId material,
    uint count,
    float height,
) @local {
    uint side = (uint)math::sqrt((float)count);
    float half_extent = (float)side * INSTANCE_SPACING / 2;
    @pool() {
        Transform[] transforms = alloc::new_array(tmem, Transform, (sz)count);
        foreach (uint index, &transform : transforms) {
            *transform = maths::TRANSFORM_IDENTITY;
            transform.position = {
                (float)(index % side) * INSTANCE_SPACING - half_extent,
                height,
                (float)(index / side) * INSTANCE_SPACING - half_extent,
            };
        }
        scene.add_instanced_mesh(
            geometry:   box,
            material:   material,
            capacity:   count,
            transforms: transforms,
        )!;
    };
}

fn float next_unit(uint* state) @local {
    *state ^= *state << 13;
    *state ^= *state >> 17;
    *state ^= *state << 5;
    return (float)(*state >> 8) / (float)(1u << 24);
}

fn Ray[] pick_rays(Allocator allocator) @local {
    Ray[] rays = alloc::new_array(allocator, Ray, (sz)PICK_RAYS);
    uint state = PICK_SEED;
    foreach (&ray : rays) {
        Vec3 origin = { (next_unit(&state) * 2 - 1) * RAY_FIELD, RAY_HEIGHT, (next_unit(&state) * 2 - 1) * RAY_FIELD };
        Vec3 target = { (next_unit(&state) * 2 - 1) * CROWD_ROW, 0, (next_unit(&state) * 2 - 1) * CROWD_ROW };
        *ray = { .origin = origin, .direction = (target - origin).normalize() };
    }
    return rays;
}

fn Aabb[] scattered_boxes(Allocator allocator, uint count) @local {
    Aabb[] boxes = alloc::alloc_array(allocator, Aabb, count);
    uint state = 0x9e3779b9;
    foreach (&box : boxes) {
        Vec3 center;
        for (usz axis = 0; axis < 3; axis++) {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            center[axis] = (float)(state >> 8) / (float)(1u << 24) * BOX_FIELD_SIZE;
        }
        *box = { .min = center - 0.5f, .max = center + 0.5f };
    }
    return boxes;
}

fn void? benchmark(
    String name,
    uint nodes,
    uint iterations,
    uint sample_count,
) @local {
    Work work = parse_work(name)!;
    IndexScene index_scene = index_scene_of(work);
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    // An index scene holds the crowd's meshes, its batch node and the root.
    uint max_nodes = index_scene == IndexScene.NONE ? nodes : CROWD_MESHES + 2;
    Scene scene = scene::create_scene(mem, { .max_nodes = max_nodes });
    defer scene::destroy_scene(&scene);
    GeometryId box;
    @pool() {
        Geometry geometry = geometry::box(allocator: tmem, width: 1, height: 1, depth: 1);
        box = assets.add_geometry(&geometry)!;
    };
    MaterialId material = assets.add_material(material::standard(material::STANDARD_PARAMS_DEFAULT))!;
    bool builds_bvh = work == BVH_TRIANGLES || work == BVH_TOP;
    IndexInput index_input;
    defer if (holds_index(index_scene)) spatial::destroy_scene_index(&index_input.index);
    defer alloc::free(mem, index_input.rays.ptr);
    switch (index_scene) {
        case CROWD:
            add_crowd_scene(&scene, box, material)!;
            index_input.index = spatial::create_scene_index(mem, CROWD_MESHES + CROWD_INSTANCES);
        case BATCH:
            add_grid_batch(
                scene:    &scene,
                box:      box,
                material: material,
                count:    BATCH_INSTANCES,
                height:   0,
            )!;
            index_input.index = spatial::create_scene_index(mem, BATCH_INSTANCES);
        case PLANE:
            @pool() {
                Geometry plane = geometry::plane(tmem, PLANE_SIZE, PLANE_SIZE, nodes, nodes);
                index_input.plane = assets.add_geometry(&plane)!;
            };
            scene.add_mesh(index_input.plane, material)!;
        case NONE:
    }
    if (!builds_bvh && index_scene == IndexScene.NONE) {
        for (uint index = 0; index < nodes; index++) {
            Node* node;
            if (work == LIGHTS || work == HIDDEN_LIGHTS) {
                node = scene.add_light(light::point({ 1, 1, 1 }, 8, 6))!;
            } else {
                node = scene.add_mesh(box, material)!;
            }
            node.local.position = {
                (float)(index % 64) - 32 + (work == CULLED_MESHES ? 1000 : 0),
                (float)(index / 64 % 32) - 16,
                -(float)(index % 127) - 1,
            };
            node.visible = work != HIDDEN_WORLD && work != HIDDEN_MESHES && work != HIDDEN_LIGHTS;
        }
    }
    scene.update_world();
    if (holds_index(index_scene)) {
        index_input.index.refresh(&assets, &scene)!;
        index_input.rays = pick_rays(mem);
        spatial::prepare_triangle_picks(&assets, &scene);
    }
    CameraMatrices matrices = camera::derive_matrices(
        camera::orthographic(256, 0.1f, 300), matrix::IDENTITY4, { 1440, 900 });
    Sample[] samples = alloc::new_array(mem, Sample, sample_count);
    defer alloc::free(mem, samples.ptr);
    double checksum;
    @pool() {
        BvhInput bvh_input;
        if (work == BVH_TRIANGLES) {
            Geometry plane = geometry::plane(tmem, PLANE_SIZE, PLANE_SIZE, nodes, nodes);
            bvh_input = { .positions = plane.positions, .indices = plane.indices };
        }
        if (work == BVH_TOP) bvh_input.boxes = scattered_boxes(tmem, nodes);
        for (uint batch = 0; batch < WARMUP_BATCHES + sample_count; batch++) {
            time::Clock started = clock::now();
            for (uint iteration = 0; iteration < iterations; iteration++) {
                checksum += run_iteration(
                    work: work,
                    scene: &scene,
                    assets: &assets,
                    matrices: &matrices,
                    bvh_input: &bvh_input,
                    index_input: &index_input,
                );
            }
            double elapsed = (double)(clock::now() - started) / NANOSECONDS_PER_MICROSECOND / iterations;
            if (batch >= WARMUP_BATCHES) {
                samples[batch - WARMUP_BATCHES] = { .microseconds = elapsed, .checksum = checksum };
            }
        }
    };
    uint reported = holds_index(index_scene) ? index_input.index.count : nodes;
    io::printn("case,nodes,batch,iterations,us_per_iteration,checksum");
    foreach (index, sample : samples) {
        io::printfn("%s,%d,%d,%d,%.6f,%.3f", name, reported, index, iterations, sample.microseconds, sample.checksum);
    }
    if (index_scene == IndexScene.PLANE) {
        Bvh* tree = &assets.geometry(index_input.plane).triangles;
        io::printfn("# triangle tree bytes: %d", tree.nodes.len * BvhNode::size + tree.primitives.len * uint::size);
    }
}

<* Measure scene traversal and CPU extraction without creating a GPU device. *>
fn int main(String[] args) {
    if (args.len < 2 || args.len > 5) {
        io::eprintn("Usage: cpu_bench CASE [nodes=4096] [iterations=100] [samples=30]");
        io::eprintn("Cases: world hidden_world meshes culled_meshes hidden_meshes shadows lights hidden_lights sort");
        io::eprintn("       bvh_triangles (nodes = plane segments per side, 128 by default, at most 1024)");
        io::eprintn("       bvh_top (nodes = boxes)");
        io::eprintn("       index_refresh_crowd index_refresh_batch index_build_crowd index_build_batch index_pick_crowd");
        io::eprintn("       scan_pick_crowd index_pick_triangles scan_pick_triangles (nodes ignored)");
        io::eprintn("       triangle_warmup (nodes = plane segments per side, as bvh_triangles)");
        return 1;
    }
    bool plane_case = args[1] == "bvh_triangles" || args[1] == "triangle_warmup";
    uint nodes = args.len > 2 ? (args[2].to_uint() ?? 0) : (plane_case ? DEFAULT_PLANE_SEGMENTS : DEFAULT_NODES);
    uint iterations = args.len > 3 ? (args[3].to_uint() ?? 0) : 100;
    uint samples = args.len > 4 ? (args[4].to_uint() ?? 0) : 30;
    if (!nodes || nodes > MAX_NODES || !iterations || iterations > 100000 || !samples || samples > 10000) {
        io::eprintn("Expected nodes 1..65536, iterations 1..100000, samples 1..10000.");
        return 1;
    }
    if (plane_case && nodes > MAX_PLANE_SEGMENTS) {
        io::eprintn("bvh_triangles and triangle_warmup take 1..1024 plane segments per side.");
        return 1;
    }
    if (catch excuse = benchmark(
        name: args[1],
        nodes: nodes,
        iterations: iterations,
        sample_count: samples,
    )) {
        io::eprintfn("CPU benchmark failed: %s", excuse);
        return 1;
    }
    return 0;
}
