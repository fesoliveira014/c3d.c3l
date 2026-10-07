module c3d::physics::fracture;

import c3d;
import std::math;

const uint KERNEL_SITE_COUNT @private = 64;
const uint KERNEL_MAX_STEPS @private = 64;
const uint KERNEL_MAX_VERTICES @local = 4 * KERNEL_MAX_STEPS + 4;
const uint KERNEL_MAX_TRIANGLES @local = 8 * KERNEL_MAX_STEPS + 4;
const uint[36] KERNEL_BOX_CORNERS @local = {
    0, 6, 4, 0, 2, 6, 1, 7, 3, 1, 5, 7,
    0, 5, 1, 0, 4, 5, 2, 7, 6, 2, 3, 7,
    0, 3, 2, 0, 1, 3, 4, 7, 5, 4, 6, 7,
};
const String[4] KERNEL_NAMES @private = { "wall", "concave", "hollow", "impact_local" };
const String[4] ROTATION_NAMES @private = { "rotation_box", "rotation_l_prism", "rotation_hollow", "rotation_nested" };

struct KernelFixture @private {
    Vec3[KERNEL_MAX_VERTICES] positions;
    uint[KERNEL_MAX_TRIANGLES * TRIANGLE_CORNERS] indices;
    uint[KERNEL_MAX_VERTICES] identities;
    uint[KERNEL_MAX_TRIANGLES] materials;
    Vec3[KERNEL_SITE_COUNT] sites;
    uint vertex_count;
    uint triangle_count;
    uint site_count;
    String name;
    uint sample;
    SolidMeshView mesh;
}

fn void refresh_kernel_mesh(KernelFixture* fixture) @local {
    fixture.mesh = {
        .geometry = {
            .positions = fixture.positions[:fixture.vertex_count],
            .indices = fixture.indices[:fixture.triangle_count * TRIANGLE_CORNERS],
        },
        .topology_vertices = fixture.identities[:fixture.vertex_count],
        .triangle_materials = fixture.materials[:fixture.triangle_count],
    };
}

fn void append_kernel_shell(
    KernelFixture* fixture,
    Vec3[] positions,
    uint[] indices,
    bool reversed,
) @local {
    uint base = fixture.vertex_count;
    foreach (point : positions) {
        fixture.positions[fixture.vertex_count] = point;
        fixture.identities[fixture.vertex_count] = fixture.vertex_count;
        fixture.vertex_count++;
    }
    for (usz first = 0; first < indices.len; first += TRIANGLE_CORNERS) {
        for (uint corner = 0; corner < TRIANGLE_CORNERS; corner++) {
            uint source = reversed && corner ? TRIANGLE_CORNERS - corner : corner;
            fixture.indices[fixture.triangle_count * TRIANGLE_CORNERS + corner] = base + indices[first + source];
        }
        fixture.triangle_count++;
    }
    refresh_kernel_mesh(fixture);
}

fn void append_kernel_box(
    KernelFixture* fixture,
    Vec3 lower,
    Vec3 upper,
    bool reversed = false,
) @local {
    Vec3[8] positions;
    for (uint vertex = 0; vertex < positions.len; vertex++) {
        positions[vertex] = {
            vertex & 4 ? upper.x : lower.x,
            vertex & 2 ? upper.y : lower.y,
            vertex & 1 ? upper.z : lower.z,
        };
    }
    append_kernel_shell(
        fixture: fixture,
        positions: positions[..],
        indices: KERNEL_BOX_CORNERS[..],
        reversed: reversed,
    );
}

fn void append_kernel_grid(
    KernelFixture* fixture,
    Vec3 lower,
    Vec3 upper,
    uint[3] counts,
) @local {
    for (uint x = 0; x < counts[0]; x++) {
        for (uint y = 0; y < counts[1]; y++) {
            for (uint z = 0; z < counts[2]; z++) {
                fixture.sites[fixture.site_count++] = {
                    lower.x + (upper.x - lower.x) * ((float)x + 0.5f) / counts[0],
                    lower.y + (upper.y - lower.y) * ((float)y + 0.5f) / counts[1],
                    lower.z + (upper.z - lower.z) * ((float)z + 0.5f) / counts[2],
                };
            }
        }
    }
}

fn void append_kernel_prism(KernelFixture* fixture, Vec3[] polygon) @local {
    uint count = (uint)polygon.len;
    uint first = fixture.vertex_count;
    for (uint level = 0; level < 2; level++) {
        foreach (point : polygon) {
            fixture.positions[fixture.vertex_count] = { point.x, point.y, (float)level };
            fixture.identities[fixture.vertex_count] = fixture.vertex_count;
            fixture.vertex_count++;
        }
    }
    uint corner = fixture.triangle_count * TRIANGLE_CORNERS;
    for (uint index = 1; index + 1 < count; index++) {
        fixture.indices[corner++] = first;
        fixture.indices[corner++] = first + index + 1;
        fixture.indices[corner++] = first + index;
        fixture.indices[corner++] = first + count;
        fixture.indices[corner++] = first + count + index;
        fixture.indices[corner++] = first + count + index + 1;
    }
    for (uint index = 0; index < count; index++) {
        uint next = (index + 1) % count;
        fixture.indices[corner++] = first + index;
        fixture.indices[corner++] = first + next;
        fixture.indices[corner++] = first + next + count;
        fixture.indices[corner++] = first + index;
        fixture.indices[corner++] = first + next + count;
        fixture.indices[corner++] = first + index + count;
    }
    fixture.triangle_count = corner / TRIANGLE_CORNERS;
    refresh_kernel_mesh(fixture);
}

fn void append_kernel_concave(KernelFixture* fixture) @local {
    Vec3[6] polygon = {
        { 0, 0, 0 }, { 2, 0, 0 }, { 2, 1, 0 }, { 1, 1, 0 }, { 1, 2, 0 }, { 0, 2, 0 },
    };
    append_kernel_prism(fixture, polygon[..]);
}

fn void make_kernel_fixture(KernelFixture* fixture, uint shape) @private {
    *fixture = { .name = KERNEL_NAMES[shape] };
    switch (shape) {
        case 0:
            append_kernel_box(fixture, { -4, -2, -0.125f }, { 4, 2, 0.125f });
            append_kernel_grid(
                fixture: fixture,
                lower: { -4, -2, -0.125f },
                upper: { 4, 2, 0.125f },
                counts: { 4, 4, 4 },
            );
        case 1:
            append_kernel_concave(fixture);
            append_kernel_grid(
                fixture: fixture,
                lower: { 0, 0, 0 },
                upper: { 2, 2, 1 },
                counts: { 2, 2, 2 },
            );
        case 2:
            append_kernel_box(fixture, { -2, -2, -2 }, { 2, 2, 2 });
            append_kernel_box(
                fixture: fixture,
                lower: { -1.5f, -1.5f, -1.5f },
                upper: { 1.5f, 1.5f, 1.5f },
                reversed: true,
            );
            append_kernel_grid(
                fixture: fixture,
                lower: { -2, -2, -2 },
                upper: { 2, 2, 2 },
                counts: { 2, 2, 2 },
            );
        case 3:
            append_kernel_box(fixture, { -4, -2, -0.125f }, { 4, 2, 0.125f });
            append_kernel_grid(
                fixture: fixture,
                lower: { 0.25f, -0.75f, -0.125f },
                upper: { 1.75f, 0.75f, 0.125f },
                counts: { 4, 4, 2 },
            );
            append_kernel_grid(
                fixture: fixture,
                lower: { -4, -2, -0.125f },
                upper: { 4, 2, 0.125f },
                counts: { 4, 4, 2 },
            );
    }
}

fn void make_staircase_fixture(KernelFixture* fixture, uint steps) @private {
    *fixture = { .name = "staircase", .sample = steps };
    Vec3[2 * KERNEL_MAX_STEPS + 2] polygon;
    uint count;
    polygon[count++] = { 0, 0, 0 };
    polygon[count++] = { (float)steps, 0, 0 };
    for (uint level = 1; level <= steps; level++) {
        polygon[count++] = { (float)(steps - level + 1), (float)level, 0 };
        polygon[count++] = { (float)(steps - level), (float)level, 0 };
    }
    append_kernel_prism(fixture, polygon[:count]);
}

fn Vec3 rotate_kernel_point(Vec3 point, uint sample) @local {
    double[<3>] axis = { 1, 2 + (double)sample, 3 };
    Quaternion rotation = quaternion::from_axis_angle{double}(axis.normalize(), 0.1 + 0.37 * sample);
    return (Vec3)(rotation * (double[<3>])point);
}

fn void make_rotation_fixture(KernelFixture* fixture, uint shape, uint sample) @private {
    *fixture = { .name = ROTATION_NAMES[shape], .sample = sample };
    if (shape == 1) {
        append_kernel_concave(fixture);
    } else {
        float extent = shape ? 3.0f : 0.5f;
        append_kernel_box(fixture, { -extent, -extent, -extent }, { extent, extent, extent });
        if (shape > 1) {
            float inner = shape == 2 ? 1.0f : 2.0f;
            append_kernel_box(
                fixture: fixture,
                lower: { -inner, -inner, -inner },
                upper: { inner, inner, inner },
                reversed: true,
            );
        }
        if (shape == 3) append_kernel_box(fixture, { -1, -1, -1 }, { 1, 1, 1 });
    }
    foreach (&point : fixture.positions[:fixture.vertex_count]) *point = rotate_kernel_point(*point, sample);
}
