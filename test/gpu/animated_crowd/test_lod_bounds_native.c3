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
import c3d::spatial;
import c3d::test::animated_crowd_fixtures;
import std::io;
import std::math;

const uint BOUNDS_NATIVE_PARTS @private = 5;
const uint BOUNDS_NATIVE_VERTICES @private = 3;
const Vec3[15] BOUNDS_NATIVE_POINTS @private = {
    { 12, 0, 1 }, { 10, 1, 1 }, { 10, 0, 1 },
    { 12, 1, 0 }, { 10, 2, 0 }, { 10, 1, 0 },
    { 1, 5, 2 }, { 0, 6, 2 }, { 0, 5, 2 },
    { 0, 0.5f, 3 }, { -2, 1.5f, 3 }, { -2, 0.5f, 3 },
    { 9, 0, 1 }, { 7, 1, 1 }, { 7, 0, 1 },
};
const Vec3[3] BOUNDS_NATIVE_CROP_CENTRES @private = {
    { 11, 1.0f / 3, 1 }, { 10.5f, 1.5f, 0 }, { 1.0f / 3, 16.0f / 3, 2 },
};
const float[3] BOUNDS_NATIVE_CROP_HEIGHTS @private = { 1.2f, 0.8f, 4 };

struct BoundsNativeAssets @private {
    PartsFixture fixture;
    GeometryId[BOUNDS_NATIVE_PARTS] coarse;
    ClipId clip;
}

struct BoundsNativeDescriptor @private {
    LodLevel[2] levels;
    AnimatedLodPart[10] parts;
}

fn ClipId? add_bounds_native_clip(AssetStore* assets) @private {
    Allocator allocator = assets.allocator;
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
    return assets.add_clip_owned(&clip, key);
}

fn BoundsNativeAssets? add_bounds_native_assets(Fixture* fixture) @private {
    BoundsNativeAssets result = { .fixture = animated_crowd_fixtures::add_parts_fixture(&fixture.assets)! };
    result.clip = add_bounds_native_clip(&fixture.assets)!;
    @pool() {
        for (uint part = 0; part < BOUNDS_NATIVE_PARTS; part++) {
            if (part == 3) {
                result.coarse[part] = result.coarse[2];
                continue;
            }
            Geometry coarse = fixture.assets.geometry(result.fixture.geometries[part]).data;
            coarse.positions = alloc::clone_slice(tmem, coarse.positions);
            foreach (&point : coarse.positions) *point *= 0.8f;
            coarse.targets = alloc::clone_slice(tmem, coarse.targets);
            foreach (&target : coarse.targets) {
                target.position_deltas = alloc::clone_slice(tmem, target.position_deltas);
                foreach (&delta : target.position_deltas) *delta *= 0.8f;
            }
            coarse.finalize();
            result.coarse[part] = fixture.assets.add_geometry(&coarse)!;
            assert(!c3d::same_id(result.coarse[part], result.fixture.geometries[part]));
        }
    };
    return result;
}

fn void fill_bounds_native_descriptor(
    Fixture* fixture,
    BoundsNativeAssets* assets,
    BoundsNativeDescriptor* descriptor,
) @private {
    ModelTemplate* template = &fixture.assets.model(assets.fixture.mixed).data;
    assert(template.meshes.len == BOUNDS_NATIVE_PARTS);
    descriptor.levels = {
        { .first_part = 0, .part_count = BOUNDS_NATIVE_PARTS, .min_screen_size = 0.5f },
        { .first_part = BOUNDS_NATIVE_PARTS, .part_count = BOUNDS_NATIVE_PARTS, .min_screen_size = 0 },
    };
    uint[5] base_order = { 4, 1, 2, 3, 0 };
    uint[5] coarse_order = { 2, 0, 4, 1, 3 };
    for (uint level = 0; level < 2; level++) {
        for (uint index = 0; index < BOUNDS_NATIVE_PARTS; index++) {
            uint logical = level == 0 ? base_order[index] : coarse_order[index];
            ModelMesh mesh = template.meshes[logical];
            ModelSkin skin;
            foreach (candidate : template.skins) if (candidate.mesh_node == mesh.node) skin = candidate;
            descriptor.parts[level * BOUNDS_NATIVE_PARTS + index] = {
                .draw = {
                    .geometry = level == 0 ? mesh.geometry : assets.coarse[logical],
                    .material = mesh.material,
                    .local = matrix::IDENTITY4,
                },
                .mesh_index = logical,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
    }
}

fn void? attach_bounds_native_sources(
    Fixture* fixture,
    CrowdNativePair* pair,
    BoundsNativeAssets* assets,
    CrowdLodNativeSources* sources,
    bool crowd,
) @private {
    sources.crowd = crowd;
    BoundsNativeDescriptor descriptor;
    fill_bounds_native_descriptor(fixture, assets, &descriptor);
    AnimatedLodDesc desc = { .levels = descriptor.levels[..], .parts = descriptor.parts[..] };
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
    pair.crowd = pair.scene.add_node(name: "ordinary_bounds_sources")!;
    ModelTemplate* template = &fixture.assets.model(assets.fixture.mixed).data;
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
        ModelInstance* reference = pair.scene.get(pair.ordinary[source], ModelInstance);
        foreach (mesh : template.meshes) {
            pair.scene.get(reference.present_node(mesh.node), Mesh).material = mesh.material;
        }
        Node* actual = model::instantiate(
            assets: &fixture.assets,
            scene: &pair.scene,
            model: assets.fixture.mixed,
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
        sources.actions[source] = animator.play(&fixture.assets, assets.clip)!;
        crowd_native_action_controls(animator.action(sources.actions[source]), 0);
    }
}

fn void set_bounds_native_pose(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    float time,
) @private {
    for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
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

fn void set_bounds_native_reference_level(
    Fixture* fixture,
    CrowdNativePair* pair,
    BoundsNativeAssets* assets,
    uint level,
) @private {
    ModelTemplate* template = &fixture.assets.model(assets.fixture.mixed).data;
    foreach (root : pair.ordinary) {
        ModelInstance* instance = pair.scene.get(root, ModelInstance);
        foreach (uint part, mesh : template.meshes) {
            pair.scene.get(instance.present_node(mesh.node), Mesh).geometry = level == 0
                ? assets.fixture.geometries[part] : assets.coarse[part];
        }
    }
}

fn Node* bounds_native_owner(CrowdNativePair* pair, CrowdLodNativeSources* sources, uint source) @private {
    return sources.crowd ? pair.crowd : sources.ordinary[source];
}

fn Transform bounds_native_placement(CrowdNativePair* pair, CrowdLodNativeSources* sources, uint source) @private {
    if (sources.crowd) return pair.scene.get(pair.crowd, AnimatedCrowd).placements[source];
    return sources.ordinary[source].local;
}

fn Vec3 bounds_native_world(Transform placement, Vec3 point) @private {
    Vec4 world = placement.to_mat4().apply({ point.x, point.y, point.z, 1 });
    return { world.x, world.y, world.z };
}

fn bool bounds_native_contains(Aabb bounds, Vec3 point) @private {
    for (uint axis = 0; axis < 3; axis++) {
        if (point[axis] < bounds.min[axis] - CROWD_NATIVE_CORNER_TOLERANCE
            || point[axis] > bounds.max[axis] + CROWD_NATIVE_CORNER_TOLERANCE) return false;
    }
    return true;
}

fn void check_bounds_native_queries(
    Fixture* fixture,
    CrowdNativePair* pair,
    BoundsNativeAssets* assets,
    CrowdLodNativeSources* sources,
    SceneIndex* index,
    bool released,
) @private {
    pair.crowd.visible = true;
    pair.references.visible = false;
    pair.scene.update_world();
    index.refresh(&fixture.assets, &pair.scene)!!;
    assert(index.count == CROWD_NATIVE_INSTANCES * BOUNDS_NATIVE_PARTS && index.dangling == 0);
    uint[15] seen;
    foreach (entry : index.entries[:index.count]) {
        uint source;
        if (sources.crowd) source = entry.instance_index;
        else {
            bool found;
            foreach (uint candidate, owner : sources.ordinary) {
                if (entry.node == owner) {
                    source = candidate;
                    found = true;
                }
            }
            assert(found && entry.instance_index == 0);
        }
        assert(source < CROWD_NATIVE_INSTANCES && entry.part_index < BOUNDS_NATIVE_PARTS);
        assert(entry.node == bounds_native_owner(pair, sources, source));
        assert(entry.flags.lod_group && entry.flags.instanced == sources.crowd);
        assert(c3d::same_id(entry.geometry, assets.fixture.geometries[entry.part_index]));
        assert(entry.flags.skinned == (entry.part_index == 0 || entry.part_index == 4));
        assert(entry.flags.static_triangles == (!sources.crowd && !released && entry.part_index == 1));
        seen[source * BOUNDS_NATIVE_PARTS + entry.part_index]++;
        Transform placement = bounds_native_placement(pair, sources, source);
        for (uint vertex = 0; vertex < BOUNDS_NATIVE_VERTICES; vertex++) {
            assert(bounds_native_contains(entry.bounds,
                bounds_native_world(placement, BOUNDS_NATIVE_POINTS[entry.part_index * 3 + vertex])));
        }
    }
    foreach (count : seen) assert(count == 1);
    @pool() {
        spatial::prepare_triangle_picks(&fixture.assets, &pair.scene);
        for (uint source = 0; source < CROWD_NATIVE_INSTANCES; source++) {
            Transform placement = bounds_native_placement(pair, sources, source);
            for (uint part = 0; part < BOUNDS_NATIVE_PARTS; part++) {
                Vec3 centre = (BOUNDS_NATIVE_POINTS[part * 3] + BOUNDS_NATIVE_POINTS[part * 3 + 1]
                    + BOUNDS_NATIVE_POINTS[part * 3 + 2]) / 3;
                Vec3 world = bounds_native_world(placement, centre);
                Ray ray = { .origin = { world.x, world.y, 30 }, .direction = { 0, 0, -1 } };
                PickOptions options = {
                    .precision = PickPrecision.TRIANGLES,
                    .faces = PickFaces.BOTH,
                    .layers = uint::max,
                };
                PickHit[] direct = spatial::pick(
                    allocator: tmem,
                    assets: &fixture.assets,
                    scene: &pair.scene,
                    ray: ray,
                    options: options,
                );
                PickHit[] indexed = index.pick(
                    allocator: tmem,
                    assets: &fixture.assets,
                    ray: ray,
                    options: options,
                );
                bool direct_found;
                bool indexed_found;
                foreach (hit : direct) {
                    if (hit.node != bounds_native_owner(pair, sources, source)
                        || hit.instance_index != (sources.crowd ? source : 0) || hit.part_index != part) continue;
                    direct_found = true;
                    assert(hit.lod_group && hit.instanced == sources.crowd);
                    assert(c3d::same_id(hit.geometry, assets.fixture.geometries[part]));
                    assert(hit.triangle_hit == (!sources.crowd && !released && part == 1));
                    foreach (other : indexed) {
                        if (other.node != hit.node || other.instance_index != hit.instance_index
                            || other.part_index != part) continue;
                        indexed_found = true;
                        assert(c3d::same_id(other.geometry, hit.geometry) && other.lod_group == hit.lod_group);
                        assert(other.triangle_hit == hit.triangle_hit && other.distance == hit.distance);
                    }
                }
                assert(direct_found && indexed_found);
            }
        }
    };
}

fn void match_bounds_native_shadow_fit(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
) @private {
    pair.crowd.visible = true;
    pair.references.visible = false;
    pair.scene.update_world();
    Aabb aggregate;
    for (uint source = 0; source < (sources.crowd ? 1u : CROWD_NATIVE_INSTANCES); source++) {
        Node* owner = bounds_native_owner(pair, sources, source);
        model::sync_animated_lod(&fixture.assets, &pair.scene, owner)!!;
        Aabb bounds = spatial::lod_world_bounds(
            assets: &fixture.assets,
            node: owner,
            group: pair.scene.get(owner, LodGroup),
            scene: &pair.scene,
        );
        aggregate = source == 0 ? bounds : maths::aabb_merge(aggregate, bounds);
    }
    foreach (root : pair.ordinary) {
        ModelInstance* instance = pair.scene.get(root, ModelInstance);
        foreach (template_node : instance.mesh_nodes) {
            Node* node = instance.present_node(template_node);
            Mesh* mesh = pair.scene.get(node, Mesh);
            mesh.has_bounds_override = true;
            mesh.local_bounds = maths::aabb_transform(aggregate, maths::inverse_affine(node.world));
        }
    }
}

fn void? capture_bounds_native_pair(
    Fixture* fixture,
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    CrowdNativeOutput* actual,
    CrowdNativeOutput* reference,
) @private {
    match_bounds_native_shadow_fit(fixture, pair, sources);
    Renderer* renderer = &fixture.renderer;
    for (uint frame = 0; frame < CROWD_NATIVE_WARMUP; frame++) {
        renderer.begin_frame({ .time = 0.37, .delta = 0 })!;
        defer catch render::abort_frame(renderer);
        record_crowd_lod_native_output(
            fixture: fixture,
            pair: pair,
            output: actual,
            actual: true,
        )!;
        record_crowd_lod_native_output(
            fixture: fixture,
            pair: pair,
            output: reference,
            actual: false,
        )!;
        renderer.end_frame()!;
    }
    render::wait_frames(renderer)!;
    read_crowd_lod_native_output(fixture, actual)!;
    read_crowd_lod_native_output(fixture, reference)!;
}

fn uint bounds_native_coverage(CrowdNativeImages* images) @private {
    uint count;
    foreach (index, depth : images.depth) {
        if (depth.x <= 0) continue;
        count++;
        assert(math::abs(images.velocity[index].x) < CROWD_NATIVE_STILL_TOLERANCE);
        assert(math::abs(images.velocity[index].y) < CROWD_NATIVE_STILL_TOLERANCE);
    }
    return count;
}

fn void check_bounds_native_images(CrowdNativeImages* actual, CrowdNativeImages* reference) @private {
    assert(bounds_native_coverage(actual) > 0 && bounds_native_coverage(reference) > 0);
    check_crowd_native_image(actual.color, reference.color, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(reference.color, actual.color, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(actual.depth, reference.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(reference.depth, actual.depth, CROWD_NATIVE_DEPTH_TOLERANCE);
    check_crowd_native_image(actual.normal, reference.normal, CROWD_NATIVE_COLOR_TOLERANCE);
    check_crowd_native_image(reference.normal, actual.normal, CROWD_NATIVE_COLOR_TOLERANCE);
    uint resolution = actual.shadow_resolution;
    assert(resolution > 0 && resolution == reference.shadow_resolution);
    uint actual_shadow;
    uint reference_shadow;
    for (uint pixel = 0; pixel < resolution * resolution; pixel++) {
        if (actual.shadow[pixel].x > 0) actual_shadow++;
        if (reference.shadow[pixel].x > 0) reference_shadow++;
    }
    assert(actual_shadow > 0 && reference_shadow > 0);
    check_crowd_native_image(
        actual: actual.shadow,
        expected: reference.shadow,
        tolerance: CROWD_NATIVE_DEPTH_TOLERANCE,
        width: resolution,
        height: resolution,
    );
    check_crowd_native_image(
        actual: reference.shadow,
        expected: actual.shadow,
        tolerance: CROWD_NATIVE_DEPTH_TOLERANCE,
        width: resolution,
        height: resolution,
    );
}

fn void configure_bounds_native_output(Fixture* fixture, CrowdNativeOutput* output) @private {
    ViewDesc desc = render::texture_view_desc(output.target);
    desc.shading = ShadingPath.DEFERRED;
    desc.post.motion_blur = true;
    desc.share_shadows = false;
    desc.lod_bias = 16;
    render::configure_view(&fixture.renderer, output.view, desc)!!;
}

fn void set_bounds_native_crop(
    CrowdNativePair* pair,
    CrowdLodNativeSources* sources,
    uint crop,
) @private {
    Vec3 point = bounds_native_world(bounds_native_placement(pair, sources, 0), BOUNDS_NATIVE_CROP_CENTRES[crop]);
    *pair.scene.get(pair.camera, Camera) = camera::orthographic(BOUNDS_NATIVE_CROP_HEIGHTS[crop], 0.1f, 60);
    pair.camera.local.position = { point.x, point.y, 20 };
    pair.scene.update_world();
}

fn void release_bounds_native_geometry(Fixture* fixture, BoundsNativeAssets* assets) @private {
    for (uint part = 0; part < BOUNDS_NATIVE_PARTS; part++) {
        if (part == 3) continue;
        fixture.assets.release_geometry_cpu(assets.fixture.geometries[part]);
        fixture.assets.release_geometry_cpu(assets.coarse[part]);
        assert(fixture.assets.geometry(assets.fixture.geometries[part]).data.positions.len == 0);
        assert(fixture.assets.geometry(assets.coarse[part]).data.positions.len == 0);
    }
}

fn void check_bounds_native_level(Stats* stats, uint level, bool crowd) @private {
    assert(stats.lod_fallbacks == 0 && stats.cull_overflows == 0 && stats.sort_overflows == 0);
    for (uint choice = 0; choice < scene::MAX_LOD_CHOICES; choice++) {
        uint expected = choice == level ? CROWD_NATIVE_INSTANCES : 0;
        if (crowd) {
            assert(stats.lod_counts_valid && stats.lod_instances_tested == CROWD_NATIVE_INSTANCES);
            assert(stats.lod_selected[choice] == expected);
        } else {
            assert(stats.lod_objects_selected[choice] == expected);
        }
    }
    io::printfn("mixed bounds level=%s crowd=%s", level, crowd);
}

fn void test_animated_lod_native_mixed_stretched_bounds_queries_and_cpu_release() @test {
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
            model: assets.fixture.mixed,
            clip: assets.clip,
            bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            placements: placements[..],
        )!!;
        defer scene::destroy_scene(&pair.scene);
        use_crowd_native_standard_materials(&fixture, &pair)!!;
        CrowdLodNativeSources sources;
        attach_bounds_native_sources(
            fixture: &fixture,
            pair: &pair,
            assets: &assets,
            sources: &sources,
            crowd: crowd,
        )!!;
        SceneIndex index = spatial::create_scene_index(mem, CROWD_NATIVE_INSTANCES * BOUNDS_NATIVE_PARTS);
        defer spatial::destroy_scene_index(&index);
        CrowdNativeOutput actual;
        create_crowd_native_output(&fixture, &actual)!!;
        defer destroy_crowd_native_output(&fixture, &actual);
        CrowdNativeOutput reference;
        create_crowd_native_output(&fixture, &reference)!!;
        defer destroy_crowd_native_output(&fixture, &reference);
        configure_bounds_native_output(&fixture, &actual);
        configure_bounds_native_output(&fixture, &reference);
        Light sun = light::directional({ 1, 1, 1 }, 1);
        sun.shadow.cascades = 1;
        sun.shadow.max_distance = 60;
        Node* light_node = pair.scene.add_light(sun)!!;
        light_node.local.rotation = maths::look_rotation((Vec3){ -0.8f, -0.3f, -1 }.normalize(), { 0, 1, 0 });
        ulong[3] identities;
        uint[3] revisions;
        ulong playback_identity;
        uint[3] generations;
        if (crowd) {
            AnimatedCrowd* animated = pair.scene.get(pair.crowd, AnimatedCrowd);
            playback_identity = animated.playback.identity;
            foreach (source, slot : animated.playback.slots) generations[source] = slot.generation;
        }
        for (uint source = 0; source < (crowd ? 1u : CROWD_NATIVE_INSTANCES); source++) {
            LodGroupState* state = pair.scene.get(bounds_native_owner(&pair, &sources, source), LodGroup).state;
            identities[source] = state.identity;
            revisions[source] = state.descriptor_revision;
        }
        for (uint crop = 0; crop < 3; crop++) {
            set_bounds_native_pose(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                time: 0,
            );
            set_bounds_native_crop(&pair, &sources, crop);
            capture_bounds_native_pair(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                actual: &actual,
                reference: &reference,
            )!!;
            assert(bounds_native_coverage(&actual.actual) == 0 && bounds_native_coverage(&reference.actual) == 0);
            set_bounds_native_pose(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                time: 1,
            );
            capture_bounds_native_pair(
                fixture: &fixture,
                pair: &pair,
                sources: &sources,
                actual: &actual,
                reference: &reference,
            )!!;
            check_bounds_native_images(&actual.actual, &reference.actual);
            io::printfn("stretched native crop=%s crowd=%s", crop, crowd);
        }
        set_bounds_native_pose(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            time: 1,
        );
        check_bounds_native_queries(
            fixture: &fixture,
            pair: &pair,
            assets: &assets,
            sources: &sources,
            index: &index,
            released: false,
        );
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(42, 0.1f, 60);
        pair.camera.local.position = { 0, 3, 30 };
        for (uint parity = 0; parity < 2; parity++) {
            if (parity) {
                for (uint source = 0; source < 2; source++) {
                    if (crowd) pair.scene.get(pair.crowd, AnimatedCrowd).placements[source].scale.x *= -1;
                    else sources.ordinary[source].local.scale.x *= -1;
                    pair.ordinary[source].local.scale.x *= -1;
                }
                if (crowd) pair.scene.write_crowd_batches(pair.scene.get(pair.crowd, AnimatedCrowd));
                crowd_native_update(&fixture, &pair, 0);
            }
            for (uint level = 0; level < 2; level++) {
                ViewDesc desc = fixture.renderer.views.get(actual.view).desc;
                desc.lod_bias = level == 0 ? 16 : -16;
                render::configure_view(&fixture.renderer, actual.view, desc)!!;
                set_bounds_native_reference_level(
                    fixture: &fixture,
                    pair: &pair,
                    assets: &assets,
                    level: level,
                );
                capture_bounds_native_pair(
                    fixture: &fixture,
                    pair: &pair,
                    sources: &sources,
                    actual: &actual,
                    reference: &reference,
                )!!;
                check_bounds_native_images(&actual.actual, &reference.actual);
                check_bounds_native_level(&actual.actual.stats, level, crowd);
                check_bounds_native_queries(
                    fixture: &fixture,
                    pair: &pair,
                    assets: &assets,
                    sources: &sources,
                    index: &index,
                    released: false,
                );
            }
        }
        set_bounds_native_pose(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            time: 0.45f,
        );
        ViewDesc hysteresis_desc = fixture.renderer.views.get(actual.view).desc;
        hysteresis_desc.lod_bias = 0;
        render::configure_view(&fixture.renderer, actual.view, hysteresis_desc)!!;
        capture_bounds_native_pair(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        check_bounds_native_level(&actual.actual.stats, 1, crowd);
        Vec3 half_extent = crowd ? (Vec3){ 9 * 0.8f, 4.5f * 1.2f, 4 * 0.7f }
            : (Vec3){ 5.625f * 0.8f, 1.4875f * 1.2f, 1.5f * 0.7f };
        pair.scene.get(pair.camera, Camera).ortho_height = 2 * half_extent.length() / 0.51f;
        capture_bounds_native_pair(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        check_bounds_native_level(&actual.actual.stats, 1, crowd);
        set_bounds_native_pose(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            time: 0.5f,
        );
        capture_bounds_native_pair(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        check_bounds_native_level(&actual.actual.stats, 1, crowd);
        io::printfn("pose-only hysteresis retained above0.5/below0.55 crowd=%s", crowd);
        set_bounds_native_pose(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            time: 1,
        );
        *pair.scene.get(pair.camera, Camera) = camera::orthographic(42, 0.1f, 60);
        ViewDesc coarse_desc = fixture.renderer.views.get(actual.view).desc;
        coarse_desc.lod_bias = -16;
        render::configure_view(&fixture.renderer, actual.view, coarse_desc)!!;
        capture_bounds_native_pair(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        check_bounds_native_images(&actual.actual, &reference.actual);
        release_bounds_native_geometry(&fixture, &assets);
        capture_bounds_native_pair(
            fixture: &fixture,
            pair: &pair,
            sources: &sources,
            actual: &actual,
            reference: &reference,
        )!!;
        check_bounds_native_images(&actual.actual, &reference.actual);
        check_bounds_native_level(&actual.actual.stats, 1, crowd);
        check_bounds_native_queries(
            fixture: &fixture,
            pair: &pair,
            assets: &assets,
            sources: &sources,
            index: &index,
            released: true,
        );
        for (uint source = 0; source < (crowd ? 1u : CROWD_NATIVE_INSTANCES); source++) {
            LodGroupState* state = pair.scene.get(bounds_native_owner(&pair, &sources, source), LodGroup).state;
            assert(state.identity == identities[source] && state.descriptor_revision == revisions[source]);
            render::LodHistoryEntry* history = &fixture.renderer.views.get(actual.view)
                .lod_history.entries[bounds_native_owner(&pair, &sources, source).id.index];
            assert(history.committed.valid);
            if (!crowd) assert(history.committed.level == 1);
        }
        if (crowd) {
            AnimatedCrowd* animated = pair.scene.get(pair.crowd, AnimatedCrowd);
            assert(animated.playback.identity == playback_identity);
            foreach (source, slot : animated.playback.slots) assert(slot.generation == generations[source]);
        }
        check_crowd_native_validation(&fixture.renderer);
    }
}
