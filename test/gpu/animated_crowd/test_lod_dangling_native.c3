module c3d::render::acceptance;

import std::math;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::spatial;
import c3d::test::animated_crowd_fixtures;
import std::io;
import gpu;

fn void? capture_animated_lod_dangling_output(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdNativeOutput* output,
) @private {
    Renderer* renderer = &fixture.renderer;
    pair.crowd.visible = true;
    pair.references.visible = false;
    pair.scene.update_world();
    renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&pair.scene, pair.camera, output.view)!;
    ViewRecord* record = renderer.views.get(output.view);
    record_crowd_native_target(
        fixture: fixture,
        probe: &output.probe,
        target: &record.depth,
        mapped: output.probe.depth,
    )!;
    assert(renderer.shadow_set.layer_count == 1 && renderer.shadow_set.light_count == 1);
    uint layer = renderer.shadow_set.lights[0].first_layer;
    uint resolution = renderer.shadow_atlas.resolution;
    Target shadow = {
        .texture = renderer.shadow_atlas.texture,
        .view = renderer.shadow_atlas.layers[layer].view,
        .state = renderer.shadow_atlas.state,
        .format = gpu::Format.D32_FLOAT,
        .width = resolution,
        .height = resolution,
    };
    record_crowd_native_target(
        fixture: fixture,
        probe: &output.probe,
        target: &shadow,
        mapped: output.probe.shadow,
    )!;
    renderer.shadow_atlas.state = shadow.state;
    renderer.finish_view(output.view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, output.probe.depth.span)!;
    gpu::invalidate_mapped_span(&renderer.device, output.probe.shadow.span)!;
    mem::copy(output.actual.depth.ptr, output.probe.depth.bytes.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
    mem::copy(output.actual.shadow.ptr, output.probe.shadow.bytes.ptr,
        (sz)resolution * resolution * Vec4::size);
    output.actual.shadow_resolution = resolution;
    output.actual.stats = renderer.stats;
}

fn uint animated_lod_dangling_coverage(Vec4[] pixels) @private {
    uint covered;
    foreach (pixel : pixels) covered += pixel.x > 0 ? 1 : 0;
    return covered;
}

fn void test_animated_lod_native_dangling_source_skips_whole_main_and_shadow_owner() @test {
    for (uint mutation = 0; mutation < 5; mutation++) {
        Fixture fixture;
        create_fixture(
            allocator: mem,
            fixture: &fixture,
            shadow_resolution: 128,
            max_shadow_layers: 1,
            max_views: 16,
            max_render_targets: 16,
        )!!;
        defer destroy_fixture(&fixture);
        PartsFixture parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)!!;
        bool crowd = mutation >= 3;
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: parts.mixed,
            clip: parts.posing,
            bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            tinted: false,
        )!!;
        defer scene::destroy_scene(&pair.scene);
        if (!crowd) {
            pair.scene.remove(pair.crowd);
            pair.crowd = model::instantiate(&fixture.assets, &pair.scene, parts.mixed)!!;
            pair.crowd.local = pair.ordinary[1].local;
            Animator* animator = anim::add_animator(&pair.scene, pair.crowd);
            AnimationActionId action = animator.play(&fixture.assets, parts.posing)!!;
            animator.action(action).time = 0.5f;
            animator.action(action).speed = 0;
            animator.action(action).loop = false;
        }
        anim::update(&fixture.assets, &pair.scene, 0);
        anim::crowd_update(&fixture.assets, &pair.scene, 0);
        @pool() {
            model::attach_animated_lod(
                assets: &fixture.assets,
                scene: &pair.scene,
                owner: pair.crowd,
                desc: lod_trace_desc(&fixture.assets, parts.mixed),
            )!!;
        };
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(24, 0.1f, 100);
        Light sun = light::directional({ 1, 1, 1 }, 1);
        sun.shadow.cascades = 1;
        sun.shadow.max_distance = 30;
        Node* light_node = pair.scene.add_light(sun)!!;
        light_node.local.rotation = maths::look_rotation((Vec3){ -0.8f, -0.3f, -1 }.normalize(), { 0, 1, 0 });
        pair.scene.update_world();
        CrowdNativeOutput output;
        create_crowd_native_output(&fixture, &output)!!;
        defer destroy_crowd_native_output(&fixture, &output);
        ViewDesc view = render::texture_view_desc(output.target);
        view.shading = ShadingPath.DEFERRED;
        view.lod_bias = 16;
        view.share_shadows = false;
        render::configure_view(&fixture.renderer, output.view, view)!!;
        capture_animated_lod_dangling_output(&fixture, &pair, &output)!!;
        uint main_before = animated_lod_dangling_coverage(output.actual.depth);
        uint resolution = output.actual.shadow_resolution;
        uint shadow_before = animated_lod_dangling_coverage(output.actual.shadow[:(sz)resolution * resolution]);
        assert(main_before > 0 && shadow_before > 0 && output.actual.stats.dangling_refs == 0);
        LodGroupState* state = pair.scene.get(pair.crowd, LodGroup).state;
        ulong identity = state.identity;
        uint surviving_parts;
        if (mutation == 0 || mutation == 1) {
            ModelInstance* instance = pair.scene.get(pair.crowd, ModelInstance);
            uint missing = mutation == 0 ? animated_crowd_fixtures::PARTS_RIGID_NODE
              : animated_crowd_fixtures::PARTS_JOINT_TIP;
            pair.scene.remove(instance.present_node(missing));
            foreach (template_node : instance.mesh_nodes) {
                Node* node = instance.present_node(template_node);
                if (node && pair.scene.has(node, Mesh)) surviving_parts++;
            }
        } else if (mutation == 3) {
            AnimatedCrowd* source = pair.scene.get(pair.crowd, AnimatedCrowd);
            pair.scene.remove(pair.scene.node(source.parts[1].batch));
            foreach (part : source.parts) {
                if (pair.scene.world.is_alive(part.batch)) surviving_parts++;
            }
        } else {
            GeometryId retired = state.desc.parts[0].geometry;
            fixture.assets.remove_geometry(retired);
            foreach (mesh : fixture.assets.model(parts.mixed).data.meshes) {
                if (fixture.assets.geometries.is_live(mesh.geometry)) surviving_parts++;
            }
        }
        assert(surviving_parts > 0);
        pair.scene.update_world();
        assert(!spatial::lod_group_is_live(
            assets: &fixture.assets,
            group: pair.scene.get(pair.crowd, LodGroup),
            scene: &pair.scene,
            node: pair.crowd,
        ));
        LodGroupState before_render = *state;
        capture_animated_lod_dangling_output(&fixture, &pair, &output)!!;
        assert(output.actual.stats.dangling_refs > 0);
        assert(animated_lod_dangling_coverage(output.actual.depth) == 0);
        assert(animated_lod_dangling_coverage(output.actual.shadow[:(sz)resolution * resolution]) == 0);
        assert(pair.scene.get(pair.crowd, LodGroup).state == state && state.identity == identity);
        assert(mem::equals((char*)state, (char*)&before_render, LodGroupState::size));
        io::printfn("dangling owner=%s mutation=%s", crowd ? "crowd" : "ordinary", mutation);
        io::printfn("main_before=%s shadow_before=%s", main_before, shadow_before);
        io::printfn("surviving_parts=%s dangling_refs=%s", surviving_parts, output.actual.stats.dangling_refs);
        check_crowd_native_validation(&fixture.renderer);
    }
}
