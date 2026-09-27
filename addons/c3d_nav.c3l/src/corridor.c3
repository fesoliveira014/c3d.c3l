module c3d::nav;

import std::math;
import c3d;

const float MIN_TARGET_DISTANCE @local = 0.01f; // metres; mirrors findCorners' MIN_TARGET_DIST
const float MIN_VISIBILITY_DISTANCE @local = 0.01f; // metres; mirrors optimizePathVisibility's too-close test and overshoot
const float VISIBILITY_HIT_T @local = 0.99f; // mirrors optimizePathVisibility: the ray must reach this far to shortcut
const usz   VISIBILITY_POLYS @local = 32; // mirrors optimizePathVisibility's MAX_RES
const usz   MAX_VISITED @local = 16; // mirrors MAX_VISITED of movePosition and moveTargetPosition
const uint  TOPOLOGY_ITERATIONS @local = 32; // mirrors optimizePathTopology's MAX_ITER
const usz   TOPOLOGY_POLYS @local = 32; // mirrors optimizePathTopology's MAX_RES
const usz   MIN_TOPOLOGY_PATH @local = 3; // mirrors optimizePathTopology: a shorter corridor has nothing to replan
const usz   FIXED_START_PATH @local = 3; // mirrors fixPathStart: the safe start, a gap and the old end

<* The polygons around an off-mesh connection and its end points in travel order. *>
struct OffMeshCrossing {
    PolyRef[2] refs;     // the polygon before the connection, then the connection
    Vec3       start;
    Vec3       end;
}

<* Polygon corridor from a position to a target; mirrors dtPathCorridor. *>
struct PathCorridor {
    Allocator allocator;
    Vec3      position;
    Vec3      target;
    PolyRef[] path;        // capacity; live in [0, count)
    usz       count;
}

struct CommonPoly @local {
    usz path_index;
    usz visited_index;    // the first visited entry holding the polygon
}

<* Restart the corridor at one polygon and position; mirrors reset. *>
fn void PathCorridor.reset(&self, PolyRef ref, Vec3 position) {
    self.position = position;
    self.target = position;
    self.path[0] = ref;
    self.count = 1;
}

<*
 Corners of the straightened corridor from the position toward the target; mirrors findCorners.
 Corners within 1 cm of the position are dropped; none follow an off-mesh connection.
 @param out_corners : "Filled up to its length."
 @param [&in] query : "Pulls the straight path."
 @return "How many were written; 0 when the corridor's polygons are gone."
 @require self.count > 0, out_corners.len > 0
*>
fn usz PathCorridor.find_corners(&self, StraightPoint[] out_corners, NavQuery* query) {
    PathResult? straight = query.straight_path(self.position, self.target, self.polys(), out_corners);
    if (catch straight) return 0;

    usz count = straight.count;
    while (count) {
        StraightPoint first = out_corners[0];
        bool far = distance_sqr_2d(first.position, self.position) > MIN_TARGET_DISTANCE * MIN_TARGET_DISTANCE;
        if (first.flags.off_mesh_connection || far) break;
        count--;
        for (usz index = 0; index < count; index++) out_corners[index] = out_corners[index + 1];
    }
    for (usz index = 0; index < count; index++) {
        if (out_corners[index].flags.off_mesh_connection) return index + 1;
    }
    return count;
}

<*
 Shortcut the corridor toward next when a raycast within range reaches it; mirrors optimizePathVisibility.
 @param range : "Metres the ray may travel."
 @param [&in] query : "Casts the ray."
 @param [&in] filter : "Polygons it rejects stop the ray."
 @require self.count > 0, range > 0
*>
fn void PathCorridor.optimize_path_visibility(
    &self,
    Vec3 next,
    float range,
    NavQuery* query,
    QueryFilter* filter,
) {
    float distance = math::sqrt(distance_sqr_2d(self.position, next));
    if (distance < MIN_VISIBILITY_DISTANCE) return;
    // Overshooting a little helps open fields in tiled meshes.
    distance = math::min(distance + MIN_VISIBILITY_DISTANCE, range);
    Vec3 goal = self.position + (next - self.position) * (range / distance);

    PolyRef[VISIBILITY_POLYS] crossed;
    RaycastHit? hit = query.raycast(
        start_ref: self.path[0],
        start:     self.position,
        end:       goal,
        filter:    filter,
        out_path:  crossed[..],
    );
    if (catch hit) return;
    if (hit.path_count > 1 && hit.t > VISIBILITY_HIT_T) {
        self.count = merge_corridor_start_shortcut(self.path, self.count, crossed[:hit.path_count]);
    }
}

<*
 Replan the first polygons with a short sliced search; mirrors optimizePathTopology.
 Ends any sliced search the query was running.
 @param [&in] query : "Runs the search."
 @param [&in] filter : "Must outlive the call."
 @return "Whether the corridor changed."
*>
fn bool PathCorridor.optimize_path_topology(&self, NavQuery* query, QueryFilter* filter) {
    if (self.count < MIN_TOPOLOGY_PATH) return false;

    // A failed start or update leaves nothing to finalize, which the finalize reports.
    (void)query.init_sliced_find_path(
        start_ref: self.path[0],
        end_ref:   self.path[self.count - 1],
        start:     self.position,
        end:       self.target,
        filter:    filter,
    );
    (void)query.update_sliced_find_path(TOPOLOGY_ITERATIONS);
    PolyRef[TOPOLOGY_POLYS] replanned;
    PathResult? result = query.finalize_sliced_find_path_partial(self.polys(), replanned[..]);
    if (catch result) return false;
    if (!result.count) return false;
    self.count = merge_corridor_start_shortcut(self.path, self.count, replanned[:result.count]);
    return true;
}

<*
 Advance the corridor over an off-mesh connection it holds; mirrors moveOverOffmeshConnection.
 The position becomes the connection's end.
 @param [&in] query : "Resolves the connection's end points."
 @return? INVALID_REF
 @require self.count > 0
*>
fn OffMeshCrossing? PathCorridor.move_over_off_mesh_connection(&self, PolyRef off_mesh_ref, NavQuery* query) {
    PolyRef previous_ref;
    PolyRef poly_ref = self.path[0];
    usz next = 0;
    while (next < self.count && poly_ref != off_mesh_ref) {
        previous_ref = poly_ref;
        poly_ref = self.path[next];
        next++;
    }
    // A connection that ends the corridor counts as absent, as upstream.
    if (next == self.count) return INVALID_REF~;

    for (usz index = next; index < self.count; index++) self.path[index - next] = self.path[index];
    self.count -= next;
    Vec3[2] ends = query.mesh.off_mesh_end_points(previous_ref, poly_ref)!;
    self.position = ends[1];
    return { .refs = { previous_ref, poly_ref }, .start = ends[0], .end = ends[1] };
}

<*
 Replace the corridor start with a safe polygon and position; mirrors fixPathStart.
 Leaves a zero ref after the start, so is_valid fails until the corridor is replanned.
 @require self.path.len >= FIXED_START_PATH
*>
fn void PathCorridor.fix_path_start(&self, PolyRef safe_ref, Vec3 safe_position) {
    self.position = safe_position;
    if (self.count > 0 && self.count < FIXED_START_PATH) {
        self.path[2] = self.path[self.count - 1];
        self.path[0] = safe_ref;
        self.path[1] = (PolyRef)0;
        self.count = FIXED_START_PATH;
    } else {
        self.path[0] = safe_ref;
        self.path[1] = (PolyRef)0;
    }
}

<*
 Cut the corridor at its first invalid polygon and clamp the target onto the last; mirrors trimInvalidPath.
 @param [&in] query : "Tests the polygons."
 @param [&in] filter : "Polygons it rejects are invalid."
 @require self.count > 0
*>
fn void PathCorridor.trim_invalid_path(
    &self,
    PolyRef safe_ref,
    Vec3 safe_position,
    NavQuery* query,
    QueryFilter* filter,
) {
    usz valid = 0;
    while (valid < self.count && query.is_valid_ref(self.path[valid], filter)) valid++;
    if (valid == self.count) return;

    if (valid == 0) {
        self.position = safe_position;
        self.path[0] = safe_ref;
        self.count = 1;
    } else {
        self.count = valid;
    }
    if (try clamped = query.closest_point_on_poly_boundary(self.path[self.count - 1], self.target)) {
        self.target = clamped;
    }
}

<*
 Whether the first max_look_ahead polygons are resident and pass the filter; mirrors isValid.
 @param [&in] query : "Tests the polygons."
 @param [&in] filter : "Polygons it rejects are invalid."
*>
fn bool PathCorridor.is_valid(&self, usz max_look_ahead, NavQuery* query, QueryFilter* filter) {
    foreach (ref : self.path[:math::min(self.count, max_look_ahead)]) {
        if (!query.is_valid_ref(ref, filter)) return false;
    }
    return true;
}

<*
 Move the position along the surface and merge the visited polygons; mirrors movePosition.
 @param [&in] query : "Moves the position."
 @param [&in] filter : "Polygons it rejects are walls."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
 @require self.count > 0
*>
fn void? PathCorridor.move_position(
    &self,
    Vec3 new_position,
    NavQuery* query,
    QueryFilter* filter,
) {
    PolyRef[MAX_VISITED] visited;
    MoveResult moved = query.move_along_surface(
        start_ref:   self.path[0],
        start:       self.position,
        end:         new_position,
        filter:      filter,
        out_visited: visited[..],
    )!;
    self.count = merge_corridor_start_moved(self.path, self.count, visited[:moved.visited_count]);
    Vec3 position = moved.position;
    position.y = query.poly_height(self.path[0], position) ?? self.position.y;
    self.position = position;
}

<*
 Move the target along the surface and merge the visited polygons; mirrors moveTargetPosition.
 @param [&in] query : "Moves the target."
 @param [&in] filter : "Polygons it rejects are walls."
 @return? INVALID_REF, c3d::INVALID_ARGUMENT
 @require self.count > 0
*>
fn void? PathCorridor.move_target_position(
    &self,
    Vec3 new_target,
    NavQuery* query,
    QueryFilter* filter,
) {
    PolyRef[MAX_VISITED] visited;
    MoveResult moved = query.move_along_surface(
        start_ref:   self.path[self.count - 1],
        start:       self.target,
        end:         new_target,
        filter:      filter,
        out_visited: visited[..],
    )!;
    self.count = merge_corridor_end_moved(self.path, self.count, visited[:moved.visited_count]);
    self.target = moved.position;
}

<*
 Load a corridor and its target; mirrors setCorridor.
 @require path.len > 0, path.len <= self.path.len
*>
fn void PathCorridor.set_corridor(&self, Vec3 target, PolyRef[] path) {
    self.target = target;
    self.path[:path.len] = path[..];
    self.count = path.len;
}

<* First polygon, or 0 when empty. *>
fn PolyRef PathCorridor.first_poly(&self) => self.count ? self.path[0] : (PolyRef)0;

<* Last polygon, or 0 when empty. *>
fn PolyRef PathCorridor.last_poly(&self) => self.count ? self.path[self.count - 1] : (PolyRef)0;

<* The live corridor. *>
fn PolyRef[] PathCorridor.polys(&self) => self.path[:self.count];

<*
 Merge a visited chain into the front of a path; mirrors dtMergeCorridorStartMoved.
 @param [inout] path : "Its length is the capacity; live in [0, count)."
 @param visited : "Start first; the last entry holds the new position."
 @return "The new count."
 @require count <= path.len
*>
fn usz merge_corridor_start_moved(PolyRef[] path, usz count, PolyRef[] visited) {
    CommonPoly? common = find_common_poly(path[:count], visited, from_path_end: true);
    if (catch common) return count;

    sz capacity = (sz)path.len;
    sz required = (sz)visited.len - (sz)common.visited_index;
    sz origin = math::min((sz)common.path_index + 1, (sz)count);
    sz kept = math::max((sz)0, (sz)count - origin);
    if (required + kept > capacity) kept = capacity - required;
    if (kept > 0) move_refs(path, from: origin, to: required, count: kept);
    sz stored = math::min(required, capacity);
    for (sz index = 0; index < stored; index++) path[index] = visited[(sz)visited.len - 1 - index];
    return (usz)(required + kept);
}

<*
 Merge a visited chain into the back of a path; mirrors dtMergeCorridorEndMoved.
 @param [inout] path : "Its length is the capacity; live in [0, count)."
 @param visited : "From the old target; the last entry holds the new target."
 @return "The new count."
 @require count <= path.len
*>
fn usz merge_corridor_end_moved(PolyRef[] path, usz count, PolyRef[] visited) {
    CommonPoly? common = find_common_poly(path[:count], visited, from_path_end: false);
    if (catch common) return count;

    usz path_position = common.path_index + 1;
    usz visited_position = common.visited_index + 1;
    usz copied = math::min(visited.len - visited_position, path.len - path_position);
    if (copied) path[path_position:copied] = visited[visited_position:copied];
    return path_position + copied;
}

<*
 Merge a shortcut into the front of a path; mirrors dtMergeCorridorStartShortcut.
 @param [inout] path : "Its length is the capacity; live in [0, count)."
 @param visited : "From the current start along the shortcut."
 @return "The new count."
 @require count <= path.len, visited.len <= path.len
*>
fn usz merge_corridor_start_shortcut(PolyRef[] path, usz count, PolyRef[] visited) {
    CommonPoly? common = find_common_poly(path[:count], visited, from_path_end: true);
    if (catch common) return count;

    sz required = (sz)common.visited_index;
    if (required <= 0) return count;
    sz capacity = (sz)path.len;
    sz origin = (sz)common.path_index;
    sz kept = math::max((sz)0, (sz)count - origin);
    if (required + kept > capacity) kept = capacity - required;
    if (kept > 0) move_refs(path, from: origin, to: required, count: kept);
    for (sz index = 0; index < required; index++) path[index] = visited[index];
    return (usz)(required + kept);
}

<*
 Free the path array.
 @param [&inout] corridor : "Left zeroed."
*>
fn void destroy_path_corridor(PathCorridor* corridor) {
    alloc::free(corridor.allocator, corridor.path.ptr);
    *corridor = {};
}

<*
 Corridor with room for max_path polygons, allocated once.
 @return? c3d::CAPACITY_EXCEEDED
 @require max_path > 0
*>
fn PathCorridor? create_path_corridor(Allocator allocator, usz max_path) {
    PolyRef[]? path = alloc::new_array_try(allocator, PolyRef, (sz)max_path);
    if (catch path) return c3d::CAPACITY_EXCEEDED~;
    return { .allocator = allocator, .path = path };
}

// Mirrors the merges' search: the path polygon nearest the chosen end that visited holds.
fn CommonPoly? find_common_poly(PolyRef[] path, PolyRef[] visited, bool from_path_end) @local {
    for (usz step = 0; step < path.len; step++) {
        usz path_index = from_path_end ? path.len - 1 - step : step;
        foreach (usz visited_index, ref : visited) {
            if (ref == path[path_index]) return { .path_index = path_index, .visited_index = visited_index };
        }
    }
    return NOT_FOUND~;
}

// Mirrors the merges' memmove: the ranges may overlap.
fn void move_refs(PolyRef[] path, sz from, sz to, sz count) @local {
    mem::move(&path[to], &path[from], count * (sz)PolyRef::size);
}
