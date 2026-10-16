module c3d::nav;

import std::math;
import c3d;

const uint CLEARANCE_RECT_CORNERS @local = 4;
const uint CLEARANCE_FAN_COUNT @local = 4;
const uint CLEARANCE_CLIP_STORAGE @local = MAX_VERTS_PER_POLY + 3;
const uint CLEARANCE_CLIPPED_VERTICES @local = 7;
const uint CLEARANCE_POLY_VERTICES @local = CLEARANCE_FAN_COUNT * CLEARANCE_CLIPPED_VERTICES + CLEARANCE_RECT_CORNERS;
const uint CLEARANCE_POLY_TRIANGLES @local = CLEARANCE_FAN_COUNT * (CLEARANCE_CLIPPED_VERTICES - 2);
const double CLEARANCE_AREA_ALLOWANCE @local = 64 * 2.220446049250313e-16;

struct ClearanceMeshRectangle @local {
    uint surface;
    uint min_x;
    uint min_z;
    uint max_x;
    uint max_z;
}

struct ClearanceMeshRange @local {
    uint first;
    uint count;
}

struct ClearanceMeshDetail @local {
    Vec3[CLEARANCE_POLY_VERTICES] vertices;
    DetailTriangle[CLEARANCE_POLY_TRIANGLES] triangles;
    uint vertex_count;
    uint triangle_count;
}

struct ClearanceMeshSide @local {
    uint polygon;
    uint edge;
}

struct ClearanceMeshLink @local {
    uint source_rectangle;
    uint target_rectangle;
    uint direction;
    uint min;
    uint max;
    ushort target_floor;
    bool external;
}

fn char[]? pack_clearance_cells(
    Allocator allocator,
    ClearanceCells* cells,
    TileConfig* config,
    int tile_x,
    int tile_z,
) @private {
    ClearanceSource* source = cells.source;
    ulong square_count = (ulong)cells.subdivision * cells.subdivision;
    if (square_count > (ulong)sz::max) return c3d::CAPACITY_EXCEEDED~;
    if ((ulong)(source.width - source.border_size * 2) * cells.subdivision >= MESH_NULL_INDEX) return c3d::CAPACITY_EXCEEDED~;
    if ((ulong)(source.height - source.border_size * 2) * cells.subdivision >= MESH_NULL_INDEX) return c3d::CAPACITY_EXCEEDED~;

    bool[]? used = alloc::new_array_try(allocator, bool, (sz)square_count);
    if (catch used) return c3d::CAPACITY_EXCEEDED~;

    ClearanceMeshRange[]? ranges = alloc::new_array_try(allocator, ClearanceMeshRange, (sz)source.surfaces.len);
    if (catch ranges) return c3d::CAPACITY_EXCEEDED~;

    uint count = clearance_rectangles(
        cells: cells,
        used: used,
        ranges: ranges,
        output: {},
    )!;
    if (!count) return {};

    ClearanceMeshRectangle[]? rectangles = alloc::new_array_try(allocator, ClearanceMeshRectangle, count);
    if (catch rectangles) return c3d::CAPACITY_EXCEEDED~;

    (void)clearance_rectangles(
        cells: cells,
        used: used,
        ranges: ranges,
        output: rectangles,
    )!;

    PolyMesh mesh = clearance_rectangle_mesh(
        allocator: allocator,
        cells: cells,
        rectangles: rectangles,
        config: config,
    )!;
    build_clearance_details(
        allocator: allocator,
        mesh: &mesh,
        source: source,
        rectangles: rectangles,
        config: config,
    )!;
    build_clearance_links(
        allocator: allocator,
        mesh: &mesh,
        cells: cells,
        rectangles: rectangles,
        ranges: ranges,
    )!;

    usz bytes = tile_mesh_size(&mesh);
    if (bytes > (usz)sz::max) return c3d::CAPACITY_EXCEEDED~;

    char[]? blob = alloc::alloc_array_try(allocator, char, (sz)bytes);
    if (catch blob) return c3d::CAPACITY_EXCEEDED~;

    pack_tile_mesh(
        mesh: &mesh,
        tile_x: tile_x,
        tile_z: tile_z,
        blob: blob,
    );

    return blob;
}

fn uint? clearance_rectangles(
    ClearanceCells* cells,
    bool[] used,
    ClearanceMeshRange[] ranges,
    ClearanceMeshRectangle[] output,
) @local {
    uint count;
    uint subdivision = cells.subdivision;

    foreach (surface_index, surface : cells.source.surfaces) {
        ranges[surface_index] = { .first = count };
        if (!cells.selected[surface_index] || !clearance_core_column(cells.source, surface.column)) continue;

        used[..] = false;
        usz base = (usz)surface_index * subdivision * subdivision;

        for (uint z = 0; z < subdivision; z++) {
            for (uint x = 0; x < subdivision; x++) {
                usz index = (usz)z * subdivision + x;
                if (used[index] || !cells.admitted[base + index]) continue;

                uint end_x = x + 1;
                while (end_x < subdivision && !used[(usz)z * subdivision + end_x]
                    && cells.admitted[base + (usz)z * subdivision + end_x]) end_x++;

                uint end_z = z + 1;
                while (end_z < subdivision) {
                    bool complete = true;
                    for (uint column = x; column < end_x; column++) {
                        usz candidate = (usz)end_z * subdivision + column;
                        if (used[candidate] || !cells.admitted[base + candidate]) {
                            complete = false;
                            break;
                        }
                    }
                    if (!complete) break;
                    end_z++;
                }

                for (uint row = z; row < end_z; row++) {
                    for (uint column = x; column < end_x; column++) used[(usz)row * subdivision + column] = true;
                }

                if (count >= (MESH_NULL_INDEX - 1) / CLEARANCE_RECT_CORNERS) return c3d::CAPACITY_EXCEEDED~;
                if (output.len && count == output.len) return c3d::CAPACITY_EXCEEDED~;

                if (output.len) output[count] = {
                    .surface = (uint)surface_index,
                    .min_x = x,
                    .min_z = z,
                    .max_x = end_x,
                    .max_z = end_z,
                };

                count++;
                ranges[surface_index].count++;
            }
        }
    }

    return count;
}

fn bool clearance_core_column(ClearanceSource* source, uint column) @local {
    uint x = column % source.width;
    uint z = column / source.width;

    return x >= source.border_size && x < source.width - source.border_size
        && z >= source.border_size && z < source.height - source.border_size;
}

fn DetailPoint[5]? clearance_reference_points(ClearanceSource* source, uint surface_index) @local {
    ClearanceSurface* surface = &source.surfaces[surface_index];
    DetailPoint[5] points;

    for (uint index = 0; index < points.len; index++) {
        ClearancePoint position = clearance_source_point(
            source: source,
            column: surface.column,
            cell_x: index == 4 ? 0.5 : (double)DETAIL_CORNER_X[index],
            cell_z: index == 4 ? 0.5 : (double)DETAIL_CORNER_Z[index],
        )!;
        if (position.x.min != position.x.max || position.z.min != position.z.max) return c3d::CAPACITY_EXCEEDED~;
        if (!math::is_finite(surface.heights[index])) return c3d::CAPACITY_EXCEEDED~;

        points[index] = { .x = position.x.min, .y = surface.heights[index], .z = position.z.min };
    }

    for (uint fan = 0; fan < CLEARANCE_FAN_COUNT; fan++) {
        if (detail_point_area(points[4], points[fan], points[(fan + 1) & 3]) <= 0) return c3d::CAPACITY_EXCEEDED~;
    }

    return points;
}

fn double? clearance_reference_height(DetailPoint[5] reference, Vec3 position) @local {
    DetailPoint point = { .x = position.x, .z = position.z };

    for (uint fan = 0; fan < CLEARANCE_FAN_COUNT; fan++) {
        DetailPoint[3] triangle = { reference[4], reference[fan], reference[(fan + 1) & 3] };
        if (detail_point_area(triangle[0], triangle[1], point) < 0
            || detail_point_area(triangle[1], triangle[2], point) < 0
            || detail_point_area(triangle[2], triangle[0], point) < 0) continue;

        double height = detail_plane_height(triangle, point);
        if (!math::is_finite(height)) return c3d::CAPACITY_EXCEEDED~;

        return height;
    }

    return c3d::CAPACITY_EXCEEDED~;
}

fn PolyMesh? clearance_rectangle_mesh(
    Allocator allocator,
    ClearanceCells* cells,
    ClearanceMeshRectangle[] rectangles,
    TileConfig* config,
) @local {
    ClearanceSource* source = cells.source;
    uint parts = config.verts_per_poly == 3 ? 2 : 1;
    uint stride = parts == 2 ? 3 : CLEARANCE_RECT_CORNERS;
    uint vertex_count = (uint)rectangles.len * CLEARANCE_RECT_CORNERS;
    uint polygon_count = (uint)rectangles.len * parts;

    ushort[]? vertices = alloc::new_array_try(allocator, ushort, (sz)vertex_count * 3);
    if (catch vertices) return c3d::CAPACITY_EXCEEDED~;

    ushort[]? polygons = alloc::new_array_try(allocator, ushort, (sz)polygon_count * stride * 2);
    if (catch polygons) return c3d::CAPACITY_EXCEEDED~;

    ushort[]? regions = alloc::new_array_try(allocator, ushort, polygon_count);
    if (catch regions) return c3d::CAPACITY_EXCEEDED~;

    ushort[]? flags = alloc::new_array_try(allocator, ushort, polygon_count);
    if (catch flags) return c3d::CAPACITY_EXCEEDED~;

    char[]? areas = alloc::new_array_try(allocator, char, polygon_count);
    if (catch areas) return c3d::CAPACITY_EXCEEDED~;

    Vec3[]? corners = alloc::new_array_try(allocator, Vec3, vertex_count);
    if (catch corners) return c3d::CAPACITY_EXCEEDED~;

    PolyDetail[]? details = alloc::new_array_try(allocator, PolyDetail, polygon_count);
    if (catch details) return c3d::CAPACITY_EXCEEDED~;

    polygons[..] = MESH_NULL_INDEX;
    PolyMesh mesh = {
        .verts = vertices,
        .polys = polygons,
        .regions = regions,
        .flags = flags,
        .areas = areas,
        .vert_count = vertex_count,
        .poly_count = polygon_count,
        .verts_per_poly = stride,
        .bounds = source.bounds,
        .cell_size = (float)((double)source.cell_size / cells.subdivision),
        .cell_height = config.cell_height,
        .border_size = source.border_size * cells.subdivision,
        .detail = {
            .mode = DetailMode.BOUNDED,
            .origin = source.origin,
            .origin_correction = {
                source.basis[0] + ((double)source.first_x + source.border_size) * source.cell_size - source.origin.x,
                source.basis[1] + ((double)source.first_z + source.border_size) * source.cell_size - source.origin.z,
            },
            .source_cell_size = source.cell_size,
            .clearance_mode = ClearanceMode.SUB_CELL,
            .clearance_max_error = config.clearance_max_error,
            .subdivision = cells.subdivision,
            .corners = corners,
            .polygons = details,
        },
    };

    foreach (rectangle_index, rectangle : rectangles) {
        ClearanceSurface* surface = &source.surfaces[rectangle.surface];
        DetailPoint[5] reference = clearance_reference_points(source, rectangle.surface)!;
        uint vertex_base = (uint)rectangle_index * CLEARANCE_RECT_CORNERS;
        uint polygon_base = (uint)rectangle_index * parts;

        for (uint slot = 0; slot < CLEARANCE_RECT_CORNERS; slot++) {
            uint corner = (2 + CLEARANCE_RECT_CORNERS - slot) & 3;
            uint micro_x = DETAIL_CORNER_X[corner] ? rectangle.max_x : rectangle.min_x;
            uint micro_z = DETAIL_CORNER_Z[corner] ? rectangle.max_z : rectangle.min_z;
            Vec3 position = clearance_micro_vertex(
                source: source,
                column: surface.column,
                micro_x: micro_x,
                micro_z: micro_z,
                subdivision: cells.subdivision,
                height: 0,
            )!;

            double height = clearance_reference_height(reference, position)!;
            position = clearance_micro_vertex(
                source: source,
                column: surface.column,
                micro_x: micro_x,
                micro_z: micro_z,
                subdivision: cells.subdivision,
                height: height,
            )!;
            if (!detail_finite_vertex(position) || !detail_finite_vertex(position + source.origin)) {
                return c3d::CAPACITY_EXCEEDED~;
            }

            mesh.detail.corners[vertex_base + slot] = position;
            uint x = (surface.column % source.width - source.border_size) * cells.subdivision + micro_x;
            uint z = (surface.column / source.width - source.border_size) * cells.subdivision + micro_z;
            mesh.verts[(vertex_base + slot) * 3] = (ushort)x;
            mesh.verts[(vertex_base + slot) * 3 + 2] = (ushort)z;
        }

        for (uint part = 0; part < parts; part++) {
            uint polygon = polygon_base + part;
            mesh.areas[polygon] = surface.area;
            mesh.regions[polygon] = (ushort)(rectangle_index + 1);
            ushort[] indices = mesh.polys[(usz)polygon * stride * 2:stride];

            if (parts == 2) {
                indices[0] = (ushort)vertex_base;
                indices[1] = (ushort)(vertex_base + part + 1);
                indices[2] = (ushort)(vertex_base + part + 2);
                uint edge = part ? 0 : 2;
                mesh.polys[(usz)polygon * stride * 2 + stride + edge] = (ushort)(polygon_base + 1 - part);
            } else {
                for (uint vertex = 0; vertex < stride; vertex++) indices[vertex] = (ushort)(vertex_base + vertex);
            }
        }
    }
    return mesh;
}

fn void? build_clearance_details(
    Allocator allocator,
    PolyMesh* mesh,
    ClearanceSource* source,
    ClearanceMeshRectangle[] rectangles,
    TileConfig* config,
) @local {
    double lowest = double::max;
    double highest = -double::max;

    foreach (surface : source.surfaces) {
        foreach (height : surface.heights) {
            lowest = math::min(lowest, height);
            highest = math::max(highest, height);
        }
    }

    double extent = highest - lowest;
    if (!math::is_finite(extent) || extent > float::max) return c3d::CAPACITY_EXCEEDED~;

    double allowance = detail_numerical_allowance((float)extent);
    uint parts = mesh.verts_per_poly == 3 ? 2 : 1;
    uint vertex_count;
    uint triangle_count;

    for (uint polygon = 0; polygon < mesh.poly_count; polygon++) {
        Vec3[4] storage;
        Vec3[] corners = clearance_polygon_corners(mesh, polygon, storage[..]);
        DetailPoint[5] reference = clearance_reference_points(source, rectangles[polygon / parts].surface)!;
        ClearanceMeshDetail detail = clearance_polygon_detail(
            corners: corners,
            reference: reference,
            maximum_error: config.detail_max_error,
            allowance: allowance,
        )!;
        if (detail.vertex_count > config.max_detail_vertices - vertex_count) return c3d::CAPACITY_EXCEEDED~;
        if (detail.triangle_count > config.max_detail_triangles - triangle_count) return c3d::CAPACITY_EXCEEDED~;

        mesh.detail.polygons[polygon] = {
            .vertex_base = vertex_count,
            .vertex_count = detail.vertex_count,
            .triangle_base = triangle_count,
            .triangle_count = detail.triangle_count,
        };
        vertex_count += detail.vertex_count;
        triangle_count += detail.triangle_count;
    }

    Vec3[]? vertices = alloc::new_array_try(allocator, Vec3, vertex_count);
    if (catch vertices) return c3d::CAPACITY_EXCEEDED~;

    DetailTriangle[]? triangles = alloc::new_array_try(allocator, DetailTriangle, triangle_count);
    if (catch triangles) return c3d::CAPACITY_EXCEEDED~;

    mesh.detail.vertices = vertices;
    mesh.detail.triangles = triangles;

    for (uint polygon = 0; polygon < mesh.poly_count; polygon++) {
        PolyDetail range = mesh.detail.polygons[polygon];
        if (!range.triangle_count) continue;

        Vec3[4] storage;
        Vec3[] corners = clearance_polygon_corners(mesh, polygon, storage[..]);
        DetailPoint[5] reference = clearance_reference_points(source, rectangles[polygon / parts].surface)!;
        ClearanceMeshDetail detail = clearance_polygon_detail(
            corners: corners,
            reference: reference,
            maximum_error: config.detail_max_error,
            allowance: allowance,
        )!;

        mesh.detail.vertices[range.vertex_base:range.vertex_count] = detail.vertices[:detail.vertex_count];
        mesh.detail.triangles[range.triangle_base:range.triangle_count] = detail.triangles[:detail.triangle_count];
        foreach (vertex : detail.vertices[:detail.vertex_count]) {
            if (!detail_finite_vertex(vertex + source.origin)) return c3d::CAPACITY_EXCEEDED~;
        }

        if (catch excuse = validate_detail_polygon(
            corners: corners,
            range: range,
            local_vertices: mesh.detail.vertices,
            triangles: mesh.detail.triangles,
            scratch: allocator,
        )) return c3d::CAPACITY_EXCEEDED~;
    }
}

fn Vec3[] clearance_polygon_corners(PolyMesh* mesh, uint polygon, Vec3[] storage) @local {
    ushort[] indices = mesh.polys[(usz)polygon * mesh.verts_per_poly * 2:mesh.verts_per_poly];
    foreach (index, vertex : indices) storage[index] = mesh.detail.corners[vertex];

    return storage[:indices.len];
}

fn ClearanceMeshDetail? clearance_polygon_detail(
    Vec3[] corners,
    DetailPoint[5] reference,
    float maximum_error,
    double allowance,
) @local {
    DetailPoint[4] clipper;
    foreach (index, corner : corners) clipper[index] = { .x = corner.x, .y = corner.y, .z = corner.z };

    if (clearance_fan_fits(
        corners: corners,
        clipper: clipper[:corners.len],
        reference: reference,
        maximum_error: maximum_error,
        allowance: allowance,
    )!) return {};

    ClearanceMeshDetail result;
    foreach (corner : corners) result.vertices[result.vertex_count++] = corner;

    for (uint fan = 0; fan < CLEARANCE_FAN_COUNT; fan++) {
        DetailPoint[3] source = { reference[4], reference[fan], reference[(fan + 1) & 3] };
        DetailPoint[CLEARANCE_CLIP_STORAGE] clipped;
        uint count = clip_detail_polygon(source[..], clipper[:corners.len], clipped[..])!;
        if (count > CLEARANCE_CLIPPED_VERTICES) return c3d::CAPACITY_EXCEEDED~;

        for (uint index = 2; index < count; index++) {
            DetailPoint[3] precise = { clipped[0], clipped[index - 1], clipped[index] };
            double area = detail_point_area(precise[0], precise[1], precise[2]);
            if (area == 0) continue;
            if (area < 0) return c3d::CAPACITY_EXCEEDED~;
            if (result.triangle_count == result.triangles.len) return c3d::CAPACITY_EXCEEDED~;

            DetailTriangle triangle;
            Vec3[3] stored;

            for (uint vertex = 0; vertex < 3; vertex++) {
                Vec3 position = { (float)precise[vertex].x, (float)precise[vertex].y, (float)precise[vertex].z };
                if (!detail_finite_vertex(position)) return c3d::CAPACITY_EXCEEDED~;

                triangle.vertices[vertex] = clearance_detail_vertex(&result, position, allowance)!;
                stored[vertex] = result.vertices[triangle.vertices[vertex]];
                uint boundary = precise[vertex].boundary & precise[(vertex + 1) % 3].boundary;
                if (boundary) triangle.boundary_edges |= (ushort)(1 << vertex);
                certify_clearance_boundary(stored[vertex], precise[vertex].boundary, corners)!;
            }

            if (detail_triangle_area(stored[0], stored[1], stored[2]) <= 0) return c3d::CAPACITY_EXCEEDED~;
            if (!detail_triangle_valid(stored[0], stored[1], stored[2])) return c3d::CAPACITY_EXCEEDED~;

            if (!clearance_triangle_fits(
                triangle: stored,
                reference: reference,
                maximum_error: maximum_error,
                allowance: allowance,
            )!) return c3d::CAPACITY_EXCEEDED~;

            result.triangles[result.triangle_count++] = triangle;
        }
    }
    if (!result.triangle_count) return c3d::CAPACITY_EXCEEDED~;

    double polygon_area;
    for (usz vertex = 2; vertex < corners.len; vertex++) {
        polygon_area += math::abs(detail_triangle_area(corners[0], corners[vertex - 1], corners[vertex]));
    }

    double covered_area;
    foreach (triangle : result.triangles[:result.triangle_count]) {
        covered_area += detail_triangle_area(
            result.vertices[triangle.vertices[0]],
            result.vertices[triangle.vertices[1]],
            result.vertices[triangle.vertices[2]],
        );
    }

    if (math::abs(covered_area - polygon_area) > CLEARANCE_AREA_ALLOWANCE * result.triangle_count * polygon_area) {
        return c3d::CAPACITY_EXCEEDED~;
    }

    return result;
}

fn bool? clearance_fan_fits(
    Vec3[] corners,
    DetailPoint[] clipper,
    DetailPoint[5] reference,
    float maximum_error,
    double allowance,
) @local {
    for (uint fan = 0; fan < CLEARANCE_FAN_COUNT; fan++) {
        DetailPoint[3] source = { reference[4], reference[fan], reference[(fan + 1) & 3] };
        DetailPoint[CLEARANCE_CLIP_STORAGE] clipped;
        uint count = clip_detail_polygon(source[..], clipper, clipped[..])!;
        if (count > CLEARANCE_CLIPPED_VERTICES) return c3d::CAPACITY_EXCEEDED~;

        foreach (point : clipped[:count]) {
            for (uint edge = 0; edge < corners.len; edge++) {
                if (!(point.boundary & (1 << edge))) continue;

                Vec3 first = corners[edge];
                Vec3 last = corners[(edge + 1) % (uint)corners.len];
                double delta_x = (double)last.x - first.x;
                double delta_z = (double)last.z - first.z;
                double parameter = ((point.x - first.x) * delta_x + (point.z - first.z) * delta_z)
                    / (delta_x * delta_x + delta_z * delta_z);
                double height = first.y + parameter * ((double)last.y - first.y);
                if (math::abs(point.y - height) > allowance) return false;
            }
        }
    }

    for (usz vertex = 2; vertex < corners.len; vertex++) {
        Vec3[3] triangle = { corners[0], corners[vertex - 1], corners[vertex] };
        if (!clearance_triangle_fits(
            triangle: triangle,
            reference: reference,
            maximum_error: maximum_error,
            allowance: allowance,
        )!) return false;
    }

    return true;
}

fn bool? clearance_triangle_fits(
    Vec3[3] triangle,
    DetailPoint[5] reference,
    float maximum_error,
    double allowance,
) @local {
    if (!detail_triangle_valid(triangle[0], triangle[1], triangle[2])) return c3d::CAPACITY_EXCEEDED~;

    DetailPoint[3] target = detail_points(triangle);
    double area = math::abs(detail_point_area(target[0], target[1], target[2]));
    double covered_area;

    for (uint fan = 0; fan < CLEARANCE_FAN_COUNT; fan++) {
        DetailPoint[3] source = { reference[4], reference[fan], reference[(fan + 1) & 3] };
        DetailPoint[CLEARANCE_CLIP_STORAGE] overlay;
        uint count = clip_detail_polygon(source[..], target[..], overlay[..])!;
        for (uint vertex = 2; vertex < count; vertex++) {
            covered_area += math::abs(detail_point_area(overlay[0], overlay[vertex - 1], overlay[vertex]));
        }

        foreach (point : overlay[:count]) {
            if (math::abs(detail_plane_height(target, point) - point.y) > maximum_error + allowance) return false;
        }
    }

    return math::abs(covered_area - area) <= CLEARANCE_AREA_ALLOWANCE * CLEARANCE_FAN_COUNT * area;
}

fn ushort? clearance_detail_vertex(ClearanceMeshDetail* detail, Vec3 position, double allowance) @local {
    foreach (index, vertex : detail.vertices[:detail.vertex_count]) {
        if (vertex.x != position.x || vertex.z != position.z) continue;
        if (math::abs((double)vertex.y - position.y) > allowance) return c3d::CAPACITY_EXCEEDED~;

        return (ushort)index;
    }

    if (detail.vertex_count == detail.vertices.len) return c3d::CAPACITY_EXCEEDED~;

    detail.vertices[detail.vertex_count] = position;
    return (ushort)detail.vertex_count++;
}

fn void? certify_clearance_boundary(Vec3 position, uint mask, Vec3[] corners) @local {
    for (uint edge = 0; edge < corners.len; edge++) {
        if (!(mask & (1 << edge))) continue;

        Vec3 first = corners[edge];
        Vec3 last = corners[(edge + 1) % (uint)corners.len];
        if (position.x < math::min(first.x, last.x) || position.x > math::max(first.x, last.x)) return c3d::CAPACITY_EXCEEDED~;
        if (position.z < math::min(first.z, last.z) || position.z > math::max(first.z, last.z)) return c3d::CAPACITY_EXCEEDED~;

        int orientation = precision_compare_products(
            first: precision_subtract(precision_point(last.x)!, precision_point(first.x)!)!,
            second: precision_subtract(precision_point(position.z)!, precision_point(first.z)!)!,
            third: precision_subtract(precision_point(last.z)!, precision_point(first.z)!)!,
            fourth: precision_subtract(precision_point(position.x)!, precision_point(first.x)!)!,
        )!;
        if (orientation != 0) return c3d::CAPACITY_EXCEEDED~;
    }
}

fn float? clearance_portal_fraction(Vec3 first, Vec3 last, Vec3 point) @private {
    if (point.x == first.x && point.z == first.z) return 0;
    if (point.x == last.x && point.z == last.z) return 1;

    double delta_x = (double)last.x - first.x;
    double delta_z = (double)last.z - first.z;
    double parameter = math::abs(delta_x) >= math::abs(delta_z)
        ? ((double)point.x - first.x) / delta_x : ((double)point.z - first.z) / delta_z;
    if (!math::is_finite(parameter) || parameter < 0 || parameter > 1) return c3d::CAPACITY_EXCEEDED~;

    float nearest = (float)parameter;
    float previous = nearest == 0 ? 0 : bitcast(bitcast(nearest, uint) - 1, float);

    // A neighbouring fraction can round back to the certified coordinate.
    foreach (candidate : (float[3]){ nearest, previous, nearest.nexthigher() }) {
        if (candidate < 0 || candidate > 1) continue;

        Vec3 decoded = lerp_point(first, last, candidate);
        if (decoded.x == point.x && decoded.z == point.z) return candidate;
    }

    return c3d::CAPACITY_EXCEEDED~;
}

fn void? build_clearance_links(
    Allocator allocator,
    PolyMesh* mesh,
    ClearanceCells* cells,
    ClearanceMeshRectangle[] rectangles,
    ClearanceMeshRange[] ranges,
) @local {
    uint count = write_clearance_links(
        mesh: mesh,
        cells: cells,
        rectangles: rectangles,
        ranges: ranges,
        output: {},
    )!;

    DetailPortal[]? portals = alloc::new_array_try(allocator, DetailPortal, count);
    if (catch portals) return c3d::CAPACITY_EXCEEDED~;

    mesh.detail.portals = portals;
    (void)write_clearance_links(
        mesh: mesh,
        cells: cells,
        rectangles: rectangles,
        ranges: ranges,
        output: portals,
    )!;
}

fn uint? write_clearance_links(
    PolyMesh* mesh,
    ClearanceCells* cells,
    ClearanceMeshRectangle[] rectangles,
    ClearanceMeshRange[] ranges,
    DetailPortal[] output,
) @local {
    uint count;

    foreach (range : ranges) {
        for (uint first = range.first; first < range.first + range.count; first++) {
            ClearanceMeshRectangle source = rectangles[first];
            for (uint second = first + 1; second < range.first + range.count; second++) {
                ClearanceMeshRectangle target = rectangles[second];
                for (uint direction = 0; direction < 4; direction++) {
                    bool touches;
                    switch (direction) {
                        case 0: touches = source.min_x == target.max_x;
                        case 1: touches = source.max_z == target.min_z;
                        case 2: touches = source.max_x == target.min_x;
                        case 3: touches = source.min_z == target.max_z;
                    }
                    if (!touches) continue;

                    bool along_z = (direction & 1) == 0;
                    uint low = math::max(along_z ? source.min_z : source.min_x, along_z ? target.min_z : target.min_x);
                    uint high = math::min(along_z ? source.max_z : source.max_x, along_z ? target.max_z : target.max_x);
                    if (low >= high) continue;

                    for (uint pass = 0; pass < 2; pass++) {
                        write_clearance_link(
                            mesh: mesh,
                            cells: cells,
                            rectangles: rectangles,
                            link: {
                                .source_rectangle = pass ? second : first,
                                .target_rectangle = pass ? first : second,
                                .direction = pass ? (direction + 2) & 3 : direction,
                                .min = low,
                                .max = high,
                            },
                            output: output,
                            count: &count,
                        )!;
                    }
                }
            }
        }
    }

    foreach (connection : cells.connections) {
        foreach (match : connection.matches) {
            uint first_surface = clearance_surface_by_ordinal(cells.source, connection.first_column, match.first)!;
            uint second_surface = clearance_surface_by_ordinal(cells.source, connection.second_column, match.second)!;

            for (uint pass = 0; pass < 2; pass++) {
                uint source_surface = pass ? second_surface : first_surface;
                uint target_surface = pass ? first_surface : second_surface;
                uint direction = pass ? (connection.direction + 2) & 3 : connection.direction;
                uint target_column = cells.source.surfaces[target_surface].column;
                bool external = !clearance_core_column(cells.source, target_column) || !cells.selected[target_surface];
                ClearanceMeshRange source_range = ranges[source_surface];
                ClearanceMeshRange target_range = ranges[target_surface];

                for (uint first = source_range.first; first < source_range.first + source_range.count; first++) {
                    ClearanceMeshRectangle rectangle = rectangles[first];
                    if (!clearance_rectangle_border(rectangle, direction, cells.subdivision)) continue;

                    bool along_z = (direction & 1) == 0;
                    uint low = along_z ? rectangle.min_z : rectangle.min_x;
                    uint high = along_z ? rectangle.max_z : rectangle.max_x;

                    if (external) {
                        if (!clearance_match_contains(
                            cells: cells,
                            surface: source_surface,
                            direction: direction,
                            low: low,
                            high: high,
                            match: match,
                        )!) continue;

                        write_clearance_link(
                            mesh: mesh,
                            cells: cells,
                            rectangles: rectangles,
                            link: {
                                .source_rectangle = first,
                                .direction = direction,
                                .min = low,
                                .max = high,
                                .target_floor = cells.source.surfaces[target_surface].ordinal,
                                .external = true,
                            },
                            output: output,
                            count: &count,
                        )!;

                        continue;
                    }

                    for (uint second = target_range.first; second < target_range.first + target_range.count; second++) {
                        ClearanceMeshRectangle target = rectangles[second];
                        if (!clearance_rectangle_border(target, (direction + 2) & 3, cells.subdivision)) continue;

                        uint begin = math::max(low, along_z ? target.min_z : target.min_x);
                        uint end = math::min(high, along_z ? target.max_z : target.max_x);
                        if (begin >= end) continue;

                        if (!clearance_match_contains(
                            cells: cells,
                            surface: source_surface,
                            direction: direction,
                            low: begin,
                            high: end,
                            match: match,
                        )!) continue;

                        write_clearance_link(
                            mesh: mesh,
                            cells: cells,
                            rectangles: rectangles,
                            link: {
                                .source_rectangle = first,
                                .target_rectangle = second,
                                .direction = direction,
                                .min = begin,
                                .max = end,
                            },
                            output: output,
                            count: &count,
                        )!;
                    }
                }
            }
        }
    }

    return count;
}

fn void? write_clearance_link(
    PolyMesh* mesh,
    ClearanceCells* cells,
    ClearanceMeshRectangle[] rectangles,
    ClearanceMeshLink link,
    DetailPortal[] output,
    uint* count,
) @local {
    ClearanceMeshRectangle rectangle = rectangles[link.source_rectangle];
    ClearanceSurface* surface = &cells.source.surfaces[rectangle.surface];
    uint parts = mesh.verts_per_poly == 3 ? 2 : 1;
    ClearanceMeshSide side = clearance_mesh_side(link.direction, parts == 2);
    uint polygon = link.source_rectangle * parts + side.polygon;
    ushort[] indices = mesh.polys[(usz)polygon * mesh.verts_per_poly * 2:mesh.verts_per_poly];
    Vec3 first = mesh.detail.origin + mesh.detail.corners[indices[side.edge]];
    Vec3 last = mesh.detail.origin + mesh.detail.corners[indices[(side.edge + 1) % (uint)indices.len]];

    Vec3 low = clearance_rectangle_endpoint(
        cells: cells,
        rectangle: rectangle,
        direction: link.direction,
        coordinate: link.min,
    )!;
    Vec3 high = clearance_rectangle_endpoint(
        cells: cells,
        rectangle: rectangle,
        direction: link.direction,
        coordinate: link.max,
    )!;

    float minimum = clearance_portal_fraction(first, last, low)!;
    float maximum = clearance_portal_fraction(first, last, high)!;
    if (minimum > maximum) @swap(minimum, maximum);
    if (minimum >= maximum) return c3d::CAPACITY_EXCEEDED~;

    usz neighbour_word = (usz)polygon * mesh.verts_per_poly * 2 + mesh.verts_per_poly + side.edge;
    uint target_polygon;
    if (!link.external) {
        ClearanceMeshSide target_side = clearance_mesh_side((link.direction + 2) & 3, parts == 2);
        target_polygon = link.target_rectangle * parts + target_side.polygon;
        if (minimum == 0 && maximum == 1) {
            mesh.polys[neighbour_word] = (ushort)target_polygon;
            return;
        }
    } else {
        mesh.polys[neighbour_word] = PORTAL_EDGE | (ushort)link.direction;
    }

    if (*count == DEFAULT_DETAIL_TRIANGLES) return c3d::CAPACITY_EXCEEDED~;
    if (output.len && *count == output.len) return c3d::CAPACITY_EXCEEDED~;

    if (output.len) output[*count] = {
        .polygon = polygon,
        .edge = side.edge,
        .min = minimum,
        .max = maximum,
        .kind = link.external ? DetailPortalKind.FLOOR_BORDER : DetailPortalKind.INTERNAL,
        .source_floor = surface.ordinal,
        .target = link.external ? link.target_floor : target_polygon,
    };

    (*count)++;
}

fn ClearanceMeshSide clearance_mesh_side(uint direction, bool triangles) @local {
    uint edge = (direction + 2) & 3;
    if (triangles && edge >= 2) return { .polygon = 1, .edge = edge - 1 };

    return { .edge = edge };
}

fn bool clearance_rectangle_border(ClearanceMeshRectangle rectangle, uint direction, uint subdivision) @local {
    switch (direction) {
        case 0: return rectangle.min_x == 0;
        case 1: return rectangle.max_z == subdivision;
        case 2: return rectangle.max_x == subdivision;
        case 3: return rectangle.min_z == 0;
    }

    return false;
}

fn Vec3? clearance_rectangle_endpoint(
    ClearanceCells* cells,
    ClearanceMeshRectangle rectangle,
    uint direction,
    uint coordinate,
) @local {
    uint x = direction == 0 ? rectangle.min_x : direction == 2 ? rectangle.max_x : coordinate;
    uint z = direction == 3 ? rectangle.min_z : direction == 1 ? rectangle.max_z : coordinate;
    Vec3 point = clearance_micro_vertex(
        source: cells.source,
        column: cells.source.surfaces[rectangle.surface].column,
        micro_x: x,
        micro_z: z,
        subdivision: cells.subdivision,
        height: 0,
    )!;

    return cells.source.origin + point;
}

fn uint? clearance_surface_by_ordinal(ClearanceSource* source, uint column, ushort ordinal) @local {
    CompactCell cell = source.columns[column];

    for (uint index = cell.index; index < cell.index + cell.count; index++) {
        if (source.surfaces[index].ordinal == ordinal) return index;
    }

    return c3d::CAPACITY_EXCEEDED~;
}

fn bool? clearance_match_contains(
    ClearanceCells* cells,
    uint surface,
    uint direction,
    uint low,
    uint high,
    GridEdgeMatch match,
) @local {
    GridEdgeRoot first = clearance_edge_coordinate(
        cells: cells,
        surface: surface,
        direction: direction,
        coordinate: low,
    )!;
    GridEdgeRoot last = clearance_edge_coordinate(
        cells: cells,
        surface: surface,
        direction: direction,
        coordinate: high,
    )!;
    if (compare_grid_roots(first, match.max)! >= 0 || compare_grid_roots(last, match.min)! <= 0) return false;

    int lower = compare_grid_roots(first, match.min)!;
    int upper = compare_grid_roots(last, match.max)!;

    // Clamping would remove part of the admitted microcell union.
    if (lower < 0 || upper > 0 || (lower == 0 && !match.include_min) || (upper == 0 && !match.include_max)) {
        return c3d::CAPACITY_EXCEEDED~;
    }

    return true;
}

fn GridEdgeRoot? clearance_edge_coordinate(
    ClearanceCells* cells,
    uint surface,
    uint direction,
    uint coordinate,
) @local {
    uint column = cells.source.surfaces[surface].column;
    bool along_z = (direction & 1) == 0;
    double fixed = direction == 1 || direction == 2 ? 1.0 : 0.0;
    ClearancePoint first = clearance_source_point(
        source: cells.source,
        column: column,
        cell_x: along_z ? fixed : 0,
        cell_z: along_z ? 0 : fixed,
    )!;
    ClearancePoint last = clearance_source_point(
        source: cells.source,
        column: column,
        cell_x: along_z ? fixed : 1,
        cell_z: along_z ? 1 : fixed,
    )!;
    Vec3 stored = clearance_micro_vertex(
        source: cells.source,
        column: column,
        micro_x: along_z ? (direction == 2 ? cells.subdivision : 0) : coordinate,
        micro_z: along_z ? coordinate : (direction == 1 ? cells.subdivision : 0),
        subdivision: cells.subdivision,
        height: 0,
    )!;

    PrecisionInterval begin = along_z ? first.z : first.x;
    PrecisionInterval end = along_z ? last.z : last.x;
    PrecisionInterval numerator = precision_subtract(precision_point(along_z ? stored.z : stored.x)!, begin)!;
    PrecisionInterval denominator = precision_subtract(end, begin)!;

    return {
        .bounds = precision_divide(numerator, denominator)!,
        .numerator = numerator,
        .denominator = denominator,
    };
}
