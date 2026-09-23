module c3d::test::scene_trace;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const gpu::GpuAddress BLOCK_BASE @local = (gpu::GpuAddress)0x10000;

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    GeometryId box;
    MaterialId opaque;
    MaterialId blended;
    MaterialId masked;
}

fn Fixture make_fixture() @local {
    Fixture fixture;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 4,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 3,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
        .max_skeletons  = 1,
    });
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        fixture.box = fixture.assets.add_geometry(&box, "box")!!;
    };
    fixture.opaque = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }), "opaque")!!;
    MaterialCommon blend = material::MATERIAL_COMMON_DEFAULT;
    blend.alpha_mode = AlphaMode.BLEND;
    fixture.blended = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 0.5f } }, blend), "blended")!!;
    MaterialCommon mask = material::MATERIAL_COMMON_DEFAULT;
    mask.alpha_mode = AlphaMode.MASK;
    fixture.masked = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }, mask), "masked")!!;
    fixture.scene = scene::create_scene(mem, { .max_nodes = 32 });
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_skinned_box(Fixture* fixture) @local {
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
    GeometryId skinned_box;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        box.joints = alloc::new_array(tmem, ushort[<4>], box.positions.len);
        box.weights = alloc::new_array(tmem, Vec4, box.positions.len);
        foreach (&weight : box.weights) *weight = { 1, 0, 0, 0 };
        skinned_box = fixture.assets.add_geometry(&box, "skinned_box")!!;
    };
    Node* joint = fixture.scene.add_node(name: "joint")!!;
    Node* skinned = fixture.scene.add_mesh(skinned_box, fixture.opaque, name: "skinned")!!;
    Node*[] joints = alloc::new_array(fixture.scene.allocator, Node*, 1);
    joints[0] = joint;
    fixture.scene.add(skinned, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
    return skinned;
}

fn Node* add_morphed_box(Fixture* fixture) @local {
    GeometryId morphed;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        box.targets = alloc::new_array(tmem, MorphTarget, 1);
        box.targets[0] = {
            .position_deltas = alloc::new_array(tmem, Vec3, box.positions.len),
            .normal_deltas   = alloc::new_array(tmem, Vec3, box.positions.len),
        };
        morphed = fixture.assets.add_geometry(&box, "morphed_box")!!;
    };
    return fixture.scene.add_mesh(morphed, fixture.opaque, name: "morphed")!!;
}

fn bool same_entity(Entity first, Entity second) @local {
    return first.index == second.index && first.generation == second.generation;
}

fn render::TraceInstance[] collect(Fixture* fixture) @local {
    uint dangling;
    render::TraceInstance[] records = render::collect_trace_instances(tmem, &fixture.scene, &fixture.assets, &dangling);
    assert(dangling == 0);
    return records;
}

fn void test_trace_instances_follow_eligibility() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Node* plain = scene.add_mesh(fixture.box, fixture.opaque, name: "plain")!!;
    Node* hidden = scene.add_mesh(fixture.box, fixture.opaque, name: "hidden")!!;
    hidden.visible = false;
    Node* untraced = scene.add_mesh(fixture.box, fixture.opaque, name: "untraced")!!;
    scene.get(untraced, Mesh).trace = false;
    scene.add_mesh(fixture.box, fixture.blended, name: "blended")!!;
    add_skinned_box(&fixture);
    add_morphed_box(&fixture);
    Node* overridden = scene.add_mesh(fixture.box, fixture.opaque, name: "overridden")!!;
    Mesh* override_mesh = scene.get(overridden, Mesh);
    override_mesh.has_bounds_override = true;
    override_mesh.local_bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    Node* masked = scene.add_mesh(fixture.box, fixture.masked, name: "masked")!!;
    Transform[3] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    foreach (index, &transform : transforms) transform.position = { (float)index + 1, 0, 0 };
    Node* batch = scene.add_instanced_mesh(fixture.box, fixture.opaque, 5, transforms[..], name: "batch")!!;
    batch.local.position = { 0, 4, 0 };
    scene.update_world();

    @pool() {
        render::TraceInstance[] records = collect(&fixture);
        assert(records.len == 5);
        assert(same_entity(records[0].entity, plain.id) && records[0].flags == 0);
        assert(same_entity(records[1].entity, masked.id));
        assert(records[1].flags == shader::TRACE_INSTANCE_ALPHA_MASK);
        foreach (index, transform : transforms) {
            render::TraceInstance* record = &records[2 + index];
            assert(same_entity(record.entity, batch.id));
            assert(record.world == batch.world.mul(transform.to_mat4()));
        }
    };
}

fn void test_trace_collection_changes_with_the_scene() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Node* moved = scene.add_mesh(fixture.box, fixture.opaque, name: "moved")!!;
    Node* removed = scene.add_mesh(fixture.box, fixture.opaque, name: "removed")!!;
    removed.local.position = { 3, 0, 0 };
    scene.update_world();

    @pool() {
        render::TraceInstance[] first = collect(&fixture);
        render::TraceInstance[] second = collect(&fixture);
        assert(first.len == 2 && second.len == 2);
        assert(mem::equals(first.ptr, second.ptr, (sz)(first.len * render::TraceInstance::size)));

        moved.local.position = { 0, 2, 0 };
        scene.update_world();
        render::TraceInstance[] after_move = collect(&fixture);
        assert(after_move[0].world != first[0].world && after_move[1].world == first[1].world);

        scene.remove(removed);
        render::TraceInstance[] after_remove = collect(&fixture);
        assert(after_remove.len == 1);

        fixture.assets.material(fixture.opaque).data.common.alpha_mode = AlphaMode.MASK;
        fixture.assets.mark_material_dirty(fixture.opaque);
        render::TraceInstance[] after_mask = collect(&fixture);
        assert(after_mask[0].flags == shader::TRACE_INSTANCE_ALPHA_MASK);
    };
}

fn void test_geometry_root_carries_the_index_address() @test {
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        render::GeometryLayout layout = render::geometry_layout(&box);
        char[] block = alloc::new_array(tmem, char, (sz)layout.total_bytes);
        render::write_geometry_block(
            block:    block,
            geometry: &box,
            layout:   &layout,
            base:     BLOCK_BASE,
        );
        shader::GeometryRoot* root = (shader::GeometryRoot*)block.ptr;
        assert(root.indices == BLOCK_BASE + (gpu::GpuAddress)layout.indices && layout.flags.indices_u16);

        Geometry wide = {
            .topology  = Topology.TRIANGLES,
            .positions = alloc::new_array(tmem, Vec3, 70000),
            .indices   = alloc::new_array(tmem, uint, 3),
        };
        render::GeometryLayout wide_layout = render::geometry_layout(&wide);
        char[] wide_block = alloc::new_array(tmem, char, (sz)wide_layout.total_bytes);
        render::write_geometry_block(
            block:    wide_block,
            geometry: &wide,
            layout:   &wide_layout,
            base:     BLOCK_BASE,
        );
        root = (shader::GeometryRoot*)wide_block.ptr;
        assert(!wide_layout.flags.indices_u16 && root.indices == BLOCK_BASE + (gpu::GpuAddress)wide_layout.indices);

        Geometry odd = {
            .topology  = Topology.TRIANGLES,
            .positions = alloc::new_array(tmem, Vec3, 3),
            .indices   = alloc::new_array(tmem, uint, 3),
        };
        render::GeometryLayout odd_layout = render::geometry_layout(&odd);
        assert(odd_layout.flags.indices_u16 && odd_layout.total_bytes % uint::size == 0);

        Geometry list = { .topology = Topology.TRIANGLES, .positions = alloc::new_array(tmem, Vec3, 3) };
        render::GeometryLayout list_layout = render::geometry_layout(&list);
        char[] list_block = alloc::new_array(tmem, char, (sz)list_layout.total_bytes);
        render::write_geometry_block(
            block:    list_block,
            geometry: &list,
            layout:   &list_layout,
            base:     BLOCK_BASE,
        );
        root = (shader::GeometryRoot*)list_block.ptr;
        assert(root.indices == (gpu::GpuAddress)0);
    };
}
