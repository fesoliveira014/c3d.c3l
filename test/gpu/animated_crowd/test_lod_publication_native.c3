module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import gpu;

fn ModelId? create_animated_lod_publication_pair(Fixture* fixture, CrowdNativePair* pair) @private {
    ModelId model_id = load_crowd_native_cc0(
        fixture: fixture,
        filename: CROWD_NATIVE_MORPH_CUBE,
        expected_hash: CROWD_NATIVE_MORPH_CUBE_SHA,
    )!;
    crowd_native_flat_source_materials(fixture, model_id);
    ModelTemplate* template = &fixture.assets.model(model_id).data;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (&placement : placements) placement.scale *= 0.6f;
    create_crowd_native_pair(
        allocator: mem,
        fixture: fixture,
        pair: pair,
        model: model_id,
        clip: template.clips[0],
        bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
        placements: placements[..],
    )!;
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 0, 12 };
    set_animated_lod_native_motion(
        fixture: fixture,
        pair: pair,
        phase_offset: 0,
        placement_offset: 0,
    );
    @pool() {
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: lod_trace_desc(&fixture.assets, model_id),
        )!;
    };
    return model_id;
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
    assert(template.meshes.len == 1 && template.meshes[0].default_morph_weights.len == 2);
    GeometryId original = template.meshes[0].geometry;
    GeometryId selected;
    @pool() {
        Geometry named = fixture.assets.geometry(original).data;
        assert(named.targets.len == 2);
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
        template.meshes[0].geometry = fixture.assets.add_geometry(&named)!!;
        selected = fixture.assets.add_geometry(&named)!!;
    };
    CrowdNativePair pair;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (&placement : placements) placement.scale *= 0.6f;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: model_id,
        clip: template.clips[0],
        bounds: { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
        placements: placements[..],
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(5, 0.1f, 100);
    pair.camera.local.position = { 0, 0, 12 };
    crowd_native_phase(&pair, 0.5f)!!;
    crowd_native_update(&fixture, &pair, 0);
    @pool() {
        AnimatedLodDesc desc = lod_trace_desc(&fixture.assets, model_id);
        desc.parts[1].draw.geometry = selected;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: desc,
        )!!;
    };
    set_animated_lod_native_reference_geometry(&pair, template, selected);
    CrowdNativeOutput[2] outputs;
    for (uint index = 0; index < outputs.len; index++) {
        create_crowd_native_output(&fixture, &outputs[index])!!;
        configure_crowd_native_temporal(&fixture, &outputs[index])!!;
        ViewDesc desc = fixture.renderer.views.get(outputs[index].view).desc;
        desc.lod_bias = -16;
        render::configure_view(&fixture.renderer, outputs[index].view, desc)!!;
    }
    defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
    for (uint frame = 0; frame < 2; frame++) {
        animated_lod_native_temporal_frame(
            fixture: &fixture,
            pair: &pair,
            crowd: &outputs[0],
            ordinary: &outputs[1],
        )!!;
        (void)check_animated_lod_native_view_motion(
            outputs: outputs[..],
            view: 0,
            rejection: frame ? 0 : 1,
            still: true,
        );
    }
    LodGroupState* state = pair.scene.get(pair.crowd, LodGroup).state;
    ulong identity = state.identity;
    uint descriptor_revision = state.descriptor_revision;
    AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
    float[] weights = crowd.playback.logical_weights[0];
    MorphSelection before = geometry::select_morph_targets(fixture.assets.geometry(selected).data.channels, weights);
    uint vertices = fixture.assets.geometry(selected).vertex_count;
    uint indices = fixture.assets.geometry(selected).index_count;
    uint revision = fixture.assets.geometry(selected).header.revision;
    @pool() {
        Geometry changed = fixture.assets.geometry(selected).data;
        changed.channels = alloc::clone_slice(tmem, changed.channels);
        foreach (&channel : changed.channels) {
            channel.full_weights = alloc::clone_slice(tmem, channel.full_weights);
            channel.full_weights[0] = 0.75f;
        }
        fixture.assets.replace_geometry(selected, &changed)!!;
    };
    assert(fixture.assets.geometry(selected).header.revision != revision);
    assert(fixture.assets.geometry(selected).vertex_count == vertices
      && fixture.assets.geometry(selected).index_count == indices);
    MorphSelection after = geometry::select_morph_targets(fixture.assets.geometry(selected).data.channels, weights);
    assert(!mem::equals(&before, &after, MorphSelection::size),
      "Channel metadata mutation must change packed weights.");
    model::sync_animated_lod(&fixture.assets, &pair.scene, pair.crowd)!!;
    assert(state.identity == identity && state.descriptor_revision == descriptor_revision);
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &outputs[0],
        ordinary: &outputs[1],
    )!!;
    (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 1,
        still: true,
    );
    animated_lod_native_temporal_frame(
        fixture: &fixture,
        pair: &pair,
        crowd: &outputs[0],
        ordinary: &outputs[1],
    )!!;
    (void)check_animated_lod_native_view_motion(
        outputs: outputs[..],
        view: 0,
        rejection: 0,
        still: true,
    );
    check_crowd_native_validation(&fixture.renderer);
}
