module c3d::test::gltf;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import std::io::path;
import std::math;

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/gltf", name)!!;
}

fn AssetStore create_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures = 8,
        .max_materials = 8,
        .max_samplers = 8,
        .max_models = 2,
    });
}

fn void test_quad_converts_material_texture_and_transform() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("quad.gltf");
    ModelId model = gltf::load_model(&assets, path)!!;
    ModelTemplate* template = &assets.model(model).data;
    assert(template.nodes.len == 2 && template.meshes.len == 1);
    assert(template.nodes[0].parent == -1 && template.nodes[1].parent == 0);
    assert(template.nodes[0].local.position == (Vec3){ 1, 2, 3 });
    assert(template.meshes[0].node == 1);

    GeometryId geometry_id = assets.find_geometry(string::tformat("%s#mesh/0/0", path))!!;
    assert(geometry_id.index == template.meshes[0].geometry.index);
    Geometry* geometry = &assets.geometry(geometry_id).data;
    assert(geometry.positions.len == 4 && geometry.normals.len == 4 && geometry.uv0.len == 4);
    assert(geometry.indices.len == 6 && geometry.tangents.len == 0);
    assert(geometry.bounds.min == (Vec3){ -1, -1, 0 } && geometry.bounds.max == (Vec3){ 1, 1, 0 });

    MaterialId material_id = assets.find_material(string::tformat("%s#material/0", path))!!;
    Material* material = &assets.material(material_id).data;
    assert(material.kind == MaterialKind.STANDARD);
    assert(material.standard.base_color == (Vec4){ 0.5f, 0.25f, 0.125f, 1 });
    assert(material.standard.metallic == 0 && material.standard.roughness == 0.5f);
    TextureSlot slot = material.standard.base_color_map;
    assert(slot.uv_set == 0 && slot.transform.rotation == 0.25f);
    assert(slot.transform.offset == (Vec2){ 0.5f, 0 } && slot.transform.scale == (Vec2){ 2, 2 });

    TextureId texture_id = assets.find_texture(string::tformat("%s#image/0/srgb", path))!!;
    assert(slot.texture.kind == TextureRefKind.ASSET && slot.texture.asset.index == texture_id.index);
    TextureAsset* texture = assets.texture(texture_id);
    assert(texture.desc.width == 2 && texture.desc.height == 2 && texture.desc.format == RGBA8_SRGB);
    SamplerId sampler_id = assets.find_sampler(string::tformat("%s#sampler/0", path))!!;
    assert(slot.sampler.index == sampler_id.index);
    SamplerDesc sampler = assets.sampler(sampler_id).desc;
    assert(sampler.min_filter == Filter.NEAREST && sampler.mag_filter == Filter.NEAREST);
    assert(sampler.address_u == AddressMode.CLAMP_TO_EDGE && sampler.address_v == AddressMode.CLAMP_TO_EDGE);
}

fn void test_hierarchy_orders_parents_before_children_and_remaps() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = gltf::load_model(&assets, fixture_path("hierarchy.gltf"))!!;
    ModelTemplate* template = &assets.model(model).data;

    assert(template.nodes.len == 8);
    int[8] parents = { -1, 0, 1, 0, 3, 3, 3, -1 };
    foreach (index, node : template.nodes) {
        assert(node.parent == parents[index]);
        assert(node.parent < (int)index);
    }
    assert(template.nodes[0].name == "root_a" && template.nodes[1].name == "child_b");
    assert(template.nodes[4].name == "mesh_c/primitive/0" && template.nodes[5].name == "mesh_c/primitive/1");
    assert(template.nodes[6].name == "tag" && template.nodes[6].local.position == (Vec3){ 0, 0, 5 });
    assert(template.nodes[1].local.position == (Vec3){ 0, 1, 0 });
    assert(template.nodes[1].local.scale == (Vec3){ 2, 2, 2 });

    assert(template.meshes.len == 2 && template.meshes[0].node == 4 && template.meshes[1].node == 5);
    Material* unlit = &assets.material(template.meshes[0].material).data;
    Material* coated = &assets.material(template.meshes[1].material).data;
    assert(unlit.kind == MaterialKind.BASIC && unlit.basic.color == (Vec4){ 1, 0, 0, 1 });
    assert(coated.kind == MaterialKind.PHYSICAL && coated.physical.standard.metallic == 0.1f);
    assert(coated.physical.clearcoat == 0.75f && coated.physical.clearcoat_roughness == 0.2f);
    Geometry* first = &assets.geometry(template.meshes[0].geometry).data;
    assert(first.positions.len == 3 && first.normals.len == 3 && first.indices.len == 0);
    assert(first.normals[0] == (Vec3){ 0, 0, 1 });

    assert(template.cameras.len == 1 && template.cameras[0].node == 2);
    Camera camera = template.cameras[0].value;
    assert(camera.projection == Projection.PERSPECTIVE && camera.fov_y == 1);
    assert(camera.near == 0.1f && camera.far == 100 && camera.aspect == 1.5f);
    assert(template.lights.len == 1 && template.lights[0].node == 7);
    Light light = template.lights[0].value;
    assert(light.kind == LightKind.POINT && light.intensity == 5 && light.range == 10);
    assert(light.color == (Vec3){ 1, 0.5f, 0.25f });
}

fn void test_strip_becomes_triangle_list_with_normals() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = gltf::load_model(&assets, fixture_path("strip.gltf"))!!;
    ModelTemplate* template = &assets.model(model).data;
    Geometry* geometry = &assets.geometry(template.meshes[0].geometry).data;
    assert(geometry.topology == Topology.TRIANGLES);
    uint[6] expected = { 0, 1, 2, 2, 1, 3 };
    assert(geometry.indices == expected[..]);
    assert(geometry.normals.len == 4);
    foreach (normal : geometry.normals) assert(math::abs(normal.length() - 1) < 0.0001f);
}

fn void test_unsupported_required_extension_leaves_store_unchanged() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    sz keys_before = assets.keys.len();
    if (catch excuse = gltf::load_model(&assets, fixture_path("unsupported.gltf"))) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "expected a fault");
    }
    assert(assets.keys.len() == keys_before);
    if (catch excuse = assets.find_model(fixture_path("unsupported.gltf"))) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false, "expected a fault");
    }
}

fn void test_missing_file_is_an_io_fault() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    if (catch excuse = gltf::load_model(&assets, fixture_path("__missing__.gltf"))) {
        assert(excuse == c3d::ASSET_IO_ERROR);
    } else {
        assert(false, "expected a fault");
    }
}

fn void test_duplicate_model_key_faults_before_insertion() @test {
    AssetStore assets = create_store();
    defer asset::destroy_asset_store(&assets);
    String path = fixture_path("strip.gltf");
    gltf::load_model(&assets, path)!!;
    sz keys_before = assets.keys.len();
    if (catch excuse = gltf::load_model(&assets, path)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "expected a fault");
    }
    assert(assets.keys.len() == keys_before);
}
