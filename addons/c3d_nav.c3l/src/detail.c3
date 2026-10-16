module c3d::nav;

import std::math;
import c3d;

const double DETAIL_MIN_AREA_RATIO @private = 2e-7;
const double DETAIL_FLOAT_EPSILON @private = 1.1920928955078125e-7;
const uint DETAIL_EDGE_HASH_MULTIPLIER @local = 2654435761;
const uint DETAIL_VERTEX_BITS @local = 16;
const ushort DETAIL_BOUNDARY_MASK @local = 7;
const uint DETAIL_EDGE_HASH_STRIDE @local = 6;

<* Select coarse or bounded polygon surface reconstruction. *>
enum DetailMode : uint {
    COARSE,
    BOUNDED,
}

<* Select captured-height, labelled-floor or in-tile portal identity. *>
enum DetailPortalKind : ushort {
    HEIGHT_BORDER,
    FLOOR_BORDER,
    INTERNAL,
}

<* Default maximum vertices retained by one tile's detail mesh. *>
const uint DEFAULT_DETAIL_VERTICES = 65534;

<* Default maximum triangles retained by one tile's detail mesh. *>
const uint DEFAULT_DETAIL_TRIANGLES = 65534;

<* Locate one polygon's detail vertices and triangles. *>
struct PolyDetail {
    uint vertex_base;
    uint vertex_count;
    uint triangle_base;
    uint triangle_count;
}

$assert PolyDetail::size == 16;

<* Index polygon-local vertices and mark its three boundary edges. *>
struct DetailTriangle {
    ushort[3] vertices;
    ushort boundary_edges;
}

$assert DetailTriangle::size == 8;

<* Retain one accepted border transition and its local floor identities. *>
struct DetailPortal {
    uint polygon;
    uint edge;
    float min;
    float max;
    float source_height;
    float target_height;
    DetailPortalKind kind;
    ushort source_floor;
    uint target; // polygon for INTERNAL, neighbour floor ordinal for FLOOR_BORDER
}

$assert DetailPortal::size == 32;

<* Borrow bounded surface arrays in a shared local coordinate basis. *>
struct DetailMesh {
    DetailMode mode;
    Vec3 origin;
    double[2] origin_correction;
    float source_cell_size;
    ClearanceMode clearance_mode;
    float clearance_max_error;
    uint subdivision;
    Vec3[] corners; // optional final local position for every coarse vertex
    PolyDetail[] polygons;
    Vec3[] vertices;
    DetailTriangle[] triangles;
    DetailPortal[] portals;
}

<* Sample ground height and its selected triangle's upward normal. *>
struct SurfacePoint {
    float height;
    Vec3 normal;
}

struct DetailValidationEdge @local {
    uint key;
    uint uses;
    uint forward;
    bool boundary;
}

fn bool valid_detail_portal(DetailPortal portal, uint polygon_count) @private {
    if ((uint)portal.kind > (uint)DetailPortalKind.INTERNAL
        || portal.polygon >= polygon_count
        || !math::is_finite(portal.min) || !math::is_finite(portal.max)
        || portal.min < 0 || portal.max > 1 || portal.min >= portal.max) return false;
    switch (portal.kind) {
        case HEIGHT_BORDER:
            return math::is_finite(portal.source_height) && math::is_finite(portal.target_height);
        case FLOOR_BORDER:
            return portal.source_floor < MESH_NULL_INDEX && portal.target < MESH_NULL_INDEX;
        case INTERNAL:
            return portal.target < polygon_count && portal.target != portal.polygon;
    }
}

fn void? validate_detail_polygon(
    Vec3[] corners,
    PolyDetail range,
    Vec3[] local_vertices,
    DetailTriangle[] triangles,
    Allocator scratch,
) @private {
    if ((usz)range.vertex_base + range.vertex_count > local_vertices.len
        || (usz)range.triangle_base + range.triangle_count > triangles.len
        || range.vertex_count > DEFAULT_DETAIL_VERTICES
        || range.triangle_count > DEFAULT_DETAIL_TRIANGLES) return c3d::INVALID_ARGUMENT~;
    if (range.triangle_count == 0) {
        if (range.vertex_count != 0) return c3d::INVALID_ARGUMENT~;
        double polygon_area;
        for (usz index = 2; index < corners.len; index++) {
            double area = detail_triangle_area(corners[0], corners[index - 1], corners[index]);
            polygon_area += area;
            if (area != 0 && !detail_triangle_valid(corners[0], corners[index - 1], corners[index])) return c3d::INVALID_ARGUMENT~;
        }
        if (polygon_area == 0) return c3d::INVALID_ARGUMENT~;
        return;
    }
    if (range.vertex_count < 3) return c3d::INVALID_ARGUMENT~;
    Vec3[] vertices = local_vertices[range.vertex_base:range.vertex_count];
    DetailTriangle[] faces = triangles[range.triangle_base:range.triangle_count];
    double polygon_area;
    double polygon_perimeter;
    double extent;
    foreach (index, corner : corners) {
        Vec3 next = corners[(index + 1) % corners.len];
        polygon_area += detail_triangle_area(corners[0], corner, next);
        double dx = (double)next.x - corner.x;
        double dz = (double)next.z - corner.z;
        polygon_perimeter += math::sqrt(dx * dx + dz * dz);
        extent = math::max(extent, math::max(math::abs((double)corner.x - corners[0].x), math::abs((double)corner.z - corners[0].z)));
    }
    if (polygon_area == 0) return c3d::INVALID_ARGUMENT~;
    double winding = polygon_area > 0 ? 1.0 : -1.0;
    double tolerance = detail_numerical_allowance((float)extent);
    foreach (vertex : vertices) {
        if (!detail_finite_vertex(vertex)) return c3d::INVALID_ARGUMENT~;
        foreach (index, corner : corners) {
            Vec3 next = corners[(index + 1) % corners.len];
            double dx = (double)next.x - corner.x;
            double dz = (double)next.z - corner.z;
            if (winding * detail_triangle_area(corner, next, vertex) < -tolerance * math::sqrt(dx * dx + dz * dz)) return c3d::INVALID_ARGUMENT~;
        }
    }
    uint table_size = next_pow2(range.triangle_count * DETAIL_EDGE_HASH_STRIDE);
    DetailValidationEdge[]? allocated = alloc::new_array_try(scratch, DetailValidationEdge, table_size);
    if (catch allocated) return c3d::CAPACITY_EXCEEDED~;
    DetailValidationEdge[] edges = allocated;
    defer alloc::free(scratch, edges.ptr);
    double triangle_area;
    foreach (face : faces) {
        if ((face.boundary_edges & (ushort)~DETAIL_BOUNDARY_MASK) != 0) return c3d::INVALID_ARGUMENT~;
        foreach (index : face.vertices) {
            if (index >= vertices.len) return c3d::INVALID_ARGUMENT~;
        }
        Vec3 first = vertices[face.vertices[0]];
        Vec3 second = vertices[face.vertices[1]];
        Vec3 third = vertices[face.vertices[2]];
        double area = detail_triangle_area(first, second, third);
        if (area <= 0 || !detail_triangle_valid(first, second, third)) return c3d::INVALID_ARGUMENT~;
        triangle_area += area;
        for (uint edge_index = 0; edge_index < 3; edge_index++) {
            uint start = face.vertices[edge_index];
            uint end = face.vertices[(edge_index + 1) % 3];
            uint key = ((math::min(start, end) << DETAIL_VERTEX_BITS) | math::max(start, end)) + 1;
            uint slot = (key * DETAIL_EDGE_HASH_MULTIPLIER) & (table_size - 1);
            while (edges[slot].key && edges[slot].key != key) slot = (slot + 1) & (table_size - 1);
            DetailValidationEdge* entry = &edges[slot];
            entry.key = key;
            entry.uses++;
            entry.forward += start < end ? 1u : 0u;
            entry.boundary |= (face.boundary_edges & (1 << edge_index)) != 0;
            if (entry.uses > 2) return c3d::INVALID_ARGUMENT~;
        }
    }
    double boundary_perimeter;
    foreach (entry : edges) {
        if (!entry.key) continue;
        if (entry.uses == 2) {
            if (entry.forward != 1 || entry.boundary) return c3d::INVALID_ARGUMENT~;
            continue;
        }
        if (!entry.boundary) return c3d::INVALID_ARGUMENT~;
        uint key = entry.key - 1;
        uint lower = key >> DETAIL_VERTEX_BITS;
        uint upper = key & ushort::max;
        Vec3 first = vertices[entry.forward ? lower : upper];
        Vec3 second = vertices[entry.forward ? upper : lower];
        bool matched;
        foreach (index, corner : corners) {
            Vec3 next = corners[(index + 1) % corners.len];
            double dx = (double)next.x - corner.x;
            double dz = (double)next.z - corner.z;
            double length = math::sqrt(dx * dx + dz * dz);
            if (length == 0) continue;
            if (math::abs(detail_triangle_area(corner, next, first)) > tolerance * length
                || math::abs(detail_triangle_area(corner, next, second)) > tolerance * length) continue;
            double start = (((double)first.x - corner.x) * dx + ((double)first.z - corner.z) * dz) / (length * length);
            double end = (((double)second.x - corner.x) * dx + ((double)second.z - corner.z) * dz) / (length * length);
            if (math::min(start, end) < -tolerance / length || math::max(start, end) > 1 + tolerance / length
                || winding * (end - start) <= 0) continue;
            double edge_x = (double)second.x - first.x;
            double edge_z = (double)second.z - first.z;
            boundary_perimeter += math::sqrt(edge_x * edge_x + edge_z * edge_z);
            matched = true;
            break;
        }
        if (!matched) return c3d::INVALID_ARGUMENT~;
    }
    if (math::abs(boundary_perimeter - polygon_perimeter) > tolerance * corners.len * 4
        || math::abs(triangle_area - math::abs(polygon_area)) > tolerance * polygon_perimeter * 4) return c3d::INVALID_ARGUMENT~;
}

fn bool detail_finite_vertex(Vec3 vertex) @private {
    return math::is_finite(vertex.x) && math::is_finite(vertex.y) && math::is_finite(vertex.z);
}

fn double detail_numerical_allowance(float height_range) @private {
    return math::max(1e-5, 32 * DETAIL_FLOAT_EPSILON * math::max(1.0, (double)height_range));
}

fn Vec3 detail_corner_position(
    Aabb bounds,
    Vec3 origin,
    ushort* voxel,
    float cell_size,
    float cell_height,
) @private {
    // Round the voxel height to float before changing basis.
    float height = (float)voxel[1] * cell_height;
    return {
        (float)((double)bounds.min.x - origin.x + (double)voxel[0] * cell_size),
        (float)((double)bounds.min.y - origin.y + height),
        (float)((double)bounds.min.z - origin.z + (double)voxel[2] * cell_size),
    };
}

fn double detail_world_allowance(Aabb bounds) @private {
    Vec3 magnitude = math::max(math::abs(bounds.min), math::abs(bounds.max));
    double x_step = math::is_finite(magnitude.x.nexthigher())
        ? (double)magnitude.x.nexthigher() - magnitude.x
        : (double)magnitude.x - bitcast(bitcast(magnitude.x, uint) - 1, float);
    double z_step = math::is_finite(magnitude.z.nexthigher())
        ? (double)magnitude.z.nexthigher() - magnitude.z
        : (double)magnitude.z - bitcast(bitcast(magnitude.z, uint) - 1, float);
    return math::sqrt(x_step * x_step + z_step * z_step);
}

fn void shift_detail_origin(Vec3* origin, double[2]* correction, Vec3 offset) @private {
    double shifted_x = (double)origin.x + correction.[0] - offset.x;
    double shifted_z = (double)origin.z + correction.[1] - offset.z;
    *origin -= offset;
    correction.[0] = shifted_x - origin.x;
    correction.[1] = shifted_z - origin.z;
}

fn double detail_triangle_area(Vec3 first, Vec3 second, Vec3 third) @private {
    double first_x = (double)second.x - first.x;
    double first_z = (double)second.z - first.z;
    double second_x = (double)third.x - first.x;
    double second_z = (double)third.z - first.z;
    return first_x * second_z - first_z * second_x;
}

fn bool detail_triangle_valid(Vec3 first, Vec3 second, Vec3 third) @private {
    double first_x = (double)second.x - first.x;
    double first_z = (double)second.z - first.z;
    double second_x = (double)third.x - first.x;
    double second_z = (double)third.z - first.z;
    double extent = math::max(math::max(math::abs(first_x), math::abs(first_z)), math::max(math::abs(second_x), math::abs(second_z)));
    double determinant = first_x * second_z - first_z * second_x;
    return extent > 0 && math::abs(determinant) >= DETAIL_MIN_AREA_RATIO * extent * extent;
}

fn SurfacePoint? detail_triangle_surface(
    Vec3 first,
    Vec3 second,
    Vec3 third,
    Vec3 position,
) @private {
    double denominator = detail_triangle_area(first, second, third);
    if (!detail_triangle_valid(first, second, third)) return c3d::CAPACITY_EXCEEDED~;
    double second_weight = detail_triangle_area(first, position, third) / denominator;
    double third_weight = detail_triangle_area(first, second, position) / denominator;
    if (second_weight < 0 || third_weight < 0 || second_weight + third_weight > 1) return c3d::INVALID_ARGUMENT~;

    double first_height = (double)second.y - first.y;
    double second_height = (double)third.y - first.y;
    double height = first.y + second_weight * first_height + third_weight * second_height;
    double normal_x = ((double)second.z - first.z) * second_height - first_height * ((double)third.z - first.z);
    double normal_z = first_height * ((double)third.x - first.x) - ((double)second.x - first.x) * second_height;
    double normal_y = denominator;
    if (normal_y < 0) {
        normal_x = -normal_x;
        normal_y = -normal_y;
        normal_z = -normal_z;
    }
    double inverse_length = 1.0 / math::sqrt(normal_x * normal_x + normal_y * normal_y + normal_z * normal_z);
    return {
        .height = (float)height,
        .normal = { (float)(normal_x * inverse_length), (float)(normal_y * inverse_length), (float)(normal_z * inverse_length) },
    };
}
