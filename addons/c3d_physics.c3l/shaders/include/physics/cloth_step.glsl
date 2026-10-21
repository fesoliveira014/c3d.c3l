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
const uint PASS_STAGE = 256u;        // mirrored in gpu/cloth_record.c3; copy the reference pairs and shapes the root names into place
const uint PASS_SHAPES = 512u;       // mirrored in gpu/cloth_record.c3; push the particles it collides out of the shapes
const uint PASS_FIRST_CONTACT = 1024u; // mirrored in gpu/cloth_record.c3; the shape contacts of this pass are the substep's first
const uint PASS_PLACE = 2048u;       // mirrored in gpu/cloth_record.c3; place the shapes for the substep, one extra item each
const float MIN_EDGE_LENGTH = 1e-7;  // metres; mirrored as MIN_CONSTRAINT_LENGTH in solve.c3
const float CONTACT_AXIS_SQUARED = 1e-14; // square metres; mirrored as CONTACT_AXIS_DISTANCE squared in cloth_contact_math.c3
const float CONTACT_PUSH_UNBOUNDED = 0.0;  // value of the push's w until the substep's total reaches the particle's limit

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

struct StepShape {
    vec3  start;                // world start of the segment at the substep
    vec3  axis;                 // world end minus start
    float reach;                // radius and contact offset
    float inverse_axis_squared; // zero for a sphere
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

uint step_pair_vectors(ClothRoot root) {
    return (root.features & CLOTH_FEATURE_REFERENCE) != 0u ? 2u * root.particle_count : 0u;
}

// Vectors the root stages: the reference pairs, then the shapes.
uint step_stage_count(ClothRoot root) {
    return step_pair_vectors(root) + root.shape_count * CLOTH_SHAPE_VECTORS;
}

void step_stage(ClothRoot root, uint index) {
    ClothVectors payload = ClothVectors(DispatchRoot(pc.root_gpu).parameters + uint64_t(root.payload_offset));
    uint pairs = step_pair_vectors(root);
    if (index < pairs) {
        StepVectors(root.reference).values[index] = payload.values[index];
    } else {
        StepVectors(root.shapes).values[index - pairs] = payload.values[index];
    }
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
        predicted.values[index] = vec4(step_reference_at_end(root, index, step), 0.0);
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

// Matches Quaternion.slerp of the host, so both solvers turn an owner alike.
vec4 step_slerp(vec4 from, vec4 to, float amount) {
    float cosine = dot(from, to);
    vec4 target = to;
    if (cosine < 0.0) {
        target = -to;
        cosine = -cosine;
    }
    if (cosine >= 1.0) return from;
    if (cosine > 0.95) return normalize(from + (target - from) * amount);

    float half_theta = acos(cosine);
    float sine = sqrt(1.0 - cosine * cosine);
    if (abs(sine) < 0.001) return (from + target) * 0.5;

    return from * (sin((1.0 - amount) * half_theta) / sine) + target * (sin(amount * half_theta) / sine);
}

vec3 step_rotate(vec4 rotation, vec3 point) {
    vec4 unit = normalize(rotation);
    return point + 2.0 * cross(unit.xyz, cross(unit.xyz, point) + unit.w * point);
}

// Where a shape's owner stands at the share of the request's motion the substep ends at, as the segment the contact
// reads: start and reach, then axis and the inverse of its squared length.
void step_place_shape(ClothRoot root, uint shape, float progress, out vec4 first, out vec4 second) {
    StepVectors staged = StepVectors(root.shapes);
    uint base = shape * CLOTH_SHAPE_VECTORS;
    vec4 solved_position = staged.values[base];
    vec4 solved_rotation = staged.values[base + 1u];
    vec3 current_position = staged.values[base + 2u].xyz;
    vec4 current_rotation = staged.values[base + 3u];

    vec3 position = current_position;
    vec4 rotation = current_rotation;
    if (progress != 1.0) {
        position = solved_position.xyz + (current_position - solved_position.xyz) * progress;
        rotation = step_slerp(solved_rotation, current_rotation, progress);
    }
    vec3 local_start = staged.values[base + 4u].xyz;
    vec3 axis = step_rotate(rotation, staged.values[base + 5u].xyz - local_start);
    float axis_squared = dot(axis, axis);
    first = vec4(position + step_rotate(rotation, local_start), solved_position.w);
    second = vec4(axis, axis_squared > 0.0 ? 1.0 / axis_squared : 0.0);
}

#ifdef CLOTH_SHARED_SHAPES
void step_store_placed(ClothRoot root, uint shape, vec4 first, vec4 second) {
    cloth_placed[2u * shape] = first;
    cloth_placed[2u * shape + 1u] = second;
}

StepShape step_placed_shape(ClothRoot root, uint shape) {
    vec4 first = cloth_placed[2u * shape];
    vec4 second = cloth_placed[2u * shape + 1u];
    return StepShape(first.xyz, second.xyz, first.w, second.w);
}
#else
void step_store_placed(ClothRoot root, uint shape, vec4 first, vec4 second) {
    StepVectors placed = StepVectors(root.shapes + CLOTH_PLACED_OFFSET);
    placed.values[2u * shape] = first;
    placed.values[2u * shape + 1u] = second;
}

StepShape step_placed_shape(ClothRoot root, uint shape) {
    StepVectors placed = StepVectors(root.shapes + CLOTH_PLACED_OFFSET);
    vec4 first = placed.values[2u * shape];
    vec4 second = placed.values[2u * shape + 1u];
    return StepShape(first.xyz, second.xyz, first.w, second.w);
}
#endif

void step_place_item(ClothRoot root, uint shape, StepPass step) {
    if (shape >= root.shape_count) return;

    vec4 first;
    vec4 second;
    step_place_shape(root, shape, step.progress, first, second);
    step_store_placed(root, shape, first, second);
}

vec3 step_perpendicular(vec3 axis) {
    float squared = dot(axis, axis);
    if (!(squared > 0.0)) return vec3(0.0, 1.0, 0.0);

    vec3 unit = axis / sqrt(squared);
    return normalize(cross(unit, abs(unit.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
}

// The position minus the nearest point of the segment.
vec3 step_shape_offset(StepShape shape, vec3 position) {
    vec3 relative = position - shape.start;
    float along = clamp(dot(relative, shape.axis) * shape.inverse_axis_squared, 0.0, 1.0);
    return relative - shape.axis * along;
}

// Pushes a position out of every shape it overlaps, in shape order, within the substep's push limit.
// A shape counts only if it overlaps the position the pass started from, as on the host.
vec3 step_collide_shapes(ClothRoot root, uint index, vec3 position, StepPass step) {
    bool first_contact = (step.phases & PASS_FIRST_CONTACT) != 0u;
    float tolerance = root.contact_tolerance;
    vec3 start_position = position;
    StepVectors push_totals = StepVectors(root.push);
    bool pushed = false;
    vec3 total = vec3(0.0);
    float limit = 0.0;
    float bounded = CONTACT_PUSH_UNBOUNDED;

    uint count = root.shape_count;
    for (uint shape = 0u; shape < count; shape++) {
        StepShape placed = step_placed_shape(root, shape);
        float inner = placed.reach - tolerance;
        vec3 offset = step_shape_offset(placed, start_position);
        if (!(inner > 0.0 && dot(offset, offset) < inner * inner)) continue;

        if (!pushed) {
            pushed = true;
            vec4 state = first_contact ? vec4(0.0) : push_totals.values[index];
            if (state.w != CONTACT_PUSH_UNBOUNDED) return position;

            total = state.xyz;
            limit = uintBitsToFloat(ClothWords(root.limits).values[index]);
        }
        if (position != start_position) offset = step_shape_offset(placed, position);

        float squared = dot(offset, offset);
        float separation = 0.0;
        vec3 direction;
        if (squared > CONTACT_AXIS_SQUARED) {
            separation = sqrt(squared);
            direction = offset / separation;
        } else {
            direction = step_perpendicular(placed.axis);
        }
        float residual = placed.reach - separation;
        if (residual <= tolerance) continue;

        vec3 target = position + direction * (residual + 0.25 * tolerance);
        vec3 sum = total + (target - position);
        float length_now = length(sum);
        if (!(length_now > limit)) {
            total = sum;
            position = target;
        } else {
            sum *= limit / length_now;
            position += sum - total;
            total = sum;
            bounded = 1.0;
        }
    }
    if (pushed) {
        push_totals.values[index] = vec4(total, bounded);
    } else if (first_contact) {
        push_totals.values[index] = vec4(0.0);
    }
    return position;
}

void step_collide(ClothRoot root, uint index, StepPass step) {
    StepVectors predicted = StepVectors(root.predicted);
    vec4 particle = predicted.values[index];
    if (particle.w == 0.0) return;

    vec3 position = particle.xyz;
    position.y = max(position.y, root.ground);
    if ((step.phases & PASS_SHAPES) != 0u) position = step_collide_shapes(root, index, position, step);
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
    if ((step.phases & PASS_COLLIDE) != 0u) step_collide(root, index, step);
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
    if (particle >= root.particle_count) {
        if ((step.phases & PASS_PLACE) != 0u) step_place_item(root, particle - root.particle_count, step);
        return;
    }
    if (((ClothWords(root.marks).values[particle] >> step.member_bit) & 1u) != 0u) return;

    step_enter(root, particle, step);
    step_leave(root, particle, step);
}

uint step_item_count(ClothRoot root, StepPass step) {
    bool owns_particles = (step.phases & (PASS_PREDICT | PASS_COLLIDE)) != 0u;
    uint placed = (step.phases & PASS_PLACE) != 0u ? root.shape_count : 0u;
    return step.count + (owns_particles ? root.particle_count : 0u) + placed;
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
