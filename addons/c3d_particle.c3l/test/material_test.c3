module c3d_particle_material_test;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::particle;
import c3d::scene;

fn void test_particle_material_copies_its_payload_and_keeps_shared_assets() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 4 });
    defer scene::destroy_scene(&scene);
    particle::register_particles(&scene)!!;
    ShaderId shader = particle::add_particle_shader(&assets)!!;
    ParticleMaterialParams params = {
        .color = { 0.8f, 0.4f, 0.2f, 0.5f },
        .soft_distance = 0.25f,
        .lighting = ParticleLighting.AMBIENT,
    };
    MaterialId material_id = particle::add_particle_material(
        assets: &assets,
        shader: shader,
        params: params,
        blend: BlendMode.ADDITIVE,
    )!!;
    params.color = {};
    ParticleMaterialParams* stored = assets.@custom_params(material_id, ParticleMaterialParams);
    assert(stored.color.x == 0.8f && stored.soft_distance == 0.25f);
    Material* material = &assets.material(material_id).data;
    assert(material.common.alpha_mode == AlphaMode.BLEND && material.common.blend_mode == BlendMode.ADDITIVE);
    assert(material.common.depth_test && !material.common.depth_write && material.common.double_sided);
    assert(c3d::same_id(material.custom.shader, shader));
    assert(material.custom.param_block.len == ParticleMaterialParams::size);
    assert(assets.shader(shader).desc.scene_reads.depth && !assets.shader(shader).desc.vertex.shaded.len);
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 4;
    desc.material = material_id;
    Node* emitter = scene.add_particle_system(desc)!!;
    scene.remove(emitter);
    assert(assets.materials.is_live(material_id) && assets.shaders.is_live(shader));
}

fn void test_particle_material_faults_are_specific_and_do_not_publish() @test {
    AssetStoreDesc desc = asset::default_asset_store_desc();
    desc.max_materials = 1;
    desc.max_shaders = 1;
    AssetStore assets = asset::create_asset_store(mem, desc);
    defer asset::destroy_asset_store(&assets);
    ShaderId shader = particle::add_particle_shader(&assets, "particle_shader")!!;
    ParticleMaterialParams params = { .color = { 1, 1, 1, 1 } };
    assert(@catch(particle::add_particle_material(&assets, {}, params)) == c3d::INVALID_ID);
    params.soft_distance = -1;
    assert(@catch(particle::add_particle_material(&assets, shader, params)) == c3d::INVALID_ARGUMENT);
    params.soft_distance = 0;
    params.color.x = bitcast(0x7fc00000u, float);
    assert(@catch(particle::add_particle_material(&assets, shader, params)) == c3d::INVALID_ARGUMENT);
    params.color.x = 1;
    particle::add_particle_material(
        assets: &assets,
        shader: shader,
        params: params,
        key: "particle_material",
    )!!;
    assert(@catch(particle::add_particle_material(
        assets: &assets,
        shader: shader,
        params: params,
        key: "particle_material",
    )) == c3d::INVALID_ARGUMENT);
    assert(@catch(particle::add_particle_material(&assets, shader, params)) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(particle::add_particle_shader(&assets)) == c3d::CAPACITY_EXCEEDED);
}
