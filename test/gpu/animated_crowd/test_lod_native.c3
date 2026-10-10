module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::animated_lod_fixtures;
import std::io;
import std::math;

const Aabb CROWD_LOD_NATIVE_BOUNDS @private = {
    .min = { -1.5f, -0.1f, -1.5f }, .max = { 1.5f, 2.7f, 1.5f },
};
const float[3] CROWD_LOD_NATIVE_FORCE_BIASES @private = { 16, -2, -16 };
const uint[3] CROWD_LOD_NATIVE_TRIANGLES @private = { 13744, 6872, 3436 };

struct CrowdLodNativeDescriptor @private {
    LodLevel[3] levels;
    AnimatedLodPart[6] parts;
}

struct CrowdLodNativeSources @private {
    Node*[CROWD_NATIVE_INSTANCES] ordinary;
    AnimationActionId[CROWD_NATIVE_INSTANCES] actions;
    bool crowd;
}

fn void fill_crowd_lod_native_descriptor(
    Fixture* fixture,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeDescriptor* descriptor,
    MaterialId material = {},
) @private {
    ModelTemplate* template = &fixture.assets.model(corpus.model).data;
    assert(template.meshes.len == LOD_PRIMITIVES && LOD_PRIMITIVES == 2 && LOD_LEVELS == 3);
    for (uint level = 0; level < LOD_LEVELS; level++) {
        descriptor.levels[level] = {
            .first_part = level * LOD_PRIMITIVES,
            .part_count = LOD_PRIMITIVES,
            .min_screen_size = level == 0 ? 1 : (level == 1 ? 0.001f : 0),
        };
        uint triangles;
        foreach (uint primitive, mesh : template.meshes) {
            ModelSkin skin;
            foreach (candidate : template.skins) if (candidate.mesh_node == mesh.node) skin = candidate;
            assert(skin.joint_nodes.len == 53);
            GeometryId geometry = corpus.levels[primitive][level];
            assert(corpus.layouts[primitive][level].index_count % 3 == 0);
            triangles += corpus.layouts[primitive][level].index_count / 3;
            descriptor.parts[level * LOD_PRIMITIVES + primitive] = {
                .draw = {
                    .geometry = geometry,
                    .material = material.generation ? material : mesh.material,
                    .local = matrix::IDENTITY4,
                },
                .mesh_index = primitive,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
        assert(triangles == CROWD_LOD_NATIVE_TRIANGLES[level]);
        if (level) assert(triangles < CROWD_LOD_NATIVE_TRIANGLES[level - 1]);
    }
}

fn AnimatedLodDesc crowd_lod_native_desc(CrowdLodNativeDescriptor* descriptor) @private => {
    .levels = descriptor.levels[..],
    .parts = descriptor.parts[..],
    .has_bounds_override = true,
    .local_bounds = CROWD_LOD_NATIVE_BOUNDS,
};

fn void? attach_crowd_lod_native_sources(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeSources* sources,
    bool crowd,
    ClipId clip,
) @private {
    sources.crowd = crowd;
    CrowdLodNativeDescriptor descriptor;
    if (crowd) {
        fill_crowd_lod_native_descriptor(
            fixture: fixture,
            corpus: corpus,
            descriptor: &descriptor,
            material: {},
        );
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: pair.crowd,
            desc: crowd_lod_native_desc(&descriptor),
        )!;
        return;
    }
    pair.scene.remove(pair.crowd);
    pair.crowd = pair.scene.add_node(name: "ordinary_lod_sources")!;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        Node* actual = model::instantiate(
            assets: &fixture.assets,
            scene: &pair.scene,
            model: corpus.model,
            parent: pair.crowd,
        )!;
        actual.local = pair.ordinary[source].local;
        ModelInstance* reference = pair.scene.get(pair.ordinary[source], ModelInstance);
        MaterialId material = pair.scene.get(reference.present_node(reference.mesh_nodes[0]), Mesh).material;
        fill_crowd_lod_native_descriptor(
            fixture: fixture,
            corpus: corpus,
            descriptor: &descriptor,
            material: material,
        );
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: actual,
            desc: crowd_lod_native_desc(&descriptor),
        )!;
        Animator* animator = anim::add_animator(&pair.scene, actual);
        sources.actions[source] = animator.play(&fixture.assets, clip)!;
        sources.ordinary[source] = actual;
        animator.action(sources.actions[source]).speed = 0;
        animator.action(sources.actions[source]).loop = false;
    }
}

fn void set_crowd_lod_native_reference_level(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    uint level,
) @private {
    ModelTemplate* template = &fixture.assets.model(corpus.model).data;
    foreach (root : pair.ordinary) {
        ModelInstance* instance = pair.scene.get(root, ModelInstance);
        foreach (uint primitive, mesh : template.meshes) {
            pair.scene.get(instance.present_node(mesh.node), Mesh).geometry = corpus.levels[primitive][level];
        }
    }
}

fn void set_crowd_lod_native_phase(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    float duration,
) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        float time = (0.125f + 0.25f * (float)source) * duration;
        Animator* reference = pair.scene.get(pair.ordinary[source], Animator);
        crowd_native_action_controls(reference.action(pair.ordinary_base[source]), time);
        if (sources.crowd) {
            CrowdPlayer player = crowd_native_player(pair, source)!!;
            crowd_native_action_controls(player.base_action()!!, time);
        } else {
            Animator* animator = pair.scene.get(sources.ordinary[source], Animator);
            crowd_native_action_controls(animator.action(sources.actions[source]), time);
        }
    }
    crowd_native_update(fixture, pair, 0);
}

fn void check_crowd_lod_native_sources_remain_base(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeSources* sources,
) @private {
    ModelTemplate* template = &fixture.assets.model(corpus.model).data;
    foreach (uint primitive, mesh : template.meshes) {
        assert(c3d::same_id(mesh.geometry, corpus.levels[primitive][0]));
        if (sources.crowd) {
            AnimatedCrowd* crowd = pair.scene.get(pair.crowd, AnimatedCrowd);
            InstancedMesh* batch = pair.scene.world.get(crowd.parts[primitive].batch, InstancedMesh);
            assert(c3d::same_id(batch.geometry, corpus.levels[primitive][0]));
        } else {
            foreach (actual : sources.ordinary) {
                ModelInstance* instance = pair.scene.get(actual, ModelInstance);
                Mesh* source = pair.scene.get(instance.present_node(mesh.node), Mesh);
                assert(c3d::same_id(source.geometry, corpus.levels[primitive][0]));
            }
        }
    }
}

fn void check_crowd_lod_native_counts(Stats* stats, uint level, bool crowd) @private {
    assert(stats.cull_overflows == 0 && stats.sort_overflows == 0 && stats.lod_fallbacks == 0);
    if (crowd) {
        assert(stats.lod_counts_valid && stats.lod_instances_tested == CROWD_NATIVE_INSTANCES);
        for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
            uint expected = choice == level ? CROWD_NATIVE_INSTANCES : 0;
            assert(stats.lod_selected[choice] == expected && stats.lod_visible[choice] == expected);
        }
    } else {
        for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
            uint expected = choice == level ? CROWD_NATIVE_INSTANCES : 0;
            assert(stats.lod_objects_selected[choice] == expected && stats.lod_objects_visible[choice] == expected);
        }
    }
    io::printfn("animated LOD level=%s crowd=%s", level, crowd);
    io::printfn("selected visible sources=%s authored triangles=%s", CROWD_NATIVE_INSTANCES,
        CROWD_NATIVE_INSTANCES * CROWD_LOD_NATIVE_TRIANGLES[level]);
    io::printfn("recorded triangle work=%s LOD fallback=%s", stats.triangles, stats.lod_fallbacks);
}

fn void? compare_crowd_lod_native_level(
    Fixture* fixture,
    CrowdNativePair* pair,
    AnimatedLodFixtures* corpus,
    CrowdLodNativeSources* sources,
    CrowdNativeOutput* output,
    uint level,
) @private {
    set_crowd_lod_native_reference_level(
        fixture: fixture,
        pair: pair,
        corpus: corpus,
        level: level,
    );
    for (uint path = 0; path < 3; path++) {
        ViewDesc desc = render::texture_view_desc(output.target);
        desc.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        desc.depth_prepass = path == 1;
        desc.lod_bias = CROWD_LOD_NATIVE_FORCE_BIASES[level];
        desc.post.motion_blur = true;
        render::configure_view(&fixture.renderer, output.view, desc)!;
        capture_crowd_native(
            fixture: fixture,
            pair: pair,
            probe: &output.probe,
            output: output.target,
            view: output.view,
            crowd_visible: true,
            images: &output.actual,
        )!;
        check_crowd_lod_native_counts(&output.actual.stats, level, sources.crowd);
        capture_crowd_native(
            fixture: fixture,
            pair: pair,
            probe: &output.probe,
            output: output.target,
            view: output.view,
            crowd_visible: false,
            images: &output.expected,
        )!;
        check_crowd_native_parity(&output.actual, &output.expected, false);
        if (path == 2) {
            assert(output.actual.has_normal && output.expected.has_normal);
            check_crowd_native_image(output.actual.normal, output.expected.normal, CROWD_NATIVE_COLOR_TOLERANCE);
            check_crowd_native_image(output.expected.normal, output.actual.normal, CROWD_NATIVE_COLOR_TOLERANCE);
            uint normal_coverage;
            foreach (index, depth : output.actual.depth) {
                if (depth.x > 0 && output.actual.normal[index].w > 0.5f) normal_coverage++;
            }
            assert(normal_coverage > 0);
        }
        check_crowd_lod_native_sources_remain_base(
            fixture: fixture,
            pair: pair,
            corpus: corpus,
            sources: sources,
        );
    }
}

fn void test_animated_lod_native_quaternius_crowd_and_ordinary_forced_levels_match_selected_geometry() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    crowd_native_flat_source_materials(&fixture, corpus.model);
    ClipId walk = crowd_native_clip_named(&fixture, corpus.model, "Walk_Loop")!!;
    float duration = fixture.assets.clip(walk).data.duration;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    foreach (bool crowd : { true, false }) {
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: corpus.model,
            clip: walk,
            bounds: CROWD_LOD_NATIVE_BOUNDS,
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(6, 0.1f, 100);
        pair.camera.local.position = { 0, 1, 12 };
        use_crowd_native_standard_materials(&fixture, &pair)!!;
        CrowdLodNativeSources sources;
        attach_crowd_lod_native_sources(
            fixture: &fixture,
            pair: &pair,
            corpus: &corpus,
            sources: &sources,
            crowd: crowd,
            clip: walk,
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
        for (uint level = 0; level < LOD_LEVELS; level++) {
            compare_crowd_lod_native_level(
                fixture: &fixture,
                pair: &pair,
                corpus: &corpus,
                sources: &sources,
                output: &output,
                level: level,
            )!!;
        }
        check_crowd_native_validation(&fixture.renderer);
    }
}
