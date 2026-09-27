module c3d::nav;

import std::math;
import std::sort;
import c3d;
import c3d::maths;

<* Vertex flag marking a tile-border vertex polygon building removes; mirrors RC_BORDER_VERTEX. *>
const int BORDER_VERTEX = 0x10000;

<* Vertex flag marking a vertex between two areas; mirrors RC_AREA_BORDER. *>
const int AREA_BORDER = 0x20000;

<* Mask of the neighbour region id in a contour vertex's fourth value; mirrors RC_CONTOUR_REG_MASK. *>
const int CONTOUR_REGION_MASK = 0xffff;

<* Default contour flags: split long wall edges. *>
const ContourFlags CONTOUR_FLAGS_DEFAULT = { .tessellate_wall_edges = true };

const uint MAX_CONTOUR_WALK @private = 40000; // mirrors walkContour's iteration cap
const char ALL_EDGES @local = 0xf;
const uint AREA_SHIFT @local = 16; // above the sixteen bits of a region id
const sz   RAW_POINTS_CAPACITY @local = 256; // mirrors upstream's verts(256); lists double from here
const sz   SIMPLIFIED_POINTS_CAPACITY @local = 64; // mirrors upstream's simplified(64)
const sz   MIN_CONTOUR_CAPACITY @local = 8; // mirrors upstream's max(maxRegions, 8) contour array

<* Which edges simplification splits past max_edge_length; mirrors rcBuildContoursFlags. *>
bitstruct ContourFlags : uint {
    bool tessellate_wall_edges : 0;
    bool tessellate_area_edges : 1;
}

<* One region outline; four ints per vertex: x, y, z in voxels and the neighbour region with flags. *>
struct Contour {
    int[]  verts;
    int[]  raw_verts;
    ushort region;
    char   area;
}

<* Outlines of every region of one tile; arrays come from the output allocator. *>
struct ContourSet {
    Contour[] contours;
    Aabb      bounds;        // without the border
    float     cell_size;
    float     cell_height;
    uint      width;         // without the border
    uint      height;
    uint      border_size;
    float     max_error;
}

struct Corner @local {
    int  height;
    bool border_vertex;
}

struct ContourHole @local {
    Contour* contour;
    int      min_x;
    int      min_z;
    int      leftmost;
}

struct ContourRegion @local {
    Contour*     outline;
    ContourHole* holes;
    sz           hole_count;
}

struct PotentialDiagonal @local {
    int vertex;
    int distance;
}

<*
 Trace and simplify the outline of every region; mirrors rcBuildContours.
 Hole contours are merged into their region's outline and left empty.
 @param allocator : "Receives the contour set; never freed by the result."
 @param scratch : "Holds edge flags and point lists for the call."
 @param [&in] compact : "Regions built."
 @param max_error : "Voxels a simplified edge may leave the raw outline."
 @param max_edge_length : "Voxels; longer edges are split. 0 disables."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn ContourSet? build_contours(
    Allocator allocator,
    Allocator scratch,
    CompactHeightfield* compact,
    float max_error,
    uint max_edge_length,
    ContourFlags flags = CONTOUR_FLAGS_DEFAULT,
) {
    int width = (int)compact.width;
    int height = (int)compact.height;
    int border = (int)compact.border_size;

    ContourSet set = {
        .bounds      = compact.bounds,
        .cell_size   = compact.cell_size,
        .cell_height = compact.cell_height,
        .width       = (uint)math::max(width - border * 2, 0),
        .height      = (uint)math::max(height - border * 2, 0),
        .border_size = compact.border_size,
        .max_error   = max_error,
    };
    if (border > 0) {
        float pad = border * compact.cell_size;
        set.bounds.min.x += pad;
        set.bounds.min.z += pad;
        set.bounds.max.x -= pad;
        set.bounds.max.z -= pad;
    }

    sz contour_capacity = math::max((sz)compact.max_regions, MIN_CONTOUR_CAPACITY);
    Contour[]? contours = alloc::new_array_try(allocator, Contour, contour_capacity);
    if (catch contours) return c3d::CAPACITY_EXCEEDED~;
    sz contour_count;

    char[]? edge_flags = alloc::new_array_try(scratch, char, compact.span_count);
    if (catch edge_flags) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, edge_flags.ptr);

    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = compact.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                ushort region = compact.spans[index].region;
                if (region == 0 || (region & BORDER_REGION) != 0) {
                    edge_flags[index] = 0;
                    continue;
                }
                char connected;
                for (uint direction = 0; direction < 4; direction++) {
                    uint neighbour = neighbour_index(
                        compact:   compact,
                        x:         x,
                        z:         z,
                        index:     index,
                        direction: direction,
                    );
                    ushort neighbour_region = neighbour != NULL_SPAN ? compact.spans[neighbour].region : 0;
                    if (neighbour_region == region) connected |= (char)(1 << direction);
                }
                edge_flags[index] = connected ^ ALL_EDGES;
            }
        }
    }

    IntList raw_points = create_int_list(scratch, RAW_POINTS_CAPACITY)!;
    defer destroy_int_list(&raw_points);
    IntList simplified = create_int_list(scratch, SIMPLIFIED_POINTS_CAPACITY)!;
    defer destroy_int_list(&simplified);

    for (int z = 0; z < height; z++) {
        for (int x = 0; x < width; x++) {
            CompactCell cell = compact.cells[x + z * width];
            for (uint index = cell.index; index < cell.index + cell.count; index++) {
                if (edge_flags[index] == 0 || edge_flags[index] == ALL_EDGES) {
                    edge_flags[index] = 0;
                    continue;
                }
                ushort region = compact.spans[index].region;
                if (region == 0 || (region & BORDER_REGION) != 0) continue;
                char area = compact.areas[index];

                raw_points.clear();
                simplified.clear();
                walk_contour(
                    compact:    compact,
                    x:          x,
                    z:          z,
                    index:      index,
                    edge_flags: edge_flags,
                    points:     &raw_points,
                )!;
                simplify_contour(
                    points:          &raw_points,
                    simplified:      &simplified,
                    max_error:       max_error,
                    max_edge_length: (int)max_edge_length,
                    flags:           flags,
                )!;
                remove_degenerate_segments(&simplified)!;
                if (simplified.count / 4 < 3) continue;

                if (contour_count == contours.len) {
                    Contour[]? grown = alloc::realloc_array_try(allocator, contours.ptr, Contour, contours.len * 2);
                    if (catch grown) return c3d::CAPACITY_EXCEEDED~;
                    contours = grown;
                }
                contours[contour_count++] = {
                    .verts     = copy_without_border(allocator, simplified.view(), border)!,
                    .raw_verts = copy_without_border(allocator, raw_points.view(), border)!,
                    .region    = region,
                    .area      = area,
                };
            }
        }
    }
    set.contours = contours[:contour_count];

    if (contour_count > 0) merge_holes(allocator, scratch, set.contours, compact.max_regions)!;
    return set;
}

// A winding opposite to the outlines marks a hole; each region is assumed to have one outline.
fn void? merge_holes(
    Allocator allocator,
    Allocator scratch,
    Contour[] contours,
    ushort max_regions,
) @local {
    bool[]? is_hole = alloc::new_array_try(scratch, bool, contours.len);
    if (catch is_hole) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, is_hole.ptr);
    sz hole_count;
    foreach (index, contour : contours) {
        is_hole[index] = signed_polygon_area(vertex_view(contour.verts)) < 0;
        if (is_hole[index]) hole_count++;
    }
    if (hole_count == 0) return;

    ContourRegion[]? regions = alloc::new_array_try(scratch, ContourRegion, (sz)max_regions + 1);
    if (catch regions) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, regions.ptr);
    ContourHole[]? holes = alloc::new_array_try(scratch, ContourHole, contours.len);
    if (catch holes) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, holes.ptr);

    foreach (index, &contour : contours) {
        if (is_hole[index]) {
            regions[contour.region].hole_count++;
        } else {
            regions[contour.region].outline = contour;
        }
    }
    sz next_hole;
    foreach (&region : regions) {
        if (region.hole_count == 0) continue;
        region.holes = &holes[next_hole];
        next_hole += region.hole_count;
        region.hole_count = 0;
    }
    foreach (index, &contour : contours) {
        if (!is_hole[index]) continue;
        ContourRegion* region = &regions[contour.region];
        region.holes[region.hole_count++].contour = contour;
    }

    // A region without an outline comes from over-aggressive simplification; its holes stay unmerged.
    foreach (&region : regions) {
        if (region.hole_count == 0 || !region.outline) continue;
        merge_region_holes(allocator, scratch, region)!;
    }
}

fn int[]? copy_without_border(Allocator allocator, int[] vertices, int border) @local {
    int[]? copied = alloc::alloc_array_try(allocator, int, vertices.len);
    if (catch copied) return c3d::CAPACITY_EXCEEDED~;
    copied[..] = vertices[..];
    foreach (&vertex : vertex_view(copied)) {
        (*vertex)[0] -= border;
        (*vertex)[2] -= border;
    }
    return copied;
}

fn int[4][] vertex_view(int[] values) @local => ((int[4]*)values.ptr)[:values.len / 4];

fn void? push_vertex(IntList* list, int[4] vertex) @local {
    foreach (value : vertex) list.push(value)!;
}

fn void? insert_vertex(IntList* list, sz position, int[4] vertex) @local {
    list.resize(list.count + 4)!;
    int[4][] vertices = vertex_view(list.view());
    for (sz shifted = vertices.len - 1; shifted > position; shifted--) vertices[shifted] = vertices[shifted - 1];
    vertices[position] = vertex;
}

// The area joins the region so a vertex between two areas is never taken for a tile-border vertex.
fn uint region_and_area(CompactHeightfield* compact, uint index) @local {
    return (uint)compact.spans[index].region | ((uint)compact.areas[index] << AREA_SHIFT);
}

fn Corner get_corner_height(
    CompactHeightfield* compact,
    int x,
    int z,
    uint index,
    uint direction,
) @local {
    int height = compact.spans[index].y;
    uint turned = (direction + 1) & 3;
    uint[4] region_codes;
    region_codes[0] = region_and_area(compact, index);

    uint ahead = neighbour_index(
        compact:   compact,
        x:         x,
        z:         z,
        index:     index,
        direction: direction,
    );
    if (ahead != NULL_SPAN) {
        height = math::max(height, (int)compact.spans[ahead].y);
        region_codes[1] = region_and_area(compact, ahead);
        uint diagonal = neighbour_index(
            compact:   compact,
            x:         x + dir_offset_x(direction),
            z:         z + dir_offset_z(direction),
            index:     ahead,
            direction: turned,
        );
        if (diagonal != NULL_SPAN) {
            height = math::max(height, (int)compact.spans[diagonal].y);
            region_codes[2] = region_and_area(compact, diagonal);
        }
    }
    uint beside = neighbour_index(
        compact:   compact,
        x:         x,
        z:         z,
        index:     index,
        direction: turned,
    );
    if (beside != NULL_SPAN) {
        height = math::max(height, (int)compact.spans[beside].y);
        region_codes[3] = region_and_area(compact, beside);
        uint diagonal = neighbour_index(
            compact:   compact,
            x:         x + dir_offset_x(turned),
            z:         z + dir_offset_z(turned),
            index:     beside,
            direction: direction,
        );
        if (diagonal != NULL_SPAN) {
            height = math::max(height, (int)compact.spans[diagonal].y);
            region_codes[2] = region_and_area(compact, diagonal);
        }
    }

    // Two equal exterior cells followed by two interior cells of one area mark a tile-border vertex.
    for (uint first = 0; first < 4; first++) {
        uint second = (first + 1) & 3;
        uint third = (first + 2) & 3;
        uint fourth = (first + 3) & 3;
        bool two_same_exteriors = (region_codes[first] & region_codes[second] & BORDER_REGION) != 0
            && region_codes[first] == region_codes[second];
        bool two_interiors = ((region_codes[third] | region_codes[fourth]) & BORDER_REGION) == 0;
        bool interiors_same_area = (region_codes[third] >> AREA_SHIFT) == (region_codes[fourth] >> AREA_SHIFT);
        bool no_zeros = region_codes[first] != 0 && region_codes[second] != 0
            && region_codes[third] != 0 && region_codes[fourth] != 0;
        if (two_same_exteriors && two_interiors && interiors_same_area && no_zeros) {
            return { .height = height, .border_vertex = true };
        }
    }
    return { .height = height };
}

fn void? walk_contour(
    CompactHeightfield* compact,
    int x,
    int z,
    uint index,
    char[] edge_flags,
    IntList* points,
) @local {
    uint direction;
    while ((edge_flags[index] & (1 << direction)) == 0) direction++;
    uint start_direction = direction;
    uint start_index = index;
    char area = compact.areas[index];

    for (uint step = 1; step < MAX_CONTOUR_WALK; step++) {
        if ((edge_flags[index] & (1 << direction)) != 0) {
            Corner corner = get_corner_height(
                compact:   compact,
                x:         x,
                z:         z,
                index:     index,
                direction: direction,
            );
            int point_x = x;
            int point_z = z;
            switch (direction) {
                case 0:
                    point_z++;
                case 1:
                    point_x++;
                    point_z++;
                case 2:
                    point_x++;
            }
            int neighbour_region;
            bool area_border;
            uint neighbour = neighbour_index(
                compact:   compact,
                x:         x,
                z:         z,
                index:     index,
                direction: direction,
            );
            if (neighbour != NULL_SPAN) {
                neighbour_region = compact.spans[neighbour].region;
                area_border = area != compact.areas[neighbour];
            }
            if (corner.border_vertex) neighbour_region |= BORDER_VERTEX;
            if (area_border) neighbour_region |= AREA_BORDER;
            push_vertex(points, { point_x, corner.height, point_z, neighbour_region })!;

            edge_flags[index] &= (char)~(1 << direction);
            direction = (direction + 1) & 3;
        } else {
            uint neighbour = neighbour_index(
                compact:   compact,
                x:         x,
                z:         z,
                index:     index,
                direction: direction,
            );
            if (neighbour == NULL_SPAN) return;
            x += dir_offset_x(direction);
            z += dir_offset_z(direction);
            index = neighbour;
            direction = (direction + 3) & 3;
        }
        if (start_index == index && start_direction == direction) break;
    }
}

fn float point_segment_distance_sq(int[4] point, int[4] start, int[4] end) @local {
    float segment_x = (float)(end[0] - start[0]);
    float segment_z = (float)(end[2] - start[2]);
    float delta_x = (float)(point[0] - start[0]);
    float delta_z = (float)(point[2] - start[2]);
    float length_sq = segment_x * segment_x + segment_z * segment_z;
    float along = segment_x * delta_x + segment_z * delta_z;
    if (length_sq > 0) along /= length_sq;
    if (along < 0) {
        along = 0;
    } else if (along > 1) {
        along = 1;
    }
    delta_x = (float)start[0] + along * segment_x - (float)point[0];
    delta_z = (float)start[2] + along * segment_z - (float)point[2];
    return delta_x * delta_x + delta_z * delta_z;
}

// Simplified vertices hold the raw point index in their fourth value until the final pass.
fn void? simplify_contour(
    IntList* points,
    IntList* simplified,
    float max_error,
    int max_edge_length,
    ContourFlags flags,
) @local {
    int[4][] raw = vertex_view(points.view());
    int raw_count = (int)raw.len;

    bool has_connections;
    foreach (point : raw) {
        if ((point[3] & CONTOUR_REGION_MASK) == 0) continue;
        has_connections = true;
        break;
    }
    if (has_connections) {
        for (int current = 0; current < raw_count; current++) {
            int next = (current + 1) % raw_count;
            bool different_regions = (raw[current][3] & CONTOUR_REGION_MASK) != (raw[next][3] & CONTOUR_REGION_MASK);
            bool area_borders = (raw[current][3] & AREA_BORDER) != (raw[next][3] & AREA_BORDER);
            if (different_regions || area_borders) {
                push_vertex(simplified, { raw[current][0], raw[current][1], raw[current][2], current })!;
            }
        }
    }

    if (simplified.count == 0) {
        int lower_left;
        int upper_right;
        foreach (current, point : raw) {
            int[4] lower = raw[lower_left];
            int[4] upper = raw[upper_right];
            if (point[0] < lower[0] || (point[0] == lower[0] && point[2] < lower[2])) lower_left = (int)current;
            if (point[0] > upper[0] || (point[0] == upper[0] && point[2] > upper[2])) upper_right = (int)current;
        }
        push_vertex(simplified, { raw[lower_left][0], raw[lower_left][1], raw[lower_left][2], lower_left })!;
        push_vertex(simplified, { raw[upper_right][0], raw[upper_right][1], raw[upper_right][2], upper_right })!;
    }

    for (int vertex = 0; vertex < simplified.count / 4;) {
        int[4][] vertices = vertex_view(simplified.view());
        int[4] start = vertices[vertex];
        int[4] end = vertices[(vertex + 1) % (int)vertices.len];

        // Walk the raw points in lexicographic order so opposite segments measure the same deviation.
        int current;
        int step;
        int last;
        if (end[0] > start[0] || (end[0] == start[0] && end[2] > start[2])) {
            step = 1;
            current = (start[3] + step) % raw_count;
            last = end[3];
        } else {
            step = raw_count - 1;
            current = (end[3] + step) % raw_count;
            last = start[3];
            @swap(start, end);
        }

        float max_deviation = 0;
        int max_index = -1;
        if ((raw[current][3] & CONTOUR_REGION_MASK) == 0 || (raw[current][3] & AREA_BORDER) != 0) {
            while (current != last) {
                float deviation = point_segment_distance_sq(raw[current], start, end);
                if (deviation > max_deviation) {
                    max_deviation = deviation;
                    max_index = current;
                }
                current = (current + step) % raw_count;
            }
        }

        if (max_index != -1 && max_deviation > max_error * max_error) {
            int[4] farthest = raw[max_index];
            insert_vertex(simplified, (sz)vertex + 1, { farthest[0], farthest[1], farthest[2], max_index })!;
        } else {
            vertex++;
        }
    }

    if (max_edge_length > 0 && (flags.tessellate_wall_edges || flags.tessellate_area_edges)) {
        for (int vertex = 0; vertex < simplified.count / 4;) {
            int[4][] vertices = vertex_view(simplified.view());
            int[4] start = vertices[vertex];
            int[4] end = vertices[(vertex + 1) % (int)vertices.len];

            int split_index = -1;
            int first_raw = (start[3] + 1) % raw_count;
            bool tessellate = (flags.tessellate_wall_edges && (raw[first_raw][3] & CONTOUR_REGION_MASK) == 0)
                || (flags.tessellate_area_edges && (raw[first_raw][3] & AREA_BORDER) != 0);
            if (tessellate) {
                int delta_x = end[0] - start[0];
                int delta_z = end[2] - start[2];
                if (delta_x * delta_x + delta_z * delta_z > max_edge_length * max_edge_length) {
                    int raw_span = end[3] < start[3] ? end[3] + raw_count - start[3] : end[3] - start[3];
                    // Round by lexicographic order so both directions of a shared edge split alike.
                    if (raw_span > 1) {
                        if (end[0] > start[0] || (end[0] == start[0] && end[2] > start[2])) {
                            split_index = (start[3] + raw_span / 2) % raw_count;
                        } else {
                            split_index = (start[3] + (raw_span + 1) / 2) % raw_count;
                        }
                    }
                }
            }

            if (split_index != -1) {
                int[4] split = raw[split_index];
                insert_vertex(simplified, (sz)vertex + 1, { split[0], split[1], split[2], split_index })!;
            } else {
                vertex++;
            }
        }
    }

    // The neighbour comes from the next raw point, the tile-border flag from the vertex's own.
    int[4][] vertices = vertex_view(simplified.view());
    for (sz vertex = 0; vertex < vertices.len; vertex++) {
        int current_raw = vertices[vertex][3];
        int next_raw = (current_raw + 1) % raw_count;
        int leaving_edge = raw[next_raw][3] & (CONTOUR_REGION_MASK | AREA_BORDER);
        vertices[vertex][3] = leaving_edge | (raw[current_raw][3] & BORDER_VERTEX);
    }
}

fn int signed_polygon_area(int[4][] vertices) @local {
    int area;
    sz previous = vertices.len - 1;
    for (sz current = 0; current < vertices.len; previous = current++) {
        area += vertices[current][0] * vertices[previous][2] - vertices[previous][0] * vertices[current][2];
    }
    return (area + 1) / 2;
}

fn void? remove_degenerate_segments(IntList* simplified) @local {
    int count = (int)(simplified.count / 4);
    for (int vertex = 0; vertex < count; vertex++) {
        int[4][] vertices = vertex_view(simplified.view());
        if (!equal_xz(&vertices[vertex][0], &vertices[next_index(vertex, count)][0])) continue;
        for (sz shifted = vertex; shifted < vertices.len - 1; shifted++) vertices[shifted] = vertices[shifted + 1];
        simplified.resize(simplified.count - 4)!;
        count--;
    }
}

fn bool in_cone(int[4][] vertices, int vertex, int* point) @local {
    int count = (int)vertices.len;
    int* current = &vertices[vertex][0];
    int* next = &vertices[next_index(vertex, count)][0];
    int* previous = &vertices[previous_index(vertex, count)][0];
    if (left_on(previous, current, next)) return left(current, point, previous) && left(point, current, next);
    return !(left_on(current, point, next) && left_on(point, current, previous));
}

fn bool intersect_segment_contour(
    int* segment_start,
    int* segment_end,
    int skipped_vertex,
    int[4][] vertices,
) @local {
    int count = (int)vertices.len;
    for (int edge = 0; edge < count; edge++) {
        int edge_end = next_index(edge, count);
        if (skipped_vertex == edge || skipped_vertex == edge_end) continue;
        int* edge_start_point = &vertices[edge][0];
        int* edge_end_point = &vertices[edge_end][0];
        if (equal_xz(segment_start, edge_start_point) || equal_xz(segment_end, edge_start_point)) continue;
        if (equal_xz(segment_start, edge_end_point) || equal_xz(segment_end, edge_end_point)) continue;
        if (intersect(a: segment_start, b: segment_end, c: edge_start_point, d: edge_end_point)) return true;
    }
    return false;
}

fn void? merge_contours(
    Allocator allocator,
    Contour* outline,
    Contour* hole,
    int outline_vertex,
    int hole_vertex,
) @local {
    int[4][] outline_vertices = vertex_view(outline.verts);
    int[4][] hole_vertices = vertex_view(hole.verts);
    int[]? merged = alloc::alloc_array_try(allocator, int, (outline_vertices.len + hole_vertices.len + 2) * 4);
    if (catch merged) return c3d::CAPACITY_EXCEEDED~;
    int[4][] merged_vertices = vertex_view(merged);

    sz written;
    for (sz offset = 0; offset <= outline_vertices.len; offset++) {
        merged_vertices[written++] = outline_vertices[(outline_vertex + offset) % outline_vertices.len];
    }
    for (sz offset = 0; offset <= hole_vertices.len; offset++) {
        merged_vertices[written++] = hole_vertices[(hole_vertex + offset) % hole_vertices.len];
    }

    alloc::free(allocator, outline.verts.ptr);
    outline.verts = merged;
    alloc::free(allocator, hole.verts.ptr);
    hole.verts = {};
}

fn void find_leftmost_vertex(ContourHole* hole) @local {
    int[4][] vertices = vertex_view(hole.contour.verts);
    hole.min_x = vertices[0][0];
    hole.min_z = vertices[0][2];
    hole.leftmost = 0;
    for (sz vertex = 1; vertex < vertices.len; vertex++) {
        int x = vertices[vertex][0];
        int z = vertices[vertex][2];
        if (x < hole.min_x || (x == hole.min_x && z < hole.min_z)) {
            hole.min_x = x;
            hole.min_z = z;
            hole.leftmost = (int)vertex;
        }
    }
}

fn int compare_holes(ContourHole* first, ContourHole* second) @local {
    if (first.min_x != second.min_x) return first.min_x < second.min_x ? -1 : 1;
    if (first.min_z != second.min_z) return first.min_z < second.min_z ? -1 : 1;
    return 0;
}

fn int compare_diagonals(PotentialDiagonal* first, PotentialDiagonal* second) @local {
    if (first.distance == second.distance) return 0;
    return first.distance < second.distance ? -1 : 1;
}

fn void? merge_region_holes(Allocator allocator, Allocator scratch, ContourRegion* region) @local {
    ContourHole[] holes = region.holes[:region.hole_count];
    foreach (&hole : holes) find_leftmost_vertex(hole);
    sort::insertionsort(holes, &compare_holes);

    // Every merge adds two bridge vertices to the outline.
    sz max_vertices = region.outline.verts.len / 4 + holes.len * 2;
    foreach (hole : holes) max_vertices += hole.contour.verts.len / 4;
    PotentialDiagonal[]? diagonals = alloc::alloc_array_try(scratch, PotentialDiagonal, max_vertices);
    if (catch diagonals) return c3d::CAPACITY_EXCEEDED~;
    defer alloc::free(scratch, diagonals.ptr);

    Contour* outline = region.outline;
    foreach (sz hole_index, hole : holes) {
        int[4][] hole_vertices = vertex_view(hole.contour.verts);
        int merge_vertex = -1;
        int best_vertex = hole.leftmost;
        for (sz attempt = 0; attempt < hole_vertices.len; attempt++) {
            int[4][] outline_vertices = vertex_view(outline.verts);
            int* corner = &hole_vertices[best_vertex][0];
            sz diagonal_count;
            for (int vertex = 0; vertex < outline_vertices.len; vertex++) {
                if (!in_cone(outline_vertices, vertex, corner)) continue;
                int delta_x = outline_vertices[vertex][0] - corner[0];
                int delta_z = outline_vertices[vertex][2] - corner[2];
                diagonals[diagonal_count++] = { .vertex = vertex, .distance = delta_x * delta_x + delta_z * delta_z };
            }
            sort::insertionsort(diagonals[:diagonal_count], &compare_diagonals);

            foreach (diagonal : diagonals[:diagonal_count]) {
                int* point = &outline_vertices[diagonal.vertex][0];
                // Upstream passes the hole index here; the incident edge to skip is the candidate's.
                bool intersects = intersect_segment_contour(
                    segment_start:  point,
                    segment_end:    corner,
                    skipped_vertex: diagonal.vertex,
                    vertices:       outline_vertices,
                );
                for (sz later = hole_index; later < holes.len && !intersects; later++) {
                    intersects = intersect_segment_contour(
                        segment_start:  point,
                        segment_end:    corner,
                        skipped_vertex: -1,
                        vertices:       vertex_view(holes[later].contour.verts),
                    );
                }
                if (intersects) continue;
                merge_vertex = diagonal.vertex;
                break;
            }
            if (merge_vertex != -1) break;
            best_vertex = (best_vertex + 1) % (int)hole_vertices.len;
        }
        if (merge_vertex == -1) continue;

        merge_contours(
            allocator:      allocator,
            outline:        outline,
            hole:           hole.contour,
            outline_vertex: merge_vertex,
            hole_vertex:    best_vertex,
        )!;
    }
}
