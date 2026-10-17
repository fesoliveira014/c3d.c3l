module c3d_physics_cloth_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::physics @public;
import c3d::physics::cloth @public;
import c3d::scene;
import std::math;
import std::math::vector;

alias SelfVector @private = double[<3>];

const float SELF_INITIAL_GAP @private = 0.005f;

fn GeometryId add_folded_strip(Fixture* fixture, bool duplicate_seam = false, bool coincident_layer = false) @private {
    Vec3[18] positions;
    positions[:12] = ((Vec3[12]){
        { -1, 0, -1 }, { 1, 0, -1 },
        { -1, 0, 1 }, { 1, 0, 1 },
        { -1, 0, 3 }, { 1, 0, 3 },
        { -1, 1, 4 }, { 1, 1, 4 },
        { -0.6f, SELF_INITIAL_GAP, 1.2f }, { 1.4f, SELF_INITIAL_GAP, 1.2f },
        { -0.6f, SELF_INITIAL_GAP, -0.8f }, { 1.4f, SELF_INITIAL_GAP, -0.8f },
    })[..];
    uint[33] indices;
    for (uint row = 0; row < 5; row++) {
        uint first = 2 * row;
        indices[6 * row:6] = ((uint[6]){ first, first + 2, first + 1, first + 1, first + 2, first + 3 })[..];
    }
    uint vertices = 12;
    uint corners = 30;
    if (duplicate_seam) {
        positions[12] = positions[4];
        positions[13] = positions[5];
        positions[14] = positions[4];
        vertices = 15;
        for (uint index = 12; index < 30; index++) {
            if (indices[index] == 4) indices[index] = 12;
            if (indices[index] == 5) indices[index] = 13;
        }
    }
    if (coincident_layer) {
        positions[15] = positions[0];
        positions[16] = positions[2];
        positions[17] = positions[1];
        indices[30:3] = ((uint[3]){ 15, 16, 17 })[..];
        vertices = 18;
        corners = 33;
    }
    Geometry geometry = { .positions = positions[:vertices], .indices = indices[:corners] };
    geometry.finalize();
    return fixture.assets.add_geometry(&geometry)!!;
}

fn ClothDesc folded_desc(bool self_collision = true) @private {
    ClothDesc desc = cloth::default_cloth_desc();
    desc.collisions.self_collision = self_collision;
    desc.collisions.max_shapes = 1;
    return desc;
}

fn void check_folded_contacts(ClothState* state, bool interior = true) @private {
    // The retained vertex projects inside lower triangle (0, 2, 1).
    SelfVector first = (SelfVector)state.published[0];
    SelfVector edge = (SelfVector)state.published[2] - first;
    SelfVector other = (SelfVector)state.published[1] - first;
    SelfVector relative = (SelfVector)state.published[10] - first;
    SelfVector normal = edge.cross(other);
    double distance = math::abs(relative.dot(normal)) / normal.length();
    double edge_squared = edge.dot(edge);
    double mixed = edge.dot(other);
    double other_squared = other.dot(other);
    double denominator = edge_squared * other_squared - mixed * mixed;
    double along = (other_squared * relative.dot(edge) - mixed * relative.dot(other)) / denominator;
    double across = (edge_squared * relative.dot(other) - mixed * relative.dot(edge)) / denominator;
    if (interior) assert(along > 0 && across > 0 && along + across < 1);
    assert(distance >= 2.0 * state.desc.thickness - state.desc.collisions.contact_tolerance);

    // Lower diagonal (1, 2) crosses upper edge (10, 11) in projection.
    SelfVector first_start = (SelfVector)state.published[1];
    SelfVector first_edge = (SelfVector)state.published[2] - first_start;
    SelfVector second_start = (SelfVector)state.published[10];
    SelfVector second_edge = (SelfVector)state.published[11] - second_start;
    SelfVector offset = first_start - second_start;
    double first_squared = first_edge.dot(first_edge);
    double edge_mixed = first_edge.dot(second_edge);
    double second_squared = second_edge.dot(second_edge);
    double first_offset = first_edge.dot(offset);
    double second_offset = second_edge.dot(offset);
    double first_along = (edge_mixed * second_offset - second_squared * first_offset) / (first_squared * second_squared - edge_mixed * edge_mixed);
    double second_along = (first_squared * second_offset - edge_mixed * first_offset) / (first_squared * second_squared - edge_mixed * edge_mixed);
    if (interior) assert(first_along > 0 && first_along < 1 && second_along > 0 && second_along < 1);
    SelfVector closest = offset + first_edge * first_along - second_edge * second_along;
    assert(closest.length() >= 2.0 * state.desc.thickness - state.desc.collisions.contact_tolerance);
}

fn void test_cloth_self_folded_vertex_face_and_edge_edge() @test {
    foreach (enabled : (bool[2]){ false, true }) {
        Fixture fixture;
        setup(&fixture, desc: weightless());
        defer teardown(&fixture);
        GeometryId source = add_folded_strip(&fixture);
        Node* node = add_cloth_node(&fixture, source);
        uint[2] pins = { 6, 7 };
        ClothDesc desc = folded_desc(enabled);
        desc.pins = pins[..];
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
        ClothState* state = state_of(&fixture, node);

        publish(&fixture);
        assert(!state.contact_result.failure);
        if (enabled) {
            assert(state.published[0].y < 0 && state.published[10].y > SELF_INITIAL_GAP);
            check_folded_contacts(state);
        } else {
            assert(state.published[0].y == 0 && state.published[10].y == SELF_INITIAL_GAP);
        }

        for (uint update = 0; update < 8; update++) {
            step(&fixture, physics::DEFAULT_FIXED_DT);
        }
        ClothContactResult result = state.contact_result;
        assert(!result.failure && result.max_residual <= desc.collisions.contact_tolerance);
        if (enabled) check_folded_contacts(state);
        foreach (pin : pins) assert(state.published[pin] == fixture.assets.geometry(source).data.positions[pin]);
    }
}

fn bool retained_self_pair(ClothState* state, uint vertex, uint face) @private {
    state.contact_result = {};
    usz count = cloth::gather_self_candidates(state, state.positions, 0)!!;
    foreach (candidate : state.candidates[:count]) {
        if (candidate.kind == SELF_VERTEX_FACE && candidate.self_pair == (uint[2]){ vertex, face }) return true;
    }
    return false;
}

fn void test_cloth_self_explicit_seam_topology_and_unrelated_coincidence() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    GeometryId source = add_folded_strip(&fixture, true, true);
    Node* node = add_cloth_node(&fixture, source);
    ClothSeam[5] seams = {
        { .first = 4, .second = 12 }, { .first = 12, .second = 14 },
        { .first = 5, .second = 13 }, { .first = 12, .second = 4 }, { .first = 5, .second = 5 },
    };
    ClothDesc desc = folded_desc();
    desc.seams = seams[..];
    desc.collisions.contact_iterations = 16;
    uint[2] pins = { 6, 7 };
    desc.pins = pins[..];
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    ClothState* state = state_of(&fixture, node);

    seams[0].first = 0;
    assert(fixture.scene.get(node, Cloth).authoring.desc.seams[0].first == 4);
    assert(state.canonical_vertices[4] == state.canonical_vertices[12]);
    assert(state.canonical_vertices[4] == state.canonical_vertices[14]);
    assert(!retained_self_pair(state, 12, 2));
    assert(!retained_self_pair(state, 14, 2));
    assert(!retained_self_pair(state, 12, 0)); // one source-edge ring through vertex 2
    assert(retained_self_pair(state, 15, 0)); // unrelated coincident layer
    assert(retained_self_pair(state, 10, 0)); // remote folded region stays eligible

    publish(&fixture);
    assert(!state.contact_result.failure && state.contact_result.contacts > 0);
    assert(state.published[15] != state.published[0]);

    Node* unseamed = add_cloth_node(&fixture, source);
    ClothDesc plain = folded_desc();
    fixture.scene.add_cloth(&fixture.assets, unseamed, plain)!!;
    ClothState* separate = state_of(&fixture, unseamed);
    assert(retained_self_pair(separate, 12, 2));
    assert(retained_self_pair(separate, 14, 2));

    Node* invalid = add_cloth_node(&fixture, source);
    ClothSeam bad = { .first = 0, .second = 18 };
    plain.seams = (&bad)[:1];
    assert(rejected_atomically(&fixture, invalid, plain) == c3d::INVALID_ARGUMENT);
}

fn void test_cloth_self_pinned_conflict_and_collapsed_feature_rollback() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    GeometryId source = add_folded_strip(&fixture);
    Node* node = add_cloth_node(&fixture, source);

    uint[12] pins;
    foreach (index, &pin : pins) *pin = (uint)index;
    ClothDesc desc = folded_desc();
    desc.pins = pins[..];
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    ClothState* state = state_of(&fixture, node);
    uint revision = geometry_of(&fixture, node).header.revision;
    publish(&fixture);
    assert(state.contact_result.failure == cloth::CONTACT_UNRESOLVED);
    assert(state.contact_result.stage == ClothContactStage.RESOLVE);
    assert(geometry_of(&fixture, node).header.revision == revision);

    fixture.scene.remove_cloth(node);
    desc.pins = {};
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    state = state_of(&fixture, node);
    // Valid source; a later motion collapses the lower face onto the remote vertex.
    state.positions[0] = state.positions[10];
    state.positions[1] = state.positions[10];
    state.positions[2] = state.positions[10];
    Vec3[12] solved;
    solved[..] = state.positions[..];
    revision = geometry_of(&fixture, node).header.revision;
    step(&fixture, physics::DEFAULT_FIXED_DT);
    assert(state.contact_result.failure == cloth::CONTACT_PRECISION_EXCEEDED);
    assert(geometry_of(&fixture, node).header.revision == revision);
    foreach (index, position : solved) assert(state.positions[index] == position && state.velocities[index] == (Vec3){});
}

