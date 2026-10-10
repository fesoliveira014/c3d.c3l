module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::io;
import std::math;

fn void? animated_lod_native_temporal_frame(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput* crowd,
    CrowdNativeOutput* ordinary,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    record_crowd_native_temporal_view(
        fixture: fixture,
        pair: pair,
        output: crowd,
        crowd_visible: true,
    )!;
    record_crowd_native_temporal_view(
        fixture: fixture,
        pair: pair,
        output: ordinary,
        crowd_visible: false,
    )!;
    assert(renderer.deformation.animated_palettes.len() == 1, "Current source palette was uploaded more than once");
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    read_crowd_native_temporal(fixture, crowd)!;
    read_crowd_native_temporal(fixture, ordinary)!;
}

fn void test_animated_lod_native_rgba_equal_count_parity_and_replacement() @test {
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
    @pool() {
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: lod_trace_desc(&fixture.assets, parts.mixed),
        )!!;
    };
    CrowdNativeOutput actual;
    create_crowd_native_output(&fixture, &actual)!!;
    defer destroy_crowd_native_output(&fixture, &actual);
    CrowdNativeOutput expected;
    create_crowd_native_output(&fixture, &expected)!!;
    defer destroy_crowd_native_output(&fixture, &expected);
    configure_crowd_native_temporal(&fixture, &actual)!!;
    configure_crowd_native_temporal(&fixture, &expected)!!;
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 1);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    crowd.placements[0].scale.x = -crowd.placements[0].scale.x;
    crowd.placements[2].scale.x = -crowd.placements[2].scale.x;
    pair.ordinary[0].local.scale.x = -pair.ordinary[0].local.scale.x;
    pair.ordinary[2].local.scale.x = -pair.ordinary[2].local.scale.x;
    pair.scene.write_crowd_batches(crowd);
    crowd_native_update(&fixture, &pair, 0);
    assert(crowd.count == CROWD_NATIVE_INSTANCES && crowd.parts.len == animated_crowd_fixtures::PARTS_MESH_COUNT);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0, false);
    check_crowd_native_image(actual.actual.depth, expected.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(expected.actual.depth, actual.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_velocity(actual.actual.velocity, expected.actual.velocity);
    check_crowd_native_velocity(expected.actual.velocity, actual.actual.velocity);
    float largest_motion;
    foreach (index, depth : expected.actual.depth) {
        if (depth.x <= 0) continue;
        Vec4 velocity = expected.actual.velocity[index];
        largest_motion = math::max(largest_motion, math::max(math::abs(velocity.x), math::abs(velocity.y)));
    }
    assert(largest_motion > 10 * CROWD_NATIVE_VELOCITY_TOLERANCE);
    io::printfn("RGBA equal-count swap instances=%s parts=%s", crowd.count, crowd.parts.len);
    io::printfn("Largest expected UV motion=%s", largest_motion);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
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
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 1);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &expected,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
    check_crowd_native_validation(&fixture.renderer);
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

fn void? capture_animated_lod_native_views(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput[] outputs,
    uint views,
    bool aborted = false,
    gpu::MappedGpuSpan[] histories = {},
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    for (uint view = 0; view < 2; view++) {
        if (!(views & (1u << view))) continue;
        for (uint source = 0; source < 2; source++) {
            record_crowd_native_temporal_view(
                fixture: fixture,
                pair: pair,
                output: &outputs[2 * view + source],
                crowd_visible: source == 0,
            )!;
            if (source == 0 && histories.len) {
                record_crowd_lod_native_history(
                    fixture: fixture,
                    pair: pair,
                    view: outputs[2 * view].view,
                    readback: histories[view],
                )!;
            }
        }
    }
    assert(renderer.deformation.animated_palettes.len() == 1);
    if (aborted) {
        render::abort_frame(renderer);
        return;
    }
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    for (uint view = 0; view < 2; view++) {
        if (!(views & (1u << view))) continue;
        if (histories.len) gpu::invalidate_mapped_span(&renderer.device, histories[view].span)!;
        for (uint source = 0; source < 2; source++) {
            read_crowd_native_temporal(fixture, &outputs[2 * view + source])!;
        }
    }
}

fn float check_animated_lod_native_view_motion(
    CrowdNativeOutput[] outputs,
    uint view,
    float rejection,
    bool still,
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
            desc: lod_trace_desc(&fixture.assets, parts.mixed),
        )!!;
    };
    gpu::MappedGpuSpan[2] histories;
    for (uint view = 0; view < 2; view++) histories[view] = allocate_crowd_lod_native_history(&fixture.renderer)!!;
    defer foreach (history : histories) free_crowd_lod_native_history(&fixture.renderer, history);
    CrowdNativeOutput[4] outputs;
    for (uint index = 0; index < outputs.len; index++) {
        create_crowd_native_output(&fixture, &outputs[index])!!;
        configure_crowd_native_temporal(&fixture, &outputs[index])!!;
    }
    defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 3,
        histories: histories[..],
    )!!;
    for (uint view = 0; view < 2; view++) (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: (uint)view,
        rejection: 1,
        still: true,
    );
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 3,
        histories: histories[..],
    )!!;
    for (uint view = 0; view < 2; view++) (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: (uint)view,
        rejection: 0,
        still: true,
    );
    ViewHistory* skipped = &fixture.renderer.views.get(outputs[2].view).history;
    ulong skipped_serial = skipped.serial;
    set_animated_lod_native_motion(
        fixture: &fixture,
        pair: &pair,
        phase_offset: 0.04f,
        placement_offset: 0.12f,
    );
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 1,
        histories: histories[..],
    )!!;
    assert(skipped.valid && skipped.serial == skipped_serial);
    float first_motion = check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 0,
        still: false,
    );
    assert(first_motion > CROWD_NATIVE_VELOCITY_TOLERANCE);
    set_animated_lod_native_motion(
        fixture: &fixture,
        pair: &pair,
        phase_offset: 0.08f,
        placement_offset: 0.24f,
    );
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 3,
        histories: histories[..],
    )!!;
    float resumed_motion = check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 1,
        rejection: 0,
        still: false,
    );
    (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 0,
        still: false,
    );
    assert(resumed_motion > first_motion + CROWD_NATIVE_VELOCITY_TOLERANCE);
    render::reset_view_history(&fixture.renderer, outputs[0].view)!!;
    render::reset_view_history(&fixture.renderer, outputs[1].view)!!;
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 3,
        histories: histories[..],
    )!!;
    (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 1,
        still: true,
    );
    (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 1,
        rejection: 0,
        still: true,
    );
    uint[2] committed_slots;
    for (uint view = 0; view < 2; view++) {
        committed_slots[view] = fixture.renderer.views.get(outputs[2 * view].view)
            .lod_history.entries[pair.crowd.id.index].committed_slot;
    }
    set_animated_lod_native_motion(
        fixture: &fixture,
        pair: &pair,
        phase_offset: 0.12f,
        placement_offset: 0.36f,
    );
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 3,
        aborted: true,
        histories: histories[..],
    )!!;
    for (uint view = 0; view < 2; view++) {
        ViewRecord* record = fixture.renderer.views.get(outputs[2 * view].view);
        assert(!record.history.valid && !record.history.pending);
        assert(record.lod_history.entries[pair.crowd.id.index].committed_slot == committed_slots[view]);
    }
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 3,
        histories: histories[..],
    )!!;
    for (uint view = 0; view < 2; view++) (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: (uint)view,
        rejection: 1,
        still: true,
    );
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 3,
        histories: histories[..],
    )!!;
    for (uint view = 0; view < 2; view++) (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: (uint)view,
        rejection: 0,
        still: true,
    );
    foreach (history : histories) {
        shader::LodHistoryGpu[] rows = ((shader::LodHistoryGpu*)history.bytes.ptr)[:CROWD_NATIVE_INSTANCES];
        foreach (row : rows) assert(row.level == 0 && row.reject_history == 0);
    }
    pair.scene.get(pair.camera, Camera).ortho_height = 80;
    capture_animated_lod_native_views(
        fixture: &fixture,
        pair: &pair,
        outputs: outputs[..],
        views: 3,
        histories: histories[..],
    )!!;
    for (uint view = 0; view < 2; view++) (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: (uint)view,
        rejection: 0,
        still: false,
    );
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    foreach (history : histories) {
        shader::LodHistoryGpu[] rows = ((shader::LodHistoryGpu*)history.bytes.ptr)[:CROWD_NATIVE_INSTANCES];
        foreach (source, row : rows) {
            assert(row.level == 1 && row.reject_history == 0);
            assert(row.generation == crowd.playback.slots[source].generation);
            assert(row.model == bitcast(crowd.placements[source].to_mat4(), Mat4f));
        }
    }
    io::printfn("Independent view motion: first=%s resumed=%s; skip/cut/abort and compatible-level correspondence pass",
        first_motion, resumed_motion);
    check_crowd_native_validation(&fixture.renderer);
}

fn GeometryId add_animated_lod_native_reduced_geometry(Fixture* fixture, GeometryId source) @private {
    @pool() {
        Geometry reduced = fixture.assets.geometry(source).data;
        assert(reduced.indices.len >= 6 && reduced.indices.len % 3 == 0);
        uint triangles = (uint)reduced.indices.len / 3;
        uint kept = (triangles + 1) / 2;
        uint[] indices = alloc::new_array(tmem, uint, (sz)kept * 3);
        for (uint face = 0; face < kept; face++) {
            indices[face * 3:3] = reduced.indices[face * 6:3];
        }
        reduced.indices = indices;
        return fixture.assets.add_geometry(&reduced)!!;
    };
}

fn void set_animated_lod_native_reference_geometry(
    CrowdNativePair* pair,
    ModelTemplate* template,
    GeometryId geometry,
) @private {
    assert(template.meshes.len == 1);
    foreach (root : pair.ordinary) {
        ModelInstance* instance = pair.scene.get(root, ModelInstance);
        Node* mesh_node = instance.present_node(template.meshes[0].node);
        pair.scene.get(mesh_node, Mesh).geometry = geometry;
    }
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
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    assert(template.meshes.len == 1 && !template.skins.len && template.clips.len > 0);
    GeometryId base = template.meshes[0].geometry;
    GeometryId reduced = add_animated_lod_native_reduced_geometry(&fixture, base);
    assert(fixture.assets.geometry(reduced).data.indices.len < fixture.assets.geometry(base).data.indices.len);
    ClipId clip = template.clips[0];
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (&placement : placements) placement.scale *= 0.6f;
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: model_id,
        clip: clip,
        bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 0, 12 };
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        Animator* animator = pair.scene.get(pair.ordinary[source], Animator);
        float time = (0.2f + 0.25f * (float)source) * fixture.assets.clip(clip).data.duration;
        crowd_native_action_controls(player.base_action()!!, time);
        crowd_native_action_controls(animator.action(pair.ordinary_base[source]), time);
    }
    crowd_native_update(&fixture, &pair, 0);
    @pool() {
        AnimatedLodDesc desc = lod_trace_desc(&fixture.assets, model_id);
        desc.parts[1].draw.geometry = reduced;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: desc,
        )!!;
    };
    CrowdNativeOutput actual;
    create_crowd_native_output(&fixture, &actual)!!;
    defer destroy_crowd_native_output(&fixture, &actual);
    CrowdNativeOutput reference;
    create_crowd_native_output(&fixture, &reference)!!;
    defer destroy_crowd_native_output(&fixture, &reference);
    configure_crowd_native_temporal(&fixture, &actual)!!;
    configure_crowd_native_temporal(&fixture, &reference)!!;
    for (uint frame = 0; frame < 2; frame++) {
        animated_lod_native_temporal_frame(
            fixture: &fixture,
            pair: &pair,
            crowd: &actual,
            ordinary: &reference,
        )!!;
        check_crowd_native_temporal_flags(&actual.actual, frame ? 0 : 1);
    }
    pair.scene.get(pair.camera, Camera).ortho_height = 40;
    set_animated_lod_native_reference_geometry(&pair, template, reduced);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 1);
    check_crowd_native_image(actual.actual.depth, reference.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(reference.actual.depth, actual.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
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
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 1);
    check_crowd_native_image(actual.actual.depth, reference.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    CrowdInstance[CROWD_NATIVE_INSTANCES] replacement;
    uint[CROWD_NATIVE_INSTANCES] generations;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        CrowdPlayer player = crowd_native_player(&pair, source)!!;
        generations[source] = player.state.slots[source].generation;
        replacement[source] = {
            .placement = crowd.placements[source],
            .pose = { .clip = clip, .time = player.base_action()!!.time, .speed = 0, .loop = false },
            .color = crowd.colors[source],
        };
    }
    model::set_crowd(
        assets: &fixture.assets,
        scene: &pair.scene,
        node: pair.crowd,
        instances: replacement[:2],
    )!!;
    pair.ordinary[2].visible = false;
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    assert(crowd.count == 2);
    check_crowd_native_temporal_flags(&actual.actual, 1);
    check_crowd_native_image(actual.actual.depth, reference.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    model::set_crowd(
        assets: &fixture.assets,
        scene: &pair.scene,
        node: pair.crowd,
        instances: replacement[..],
    )!!;
    pair.ordinary[2].visible = true;
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    assert(crowd.count == CROWD_NATIVE_INSTANCES);
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        assert(crowd.playback.slots[source].generation != generations[source]);
    }
    check_crowd_native_temporal_flags(&actual.actual, 1);
    check_crowd_native_image(actual.actual.depth, reference.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(reference.actual.depth, actual.actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
    @pool() {
        AnimatedLodDesc desc = lod_trace_desc(&fixture.assets, model_id);
        desc.parts[1].draw.geometry = reduced;
        model::replace_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: desc,
        )!!;
    };
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 1);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &actual,
        ordinary: &reference,
    )!!;
    check_crowd_native_temporal_flags(&actual.actual, 0);
    io::printn("Real morph LOD: topology, binding incarnation, shrink/regrowth reject stale history");
    check_crowd_native_validation(&fixture.renderer);
}
