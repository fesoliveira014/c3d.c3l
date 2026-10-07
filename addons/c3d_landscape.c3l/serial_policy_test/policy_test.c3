module c3d_landscape_policy_test;

import c3d::asset;
import c3d::ecs @public;
import c3d::landscape @public;
import c3d::landscape::terrain;
import c3d::landscape::foliage @public;
import c3d::landscape::water;
import c3d::scene;
import c3d::serial @public;

struct ExpectedPolicy @private {
    uint slot;
    String name;
    typeid identity;
    RestorePhase phase;
}

fn void test_every_landscape_component_has_one_expected_serialization_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 1, .max_textures = 8, .max_materials = 1, .max_samplers = 8,
    });
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, { .max_nodes = 1 });
    defer scene::destroy_scene(&scene);
    uint core_count = ecs::registered_type_count;
    register_scene(&scene, &assets);
    uint registered_count = ecs::registered_type_count;
    landscape::register_serial_codecs()!!;
    ExpectedPolicy[3] authored = {
        { .slot = ecs::assigned_slot(Terrain)!!, .name = "terrain", .identity = TerrainDesc::typeid, .phase = VALUE },
        { .slot = ecs::assigned_slot(Foliage)!!, .name = "foliage",
            .identity = FoliageAuthoring::typeid, .phase = OWNER },
        { .slot = ecs::assigned_slot(Water)!!, .name = "water", .identity = WaterDesc::typeid, .phase = VALUE },
    };
    uint[5] transient = {
        ecs::assigned_slot(TerrainRuntime)!!, ecs::assigned_slot(FoliageRuntime)!!,
        ecs::assigned_slot(FoliageCellOwner)!!, ecs::assigned_slot(WaterRuntime)!!,
        ecs::assigned_slot(WaterMirror)!!,
    };
    assert(registered_count == core_count + authored.len + transient.len);
    assert(ecs::registered_type_count == registered_count);
    for (uint slot = core_count; slot < registered_count; slot++) {
        serial::CodecEntry* entry = &serial::codecs[slot];
        uint policies = (uint)(entry.described != null)
          + (uint)(entry.codec.name.len != 0 && entry.described == null) + (uint)entry.transient;
        uint matches;
        foreach (policy : authored) {
            if (policy.slot != slot) continue;
            matches++;
            assert(policies == 1 && entry.described && !entry.transient);
            assert(entry.codec.name == policy.name && entry.codec.phase == policy.phase && entry.codec.version == 1);
            assert(entry.described.type.descriptor.identity == policy.identity);
        }
        foreach (expected : transient) {
            if (expected != slot) continue;
            matches++;
            assert(policies == 1 && entry.transient && !entry.described && !entry.codec.name.len);
            assert(entry.codec.collect != null);
        }
        assert(matches == 1);
    }
    landscape::register_serial_codecs()!!;
    register_scene(&scene, &assets);
    serial::register_core_codecs()!!;
    assert(ecs::registered_type_count == registered_count);
}

fn void register_scene(Scene* scene, AssetStore* assets) @local {
    terrain::register_terrain(scene, assets)!!;
    foliage::register_foliage(scene)!!;
    water::register_water(scene, assets)!!;
}
