module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::math;

const float CROWD_NATIVE_VELOCITY_TOLERANCE @private = 2e-3f;

fn void? configure_crowd_native_temporal(Fixture* fixture, CrowdNativeOutput* output, float lod_bias = 0) @private {
    ViewDesc desc = render::texture_view_desc(output.target);
    desc.post.anti_aliasing = AntiAliasing.TAA;
    desc.post.motion_blur = true;
    desc.lod_bias = lod_bias;
    return render::configure_view(&fixture.renderer, output.view, desc);
}

fn void? capture_crowd_native_temporal(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput[] outputs,
    uint views = uint::max,
    bool aborted = false,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    foreach (uint index, &output : outputs) {
        if (!(views & (1u << (index / 2)))) continue;
        record_crowd_native_view(
            fixture: fixture,
            pair: pair,
            probe: &output.probe,
            view: output.view,
            crowd_visible: index % 2 == 0,
            images: &output.actual,
        )!;
    }
    if (aborted) {
        render::abort_frame(renderer);
        return;
    }

    renderer.end_frame()!;
    foreach (uint index, &output : outputs) {
        if (views & (1u << (index / 2))) read_crowd_native_view(fixture, &output.probe, &output.actual)!;
    }
}

fn void check_crowd_native_temporal_flags(CrowdNativeImages* images, float rejection, bool still = true) @private {
    assert(images.velocity_format == gpu::Format.RGBA16_FLOAT);
    uint covered;
    foreach (index, depth : images.depth) {
        if (depth.x <= 0) continue;
        covered++;
        Vec4 velocity = images.velocity[index];
        assert(velocity.w == rejection, "Crowd source correspondence rejection differs");
        if (still) {
            assert(math::abs(velocity.x) < CROWD_NATIVE_STILL_TOLERANCE);
            assert(math::abs(velocity.y) < CROWD_NATIVE_STILL_TOLERANCE);
        }
    }
    assert(covered > 0);
}

fn void check_crowd_native_velocity(Vec4[] actual, Vec4[] expected) @private {
    for (int y = 1; y + 1 < (int)CROWD_NATIVE_HEIGHT; y++) {
        for (int x = 1; x + 1 < (int)CROWD_NATIVE_WIDTH; x++) {
            Vec4 pixel = actual[y * (int)CROWD_NATIVE_WIDTH + x];
            bool matched;
            for (int dy = -1; dy <= 1 && !matched; dy++) {
                for (int dx = -1; dx <= 1; dx++) {
                    Vec4 delta = math::abs(pixel - expected[(y + dy) * (int)CROWD_NATIVE_WIDTH + x + dx]);
                    if (math::max(delta.x, delta.y) < CROWD_NATIVE_VELOCITY_TOLERANCE) matched = true;
                }
            }
            assert(matched, "Crowd velocity read another logical source's previous pose");
        }
    }
}

fn float check_crowd_native_view_motion(
    CrowdNativeOutput[] outputs,
    uint view,
    float rejection,
    bool still = true,
) @private {
    CrowdNativeImages* actual = &outputs[2 * view].actual;
    CrowdNativeImages* reference = &outputs[2 * view + 1].actual;
    check_crowd_native_temporal_flags(actual, rejection, still);
    check_crowd_native_image(actual.depth, reference.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(reference.depth, actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_velocity(actual.velocity, reference.velocity);
    check_crowd_native_velocity(reference.velocity, actual.velocity);
    float maximum;
    foreach (pixel, depth : reference.depth) {
        if (depth.x <= 0) continue;
        maximum = math::max(maximum, math::max(math::abs(reference.velocity[pixel].x),
            math::abs(reference.velocity[pixel].y)));
    }
    return maximum;
}

fn void set_animated_lod_native_motion(
    Fixture* fixture,
    CrowdNativePair* pair,
    float phase_offset,
    float placement_offset,
) @private {
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        float phase = 0.1f + 0.25f * (float)source + phase_offset;
        CrowdPlayer player = crowd_native_player(pair, source)!!;
        Animator* reference = pair.scene.get(pair.ordinary[source], Animator);
        crowd_native_action_controls(player.base_action()!!, phase);
        crowd_native_action_controls(reference.action(pair.ordinary_base[source]), phase);
        float displacement = placement_offset * (float)(source + 1);
        crowd.placements[source].position.y = displacement;
        pair.ordinary[source].local.position.y = displacement;
    }
    pair.scene.write_crowd_batches(crowd);
    crowd_native_update(fixture, pair, 0);
}

fn void? create_crowd_native_morph_pair(Fixture* fixture, CrowdNativePair* pair, ModelId model) @private {
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (&placement : placements) placement.scale *= 0.6f;
    create_crowd_native_pair(
        allocator: mem,
        fixture: fixture,
        pair: pair,
        model: model,
        clip: fixture.assets.model(model).data.clips[0],
        bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
        placements: placements[..],
    )!;
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 0, 12 };
}

fn void test_crowd_native_rgba_history_equal_count_parity_swap_and_replacement() @test {
    foreach (bool lod : { false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: parts.mixed,
            clip: parts.posing,
            bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(24, 0.1f, 100);
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            CrowdPlayer player = crowd_native_player(&pair, source)!!;
            Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
            float phase = 0.1f + 0.35f * (float)source;
            crowd_native_action_controls(player.base_action()!!, phase);
            crowd_native_action_controls(animator.action(pair.ordinary_base[source]), phase);
        }
        crowd_native_update(&fixture, &pair, 0);
        if (lod) {
            @pool() {
                model::attach_animated_lod(
                    assets: &fixture.assets,
                    scene: &pair.scene,
                    owner: pair.crowd,
                    desc: animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed),
                )!!;
            };
        }
        CrowdNativeOutput[2] outputs;
        foreach (&output : outputs) {
            create_crowd_native_output(&fixture, output)!!;
            configure_crowd_native_temporal(&fixture, output)!!;
        }
        defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
        for (uint frame = 0; frame < 2; frame++) {
            capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
            check_crowd_native_temporal_flags(&outputs[0].actual, frame ? 0 : 1);
        }

        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        foreach (source : (uint[2]){ 0, 2 }) {
            crowd.placements[source].scale.x = -crowd.placements[source].scale.x;
            pair.ordinary[source].local.scale.x = -pair.ordinary[source].local.scale.x;
        }
        pair.scene.write_crowd_batches(crowd);
        crowd_native_update(&fixture, &pair, 0);
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        float largest_motion = check_crowd_native_view_motion(
            outputs: outputs[..],
            view: 0,
            rejection: 0,
            still: false,
        );
        assert(largest_motion > 10 * CROWD_NATIVE_VELOCITY_TOLERANCE);
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        check_crowd_native_temporal_flags(&outputs[0].actual, 0);

        CrowdInstance[CROWD_NATIVE_INSTANCES] replacement;
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            CrowdPlayer player = crowd_native_player(&pair, source)!!;
            replacement[source] = {
                .placement = crowd.placements[source],
                .pose = { .clip = parts.posing, .time = player.base_action()!!.time, .speed = 0, .loop = false },
                .color = crowd.colors[source],
            };
        }
        model::set_crowd(
            assets: &fixture.assets,
            scene: &pair.scene,
            node: pair.crowd,
            instances: replacement[..],
        )!!;
        for (uint frame = 0; frame < 2; frame++) {
            capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
            check_crowd_native_temporal_flags(&outputs[0].actual, frame ? 0 : 1);
        }
        check_crowd_native_validation(&fixture.renderer);
    }
}

fn void test_animated_lod_native_independent_view_skip_cut_abort_and_compatible_level_history() @test {
    Fixture fixture;
    create_fixture(
        allocator: mem,
        fixture: &fixture,
        max_views: 8,
        max_render_targets: 8,
    )!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: parts.mixed,
        clip: parts.posing,
        bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(24, 0.1f, 100);
    set_animated_lod_native_motion(
        fixture: &fixture,
        pair: &pair,
        phase_offset: 0,
        placement_offset: 0,
    );
    @pool() {
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed),
        )!!;
    };
    CrowdNativeOutput[4] outputs;
    foreach (&output : outputs) {
        create_crowd_native_output(&fixture, output)!!;
        configure_crowd_native_temporal(&fixture, output)!!;
    }
    defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
    for (uint frame = 0; frame < 2; frame++) {
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        for (uint view = 0; view < 2; view++) (void)check_crowd_native_view_motion(outputs[..], view, frame ? 0 : 1);
    }

    set_animated_lod_native_motion(
        fixture: &fixture,
        pair: &pair,
        phase_offset: 0.04f,
        placement_offset: 0.2f,
    );
    capture_crowd_native_temporal(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 1,
    )!!;
    float first_motion = check_crowd_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 0,
        still: false,
    );
    assert(first_motion > 10 * CROWD_NATIVE_VELOCITY_TOLERANCE);
    set_animated_lod_native_motion(
        fixture: &fixture,
        pair: &pair,
        phase_offset: 0.08f,
        placement_offset: 0.4f,
    );
    capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
    float resumed_motion = check_crowd_native_view_motion(
        outputs: outputs[..],
        view: 1,
        rejection: 0,
        still: false,
    );
    (void)check_crowd_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 0,
        still: false,
    );
    assert(resumed_motion > first_motion + CROWD_NATIVE_VELOCITY_TOLERANCE);

    render::reset_view_history(&fixture.renderer, outputs[0].view)!!;
    render::reset_view_history(&fixture.renderer, outputs[1].view)!!;
    capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
    (void)check_crowd_native_view_motion(outputs[..], 0, 1);
    (void)check_crowd_native_view_motion(outputs[..], 1, 0);

    set_animated_lod_native_motion(
        fixture: &fixture,
        pair: &pair,
        phase_offset: 0.12f,
        placement_offset: 0.6f,
    );
    capture_crowd_native_temporal(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        aborted: true,
    )!!;
    for (uint frame = 0; frame < 2; frame++) {
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        for (uint view = 0; view < 2; view++) (void)check_crowd_native_view_motion(outputs[..], view, frame ? 0 : 1);
    }
    assert(outputs[0].actual.stats.lod_selected[0] == 2 * CROWD_NATIVE_INSTANCES);

    pair.scene.get(pair.camera, Camera).ortho_height = 80;
    capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
    for (uint view = 0; view < 2; view++) {
        (void)check_crowd_native_view_motion(
            outputs: outputs[..],
            view: view,
            rejection: 0,
            still: false,
        );
    }
    // LOD counters reach Stats only when their frame slot is reused.
    for (uint frame = 0; frame < render::FRAMES_IN_FLIGHT; frame++) {
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        for (uint view = 0; view < 2; view++) (void)check_crowd_native_view_motion(outputs[..], view, 0);
    }
    assert(outputs[0].actual.stats.lod_selected[1] == 2 * CROWD_NATIVE_INSTANCES);
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animated_lod_native_real_morph_topology_replacement_shrink_and_regrowth_reject_history() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model_id = load_crowd_native_cc0(
        fixture: &fixture,
        filename: CROWD_NATIVE_MORPH_CUBE,
        expected_hash: CROWD_NATIVE_MORPH_CUBE_SHA,
    )!!;
    crowd_native_flat_source_materials(&fixture, model_id);
    LodNativeSubject subject = morph_cube_lod_subject(&fixture, model_id);
    GeometryId reduced = subject.geometries[0][1];
    CrowdNativePair pair;
    create_crowd_native_morph_pair(&fixture, &pair, model_id)!!;
    defer scene::destroy_scene(&pair.scene);
    float duration = fixture.assets.clip(subject.clip).data.duration;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        float time = (0.2f + 0.25f * (float)source) * duration;
        crowd_native_action_controls(player.base_action()!!, time);
        crowd_native_action_controls(animator.action(pair.ordinary_base[source]), time);
    }
    crowd_native_update(&fixture, &pair, 0);
    LodNativeDescriptor descriptor;
    model::attach_animated_lod(
        assets: &fixture.assets,
        scene: &pair.scene,
        owner: pair.crowd,
        desc: lod_native_desc(
            fixture: &fixture,
            subject: &subject,
            descriptor: &descriptor,
            crowd: true,
        ),
    )!!;
    CrowdNativeOutput[2] outputs;
    foreach (&output : outputs) {
        create_crowd_native_output(&fixture, output)!!;
        configure_crowd_native_temporal(&fixture, output)!!;
    }
    defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
    for (uint frame = 0; frame < 2; frame++) {
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        check_crowd_native_temporal_flags(&outputs[0].actual, frame ? 0 : 1);
    }

    pair.scene.get(pair.camera, Camera).ortho_height = 40;
    set_lod_native_reference_level(
        fixture: &fixture,
        pair: &pair,
        subject: &subject,
        level: 1,
    );
    capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
    (void)check_crowd_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 1,
        still: false,
    );
    capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
    check_crowd_native_temporal_flags(&outputs[0].actual, 0);

    @pool() {
        Geometry replacement = fixture.assets.geometry(reduced).data;
        uint[] indices = alloc::new_array(tmem, uint, replacement.indices.len);
        for (sz face = 0; face < replacement.indices.len / 3; face++) {
            sz from = (face + 1) % (replacement.indices.len / 3);
            indices[face * 3:3] = replacement.indices[from * 3:3];
        }
        replacement.indices = indices;
        fixture.assets.replace_geometry(reduced, &replacement)!!;
    };
    model::sync_animated_lod(&fixture.assets, &pair.scene, pair.crowd)!!;
    for (uint frame = 0; frame < 2; frame++) {
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        (void)check_crowd_native_view_motion(outputs[..], 0, frame ? 0 : 1);
    }

    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    CrowdInstance[CROWD_NATIVE_INSTANCES] replacement;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        replacement[source] = {
            .placement = crowd.placements[source],
            .pose = { .clip = subject.clip, .time = player.base_action()!!.time, .speed = 0, .loop = false },
            .color = crowd.colors[source],
        };
    }
    for (uint count = 2; count <= CROWD_NATIVE_INSTANCES; count++) {
        model::set_crowd(
            assets: &fixture.assets,
            scene: &pair.scene,
            node: pair.crowd,
            instances: replacement[:count],
        )!!;
        pair.ordinary[2].visible = count == CROWD_NATIVE_INSTANCES;
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        assert(crowd.count == count);
        (void)check_crowd_native_view_motion(outputs[..], 0, 1);
    }
    capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
    (void)check_crowd_native_view_motion(outputs[..], 0, 0);

    model::replace_animated_lod(
        assets: &fixture.assets,
        scene: &pair.scene,
        owner: pair.crowd,
        desc: lod_native_desc(
            fixture: &fixture,
            subject: &subject,
            descriptor: &descriptor,
            crowd: true,
        ),
    )!!;
    for (uint frame = 0; frame < 2; frame++) {
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        check_crowd_native_temporal_flags(&outputs[0].actual, frame ? 0 : 1);
    }
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animated_lod_native_admitted_channel_metadata_edit_rejects_current_pose() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model_id = load_crowd_native_cc0(
        fixture: &fixture,
        filename: CROWD_NATIVE_MORPH_CUBE,
        expected_hash: CROWD_NATIVE_MORPH_CUBE_SHA,
    )!!;
    crowd_native_flat_source_materials(&fixture, model_id);
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    LodNativeSubject subject = {
        .model = model_id,
        .clip = template.clips[0],
        .level_count = 2,
        .thresholds = { 0.2f, 0, 0 },
    };
    identity_lod_native_order(&subject);
    @pool() {
        Geometry named = fixture.assets.geometry(template.meshes[0].geometry).data;
        named.channels = alloc::new_array(tmem, MorphChannel, 2);
        String[2] names = { "square", "cube" };
        foreach (uint index, &channel : named.channels) {
            *channel = {
                .name = names[index],
                .first_target = index,
                .full_weights = alloc::new_array(tmem, float, 1),
            };
            channel.full_weights[0] = 1;
        }
        template.meshes[0].geometry = subject.geometries[0][0] = fixture.assets.add_geometry(&named)!!;
        subject.geometries[0][1] = fixture.assets.add_geometry(&named)!!;
    };
    GeometryId selected = subject.geometries[0][1];
    CrowdNativePair pair;
    create_crowd_native_morph_pair(&fixture, &pair, model_id)!!;
    defer scene::destroy_scene(&pair.scene);
    crowd_native_phase(&pair, 0.5f)!!;
    crowd_native_update(&fixture, &pair, 0);
    LodNativeDescriptor descriptor;
    model::attach_animated_lod(
        assets: &fixture.assets,
        scene: &pair.scene,
        owner: pair.crowd,
        desc: lod_native_desc(
            fixture: &fixture,
            subject: &subject,
            descriptor: &descriptor,
            crowd: true,
        ),
    )!!;
    set_lod_native_reference_level(
        fixture: &fixture,
        pair: &pair,
        subject: &subject,
        level: 1,
    );
    CrowdNativeOutput[2] outputs;
    foreach (&output : outputs) {
        create_crowd_native_output(&fixture, output)!!;
        configure_crowd_native_temporal(&fixture, output, -16)!!;
    }
    defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
    for (uint frame = 0; frame < 2; frame++) {
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        (void)check_crowd_native_view_motion(outputs[..], 0, frame ? 0 : 1);
    }

    @pool() {
        Geometry changed = fixture.assets.geometry(selected).data;
        changed.channels = alloc::clone_slice(tmem, changed.channels);
        foreach (&channel : changed.channels) {
            channel.full_weights = alloc::clone_slice(tmem, channel.full_weights);
            channel.full_weights[0] = 0.75f;
        }
        fixture.assets.replace_geometry(selected, &changed)!!;
    };
    model::sync_animated_lod(&fixture.assets, &pair.scene, pair.crowd)!!;
    for (uint frame = 0; frame < 2; frame++) {
        capture_crowd_native_temporal(&fixture, &pair, outputs[..])!!;
        (void)check_crowd_native_view_motion(outputs[..], 0, frame ? 0 : 1);
    }
    check_crowd_native_validation(&fixture.renderer);
}

fn void test_animated_lod_native_cull_overflow_falls_back_whole_group_with_source_parity_and_shadows() @test {
    Fixture fixture;
    create_fixture(
        allocator: mem,
        fixture: &fixture,
        instance_cull_bytes: 768,
        shadow_resolution: 128,
        max_shadow_layers: 1,
    )!!;
    defer destroy_fixture(&fixture);
    PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: parts.mixed,
        clip: parts.posing,
        bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
    )!!;
    defer scene::destroy_scene(&pair.scene);
    use_crowd_native_standard_materials(&fixture, &pair)!!;
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(24, 0.1f, 100);
    set_animated_lod_native_motion(
        fixture: &fixture,
        pair: &pair,
        phase_offset: 0.04f,
        placement_offset: 0.1f,
    );
    @pool() {
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed),
        )!!;
    };
    LodLevel[2] fitting_levels = {
        { .first_part = 0, .part_count = 1, .min_screen_size = 100 },
        { .first_part = 1, .part_count = 1, .min_screen_size = 0 },
    };
    LodPart[2] fitting_parts = {
        { .geometry = fixture.box, .material = parts.material, .local = matrix::IDENTITY4 },
        { .geometry = fixture.box, .material = parts.material, .local = matrix::IDENTITY4 },
    };
    Transform[1] fitting_placement = { maths::TRANSFORM_IDENTITY };
    fitting_placement[0].position.x = 1000;
    Node* fitting = pair.scene.add_instanced_lod_group(
        assets: &fixture.assets,
        desc: { .levels = fitting_levels[..], .parts = fitting_parts[..] },
        capacity: 1,
        transforms: fitting_placement[..],
        parent: pair.crowd,
    )!!;
    pair.scene.set_lod_effects(fitting, { .receive_shadow = true });
    add_lod_native_sun(&pair, 30)!!;
    CrowdLodNativeSources sources = { .crowd = true };
    CrowdNativeOutput actual;
    create_crowd_native_output(&fixture, &actual)!!;
    defer destroy_crowd_native_output(&fixture, &actual);
    CrowdNativeOutput reference;
    create_crowd_native_output(&fixture, &reference)!!;
    defer destroy_crowd_native_output(&fixture, &reference);
    foreach (AntiAliasing anti_aliasing : { AntiAliasing.TAA, AntiAliasing.NONE }) {
        foreach (output : (CrowdNativeOutput*[2]){ &actual, &reference }) {
            ViewDesc desc = render::texture_view_desc(output.target);
            desc.shading = ShadingPath.DEFERRED;
            desc.post.anti_aliasing = anti_aliasing;
            desc.post.motion_blur = true;
            desc.lod_bias = -16;
            desc.share_shadows = false;
            render::configure_view(&fixture.renderer, output.view, desc)!!;
        }
        capture_lod_native_shadowed(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        Stats* stats = &actual.actual.stats;
        assert(stats.lod_counts_valid && stats.lod_fallbacks == 1);
        assert(stats.lod_instances_tested == CROWD_NATIVE_INSTANCES + 1);
        assert(stats.lod_selected[0] == CROWD_NATIVE_INSTANCES && stats.lod_selected[1] == 1);
        assert(stats.lod_visible[0] == CROWD_NATIVE_INSTANCES && stats.lod_visible[1] == 0);
        if (anti_aliasing == AntiAliasing.TAA) {
            check_crowd_native_temporal_flags(&actual.actual, 1);
            check_crowd_native_image(actual.actual.depth, reference.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
            check_crowd_native_image(reference.actual.depth, actual.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
            check_crowd_native_normals(&actual.actual, &reference.actual);
        } else {
            check_lod_native_view_parity(&actual.actual, &reference.actual);
        }
    }
    check_crowd_native_validation(&fixture.renderer);
}
