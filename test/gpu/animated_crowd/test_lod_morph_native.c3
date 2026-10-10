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
import std::io;

const uint[2] MORPH_LOD_NATIVE_TRIANGLES @private = { 12, 6 };
const float[2] MORPH_LOD_NATIVE_FORCE_BIASES @private = { 16, -16 };

fn void? attach_morph_lod_native_sources(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    GeometryId reduced,
    bool crowd,
) @private {
    sources.crowd = crowd;
    ModelTemplate* template = &fixture.assets.model(pair.model).data;
    assert(template.meshes.len == 1 && !template.skins.len);
    @pool() {
        AnimatedLodDesc desc = lod_trace_desc(&fixture.assets, pair.model);
        assert(desc.levels.len == 2 && desc.parts.len == 2 && !desc.has_bounds_override);
        desc.parts[1].draw.geometry = reduced;
        if (crowd) {
            model::attach_animated_lod(
                assets: &fixture.assets,
                scene: &pair.scene,
                owner: pair.crowd,
                desc: desc,
            )!;
            return;
        }
        pair.scene.remove(pair.crowd);
        pair.crowd = pair.scene.add_node(name: "morph_lod_sources")!;
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Node* actual = model::instantiate(
                assets: &fixture.assets,
                scene: &pair.scene,
                model: pair.model,
                parent: pair.crowd,
            )!;
            actual.local = pair.ordinary[source].local;
            ModelInstance* reference = pair.scene.get(pair.ordinary[source], ModelInstance);
            Mesh* reference_mesh = pair.scene.get(reference.present_node(template.meshes[0].node), Mesh);
            reference_mesh.material = template.meshes[0].material;
            model::attach_animated_lod(
                assets: &fixture.assets,
                scene: &pair.scene,
                owner: actual,
                desc: desc,
            )!;
            Animator* animator = anim::add_animator(&pair.scene, actual);
            sources.actions[source] = animator.play(&fixture.assets, template.clips[0])!;
            sources.ordinary[source] = actual;
        }
    };
}

fn void check_morph_lod_native_counts(Stats* stats, uint level, bool crowd) @private {
    assert(stats.cull_overflows == 0 && stats.sort_overflows == 0 && stats.lod_fallbacks == 0);
    if (crowd) assert(stats.lod_counts_valid && stats.lod_instances_tested == CROWD_NATIVE_INSTANCES);
    for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
        uint expected = choice == level ? CROWD_NATIVE_INSTANCES : 0;
        if (crowd) {
            assert(stats.lod_selected[choice] == expected && stats.lod_visible[choice] == expected);
        } else {
            assert(stats.lod_objects_selected[choice] == expected && stats.lod_objects_visible[choice] == expected);
        }
    }
    io::printfn("MorphCube LOD: crowd=%s level=%s selected=%s visible=%s authored_triangles=%s",
        crowd, level, CROWD_NATIVE_INSTANCES, CROWD_NATIVE_INSTANCES,
        CROWD_NATIVE_INSTANCES * MORPH_LOD_NATIVE_TRIANGLES[level]);
}

fn void check_morph_lod_native_sources_remain_base(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    GeometryId base,
) @private {
    ModelTemplate* template = &fixture.assets.model(pair.model).data;
    assert(c3d::same_id(template.meshes[0].geometry, base));
    if (sources.crowd) {
        AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
        assert(crowd.parts.len == 1 && crowd.parts[0].weight_count == 2 && !crowd.joint_count);
        InstancedMesh* batch = pair.scene.world.get(crowd.parts[0].batch, InstancedMesh);
        assert(c3d::same_id(batch.geometry, base));
        LodGroupState* state = pair.scene.get(pair.crowd, LodGroup).state;
        assert(state.desc.has_bounds_override && state.desc.local_bounds.min == crowd.pose_bounds.min);
        assert(state.desc.local_bounds.max == crowd.pose_bounds.max);
    } else {
        foreach (actual : sources.ordinary) {
            ModelInstance* instance = pair.scene.get(actual, ModelInstance);
            Mesh* mesh = pair.scene.get(instance.present_node(template.meshes[0].node), Mesh);
            assert(c3d::same_id(mesh.geometry, base) && mesh.morph_weights.len == 2);
        }
    }
}

fn void check_morph_lod_native_normals(CrowdNativeImages* actual, CrowdNativeImages* reference) @private {
    assert(actual.has_normal && reference.has_normal);
    check_crowd_native_image(actual.normal, reference.normal, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(reference.normal, actual.normal, CROWD_NATIVE_COLOR_TOLERANCE);
    foreach (images : (CrowdNativeImages*[2]){ actual, reference }) {
        uint covered;
        foreach (index, depth : images.depth) {
            if (depth.x > 0 && images.normal[index].w > 0.5f) covered++;
        }
        assert(covered > 0, "Reduced MorphCube did not write Standard G-buffer normals");
    }
}

fn void test_animated_lod_native_morph_cube_selected_levels_match_color_depth_normals_and_still_velocity() @test {
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
    GeometryId[2] levels = { base, reduced };
    for (uint level = 0; level < 2; level++) {
        Geometry* geometry = &fixture.assets.geometry(levels[level]).data;
        assert(geometry.indices.len / 3 == MORPH_LOD_NATIVE_TRIANGLES[level]);
        assert(geometry.normals.len == geometry.positions.len && geometry.targets.len == 2);
    }
    ClipId clip = template.clips[0];
    float duration = fixture.assets.clip(clip).data.duration;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (&placement : placements) placement.scale *= 0.6f;
    foreach (bool crowd : { true, false }) {
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
        use_crowd_native_standard_materials(&fixture, &pair)!!;
        CrowdLodNativeSources sources;
        attach_morph_lod_native_sources(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            reduced: reduced,
            crowd: crowd,
        )!!;
        set_crowd_lod_native_phase(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            duration: duration,
        );
        CrowdNativeOutput output;
        create_crowd_native_output(&fixture, &output)!!;
        defer destroy_crowd_native_output(&fixture, &output);
        for (uint level = 0; level < 2; level++) {
            set_animated_lod_native_reference_geometry(&pair, template, levels[level]);
            for (uint path = 0; path < 3; path++) {
                ViewDesc desc = render::texture_view_desc(output.target);
                desc.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
                desc.depth_prepass = path == 1;
                desc.lod_bias = MORPH_LOD_NATIVE_FORCE_BIASES[level];
                desc.post.anti_aliasing = AntiAliasing.NONE;
                desc.post.motion_blur = true;
                render::configure_view(&fixture.renderer, output.view, desc)!!;
                capture_crowd_native(
                    fixture: &fixture,
                    pair: &pair,
                    probe: &output.probe,
                    output: output.target,
                    view: output.view,
                    crowd_visible: true,
                    images: &output.actual,
                )!!;
                check_morph_lod_native_counts(&output.actual.stats, level, crowd);
                capture_crowd_native(
                    fixture: &fixture,
                    pair: &pair,
                    probe: &output.probe,
                    output: output.target,
                    view: output.view,
                    crowd_visible: false,
                    images: &output.expected,
                )!!;
                check_crowd_native_parity(&output.actual, &output.expected, false);
                if (path == 2) check_morph_lod_native_normals(&output.actual, &output.expected);
                io::printfn("MorphCube path=%s velocity_format=%s normal_attachment=%s color/depth/velocity pass",
                    path, output.actual.velocity_format, output.actual.has_normal);
                check_morph_lod_native_sources_remain_base(
                    fixture: &fixture,
                    pair: &pair,
                    sources: &sources,
                    base: base,
                );
            }
        }
        check_crowd_native_validation(&fixture.renderer);
    }
}
