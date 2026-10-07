module c3d::physics::fracture;

import c3d;

struct SiteBisector @private {
    ExactPlane plane;
    uint first;
    uint second;
    bool first_reversed;
}

struct VoronoiPartition @private {
    SiteBisector[] bisectors;
    SolidPartition[] sites;
}

fn usz voronoi_bisector_index(usz count, usz first, usz second) @local {
    return first * count - first * (first + 1) / 2 + second - first - 1;
}

fn VoronoiPartition? partition_voronoi_cells(
    SolidScratch* scratch,
    SolidPartition* source,
    GridPoint[] sites,
) @private {
    usz saved = scratch.used;
    defer catch scratch.used = saved;
    usz count = sites.len;
    if (count > uint::max || (count > 1 && count > usz::max / (count - 1))) return c3d::CAPACITY_EXCEEDED~;
    usz pairs = count ? count * (count - 1) / 2 : 0;
    VoronoiPartition result = {
        .bisectors = reserve_elements(scratch, SiteBisector, pairs)!,
        .sites = reserve_elements(scratch, SolidPartition, count)!,
    };
    foreach (&site : result.sites) *site = {};
    usz index;
    for (uint first = 0; first < count; first++) {
        for (uint second = first + 1; second < count; second++) {
            SiteBisector* bisector = &result.bisectors[index++];
            bisector.first = first;
            bisector.second = second;
            bisector.first_reversed = bisector_plane(
                scratch: scratch.exact,
                output: &bisector.plane,
                first: sites[first],
                second: sites[second],
            )!;
        }
    }
    foreach (uint site, &partition : result.sites) {
        PartitionCell* last;
        for (PartitionCell* original = source.first; original; original = original.next) {
            if (!original.occupied) continue;
            usz cell_start = scratch.used;
            ConvexCell cell = original.cell;
            for (uint other = 0; other < count; other++) {
                if (other == site) continue;
                uint first = site < other ? site : other;
                uint second = site < other ? other : site;
                SiteBisector* bisector = &result.bisectors[voronoi_bisector_index(count, first, second)];
                CellSplit split = split_convex_cell(scratch, &cell, &bisector.plane)!;
                bool positive = site == first ? bisector.first_reversed : !bisector.first_reversed;
                cell = positive ? split.positive : split.negative;
                if (!cell.vertices.len) break;
            }
            if (!cell.vertices.len) {
                scratch.used = cell_start;
                continue;
            }
            PartitionCell* retained = &reserve_elements(scratch, PartitionCell, 1)![0];
            *retained = { .cell = cell, .occupied = true };
            if (last) {
                last.next = retained;
            } else {
                partition.first = retained;
            }
            last = retained;
            partition.cell_count++;
            partition.occupied_count++;
        }
    }
    return result;
}
