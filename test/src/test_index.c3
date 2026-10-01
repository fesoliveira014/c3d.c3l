module c3d::test::index;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::spatial;
import c3d::spatial::bvh;
import std::math;

const uint SEED @local = 0x2545f491;
const float TOLERANCE @local = 1e-5f;
const uint MESH_COUNT @local = 200;
const uint BATCH_COUNT @local = 3;
const uint BATCH_SIZE @local = 50;
const uint CROWD_SIZE @local = 10;
const uint RAY_COUNT @local = 64;
const float FIELD @local = 20; // meshes and batch nodes lie in -FIELD to FIELD on each axis

struct Random @local {
    uint state;
}

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    GeometryId box;
    GeometryId released;
    MaterialId one_sided;
    MaterialId two_sided;
}

fn uint next_bits(Random* random) @local {
    random.state ^= random.state << 13;
    random.state ^= random.state >> 17;
    random.state ^= random.state << 5;
    return random.state;
}

fn float next_float(Random* random, float low, float high) @local {
    return low + (high - low) * (float)(next_bits(random) >> 8) / (float)(1u << 24);
}

fn Vec3 next_point(Random* random, float low, float high) @local {
    return { next_float(random, low, high), next_float(random, low, high), next_float(random, low, high) };
}

fn Transform random_transform(Random* random, float extent) @local {
    Vec3 axis = next_point(random, 0.1f, 1);
    return {
        .position = next_point(random, -extent, extent),
        .rotation = quaternion::from_axis_angle{float}(axis.normalize(), next_float(random, 0, 2 * math::PI)),
        .scale    = next_point(random, 0.5f, 2),
    };
}

fn Fixture make_fixture(uint max_nodes = 16) @local {
    Fixture fixture;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 3,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
        .max_skeletons  = 2,
    });
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        fixture.box = fixture.assets.add_geometry(&box, "box")!!;
        fixture.released = fixture.assets.add_geometry(&box, "released")!!;
    };
    fixture.one_sided = fixture.assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }), "single")!!;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    fixture.two_sided = fixture.assets.add_material(material::basic({ .color = { 0, 1, 0, 1 } }, common), "double")!!;
    fixture.scene = scene::create_scene(mem, { .max_nodes = max_nodes });
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_box(Fixture* fixture, Vec3 position, Node* parent = null) @local {
    Node* node = fixture.scene.add_mesh(fixture.box, fixture.one_sided, parent: parent)!!;
    node.local.position = position;
    return node;
}

fn Node* add_skinned_box(Fixture* fixture, Vec3 joint_position) @local {
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, 1),
        .parents      = alloc::new_array(mem, int, 1),
        .rest_pose    = alloc::new_array(mem, Transform, 1),
        .inverse_bind = alloc::new_array(mem, Mat4, 1),
    };
    skeleton.parents[0] = -1;
    skeleton.rest_pose[0] = maths::TRANSFORM_IDENTITY;
    skeleton.inverse_bind[0] = matrix::IDENTITY4;
    SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton, "skeleton")!!;
    Node* joint = fixture.scene.add_node(name: "joint")!!;
    joint.local.position = joint_position;
    GeometryId skinned_box;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        box.joints = alloc::new_array(tmem, ushort[<4>], box.positions.len);
        box.weights = alloc::new_array(tmem, Vec4, box.positions.len);
        foreach (&weight : box.weights) *weight = { 1, 0, 0, 0 };
        skinned_box = fixture.assets.add_geometry(&box, "skinned_box")!!;
    };
    Node* skinned = fixture.scene.add_mesh(skinned_box, fixture.one_sided, name: "skinned")!!;
    Node*[] joints = alloc::new_array(fixture.scene.allocator, Node*, 1);
    joints[0] = joint;
    fixture.scene.add(skinned, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
    return skinned;
}

fn Node* add_random_batch(
    Fixture* fixture,
    Random* random,
    uint count,
    Node* parent = null,
) @local {
    Transform[] transforms = alloc::new_array(tmem, Transform, (sz)count);
    foreach (&transform : transforms) *transform = random_transform(random, 4);
    Node* node = fixture.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.two_sided,
        capacity:   count,
        transforms: transforms,
        parent:     parent,
    )!!;
    node.local.position = next_point(random, -FIELD, FIELD);
    return node;
}

fn Ray random_ray(Random* random) @local {
    Vec3 origin = next_point(random, -2 * FIELD, 2 * FIELD);
    Vec3 target = next_point(random, -FIELD, FIELD);
    return { .origin = origin, .direction = (target - origin).normalize() };
}

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn bool same_hit(PickHit* first, PickHit* second) @local {
    return first.node == second.node && first.instanced == second.instanced
        && first.instance_index == second.instance_index && first.triangle_hit == second.triangle_hit
        && first.triangle_index == second.triangle_index && close(first.distance, second.distance)
        && close(first.barycentric.x, second.barycentric.x) && close(first.barycentric.y, second.barycentric.y)
        && close(first.barycentric.z, second.barycentric.z) && (first.position - second.position).length() <= TOLERANCE;
}

fn bool has_entry_for(SceneIndex* index, Node* node) @local {
    foreach (entry : index.entries[:index.count]) {
        if (entry.node == node) return true;
    }
    return false;
}

fn void test_index_pick_matches_scan_on_random_scenes() @test {
    Fixture fixture = make_fixture(max_nodes: 256);
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Random random = { SEED };
    for (uint mesh_index = 0; mesh_index < MESH_COUNT; mesh_index++) {
        MaterialId material = mesh_index % 2 == 1 ? fixture.two_sided : fixture.one_sided;
        Node* node = scene.add_mesh(fixture.box, material)!!;
        node.local = random_transform(&random, FIELD);
    }
    Node* mirrored = add_box(&fixture, { 0, 0, 0 });
    mirrored.local.scale = { -1, 1, 1 };
    Node* hidden = scene.add_node(name: "hidden")!!;
    hidden.visible = false;
    for (uint child = 0; child < 5; child++) add_box(&fixture, next_point(&random, -FIELD, FIELD), hidden);
    Node* off_layer = add_box(&fixture, next_point(&random, -FIELD, FIELD));
    off_layer.layers = 2;
    Node* released = scene.add_mesh(fixture.released, fixture.one_sided)!!;
    released.local.position = next_point(&random, -FIELD, FIELD);
    fixture.assets.release_geometry_cpu(fixture.released);
    add_skinned_box(&fixture, next_point(&random, -FIELD, FIELD));
    Node*[BATCH_COUNT] batches;
    @pool() {
        foreach (&batch : batches) *batch = add_random_batch(&fixture, &random, BATCH_SIZE);
        InstancedMesh* overridden = scene.get(batches[2], InstancedMesh);
        overridden.has_bounds_override = true;
        overridden.local_bounds = { .min = { -3, -3, -3 }, .max = { 3, 3, 3 } };
        // A crowd part batch: bounds override under an AnimatedCrowd node, built without a model.
        Node* crowd = scene.add_node(name: "crowd")!!;
        crowd.local.position = next_point(&random, -FIELD, FIELD);
        scene.add(crowd, (AnimatedCrowd){});
        Node* part = add_random_batch(&fixture, &random, CROWD_SIZE, crowd);
        part.local.position = {};
        InstancedMesh* part_batch = scene.get(part, InstancedMesh);
        part_batch.has_bounds_override = true;
        part_batch.local_bounds = { .min = { -5, -5, -5 }, .max = { 5, 5, 5 } };
    };
    scene.update_world();

    SceneIndex index = spatial::create_scene_index(mem, 512);
    defer spatial::destroy_scene_index(&index);
    index.refresh(&fixture.assets, scene)!!;
    assert(index.count == MESH_COUNT + 4 + BATCH_COUNT * BATCH_SIZE + CROWD_SIZE);

    PickPrecision[2] precisions = { PickPrecision.BOUNDS, PickPrecision.TRIANGLES };
    PickFaces[3] faces = { PickFaces.MATERIAL, PickFaces.BOTH, PickFaces.FRONT };
    uint[2] layers = { camera::ALL_LAYERS, 1 };
    usz hit_count;
    usz triangle_hits;
    for (uint ray_index = 0; ray_index < RAY_COUNT; ray_index++) {
        Ray ray = random_ray(&random);
        foreach (precision : precisions) {
            foreach (face : faces) {
                foreach (layer : layers) {
                    PickOptions options = { .precision = precision, .faces = face, .layers = layer };
                    @pool() {
                        PickHit[] scanned = spatial::pick(
                            allocator: tmem,
                            assets:    &fixture.assets,
                            scene:     scene,
                            ray:       ray,
                            options:   options,
                        );
                        PickHit[] indexed = index.pick(
                            allocator: tmem,
                            assets:    &fixture.assets,
                            ray:       ray,
                            options:   options,
                        );
                        assert(scanned.len == indexed.len);
                        foreach (slot, &hit : scanned) {
                            assert(same_hit(hit, &indexed[slot]));
                            if (hit.triangle_hit) triangle_hits++;
                        }
                        hit_count += scanned.len;
                    };
                }
            }
        }
    }
    assert(hit_count > RAY_COUNT && triangle_hits > 0);
}

fn void test_refresh_advances_revision_only_on_change() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* first = add_box(&fixture, { 0, 0, -3 });
    add_box(&fixture, { 0, 0, -6 });
    fixture.scene.update_world();
    SceneIndex index = spatial::create_scene_index(mem, 4);
    defer spatial::destroy_scene_index(&index);

    index.refresh(&fixture.assets, &fixture.scene)!!;
    assert(index.revision == 1 && index.count == 2);
    index.refresh(&fixture.assets, &fixture.scene)!!;
    assert(index.revision == 1);

    first.local.position = { 1, 0, -3 };
    fixture.scene.update_world();
    index.refresh(&fixture.assets, &fixture.scene)!!;
    assert(index.revision == 2);

    first.visible = false;
    fixture.scene.update_world();
    index.refresh(&fixture.assets, &fixture.scene)!!;
    assert(index.revision == 3 && index.count == 1);
    index.refresh(&fixture.assets, &fixture.scene)!!;
    assert(index.revision == 3);
}

fn void test_refresh_faults_past_capacity() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    for (uint mesh_index = 0; mesh_index < 5; mesh_index++) add_box(&fixture, { 0, 0, -3 - 3 * (float)mesh_index });
    fixture.scene.update_world();
    SceneIndex index = spatial::create_scene_index(mem, 4);
    defer spatial::destroy_scene_index(&index);

    if (catch excuse = index.refresh(&fixture.assets, &fixture.scene)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(index.count == 0 && index.revision > 0);
    @pool() {
        Ray ray = { .origin = { 0, 0, 0 }, .direction = { 0, 0, -1 } };
        assert(index.pick(tmem, &fixture.assets, ray).len == 0);
    };

    Scene billboard_scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&billboard_scene);
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    MaterialId material = fixture.assets.add_material(material::basic(common: common))!!;
    Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    Node* batch = billboard_scene.add_billboards(material, 2, values[:1])!!;
    billboard_scene.update_world();
    SceneIndex small = spatial::create_scene_index(mem, 1);
    defer spatial::destroy_scene_index(&small);
    small.refresh(&fixture.assets, &billboard_scene)!!;
    assert(small.count == 1);
    billboard_scene.set_billboards(batch, values[..])!!;
    if (catch excuse = small.refresh(&fixture.assets, &billboard_scene)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(small.count == 0);
    SceneIndex sufficient = spatial::create_scene_index(mem, 2);
    defer spatial::destroy_scene_index(&sufficient);
    sufficient.refresh(&fixture.assets, &billboard_scene)!!;
    assert(sufficient.count == 2);
}

fn void test_pick_builds_the_tree_once_per_revision() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* first = add_box(&fixture, { 0, 0, -3 });
    add_box(&fixture, { 0, 0, -6 });
    fixture.scene.update_world();
    SceneIndex index = spatial::create_scene_index(mem, 4);
    defer spatial::destroy_scene_index(&index);
    index.refresh(&fixture.assets, &fixture.scene)!!;
    Ray ray = { .origin = { 0, 0, 0 }, .direction = { 0, 0, -1 } };

    @pool() {
        assert(index.pick(tmem, &fixture.assets, ray).len == 2);
        assert(index.tree_revision == index.revision);
        BvhNode* nodes = index.tree.nodes.ptr;
        usz node_count = index.tree.nodes.len;
        assert(index.pick(tmem, &fixture.assets, ray).len == 2);
        assert(index.tree.nodes.ptr == nodes && index.tree.nodes.len == node_count);

        first.local.position = { 0, 5, -3 };
        fixture.scene.update_world();
        index.refresh(&fixture.assets, &fixture.scene)!!;
        assert(index.tree_revision != index.revision);
        assert(index.pick(tmem, &fixture.assets, ray).len == 1);
        assert(index.tree_revision == index.revision);
    };
}

fn void test_entries_follow_resize_and_removal() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Node* removed = add_box(&fixture, { 0, 0, -3 });
    Node* kept = add_box(&fixture, { 0, 0, -6 });
    Transform[3] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    Node* batch = scene.add_instanced_mesh(fixture.box, fixture.two_sided, 5, transforms[..])!!;
    scene.update_world();
    SceneIndex index = spatial::create_scene_index(mem, 8);
    defer spatial::destroy_scene_index(&index);
    index.refresh(&fixture.assets, scene)!!;
    assert(index.count == 5);

    scene.resize_instances(batch, 5)!!;
    index.refresh(&fixture.assets, scene)!!;
    assert(index.count == 7);
    uint next_instance;
    foreach (entry : index.entries[:index.count]) {
        if (entry.flags.instanced) {
            assert(entry.node == batch && entry.instance_index == next_instance);
            next_instance++;
        }
    }
    assert(next_instance == 5);

    scene.remove_later(removed);
    scene.flush_removals();
    index.refresh(&fixture.assets, scene)!!;
    assert(index.count == 6);
    assert(has_entry_for(&index, kept) && has_entry_for(&index, batch));
    foreach (entry : index.entries[:index.count]) assert(scene.world.is_alive(entry.node.id));
}

fn void test_prepare_triangle_picks_builds_each_static_geometry_once() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    add_box(&fixture, { 0, 0, -3 });
    add_box(&fixture, { 0, 0, -6 });
    Node* skinned = add_skinned_box(&fixture, { 0, 5, 0 });
    scene.add_mesh(fixture.released, fixture.one_sided)!!;
    fixture.assets.release_geometry_cpu(fixture.released);
    GeometryId malformed;
    GeometryId hidden_geometry;
    @pool() {
        Geometry broken = geometry::box(tmem, 1, 1, 1);
        broken.indices[5] = (uint)broken.positions.len;
        malformed = fixture.assets.add_geometry(&broken, "malformed")!!;
        Geometry box = geometry::box(tmem, 2, 2, 2);
        hidden_geometry = fixture.assets.add_geometry(&box, "hidden")!!;
    };
    scene.add_mesh(malformed, fixture.one_sided)!!;
    Node* hidden = scene.add_mesh(hidden_geometry, fixture.one_sided)!!;
    hidden.visible = false;
    scene.update_world();

    spatial::prepare_triangle_picks(&fixture.assets, scene);
    GeometryAsset* shared = fixture.assets.geometry(fixture.box);
    GeometryAsset* hidden_record = fixture.assets.geometry(hidden_geometry);
    GeometryAsset* skinned_record = fixture.assets.geometry(scene.get(skinned, Mesh).geometry);
    assert(shared.triangle_revision == shared.header.revision);
    assert(hidden_record.triangle_revision == hidden_record.header.revision);
    assert(skinned_record.triangle_revision == 0);
    assert(fixture.assets.geometry(fixture.released).triangle_revision == 0);
    GeometryAsset* malformed_record = fixture.assets.geometry(malformed);
    assert(malformed_record.rejected_revision == malformed_record.header.revision);
    assert(malformed_record.triangle_revision == 0);

    BvhNode* shared_nodes = shared.triangles.nodes.ptr;
    BvhNode* hidden_nodes = hidden_record.triangles.nodes.ptr;
    spatial::prepare_triangle_picks(&fixture.assets, scene);
    assert(shared.triangles.nodes.ptr == shared_nodes && hidden_record.triangles.nodes.ptr == hidden_nodes);
}

fn void assert_matches_fresh_refresh(SceneIndex* kept, Fixture* fixture) @local {
    kept.refresh(&fixture.assets, &fixture.scene)!!;
    SceneIndex fresh = spatial::create_scene_index(mem, (uint)kept.entries.len);
    defer spatial::destroy_scene_index(&fresh);
    fresh.refresh(&fixture.assets, &fixture.scene)!!;
    assert(kept.count == fresh.count);
    assert(mem::equals(kept.entries.ptr, fresh.entries.ptr, (sz)(fresh.count * SceneEntry::size)));
}

fn void test_batch_skip_matches_a_fresh_refresh() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Random random = { SEED };
    Node* leading = add_box(&fixture, { 0, 0, -3 });
    Node* first_batch;
    Node* second_batch;
    @pool() {
        first_batch = add_random_batch(&fixture, &random, 4);
        second_batch = add_random_batch(&fixture, &random, 6);
    };
    scene.resize_instances(first_batch, 3)!!;
    scene.update_world();
    SceneIndex kept = spatial::create_scene_index(mem, 16);
    defer spatial::destroy_scene_index(&kept);
    assert_matches_fresh_refresh(&kept, &fixture);
    uint revision = kept.revision;
    assert_matches_fresh_refresh(&kept, &fixture);
    assert(kept.revision == revision);

    first_batch.local.position += { 1, 0, 0 };
    scene.update_world();
    assert_matches_fresh_refresh(&kept, &fixture);

    InstancedMesh* second = scene.get(second_batch, InstancedMesh);
    second.transforms[2].position += { 0, 1, 0 };
    scene.mark_instances_dirty(second_batch);
    assert_matches_fresh_refresh(&kept, &fixture);

    scene.resize_instances(first_batch, 4)!!;
    assert_matches_fresh_refresh(&kept, &fixture);

    GeometryAsset* record = fixture.assets.geometry(fixture.box);
    record.data.bounds.max.y += 1;
    fixture.assets.mark_geometry_dirty(fixture.box);
    assert_matches_fresh_refresh(&kept, &fixture);

    second.has_bounds_override = true;
    second.local_bounds = { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } };
    assert_matches_fresh_refresh(&kept, &fixture);

    leading.visible = false;
    scene.update_world();
    assert_matches_fresh_refresh(&kept, &fixture);
    leading.visible = true;
    scene.update_world();
    assert_matches_fresh_refresh(&kept, &fixture);
}

fn Node* add_level(Fixture* fixture, Scene* scene) @local {
    Node* box = scene.add_mesh(fixture.box, fixture.one_sided)!!;
    box.local.position = { 0, 0, -3 };
    Transform[3] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    transforms[1].position = { 2, 0, 0 };
    transforms[2].position = { 4, 0, 0 };
    Node* batch = scene.add_instanced_mesh(fixture.box, fixture.two_sided, 3, transforms[..])!!;
    scene.update_world();
    return batch;
}

fn void test_refresh_with_another_scene_keeps_no_batch_entries() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene second = scene::create_scene(mem, { .max_nodes = 16 });
    defer scene::destroy_scene(&second);
    add_level(&fixture, &fixture.scene);
    Node* second_batch = add_level(&fixture, &second);

    SceneIndex kept = spatial::create_scene_index(mem, 8);
    defer spatial::destroy_scene_index(&kept);
    kept.refresh(&fixture.assets, &fixture.scene)!!;
    kept.refresh(&fixture.assets, &second)!!;
    foreach (entry : kept.entries[:kept.count]) {
        if (entry.flags.instanced) assert(entry.node == second_batch);
    }

    SceneIndex fresh = spatial::create_scene_index(mem, 8);
    defer spatial::destroy_scene_index(&fresh);
    fresh.refresh(&fixture.assets, &second)!!;
    assert(kept.count == fresh.count);
    assert(mem::equals(kept.entries.ptr, fresh.entries.ptr, (sz)(fresh.count * SceneEntry::size)));
}
