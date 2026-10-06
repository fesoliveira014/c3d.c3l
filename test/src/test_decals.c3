module c3d::test::decals;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::render;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const float TOLERANCE @local = 0.00002f;
const Vec3 FRAME_ORIGIN @local = { 1048576, -2097152, 4194304 };

struct DecalFixture @local {
    AssetStore assets;
    Scene      scene;
    MaterialId standard;
    MaterialId basic;
}

fn DecalFixture make_fixture() @local {
    DecalFixture fixture = {
        .assets = asset::create_asset_store(mem, {
            .max_geometries = 1,
            .max_materials = 2,
            .max_textures = asset::BUILTIN_TEXTURE_COUNT,
            .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        }),
        .scene = scene::create_scene(mem, { .max_nodes = 16 }),
    };
    fixture.standard = fixture.assets.add_material(material::standard())!!;
    fixture.basic = fixture.assets.add_material(material::basic())!!;
    return fixture;
}

fn void destroy_fixture(DecalFixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Vec3 unpack_local(DecalGpu* decal, Vec3 point) @local {
    Vec4 homogeneous = { point.x, point.y, point.z, 1 };
    return {
        decal.world_to_local_0.dot(homogeneous),
        decal.world_to_local_1.dot(homogeneous),
        decal.world_to_local_2.dot(homogeneous),
    };
}

fn Vec3 unpack_world(DecalGpu* decal, Vec3 point) @local {
    Vec4 homogeneous = { point.x, point.y, point.z, 1 };
    return {
        decal.local_to_world_0.dot(homogeneous),
        decal.local_to_world_1.dot(homogeneous),
        decal.local_to_world_2.dot(homogeneous),
    };
}

fn Vec3 corner_of(uint index) @local {
    return {
        index & 1 ? 0.5f : -0.5f,
        index & 2 ? 0.5f : -0.5f,
        index & 4 ? 0.5f : -0.5f,
    };
}

fn void test_decal_extraction_filters_culls_and_counts() @test {
    DecalFixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    DecalDesc desc = scene::default_decal_desc(fixture.standard);
    Node* eligible = fixture.scene.add_decal(desc)!!;
    Node* hidden_parent = fixture.scene.add_node()!!;
    hidden_parent.visible = false;
    fixture.scene.add_decal(desc, hidden_parent)!!;
    Node* off_layer = fixture.scene.add_decal(desc)!!;
    off_layer.layers = 2;
    Node* no_layers = fixture.scene.add_decal(desc)!!;
    no_layers.layers = 0;
    Node* no_receivers = fixture.scene.add_decal(desc)!!;
    fixture.scene.get(no_receivers, Decal).receiver_layers = 0;
    Node* outside = fixture.scene.add_decal(desc)!!;
    outside.local.position = { 10, 0, 0 };
    fixture.scene.add_decal(scene::default_decal_desc(fixture.basic))!!;
    fixture.scene.add_decal(scene::default_decal_desc({ .index = 1, .generation = 99 }))!!;
    fixture.scene.update_world();
    Frustum frustum = {
        .planes = {
            { .normal = { 1, 0, 0 }, .d = 2 }, { .normal = { -1, 0, 0 }, .d = 2 },
            { .normal = { 0, 1, 0 }, .d = 2 }, { .normal = { 0, -1, 0 }, .d = 2 },
            { .normal = { 0, 0, 1 }, .d = 2 }, { .normal = { 0, 0, -1 }, .d = 2 },
        },
        .plane_count = 6,
    };
    @pool() {
        DecalCounts counts;
        DecalCandidate[] candidates = render::extract_decals(
            allocator: tmem,
            scene: &fixture.scene,
            assets: &fixture.assets,
            frustum: &frustum,
            view_layers: 1,
            capacity: 8,
            counts: &counts,
        );
        assert(candidates.len == 1 && candidates[0].node == eligible);
        assert(counts.packed == 1 && counts.culled == 1 && counts.dangling == 2 && counts.dropped == 0);
        eligible.local.position = FRAME_ORIGIN;
        fixture.scene.update_world();
        candidates = render::extract_decals(
            allocator: tmem,
            scene: &fixture.scene,
            assets: &fixture.assets,
            frustum: &frustum,
            view_layers: 1,
            capacity: 8,
            counts: &counts,
            origin: FRAME_ORIGIN,
        );
        assert(candidates.len == 1 && candidates[0].node == eligible && counts.packed == 1);
    };
}

fn void test_decal_extraction_skips_collapsed_and_nonfinite_inverses() @test {
    DecalFixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Node* node = fixture.scene.add_decal(scene::default_decal_desc(fixture.standard))!!;
    fixture.scene.update_world();
    Mat4[4] invalid_worlds = { matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4 };
    invalid_worlds[0].m00 = 0;
    invalid_worlds[1].m00 = bitcast(0x7fc00000u, float);
    invalid_worlds[2].m03 = bitcast(0x7f800000u, float);
    invalid_worlds[3].m00 = 1e-20f;
    invalid_worlds[3].m03 = 1e30f;
    @pool() {
        foreach (world : invalid_worlds) {
            node.world = world;
            DecalCounts counts;
            DecalCandidate[] candidates = render::extract_decals(
                allocator: tmem,
                scene: &fixture.scene,
                assets: &fixture.assets,
                frustum: null,
                view_layers: 1,
                capacity: 8,
                counts: &counts,
            );
            assert(candidates.len == 0 && counts.packed == 0 && counts.dropped == 0);
        }
    };
}

fn void test_decal_budget_keeps_lowest_order_then_entity() @test {
    DecalFixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    int[5] orders = { int::max, int::min, 1, 1, 2 };
    Node*[5] nodes;
    foreach (index, order : orders) {
        DecalDesc desc = scene::default_decal_desc(fixture.standard);
        desc.decal.order = order;
        nodes[index] = fixture.scene.add_decal(desc)!!;
    }
    fixture.scene.update_world();
    @pool() {
        DecalCounts counts;
        DecalCandidate[] candidates = render::extract_decals(
            allocator: tmem,
            scene: &fixture.scene,
            assets: &fixture.assets,
            frustum: null,
            view_layers: 1,
            capacity: 3,
            counts: &counts,
        );
        assert(candidates.len == 3 && counts.packed == 3 && counts.dropped == 2);
        assert(candidates[0].node == nodes[1] && candidates[1].node == nodes[2] && candidates[2].node == nodes[3]);
        Node previous = *nodes[2];
        fixture.scene.remove(nodes[2]);
        DecalDesc desc = scene::default_decal_desc(fixture.standard);
        desc.decal.order = 1;
        Node* replacement = fixture.scene.add_decal(desc)!!;
        fixture.scene.update_world();
        candidates = render::extract_decals(
            allocator: tmem,
            scene: &fixture.scene,
            assets: &fixture.assets,
            frustum: null,
            view_layers: 1,
            capacity: 3,
            counts: &counts,
        );
        assert(candidates.len == 3 && candidates[0].node == nodes[1] && counts.dropped == 2);
        assert(candidates[1].node.id.index < candidates[2].node.id.index);
        assert(previous.id.index == replacement.id.index && previous.id.generation < replacement.id.generation);
        DecalCandidate old = { .node = &previous, .decal = &desc.decal };
        DecalCandidate current = { .node = replacement, .decal = &desc.decal };
        assert(render::compare_decal_candidates(old, current) < 0);
        assert(render::compare_decal_candidates(current, old) > 0);
    };
}

fn void test_decal_packing_preserves_affine_corners_and_frame_origin() @test {
    Transform parent = {
        .position = { 3, -2, 1 },
        .rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.4f),
        .scale = { 2, 1, 0.5f },
    };
    Transform child = {
        .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, 0.6f),
        .scale = { 1, 0.75f, 1.5f },
    };
    Mat4 relative = parent.to_mat4().mul(child.to_mat4());
    Node node = { .world = relative };
    node.world.m03 += FRAME_ORIGIN.x;
    node.world.m13 += FRAME_ORIGIN.y;
    node.world.m23 += FRAME_ORIGIN.z;
    Decal decal = {
        .weights = { .base_color = 0.1f, .normal = 0.2f, .roughness = 0.3f, .metallic = 0.4f },
        .fade_angle = (float)math::PI / 4,
        .receiver_layers = 0x12,
    };
    DecalGpu packed = render::pack_decal(
        node: &node,
        decal: &decal,
        material: (gpu::GpuAddress)16384,
        origin: FRAME_ORIGIN,
    );
    Vec3 world_x = maths::transform_dir(relative, { 1, 0, 0 });
    Vec3 world_z = maths::transform_dir(relative, { 0, 0, 1 });
    assert(math::abs(world_x.normalize().dot(world_z.normalize())) > 0.1f);
    assert((packed.projection_fade.xyz - world_z.normalize()).length() < TOLERANCE);
    assert(packed.material == (gpu::GpuAddress)16384 && packed.receiver_layers == decal.receiver_layers);
    assert(packed.weights == (Vec4){ 0.1f, 0.2f, 0.3f, 0.4f });
    Aabb bounds = maths::aabb_transform(render::DECAL_LOCAL_BOUNDS, relative);
    for (uint index = 0; index < 8; index++) {
        Vec3 local = corner_of(index);
        Vec3 world = maths::transform_point(relative, local);
        assert((unpack_world(&packed, local) - world).length() < TOLERANCE);
        assert((unpack_local(&packed, world) - local).length() < TOLERANCE);
        for (uint axis = 0; axis < 3; axis++) {
            assert(world[axis] >= bounds.min[axis] - TOLERANCE && world[axis] <= bounds.max[axis] + TOLERANCE);
        }
    }
    assert(unpack_local(&packed, maths::translation(relative)).length() < TOLERANCE);
    Vec3 outside = maths::transform_point(relative, { 0.501f, 0, 0 });
    assert(unpack_local(&packed, outside).x > 0.5f);
}

fn void test_decal_normal_frame_follows_projected_uv_and_reflection() @test {
    Transform[4] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY,
        maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    transforms[1].rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, 0.7f);
    transforms[2] = transforms[1];
    transforms[2].scale = { 2, 3, 0.5f };
    transforms[3] = transforms[2];
    transforms[3].scale.x = -2;
    Decal decal = scene::default_decal_desc({}).decal;
    foreach (index, transform : transforms) {
        Node node = { .world = transform.to_mat4() };
        DecalGpu packed = render::pack_decal(&node, &decal, (gpu::GpuAddress)0);
        Vec3 increasing_u = maths::transform_dir(node.world, { 1, 0, 0 }).normalize();
        Vec3 increasing_v = maths::transform_dir(node.world, { 0, -1, 0 }).normalize();
        Vec3 normal = maths::transform_dir(node.world, { 0, 0, 1 }).normalize();
        assert((packed.tangent.xyz - increasing_u).length() < TOLERANCE);
        assert((normal.cross(packed.tangent.xyz) * packed.tangent.w - increasing_v).length() < TOLERANCE);
        assert(packed.tangent.w == (index == 3 ? 1 : -1));
    }
    foreach (float scale : { 1e20f, 1e-30f }) {
        foreach (uint axis : { 0u, 2u }) {
            Transform transform = maths::TRANSFORM_IDENTITY;
            transform.scale[axis] = scale;
            Node node = { .world = transform.to_mat4() };
            DecalGpu packed = render::pack_decal(&node, &decal, (gpu::GpuAddress)0);
            assert(packed.tangent.xyz == (Vec3){ 1, 0, 0 });
            assert(packed.projection_fade.xyz == (Vec3){ 0, 0, 1 });
        }
    }
}

fn void test_decal_angle_weight_covers_narrow_fades_switch_and_step() @test {
    Node node = { .world = matrix::IDENTITY4 };
    Decal decal = scene::default_decal_desc({}).decal;
    float[6] angles = { 0, 1, 10, 25.84f, 45, 90 };
    foreach (degrees : angles) {
        decal.fade_angle = degrees * (float)math::PI / 180;
        DecalGpu packed = render::pack_decal(&node, &decal, (gpu::GpuAddress)0);
        float cosine = packed.fade_cosine;
        float inverse_band = packed.projection_fade.w;
        assert(math::abs(render::decal_angle_weight(1, cosine, inverse_band) - 1) <= 0.000001f);
        if (degrees == 0) {
            assert(cosine == 1 && inverse_band == 0);
            assert(render::decal_angle_weight(0.999999f, cosine, inverse_band) == 0);
            continue;
        }
        assert(render::decal_angle_weight(cosine, cosine, inverse_band) == 0);
        assert(render::decal_angle_weight(cosine - 0.1f, cosine, inverse_band) == 0);
        float band = math::min(shader::DECAL_FADE_BAND, 1 - cosine);
        float middle = render::decal_angle_weight(cosine + band * 0.5f, cosine, inverse_band);
        assert(math::abs(middle - 0.5f) < 0.0005f);
        float previous;
        for (uint sample = 0; sample <= 32; sample++) {
            float facing = cosine + (1 - cosine) * (float)sample / 32;
            float weight = render::decal_angle_weight(facing, cosine, inverse_band);
            assert(weight >= previous && weight <= 1);
            previous = weight;
        }
    }
    // Adjacent cosine inputs isolate continuity from finite angular variation and cosine rounding.
    float wide_cosine = 1.0f - shader::DECAL_FADE_BAND;
    float narrow_cosine = bitcast(bitcast(wide_cosine, uint) + 1u, float);
    float narrow_band = 1.0f - narrow_cosine;
    assert(narrow_band < shader::DECAL_FADE_BAND && 1.0f - wide_cosine >= shader::DECAL_FADE_BAND);
    float before = render::decal_angle_weight(0.95f, narrow_cosine, 1.0f / narrow_band);
    float after = render::decal_angle_weight(0.95f, wide_cosine, 1.0f / shader::DECAL_FADE_BAND);
    assert(math::abs(before - after) <= 0.000001f);
}

fn void test_decal_plane_culling_matches_transformed_corner_extrema() @test {
    Node node = {
        .world = {
            .m00 = 2, .m01 = 0.5f, .m02 = 0.25f, .m03 = 1,
            .m10 = 0, .m11 = 1, .m12 = 0.5f, .m13 = -2,
            .m20 = 0, .m21 = 0, .m22 = -0.5f, .m23 = -5,
            .m30 = 0, .m31 = 0, .m32 = 0, .m33 = 1,
        },
    };
    Decal decal = scene::default_decal_desc({}).decal;
    DecalGpu packed = render::pack_decal(&node, &decal, (gpu::GpuAddress)0);
    Vec3[4] normals = { { 1, 0, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 1, 2, -3 } };
    foreach (direction : normals) {
        Vec3 normal = direction.normalize();
        float maximum = -math::FLOAT_MAX;
        for (uint index = 0; index < 8; index++) {
            Vec3 world = maths::transform_point(node.world, corner_of(index));
            maximum = math::max(maximum, normal.dot(world));
        }
        Plane[1] planes = { { .normal = normal, .d = -maximum + 0.0001f } };
        assert(render::decal_intersects_planes(&packed, planes[..]));
        planes[0].d = -maximum - 0.0001f;
        assert(!render::decal_intersects_planes(&packed, planes[..]));
    }
}

fn void test_add_decal_scales_node_and_rejects_partial_add() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);

    MaterialId material = { .index = 7, .generation = 3 };
    DecalDesc desc = scene::default_decal_desc(material);
    assert(desc.size == (Vec3){ 1, 1, 1 });
    desc.size = { 2, 1, 0.5f };
    Node* node = scene.add_decal(desc)!!;
    assert(node.local.scale == desc.size);
    Decal* decal = scene.get(node, Decal);
    assert(decal != null);
    assert(c3d::same_id(decal.material, material));
    assert(decal.weights.base_color == 1 && decal.weights.normal == 1);
    assert(decal.weights.roughness == 1 && decal.weights.metallic == 1);
    assert(math::abs(decal.fade_angle - (float)math::PI * 4 / 9) < 1e-6f);
    assert(decal.receiver_layers == uint::max && decal.order == 0);

    if (catch excuse = scene.add_decal(desc)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full scene added a decal");
    }
    assert(scene.count(Decal) == 1);
    assert(scene.root.first_child == node && node.next_sibling == null);

    desc.size.x = 0;
    reject_decal_without_mutation(&scene, desc);
}

fn void test_invalid_decal_descriptions_preserve_scene() @test {
    Scene scene = scene::create_scene(mem, { .max_nodes = 2 });
    defer scene::destroy_scene(&scene);
    scene.add_node()!!;
    DecalDesc valid = scene::default_decal_desc((MaterialId){});

    float[4] bad_sizes = { 0, -1, float::inf, float::nan };
    for (uint axis = 0; axis < 3; axis++) {
        foreach (float size : bad_sizes) {
            DecalDesc desc = valid;
            desc.size[axis] = size;
            reject_decal_without_mutation(&scene, desc);
        }
    }

    float[4] bad_weights = { -0.01f, 1.01f, float::inf, float::nan };
    for (uint channel = 0; channel < 4; channel++) {
        foreach (float weight : bad_weights) {
            DecalDesc desc = valid;
            switch (channel) {
                case 0: desc.decal.weights.base_color = weight;
                case 1: desc.decal.weights.normal = weight;
                case 2: desc.decal.weights.roughness = weight;
                case 3: desc.decal.weights.metallic = weight;
            }
            reject_decal_without_mutation(&scene, desc);
        }
    }

    float[4] bad_angles = { -0.01f, (float)math::PI / 2 + 0.01f, float::inf, float::nan };
    foreach (float angle : bad_angles) {
        DecalDesc desc = valid;
        desc.decal.fade_angle = angle;
        reject_decal_without_mutation(&scene, desc);
    }

    valid.decal.weights = { .base_color = 0, .normal = 1, .roughness = 0, .metallic = 1 };
    valid.decal.fade_angle = 0;
    Node* node = scene.add_decal(valid)!!;
    scene.remove(node);
    valid.decal.fade_angle = (float)math::PI / 2;
    scene.add_decal(valid)!!;
    assert(scene.count(Decal) == 1);
}

fn void reject_decal_without_mutation(Scene* scene, DecalDesc desc) @local {
    Node* first_child = scene.root.first_child;
    uint free_count = scene.world.entities.free_count;
    uint decal_count = scene.count(Decal);
    if (catch excuse = scene.add_decal(desc)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        unreachable("expected an invalid decal description fault");
    }
    assert(scene.root.first_child == first_child);
    assert(scene.world.entities.free_count == free_count);
    assert(scene.count(Decal) == decal_count);
}
