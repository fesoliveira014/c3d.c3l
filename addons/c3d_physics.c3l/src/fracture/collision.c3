module c3d::physics::fracture;

import c3d;
import std::math;
import std::sort;

const uint COLLISION_TETRAHEDRON_VERTICES @private = 4;
const uint COLLISION_FLOAT_MAGNITUDE_MASK @local = uint::max >> 1;

<* Borrow one convex point set in its piece frame. *>
struct FractureHullView {
    uint piece_index;
    Vec3[] points;
}

<* Own convex hull input geometry grouped by physical piece. *>
struct FractureCollision {
    Allocator allocator;
    FractureHullView[] hulls;
    char[] storage;
}

struct CollisionHullLink @private {
    FractureHullView hull;
    CollisionHullLink* next;
}

struct CollisionBuild @private {
    FractureLimits limits;
    CollisionHullLink* first;
    CollisionHullLink* last;
    uint hull_count;
    uint vertex_count;
}

$assert FractureHullView::alignment >= Vec3::alignment;

<*
 Partition fragments into bounded convex collision hulls.
 @param [&inout] workspace : "Exclusively borrowed for this call."
 @param [&in] fragments : "Live result; geometry remains unchanged."
 @param max_hull_vertices : "At least four; matches the consumer limit."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, NUMERICAL_FAILURE
*>
fn FractureCollision? create_fracture_collision(
    Allocator allocator,
    FractureWorkspace* workspace,
    FractureResult* fragments,
    uint max_hull_vertices,
) {
    if (max_hull_vertices < COLLISION_TETRAHEDRON_VERTICES) return c3d::INVALID_ARGUMENT~;
    if (fragments.pieces.len > workspace.limits.max_pieces) return c3d::CAPACITY_EXCEEDED~;

    SolidScratch scratch = begin_solid_scratch(workspace);
    CollisionBuild build = { .limits = workspace.limits };

    foreach (uint piece, source : fragments.pieces) {
        if (catch failure = build_collision_piece(
            scratch: &scratch, build: &build, piece: piece,
            source: source.mesh, max_hull_vertices: max_hull_vertices,
        )) {
            if (failure == c3d::CAPACITY_EXCEEDED) return failure~;
            return NUMERICAL_FAILURE~;
        }
    }

    return copy_collision_hulls(allocator, &build);
}

<*
 Release collision storage and invalidate every hull view.
 @param [&inout] collision : "Sole owning result."
*>
fn void destroy_fracture_collision(FractureCollision* collision) {
    alloc::free_aligned(collision.allocator, collision.storage.ptr);
    *collision = {};
}

fn FractureCollision? copy_collision_hulls(Allocator allocator, CollisionBuild* build) @private {
    if (build.hull_count > (usz)sz::max / FractureHullView::size) return c3d::CAPACITY_EXCEEDED~;

    usz header_bytes = (usz)build.hull_count * FractureHullView::size;
    usz padding = (Vec3::alignment - header_bytes % Vec3::alignment) % Vec3::alignment;
    if (padding > (usz)sz::max - header_bytes) return c3d::CAPACITY_EXCEEDED~;

    usz points_offset = header_bytes + padding;
    if (build.vertex_count > ((usz)sz::max - points_offset) / Vec3::size) return c3d::CAPACITY_EXCEEDED~;

    usz bytes = math::max(points_offset + (usz)build.vertex_count * Vec3::size, (usz)1);
    char*? storage = alloc::calloc_aligned(allocator, (sz)bytes, FractureHullView::alignment);
    if (catch storage) return c3d::CAPACITY_EXCEEDED~;

    FractureCollision result = { .allocator = allocator, .storage = storage[:bytes] };
    if (!build.hull_count) return result;

    result.hulls = ((FractureHullView*)result.storage.ptr)[:build.hull_count];
    Vec3* positions = (Vec3*)(result.storage.ptr + points_offset);
    uint index;
    for (CollisionHullLink* link = build.first; link; link = link.next) {
        result.hulls[index] = { .piece_index = link.hull.piece_index, .points = positions[:link.hull.points.len] };
        result.hulls[index].points[..] = link.hull.points[..];
        positions += link.hull.points.len;
        index++;
    }

    sort::quicksort(result.hulls, &compare_collision_hulls);
    return result;
}

fn int compare_collision_positions(Vec3 first, Vec3 second) @private {
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        uint left_bits = bitcast(first[axis], uint);
        uint right_bits = bitcast(second[axis], uint);
        long left = left_bits >> FLOAT_SIGN_BIT ? -(long)(left_bits & COLLISION_FLOAT_MAGNITUDE_MASK) : (long)left_bits;
        long right = right_bits >> FLOAT_SIGN_BIT ? -(long)(right_bits & COLLISION_FLOAT_MAGNITUDE_MASK) : (long)right_bits;
        if (left != right) return left < right ? -1 : 1;
    }

    return 0;
}

fn int compare_collision_hulls(FractureHullView first, FractureHullView second) @private {
    if (first.piece_index != second.piece_index) return first.piece_index < second.piece_index ? -1 : 1;

    usz count = (usz)math::min(first.points.len, second.points.len);
    for (usz index = 0; index < count; index++) {
        int order = compare_collision_positions(first.points[index], second.points[index]);
        if (order) return order;
    }

    return first.points.len < second.points.len ? -1 : first.points.len > second.points.len ? 1 : 0;
}

fn void? append_collision_hull(
    SolidScratch* scratch,
    CollisionBuild* build,
    uint piece,
    Vec3[] points,
) @private {
    if (build.hull_count == build.limits.max_hulls
        || points.len > (usz)(build.limits.max_vertices - build.vertex_count)) return c3d::CAPACITY_EXCEEDED~;

    CollisionHullLink* link = &reserve_elements(scratch, CollisionHullLink, 1)![0];
    sort::quicksort(points, &compare_collision_positions);
    *link = { .hull = { .piece_index = piece, .points = points } };

    if (build.last) {
        build.last.next = link;
    } else {
        build.first = link;
    }

    build.last = link;
    build.hull_count++;
    build.vertex_count += (uint)points.len;

    return;
}
