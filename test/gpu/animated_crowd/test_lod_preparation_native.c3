module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::test::animated_crowd_fixtures;
import gpu;
import std::io;
import std::math;

fn void check_animated_lod_native_prepared_switch(bool crowd) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    BoundsNativeAssets assets = add_bounds_native_assets(&fixture)!!;
    Transform[CROWD_NATIVE_INSTANCES] placements;
    foreach (index, &placement : placements) {
        *placement = maths::TRANSFORM_IDENTITY;
        placement.position.x = (float)index * 3 - 3;
        placement.scale = { index == 2 ? -0.5f : 0.5f, 0.5f, 0.5f };
    }
    CrowdNativePair pair;
    create_crowd_native_pair(
        allocator: mem,
        fixture: &fixture,
        pair: &pair,
        model: assets.fixture.mixed,
        clip: assets.clip,
        bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
        placements: placements[..],
        tinted: false,
    )!!;
    defer scene::destroy_scene(&pair.scene);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(25, 0.1f, 100);
    CrowdLodNativeSources sources;
    attach_bounds_native_sources(
        fixture: &fixture,
        pair: &pair,
        assets: &assets,
        sources: &sources,
        crowd: crowd,
    )!!;
    Material lower = material::standard();
    lower.common.alpha_mode = AlphaMode.MASK;
    lower.common.alpha_cutoff = 0.2f;
    MaterialId lower_material = fixture.assets.add_material(lower)!!;
    uint owners = crowd ? 1 : CROWD_NATIVE_INSTANCES;
    for (uint owner = 0; owner < owners; owner++) {
        LodGroupState* state = pair.scene.get(bounds_native_owner(&pair, &sources, owner), LodGroup).state;
        uint first = state.desc.levels[1].first_part;
        foreach (&part : state.desc.parts[first:state.desc.levels[1].part_count]) part.material = lower_material;
    }
    pair.references.visible = false;
    crowd_native_update(&fixture, &pair, 0);
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(TARGET_SIZE, TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!!;
    ViewId view = render::create_view(&fixture.renderer, render::texture_view_desc(target))!!;
    Renderer* renderer = &fixture.renderer;
    for (uint path = 0; path < 3; path++) {
        ViewDesc desc = render::texture_view_desc(target);
        desc.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        desc.depth_prepass = path == 1;
        desc.post.motion_blur = false;
        desc.lod_bias = 16;
        pair.crowd.visible = false;
        for (uint owner = 0; owner < owners; owner++) {
            bounds_native_owner(&pair, &sources, owner).visible = false;
        }
        pair.scene.update_world();
        assert(!pair.references.visible_effective && !pair.crowd.visible_effective);

        render::configure_view(renderer, view, desc)!!;
        renderer.begin_frame()!!;
        renderer.render_view(&pair.scene, pair.camera, view)!!;
        renderer.finish_view(view)!!;
        renderer.end_frame()!!;
        render::wait_frames(renderer)!!;

        if (path == 0) {
            renderer.pipelines.pipelines.@each(; PipelineKey key, gpu::PipelineHandle pipeline) {
                uint deformation = shader::SHADER_FLAG_SKINNED | shader::SHADER_FLAG_SKINNED_U16
                  | shader::SHADER_FLAG_MORPH;
                assert((key.vertex.flags & deformation) == 0,
                    "Hidden warm-up populated a deformation pipeline");
            };
        }

        pair.crowd.visible = true;
        for (uint owner = 0; owner < owners; owner++) {
            bounds_native_owner(&pair, &sources, owner).visible = true;
        }
        pair.scene.update_world();
        desc.post.motion_blur = true;
        render::configure_view(renderer, view, desc)!!;
        ulong warm_calls = renderer.pipelines.creations.calls;
        renderer.prepare_scene(&pair.scene)!!;
        ulong prepared_calls = renderer.pipelines.creations.calls;
        PipelineKey[] prepared_keys = alloc::new_array(mem, PipelineKey, renderer.pipelines.pipelines.len());
        defer alloc::free(mem, prepared_keys.ptr);
        usz prepared_count;
        renderer.pipelines.pipelines.@each(; PipelineKey key, gpu::PipelineHandle pipeline) {
            prepared_keys[prepared_count++] = key;
        };
        if (path == 0) assert(prepared_calls > warm_calls, "Preparation did not create deformation pipelines");
        for (uint level = 0; level < 2; level++) {
            desc.lod_bias = level == 0 ? 16 : -16;
            render::configure_view(renderer, view, desc)!!;
            for (uint frame = 0; frame < CROWD_NATIVE_WARMUP; frame++) {
                renderer.begin_frame()!!;
                renderer.render_view(&pair.scene, pair.camera, view)!!;
                renderer.finish_view(view)!!;
                renderer.end_frame()!!;
                if (renderer.pipelines.creations.calls != prepared_calls) {
                    renderer.pipelines.pipelines.@each(; PipelineKey key, gpu::PipelineHandle pipeline) {
                        bool found;
                        foreach (prepared : prepared_keys) found |= prepared.equals(key);
                        if (!found) {
                            io::printfn("New vertex=%s flags=%s", key.vertex.shader, key.vertex.flags);
                            io::printfn("New fragment=%s flags=%s", key.fragment.shader, key.fragment.flags);
                        }
                    };
                }
                assert(renderer.pipelines.creations.calls == prepared_calls,
                    "Prepared animated LOD switch created a graphics pipeline");
            }
            render::wait_frames(renderer)!!;
            Stats* stats = &renderer.stats;
            assert(stats.lod_fallbacks == 0 && stats.cull_overflows == 0);
            if (crowd) {
                assert(stats.lod_counts_valid && stats.lod_selected[level] == CROWD_NATIVE_INSTANCES);
            } else {
                assert(stats.lod_objects_selected[level] == CROWD_NATIVE_INSTANCES);
            }
        }
        io::printfn("prepared animated LOD crowd=%s path=%s no additional pipeline creations", crowd, path);
    }
    check_crowd_native_validation(renderer);
}

fn void test_animated_lod_native_preparation_covers_ordinary_lower_skin_and_morph_variants() @test {
    check_animated_lod_native_prepared_switch(false);
}

fn void test_animated_lod_native_preparation_covers_crowd_lower_skin_and_morph_variants() @test {
    check_animated_lod_native_prepared_switch(true);
}
