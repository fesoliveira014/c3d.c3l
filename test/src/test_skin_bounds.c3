module c3d::test::skin_bounds;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::spatial;
import std::math;

const uint NODE_CAPACITY @local = 16;
const float EPSILON @local = 0.0005f;
const Vec3 JOINT_OFFSET @local = { 10, 0, 0 };

struct Fixture @local {
    AssetStore assets;
    Scene scene;
    MaterialId material;
}

struct Rig @local {
    Node* mesh;
    Node*[] joints;
    SkeletonId skeleton;
}

fn Fixture make_fixture() @local {
    Fixture fixture = {
        .assets = asset::create_asset_store(mem, {
            .max_geometries = 4,
            .max_textures   = asset::BUILTIN_TEXTURE_COUNT,
            .max_materials  = 2,
            .max_samplers   = asset::BUILTIN_SAMPLER_COUNT,
            .max_skeletons  = 4,
        }),
        .scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY }),
    };
    fixture.material = fixture.assets.add_material(material::basic({ .color = { 1, 0, 0, 1 } }))!!;
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Geometry two_joint_box(Allocator allocator, bool blended = false, uint targets = 0) @local {
    Geometry box = geometry::box(allocator, 1, 1, 1);
    box.joints = alloc::new_array(allocator, ushort[<4>], box.positions.len);
    box.weights = alloc::new_array(allocator, Vec4, box.positions.len);
    foreach (index, position : box.positions) {
        box.joints[index] = { position.x < 0 ? 0 : 1, 0, 0, 0 };
        box.weights[index] = { 1, 0, 0, 0 };
        if (blended && position.x > 0) {
            box.joints[index] = { 0, 1, 0, 0 };
            box.weights[index] = { 0.5f, 0.5f, 0, 0 };
        }
    }
    if (targets) {
        box.targets = alloc::new_array(allocator, MorphTarget, targets);
        foreach (target, &shape : box.targets) {
            *shape = {
                .position_deltas = alloc::new_array(allocator, Vec3, box.positions.len),
                .normal_deltas   = alloc::new_array(allocator, Vec3, box.positions.len),
            };
            foreach (&delta : shape.position_deltas) *delta = { 0, (float)(target + 1), 0 };
        }
    }
    return box;
}

fn SkeletonId add_skeleton(Fixture* fixture, Mat4[] inverse_bind) @local {
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(mem, String, inverse_bind.len),
        .parents      = alloc::new_array(mem, int, inverse_bind.len),
        .rest_pose    = alloc::new_array(mem, Transform, inverse_bind.len),
        .inverse_bind = alloc::new_array(mem, Mat4, inverse_bind.len),
    };
    foreach (index, matrix : inverse_bind) {
        skeleton.parents[index] = -1;
        skeleton.rest_pose[index] = maths::TRANSFORM_IDENTITY;
        skeleton.inverse_bind[index] = matrix;
    }
    return fixture.assets.add_skeleton_owned(&skeleton)!!;
}

fn Rig add_rig(Fixture* fixture, GeometryId geometry, Mat4[] inverse_bind, float[] morph_weights = {}) @local {
    Rig rig = { .skeleton = add_skeleton(fixture, inverse_bind) };
    rig.joints = alloc::new_array(fixture.scene.allocator, Node*, inverse_bind.len);
    foreach (index, &joint : rig.joints) *joint = fixture.scene.add_node(name: "joint")!!;
    rig.mesh = fixture.scene.add_mesh(geometry, fixture.material, name: "skinned")!!;
    if (morph_weights.len) {
        Mesh* mesh = fixture.scene.get(rig.mesh, Mesh);
        mesh.morph_weights = alloc::new_array(fixture.scene.allocator, float, morph_weights.len);
        mesh.morph_weights[..] = morph_weights[..];
    }
    fixture.scene.add(rig.mesh, (SkinBinding){ .skeleton = rig.skeleton, .joints = rig.joints });
    return rig;
}

fn Aabb world_bounds(Fixture* fixture, Rig* rig) @local {
    fixture.scene.update_world();
    return spatial::mesh_world_bounds(
        assets: &fixture.assets,
        node:   rig.mesh,
        mesh:   fixture.scene.get(rig.mesh, Mesh),
        skin:   fixture.scene.get(rig.mesh, SkinBinding),
    );
}

fn Aabb deformed_bounds(Fixture* fixture, Rig* rig, Geometry* geometry, Mat4[] inverse_bind) @local {
    float[] morph_weights = fixture.scene.get(rig.mesh, Mesh).morph_weights;
    MorphSelection selection = geometry::select_morph_targets(geometry.channels, morph_weights);
    Aabb bounds;
    foreach (vertex, position : geometry.positions) {
        Vec3 local = position;
        for (uint active = 0; active < selection.count; active++) {
            local += geometry.targets[selection.targets[active]].position_deltas[vertex] * selection.weights[active];
        }
        Vec3 world;
        for (usz slot = 0; slot < 4; slot++) {
            float weight = geometry.weights[vertex][slot];
            if (weight <= 0) continue;
            uint joint = geometry.joints[vertex][slot];
            Mat4 palette = rig.joints[joint].world.mul(inverse_bind[joint]);
            world += maths::transform_point(palette, local) * weight;
        }
        bounds = vertex == 0 ? (Aabb){ .min = world, .max = world }
          : (Aabb){ .min = math::min(bounds.min, world), .max = math::max(bounds.max, world) };
    }
    return bounds;
}

fn bool contains(Aabb outer, Aabb inner) @local {
    return outer.min.x <= inner.min.x + EPSILON && outer.min.y <= inner.min.y + EPSILON
        && outer.min.z <= inner.min.z + EPSILON && outer.max.x + EPSILON >= inner.max.x
        && outer.max.y + EPSILON >= inner.max.y && outer.max.z + EPSILON >= inner.max.z;
}

fn bool nearly(float value, float expected) @local {
    return math::abs(value - expected) < EPSILON;
}

fn void test_offset_joint_bounds_contain_deformed_vertices_tightly() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Geometry box = two_joint_box(mem);
    GeometryId geometry = fixture.assets.add_geometry_owned(&box)!!;
    Mat4[2] inverse_bind = { matrix::IDENTITY4, matrix::IDENTITY4 };
    Rig rig = add_rig(&fixture, geometry, inverse_bind[..]);
    rig.joints[1].local.position = JOINT_OFFSET;

    Aabb bounds = world_bounds(&fixture, &rig);
    Aabb expected = deformed_bounds(&fixture, &rig, &box, inverse_bind[..]);
    assert(contains(bounds, expected));
    assert(nearly(bounds.min.x, -0.5f) && nearly(bounds.max.x, 10.5f));
    assert(nearly(bounds.min.y, -0.5f) && nearly(bounds.max.y, 0.5f));
}

fn void test_nonuniform_joint_scale_bounds_contain_deformed_vertices() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Geometry box = two_joint_box(mem);
    GeometryId geometry = fixture.assets.add_geometry_owned(&box)!!;
    Mat4[2] inverse_bind = { matrix::IDENTITY4, matrix::IDENTITY4 };
    Rig rig = add_rig(&fixture, geometry, inverse_bind[..]);
    rig.joints[1].local.scale = { 2, 1, 0.5f };
    rig.joints[1].local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::deg_to_rad(30.0f));

    Aabb bounds = world_bounds(&fixture, &rig);
    Aabb expected = deformed_bounds(&fixture, &rig, &box, inverse_bind[..]);
    assert(contains(bounds, expected));
    assert(bounds.max.x < 1.5f && bounds.max.x > 0.9f);
}

fn void test_blended_influences_stay_inside_the_merged_bound() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Geometry box = two_joint_box(mem, blended: true);
    GeometryId geometry = fixture.assets.add_geometry_owned(&box)!!;
    Mat4[2] inverse_bind = { matrix::IDENTITY4, matrix::IDENTITY4 };
    Rig rig = add_rig(&fixture, geometry, inverse_bind[..]);
    rig.joints[1].local.position = JOINT_OFFSET;

    Aabb bounds = world_bounds(&fixture, &rig);
    Aabb expected = deformed_bounds(&fixture, &rig, &box, inverse_bind[..]);
    assert(contains(bounds, expected));
    assert(nearly(expected.max.x, 5.5f));
}

fn void test_unused_joints_do_not_widen_the_bound() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Geometry box = two_joint_box(mem);
    GeometryId geometry = fixture.assets.add_geometry_owned(&box)!!;
    Mat4[3] inverse_bind = { matrix::IDENTITY4, matrix::IDENTITY4, matrix::IDENTITY4 };
    Rig rig = add_rig(&fixture, geometry, inverse_bind[..]);
    rig.joints[2].local.position = { 0, 100, 0 };

    Aabb bounds = world_bounds(&fixture, &rig);
    assert(nearly(bounds.max.y, 0.5f) && nearly(bounds.min.y, -0.5f));
    assert(fixture.assets.geometry(geometry).skin_bounds.joints.len == 2);
}

fn void test_morph_weights_widen_the_bound_with_their_sign() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Geometry box = two_joint_box(mem, targets: 1);
    GeometryId geometry = fixture.assets.add_geometry_owned(&box)!!;
    Mat4[2] inverse_bind = { matrix::IDENTITY4, matrix::IDENTITY4 };
    float[1] raised = { 0.5f };
    Rig rig = add_rig(&fixture, geometry, inverse_bind[..], raised[..]);

    Aabb bounds = world_bounds(&fixture, &rig);
    assert(contains(bounds, deformed_bounds(&fixture, &rig, &box, inverse_bind[..])));
    assert(nearly(bounds.max.y, 1.0f) && nearly(bounds.min.y, 0.0f));

    fixture.scene.get(rig.mesh, Mesh).morph_weights[0] = -0.5f;
    bounds = world_bounds(&fixture, &rig);
    assert(contains(bounds, deformed_bounds(&fixture, &rig, &box, inverse_bind[..])));
    assert(nearly(bounds.max.y, 0.0f) && nearly(bounds.min.y, -1.0f));
}

fn void test_channel_weights_select_the_same_targets_as_the_deformation() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    GeometryId geometry;
    @pool() {
        Geometry box = two_joint_box(tmem, targets: 2);
        float[2] keys = { 0.5f, 1 };
        box.channels = alloc::new_array(tmem, MorphChannel, 1);
        box.channels[0] = { .name = "rise", .first_target = 0, .full_weights = keys[..] };
        geometry = fixture.assets.add_geometry(&box)!!;
    };
    Mat4[2] inverse_bind = { matrix::IDENTITY4, matrix::IDENTITY4 };
    float[1] channel_weight = { 0.75f };
    Rig rig = add_rig(&fixture, geometry, inverse_bind[..], channel_weight[..]);

    Aabb bounds = world_bounds(&fixture, &rig);
    Geometry* stored = &fixture.assets.geometry(geometry).data;
    Aabb expected = deformed_bounds(&fixture, &rig, stored, inverse_bind[..]);
    assert(contains(bounds, expected));
    assert(bounds.max.y > 1.0f && nearly(bounds.max.y, expected.max.y));
}

fn void test_two_bindings_share_geometry_with_different_inverse_binds() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Geometry box = two_joint_box(mem);
    GeometryId geometry = fixture.assets.add_geometry_owned(&box)!!;
    Mat4[2] identity = { matrix::IDENTITY4, matrix::IDENTITY4 };
    Mat4 shifted = matrix::IDENTITY4.translate({ -10, 0, 0 });
    Mat4[2] offset = { shifted, shifted };
    Rig first = add_rig(&fixture, geometry, identity[..]);
    Rig second = add_rig(&fixture, geometry, offset[..]);

    Aabb first_bounds = world_bounds(&fixture, &first);
    Aabb second_bounds = world_bounds(&fixture, &second);
    assert(contains(first_bounds, deformed_bounds(&fixture, &first, &box, identity[..])));
    assert(contains(second_bounds, deformed_bounds(&fixture, &second, &box, offset[..])));
    assert(nearly(first_bounds.min.x, -0.5f) && nearly(second_bounds.min.x, -10.5f));
}

fn void test_skin_bounds_survive_release_and_refresh_on_dirty() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    GeometryId geometry;
    @pool() {
        Geometry box = two_joint_box(tmem);
        geometry = fixture.assets.add_geometry(&box)!!;
    };
    Mat4[2] inverse_bind = { matrix::IDENTITY4, matrix::IDENTITY4 };
    Rig rig = add_rig(&fixture, geometry, inverse_bind[..]);
    Aabb before = world_bounds(&fixture, &rig);

    GeometryAsset* record = fixture.assets.geometry(geometry);
    foreach (&position : record.data.positions) *position = *position * 2;
    fixture.assets.mark_geometry_dirty(geometry);
    Aabb grown = world_bounds(&fixture, &rig);
    assert(nearly(grown.max.x, 1.0f) && nearly(before.max.x, 0.5f));

    fixture.assets.release_geometry_cpu(geometry);
    assert(record.data.positions.len == 0 && record.skin_bounds.joints.len == 2);
    Aabb released = world_bounds(&fixture, &rig);
    assert(nearly(released.max.x, grown.max.x) && nearly(released.min.z, grown.min.z));
}

fn void test_bounds_override_precedes_skin_bounds() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    Geometry box = two_joint_box(mem);
    GeometryId geometry = fixture.assets.add_geometry_owned(&box)!!;
    Mat4[2] inverse_bind = { matrix::IDENTITY4, matrix::IDENTITY4 };
    Rig rig = add_rig(&fixture, geometry, inverse_bind[..]);
    rig.joints[1].local.position = JOINT_OFFSET;
    Mesh* mesh = fixture.scene.get(rig.mesh, Mesh);
    mesh.has_bounds_override = true;
    mesh.local_bounds = { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } };

    Aabb bounds = world_bounds(&fixture, &rig);
    assert(nearly(bounds.max.x, 2) && nearly(bounds.min.x, -2));
}

fn void test_add_geometry_rejects_malformed_influences() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    @pool() {
        Geometry short_joints = two_joint_box(tmem);
        short_joints.joints = short_joints.joints[:2];
        if (catch excuse = fixture.assets.add_geometry(&short_joints)) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "a joint stream shorter than the positions was accepted");
        }
        Geometry negative = two_joint_box(tmem);
        negative.weights[0] = { -0.5f, 1.5f, 0, 0 };
        if (catch excuse = fixture.assets.add_geometry(&negative)) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "a negative weight was accepted");
        }
    };
}
