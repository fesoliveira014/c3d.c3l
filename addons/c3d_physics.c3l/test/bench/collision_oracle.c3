module c3d::physics::fracture;

import c3d;
import std::io;
import std::math;

const uint ORACLE_ROTATIONS @local = 12;
const uint[2] ORACLE_HULL_LIMITS @local = { 128, 4 };
const String[4] ORACLE_SHAPES @local = { "box", "l-prism", "hollow-box", "nested-shell" };
const uint ORACLE_CASES @local = ORACLE_ROTATIONS * ORACLE_HULL_LIMITS.len * ORACLE_SHAPES.len;
const uint[36] ORACLE_BOX_TRIANGLES @local = {
    0, 6, 4, 0, 2, 6, 1, 7, 3, 1, 5, 7,
    0, 5, 1, 0, 4, 5, 2, 7, 6, 2, 3, 7,
    0, 3, 2, 0, 1, 3, 4, 7, 5, 4, 6, 7,
};

struct OracleFixture @local {
    Vec3[24] positions;
    uint[108] indices;
    uint[24] identities;
    uint[36] materials;
    uint vertex_count;
    uint triangle_count;
}

struct OracleCase @local {
    uint shape;
    uint rotation;
    uint hull_limit;
}

struct OracleFailure @local {
    OracleCase input;
    fault cause;
    bool reconstructed;
}

fn int main(String[] arguments) {
    if (arguments.len > 2 || (arguments.len == 2 && arguments[1] != "--box-only")) {
        io::eprintn("Usage: collision_oracle [--box-only]");
        return 2;
    }

    FractureLimits limits = {
        .scratch_bytes = 64 * 1024 * 1024,
        .max_vertices = 65536,
        .max_triangles = 1,
        .max_pieces = 1,
        .max_sites = 1,
        .max_hulls = 4096,
        .resolution_m = 0.0001f,
    };
    FractureWorkspace? created = create_fracture_workspace(mem, limits);
    if (catch failure = created) {
        io::eprintfn("Workspace creation failed: %s", failure);
        return 2;
    }
    FractureWorkspace workspace = created;
    defer destroy_fracture_workspace(&workspace);

    OracleFailure[ORACLE_CASES] failures;
    uint failure_count;
    bool first_case = true;
    uint shape_count = arguments.len == 2 ? 1 : ORACLE_SHAPES.len;

    io::print("{\"cases\":[");
    for (uint shape = 0; shape < shape_count; shape++) {
        for (uint rotation = 0; rotation < ORACLE_ROTATIONS; rotation++) {
            foreach (hull_limit : ORACLE_HULL_LIMITS) {
                OracleCase current = { .shape = shape, .rotation = rotation, .hull_limit = hull_limit };
                bool reconstructed;
                if (catch failure = emit_oracle_case(
                    workspace: &workspace,
                    current: current,
                    first_case: &first_case,
                    reconstructed: &reconstructed,
                )) {
                    failures[failure_count++] = {
                        .input = current, .cause = failure, .reconstructed = reconstructed,
                    };
                }
            }
        }
    }

    io::print("],\"failures\":[");
    foreach (uint index, failure : failures[:failure_count]) {
        if (index) io::print(",");
        io::print("{");
        emit_oracle_name(failure.input);
        io::printf(",\"stage\":\"%s\"", failure.reconstructed ? "export-validation" : "reconstruction");
        io::printf(",\"cause\":\"%s\"}", failure.cause);
    }
    io::printn("]}");
    return failure_count ? 1 : 0;
}

fn void? emit_oracle_case(
    FractureWorkspace* workspace,
    OracleCase current,
    bool* first_case,
    bool* reconstructed,
) @local {
    OracleFixture fixture;
    oracle_fixture(&fixture, current.shape);
    foreach (&point : fixture.positions[:fixture.vertex_count]) *point = rotate_oracle_point(*point, current.rotation);

    FracturePieceView piece = { .mesh = {
        .geometry = {
            .positions = fixture.positions[:fixture.vertex_count],
            .indices = fixture.indices[:fixture.triangle_count * TRIANGLE_CORNERS],
        },
        .topology_vertices = fixture.identities[:fixture.vertex_count],
        .triangle_materials = fixture.materials[:fixture.triangle_count],
    } };
    FractureResult fragments = { .pieces = (&piece)[:1] };
    FractureCollision collision = create_fracture_collision(
        allocator: mem,
        workspace: workspace,
        fragments: &fragments,
        max_hull_vertices: current.hull_limit,
    )!;
    defer destroy_fracture_collision(&collision);
    *reconstructed = true;

    SolidScratch scratch = begin_solid_scratch(workspace);
    CollisionHullSurface[] hulls = oracle_hull_surfaces(&scratch, &collision)!;

    if (!*first_case) io::print(",");
    *first_case = false;
    io::print("{");
    emit_oracle_name(current);
    io::printf(",\"epsilon_bits\":%s,\"source\":", bitcast(workspace.limits.resolution_m, uint));
    emit_oracle_mesh(piece.mesh.geometry.positions, piece.mesh.geometry.indices);

    io::print(",\"hulls\":[");
    foreach (uint index, hull : hulls) {
        if (index) io::print(",");
        emit_oracle_mesh(hull.points, hull.indices);
    }
    io::print("]}");
    return;
}

fn CollisionHullSurface[]? oracle_hull_surfaces(SolidScratch* scratch, FractureCollision* collision) @local {
    CollisionHullSurface[] surfaces = reserve_elements(scratch, CollisionHullSurface, collision.hulls.len)!;

    foreach (uint index, published : collision.hulls) {
        CollisionHullSurface rebuilt = build_collision_hull(scratch, published.points)!;
        uint[] original_indices = reserve_elements(scratch, uint, rebuilt.points.len)!;

        foreach (uint vertex, point : rebuilt.points) {
            uint original = NO_SOLID_INDEX;
            foreach (uint candidate, source : published.points) {
                bool identical = true;
                for (uint axis = 0; axis < SPACE_AXES; axis++) {
                    identical &= bitcast(point[axis], uint) == bitcast(source[axis], uint);
                }
                if (identical) {
                    original = candidate;
                    break;
                }
            }
            if (original == NO_SOLID_INDEX) return NUMERICAL_FAILURE~;
            original_indices[vertex] = original;
        }

        foreach (&vertex : rebuilt.indices) *vertex = original_indices[*vertex];
        rebuilt.points = published.points;
        validate_oracle_hull(scratch, &rebuilt)!;
        surfaces[index] = rebuilt;
    }
    return surfaces;
}

fn void? validate_oracle_hull(SolidScratch* scratch, CollisionHullSurface* hull) @local {
    usz saved = scratch.used;
    defer scratch.used = saved;

    SolidMeshView mesh = collision_indexed_mesh(scratch, hull.points, hull.indices)!;
    SolidDiagnostic diagnostic;
    ValidatedSolid validated = validate_solid(
        scratch: scratch,
        source: mesh,
        grid: null,
        diagnostic: &diagnostic,
    )!;
    if (validated.nesting.shells.len != 1) return NUMERICAL_FAILURE~;

    for (usz face = 0; face < hull.indices.len; face += TRIANGLE_CORNERS) {
        uint[] triangle = hull.indices[face:TRIANGLE_CORNERS];
        foreach (point : hull.points) {
            if (exact_float_orientation(scratch.exact, {
                hull.points[triangle[0]], hull.points[triangle[1]], hull.points[triangle[2]], point,
            })! > 0) return NUMERICAL_FAILURE~;
        }
    }
    return;
}

fn void emit_oracle_name(OracleCase current) @local {
    io::printf("\"name\":\"%s-r", ORACLE_SHAPES[current.shape]);
    io::printf("%02d-limit", current.rotation);
    io::printf("%d\"", current.hull_limit);
}

fn void emit_oracle_mesh(Vec3[] positions, uint[] indices) @local {
    io::print("{\"positions_bits\":[");
    foreach (uint vertex, point : positions) {
        if (vertex) io::print(",");
        io::print("[");
        for (uint axis = 0; axis < SPACE_AXES; axis++) {
            if (axis) io::print(",");
            io::printf("%s", bitcast(point[axis], uint));
        }
        io::print("]");
    }

    io::print("],\"indices\":[");
    foreach (uint corner, vertex : indices) {
        if (corner) io::print(",");
        io::printf("%s", vertex);
    }
    io::print("]}");
}

fn void oracle_fixture(OracleFixture* fixture, uint shape) @local {
    if (shape == 1) {
        Vec3[12] positions = {
            { 0, 0, 0 }, { 2, 0, 0 }, { 2, 1, 0 }, { 1, 1, 0 }, { 1, 2, 0 }, { 0, 2, 0 },
            { 0, 0, 1 }, { 2, 0, 1 }, { 2, 1, 1 }, { 1, 1, 1 }, { 1, 2, 1 }, { 0, 2, 1 },
        };
        fixture.positions[:12] = positions[..];
        fixture.vertex_count = 12;

        uint count;
        for (uint index = 1; index < 5; index++) {
            fixture.indices[count++] = 0;
            fixture.indices[count++] = index + 1;
            fixture.indices[count++] = index;
            fixture.indices[count++] = 6;
            fixture.indices[count++] = index + 6;
            fixture.indices[count++] = index + 7;
        }
        for (uint index = 0; index < 6; index++) {
            uint next = (index + 1) % 6;
            fixture.indices[count++] = index;
            fixture.indices[count++] = next;
            fixture.indices[count++] = next + 6;
            fixture.indices[count++] = index;
            fixture.indices[count++] = next + 6;
            fixture.indices[count++] = index + 6;
        }
        fixture.triangle_count = count / TRIANGLE_CORNERS;
    } else {
        append_oracle_box(fixture, shape ? 3.0f : 0.5f);
        if (shape > 1) append_oracle_box(fixture, shape == 2 ? 1.0f : 2.0f, true);
        if (shape == 3) append_oracle_box(fixture, 1.0f);
    }
    for (uint index = 0; index < fixture.vertex_count; index++) fixture.identities[index] = index;
}

fn void append_oracle_box(OracleFixture* fixture, float extent, bool reversed = false) @local {
    uint first = fixture.vertex_count;
    for (uint vertex = 0; vertex < 8; vertex++) {
        fixture.positions[first + vertex] = {
            vertex & 4 ? extent : -extent,
            vertex & 2 ? extent : -extent,
            vertex & 1 ? extent : -extent,
        };
    }
    foreach (uint corner, vertex : ORACLE_BOX_TRIANGLES) {
        fixture.indices[fixture.triangle_count * TRIANGLE_CORNERS + corner] = first + vertex;
    }

    if (reversed) {
        for (uint triangle = fixture.triangle_count; triangle < fixture.triangle_count + 12; triangle++) {
            uint saved = fixture.indices[triangle * TRIANGLE_CORNERS + 1];
            fixture.indices[triangle * TRIANGLE_CORNERS + 1] = fixture.indices[triangle * TRIANGLE_CORNERS + 2];
            fixture.indices[triangle * TRIANGLE_CORNERS + 2] = saved;
        }
    }
    fixture.vertex_count += 8;
    fixture.triangle_count += 12;
}

fn Vec3 rotate_oracle_point(Vec3 point, uint index) @local {
    double[SPACE_AXES] axis = { 1, 2.0 + index, 3 };
    double length = math::sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    foreach (&value : axis) *value /= length;

    double angle = 0.1 + 0.37 * index;
    double cosine = math::cos(angle);
    double sine = math::sin(angle);
    double dot;
    for (uint component = 0; component < SPACE_AXES; component++) dot += axis[component] * (double)point[component];

    Vec3 result;
    for (uint component = 0; component < SPACE_AXES; component++) {
        uint first = (component + 1) % SPACE_AXES;
        uint second = (component + 2) % SPACE_AXES;
        double cross = axis[first] * (double)point[second] - axis[second] * (double)point[first];
        result[component] = (float)((double)point[component] * cosine + cross * sine + axis[component] * dot * (1 - cosine));
    }
    return result;
}
