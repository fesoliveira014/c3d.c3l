module c3d::physics;

import std::math;
import c3d;
import c3d::scene;
import b3;

const usz MAX_OVERLAP_SHAPES @local = 256; // 3 KiB of stack per query; the overlap result lever

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
    foreach (index, body : bodies[:body_count]) nodes[index] = self.scene.node(unpack_entity(body.user_data()));
    return nodes;
}

fn b3::QueryFilter query_filter(CollisionFilter filter) @local {
    b3::QueryFilter query = b3::default_query_filter();
    query.category_bits = filter.category;
    query.mask_bits = filter.mask;
    return query;
}
