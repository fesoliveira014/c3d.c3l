module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;

<*
 Whether a cloth simulates, rests until a trigger, or holds until woken.
*>
enum ClothActivity {
    AWAKE,
    RESTING,
    HELD,
}

enum ClothUpdateKind @private {
    SIMULATED,
    RESTED,
    HELD,
}

<* Settle run, recorded environment and pending wake of one cloth. *>
struct ClothSettle {
    bool resting;
    bool wake_requested;
    uint quiet_steps;
    bool wind_present;
    Wind wind;
    Vec3 gravity;
}

<* Material-vertex ranges whose staged values differ from the geometry. *>
struct ClothSpans {
    VertexRange positions;
    VertexRange normals;
    VertexRange tangents;
}

<*
 Hold the cloth still until wake; triggers do not wake it.
*>
fn void Cloth.sleep(&self) {
    self.authoring.held = true;
    if (!self.state) return;

    self.state.velocities[..] = (Vec3){};
    self.state.settle.wake_requested = false;
}

<*
 Resume simulation, carrying particles by the reference motion since the cloth stopped.
*>
fn void Cloth.wake(&self) {
    bool was_held = self.authoring.held;
    self.authoring.held = false;
    if (self.state && (was_held || self.state.settle.resting)) self.state.settle.wake_requested = true;
}

<*
 Whether the cloth simulates, rests or is held.
*>
fn ClothActivity Cloth.activity(&self) {
    if (self.authoring.held) return HELD;
    if (self.state && self.state.settle.resting) return RESTING;
    return AWAKE;
}

<*
 Hold every part of one crowd slot still until wake_slot.
 @require slot < self.state.held_slots.len : "Below the owning AnimatedCrowd's capacity."
*>
fn void CrowdCloth.sleep_slot(&self, uint slot) {
    self.state.held_slots[slot] = true;
    foreach (&part_record : self.state.parts) {
        if (!part_record.prepared) continue;

        ClothState* state = part_record.states[slot];
        state.velocities[..] = (Vec3){};
        state.settle.wake_requested = false;
    }
}

<*
 Resume every part of one crowd slot, carrying it by its reference motion.
 @require slot < self.state.held_slots.len : "Below the owning AnimatedCrowd's capacity."
*>
fn void CrowdCloth.wake_slot(&self, uint slot) {
    bool was_held = self.state.held_slots[slot];
    self.state.held_slots[slot] = false;
    foreach (&part_record : self.state.parts) {
        if (!part_record.prepared) continue;

        ClothState* state = part_record.states[slot];
        if (was_held || state.settle.resting) state.settle.wake_requested = true;
    }
}

<*
 Whether one crowd slot's cloth simulates, rests or is held.
 @require slot < self.state.held_slots.len : "Below the owning AnimatedCrowd's capacity."
*>
fn ClothActivity CrowdCloth.slot_activity(&self, uint slot) {
    if (self.state.held_slots[slot]) return HELD;

    bool any_prepared;
    foreach (&part_record : self.state.parts) {
        if (!part_record.prepared) continue;

        any_prepared = true;
        if (!part_record.states[slot].settle.resting) return AWAKE;
    }
    return any_prepared ? RESTING : AWAKE;
}

fn ClothState probe_cloth(ClothState* state) @private {
    ClothState probe = *state;
    probe.bodies = state.staged_bodies;
    probe.shape_storage = state.staged_shapes;
    probe.bodies[..] = state.bodies[..];
    probe.current_reference = state.staged_current_reference.len
        ? state.staged_current_reference[:state.committed_particle_count]
        : state.current_reference;
    probe.contact_result = {};
    return probe;
}

fn bool rest_disturbed(PhysicsWorld* world, ClothState* state, Wind* wind) @private {
    ClothSettle* settle = &state.settle;
    if (state.pending_request_count) return true;
    if (world.desc.tuning.gravity != settle.gravity) return true;
    if ((wind != null) != settle.wind_present) return true;
    if (wind && wind_differs(wind, &settle.wind)) return true;

    float threshold = state.desc.sleep_speed * world.desc.tuning.fixed_dt;
    foreach (particle, reference : state.current_reference) {
        Vec3 displacement = reference - state.solved_reference[particle];
        if (displacement.dot(displacement) > threshold * threshold) return true;
    }
    return bodies_disturbed(state, threshold);
}

fn void carry_waking_cloth(ClothState* state) @private {
    if (!state.settle.resting && !state.settle.wake_requested) return;

    foreach (particle, reference : state.current_reference) {
        Vec3 displacement = reference - state.solved_reference[particle];
        state.positions[particle] += displacement;
        state.predicted[particle] += displacement;
    }
    state.velocities[..] = (Vec3){};
    state.solved_reference[..] = state.current_reference[..];
    if (state.settle.wake_requested) {
        foreach (&body : state.bodies) body.observed = body.published_observed = false;
    }
    state.settle = {};
}

fn void note_settling(
    PhysicsWorld* world,
    ClothState* state,
    Wind* wind,
    uint steps,
) @private {
    float sleep_speed = state.desc.sleep_speed;
    if (sleep_speed <= 0 || !steps) return;

    ClothSettle* settle = &state.settle;
    foreach (particle, velocity : state.velocities) {
        if (state.inverse_masses[particle] == 0) continue;
        if (velocity.dot(velocity) >= sleep_speed * sleep_speed) {
            settle.quiet_steps = 0;
            return;
        }
    }

    settle.quiet_steps = steps > uint::max - settle.quiet_steps ? uint::max : settle.quiet_steps + steps;
    if (settle.quiet_steps < state.desc.sleep_steps) return;

    state.velocities[..] = (Vec3){};
    settle.resting = true;
    settle.wind_present = wind != null;
    if (wind) settle.wind = *wind;
    settle.gravity = world.desc.tuning.gravity;
    foreach (&body : state.bodies) {
        body.rested_live = body.live;
        body.rested = body.current;
    }
}

fn bool wind_differs(Wind* current, Wind* recorded) @local {
    return current.velocity != recorded.velocity
        || current.drag != recorded.drag
        || current.lift != recorded.lift
        || current.max_speed != recorded.max_speed;
}

fn bool bodies_disturbed(ClothState* state, float threshold) @local {
    foreach (&body : state.bodies) {
        if (body.live != body.rested_live) return true;
        if (body.live && !body.published_observed) return true;
    }

    bool bounds_ready;
    Aabb cloth_bounds;
    foreach (&shape : state.shapes) {
        ClothBody* body = &state.bodies[shape.body];
        if (!body.live || !body_moved(body, shape_reach(shape), threshold)) continue;

        if (!bounds_ready) {
            cloth_bounds = cloth_contact_bounds(state);
            bounds_ready = true;
        }
        Aabb placed = maths::aabb_transform(shape.bounds, body.current.to_mat4().mul(shape.local.to_mat4()));
        if (bounds_overlap(placed, cloth_bounds)) return true;
    }
    return false;
}

fn bool body_moved(ClothBody* body, float reach, float threshold) @local {
    if ((body.current.position - body.rested.position).length() > threshold) return true;

    Quaternionf relative = body.current.rotation * body.rested.rotation.conjugate();
    Vec3 half_turn = { relative.i, relative.j, relative.k };
    return 2 * reach * half_turn.length() > threshold;
}

fn float shape_reach(ClothShape* shape) @local {
    Vec3 farthest = math::max(math::abs(shape.bounds.min), math::abs(shape.bounds.max));
    return shape.local.position.length() + farthest.length();
}

fn Aabb cloth_contact_bounds(ClothState* state) @local {
    Aabb bounds = { .min = state.positions[0], .max = state.positions[0] };
    foreach (position : state.positions) {
        bounds.min = math::min(bounds.min, position);
        bounds.max = math::max(bounds.max, position);
    }

    float margin = state.desc.thickness + (float)state.desc.collisions.contact_tolerance;
    bounds.min -= margin;
    bounds.max += margin;
    return bounds;
}

fn bool bounds_overlap(Aabb first, Aabb second) @local {
    for (uint axis = 0; axis < 3; axis++) {
        if (first.max[axis] < second.min[axis] || first.min[axis] > second.max[axis]) return false;
    }
    return true;
}

fn void tally_cloth(
    ClothStats* stats,
    ClothState* state,
    ClothUpdateKind kind,
    double total_seconds,
    double publication_seconds,
) @private {
    stats.solve_seconds += math::max(0.0, total_seconds - publication_seconds);
    stats.publish_seconds += publication_seconds;
    switch (kind) {
        case RESTED:
            stats.resting++;
        case HELD:
            stats.held++;
        case SIMULATED:
            stats.candidates += state.contact_result.candidates;
            stats.contacts += state.contact_result.contacts;
            stats.ccd_iterations += state.contact_result.ccd_iterations;
            stats.impacts += state.contact_result.impacts;
            stats.max_residual = math::max(stats.max_residual, state.contact_result.max_residual);
            stats.particles += (uint)state.positions.len;
            stats.constraints += (uint)(
                state.edges.len + state.bends.len + state.hinges.len + state.soft_attachments.len
            );
    }
}

fn void include_vertex(VertexRange* range, usz vertex) @private {
    if (range.is_empty()) range.first = (uint)vertex;
    range.end = (uint)vertex + 1;
}

macro VertexRange differing_range(current, staged) @private {
    VertexRange range;
    foreach (vertex, value : staged) {
        if (value != current[vertex]) include_vertex(&range, (usz)vertex);
    }
    return range;
}
