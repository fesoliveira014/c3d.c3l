module c3d::physics;

import std::math;
import c3d::maths;
import c3d::physics::collide @public;
import b3;

const usz COLLISION_TRIANGLE_POINTS @local = 64; // two clipped 32-vertex faces; 1,536 B of stack per contacts call
const float COLLISION_SPECULATIVE_SLOPS @local = 4; // native contact margin, in linear slops

$assert COLLISION_TRIANGLE_POINTS == 2 * MAX_COLLISION_FACE_VERTICES;

struct MeshPair @local {
    CollisionShapeState* surface;
    maths::Transform surface_pose;
    CollisionShapeState* convex;
    maths::Transform convex_pose;
    bool convex_first;
}

struct MeshContactWriter @local {
    b3::Transform surface_in_convex;
    maths::Transform convex_pose;
    collide::Shape shape;
    b3::HullData* hull;
    bool convex_first;
    CollisionContact[] output;
    usz count;
    fault failure;
    b3::LocalManifoldPoint[COLLISION_TRIANGLE_POINTS] scratch;
}

struct MeshDistanceSearch @local {
    b3::ShapeProxy proxy;
    b3::Transform convex_in_surface;
    b3::DistanceOutput nearest;
    fault failure;
}

fn usz? mesh_contacts(
    CollisionShapeState* first,
    maths::Transform pose_a,
    CollisionShapeState* second,
    maths::Transform pose_b,
    CollisionContact[] output,
) @private {
    MeshPair pair = admit_mesh_pair(
        first: first,
        pose_a: pose_a,
        second: second,
        pose_b: pose_b,
    )!;

    maths::Aabb query = collision_relative_bounds(pair.surface_pose, pair.convex.bounds, pair.convex_pose)!;
    float margin = COLLISION_SPECULATIVE_SLOPS * COLLISION_LINEAR_SLOP * b3::length_units_per_meter();
    query = { .min = query.min - margin, .max = query.max + margin };

    b3::BoxHull box_storage;
    MeshContactWriter writer = {
        .surface_in_convex = collide::relative(pair.convex_pose, pair.surface_pose),
        .convex_pose = pair.convex_pose,
        .shape = pair.convex.shape,
        .convex_first = pair.convex_first,
        .output = output,
    };
    if (writer.shape.kind == collide::ShapeKind.BOX || writer.shape.kind == collide::ShapeKind.HULL) {
        writer.hull = collide::hull_data_of(&writer.shape, &box_storage);
    }

    b3::query_mesh(
        mesh: &pair.surface.mesh,
        bounds: { .lower_bound = query.min, .upper_bound = query.max },
        fcn: &write_mesh_contacts,
        context: &writer,
    );
    if (writer.failure) return writer.failure~;

    return writer.count;
}

fn collide::Distance? mesh_distance(
    CollisionShapeState* first,
    maths::Transform pose_a,
    CollisionShapeState* second,
    maths::Transform pose_b,
) @private {
    MeshPair pair = admit_mesh_pair(
        first: first,
        pose_a: pose_a,
        second: second,
        pose_b: pose_b,
    )!;

    collide::Proxy proxy;
    collide::proxy_of(&pair.convex.shape, &proxy);
    MeshDistanceSearch search = {
        .proxy = proxy.proxy,
        .convex_in_surface = collide::relative(pair.surface_pose, pair.convex_pose),
        .nearest = { .distance = float::max },
    };
    b3::query_mesh(
        mesh: &pair.surface.mesh,
        bounds: collision_surface_enumeration(pair.surface.bounds)!,
        fcn: &measure_mesh_triangle,
        context: &search,
    );
    if (search.failure) return search.failure~;

    b3::DistanceOutput nearest = search.nearest;
    collide::Distance found = {
        .point_a = collide::to_world(pair.surface_pose, nearest.point_a),
        .point_b = collide::to_world(pair.surface_pose, nearest.point_b),
        .normal = collide::to_world_direction(pair.surface_pose, nearest.normal),
        .distance = nearest.distance,
    };
    if (pair.convex_first) {
        found = {
            .point_a = found.point_b,
            .point_b = found.point_a,
            .normal = -found.normal,
            .distance = found.distance,
        };
    }

    check_collision_vector(found.point_a)!;
    check_collision_vector(found.point_b)!;
    check_collision_vector(found.normal)!;
    if (!math::is_finite(found.distance)) return c3d::UNSUPPORTED~;

    return found;
}

fn collide::Impact? mesh_cast(
    CollisionShapeState* first,
    maths::Transform pose_a,
    CollisionShapeState* second,
    maths::Transform pose_b,
    Vec3 translation_a,
    Vec3 translation_b,
) @private {
    MeshPair pair = admit_mesh_pair(
        first: first,
        pose_a: pose_a,
        second: second,
        pose_b: pose_b,
    )!;

    Vec3 surface_translation = pair.convex_first ? translation_b : translation_a;
    Vec3 convex_translation = pair.convex_first ? translation_a : translation_b;
    Vec3 relative_translation = convex_translation - surface_translation;
    check_collision_vector(relative_translation)!;

    Vec3 local_translation = collision_rotate(pair.surface_pose.rotation.conjugate(), relative_translation)!;
    check_collision_relative(
        first: pair.surface.bounds,
        pose_a: pair.surface_pose,
        second: pair.convex.bounds,
        pose_b: pair.convex_pose,
        translation: local_translation,
    )!;
    check_collision_world(first.bounds, pose_a, translation_a)!;
    check_collision_world(second.bounds, pose_b, translation_b)!;

    collide::Proxy proxy;
    collide::proxy_of(&pair.convex.shape, &proxy);
    b3::Transform convex_in_surface = collide::relative(pair.surface_pose, pair.convex_pose);
    Vec3[b3::MAX_SHAPE_CAST_POINTS] placed;
    foreach (index, point : proxy.proxy.points[:proxy.proxy.count]) {
        placed[index] = convex_in_surface.q.rotate_vec3(point) + convex_in_surface.p;
    }

    b3::CastOutput hit = b3::shape_cast_mesh(
        mesh: &pair.surface.mesh,
        input: {
            .proxy = { .points = &placed, .count = proxy.proxy.count, .radius = proxy.proxy.radius },
            .translation = local_translation,
            .max_fraction = 1,
            .can_encroach = false,
        },
    )!;

    Vec3 normal = collide::to_world_direction(pair.surface_pose, hit.normal);
    collide::Impact found = {
        .time = hit.fraction,
        .point = collide::to_world(pair.surface_pose, hit.point) + surface_translation * hit.fraction,
        .normal = pair.convex_first ? -normal : normal,
    };
    check_collision_impact(found)!;

    return found;
}

fn collide::Impact? mesh_time_of_impact(
    CollisionShapeView first,
    collide::Sweep sweep_a,
    CollisionShapeView second,
    collide::Sweep sweep_b,
) @private {
    foreach (pose : (maths::Transform[4]){ sweep_a.start, sweep_a.end, sweep_b.start, sweep_b.end }) {
        check_collision_pose(pose)!;
    }
    foreach (sweep : (collide::Sweep[2]){ sweep_a, sweep_b }) {
        if (!collision_orientation_unchanged(sweep.start.rotation, sweep.end.rotation)) return c3d::UNSUPPORTED~;
    }

    Vec3 translation_a = sweep_a.end.position - sweep_a.start.position;
    Vec3 translation_b = sweep_b.end.position - sweep_b.start.position;
    check_collision_vector(translation_a)!;
    check_collision_vector(translation_b)!;

    return first.cast(
        pose_a: sweep_a.start,
        other: second,
        pose_b: sweep_b.start,
        translation_a: translation_a,
        translation_b: translation_b,
    );
}

fn collide::ShapeRayHit? mesh_ray_cast(
    b3::Mesh* mesh,
    maths::Transform pose,
    Vec3 local_origin,
    Vec3 local_translation,
) @private {
    b3::CastOutput hit = b3::ray_cast_mesh(mesh, {
        .origin = local_origin,
        .translation = local_translation,
        .max_fraction = 1,
    })!;

    return {
        .point = collide::to_world(pose, hit.point),
        .normal = collide::to_world_direction(pose, hit.normal),
        .fraction = hit.fraction,
    };
}

fn MeshPair? admit_mesh_pair(
    CollisionShapeState* first,
    maths::Transform pose_a,
    CollisionShapeState* second,
    maths::Transform pose_b,
) @local {
    if (first.mesh.data && second.mesh.data) return c3d::UNSUPPORTED~;
    check_collision_pair(
        first: first,
        pose_a: pose_a,
        second: second,
        pose_b: pose_b,
    )!;

    if (first.mesh.data) {
        return { .surface = first, .surface_pose = pose_a, .convex = second, .convex_pose = pose_b };
    }

    return { .surface = second, .surface_pose = pose_b, .convex = first, .convex_pose = pose_a, .convex_first = true };
}

fn bool collision_orientation_unchanged(Quat start, Quat end) @local => start.v == end.v || start.v == -end.v;

fn bool write_mesh_contacts(
    Vec3 first,
    Vec3 second,
    Vec3 third,
    int triangle_index,
    void* context,
) @local {
    MeshContactWriter* writer = context;
    if (writer.failure) return false;

    b3::Transform frame = writer.surface_in_convex;
    b3::Triangle triangle = {
        frame.q.rotate_vec3(first) + frame.p,
        frame.q.rotate_vec3(second) + frame.p,
        frame.q.rotate_vec3(third) + frame.p,
    };
    if (catch excuse = append_triangle_contacts(writer, &triangle, triangle_index)) {
        writer.failure = excuse;
        return false;
    }

    return true;
}

fn void? append_triangle_contacts(MeshContactWriter* writer, b3::Triangle* triangle, int triangle_index) @local {
    Vec3 normal;
    b3::LocalManifoldPoint[] points;
    b3::CollisionManifold manifold;
    switch (writer.shape.kind) {
        case SPHERE:
            manifold = b3::collide_triangle_and_sphere(triangle, { .radius = writer.shape.radius })
              ?? c3d::UNSUPPORTED~!;
            normal = manifold.normal;
            points = manifold.points[:(usz)manifold.point_count];
        case CAPSULE:
            manifold = b3::collide_triangle_and_capsule(triangle, collide::capsule_of(&writer.shape))
              ?? c3d::UNSUPPORTED~!;
            normal = manifold.normal;
            points = manifold.points[:(usz)manifold.point_count];
        case BOX:
        case HULL:
            b3::CollisionManifoldView view = b3::collide_triangle_and_hull(
                triangle: triangle,
                hull: writer.hull,
                enable_speculative: true,
                buffer: writer.scratch[..],
            ) ?? c3d::UNSUPPORTED~!;
            normal = view.normal;
            points = view.points;
    }
    if (writer.count + points.len > writer.output.len) return c3d::CAPACITY_EXCEEDED~;

    Vec3 direction = collide::to_world_direction(writer.convex_pose, normal);
    if (writer.convex_first) direction = -direction;
    check_collision_vector(direction)!;

    foreach (point : points) {
        Vec3 world = collide::to_world(writer.convex_pose, point.point);
        check_collision_vector(world)!;
        if (!math::is_finite(point.separation)) return c3d::UNSUPPORTED~;

        writer.output[writer.count++] = {
            .point = world,
            .normal = direction,
            .separation = point.separation,
            .triangle_index = (uint)triangle_index,
        };
    }
}

fn bool measure_mesh_triangle(
    Vec3 first,
    Vec3 second,
    Vec3 third,
    int triangle_index,
    void* context,
) @local {
    MeshDistanceSearch* search = context;
    Vec3[3] corners = { first, second, third };
    b3::DistanceOutput? found = b3::shape_distance({
        .proxy_a = { .points = &corners, .count = 3 },
        .proxy_b = search.proxy,
        .transform = search.convex_in_surface,
        .use_radii = true,
    });
    if (catch found) {
        search.failure = c3d::UNSUPPORTED;
        return false;
    }

    if (found.distance < search.nearest.distance) search.nearest = found;

    return found.distance > 0;
}
