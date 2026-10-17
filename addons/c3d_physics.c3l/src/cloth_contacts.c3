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
            if (collider.shape.type() == b3::ShapeType.SPHERE) {
                return cloth_sphere(shape, collider.shape.sphere()!);
            }
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
            double height = state.sweep_active ? state.sweep_bounds[index].min.y : position.y;
            if (height - state.desc.ground_height > reach) continue;
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
            maths::Aabb query = state.sweep_active
              ? cloth_swept_query_bounds(
                  state: state,
                  shape_index: (uint)shape_index,
                  particle: (uint)particle,
                  reach: reach,
              )!
              : contact_query_bounds(&state.frames[shape_index], position, reach)!;
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

fn b3::HullData*? cloth_contact_hull(PhysicsWorld* world, cloth::ClothState* state, ClothShape* shape) @local {
    RigidBody* body = world.scene.get(world.scene.node(state.bodies[shape.body].owner), RigidBody);
    if (!shape.compound_child) return body.colliders[shape.collider].shape.hull();
    b3::CompoundData* compound = cloth_snapshot(world, shape.snapshot)!.compound;
    return compound.child((int)shape.child)!.hull;
}

fn void? sample_cloth_external(
    PhysicsWorld* world,
    cloth::ClothState* state,
    ClothCandidate* candidate,
    ContactFrame* frame,
    ContactIntervals particle,
    ContactPairSample* sample,
) @private {
    sample.first_count = 1;
    sample.first[0] = sample.witness_first = particle;
    sample.vertices[0] = candidate.particle;
    sample.coefficients[0] = 1;
    ClothShape* shape = &state.shapes[candidate.shape];
    if (candidate.kind == TRIANGLE) {
        sample.second_count = 3;
        foreach (index, vertex : candidate.vertices) sample.second[index] = contact_point(frame, vertex)!;
        ContactVector weights = contact_triangle_weights(
            point: contact_middle(particle),
            first: contact_middle(sample.second[0]),
            second: contact_middle(sample.second[1]),
            third: contact_middle(sample.second[2]),
        );
        sample.witness_second = contact_triangle_witness(
            first: sample.second[0],
            second: sample.second[1],
            third: sample.second[2],
            weights: weights,
        )!;
        return;
    }

    if (shape.kind == SPHERE || shape.kind == CAPSULE) {
        sample.second_count = shape.kind == SPHERE ? 1 : 2;
        sample.second[0] = contact_point(frame, shape.start)!;
        sample.second[1] = contact_point(frame, shape.end)!;
        ContactVector first = contact_middle(sample.second[0]);
        ContactVector edge = contact_middle(sample.second[1]) - first;
        double squared = edge.dot(edge);
        double along = squared > 0 ? math::clamp((contact_middle(particle) - first).dot(edge) / squared, 0.0, 1.0) : 0;
        sample.witness_second = contact_vector_add(
            first: sample.second[0],
            second: contact_vector_scale(
                value: contact_vector_subtract(sample.second[1], sample.second[0])!,
                scale: contact_value(along),
            )!,
        )!;
        sample.radius = shape.radius;
        return;
    }

    b3::HullData* hull = cloth_contact_hull(world, state, shape)!;
    if (hull.vertex_count <= 0 || hull.vertex_count > (int)MAX_CONTACT_HULL_POINTS) return cloth::CONTACT_PRECISION_EXCEEDED~;
    Vec3* points = (Vec3*)((char*)hull + hull.point_offset);
    b3::HullHalfEdge* edges = (b3::HullHalfEdge*)((char*)hull + hull.edge_offset);
    b3::HullFace* faces = (b3::HullFace*)((char*)hull + hull.face_offset);
    sample.second_count = (uint)hull.vertex_count;
    for (uint index = 0; index < sample.second_count; index++) sample.second[index] = contact_point(frame, points[index])!;

    double best = double::max;
    for (int face = 0; face < hull.face_count; face++) {
        uint first_edge = faces[face].edge;
        uint first = edges[first_edge].origin;
        uint edge = edges[first_edge].next;
        uint second = edges[edge].origin;
        edge = edges[edge].next;
        while (edge != first_edge) {
            uint third = edges[edge].origin;
            ContactVector weights = contact_triangle_weights(
                point: contact_middle(particle),
                first: contact_middle(sample.second[first]),
                second: contact_middle(sample.second[second]),
                third: contact_middle(sample.second[third]),
            );
            ContactIntervals witness = contact_triangle_witness(
                first: sample.second[first],
                second: sample.second[second],
                third: sample.second[third],
                weights: weights,
            )!;
            double upper = contact_length(contact_vector_subtract(particle, witness)!)!.max;
            if (upper < best) {
                best = upper;
                sample.witness_second = witness;
            }
            second = third;
            edge = edges[edge].next;
        }
    }
    if (best == double::max) return cloth::CONTACT_PRECISION_EXCEEDED~;
}

fn double? cloth_local_support(
    PhysicsWorld* world,
    cloth::ClothState* state,
    ClothCandidate* candidate,
    ContactVector normal,
) @private {
    ClothShape* shape = &state.shapes[candidate.shape];
    ContactIntervals axis = contact_vector(normal);
    double support = -double::max;
    if (candidate.kind == TRIANGLE) {
        foreach (vertex : candidate.vertices) support = math::max(
            x: support,
            y: contact_dot(axis, contact_vector((ContactVector)vertex))!.max
        );
        return support;
    }
    if (shape.kind == SPHERE || shape.kind == CAPSULE) {
        support = math::max(
            x: contact_dot(axis, contact_vector((ContactVector)shape.start))!.max,
            y: contact_dot(axis, contact_vector((ContactVector)shape.end))!.max
        );
        return contact_add(
            first: contact_value(support),
            second: contact_multiply(contact_length(axis)!, contact_value(shape.radius))!,
        )!.max;
    }
    b3::HullData* hull = cloth_contact_hull(world, state, shape)!;
    Vec3* points = (Vec3*)((char*)hull + hull.point_offset);
    for (int index = 0; index < hull.vertex_count; index++) {
        support = math::max(support, contact_dot(axis, contact_vector((ContactVector)points[index]))!.max);
    }
    return support;
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

fn maths::Aabb? cloth_swept_query_bounds(
    ClothState* state,
    uint shape_index,
    uint particle,
    double reach,
) @local {
    ClothShape* shape = &state.shapes[shape_index];
    ContactMotion* motion = &state.body_motions[shape.body];
    ContactFrame frame = contact_motion_leaf(motion, shape.local, { .min = state.sweep_begin, .max = state.sweep_end })!;
    ContactIntervals point;
    for (uint axis = 0; axis < 3; axis++) {
        point[axis] = { .min = state.sweep_bounds[particle].min[axis], .max = state.sweep_bounds[particle].max[axis] };
    }

    ContactIntervals relative = contact_vector_subtract(point, frame.position)!;
    ContactIntervals local;
    if (motion.constant_rotation || state.sweep_begin == state.sweep_end) {
        local = contact_inverse_rotate(&frame, relative)!;
    } else {
        double radius = contact_length(relative)!.max;
        for (uint axis = 0; axis < 3; axis++) local[axis] = { .min = -radius, .max = radius };
    }

    maths::Aabb result;
    for (uint axis = 0; axis < 3; axis++) {
        result.min[axis] = contact_float_bound(contact_subtract(local[axis], contact_value(reach))!.min, false)!;
        result.max[axis] = contact_float_bound(contact_add(local[axis], contact_value(reach))!.max, true)!;
    }
    return result;
}

fn void reset_cloth_body_contact_history(Scene* scene, Entity owner) @private {
    scene.@each(cloth::Cloth; entity, component) {
        if (component.state) {
            foreach (&body : component.state.bodies) {
                if (c3d::same_id(body.owner, owner)) body.observed = body.published_observed = false;
            }
        }
    };
    if (scene.world.is_registered(cloth::CrowdCloth)) {
        scene.@each(cloth::CrowdCloth; entity, crowd_cloth) {
            if (crowd_cloth.state) {
                foreach (&part_rec : crowd_cloth.state.parts) {
                    if (!part_rec.prepared) continue;
                    foreach (state : part_rec.states) {
                        if (!state) continue;
                        foreach (&body : state.bodies) {
                            if (c3d::same_id(body.owner, owner)) body.observed = body.published_observed = false;
                        }
                    }
                }
            }
        };
    }
}
