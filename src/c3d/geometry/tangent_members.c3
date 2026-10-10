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
