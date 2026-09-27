module c3d::nav;

import std::math;
import c3d;

<* Random number in [0, 1) for point sampling. *>
alias RandomFn = fn float (void* context);

const usz   MAX_STACK @local = 48; // mirrors MAX_STACK of findLocalNeighbourhood and moveAlongSurface: polygons queued
const usz   MAX_NEIGHBOURS @local = 8; // mirrors moveAlongSurface's MAX_NEIS: portals followed per edge
const usz   MAX_INTERVALS @local = 16; // mirrors getPolyWallSegments' MAX_INTERVAL: portal pieces per edge
const float SEARCH_RADIUS_MARGIN @local = 0.001f; // metres; mirrors moveAlongSurface's slack on its search circle

enum SearchShape @local {
    CIRCLE,
    POLYGON,
}

<* Polygons a Dijkstra search reached. *>
struct DijkstraResult {
    usz  count;
    bool truncated;    // out_refs or the node pool filled up; reachable polygons may be missing
}

<* Result of move_along_surface. *>
struct MoveResult {
    Vec3 position;         // not projected onto the surface; poly_height gives its height
    usz  visited_count;
    bool truncated;        // out_visited filled up; the chain keeps its start
}

<* Nearest wall to a point. *>
struct WallHit {
    float distance;
    Vec3  point;
    Vec3  normal;      // from the wall point toward the source
}

<* One boundary segment of a polygon and the neighbour across it. *>
struct WallSegment {
    Vec3    start;
    Vec3    end;
    PolyRef neighbour;    // 0 for a wall
}

<* A point on the mesh and its polygon. *>
struct RandomPoint {
    PolyRef ref;
    Vec3    point;
}

struct SearchBoundary @local {
    SearchShape shape;
    Vec3        center;
    float       radius_sqr;    // CIRCLE
    Vec3[]      vertices;      // POLYGON
}

// First in, first out, as upstream's stack of the local walks.
struct BreadthQueue @local {
    SearchNode*[MAX_STACK] nodes;
    usz                    count;
}

struct PortalInterval @local {
    short   min;    // along the edge, 0..255
    short   max;
    PolyRef ref;
}

struct IntervalList @local {
    PortalInterval[MAX_INTERVALS] items;
    usz                           count;
}

<*
 Polygons reachable from start whose portals touch the circle, nearest first; mirrors findPolysAroundCircle.
 @param center : "Start of the cost measurement; the circle's centre in XZ."
 @param [&in] filter : "Polygons it rejects are not entered."
 @param [out] out_refs : "Filled up to its length."
 @param [out] out_parents : "Parent per result, 0 at the start; empty when not wanted."
 @param [out] out_costs : "Search cost per result; empty when not wanted."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
 @require out_parents.len == 0 || out_parents.len >= out_refs.len
 @require out_costs.len == 0 || out_costs.len >= out_refs.len
*>
fn DijkstraResult? NavQuery.find_polys_around_circle(
    &self,
    PolyRef start_ref,
    Vec3 center,
    float radius,
    QueryFilter* filter,
    PolyRef[] out_refs,
    PolyRef[] out_parents = {},
    float[] out_costs = {},
) {
    if (!self.mesh.is_valid_ref(start_ref)) return INVALID_REF~;
    if (!finite_point(center) || !valid_radius(radius)) return c3d::INVALID_ARGUMENT~;
    SearchBoundary circle = { .shape = CIRCLE, .center = center, .radius_sqr = radius * radius };
    return dijkstra_search(
        query:       self,
        start_ref:   start_ref,
        boundary:    &circle,
        filter:      filter,
        out_refs:    out_refs,
        out_parents: out_parents,
        out_costs:   out_costs,
    );
}

<*
 Polygons reachable from start whose portals touch the convex polygon; mirrors findPolysAroundShape.
 @param vertices : "Counter-clockwise seen from above; their centroid starts the cost measurement."
 @param [&in] filter : "Polygons it rejects are not entered."
 @param [out] out_refs : "Filled up to its length."
 @param [out] out_parents : "Parent per result, 0 at the start; empty when not wanted."
 @param [out] out_costs : "Search cost per result; empty when not wanted."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
 @require vertices.len >= 3
 @require out_parents.len == 0 || out_parents.len >= out_refs.len
 @require out_costs.len == 0 || out_costs.len >= out_refs.len
*>
fn DijkstraResult? NavQuery.find_polys_around_shape(
    &self,
    PolyRef start_ref,
    Vec3[] vertices,
    QueryFilter* filter,
    PolyRef[] out_refs,
    PolyRef[] out_parents = {},
    float[] out_costs = {},
) {
    if (!self.mesh.is_valid_ref(start_ref)) return INVALID_REF~;
    Vec3 center;
    foreach (vertex : vertices) {
        if (!finite_point(vertex)) return c3d::INVALID_ARGUMENT~;
        center += vertex;
    }
    SearchBoundary shape = { .shape = POLYGON, .center = center / (float)vertices.len, .vertices = vertices };
    return dijkstra_search(
        query:       self,
        start_ref:   start_ref,
        boundary:    &shape,
        filter:      filter,
        out_refs:    out_refs,
        out_parents: out_parents,
        out_costs:   out_costs,
    );
}

<*
 Corridor from the start of the last Dijkstra search to a polygon it explored; mirrors getPathFromDijkstraSearch.
 Valid only right after find_polys_around_circle or find_polys_around_shape.
 @param [out] out_path : "Start to end_ref; filled up to its length."
 @return? INVALID_REF, NO_PATH
*>
fn PathResult? NavQuery.path_from_dijkstra_search(&self, PolyRef end_ref, PolyRef[] out_path) {
    if (!self.mesh.is_valid_ref(end_ref)) return INVALID_REF~;
    SearchNode*[1] explored;
    if (self.nodes.find_nodes(end_ref, explored[..]) != 1 || !explored[0].bits.closed) return NO_PATH~;
    return path_to_node(&self.nodes, explored[0], out_path);
}

<*
 Non-overlapping polygons around the center within the radius; mirrors findLocalNeighbourhood.
 @param [&in] filter : "Polygons it rejects are not entered."
 @param [out] out_refs : "Filled up to its length."
 @param [out] out_parents : "Parent per result, 0 at the start; empty when not wanted."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
 @require out_parents.len == 0 || out_parents.len >= out_refs.len
*>
fn DijkstraResult? NavQuery.find_local_neighbourhood(
    &self,
    PolyRef start_ref,
    Vec3 center,
    float radius,
    QueryFilter* filter,
    PolyRef[] out_refs,
    PolyRef[] out_parents = {},
) {
    NavMesh* mesh = self.mesh;
    if (!mesh.is_valid_ref(start_ref)) return INVALID_REF~;
    if (!finite_point(center) || !valid_radius(radius)) return c3d::INVALID_ARGUMENT~;

    NodePool* nodes = &self.tiny_nodes;
    nodes.clear();
    BreadthQueue queue;
    SearchNode* start_node = nodes.get_node(start_ref);
    start_node.bits.closed = true;
    push_back(&queue, start_node);
    float radius_sqr = radius * radius;
    DijkstraResult result;
    record_result(
        result:      &result,
        out_refs:    out_refs,
        out_parents: out_parents,
        out_costs:   {},
        ref:         start_ref,
        parent_ref:  (PolyRef)0,
        cost:        0,
    );

    while (queue.count) {
        SearchNode* current = pop_front(&queue);
        TileAndPoly found = mesh.tile_and_poly_unchecked(current.id);
        for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
            PolyRef neighbour_ref = found.tile.links[link].ref;
            if (!neighbour_ref) continue;
            SearchNode* node = nodes.get_node(neighbour_ref);
            if (!node || node.bits.closed) continue;
            TileAndPoly neighbour = mesh.tile_and_poly_unchecked(neighbour_ref);
            if (neighbour.poly.area_type.type == OFF_MESH_CONNECTION) continue;
            if (!filter.passes(neighbour_ref, neighbour.poly)) continue;
            Portal? portal = portal_points(current.id, found, neighbour_ref, neighbour);
            if (catch portal) continue;
            if (distance_pt_seg_sqr_2d(center, portal.left, portal.right).distance_sqr > radius_sqr) continue;

            // Visited before the overlap test, so a rejected polygon is not tried again.
            node.bits.closed = true;
            node.bits.parent = nodes.node_index(current);
            bool overlap = overlaps_results(
                mesh:      mesh,
                current:   found,
                candidate: neighbour,
                results:   out_refs[:result.count],
            );
            if (overlap) continue;
            record_result(
                result:      &result,
                out_refs:    out_refs,
                out_parents: out_parents,
                out_costs:   {},
                ref:         neighbour_ref,
                parent_ref:  current.id,
                cost:        0,
            );
            push_back(&queue, node);
        }
    }
    return result;
}

<*
 Move from start toward end, sliding along walls; mirrors moveAlongSurface.
 @param start : "Inside the start polygon."
 @param [&in] filter : "Polygons it rejects are walls."
 @param [out] out_visited : "Polygons crossed, start first; filled up to its length."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
*>
fn MoveResult? NavQuery.move_along_surface(
    &self,
    PolyRef start_ref,
    Vec3 start,
    Vec3 end,
    QueryFilter* filter,
    PolyRef[] out_visited,
) {
    NavMesh* mesh = self.mesh;
    if (!mesh.is_valid_ref(start_ref)) return INVALID_REF~;
    if (!finite_point(start) || !finite_point(end)) return c3d::INVALID_ARGUMENT~;

    NodePool* nodes = &self.tiny_nodes;
    nodes.clear();
    BreadthQueue queue;
    SearchNode* start_node = nodes.get_node(start_ref);
    start_node.bits.closed = true;
    push_back(&queue, start_node);

    Vec3 best_position = start;
    float best_distance = float::max;
    SearchNode* best_node;
    Vec3 search_center = lerp_point(start, end, 0.5f);
    float search_radius = (end - start).length() * 0.5f + SEARCH_RADIUS_MARGIN;
    float search_radius_sqr = search_radius * search_radius;

    while (queue.count) {
        SearchNode* current = pop_front(&queue);
        TileAndPoly found = mesh.tile_and_poly_unchecked(current.id);
        Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(found.tile, found.poly);
        Vec3[] corners = verts[:found.poly.vert_count];
        if (point_in_polygon(end, corners)) {
            best_node = current;
            best_position = end;
            break;
        }

        usz edge = corners.len - 1;
        for (usz vertex = 0; vertex < corners.len; edge = vertex++) {
            PolyRef[MAX_NEIGHBOURS] neighbours;
            usz neighbour_count = passable_neighbours(
                mesh:     mesh,
                found:    found,
                edge:     edge,
                filter:   filter,
                out_refs: neighbours[..],
            );
            if (!neighbour_count) {
                SegmentProjection projection = distance_pt_seg_sqr_2d(end, corners[edge], corners[vertex]);
                if (projection.distance_sqr < best_distance) {
                    best_position = lerp_point(corners[edge], corners[vertex], projection.t);
                    best_distance = projection.distance_sqr;
                    best_node = current;
                }
                continue;
            }
            foreach (neighbour_ref : neighbours[:neighbour_count]) {
                SearchNode* node = nodes.get_node(neighbour_ref);
                if (!node || node.bits.closed) continue;
                // The whole edge stands in for the portal, as upstream does for speed.
                SegmentProjection projection = distance_pt_seg_sqr_2d(search_center, corners[edge], corners[vertex]);
                if (projection.distance_sqr > search_radius_sqr) continue;
                if (queue.count == MAX_STACK) continue;
                node.bits.parent = nodes.node_index(current);
                node.bits.closed = true;
                push_back(&queue, node);
            }
        }
    }

    MoveResult result = { .position = best_position };
    if (!best_node) return result;
    PathResult chain = path_to_node(nodes, best_node, out_visited);
    result.visited_count = chain.count;
    result.truncated = chain.truncated;
    return result;
}

<*
 Nearest wall within max_radius of the point, searching through portals; mirrors findDistanceToWall.
 @param [&in] filter : "Edges to polygons it rejects are walls."
 @return "Distance max_radius and a zero normal when no wall lies within it."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
*>
fn WallHit? NavQuery.find_distance_to_wall(
    &self,
    PolyRef start_ref,
    Vec3 center,
    float max_radius,
    QueryFilter* filter,
) {
    NavMesh* mesh = self.mesh;
    if (!mesh.is_valid_ref(start_ref)) return INVALID_REF~;
    if (!finite_point(center) || !valid_radius(max_radius)) return c3d::INVALID_ARGUMENT~;

    self.nodes.clear();
    self.open.clear();
    SearchNode* start_node = self.nodes.get_node(start_ref);
    start_node.position = center;
    start_node.bits.open = true;
    self.open.push(start_node);

    WallHit hit = { .point = center };
    float radius_sqr = max_radius * max_radius;
    while (!self.open.is_empty()) {
        SearchNode* current = self.open.pop();
        current.bits.open = false;
        current.bits.closed = true;
        TileAndPoly found = mesh.tile_and_poly_unchecked(current.id);
        SearchNode* parent = self.nodes.node_at(current.bits.parent);
        PolyRef parent_ref = parent ? parent.id : (PolyRef)0;

        Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(found.tile, found.poly);
        usz vert_count = found.poly.vert_count;
        usz edge = vert_count - 1;
        for (usz vertex = 0; vertex < vert_count; edge = vertex++) {
            bool wall = is_wall_edge(
                mesh:   mesh,
                found:  found,
                edge:   edge,
                filter: filter,
            );
            if (!wall) continue;
            SegmentProjection projection = distance_pt_seg_sqr_2d(center, verts[edge], verts[vertex]);
            if (projection.distance_sqr > radius_sqr) continue;
            radius_sqr = projection.distance_sqr;
            hit.point = lerp_point(verts[edge], verts[vertex], projection.t);
        }

        for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
            Link* entry = &found.tile.links[link];
            PolyRef neighbour_ref = entry.ref;
            if (!neighbour_ref || neighbour_ref == parent_ref) continue;
            TileAndPoly neighbour = mesh.tile_and_poly_unchecked(neighbour_ref);
            if (neighbour.poly.area_type.type == OFF_MESH_CONNECTION) continue;
            Vec3 edge_start = verts[entry.edge];
            Vec3 edge_end = verts[((usz)entry.edge + 1) % vert_count];
            if (distance_pt_seg_sqr_2d(center, edge_start, edge_end).distance_sqr > radius_sqr) continue;
            if (!filter.passes(neighbour_ref, neighbour.poly)) continue;

            SearchNode* node = self.nodes.get_node(neighbour_ref);
            if (!node || node.bits.closed) continue;
            if (first_visit(node)) {
                if (try portal = portal_points(current.id, found, neighbour_ref, neighbour)) {
                    node.position = (portal.left + portal.right) * 0.5f;
                }
            }
            float total = current.total + (current.position - node.position).length();
            if (node.bits.open && total >= node.total) continue;
            node.id = neighbour_ref;
            node.bits.parent = self.nodes.node_index(current);
            node.total = total;
            if (node.bits.open) {
                self.open.modify(node);
            } else {
                node.bits.open = true;
                self.open.push(node);
            }
        }
    }

    hit.distance = math::sqrt(radius_sqr);
    hit.normal = (center - hit.point).normalize();
    return hit;
}

<*
 Boundary segments of a polygon and the neighbour across each; mirrors getPolyWallSegments.
 @param [in] filter : "Neighbours it rejects are walls; null returns whole edges with neighbour 0 for every edge."
 @param [out] out_segments : "Filled up to its length."
 @return? INVALID_REF
*>
fn QueryResult? NavQuery.poly_wall_segments(
    &self,
    PolyRef ref,
    QueryFilter* filter,
    WallSegment[] out_segments,
) {
    NavMesh* mesh = self.mesh;
    TileAndPoly found = mesh.tile_and_poly(ref)!;
    Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(found.tile, found.poly);
    usz vert_count = found.poly.vert_count;
    QueryResult result;
    usz edge = vert_count - 1;
    for (usz vertex = 0; vertex < vert_count; edge = vertex++) {
        Vec3 edge_start = verts[edge];
        Vec3 edge_end = verts[vertex];
        ushort neighbour_word = found.poly.neighbours[edge];
        if (!filter || (neighbour_word & EXTERNAL_LINK) == 0) {
            PolyRef neighbour_ref;
            if (filter && neighbour_word) {
                neighbour_ref = mesh.poly_ref_base(found.tile) | (PolyRef)(neighbour_word - 1);
                if (!filter.passes(neighbour_ref, &found.tile.polys[neighbour_word - 1])) neighbour_ref = (PolyRef)0;
            }
            append_segment(&result, out_segments, { .start = edge_start, .end = edge_end, .neighbour = neighbour_ref });
            continue;
        }

        IntervalList intervals;
        for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
            Link* entry = &found.tile.links[link];
            if (entry.edge != edge || !entry.ref) continue;
            if (!filter.passes(entry.ref, mesh.tile_and_poly_unchecked(entry.ref).poly)) continue;
            insert_interval(
                list: &intervals,
                min:  entry.min,
                max:  entry.max,
                ref:  entry.ref,
            );
        }
        // Sentinels before and after the edge, so the walls between portals fall out of one loop.
        insert_interval(
            list: &intervals,
            min:  -1,
            max:  0,
            ref:  (PolyRef)0,
        );
        insert_interval(
            list: &intervals,
            min:  char::max,
            max:  (short)char::max + 1,
            ref:  (PolyRef)0,
        );
        for (usz index = 1; index < intervals.count; index++) {
            PortalInterval interval = intervals.items[index];
            if (interval.ref) {
                append_segment(&result, out_segments, {
                    .start     = lerp_point(edge_start, edge_end, interval.min * PORTAL_LIMIT_STEP),
                    .end       = lerp_point(edge_start, edge_end, interval.max * PORTAL_LIMIT_STEP),
                    .neighbour = interval.ref,
                });
            }
            short wall_min = intervals.items[index - 1].max;
            short wall_max = interval.min;
            if (wall_min == wall_max) continue;
            append_segment(&result, out_segments, {
                .start = lerp_point(edge_start, edge_end, wall_min * PORTAL_LIMIT_STEP),
                .end   = lerp_point(edge_start, edge_end, wall_max * PORTAL_LIMIT_STEP),
            });
        }
    }
    return result;
}

<*
 Point on a polygon chosen by area over the whole mesh; mirrors findRandomPoint.
 Linear in the polygon count.
 @param [&in] filter : "Polygons it rejects are never chosen."
 @param random : "Returns [0, 1)."
 @param [in] context : "Passed to random."
 @return? NO_POLY
*>
fn RandomPoint? NavQuery.find_random_point(
    &self,
    QueryFilter* filter,
    RandomFn random,
    void* context,
) {
    NavMesh* mesh = self.mesh;
    TileAndPoly chosen;
    PolyRef chosen_ref;
    float area_sum = 0;
    foreach (&tile : mesh.tiles) {
        if (!tile.header) continue;
        PolyRef base = mesh.poly_ref_base(tile);
        foreach (index, &poly : tile.polys) {
            if (poly.area_type.type != GROUND) continue;
            PolyRef ref = base | (PolyRef)index;
            if (!filter.passes(ref, poly)) continue;
            TileAndPoly found = { .tile = tile, .poly = poly };
            float area = polygon_area(found);
            area_sum += area;
            // Reservoir sampling keeps each polygon with probability area over the running sum.
            if (random(context) * area_sum > area) continue;
            chosen = found;
            chosen_ref = ref;
        }
    }
    if (!chosen_ref) return NO_POLY~;
    Vec3 point = random_point_in_polygon(
        mesh:    mesh,
        found:   chosen,
        ref:     chosen_ref,
        random:  random,
        context: context,
    );
    return { .ref = chosen_ref, .point = point };
}

<*
 Point on a polygon reachable within the radius, chosen by area; mirrors findRandomPointAroundCircle.
 The radius limits the polygons visited, not the point.
 @param [&in] filter : "Polygons it rejects are not entered; the start polygon must pass it."
 @param random : "Returns [0, 1)."
 @param [in] context : "Passed to random."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT, NO_POLY
*>
fn RandomPoint? NavQuery.find_random_point_around_circle(
    &self,
    PolyRef start_ref,
    Vec3 center,
    float max_radius,
    QueryFilter* filter,
    RandomFn random,
    void* context,
) {
    NavMesh* mesh = self.mesh;
    if (!mesh.is_valid_ref(start_ref)) return INVALID_REF~;
    if (!finite_point(center) || !valid_radius(max_radius)) return c3d::INVALID_ARGUMENT~;
    if (!filter.passes(start_ref, mesh.tile_and_poly_unchecked(start_ref).poly)) return c3d::INVALID_ARGUMENT~;

    self.nodes.clear();
    self.open.clear();
    SearchNode* start_node = self.nodes.get_node(start_ref);
    start_node.position = center;
    start_node.bits.open = true;
    self.open.push(start_node);

    float radius_sqr = max_radius * max_radius;
    float area_sum = 0;
    TileAndPoly chosen;
    PolyRef chosen_ref;
    while (!self.open.is_empty()) {
        SearchNode* current = self.open.pop();
        current.bits.open = false;
        current.bits.closed = true;
        TileAndPoly found = mesh.tile_and_poly_unchecked(current.id);
        if (found.poly.area_type.type == GROUND) {
            float area = polygon_area(found);
            area_sum += area;
            if (random(context) * area_sum <= area) {
                chosen = found;
                chosen_ref = current.id;
            }
        }

        SearchNode* parent = self.nodes.node_at(current.bits.parent);
        PolyRef parent_ref = parent ? parent.id : (PolyRef)0;
        for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
            PolyRef neighbour_ref = found.tile.links[link].ref;
            if (!neighbour_ref || neighbour_ref == parent_ref) continue;
            TileAndPoly neighbour = mesh.tile_and_poly_unchecked(neighbour_ref);
            if (!filter.passes(neighbour_ref, neighbour.poly)) continue;
            Portal? portal = portal_points(current.id, found, neighbour_ref, neighbour);
            if (catch portal) continue;
            if (distance_pt_seg_sqr_2d(center, portal.left, portal.right).distance_sqr > radius_sqr) continue;

            SearchNode* node = self.nodes.get_node(neighbour_ref);
            if (!node || node.bits.closed) continue;
            if (first_visit(node)) node.position = (portal.left + portal.right) * 0.5f;
            float total = current.total + (current.position - node.position).length();
            if (node.bits.open && total >= node.total) continue;
            node.id = neighbour_ref;
            node.bits.parent = self.nodes.node_index(current);
            node.total = total;
            if (node.bits.open) {
                self.open.modify(node);
            } else {
                node.bits.open = true;
                self.open.push(node);
            }
        }
    }

    if (!chosen_ref) return NO_POLY~;
    Vec3 point = random_point_in_polygon(
        mesh:    mesh,
        found:   chosen,
        ref:     chosen_ref,
        random:  random,
        context: context,
    );
    return { .ref = chosen_ref, .point = point };
}

fn bool valid_radius(float radius) @local => radius >= 0 && math::is_finite(radius);

// Mirrors the shared body of findPolysAroundCircle and findPolysAroundShape: results in pop order.
fn DijkstraResult dijkstra_search(
    NavQuery* query,
    PolyRef start_ref,
    SearchBoundary* boundary,
    QueryFilter* filter,
    PolyRef[] out_refs,
    PolyRef[] out_parents,
    float[] out_costs,
) @local {
    NavMesh* mesh = query.mesh;
    query.nodes.clear();
    query.open.clear();
    SearchNode* start_node = query.nodes.get_node(start_ref);
    start_node.position = boundary.center;
    start_node.bits.open = true;
    query.open.push(start_node);

    DijkstraResult result;
    while (!query.open.is_empty()) {
        SearchNode* current = query.open.pop();
        current.bits.open = false;
        current.bits.closed = true;
        TileAndPoly found = mesh.tile_and_poly_unchecked(current.id);
        SearchNode* parent = query.nodes.node_at(current.bits.parent);
        PolyRef parent_ref = parent ? parent.id : (PolyRef)0;
        record_result(
            result:      &result,
            out_refs:    out_refs,
            out_parents: out_parents,
            out_costs:   out_costs,
            ref:         current.id,
            parent_ref:  parent_ref,
            cost:        current.total,
        );

        for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
            PolyRef neighbour_ref = found.tile.links[link].ref;
            if (!neighbour_ref || neighbour_ref == parent_ref) continue;
            TileAndPoly neighbour = mesh.tile_and_poly_unchecked(neighbour_ref);
            if (!filter.passes(neighbour_ref, neighbour.poly)) continue;
            Portal? portal = portal_points(current.id, found, neighbour_ref, neighbour);
            if (catch portal) continue;
            if (!portal_touches(boundary, portal.left, portal.right)) continue;

            SearchNode* node = query.nodes.get_node(neighbour_ref);
            if (!node) {
                result.truncated = true;
                continue;
            }
            if (node.bits.closed) continue;
            if (first_visit(node)) node.position = (portal.left + portal.right) * 0.5f;
            float total = current.total + filter.segment_cost(
                from:     current.position,
                to:       node.position,
                current:  found.poly,
                next_ref: neighbour_ref,
                next:     neighbour.poly,
            );
            if (node.bits.open && total >= node.total) continue;
            node.id = neighbour_ref;
            node.bits.parent = query.nodes.node_index(current);
            node.total = total;
            if (node.bits.open) {
                query.open.modify(node);
            } else {
                node.bits.open = true;
                query.open.push(node);
            }
        }
    }
    return result;
}

fn bool portal_touches(SearchBoundary* boundary, Vec3 left, Vec3 right) @local {
    switch (boundary.shape) {
        case CIRCLE:
            return distance_pt_seg_sqr_2d(boundary.center, left, right).distance_sqr <= boundary.radius_sqr;
        case POLYGON:
            SegmentPolyHit? hit = intersect_segment_poly_2d(left, right, boundary.vertices);
            if (catch hit) return false;
            return hit.t_min <= 1 && hit.t_max >= 0;
    }
}

fn void record_result(
    DijkstraResult* result,
    PolyRef[] out_refs,
    PolyRef[] out_parents,
    float[] out_costs,
    PolyRef ref,
    PolyRef parent_ref,
    float cost,
) @local {
    if (result.count == out_refs.len) {
        result.truncated = true;
        return;
    }
    out_refs[result.count] = ref;
    if (out_parents.len) out_parents[result.count] = parent_ref;
    if (out_costs.len) out_costs[result.count] = cost;
    result.count++;
}

// Connected polygons are taken not to overlap, as upstream assumes.
fn bool overlaps_results(
    NavMesh* mesh,
    TileAndPoly current,
    TileAndPoly candidate,
    PolyRef[] results,
) @local {
    Vec3[MAX_VERTS_PER_POLY] candidate_verts = polygon_vertices(candidate.tile, candidate.poly);
    foreach (past_ref : results) {
        if (@ok(find_link(current, past_ref))) continue;
        TileAndPoly past = mesh.tile_and_poly_unchecked(past_ref);
        Vec3[MAX_VERTS_PER_POLY] past_verts = polygon_vertices(past.tile, past.poly);
        if (overlap_poly_poly_2d(candidate_verts[:candidate.poly.vert_count], past_verts[:past.poly.vert_count])) {
            return true;
        }
    }
    return false;
}

fn SearchNode* pop_front(BreadthQueue* queue) @local {
    SearchNode* front = queue.nodes[0];
    queue.count--;
    for (usz index = 0; index < queue.count; index++) queue.nodes[index] = queue.nodes[index + 1];
    return front;
}

// A full queue drops the node, as upstream's fixed stack does.
fn void push_back(BreadthQueue* queue, SearchNode* node) @local {
    if (queue.count < MAX_STACK) queue.nodes[queue.count++] = node;
}

// Refs across the edge that pass the filter; a tile border edge may lead to several.
fn usz passable_neighbours(
    NavMesh* mesh,
    TileAndPoly found,
    usz edge,
    QueryFilter* filter,
    PolyRef[] out_refs,
) @local {
    ushort neighbour_word = found.poly.neighbours[edge];
    if ((neighbour_word & EXTERNAL_LINK) == 0) {
        if (!neighbour_word) return 0;
        PolyRef ref = mesh.poly_ref_base(found.tile) | (PolyRef)(neighbour_word - 1);
        if (!filter.passes(ref, &found.tile.polys[neighbour_word - 1])) return 0;
        out_refs[0] = ref;
        return 1;
    }
    usz count;
    for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
        Link* entry = &found.tile.links[link];
        if (entry.edge != edge || !entry.ref || count == out_refs.len) continue;
        if (filter.passes(entry.ref, mesh.tile_and_poly_unchecked(entry.ref).poly)) out_refs[count++] = entry.ref;
    }
    return count;
}

// Mirrors findDistanceToWall's edge test, which decides a tile border edge by its first link.
fn bool is_wall_edge(
    NavMesh* mesh,
    TileAndPoly found,
    usz edge,
    QueryFilter* filter,
) @local {
    ushort neighbour_word = found.poly.neighbours[edge];
    if ((neighbour_word & EXTERNAL_LINK) != 0) {
        for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
            Link* entry = &found.tile.links[link];
            if (entry.edge != edge) continue;
            if (!entry.ref) return true;
            return !filter.passes(entry.ref, mesh.tile_and_poly_unchecked(entry.ref).poly);
        }
        return true;
    }
    if (!neighbour_word) return true;
    PolyRef ref = mesh.poly_ref_base(found.tile) | (PolyRef)(neighbour_word - 1);
    return !filter.passes(ref, &found.tile.polys[neighbour_word - 1]);
}

// Mirrors insertInterval: kept sorted along the edge; a full list drops the interval.
fn void insert_interval(
    IntervalList* list,
    short min,
    short max,
    PolyRef ref,
) @local {
    if (list.count == MAX_INTERVALS) return;
    usz slot = 0;
    while (slot < list.count && max > list.items[slot].min) slot++;
    for (usz index = list.count; index > slot; index--) list.items[index] = list.items[index - 1];
    list.items[slot] = { .min = min, .max = max, .ref = ref };
    list.count++;
}

fn void append_segment(QueryResult* result, WallSegment[] out_segments, WallSegment segment) @local {
    if (result.count == out_segments.len) {
        result.truncated = true;
        return;
    }
    out_segments[result.count++] = segment;
}

// Twice the polygon's XZ area, the weight upstream samples by.
fn float polygon_area(TileAndPoly found) @local {
    MeshTile* tile = found.tile;
    Poly* poly = found.poly;
    Vec3 first = tile.verts[poly.verts[0]];
    float area = 0;
    for (usz third = 2; third < poly.vert_count; third++) {
        area += tri_area_2d(first, tile.verts[poly.verts[third - 1]], tile.verts[poly.verts[third]]);
    }
    return area;
}

fn Vec3 random_point_in_polygon(
    NavMesh* mesh,
    TileAndPoly found,
    PolyRef ref,
    RandomFn random,
    void* context,
) @local {
    Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(found.tile, found.poly);
    float s = random(context);
    float t = random(context);
    Vec3 point = random_point_in_convex_poly(verts[:found.poly.vert_count], s, t);
    return closest_point_on_polygon(mesh, ref, point).point;
}
