module c3d::physics;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics::collide;
import std::math;
import b3;

const uint MAX_COLLISION_FACE_VERTICES @private = 32; // two clipped faces fit the native 64-vertex scratch
const float MIN_COLLISION_SCALE @local = 0.01f; // box3d pushes smaller hull components away from zero
const float COLLISION_LINEAR_SLOP @private = 0.005f; // native linear slop at one length unit per metre
const int MAX_COLLISION_MESH_HEIGHT @local = 256; // native mesh traversal stack holds this many node pointers
const float COLLISION_TRIANGLE_AREA_FLOOR @local = 1.17549435e-35f; // twin of b3 TRIANGLE_AREA_FLOOR, the native 1000 * FLT_MIN
const float COLLISION_ENUMERATION_GROWTH @local = 4; // keeps boundary triangles inside the inclusive whole-surface box
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
    b3::Mesh mesh; // data is null for convex shapes
    b3::HeightFieldData* height_field; // null unless the shape is a height field
    Vec3 field_scale; // the scale baked into the height field; unused otherwise
    maths::Aabb bounds;
}

struct CollisionTriangleAudit @private {
    usz triangles;
    fault failure;
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
 Prepare immutable scaled convex, mesh or height-field geometry for world-free queries.
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

    switch (desc.kind) {
        case SPHERE:
            check_collision_dimension(desc.radius)!;

            float radius = desc.radius * collision_uniform_scale(magnitude)!;
            check_collision_quantity(radius * radius)!;

            state.shape = collide::sphere_shape(radius);

            Vec3 extents = { radius, radius, radius };
            state.bounds = { .min = -extents, .max = extents };
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

            Vec3 extents = { radius, half_height + radius, radius };
            check_collision_quantity(extents.y)!;
            state.shape = collide::capsule_shape(half_height, radius);
            state.bounds = { .min = -extents, .max = extents };
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
            state.bounds = { .min = -half, .max = half };
        case HULL:
            check_collision_scale_floor(magnitude)!;

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
            check_collision_scale_floor(magnitude)!;

            if (!cache.state.assets.geometries.is_live(desc.geometry)) return c3d::INVALID_ID~;
            state.snapshot = acquire_mesh(
                table: cache.state,
                geometry: desc.geometry,
                material_indices: desc.material_indices,
                query: true,
            )!;

            state.mesh = { .data = snapshot_of(cache.state, state.snapshot).mesh, .scale = desc.scale };
            state.bounds = check_collision_mesh(state.mesh)!;
        case HEIGHT_FIELD:
            check_collision_height_scale(desc.scale)!;

            @pool() {
                state.snapshot = acquire_height_field(
                    table: cache.state,
                    field: desc.height_field,
                    scale: desc.scale,
                    material_indices: desc.material_indices,
                    query: true,
                )!;
            };

            state.height_field = snapshot_of(cache.state, state.snapshot).height_field;
            state.field_scale = desc.scale;
            state.bounds = check_collision_height_field(state.height_field)!;
        case COMPOUND:
            return c3d::UNSUPPORTED~;
    }

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

fn void? check_collision_scale_floor(Vec3 magnitude) @local {
    foreach (component : magnitude) {
        if (component < MIN_COLLISION_SCALE) return c3d::UNSUPPORTED~;
    }
}

fn void? check_collision_dimension(float value) @local {
    if (!math::is_finite(value) || value <= 0) return c3d::INVALID_ARGUMENT~;
}

fn void? check_collision_quantity(float value) @private {
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

// The native cook reads indices and material indices unchecked, so query owners validate authored arrays first.
fn void? check_collision_mesh_source(Geometry* source, char[] material_indices) @private {
    uint[] indices = source.indices;
    usz index_count = indices.len ? indices.len : source.positions.len;
    if (source.positions.len > int::max || index_count > int::max) return c3d::CAPACITY_EXCEEDED~;
    if (index_count % 3 != 0) return c3d::INVALID_ARGUMENT~;
    if (material_indices.len && material_indices.len != index_count / 3) return c3d::INVALID_ARGUMENT~;

    foreach (position : source.positions) {
        if (!collision_vector_finite(position)) return c3d::INVALID_ARGUMENT~;
    }

    foreach (index : indices) {
        if (index >= source.positions.len) return c3d::INVALID_ARGUMENT~;
    }
}

// Reads the retained surface through the scaled view, so entries cooked by bodies are checked the same way.
fn maths::Aabb? check_collision_mesh(b3::Mesh mesh) @private {
    if (mesh.data.tree_height() > MAX_COLLISION_MESH_HEIGHT) return c3d::CAPACITY_EXCEEDED~;

    b3::Aabb native = mesh.data.compute_aabb(IDENTITY_FRAME, mesh.scale);
    maths::Aabb bounds = { .min = native.lower_bound, .max = native.upper_bound };
    if (!collision_vector_finite(bounds.min) || !collision_vector_finite(bounds.max)) {
        return b3::DEGENERATE_GEOMETRY~;
    }

    CollisionTriangleAudit audit;
    b3::query_mesh(
        mesh: &mesh,
        bounds: collision_surface_enumeration(bounds)!,
        fcn: &audit_collision_triangle,
        context: &audit,
    );
    if (audit.failure) return audit.failure~;
    if (!audit.triangles) return b3::DEGENERATE_GEOMETRY~;

    return bounds;
}

fn b3::Aabb? collision_surface_enumeration(maths::Aabb bounds) @private {
    Vec3 reach = math::max(math::abs(bounds.min), math::abs(bounds.max));
    float largest = math::max(reach.x, math::max(reach.y, reach.z));
    float reference = math::max(largest, b3::length_units_per_meter());
    float half = collision_bound_product(reference, COLLISION_ENUMERATION_GROWTH)!;
    Vec3 extent = { half, half, half };

    return { .lower_bound = -extent, .upper_bound = extent };
}

fn bool audit_collision_triangle(
    Vec3 first,
    Vec3 second,
    Vec3 third,
    int triangle_index,
    void* context,
) @private {
    CollisionTriangleAudit* audit = context;
    Vec3 cross = (second - first).cross(third - first);
    float area = cross.dot(cross);
    if (!collision_vector_finite(first) || !collision_vector_finite(second) || !collision_vector_finite(third)
        || !math::is_finite(area) || area <= COLLISION_TRIANGLE_AREA_FLOOR) {
        audit.failure = b3::DEGENERATE_GEOMETRY;
        return false;
    }

    audit.triangles++;
    return true;
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
