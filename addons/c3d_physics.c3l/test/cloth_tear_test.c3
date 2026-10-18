module c3d_physics_cloth_test;

import std::math;
import std::core::mem::allocators;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::physics;
import c3d::physics::cloth @public;
import c3d::scene;

fn Geometry create_tear_patch_geometry(Allocator allocator) @local {
    Vec3[] positions = alloc::new_array(allocator, Vec3, 8);
    positions[..] = ((Vec3[8]){
        { -1, 0, 0 }, { 0, 0, 0 }, { 0, 1, 0 }, { -1, 1, 0 },
        { 0, 0, 0 }, { 1, 0, 0 }, { 1, 1, 0 }, { 0, 1, 0 },
    })[..];
    Vec2[] uv0 = alloc::new_array(allocator, Vec2, 8);
    uv0[..] = ((Vec2[8]){
        { 0, 0 }, { 1, 0 }, { 1, 1 }, { 0, 1 },
        { 1, 0 }, { 0, 0 }, { 0, 1 }, { 1, 1 },
    })[..];
    uint[] indices = alloc::new_array(allocator, uint, 12);
    indices[..] = ((uint[12]){ 0, 1, 2, 0, 2, 3, 4, 5, 6, 4, 6, 7 })[..];
    Geometry geometry = {
        .positions = positions,
        .uv0       = uv0,
        .indices   = indices,
    };
    geometry.finalize();
    return geometry;
}

fn void test_cloth_tear_request_ordering_and_strain_trigger() @test {
    @pool() {
        Fixture fixture;
        PhysicsDesc physics_desc = weightless();
        physics_desc.tuning.fixed_dt = 1.0f / 240.0f;
        setup(&fixture, physics_desc);
        defer teardown(&fixture);

        Geometry patch = create_tear_patch_geometry(tmem);
        GeometryId patch_id = fixture.assets.add_geometry(&patch, "tear_patch")!!;
        uint[8] render_map = { 0, 1, 4, 3, 1, 2, 5, 4 };
        uint[2] cut_vertices = { 1, 4 };

        Geometry grid2 = hanging_grid(tmem, 2, 2.0f);
        GeometryId grid2_id = fixture.assets.add_geometry(&grid2, "grid2")!!;
        Node* cross_node = fixture.scene.add_mesh(grid2_id, fixture.material, name: "cross_grid")!!;
        fixture.scene.update_world();
        uint[2] top_path = { 1, 4 };
        uint[2] bottom_path = { 4, 7 };
        uint[3] horizontal_path = { 3, 4, 5 };
        ClothCutPath[3] cross_cuts = {
            { .id = 20, .vertices = top_path[..] },
            { .id = 10, .vertices = bottom_path[..] },
            { .id = 30, .vertices = horizontal_path[..] },
        };
        ClothDesc cross_desc = cloth::default_cloth_desc();
        cross_desc.substeps = 1;
        cross_desc.stretch_stiffness = 0;
        cross_desc.bend_stiffness = 0;
        cross_desc.damping = 0;
        cross_desc.gravity_scale = 0;
        cross_desc.collisions.self_collision = true;
        cross_desc.collisions.continuous = true;
        cross_desc.cuts = cross_cuts[..];
        cross_desc.tears.max_requests = 2;
        fixture.scene.attach_cloth(&fixture.assets, cross_node, cross_desc)!!;
        fixture.physics.update(0);
        cloth::prepare(&fixture.scene, &fixture.assets, cross_node)!!;
        Cloth* cross_cloth = fixture.scene.get(cross_node, Cloth);

        uint center_sectors;
        foreach (base_particle : cross_cloth.state.sector_bases) {
            if (base_particle == 4) center_sectors++;
        }
        assert(center_sectors == 4);
        assert(cross_cloth.state.cut_paths[0].id == 10);
        assert(cross_cloth.state.cut_paths[1].id == 20);
        assert(cross_cloth.state.cut_paths[2].id == 30);

        cross_cloth.request_cut(20)!!;
        cross_cloth.request_cut(20)!!;
        assert(cross_cloth.state.pending_request_count == 1);
        cross_cloth.request_cut(10)!!;
        assert(cross_cloth.state.pending_request_count == 2);
        assert(@catch(cross_cloth.request_cut(30)) == c3d::CAPACITY_EXCEEDED);
        assert(cross_cloth.state.pending_request_count == 2);

        fixture.physics.update(0);
        fixture.physics.update_cloths();
        assert(cross_cloth.state.pending_request_count == 2);
        assert(cross_cloth.cut_result(10)!!.outcome == NONE);
        assert(cross_cloth.cut_result(20)!!.outcome == NONE);

        Node* strain_node = fixture.scene.add_mesh(patch_id, fixture.material, name: "strain_patch")!!;
        fixture.scene.update_world();
        ClothCutPath[1] strain_cuts = {
            { .id = 10, .vertices = cut_vertices[..], .strain_trigger = true, .strain_threshold = 0.25f },
        };
        ClothDesc strain_desc = cloth::default_cloth_desc();
        strain_desc.render_particles = render_map[..];
        strain_desc.substeps = 1;
        strain_desc.stretch_stiffness = 0;
        strain_desc.bend_stiffness = 0;
        strain_desc.damping = 0;
        strain_desc.gravity_scale = 0;
        strain_desc.collisions.self_collision = true;
        strain_desc.collisions.continuous = true;
        strain_desc.cuts = strain_cuts[..];
        fixture.scene.attach_cloth(&fixture.assets, strain_node, strain_desc)!!;
        cloth::prepare(&fixture.scene, &fixture.assets, strain_node)!!;
        Cloth* strain_cloth = fixture.scene.get(strain_node, Cloth);

        strain_cloth.state.positions[4].y = 1.249f;
        strain_cloth.state.published[4].y = 1.249f;
        strain_cloth.state.sweep_start[4].y = 1.249f;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();
        assert(!strain_cloth.cut_result(10)!!.is_cut);

        strain_cloth.state.positions[4].y = 1.25f;
        strain_cloth.state.published[4].y = 1.25f;
        strain_cloth.state.sweep_start[4].y = 1.25f;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();
        assert(strain_cloth.cut_result(10)!!.is_cut);
        assert(strain_cloth.cut_result(10)!!.outcome == APPLIED);
    };
}

fn void test_cloth_tear_splits_mass_and_attachment_stiffness() @test {
    @pool() {
        Fixture fixture;
        PhysicsDesc physics_desc = weightless();
        physics_desc.tuning.fixed_dt = 1.0f / 240.0f;
        setup(&fixture, physics_desc);
        defer teardown(&fixture);

        Geometry patch = create_tear_patch_geometry(tmem);
        GeometryId patch_id = fixture.assets.add_geometry(&patch, "tear_patch_mass")!!;
        uint[8] render_map = { 0, 1, 4, 3, 1, 2, 5, 4 };
        uint[2] cut_vertices = { 1, 4 };
        ClothCutPath[1] cuts = {
            { .id = 10, .vertices = cut_vertices[..] },
        };
        ClothAttachment[2] attachments = {
            { .particle = 1, .weight = 1.0f, .compliance = 0.01f },
            { .particle = 4, .weight = 1.0f, .compliance = 0.01f },
        };
        ClothDesc desc = cloth::default_cloth_desc();
        desc.render_particles = render_map[..];
        desc.substeps = 1;
        desc.stretch_stiffness = 0;
        desc.bend_stiffness = 0;
        desc.damping = 0;
        desc.gravity_scale = 0;
        desc.collisions.self_collision = true;
        desc.collisions.continuous = true;
        desc.attachments = attachments[..];
        desc.cuts = cuts[..];

        Node* node = fixture.scene.add_mesh(patch_id, fixture.material, name: "mass_patch")!!;
        fixture.scene.update_world();
        fixture.scene.attach_cloth(&fixture.assets, node, desc)!!;
        fixture.physics.update(0);
        cloth::prepare(&fixture.scene, &fixture.assets, node)!!;
        Cloth* cloth = fixture.scene.get(node, Cloth);

        cloth.request_cut(10)!!;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();
        assert(cloth.cut_result(10)!!.outcome == APPLIED);
        assert(cloth.state.active_particle_count == 8);

        double total_mass;
        foreach (mass : cloth.state.particle_masses) total_mass += mass;
        assert(math::abs(total_mass - 6.0) <= 2e-6);

        double mass_1_a = cloth.state.particle_masses[1];
        double mass_1_b = cloth.state.particle_masses[6];
        double mass_4_a = cloth.state.particle_masses[4];
        double mass_4_b = cloth.state.particle_masses[7];
        assert(math::abs((mass_1_a + mass_1_b) - 1.0) <= 1e-6);
        assert(math::abs((mass_4_a + mass_4_b) - 1.0) <= 1e-6);
        assert(math::abs(math::min(mass_1_a, mass_1_b) - 1.0 / 3.0) <= 1e-6);
        assert(math::abs(math::max(mass_1_a, mass_1_b) - 2.0 / 3.0) <= 1e-6);
        assert(math::abs(math::min(mass_4_a, mass_4_b) - 1.0 / 3.0) <= 1e-6);
        assert(math::abs(math::max(mass_4_a, mass_4_b) - 2.0 / 3.0) <= 1e-6);

        assert(cloth.state.soft_attachments.len == 4);
        double stiffness_sum_1;
        double stiffness_sum_4;
        foreach (attachment : cloth.state.soft_attachments) {
            uint base_particle = cloth.state.particle_bases[attachment.particle];
            if (base_particle == 1) stiffness_sum_1 += 1.0 / (double)attachment.effective_compliance;
            if (base_particle == 4) stiffness_sum_4 += 1.0 / (double)attachment.effective_compliance;
        }
        assert(math::abs(stiffness_sum_1 - 100.0) <= 2e-4);
        assert(math::abs(stiffness_sum_4 - 100.0) <= 2e-4);
    };
}

fn void test_cloth_tear_free_opening_certificate_and_recontact() @test {
    @pool() {
        Fixture fixture;
        PhysicsDesc physics_desc = weightless();
        physics_desc.tuning.fixed_dt = 1.0f / 240.0f;
        setup(&fixture, physics_desc);
        defer teardown(&fixture);

        Geometry patch = create_tear_patch_geometry(tmem);
        GeometryId patch_id = fixture.assets.add_geometry(&patch, "tear_patch_open")!!;
        uint[8] render_map = { 0, 1, 4, 3, 1, 2, 5, 4 };
        uint[2] cut_vertices = { 1, 4 };
        ClothCutPath[1] cuts = {
            { .id = 10, .vertices = cut_vertices[..] },
        };
        ClothAttachment[2] attachments = {
            { .particle = 1, .weight = 1.0f, .compliance = 0.01f },
            { .particle = 4, .weight = 1.0f, .compliance = 0.01f },
        };
        ClothDesc desc = cloth::default_cloth_desc();
        desc.render_particles = render_map[..];
        desc.substeps = 1;
        desc.stretch_stiffness = 0;
        desc.bend_stiffness = 0;
        desc.damping = 0;
        desc.gravity_scale = 0;
        desc.thickness = 0.01f;
        desc.collisions.contact_tolerance = 0.0001f;
        desc.collisions.self_collision = true;
        desc.collisions.continuous = true;
        desc.attachments = attachments[..];
        desc.cuts = cuts[..];

        Node* node = fixture.scene.add_mesh(patch_id, fixture.material, name: "open_patch")!!;
        fixture.scene.update_world();
        fixture.scene.attach_cloth(&fixture.assets, node, desc)!!;
        fixture.physics.update(0);
        cloth::prepare(&fixture.scene, &fixture.assets, node)!!;
        Cloth* cloth = fixture.scene.get(node, Cloth);
        scene::Mesh* mesh = fixture.scene.get(node, scene::Mesh);
        ulong token_before = mesh.vertex_history_token;
        GeometryId geometry_before = mesh.geometry;

        cloth.request_cut(10)!!;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();

        ClothCutResult cut_result = cloth.cut_result(10)!!;
        assert(cut_result.outcome == APPLIED && cut_result.is_cut);
        assert(cut_result.attempts == 1 && !cut_result.failure);
        assert((cloth.state.published[6] - cloth.state.published[1]).length() >= 0.02f - 1e-4f);
        assert((cloth.state.published[7] - cloth.state.published[4]).length() >= 0.02f - 1e-4f);
        assert(cloth.state.contact_result.max_residual <= 0.0001f);
        assert(mesh.vertex_history_token == token_before + 1);
        assert(c3d::same_id(mesh.geometry, geometry_before));

        cloth.state.velocities[..] = (Vec3){};
        cloth.request_cut(10)!!;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();
        ClothCutResult second_result = cloth.cut_result(10)!!;
        assert(second_result.outcome == ALREADY_CUT && second_result.is_cut);
        assert(mesh.vertex_history_token == token_before + 1);

        cloth.state.velocities[..] = (Vec3){};
        uint total_self_contacts;
        for (uint step = 0; step < 60; step++) {
            fixture.physics.update(1.0f / 240.0f);
            fixture.physics.update_cloths();
            assert(!cloth.state.contact_result.failure);
            assert(cloth.state.contact_result.max_residual <= 0.0001f);
            total_self_contacts += cloth.state.contact_result.contacts + cloth.state.contact_result.impacts;
        }
        assert(total_self_contacts > 0);
        float gap_1 = (cloth.state.published[6] - cloth.state.published[1]).length();
        float gap_4 = (cloth.state.published[7] - cloth.state.published[4]).length();
        assert(gap_1 >= 0.02f - 0.0001f);
        assert(gap_4 >= 0.02f - 0.0001f);
    };
}

fn void test_cloth_tear_refusal_cases_and_whole_update_atomicity() @test {
    @pool() {
        Fixture fixture;
        PhysicsDesc physics_desc = weightless();
        physics_desc.tuning.fixed_dt = 1.0f / 240.0f;
        setup(&fixture, physics_desc);
        defer teardown(&fixture);

        Geometry patch = create_tear_patch_geometry(tmem);
        GeometryId patch_id = fixture.assets.add_geometry(&patch, "tear_patch_refuse")!!;
        uint[8] render_map = { 0, 1, 4, 3, 1, 2, 5, 4 };
        uint[2] cut_vertices = { 1, 4 };
        ClothCutPath[1] cuts = {
            { .id = 10, .vertices = cut_vertices[..] },
        };

        Node* seam_node = fixture.scene.add_mesh(patch_id, fixture.material, name: "bad_seam")!!;
        fixture.scene.update_world();
        ClothSeam[1] bad_seams = { { .first = 0, .second = 5 } };
        ClothDesc seam_desc = cloth::default_cloth_desc();
        seam_desc.render_particles = render_map[..];
        seam_desc.collisions.self_collision = true;
        seam_desc.seams = bad_seams[..];
        seam_desc.cuts = cuts[..];
        assert(@catch(fixture.scene.attach_cloth(&fixture.assets, seam_node, seam_desc)) == c3d::INVALID_ARGUMENT);

        Node* pin_node = fixture.scene.add_mesh(patch_id, fixture.material, name: "pinned_seam")!!;
        fixture.scene.update_world();
        uint[2] seam_pins = { 1, 2 };
        ClothCutPath[1] strain_cuts = {
            { .id = 10, .vertices = cut_vertices[..], .strain_trigger = true, .strain_threshold = 0.25f },
        };
        ClothDesc pin_desc = cloth::default_cloth_desc();
        pin_desc.render_particles = render_map[..];
        pin_desc.substeps = 1;
        pin_desc.stretch_stiffness = 0;
        pin_desc.bend_stiffness = 0;
        pin_desc.damping = 0;
        pin_desc.gravity_scale = 0;
        pin_desc.collisions.self_collision = true;
        pin_desc.collisions.continuous = true;
        pin_desc.pins = seam_pins[..];
        pin_desc.cuts = strain_cuts[..];
        fixture.scene.attach_cloth(&fixture.assets, pin_node, pin_desc)!!;
        fixture.physics.update(0);
        cloth::prepare(&fixture.scene, &fixture.assets, pin_node)!!;
        Cloth* pin_cloth = fixture.scene.get(pin_node, Cloth);
        ulong pin_token = fixture.scene.get(pin_node, scene::Mesh).vertex_history_token;

        pin_cloth.state.rest[4].y = 1.3f;
        pin_cloth.state.solved_reference[4].y = 1.3f;
        pin_cloth.state.current_reference[4].y = 1.3f;
        pin_cloth.state.positions[4].y = 1.3f;
        pin_cloth.state.published[4].y = 1.3f;
        pin_cloth.state.sweep_start[4].y = 1.3f;
        pin_cloth.state.pin_anchors[1].y = 1.3f;
        pin_cloth.state.pin_targets[1].y = 1.3f;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();
        ClothCutResult pin_result = pin_cloth.cut_result(10)!!;
        assert(pin_result.outcome == REFUSED && !pin_result.is_cut && pin_result.attempts == 1);
        assert(pin_result.failure == cloth::OPENING_UNRESOLVED && pin_result.stage == cloth::ClothContactStage.OPENING);
        assert(pin_cloth.state.active_particle_count == 6);
        assert(pin_cloth.state.pending_request_count == 0);
        assert(fixture.scene.get(pin_node, scene::Mesh).vertex_history_token == pin_token);

        // A refused strain-triggered path latches so subsequent updates continue simulating instead of freezing.
        pin_cloth.state.velocities[0] = { -1.0f, 0, 0 };
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();
        assert(pin_cloth.cut_result(10)!!.attempts == 1);
        assert(!pin_cloth.state.contact_result.failure);
        assert(pin_cloth.state.published[0].x < -1.0f);

        Node* singular_node = fixture.scene.add_mesh(patch_id, fixture.material, name: "singular_publish")!!;
        fixture.scene.update_world();
        ClothDesc singular_desc = cloth::default_cloth_desc();
        singular_desc.render_particles = render_map[..];
        singular_desc.substeps = 2;
        singular_desc.stretch_stiffness = 0;
        singular_desc.bend_stiffness = 0;
        singular_desc.damping = 0;
        singular_desc.gravity_scale = 0;
        singular_desc.collisions.self_collision = true;
        singular_desc.collisions.continuous = true;
        singular_desc.cuts = cuts[..];
        fixture.scene.attach_cloth(&fixture.assets, singular_node, singular_desc)!!;
        cloth::prepare(&fixture.scene, &fixture.assets, singular_node)!!;
        Cloth* singular_cloth = fixture.scene.get(singular_node, Cloth);
        singular_node.world.m00 = 0;

        singular_cloth.request_cut(10)!!;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();
        ClothCutResult singular_result = singular_cloth.cut_result(10)!!;
        assert(singular_result.outcome == REFUSED && !singular_result.is_cut);
        assert(singular_result.failure == cloth::CONTACT_PRECISION_EXCEEDED);
        assert(singular_result.stage == cloth::ClothContactStage.PUBLICATION);
        assert(singular_cloth.state.active_particle_count == 6);
        assert(singular_cloth.state.committed_particle_count == 6);
    };

    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    @pool() {
        Fixture tracked;
        PhysicsDesc physics_desc = weightless();
        physics_desc.tuning.fixed_dt = 1.0f / 240.0f;
        setup(&tracked, physics_desc, &tracker);
        defer teardown(&tracked);

        Geometry patch = create_tear_patch_geometry(tmem);
        GeometryId patch_id = tracked.assets.add_geometry(&patch, "tear_patch_tracked")!!;
        uint[8] render_map = { 0, 1, 4, 3, 1, 2, 5, 4 };
        uint[2] cut_vertices = { 1, 4 };
        ClothCutPath[1] cuts = {
            { .id = 10, .vertices = cut_vertices[..] },
        };
        ClothDesc desc = cloth::default_cloth_desc();
        desc.render_particles = render_map[..];
        desc.substeps = 2;
        desc.stretch_stiffness = 0;
        desc.bend_stiffness = 0;
        desc.damping = 0;
        desc.gravity_scale = 0;
        desc.collisions.self_collision = true;
        desc.collisions.continuous = true;
        desc.cuts = cuts[..];

        Node* node = tracked.scene.add_mesh(patch_id, tracked.material, name: "tracked_patch")!!;
        tracked.scene.update_world();
        tracked.scene.attach_cloth(&tracked.assets, node, desc)!!;
        tracked.physics.update(0);
        cloth::prepare(&tracked.scene, &tracked.assets, node)!!;
        Cloth* cloth = tracked.scene.get(node, Cloth);
        scene::Mesh* mesh = tracked.scene.get(node, scene::Mesh);
        mesh.vertex_history_token = 10;

        sz allocated_before = tracker.allocated();
        cloth.request_cut(10)!!;
        for (uint step = 0; step < 20; step++) {
            tracked.physics.update(1.0f / 240.0f);
            tracked.physics.update_cloths();
        }
        assert(cloth.cut_result(10)!!.outcome == APPLIED && cloth.cut_result(10)!!.is_cut);
        assert(mesh.vertex_history_token == 11);
        assert(tracker.allocated() == allocated_before);
    };
}

fn void test_crowd_cloth_tear_isolates_slots_and_reseeds_intact() @test {
    @pool() {
        Fixture fixture;
        PhysicsDesc physics_desc = weightless();
        physics_desc.tuning.fixed_dt = 1.0f / 240.0f;
        setup(&fixture, physics_desc);
        defer teardown(&fixture);

        AnimationClip clip = {
            .name     = "idle".copy(mem),
            .duration = 1,
            .tracks   = alloc::new_array(mem, Track, 1),
            .targets  = alloc::new_array(mem, uint, 1),
        };
        clip.targets[0] = 0;
        clip.tracks[0] = {
            .target        = 0,
            .path          = TargetPath.TRANSLATION,
            .interpolation = Interpolation.STEP,
            .times         = alloc::new_array(mem, float, 1),
            .values        = alloc::new_array(mem, float, 3),
        };
        ClipId clip_id = fixture.assets.add_clip_owned(&clip, "crowd_tear_idle")!!;

        Geometry patch = create_tear_patch_geometry(tmem);
        GeometryId patch_id = fixture.assets.add_geometry(&patch, "crowd_tear_patch")!!;
        NodeTemplate[] nodes = alloc::new_array(mem, NodeTemplate, 1);
        nodes[0] = { .parent = -1, .name = "banner".copy(mem), .local = maths::TRANSFORM_IDENTITY, .visible = true };
        ModelMesh[] meshes = alloc::new_array(mem, ModelMesh, 1);
        meshes[0] = { .node = 0, .geometry = patch_id, .material = fixture.material };
        ClipId[] clips = alloc::new_array(mem, ClipId, 1);
        clips[0] = clip_id;
        ModelTemplate model_template = { .nodes = nodes, .meshes = meshes, .clips = clips };
        ModelId model = fixture.assets.add_model_owned(&model_template, "crowd_tear_model")!!;

        CrowdPose seed = { .clip = clip_id, .speed = 1, .loop = true };
        CrowdInstance[2] instances = {
            {
                .placement = { .position = { 0, 0, 0 }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } },
                .pose      = seed,
                .color     = { 1, 0, 0, 1 },
            },
            {
                .placement = { .position = { 4, 0, 0 }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } },
                .pose      = seed,
                .color     = { 0, 1, 0, 1 },
            },
        };
        Node* crowd_node = model::add_crowd(
            assets:      &fixture.assets,
            scene:       &fixture.scene,
            model:       model,
            capacity:    2,
            pose_bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
            instances:   instances[..],
            name:        "crowd_tear",
        )!!;
        fixture.scene.update_world();

        uint[8] render_map = { 0, 1, 4, 3, 1, 2, 5, 4 };
        uint[2] cut_vertices = { 1, 4 };
        ClothCutPath[1] cuts = { { .id = 10, .vertices = cut_vertices[..] } };
        ClothAttachment[2] attachments = {
            { .particle = 1, .weight = 1.0f, .compliance = 0.01f },
            { .particle = 4, .weight = 1.0f, .compliance = 0.01f },
        };
        ClothDesc desc = cloth::default_cloth_desc();
        desc.render_particles = render_map[..];
        desc.substeps = 1;
        desc.stretch_stiffness = 0;
        desc.bend_stiffness = 0;
        desc.damping = 0;
        desc.gravity_scale = 0;
        desc.collisions.self_collision = true;
        desc.collisions.continuous = true;
        desc.attachments = attachments[..];
        desc.cuts = cuts[..];

        fixture.scene.attach_crowd_cloth(&fixture.assets, crowd_node, 0, desc)!!;
        fixture.physics.update(0);
        cloth::prepare_crowd_cloth(&fixture.physics, &fixture.assets, crowd_node)!!;

        CrowdCloth* crowd_cloth = fixture.scene.get(crowd_node, CrowdCloth);
        CrowdClothPart* part = crowd_cloth.find_part(0)!!;
        CrowdInstanceId slot0_instance = { .index = 0, .generation = part.slot_generations[0] };
        CrowdInstanceId slot1_instance = { .index = 1, .generation = part.slot_generations[1] };
        CrowdInstanceId stale_instance = { .index = 0, .generation = part.slot_generations[0] + 1 };
        assert(@catch(crowd_cloth.request_cut(0, stale_instance, 10)) == c3d::INVALID_ID);
        assert(@catch(crowd_cloth.request_cut(99, slot0_instance, 10)) == NOT_FOUND);

        crowd_cloth.request_cut(0, slot0_instance, 10)!!;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();

        ClothCutResult slot0_result = crowd_cloth.cut_result(0, slot0_instance, 10)!!;
        ClothCutResult slot1_result = crowd_cloth.cut_result(0, slot1_instance, 10)!!;
        assert(slot0_result.outcome == APPLIED && slot0_result.is_cut && slot0_result.attempts == 1);
        assert(part.states[0].active_particle_count == 8);
        assert(slot1_result.outcome == NONE && !slot1_result.is_cut && slot1_result.attempts == 0);
        assert(part.states[1].active_particle_count == 6);

        CrowdInstance[1] replacement = {
            {
                .placement = { .position = { 8, 0, 0 }, .rotation = quaternion::IDENTITY, .scale = { 1, 1, 1 } },
                .pose      = seed,
                .color     = { 0, 0, 1, 1 },
            },
        };
        model::set_crowd(
            assets:    &fixture.assets,
            scene:     &fixture.scene,
            node:      crowd_node,
            instances: replacement[..],
        )!!;
        fixture.physics.update(1.0f / 240.0f);
        fixture.physics.update_cloths();

        CrowdInstanceId reseeded_instance = { .index = 0, .generation = part.slot_generations[0] };
        assert(@catch(crowd_cloth.cut_result(0, slot0_instance, 10)) == c3d::INVALID_ID);
        ClothCutResult reseeded_result = crowd_cloth.cut_result(0, reseeded_instance, 10)!!;
        assert(reseeded_result.outcome == NONE && !reseeded_result.is_cut && reseeded_result.attempts == 0);
        assert(part.states[0].active_particle_count == 6);
    };
}
