module c3d::physics::fracture;

import c3d;
import std::io;
import std::time;

const uint KERNEL_REPEATS @local = 3;
const uint KERNEL_HULL_VERTEX_LIMIT @local = 64;
const uint KERNEL_ROTATIONS @local = 12;
const uint[2] KERNEL_ROTATION_HULL_LIMITS @local = { 128, 4 };

struct KernelMeasurement @local {
    ulong nanoseconds;
    ulong predicates;
    ulong filtered;
    ulong exact_nanoseconds;
    uint wide_peak;
    FractureStatistics statistics;
}

struct KernelRun @local {
    KernelFixture* fixture;
    FractureWorkspace* workspace;
    uint hull_vertex_limit;
    uint repeat;
    bool warmup;
}

<* Measure fracture generation and collision decomposition independently. *>
fn int main(String[] arguments) {
    String selection = "all";
    bool single_pass;
    bool selected;
    foreach (argument : arguments[1..]) {
        if (argument == "--single-pass") {
            single_pass = true;
        } else if (!selected) {
            selection = argument;
            selected = true;
        } else {
            io::eprintn("Usage: kernel_bench [all|kernel|wall|concave|hollow|impact_local|staircase|rotations] [--single-pass]");
            return 2;
        }
    }
    bool known = selection == "all" || selection == "kernel" || selection == "staircase" || selection == "rotations";
    foreach (name : KERNEL_NAMES) known |= selection == name;
    if (!known) {
        io::eprintfn("Unknown fixture selection: %s", selection);
        return 2;
    }

    FractureLimits limits = {
        .scratch_bytes = 256 * 1024 * 1024,
        .max_vertices = 1024 * 1024,
        .max_triangles = 1024 * 1024,
        .max_pieces = 256,
        .max_sites = KERNEL_SITE_COUNT,
        .max_hulls = 65536,
        .resolution_m = 0.0001f,
    };
    FractureWorkspace? created = create_fracture_workspace(mem, limits);
    if (catch failure = created) {
        io::eprintfn("Workspace creation failed: %s", failure);
        return 2;
    }
    FractureWorkspace workspace = created;
    defer destroy_fracture_workspace(&workspace);

    io::printfn("{\"event\":\"configuration\",\"scratch_bytes\":%s,\"max_vertices\":%s,\"max_triangles\":%s,\"max_pieces\":%s,\"max_sites\":%s,\"max_hulls\":%s,\"resolution_m\":%.8f,\"arithmetic_bytes\":%s,\"warmups\":%s,\"repeats\":%s}",
        limits.scratch_bytes, limits.max_vertices, limits.max_triangles, limits.max_pieces,
        limits.max_sites, limits.max_hulls, limits.resolution_m, MIN_FRACTURE_SCRATCH_BYTES,
        single_pass ? 0 : 1, single_pass ? 1 : KERNEL_REPEATS);
    uint failures;
    uint cases;
    KernelFixture fixture;
    for (uint shape = 0; shape < KERNEL_NAMES.len; shape++) {
        if (selection != "all" && selection != "kernel" && selection != KERNEL_NAMES[shape]) continue;
        make_kernel_fixture(&fixture, shape);
        failures += measure_kernel_case(
            workspace: &workspace,
            fixture: &fixture,
            hull_vertex_limit: KERNEL_HULL_VERTEX_LIMIT,
            single_pass: single_pass,
        ) ? 0 : 1;
        cases++;
    }
    if (selection == "all" || selection == "staircase") {
        for (uint steps = 4; steps <= KERNEL_MAX_STEPS; steps *= 2) {
            make_staircase_fixture(&fixture, steps);
            failures += measure_kernel_case(
                workspace: &workspace,
                fixture: &fixture,
                hull_vertex_limit: KERNEL_HULL_VERTEX_LIMIT,
                single_pass: single_pass,
            ) ? 0 : 1;
            cases++;
        }
    }
    if (selection == "all" || selection == "rotations") {
        for (uint shape = 0; shape < ROTATION_NAMES.len; shape++) {
            for (uint sample = 0; sample < KERNEL_ROTATIONS; sample++) {
                make_rotation_fixture(&fixture, shape, sample);
                foreach (hull_limit : KERNEL_ROTATION_HULL_LIMITS) {
                    failures += measure_kernel_case(
                        workspace: &workspace,
                        fixture: &fixture,
                        hull_vertex_limit: hull_limit,
                        single_pass: single_pass,
                    ) ? 0 : 1;
                    cases++;
                }
            }
        }
    }
    io::printfn("{\"event\":\"summary\",\"cases\":%s,\"failed_cases\":%s}", cases, failures);
    return failures ? 1 : 0;
}

fn KernelMeasurement kernel_measurement(FractureWorkspace* workspace, std::time::Clock started) @local {
    ulong elapsed = (ulong)started.to_now();
    ExactScratch* exact = (ExactScratch*)workspace.storage.ptr;
    assert(!exact.count && !exact.measurement_depth && exact.peak <= EXACT_TEMPORARIES);
    return {
        .nanoseconds = elapsed,
        .predicates = exact.predicate_count,
        .filtered = exact.filtered_count,
        .exact_nanoseconds = exact.exact_nanoseconds,
        .wide_peak = exact.peak,
        .statistics = exact.statistics,
    };
}

fn void print_kernel_identity(KernelRun run, String event) @local {
    io::printf("{\"event\":\"%s\",\"fixture\":\"%s\",\"sample\":%s,\"hull_vertex_limit\":%s,\"repeat\":%s,\"warmup\":%s",
        event, run.fixture.name, run.fixture.sample, run.hull_vertex_limit, run.repeat, run.warmup);
}

fn void print_kernel_start(KernelRun run, String phase) @local {
    print_kernel_identity(run, "start");
    io::printfn(",\"phase\":\"%s\"}", phase);
    io::stdout().flush()!!;
}

fn void print_kernel_measurement(
    KernelRun run,
    String phase,
    KernelMeasurement measurement,
    fault failure = {},
) @local {
    FractureStatistics statistics = measurement.statistics;
    double filtered_fraction = measurement.predicates ? (double)measurement.filtered / measurement.predicates : 0;
    double partition_fraction = measurement.nanoseconds ? (double)statistics.partition_nanoseconds / measurement.nanoseconds : 0;
    print_kernel_identity(run, "measurement");
    io::printf(",\"phase\":\"%s\",\"status\":\"%s\",\"failure\":", phase, failure ? "failed" : "passed");
    if (failure) {
        io::printf("\"%s\"", failure);
    } else {
        io::print("null");
    }
    io::printf(",\"nanoseconds\":%s,\"scratch_peak_bytes\":%s,\"cell_splits\":%s,\"final_leaves\":%s,\"occupied_leaves\":%s",
        measurement.nanoseconds, statistics.scratch_peak, statistics.cell_split_count,
        statistics.final_leaf_count, statistics.occupied_leaf_count);
    io::printf(",\"predicates\":%s,\"filtered_predicates\":%s,\"filtered_fraction\":%.8f,\"exact_nanoseconds\":%s,\"wide_peak\":%s",
        measurement.predicates, measurement.filtered, filtered_fraction, measurement.exact_nanoseconds, measurement.wide_peak);
    io::printf(",\"max_planar_segments\":%s,\"max_planar_points\":%s,\"max_patch_vertices\":%s,\"max_patch_predicates\":%s,\"max_patch_nanoseconds\":%s",
        statistics.max_planar_segments, statistics.max_planar_points, statistics.max_patch_vertices,
        statistics.max_patch_predicates, statistics.max_patch_nanoseconds);
    io::printfn(",\"partition_nanoseconds\":%s,\"partition_fraction\":%.8f}", statistics.partition_nanoseconds, partition_fraction);
    io::stdout().flush()!!;
}

fn void print_kernel_fragments(KernelRun run, FractureResult* fragments) @local {
    usz vertices;
    usz triangles;
    foreach (piece : fragments.pieces) {
        vertices += piece.mesh.geometry.positions.len;
        triangles += piece.mesh.geometry.indices.len / TRIANGLE_CORNERS;
    }
    print_kernel_identity(run, "fragments");
    io::printfn(",\"pieces\":%s,\"vertices\":%s,\"triangles\":%s,\"triangle_ratio\":%.8f,\"result_bytes\":%s}",
        fragments.pieces.len, vertices, triangles, (double)triangles / run.fixture.triangle_count, fragments.storage.len);
}

fn void print_kernel_collision(
    KernelRun run,
    FractureResult* fragments,
    FractureCollision* collision,
) @local {
    print_kernel_identity(run, "collision");
    io::printf(",\"pieces\":%s,\"hulls\":%s,\"collision_bytes\":%s,\"per_piece\":[",
        fragments.pieces.len, collision.hulls.len, collision.storage.len);
    foreach (uint piece, unused : fragments.pieces) {
        uint hulls;
        usz points;
        foreach (hull : collision.hulls) {
            if (hull.piece_index != piece) continue;
            hulls++;
            points += hull.points.len;
        }
        io::printf("%s{\"piece\":%s,\"hulls\":%s,\"points\":%s}", piece ? "," : "", piece, hulls, points);
    }
    io::printn("]}");
    io::stdout().flush()!!;
}

fn bool measure_kernel_collision(KernelRun run, FractureResult* fragments) @local {
    print_kernel_start(run, "decomposition");
    std::time::Clock started = clock::now();
    FractureCollision? created = create_fracture_collision(
        allocator: mem,
        workspace: run.workspace,
        fragments: fragments,
        max_hull_vertices: run.hull_vertex_limit,
    );
    KernelMeasurement measurement = kernel_measurement(run.workspace, started);
    if (catch failure = created) {
        print_kernel_measurement(
            run: run,
            phase: "decomposition",
            measurement: measurement,
            failure: failure,
        );
        return false;
    }
    FractureCollision collision = created;
    defer destroy_fracture_collision(&collision);
    print_kernel_measurement(run, "decomposition", measurement);
    print_kernel_collision(run, fragments, &collision);
    return true;
}

fn bool measure_kernel_generation(KernelRun run) @local {
    print_kernel_start(run, "generation");
    std::time::Clock started = clock::now();
    FractureResult? created = create_voronoi_fracture(
        allocator: mem,
        workspace: run.workspace,
        source: run.fixture.mesh,
        sites: run.fixture.sites[:run.fixture.site_count],
        cut: { .material_slot = 1, .uv_repeats_per_meter = 1 },
    );
    KernelMeasurement measurement = kernel_measurement(run.workspace, started);
    if (catch failure = created) {
        print_kernel_measurement(
            run: run,
            phase: "generation",
            measurement: measurement,
            failure: failure,
        );
        return false;
    }
    FractureResult fragments = created;
    defer destroy_fracture_result(&fragments);
    print_kernel_measurement(run, "generation", measurement);
    print_kernel_fragments(run, &fragments);
    return measure_kernel_collision(run, &fragments);
}

fn bool measure_kernel_case(
    FractureWorkspace* workspace,
    KernelFixture* fixture,
    uint hull_vertex_limit,
    bool single_pass,
) @local {
    io::printfn("{\"event\":\"fixture\",\"fixture\":\"%s\",\"sample\":%s,\"hull_vertex_limit\":%s,\"input_vertices\":%s,\"input_triangles\":%s,\"sites\":%s}",
        fixture.name, fixture.sample, hull_vertex_limit, fixture.vertex_count, fixture.triangle_count, fixture.site_count);
    FracturePieceView piece = { .mesh = fixture.mesh };
    FractureResult? copied = copy_fracture_result(mem, (&piece)[:1]);
    if (catch failure = copied) {
        io::eprintfn("Fixture copy failed: %s", failure);
        return false;
    }
    FractureResult source = copied;
    defer destroy_fracture_result(&source);

    uint pass_count = single_pass ? 1 : KERNEL_REPEATS + 1;
    for (uint pass = 0; pass < pass_count; pass++) {
        KernelRun run = {
            .fixture = fixture,
            .workspace = workspace,
            .hull_vertex_limit = hull_vertex_limit,
            .repeat = single_pass ? 1 : pass,
            .warmup = !single_pass && !pass,
        };
        bool passed = fixture.site_count ? measure_kernel_generation(run) : measure_kernel_collision(run, &source);
        if (!passed) return false;
    }
    return true;
}
