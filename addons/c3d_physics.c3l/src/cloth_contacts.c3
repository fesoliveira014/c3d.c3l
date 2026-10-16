module c3d::physics;

import c3d;
import c3d::maths;
import c3d::physics::cloth;
import c3d::scene;
import std::math;
import b3;

const b3::Transform CLOTH_IDENTITY @local = { .q = { .v = { 0, 0, 0, 1 } } };
const uint CLOTH_HULL_TRIANGLES @local = 2 * b3::MAX_HULL_VERTICES;
const double NATIVE_BOUND_ERROR @local = 0.000003814697265625; // 32 binary32 epsilons
const double NATIVE_BOUND_UNDERFLOW @local = 4.4841550858394146269559346665277e-44; // 32 minimum binary32 subnormals
const float MAX_ENUMERATION_EXTENT @local = 1099511627776; // 2^40 keeps the native SAT products finite

$assert b3::MAX_HULL_VERTICES == MAX_CONTACT_HULL_POINTS;

struct ClothTriangleWriter @local {
    ClothCandidate[] candidates;
    usz* count;
    uint particle;
    uint shape;
    fault failure;
    Vec3 scale;
    maths::Aabb query;
}

fn uint[4] cloth_body_identity(RigidBody* body) @private {
    b3::WorldId world = body.body.world();
    return { world.index1, world.generation, (uint)body.body.index1, body.body.generation };
}

fn bool cloth_body_live(RigidBody* body) @private => body != null && body.body.is_valid();

fn CollisionSnapshot*? cloth_snapshot(PhysicsWorld* world, SnapshotHandle handle) @local {
    if (!handle.generation || handle.index >= world.snapshots.slots.len) return SOURCE_UNAVAILABLE~;
    CollisionSnapshot* snapshot = &world.snapshots.slots[handle.index];
    if (snapshot.generation != handle.generation || !snapshot.holders) return SOURCE_UNAVAILABLE~;
    return snapshot;
}

fn void? cloth_bounds(cloth::ClothShape* shape, b3::Aabb bounds) @local {
    if (!contact_finite(bounds.lower_bound) || !contact_finite(bounds.upper_bound)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    for (uint axis = 0; axis < 3; axis++) {
        if (bounds.lower_bound[axis] > bounds.upper_bound[axis]) return c3d::INVALID_ARGUMENT~;
    }
    for (uint axis = 0; axis < 3; axis++) {
        double magnitude = math::max(math::abs((double)bounds.lower_bound[axis]), math::abs((double)bounds.upper_bound[axis]));
        ContactInterval padding = contact_add(contact_multiply(contact_value(magnitude), contact_value(NATIVE_BOUND_ERROR))!, contact_value(NATIVE_BOUND_UNDERFLOW))!;
        shape.bounds.min[axis] = contact_float_bound(contact_subtract(contact_value(bounds.lower_bound[axis]), padding)!.min, false)!;
        shape.bounds.max[axis] = contact_float_bound(contact_add(contact_value(bounds.upper_bound[axis]), padding)!.max, true)!;
    }
}

fn void? cloth_sphere(cloth::ClothShape* shape, b3::Sphere sphere) @local {
    if (!math::is_finite(sphere.radius) || sphere.radius < 0 || !contact_finite(sphere.center)) return c3d::INVALID_ARGUMENT~;
    shape.kind = SPHERE;
    shape.start = shape.end = sphere.center;
    shape.radius = sphere.radius;
    return cloth_bounds(shape, sphere.compute_aabb(CLOTH_IDENTITY));
}

fn void? cloth_capsule(cloth::ClothShape* shape, b3::Capsule capsule) @local {
    if (!math::is_finite(capsule.radius) || capsule.radius < 0
        || !contact_finite(capsule.center1) || !contact_finite(capsule.center2)) return c3d::INVALID_ARGUMENT~;
    shape.kind = CAPSULE;
    shape.start = capsule.center1;
    shape.end = capsule.center2;
    shape.radius = capsule.radius;
    return cloth_bounds(shape, capsule.compute_aabb(CLOTH_IDENTITY));
}

fn void? cloth_mesh_scale(Vec3 scale) @local {
    if (!contact_finite(scale) || scale.x == 0 || scale.y == 0 || scale.z == 0) return c3d::INVALID_ARGUMENT~;
}

fn void? cloth_shape_geometry(Collider* collider, cloth::ClothShape* shape) @local {
    switch (collider.kind) {
        case SPHERE:
            return cloth_sphere(shape, collider.shape.sphere()!);
        case CAPSULE:
            return cloth_capsule(shape, collider.shape.capsule()!);
        case BOX:
        case HULL:
            b3::HullData* hull = collider.shape.hull()!;
            return cloth_bounds(shape, hull.compute_aabb(CLOTH_IDENTITY));
        case MESH:
            b3::Mesh mesh = collider.shape.mesh()!;
            cloth_mesh_scale(mesh.scale)!;
            return cloth_bounds(shape, mesh.data.compute_aabb(CLOTH_IDENTITY, mesh.scale));
        case HEIGHT_FIELD:
            Vec3 scale = collider.local.scale;
            if (!contact_finite(scale) || scale.x <= 0 || scale.y <= 0 || scale.z <= 0) return c3d::INVALID_ARGUMENT~;
            return cloth_bounds(shape, collider.shape.height_field()!.compute_aabb(CLOTH_IDENTITY));
        case COMPOUND:
            return;
    }
}

fn void? cloth_child_geometry(b3::ChildShape child, cloth::ClothShape* shape) @local {
    shape.local = { .position = child.transform.p, .rotation = child.transform.q, .scale = { 1, 1, 1 } };
    switch (child.type) {
        case SPHERE:
            return cloth_sphere(shape, child.sphere);
        case CAPSULE:
            return cloth_capsule(shape, child.capsule);
        case HULL:
            shape.kind = HULL;
            return cloth_bounds(shape, child.hull.compute_aabb(CLOTH_IDENTITY));
        case MESH:
            shape.kind = MESH;
            cloth_mesh_scale(child.mesh.scale)!;
            return cloth_bounds(shape, child.mesh.data.compute_aabb(CLOTH_IDENTITY, child.mesh.scale));
        case COMPOUND:
        case HEIGHT_FIELD:
            return c3d::UNSUPPORTED~;
    }
}

fn usz? capture_cloth_shapes(
    PhysicsWorld* world,
    RigidBody* body,
    uint body_index,
    cloth::ClothShape[] output,
) @private {
    usz count;
    foreach (index, &collider : body.colliders) {
        if (!collider.shape.is_valid()) return NO_BODY~;
        if (world && collider.snapshot.generation) (void)cloth_snapshot(world, collider.snapshot)!;
        cloth::ClothShape shape = {
            .body = body_index,
            .kind = collider.kind,
            .collider = (uint)index,
            .native_identity = { (uint)collider.shape.index1, collider.shape.world0, collider.shape.generation },
            .snapshot = collider.snapshot,
            .local = maths::TRANSFORM_IDENTITY,
        };
        if (collider.kind == COMPOUND && world) {
            b3::CompoundData* compound = cloth_snapshot(world, collider.snapshot)!.compound;
            for (int child = 0; child < compound.child_count(); child++) {
                if (count == output.len) return c3d::CAPACITY_EXCEEDED~;
                cloth::ClothShape leaf = shape;
                leaf.compound_child = true;
                leaf.child = (uint)child;
                cloth_child_geometry(compound.child(child)!, &leaf)!;
                output[count++] = leaf;
            }
        } else {
            if (count == output.len) return c3d::CAPACITY_EXCEEDED~;
            cloth_shape_geometry(collider, &shape)!;
            output[count++] = shape;
        }
    }
    return count;
}

fn bool cloth_bounds_overlap(maths::Aabb first, maths::Aabb second) @local {
    for (uint axis = 0; axis < 3; axis++) {
        if (first.max[axis] < second.min[axis] || first.min[axis] > second.max[axis]) return false;
    }
    return true;
}

fn bool write_cloth_triangle(
    Vec3 first,
    Vec3 second,
    Vec3 third,
    int triangle_index,
    void* context,
) @local {
    ClothTriangleWriter* writer = context;
    if (writer.failure) return false;
    if (!contact_finite(first) || !contact_finite(second) || !contact_finite(third)) {
        writer.failure = cloth::CONTACT_PRECISION_EXCEEDED;
        return false;
    }
    first *= writer.scale;
    second *= writer.scale;
    third *= writer.scale;
    if (!contact_finite(first) || !contact_finite(second) || !contact_finite(third)) {
        writer.failure = cloth::CONTACT_PRECISION_EXCEEDED;
        return false;
    }
    maths::Aabb triangle = { .min = math::min(first, math::min(second, third)), .max = math::max(first, math::max(second, third)) };
    if (!cloth_bounds_overlap(writer.query, triangle)) return true;
    if (*writer.count == writer.candidates.len) {
        writer.failure = c3d::CAPACITY_EXCEEDED;
        return false;
    }
    writer.candidates[(*writer.count)++] = {
        .particle = writer.particle,
        .shape = writer.shape,
        .triangle_index = triangle_index,
        .kind = ClothCandidateKind.TRIANGLE,
        .vertices = { first, second, third },
    };
    return true;
}

fn b3::Aabb? cloth_mesh_enumeration_bounds(b3::Mesh mesh) @local {
    cloth::ClothShape unscaled;
    cloth_bounds(&unscaled, mesh.data.compute_aabb(CLOTH_IDENTITY, { 1, 1, 1 }))!;
    double largest;
    for (uint axis = 0; axis < 3; axis++) {
        largest = math::max(largest, math::max(math::abs((double)unscaled.bounds.min[axis]), math::abs((double)unscaled.bounds.max[axis])));
    }
    float extent = 1;
    while ((double)extent < largest * 16) {
        if (extent == MAX_ENUMERATION_EXTENT) return cloth::CONTACT_PRECISION_EXCEEDED~;
        extent *= 2;
    }
    return { .lower_bound = { -extent, -extent, -extent }, .upper_bound = { extent, extent, extent } };
}

fn b3::Aabb? cloth_field_query_bounds(maths::Aabb query, maths::Aabb bounds, Vec3 scale) @local {
    double height_bound = math::max(math::abs((double)bounds.min.y), math::abs((double)bounds.max.y)) / scale.y;
    if (!math::is_finite(height_bound) || height_bound > (double)float::max / 4) return cloth::CONTACT_PRECISION_EXCEEDED~;
    b3::Aabb result = { .lower_bound = query.min, .upper_bound = query.max };
    for (uint axis = 0; axis < 3; axis += 2) {
        double magnitude = math::max(math::abs((double)query.min[axis]), math::abs((double)query.max[axis]));
        ContactInterval padding = contact_add(
            contact_add(contact_multiply(contact_value(magnitude), contact_value(NATIVE_BOUND_ERROR))!, contact_value(NATIVE_BOUND_UNDERFLOW))!,
            contact_multiply(contact_value(scale[axis]), contact_value(2))!,
        )!;
        result.lower_bound[axis] = math::max(0.0f, contact_float_bound(contact_subtract(contact_value(query.min[axis]), padding)!.min, false)!);
        result.upper_bound[axis] = math::min(bounds.max[axis], contact_float_bound(contact_add(contact_value(query.max[axis]), padding)!.max, true)!);
        float first = result.lower_bound[axis] / scale[axis];
        float last = result.upper_bound[axis] / scale[axis];
        if (!math::is_finite(first) || !math::is_finite(last) || first < 0 || (double)last >= int::max) {
            return cloth::CONTACT_PRECISION_EXCEEDED~;
        }
    }
    return result;
}

fn usz? gather_cloth_candidates(PhysicsWorld* world, cloth::ClothState* state, Vec3[] positions) @private {
    usz count;
    defer {
        state.contact_result.candidates += (uint)count;
        state.contact_result.peak_candidates = math::max(state.contact_result.peak_candidates, (uint)count);
    }
    double reach = (double)state.desc.thickness + state.desc.collisions.contact_tolerance;
    foreach (position : positions) {
        if (!contact_finite(position)) return cloth::CONTACT_PRECISION_EXCEEDED~;
    }
    if (state.desc.collide_ground) {
        foreach (index, position : positions) {
            if ((double)position.y - state.desc.ground_height > reach) continue;
            if (count == state.candidates.len) return c3d::CAPACITY_EXCEEDED~;
            state.candidates[count++] = { .particle = (uint)index, .kind = ClothCandidateKind.GROUND };
        }
    }

    foreach (shape_index, &shape : state.shapes) {
        if (!state.bodies[shape.body].live) continue;
        RigidBody* body = world.scene.get(world.scene.node(state.bodies[shape.body].owner), RigidBody);
        Collider* collider = &body.colliders[shape.collider];
        b3::Mesh mesh;
        b3::HeightFieldData* height_field;
        b3::Aabb mesh_enumeration;
        bool mesh_enumeration_ready;
        if (shape.kind == MESH) {
            if (shape.compound_child) {
                b3::CompoundData* compound = cloth_snapshot(world, shape.snapshot)!.compound;
                mesh = compound.child((int)shape.child)!.mesh;
            } else {
                mesh = collider.shape.mesh()!;
            }
        }
        if (shape.kind == HEIGHT_FIELD) height_field = collider.shape.height_field()!;
        foreach (particle, position : positions) {
            maths::Aabb query = contact_query_bounds(&state.frames[shape_index], position, reach)!;
            if (!cloth_bounds_overlap(query, shape.bounds)) continue;
            switch (shape.kind) {
                case SPHERE:
                case CAPSULE:
                case BOX:
                case HULL:
                    if (count == state.candidates.len) return c3d::CAPACITY_EXCEEDED~;
                    state.candidates[count++] = {
                        .particle = (uint)particle,
                        .shape = (uint)shape_index,
                        .kind = ClothCandidateKind.SHAPE,
                    };
                case MESH:
                case HEIGHT_FIELD:
                    ClothTriangleWriter writer = {
                        .candidates = state.candidates,
                        .count = &count,
                        .particle = (uint)particle,
                        .shape = (uint)shape_index,
                        .scale = shape.kind == MESH ? mesh.scale : (Vec3){ 1, 1, 1 },
                        .query = query,
                    };
                    // A field query cannot stop early and does not clamp its cell range.
                    maths::Aabb clipped = { .min = math::max(query.min, shape.bounds.min), .max = math::min(query.max, shape.bounds.max) };
                    if (shape.kind == MESH) {
                        if (!mesh_enumeration_ready) {
                            mesh_enumeration = cloth_mesh_enumeration_bounds(mesh)!;
                            mesh_enumeration_ready = true;
                        }
                        b3::Mesh unscaled = { .data = mesh.data, .scale = { 1, 1, 1 } };
                        b3::query_mesh(mesh: &unscaled, bounds: mesh_enumeration, fcn: &write_cloth_triangle, context: &writer);
                    } else {
                        b3::Aabb native_bounds = cloth_field_query_bounds(clipped, shape.bounds, collider.local.scale)!;
                        b3::query_height_field(height_field: height_field, bounds: native_bounds, fcn: &write_cloth_triangle, context: &writer);
                    }
                    if (writer.failure) return writer.failure~;
                case COMPOUND:
                    return c3d::UNSUPPORTED~;
            }
        }
    }
    return count;
}

fn ContactProjection? project_cloth_convex(
    PhysicsWorld* world,
    cloth::ClothState* state,
    ClothCandidate* candidate,
    Vec3 position,
    bool correct,
) @private {
    cloth::ClothShape* shape = &state.shapes[candidate.shape];
    RigidBody* body = world.scene.get(world.scene.node(state.bodies[shape.body].owner), RigidBody);
    b3::HullData* hull;
    if (shape.compound_child) {
        b3::CompoundData* compound = cloth_snapshot(world, shape.snapshot)!.compound;
        hull = compound.child((int)shape.child)!.hull;
    } else {
        hull = body.colliders[shape.collider].shape.hull()!;
    }
    Vec3* points = (Vec3*)((char*)hull + hull.point_offset);
    b3::HullHalfEdge* edges = (b3::HullHalfEdge*)((char*)hull + hull.edge_offset);
    b3::HullFace* faces = (b3::HullFace*)((char*)hull + hull.face_offset);
    b3::Plane* planes = (b3::Plane*)((char*)hull + hull.plane_offset);
    uint[3 * CLOTH_HULL_TRIANGLES] triangles;
    Vec3[CLOTH_HULL_TRIANGLES] normals;
    usz count;
    for (int face = 0; face < hull.face_count; face++) {
        uint first_edge = faces[face].edge;
        uint first = edges[first_edge].origin;
        uint edge = edges[first_edge].next;
        uint second = edges[edge].origin;
        edge = edges[edge].next;
        while (edge != first_edge) {
            if (count == normals.len) return c3d::CAPACITY_EXCEEDED~;
            uint third = edges[edge].origin;
            triangles[3 * count] = first;
            triangles[3 * count + 1] = second;
            triangles[3 * count + 2] = third;
            normals[count++] = planes[face].normal;
            second = third;
            edge = edges[edge].next;
        }
    }
    return contact_convex(
        frame: &state.frames[candidate.shape],
        vertices: points[:hull.vertex_count],
        triangles: triangles[:3 * count],
        normals: normals[:count],
        position: position,
        thickness: state.desc.thickness,
        tolerance: state.desc.collisions.contact_tolerance,
        correct: correct,
    );
}
