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
import std::core::mem::alloc;

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
