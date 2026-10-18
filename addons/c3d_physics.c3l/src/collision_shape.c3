module c3d::physics;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics::collide;
import std::math;
import b3;

const uint MAX_COLLISION_FACE_VERTICES @local = 32; // two clipped faces fit the native 64-vertex scratch
const float MIN_COLLISION_HULL_SCALE @local = 0.01f; // native floor; box3d pushes smaller components away from zero
const float COLLISION_LINEAR_SLOP @local = 0.005f; // native linear slop at one length unit per metre
const float COLLISION_BOX_SLOP_FRACTION @local = 0.2f; // native box half-extents are floored at this fraction
const usz COLLISION_HULL_WORK_BASE @local = 242_112; // pinned 128-vertex builder, largest supported pointer layout
const usz COLLISION_HULL_WORK_PER_POINT @local = 60; // one native work vertex and one shifted Vec3
const usz MAX_COLLISION_SOURCE_POINTS @local = (0x7fff_fff0 - COLLISION_HULL_WORK_BASE) / COLLISION_HULL_WORK_PER_POINT;
const float COLLISION_SQRT3 @local = 1.732050808f; // native B3_SQRT3
const float COLLISION_FLOAT_EPSILON @local = 1.1920928955078125e-7f; // native FLT_EPSILON

$assert b3::MAX_HULL_VERTICES == 128;
$assert void*::size <= 8;

<* Scale, geometry and source values for a prepared query shape. *>
struct CollisionShapeDesc {
    ColliderKind kind;
    Vec3 scale;
    float radius;
    float half_height;
    Vec3 half_extents;
    GeometryId geometry;
    HeightField height_field;
    char[] material_indices;
}

<* Own prepared query geometry and its cache lifetime interest. *>
struct CollisionShape {
    CollisionShapeState* state;
}

<* Borrow prepared geometry until its CollisionShape is destroyed. *>
struct CollisionShapeView {
    CollisionShapeState* state;
}

struct CollisionShapeState @private {
    Allocator allocator;
    SnapshotTable* cache;
    SnapshotHandle snapshot;
    collide::Shape shape;
    maths::Aabb bounds;
}

<*
 Borrow this owner's prepared geometry.
 @param [&in] self : "Outlives every use of the returned view."
 @require self.state != null
*>
fn CollisionShapeView CollisionShape.view(&self) => { .state = self.state };

<* Unit-scale query description with caller-supplied dimensions or source. *>
fn CollisionShapeDesc default_collision_shape_desc(ColliderKind kind) {
    return { .kind = kind, .scale = { 1, 1, 1 } };
}

<*
 Prepare immutable scaled convex geometry for world-free queries.
 @param [&inout] cache : "Borrowed; outlives the prepared owner."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @return? SOURCE_UNAVAILABLE, b3::DEGENERATE_GEOMETRY, b3::INVALID_DEFINITION
*>
fn CollisionShape? create_collision_shape(Allocator allocator, CollisionCache* cache, CollisionShapeDesc desc) {
    if (!cache.state) return c3d::INVALID_ARGUMENT~;
    foreach (scale : desc.scale) {
        if (!math::is_finite(scale) || scale == 0) return c3d::INVALID_ARGUMENT~;
    }

    Vec3 magnitude = math::abs(desc.scale);
    CollisionShapeState state = { .allocator = allocator, .cache = cache.state };
    defer catch release_snapshot(state.cache, state.snapshot);

    Vec3 extents;
    switch (desc.kind) {
        case SPHERE:
            check_collision_dimension(desc.radius)!;
            float radius = desc.radius * collision_uniform_scale(magnitude)!;
            check_collision_quantity(radius * radius)!;
            state.shape = collide::sphere_shape(radius);
            extents = { radius, radius, radius };
        case CAPSULE:
            check_collision_dimension(desc.radius)!;
            check_collision_dimension(desc.half_height)!;
            float factor = collision_uniform_scale(magnitude)!;
            float radius = desc.radius * factor;
            float half_height = desc.half_height * factor;
            check_collision_quantity(radius * radius)!;
            check_collision_quantity(half_height * half_height)!;
            if (2 * half_height < COLLISION_LINEAR_SLOP * b3::length_units_per_meter()) {
                return c3d::UNSUPPORTED~;
            }
            extents = { radius, half_height + radius, radius };
            check_collision_quantity(extents.y)!;
            state.shape = collide::capsule_shape(half_height, radius);
        case BOX:
            float minimum = COLLISION_BOX_SLOP_FRACTION * (COLLISION_LINEAR_SLOP * b3::length_units_per_meter());
            Vec3 half = desc.half_extents * magnitude;
            foreach (index, extent : desc.half_extents) {
                check_collision_dimension(extent)!;
                if (half[index] < minimum) return c3d::UNSUPPORTED~;
                check_collision_quantity(half[index] * half[index])!;
            }
            float volume = 8 * half.x * half.y * half.z;
            check_collision_quantity(volume)!;
            Vec3 size = 2 * half;
            Vec3 squared = size * size;
            check_collision_quantity(volume * (squared.y + squared.z))!;
            check_collision_quantity(volume * (squared.x + squared.z))!;
            check_collision_quantity(volume * (squared.x + squared.y))!;
            check_collision_quantity(8 * (half.x * half.y + half.x * half.z + half.y * half.z))!;
            state.shape = collide::box_shape(half);
            extents = half;
        case HULL:
            foreach (component : magnitude) {
                if (component < MIN_COLLISION_HULL_SCALE) return c3d::UNSUPPORTED~;
            }
            if (!cache.state.assets.geometries.is_live(desc.geometry)) return c3d::INVALID_ID~;
            if (desc.scale == (Vec3){ 1, 1, 1 }) {
                state.snapshot = acquire_hull(cache.state, desc.geometry, query: true)!;
            } else {
                state.snapshot = acquire_scaled_hull(cache.state, desc.geometry, desc.scale)!;
            }
            b3::HullData* hull = snapshot_of(cache.state, state.snapshot).hull;
            check_collision_hull(hull)!;
            state.shape = { .kind = collide::ShapeKind.HULL, .hull = hull };
            state.bounds = { .min = hull.aabb.lower_bound, .max = hull.aabb.upper_bound };
        case MESH:
        case HEIGHT_FIELD:
        case COMPOUND:
            return c3d::UNSUPPORTED~;
    }

    if (desc.kind != HULL) state.bounds = { .min = -extents, .max = extents };
    CollisionShapeState* owned = alloc::new_try(allocator, CollisionShapeState) ?? c3d::CAPACITY_EXCEEDED~!;
    *owned = state;
    cache.state.borrowers++;
    return { .state = owned };
}

<*
 Release prepared geometry and invalidate its borrowed views.
 @param [&inout] shape : "Left zeroed."
*>
fn void destroy_collision_shape(CollisionShape* shape) {
    CollisionShapeState* state = shape.state;
    if (!state) return;
    release_snapshot(state.cache, state.snapshot);
    state.cache.borrowers--;
    alloc::free(state.allocator, state);
    *shape = {};
}

fn float? collision_uniform_scale(Vec3 magnitude) @local {
    if (magnitude.x != magnitude.y || magnitude.y != magnitude.z) return c3d::UNSUPPORTED~;
    return magnitude.x;
}

fn void? check_collision_dimension(float value) @local {
    if (!math::is_finite(value) || value <= 0) return c3d::INVALID_ARGUMENT~;
}

fn void? check_collision_quantity(float value) @local {
    if (!math::is_finite(value) || value <= 0) return b3::DEGENERATE_GEOMETRY~;
}

// The pinned hull builder uses points[0] as its origin and a signed-int aligned work allocation.
fn void? check_collision_hull_source(Vec3[] points) @private {
    if (points.len > MAX_COLLISION_SOURCE_POINTS) return c3d::CAPACITY_EXCEEDED~;
    if (points.len < 4) return b3::DEGENERATE_GEOMETRY~;

    Vec3 maximum;
    Vec3 lower = { float::max, float::max, float::max };
    Vec3 upper = -lower;
    foreach (point : points) {
        foreach (coordinate : point) if (!math::is_finite(coordinate)) return c3d::INVALID_ARGUMENT~;
        Vec3 shifted = point - points[0];
        foreach (coordinate : shifted) {
            if (!math::is_finite(coordinate)) return b3::DEGENERATE_GEOMETRY~;
        }
        maximum = math::max(maximum, math::abs(shifted));
        lower = math::min(lower, shifted);
        upper = math::max(upper, shifted);
    }

    Vec3 span = upper - lower;
    check_collision_quantity(span.dot(span))!;
    Vec3 cross = { 2 * span.y * span.z, 2 * span.z * span.x, 2 * span.x * span.y };
    check_collision_quantity(cross.dot(cross))!;
    float longest = math::max(span.x, math::max(span.y, span.z));
    check_collision_quantity(1 / (longest * longest))!;

    float sum = maximum.x + maximum.y + maximum.z;
    float coordinate = math::max(maximum.x, math::max(maximum.y, maximum.z));
    float diagonal = COLLISION_SQRT3 * coordinate;
    check_collision_quantity(sum)!;
    check_collision_quantity(diagonal)!;
    float tolerance = (3.0f * math::min(diagonal, sum) * 1.01f + coordinate) * COLLISION_FLOAT_EPSILON;
    check_collision_quantity(tolerance)!;
    check_collision_quantity(8 * tolerance)!;
}

// The scaled points reach the native rebake, so they pass the same arithmetic admission as authored source.
fn void? check_collision_hull_scale(b3::HullData* hull, Vec3 scale) @private {
    Vec3* points = (Vec3*)((char*)hull + hull.point_offset);
    Vec3[b3::MAX_HULL_VERTICES] scaled;
    foreach (index, point : points[:hull.vertex_count]) {
        scaled[index] = point * scale;
        foreach (coordinate : scaled[index]) {
            if (!math::is_finite(coordinate)) return b3::DEGENERATE_GEOMETRY~;
        }
    }
    check_collision_hull_source(scaled[:hull.vertex_count])!;
}

fn void? check_collision_hull(b3::HullData* hull) @local {
    if (hull.vertex_count > b3::MAX_HULL_VERTICES) return c3d::CAPACITY_EXCEEDED~;
    check_collision_quantity(hull.volume)!;
    check_collision_quantity(hull.surface_area)!;
    check_collision_quantity(hull.inner_radius)!;
    if (!b3::is_valid_aabb(hull.aabb) || !b3::is_valid_matrix3(hull.central_inertia)
        || !b3::is_valid_vec3(hull.center)) return b3::DEGENERATE_GEOMETRY~;

    Vec3* points = (Vec3*)((char*)hull + hull.point_offset);
    foreach (point : points[:hull.vertex_count]) {
        if (!b3::is_valid_vec3(point)) return b3::DEGENERATE_GEOMETRY~;
    }

    b3::Plane* planes = (b3::Plane*)((char*)hull + hull.plane_offset);
    foreach (plane : planes[:hull.face_count]) {
        if (!b3::is_valid_plane(plane)) return b3::DEGENERATE_GEOMETRY~;
    }

    b3::HullFace* faces = (b3::HullFace*)((char*)hull + hull.face_offset);
    b3::HullHalfEdge* edges = (b3::HullHalfEdge*)((char*)hull + hull.edge_offset);
    foreach (face : faces[:hull.face_count]) {
        uint count;
        uint edge = face.edge;
        do {
            if (++count > MAX_COLLISION_FACE_VERTICES) return c3d::CAPACITY_EXCEEDED~;
            edge = edges[edge].next;
        } while (edge != face.edge);
    }
}
