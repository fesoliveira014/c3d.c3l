module nav_persistence;

import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;
import c3d;
import c3d::nav;

const usz SCRATCH_BYTES @local = 32768;
const usz STAGED_BYTES @local = 8 * 1024 * 1024;
const usz SAMPLE_COUNT @local = 101; // A bounded median reduces timer noise.
const usz WARMUP_COUNT @local = 8; // Keep first-use work outside the timing samples.
const double NANOSECONDS_PER_MICROSECOND @local = 1000;
const usz MAX_TRACKED_ALLOCATIONS @local = 32;

struct TrackedAllocation @local {
    void* pointer;
    usz bytes;
}

struct AllocationCounter (Allocator) @local {
    Allocator backing;
    TrackedAllocation[MAX_TRACKED_ALLOCATIONS] entries;
    usz live_bytes;
    usz peak_bytes;
}

fn void*? AllocationCounter.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    foreach (&entry : self.entries) {
        if (entry.pointer) continue;
        void* pointer = self.backing.acquire(size, init_type, alignment)!;
        *entry = { .pointer = pointer, .bytes = (usz)size };
        self.live_bytes += (usz)size;
        self.peak_bytes = math::max(self.peak_bytes, self.live_bytes);
        return pointer;
    }
    return mem::OUT_OF_MEMORY~;
}

fn void*? AllocationCounter.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    return mem::OUT_OF_MEMORY~;
}

fn void AllocationCounter.release(&self, void* pointer, bool aligned) @dynamic {
    foreach (&entry : self.entries) {
        if (entry.pointer != pointer) continue;
        self.live_bytes -= entry.bytes;
        *entry = {};
        self.backing.release(pointer, aligned);
        return;
    }
    unreachable();
}

fn int main(String[] args) {
    bool measure = args.len == 2 && args[1] == "--measure";
    if (args.len > 1 && !measure) {
        io::printn("Usage: nav_persistence [--measure]");
        return 1;
    }

    if (catch excuse = run_example(measure)) {
        io::printfn("Navigation snapshot failed: %s", excuse);
        return 1;
    }
    if (measure) {
        if (catch excuse = measure_memory()) {
            io::printfn("Navigation memory measurement failed: %s", excuse);
            return 1;
        }
    }
    return 0;
}

fn void? run_example(bool measure) @local {
    NavMesh mesh = create_example_mesh(mem)!;
    defer nav::destroy_nav_mesh(&mesh);

    char[]? snapshot = alloc::new_array_try(mem, char, (sz)mesh.snapshot_size()!);
    if (catch snapshot) return c3d::CAPACITY_EXCEEDED~;
    defer free(snapshot);

    char[]? scratch = alloc::new_array_try(mem, char, SCRATCH_BYTES);
    if (catch scratch) return c3d::CAPACITY_EXCEEDED~;
    defer free(scratch);

    NavSnapshotLimits limits = { .max_blob_bytes = snapshot.len, .max_staged_bytes = STAGED_BYTES };
    PolyRef original = mesh.poly_ref_base(mesh.tile_at(0, 0, 0));
    NavPolyKey key = mesh.poly_key(original)!;

    (void)mesh.write_snapshot(snapshot, scratch)!;
    mesh.read_snapshot(snapshot, scratch, limits)!;
    PolyRef restored = mesh.resolve_poly_key(key)!;
    io::printfn("Snapshot: %d bytes; 4 tiles, 2 layers, 1 off-mesh connection.", snapshot.len);
    io::printfn("Previous reference valid: %s. Restored polygon flags: %d.", mesh.is_valid_ref(original), mesh.poly_flags(restored)!);
    show_path(&mesh)!;
    if (!measure) return;

    double[SAMPLE_COUNT] write_samples;
    double[SAMPLE_COUNT] read_samples;
    for (usz sample = 0; sample < WARMUP_COUNT + SAMPLE_COUNT; sample++) {
        time::Clock started = clock::now();
        (void)mesh.write_snapshot(snapshot, scratch)!;
        double written = (double)(clock::now() - started) / NANOSECONDS_PER_MICROSECOND;

        started = clock::now();
        mesh.read_snapshot(snapshot, scratch, limits)!;
        double read = (double)(clock::now() - started) / NANOSECONDS_PER_MICROSECOND;
        if (sample >= WARMUP_COUNT) {
            write_samples[sample - WARMUP_COUNT] = written;
            read_samples[sample - WARMUP_COUNT] = read;
        }
    }

    sort::quicksort(write_samples[..]);
    sort::quicksort(read_samples[..]);
    io::printfn("Warmup: %d; samples: %d.", WARMUP_COUNT, SAMPLE_COUNT);
    io::printfn("Median save: %.3f us; median replace: %.3f us.",
        write_samples[SAMPLE_COUNT / 2], read_samples[SAMPLE_COUNT / 2]);
}

fn void? show_path(NavMesh* mesh) @local {
    NavQuery query = nav::create_nav_query(mem, mesh, 64)!;
    defer nav::destroy_nav_query(&query);

    QueryFilter filter = nav::default_query_filter();
    NearestPoly start = query.find_nearest_poly({ 0.5f, 0, 1 }, { 0.1f, 1, 0.1f }, &filter)!;
    NearestPoly end = query.find_nearest_poly({ 5.5f, 0, 1 }, { 0.1f, 1, 0.1f }, &filter)!;

    PolyRef[8] path;
    PathResult result = query.find_path(
        start_ref: start.ref,
        end_ref: end.ref,
        start: start.point,
        end: end.point,
        filter: &filter,
        out_path: path[..],
    )!;
    io::printfn("Restored path: %d polygons; partial: %s.", result.count, result.partial);
    io::printfn("Restored start height: %.3f.", query.poly_height(start.ref, start.point)!);
}

fn void? measure_memory() @local {
    AllocationCounter counter = { .backing = mem };
    NavMesh mesh = create_example_mesh(&counter)!;
    defer nav::destroy_nav_mesh(&mesh);

    char[]? snapshot = alloc::new_array_try(mem, char, (sz)mesh.snapshot_size()!);
    if (catch snapshot) return c3d::CAPACITY_EXCEEDED~;
    defer free(snapshot);

    char[]? scratch = alloc::new_array_try(mem, char, SCRATCH_BYTES);
    if (catch scratch) return c3d::CAPACITY_EXCEEDED~;
    defer free(scratch);

    NavSnapshotLimits limits = { .max_blob_bytes = snapshot.len, .max_staged_bytes = STAGED_BYTES };
    (void)mesh.write_snapshot(snapshot, scratch)!;

    usz old_bytes = counter.live_bytes;
    counter.peak_bytes = old_bytes;
    mesh.read_snapshot(snapshot, scratch, limits)!;
    usz staged_bytes = counter.peak_bytes - old_bytes;
    usz mesh_peak = counter.peak_bytes;

    usz read_scratch = minimum_scratch(
        mesh: &mesh,
        snapshot: snapshot,
        scratch: scratch,
        read: true,
    )!;
    usz write_scratch = minimum_scratch(
        mesh: &mesh,
        snapshot: snapshot,
        scratch: scratch,
        read: false,
    )!;

    io::printfn("Old live: %d bytes; staged: %d bytes.", old_bytes, staged_bytes);
    io::printfn("Resident after replace: %d bytes.", counter.live_bytes);
    io::printfn("Input/output shared buffer: %d bytes; scratch reserved: %d bytes.",
        snapshot.len, scratch.len);
    io::printfn("Minimum successful scratch: save %d bytes; replace %d bytes.", write_scratch, read_scratch);
    io::printfn("Concurrent requested bytes: reserved peak %d; used peak %d.",
        mesh_peak + snapshot.len + scratch.len, mesh_peak + snapshot.len + read_scratch);
    io::printn("Byte counts exclude allocator bookkeeping, stack and executable storage; timings use the ordinary allocator.");
}

fn usz? minimum_scratch(
    NavMesh* mesh,
    char[] snapshot,
    char[] scratch,
    bool read,
) @local {
    usz lower;
    usz upper = scratch.len;
    NavSnapshotLimits limits = { .max_blob_bytes = snapshot.len, .max_staged_bytes = STAGED_BYTES };
    while (lower < upper) {
        usz candidate = lower + (upper - lower) / 2;
        fault excuse = read
            ? @catch(mesh.read_snapshot(snapshot, scratch[:candidate], limits))
            : @catch(mesh.write_snapshot(snapshot, scratch[:candidate]));
        if (!excuse) {
            upper = candidate;
        } else if (excuse == c3d::CAPACITY_EXCEEDED) {
            lower = candidate + 1;
        } else {
            return excuse~;
        }
    }
    return lower;
}

fn NavMesh? create_example_mesh(Allocator allocator) @local {
    NavMesh mesh = nav::create_nav_mesh(allocator, {
        .tile_width = 2,
        .tile_height = 2,
        .max_tiles = 8,
        .max_links = 128,
    })!;
    defer catch nav::destroy_nav_mesh(&mesh);

    int[4] coordinates = { 0, 0, 1, 2 };
    int[4] layers = { 0, 1, 0, 0 };
    foreach (index, x : coordinates) {
        int layer = layers[index];
        char[] built = example_tile(allocator, x, layer)!;
        defer alloc::free(allocator, built.ptr);

        OffMeshConnectionDesc[1] connections = { {
            .start = { 3, 0.4f, 1 },
            .end = { 5, 0.4f, 1 },
            .radius = 0.3f,
            .flags = 8,
            .area = 6,
            .bidirectional = true,
            .user_id = 42,
        } };
        TileRef ref = mesh.add_tile_mesh(
            tile_mesh: built,
            connections: x == 1 ? connections[..] : (OffMeshConnectionDesc[]){},
            params: {
                .tile_x = x,
                .tile_layer = layer,
                .user_id = 42,
                .walkable_height = 1,
                .walkable_radius = 0.2f,
                .walkable_climb = 0.5f,
                .build_bv_tree = true,
            },
        )!;
        PolyRef polygon = mesh.poly_ref_base(mesh.tile_by_ref(ref)!);
        mesh.set_poly_flags(polygon, layer ? 0 : 3)!;
        mesh.set_poly_area(polygon, (char)(layer ? 0 : x + 3))!;
    }
    return mesh;
}

fn char[]? example_tile(Allocator allocator, int tile_x, int layer) @local {
    ushort[12] vertices = { 0, 0, 0, 0, 0, 2, 2, 0, 2, 2, 0, 0 };
    ushort[12] polygons;
    polygons[..] = nav::MESH_NULL_INDEX;
    polygons[:4] = (ushort[4]){ 0, 1, 2, 3 }[..];
    bool border = layer == 0 && tile_x < 2;
    uint edge = tile_x == 0 ? 2 : 0;
    if (border) polygons[nav::MAX_VERTS_PER_POLY + edge] = nav::PORTAL_EDGE | (ushort)(tile_x == 0 ? 2 : 0);

    ushort[1] regions;
    ushort[1] flags = { nav::POLY_FLAG_WALK };
    char[1] areas = { nav::WALKABLE_AREA };
    Vec3 origin = { tile_x * 2.0f, layer * 3.0f, 0 };
    Vec3[4] corners = { { 0, 0, 0 }, { 0, 0, 2 }, { 2, 0, 2 }, { 2, 0, 0 } };
    Vec3[5] details = { { 0, 0, 0 }, { 2, 0, 0 }, { 2, 0, 2 }, { 0, 0, 2 }, { 1, 0.25f, 1 } };
    PolyDetail[1] ranges = { { .vertex_count = 5, .triangle_count = 4 } };
    DetailTriangle[4] triangles = {
        { .vertices = { 0, 1, 4 }, .boundary_edges = 1 },
        { .vertices = { 1, 2, 4 }, .boundary_edges = 1 },
        { .vertices = { 2, 3, 4 }, .boundary_edges = 1 },
        { .vertices = { 3, 0, 4 }, .boundary_edges = 1 },
    };
    DetailPortal[1] portals = { { .edge = edge, .min = 0.1f, .max = 0.9f, .kind = HEIGHT_BORDER } };

    PolyMesh source = {
        .verts = vertices[..],
        .polys = polygons[..],
        .regions = regions[..],
        .flags = flags[..],
        .areas = areas[..],
        .vert_count = 4,
        .poly_count = 1,
        .verts_per_poly = nav::MAX_VERTS_PER_POLY,
        .bounds = { .min = origin, .max = origin + { 2, 1, 2 } },
        .cell_size = 1,
        .cell_height = 1,
        .detail = {
            .mode = BOUNDED,
            .origin = origin,
            .source_cell_size = 1,
            .subdivision = 1,
            .corners = corners[..],
            .polygons = ranges[..],
            .vertices = details[..],
            .triangles = triangles[..],
            .portals = border ? portals[..] : (DetailPortal[]){},
        },
    };
    char[]? bytes = alloc::new_array_try(allocator, char, (sz)nav::tile_mesh_size(&source));
    if (catch bytes) return c3d::CAPACITY_EXCEEDED~;
    nav::pack_tile_mesh(mesh: &source, tile_x: tile_x, tile_z: 0, blob: bytes);
    return bytes;
}
