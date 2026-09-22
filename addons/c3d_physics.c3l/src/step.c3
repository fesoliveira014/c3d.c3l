module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import b3;

<*
 Advance the simulation by dt in fixed steps and write dynamic poses to their nodes.
 Event node pointers are valid until the scene flushes removals.
*>
fn void PhysicsWorld.update(&self, float dt) {
    self.contact_begin_count = 0;
    self.contact_end_count = 0;
    self.hit_count = 0;
    self.sensor_begin_count = 0;
    self.sensor_end_count = 0;
    self.dropped_events = 0;

    float fixed_dt = self.desc.fixed_dt;
    self.accumulator += dt;
    uint steps;
    while (self.accumulator >= fixed_dt && steps < self.desc.max_steps_per_frame) {
        begin_step(self, fixed_dt);
        b3::world_step(self.world, fixed_dt, (int)self.desc.sub_steps);
        end_step(self);
        self.accumulator -= fixed_dt;
        steps++;
    }
    if (self.accumulator >= fixed_dt) self.accumulator -= math::floor(self.accumulator / fixed_dt) * fixed_dt;
    self.alpha = self.accumulator / fixed_dt;
    self.steps_last_update = steps;

    float alpha = self.desc.interpolate ? self.alpha : 1;
    self.scene.@each(RigidBody; entity, body) {
        if (body.kind == DYNAMIC) {
            write_pose(self.scene, self.scene.node(entity), interpolate_pose(body.previous, body.current, alpha));
        }
    };
}

<*
 Pose between two body poses; rotation by normalized lerp.
*>
fn maths::Transform interpolate_pose(maths::Transform previous, maths::Transform current, float alpha) {
    return {
        .position = previous.position + (current.position - previous.position) * alpha,
        .rotation = previous.rotation.nlerp(current.rotation, alpha),
        .scale    = current.scale,
    };
}

fn void begin_step(PhysicsWorld* world, float fixed_dt) @local {
    world.scene.@each(RigidBody; entity, body) {
        body.previous = body.current;
        if (body.kind == KINEMATIC) {
            maths::Transform target = maths::transform_from_mat4(world.scene.node(entity).world);
            body.body.set_target_transform({ .p = (b3::Pos)target.position, .q = target.rotation }, fixed_dt, true);
        }
    };
}

fn void end_step(PhysicsWorld* world) @local {
    foreach (event : world.world.body_move_events()) {
        Node* node = world.scene.node(unpack_entity(event.user_data));
        RigidBody* body = world.scene.get(node, RigidBody);
        body.current = { .position = event.transform.p, .rotation = event.transform.q, .scale = { 1, 1, 1 } };
    }
    foreach (event : world.world.contact_begin_touch_events()) {
        push_contact(
            world:   world,
            storage: world.contact_begin_storage,
            count:   &world.contact_begin_count,
            shape_a: event.shape_id_a,
            shape_b: event.shape_id_b,
        );
    }
    foreach (event : world.world.contact_end_touch_events()) {
        push_contact(
            world:   world,
            storage: world.contact_end_storage,
            count:   &world.contact_end_count,
            shape_a: event.shape_id_a,
            shape_b: event.shape_id_b,
        );
    }
    foreach (event : world.world.contact_hit_events()) {
        push_hit(world, event);
    }
    foreach (event : world.world.sensor_begin_touch_events()) {
        push_sensor(
            world:   world,
            storage: world.sensor_begin_storage,
            count:   &world.sensor_begin_count,
            sensor:  event.sensor_shape_id,
            visitor: event.visitor_shape_id,
        );
    }
    foreach (event : world.world.sensor_end_touch_events()) {
        push_sensor(
            world:   world,
            storage: world.sensor_end_storage,
            count:   &world.sensor_end_count,
            sensor:  event.sensor_shape_id,
            visitor: event.visitor_shape_id,
        );
    }
}

fn void push_contact(
    PhysicsWorld* world,
    ContactEvent[] storage,
    uint* count,
    b3::ShapeId shape_a,
    b3::ShapeId shape_b,
) @local {
    Node*? node_a = node_of(world, shape_a);
    Node*? node_b = node_of(world, shape_b);
    if (catch node_a) return;
    if (catch node_b) return;
    if (*count == storage.len) {
        world.dropped_events++;
        return;
    }
    storage[(*count)++] = { .a = node_a, .b = node_b };
}

fn void push_hit(PhysicsWorld* world, b3::ContactHitEvent event) @local {
    Node*? node_a = node_of(world, event.shape_id_a);
    Node*? node_b = node_of(world, event.shape_id_b);
    if (catch node_a) return;
    if (catch node_b) return;
    if (world.hit_count == world.hit_storage.len) {
        world.dropped_events++;
        return;
    }
    world.hit_storage[world.hit_count++] = {
        .a              = node_a,
        .b              = node_b,
        .point          = event.point,
        .normal         = event.normal,
        .approach_speed = event.approach_speed,
    };
}

fn void push_sensor(
    PhysicsWorld* world,
    SensorEvent[] storage,
    uint* count,
    b3::ShapeId sensor,
    b3::ShapeId visitor,
) @local {
    Node*? sensor_node = node_of(world, sensor);
    Node*? visitor_node = node_of(world, visitor);
    if (catch sensor_node) return;
    if (catch visitor_node) return;
    if (*count == storage.len) {
        world.dropped_events++;
        return;
    }
    storage[(*count)++] = { .sensor = sensor_node, .visitor = visitor_node };
}

fn Node*? node_of(PhysicsWorld* world, b3::ShapeId shape) @private {
    if (!shape.is_valid()) return NO_BODY~;
    return world.scene.node(unpack_entity(shape.body().user_data()));
}

fn void write_pose(Scene* scene, Node* node, maths::Transform pose) @private {
    if (node.parent == scene.root) {
        node.local.position = pose.position;
        node.local.rotation = pose.rotation;
        return;
    }
    Mat4 parent_inverse = maths::inverse_affine(node.parent.world);
    Quat parent_rotation = maths::transform_from_mat4(node.parent.world).rotation;
    node.local.position = maths::transform_point(parent_inverse, pose.position);
    node.local.rotation = parent_rotation.conjugate().mul(pose.rotation).normalize();
}
