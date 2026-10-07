module c3d_physics_fracture_test;

import c3d;
import c3d::physics::collide;
import c3d::physics::fracture;
import std::io;
import std::math;

const uint SWEEP_ROTATIONS @private = 12;
const uint SWEEP_SHAPES @private = 4;
const uint[2] SWEEP_HULL_LIMITS @private = { 128, 4 };
const uint[36] BOX_TRIANGLES @private = {
    0, 6, 4, 0, 2, 6, 1, 7, 3, 1, 5, 7,
    0, 5, 1, 0, 4, 5, 2, 7, 6, 2, 3, 7,
    0, 3, 2, 0, 1, 3, 4, 7, 5, 4, 6, 7,
};

struct CookingFixture @private {
    Vec3[24] positions;
    uint[108] indices;
    uint[24] identities;
    uint[36] materials;
    uint vertex_count;
    uint triangle_count;
}

struct CookingCase @private {
    uint shape;
    uint rotation;
    uint hull_limit;
}

struct CookingCounts @private {
    uint reconstructed;
    uint cooked;
    uint reconstruction_failures;
    uint cooking_failures;
}

fn void test_fracture_collision_rotated_box_hulls_cook() @test {
    run_cooking_sweep(0, 1);
}

fn void test_fracture_collision_rotated_concave_hollow_and_nested_hulls_cook() @test {
    run_cooking_sweep(1, SWEEP_SHAPES);
}

fn void run_cooking_sweep(uint first_shape, uint end_shape) @private {
    FractureLimits limits = {
        .scratch_bytes = 64 * 1024 * 1024,
        .max_vertices = 65536,
        .max_triangles = 1,
        .max_pieces = 1,
        .max_sites = 1,
        .max_hulls = 4096,
        .resolution_m = 0.0001f,
    };

    FractureWorkspace workspace = fracture::create_fracture_workspace(mem, limits)!!;
    defer fracture::destroy_fracture_workspace(&workspace);

    CookingCounts counts;
    for (uint shape = first_shape; shape < end_shape; shape++) {
        for (uint rotation = 0; rotation < SWEEP_ROTATIONS; rotation++) {
            CookingFixture fixture;
            cooking_fixture(&fixture, shape);
            foreach (&point : fixture.positions[:fixture.vertex_count]) *point = rotate_cooking_point(*point, rotation);
            foreach (hull_limit : SWEEP_HULL_LIMITS) {
                CookingCase current = { .shape = shape, .rotation = rotation, .hull_limit = hull_limit };
                if (catch failure = cook_collision_case(
                    workspace: &workspace,
                    fixture: &fixture,
                    current: current,
                    counts: &counts,
                )) {
                    counts.reconstruction_failures++;
                    io::printfn("Collision reconstruction failed: shape=%s rotation=%s", shape, rotation);
                    io::printfn("hull_limit=%s cause=%s", hull_limit, failure);
                }
            }
        }
    }

    assert(counts.reconstruction_failures == 0 && counts.cooking_failures == 0);
    assert(counts.reconstructed == (usz)(end_shape - first_shape) * SWEEP_ROTATIONS * SWEEP_HULL_LIMITS.len);
    assert(counts.cooked >= counts.reconstructed);
}

fn void? cook_collision_case(
    FractureWorkspace* workspace,
    CookingFixture* fixture,
    CookingCase current,
    CookingCounts* counts,
) @private {
    FracturePieceView piece = { .mesh = {
        .geometry = {
            .positions = fixture.positions[:fixture.vertex_count],
            .indices = fixture.indices[:fixture.triangle_count * 3],
        },
        .topology_vertices = fixture.identities[:fixture.vertex_count],
        .triangle_materials = fixture.materials[:fixture.triangle_count],
    } };
    FractureResult fragments = { .pieces = (&piece)[:1] };

    FractureCollision collision = fracture::create_fracture_collision(
        allocator: mem,
        workspace: workspace,
        fragments: &fragments,
        max_hull_vertices: current.hull_limit,
    )!;
    defer fracture::destroy_fracture_collision(&collision);
    counts.reconstructed++;
    assert(collision.hulls.len);
    if (current.shape == 0 && current.hull_limit == 128) {
        assert(collision.hulls.len == 1 && collision.hulls[0].points.len == 8);
    }

    foreach (uint index, view : collision.hulls) {
        assert(view.points.len >= 4 && view.points.len <= current.hull_limit);

        Hull? result = collide::create_hull(view.points);
        if (catch failure = result) {
            counts.cooking_failures++;
            io::printfn("Collision hull cooking failed: shape=%s rotation=%s", current.shape, current.rotation);
            io::printfn("hull_limit=%s hull=%s", current.hull_limit, index);
            io::printfn("points=%s cause=%s", view.points.len, failure);
            continue;
        }

        Hull hull = result;
        defer collide::destroy_hull(&hull);
        assert(collide::hull_points(collide::hull_shape(&hull)).len >= 4);
        counts.cooked++;
    }
    return;
}

fn void cooking_fixture(CookingFixture* fixture, uint shape) @private {
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
        fixture.triangle_count = count / 3;
    } else {
        append_cooking_box(fixture, shape ? 3.0f : 0.5f);
        if (shape > 1) append_cooking_box(fixture, shape == 2 ? 1.0f : 2.0f, true);
        if (shape == 3) append_cooking_box(fixture, 1.0f);
    }
    for (uint index = 0; index < fixture.vertex_count; index++) fixture.identities[index] = index;
}

fn void append_cooking_box(CookingFixture* fixture, float extent, bool reversed = false) @private {
    uint first = fixture.vertex_count;
    for (uint vertex = 0; vertex < 8; vertex++) {
        fixture.positions[first + vertex] = {
            vertex & 4 ? extent : -extent,
            vertex & 2 ? extent : -extent,
            vertex & 1 ? extent : -extent,
        };
    }
    foreach (uint corner, vertex : BOX_TRIANGLES) fixture.indices[fixture.triangle_count * 3 + corner] = first + vertex;
    if (reversed) {
        for (uint triangle = fixture.triangle_count; triangle < fixture.triangle_count + 12; triangle++) {
            uint saved = fixture.indices[triangle * 3 + 1];
            fixture.indices[triangle * 3 + 1] = fixture.indices[triangle * 3 + 2];
            fixture.indices[triangle * 3 + 2] = saved;
        }
    }
    fixture.vertex_count += 8;
    fixture.triangle_count += 12;
}

fn Vec3 rotate_cooking_point(Vec3 point, uint index) @private {
    double[3] axis = { 1, 2.0 + index, 3 };
    double length = math::sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    foreach (&value : axis) *value /= length;

    double angle = 0.1 + 0.37 * index;
    double cosine = math::cos(angle);
    double sine = math::sin(angle);
    double dot;
    for (uint component = 0; component < 3; component++) dot += axis[component] * (double)point[component];

    Vec3 result;
    for (uint component = 0; component < 3; component++) {
        uint first = (component + 1) % 3;
        uint second = (component + 2) % 3;
        double cross = axis[first] * (double)point[second] - axis[second] * (double)point[first];
        result[component] = (float)((double)point[component] * cosine + cross * sine + axis[component] * dot * (1 - cosine));
    }

    return result;
}
