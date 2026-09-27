module c3d::nav;

import std::math;
import c3d;

<* Search nodes of the small pool used by local queries; mirrors dtNavMeshQuery's tiny pool. *>
const uint TINY_NODE_POOL = 64;

const uint  TINY_NODE_HASH @local = 32; // mirrors dtNavMeshQuery::init
const float HEURISTIC_SCALE @local = 0.999f; // mirrors findPath's H_SCALE; keeps the heuristic below the cost
const float PORTAL_SKIP_DISTANCE @local = 0.001f; // metres; a start this close to the first portal skips it
const float PORTAL_LIMIT_STEP @local = 1.0f / 255.0f; // a link's portal sub-range is stored in a byte

<* Flags of one straight-path point; mirrors dtStraightPathFlags. *>
bitstruct StraightPathFlags : char {
    bool start               : 0;
    bool end                 : 1;
    bool off_mesh_connection : 2;    // the point starts an off-mesh connection
}

<* Options of straight_path; mirrors dtStraightPathOptions. *>
bitstruct StraightPathOptions : uint {
    bool area_crossings : 0;    // a point wherever the area changes
    bool all_crossings  : 1;    // a point at every polygon edge crossed
}

<* Options of raycast; mirrors dtRaycastOptions. *>
bitstruct RaycastOptions : uint {
    bool use_costs : 0;
}

enum AppendStatus @local {
    IN_PROGRESS,
    COMPLETE,     // the end point was appended
    FULL,         // the slice filled up
}

<* Outcome of a search that fills a caller slice. *>
struct PathResult {
    usz  count;
    bool partial;      // the goal was unreachable or the search ran out of nodes; the path ends nearest the goal
    bool truncated;    // the slice filled up; the path may be cut
}

<* Outcome of a query that fills a caller slice. *>
struct QueryResult {
    usz  count;
    bool truncated;
}

<* One point of a string-pulled path and the polygon entered there. *>
struct StraightPoint {
    Vec3              position;
    StraightPathFlags flags;
    PolyRef           ref;         // 0 at the end point
}

<* Result of a walkability raycast; mirrors dtRaycastHit. *>
struct RaycastHit {
    float t;             // hit parameter along start to end; float::max when no wall was hit
    Vec3  normal;        // of the wall hit
    int   edge;          // edge of the last polygon crossed; -1 when the ray ended inside it
    usz   path_count;
    bool  truncated;     // the path slice filled up and the ray stopped there
    float cost;          // when use_costs
}

<* Pathfinding over one NavMesh with its own node pools; mirrors dtNavMeshQuery. *>
struct NavQuery {
    NavMesh*  mesh;
    NodePool  nodes;
    NodePool  tiny_nodes;
    NodeQueue open;
}

struct Portal @local {
    Vec3     left;
    Vec3     right;
    PolyType to_type;
}

struct StraightPathWriter @local {
    StraightPoint[] points;
    usz             count;
}

<*
 Nearest polygon passing the filter inside the box around center; mirrors findNearestPoly.
 @param half_extents : "Search distance along each axis."
 @param [&in] filter : "Polygons it rejects are skipped."
 @return? NO_POLY, c3d::INVALID_ARGUMENT
*>
fn NearestPoly? NavQuery.find_nearest_poly(&self, Vec3 center, Vec3 half_extents, QueryFilter* filter) {
    if (!finite_point(center) || !finite_point(half_extents)) return c3d::INVALID_ARGUMENT~;
    NearestPoly nearest;
    float nearest_distance = float::max;
    Aabb box = { .min = center - half_extents, .max = center + half_extents };
    @each_poly_in_box(self, box, filter; tile, ref, poly) {
        ClosestPoint closest = closest_point_on_polygon(self.mesh, ref, center);
        float distance = nearness(center, closest, tile.header.walkable_climb);
        if (distance < nearest_distance) {
            nearest = { .ref = ref, .point = closest.point, .over_poly = closest.over_poly };
            nearest_distance = distance;
        }
    };
    if (!nearest.ref) return NO_POLY~;
    return nearest;
}

<*
 Polygons passing the filter whose bounds overlap the box around center; mirrors queryPolygons.
 @param half_extents : "Search distance along each axis."
 @param [&in] filter : "Polygons it rejects are skipped."
 @param [out] out_refs : "Filled up to its length."
*>
fn QueryResult NavQuery.query_polygons(
    &self,
    Vec3 center,
    Vec3 half_extents,
    QueryFilter* filter,
    PolyRef[] out_refs,
) {
    QueryResult result;
    Aabb box = { .min = center - half_extents, .max = center + half_extents };
    @each_poly_in_box(self, box, filter; tile, ref, poly) {
        if (result.count < out_refs.len) {
            out_refs[result.count++] = ref;
        } else {
            result.truncated = true;
        }
    };
    return result;
}

<*
 Closest point on the polygon to the position, its height from the vertex fan; mirrors closestPointOnPoly.
 @return? INVALID_REF
*>
fn ClosestPoint? NavQuery.closest_point_on_poly(&self, PolyRef ref, Vec3 position) {
    if (!self.mesh.is_valid_ref(ref)) return INVALID_REF~;
    return closest_point_on_polygon(self.mesh, ref, position);
}

<*
 Point on the polygon boundary closest to a position outside its XZ bounds; mirrors closestPointOnPolyBoundary.
 @return "The position itself when its XZ lies inside the polygon."
 @return? INVALID_REF
*>
fn Vec3? NavQuery.closest_point_on_poly_boundary(&self, PolyRef ref, Vec3 position) {
    TileAndPoly found = self.mesh.tile_and_poly(ref)!;
    Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(found.tile, found.poly);
    Vec3[] corners = verts[:found.poly.vert_count];
    float[MAX_VERTS_PER_POLY] edge_distances;
    float[MAX_VERTS_PER_POLY] edge_t;
    if (distance_pt_poly_edges_sqr(position, corners, edge_distances[..], edge_t[..])) return position;

    usz nearest = 0;
    for (usz edge = 1; edge < corners.len; edge++) {
        if (edge_distances[edge] < edge_distances[nearest]) nearest = edge;
    }
    return lerp_point(corners[nearest], corners[(nearest + 1) % (usz)corners.len], edge_t[nearest]);
}

<*
 Height of the polygon surface under the position, from its vertex fan; mirrors getPolyHeight.
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
*>
fn float? NavQuery.poly_height(&self, PolyRef ref, Vec3 position) {
    TileAndPoly found = self.mesh.tile_and_poly(ref)!;
    if (!math::is_finite(position.x) || !math::is_finite(position.z)) return c3d::INVALID_ARGUMENT~;
    if (found.poly.area_type.type == OFF_MESH_CONNECTION) {
        Vec3 start = found.tile.verts[found.poly.verts[0]];
        Vec3 end = found.tile.verts[found.poly.verts[1]];
        return lerp_point(start, end, distance_pt_seg_sqr_2d(position, start, end).t).y;
    }
    return polygon_height(found.tile, found.poly, position);
}

<*
 A* corridor of polygons from start to end; mirrors findPath.
 Replaces the closed list is_in_closed_list reads.
 @param start : "Inside the start polygon."
 @param end : "Inside the end polygon."
 @param [&in] filter : "Polygons it rejects are not entered."
 @param [out] out_path : "Start to end; filled up to its length."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
 @require out_path.len >= 1
*>
fn PathResult? NavQuery.find_path(
    &self,
    PolyRef start_ref,
    PolyRef end_ref,
    Vec3 start,
    Vec3 end,
    QueryFilter* filter,
    PolyRef[] out_path,
) {
    NavMesh* mesh = self.mesh;
    if (!mesh.is_valid_ref(start_ref) || !mesh.is_valid_ref(end_ref)) return INVALID_REF~;
    if (!finite_point(start) || !finite_point(end)) return c3d::INVALID_ARGUMENT~;
    if (start_ref == end_ref) {
        out_path[0] = start_ref;
        return { .count = 1 };
    }

    self.nodes.clear();
    self.open.clear();
    SearchNode* start_node = self.nodes.get_node(start_ref);
    start_node.position = start;
    start_node.total = (end - start).length() * HEURISTIC_SCALE;
    start_node.bits.open = true;
    self.open.push(start_node);

    SearchNode* best_node = start_node;
    float best_heuristic = start_node.total;
    bool out_of_nodes;
    while (!self.open.is_empty()) {
        SearchNode* current = self.open.pop();
        current.bits.open = false;
        current.bits.closed = true;
        if (current.id == end_ref) {
            best_node = current;
            break;
        }

        TileAndPoly found = mesh.tile_and_poly_unchecked(current.id);
        SearchNode* parent = self.nodes.node_at(current.bits.parent);
        PolyRef parent_ref = parent ? parent.id : (PolyRef)0;
        for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
            Link* entry = &found.tile.links[link];
            PolyRef neighbour_ref = entry.ref;
            if (!neighbour_ref || neighbour_ref == parent_ref) continue;
            TileAndPoly neighbour = mesh.tile_and_poly_unchecked(neighbour_ref);
            if (!filter.passes(neighbour_ref, neighbour.poly)) continue;

            // A tile border crossing takes its own node per side, so each portal keeps its own position.
            char cross_side = entry.side == NO_SIDE ? 0 : (char)(entry.side >> 1);
            SearchNode* node = self.nodes.get_node(neighbour_ref, cross_side);
            if (!node) {
                out_of_nodes = true;
                continue;
            }
            if (first_visit(node)) {
                if (try portal = portal_points(current.id, found, neighbour_ref, neighbour)) {
                    node.position = (portal.left + portal.right) * 0.5f;
                }
            }

            float cost = current.cost + filter.segment_cost(
                from:     current.position,
                to:       node.position,
                current:  found.poly,
                next_ref: neighbour_ref,
                next:     neighbour.poly,
            );
            float heuristic = 0;
            if (neighbour_ref == end_ref) {
                cost += filter.segment_cost(
                    from:     node.position,
                    to:       end,
                    current:  neighbour.poly,
                    next_ref: (PolyRef)0,
                    next:     null,
                );
            } else {
                heuristic = (end - node.position).length() * HEURISTIC_SCALE;
            }
            float total = cost + heuristic;
            if ((node.bits.open || node.bits.closed) && total >= node.total) continue;

            node.bits.parent = self.nodes.node_index(current);
            node.bits.closed = false;
            node.id = neighbour_ref;
            node.cost = cost;
            node.total = total;
            if (node.bits.open) {
                self.open.modify(node);
            } else {
                node.bits.open = true;
                self.open.push(node);
            }
            if (heuristic < best_heuristic) {
                best_heuristic = heuristic;
                best_node = node;
            }
        }
    }

    PathResult result = path_to_node(&self.nodes, best_node, out_path);
    result.partial = best_node.id != end_ref || out_of_nodes;
    return result;
}

<*
 String-pulled points through a polygon corridor; mirrors findStraightPath.
 @param start : "Clamped onto the first polygon."
 @param end : "Clamped onto the last polygon."
 @param path : "A corridor from find_path."
 @param [out] out_points : "Filled up to its length."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
 @require path.len >= 1, out_points.len >= 1
*>
fn PathResult? NavQuery.straight_path(
    &self,
    Vec3 start,
    Vec3 end,
    PolyRef[] path,
    StraightPoint[] out_points,
    StraightPathOptions options = {},
) {
    if (!finite_point(start) || !finite_point(end)) return c3d::INVALID_ARGUMENT~;
    Vec3 closest_start = self.closest_point_on_poly_boundary(path[0], start)!;
    Vec3 closest_end = self.closest_point_on_poly_boundary(path[^1], end)!;
    StraightPathWriter writer = { .points = out_points };
    bool crossings = options.area_crossings || options.all_crossings;

    AppendStatus status = append_vertex(&writer, closest_start, { .start = true }, path[0]);
    if (status != IN_PROGRESS) return finished(&writer, status);
    if (path.len > 1) {
        Vec3 apex = closest_start;
        Vec3 left_point = apex;
        Vec3 right_point = apex;
        usz apex_index;
        usz left_index;
        usz right_index;
        PolyType left_type = GROUND;
        PolyType right_type = GROUND;
        PolyRef left_ref = path[0];
        PolyRef right_ref = path[0];

        for (usz index = 0; index < path.len; index++) {
            Vec3 left = closest_end;
            Vec3 right = closest_end;
            PolyType to_type = GROUND;
            if (index + 1 < path.len) {
                Portal? portal = portal_points_by_ref(self.mesh, path[index], path[index + 1]);
                if (catch portal) {
                    // The next polygon is gone, so the path ends on this one.
                    closest_end = self.closest_point_on_poly_boundary(path[index], end)!;
                    if (crossings) {
                        (void)append_portals(
                            mesh:        self.mesh,
                            writer:      &writer,
                            start_index: apex_index,
                            end_index:   index,
                            end:         closest_end,
                            path:        path,
                            options:     options,
                        );
                    }
                    (void)append_vertex(&writer, closest_end, {}, path[index]);
                    return { .count = writer.count, .partial = true, .truncated = writer.count >= out_points.len };
                }
                left = portal.left;
                right = portal.right;
                to_type = portal.to_type;
                if (index == 0) {
                    SegmentProjection projection = distance_pt_seg_sqr_2d(apex, left, right);
                    if (projection.distance_sqr < PORTAL_SKIP_DISTANCE * PORTAL_SKIP_DISTANCE) continue;
                }
            }

            if (tri_area_2d(apex, right_point, right) <= 0) {
                if (same_point(apex, right_point) || tri_area_2d(apex, left_point, right) > 0) {
                    right_point = right;
                    right_ref = index + 1 < path.len ? path[index + 1] : (PolyRef)0;
                    right_type = to_type;
                    right_index = index;
                } else {
                    if (crossings) {
                        status = append_portals(
                            mesh:        self.mesh,
                            writer:      &writer,
                            start_index: apex_index,
                            end_index:   left_index,
                            end:         left_point,
                            path:        path,
                            options:     options,
                        )!;
                        if (status != IN_PROGRESS) return finished(&writer, status);
                    }
                    apex = left_point;
                    apex_index = left_index;
                    status = append_vertex(&writer, apex, corner_flags(left_ref, left_type), left_ref);
                    if (status != IN_PROGRESS) return finished(&writer, status);
                    left_point = apex;
                    right_point = apex;
                    left_index = apex_index;
                    right_index = apex_index;
                    // The loop resumes at the portal after the new apex.
                    index = apex_index;
                    continue;
                }
            }

            if (tri_area_2d(apex, left_point, left) >= 0) {
                if (same_point(apex, left_point) || tri_area_2d(apex, right_point, left) < 0) {
                    left_point = left;
                    left_ref = index + 1 < path.len ? path[index + 1] : (PolyRef)0;
                    left_type = to_type;
                    left_index = index;
                } else {
                    if (crossings) {
                        status = append_portals(
                            mesh:        self.mesh,
                            writer:      &writer,
                            start_index: apex_index,
                            end_index:   right_index,
                            end:         right_point,
                            path:        path,
                            options:     options,
                        )!;
                        if (status != IN_PROGRESS) return finished(&writer, status);
                    }
                    apex = right_point;
                    apex_index = right_index;
                    status = append_vertex(&writer, apex, corner_flags(right_ref, right_type), right_ref);
                    if (status != IN_PROGRESS) return finished(&writer, status);
                    left_point = apex;
                    right_point = apex;
                    left_index = apex_index;
                    right_index = apex_index;
                    index = apex_index;
                    continue;
                }
            }
        }

        if (crossings) {
            status = append_portals(
                mesh:        self.mesh,
                writer:      &writer,
                start_index: apex_index,
                end_index:   path.len - 1,
                end:         closest_end,
                path:        path,
                options:     options,
            )!;
            if (status != IN_PROGRESS) return finished(&writer, status);
        }
    }

    (void)append_vertex(&writer, closest_end, { .end = true }, (PolyRef)0);
    return { .count = writer.count, .truncated = writer.count >= out_points.len };
}

<*
 Walkability ray along the surface from start toward end, over the XZ plane; mirrors raycast.
 @param [&in] filter : "Polygons it rejects stop the ray."
 @param [out] out_path : "Polygons visited; may be empty."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
*>
fn RaycastHit? NavQuery.raycast(
    &self,
    PolyRef start_ref,
    Vec3 start,
    Vec3 end,
    QueryFilter* filter,
    PolyRef[] out_path,
    RaycastOptions options = {},
) {
    NavMesh* mesh = self.mesh;
    if (!mesh.is_valid_ref(start_ref)) return INVALID_REF~;
    if (!finite_point(start) || !finite_point(end)) return c3d::INVALID_ARGUMENT~;

    RaycastHit hit;
    Vec3 direction = end - start;
    Vec3 position = start;
    PolyRef current_ref = start_ref;
    TileAndPoly current = mesh.tile_and_poly_unchecked(current_ref);
    while (current_ref) {
        Vec3[MAX_VERTS_PER_POLY] verts = polygon_vertices(current.tile, current.poly);
        Vec3[] corners = verts[:current.poly.vert_count];
        SegmentPolyHit? crossing = intersect_segment_poly_2d(start, end, corners);
        if (catch crossing) return hit;

        hit.edge = crossing.edge_max;
        if (crossing.t_max > hit.t) hit.t = crossing.t_max;
        if (hit.path_count < out_path.len) {
            out_path[hit.path_count++] = current_ref;
        } else {
            hit.truncated = true;
        }
        if (crossing.edge_max == -1) {
            hit.t = float::max;
            if (options.use_costs) {
                hit.cost += filter.segment_cost(
                    from:     position,
                    to:       end,
                    current:  current.poly,
                    next_ref: current_ref,
                    next:     current.poly,
                );
            }
            return hit;
        }

        PolyRef next_ref;
        TileAndPoly next;
        for (uint link = current.poly.first_link; link != NULL_LINK; link = current.tile.links[link].next) {
            Link* entry = &current.tile.links[link];
            if ((int)entry.edge != crossing.edge_max) continue;
            TileAndPoly candidate = mesh.tile_and_poly_unchecked(entry.ref);
            if (candidate.poly.area_type.type == OFF_MESH_CONNECTION) continue;
            if (!filter.passes(entry.ref, candidate.poly)) continue;
            if (entry.side == NO_SIDE || portal_holds(current, entry, start, end, crossing.t_max)) {
                next_ref = entry.ref;
                next = candidate;
                break;
            }
        }

        usz wall_edge = (usz)crossing.edge_max;
        Vec3 edge_start = corners[wall_edge];
        Vec3 edge_end = corners[(wall_edge + 1) % (usz)corners.len];
        if (options.use_costs) {
            // The crossing point takes the edge's height, since the ray moves in XZ.
            Vec3 previous_position = position;
            position = start + direction * hit.t;
            Vec3 along = edge_end - edge_start;
            Vec3 offset = position - edge_start;
            float s = along.x * along.x > along.z * along.z ? offset.x / along.x : offset.z / along.z;
            position.y = edge_start.y + along.y * s;
            hit.cost += filter.segment_cost(
                from:     previous_position,
                to:       position,
                current:  current.poly,
                next_ref: next_ref,
                next:     next_ref ? next.poly : null,
            );
        }

        if (!next_ref) {
            hit.normal = ((Vec3){ edge_end.z - edge_start.z, 0, -(edge_end.x - edge_start.x) }).normalize();
            return hit;
        }
        current_ref = next_ref;
        current = next;
        if (hit.truncated) break;
    }
    return hit;
}

<*
 Whether the ref is resident and passes the filter; mirrors isValidPolyRef.
 @param [&in] filter : "Applied to the polygon."
*>
fn bool NavQuery.is_valid_ref(&self, PolyRef ref, QueryFilter* filter) {
    TileAndPoly? found = self.mesh.tile_and_poly(ref);
    if (catch found) return false;
    return filter.passes(ref, found.poly);
}

<* Whether the last find_path closed the polygon; mirrors isInClosedList. *>
fn bool NavQuery.is_in_closed_list(&self, PolyRef ref) {
    SearchNode*[MAX_NODE_STATES] nodes;
    usz count = self.nodes.find_nodes(ref, nodes[..]);
    foreach (node : nodes[:count]) {
        if (node.bits.closed) return true;
    }
    return false;
}

<*
 Query over the mesh with a node pool of max_nodes, allocated once.
 @param [&in] mesh : "Outlives the query."
 @return? c3d::CAPACITY_EXCEEDED
 @require max_nodes > 0 && max_nodes < (uint)NULL_NODE
*>
fn NavQuery? create_nav_query(Allocator allocator, NavMesh* mesh, uint max_nodes) {
    NodePool nodes = create_node_pool(allocator, max_nodes, math::max(next_pow2(max_nodes / 4), 1u))!;
    defer catch destroy_node_pool(&nodes);
    NodePool tiny_nodes = create_node_pool(allocator, TINY_NODE_POOL, TINY_NODE_HASH)!;
    defer catch destroy_node_pool(&tiny_nodes);
    NodeQueue open = create_node_queue(allocator, max_nodes)!;
    return { .mesh = mesh, .nodes = nodes, .tiny_nodes = tiny_nodes, .open = open };
}

<*
 Free the pools and the queue.
 @param [&inout] query : "Left zeroed."
*>
fn void destroy_nav_query(NavQuery* query) {
    destroy_node_pool(&query.nodes);
    destroy_node_pool(&query.tiny_nodes);
    destroy_node_queue(&query.open);
    *query = {};
}

fn bool finite_point(Vec3 point) @local {
    return math::is_finite(point.x) && math::is_finite(point.y) && math::is_finite(point.z);
}

fn bool first_visit(SearchNode* node) @local => !node.bits.open && !node.bits.closed && !node.bits.parent_detached;

// Every polygon passing the filter whose bounds overlap the box, tile by tile; mirrors queryPolygons.
macro void @each_poly_in_box(
    NavQuery* query,
    Aabb box,
    QueryFilter* filter;
    @body(MeshTile* tile, PolyRef ref, Poly* poly)
) @local {
    NavMesh* mesh = query.mesh;
    int[<2>] low = mesh.tile_location(box.min);
    int[<2>] high = mesh.tile_location(box.max);
    MeshTile*[MAX_TILES_AT] tiles;
    for (int z = low.y; z <= high.y; z++) {
        for (int x = low.x; x <= high.x; x++) {
            usz count = mesh.tiles_at(x, z, tiles[..]);
            foreach (tile : tiles[:count]) {
                @each_poly_overlapping(mesh, tile, box; ref, poly) {
                    if (filter.passes(ref, poly)) @body(tile, ref, poly);
                };
            }
        }
    }
}

// Mirrors getPathToNode: a path longer than the slice keeps its start.
fn PathResult path_to_node(NodePool* nodes, SearchNode* end_node, PolyRef[] out_path) @local {
    usz length;
    for (SearchNode* node = end_node; node; node = nodes.node_at(node.bits.parent)) length++;
    SearchNode* node = end_node;
    for (usz skipped = length; skipped > out_path.len; skipped--) node = nodes.node_at(node.bits.parent);
    usz count = math::min(length, (usz)out_path.len);
    for (usz index = count; index > 0; index--) {
        out_path[index - 1] = node.id;
        node = nodes.node_at(node.bits.parent);
    }
    return { .count = count, .truncated = length > out_path.len };
}

fn Portal? portal_points_by_ref(NavMesh* mesh, PolyRef from_ref, PolyRef to_ref) @local {
    TileAndPoly from = mesh.tile_and_poly(from_ref)!;
    TileAndPoly to = mesh.tile_and_poly(to_ref)!;
    return portal_points(from_ref, from, to_ref, to);
}

// INVALID_REF when from holds no link to to; mirrors getPortalPoints.
fn Portal? portal_points(PolyRef from_ref, TileAndPoly from, PolyRef to_ref, TileAndPoly to) @local {
    Link* link = find_link(from, to_ref)!;
    PolyType to_type = to.poly.area_type.type;
    if (from.poly.area_type.type == OFF_MESH_CONNECTION) {
        Vec3 vertex = from.tile.verts[from.poly.verts[link.edge]];
        return { .left = vertex, .right = vertex, .to_type = to_type };
    }
    if (to_type == OFF_MESH_CONNECTION) {
        Link* back = find_link(to, from_ref)!;
        Vec3 vertex = to.tile.verts[to.poly.verts[back.edge]];
        return { .left = vertex, .right = vertex, .to_type = to_type };
    }

    Vec3 first = from.tile.verts[from.poly.verts[link.edge]];
    Vec3 second = from.tile.verts[from.poly.verts[(link.edge + 1) % from.poly.vert_count]];
    Portal portal = { .left = first, .right = second, .to_type = to_type };
    // A tile border link may cover only part of its edge.
    if (link.side != NO_SIDE && (link.min != 0 || link.max != char::max)) {
        portal.left = lerp_point(first, second, link.min * PORTAL_LIMIT_STEP);
        portal.right = lerp_point(first, second, link.max * PORTAL_LIMIT_STEP);
    }
    return portal;
}

fn Link*? find_link(TileAndPoly from, PolyRef to_ref) @local {
    for (uint link = from.poly.first_link; link != NULL_LINK; link = from.tile.links[link].next) {
        if (from.tile.links[link].ref == to_ref) return &from.tile.links[link];
    }
    return INVALID_REF~;
}

// Whether the ray crosses the edge inside the part of it the tile border link covers.
fn bool portal_holds(
    TileAndPoly current,
    Link* link,
    Vec3 start,
    Vec3 end,
    float t,
) @local {
    if (link.min == 0 && link.max == char::max) return true;
    Vec3 left = current.tile.verts[current.poly.verts[link.edge]];
    Vec3 right = current.tile.verts[current.poly.verts[(link.edge + 1) % current.poly.vert_count]];
    bool along_z = link.side == 0 || link.side == 4;
    float left_coord = along_z ? left.z : left.x;
    float right_coord = along_z ? right.z : right.x;
    float low = left_coord + (right_coord - left_coord) * (link.min * PORTAL_LIMIT_STEP);
    float high = left_coord + (right_coord - left_coord) * (link.max * PORTAL_LIMIT_STEP);
    if (low > high) @swap(low, high);
    float crossing = along_z ? start.z + (end.z - start.z) * t : start.x + (end.x - start.x) * t;
    return crossing >= low && crossing <= high;
}

fn StraightPathFlags corner_flags(PolyRef ref, PolyType type) @local {
    if (!ref) return { .end = true };
    if (type == OFF_MESH_CONNECTION) return { .off_mesh_connection = true };
    return {};
}

fn PathResult finished(StraightPathWriter* writer, AppendStatus status) @local {
    return { .count = writer.count, .truncated = status == FULL };
}

// Mirrors appendVertex: a point equal to the last one replaces its flags and polygon.
fn AppendStatus append_vertex(
    StraightPathWriter* writer,
    Vec3 position,
    StraightPathFlags flags,
    PolyRef ref,
) @local {
    if (writer.count > 0 && same_point(writer.points[writer.count - 1].position, position)) {
        writer.points[writer.count - 1].flags = flags;
        writer.points[writer.count - 1].ref = ref;
        return IN_PROGRESS;
    }
    writer.points[writer.count++] = { .position = position, .flags = flags, .ref = ref };
    if (writer.count >= writer.points.len) return FULL;
    if (flags == (StraightPathFlags){ .end = true }) return COMPLETE;
    return IN_PROGRESS;
}

// Mirrors appendPortals: a point where the segment from the last point to end crosses each portal.
fn AppendStatus? append_portals(
    NavMesh* mesh,
    StraightPathWriter* writer,
    usz start_index,
    usz end_index,
    Vec3 end,
    PolyRef[] path,
    StraightPathOptions options,
) @local {
    Vec3 start = writer.points[writer.count - 1].position;
    for (usz index = start_index; index < end_index; index++) {
        TileAndPoly from = mesh.tile_and_poly(path[index])!;
        TileAndPoly to = mesh.tile_and_poly(path[index + 1])!;
        Portal? portal = portal_points(path[index], from, path[index + 1], to);
        if (catch portal) break;
        if (options.area_crossings && from.poly.area_type.area == to.poly.area_type.area) continue;
        if (try crossing = intersect_seg_seg_2d(start, end, portal.left, portal.right)) {
            AppendStatus status = append_vertex(
                writer:   writer,
                position: lerp_point(portal.left, portal.right, crossing[1]),
                flags:    {},
                ref:      path[index + 1],
            );
            if (status != IN_PROGRESS) return status;
        }
    }
    return IN_PROGRESS;
}
