module cpu_bench_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::render;
import c3d::scene;
import c3d::spatial::bvh;
import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;

const uint WARMUP_BATCHES @local = 5; // populate temporary allocator pages before collecting samples
const uint MAX_NODES @local = 65536; // bounds command-line allocation without changing library capacities
const double NANOSECONDS_PER_MICROSECOND @local = 1000;
const float BOX_FIELD_SIZE @local = 100; // metres of the cube the bvh_top boxes scatter in
const float PLANE_SIZE @local = 100;
const BvhBuildDesc TOP_LEVEL_BUILD @local = { .bins = 12, .leaf_size = 1 }; // the renderer's top-level settings

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
}

struct BvhInput @local {
    Vec3[] positions;
    uint[] indices;
    Aabb[] boxes;
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
        default: return c3d::INVALID_ARGUMENT~;
    }
}

fn double run_iteration(
    Work work,
    Scene* scene,
    AssetStore* assets,
    CameraMatrices* matrices,
    BvhInput* bvh_input,
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
    }
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
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = nodes });
    defer scene::destroy_scene(&scene);
    GeometryId box;
    @pool() {
        Geometry geometry = geometry::box(allocator: tmem, width: 1, height: 1, depth: 1);
        box = assets.add_geometry(&geometry)!;
    };
    MaterialId material = assets.add_material(material::standard(material::STANDARD_PARAMS_DEFAULT))!;
    bool builds_bvh = work == BVH_TRIANGLES || work == BVH_TOP;
    for (uint index = 0; index < nodes && !builds_bvh; index++) {
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
    scene.update_world();
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
                );
            }
            double elapsed = (double)(clock::now() - started) / NANOSECONDS_PER_MICROSECOND / iterations;
            if (batch >= WARMUP_BATCHES) {
                samples[batch - WARMUP_BATCHES] = { .microseconds = elapsed, .checksum = checksum };
            }
        }
    };
    io::printn("case,nodes,batch,iterations,us_per_iteration,checksum");
    foreach (index, sample : samples) {
        io::printfn("%s,%d,%d,%d,%.6f,%.3f", name, nodes, index, iterations, sample.microseconds, sample.checksum);
    }
}

<* Measure scene traversal and CPU extraction without creating a GPU device. *>
fn int main(String[] args) {
    if (args.len < 2 || args.len > 5) {
        io::eprintn("Usage: cpu_bench CASE [nodes=4096] [iterations=100] [samples=30]");
        io::eprintn("Cases: world hidden_world meshes culled_meshes hidden_meshes shadows lights hidden_lights sort");
        io::eprintn("       bvh_triangles (nodes = plane segments per side) bvh_top (nodes = boxes)");
        return 1;
    }
    uint nodes = args.len > 2 ? (args[2].to_uint() ?? 0) : 4096;
    uint iterations = args.len > 3 ? (args[3].to_uint() ?? 0) : 100;
    uint samples = args.len > 4 ? (args[4].to_uint() ?? 0) : 30;
    if (!nodes || nodes > MAX_NODES || !iterations || iterations > 100000 || !samples || samples > 10000) {
        io::eprintn("Expected nodes 1..65536, iterations 1..100000, samples 1..10000.");
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
