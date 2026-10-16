module c3d::nav;

import c3d;

const uint CLEARANCE_NO_FACE @private = uint::max;

struct ClearanceFace @private {
    ClearancePoint[] vertices;
    uint first_edge;
    uint edge_count;
    uint source;
}

struct ClearanceEdge @private {
    ClearancePoint first;
    ClearancePoint last;
    uint neighbour;
}

struct ClearanceDomain @private {
    ClearanceRectangle captured;
    ClearanceFace[] faces;
    ClearanceEdge[] edges;
    ClearanceSource* source;
    TileConfig* config;
    Obstacle[] obstacles;
    VolumeRecord[] volumes;
}

struct ClearanceWork @private {
    uint[] queue;
    uint[] seen;
    uint epoch;
}

fn ClearanceWork? create_clearance_work(Allocator allocator, usz face_count) @private {
    uint[]? queue = alloc::alloc_array_try(allocator, uint, (sz)face_count);
    if (catch queue) return c3d::CAPACITY_EXCEEDED~;

    uint[]? seen = alloc::new_array_try(allocator, uint, (sz)face_count);
    if (catch seen) return c3d::CAPACITY_EXCEEDED~;

    return { .queue = queue, .seen = seen };
}

fn bool? clearance_admits(
    ClearanceDomain* domain,
    uint root,
    ClearanceRectangle square,
    ClearanceSettings settings,
    double agent_radius,
    double storage_delta,
    ClearanceWork* work,
) @private {
    if (root >= domain.faces.len || work.queue.len < domain.faces.len || work.seen.len < domain.faces.len
        || storage_delta < 0 || storage_delta > settings.storage_limit) return c3d::CAPACITY_EXCEEDED~;
    PrecisionInterval radius = precision_add(
        precision_add(precision_point(agent_radius)!, precision_point(storage_delta)!)!,
        precision_point(settings.interval_limit)!,
    )!;
    PrecisionInterval outer_radius = precision_add(radius, precision_point(settings.interval_limit)!)!;
    PrecisionInterval[4] capture_gaps = {
        precision_subtract(square.min_x, domain.captured.min_x)!,
        precision_subtract(square.min_z, domain.captured.min_z)!,
        precision_subtract(domain.captured.max_x, square.max_x)!,
        precision_subtract(domain.captured.max_z, square.max_z)!,
    };
    foreach (gap : capture_gaps) {
        if (precision_subtract(gap, outer_radius)!.min <= 0) return c3d::CAPACITY_EXCEEDED~;
    }
    if (work.epoch == uint::max) {
        work.seen[..] = 0;
        work.epoch = 0;
    }
    work.epoch++;
    uint count = 1;
    work.queue[0] = root;
    work.seen[root] = work.epoch;
    for (uint cursor = 0; cursor < count; cursor++) {
        ClearanceFace face = domain.faces[work.queue[cursor]];
        if ((domain.obstacles.len || domain.volumes.len) && clearance_obstacle_meets(
            source: domain.source,
            surface_index: face.source,
            fan: work.queue[cursor] & 3,
            config: domain.config,
            square: square,
            radius: radius,
            interval_limit: settings.interval_limit,
            obstacles: domain.obstacles,
            volumes: domain.volumes,
        )!) return false;
        foreach (edge : domain.edges[face.first_edge:face.edge_count]) {
            if (edge.neighbour != CLEARANCE_NO_FACE && work.seen[edge.neighbour] == work.epoch) continue;
            if (!clearance_neighborhood_meets(
                first: edge.first,
                last: edge.last,
                rectangle: square,
                radius: radius,
                interval_limit: settings.interval_limit,
            )!) continue;
            if (edge.neighbour == CLEARANCE_NO_FACE) return false;
            if (count == work.queue.len) return c3d::CAPACITY_EXCEEDED~;
            work.seen[edge.neighbour] = work.epoch;
            work.queue[count++] = edge.neighbour;
        }
    }
    return true;
}
