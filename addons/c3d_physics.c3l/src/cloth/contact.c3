module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import std::math;

<* Maximum accepted contact separation deficit, in metres. *>
const float DEFAULT_CONTACT_TOLERANCE = 0.0001f;
<* Final contact passes per substep or publication. *>
const uint DEFAULT_CONTACT_ITERATIONS = 8;
<* Collider leaves retained across the listed bodies. *>
const uint DEFAULT_CONTACT_SHAPES = 128;
<* Candidate pairs retained in one contact pass. *>
const uint DEFAULT_CONTACT_CANDIDATES = 8192;
<* Active contacts retained in one contact pass. *>
const uint DEFAULT_CONTACTS = 4096;
<* Distance advances allowed for one candidate path. *>
const uint DEFAULT_CCD_ITERATIONS = 64;

<* Stage of the last contact failure. *>
enum ClothContactStage : uint {
    NONE,
    ARITHMETIC,
    BINDINGS,
    CANDIDATES,
    CONTACTS,
    RESOLVE,
    PUBLICATION,
    REEXPRESSION,
    MATERIAL,
    ATTACHMENT,
    BEND,
    REFERENCE,
    OPENING,
}

<* Prepared storage and convergence limits for cloth contacts. *>
struct ClothCollisionDesc {
    float contact_tolerance;
    uint  contact_iterations;
    uint  max_shapes;
    uint  max_candidates;
    uint  max_contacts;
    bool  self_collision;
    bool  continuous;
    uint  max_ccd_iterations;
}

<* Observed contact work and failure from the last update. *>
struct ClothContactResult {
    fault             failure;
    ClothContactStage stage;
    uint              candidates;
    uint              peak_candidates;
    uint              contacts;
    uint              peak_contacts;
    uint              pinned_overlaps;
    uint              unresolved;
    uint              sweeps;
    uint              ccd_iterations;
    uint              impacts;
    uint              vertex_face_impacts;
    uint              edge_edge_impacts;
    uint              resweeps;
    double            max_residual;
}

<* Default cloth contact accuracy and prepared capacities. *>
fn ClothCollisionDesc default_cloth_collision_desc() {
    return {
        .contact_tolerance = DEFAULT_CONTACT_TOLERANCE,
        .contact_iterations = DEFAULT_CONTACT_ITERATIONS,
        .max_shapes = DEFAULT_CONTACT_SHAPES,
        .max_candidates = DEFAULT_CONTACT_CANDIDATES,
        .max_contacts = DEFAULT_CONTACTS,
        .max_ccd_iterations = DEFAULT_CCD_ITERATIONS,
    };
}

fn ContactProjection? evaluate_contact(
    PhysicsWorld* world,
    ClothState* state,
    ClothCandidate* candidate,
    Vec3 position,
    bool correct,
) @local {
    float tolerance = state.desc.collisions.contact_tolerance;
    switch (candidate.kind) {
        case GROUND:
            ContactInterval distance = physics::contact_subtract(physics::contact_value(position.y), physics::contact_value(state.desc.ground_height))!;
            double residual = math::max(0.0, (double)state.desc.thickness - distance.min);
            ContactProjection result = { .corrected = position, .residual = residual };
            if (correct && residual > tolerance) {
                result.corrected.y = (float)((double)state.desc.ground_height + state.desc.thickness + (double)tolerance / 4);
                if (!finite_vector(result.corrected) || result.corrected == position) return CONTACT_PRECISION_EXCEEDED~;
            }
            return result;
        case TRIANGLE:
            return physics::contact_triangle(
                frame: &state.frames[candidate.shape],
                vertices: candidate.vertices,
                position: position,
                thickness: state.desc.thickness,
                tolerance: tolerance,
                correct: correct,
            );
        case SELF_VERTEX_FACE:
        case SELF_EDGE_EDGE:
            return c3d::INVALID_ARGUMENT~;
        case SHAPE:
            ClothShape* shape = &state.shapes[candidate.shape];
            switch (shape.kind) {
                case SPHERE:
                case CAPSULE:
                    return physics::contact_capsule(
                        frame: &state.frames[candidate.shape],
                        start: shape.start,
                        end: shape.end,
                        radius: shape.radius,
                        position: position,
                        thickness: state.desc.thickness,
                        tolerance: tolerance,
                        correct: correct,
                    );
                case BOX:
                case HULL:
                    return physics::project_cloth_convex(
                        world: world, state: state, candidate: candidate, position: position, correct: correct,
                    );
                case MESH:
                case HEIGHT_FIELD:
                case COMPOUND:
                    return c3d::UNSUPPORTED~;
            }
    }
}

fn usz? contact_pass(
    PhysicsWorld* world,
    ClothState* state,
    Vec3[] positions,
    bool apply,
) @private {
    ClothContactResult* result = &state.contact_result;
    result.stage = ClothContactStage.CANDIDATES;
    usz candidates = physics::gather_cloth_candidates(world, state, positions)!;
    candidates = gather_self_candidates(state, positions, candidates)!;

    result.stage = ClothContactStage.CONTACTS;
    result.max_residual = 0;
    result.unresolved = 0;
    result.pinned_overlaps = 0;

    usz count;
    defer {
        result.contacts += (uint)count;
        result.peak_contacts = math::max(result.peak_contacts, (uint)count);
    }

    foreach (index, &candidate : state.candidates[:candidates]) {
        if (candidate.kind == SELF_VERTEX_FACE || candidate.kind == SELF_EDGE_EDGE) {
            double residual = self_contact_residual(state, candidate, positions)!;
            result.max_residual = math::max(result.max_residual, residual);
            if (residual <= state.desc.collisions.contact_tolerance) continue;
            result.unresolved++;
            if (count == state.contacts.len) return c3d::CAPACITY_EXCEEDED~;
            state.contacts[count++] = { .candidate = (uint)index };
            continue;
        }

        bool pinned = state.inverse_masses[candidate.particle] == 0;
        ContactProjection projection = evaluate_contact(
            world: world,
            state: state,
            candidate: candidate,
            position: positions[candidate.particle],
            correct: apply && !pinned,
        )!;
        if (pinned) {
            if (projection.residual > state.desc.collisions.contact_tolerance) result.pinned_overlaps++;
            continue;
        }

        result.max_residual = math::max(result.max_residual, projection.residual);
        if (projection.residual <= state.desc.collisions.contact_tolerance) continue;

        result.unresolved++;
        if (count == state.contacts.len) return c3d::CAPACITY_EXCEEDED~;
        state.contacts[count++] = {
            .candidate = (uint)index,
            .original = positions[candidate.particle],
            .corrected = projection.corrected,
        };
    }
    if (!apply) return count;

    if (state.desc.collisions.continuous) state.sweep_start[..] = positions[..];
    foreach (&contact : state.contacts[:count]) {
        ClothCandidate* candidate = &state.candidates[contact.candidate];
        if (candidate.kind == SELF_VERTEX_FACE || candidate.kind == SELF_EDGE_EDGE) {
            apply_self_contact(state, candidate, positions)!;
            continue;
        }
        Vec3* position = &positions[candidate.particle];
        if (*position == contact.original) {
            *position = contact.corrected;
        } else {
            *position = evaluate_contact(world: world, state: state, candidate: candidate, position: *position, correct: true)!.corrected;
        }
    }
    if (count) {
        filter_displacement(
            world: world,
            state: state,
            start: state.sweep_start,
            proposed: positions,
            begin: state.sweep_end,
            end: state.sweep_end,
        )!;
    }
    return count;
}

fn void? resolve_contacts(PhysicsWorld* world, ClothState* state, Vec3[] positions) @private {
    for (uint iteration = 0; iteration < state.desc.collisions.contact_iterations; iteration++) {
        if (contact_pass(world: world, state: state, positions: positions, apply: true)! == 0) return;
    }
    if (contact_pass(world: world, state: state, positions: positions, apply: false)! == 0) return;
    state.contact_result.stage = ClothContactStage.RESOLVE;
    return CONTACT_UNRESOLVED~;
}
