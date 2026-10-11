// Altered source: C3 port of the recorded MikkTSpace stage.
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
import std::core::mem::alloc, std::math;

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

fn bool mikk_full_mesh_valid(MikkFullMesh source) @private {
    if (!source.indices.len || source.indices.len % CORNERS_PER_TRIANGLE != 0 || source.uv_set > 1) return false;
    if (source.indices.len / CORNERS_PER_TRIANGLE > (usz)(int::max >> 2)) return false;

    foreach (index : source.indices) if (index >= source.vertices.len) return false;

    foreach (vertex : source.vertices) {
        float[2] uv = mikk_selected_uv(vertex, source.uv_set);
        if (!mikk_finite_vector(vertex.position) || !mikk_finite_vector(vertex.normal)
          || !math::is_finite(uv[0]) || !math::is_finite(uv[1])) return false;
    }

    return true;
}

<*
 Generate per-corner reference tangent spaces.
 @require mikk_full_mesh_valid(source)
*>
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
                int corner = mikk_vertex_corner(good[other], group.vertex);
                if (good[other].groups[corner] != group_index) continue;

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
