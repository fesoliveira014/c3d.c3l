module c3d::nav;

import std::math;
import c3d;

const float RAY_CAST_LIMIT_PROPORTIONS @local = 50; // mirrors DT_RAY_CAST_LIMIT_PROPORTIONS; agent radii per shortcut
const usz   LINE_OF_SIGHT_POLYS @local = 32; // polygons a shortcut ray may cross; a longer crossing takes no shortcut

<* Options of a sliced search; mirrors dtFindPathOptions. *>
bitstruct FindPathOptions : uint {
    bool any_angle : 1;    // raycast shortcuts during the search; costs still apply
}

<* Progress of a sliced search. *>
enum SlicedStatus {
    IN_PROGRESS,
    DONE,
}

<* Result of one update of a sliced search. *>
struct SlicedProgress {
    SlicedStatus status;
    uint         iterations;
}

<* State of the search in progress; mirrors dtQueryData. *>
struct SlicedQuery {
    SlicedStatus    status;
    bool            out_of_nodes;           // a neighbour found no free node; the result is partial
    SearchNode*     last_best;              // null when no search runs or it failed
    float           last_best_heuristic;
    PolyRef         start_ref;
    PolyRef         end_ref;
    Vec3            start;
    Vec3            end;
    QueryFilter*    filter;
    FindPathOptions options;
    float           raycast_limit_sqr;
}

<*
 Start a sliced A* search; mirrors initSlicedFindPath.
 The filter must outlive the search; A* or Dijkstra queries before finalize corrupt it.
 @param start : "Inside the start polygon."
 @param end : "Inside the end polygon."
 @param [&in] filter : "Polygons it rejects are not entered."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
*>
fn void? NavQuery.init_sliced_find_path(
    &self,
    PolyRef start_ref,
    PolyRef end_ref,
    Vec3 start,
    Vec3 end,
    QueryFilter* filter,
    FindPathOptions options = {},
) {
    NavMesh* mesh = self.mesh;
    self.sliced = {
        .status            = DONE,
        .start_ref         = start_ref,
        .end_ref           = end_ref,
        .start             = start,
        .end               = end,
        .filter            = filter,
        .options           = options,
        .raycast_limit_sqr = float::max,
    };
    if (!mesh.is_valid_ref(start_ref) || !mesh.is_valid_ref(end_ref)) return INVALID_REF~;
    if (!finite_point(start) || !finite_point(end)) return c3d::INVALID_ARGUMENT~;
    if (options.any_angle) {
        // The limit is not sensitive, so the start tile's agent radius serves the whole search.
        float radius = mesh.tile_and_poly_unchecked(start_ref).tile.header.walkable_radius;
        float limit = radius * RAY_CAST_LIMIT_PROPORTIONS;
        self.sliced.raycast_limit_sqr = limit * limit;
    }

    self.nodes.clear();
    self.open.clear();
    SearchNode* start_node = self.nodes.get_node(start_ref);
    start_node.position = start;
    start_node.total = (end - start).length() * HEURISTIC_SCALE;
    start_node.bits.open = true;
    self.open.push(start_node);
    self.sliced.last_best = start_node;
    self.sliced.last_best_heuristic = start_node.total;
    if (start_ref != end_ref) self.sliced.status = IN_PROGRESS;
}

<*
 Run up to max_iterations expansions; mirrors updateSlicedFindPath.
 A start, end or parent polygon removed mid-search ends the search with INVALID_REF.
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
*>
fn SlicedProgress? NavQuery.update_sliced_find_path(&self, uint max_iterations) {
    SlicedQuery* sliced = &self.sliced;
    if (!sliced.last_best) return c3d::INVALID_ARGUMENT~;
    if (sliced.status == DONE) return { .status = DONE };
    NavMesh* mesh = self.mesh;
    if (!mesh.is_valid_ref(sliced.start_ref) || !mesh.is_valid_ref(sliced.end_ref)) return fail_sliced(sliced);

    QueryFilter* filter = sliced.filter;
    uint iterations;
    while (iterations < max_iterations && !self.open.is_empty()) {
        iterations++;
        SearchNode* current = self.open.pop();
        current.bits.open = false;
        current.bits.closed = true;
        if (current.id == sliced.end_ref) {
            sliced.last_best = current;
            sliced.status = DONE;
            return { .status = DONE, .iterations = iterations };
        }

        TileAndPoly? found = mesh.tile_and_poly(current.id);
        if (catch found) return fail_sliced(sliced);
        SearchNode* parent = self.nodes.node_at(current.bits.parent);
        PolyRef parent_ref = parent ? parent.id : (PolyRef)0;
        if (parent_ref) {
            SearchNode* grandparent = self.nodes.node_at(parent.bits.parent);
            if (!mesh.is_valid_ref(parent_ref)) return fail_sliced(sliced);
            if (grandparent && !mesh.is_valid_ref(grandparent.id)) return fail_sliced(sliced);
        }
        bool try_shortcut = sliced.options.any_angle && parent_ref
            && (current.position - parent.position).length_sq() < sliced.raycast_limit_sqr;

        for (uint link = found.poly.first_link; link != NULL_LINK; link = found.tile.links[link].next) {
            Link* entry = &found.tile.links[link];
            PolyRef neighbour_ref = entry.ref;
            if (!neighbour_ref || neighbour_ref == parent_ref) continue;
            TileAndPoly neighbour = mesh.tile_and_poly_unchecked(neighbour_ref);
            if (!filter.passes(neighbour_ref, neighbour.poly)) continue;

            // Tile border crossings take a node per side, as find_path does, so both searches agree.
            char cross_side = entry.side == NO_SIDE ? 0 : (char)(entry.side >> 1);
            SearchNode* node = self.nodes.get_node(neighbour_ref, cross_side);
            if (!node) {
                sliced.out_of_nodes = true;
                continue;
            }
            // Upstream always skips a node reached from the same parent; only the shortcut search does here,
            // so the plain search stays equal to find_path under any costs.
            bool sibling = node.bits.parent != 0 && node.bits.parent == current.bits.parent;
            if (sliced.options.any_angle && sibling) continue;
            if (first_visit(node)) {
                if (try portal = portal_points(current.id, found, neighbour_ref, neighbour)) {
                    node.position = (portal.left + portal.right) * 0.5f;
                }
            }

            float cost;
            bool shortcut;
            if (try_shortcut) {
                RaycastHit? hit = line_of_sight(
                    query:    self,
                    from_ref: parent_ref,
                    from:     parent.position,
                    to:       node.position,
                    filter:   filter,
                );
                if (try hit) {
                    shortcut = hit.t >= 1;
                    cost = parent.cost + hit.cost;
                }
            }
            if (!shortcut) {
                cost = current.cost + filter.segment_cost(
                    from:     current.position,
                    to:       node.position,
                    current:  found.poly,
                    next_ref: neighbour_ref,
                    next:     neighbour.poly,
                );
            }
            float heuristic = 0;
            if (neighbour_ref == sliced.end_ref) {
                cost += filter.segment_cost(
                    from:     node.position,
                    to:       sliced.end,
                    current:  neighbour.poly,
                    next_ref: (PolyRef)0,
                    next:     null,
                );
            } else {
                heuristic = (sliced.end - node.position).length() * HEURISTIC_SCALE;
            }
            float total = cost + heuristic;
            if ((node.bits.open || node.bits.closed) && total >= node.total) continue;

            node.bits.parent = shortcut ? current.bits.parent : self.nodes.node_index(current);
            node.bits.closed = false;
            node.bits.parent_detached = shortcut;
            node.id = neighbour_ref;
            node.cost = cost;
            node.total = total;
            if (node.bits.open) {
                self.open.modify(node);
            } else {
                node.bits.open = true;
                self.open.push(node);
            }
            if (heuristic < sliced.last_best_heuristic) {
                sliced.last_best_heuristic = heuristic;
                sliced.last_best = node;
            }
        }
    }

    if (self.open.is_empty()) sliced.status = DONE;
    return { .status = sliced.status, .iterations = iterations };
}

<*
 Corridor to the goal, or to the node nearest it so far; mirrors finalizeSlicedFindPath.
 Ends the search.
 @param [out] out_path : "Start to end; filled up to its length."
 @return? c3d::INVALID_ARGUMENT
 @require out_path.len >= 1
*>
fn PathResult? NavQuery.finalize_sliced_find_path(&self, PolyRef[] out_path) {
    SlicedQuery sliced = self.sliced;
    self.sliced = { .status = DONE };
    if (!sliced.last_best) return c3d::INVALID_ARGUMENT~;
    if (sliced.start_ref == sliced.end_ref) {
        out_path[0] = sliced.start_ref;
        return { .count = 1 };
    }

    PathResult result = write_sliced_path(
        query:    self,
        filter:   sliced.filter,
        end_node: sliced.last_best,
        out_path: out_path,
    );
    result.partial = result.partial || sliced.last_best.id != sliced.end_ref || sliced.out_of_nodes;
    return result;
}

<*
 Corridor to the furthest polygon of an existing path the search visited; mirrors finalizeSlicedFindPathPartial.
 Ends the search.
 @param existing : "The path being replanned."
 @param [out] out_path : "Start to end; filled up to its length."
 @return "Partial, ending nearest the goal, when no existing polygon was visited."
 @return? c3d::INVALID_ARGUMENT
 @require out_path.len >= 1
*>
fn PathResult? NavQuery.finalize_sliced_find_path_partial(&self, PolyRef[] existing, PolyRef[] out_path) {
    SlicedQuery sliced = self.sliced;
    self.sliced = { .status = DONE };
    if (!sliced.last_best) return c3d::INVALID_ARGUMENT~;
    if (sliced.start_ref == sliced.end_ref) {
        out_path[0] = sliced.start_ref;
        return { .count = 1 };
    }

    SearchNode*[1] visited;
    for (usz index = existing.len; index > 0; index--) {
        if (self.nodes.find_nodes(existing[index - 1], visited[..])) break;
    }
    SearchNode* end_node = visited[0] ?: sliced.last_best;
    PathResult result = write_sliced_path(
        query:    self,
        filter:   sliced.filter,
        end_node: end_node,
        out_path: out_path,
    );
    result.partial = result.partial || !visited[0] || sliced.out_of_nodes;
    return result;
}

fn SlicedProgress? fail_sliced(SlicedQuery* sliced) @local {
    sliced.status = DONE;
    sliced.last_best = null;
    return INVALID_REF~;
}

// Upstream casts this ray with an empty path, which stops it at the first polygon, so no shortcut is ever found.
fn RaycastHit? line_of_sight(
    NavQuery* query,
    PolyRef from_ref,
    Vec3 from,
    Vec3 to,
    QueryFilter* filter,
) @local {
    PolyRef[LINE_OF_SIGHT_POLYS] crossed;
    return query.raycast(
        start_ref: from_ref,
        start:     from,
        end:       to,
        filter:    filter,
        out_path:  crossed[..],
        options:   { .use_costs = true },
    );
}

// Mirrors the finalize tail: reverses the parent chain, then writes it forward, re-tracing detached hops by raycast.
fn PathResult write_sliced_path(
    NavQuery* query,
    QueryFilter* filter,
    SearchNode* end_node,
    PolyRef[] out_path,
) @local {
    NodePool* nodes = &query.nodes;
    SearchNode* previous;
    bool previous_detached;
    for (SearchNode* node = end_node; node;) {
        SearchNode* next = nodes.node_at(node.bits.parent);
        node.bits.parent = nodes.node_index(previous);
        // After the reversal a node's flag marks the hop to the node after it.
        bool detached = node.bits.parent_detached;
        node.bits.parent_detached = previous_detached;
        previous_detached = detached;
        previous = node;
        node = next;
    }

    PathResult result;
    for (SearchNode* node = previous; node; node = nodes.node_at(node.bits.parent)) {
        if (result.count == out_path.len) {
            result.truncated = true;
            break;
        }
        if (!node.bits.parent_detached) {
            out_path[result.count++] = node.id;
            continue;
        }
        SearchNode* next = nodes.node_at(node.bits.parent);
        RaycastHit? hit = query.raycast(
            start_ref: node.id,
            start:     node.position,
            end:       next.position,
            filter:    filter,
            out_path:  out_path[result.count..],
        );
        if (catch hit) {
            result.partial = true;
            break;
        }
        result.count += hit.path_count;
        // The ray ends inside the next polygon, which its own node writes.
        if (result.count > 0 && out_path[result.count - 1] == next.id) result.count--;
        if (hit.truncated) {
            result.truncated = true;
            break;
        }
    }
    return result;
}
