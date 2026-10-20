module c3d::render::cloth_gpu @feat(C3D_PHYSICS_GPU);

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics::cloth @public;
import c3d::render;
import c3d::scene;
import std::math;

const float REACH_FACTOR @private = 1; // rest diagonals the bounds grow by; the pins hold the sheet, so a pinless cloth that falls further leaves the box
const uint FIRST_COLOR_BIT @private = 0; // bit of a particle's mark: it is on an edge of the first color; mirrored by member_bit
const uint LAST_COLOR_BIT @private = 1; // bit of a particle's mark: it is on an edge of the last color

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

$assert EdgeGpu::size == 16;

<*
 Byte offsets of one cloth's tables from the start of its range, and the range's length.
*>
struct ClothTables {
    usz initial;      // vec4 per particle: world position at the first step, inverse mass
    usz rest;         // vec4 per particle: node-local rest position, inverse mass
    usz edges;        // EdgeGpu per edge, ordered by color
    usz marks;        // uint per particle: FIRST_COLOR_BIT and LAST_COLOR_BIT set
    usz color_starts; // uint per color plus one
    usz adjacency;    // uint offsets per particle plus one, then the incident triangle numbers
    usz triangles;    // three vertex indices per triangle
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
    ClothSlot claimed = {
        .cloth          = entity,
        .geometry       = state.geometry,
        .particle_count = particle_count,
        .tables         = plan_tables(
            particles: particle_count,
            edges:     state.edges.len,
            colors:    state.edge_colors,
            corners:   indices.len,
        ),
        .shape          = step_shape(particle_count),
    };
    claimed.first_particle = (uint)find_gap(cloths, ClothArena.PARTICLES, particle_count, budget.max_particles)!;
    claimed.tables_offset = find_gap(cloths, ClothArena.TABLES, claimed.tables.total, budget.table_bytes)!;
    renderer.upload_geometry(state.geometry)!;

    char[] block = cloths.tables_cpu[claimed.tables_offset:claimed.tables.total];
    claimed.bounds = write_tables(
        block:   block,
        tables:  &claimed.tables,
        state:   state,
        indices: indices,
    );
    *free_slot = claimed;
    cloths.tables_dirty = true;
    return free_slot;
}

fn ClothTables plan_tables(uint particles, usz edges, uint colors, usz corners) @private {
    ClothTables tables;
    usz cursor;
    tables.initial = place(&cursor, particles * Vec4::size);
    tables.rest = place(&cursor, particles * Vec4::size);
    tables.edges = place(&cursor, edges * EdgeGpu::size);
    tables.marks = place(&cursor, particles * uint::size);
    tables.color_starts = place(&cursor, ((usz)colors + 1) * uint::size);
    tables.adjacency = place(&cursor, ((usz)particles + 1 + corners) * uint::size);
    tables.triangles = place(&cursor, corners * uint::size);
    tables.total = cursor;
    return tables;
}

fn usz place(usz* cursor, usz bytes) @private {
    usz offset = *cursor;
    *cursor = (offset + bytes + render::STREAM_ALIGNMENT - 1) / render::STREAM_ALIGNMENT * render::STREAM_ALIGNMENT;
    return offset;
}

// Fills the cloth's range of the CPU block and returns the node-local bounds of its output.
fn Aabb write_tables(char[] block, ClothTables* tables, ClothState* state, uint[] indices) @private {
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

    EdgeGpu[] edges = ((EdgeGpu*)&block[tables.edges])[:state.edges.len];
    foreach (index, edge : state.edges) {
        edges[index] = { .first = edge.first, .second = edge.second, .rest_length = edge.rest_length };
    }

    uint colors = state.edge_colors;
    uint[] starts = ((uint*)&block[tables.color_starts])[:colors + 1];
    starts[..] = state.edge_color_starts[:colors + 1];
    uint[] marks = ((uint*)&block[tables.marks])[:particles];
    marks[..] = 0;
    mark_color(marks, state.edges[starts[0]:starts[1] - starts[0]], 1u << FIRST_COLOR_BIT);
    mark_color(marks, state.edges[starts[colors - 1]:starts[colors] - starts[colors - 1]], 1u << LAST_COLOR_BIT);

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
    return { .min = low - margin, .max = high + margin };
}

fn void mark_color(uint[] marks, ClothConstraint[] color_edges, uint mark) @private {
    foreach (edge : color_edges) {
        marks[edge.first] |= mark;
        marks[edge.second] |= mark;
    }
}
