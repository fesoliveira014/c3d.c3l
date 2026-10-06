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
const uint CURRENT_REVISION @local = 3;

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
        .max_geometries = 6,
        .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials  = 8,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
        .max_skeletons  = 2,
        .max_shaders    = 2,
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
    SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton)!!;
    GeometryId skinned_box;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        box.joints = alloc::new_array(tmem, ushort[<4>], box.positions.len);
        box.weights = alloc::new_array(tmem, Vec4, box.positions.len);
        foreach (&weight : box.weights) *weight = { 1, 0, 0, 0 };
        skinned_box = fixture.assets.add_geometry(&box)!!;
    };
    Node* joint = fixture.scene.add_node(name: "joint")!!;
    Node* skinned = fixture.scene.add_mesh(skinned_box, fixture.opaque, name: "skinned")!!;
    Node*[] joints = alloc::new_array(fixture.scene.allocator, Node*, 1);
    joints[0] = joint;
    fixture.scene.add(skinned, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
    return skinned;
}

fn Node* add_morphed_box(Fixture* fixture, float[] weights = {}) @local {
    GeometryId morphed;
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        box.targets = alloc::new_array(tmem, MorphTarget, 1);
        box.targets[0] = {
            .position_deltas = alloc::new_array(tmem, Vec3, box.positions.len),
            .normal_deltas   = alloc::new_array(tmem, Vec3, box.positions.len),
        };
        morphed = fixture.assets.add_geometry(&box)!!;
    };
    Node* node = fixture.scene.add_mesh(morphed, fixture.opaque, name: "morphed")!!;
    Mesh* mesh = fixture.scene.get(node, Mesh);
    mesh.morph_weights = alloc::new_array(fixture.scene.allocator, float, weights.len);
    mesh.morph_weights[..] = weights[..];
    return node;
}

fn bool same_entity(Entity first, Entity second) @local {
    return first.index == second.index && first.generation == second.generation;
}

fn render::TraceCollection collect_all(Fixture* fixture) @local {
    render::TraceCollection collection = render::collect_trace_instances(tmem, &fixture.scene, &fixture.assets);
    assert(collection.dangling == 0);
    return collection;
}

fn render::TraceInstance[] collect(Fixture* fixture) @local => collect_all(fixture).records;

fn ShaderId add_custom_shader(Fixture* fixture, bool vertex_stage) @local {
    char[4] stage = { 1, 2, 3, 4 };
    asset::ShaderDesc desc = { .fragment = stage[..] };
    if (vertex_stage) desc.vertex = { .shaded = stage[..], .depth = stage[..] };
    return fixture.assets.add_shader(&desc)!!;
}

fn Aabb rest_bounds(Fixture* fixture, render::TraceInstance* record) @local {
    Aabb local = fixture.assets.geometry(record.geometry).data.bounds;
    return maths::aabb_transform(local, render::trace_instance_world(record));
}

fn bool same_box(Aabb first, Aabb second) @local => first.min == second.min && first.max == second.max;

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
    Node* skinned = add_skinned_box(&fixture);
    Node* morphed = add_morphed_box(&fixture);
    Node* masked = scene.add_mesh(fixture.box, fixture.masked, name: "masked")!!;
    Transform[3] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    foreach (index, &transform : transforms) transform.position = { (float)index + 1, 0, 0 };
    Node* batch = scene.add_instanced_mesh(fixture.box, fixture.opaque, 5, transforms[..], name: "batch")!!;
    batch.local.position = { 0, 4, 0 };
    scene.update_world();

    @pool() {
        render::TraceCollection collection = collect_all(&fixture);
        render::TraceInstance[] records = collection.records;
        assert(records.len == 7);
        assert(same_entity(records[0].entity, plain.id) && records[0].flags == 0);
        assert(same_entity(records[1].entity, skinned.id) && collection.poses[1].kind == render::TracePose.MESH);
        assert(same_entity(records[2].entity, morphed.id) && collection.poses[2].kind == render::TracePose.REST);
        assert(same_entity(records[3].entity, masked.id));
        assert(records[3].flags == shader::TRACE_INSTANCE_ALPHA_MASK);
        foreach (index, transform : transforms) {
            render::TraceInstance* record = &records[4 + index];
            assert(same_entity(record.entity, batch.id) && collection.poses[4 + index].kind == render::TracePose.REST);
            assert(render::trace_instance_world(record) == batch.world.mul(transform.to_mat4()));
            assert(same_box(record.bounds, rest_bounds(&fixture, record)) && record.pose_serial == 0);
        }
    };
}

fn void test_deformed_meshes_collect_posed_only_away_from_rest() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Node* skinned = add_skinned_box(&fixture);
    Node* weighted = add_morphed_box(&fixture, { 0.5f });
    Node* zero = add_morphed_box(&fixture, { 0 });
    Node* unweighted = add_morphed_box(&fixture);
    Node* unbound = scene.add_mesh(scene.get(skinned, Mesh).geometry, fixture.opaque, name: "unbound")!!;
    Node* rigid = scene.add_mesh(fixture.box, fixture.opaque, name: "rigid")!!;
    Node* bound_morph = add_morphed_box(&fixture, { 0.5f });
    SkinBinding* binding = scene.get(skinned, SkinBinding);
    foreach (target : (Node*[2]){ rigid, bound_morph }) {
        Node*[] joints = alloc::new_array(scene.allocator, Node*, 1);
        joints[0] = binding.joints[0];
        scene.add(target, (SkinBinding){ .skeleton = binding.skeleton, .joints = joints });
    }
    scene.update_world();

    @pool() {
        render::TraceCollection collection = collect_all(&fixture);
        assert(collection.records.len == 7);
        render::TracePose[7] expected = { MESH, MESH, REST, REST, REST, REST, MESH };
        Node*[7] nodes = { skinned, weighted, zero, unweighted, unbound, rigid, bound_morph };
        foreach (index, pose : expected) {
            assert(same_entity(collection.records[index].entity, nodes[index].id));
            assert(collection.poses[index].kind == pose && collection.poses[index].node == nodes[index]);
        }
        assert(collection.poses[0].skin == scene.get(skinned, SkinBinding));
        assert(collection.poses[1].skin == null && collection.poses[1].mesh == scene.get(weighted, Mesh));
        assert(collection.poses[5].skin == null && collection.poses[6].skin == null);
    };
}

fn void test_custom_vertex_stage_keeps_meshes_out_whatever_trace_says() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    MaterialId displaced = fixture.assets.add_material(material::custom(add_custom_shader(&fixture, true)))!!;
    MaterialId shaded = fixture.assets.add_material(material::custom(add_custom_shader(&fixture, false)))!!;
    Node* traced = scene.add_mesh(fixture.box, displaced, name: "traced")!!;
    scene.get(traced, Mesh).trace = true;
    Node* water = scene.add_mesh(fixture.box, displaced, name: "water")!!;
    Mesh* water_mesh = scene.get(water, Mesh);
    water_mesh.has_bounds_override = true;
    water_mesh.local_bounds = { .min = { -2, -1, -2 }, .max = { 2, 1, 2 } };
    Node* fragment_only = scene.add_mesh(fixture.box, shaded, name: "fragment_only")!!;
    Transform[2] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    scene.add_instanced_mesh(
        geometry: fixture.box,
        material: displaced,
        capacity: 2,
        transforms: transforms[..],
        name: "displaced_batch",
    )!!;
    scene.update_world();

    @pool() {
        render::TraceInstance[] records = collect(&fixture);
        assert(records.len == 1 && same_entity(records[0].entity, fragment_only.id));
    };
}

fn void test_bounds_override_bounds_without_excluding() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Node* still = scene.add_mesh(fixture.box, fixture.opaque, name: "still")!!;
    still.local.position = { 3, 0, 0 };
    Mesh* still_mesh = scene.get(still, Mesh);
    still_mesh.has_bounds_override = true;
    still_mesh.local_bounds = { .min = { -3, -3, -3 }, .max = { 3, 3, 3 } };
    Node* skinned = add_skinned_box(&fixture);
    Mesh* skinned_mesh = scene.get(skinned, Mesh);
    skinned_mesh.has_bounds_override = true;
    skinned_mesh.local_bounds = { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } };
    scene.update_world();

    @pool() {
        render::TraceCollection collection = collect_all(&fixture);
        assert(collection.records.len == 2);
        assert(collection.poses[0].kind == render::TracePose.REST);
        assert(same_box(collection.records[0].bounds, rest_bounds(&fixture, &collection.records[0])));
        assert(collection.poses[1].kind == render::TracePose.MESH);
        Aabb widened = maths::aabb_transform(skinned_mesh.local_bounds, skinned.world);
        assert(same_box(collection.records[1].bounds, widened));
    };
}

fn void test_sway_traces_at_rest_and_is_counted() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Transform[2] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    transforms[1].position = { 2, 0, 0 };
    InstanceSway wind = { .direction = { 1, 0, 0 }, .amplitude = 0.2f, .frequency = 1 };
    Node* swaying = scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.opaque,
        capacity:   2,
        transforms: transforms[..],
        name:       "swaying",
    )!!;
    scene.get(swaying, InstancedMesh).sway = wind;
    scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.opaque,
        capacity:   2,
        transforms: transforms[..],
        name:       "still",
    )!!;
    Node* hidden = scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.opaque,
        capacity:   2,
        transforms: transforms[..],
        name:       "untraced",
    )!!;
    scene.get(hidden, InstancedMesh).sway = wind;
    scene.get(hidden, InstancedMesh).trace = false;
    scene.update_world();

    @pool() {
        render::TraceCollection collection = collect_all(&fixture);
        assert(collection.records.len == 4 && collection.sway_at_rest == 1);
        foreach (index, &record : collection.records) {
            assert(!same_entity(record.entity, hidden.id));
            assert(same_box(record.bounds, rest_bounds(&fixture, record)));
            assert(collection.poses[index].kind == render::TracePose.REST);
        }
    };
}

fn TraceInstance posed_row(uint index, ulong pose_serial = 0) @local {
    return {
        .entity      = { .index = index, .generation = 1 },
        .world       = matrix::IDENTITY4,
        .local       = matrix::IDENTITY4,
        .mask        = shader::TRACE_MASK_ALL,
        .pose_serial = pose_serial,
    };
}

fn bool reusable(
    render::SceneTrace* trace,
    render::RtContext* rt,
    TraceInstance[] records,
    Vec3 origin = {},
) @local {
    return render::top_level_reusable(
        trace:   trace,
        rt:      rt,
        records: records,
        scene:   9,
        origin:  origin,
    );
}

fn void test_top_level_reuse_needs_unchanged_rows() @test {
    TraceInstance[2] baseline = { posed_row(0), posed_row(1, 4) };
    render::SceneTrace trace = { .scene = 9, .baseline = baseline[..], .baseline_count = 2 };
    render::RtContext rt = { .current_holds_set = true };
    TraceInstance[2] records = baseline;
    assert(reusable(&trace, &rt, records[..]));
    assert(!reusable(&trace, &rt, records[..], origin: { 256, 0, 0 }));
    records[1].nodes = (gpu::GpuAddress)0x400;
    records[1].primitives = (gpu::GpuAddress)0x800;
    assert(reusable(&trace, &rt, records[..]));
    records[1].pose_serial = 5;
    assert(!reusable(&trace, &rt, records[..]));
    records[1].pose_serial = 4;
    records[1].bottom_level = { .owner = 1, .index = 2, .generation = 1 };
    assert(!reusable(&trace, &rt, records[..]));
    rt.current_holds_set = false;
    assert(!reusable(&trace, &rt, baseline[..]));
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

fn void test_blas_desc_follows_the_geometry_layout() @test {
    @pool() {
        Geometry box = geometry::box(tmem, 1, 1, 1);
        render::GeometryLayout layout = render::geometry_layout(&box);
        gpu::AccelerationStructureGeometryDesc desc = render::blas_geometry_desc(&layout);
        assert(desc.kind == gpu::AccelerationStructureGeometryKind.TRIANGLES && !desc.flags.opaque);
        assert(desc.triangles.max_vertex_count == 24 && desc.triangles.max_primitive_count == 12);
        assert(desc.triangles.index_type == gpu::AccelerationStructureIndexType.U16 && !desc.triangles.has_transform);

        Geometry wide = {
            .topology  = Topology.TRIANGLES,
            .positions = alloc::new_array(tmem, Vec3, 70002),
            .indices   = alloc::new_array(tmem, uint, 70002),
        };
        foreach (index, &value : wide.indices) *value = (uint)index;
        render::GeometryLayout wide_layout = render::geometry_layout(&wide);
        desc = render::blas_geometry_desc(&wide_layout);
        assert(desc.triangles.index_type == gpu::AccelerationStructureIndexType.U32);
        assert(desc.triangles.max_primitive_count == 23334 && desc.triangles.max_vertex_count == 70002);

        box.unindex(tmem);
        render::GeometryLayout list_layout = render::geometry_layout(&box);
        desc = render::blas_geometry_desc(&list_layout);
        assert(desc.triangles.index_type == gpu::AccelerationStructureIndexType.NONE);
        assert(desc.triangles.max_primitive_count == 12 && desc.triangles.max_vertex_count == 36);
    };
}

fn void test_tlas_instance_follows_the_row() @test {
    render::TraceInstance record = {
        .world        = matrix::IDENTITY4.translate({ 1, 2, 3 }).scale({ 2, 2, 2 }),
        .local        = matrix::IDENTITY4,
        .mask         = 3,
        .bottom_level = { .owner = 1, .index = 5, .generation = 1 },
    };
    gpu::AccelerationStructureInstanceDesc desc = render::tlas_instance_desc(&record, 7);
    assert(desc.custom_index == 7 && desc.mask == 3 && desc.bottom_level.index == 5);
    assert(!desc.flags.triangle_cull_disable && desc.flags.force_opaque && !desc.flags.force_non_opaque);
    assert(desc.transform_row_0 == (Vec4f){ 2, 0, 0, 1 });
    assert(desc.transform_row_1 == (Vec4f){ 0, 2, 0, 2 });
    assert(desc.transform_row_2 == (Vec4f){ 0, 0, 2, 3 });
    assert(!desc.flags.triangle_facing_flip);

    record.flags = shader::TRACE_INSTANCE_DOUBLE_SIDED;
    desc = render::tlas_instance_desc(&record, 7);
    assert(desc.flags.triangle_cull_disable && !desc.flags.triangle_facing_flip);

    record.flags = shader::TRACE_INSTANCE_ALPHA_MASK;
    record.mask = 1;
    desc = render::tlas_instance_desc(&record, 7);
    assert(!desc.flags.triangle_cull_disable && desc.flags.force_non_opaque && !desc.flags.force_opaque);
    assert(!desc.flags.triangle_facing_flip && desc.mask == 1);

    record.flags = 0;
    record.world = matrix::IDENTITY4.scale({ -1, 1, 1 });
    desc = render::tlas_instance_desc(&record, 7);
    assert(!desc.flags.triangle_cull_disable && !desc.flags.triangle_facing_flip);
}

fn void test_rt_shadow_flags_follow_ray_queries() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    uint software = shader::SHADER_FLAG_RT_SHADOWS | shader::SHADER_FLAG_SCENE_TRACE_BVH;
    assert(render::rt_shadow_flags(renderer, true) == software);
    assert(render::rt_shadow_flags(renderer, false) == 0);
    renderer.caps.ray_queries.enabled = true;
    assert(render::rt_shadow_flags(renderer, true) == shader::SHADER_FLAG_RT_SHADOWS);
    assert(render::rt_shadow_flags(renderer, false) == 0);
}

fn void test_trace_kind_resolves_against_ray_queries() @test {
    assert(render::resolve_trace_kind(TraceKind.AUTO, true)!! == TraceKind.HARDWARE);
    assert(render::resolve_trace_kind(TraceKind.AUTO, false)!! == TraceKind.SOFTWARE);
    assert(render::resolve_trace_kind(TraceKind.SOFTWARE, true)!! == TraceKind.SOFTWARE);
    assert(render::resolve_trace_kind(TraceKind.HARDWARE, true)!! == TraceKind.HARDWARE);
    if (catch excuse = render::resolve_trace_kind(TraceKind.HARDWARE, false)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false);
    }
}

fn void test_ray_cone_lod_follows_distance_density_and_obliquity() @test {
    float base = render::ray_cone_lod(1024, 1, 0.01f, 1);
    assert(math::abs(render::ray_cone_lod(1024, 1, 0.02f, 1) - (base + 1)) < 1e-5);
    assert(math::abs(render::ray_cone_lod(4096, 1, 0.01f, 1) - (base + 1)) < 1e-5);
    assert(math::abs(render::ray_cone_lod(1024, 4, 0.01f, 1) - (base - 1)) < 1e-5);
    assert(math::abs(render::ray_cone_lod(1024, 1, 0.01f, 0.5f) - (base + 1)) < 1e-5);
    assert(math::abs(render::ray_cone_lod(1, 1, 1, 1)) < 1e-5);
}

fn void test_trace_source_needs_arrays_or_a_level() @test {
    assert(render::trace_source(3, 3, false) == render::TraceSource.REUSE);
    assert(render::trace_source(0, 3, true) == render::TraceSource.BUILD);
    assert(render::trace_source(2, 3, false) == render::TraceSource.SKIP);
}

fn render::TraceSource hardware_source(uint built_revision, bool proven, bool streams) @local {
    return render::blas_source(
        built_revision: built_revision,
        revision:       CURRENT_REVISION,
        proven:         proven,
        streams:        streams,
    );
}

fn void test_blas_source_needs_a_proven_list_and_streams() @test {
    assert(hardware_source(CURRENT_REVISION, false, false) == render::TraceSource.REUSE);
    assert(hardware_source(0, true, true) == render::TraceSource.BUILD);
    assert(hardware_source(CURRENT_REVISION - 1, true, true) == render::TraceSource.BUILD);
    assert(hardware_source(CURRENT_REVISION - 1, true, false) == render::TraceSource.SKIP);
    assert(hardware_source(CURRENT_REVISION - 1, false, true) == render::TraceSource.SKIP);
    assert(hardware_source(0, false, false) == render::TraceSource.SKIP);
}

fn void test_trace_record_mask_follows_cast_shadow() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    Node* caster = scene.add_mesh(fixture.box, fixture.opaque, name: "caster")!!;
    Node* receiver = scene.add_mesh(fixture.box, fixture.opaque, name: "receiver")!!;
    scene.get(receiver, Mesh).cast_shadow = false;
    Transform[2] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    transforms[1].position = { 2, 0, 0 };
    Node* batch = scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   fixture.opaque,
        capacity:   2,
        transforms: transforms[..],
        name:       "batch",
    )!!;
    scene.get(batch, InstancedMesh).cast_shadow = false;
    scene.update_world();

    @pool() {
        render::TraceInstance[] records = collect(&fixture);
        assert(records.len == 4);
        assert(records[0].mask == (shader::TRACE_MASK_ALL | shader::TRACE_MASK_SHADOW_CASTER));
        foreach (record : records[1..]) assert(record.mask == shader::TRACE_MASK_ALL);

        scene.get(caster, Mesh).cast_shadow = false;
        render::TraceInstance[] toggled = collect(&fixture);
        assert(!mem::equals(&records[0], &toggled[0], (sz)render::TraceInstance::size));
    };
}

fn void test_trace_record_carries_the_instance_index() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Scene* scene = &fixture.scene;
    scene.add_mesh(fixture.box, fixture.opaque, name: "single")!!;
    Transform[3] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    transforms[1].position = { 2, 0, 0 };
    transforms[2].position = { 4, 0, 0 };
    scene.add_instanced_mesh(fixture.box, fixture.opaque, 3, transforms[..], name: "batch")!!;
    scene.update_world();

    @pool() {
        render::TraceInstance[] records = collect(&fixture);
        assert(records.len == 4);
        assert(records[0].instance_index == 0);
        foreach (uint index, record : records[1..]) assert(record.instance_index == index);
    };
}

fn void test_trace_collection_counts_invalid_material_references_as_dangling() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    char[4] fragment = { 1, 2, 3, 4 };
    asset::ShaderDesc desc = { .fragment = fragment[..] };
    ShaderId shader = fixture.assets.add_shader(&desc)!!;
    MaterialId layer = fixture.assets.add_material(material::standard())!!;
    MaterialId custom = fixture.assets.add_material(material::custom(shader, references: { [0] = layer }))!!;
    fixture.scene.add_mesh(fixture.box, custom, name: "layered")!!;
    fixture.scene.update_world();

    @pool() {
        assert(collect(&fixture).len == 1);
        fixture.assets.remove_material(layer);
        render::TraceCollection collection = render::collect_trace_instances(tmem, &fixture.scene, &fixture.assets);
        assert(collection.records.len == 0 && collection.dangling == 1);
    };
}
