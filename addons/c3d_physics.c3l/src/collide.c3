module c3d::physics::collide;

import std::math;
import c3d::maths;
import b3;

alias Quat @private = Quaternionf;

<*
 Touching points one manifold holds.
*>
const uint MAX_MANIFOLD_POINTS = 4; // mirrors b3::MAX_MANIFOLD_POINTS
<*
 Largest scale deviation a query pose may carry.
*>
const float UNIT_SCALE_TOLERANCE = 1e-4f; // a pose decomposed from a world matrix reads 0.99999994

const uint BOX_CORNER_COUNT @local = 8;

$assert (int)MAX_MANIFOLD_POINTS == b3::MAX_MANIFOLD_POINTS;
$assert b3::MAX_HULL_VERTICES == b3::MAX_SHAPE_CAST_POINTS;

<*
 Kind of a world-free query shape.
*>
enum ShapeKind {
    SPHERE,
    CAPSULE,
    BOX,
    HULL,
}

<*
 Convex hull cooked for world-free queries.
*>
struct Hull {
    b3::HullData* data;
}

<*
 Query shape at its own origin; a HULL borrows a cooked hull.
*>
struct Shape {
    ShapeKind     kind;
    float         radius;
    float         half_height;
    Vec3          half_extents;
    b3::HullData* hull;
}

<*
 One touching point of a manifold, in world space.
*>
struct ManifoldPoint {
    Vec3  point;
    float separation;
}

<*
 Touching points of two shapes; count 0 means no contact within the speculative margin.
*>
struct Manifold {
    Vec3                               normal;
    ManifoldPoint[MAX_MANIFOLD_POINTS] points;
    uint                               count;
}

<*
 Closest points of two shapes, in world space.
*>
struct Distance {
    Vec3  point_a;
    Vec3  point_b;
    Vec3  normal;
    float distance;
}

<*
 Start and end pose of one shape over a sweep.
*>
struct Sweep {
    maths::Transform start;
    maths::Transform end;
}

<*
 First contact of a cast or sweep, in world space; normal from a to b.
*>
struct Impact {
    float time;
    Vec3  point;
    Vec3  normal;
}

<*
 Ray hit against one shape, in world space.
*>
struct ShapeRayHit {
    Vec3  point;
    Vec3  normal;
    float fraction;
}

struct Proxy @local {
    b3::ShapeProxy proxy;
    Vec3[BOX_CORNER_COUNT] corners;
}

<*
 Cook the convex hull of the points; box3d owns the allocation.
 @return? b3::DEGENERATE_GEOMETRY, b3::INVALID_DEFINITION
*>
fn Hull? create_hull(Vec3[] points) {
    return { .data = b3::create_hull(points, b3::MAX_HULL_VERTICES)! };
}

<*
 Free the cooked hull; every shape borrowing it becomes invalid.
 @param [&inout] hull : "Left zeroed."
*>
fn void destroy_hull(Hull* hull) {
    if (hull.data) b3::destroy_hull(hull.data);
    *hull = {};
}

<*
 Sphere of the radius at the shape origin.
 @require radius > 0
*>
fn Shape sphere_shape(float radius) => { .kind = ShapeKind.SPHERE, .radius = radius };

<*
 Capsule along local Y.
 @require radius > 0 && half_height > 0
*>
fn Shape capsule_shape(float half_height, float radius) {
    return { .kind = ShapeKind.CAPSULE, .radius = radius, .half_height = half_height };
}

<*
 Box of the half extents at the shape origin.
 @require half_extents.x > 0 && half_extents.y > 0 && half_extents.z > 0
*>
fn Shape box_shape(Vec3 half_extents) => { .kind = ShapeKind.BOX, .half_extents = half_extents };

<*
 Shape borrowing a cooked hull; invalid after destroy_hull.
 @param [&in] hull
 @require hull.data != null
*>
fn Shape hull_shape(Hull* hull) => { .kind = ShapeKind.HULL, .hull = hull.data };

<*
 Whether the pose's scale is one within UNIT_SCALE_TOLERANCE on every axis.
 @pure
*>
fn bool unit_scale(maths::Transform pose) {
    Vec3 deviation = pose.scale - (Vec3){ 1, 1, 1 };
    return math::abs(deviation.x) <= UNIT_SCALE_TOLERANCE
        && math::abs(deviation.y) <= UNIT_SCALE_TOLERANCE
        && math::abs(deviation.z) <= UNIT_SCALE_TOLERANCE;
}

<*
 Points of a cooked hull shape; borrowed until destroy_hull.
 @require shape.kind == ShapeKind.HULL && cooked(shape)
*>
fn Vec3[] hull_points(Shape shape) {
    Vec3* points = (Vec3*)((char*)shape.hull + shape.hull.point_offset);
    return points[:shape.hull.vertex_count];
}

<*
 Whether a HULL shape still carries a cooked hull; other kinds always do.
 @pure
*>
fn bool cooked(Shape shape) => shape.kind != ShapeKind.HULL || shape.hull != null;

<*
 Touching points of two posed shapes; the normal points from a to b.
 @require unit_scale(pose_a) && unit_scale(pose_b)
 @require cooked(a) && cooked(b)
*>
fn Manifold manifold(
    Shape a,
    maths::Transform pose_a,
    Shape b,
    maths::Transform pose_b,
) {
    if (kind_rank(a.kind) < kind_rank(b.kind)) {
        Manifold swapped = manifold_ordered(b, pose_b, a, pose_a);
        swapped.normal = -swapped.normal;
        return swapped;
    }
    return manifold_ordered(a, pose_a, b, pose_b);
}

<*
 Closest points of two posed shapes; zero distance when they overlap.
 @require unit_scale(pose_a) && unit_scale(pose_b)
 @require cooked(a) && cooked(b)
*>
fn Distance distance(
    Shape a,
    maths::Transform pose_a,
    Shape b,
    maths::Transform pose_b,
) {
    Proxy proxy_a;
    Proxy proxy_b;
    proxy_of(&a, &proxy_a);
    proxy_of(&b, &proxy_b);
    b3::DistanceOutput output = b3::shape_distance({
        .proxy_a   = proxy_a.proxy,
        .proxy_b   = proxy_b.proxy,
        .transform = relative(pose_a, pose_b),
        .use_radii = true,
    })!!;
    return {
        .point_a  = to_world(pose_a, output.point_a),
        .point_b  = to_world(pose_a, output.point_b),
        .normal   = to_world_direction(pose_a, output.normal),
        .distance = output.distance,
    };
}

<*
 First contact when b moves by translation against a resting a.
 An overlapped start reports time 0 and a zero normal.
 @return? b3::NO_HIT
 @require unit_scale(pose_a) && unit_scale(pose_b)
 @require cooked(a) && cooked(b)
*>
fn Impact? cast(
    Shape a,
    maths::Transform pose_a,
    Shape b,
    maths::Transform pose_b,
    Vec3 translation,
) {
    Proxy proxy_a;
    Proxy proxy_b;
    proxy_of(&a, &proxy_a);
    proxy_of(&b, &proxy_b);
    b3::CastOutput output = b3::shape_cast({
        .proxy_a       = proxy_a.proxy,
        .proxy_b       = proxy_b.proxy,
        .transform     = relative(pose_a, pose_b),
        .translation_b = pose_a.rotation.conjugate().rotate_vec3(translation),
        .max_fraction  = 1,
    })!;
    return {
        .time   = output.fraction,
        .point  = to_world(pose_a, output.point),
        .normal = to_world_direction(pose_a, output.normal),
    };
}

<*
 First contact of two shapes moving along their sweeps.
 An overlapped start reports time 0 and a zero normal.
 @return? b3::NO_HIT
 @require unit_scale(sweep_a.start) && unit_scale(sweep_a.end)
 @require unit_scale(sweep_b.start) && unit_scale(sweep_b.end)
 @require cooked(a) && cooked(b)
*>
fn Impact? time_of_impact(
    Shape a,
    Sweep sweep_a,
    Shape b,
    Sweep sweep_b,
) {
    Proxy proxy_a;
    Proxy proxy_b;
    proxy_of(&a, &proxy_a);
    proxy_of(&b, &proxy_b);
    b3::ToiOutput output = b3::time_of_impact({
        .proxy_a      = proxy_a.proxy,
        .proxy_b      = proxy_b.proxy,
        .sweep_a      = box3d_sweep(sweep_a),
        .sweep_b      = box3d_sweep(sweep_b),
        .max_fraction = 1,
    })!!;
    switch (output.state) {
        case HIT:
            return { .time = output.fraction, .point = output.point, .normal = output.normal };
        case OVERLAPPED:
            return { .time = 0, .point = output.point };
        case UNKNOWN:
        case FAILED:
        case SEPARATED:
            return b3::NO_HIT~;
    }
}

<*
 Closest hit of a ray against one posed shape.
 A ray starting inside reports fraction 0 and a zero normal.
 @param direction : "Unit length."
 @param max_distance : "The fraction is of this length."
 @return? b3::NO_HIT
 @require unit_scale(pose)
 @require cooked(shape)
*>
fn ShapeRayHit? ray_cast(
    Shape shape,
    maths::Transform pose,
    Vec3 origin,
    Vec3 direction,
    float max_distance,
) {
    Quat inverse = pose.rotation.conjugate();
    b3::RayCastInput input = {
        .origin       = inverse.rotate_vec3(origin - pose.position),
        .translation  = inverse.rotate_vec3(direction) * max_distance,
        .max_fraction = 1,
    };
    b3::CastOutput output;
    switch (shape.kind) {
        case SPHERE:
            b3::Sphere sphere = { .radius = shape.radius };
            output = b3::ray_cast_sphere(&sphere, input)!;
        case CAPSULE:
            b3::Capsule capsule = capsule_of(&shape);
            output = b3::ray_cast_capsule(&capsule, input)!;
        case BOX:
            b3::BoxHull box = box_hull_of(&shape);
            output = b3::ray_cast_hull(&box.base, input)!;
        case HULL:
            output = b3::ray_cast_hull(shape.hull, input)!;
    }
    return {
        .point    = to_world(pose, output.point),
        .normal   = to_world_direction(pose, output.normal),
        .fraction = output.fraction,
    };
}

fn int kind_rank(ShapeKind kind) @local {
    switch (kind) {
        case SPHERE: return 0;
        case CAPSULE: return 1;
        case BOX:
        case HULL: return 2;
    }
}

fn Manifold manifold_ordered(
    Shape a,
    maths::Transform pose_a,
    Shape b,
    maths::Transform pose_b,
) @local {
    b3::Transform b_in_a = relative(pose_a, pose_b);
    b3::CollisionManifold found;
    switch (a.kind) {
        case SPHERE:
            b3::Sphere sphere_a = { .radius = a.radius };
            found = b3::collide_spheres(&sphere_a, { .radius = b.radius }, b_in_a);
        case CAPSULE:
            b3::Capsule capsule_a = capsule_of(&a);
            switch (b.kind) {
                case SPHERE: found = b3::collide_capsule_and_sphere(&capsule_a, { .radius = b.radius }, b_in_a);
                case CAPSULE: found = b3::collide_capsules(&capsule_a, capsule_of(&b), b_in_a);
                case BOX:
                case HULL: unreachable("ordered pairs never put a hull second after a capsule");
            }
        case BOX:
        case HULL:
            b3::BoxHull box_a;
            b3::HullData* hull_a = hull_data_of(&a, &box_a);
            switch (b.kind) {
                case SPHERE:
                    found = b3::collide_hull_and_sphere(hull_a, { .radius = b.radius }, b_in_a);
                case CAPSULE:
                    found = b3::collide_hull_and_capsule(hull_a, capsule_of(&b), b_in_a);
                case BOX:
                case HULL:
                    b3::BoxHull box_b;
                    found = b3::collide_hulls(hull_a, hull_data_of(&b, &box_b), b_in_a)!!;
            }
    }

    Manifold result = { .normal = to_world_direction(pose_a, found.normal), .count = (uint)found.point_count };
    for (uint index = 0; index < result.count; index++) {
        result.points[index] = {
            .point      = to_world(pose_a, found.points[index].point),
            .separation = found.points[index].separation,
        };
    }
    return result;
}

fn void proxy_of(Shape* shape, Proxy* proxy) @local {
    switch (shape.kind) {
        case SPHERE:
            proxy.corners[0] = { 0, 0, 0 };
            proxy.proxy = { .points = &proxy.corners, .count = 1, .radius = shape.radius };
        case CAPSULE:
            proxy.corners[0] = { 0, -shape.half_height, 0 };
            proxy.corners[1] = { 0, shape.half_height, 0 };
            proxy.proxy = { .points = &proxy.corners, .count = 2, .radius = shape.radius };
        case BOX:
            for (uint corner = 0; corner < BOX_CORNER_COUNT; corner++) {
                Vec3 sign = { corner & 1 ? 1 : -1, corner & 2 ? 1 : -1, corner & 4 ? 1 : -1 };
                proxy.corners[corner] = shape.half_extents * sign;
            }
            proxy.proxy = { .points = &proxy.corners, .count = BOX_CORNER_COUNT };
        case HULL:
            Vec3[] points = hull_points(*shape);
            proxy.proxy = { .points = points.ptr, .count = (int)points.len };
    }
}

fn b3::Capsule capsule_of(Shape* shape) @local {
    return {
        .center1 = { 0, -shape.half_height, 0 },
        .center2 = { 0, shape.half_height, 0 },
        .radius  = shape.radius,
    };
}

fn b3::BoxHull box_hull_of(Shape* shape) @local {
    return b3::make_box_hull(shape.half_extents.x, shape.half_extents.y, shape.half_extents.z);
}

fn b3::HullData* hull_data_of(Shape* shape, b3::BoxHull* storage) @local {
    if (shape.kind == ShapeKind.HULL) return shape.hull;
    *storage = box_hull_of(shape);
    return &storage.base;
}

fn b3::Transform relative(maths::Transform pose_a, maths::Transform pose_b) @local {
    Quat inverse = pose_a.rotation.conjugate();
    return {
        .p = inverse.rotate_vec3(pose_b.position - pose_a.position),
        .q = inverse.mul(pose_b.rotation).normalize(),
    };
}

fn b3::Sweep box3d_sweep(Sweep sweep) @local {
    return {
        .c1 = sweep.start.position,
        .c2 = sweep.end.position,
        .q1 = sweep.start.rotation,
        .q2 = sweep.end.rotation,
    };
}

fn Vec3 to_world(maths::Transform pose, Vec3 point) @local => pose.rotation.rotate_vec3(point) + pose.position;

fn Vec3 to_world_direction(maths::Transform pose, Vec3 direction) @local => pose.rotation.rotate_vec3(direction);
