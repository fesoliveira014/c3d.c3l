// Altered source: C3 port of the triangle path of Morten S. Mikkelsen's MikkTSpace.
/** \file mikktspace/mikktspace.c
 *  \ingroup mikktspace
 */
/**
 *  Copyright (C) 2011 by Morten S. Mikkelsen
 *
 *  This software is provided 'as-is', without any express or implied
 *  warranty.  In no event will the authors be held liable for any damages
 *  arising from the use of this software.
 *
 *  Permission is granted to anyone to use this software for any purpose,
 *  including commercial applications, and to alter it and redistribute it
 *  freely, subject to the following restrictions:
 *
 *  1. The origin of this software must not be misrepresented; you must not
 *     claim that you wrote the original software. If you use this software
 *     in a product, an acknowledgment in the product documentation would be
 *     appreciated but is not required.
 *  2. Altered source versions must be plainly marked as such, and must not be
 *     misrepresented as being the original software.
 *  3. This notice may not be removed or altered from any source distribution.
 */

module c3d::geometry;

import c3d;
import std::core::mem::alloc;
import std::math;

const int MARK_DEGENERATE @private = 1;
const int GRID_CELLS @private = 2048;
const uint INTERNAL_RND_SORT_SEED @private = 39871946;
const int GROUP_WITH_ANY @private = 4;
const int ORIENT_PRESERVING @private = 8;
const int CORNERS_PER_TRIANGLE @private = 3;
const float REFERENCE_MIN_NORMAL @private = 0x1p-126;

struct MikkVector @private {
    float x;
    float y;
    float z;
}

struct MikkVertex @private {
    MikkVector position;
    MikkVector normal;
    float[2] uv;
}

struct MikkTangent @private {
    MikkVector direction;
    float sign;
}

$assert MikkTangent::size == 16;
$assert MikkVertex::size == 32;

struct MikkTriangle @private {
    int[3] vertices;
    int[3] neighbors;
    int[3] groups;
    MikkVector tangent;
    MikkVector bitangent;
    float magnitude_s;
    float magnitude_t;
    int flags;
    int face;
}

struct MikkGroup @private {
    int vertex;
    bool orientation;
    int[] faces;
    int count;
}

struct MikkFullMesh @private {
    MikkVertex[] vertices;
    uint[] indices;
}

struct MikkSpace @private {
    MikkVector tangent;
    float magnitude_s;
    MikkVector bitangent;
    float magnitude_t;
    int counter;
    bool orientation;
}

struct MikkTemporaryVertex @private {
    float[3] position;
    int index;
}

struct MikkEdge @private {
    int[3] values;
}

struct MikkRange @private {
    int left;
    int right;
    uint seed;
}

fn MikkVector mikk_add_vectors(MikkVector left, MikkVector right) @private {
    return { .x = left.x + right.x, .y = left.y + right.y, .z = left.z + right.z };
}

fn MikkVector mikk_subtract_vectors(MikkVector left, MikkVector right) @private {
    return { .x = left.x - right.x, .y = left.y - right.y, .z = left.z - right.z };
}

fn MikkVector mikk_scale_vector(float scale, MikkVector vector) @private {
    return { .x = scale * vector.x, .y = scale * vector.y, .z = scale * vector.z };
}

fn float mikk_dot_vectors(MikkVector left, MikkVector right) @private {
    return left.x * right.x + left.y * right.y + left.z * right.z;
}

fn float mikk_length_vector(MikkVector vector) @private {
    return math::sqrt(mikk_dot_vectors(vector, vector));
}

fn bool mikk_not_zero(float value) @private {
    return math::abs(value) > REFERENCE_MIN_NORMAL;
}

fn bool mikk_vector_not_zero(MikkVector vector) @private {
    return mikk_not_zero(vector.x) || mikk_not_zero(vector.y) || mikk_not_zero(vector.z);
}

fn MikkVector mikk_normalize_vector(MikkVector vector) @private {
    return mikk_scale_vector(1.0f / mikk_length_vector(vector), vector);
}

fn MikkVector mikk_project_normal(MikkVector vector, MikkVector normal) @private {
    MikkVector projected = mikk_subtract_vectors(vector, mikk_scale_vector(mikk_dot_vectors(normal, vector), normal));

    return mikk_vector_not_zero(projected) ? mikk_normalize_vector(projected) : projected;
}

fn bool mikk_equal_vectors(MikkVector left, MikkVector right) @private {
    return left.x == right.x && left.y == right.y && left.z == right.z;
}

fn bool mikk_equal_vertex(MikkVertex left, MikkVertex right) @private {
    return mikk_equal_vectors(left.position, right.position) && mikk_equal_vectors(left.normal, right.normal)
      && left.uv[0] == right.uv[0] && left.uv[1] == right.uv[1];
}

macro @tangent_array(Allocator allocator, $Type, usz count) @private {
    if (count > (usz)sz::max / $Type::size) return c3d::INVALID_ARGUMENT~;

    if (try result = alloc::new_array_try(allocator, $Type, (sz)count)) return result;

    return c3d::CAPACITY_EXCEEDED~;
}

fn MikkVertex mikk_indexed_vertex(MikkFullMesh source, int index) @private {
    int face = index >> 2;
    int corner = index & 3;

    return source.vertices[source.indices[face * CORNERS_PER_TRIANGLE + corner]];
}

fn MikkVector mikk_indexed_position(MikkFullMesh source, int index) @private {
    return mikk_indexed_vertex(source, index).position;
}

fn MikkVector mikk_indexed_normal(MikkFullMesh source, int index) @private {
    return mikk_indexed_vertex(source, index).normal;
}

fn MikkVector mikk_indexed_uv(MikkFullMesh source, int index) @private {
    float[2] uv = mikk_indexed_vertex(source, index).uv;

    return { .x = uv[0], .y = uv[1], .z = 1 };
}

fn float mikk_component(MikkVector vector, int channel) @private {
    return channel == 0 ? vector.x : (channel == 1 ? vector.y : vector.z);
}

fn int mikk_grid_cell(float minimum, float maximum, float value) @private @noinline {
    float scaled = GRID_CELLS * ((value - minimum) / (maximum - minimum));
    int index = (int)scaled;

    return index < GRID_CELLS ? (index >= 0 ? index : 0) : GRID_CELLS - 1;
}

fn void mikk_merge_vertices_fast(
    int[] indices,
    MikkTemporaryVertex[] temporary,
    MikkFullMesh source,
    int left,
    int right,
    MikkRange[] ranges,
) @private {
    int pending = 1;
    ranges[0] = { .left = left, .right = right };

    while (pending > 0) {
        MikkRange range = ranges[--pending];
        left = range.left;
        right = range.right;
        float[3] minimum = temporary[left].position;
        float[3] maximum = minimum;

        for (int i = left + 1; i <= right; i++) {
            for (int channel = 0; channel < 3; channel++) {
                if (minimum[channel] > temporary[i].position[channel]) minimum[channel] = temporary[i].position[channel];
                if (maximum[channel] < temporary[i].position[channel]) maximum[channel] = temporary[i].position[channel];
            }
        }

        float width_x = maximum[0] - minimum[0];
        float width_y = maximum[1] - minimum[1];
        float width_z = maximum[2] - minimum[2];

        int channel = 0;
        if (width_y > width_x && width_y > width_z) { channel = 1; }
        else if (width_z > width_x) { channel = 2; }

        float separation = 0.5f * (maximum[channel] + minimum[channel]);
        if (!math::is_finite(separation)) continue;

        if (separation >= maximum[channel] || separation <= minimum[channel]) {
            for (int i = left; i <= right; i++) {
                int destination = temporary[i].index;
                MikkVertex vertex = mikk_indexed_vertex(source, indices[destination]);

                for (int earlier = left; earlier < i; earlier++) {
                    int candidate = temporary[earlier].index;
                    if (mikk_equal_vertex(vertex, mikk_indexed_vertex(source, indices[candidate]))) {
                        indices[destination] = indices[candidate];
                        break;
                    }
                }
            }
        } else {
            int partition_left = left;
            int partition_right = right;

            while (partition_left < partition_right) {
                bool ready_left = false;
                bool ready_right = false;

                while (!ready_left && partition_left < partition_right) {
                    ready_left = !(temporary[partition_left].position[channel] < separation);
                    if (!ready_left) partition_left++;
                }

                while (!ready_right && partition_left < partition_right) {
                    ready_right = temporary[partition_right].position[channel] < separation;
                    if (!ready_right) partition_right--;
                }

                if (ready_left && ready_right) {
                    MikkTemporaryVertex swap = temporary[partition_left];
                    temporary[partition_left] = temporary[partition_right];
                    temporary[partition_right] = swap;
                    partition_left++;
                    partition_right--;
                }
            }

            if (partition_left == partition_right) {
                if (temporary[partition_right].position[channel] < separation) { partition_left++; }
                else { partition_right--; }
            }

            if (partition_left < right) ranges[pending++] = { .left = partition_left, .right = right };
            if (left < partition_right) ranges[pending++] = { .left = left, .right = partition_right };
        }
    }
}

fn void? mikk_weld_vertices(Allocator allocator, int[] indices, MikkFullMesh source) @private {
    MikkVector minimum = mikk_indexed_position(source, 0);
    MikkVector maximum = minimum;

    for (int i = 1; i < indices.len; i++) {
        MikkVector position = mikk_indexed_position(source, indices[i]);
        if (minimum.x > position.x) { minimum.x = position.x; }
        else if (maximum.x < position.x) { maximum.x = position.x; }
        if (minimum.y > position.y) { minimum.y = position.y; }
        else if (maximum.y < position.y) { maximum.y = position.y; }
        if (minimum.z > position.z) { minimum.z = position.z; }
        else if (maximum.z < position.z) { maximum.z = position.z; }
    }

    MikkVector width = mikk_subtract_vectors(maximum, minimum);
    int channel = 0;
    if (width.y > width.x && width.y > width.z) { channel = 1; }
    else if (width.z > width.x) { channel = 2; }
    float minimum_value = mikk_component(minimum, channel);
    float maximum_value = mikk_component(maximum, channel);

    int[] table = @tangent_array(allocator, int, indices.len)!;
    defer alloc::free(allocator, table);
    int[] counts = @tangent_array(allocator, int, GRID_CELLS)!;
    defer alloc::free(allocator, counts);
    int[] offsets = @tangent_array(allocator, int, GRID_CELLS)!;
    defer alloc::free(allocator, offsets);
    int[] inserted = @tangent_array(allocator, int, GRID_CELLS)!;
    defer alloc::free(allocator, inserted);

    foreach (index : indices) {
        float value = mikk_component(mikk_indexed_position(source, index), channel);
        counts[mikk_grid_cell(minimum_value, maximum_value, value)]++;
    }

    for (int cell = 1; cell < GRID_CELLS; cell++) offsets[cell] = offsets[cell - 1] + counts[cell - 1];

    foreach (i, index : indices) {
        float value = mikk_component(mikk_indexed_position(source, index), channel);
        int cell = mikk_grid_cell(minimum_value, maximum_value, value);
        table[offsets[cell] + inserted[cell]++] = (int)i;
    }

    int maximum_count = counts[0];

    for (int cell = 1; cell < GRID_CELLS; cell++) if (maximum_count < counts[cell]) maximum_count = counts[cell];

    MikkTemporaryVertex[] temporary = @tangent_array(allocator, MikkTemporaryVertex, (usz)maximum_count)!;
    defer alloc::free(allocator, temporary);
    MikkRange[] ranges = @tangent_array(allocator, MikkRange, (usz)maximum_count)!;
    defer alloc::free(allocator, ranges);

    for (int cell = 0; cell < GRID_CELLS; cell++) {
        int count = counts[cell];
        if (count < 2) continue;

        for (int entry = 0; entry < count; entry++) {
            int index = table[offsets[cell] + entry];
            MikkVector position = mikk_indexed_position(source, indices[index]);
            temporary[entry] = { .position = { position.x, position.y, position.z }, .index = index };
        }

        mikk_merge_vertices_fast(
            indices: indices,
            temporary: temporary,
            source: source,
            left: 0,
            right: count - 1,
            ranges: ranges,
        );
    }
}

fn uint mikk_rotated_seed(uint seed) @private {
    uint shift = seed & 31;
    // MSVC masks the complementary shift when the rotation count is zero.
    uint rotated = (seed << shift) | (seed >> ((32 - shift) & 31));

    return seed + rotated + 3;
}

fn void mikk_quick_sort_edges(
    MikkEdge[] edges,
    int left,
    int right,
    int channel,
    uint seed,
    MikkRange[] ranges,
) @private {
    int pending = 1;
    ranges[0] = { .left = left, .right = right, .seed = seed };

    while (pending > 0) {
        MikkRange range = ranges[--pending];
        left = range.left;
        right = range.right;
        seed = range.seed;
        int count = right - left + 1;
        if (count < 2) continue;

        if (count == 2) {
            if (edges[left].values[channel] > edges[right].values[channel]) {
                MikkEdge swap = edges[left];
                edges[left] = edges[right];
                edges[right] = swap;
            }
            continue;
        }

        seed = mikk_rotated_seed(seed);
        int partition_left = left;
        int partition_right = right;
        int pivot = edges[left + (int)(seed % (uint)count)].values[channel];

        do {
            while (edges[partition_left].values[channel] < pivot) partition_left++;

            while (edges[partition_right].values[channel] > pivot) partition_right--;

            if (partition_left <= partition_right) {
                MikkEdge swap = edges[partition_left];
                edges[partition_left] = edges[partition_right];
                edges[partition_right] = swap;
                partition_left++;
                partition_right--;
            }
        } while (partition_left <= partition_right);

        if (partition_left < right) ranges[pending++] = { .left = partition_left, .right = right, .seed = seed };
        if (left < partition_right) ranges[pending++] = { .left = left, .right = partition_right, .seed = seed };
    }
}

fn int[3] mikk_ordered_edge(MikkTriangle triangle, int first, int second) @private {
    int corner;
    if (triangle.vertices[0] == first || triangle.vertices[0] == second) {
        corner = (triangle.vertices[1] == first || triangle.vertices[1] == second) ? 0 : 2;
    } else { corner = 1; }

    return { triangle.vertices[corner], triangle.vertices[(corner + 1) % 3], corner };
}

fn void? mikk_build_neighbors(Allocator allocator, MikkTriangle[] triangles) @private {
    if (triangles.len == 0) return;

    MikkEdge[] edges = @tangent_array(allocator, MikkEdge, triangles.len * 3)!;
    defer alloc::free(allocator, edges);
    MikkRange[] ranges = @tangent_array(allocator, MikkRange, edges.len)!;
    defer alloc::free(allocator, ranges);

    foreach (face, triangle : triangles) {
        for (int corner = 0; corner < 3; corner++) {
            int first = triangle.vertices[corner];
            int second = triangle.vertices[(corner + 1) % 3];
            edges[face * 3 + corner].values = { first < second ? first : second,
              !(first < second) ? first : second, (int)face };
        }
    }

    mikk_quick_sort_edges(
        edges: edges,
        left: 0,
        right: (int)edges.len - 1,
        channel: 0,
        seed: INTERNAL_RND_SORT_SEED,
        ranges: ranges,
    );

    int start = 0;

    for (int i = 1; i < edges.len; i++) {
        if (edges[start].values[0] != edges[i].values[0]) {
            int previous_start = start;
            start = i;
            mikk_quick_sort_edges(
                edges: edges,
                left: previous_start,
                right: i - 1,
                channel: 1,
                seed: INTERNAL_RND_SORT_SEED,
                ranges: ranges,
            );
        }
    }

    start = 0;

    for (int i = 1; i < edges.len; i++) {
        if (edges[start].values[0] != edges[i].values[0] || edges[start].values[1] != edges[i].values[1]) {
            int previous_start = start;
            start = i;
            mikk_quick_sort_edges(
                edges: edges,
                left: previous_start,
                right: i - 1,
                channel: 2,
                seed: INTERNAL_RND_SORT_SEED,
                ranges: ranges,
            );
        }
    }

    for (int i = 0; i < edges.len; i++) {
        int first = edges[i].values[0];
        int second = edges[i].values[1];
        int face = edges[i].values[2];
        int[3] edge = mikk_ordered_edge(triangles[face], first, second);
        if (triangles[face].neighbors[edge[2]] >= 0) continue;

        int candidate = i + 1;
        int[3] other_edge;
        bool found = false;

        while (candidate < edges.len && first == edges[candidate].values[0]
          && second == edges[candidate].values[1] && !found) {
            int other = edges[candidate].values[2];
            other_edge = mikk_ordered_edge(triangles[other], edges[candidate].values[0], edges[candidate].values[1]);
            if (edge[0] == other_edge[1] && edge[1] == other_edge[0]
              && triangles[other].neighbors[other_edge[2]] < 0) { found = true; }
            else { candidate++; }
        }
        if (found) {
            int other = edges[candidate].values[2];
            triangles[face].neighbors[edge[2]] = other;
            triangles[other].neighbors[other_edge[2]] = face;
        }
    }
}

fn void mikk_quick_sort_members(
    int[] members,
    int left,
    int right,
    uint seed,
    MikkRange[] ranges,
) @private {
    int pending = 1;
    ranges[0] = { .left = left, .right = right, .seed = seed };

    while (pending > 0) {
        MikkRange range = ranges[--pending];
        left = range.left;
        right = range.right;
        seed = range.seed;

        seed = mikk_rotated_seed(seed);
        int partition_left = left;
        int partition_right = right;
        int count = right - left + 1;
        int pivot = members[left + (int)(seed % (uint)count)];

        do {
            while (members[partition_left] < pivot) partition_left++;

            while (members[partition_right] > pivot) partition_right--;

            if (partition_left <= partition_right) {
                int swap = members[partition_left];
                members[partition_left] = members[partition_right];
                members[partition_right] = swap;
                partition_left++;
                partition_right--;
            }
        } while (partition_left <= partition_right);

        if (partition_left < right) ranges[pending++] = { .left = partition_left, .right = right, .seed = seed };
        if (left < partition_right) ranges[pending++] = { .left = left, .right = partition_right, .seed = seed };
    }
}

fn int mikk_vertex_corner(MikkTriangle triangle, int vertex) @private {
    if (triangle.vertices[0] == vertex) return 0;
    if (triangle.vertices[1] == vertex) return 1;

    return 2;
}

fn void mikk_initialize_triangle(MikkTriangle* triangle, MikkFullMesh source) @private {
    triangle.neighbors = { -1, -1, -1 };
    triangle.groups = { -1, -1, -1 };
    triangle.flags |= GROUP_WITH_ANY;

    MikkVector first = mikk_indexed_position(source, triangle.vertices[0]);
    MikkVector second = mikk_indexed_position(source, triangle.vertices[1]);
    MikkVector third = mikk_indexed_position(source, triangle.vertices[2]);
    MikkVector uv0 = mikk_indexed_uv(source, triangle.vertices[0]);
    MikkVector uv1 = mikk_indexed_uv(source, triangle.vertices[1]);
    MikkVector uv2 = mikk_indexed_uv(source, triangle.vertices[2]);

    float delta_u1 = uv1.x - uv0.x;
    float delta_v1 = uv1.y - uv0.y;
    float delta_u2 = uv2.x - uv0.x;
    float delta_v2 = uv2.y - uv0.y;

    MikkVector edge1 = mikk_subtract_vectors(second, first);
    MikkVector edge2 = mikk_subtract_vectors(third, first);
    float signed_area = delta_u1 * delta_v2 - delta_v1 * delta_u2;
    MikkVector tangent = mikk_subtract_vectors(mikk_scale_vector(delta_v2, edge1), mikk_scale_vector(delta_v1, edge2));
    MikkVector bitangent = mikk_add_vectors(mikk_scale_vector(-delta_u2, edge1), mikk_scale_vector(delta_u1, edge2));

    if (signed_area > 0) triangle.flags |= ORIENT_PRESERVING;
    if (mikk_not_zero(signed_area)) {
        float tangent_length = mikk_length_vector(tangent);
        float bitangent_length = mikk_length_vector(bitangent);
        float sign = (triangle.flags & ORIENT_PRESERVING) == 0 ? -1.0f : 1.0f;
        if (mikk_not_zero(tangent_length)) triangle.tangent = mikk_scale_vector(sign / tangent_length, tangent);
        if (mikk_not_zero(bitangent_length)) triangle.bitangent = mikk_scale_vector(sign / bitangent_length, bitangent);

        triangle.magnitude_s = tangent_length / math::abs(signed_area);
        triangle.magnitude_t = bitangent_length / math::abs(signed_area);
        if (mikk_not_zero(triangle.magnitude_s) && mikk_not_zero(triangle.magnitude_t)) triangle.flags &= ~GROUP_WITH_ANY;
    }
}

fn void mikk_assign_group(
    MikkTriangle[] triangles,
    int face,
    MikkGroup* group,
    int group_index,
    int[] traversal,
) @private {
    int pending = 1;
    traversal[0] = face;

    while (pending > 0) {
        face = traversal[--pending];
        MikkTriangle* triangle = &triangles[face];
        int corner = mikk_vertex_corner(*triangle, group.vertex);
        if (triangle.groups[corner] >= 0) continue;

        if ((triangle.flags & GROUP_WITH_ANY) != 0 && triangle.groups[0] < 0
          && triangle.groups[1] < 0 && triangle.groups[2] < 0) {
            triangle.flags &= ~ORIENT_PRESERVING;
            if (group.orientation) triangle.flags |= ORIENT_PRESERVING;
        }

        if (((triangle.flags & ORIENT_PRESERVING) != 0) != group.orientation) continue;

        triangle.groups[corner] = group_index;
        group.faces[group.count++] = face;

        int left = triangle.neighbors[corner];
        int right = triangle.neighbors[(corner + 2) % 3];

        if (right >= 0) traversal[pending++] = right;
        if (left >= 0) traversal[pending++] = left;
    }
}

fn MikkSpace mikk_evaluate_space(
    MikkTriangle[] triangles,
    int[] faces,
    MikkFullMesh source,
    int representative,
) @private {
    MikkSpace sum;
    float angle_sum = 0;

    foreach (face : faces) {
        MikkTriangle triangle = triangles[face];
        if ((triangle.flags & GROUP_WITH_ANY) != 0) continue;

        int corner = mikk_vertex_corner(triangle, representative);
        MikkVector normal = mikk_indexed_normal(source, triangle.vertices[corner]);
        MikkVector tangent = mikk_project_normal(triangle.tangent, normal);
        MikkVector bitangent = mikk_project_normal(triangle.bitangent, normal);

        MikkVector position = mikk_indexed_position(source, triangle.vertices[corner]);
        MikkVector previous = mikk_indexed_position(source, triangle.vertices[(corner + 2) % 3]);
        MikkVector next = mikk_indexed_position(source, triangle.vertices[(corner + 1) % 3]);

        MikkVector edge1 = mikk_project_normal(mikk_subtract_vectors(previous, position), normal);
        MikkVector edge2 = mikk_project_normal(mikk_subtract_vectors(next, position), normal);

        float cosine = mikk_dot_vectors(edge1, edge2);
        cosine = cosine > 1 ? 1 : (cosine < -1 ? -1 : cosine);
        float angle = (float)math::acos((double)cosine);

        sum.tangent = mikk_add_vectors(sum.tangent, mikk_scale_vector(angle, tangent));
        sum.bitangent = mikk_add_vectors(sum.bitangent, mikk_scale_vector(angle, bitangent));
        sum.magnitude_s += angle * triangle.magnitude_s;
        sum.magnitude_t += angle * triangle.magnitude_t;
        angle_sum += angle;
    }

    if (mikk_vector_not_zero(sum.tangent)) sum.tangent = mikk_normalize_vector(sum.tangent);
    if (mikk_vector_not_zero(sum.bitangent)) sum.bitangent = mikk_normalize_vector(sum.bitangent);
    if (angle_sum > 0) {
        sum.magnitude_s /= angle_sum;
        sum.magnitude_t /= angle_sum;
    }

    return sum;
}

fn MikkSpace mikk_average_spaces(MikkSpace first, MikkSpace second) @private {
    MikkSpace result;
    if (first.magnitude_s == second.magnitude_s && first.magnitude_t == second.magnitude_t
      && mikk_equal_vectors(first.tangent, second.tangent) && mikk_equal_vectors(first.bitangent, second.bitangent)) {
        result.magnitude_s = first.magnitude_s;
        result.magnitude_t = first.magnitude_t;
        result.tangent = first.tangent;
        result.bitangent = first.bitangent;
    } else {
        result.magnitude_s = 0.5f * (first.magnitude_s + second.magnitude_s);
        result.magnitude_t = 0.5f * (first.magnitude_t + second.magnitude_t);
        result.tangent = mikk_add_vectors(first.tangent, second.tangent);
        result.bitangent = mikk_add_vectors(first.bitangent, second.bitangent);

        if (mikk_vector_not_zero(result.tangent)) result.tangent = mikk_normalize_vector(result.tangent);
        if (mikk_vector_not_zero(result.bitangent)) result.bitangent = mikk_normalize_vector(result.bitangent);
    }

    return result;
}

fn void mikk_initialize_faces(MikkTriangle[] triangles) @private {
    foreach (face, &triangle : triangles) {
        triangle.face = (int)face;

        for (int corner = 0; corner < 3; corner++) triangle.vertices[corner] = ((int)face << 2) | corner;
    }
}

fn int mikk_mark_and_pack_degenerates(MikkTriangle[] triangles, MikkFullMesh source) @private {
    int good_count = 0;

    foreach (&triangle : triangles) {
        MikkVector first = mikk_indexed_position(source, triangle.vertices[0]);
        MikkVector second = mikk_indexed_position(source, triangle.vertices[1]);
        MikkVector third = mikk_indexed_position(source, triangle.vertices[2]);
        if (mikk_equal_vectors(first, second) || mikk_equal_vectors(first, third) || mikk_equal_vectors(second, third)) {
            triangle.flags |= MARK_DEGENERATE;
        } else { good_count++; }
    }

    int next_good = 1;

    for (int face = 0; face < good_count; face++) {
        if ((triangles[face].flags & MARK_DEGENERATE) == 0) {
            if (next_good < face + 2) next_good = face + 2;
        } else {
            while ((triangles[next_good].flags & MARK_DEGENERATE) != 0) next_good++;

            MikkTriangle swap = triangles[face];
            triangles[face] = triangles[next_good];
            triangles[next_good++] = swap;
        }
    }

    return good_count;
}

fn void mikk_inherit_degenerate_spaces(MikkSpace[] spaces, MikkTriangle[] triangles, int good_count) @private {
    for (int face = good_count; face < triangles.len; face++) {
        MikkTriangle triangle = triangles[face];

        for (int corner = 0; corner < 3; corner++) {
            int representative = triangle.vertices[corner];
            bool found = false;

            for (int other = 0; other < good_count && !found; other++) {
                for (int other_corner = 0; other_corner < 3; other_corner++) {
                    MikkTriangle good = triangles[other];
                    if (good.vertices[other_corner] == representative) {
                        spaces[triangle.face * CORNERS_PER_TRIANGLE + corner]
                          = spaces[good.face * CORNERS_PER_TRIANGLE + other_corner];
                        found = true;
                        break;
                    }
                }
            }
        }
    }
}

fn MikkTangent[]? mikk_generate_full(Allocator allocator, MikkFullMesh source) @private {
    int corner_count = (int)source.indices.len;
    int triangle_count = corner_count / CORNERS_PER_TRIANGLE;

    MikkTriangle[] triangles = @tangent_array(allocator, MikkTriangle, (usz)triangle_count)!;
    defer alloc::free(allocator, triangles);

    mikk_initialize_faces(triangles);

    int[] welded = @tangent_array(allocator, int, (usz)triangle_count * 3)!;
    defer alloc::free(allocator, welded);

    foreach (face, triangle : triangles) {
        for (int corner = 0; corner < 3; corner++) welded[face * 3 + corner] = triangle.vertices[corner];
    }

    mikk_weld_vertices(allocator, welded, source)!;

    foreach (face, &triangle : triangles) {
        for (int corner = 0; corner < 3; corner++) triangle.vertices[corner] = welded[face * 3 + corner];
    }

    int good_count = mikk_mark_and_pack_degenerates(triangles, source);
    MikkTriangle[] good = triangles[:(usz)good_count];

    foreach (&triangle : good) mikk_initialize_triangle(triangle, source);

    mikk_build_neighbors(allocator, good)!;

    MikkGroup[] groups = @tangent_array(allocator, MikkGroup, (usz)good_count * 3)!;
    defer alloc::free(allocator, groups);
    int[] group_faces = @tangent_array(allocator, int, (usz)good_count * 3)!;
    defer alloc::free(allocator, group_faces);
    int[] traversal = @tangent_array(allocator, int, (usz)good_count * 3 + 1)!;
    defer alloc::free(allocator, traversal);
    MikkRange[] ranges = @tangent_array(allocator, MikkRange, (usz)good_count)!;
    defer alloc::free(allocator, ranges);

    float threshold_cosine = (float)math::cos((double)((180.0f * (float)math::PI) / 180.0f));
    int group_count = 0;
    int face_offset = 0;

    foreach (face, &triangle : good) {
        for (int corner = 0; corner < 3; corner++) {
            if ((triangle.flags & GROUP_WITH_ANY) != 0 || triangle.groups[corner] >= 0) continue;

            MikkGroup* group = &groups[group_count];
            group.vertex = triangle.vertices[corner];
            group.orientation = (triangle.flags & ORIENT_PRESERVING) != 0;
            group.faces = group_faces[(usz)face_offset..];

            mikk_assign_group(
                triangles: good,
                face: (int)face,
                group: group,
                group_index: group_count,
                traversal: traversal,
            );

            face_offset += group.count;
            group_count++;
        }
    }

    MikkSpace[] spaces = @tangent_array(allocator, MikkSpace, (usz)corner_count)!;
    defer alloc::free(allocator, spaces);

    foreach (&space : spaces) {
        *space = { .tangent = { .x = 1 }, .magnitude_s = 1, .bitangent = { .y = 1 }, .magnitude_t = 1 };
    }

    int[] members = @tangent_array(allocator, int, (usz)good_count)!;
    defer alloc::free(allocator, members);

    for (int group_index = 0; group_index < group_count; group_index++) {
        MikkGroup group = groups[group_index];
        MikkVector normal = mikk_indexed_normal(source, group.vertex);

        foreach (face : group.faces[:(usz)group.count]) {
            MikkTriangle triangle = good[face];
            MikkVector tangent = mikk_project_normal(triangle.tangent, normal);
            MikkVector bitangent = mikk_project_normal(triangle.bitangent, normal);
            int member_count = 0;

            foreach (other : group.faces[:(usz)group.count]) {
                MikkVector other_tangent = mikk_project_normal(good[other].tangent, normal);
                MikkVector other_bitangent = mikk_project_normal(good[other].bitangent, normal);

                if (((triangle.flags | good[other].flags) & GROUP_WITH_ANY) != 0 || triangle.face == good[other].face
                  || (mikk_dot_vectors(tangent, other_tangent) > threshold_cosine
                    && mikk_dot_vectors(bitangent, other_bitangent) > threshold_cosine)) {
                    members[member_count++] = other;
                }
            }

            if (member_count > 1) mikk_quick_sort_members(
                members: members,
                left: 0,
                right: member_count - 1,
                seed: INTERNAL_RND_SORT_SEED,
                ranges: ranges,
            );

            MikkSpace space = mikk_evaluate_space(
                triangles: good,
                faces: members[:(usz)member_count],
                source: source,
                representative: group.vertex,
            );

            int corner = mikk_vertex_corner(triangle, group.vertex);
            MikkSpace* output = &spaces[triangle.face * CORNERS_PER_TRIANGLE + corner];

            if (output.counter == 1) {
                *output = mikk_average_spaces(*output, space);
                output.counter = 2;
            } else {
                *output = space;
                output.counter = 1;
            }

            output.orientation = group.orientation;
        }
    }

    mikk_inherit_degenerate_spaces(spaces, triangles, good_count);

    MikkTangent[] output = @tangent_array(allocator, MikkTangent, (usz)corner_count)!;

    foreach (corner, space : spaces) {
        output[corner] = { .direction = space.tangent, .sign = space.orientation ? 1.0f : -1.0f };
    }

    return output;
}
