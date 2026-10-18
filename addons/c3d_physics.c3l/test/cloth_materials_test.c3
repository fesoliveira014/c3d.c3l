module c3d_physics_cloth_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;
import std::core::mem::allocators;
import std::math;

fn Geometry split_seam_quad(
    Allocator allocator,
    bool collapse_second_uv = false,
    bool use_uv1 = false,
) @local {
    Vec3[6] positions = {
        { 0, 0, 0 },
        { 1, 0, 0 },
        { 0, -1, 0 },
        { 1, 0, 0 },
        { 1, -1, 0.35f },
        { 0, -1, 0 },
    };
    Vec3 tilted = ((Vec3){ 0.2f, 0, 1.0f }).normalize();
    Vec3[6] normals = {
        { 0, 0, 1 },
        { 0, 0, 1 },
        { 0, 1, 0 },
        tilted,
        tilted,
        tilted,
    };
    Vec2[6] uvs = {
        { 0, 0 },
        { 1, 0 },
        { 0, 1 },
        { 1, 0 },
        collapse_second_uv ? (Vec2){ 1, 0 } : (Vec2){ 0, 0 },
        collapse_second_uv ? (Vec2){ 1, 0 } : (Vec2){ 1, 1 },
    };
    uint[6] indices = { 0, 2, 1, 3, 5, 4 };

    Geometry geometry = {
        .positions = alloc::new_array(allocator, Vec3, 6),
        .normals   = alloc::new_array(allocator, Vec3, 6),
        .indices   = alloc::new_array(allocator, uint, 6),
    };
    geometry.positions[..] = positions[..];
    geometry.normals[..] = normals[..];
    geometry.indices[..] = indices[..];

    if (use_uv1) {
        geometry.uv1 = alloc::new_array(allocator, Vec2, 6);
        geometry.uv1[..] = uvs[..];
    } else {
        geometry.uv0 = alloc::new_array(allocator, Vec2, 6);
        geometry.uv0[..] = uvs[..];
    }
    geometry.finalize();
    return geometry;
}

fn Geometry hinge_quad(Allocator allocator, float flap_z = 0, bool flip_second_winding = false) @local {
    Vec3[4] positions = {
        { -1, 0, flap_z },
        { 0, 1, 0 },
        { 0, -1, 0 },
        { 1, 0, flap_z },
    };
    uint[6] indices = flip_second_winding
      ? (uint[6]){ 1, 2, 0, 1, 2, 3 }
      : (uint[6]){ 1, 2, 0, 2, 1, 3 };
    Geometry geometry = {
        .positions = alloc::new_array(allocator, Vec3, 4),
        .indices   = alloc::new_array(allocator, uint, 6),
    };
    geometry.positions[..] = positions[..];
    geometry.indices[..] = indices[..];
    geometry.finalize();
    return geometry;
}

fn void test_cloth_material_splits_tangents_and_uv_fallback() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    GeometryId source_id;
    GeometryId uv1_id;
    GeometryId degenerate_uv_id;
    @pool() {
        Geometry source_geometry = split_seam_quad(tmem);
        source_id = fixture.assets.add_geometry(&source_geometry)!!;
        Geometry uv1_geometry = split_seam_quad(tmem, false, true);
        uv1_id = fixture.assets.add_geometry(&uv1_geometry)!!;
        Geometry degenerate_uv_geometry = split_seam_quad(tmem, true, false);
        degenerate_uv_id = fixture.assets.add_geometry(&degenerate_uv_geometry)!!;
    };

    uint[6] render_particles = { 0, 1, 2, 1, 3, 2 };
    uint[2] pins = { 0, 1 };
    ClothDesc desc = cloth::default_cloth_desc();
    desc.render_particles = render_particles[..];
    desc.pins = pins[..];
    desc.tangent_frame = true;

    Node* node = add_cloth_node(&fixture, source_id);
    uint free_before = fixture.assets.geometries.free_count;

    uint[5] short_map = { 0, 1, 2, 1, 2 };
    ClothDesc bad = desc;
    bad.render_particles = short_map[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, node, bad)) == c3d::INVALID_ARGUMENT);

    uint[6] non_dense_map = { 0, 1, 2, 1, 4, 2 };
    bad.render_particles = non_dense_map[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, node, bad)) == c3d::INVALID_ARGUMENT);

    uint[6] mismatch_pos_map = { 0, 0, 1, 2, 3, 1 };
    bad.render_particles = mismatch_pos_map[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, node, bad)) == c3d::INVALID_ARGUMENT);

    bad = desc;
    bad.tangent_uv_set = 1;
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, node, bad)) == c3d::INVALID_ARGUMENT);
    bad.tangent_uv_set = 2;
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, node, bad)) == c3d::INVALID_ARGUMENT);
    assert(fixture.assets.geometries.free_count == free_before);

    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    ClothState* state = state_of(&fixture, node);
    assert(state.rest.len == 4);
    assert(state.normal_accum.len == 6);

    for (uint step_index = 0; step_index < 6; step_index++) step(&fixture, physics::DEFAULT_FIXED_DT);

    Geometry* runtime = &fixture.assets.geometry(state.geometry).data;
    assert(runtime.tangents.len == runtime.positions.len);
    uint m1_first = state.corners[2].material_vertex;
    uint m1_second = state.corners[3].material_vertex;
    uint m2_first = state.corners[1].material_vertex;
    uint m2_second = state.corners[4].material_vertex;
    assert(runtime.positions[m1_first] == runtime.positions[m1_second]);
    assert(runtime.positions[m2_first] == runtime.positions[m2_second]);
    assert((runtime.normals[m1_first] - runtime.normals[m1_second]).length() > 0.05f);
    assert(runtime.tangents[m1_first].w * runtime.tangents[m1_second].w < 0);

    foreach (vertex_index, normal : runtime.normals) {
        assert(math::abs(normal.length() - 1.0f) <= 1e-4f);
        Vec4 tangent = runtime.tangents[vertex_index];
        Vec3 direction = { tangent.x, tangent.y, tangent.z };
        assert(math::abs(direction.length() - 1.0f) <= 1e-4f);
        assert(math::abs(normal.dot(direction)) <= 1e-4f);
        assert(tangent.w == 1.0f || tangent.w == -1.0f);
    }

    Vec3 saved_position = runtime.positions[m2_first];
    uint saved_revision = fixture.assets.geometry(state.geometry).header.revision;
    state.positions[2] = state.positions[0];
    publish(&fixture);
    assert(state.contact_result.failure == cloth::FRAME_UNRESOLVED);
    assert(state.contact_result.stage == ClothContactStage.MATERIAL);
    assert(fixture.assets.geometry(state.geometry).header.revision == saved_revision);
    assert(runtime.positions[m2_first] == saved_position);
    state.positions[2] = state.published[2];

    Node* uv1_node = add_cloth_node(&fixture, uv1_id);
    ClothDesc uv1_desc = desc;
    uv1_desc.tangent_uv_set = 1;
    fixture.scene.add_cloth(&fixture.assets, uv1_node, uv1_desc)!!;

    Node* fallback_node = add_cloth_node(&fixture, degenerate_uv_id);
    fixture.scene.add_cloth(&fixture.assets, fallback_node, desc)!!;
    step(&fixture, physics::DEFAULT_FIXED_DT);
    ClothState* fallback_state = state_of(&fixture, fallback_node);
    Geometry* fallback_geometry = &fixture.assets.geometry(fallback_state.geometry).data;
    foreach (vertex_index, normal : fallback_geometry.normals) {
        Vec4 tangent = fallback_geometry.tangents[vertex_index];
        Vec3 direction = { tangent.x, tangent.y, tangent.z };
        assert(math::abs(direction.length() - 1.0f) <= 1e-4f && math::abs(normal.dot(direction)) <= 1e-4f);
    }
}

fn void test_cloth_weighted_compliant_attachments_and_coalescing() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    GeometryId grid = add_grid(&fixture, 2, 1.0f);
    Node* check_node = add_cloth_node(&fixture, grid);

    ClothAttachment[2] conflict = {
        { .particle = 0, .weight = 1.0f, .compliance = 0.0f },
        { .particle = 0, .weight = 0.5f, .compliance = 0.01f },
    };
    ClothDesc bad = cloth::default_cloth_desc();
    bad.attachments = conflict[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, check_node, bad)) == c3d::INVALID_ARGUMENT);

    uint[1] hard_pin = { 0 };
    ClothAttachment[1] pin_conflict = { { .particle = 0, .weight = 0.8f, .compliance = 0.01f } };
    bad.pins = hard_pin[..];
    bad.attachments = pin_conflict[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, check_node, bad)) == c3d::INVALID_ARGUMENT);

    ClothAttachment[1] bad_weight = { { .particle = 0, .weight = 1.2f, .compliance = 0.0f } };
    bad.pins = {};
    bad.attachments = bad_weight[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, check_node, bad)) == c3d::INVALID_ARGUMENT);

    float[3] sags;
    float[3] compliances = { 0.0f, 0.002f, 0.05f };
    foreach (index, compliance : compliances) {
        Node* node = add_cloth_node(&fixture, grid);
        ClothAttachment[3] attachments = {
            { .particle = 0, .weight = 1.0f, .compliance = 0.0f },
            { .particle = 2, .weight = 0.5f, .compliance = compliance * 0.5f },
            { .particle = 2, .weight = 1.0f, .compliance = compliance },
        };
        ClothDesc desc = cloth::default_cloth_desc();
        desc.attachments = attachments[..];
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
        ClothState* state = state_of(&fixture, node);
        assert(state.inverse_masses[0] == 0);
        assert((compliance == 0.0f) == (state.inverse_masses[2] == 0));

        for (uint step_index = 0; step_index < 12; step_index++) step(&fixture, physics::DEFAULT_FIXED_DT);
        assert((state.published[0] - (Vec3){ 0, 0, 0 }).length() <= POSITION_TOLERANCE);
        sags[index] = -state.published[2].y;
    }
    assert(sags[0] <= POSITION_TOLERANCE);
    assert(sags[1] > 1e-4f && sags[2] > sags[1] + 1e-3f);

    Node* partial_node = add_cloth_node(&fixture, grid);
    ClothAttachment[2] partial_attachments = {
        { .particle = 0, .weight = 1.0f, .compliance = 0.0f },
        { .particle = 2, .weight = 0.25f, .compliance = 0.002f },
    };
    ClothDesc partial_desc = cloth::default_cloth_desc();
    partial_desc.attachments = partial_attachments[..];
    fixture.scene.add_cloth(&fixture.assets, partial_node, partial_desc)!!;
    for (uint step_index = 0; step_index < 12; step_index++) step(&fixture, physics::DEFAULT_FIXED_DT);
    float partial_sag = -state_of(&fixture, partial_node).published[2].y;
    assert(partial_sag > sags[1] + 1e-4f);
}

fn void test_cloth_dihedral_bending_rest_angles_and_certification() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);

    GeometryId quad_id;
    GeometryId flipped_quad_id;
    GeometryId lifted_quad_id;
    @pool() {
        Geometry hinge_geometry = hinge_quad(tmem, 0);
        quad_id = fixture.assets.add_geometry(&hinge_geometry)!!;
        Geometry flipped_geometry = hinge_quad(tmem, 0, true);
        flipped_quad_id = fixture.assets.add_geometry(&flipped_geometry)!!;
        Geometry lifted_geometry = hinge_quad(tmem, 0.37f);
        lifted_quad_id = fixture.assets.add_geometry(&lifted_geometry)!!;
    };

    Node* distance_flipped_node = add_cloth_node(&fixture, flipped_quad_id);
    uint[2] hinge_pins = { 1, 2 };
    ClothDesc distance_desc = cloth::default_cloth_desc();
    distance_desc.pins = hinge_pins[..];
    distance_desc.bend_mode = DISTANCE;
    fixture.scene.add_cloth(&fixture.assets, distance_flipped_node, distance_desc)!!;

    Node* dihedral_flipped_node = add_cloth_node(&fixture, flipped_quad_id);
    ClothDesc dihedral_flipped_desc = distance_desc;
    dihedral_flipped_desc.bend_mode = DIHEDRAL;
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, dihedral_flipped_node, dihedral_flipped_desc)) == c3d::INVALID_ARGUMENT);

    Node* invalid_node = add_cloth_node(&fixture, quad_id);
    ClothDesc bad = cloth::default_cloth_desc();
    bad.pins = hinge_pins[..];
    bad.bend_mode = DIHEDRAL;
    bad.bend_compliance = -0.1f;
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, invalid_node, bad)) == c3d::INVALID_ARGUMENT);

    ClothRestAngle[1] boundary_override = { { .first = 0, .second = 1, .angle = 0.5f } };
    bad = cloth::default_cloth_desc();
    bad.pins = hinge_pins[..];
    bad.bend_mode = DIHEDRAL;
    bad.rest_angles = boundary_override[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, invalid_node, bad)) == c3d::INVALID_ARGUMENT);

    ClothRestAngle[1] neg_pi_override = { { .first = 1, .second = 2, .angle = -(float)math::PI } };
    bad.rest_angles = neg_pi_override[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, invalid_node, bad)) == c3d::INVALID_ARGUMENT);

    ClothRestAngle[1] non_canonical_override = { { .first = 2, .second = 1, .angle = 0.5f } };
    bad.rest_angles = non_canonical_override[..];
    assert(@catch(fixture.scene.add_cloth(&fixture.assets, invalid_node, bad)) == c3d::INVALID_ARGUMENT);

    float[2] target_signs = { 0.7f, -0.7f };
    float[2] solved_angles;
    foreach (index, target : target_signs) {
        Node* node = add_cloth_node(&fixture, quad_id);
        ClothRestAngle[1] overrides = {
            { .first = 1, .second = 2, .angle = target },
        };
        ClothDesc desc = cloth::default_cloth_desc();
        desc.pins = hinge_pins[..];
        desc.bend_mode = DIHEDRAL;
        desc.bend_compliance = 0.0f;
        desc.damping = 0.2f;
        desc.rest_angles = overrides[..];
        fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
        ClothState* state = state_of(&fixture, node);
        assert(state.hinges.len == 1 && !state.bends.len);
        assert(math::abs(state.hinges[0].rest_angle - target) <= 1e-6f);

        for (uint step_index = 0; step_index < 25; step_index++) step(&fixture, physics::DEFAULT_FIXED_DT);
        solved_angles[index] = state.hinges[0].last_angle;
    }
    assert(solved_angles[0] > 0.35f && solved_angles[1] < -0.35f);
    assert(math::abs(solved_angles[0] + solved_angles[1]) <= 1e-2f);

    Node* large_fold_node = add_cloth_node(&fixture, quad_id);
    ClothRestAngle[1] large_override = { { .first = 1, .second = 2, .angle = 2.4f } };
    ClothDesc large_desc = cloth::default_cloth_desc();
    large_desc.pins = hinge_pins[..];
    large_desc.bend_mode = DIHEDRAL;
    large_desc.bend_compliance = 0.0f;
    large_desc.damping = 0.4f;
    large_desc.rest_angles = large_override[..];
    fixture.scene.add_cloth(&fixture.assets, large_fold_node, large_desc)!!;
    for (uint step_index = 0; step_index < 25; step_index++) step(&fixture, physics::DEFAULT_FIXED_DT);
    ClothState* large_state = state_of(&fixture, large_fold_node);
    assert(!large_state.contact_result.failure);
    assert(large_state.hinges[0].last_angle > 1.0f);

    Node* long_way_node = add_cloth_node(&fixture, lifted_quad_id);
    uint[3] single_wing_pins = { 0, 1, 2 };
    ClothRestAngle[1] long_way_override = { { .first = 1, .second = 2, .angle = -3.0f } };
    ClothDesc long_way_desc = large_desc;
    long_way_desc.pins = single_wing_pins[..];
    long_way_desc.substeps = 1;
    long_way_desc.iterations = 32;
    long_way_desc.rest_angles = long_way_override[..];
    fixture.scene.add_cloth(&fixture.assets, long_way_node, long_way_desc)!!;
    for (uint step_index = 0; step_index < 25; step_index++) step(&fixture, physics::DEFAULT_FIXED_DT);
    ClothState* long_way_state = state_of(&fixture, long_way_node);
    assert(!long_way_state.contact_result.failure);
    assert(math::abs(long_way_state.hinges[0].last_angle + 3.0f) <= 0.05f);

    Node* soft_hinge_node = add_cloth_node(&fixture, quad_id);
    ClothRestAngle[1] soft_override = { { .first = 1, .second = 2, .angle = 0.7f } };
    ClothDesc soft_desc = cloth::default_cloth_desc();
    soft_desc.pins = hinge_pins[..];
    soft_desc.bend_mode = DIHEDRAL;
    soft_desc.bend_compliance = 50.0f;
    soft_desc.damping = 0.2f;
    soft_desc.rest_angles = soft_override[..];
    fixture.scene.add_cloth(&fixture.assets, soft_hinge_node, soft_desc)!!;
    for (uint step_index = 0; step_index < 25; step_index++) step(&fixture, physics::DEFAULT_FIXED_DT);
    ClothState* soft_state = state_of(&fixture, soft_hinge_node);
    float soft_angle = soft_state.hinges[0].last_angle;
    assert(soft_angle > 0.0f && soft_angle < solved_angles[0] * 0.5f);

    uint saved_revision = fixture.assets.geometry(soft_state.geometry).header.revision;
    Vec3 saved_flap = soft_state.published[0];
    soft_state.positions[0] = { 0, 0, 0 };
    publish(&fixture);
    assert(soft_state.contact_result.failure == cloth::BEND_UNRESOLVED);
    assert(fixture.assets.geometry(soft_state.geometry).header.revision == saved_revision);
    assert(soft_state.published[0] == saved_flap);

    Node* capsule_body = fixture.scene.add_node()!!;
    ColliderDesc zero_capsule = physics::default_collider_desc(CAPSULE);
    zero_capsule.radius = 0.25f;
    zero_capsule.half_height = 0.0f;
    fixture.physics.add_body(capsule_body, physics::default_body_desc(STATIC), (&zero_capsule)[:1])!!;
    Node* capsule_cloth_node = add_cloth_node(&fixture, quad_id);
    ClothDesc capsule_cloth_desc = cloth::default_cloth_desc();
    capsule_cloth_desc.pins = hinge_pins[..];
    capsule_cloth_desc.colliders = (&capsule_body.id)[:1];
    fixture.scene.add_cloth(&fixture.assets, capsule_cloth_node, capsule_cloth_desc)!!;
    ClothState* capsule_cloth_state = state_of(&fixture, capsule_cloth_node);
    assert(capsule_cloth_state.shapes.len == 1 && capsule_cloth_state.shapes[0].kind == SPHERE);

    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Fixture tracked;
        setup(&tracked, weightless(), &tracker);
        defer teardown(&tracked);
        GeometryId hinge_id;
        @pool() {
            Geometry hinge_geometry = hinge_quad(tmem, 0.1f);
            hinge_id = tracked.assets.add_geometry(&hinge_geometry)!!;
        };
        Node* tracked_node = add_cloth_node(&tracked, hinge_id);
        ClothDesc tracked_desc = cloth::default_cloth_desc();
        tracked_desc.pins = hinge_pins[..];
        tracked_desc.bend_mode = DIHEDRAL;
        tracked_desc.bend_compliance = 0.01f;
        tracked.scene.add_cloth(&tracked.assets, tracked_node, tracked_desc)!!;
        step(&tracked, physics::DEFAULT_FIXED_DT);

        sz allocated_before = tracker.allocated();
        for (uint step_index = 0; step_index < 5; step_index++) step(&tracked, physics::DEFAULT_FIXED_DT);
        assert(tracker.allocated() == allocated_before);
    }
    assert(!tracker.has_leaks());
}
