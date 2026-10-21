module c3d::render::cloth_gpu @feat(C3D_PHYSICS_GPU);

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics::cloth @public;
import c3d::render;
import c3d::scene;
import std::math;

const float REACH_FACTOR @private = 1; // rest diagonals the bounds grow by; the pins hold the sheet, so a pinless cloth that falls further leaves the box
const uint FIRST_COLOR_BIT @private = 0; // bit of a particle's mark: it is on a constraint of the first pass; mirrored by member_bit
const uint LAST_COLOR_BIT @private = 1; // bit of a particle's mark: it is on a constraint of the last pass
const uint FEATURE_SOFT @private = 1; // mirrored in cloth_root.glsl
const uint FEATURE_TRANSPORT @private = 2; // mirrored in cloth_root.glsl
const uint FEATURE_REFERENCE @private = 4; // mirrored in cloth_root.glsl
const uint FEATURE_WIND @private = 8; // mirrored in cloth_root.glsl
const uint FEATURE_SHAPES @private = 16; // mirrored in cloth_root.glsl

enum ClothArena @private {
    PARTICLES, // slots of the positions and work buffers
    TABLES,    // bytes of the tables buffer
}

struct EdgeGpu @private {
    uint  first;
    uint  second;
    float rest_length;
    uint  _pad0;
}

struct DirectionGpu @private {
    float[3] direction;
    uint     _pad0;
}

$assert EdgeGpu::size == 16;
$assert DirectionGpu::size == 16;

<*
 Byte offsets of one cloth's tables from the start of its range, and the range's length.
*>
struct ClothTables {
    usz initial;      // vec4 per particle: world position at the first step, inverse mass
    usz rest;         // vec4 per particle: node-local rest position, inverse mass
    usz constraints;  // EdgeGpu per edge, ordered by color, then per bend, ordered by color; then a DirectionGpu for each
    usz marks;        // uint per particle: FIRST_COLOR_BIT and LAST_COLOR_BIT set
    usz color_starts; // uint per pass plus one: first constraint of each pass
    usz adjacency;    // uint offsets per particle plus one, then the incident triangle numbers
    usz triangles;    // three vertex indices per triangle
    usz soft;         // float per particle: effective compliance, zero off the soft attachments
    usz transport;    // float per particle: the share of the owner's motion the particle follows
    usz limits;       // float per particle: metres contact may push it within one substep
    usz total;
}

<*
 Ranges, step shape and replay state of one packed cloth.
*>
struct ClothSlot {
    Entity         cloth;          // a zero generation marks a free slot
    GeometryId     geometry;       // the output copy the tables were built for
    uint           stamp;          // the update that last saw the cloth
    uint           first_particle; // in the positions and work buffers
    uint           particle_count;
    usz            tables_offset;  // in the tables buffer
    ClothTables    tables;
    ClothStepShape shape;
    uint           passes;         // color passes of one iteration: the edge colors, then the bend colors
    uint           edge_colors;
    uint           features;       // FEATURE_* bits the cloth keeps for its life
    Aabb           bounds;         // node-local; the geometry write's bounds
    bool           started;        // a step is recorded and not known lost
    bool           pending;        // the frame of that first step is not yet known submitted
    ulong          first_frame;
}

fn usz slot_start(ClothSlot* slot, ClothArena arena) @private {
    return arena == ClothArena.PARTICLES ? slot.first_particle : slot.tables_offset;
}

fn usz slot_length(ClothSlot* slot, ClothArena arena) @private {
    return arena == ClothArena.PARTICLES ? slot.particle_count : slot.tables.total;
}

// A frame that was not submitted lost the first step, so the next step initializes the cloth again.
fn void settle_slot(ClothSlot* slot, Renderer* renderer) @private {
    if (!slot.pending) return;

    bool landed = renderer.frame_was_submitted(slot.first_frame)
        || renderer.frame_index - slot.first_frame > render::FRAMES_IN_FLIGHT;
    slot.pending = false;
    if (!landed) slot.started = false;
}

fn usz slot_index(GpuCloths* cloths, ClothSlot* slot) @private {
    return (usz)(slot - cloths.slots.ptr);
}

fn ClothSlot* find_slot(GpuCloths* cloths, Entity cloth) @private {
    foreach (&slot : cloths.slots) {
        if (slot.cloth.generation && c3d::same_id(slot.cloth, cloth)) return slot;
    }
    return null;
}

<*
 Bytes of the tables buffer the packed cloths reach.
 @pure
*>
fn usz GpuCloths.tables_used(&self) {
    usz used;
    foreach (&slot : self.slots) {
        if (slot.cloth.generation) used = math::max(used, slot.tables_offset + slot.tables.total);
    }
    return used;
}

<*
 Bytes of device memory the context's three buffers take once created.
*>
fn usz GpuCloths.device_bytes(&self) {
    usz vectors = (usz)self.desc.max_particles * Vec4::size;
    return vectors + WORK_SECTIONS * vectors + shape_bytes(self.desc.max_cloths) + self.desc.table_bytes;
}

fn usz shape_bytes(uint max_cloths) @private {
    return (usz)max_cloths * (PLACED_OFFSET + cloth::MAX_DEVICE_SHAPES * PLACED_BYTES);
}

<*
 Particle slots the packed cloths reach.
 @pure
*>
fn usz GpuCloths.particles_used(&self) {
    usz used;
    foreach (&slot : self.slots) {
        if (slot.cloth.generation) used = math::max(used, (usz)slot.first_particle + slot.particle_count);
    }
    return used;
}

// A range starts at zero or where another ends, so the lowest start that fits is among those.
fn usz? find_gap(GpuCloths* cloths, ClothArena arena, usz size, usz capacity) @private {
    usz best = usz::max;
    if (size <= capacity && range_is_free(cloths.slots, arena, 0, size)) best = 0;
    foreach (&ended : cloths.slots) {
        if (!ended.cloth.generation) continue;

        usz candidate = slot_start(ended, arena) + slot_length(ended, arena);
        if (candidate < best && candidate + size <= capacity && range_is_free(cloths.slots, arena, candidate, size)) {
            best = candidate;
        }
    }
    if (best == usz::max) return c3d::CAPACITY_EXCEEDED~;

    return best;
}

fn bool range_is_free(ClothSlot[] slots, ClothArena arena, usz start, usz size) @private {
    foreach (&slot : slots) {
        if (!slot.cloth.generation) continue;

        usz begin = slot_start(slot, arena);
        if (start < begin + slot_length(slot, arena) && begin < start + size) return false;
    }
    return true;
}

fn void retire_unseen(GpuCloths* cloths) @private {
    foreach (&slot : cloths.slots) {
        if (slot.cloth.generation && slot.stamp != cloths.stamp) *slot = {};
    }
}

// A cloth prepared again over a new output copy gives up its ranges and is packed anew.
fn void keep_cloth(GpuCloths* cloths, Scene* scene, Entity entity) @private {
    ClothSlot* slot = find_slot(cloths, entity);
    if (!slot) return;

    ClothState* state = scene.get(scene.node(entity), Cloth).state;
    if (c3d::same_id(slot.geometry, state.geometry)) {
        slot.stamp = cloths.stamp;
    } else {
        *slot = {};
    }
}

fn void? admit_cloth(
    GpuCloths* cloths,
    Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    Entity entity,
) @private {
    if (find_slot(cloths, entity)) return;

    ClothState* state = scene.get(scene.node(entity), Cloth).state;
    ClothSlot* slot = claim_slot(
        cloths:   cloths,
        renderer: renderer,
        assets:   assets,
        state:    state,
        entity:   entity,
    )!;
    slot.stamp = cloths.stamp;
}

fn ClothSlot*? claim_slot(
    GpuCloths* cloths,
    Renderer* renderer,
    AssetStore* assets,
    ClothState* state,
    Entity entity,
) @private {
    ClothSlot* free_slot;
    foreach (&slot : cloths.slots) {
        if (!slot.cloth.generation) {
            free_slot = slot;
            break;
        }
    }
    if (!free_slot) return c3d::CAPACITY_EXCEEDED~;

    uint[] indices = assets.geometry(state.geometry).data.indices;
    GpuClothsDesc* budget = &cloths.desc;
    uint particle_count = (uint)state.positions.len;
    uint bend_colors = bend_passes(state);
    uint features = cloth_features(state);
    ClothSlot claimed = {
        .cloth          = entity,
        .geometry       = state.geometry,
        .particle_count = particle_count,
        .tables         = plan_tables(
            particles:   particle_count,
            constraints: state.edges.len + (bend_colors ? state.bends.len : 0),
            passes:      state.edge_colors + bend_colors,
            corners:     indices.len,
            features:    features,
        ),
        .shape          = step_shape(particle_count),
        .passes         = state.edge_colors + bend_colors,
        .edge_colors    = state.edge_colors,
        .features       = features,
    };
    claimed.first_particle = (uint)find_gap(cloths, ClothArena.PARTICLES, particle_count, budget.max_particles)!;
    claimed.tables_offset = find_gap(cloths, ClothArena.TABLES, claimed.tables.total, budget.table_bytes)!;
    renderer.upload_geometry(state.geometry)!;

    char[] block = cloths.tables_cpu[claimed.tables_offset:claimed.tables.total];
    claimed.bounds = write_tables(
        block:    block,
        tables:   &claimed.tables,
        state:    state,
        indices:  indices,
        features: features,
    );
    *free_slot = claimed;
    cloths.tables_dirty = true;
    return free_slot;
}

// Bends are projected only at a stiffness that moves a particle.
fn uint bend_passes(ClothState* state) @private {
    return state.desc.bend_stiffness != 0 ? state.bend_colors : 0;
}

// A lean stage has no soft attachment, transport, reference or wind code; shape contact stays in it.
fn bool lean_features(uint features) @private => (features & ~FEATURE_SHAPES) == 0;

fn uint cloth_features(ClothState* state) @private {
    uint features;
    if (state.soft_attachments.len) features |= FEATURE_SOFT;
    if (state.skinned) features |= FEATURE_REFERENCE;
    if (state.bodies.len) features |= FEATURE_SHAPES;
    foreach (weight : state.transport) {
        if (weight != 0) {
            features |= FEATURE_TRANSPORT;
            break;
        }
    }
    return features;
}

fn ClothTables plan_tables(uint particles, usz constraints, uint passes, usz corners, uint features) @private {
    ClothTables tables;
    usz cursor;
    tables.initial = place(&cursor, particles * Vec4::size);
    tables.rest = place(&cursor, particles * Vec4::size);
    tables.constraints = place(&cursor, constraints * (EdgeGpu::size + DirectionGpu::size));
    tables.marks = place(&cursor, particles * uint::size);
    tables.color_starts = place(&cursor, ((usz)passes + 1) * uint::size);
    tables.adjacency = place(&cursor, ((usz)particles + 1 + corners) * uint::size);
    tables.triangles = place(&cursor, corners * uint::size);
    tables.soft = place(&cursor, (features & FEATURE_SOFT) != 0 ? particles * float::size : 0);
    tables.transport = place(&cursor, (features & FEATURE_TRANSPORT) != 0 ? particles * float::size : 0);
    tables.limits = place(&cursor, (features & FEATURE_SHAPES) != 0 ? particles * float::size : 0);
    tables.total = cursor;
    return tables;
}

fn usz place(usz* cursor, usz bytes) @private {
    usz offset = *cursor;
    *cursor = (offset + bytes + render::STREAM_ALIGNMENT - 1) / render::STREAM_ALIGNMENT * render::STREAM_ALIGNMENT;
    return offset;
}

// Fills the cloth's range of the CPU block and returns the node-local bounds of its output.
fn Aabb write_tables(
    char[] block,
    ClothTables* tables,
    ClothState* state,
    uint[] indices,
    uint features,
) @private {
    uint particles = (uint)state.positions.len;
    Vec4[] initial = ((Vec4*)&block[tables.initial])[:particles];
    Vec4[] rest = ((Vec4*)&block[tables.rest])[:particles];
    Vec3 low = state.rest[0];
    Vec3 high = state.rest[0];
    foreach (index, position : state.positions) {
        float inverse_mass = state.inverse_masses[index];
        Vec3 local = state.rest[index];
        initial[index] = { position.x, position.y, position.z, inverse_mass };
        rest[index] = { local.x, local.y, local.z, inverse_mass };
        low = { math::min(low.x, local.x), math::min(low.y, local.y), math::min(low.z, local.z) };
        high = { math::max(high.x, local.x), math::max(high.y, local.y), math::max(high.z, local.z) };
    }
    float reach = REACH_FACTOR * (high - low).length();
    Vec3 margin = { reach, reach, reach };

    uint edge_colors = state.edge_colors;
    uint bend_colors = bend_passes(state);
    uint passes = edge_colors + bend_colors;
    usz edge_count = state.edges.len;
    usz bend_count = bend_colors ? state.bends.len : 0;
    usz constraint_count = edge_count + bend_count;
    EdgeGpu[] constraints = ((EdgeGpu*)&block[tables.constraints])[:constraint_count];
    DirectionGpu[] directions = ((DirectionGpu*)&block[tables.constraints + constraint_count * EdgeGpu::size])[:constraint_count];
    foreach (index, &edge : state.edges) {
        constraints[index] = constraint_record(edge);
        directions[index] = direction_record(edge);
    }
    foreach (index, &bend : state.bends[:bend_count]) {
        constraints[edge_count + (usz)index] = constraint_record(bend);
        directions[edge_count + (usz)index] = direction_record(bend);
    }

    uint[] starts = ((uint*)&block[tables.color_starts])[:passes + 1];
    starts[:edge_colors + 1] = state.edge_color_starts[:edge_colors + 1];
    for (uint color = 1; color <= bend_colors; color++) {
        starts[edge_colors + color] = (uint)edge_count + state.bend_color_starts[color];
    }
    uint[] marks = ((uint*)&block[tables.marks])[:particles];
    marks[..] = 0;
    mark_pass(marks, constraints[starts[0]:starts[1] - starts[0]], 1u << FIRST_COLOR_BIT);
    mark_pass(marks, constraints[starts[passes - 1]:starts[passes] - starts[passes - 1]], 1u << LAST_COLOR_BIT);

    // Offsets table, then the triangle numbers incident to each particle.
    uint[] adjacency = ((uint*)&block[tables.adjacency])[:(usz)particles + 1 + indices.len];
    adjacency[..] = 0;
    foreach (vertex : indices) adjacency[vertex + 1]++;
    for (usz particle = 0; particle < particles; particle++) adjacency[particle + 1] += adjacency[particle];
    @pool() {
        uint[] cursor = alloc::new_array(tmem, uint, particles);
        cursor[..] = adjacency[:particles];
        foreach (corner, vertex : indices) {
            adjacency[(usz)particles + 1 + cursor[vertex]++] = (uint)(corner / 3);
        }
    };
    uint[] triangles = ((uint*)&block[tables.triangles])[:indices.len];
    triangles[..] = indices[..];

    if ((features & FEATURE_SOFT) != 0) {
        float[] compliances = ((float*)&block[tables.soft])[:particles];
        compliances[..] = 0;
        foreach (attachment : state.soft_attachments) {
            compliances[attachment.particle] = attachment.effective_compliance;
        }
    }
    if ((features & FEATURE_TRANSPORT) != 0) {
        float[] weights = ((float*)&block[tables.transport])[:particles];
        weights[..] = state.transport[:particles];
    }
    if ((features & FEATURE_SHAPES) != 0) {
        float[] limits = ((float*)&block[tables.limits])[:particles];
        limits[..] = state.push_limits[:particles];
    }
    return { .min = low - margin, .max = high + margin };
}

fn EdgeGpu constraint_record(ClothConstraint* constraint) @private {
    return {
        .first       = constraint.first,
        .second      = constraint.second,
        .rest_length = constraint.rest_length,
    };
}

fn DirectionGpu direction_record(ClothConstraint* constraint) @private {
    Vec3 direction = constraint.rest_direction;
    return { .direction = { direction.x, direction.y, direction.z } };
}

fn void mark_pass(uint[] marks, EdgeGpu[] pass_constraints, uint mark) @private {
    foreach (constraint : pass_constraints) {
        marks[constraint.first] |= mark;
        marks[constraint.second] |= mark;
    }
}
