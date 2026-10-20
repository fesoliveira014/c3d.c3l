module c3d::test::billboards;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import std::math;

const float TOLERANCE @local = 1e-5f;

fn bool near_vector(Vec3 first, Vec3 second) @local {
    return (first - second).length() <= TOLERANCE;
}

fn void test_billboard_edits_copy_and_preserve_state_on_failure() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    values[0].position = { 2, 3, 4 };
    Node* node = scene.add_billboards(material: {}, capacity: 2, billboards: values[..])!!;
    BillboardBatch* batch = scene.get(node, BillboardBatch);
    values[0].position = { 9, 9, 9 };
    assert(batch.billboards[0].position == (Vec3){ 2, 3, 4 });
    uint revision = batch.revision;
    values[1].size.x = -1;
    assert(@catch(scene.set_billboards(node, values[..])) == c3d::INVALID_ARGUMENT);
    assert(batch.revision == revision && batch.count == 2);
    assert(batch.billboards[0].position == (Vec3){ 2, 3, 4 });
    values[1] = scene::BILLBOARD_DEFAULT;
    values[1].rotation = bitcast(0x7fc00000u, float);
    assert(@catch(scene.set_billboards(node, values[..])) == c3d::INVALID_ARGUMENT);
    assert(@catch(scene.resize_billboards(node, 3)) == c3d::CAPACITY_EXCEEDED);
    assert(batch.revision == revision && batch.count == 2);
    scene.resize_billboards(node, 1)!!;
    scene.resize_billboards(node, 2)!!;
    assert(batch.billboards[1].size == (Vec2){ 1, 1 });
    assert(batch.billboards[1].color == (Vec4){ 1, 1, 1, 1 });
}

fn void test_invalid_billboard_creation_leaves_node_capacity_available() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    values[0].size.y = -1;
    assert(@catch(scene.add_billboards(material: {}, capacity: 1, billboards: values[..]))
        == c3d::INVALID_ARGUMENT);
    Node* node = scene.add_node()!!;
    assert(scene.world.is_alive(node.id));
}

fn void test_billboard_atlas_rejects_bad_layouts() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    BillboardAtlas grid = { .columns = 2, .rows = 2, .frame_count = 4, .inset = { 0.01f, 0.02f } };
    Node* node = scene.add_billboards(material: {}, capacity: 1, atlas: grid)!!;
    BillboardBatch* batch = scene.get(node, BillboardBatch);
    uint revision = batch.revision;

    BillboardAtlas bad = grid;
    bad.frame_count = 5;
    assert(@catch(scene.set_billboard_atlas(node, bad)) == c3d::INVALID_ARGUMENT);
    bad = grid;
    bad.inset.x = 0.25f;
    assert(@catch(scene.set_billboard_atlas(node, bad)) == c3d::INVALID_ARGUMENT);
    assert(batch.revision == revision && batch.atlas.frame_count == 4 && batch.atlas.inset.x == 0.01f);

    grid.frame_count = 3;
    scene.set_billboard_atlas(node, grid)!!;
    assert(batch.revision != revision && batch.atlas.frame_count == 3);
}

fn void test_billboard_bounds_cover_scaled_rotated_quads() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    Billboard[1] values = { scene::BILLBOARD_DEFAULT };
    values[0].position = { 1, 0, 0 };
    values[0].size = { 2, 2 };
    values[0].rotation = 0.7f;
    Node* node = scene.add_billboards(material: {}, capacity: 1, billboards: values[..])!!;
    node.local.position = { 3, 4, 5 };
    node.local.scale = { 2, 3, 4 };
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2);
    scene.update_world();
    Aabb bounds = spatial::billboard_world_bounds(node, scene.get(node, BillboardBatch));
    float radius = math::sqrt(13.0f);
    Vec3 extent = { radius, radius, radius };
    assert(near_vector(bounds.min, (Vec3){ 3, 4, 3 } - extent));
    assert(near_vector(bounds.max, (Vec3){ 3, 4, 3 } + extent));
}

fn void test_billboard_world_child_keeps_visibility_and_frees_storage() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Scene scene = scene::create_scene(&tracker, { .max_nodes = 3 });
        defer scene::destroy_scene(&scene);
        Node* parent = scene.add_node()!!;
        parent.local.position = { 10, 2, -3 };
        Billboard[1] values = { scene::BILLBOARD_DEFAULT };
        values[0].position = { 1, 2, 3 };
        Node* child = scene.add_billboards(
            material: {},
            capacity: 32,
            billboards: values[..],
            parent: parent,
        )!!;
        child.transform_space = TransformSpace.WORLD;
        parent.visible = false;
        scene.update_world();
        assert(!child.visible_effective);
        BillboardGpu[1] records;
        render::pack_billboard_records(records[..], child.world, scene.get(child, BillboardBatch));
        assert(records[0].position_width == (Vec4){ 1, 2, 3, 1 });
        Entity child_id = child.id;
        sz before = tracker.allocated();
        scene.remove(parent);
        assert(!scene.world.is_alive(child_id));
        assert(before - tracker.allocated() >= 32 * Billboard::size);
    }
    assert(!tracker.has_leaks());
}

fn void test_billboard_packing_keeps_indices_and_handles_zero_dimensions() @test {
    Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    values[0].position = { 2, 0, -1 };
    values[0].size = {};
    values[0].direction = {};
    values[1].position = { -3, 0, -2 };
    values[1].size = { 2, 4 };
    values[1].direction = { 0, 2, 0 };
    values[1].rotation = 0.7f;
    values[1].frame = 2.5f;
    BillboardBatch batch = { .billboards = values[..], .count = 2, .facing = BillboardFacing.DIRECTIONAL };
    BillboardGpu[2] records;
    render::pack_billboard_records(records[..], matrix::IDENTITY4, &batch);
    assert(records[0].position_width == (Vec4){ 2, 0, -1, 0 });
    assert(records[0].direction_height == (Vec4){});
    assert(records[1].position_width == (Vec4){ -3, 0, -2, 2 });
    assert(records[1].direction_height == (Vec4){ 0, 1, 0, 4 });
    assert(records[1].rotation == 0.7f);
    assert(records[0].frame == 0 && records[1].frame == 2.5f && records[1]._pad1 == 0);
}

fn void test_billboard_array_updates_allocate_nothing() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        Scene scene = scene::create_scene(&tracker, { .max_nodes = 1 });
        defer scene::destroy_scene(&scene);
        Node* node = scene.add_billboards({}, 8)!!;
        Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
        sz before = tracker.total_allocation_count();
        for (uint frame = 0; frame < 32; frame++) {
            values[0].position.x = (float)frame;
            scene.set_billboards(node, values[..])!!;
        }
        assert(tracker.total_allocation_count() == before);
    }
    assert(!tracker.has_leaks());
}

fn void test_billboard_index_and_linear_pick_preserve_source_identity() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    MaterialId material_id = assets.add_material(material::basic(common: common))!!;
    Billboard[2] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    values[0].position = { -2, 0, 0 };
    values[1].position = { 2, 0, 0 };
    Node* node = scene.add_billboards(material: material_id, capacity: 2, billboards: values[..])!!;
    scene.update_world();
    SceneIndex index = spatial::create_scene_index(mem, 2);
    defer spatial::destroy_scene_index(&index);
    SceneIndex small = spatial::create_scene_index(mem, 1);
    defer spatial::destroy_scene_index(&small);
    assert(@catch(small.refresh(&assets, &scene)) == c3d::CAPACITY_EXCEEDED);
    assert(small.count == 0);
    index.refresh(&assets, &scene)!!;
    Ray ray = { .origin = { 2, 0, 3 }, .direction = { 0, 0, -1 } };
    PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
    options.precision = PickPrecision.TRIANGLES;
    @pool() {
        PickHit[] linear = spatial::pick(
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
        assert(linear.len == 1 && indexed.len == 1);
        assert(linear[0].node == node && indexed[0].node == node);
        assert(linear[0].instance_index == 1 && indexed[0].instance_index == 1);
        assert(linear[0].billboard && indexed[0].billboard);
        assert(!linear[0].triangle_hit && !indexed[0].triangle_hit);
        assert(math::abs(linear[0].distance - indexed[0].distance) < TOLERANCE);
    };
    node.visible = false;
    scene.update_world();
    index.refresh(&assets, &scene)!!;
    @pool() { assert(index.pick(tmem, &assets, ray).len == 0); };
}

fn void test_record_batch_copies_records_relative_to_frame_origin() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    Node* node = scene.add_billboards(
        material: {},
        capacity: 4,
        source: BillboardSource.RECORDS,
    )!!;
    BillboardBatch* batch = scene.get(node, BillboardBatch);
    batch.records[0] = {
        .position_width = { 300, 5, -500, 2 },
        .direction_height = { 0, 1, 0, 4 },
        .color = { 0.1f, 0.2f, 0.3f, 0.4f },
        .rotation = 0.7f,
        .facing = 1,
        .frame = 2.5f,
    };
    batch.records[1] = {
        .position_width = { -8, 0, 30, 0.5f },
        .direction_height = { 1, 0, 0, 1.5f },
        .color = { 1, 0.5f, 0.25f, 1 },
        .rotation = -0.3f,
        .facing = 1,
        .frame = 0,
    };
    batch.count = 2;
    BillboardGpu[2] copied;
    render::copy_billboard_records(copied[..], batch, { 256, 0, -512 });
    assert(copied[0].position_width == (Vec4){ 44, 5, 12, 2 });
    assert(copied[1].position_width == (Vec4){ -264, 0, 542, 0.5f });
    sz tail = (sz)(BillboardGpu::size - Vec4::size);
    assert(mem::equals(&copied[0].direction_height, &batch.records[0].direction_height, tail));
    assert(mem::equals(&copied[1].direction_height, &batch.records[1].direction_height, tail));
}

fn void test_record_batch_bounds_index_and_pick_read_records() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    MaterialId material_id = assets.add_material(material::basic(common: common))!!;
    Billboard[3] values = { scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT, scene::BILLBOARD_DEFAULT };
    values[0].position = { -4, 0, 0 };
    values[1].position = { 0, 1, 0 };
    values[1].size = { 2, 2 };
    values[1].direction = { 0, 2, 0 };
    values[2].position = { 4, 0, 0 };
    values[2].size = { 3, 3 };
    Node* billboards = scene.add_billboards(material: material_id, capacity: 3, billboards: values[..])!!;
    Node* records = scene.add_billboards(
        material: material_id,
        capacity: 3,
        source: BillboardSource.RECORDS,
    )!!;
    BillboardBatch* source = scene.get(billboards, BillboardBatch);
    BillboardBatch* packed = scene.get(records, BillboardBatch);
    BillboardGpu[3] converted;
    render::pack_billboard_records(converted[..], matrix::IDENTITY4, source);
    foreach (index, &record : packed.records) *record = *(BillboardRecord*)&converted[index];
    packed.count = 3;
    scene.update_world();

    Aabb expected = spatial::billboard_world_bounds(billboards, source);
    Aabb actual = spatial::billboard_world_bounds(records, packed);
    assert(near_vector(expected.min, actual.min) && near_vector(expected.max, actual.max));

    SceneIndex index = spatial::create_scene_index(mem, 6);
    defer spatial::destroy_scene_index(&index);
    index.refresh(&assets, &scene)!!;
    assert(index.count == 6);
    for (uint instance = 0; instance < 3; instance++) {
        Aabb first = index.entries[instance].bounds;
        Aabb second = index.entries[3 + instance].bounds;
        assert(index.entries[instance].node == billboards && index.entries[3 + instance].node == records);
        assert(near_vector(first.min, second.min) && near_vector(first.max, second.max));
    }

    Ray ray = { .origin = { 0, 1, 3 }, .direction = { 0, 0, -1 } };
    @pool() {
        PickHit[] hits = index.pick(allocator: tmem, assets: &assets, ray: ray);
        PickHit[] linear = spatial::pick(
            allocator: tmem,
            assets: &assets,
            scene: &scene,
            ray: ray,
        );
        assert(hits.len == 2 && linear.len == 2);
        foreach (hit : hits) assert(hit.instance_index == 1 && hit.billboard);
        foreach (hit : linear) assert(hit.instance_index == 1 && hit.billboard);
        assert(hits[0].node != hits[1].node && linear[0].node != linear[1].node);
    };
}
