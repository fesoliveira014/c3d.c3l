module c3d::physics;

import c3d;
import c3d::scene;
import b3;

<*
 Milliseconds of the last fixed step by phase; box3d's profile.
*>
struct PhysicsProfile {
    float step;
    float pairs;
    float collide;
    float solve;
    float solver_setup;
    float constraints;
    float prepare_constraints;
    float integrate_velocities;
    float warm_start;
    float solve_impulses;
    float integrate_positions;
    float relax_impulses;
    float apply_restitution;
    float store_impulses;
    float split_islands;
    float transforms;
    float sensor_hits;
    float joint_events;
    float hit_events;
    float refit;
    float bullets;
    float sleep_islands;
    float sensors;
}

<*
 World occupancy.
*>
struct PhysicsCounters {
    uint bodies;
    uint awake_bodies;
    uint shapes;
    uint contacts;
    uint awake_contacts;
    uint joints;
    uint islands;
    uint tree_height;
    uint static_tree_height;
    uint bytes;
    uint occupied_snapshots;
    uint snapshot_capacity;
}

<*
 Live motion of one body.
*>
struct BodyState {
    bool  awake;
    float mass;
    Vec3  center_of_mass;   // world space
    Vec3  linear_velocity;
    Vec3  angular_velocity;
}

<*
 Phase timings of the last fixed step; several steps in one update report the last.
*>
fn PhysicsProfile PhysicsWorld.profile(&self) {
    b3::Profile profile = self.world.profile();
    return {
        .step                 = profile.step,
        .pairs                = profile.pairs,
        .collide              = profile.collide,
        .solve                = profile.solve,
        .solver_setup         = profile.solver_setup,
        .constraints          = profile.constraints,
        .prepare_constraints  = profile.prepare_constraints,
        .integrate_velocities = profile.integrate_velocities,
        .warm_start           = profile.warm_start,
        .solve_impulses       = profile.solve_impulses,
        .integrate_positions  = profile.integrate_positions,
        .relax_impulses       = profile.relax_impulses,
        .apply_restitution    = profile.apply_restitution,
        .store_impulses       = profile.store_impulses,
        .split_islands        = profile.split_islands,
        .transforms           = profile.transforms,
        .sensor_hits          = profile.sensor_hits,
        .joint_events         = profile.joint_events,
        .hit_events           = profile.hit_events,
        .refit                = profile.refit,
        .bullets              = profile.bullets,
        .sleep_islands        = profile.sleep_islands,
        .sensors              = profile.sensors,
    };
}

<*
 Occupancy of the world and its snapshot table.
*>
fn PhysicsCounters PhysicsWorld.counters(&self) {
    b3::Counters counters = self.world.counters();
    return {
        .bodies             = (uint)counters.body_count,
        .awake_bodies       = (uint)self.world.awake_body_count(),
        .shapes             = (uint)counters.shape_count,
        .contacts           = (uint)counters.contact_count,
        .awake_contacts     = (uint)counters.awake_contact_count,
        .joints             = (uint)counters.joint_count,
        .islands            = (uint)counters.island_count,
        .tree_height        = (uint)counters.tree_height,
        .static_tree_height = (uint)counters.static_tree_height,
        .bytes              = (uint)counters.byte_count,
        .occupied_snapshots = occupied_snapshots(self.snapshots),
        .snapshot_capacity  = (uint)self.snapshots.slots.len,
    };
}

<*
 Live motion of the node's body.
 @require self.scene.has(node, RigidBody)
*>
fn BodyState PhysicsWorld.body_state(&self, Node* node) {
    b3::BodyId body = self.scene.get(node, RigidBody).body;
    return {
        .awake            = body.is_awake(),
        .mass             = body.mass(),
        .center_of_mass   = body.world_center(),
        .linear_velocity  = body.linear_velocity(),
        .angular_velocity = body.angular_velocity(),
    };
}

<*
 Wake the node's body.
 @require self.scene.has(node, RigidBody)
*>
fn void PhysicsWorld.wake(&self, Node* node) {
    self.scene.get(node, RigidBody).body.set_awake(true);
}

fn uint occupied_snapshots(SnapshotTable* table) @private {
    uint count;
    foreach (&slot : table.slots) {
        if (is_occupied(slot)) count++;
    }
    return count;
}
