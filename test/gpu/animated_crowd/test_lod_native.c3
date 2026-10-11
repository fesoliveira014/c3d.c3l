module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import c3d::test::animated_crowd_fixtures;
import c3d::test::animated_lod_fixtures;
import gpu;
import std::math;

const uint LOD_NATIVE_MAX_LEVELS @private = 3;
const uint LOD_NATIVE_MAX_MESHES @private = 5;
const Aabb CROWD_LOD_NATIVE_BOUNDS @private = {
    .min = { -1.5f, -0.1f, -1.5f }, .max = { 1.5f, 2.7f, 1.5f },
};
const Vec3[3] BOUNDS_NATIVE_CROP_CENTRES @private = {
    { 11, 1.0f / 3, 1 }, { 10.5f, 1.5f, 0 }, { 1.0f / 3, 16.0f / 3, 2 },
};
const float[3] BOUNDS_NATIVE_CROP_HEIGHTS @private = { 1.2f, 0.8f, 4 };

struct LodNativeSubject @private {
    ModelId model;
    ClipId clip;
    uint level_count;
    float[LOD_NATIVE_MAX_LEVELS] thresholds;
    GeometryId[LOD_NATIVE_MAX_LEVELS][LOD_NATIVE_MAX_MESHES] geometries;
    uint[LOD_NATIVE_MAX_MESHES][LOD_NATIVE_MAX_LEVELS] order;
    Aabb bounds;
    bool ordinary_bounds;
}

struct LodNativeDescriptor @private {
    LodLevel[LOD_NATIVE_MAX_LEVELS] levels;
    AnimatedLodPart[LOD_NATIVE_MAX_LEVELS * LOD_NATIVE_MAX_MESHES] parts;
}

struct CrowdLodNativeSources @private {
    Node*[CROWD_NATIVE_INSTANCES] ordinary;
    bool crowd;
}

struct BoundsNativeAssets @private {
    PartsFixture parts;
    LodNativeSubject subject;
}

fn void identity_lod_native_order(LodNativeSubject* subject) @private {
    for (uint level = 0; level < LOD_NATIVE_MAX_LEVELS; level++) {
        for (uint index = 0; index < LOD_NATIVE_MAX_MESHES; index++) subject.order[level][index] = index;
    }
}

fn LodNativeSubject quaternius_lod_subject(Fixture* fixture, AnimatedLodFixtures* corpus) @private {
    LodNativeSubject subject = {
        .model = corpus.model,
        .clip = crowd_native_clip_named(fixture, corpus.model, "Walk_Loop")!!,
        .level_count = animated_lod_fixtures::LOD_LEVELS,
        .thresholds = { 1, 0.001f, 0 },
        .bounds = CROWD_LOD_NATIVE_BOUNDS,
        .ordinary_bounds = true,
    };
    identity_lod_native_order(&subject);
    for (uint primitive = 0; primitive < animated_lod_fixtures::LOD_PRIMITIVES; primitive++) {
        subject.geometries[primitive][..] = corpus.levels[primitive][..];
    }
    return subject;
}

fn GeometryId add_animated_lod_native_reduced_geometry(Fixture* fixture, GeometryId source) @private {
    @pool() {
        Geometry reduced = fixture.assets.geometry(source).data;
        uint kept = ((uint)reduced.indices.len / 3 + 1) / 2;
        uint[] indices = alloc::new_array(tmem, uint, (sz)kept * 3);
        for (uint face = 0; face < kept; face++) indices[face * 3:3] = reduced.indices[face * 6:3];
        reduced.indices = indices;
        return fixture.assets.add_geometry(&reduced)!!;
    };
}

fn LodNativeSubject morph_cube_lod_subject(Fixture* fixture, ModelId model) @private {
    ModelTemplate* template = &fixture.assets.model(model).data;
    LodNativeSubject subject = {
        .model = model,
        .clip = template.clips[0],
        .level_count = 2,
        .thresholds = { 0.2f, 0, 0 },
        .bounds = { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } },
    };
    identity_lod_native_order(&subject);
    subject.geometries[0][0] = template.meshes[0].geometry;
    subject.geometries[0][1] = add_animated_lod_native_reduced_geometry(fixture, template.meshes[0].geometry);
    return subject;
}

fn AnimatedLodDesc lod_native_desc(
    Fixture* fixture,
    LodNativeSubject* subject,
    LodNativeDescriptor* descriptor,
    bool crowd,
) @private {
    ModelTemplate* template = &fixture.assets.model(subject.model).data;
    uint count = (uint)template.meshes.len;
    for (uint level = 0; level < subject.level_count; level++) {
        descriptor.levels[level] = {
            .first_part = level * count,
            .part_count = count,
            .min_screen_size = subject.thresholds[level],
        };
        for (uint index = 0; index < count; index++) {
            uint mesh_index = subject.order[level][index];
            ModelMesh mesh = template.meshes[mesh_index];
            ModelSkin skin;
            foreach (candidate : template.skins) if (candidate.mesh_node == mesh.node) skin = candidate;
            descriptor.parts[level * count + index] = {
                .draw = {
                    .geometry = subject.geometries[mesh_index][level],
                    .material = mesh.material,
                    .local = matrix::IDENTITY4,
                },
                .mesh_index = mesh_index,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
    }
    return {
        .levels = descriptor.levels[:subject.level_count],
        .parts = descriptor.parts[:subject.level_count * count],
        .has_bounds_override = !crowd && subject.ordinary_bounds,
        .local_bounds = subject.bounds,
    };
}

fn float lod_native_force_bias(LodNativeSubject* subject, uint level) @private {
    if (level == 0) return 16;
    return level + 1 == subject.level_count ? -16 : -2;
}

fn Node* lod_native_owner(CrowdNativePair* pair, CrowdLodNativeSources* sources, uint source) @private {
    return sources.crowd ? pair.crowd : sources.ordinary[source];
}

fn void? attach_lod_native_sources(
    Fixture* fixture,
    CrowdNativePair* pair,
    LodNativeSubject* subject,
    CrowdLodNativeSources* sources,
    bool crowd,
) @private {
    sources.crowd = crowd;
    LodNativeDescriptor descriptor;
    AnimatedLodDesc desc = lod_native_desc(
        fixture: fixture,
        subject: subject,
        descriptor: &descriptor,
        crowd: crowd,
    );
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
    pair.crowd = pair.scene.add_node(name: "ordinary_lod_sources")!;
    ModelTemplate* template = &fixture.assets.model(subject.model).data;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        ModelInstance* reference = pair.scene.get(pair.ordinary[source], ModelInstance);
        foreach (mesh : template.meshes) {
            pair.scene.get(reference.present_node(mesh.node), Mesh).material = mesh.material;
        }
        Node* actual = model::instantiate(
            assets: &fixture.assets,
            scene: &pair.scene,
            model: subject.model,
            parent: pair.crowd,
        )!;
        actual.local = pair.ordinary[source].local;
        model::attach_animated_lod(
            assets: &fixture.assets,
            scene: &pair.scene,
            owner: actual,
            desc: desc,
        )!;
        sources.ordinary[source] = actual;
        Animator* animator = anim::add_animator(&pair.scene, actual);
        crowd_native_action_controls(animator.action(animator.play(&fixture.assets, subject.clip)!), 0);
    }
}

fn void set_lod_native_reference_level(
    Fixture* fixture,
    CrowdNativePair* pair,
    LodNativeSubject* subject,
    uint level,
) @private {
    ModelTemplate* template = &fixture.assets.model(subject.model).data;
    foreach (root : pair.ordinary) {
        ModelInstance* instance = pair.scene.get(root, ModelInstance);
        foreach (uint mesh_index, mesh : template.meshes) {
            pair.scene.get(instance.present_node(mesh.node), Mesh).geometry = subject.geometries[mesh_index][level];
        }
    }
}

fn void set_lod_native_pose(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    float time,
    float stagger = 0,
) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        float source_time = time + stagger * (float)source;
        Animator* reference = pair.scene.get(pair.ordinary[source], Animator);
        crowd_native_action_controls(reference.action(pair.ordinary_base[source]), source_time);
        if (sources.crowd) {
            CrowdPlayer player = crowd_native_player(pair, source)!!;
            crowd_native_action_controls(player.base_action()!!, source_time);
        } else {
            Animator* animator = pair.scene.get(sources.ordinary[source], Animator);
            crowd_native_action_controls(animator.action(animator.order[0]), source_time);
        }
    }
    crowd_native_update(fixture, pair, 0);
}

fn void check_lod_native_counts(Stats* stats, uint level, bool crowd, bool all_visible = true) @private {
    assert(stats.cull_overflows == 0 && stats.sort_overflows == 0 && stats.lod_fallbacks == 0);
    if (crowd) assert(stats.lod_counts_valid && stats.lod_instances_tested == CROWD_NATIVE_INSTANCES);
    for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
        uint expected = choice == level ? CROWD_NATIVE_INSTANCES : 0;
        uint selected = crowd ? stats.lod_selected[choice] : stats.lod_objects_selected[choice];
        uint visible = crowd ? stats.lod_visible[choice] : stats.lod_objects_visible[choice];
        assert(selected == expected && (!all_visible || visible == expected));
    }
}

fn void match_lod_native_shadow_fit(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
) @private {
    pair.crowd.visible = true;
    pair.references.visible = false;
    pair.scene.update_world();
    Aabb aggregate;
    for (uint source = 0; source < (sources.crowd ? 1u : CROWD_NATIVE_INSTANCES); source++) {
        Node* owner = lod_native_owner(pair, sources, source);
        model::sync_animated_lod(&fixture.assets, &pair.scene, owner)!!;
        Aabb bounds = spatial::lod_world_bounds(
            assets: &fixture.assets,
            node: owner,
            group: pair.scene.get(owner, LodGroup),
            scene: &pair.scene,
        );
        aggregate = source == 0 ? bounds : maths::aabb_merge(aggregate, bounds);
    }
    foreach (uint source, root : pair.ordinary) {
        LodDesc* desc = &pair.scene.get(lod_native_owner(pair, sources, source), LodGroup).state.desc;
        ModelInstance* instance = pair.scene.get(root, ModelInstance);
        foreach (template_node : instance.mesh_nodes) {
            Node* node = instance.present_node(template_node);
            Mesh* mesh = pair.scene.get(node, Mesh);
            mesh.has_bounds_override = true;
            if (!sources.crowd && desc.has_bounds_override) {
                Mat4 mesh_local = maths::inverse_affine(root.world).mul(node.world);
                mesh.local_bounds = maths::aabb_transform(desc.local_bounds, maths::inverse_affine(mesh_local));
            } else {
                mesh.local_bounds = maths::aabb_transform(aggregate, maths::inverse_affine(node.world));
            }
        }
    }
}

fn uint lod_native_coverage(Vec4[] depth, Vec4[] velocity = {}) @private {
    uint covered;
    foreach (index, pixel : depth) {
        if (pixel.x <= 0) continue;
        covered++;
        if (!velocity.len) continue;
        assert(math::abs(velocity[index].x) < CROWD_NATIVE_STILL_TOLERANCE);
        assert(math::abs(velocity[index].y) < CROWD_NATIVE_STILL_TOLERANCE);
    }
    return covered;
}

fn void check_lod_native_view_parity(CrowdNativeImages* actual, CrowdNativeImages* reference) @private {
    assert(lod_native_coverage(actual.depth, actual.velocity) > 0);
    assert(lod_native_coverage(reference.depth, reference.velocity) > 0);
    check_crowd_native_image(actual.color, reference.color, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(reference.color, actual.color, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(actual.depth, reference.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(reference.depth, actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_normals(actual, reference);
    check_crowd_native_shadows(actual, reference);
}

fn void? configure_lod_native_shadowed_view(Fixture* fixture, CrowdNativeOutput* output, float lod_bias) @private {
    ViewDesc desc = render::texture_view_desc(output.target);
    desc.shading = ShadingPath.DEFERRED;
    desc.post.motion_blur = true;
    desc.share_shadows = false;
    desc.lod_bias = lod_bias;
    return render::configure_view(&fixture.renderer, output.view, desc);
}

fn void? add_lod_native_sun(CrowdNativePair* pair, float max_distance) @private {
    Light sun = light::directional({ 1, 1, 1 }, 1);
    sun.shadow.cascades = 1;
    sun.shadow.max_distance = max_distance;
    Node* light_node = pair.scene.add_light(sun)!;
    light_node.local.rotation = maths::look_rotation((Vec3){ -0.8f, -0.3f, -1 }.normalize(), { 0, 1, 0 });
    pair.scene.update_world();
}

fn void? compare_lod_native_level(
    Fixture* fixture,
    CrowdNativePair* pair,
    LodNativeSubject* subject,
    CrowdLodNativeSources* sources,
    CrowdNativeOutput* output,
    uint level,
) @private {
    set_lod_native_reference_level(
        fixture: fixture,
        pair: pair,
        subject: subject,
        level: level,
    );
    for (uint path = 0; path < 3; path++) {
        ViewDesc desc = render::texture_view_desc(output.target);
        desc.shading = path == 2 ? ShadingPath.DEFERRED : ShadingPath.FORWARD;
        desc.depth_prepass = path == 1;
        desc.lod_bias = lod_native_force_bias(subject, level);
        desc.post.anti_aliasing = AntiAliasing.NONE;
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
        check_lod_native_counts(&output.actual.stats, level, sources.crowd);
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
        if (path == 2) check_crowd_native_normals(&output.actual, &output.expected);
    }
}

fn BoundsNativeAssets? add_bounds_native_assets(Fixture* fixture) @private {
    BoundsNativeAssets result = { .parts = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)! };
    LodNativeSubject* subject = &result.subject;
    *subject = {
        .model = result.parts.mixed,
        .level_count = 2,
        .thresholds = { 0.5f, 0, 0 },
        .order = { { 4, 1, 2, 3, 0 }, { 2, 0, 4, 1, 3 }, {} },
    };
    Allocator allocator = fixture.assets.allocator;
    String key = "native_bounds/extension";
    AnimationClip clip = {
        .name = key.copy(allocator),
        .duration = 1,
        .tracks = alloc::new_array(allocator, Track, 3),
        .targets = alloc::new_array(allocator, uint, 3),
    };
    defer catch asset::free_clip(allocator, &clip);
    clip.targets[0] = animated_crowd_fixtures::PARTS_JOINT_TIP;
    clip.targets[1] = animated_crowd_fixtures::PARTS_RIGID_NODE;
    clip.targets[2] = animated_crowd_fixtures::PARTS_MORPH_A;
    float[6] tip = { 0, 3, 0, 5, 3, 0 };
    float[6] rigid = { 1, 0, 0, 6, 0, 0 };
    float[2] morph = { 0.25f, 3 };
    clip.tracks[0] = crowd_native_track(
        allocator: allocator,
        target: 0,
        path: TargetPath.TRANSLATION,
        values: tip[..],
    );
    clip.tracks[1] = crowd_native_track(
        allocator: allocator,
        target: 1,
        path: TargetPath.TRANSLATION,
        values: rigid[..],
    );
    clip.tracks[2] = crowd_native_track(
        allocator: allocator,
        target: 2,
        path: TargetPath.MORPH_WEIGHTS,
        values: morph[..],
    );
    subject.clip = fixture.assets.add_clip_owned(&clip, key)!;

    @pool() {
        for (uint part = 0; part < LOD_NATIVE_MAX_MESHES; part++) {
            subject.geometries[part][0] = result.parts.geometries[part];
            if (part == 3) {
                subject.geometries[part][1] = subject.geometries[2][1];
                continue;
            }
            Geometry coarse = fixture.assets.geometry(result.parts.geometries[part]).data;
            coarse.positions = alloc::clone_slice(tmem, coarse.positions);
            foreach (&point : coarse.positions) *point *= 0.8f;
            coarse.targets = alloc::clone_slice(tmem, coarse.targets);
            foreach (&target : coarse.targets) {
                target.position_deltas = alloc::clone_slice(tmem, target.position_deltas);
                foreach (&delta : target.position_deltas) *delta *= 0.8f;
            }
            coarse.finalize();
            subject.geometries[part][1] = fixture.assets.add_geometry(&coarse)!;
        }
    };
    return result;
}

fn void set_bounds_native_crop(
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    uint crop,
) @private {
    Transform placement = sources.crowd
      ? pair.scene.get(pair.crowd, AnimatedCrowd).placements[0] : sources.ordinary[0].local;
    Vec3 point = maths::transform_point(placement.to_mat4(), BOUNDS_NATIVE_CROP_CENTRES[crop]);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(BOUNDS_NATIVE_CROP_HEIGHTS[crop], 0.1f, 60);
    pair.camera.local.position = { point.x, point.y, 20 };
    pair.scene.update_world();
}

fn void? capture_lod_native_shadowed(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    CrowdNativeOutput* actual,
    CrowdNativeOutput* reference,
) @private {
    match_lod_native_shadow_fit(fixture, pair, sources);
    capture_crowd_native_outputs(
        fixture: fixture,
        pair: pair,
        actual: actual,
        reference: reference,
    )!;
}

fn void test_animated_lod_native_forced_levels_match_selected_geometry() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    CrowdNativeOutput output;
    create_crowd_native_output(&fixture, &output)!!;
    defer destroy_crowd_native_output(&fixture, &output);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    ModelId morph_cube = load_crowd_native_cc0(
        fixture: &fixture,
        filename: CROWD_NATIVE_MORPH_CUBE,
        expected_hash: CROWD_NATIVE_MORPH_CUBE_SHA,
    )!!;
    LodNativeSubject[2] subjects = {
        quaternius_lod_subject(&fixture, &corpus),
        morph_cube_lod_subject(&fixture, morph_cube),
    };
    foreach (uint index, &subject : subjects) {
        bool character = index == 0;
        crowd_native_flat_source_materials(&fixture, subject.model);
        float duration = fixture.assets.clip(subject.clip).data.duration;
        Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
        if (!character) {
            foreach (&placement : placements) placement.scale *= 0.6f;
        }
        foreach (bool crowd : { true, false }) {
            CrowdNativePair pair;
            create_crowd_native_pair(
                allocator: mem,
                fixture: &fixture,
                pair: &pair,
                model: subject.model,
                clip: subject.clip,
                bounds: subject.bounds,
                placements: placements[..],
            )!!;
            defer scene::destroy_scene(&pair.scene);
            *pair.scene.get(pair.camera, Camera) = camera::orthographic(character ? 6 : 5, 0.1f, 100);
            pair.camera.local.position = { 0, character ? 1 : 0, 12 };
            use_crowd_native_standard_materials(&fixture, &pair)!!;
            CrowdLodNativeSources sources;
            attach_lod_native_sources(
                fixture: &fixture,
                pair: &pair,
                subject: subject,
                sources: &sources,
                crowd: crowd,
            )!!;
            set_lod_native_pose(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                time: 0.125f * duration,
                stagger: 0.25f * duration,
            );
            for (uint level = 0; level < subject.level_count; level++) {
                compare_lod_native_level(
                    fixture: &fixture,
                    pair: &pair,
                    subject: subject,
                    sources: &sources,
                    output: &output,
                    level: level,
                )!!;
            }
            check_crowd_native_validation(&fixture.renderer);
        }
    }
}

fn void test_animated_lod_native_quaternius_simultaneous_parent_levels_and_offscreen_shadows() @test {
    Fixture fixture;
    create_fixture(
        allocator: mem,
        fixture: &fixture,
        shadow_resolution: 128,
        max_shadow_layers: 1,
        max_views: 12,
        max_render_targets: 12,
    )!!;
    defer destroy_fixture(&fixture);
    AnimatedLodFixtures corpus = animated_lod_fixtures::load_animated_lod_fixtures(&fixture.assets, "../../..")!!;
    LodNativeSubject subject = quaternius_lod_subject(&fixture, &corpus);
    crowd_native_flat_source_materials(&fixture, corpus.model);
    float duration = fixture.assets.clip(subject.clip).data.duration;
    Transform[CROWD_NATIVE_INSTANCES] placements = crowd_native_real_placements();
    placements[0].position.x = -1.5f;
    placements[1].position.x = 1.5f;
    placements[2].position.x = 6;
    CrowdNativeOutput[4] outputs;
    foreach (&output : outputs) create_crowd_native_output(&fixture, output)!!;
    defer foreach (&output : outputs) destroy_crowd_native_output(&fixture, output);
    foreach (bool crowd : { true, false }) {
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: corpus.model,
            clip: subject.clip,
            bounds: CROWD_LOD_NATIVE_BOUNDS,
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(6, 0.1f, 30);
        pair.camera.local.position = { 0, 1, 12 };
        use_crowd_native_standard_materials(&fixture, &pair)!!;
        CrowdLodNativeSources sources;
        attach_lod_native_sources(
            fixture: &fixture,
            pair: &pair,
            subject: &subject,
            sources: &sources,
            crowd: crowd,
        )!!;
        set_lod_native_pose(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            time: 0.125f * duration,
            stagger: 0.25f * duration,
        );
        add_lod_native_sun(&pair, 25)!!;
        uint[2] levels = { 0, 2 };
        for (uint view = 0; view < 2; view++) {
            float bias = lod_native_force_bias(&subject, levels[view]);
            configure_lod_native_shadowed_view(&fixture, &outputs[view], bias)!!;
            configure_lod_native_shadowed_view(&fixture, &outputs[2 + view], 0)!!;
        }
        for (uint offscreen = 0; offscreen < 2; offscreen++) {
            if (offscreen) {
                if (crowd) {
                    AnimatedCrowd* animated = pair.scene.get(pair.crowd, AnimatedCrowd);
                    animated.placements[2].position.x = 1000;
                    pair.scene.write_crowd_batches(animated);
                } else {
                    sources.ordinary[2].local.position.x = 1000;
                }
                pair.ordinary[2].local.position.x = 1000;
                crowd_native_update(&fixture, &pair, 0);
            }
            match_lod_native_shadow_fit(&fixture, &pair, &sources);
            Renderer* renderer = &fixture.renderer;
            Mat4[4] shadow_inverse;
            for (uint frame = 0; frame < CROWD_NATIVE_WARMUP; frame++) {
                renderer.begin_frame({ .time = 0.37, .delta = 0 })!!;
                for (uint index = 0; index < 4; index++) {
                    if (index >= 2) {
                        set_lod_native_reference_level(
                            fixture: &fixture,
                            pair: &pair,
                            subject: &subject,
                            level: levels[index - 2],
                        );
                    }
                    record_crowd_native_view(
                        fixture: &fixture,
                        pair: &pair,
                        probe: &outputs[index].probe,
                        view: outputs[index].view,
                        crowd_visible: index < 2,
                        images: &outputs[index].actual,
                    )!!;
                    shadow_inverse[index] = renderer.shadow_frusta[0].inv_view_proj;
                }
                assert(renderer.stats.shadow_sets_recorded == 4 && renderer.stats.shadow_sets_shared == 0);
                assert(renderer.stats.shadow_layers == 4 && renderer.stats.shadow_requests_dropped == 0);
                renderer.end_frame()!!;
            }
            foreach (&output : outputs) read_crowd_native_output(&fixture, output)!!;
            Stats* stats = &outputs[0].actual.stats;
            assert(stats.lod_fallbacks == 0 && stats.cull_overflows == 0 && stats.sort_overflows == 0);
            for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
                uint selected = choice == 0 || choice == 2 ? CROWD_NATIVE_INSTANCES : 0;
                uint visible = choice == 0 || choice == 2 ? 2 : 0;
                if (crowd) {
                    assert(stats.lod_counts_valid && stats.lod_instances_tested == 2 * CROWD_NATIVE_INSTANCES);
                    assert(stats.lod_selected[choice] == selected && stats.lod_visible[choice] == visible);
                } else {
                    assert(stats.lod_objects_selected[choice] == selected);
                    assert(stats.lod_objects_visible[choice] == visible);
                }
            }

            for (uint view = 0; view < 2; view++) {
                float[] actual_projection = ((float*)&shadow_inverse[view])[:Mat4::size / float::size];
                float[] reference_projection = ((float*)&shadow_inverse[2 + view])[:Mat4::size / float::size];
                foreach (component, value : actual_projection) {
                    assert(math::abs(value - reference_projection[component]) <= CROWD_NATIVE_DEPTH_TOLERANCE);
                }
                CrowdNativeImages* actual = &outputs[view].actual;
                CrowdNativeImages* onscreen = &outputs[view].expected;
                check_lod_native_view_parity(actual, &outputs[2 + view].actual);
                uint resolution = actual.shadow_resolution;
                if (!offscreen) {
                    mem::copy(onscreen.shadow.ptr, actual.shadow.ptr, (sz)resolution * resolution * Vec4::size);
                    mem::copy(onscreen.depth.ptr, actual.depth.ptr, CROWD_NATIVE_PIXELS * Vec4::size);
                    continue;
                }
                check_crowd_native_image(actual.depth, onscreen.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
                check_crowd_native_image(onscreen.depth, actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
                uint changed;
                for (uint pixel = 0; pixel < resolution * resolution; pixel++) {
                    float delta = math::abs(actual.shadow[pixel].x - onscreen.shadow[pixel].x);
                    if (delta > CROWD_NATIVE_DEPTH_TOLERANCE) changed++;
                }
                assert(changed > 0, "Offscreen source did not contribute to its parent shadow");
            }
            if (!offscreen) {
                uint resolution = outputs[2].actual.shadow_resolution;
                uint level_differences;
                for (uint pixel = 0; pixel < resolution * resolution; pixel++) {
                    float delta = math::abs(outputs[2].actual.shadow[pixel].x - outputs[3].actual.shadow[pixel].x);
                    if (delta > CROWD_NATIVE_DEPTH_TOLERANCE) level_differences++;
                }
                assert(level_differences > 0, "Reduced parent shadow level is not discriminating");
            }
        }
        check_crowd_native_validation(&fixture.renderer);
    }
}

fn void test_animated_lod_native_mixed_stretched_bounds_and_cpu_release() @test {
    foreach (bool crowd : { true, false }) {
        Fixture fixture;
        create_fixture(
            allocator: mem,
            fixture: &fixture,
            shadow_resolution: 128,
            max_shadow_layers: 1,
        )!!;
        defer destroy_fixture(&fixture);
        BoundsNativeAssets assets = add_bounds_native_assets(&fixture)!!;
        LodNativeSubject* subject = &assets.subject;
        Transform[CROWD_NATIVE_INSTANCES] placements;
        foreach (uint source, &placement : placements) {
            *placement = maths::TRANSFORM_IDENTITY;
            placement.position.x = ((float)source - 1) * 20;
            placement.scale = { source == 1 ? -0.8f : 0.8f, 1.2f, 0.7f };
        }
        CrowdNativePair pair;
        create_crowd_native_pair(
            allocator: mem,
            fixture: &fixture,
            pair: &pair,
            model: subject.model,
            clip: subject.clip,
            bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        use_crowd_native_standard_materials(&fixture, &pair)!!;
        CrowdLodNativeSources sources;
        attach_lod_native_sources(
            fixture: &fixture,
            pair: &pair,
            subject: subject,
            sources: &sources,
            crowd: crowd,
        )!!;
        CrowdNativeOutput actual;
        create_crowd_native_output(&fixture, &actual)!!;
        defer destroy_crowd_native_output(&fixture, &actual);
        CrowdNativeOutput reference;
        create_crowd_native_output(&fixture, &reference)!!;
        defer destroy_crowd_native_output(&fixture, &reference);
        configure_lod_native_shadowed_view(&fixture, &actual, 16)!!;
        configure_lod_native_shadowed_view(&fixture, &reference, 16)!!;
        add_lod_native_sun(&pair, 60)!!;
        for (uint crop = 0; crop < 3; crop++) {
            set_lod_native_pose(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                time: 0,
            );
            set_bounds_native_crop(&pair, &sources, crop);
            capture_lod_native_shadowed(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                actual: &actual,
                reference: &reference,
            )!!;
            assert(lod_native_coverage(actual.actual.depth) == 0 && lod_native_coverage(reference.actual.depth) == 0);
            set_lod_native_pose(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                time: 1,
            );
            capture_lod_native_shadowed(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                actual: &actual,
                reference: &reference,
            )!!;
            check_lod_native_view_parity(&actual.actual, &reference.actual);
        }

        *pair.scene.get(pair.camera, Camera) = camera::orthographic(42, 0.1f, 60);
        pair.camera.local.position = { 0, 3, 30 };
        for (uint parity = 0; parity < 2; parity++) {
            if (parity) {
                for (uint source = 0; source < 2; source++) {
                    if (crowd) {
                        pair.scene.get(pair.crowd, AnimatedCrowd).placements[source].scale.x *= -1;
                    } else {
                        sources.ordinary[source].local.scale.x *= -1;
                    }
                    pair.ordinary[source].local.scale.x *= -1;
                }
                if (crowd) pair.scene.write_crowd_batches(pair.scene.get(pair.crowd, AnimatedCrowd));
                crowd_native_update(&fixture, &pair, 0);
            }
            for (uint level = 0; level < 2; level++) {
                configure_lod_native_shadowed_view(&fixture, &actual, level == 0 ? 16 : -16)!!;
                set_lod_native_reference_level(
                    fixture: &fixture,
                    pair: &pair,
                    subject: subject,
                    level: level,
                );
                capture_lod_native_shadowed(
                    fixture: &fixture,
                    pair: &pair,
                    sources: &sources,
                    actual: &actual,
                    reference: &reference,
                )!!;
                check_lod_native_view_parity(&actual.actual, &reference.actual);
                check_lod_native_counts(
                    stats: &actual.actual.stats,
                    level: level,
                    crowd: crowd,
                    all_visible: false,
                );
            }
        }

        set_lod_native_pose(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            time: 0.45f,
        );
        configure_lod_native_shadowed_view(&fixture, &actual, 0)!!;
        capture_lod_native_shadowed(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        check_lod_native_counts(
            stats: &actual.actual.stats,
            level: 1,
            crowd: crowd,
            all_visible: false,
        );
        Vec3 half_extent = crowd ? (Vec3){ 9 * 0.8f, 4.5f * 1.2f, 4 * 0.7f }
            : (Vec3){ 5.625f * 0.8f, 1.4875f * 1.2f, 1.5f * 0.7f };
        pair.scene.get(pair.camera, Camera).ortho_height = 2 * half_extent.length() / 0.51f;
        capture_lod_native_shadowed(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        check_lod_native_counts(
            stats: &actual.actual.stats,
            level: 1,
            crowd: crowd,
            all_visible: false,
        );
        set_lod_native_pose(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            time: 0.5f,
        );
        capture_lod_native_shadowed(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        check_lod_native_counts(
            stats: &actual.actual.stats,
            level: 1,
            crowd: crowd,
            all_visible: false,
        );

        set_lod_native_pose(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            time: 1,
        );
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(42, 0.1f, 60);
        configure_lod_native_shadowed_view(&fixture, &actual, -16)!!;
        for (uint released = 0; released < 2; released++) {
            if (released) {
                for (uint part = 0; part < LOD_NATIVE_MAX_MESHES; part++) {
                    if (part == 3) continue;
                    fixture.assets.release_geometry_cpu(subject.geometries[part][0]);
                    fixture.assets.release_geometry_cpu(subject.geometries[part][1]);
                }
            }
            capture_lod_native_shadowed(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                actual: &actual,
                reference: &reference,
            )!!;
            check_lod_native_view_parity(&actual.actual, &reference.actual);
            check_lod_native_counts(
                stats: &actual.actual.stats,
                level: 1,
                crowd: crowd,
                all_visible: false,
            );
        }
        check_crowd_native_validation(&fixture.renderer);
    }
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
            crowd_native_action_controls(animator.action(animator.play(&fixture.assets, parts.posing)!!), 0.5f);
        }
        anim::update(&fixture.assets, &pair.scene, 0);
        anim::crowd_update(&fixture.assets, &pair.scene, 0);
        @pool() {
            model::attach_animated_lod(
                assets: &fixture.assets,
                scene: &pair.scene,
                owner: pair.crowd,
                desc: animated_crowd_fixtures::parts_lod_desc(&fixture.assets, parts.mixed),
            )!!;
        };
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(24, 0.1f, 100);
        add_lod_native_sun(&pair, 30)!!;
        CrowdNativeOutput output;
        create_crowd_native_output(&fixture, &output)!!;
        defer destroy_crowd_native_output(&fixture, &output);
        configure_lod_native_shadowed_view(&fixture, &output, 16)!!;
        for (uint dangling = 0; dangling < 2; dangling++) {
            if (dangling) {
                LodGroupState* state = pair.scene.get(pair.crowd, LodGroup).state;
                switch (mutation) {
                    case 0:
                    case 1:
                        ModelInstance* instance = pair.scene.get(pair.crowd, ModelInstance);
                        uint missing = mutation == 0
                          ? animated_crowd_fixtures::PARTS_RIGID_NODE : animated_crowd_fixtures::PARTS_JOINT_TIP;
                        pair.scene.remove(instance.present_node(missing));
                    case 3:
                        AnimatedCrowd* source = pair.scene.get(pair.crowd, AnimatedCrowd);
                        pair.scene.remove(pair.scene.node(source.parts[1].batch));
                    default:
                        fixture.assets.remove_geometry(state.desc.parts[0].geometry);
                }
                pair.scene.update_world();
            }
            Renderer* renderer = &fixture.renderer;
            renderer.begin_frame({ .time = 0.37, .delta = 0 })!!;
            record_crowd_native_view(
                fixture: &fixture,
                pair: &pair,
                probe: &output.probe,
                view: output.view,
                crowd_visible: true,
                images: &output.actual,
            )!!;
            renderer.end_frame()!!;
            read_crowd_native_view(&fixture, &output.probe, &output.actual)!!;
            uint resolution = output.actual.shadow_resolution;
            uint main = lod_native_coverage(output.actual.depth);
            uint shadow = lod_native_coverage(output.actual.shadow[:(sz)resolution * resolution]);
            if (dangling) {
                assert(output.actual.stats.dangling_refs > 0 && main == 0 && shadow == 0);
            } else {
                assert(output.actual.stats.dangling_refs == 0 && main > 0 && shadow > 0);
            }
        }
        check_crowd_native_validation(&fixture.renderer);
    }
}

fn void test_animated_lod_native_preparation_covers_lower_skin_and_morph_variants() @test {
    foreach (bool crowd : { false, true }) {
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
            model: assets.subject.model,
            clip: assets.subject.clip,
            bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            placements: placements[..],
            tinted: false,
        )!!;
        defer scene::destroy_scene(&pair.scene);
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(25, 0.1f, 100);
        CrowdLodNativeSources sources;
        attach_lod_native_sources(
            fixture: &fixture,
            pair: &pair,
            subject: &assets.subject,
            sources: &sources,
            crowd: crowd,
        )!!;
        Material lower = material::standard();
        lower.common.alpha_mode = AlphaMode.MASK;
        lower.common.alpha_cutoff = 0.2f;
        MaterialId lower_material = fixture.assets.add_material(lower)!!;
        uint owners = crowd ? 1 : CROWD_NATIVE_INSTANCES;
        for (uint owner = 0; owner < owners; owner++) {
            LodGroupState* state = pair.scene.get(lod_native_owner(&pair, &sources, owner), LodGroup).state;
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
            for (uint owner = 0; owner < owners; owner++) lod_native_owner(&pair, &sources, owner).visible = false;
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
                    assert((key.vertex.flags & deformation) == 0, "Hidden warm-up populated a deformation pipeline");
                };
            }

            pair.crowd.visible = true;
            for (uint owner = 0; owner < owners; owner++) lod_native_owner(&pair, &sources, owner).visible = true;
            pair.scene.update_world();
            desc.post.motion_blur = true;
            render::configure_view(renderer, view, desc)!!;
            ulong warm_calls = renderer.pipelines.creations.calls;
            renderer.prepare_scene(&pair.scene)!!;
            ulong prepared_calls = renderer.pipelines.creations.calls;
            if (path == 0) assert(prepared_calls > warm_calls, "Preparation did not create deformation pipelines");
            for (uint level = 0; level < 2; level++) {
                desc.lod_bias = level == 0 ? 16 : -16;
                render::configure_view(renderer, view, desc)!!;
                for (uint frame = 0; frame < CROWD_NATIVE_WARMUP; frame++) {
                    renderer.begin_frame()!!;
                    renderer.render_view(&pair.scene, pair.camera, view)!!;
                    renderer.finish_view(view)!!;
                    renderer.end_frame()!!;
                    assert(renderer.pipelines.creations.calls == prepared_calls,
                        "Prepared animated LOD switch created a graphics pipeline");
                }
                render::wait_frames(renderer)!!;
                check_lod_native_counts(
                    stats: &renderer.stats,
                    level: level,
                    crowd: crowd,
                    all_visible: false,
                );
            }
        }
        check_crowd_native_validation(renderer);
    }
}
