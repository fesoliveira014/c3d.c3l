module c3d_nav_test;

import std::io;
import std::math;
import std::sort;
import std::time;
import std::time::clock;
import c3d;
import c3d::nav @public;

const uint PRECISION_BUILD_SAMPLES @local = 100;
const uint PRECISION_WARMUPS @local = 10;
const uint PRECISION_QUERY_OPERATIONS @local = 100000;
const uint PRECISION_QUERY_BATCHES @local = 10;
const double PRECISION_NS_PER_MS @local = 1_000_000;

struct PrecisionTiming @local {
    double median;
    double p95;
}

fn PrecisionTiming precision_timing(double[] values) @local {
    sort::quicksort(values);
    usz percentile = (values.len * 95 + 99) / 100 - 1;
    return { .median = values[values.len / 2], .p95 = values[percentile] };
}

fn void precision_emit_timing(String name, PrecisionTiming timing) @local {
    io::printf(",\"%s\":", name);
    io::printf("[%.6f,%.6f]", timing.median, timing.p95);
}

fn void precision_emit_count(String name, usz value) @local {
    io::printf(",\"%s\":%d", name, value);
}

fn void? precision_rebuild(BuilderFixture* fixture, bool retained) @local {
    if (retained) {
        for (uint z = 0; z < fixture.builder.tiles_z; z++) {
            for (uint x = 0; x < fixture.builder.tiles_x; x++) {
                fixture.builder.cache.build_tiles_at((int)x, (int)z, &fixture.mesh)!;
            }
        }
        return;
    }
    fixture.builder.mark_dirty(fixture.builder.bounds);
    NavSyncResult result = build_everything(fixture);
    if (result.failed || result.pending) {
        io::eprintfn("Build failure: %s at %s", fixture.builder.last_failure.reason, fixture.builder.last_failure.stage);
        return c3d::INVALID_ARGUMENT~;
    }
}

fn PrecisionTiming? precision_build_timing(
    BuilderFixture* fixture,
    uint samples,
    uint warmups,
    bool retained,
) @local {
    double[] elapsed = mem::new_array(double, samples);
    defer free(elapsed);
    for (uint index = 0; index < samples + warmups; index++) {
        time::Clock started = clock::now();
        precision_rebuild(fixture, retained)!;
        double duration = (double)(clock::now() - started) / PRECISION_NS_PER_MS;
        if (index >= warmups) elapsed[index - warmups] = duration;
    }
    return precision_timing(elapsed);
}

fn void precision_emit_memory(BuilderFixture* fixture) @local {
    usz runtime_bytes;
    usz detail_bytes;
    usz local_corner_bytes;
    usz polygons;
    usz detail_vertices;
    usz detail_triangles;
    foreach (tile : fixture.mesh.tiles) {
        if (!tile.header) continue;
        runtime_bytes += tile.data.len;
        polygons += tile.header.off_mesh_base;
        detail_vertices += tile.header.detail_vertex_count;
        detail_triangles += tile.header.detail_triangle_count;
        local_corner_bytes += tile.detail_corners.len * Vec3::size;
        detail_bytes += tile.details.len * PolyDetail::size + tile.detail_vertices.len * Vec3::size
            + tile.detail_triangles.len * DetailTriangle::size + tile.detail_portals.len * DetailPortal::size
            + tile.detail_corners.len * Vec3::size;
    }
    precision_emit_count("polygons", polygons);
    precision_emit_count("detail_vertices", detail_vertices);
    precision_emit_count("detail_triangles", detail_triangles);
    precision_emit_count("detail_bytes", detail_bytes);
    precision_emit_count("local_corner_bytes", local_corner_bytes);
    precision_emit_count("runtime_bytes", runtime_bytes);
    precision_emit_count("links_used", fixture.mesh.links.len - fixture.mesh.free_links());
    precision_emit_count("links_capacity_bytes", fixture.mesh.links.len * Link::size);
    usz slot_used;
    usz slot_capacity;
    uint spans;
    foreach (job : fixture.builder.jobs) {
        slot_used = math::max(slot_used, (usz)job.arena.used);
        slot_capacity += job.scratch.len;
        spans = math::max(spans, job.heightfield.pool.high_water);
    }
    precision_emit_count("source_cells", (usz)fixture.builder.tiles_x * fixture.builder.tiles_z * fixture.builder.tile_config.width * fixture.builder.tile_config.height);
    precision_emit_count("source_span_high_water", spans);
    precision_emit_count("slot_end_used_bytes", slot_used);
    precision_emit_count("slot_capacity_bytes", slot_capacity);
    usz cache_bytes;
    usz reference_bytes;
    if (fixture.builder.cache_layers) {
        foreach (tile : fixture.builder.cache.tiles) {
            if (!tile.header) continue;
            cache_bytes += tile.data.len;
            reference_bytes += tile.header.reference_bytes;
        }
        precision_emit_count("cache_end_used_bytes", (usz)fixture.builder.cache.arena.used);
        precision_emit_count("cache_capacity_bytes", fixture.builder.cache.build_scratch.len);
    }
    precision_emit_count("cache_bytes", cache_bytes);
    precision_emit_count("reference_bytes", reference_bytes);
    precision_emit_count("tile_record_bytes", fixture.builder.tiles.len * TileRecord::size);
    if (fixture.builder.cache_layers) {
        usz runtime_stage;
        foreach (index, record : fixture.builder.tiles) {
            int x = (int)(index % fixture.builder.tiles_x);
            int z = (int)(index / fixture.builder.tiles_x);
            usz set_bytes;
            foreach (tile : fixture.mesh.tiles) {
                if (tile.header && tile.header.x == x && tile.header.z == z) set_bytes += tile.data.len;
            }
            runtime_stage = math::max(runtime_stage, set_bytes);
        }
        precision_emit_count("same_surface_runtime_stage_bytes", runtime_stage);
        precision_emit_count("same_surface_cache_stage_bytes", cache_bytes + fixture.builder.tiles.len * nav::LayerReplacement::size);
        precision_emit_count("pending_set_metadata_bytes", nav::LayerReplacement::size);
    }
}

fn PrecisionTiming? precision_query_timing(
    NavQuery* query,
    NearestPoly start,
    QueryFilter* filter,
    uint operation,
    uint count,
    uint warmups,
    double* checksum,
) @local {
    double[PRECISION_QUERY_BATCHES] elapsed;
    uint batch = math::max(1u, count / PRECISION_QUERY_BATCHES);
    PolyRef[16] visited;
    for (uint pass = 0; pass < PRECISION_QUERY_BATCHES + warmups; pass++) {
        uint operations = pass < warmups ? math::min(batch, 100u) : batch;
        time::Clock started = clock::now();
        for (uint index = 0; index < operations; index++) {
            Vec3 point = start.point + (Vec3){ (float)(index & 3) * 0.01f, 0, (float)((index >> 2) & 3) * 0.01f };
            switch (operation) {
                case 0: *checksum += query.poly_height(start.ref, point)!;
                case 1: *checksum += query.poly_surface(start.ref, point)!.normal.y;
                case 2: *checksum += query.find_nearest_poly(point, { 0.1f, 0.5f, 0.1f }, filter)!.point.y;
                case 3:
                    MoveResult result = query.move_along_surface_projected(
                        start_ref: start.ref,
                        start: start.point,
                        end: point,
                        filter: filter,
                        out_visited: visited[..],
                    )!;
                    *checksum += result.position.y;
            }
        }
        double duration = (double)(clock::now() - started) / operations;
        if (pass >= warmups) elapsed[pass - warmups] = duration;
    }
    return precision_timing(elapsed[..]);
}

fn void? precision_measure_case(
    PrecisionFixtureKind kind,
    DetailMode mode,
    bool cached,
    uint builds,
    uint queries,
    uint warmups,
) @local {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    time::Clock setup_started = clock::now();
    setup_precision_fixture(fixture: fixture, kind: kind, cached: cached, mode: mode);
    defer teardown(fixture);
    precision_rebuild(fixture, false)!;
    double setup_ms = (double)(clock::now() - setup_started) / PRECISION_NS_PER_MS;
    PrecisionTiming build = precision_build_timing(fixture: fixture, samples: builds, warmups: warmups, retained: false)!;
    PrecisionTiming rebuild;
    if (cached) rebuild = precision_build_timing(fixture: fixture, samples: builds, warmups: warmups, retained: true)!;
    NavQuery query = nav::create_nav_query(mem, &fixture.mesh, 256)!;
    defer nav::destroy_nav_query(&query);
    QueryFilter filter = nav::default_query_filter();
    Vec3 point = { 2.25f, kind == PrecisionFixtureKind.BRIDGE ? 3.0f : precision_source_height(kind, 2.25f, 2.25f), 2.25f };
    NearestPoly start = query.find_nearest_poly(point, { 0.1f, 0.5f, 0.1f }, &filter)!;
    PrecisionTiming[4] operations;
    double checksum;
    foreach (index, &timing : operations) {
        *timing = precision_query_timing(
            query: &query,
            start: start,
            filter: &filter,
            operation: (uint)index,
            count: queries,
            warmups: warmups,
            checksum: &checksum,
        )!;
    }
    io::printf("{\"fixture_version\":%d,\"fixture_id\":%d", PRECISION_FIXTURE_VERSION, kind.ordinal);
    io::printf(",\"mode\":\"%s\",\"path\":\"%s\"", mode == DetailMode.BOUNDED ? "bounded" : "coarse", cached ? "cache" : "direct");
    precision_emit_count("build_runs", builds);
    precision_emit_count("warmups", warmups);
    precision_emit_count("query_operations", (usz)(queries / PRECISION_QUERY_BATCHES * PRECISION_QUERY_BATCHES));
    io::printf(",\"setup_ms\":%.6f", setup_ms);
    precision_emit_timing("build_ms", build);
    if (cached) precision_emit_timing("retained_rebuild_ms", rebuild);
    precision_emit_timing("height_ns", operations[0]);
    precision_emit_timing("surface_ns", operations[1]);
    precision_emit_timing("nearest_ns", operations[2]);
    precision_emit_timing("move_ns", operations[3]);
    precision_emit_memory(fixture);
    io::printfn(",\"checksum\":%.8f}", checksum);
}

fn void precision_export_triangle(
    String record,
    PrecisionFixtureKind kind,
    bool cached,
    int tile_x,
    int tile_z,
    uint item,
    uint floor,
    Vec3 origin,
    Vec3[3] triangle,
    bool core_cell = true,
) @local {
    io::printf("{\"record\":\"%s\",\"fixture_id\":%d", record, kind.ordinal);
    io::printf(",\"path\":\"%s\",\"tile_x\":%d", cached ? "cache" : "direct", tile_x);
    io::printf(",\"tile_z\":%d,\"item\":%d", tile_z, item);
    io::printf(",\"floor\":%d", floor);
    io::printf(",\"core_cell\":%s,\"points\":[", core_cell ? "true" : "false");
    for (uint vertex = 0; vertex < 3; vertex++) {
        if (vertex) io::print(",");
        io::printf("[%.17g,", (double)origin.x + triangle[vertex].x);
        io::printf("%.17g,", (double)origin.y + triangle[vertex].y);
        io::printf("%.17g]", (double)origin.z + triangle[vertex].z);
    }
    io::printn("]}");
}

fn void? precision_export_case(PrecisionFixtureKind kind, bool cached) @local {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    setup_precision_fixture(fixture: fixture, kind: kind, cached: cached, mode: DetailMode.BOUNDED);
    defer teardown(fixture);
    precision_rebuild(fixture, false)!;
    if (cached) {
        foreach (tile : fixture.builder.cache.tiles) {
            if (!tile.header) continue;
            DetailReference reference = nav::cached_detail_reference(tile.data)!;
            foreach (sample_index, sample : reference.samples) {
                if (sample.area == nav::NULL_AREA) continue;
                uint floor = kind == PrecisionFixtureKind.BRIDGE && reference.origin.y + sample.height >= 2 ? 1 : 0;
                for (uint face = 0; face < 4; face++) {
                    precision_export_triangle(
                        record: "reference",
                        kind: kind,
                        cached: cached,
                        tile_x: tile.header.tile_x,
                        tile_z: tile.header.tile_z,
                        item: (uint)sample_index * 4 + face,
                        floor: floor,
                        origin: reference.origin,
                        triangle: nav::detail_reference_triangle(&reference, (uint)sample_index, face),
                        core_cell: sample.column % reference.width >= reference.border_size
                            && sample.column % reference.width < reference.width - reference.border_size
                            && sample.column / reference.width >= reference.border_size
                            && sample.column / reference.width < reference.height - reference.border_size,
                    );
                }
            }
        }
    }
    foreach (tile : fixture.mesh.tiles) {
        if (!tile.header) continue;
        for (uint polygon = 0; polygon < tile.header.off_mesh_base; polygon++) {
            Poly poly = tile.polys[polygon];
            PolyDetail range = tile.details[polygon];
            uint floor = kind == PrecisionFixtureKind.BRIDGE && tile.verts[poly.verts[0]].y >= 2 ? 1 : 0;
            uint triangles = range.triangle_count ? range.triangle_count : poly.vert_count - 2;
            for (uint face = 0; face < triangles; face++) {
                Vec3[3] triangle;
                if (range.triangle_count) {
                    DetailTriangle indices = tile.detail_triangles[range.triangle_base + face];
                    for (uint vertex = 0; vertex < 3; vertex++) triangle[vertex] = tile.detail_vertices[range.vertex_base + indices.vertices[vertex]];
                } else {
                    triangle = { tile.detail_corners[poly.verts[0]], tile.detail_corners[poly.verts[face + 1]], tile.detail_corners[poly.verts[face + 2]] };
                }
                precision_export_triangle(
                    record: "output",
                    kind: kind,
                    cached: cached,
                    tile_x: tile.header.x,
                    tile_z: tile.header.z,
                    item: polygon,
                    floor: floor,
                    origin: tile.header.detail_origin,
                    triangle: triangle,
                );
            }
        }
    }
}

fn int main(String[] args) {
    uint builds = PRECISION_BUILD_SAMPLES;
    uint queries = PRECISION_QUERY_OPERATIONS;
    uint warmups = PRECISION_WARMUPS;
    bool export_triangles;
    foreach (argument : args[1..]) {
        if (argument == "--quick") {
            builds = 2;
            queries = 1000;
            warmups = 1;
        } else if (argument == "--export") {
            export_triangles = true;
        } else {
            io::eprintfn("Unknown argument: %s; use --quick or --export", argument);
            return 1;
        }
    }
    foreach (kind : PrecisionFixtureKind::values) {
        if (export_triangles) {
            foreach (bool cached : { false, true }) {
                if (catch excuse = precision_export_case(kind, cached)) {
                    io::eprintfn("Export fixture %d failed: %s", kind.ordinal, excuse);
                    return 1;
                }
            }
            continue;
        }
        foreach (mode : DetailMode::values) {
            foreach (bool cached : { false, true }) {
                if (catch excuse = precision_measure_case(
                    kind: kind,
                    mode: mode,
                    cached: cached,
                    builds: builds,
                    queries: queries,
                    warmups: warmups,
                )) {
                    io::eprintfn("Fixture %d failed: %s", kind.ordinal, excuse);
                    return 1;
                }
            }
        }
    }
    return 0;
}
