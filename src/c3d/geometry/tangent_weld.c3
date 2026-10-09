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

fn MikkVertex mikk_indexed_vertex(MikkFullMesh source, int index) @private {
    int face = index >> 2;
    int corner = index & 3;

    return source.vertices[source.indices[source.face_offsets[face] + corner]];
}

fn MikkVector mikk_indexed_position(MikkFullMesh source, int index) @private {
    return mikk_indexed_vertex(source, index).position;
}

fn MikkVector mikk_indexed_normal(MikkFullMesh source, int index) @private {
    return mikk_indexed_vertex(source, index).normal;
}

fn MikkVector mikk_indexed_uv(MikkFullMesh source, int index) @private {
    float[2] uv = mikk_selected_uv(mikk_indexed_vertex(source, index), source.uv_set);

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
                    if (mikk_equal_vertex(vertex, mikk_indexed_vertex(source, indices[candidate]), source.uv_set)) {
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
