module c3d::nav;

import std::math;

<* Wall segments a boundary keeps; mirrors MAX_LOCAL_SEGS. *>
const uint MAX_LOCAL_SEGMENTS = 8;

<* Polygons a boundary keeps; mirrors MAX_LOCAL_POLYS. *>
const uint MAX_LOCAL_POLYS = 16;

const usz MAX_SEGMENTS_PER_POLY @local = MAX_VERTS_PER_POLY * 3; // mirrors MAX_SEGS_PER_POLY; portals split border edges

<* Wall segment with its pruning distance. *>
struct BoundarySegment {
    Vec3  start;
    Vec3  end;
    float distance_sqr;    // XZ, from the boundary's centre
}

<* Nearby wall segments around an agent, nearest first; mirrors dtLocalBoundary. *>
struct LocalBoundary {
    Vec3                                center;    // float::max when empty
    BoundarySegment[MAX_LOCAL_SEGMENTS] segments;
    uint                                segment_count;
    PolyRef[MAX_LOCAL_POLYS]            polys;
    uint                                poly_count;
}

<* Forget every segment and polygon. *>
fn void LocalBoundary.reset(&self) {
    self.center = { float::max, float::max, float::max };
    self.poly_count = 0;
    self.segment_count = 0;
}

<*
 Gather the nearest wall segments within the range; mirrors update.
 @param ref : "Polygon of the position; 0 empties the boundary."
 @param [&in] query : "Searches the neighbourhood."
 @param [&in] filter : "Edges to polygons it rejects are walls."
*>
fn void LocalBoundary.update(
    &self,
    PolyRef ref,
    Vec3 position,
    float collision_query_range,
    NavQuery* query,
    QueryFilter* filter,
) {
    if (!ref) {
        self.reset();
        return;
    }
    self.center = position;
    self.poly_count = 0;
    self.segment_count = 0;
    DijkstraResult? neighbourhood = query.find_local_neighbourhood(
        start_ref: ref,
        center:    position,
        radius:    collision_query_range,
        filter:    filter,
        out_refs:  self.polys[..],
    );
    if (catch neighbourhood) return;
    self.poly_count = (uint)neighbourhood.count;

    float range_sqr = collision_query_range * collision_query_range;
    foreach (poly_ref : self.polys[:self.poly_count]) {
        WallSegment[MAX_SEGMENTS_PER_POLY] walls;
        QueryResult? found = query.poly_wall_segments(poly_ref, filter, walls[..]);
        if (catch found) continue;
        foreach (wall : walls[:found.count]) {
            // Upstream asks for walls alone; portals are not collision segments.
            if (wall.neighbour) continue;
            float distance_sqr = distance_pt_seg_sqr_2d(position, wall.start, wall.end).distance_sqr;
            if (distance_sqr > range_sqr) continue;
            add_boundary_segment(self, distance_sqr, wall.start, wall.end);
        }
    }
}

<*
 Whether every gathered polygon is still resident and passes the filter; mirrors isValid.
 @param [&in] query : "Tests the polygons."
 @param [&in] filter : "Polygons it rejects are invalid."
*>
fn bool LocalBoundary.is_valid(&self, NavQuery* query, QueryFilter* filter) {
    if (!self.poly_count) return false;
    foreach (ref : self.polys[:self.poly_count]) {
        if (!query.is_valid_ref(ref, filter)) return false;
    }
    return true;
}

// Mirrors addSegment: kept nearest first; a full boundary drops the furthest.
fn void add_boundary_segment(
    LocalBoundary* boundary,
    float distance_sqr,
    Vec3 start,
    Vec3 end,
) @local {
    uint count = boundary.segment_count;
    uint slot = count;
    if (count && distance_sqr < boundary.segments[count - 1].distance_sqr) {
        slot = 0;
        while (slot < count && distance_sqr > boundary.segments[slot].distance_sqr) slot++;
        uint moved = math::min(count - slot, MAX_LOCAL_SEGMENTS - slot - 1);
        for (uint index = moved; index > 0; index--) {
            boundary.segments[slot + index] = boundary.segments[slot + index - 1];
        }
    } else if (count >= MAX_LOCAL_SEGMENTS) {
        return;
    }
    boundary.segments[slot] = { .start = start, .end = end, .distance_sqr = distance_sqr };
    if (count < MAX_LOCAL_SEGMENTS) boundary.segment_count++;
}
