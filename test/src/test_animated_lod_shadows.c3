module c3d::test::animated_lod_shadows;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::spatial;
import std::math;
import c3d::test::animated_crowd_fixtures;

const uint SHADOW_BASE_PARTS @local = 5;
const uint SHADOW_REDUCED_PARTS @local = 2;
const uint SHADOW_REPRESENTATIONS @local = SHADOW_BASE_PARTS + SHADOW_REDUCED_PARTS;

fn AssetStore shadow_lod_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8, .max_textures = 8, .max_materials = 4, .max_samplers = 8,
        .max_models = 8, .max_skeletons = 8, .max_clips = 8,
    });
}

fn AnimatedLodDesc shadow_lod_desc(AssetStore* assets, ModelId model_id) @local {
    ModelTemplate* template = &assets.model(model_id).data;
    assert(template.meshes.len == SHADOW_BASE_PARTS);
    LodLevel[] levels = alloc::new_array(tmem, LodLevel, 2);
    levels[0] = { .first_part = 0, .part_count = SHADOW_BASE_PARTS, .min_screen_size = 0.2f };
    levels[1] = { .first_part = SHADOW_BASE_PARTS, .part_count = SHADOW_REDUCED_PARTS, .min_screen_size = 0 };
    AnimatedLodPart[] parts = alloc::new_array(tmem, AnimatedLodPart, SHADOW_REPRESENTATIONS);
    foreach (uint index, mesh : template.meshes) {
        ModelSkin skin;
        foreach (candidate : template.skins) {
            if (candidate.mesh_node == mesh.node) skin = candidate;
        }
        parts[index] = {
            .draw = { .geometry = mesh.geometry, .material = mesh.material, .local = matrix::IDENTITY4 },
            .mesh_index = index,
            .skin = skin,
            .default_morph_weights = mesh.default_morph_weights,
        };
    }
    parts[SHADOW_BASE_PARTS] = parts[0];
    parts[SHADOW_BASE_PARTS + 1] = parts[2];
    return { .levels = levels, .parts = parts };
}

fn void test_animated_lod_shadow_ordinary_uses_selected_parts_without_imported_bases() @test {
    @pool() {
        AssetStore assets = shadow_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        Node* owner = model::instantiate(&assets, &scene, fixture.mixed)!!;
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: shadow_lod_desc(&assets, fixture.mixed),
        )!!;
        Node* unrelated = scene.add_mesh(
            geometry: fixture.geometries[1],
            material: fixture.material,
            parent: owner,
            name: "unrelated_shadow_child",
        )!!;
        unrelated.local.position.x = 30;
        scene.update_world();
        LodGroup* group = scene.get(owner, LodGroup);
        LodSelection[1] selections = {
            {
                .scene = &scene,
                .scene_identity = scene.identity,
                .node = owner,
                .state = group.state,
                .level = 1,
                .world_bounds = spatial::lod_world_bounds(
                    assets: &assets,
                    node: owner,
                    group: group,
                    scene: &scene,
                ),
            },
        };
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_shadow_candidates(
            allocator: tmem,
            scene: &scene,
            assets: &assets,
            fade_origin: {},
            counts: &counts,
            lod: selections[..],
        );
        assert(counts.dangling == 0 && counts.visible == 3 && candidates.len == 3);
        uint imported;
        uint unrelated_count;
        uint[SHADOW_REDUCED_PARTS] selected;
        ModelInstance* instance = scene.get(owner, ModelInstance);
        foreach (candidate : candidates) {
            if (candidate.node == unrelated) {
                assert(candidate.lod == null && candidate.animated_lod == null);
                unrelated_count++;
            } else if (candidate.node == owner) {
                assert(candidate.lod == &selections[0] && candidate.lod_level == 1);
                assert(candidate.lod_part >= SHADOW_BASE_PARTS && candidate.lod_part < SHADOW_REPRESENTATIONS);
                uint part = candidate.lod_part - SHADOW_BASE_PARTS;
                selected[part]++;
                assert(candidate.animated_lod.mesh_index == (part == 0 ? 0u : 2u));
                assert(candidate.animated_lod.skinned == (part == 0));
                assert(candidate.model_instance == instance && candidate.crowd == null);
                assert(candidate.source_node == instance.present_node(part == 0 ? 2u : 5u));
                assert(candidate.instance_count == 1);
                assert(c3d::same_id(candidate.geometry, fixture.geometries[part == 0 ? 0u : 2u]));
            } else {
                imported++;
            }
        }
        assert(imported == 0 && unrelated_count == 1);
        foreach (count : selected) assert(count == 1);
    };
}

fn void test_animated_lod_shadow_crowd_keeps_parent_representations_and_source_parities() @test {
    @pool() {
        AssetStore assets = shadow_lod_store();
        defer asset::destroy_asset_store(&assets);
        PartsFixture fixture = animated_crowd_fixtures::add_parts_fixture(&assets)!!;
        Scene scene = scene::create_scene(mem, { .max_nodes = 64 });
        defer scene::destroy_scene(&scene);
        CrowdInstance[3] instances;
        for (uint source = 0; source < 3; source++) {
            instances[source] = {
                .placement = maths::TRANSFORM_IDENTITY,
                .pose = { .clip = fixture.posing, .time = 0.25f * (float)source, .speed = 0, .loop = false },
                .color = { 1, 1, 1, 1 },
            };
            instances[source].placement.position.x = 30 * (float)source;
        }
        instances[1].placement.scale.x = -1;
        Node* owner = model::add_crowd(
            assets: &assets,
            scene: &scene,
            model: fixture.mixed,
            capacity: 3,
            pose_bounds: animated_crowd_fixtures::PARTS_POSE_BOUNDS,
            instances: instances[..],
        )!!;
        model::attach_animated_lod(
            assets: &assets,
            scene: &scene,
            owner: owner,
            desc: shadow_lod_desc(&assets, fixture.mixed),
        )!!;
        Node* unrelated = scene.add_mesh(
            geometry: fixture.geometries[1],
            material: fixture.material,
            parent: owner,
            name: "unrelated_crowd_shadow_child",
        )!!;
        unrelated.local.position.x = 90;
        scene.update_world();
        LodGroup* group = scene.get(owner, LodGroup);
        uint[SHADOW_REPRESENTATIONS] unmirrored;
        unmirrored[..] = 2;
        LodSelection[1] selections = {
            {
                .scene = &scene,
                .scene_identity = scene.identity,
                .node = owner,
                .state = group.state,
                .part_unmirrored = unmirrored[..],
                .world_bounds = spatial::lod_world_bounds(
                    assets: &assets,
                    node: owner,
                    group: group,
                    scene: &scene,
                ),
            },
        };
        ExtractCounts counts;
        MeshCandidate[] candidates = render::extract_shadow_candidates(
            allocator: tmem,
            scene: &scene,
            assets: &assets,
            fade_origin: {},
            counts: &counts,
            lod: selections[..],
        );
        assert(counts.dangling == 0 && counts.visible == 15 && candidates.len == 15);
        AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
        uint unrelated_count;
        uint[SHADOW_REPRESENTATIONS] parities;
        foreach (candidate : candidates) {
            if (candidate.node == unrelated) {
                assert(candidate.lod == null && candidate.batch == null);
                unrelated_count++;
            } else {
                assert(candidate.node == owner && candidate.lod == &selections[0]);
                assert(candidate.batch == null && candidate.crowd == crowd);
                assert(candidate.lod_part < SHADOW_REPRESENTATIONS);
                assert(candidate.lod_level == (candidate.lod_part < SHADOW_BASE_PARTS ? 0u : 1u));
                assert(candidate.instance_count == (candidate.mirrored ? 1u : 2u));
                assert(c3d::same_id(candidate.geometry, group.state.desc.parts[candidate.lod_part].geometry));
                parities[candidate.lod_part] |= candidate.mirrored ? 2u : 1u;
                foreach (part : crowd.parts) assert(!c3d::same_id(candidate.node.id, part.batch));
            }
        }
        assert(unrelated_count == 1);
        foreach (parity : parities) assert(parity == 3);
    };
}
