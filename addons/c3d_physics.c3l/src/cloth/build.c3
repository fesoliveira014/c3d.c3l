module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::physics @public;
import c3d::scene;
import std::math;
import std::sort;

const float MIN_TRIANGLE_AREA @private = 1e-12f; // square metres; a smaller triangle has no stable normal
const Vec3 COLLAPSED_AXIS @private = { 0, 1, 0 }; // separates a constraint whose rest length is zero

struct ClothTopology @private {
    ClothConstraint[] edges;
    ClothConstraint[] bends;
}

struct ClothCounts @local {
    uint vertices;
    uint pins;
    uint edges;
    uint bends;
    uint bodies;
    uint shapes;
}

struct EdgeRecord @local {
    uint low;
    uint high;
    uint opposite;
}

fn void? check_cloth_desc(ClothDesc desc) @private {
    if (!desc.substeps || !desc.iterations) return c3d::INVALID_ARGUMENT~;
    if (!unit_interval(desc.stretch_stiffness) || !unit_interval(desc.bend_stiffness)) return c3d::INVALID_ARGUMENT~;
    if (!(desc.damping >= 0) || !math::is_finite(desc.damping)) return c3d::INVALID_ARGUMENT~;
    if (!(desc.thickness >= 0) || !math::is_finite(desc.thickness)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(desc.gravity_scale) || !math::is_finite(desc.ground_height)) return c3d::INVALID_ARGUMENT~;
}

fn void? check_cloth_source(Scene* scene, Node* node, scene::Mesh* mesh, GeometryAsset* source) @private {
    if (scene.has(node, SkinBinding) || mesh.morph_weights.len || mesh.has_bounds_override) return c3d::UNSUPPORTED~;
    Geometry* data = &source.data;
    if (!data.positions.len) return physics::SOURCE_UNAVAILABLE~;
    if (data.targets.len || data.joints.len || data.custom_data.len) return c3d::UNSUPPORTED~;
    if (data.topology != Topology.TRIANGLES || !data.indices.len) return c3d::UNSUPPORTED~;
    if (data.indices.len % 3) return c3d::INVALID_ARGUMENT~;
    foreach (index : data.indices) {
        if (index >= data.positions.len) return c3d::INVALID_ARGUMENT~;
    }
    foreach (position : data.positions) {
        if (!finite_vector(position)) return c3d::INVALID_ARGUMENT~;
    }
}

fn uint[]? unique_pins(uint[] requested, uint vertex_count) @private {
    uint[] pins = alloc::new_array(tmem, uint, (sz)requested.len);
    pins[..] = requested[..];
    sort::quicksort(pins);
    usz count;
    foreach (pin : pins) {
        if (pin >= vertex_count) return c3d::INVALID_ARGUMENT~;
        if (count && pins[count - 1] == pin) continue;
        pins[count++] = pin;
    }
    return pins[:count];
}

fn void? check_world_positions(Vec3[] world) @private {
    foreach (position : world) {
        if (!finite_vector(position)) return c3d::INVALID_ARGUMENT~;
    }
}

fn ClothTopology? build_topology(Geometry* data, Vec3[] world) @private {
    usz triangle_count = data.indices.len / 3;
    EdgeRecord[] records = alloc::new_array(tmem, EdgeRecord, (sz)(triangle_count * 3));
    for (usz triangle = 0; triangle < triangle_count; triangle++) {
        uint[3] corners = { data.indices[3 * triangle], data.indices[3 * triangle + 1], data.indices[3 * triangle + 2] };
        Vec3 normal = (world[corners[1]] - world[corners[0]]).cross(world[corners[2]] - world[corners[0]]);
        if (normal.length() * 0.5f <= MIN_TRIANGLE_AREA) return c3d::INVALID_ARGUMENT~;
        for (uint side = 0; side < 3; side++) {
            uint first = corners[side];
            uint second = corners[(side + 1) % 3];
            records[3 * triangle + side] = {
                .low      = math::min(first, second),
                .high     = math::max(first, second),
                .opposite = corners[(side + 2) % 3],
            };
        }
    }
    sort::quicksort(records, &by_edge);

    usz edge_count;
    usz bend_count;
    for (usz start = 0; start < records.len;) {
        usz end = start + 1;
        while (end < records.len && same_edge(records[start], records[end])) end++;
        if (end - start > 2) return c3d::INVALID_ARGUMENT~;
        if (end - start == 2 && records[start].opposite == records[start + 1].opposite) return c3d::INVALID_ARGUMENT~;
        edge_count++;
        if (end - start == 2) bend_count++;
        start = end;
    }
    ClothTopology topology = {
        .edges = alloc::new_array(tmem, ClothConstraint, (sz)edge_count),
        .bends = alloc::new_array(tmem, ClothConstraint, (sz)bend_count),
    };
    usz edge;
    usz bend;
    for (usz start = 0; start < records.len;) {
        usz end = start + 1;
        while (end < records.len && same_edge(records[start], records[end])) end++;
        topology.edges[edge++] = rest_constraint(world, records[start].low, records[start].high);
        if (end - start == 2) {
            topology.bends[bend++] = rest_constraint(world, records[start].opposite, records[start + 1].opposite);
        }
        start = end;
    }
    return topology;
}

fn GeometryId? copy_cloth_geometry(AssetStore* assets, Geometry* source) @private {
    Geometry copy = {
        .topology  = Topology.TRIANGLES,
        .positions = source.positions,
        .uv0       = source.uv0,
        .uv1       = source.uv1,
        .colors    = source.colors,
        .indices   = source.indices,
        .bounds    = source.bounds,
    };
    copy.compute_normals(tmem);
    return assets.add_geometry(&copy);
}

fn ClothState*? allocate_cloth_state(
    Allocator allocator,
    uint vertex_count,
    uint pin_count,
    uint edge_count,
    uint bend_count,
    uint body_count,
    uint shape_count,
) @private {
    ClothCounts counts = {
        .vertices = vertex_count,
        .pins     = pin_count,
        .edges    = edge_count,
        .bends    = bend_count,
        .bodies   = body_count,
        .shapes   = shape_count,
    };
    BlockCursor measure;
    carve_cloth_state(&measure, counts);
    char*? allocation = alloc::malloc_try(allocator, (sz)measure.offset);
    if (catch allocation) return c3d::CAPACITY_EXCEEDED~;
    BlockCursor fill = { .base = allocation };
    return carve_cloth_state(&fill, counts);
}

fn ClothState* carve_cloth_state(BlockCursor* cursor, ClothCounts counts) @local {
    ClothState[] states = physics::carve(cursor, ClothState, 1);
    ClothState state = {
        .rest           = physics::carve(cursor, Vec3, counts.vertices),
        .positions      = physics::carve(cursor, Vec3, counts.vertices),
        .velocities     = physics::carve(cursor, Vec3, counts.vertices),
        .predicted      = physics::carve(cursor, Vec3, counts.vertices),
        .accelerations  = physics::carve(cursor, Vec3, counts.vertices),
        .published      = physics::carve(cursor, Vec3, counts.vertices),
        .inverse_masses = physics::carve(cursor, float, counts.vertices),
        .pins           = physics::carve(cursor, uint, counts.pins),
        .pin_anchors    = physics::carve(cursor, Vec3, counts.pins),
        .pin_targets    = physics::carve(cursor, Vec3, counts.pins),
        .edges          = physics::carve(cursor, ClothConstraint, counts.edges),
        .bends          = physics::carve(cursor, ClothConstraint, counts.bends),
        .colliders      = physics::carve(cursor, Entity, counts.bodies),
        .bodies         = physics::carve(cursor, ClothBody, counts.bodies),
        .shapes         = physics::carve(cursor, ClothShape, counts.shapes),
        .shape_starts   = physics::carve(cursor, Vec3, counts.shapes),
        .shape_ends     = physics::carve(cursor, Vec3, counts.shapes),
    };
    if (!cursor.base) return null;
    states[0] = state;
    states[0].velocities[..] = (Vec3){};
    return states.ptr;
}

fn ClothConstraint rest_constraint(Vec3[] world, uint first, uint second) @local {
    Vec3 delta = world[second] - world[first];
    float length = delta.length();
    return {
        .first          = first,
        .second         = second,
        .rest_length    = length,
        .rest_direction = length > 0 ? delta / length : COLLAPSED_AXIS,
    };
}

fn bool same_edge(EdgeRecord first, EdgeRecord second) @local => first.low == second.low && first.high == second.high;

fn int by_edge(EdgeRecord first, EdgeRecord second) @local {
    if (first.low != second.low) return first.low < second.low ? -1 : 1;
    if (first.high != second.high) return first.high < second.high ? -1 : 1;
    return 0;
}

fn bool unit_interval(float value) @local => value >= 0 && value <= 1;

fn bool finite_vector(Vec3 value) @private => math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
