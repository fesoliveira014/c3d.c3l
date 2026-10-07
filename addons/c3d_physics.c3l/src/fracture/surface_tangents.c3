module c3d::physics::fracture;

import c3d::geometry;
import std::math;

struct SurfaceTangentSum @local {
    double[<3>] tangent;
    double[<3>] bitangent;
}

fn void? regenerate_surface_tangents(SolidScratch* scratch, Geometry* geometry) @private {
    usz saved = scratch.used;
    defer scratch.used = saved;
    SurfaceTangentSum[] sums = reserve_elements(scratch, SurfaceTangentSum, geometry.positions.len)!;
    Vec4[] tangents = reserve_elements(scratch, Vec4, geometry.positions.len)!;
    sums[..] = {};
    usz corner_count = geometry.indices.len ? (usz)geometry.indices.len : (usz)geometry.positions.len;
    for (usz corner = 0; corner < corner_count; corner += TRIANGLE_CORNERS) {
        uint[TRIANGLE_CORNERS] vertices;
        for (uint offset = 0; offset < TRIANGLE_CORNERS; offset++) {
            vertices[offset] = geometry.indices.len ? geometry.indices[corner + offset] : (uint)(corner + offset);
        }
        double[<3>] origin = decoded_surface_vector(geometry.positions[vertices[0]]);
        double[<3>] first_edge = decoded_surface_vector(geometry.positions[vertices[1]]) - origin;
        double[<3>] second_edge = decoded_surface_vector(geometry.positions[vertices[2]]) - origin;
        double[2][2] differences;
        for (uint edge = 0; edge < 2; edge++) {
            for (uint axis = 0; axis < 2; axis++) {
                differences[edge][axis] = decoded_surface_float(geometry.uv0[vertices[edge + 1]][axis])
                  - decoded_surface_float(geometry.uv0[vertices[0]][axis]);
            }
        }
        double area = differences[0][0] * differences[1][1] - differences[1][0] * differences[0][1];
        if (area == 0) continue;
        double[<3>] tangent = (first_edge * differences[1][1] - second_edge * differences[0][1]) / area;
        double[<3>] bitangent = (second_edge * differences[0][0] - first_edge * differences[1][0]) / area;
        foreach (vertex : vertices) {
            sums[vertex].tangent += tangent;
            sums[vertex].bitangent += bitangent;
        }
    }
    foreach (uint index, normal : geometry.normals) {
        double[<3>] direction = normalized_surface_vector(decoded_surface_vector(normal));
        double[<3>] tangent = normalized_surface_vector(sums[index].tangent);
        double[<3>] orthogonal = normalized_surface_vector(tangent - direction * direction.dot(tangent));
        double[<3>] bitangent = normalized_surface_vector(sums[index].bitangent);
        Vec3 rounded = rounded_surface_direction(scratch.exact, orthogonal)!;
        float handedness = direction.cross(orthogonal).dot(bitangent) < 0 ? -1.0f : 1.0f;
        tangents[index] = { rounded.x, rounded.y, rounded.z, handedness };
    }
    geometry.tangents[..] = tangents[..];
    return;
}
