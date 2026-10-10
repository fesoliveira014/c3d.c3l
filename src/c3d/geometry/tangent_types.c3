// Altered source: C3 triangle and quad paths derived from Morten S. Mikkelsen's MikkTSpace.
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

const int MARK_DEGENERATE @private = 1;
const int QUAD_ONE_DEGENERATE @private = 2;
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
    float[2] uv0;
    float[2] uv1;
}

struct MikkTangent @private {
    MikkVector direction;
    float sign;
}

$assert MikkTangent::size == 16;
$assert MikkVertex::size == 40;

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
    int output_offset;
    int[3] vertex_numbers;
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
    int[] face_offsets;
    int[] face_sizes;
    uint uv_set;
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

fn bool mikk_finite_vector(MikkVector vector) @private {
    return math::is_finite(vector.x) && math::is_finite(vector.y) && math::is_finite(vector.z);
}

fn float[2] mikk_selected_uv(MikkVertex vertex, uint uv_set) @private {
    return uv_set == 0 ? vertex.uv0 : vertex.uv1;
}

fn bool mikk_equal_vertex(MikkVertex left, MikkVertex right, uint uv_set) @private {
    float[2] left_uv = mikk_selected_uv(left, uv_set);
    float[2] right_uv = mikk_selected_uv(right, uv_set);

    return mikk_equal_vectors(left.position, right.position) && mikk_equal_vectors(left.normal, right.normal)
      && left_uv[0] == right_uv[0] && left_uv[1] == right_uv[1];
}

macro @tangent_array(Allocator allocator, $Type, usz count) @private {
    if (count > (usz)sz::max / $Type::size) return c3d::INVALID_ARGUMENT~;

    if (try result = alloc::new_array_try(allocator, $Type, (sz)count)) return result;

    return c3d::CAPACITY_EXCEEDED~;
}
