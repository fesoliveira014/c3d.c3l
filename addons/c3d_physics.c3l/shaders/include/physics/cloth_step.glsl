#ifndef PHYSICS_CLOTH_STEP_GLSL
#define PHYSICS_CLOTH_STEP_GLSL

#include "physics/cloth_root.glsl"

#ifndef CLOTH_COHERENT
#define CLOTH_COHERENT
#endif

const uint PASS_PREDICT = 1u;        // mirrored in gpu/cloth_record.c3; predict every particle in this pass, before projecting
const uint PASS_COLLIDE = 2u;        // mirrored in gpu/cloth_record.c3; collide every particle in this pass, after projecting
const uint PASS_INTEGRATE = 4u;      // mirrored in gpu/cloth_record.c3; integrate every particle in this pass, after colliding
const uint PASS_INITIALIZE = 8u;     // mirrored in gpu/cloth_record.c3; copy the initial state before the pass's other work
const uint PASS_OUTPUT = 16u;        // mirrored in gpu/cloth_record.c3; write the output geometry from the final positions
const uint PASS_FINAL_SUBSTEP = 32u; // mirrored in gpu/cloth_record.c3; the pass belongs to the request's last substep
const uint PASS_SOFT_BEFORE = 64u;   // mirrored in gpu/cloth_record.c3; project the soft attachments after predicting
const uint PASS_SOFT_AFTER = 128u;   // mirrored in gpu/cloth_record.c3; project the soft attachments after colliding
const uint PASS_STAGE = 256u;        // mirrored in gpu/cloth_record.c3; copy the payload that follows the root into the reference
const float MIN_EDGE_LENGTH = 1e-7;  // metres; mirrored as MIN_CONSTRAINT_LENGTH in solve.c3

layout(buffer_reference, std430, buffer_reference_align = 16) CLOTH_COHERENT buffer StepVectors {
    vec4 values[];
};

struct StepPass {
    uint  first;             // first constraint of the pass
    uint  count;             // constraints of the pass
    uint  phases;
    uint  member_bit;
    float progress;
    float previous_progress;
    float stiffness;
};

struct StepConstraint {
    uint  first;
    uint  second;
    float rest_length;
    vec3  rest_direction;
};

void step_initialize(ClothRoot root, uint index) {
    vec4 start = ClothVectors(root.initial).values[index];
    StepVectors(root.positions).values[index] = start;
    StepVectors(root.predicted).values[index] = start;
    StepVectors(root.velocities).values[index] = vec4(0.0);
}

void step_stage(ClothRoot root, uint index) {
    ClothVectors payload = ClothVectors(DispatchRoot(pc.root_gpu).parameters + uint64_t(CLOTH_PAYLOAD_OFFSET));
    StepVectors(root.reference).values[index] = payload.values[index];
}

// Sums the columns in the order maths::transform_point does, so the device and the host round a point alike.
vec3 step_transform_point(mat4 frame, vec3 point) {
    return frame[0].xyz * point.x + frame[1].xyz * point.y + frame[2].xyz * point.z + frame[3].xyz;
}

vec3 step_reference_solved(ClothRoot root, uint index) {
    if ((root.features & CLOTH_FEATURE_REFERENCE) != 0u) return StepVectors(root.reference).values[2u * index].xyz;

    return step_transform_point(root.anchor_frame, ClothVectors(root.rest).values[index].xyz);
}

vec3 step_reference_current(ClothRoot root, uint index) {
    if ((root.features & CLOTH_FEATURE_REFERENCE) != 0u) return StepVectors(root.reference).values[2u * index + 1u].xyz;

    return step_transform_point(root.target_frame, ClothVectors(root.rest).values[index].xyz);
}

// The reference position the substep ends at, which is the request's end in its last substep.
vec3 step_reference_at_end(ClothRoot root, uint index, StepPass step) {
    vec3 current = step_reference_current(root, index);
    if ((step.phases & PASS_FINAL_SUBSTEP) != 0u) return current;

    vec3 solved = step_reference_solved(root, index);
    return solved + (current - solved) * step.progress;
}

vec3 step_pin_target(ClothRoot root, uint index, StepPass step) {
    return step_reference_at_end(root, index, step);
}

vec3 step_transport(ClothRoot root, uint index, StepPass step) {
    if ((root.features & CLOTH_FEATURE_TRANSPORT) == 0u) return vec3(0.0);

    float weight = uintBitsToFloat(ClothWords(root.transport).values[index]);
    if (weight == 0.0) return vec3(0.0);

    vec3 solved = step_reference_solved(root, index);
    vec3 delta = step_reference_current(root, index) - solved;
    vec3 previous_reference = solved + delta * step.previous_progress;
    vec3 next_reference = step_reference_at_end(root, index, step);
    return (next_reference - previous_reference) * weight;
}

// Each particle sums the force shares of its own triangles in triangle order, as the host does, so no atomics are needed.
vec3 step_wind_acceleration(ClothRoot root, uint index) {
    if ((root.features & CLOTH_FEATURE_WIND) == 0u) return vec3(0.0);

    ClothWords adjacency = ClothWords(root.adjacency);
    ClothWords triangles = ClothWords(root.triangles);
    StepVectors positions = StepVectors(root.positions);
    StepVectors velocities = StepVectors(root.velocities);
    float inverse_mass = positions.values[index].w;
    vec3 acceleration = vec3(0.0);
    for (uint entry = adjacency.values[index]; entry < adjacency.values[index + 1u]; entry++) {
        uint triangle = adjacency.values[root.particle_count + 1u + entry];
        uint first = triangles.values[3u * triangle];
        uint second = triangles.values[3u * triangle + 1u];
        uint third = triangles.values[3u * triangle + 2u];

        vec3 doubled_normal = cross(
            positions.values[second].xyz - positions.values[first].xyz,
            positions.values[third].xyz - positions.values[first].xyz
        );
        float doubled_area = length(doubled_normal);
        if (doubled_area == 0.0) continue;

        vec3 normal = doubled_normal / doubled_area;
        vec3 relative = root.wind.xyz
            - (velocities.values[first].xyz + velocities.values[second].xyz + velocities.values[third].xyz) / 3.0;
        float speed = length(relative);
        if (speed == 0.0) continue;

        if (root.wind.w > 0.0 && speed > root.wind.w) {
            relative *= root.wind.w / speed;
            speed = root.wind.w;
        }

        vec3 direction = relative / speed;
        float side = dot(direction, normal);
        float speed_squared_area = speed * speed * doubled_area * 0.5;
        vec3 force = normal * (root.aero.x * speed_squared_area * side * abs(side))
            + (normal - direction * side) * (root.aero.y * speed_squared_area * side);
        acceleration += (force / 3.0) * inverse_mass;
    }
    return acceleration;
}

float step_soft_compliance(ClothRoot root, uint index) {
    if ((root.features & CLOTH_FEATURE_SOFT) == 0u) return 0.0;

    return uintBitsToFloat(ClothWords(root.soft).values[index]);
}

// Wind reads the neighbours' velocities, so this pass never writes them; integrate sets every free velocity.
void step_predict(ClothRoot root, uint index, StepPass step) {
    StepVectors predicted = StepVectors(root.predicted);
    vec4 position = StepVectors(root.positions).values[index];
    if (position.w == 0.0) {
        predicted.values[index] = vec4(step_pin_target(root, index, step), 0.0);
        return;
    }

    float substep_seconds = root.gravity_step.w;
    vec3 held = StepVectors(root.velocities).values[index].xyz;
    vec3 acceleration = root.gravity_step.xyz + step_wind_acceleration(root, index);
    vec3 velocity = (held + acceleration * substep_seconds) * root.damping;
    vec3 transport = step_transport(root, index, step);
    predicted.values[index] = vec4(position.xyz + transport + velocity * substep_seconds, position.w);
    if (step_soft_compliance(root, index) != 0.0) StepVectors(root.lambdas).values[index] = vec4(0.0);
}

void step_soft(ClothRoot root, uint index, StepPass step) {
    float compliance = step_soft_compliance(root, index);
    if (compliance == 0.0) return;

    StepVectors predicted = StepVectors(root.predicted);
    StepVectors lambdas = StepVectors(root.lambdas);
    vec4 particle = predicted.values[index];
    float substep_seconds = root.gravity_step.w;
    float compliance_per_step = compliance / (substep_seconds * substep_seconds);

    vec3 residual = particle.xyz - step_reference_at_end(root, index, step);
    vec3 lambda = lambdas.values[index].xyz;
    vec3 delta_lambda = -(residual + lambda * compliance_per_step) / (particle.w + compliance_per_step);
    lambdas.values[index] = vec4(lambda + delta_lambda, 0.0);
    predicted.values[index] = vec4(particle.xyz + delta_lambda * particle.w, particle.w);
}

StepConstraint step_constraint(ClothRoot root, uint index) {
    ClothConstraints constraints = ClothConstraints(root.constraints);
    uvec4 head = constraints.values[2u * index];
    uvec4 tail = constraints.values[2u * index + 1u];
    return StepConstraint(
        head.x,
        head.y,
        uintBitsToFloat(head.z),
        vec3(uintBitsToFloat(tail.x), uintBitsToFloat(tail.y), uintBitsToFloat(tail.z))
    );
}

void step_project(ClothRoot root, StepConstraint constraint, StepPass step) {
    StepVectors predicted = StepVectors(root.predicted);
    vec4 first = predicted.values[constraint.first];
    vec4 second = predicted.values[constraint.second];
    float total_weight = first.w + second.w;
    if (total_weight == 0.0) return;

    vec3 delta = second.xyz - first.xyz;
    float length_now = length(delta);
    vec3 direction = length_now > MIN_EDGE_LENGTH ? delta / length_now : constraint.rest_direction;
    vec3 correction = direction * ((length_now - constraint.rest_length) * step.stiffness / total_weight);
    predicted.values[constraint.first].xyz = first.xyz + correction * first.w;
    predicted.values[constraint.second].xyz = second.xyz - correction * second.w;
}

void step_collide(ClothRoot root, uint index) {
    StepVectors predicted = StepVectors(root.predicted);
    vec4 particle = predicted.values[index];
    if (particle.w == 0.0) return;

    vec3 position = particle.xyz;
    if (root.sphere.w > 0.0) {
        vec3 offset = position - root.sphere.xyz;
        float distance_now = length(offset);
        if (distance_now < root.sphere.w) {
            vec3 outward = distance_now > 1e-7 ? offset / distance_now : vec3(0.0, 1.0, 0.0);
            position = root.sphere.xyz + outward * root.sphere.w;
        }
    }
    position.y = max(position.y, root.ground);
    predicted.values[index].xyz = position;
}

void step_integrate(ClothRoot root, uint index, StepPass step) {
    StepVectors positions = StepVectors(root.positions);
    vec4 position = positions.values[index];
    vec4 predicted = StepVectors(root.predicted).values[index];
    if (position.w != 0.0) {
        vec3 transport = step_transport(root, index, step);
        StepVectors(root.velocities).values[index] = vec4(
            (predicted.xyz - position.xyz - transport) / root.gravity_step.w,
            0.0
        );
    }
    positions.values[index] = vec4(predicted.xyz, position.w);
}

// Work a pass does on a particle it owns before the pass's constraints project.
void step_enter(ClothRoot root, uint index, StepPass step) {
    if ((step.phases & PASS_INITIALIZE) != 0u) step_initialize(root, index);
    if ((step.phases & PASS_PREDICT) != 0u) step_predict(root, index, step);
    if ((step.phases & PASS_SOFT_BEFORE) != 0u) step_soft(root, index, step);
}

// Work a pass does on a particle it owns after the pass's constraints project.
void step_leave(ClothRoot root, uint index, StepPass step) {
    if ((step.phases & PASS_COLLIDE) != 0u) step_collide(root, index);
    if ((step.phases & PASS_SOFT_AFTER) != 0u) step_soft(root, index, step);
    if ((step.phases & PASS_INTEGRATE) != 0u) step_integrate(root, index, step);
}

// Items below the pass's constraint count project one constraint and own both of its particles. The items after them
// own one particle that is on no constraint of the pass, so every particle has exactly one owner and no item reads
// another item's data.
void step_item(ClothRoot root, uint item, StepPass step) {
    if (item < step.count) {
        StepConstraint constraint = step_constraint(root, step.first + item);
        step_enter(root, constraint.first, step);
        step_enter(root, constraint.second, step);
        step_project(root, constraint, step);
        step_leave(root, constraint.first, step);
        step_leave(root, constraint.second, step);
        return;
    }

    uint particle = item - step.count;
    if (particle >= root.particle_count) return;
    if (((ClothWords(root.marks).values[particle] >> step.member_bit) & 1u) != 0u) return;

    step_enter(root, particle, step);
    step_leave(root, particle, step);
}

uint step_item_count(ClothRoot root, StepPass step) {
    bool owns_particles = (step.phases & (PASS_PREDICT | PASS_COLLIDE)) != 0u;
    return step.count + (owns_particles ? root.particle_count : 0u);
}

vec3 step_local_position(ClothRoot root, uint particle) {
    return (root.inverse_world * vec4(StepVectors(root.positions).values[particle].xyz, 1.0)).xyz;
}

// Writes the node-local position and the area-weighted normal of every particle of the output geometry.
void step_output(ClothRoot root, uint index) {
    ClothWords adjacency = ClothWords(root.adjacency);
    ClothWords triangles = ClothWords(root.triangles);
    vec3 normal = vec3(0.0);
    for (uint entry = adjacency.values[index]; entry < adjacency.values[index + 1u]; entry++) {
        uint triangle = adjacency.values[root.particle_count + 1u + entry];
        vec3 a = step_local_position(root, triangles.values[3u * triangle]);
        vec3 b = step_local_position(root, triangles.values[3u * triangle + 1u]);
        vec3 c = step_local_position(root, triangles.values[3u * triangle + 2u]);
        normal += cross(b - a, c - a);
    }
    float normal_length = length(normal);
    normal = normal_length > 0.0 ? normal / normal_length : vec3(0.0, 1.0, 0.0);

    vec3 position = step_local_position(root, index);
    ClothFloats positions = ClothFloats(root.geometry_positions);
    ClothFloats normals = ClothFloats(root.geometry_normals);
    for (uint axis = 0u; axis < 3u; axis++) {
        positions.values[3u * index + axis] = position[axis];
        normals.values[3u * index + axis] = normal[axis];
    }
}

#endif
