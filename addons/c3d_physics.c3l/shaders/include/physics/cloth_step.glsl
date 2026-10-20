#ifndef PHYSICS_CLOTH_STEP_GLSL
#define PHYSICS_CLOTH_STEP_GLSL

#include "physics/cloth_root.glsl"

#ifndef CLOTH_COHERENT
#define CLOTH_COHERENT
#endif

const uint PASS_PREDICT = 1u;        // mirrored in gpu/cloth.c3; predict every particle in this pass, before projecting
const uint PASS_COLLIDE = 2u;        // mirrored in gpu/cloth.c3; collide every particle in this pass, after projecting
const uint PASS_INTEGRATE = 4u;      // mirrored in gpu/cloth.c3; integrate every particle in this pass, after colliding
const uint PASS_INITIALIZE = 8u;     // mirrored in gpu/cloth.c3; copy the initial state before the pass's other work
const uint PASS_OUTPUT = 16u;        // mirrored in gpu/cloth.c3; write the output geometry from the final positions
const uint PASS_FINAL_SUBSTEP = 32u; // mirrored in gpu/cloth.c3; the pass belongs to the request's last substep
const float MIN_EDGE_LENGTH = 1e-7;  // metres; mirrored as MIN_CONSTRAINT_LENGTH in solve.c3

layout(buffer_reference, std430, buffer_reference_align = 16) CLOTH_COHERENT buffer StepVectors {
    vec4 values[];
};

struct StepPass {
    uint  first;      // first edge of the color
    uint  count;      // edges of the color
    uint  phases;
    uint  member_bit;
    float progress;
};

void step_initialize(ClothRoot root, uint index) {
    vec4 start = ClothVectors(root.initial).values[index];
    StepVectors(root.positions).values[index] = start;
    StepVectors(root.predicted).values[index] = start;
    StepVectors(root.velocities).values[index] = vec4(0.0);
}

vec3 step_pin_target(ClothRoot root, uint index, StepPass step) {
    vec3 local = ClothVectors(root.rest).values[index].xyz;
    vec3 target = (root.target_frame * vec4(local, 1.0)).xyz;
    if ((step.phases & PASS_FINAL_SUBSTEP) != 0u) return target;

    vec3 anchor = (root.anchor_frame * vec4(local, 1.0)).xyz;
    return anchor + (target - anchor) * step.progress;
}

void step_predict(ClothRoot root, uint index, StepPass step) {
    StepVectors predicted = StepVectors(root.predicted);
    StepVectors velocities = StepVectors(root.velocities);
    vec4 position = StepVectors(root.positions).values[index];
    if (position.w == 0.0) {
        predicted.values[index] = vec4(step_pin_target(root, index, step), 0.0);
        return;
    }

    float substep_seconds = root.gravity_step.w;
    vec3 held = velocities.values[index].xyz;
    vec3 velocity = (held + root.gravity_step.xyz * substep_seconds) * root.damping;
    velocities.values[index] = vec4(velocity, 0.0);
    predicted.values[index] = vec4(position.xyz + velocity * substep_seconds, position.w);
}

void step_project(ClothRoot root, uvec4 edge) {
    StepVectors predicted = StepVectors(root.predicted);
    vec4 first = predicted.values[edge.x];
    vec4 second = predicted.values[edge.y];
    float total_weight = first.w + second.w;
    if (total_weight == 0.0) return;

    vec3 delta = second.xyz - first.xyz;
    float length_now = length(delta);
    if (length_now <= MIN_EDGE_LENGTH) return;

    vec3 correction = delta / length_now * ((length_now - uintBitsToFloat(edge.z)) * root.stiffness / total_weight);
    predicted.values[edge.x].xyz = first.xyz + correction * first.w;
    predicted.values[edge.y].xyz = second.xyz - correction * second.w;
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

void step_integrate(ClothRoot root, uint index) {
    StepVectors positions = StepVectors(root.positions);
    vec4 position = positions.values[index];
    vec4 predicted = StepVectors(root.predicted).values[index];
    if (position.w != 0.0) {
        StepVectors(root.velocities).values[index] = vec4((predicted.xyz - position.xyz) / root.gravity_step.w, 0.0);
    }
    positions.values[index] = vec4(predicted.xyz, position.w);
}

void step_particle(ClothRoot root, uint index, StepPass step) {
    if ((step.phases & PASS_INITIALIZE) != 0u) step_initialize(root, index);
    if ((step.phases & PASS_PREDICT) != 0u) step_predict(root, index, step);
    if ((step.phases & PASS_COLLIDE) != 0u) step_collide(root, index);
    if ((step.phases & PASS_INTEGRATE) != 0u) step_integrate(root, index);
}

// Items below the pass's edge count project one edge and own both of its particles. The items after them own one
// particle that is on no edge of the pass's color, so every particle has exactly one owner and no item reads another
// item's data.
void step_item(ClothRoot root, uint item, StepPass step) {
    if (item < step.count) {
        uvec4 edge = ClothEdges(root.edges).values[step.first + item];
        if ((step.phases & PASS_INITIALIZE) != 0u) {
            step_initialize(root, edge.x);
            step_initialize(root, edge.y);
        }
        if ((step.phases & PASS_PREDICT) != 0u) {
            step_predict(root, edge.x, step);
            step_predict(root, edge.y, step);
        }
        step_project(root, edge);
        if ((step.phases & PASS_COLLIDE) != 0u) {
            step_collide(root, edge.x);
            step_collide(root, edge.y);
        }
        if ((step.phases & PASS_INTEGRATE) != 0u) {
            step_integrate(root, edge.x);
            step_integrate(root, edge.y);
        }
        return;
    }

    uint particle = item - step.count;
    if (particle >= root.particle_count) return;
    if (((ClothWords(root.marks).values[particle] >> step.member_bit) & 1u) != 0u) return;

    step_particle(root, particle, step);
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
