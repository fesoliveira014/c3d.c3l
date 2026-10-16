module c3d::nav;

import std::math;
import c3d;

const uint DETAIL_CLIP_VERTICES @local = MAX_VERTS_PER_POLY + 3;
const double DETAIL_DOUBLE_EPSILON @local = 2.220446049250313e-16;
const double DETAIL_COVERAGE_ROUNDING @local = 64;
const uint DETAIL_VERTEX_HASH_X @local = 0x8da6b343;
const uint DETAIL_VERTEX_HASH_Y @local = 0xd8163841;
const uint DETAIL_VERTEX_HASH_Z @local = 0xcb1ab31f;

struct DetailPoint @local {
    double x;
    double y;
    double z;
    uint boundary;
}

struct DetailAnalysis @local {
    bool fan;
    uint triangle_count;
}

struct DetailBuildState @local {
    DetailMesh mesh;
    uint vertex_count;
    uint triangle_count;
    uint[] vertex_hash;
    double height_bias;
}

fn void? build_poly_details(
    Allocator allocator,
    PolyMesh* mesh,
    DetailReference* reference,
    ushort[] regions,
    TileConfig* config,
    float height_offset = 0,
) @private {
    mesh.bounds.min.x = reference.origin.x;
    mesh.bounds.min.z = reference.origin.z;
    mesh.bounds.max.x = (float)((double)reference.origin.x + (double)(reference.width - reference.border_size * 2) * reference.cell_size);
    mesh.bounds.max.z = (float)((double)reference.origin.z + (double)(reference.height - reference.border_size * 2) * reference.cell_size);
    PolyDetail[]? polygons = alloc::new_array_try(allocator, PolyDetail, mesh.poly_count);
    if (catch polygons) return c3d::CAPACITY_EXCEEDED~;
    DetailAnalysis[]? analyses = alloc::new_array_try(allocator, DetailAnalysis, mesh.poly_count);
    if (catch analyses) return c3d::CAPACITY_EXCEEDED~;
    float lowest_height = float::max;
    float highest_height = -float::max;
    foreach (sample : reference.samples) {
        lowest_height = math::min(lowest_height, sample.height);
        highest_height = math::max(highest_height, sample.height);
        foreach (corner : sample.corners) {
            lowest_height = math::min(lowest_height, corner);
            highest_height = math::max(highest_height, corner);
        }
    }
    double allowance = detail_numerical_allowance(highest_height - lowest_height);
    DetailBuildState state = { .mesh = { .mode = DetailMode.BOUNDED, .origin = reference.origin, .polygons = polygons } };
    state.mesh.origin_correction = reference.origin_correction;
    state.mesh.origin.y = (float)((double)reference.origin.y + math::floor((double)lowest_height));
    state.height_bias = (double)reference.origin.y - state.mesh.origin.y;
    uint triangle_capacity;
    for (uint index = 0; index < mesh.poly_count; index++) {
        Vec3[MAX_VERTS_PER_POLY] storage;
        Vec3[] corners = detail_mesh_corners(mesh, index, height_offset, storage[..]);
        Vec3[MAX_VERTS_PER_POLY] stored_corners;
        ushort[] polygon = mesh.polys[(usz)index * mesh.verts_per_poly * 2:corners.len];
        foreach (corner, vertex : polygon) {
            stored_corners[corner] = detail_corner_position(
                bounds: mesh.bounds,
                origin: state.mesh.origin,
                voxel: &mesh.verts[(usz)vertex * 3],
                cell_size: mesh.cell_size,
                cell_height: mesh.cell_height,
            );
        }
        analyses[index] = analyse_detail_polygon(
            corners: corners,
            stored_corners: stored_corners[:corners.len],
            reference: reference,
            regions: regions,
            region: mesh.regions[index],
            maximum_error: config.detail_max_error,
            allowance: allowance,
            height_bias: state.height_bias,
        )!;
        if (analyses[index].fan) continue;
        if (analyses[index].triangle_count > config.max_detail_triangles - triangle_capacity) return c3d::CAPACITY_EXCEEDED~;
        triangle_capacity += analyses[index].triangle_count;
    }
    if (triangle_capacity == 0) {
        mesh.detail = state.mesh;
        return;
    }
    uint vertex_capacity = math::min(triangle_capacity * 3, config.max_detail_vertices);
    Vec3[]? vertices = alloc::alloc_array_try(allocator, Vec3, vertex_capacity);
    if (catch vertices) return c3d::CAPACITY_EXCEEDED~;
    DetailTriangle[]? triangles = alloc::alloc_array_try(allocator, DetailTriangle, triangle_capacity);
    if (catch triangles) return c3d::CAPACITY_EXCEEDED~;
    uint[]? vertex_hash = alloc::new_array_try(allocator, uint, next_pow2(vertex_capacity * 2));
    if (catch vertex_hash) return c3d::CAPACITY_EXCEEDED~;
    state.mesh.vertices = vertices;
    state.mesh.triangles = triangles;
    state.vertex_hash = vertex_hash;
    for (uint index = 0; index < mesh.poly_count; index++) {
        if (analyses[index].fan) continue;
        state.vertex_hash[..] = 0;
        PolyDetail* range = &state.mesh.polygons[index];
        range.vertex_base = state.vertex_count;
        range.triangle_base = state.triangle_count;
        Vec3[MAX_VERTS_PER_POLY] storage;
        Vec3[] corners = detail_mesh_corners(mesh, index, height_offset, storage[..]);
        emit_detail_polygon(
            state: &state,
            range: range,
            corners: corners,
            reference: reference,
            regions: regions,
            region: mesh.regions[index],
            maximum_error: config.detail_max_error,
            allowance: allowance,
        )!;
        range.vertex_count = state.vertex_count - range.vertex_base;
        range.triangle_count = state.triangle_count - range.triangle_base;
    }
    state.mesh.vertices = state.mesh.vertices[:state.vertex_count];
    state.mesh.triangles = state.mesh.triangles[:state.triangle_count];
    mesh.detail = state.mesh;
}

fn void? build_detail_portals(
    Allocator allocator,
    PolyMesh* mesh,
    DetailReference* reference,
    ushort[] regions,
    char[] areas,
    uint capacity,
) @private {
    uint count = write_detail_portals(
        mesh: mesh,
        reference: reference,
        regions: regions,
        areas: areas,
        capacity: capacity,
        output: {},
    )!;
    if (count == 0) return;
    DetailPortal[]? portals = alloc::alloc_array_try(allocator, DetailPortal, count);
    if (catch portals) return c3d::CAPACITY_EXCEEDED~;
    write_detail_portals(
        mesh: mesh,
        reference: reference,
        regions: regions,
        areas: areas,
        capacity: capacity,
        output: portals,
    )!;
    mesh.detail.portals = portals;
}

fn uint? write_detail_portals(
    PolyMesh* mesh,
    DetailReference* reference,
    ushort[] regions,
    char[] areas,
    uint capacity,
    DetailPortal[] output,
) @local {
    uint count;
    for (uint polygon = 0; polygon < mesh.poly_count; polygon++) {
        ushort[] indices = mesh.polys[(usz)polygon * mesh.verts_per_poly * 2:mesh.verts_per_poly];
        ushort[] neighbours = mesh.polys[(usz)polygon * mesh.verts_per_poly * 2 + mesh.verts_per_poly:mesh.verts_per_poly];
        uint vertices;
        foreach (index : indices) {
            if (index == MESH_NULL_INDEX) break;
            vertices++;
        }
        for (uint edge = 0; edge < vertices; edge++) {
            if (neighbours[edge] == MESH_NULL_INDEX || (neighbours[edge] & PORTAL_EDGE) == 0) continue;
            uint direction = neighbours[edge] & 3;
            bool along_z = direction == 0 || direction == 2;
            ushort* first = &mesh.verts[(usz)indices[edge] * 3];
            ushort* second = &mesh.verts[(usz)indices[(edge + 1) % vertices] * 3];
            double start = (along_z ? first[2] : first[0]) * (double)mesh.cell_size;
            double end = (along_z ? second[2] : second[0]) * (double)mesh.cell_size;
            if (start == end) return c3d::CAPACITY_EXCEEDED~;
            foreach (sample_index, sample : reference.samples) {
                if (!detail_selected_region(regions[sample_index], mesh.regions[polygon])) continue;
                uint x = sample.column % reference.width;
                uint z = sample.column / reference.width;
                int boundary = (int)(along_z ? x : z) - (int)reference.border_size
                    + ((direction == 1 || direction == 2) ? 1 : 0);
                if (boundary != (int)(along_z ? first[0] : first[2])
                    || boundary != (int)(along_z ? second[0] : second[2])) continue;
                uint neighbour = sample.connections[direction];
                if (neighbour == NULL_SPAN || areas[neighbour] == NULL_AREA) continue;
                int cell = (int)(along_z ? z : x) - (int)reference.border_size;
                double first_fraction = ((double)cell * reference.cell_size - start) / (end - start);
                double second_fraction = ((double)(cell + 1) * reference.cell_size - start) / (end - start);
                double low = math::max(0.0, math::min(first_fraction, second_fraction));
                double high = math::min(1.0, math::max(first_fraction, second_fraction));
                if (low >= high) continue;
                float minimum = detail_inward_fraction(low, true);
                float maximum = detail_inward_fraction(high, false);
                if (minimum >= maximum) return c3d::CAPACITY_EXCEEDED~;
                if (count == capacity) return c3d::CAPACITY_EXCEEDED~;
                if (output.len) {
                    output[count] = {
                        .polygon = polygon,
                        .edge = edge,
                        .min = minimum,
                        .max = maximum,
                        .source_height = (float)((double)reference.origin.y + sample.height - mesh.detail.origin.y),
                        .target_height = (float)((double)reference.origin.y + reference.samples[neighbour].height - mesh.detail.origin.y),
                    };
                    if ((double)mesh.detail.origin.y + output[count].source_height != (double)reference.origin.y + sample.height
                        || (double)mesh.detail.origin.y + output[count].target_height != (double)reference.origin.y + reference.samples[neighbour].height) return c3d::CAPACITY_EXCEEDED~;
                }
                count++;
            }
        }
    }
    return count;
}

fn float detail_inward_fraction(double value, bool minimum) @local {
    float rounded = (float)value;
    if (minimum && rounded < value) return bitcast(bitcast(rounded, uint) + 1, float);
    if (!minimum && rounded > value) return bitcast(bitcast(rounded, uint) - 1, float);
    return rounded;
}

fn Vec3[] detail_mesh_corners(
    PolyMesh* mesh,
    uint index,
    float height_offset,
    Vec3[] storage,
) @local {
    ushort[] polygon = mesh.polys[(usz)index * mesh.verts_per_poly * 2:mesh.verts_per_poly];
    uint count;
    foreach (vertex : polygon) {
        if (vertex == MESH_NULL_INDEX) break;
        ushort* point = &mesh.verts[(usz)vertex * 3];
        storage[count++] = { (float)point[0], height_offset + point[1] * mesh.cell_height, (float)point[2] };
    }
    return storage[:count];
}

fn DetailAnalysis? analyse_detail_polygon(
    Vec3[] corners,
    Vec3[] stored_corners,
    DetailReference* reference,
    ushort[] regions,
    ushort region,
    float maximum_error,
    double allowance,
    double height_bias,
) @local {
    DetailAnalysis analysis = { .fan = true };
    DetailPoint[MAX_VERTS_PER_POLY] corner_points;
    foreach (index, corner : corners) {
        corner_points[index] = { .x = corner.x, .y = corner.y, .z = corner.z };
    }
    double polygon_area;
    for (usz index = 2; index < corners.len; index++) {
        double area = detail_triangle_area(corners[0], corners[index - 1], corners[index]);
        polygon_area += area;
        if (area != 0 && !detail_triangle_valid(stored_corners[0], stored_corners[index - 1], stored_corners[index])) analysis.fan = false;
    }
    polygon_area = math::abs(polygon_area);
    if (polygon_area == 0) return c3d::CAPACITY_EXCEEDED~;
    double reference_area;
    foreach (sample_index, sample : reference.samples) {
        if (!detail_selected_region(regions[sample_index], region)) continue;
        for (uint triangle_index = 0; triangle_index < 4; triangle_index++) {
            Vec3[3] source = detail_reference_cell_triangle(reference, (uint)sample_index, triangle_index);
            DetailPoint[3] source_points = detail_points(source);
            DetailPoint[DETAIL_CLIP_VERTICES] clipped;
            uint count = clip_detail_polygon(source_points[..], corner_points[:corners.len], clipped[..])!;
            if (count < 3) continue;
            for (uint index = 2; index < count; index++) {
                double area = detail_point_area(clipped[0], clipped[index - 1], clipped[index]);
                if (area == 0) continue;
                if (area < 0) return c3d::CAPACITY_EXCEEDED~;
                reference_area += area;
                analysis.triangle_count++;
            }
            if (!analysis.fan) continue;
            foreach (point : clipped[:count]) {
                for (uint edge = 0; edge < corners.len; edge++) {
                    if ((point.boundary & (1 << edge)) == 0) continue;
                    Vec3 first = stored_corners[edge];
                    Vec3 second = stored_corners[(edge + 1) % (uint)corners.len];
                    Vec3 stored = { (float)(point.x * reference.cell_size), (float)point.y, (float)(point.z * reference.cell_size) };
                    double dx = (double)second.x - first.x;
                    double dz = (double)second.z - first.z;
                    double fraction = math::abs(dx) >= math::abs(dz) ? ((double)stored.x - first.x) / dx : ((double)stored.z - first.z) / dz;
                    double height = first.y + fraction * ((double)second.y - first.y);
                    if (detail_triangle_area(first, second, stored) != 0 || math::abs(point.y + height_bias - height) > allowance) analysis.fan = false;
                }
            }
        }
    }
    double coverage_tolerance = DETAIL_COVERAGE_ROUNDING * DETAIL_DOUBLE_EPSILON
        * math::max(1.0, (double)reference.samples.len * 4) * polygon_area;
    if (math::abs(reference_area - polygon_area) > coverage_tolerance) return c3d::CAPACITY_EXCEEDED~;
    if (analysis.fan) {
        for (usz index = 2; index < corners.len; index++) {
            Vec3[3] fan = { stored_corners[0], stored_corners[index - 1], stored_corners[index] };
            if (detail_triangle_area(fan[0], fan[1], fan[2]) == 0) continue;
            if (catch excuse = certify_detail_triangle(
                triangle: fan,
                reference: reference,
                regions: regions,
                region: region,
                maximum_error: maximum_error,
                allowance: allowance,
                height_bias: height_bias,
            )) {
                if (excuse != c3d::CAPACITY_EXCEEDED) return excuse~;
                analysis.fan = false;
                break;
            }
        }
    }
    return analysis;
}

fn void? emit_detail_polygon(
    DetailBuildState* state,
    PolyDetail* range,
    Vec3[] corners,
    DetailReference* reference,
    ushort[] regions,
    ushort region,
    float maximum_error,
    double allowance,
) @local {
    DetailPoint[MAX_VERTS_PER_POLY] corner_points;
    foreach (index, corner : corners) corner_points[index] = { .x = corner.x, .y = corner.y, .z = corner.z };
    foreach (sample_index, sample : reference.samples) {
        if (!detail_selected_region(regions[sample_index], region)) continue;
        for (uint triangle_index = 0; triangle_index < 4; triangle_index++) {
            Vec3[3] source = detail_reference_cell_triangle(reference, (uint)sample_index, triangle_index);
            DetailPoint[3] source_points = detail_points(source);
            DetailPoint[DETAIL_CLIP_VERTICES] clipped;
            uint count = clip_detail_polygon(source_points[..], corner_points[:corners.len], clipped[..])!;
            if (count < 3) continue;
            for (uint index = 2; index < count; index++) {
                DetailPoint[3] precise = { clipped[0], clipped[index - 1], clipped[index] };
                double area = detail_point_area(precise[0], precise[1], precise[2]);
                if (area == 0) continue;
                Vec3[3] triangle;
                for (uint vertex = 0; vertex < 3; vertex++) {
                    triangle[vertex] = {
                        (float)(precise[vertex].x * reference.cell_size),
                        (float)(precise[vertex].y + state.height_bias),
                        (float)(precise[vertex].z * reference.cell_size),
                    };
                }
                if (area < 0 || detail_triangle_area(triangle[0], triangle[1], triangle[2]) <= 0
                    || !detail_triangle_valid(triangle[0], triangle[1], triangle[2])) return c3d::CAPACITY_EXCEEDED~;
                certify_detail_triangle(
                    triangle: triangle,
                    reference: reference,
                    regions: regions,
                    region: region,
                    maximum_error: maximum_error,
                    allowance: allowance,
                    height_bias: state.height_bias,
                )!;
                if (state.triangle_count == state.mesh.triangles.len) return c3d::CAPACITY_EXCEEDED~;
                DetailTriangle face;
                for (uint vertex = 0; vertex < 3; vertex++) {
                    uint global = add_detail_vertex(state, triangle[vertex])!;
                    face.vertices[vertex] = (ushort)(global - range.vertex_base);
                    if ((precise[vertex].boundary & precise[(vertex + 1) % 3].boundary) != 0) {
                        face.boundary_edges |= (ushort)(1 << vertex);
                    }
                }
                state.mesh.triangles[state.triangle_count++] = face;
            }
        }
    }
}

fn void? certify_detail_triangle(
    Vec3[3] triangle,
    DetailReference* reference,
    ushort[] regions,
    ushort region,
    float maximum_error,
    double allowance,
    double height_bias,
) @local {
    DetailPoint[3] target = detail_points(triangle);
    foreach (&point : target) {
        point.x /= reference.cell_size;
        point.z /= reference.cell_size;
    }
    double target_area = math::abs(detail_point_area(target[0], target[1], target[2]));
    if (target_area == 0) return c3d::CAPACITY_EXCEEDED~;
    double covered_area;
    Vec3 lowest = math::min(triangle[0], math::min(triangle[1], triangle[2]));
    Vec3 highest = math::max(triangle[0], math::max(triangle[1], triangle[2]));
    int min_x = math::clamp((int)math::floor((double)lowest.x / reference.cell_size) + (int)reference.border_size - 1, 0, (int)reference.width - 1);
    int min_z = math::clamp((int)math::floor((double)lowest.z / reference.cell_size) + (int)reference.border_size - 1, 0, (int)reference.height - 1);
    int max_x = math::clamp((int)math::floor((double)highest.x / reference.cell_size) + (int)reference.border_size + 1, 0, (int)reference.width - 1);
    int max_z = math::clamp((int)math::floor((double)highest.z / reference.cell_size) + (int)reference.border_size + 1, 0, (int)reference.height - 1);
    for (int z = min_z; z <= max_z; z++) {
        for (int x = min_x; x <= max_x; x++) {
            CompactCell column = reference.columns[x + z * (int)reference.width];
            for (uint sample_index = column.index; sample_index < column.index + column.count; sample_index++) {
                if (!detail_selected_region(regions[sample_index], region)) continue;
                for (uint triangle_index = 0; triangle_index < 4; triangle_index++) {
                    DetailPoint[3] source = detail_points(detail_reference_triangle(reference, sample_index, triangle_index));
                    foreach (&point : source) {
                        point.x /= reference.cell_size;
                        point.z /= reference.cell_size;
                    }
                    DetailPoint[DETAIL_CLIP_VERTICES] overlay;
                    uint count = clip_detail_polygon(source[..], target[..], overlay[..])!;
                    for (uint index = 2; index < count; index++) {
                        covered_area += math::abs(detail_point_area(overlay[0], overlay[index - 1], overlay[index]));
                    }
                    foreach (point : overlay[:count]) {
                        if (math::abs(detail_plane_height(target, point) - (point.y + height_bias)) > maximum_error + allowance) return c3d::CAPACITY_EXCEEDED~;
                    }
                }
            }
        }
    }
    double coverage_tolerance = DETAIL_COVERAGE_ROUNDING * DETAIL_DOUBLE_EPSILON
        * math::max(1.0, (double)reference.samples.len * 4) * target_area;
    if (math::abs(covered_area - target_area) > coverage_tolerance) return c3d::CAPACITY_EXCEEDED~;
}

fn bool detail_selected_region(ushort candidate, ushort region) @local {
    return candidate != 0 && (region == 0 || candidate == region);
}

fn uint? add_detail_vertex(DetailBuildState* state, Vec3 vertex) @local {
    if (vertex.x == 0) vertex.x = 0;
    if (vertex.y == 0) vertex.y = 0;
    if (vertex.z == 0) vertex.z = 0;
    uint hash = bitcast(vertex.x, uint) * DETAIL_VERTEX_HASH_X
        ^ bitcast(vertex.y, uint) * DETAIL_VERTEX_HASH_Y
        ^ bitcast(vertex.z, uint) * DETAIL_VERTEX_HASH_Z;
    uint mask = (uint)state.vertex_hash.len - 1;
    uint slot = hash & mask;
    while (state.vertex_hash[slot]) {
        uint index = state.vertex_hash[slot] - 1;
        Vec3 existing = state.mesh.vertices[index];
        if (existing.x == vertex.x && existing.y == vertex.y && existing.z == vertex.z) return index;
        slot = (slot + 1) & mask;
    }
    if (state.vertex_count == state.mesh.vertices.len) return c3d::CAPACITY_EXCEEDED~;
    uint index = state.vertex_count++;
    state.mesh.vertices[index] = vertex;
    state.vertex_hash[slot] = index + 1;
    return index;
}

fn DetailPoint[3] detail_points(Vec3[3] triangle) @local {
    DetailPoint[3] points;
    for (uint index = 0; index < 3; index++) {
        points[index] = { .x = triangle[index].x, .y = triangle[index].y, .z = triangle[index].z };
    }
    return points;
}

fn double detail_point_area(DetailPoint first, DetailPoint second, DetailPoint third) @local {
    return (second.x - first.x) * (third.z - first.z) - (second.z - first.z) * (third.x - first.x);
}

fn double detail_plane_height(DetailPoint[3] triangle, DetailPoint point) @local {
    double denominator = detail_point_area(triangle[0], triangle[1], triangle[2]);
    double second_weight = detail_point_area(triangle[0], point, triangle[2]) / denominator;
    double third_weight = detail_point_area(triangle[0], triangle[1], point) / denominator;
    return triangle[0].y + second_weight * (triangle[1].y - triangle[0].y) + third_weight * (triangle[2].y - triangle[0].y);
}

fn uint? clip_detail_polygon(
    DetailPoint[] polygon,
    DetailPoint[] clipper,
    DetailPoint[] output,
) @local {
    DetailPoint[DETAIL_CLIP_VERTICES] first_storage;
    DetailPoint[DETAIL_CLIP_VERTICES] second_storage;
    DetailPoint[] incoming = first_storage[..];
    DetailPoint[] outgoing = second_storage[..];
    incoming[:polygon.len] = polygon[..];
    uint count = (uint)polygon.len;
    double winding;
    for (usz index = 2; index < clipper.len; index++) winding += detail_point_area(clipper[0], clipper[index - 1], clipper[index]);
    if (winding == 0) return 0;
    winding = winding > 0 ? 1.0 : -1.0;
    for (uint edge = 0; edge < clipper.len; edge++) {
        if (count == 0) break;
        DetailPoint edge_first = clipper[edge];
        DetailPoint edge_second = clipper[(edge + 1) % (uint)clipper.len];
        DetailPoint previous = incoming[count - 1];
        double previous_side = detail_clip_side(edge_first, edge_second, previous) * winding;
        uint written;
        for (uint index = 0; index < count; index++) {
            DetailPoint current = incoming[index];
            double current_side = detail_clip_side(edge_first, edge_second, current) * winding;
            if ((current_side >= 0) != (previous_side >= 0)) {
                DetailPoint intersection = detail_edge_intersection(
                    first: previous,
                    second: current,
                    edge_first: edge_first,
                    edge_second: edge_second,
                )!;
                intersection.boundary = (previous.boundary & current.boundary) | (1 << edge);
                append_detail_point(outgoing, &written, intersection)!;
            }
            if (current_side >= 0) {
                if (current_side == 0) current.boundary |= 1 << edge;
                append_detail_point(outgoing, &written, current)!;
            }
            previous = incoming[index];
            previous_side = current_side;
        }
        if (written > 1 && detail_same_point(outgoing[0], outgoing[written - 1])) {
            outgoing[0].boundary |= outgoing[written - 1].boundary;
            written--;
        }
        DetailPoint[] swap = incoming;
        incoming = outgoing;
        outgoing = swap;
        count = written;
    }
    output[:count] = incoming[:count];
    return count;
}

fn double detail_clip_side(DetailPoint first, DetailPoint second, DetailPoint point) @local {
    return (second.x - first.x) * (point.z - first.z) - (second.z - first.z) * (point.x - first.x);
}

fn DetailPoint? detail_edge_intersection(
    DetailPoint first,
    DetailPoint second,
    DetailPoint edge_first,
    DetailPoint edge_second,
) @local {
    if (first.x > second.x || (first.x == second.x && first.z > second.z)) {
        DetailPoint swap = first;
        first = second;
        second = swap;
    }
    if (edge_first.x > edge_second.x || (edge_first.x == edge_second.x && edge_first.z > edge_second.z)) {
        DetailPoint swap = edge_first;
        edge_first = edge_second;
        edge_second = swap;
    }
    double dx = second.x - first.x;
    double dz = second.z - first.z;
    if (detail_clip_side(edge_first, edge_second, first) == 0) return first;
    if (detail_clip_side(edge_first, edge_second, second) == 0) return second;
    foreach (endpoint : (DetailPoint[2]){ edge_first, edge_second }) {
        if (detail_point_area(first, second, endpoint) != 0
            || endpoint.x < math::min(first.x, second.x) || endpoint.x > math::max(first.x, second.x)
            || endpoint.z < math::min(first.z, second.z) || endpoint.z > math::max(first.z, second.z)) continue;
        double fraction = math::abs(dx) >= math::abs(dz) ? (endpoint.x - first.x) / dx : (endpoint.z - first.z) / dz;
        return { .x = endpoint.x, .y = first.y + fraction * (second.y - first.y), .z = endpoint.z };
    }
    double edge_x = edge_second.x - edge_first.x;
    double edge_z = edge_second.z - edge_first.z;
    double denominator = dx * edge_z - dz * edge_x;
    if (denominator == 0) return c3d::CAPACITY_EXCEEDED~;
    double fraction = (((double)edge_first.x - first.x) * edge_z - ((double)edge_first.z - first.z) * edge_x) / denominator;
    DetailPoint point = {
        .x = first.x + fraction * dx,
        .y = first.y + fraction * (second.y - first.y),
        .z = first.z + fraction * dz,
    };
    if (edge_x == 0) point.x = edge_first.x;
    if (edge_z == 0) point.z = edge_first.z;
    if (!math::is_finite(point.x) || !math::is_finite(point.y) || !math::is_finite(point.z)) return c3d::CAPACITY_EXCEEDED~;
    return point;
}

fn void? append_detail_point(DetailPoint[] output, uint* count, DetailPoint point) @local {
    if (*count && detail_same_point(output[*count - 1], point)) {
        output[*count - 1].boundary |= point.boundary;
        return;
    }
    if (*count == output.len) return c3d::CAPACITY_EXCEEDED~;
    output[(*count)++] = point;
}

fn bool detail_same_point(DetailPoint first, DetailPoint second) @local {
    return first.x == second.x && first.y == second.y && first.z == second.z;
}
