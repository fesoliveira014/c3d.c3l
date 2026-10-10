module c3d::test;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::spatial;
import c3d::test::animated_crowd_fixtures;
import std::math;

const float ANIMATED_LOD_QUERY_TOLERANCE @local = 1e-5f;

fn AssetStore animated_lod_query_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8, .max_textures = 8, .max_materials = 4, .max_samplers = 8,
        .max_models = 8, .max_skeletons = 8, .max_clips = 8,
    });
}

fn AnimatedLodDesc animated_lod_query_desc(AssetStore* assets, ModelId model_id) @local {
    ModelTemplate* template = &assets.model(model_id).data;
    uint count = (uint)template.meshes.len;
    LodLevel[] levels = alloc::new_array(tmem, LodLevel, 2);
    levels[0] = { .first_part = 0, .part_count = count, .min_screen_size = 0.2f };
    levels[1] = { .first_part = count, .part_count = count, .min_screen_size = 0 };
    AnimatedLodPart[] parts = alloc::new_array(tmem, AnimatedLodPart, (sz)count * 2);
    for (uint level = 0; level < 2; level++) {
        foreach (uint index, mesh : template.meshes) {
            ModelSkin skin;
            foreach (candidate : template.skins) {
                if (candidate.mesh_node == mesh.node) skin = candidate;
            }
            parts[level * count + index] = {
                .draw = { .geometry = mesh.geometry, .material = mesh.material, .local = matrix::IDENTITY4 },
                .mesh_index = index,
                .skin = skin,
                .default_morph_weights = mesh.default_morph_weights,
            };
        }
    }
    AnimatedLodPart first = parts[0];
    parts[0] = parts[count - 1];
    parts[count - 1] = first;
    return { .levels = levels, .parts = parts };
}

fn bool animated_lod_query_contains(Aabb bounds, Vec3 point) @local {
    for (uint axis = 0; axis < 3; axis++) {
        if (point[axis] < bounds.min[axis] - ANIMATED_LOD_QUERY_TOLERANCE
          || point[axis] > bounds.max[axis] + ANIMATED_LOD_QUERY_TOLERANCE) return false;
    }
    return true;
}

fn void animated_lod_query_equal(PickHit[] direct, PickHit[] indexed) @local {
    assert(direct.len == indexed.len);
    foreach (index, hit : direct) {
        assert(hit.node == indexed[index].node && hit.lod_group == indexed[index].lod_group);
        assert(hit.instance_index == indexed[index].instance_index && hit.part_index == indexed[index].part_index);
        assert(c3d::same_id(hit.geometry, indexed[index].geometry));
        assert(hit.distance == indexed[index].distance && hit.triangle_hit == indexed[index].triangle_hit);
    }
}

fn void test_animated_lod_queries_use_posed_base_logical_parts_once() @test {
    @pool() {
        AssetStore assets = animated_lod_query_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
        Animator* animator = anim::add_animator(&scene, owner);
        AnimationActionId action = animator.play(&assets, fixture.posing)!!;
        Action* played = animator.try_action(action)!!;
        played.loop = false;
        animator.action(action).time = 1;
        anim::update(&assets, &scene, 0);
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: animated_lod_query_desc(&assets, fixture.mixed),
        )!!;
        Node* extra = scene.add_mesh(
            geometry: fixture.geometries[1],
            material: fixture.material,
            parent: owner,
            name: "unrelated_child",
        )!!;
        extra.local.position.x = 40;
        scene.update_world();
        SceneIndex index = spatial::create_scene_index(mem, 6);
        defer spatial::destroy_scene_index(&index);
        index.refresh(&assets, &scene)!!;
        assert(index.count == 6 && index.dangling == 0);
        uint[animated_crowd_fixtures::PARTS_MESH_COUNT] seen;
        uint unrelated;
        foreach (entry : index.entries[:index.count]) {
            if (!entry.flags.lod_group) {
                assert(entry.node == extra);
                unrelated++;
            } else {
                assert(entry.node == owner && entry.instance_index == 0 && !entry.flags.instanced);
                assert(entry.part_index < seen.len);
                seen[entry.part_index]++;
                assert(c3d::same_id(entry.geometry, fixture.geometries[entry.part_index]));
                assert(entry.flags.static_triangles == (entry.part_index == 1));
                assert(entry.flags.skinned == (entry.part_index == 0 || entry.part_index == 4));
                for (uint vertex = 0; vertex < animated_crowd_fixtures::PARTS_VERTEX_COUNT; vertex++) {
                    assert(animated_lod_query_contains(entry.bounds,
                        animated_crowd_fixtures::PARTS_POSED_POINTS[3 * entry.part_index + vertex]));
                }
                if (entry.part_index == 1) {
                    assert(entry.bounds.min == (Vec3){ 14, 1, -2 });
                    assert(entry.bounds.max == (Vec3){ 16, 2, -2 });
                }
            }
        }
        foreach (count : seen) assert(count == 1);
        assert(unrelated == 1);
        spatial::prepare_triangle_picks(&assets, &scene);
        for (uint part = 0; part < animated_crowd_fixtures::PARTS_MESH_COUNT; part++) {
            Vec3 first = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part];
            Vec3 second = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + 1];
            Vec3 third = animated_crowd_fixtures::PARTS_POSED_POINTS[3 * part + 2];
            Vec3 centre = (first + second + third) / 3;
            Ray ray = { .origin = { centre.x, centre.y, 10 }, .direction = { 0, 0, -1 } };
            PickOptions options = { .precision = PickPrecision.TRIANGLES, .faces = PickFaces.BOTH, .layers = uint::max };
            PickHit[] direct = spatial::pick(
                allocator: tmem,
                assets: &assets,
                scene: &scene,
                ray: ray,
                options: options,
            );
            PickHit[] indexed = index.pick(
                allocator: tmem,
                assets: &assets,
                ray: ray,
                options: options,
            );
            animated_lod_query_equal(direct, indexed);
            bool found;
            foreach (hit : direct) {
                if (hit.node == owner && hit.part_index == part) {
                    found = true;
                    assert(hit.lod_group && hit.instance_index == 0);
                    assert(c3d::same_id(hit.geometry, fixture.geometries[part]));
                    assert(hit.triangle_hit == (part == 1));
                }
            }
            assert(found);
        }
    };
}

fn void test_animated_lod_queries_keep_retained_pose_bounds_without_cpu_streams() @test {
    @pool() {
        AssetStore assets = animated_lod_query_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
        Animator* animator = anim::add_animator(&scene, owner);
        AnimationActionId action = animator.play(&assets, fixture.posing)!!;
        Action* played = animator.try_action(action)!!;
        played.loop = false;
        animator.action(action).time = 1;
        anim::update(&assets, &scene, 0);
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: animated_lod_query_desc(&assets, fixture.mixed),
        )!!;
        scene.update_world();
        SceneIndex index = spatial::create_scene_index(mem, 5);
        defer spatial::destroy_scene_index(&index);
        index.refresh(&assets, &scene)!!;
        Aabb[animated_crowd_fixtures::PARTS_MESH_COUNT] retained;
        foreach (entry : index.entries[:index.count]) retained[entry.part_index] = entry.bounds;
        assets.release_geometry_cpu(fixture.geometries[0]);
        assets.release_geometry_cpu(fixture.geometries[1]);
        assets.release_geometry_cpu(fixture.geometries[2]);
        assets.release_geometry_cpu(fixture.geometries[4]);
        index.refresh(&assets, &scene)!!;
        assert(index.count == 5 && index.dangling == 0);
        foreach (entry : index.entries[:index.count]) {
            assert(entry.bounds.min == retained[entry.part_index].min);
            assert(entry.bounds.max == retained[entry.part_index].max);
            assert(!entry.flags.static_triangles);
        }
        Ray ray = { .origin = { 10.5f, 1, 10 }, .direction = { 0, 0, -1 } };
        PickOptions options = { .precision = PickPrecision.TRIANGLES, .faces = PickFaces.BOTH, .layers = uint::max };
        PickHit[] direct = spatial::pick(
            allocator: tmem,
            assets: &assets,
            scene: &scene,
            ray: ray,
            options: options,
        );
        PickHit[] indexed = index.pick(
            allocator: tmem,
            assets: &assets,
            ray: ray,
            options: options,
        );
        animated_lod_query_equal(direct, indexed);
        assert(direct.len > 0);
        foreach (hit : direct) assert(!hit.triangle_hit);
    };
}

fn void test_animated_lod_queries_use_crowd_envelope_source_slots_and_regrowth() @test {
    @pool() {
        AssetStore assets = animated_lod_query_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = scene.add_node(name: "crowd_lod")!!;
        owner.local.position = animated_crowd_fixtures::PARTS_ROOT_POSITION;
        CrowdInstance[2] instances = {
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .clip = fixture.posing, .time = 0.75f, .speed = 1, .loop = true }, .color = { 1, 1, 1, 1 } },
            { .placement = maths::TRANSFORM_IDENTITY, .pose = { .clip = fixture.posing, .time = 0.25f, .speed = 1, .loop = true }, .color = { 0.5f, 0.7f, 1, 1 } },
        };
        instances[0].placement.scale = { -2, 3, 0.5f };
        instances[1].placement.position.x = 50;
        model::attach_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            model: fixture.mixed,
            capacity: 4,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: instances[..],
        )!!;
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: animated_lod_query_desc(&assets, fixture.mixed),
        )!!;
        LodGroupState* state = scene.get(owner, LodGroup).state;
        ulong identity = state.identity;
        uint descriptor = state.descriptor_revision;
        assert(state.count == 0);
        model::prepare_crowd(&assets, &scene, owner)!!;
        scene.update_world();
        Ray ray = { .origin = { 10, 0, 10 }, .direction = { 0, 0, -1 } };
        PickOptions options = { .precision = PickPrecision.TRIANGLES, .faces = PickFaces.BOTH, .layers = uint::max };
        PickHit[] initial = spatial::pick(
            allocator: tmem,
            assets: &assets,
            scene: &scene,
            ray: ray,
            options: options,
        );
        assert(state.count == 2 && initial.len == 5);
        SceneIndex index = spatial::create_scene_index(mem, 10);
        defer spatial::destroy_scene_index(&index);
        index.refresh(&assets, &scene)!!;
        assert(index.count == 10 && index.dangling == 0);
        uint generation = state.slot_generations[0];
        uint[10] seen;
        foreach (entry : index.entries[:index.count]) {
            assert(entry.node == owner && entry.flags.lod_group && entry.flags.instanced);
            assert(!entry.flags.static_triangles && entry.instance_index < 2);
            assert(entry.part_index < 5 && c3d::same_id(entry.geometry, fixture.geometries[entry.part_index]));
            seen[5 * entry.instance_index + entry.part_index]++;
            Aabb expected = entry.instance_index == 0
              ? (Aabb){ .min = { -14, -9, -4 }, .max = { 22, 18, 0 } }
              : (Aabb){ .min = { 54, -3, -6 }, .max = { 72, 6, 2 } };
            assert(entry.bounds.min == expected.min && entry.bounds.max == expected.max);
        }
        foreach (count : seen) assert(count == 1);
        PickHit[] indexed = index.pick(
            allocator: tmem,
            assets: &assets,
            ray: ray,
            options: options,
        );
        animated_lod_query_equal(initial, indexed);
        foreach (hit : initial) assert(hit.instance_index == 0 && !hit.triangle_hit);
        ray.origin.x = 60;
        PickHit[] second = spatial::pick(
            allocator: tmem,
            assets: &assets,
            scene: &scene,
            ray: ray,
            options: options,
        );
        assert(second.len == 5);
        foreach (hit : second) assert(hit.instance_index == 1 && hit.node == owner);
        model::set_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            instances: instances[:1],
        )!!;
        index.refresh(&assets, &scene)!!;
        assert(index.count == 5 && state.count == 1 && state.slot_generations[0] != generation);
        model::set_crowd(
            assets: &assets,
            scene: &scene,
            node: owner,
            instances: instances[..],
        )!!;
        index.refresh(&assets, &scene)!!;
        assert(index.count == 10 && state.count == 2);
        assert(state.identity == identity && state.descriptor_revision == descriptor);
        foreach (entry : index.entries[:index.count]) {
            assert(entry.node == owner && entry.part_index < 5 && entry.instance_index < 2);
        }
    };
}

fn void test_animated_lod_queries_skip_whole_missing_source_without_base_duplicates() @test {
    @pool() {
        AssetStore assets = animated_lod_query_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        SceneIndex index = spatial::create_scene_index(mem, 5);
        defer spatial::destroy_scene_index(&index);
        for (uint missing = 0; missing < 3; missing++) {
            Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
            model::attach_animated_lod(
                assets: &assets,
                scene: &scene,
                owner: owner,
                desc: animated_lod_query_desc(&assets, fixture.mixed),
            )!!;
            scene.update_world();
            index.refresh(&assets, &scene)!!;
            assert(index.count == 5);
            ModelInstance* instance = scene.get(owner, ModelInstance);
            if (missing < 2) {
                scene.remove(instance.present_node(missing == 0 ? 4u : 0u));
            } else {
                assets.remove_geometry(fixture.geometries[2]);
            }
            Ray ray = { .origin = { 6, 0.5f, 10 }, .direction = { 0, 0, -1 } };
            PickHit[] direct = spatial::pick(
                allocator: tmem,
                assets: &assets,
                scene: &scene,
                ray: ray,
            );
            PickHit[] indexed = index.pick(
                allocator: tmem,
                assets: &assets,
                ray: ray,
            );
            assert(direct.len == 0 && indexed.len == 0);
            spatial::prepare_triangle_picks(&assets, &scene);
            index.refresh(&assets, &scene)!!;
            assert(index.count == 0 && index.dangling == 1);
            scene.remove(owner);
        }
    };
}
