module c3d::physics;

import std::math;
import c3d;
import c3d::scene;
import b3;

const usz MAX_OVERLAP_SHAPES @local = 256; // 3 KiB of stack per query; the overlap result lever
const usz MAX_CAST_HITS @local = 128;      // 7 KiB of stack per cast; results past it are dropped
const usz MAX_BODY_CONTACTS @local = 64;   // 3 KiB of stack per body; contacts past it are dropped

<*
 One shape a cast primitive touches.
*>
struct ShapeCastHit {
    Node*             node;
    Vec3              point;
    Vec3              normal;
    float             fraction;
    SurfaceMaterialId surface;
}

<*
 Point where the node's body touches another, in world space.
*>
struct ContactPoint {
    Node* other;
    Vec3  point;
    Vec3  normal;          // from the node's shape toward other
    float separation;      // negative when overlapping; box3d keeps speculative points
    float normal_impulse;
}

<*
 Closest body along the ray, as its node.
 @param direction : "Unit length."
 @return? b3::NO_HIT
*>
fn RayHit? PhysicsWorld.raycast(
    &self,
    Vec3 origin,
    Vec3 direction,
    float max_distance,
    CollisionFilter filter = FILTER_ALL,
) {
    b3::RayResult result = b3::world_cast_ray_closest(
        self.world,
        (b3::Pos)origin,
        direction * max_distance,
        query_filter(filter),
    )!;
    return {
        .node     = node_of(self, result.shape_id)!!,
        .point    = result.point,
        .normal   = result.normal,
        .fraction = result.fraction,
        .surface  = (SurfaceMaterialId)result.user_material_id,
    };
}

<*
 Nodes whose shapes overlap the sphere, each once, in the caller's allocator.
*>
fn Node*[] PhysicsWorld.overlap_sphere(
    &self,
    Allocator allocator,
    Vec3 center,
    float radius,
    CollisionFilter filter = FILTER_ALL,
) {
    Vec3 origin_point;
    b3::ShapeProxy proxy = { .points = &origin_point, .count = 1, .radius = radius };
    b3::ShapeId[MAX_OVERLAP_SHAPES] shape_buffer;
    b3::ShapeId[] shapes = b3::world_overlap_shape_all(
        world:  self.world,
        origin: (b3::Pos)center,
        proxy:  &proxy,
        filter: query_filter(filter),
        buffer: shape_buffer[..],
    );

    return nodes_of_shapes(self, allocator, shapes);
}

<*
 Nodes with a shape whose bounds overlap the box, each once, in the caller's allocator.
*>
fn Node*[] PhysicsWorld.overlap_aabb(
    &self,
    Allocator allocator,
    maths::Aabb bounds,
    CollisionFilter filter = FILTER_ALL,
) {
    b3::ShapeId[MAX_OVERLAP_SHAPES] shape_buffer;
    b3::ShapeId[] shapes = b3::world_overlap_aabb_all(
        world:  self.world,
        aabb:   { .lower_bound = bounds.min, .upper_bound = bounds.max },
        filter: query_filter(filter),
        buffer: shape_buffer[..],
    );
    return nodes_of_shapes(self, allocator, shapes);
}

<*
 Shapes a moving primitive would touch, nearest first, in the caller's allocator.
 @param shape : "SPHERE, CAPSULE or BOX; local is its start pose, unit scale."
 @require shape.kind == SPHERE || shape.kind == CAPSULE || shape.kind == BOX
*>
fn ShapeCastHit[] PhysicsWorld.cast_shape(
    &self,
    Allocator allocator,
    ColliderDesc shape,
    Vec3 translation,
    CollisionFilter filter = FILTER_ALL,
) {
    Vec3[8] points;
    b3::ShapeProxy proxy = cast_proxy(&shape, &points);
    b3::CastHit[MAX_CAST_HITS] hit_buffer;
    b3::CastHit[] hits = b3::world_cast_shape_all(
        world:       self.world,
        origin:      (b3::Pos)shape.local.position,
        proxy:       &proxy,
        translation: translation,
        filter:      query_filter(filter),
        buffer:      hit_buffer[..],
    );
    for (usz index = 1; index < hits.len; index++) {
        b3::CastHit hit = hits[index];
        usz slot = index;
        for (; slot > 0 && hits[slot - 1].fraction > hit.fraction; slot--) hits[slot] = hits[slot - 1];
        hits[slot] = hit;
    }

    ShapeCastHit[] result = alloc::new_array(allocator, ShapeCastHit, (sz)hits.len);
    foreach (index, hit : hits) {
        result[index] = {
            .node     = node_of(self, hit.shape_id)!!,
            .point    = hit.point,
            .normal   = hit.normal,
            .fraction = hit.fraction,
            .surface  = (SurfaceMaterialId)hit.user_material_id,
        };
    }
    return result;
}

<*
 Touching points of the node's body from the last step, in the caller's allocator.
 @require self.scene.has(node, RigidBody)
*>
fn ContactPoint[] PhysicsWorld.contact_points(&self, Allocator allocator, Node* node) {
    b3::BodyId body = self.scene.get(node, RigidBody).body;
    b3::ContactData[MAX_BODY_CONTACTS] contact_buffer;
    b3::ContactData[] contacts = body.contact_data(contact_buffer[..]);

    usz count;
    foreach (&contact : contacts) {
        foreach (&manifold : contact.contact_manifolds()) count += (usz)manifold.point_count;
    }
    ContactPoint[] points = alloc::new_array(allocator, ContactPoint, (sz)count);
    usz cursor;
    foreach (&contact : contacts) {
        b3::BodyId body_a = contact.shape_id_a.body();
        bool node_is_a = body_a.index1 == body.index1 && body_a.generation == body.generation;
        Node* other = node_of(self, node_is_a ? contact.shape_id_b : contact.shape_id_a)!!;
        Vec3 center_a = body_a.world_center();
        foreach (&manifold : contact.contact_manifolds()) {
            Vec3 normal = node_is_a ? manifold.normal : -manifold.normal;
            foreach (&manifold_point : manifold.contact_points()) {
                points[cursor++] = {
                    .other          = other,
                    .point          = center_a + manifold_point.anchor_a,
                    .normal         = normal,
                    .separation     = manifold_point.separation,
                    .normal_impulse = manifold_point.normal_impulse,
                };
            }
        }
    }
    return points;
}

fn Node*[] nodes_of_shapes(PhysicsWorld* world, Allocator allocator, b3::ShapeId[] shapes) @local {
    b3::BodyId[MAX_OVERLAP_SHAPES] bodies;
    usz body_count;
    foreach (shape : shapes) {
        b3::BodyId body = shape.body();
        bool seen;
        foreach (known : bodies[:body_count]) {
            if (known.index1 == body.index1 && known.generation == body.generation) seen = true;
        }
        if (!seen) bodies[body_count++] = body;
    }

    Node*[] nodes = alloc::new_array(allocator, Node*, (sz)body_count);
    foreach (index, body : bodies[:body_count]) nodes[index] = world.scene.node(unpack_entity(body.user_data()));
    return nodes;
}

fn b3::ShapeProxy cast_proxy(ColliderDesc* shape, Vec3[8]* points) @local {
    switch (shape.kind) {
        case CAPSULE:
            b3::Capsule capsule = capsule_of(shape.local, shape.half_height, shape.radius);
            (*points)[0] = capsule.center1 - shape.local.position;
            (*points)[1] = capsule.center2 - shape.local.position;
            return { .points = &(*points)[0], .count = 2, .radius = shape.radius };
        case BOX:
            for (uint corner = 0; corner < 8; corner++) {
                Vec3 sign = { corner & 1 ? 1 : -1, corner & 2 ? 1 : -1, corner & 4 ? 1 : -1 };
                (*points)[corner] = shape.local.rotation.rotate_vec3(shape.half_extents * sign);
            }
            return { .points = &(*points)[0], .count = 8, .radius = 0 };
        default:
            (*points)[0] = {};
            return { .points = &(*points)[0], .count = 1, .radius = shape.radius };
    }
}

fn b3::QueryFilter query_filter(CollisionFilter filter) @private {
    b3::QueryFilter query = b3::default_query_filter();
    query.category_bits = filter.category;
    query.mask_bits = filter.mask;
    return query;
}
