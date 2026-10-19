module c3d_landscape_serial_test;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::describe;
import c3d::ecs;
import c3d::landscape @public;
import c3d::landscape::terrain;
import c3d::landscape::foliage;
import c3d::landscape::water;
import c3d::scene;
import c3d::serial;

const char[*] TERRAIN_V1_BINARY @private = $embed("fixtures/terrain_v1.bin");
const char[*] TERRAIN_V1_TEXT @private = $embed("fixtures/terrain_v1.json");
const char[*] WATER_V1_BINARY @private = $embed("fixtures/water_v1.bin");
const char[*] WATER_V1_TEXT @private = $embed("fixtures/water_v1.json");

fn void test_serial_layout_registration() @test {
    landscape::register_serial_codecs()!!;
    assert(serial::described_type(TerrainDesc)!!.version == 2);
    assert(serial::described_type(TerrainDesc)!!.layout == 0xbbb8c4e5931f82a4);
    assert(serial::described_type(landscape::TerrainDescV1)!!.layout == 0x7638a7507fa65b33);
    assert(serial::described_type(TerrainTile)!!.layout == 0x3fe780c7be5416e1);
    assert(serial::described_type(landscape::TerrainSetAuthoring)!!.layout == 0x6b17270c6b53663f);
    assert(serial::described_type(ScatterRules)!!.layout == 0x40955fefc693491e);
    assert(serial::described_type(SwayTemplate)!!.layout == 0x750cddc9cb008976);
    assert(serial::described_type(landscape::FoliageAuthoring)!!.version == 2);
    assert(serial::described_type(landscape::FoliageAuthoring)!!.layout == 0x797c3ed45915c1ed);
    assert(serial::described_type(Wave)!!.layout == 0xb7ea583c7a255cb9);
    assert(serial::described_type(WaterDesc)!!.version == 2);
    assert(serial::described_type(WaterDesc)!!.layout == 0x718815cf64669e4e);
    assert(serial::described_type(landscape::WaterDescV1)!!.layout == 0x74434d01389bb922);
    @pool() {
        String schema = serial::write_schema(tmem)!!;
        assert(schema.contains("terrain") && schema.contains("foliage") && schema.contains("water"));
        assert(schema.contains("terrain_set") && schema.contains("terrain_tile"));
        assert(schema.contains("density_channel") && schema.contains("lod_threshold")
          && schema.contains("ripple_drift") && schema.contains("reflection_view_slot"));
    };
}

fn void test_terrain_v1_fixtures_read_with_default_projection() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? TERRAIN_V1_TEXT[..] : TERRAIN_V1_BINARY[..];
            Node* ground = decode(&fixture, bytes, text_mode)!!;
            TerrainDesc* desc = &fixture.destination.get(ground, Terrain).desc;
            assert(desc.height_scale == 4 && desc.lod_threshold == 123 && !desc.cast_shadow);
            assert(desc.slope_projection == TOP && desc.triplanar_sharpness == terrain::DEFAULT_TRIPLANAR_SHARPNESS);
        };
    }
}

fn void test_water_v1_fixtures_read_with_one_mirror_on_view_slot_zero() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(
                fixture:   &fixture,
                allocator: mem,
                capacity:  32,
                with_lod:  false,
            );
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? WATER_V1_TEXT[..] : WATER_V1_BINARY[..];
            Node* lake = decode(&fixture, bytes, text_mode)!!;
            WaterDesc* desc = &fixture.destination.get(lake, Water).desc;
            assert(desc.roughness == 0.2f && desc.foam_depth == 0.8f && desc.wave_count == 3);
            assert(desc.max_mirrors == 1 && desc.reflection_view_slot == 0);
        };
    }
}

fn void test_landscape_both_encodings_restore_pending_authoring_and_prepare() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        foreach (with_lod : (bool[2]){ false, true }) {
            @pool() {
                Fixture fixture;
                create_fixture(
                    fixture: &fixture,
                    allocator: mem,
                    capacity: 32,
                    with_lod: with_lod,
                );
                defer destroy_fixture(&fixture);
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!;
                assert(bytes == encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!);
                char[] whole = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.source.root,
                    text_mode: text_mode,
                )!!;
                prepare_all(&fixture.source, &fixture.assets, fixture.root);
                fixture.source.reparent(fixture.root, fixture.source.root);
                assert(bytes == encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!);
                assert(whole == encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.source.root,
                    text_mode: text_mode,
                )!!);
                uint free_geometry = fixture.assets.geometries.free_count;
                uint free_materials = fixture.assets.materials.free_count;
                Node* restored = decode(&fixture, bytes, text_mode)!!;
                Node* ground = child_named(restored, "ground");
                Node* plants = child_named(restored, "plants");
                Node* lake = child_named(restored, "water");
                TerrainDesc* restored_desc = &fixture.destination.get(ground, Terrain).desc;
                assert(restored_desc.slope_projection == TRIPLANAR && restored_desc.triplanar_sharpness == 7);
                assert(!terrain::is_prepared(&fixture.destination, ground));
                assert(!foliage::is_prepared(&fixture.destination, plants));
                assert(!water::is_prepared(&fixture.destination, lake));
                assert(fixture.destination.count(InstancedMesh) == 0 && fixture.destination.count(Mesh) == 0);
                assert(fixture.destination.count(LodGroup) == 0 && fixture.destination.count(WaterMirror) == 0);
                assert(fixture.assets.geometries.free_count == free_geometry
                  && fixture.assets.materials.free_count == free_materials);
                assert(child_named(ground, "authored-child") != null);
                WaterDesc* restored_water = &fixture.destination.get(lake, Water).desc;
                assert(restored_water.max_mirrors == 2 && restored_water.reflection_view_slot == 2);
                FoliageDesc* desc = &fixture.destination.get(plants, Foliage).desc;
                assert(c3d::same_id(desc.ground, ground.id) && (desc.lod != null) == with_lod);
                assert(desc.rules.slope_normal == SMOOTH);
                if (with_lod) {
                    assert(desc.lod.parts[0].local.m00 == -1 && desc.lod.parts[0].local.m01 == 0.25f);
                    assert(desc.lod.parts[0].local.m03 == 2 && desc.lod.parts[0].local.m13 == 3
                      && desc.lod.parts[0].local.m23 == -4);
                    assert(desc.lod.parts.ptr != fixture.source.get(fixture.foliage_node, Foliage).desc.lod.parts.ptr);
                } else {
                    assert(c3d::same_id(fixture.destination.get(lake, Water).desc.geometry,
                        fixture.assets.find_geometry("water-source")!!));
                }
                assert(bytes == encode(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                    text_mode: text_mode,
                )!!);
                prepare_all(&fixture.destination, &fixture.assets, restored);
                free_materials = fixture.assets.materials.free_count;
                prepare_all(&fixture.destination, &fixture.assets, restored);
                assert(fixture.assets.materials.free_count == free_materials);
                Node* camera = fixture.destination.add_camera(camera::perspective_deg(60, 0.1f))!!;
                fixture.destination.update_world();
                terrain::update(&fixture.destination, &fixture.assets)!!;
                foliage::update(&fixture.destination, &fixture.assets, { 2, 0, 1 })!!;
                water::update(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    wind_velocity: { 2, 0, 1 },
                    time: 0.5,
                );
                water::update_mirror(
                    scene: &fixture.destination,
                    body: lake.id,
                    slot: 1,
                    viewing_camera: camera.id,
                )!!;
                assert(fixture.destination.get(ground, InstancedMesh).count > 0);
                assert(fixture.destination.get(plants, FoliageRuntime).cell_nodes > 0);
                assert(fixture.destination.has(lake, Mesh));
                assert(bytes == encode(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                    text_mode: text_mode,
                )!!);
            };
        }
    }
}

fn void test_tile_set_authoring_restores_pending_and_links_on_preparation() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            TerrainDesc tile_desc = fixture.source.get(fixture.terrain_node, Terrain).desc;
            Node* set_node = fixture.source.add_node(fixture.root, "tiles")!!;
            fixture.source.add(set_node, (TerrainSet){ .texels = 129, .cell_size = 1, .height_scale = 4 });
            foreach (column : (int[2]){ 0, 1 }) {
                Node* tile = fixture.source.add_node(set_node, "tile")!!;
                tile.local.position = { (float)column * 128, 0, 0 };
                fixture.source.add(tile, (TerrainTile){ .x = column, .z = 0 });
                terrain::attach_terrain(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    node: tile,
                    desc: tile_desc,
                )!!;
            }
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: set_node,
                text_mode: text_mode,
            )!!;

            Node* restored = decode(&fixture, bytes, text_mode)!!;
            TerrainSet* set = fixture.destination.get(restored, TerrainSet);
            assert(set.texels == 129 && set.cell_size == 1 && set.height_scale == 4 && set.state == null);
            Node* west = restored.first_child;
            Node* east = west.next_sibling;
            if (fixture.destination.get(west, TerrainTile).x != 0) @swap(west, east);
            assert(fixture.destination.get(east, TerrainTile).x == 1 && !set.is_linked(west.id));
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);

            prepare_all(&fixture.destination, &fixture.assets, restored);
            assert(c3d::same_id(set.neighbour(west.id, EAST)!!, east.id));
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);

            fixture.source.get(set_node, TerrainSet).texels = 1;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: set_node,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
        };
    }
}

fn void test_landscape_generated_nodes_reject_roots_and_authored_additions() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            prepare_all(&fixture.source, &fixture.assets, fixture.root);
            Entity cell_id = fixture.source.get(fixture.foliage_node, FoliageRuntime).cells[0];
            Node* cell = fixture.source.node(cell_id);
            Node* mirror = fixture.source.node(fixture.source.get(fixture.water_node, WaterRuntime).mirrors[1]);
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: cell,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: mirror,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            Node* child = fixture.source.add_node(cell, "application")!!;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            fixture.source.remove(child);
            fixture.source.add(cell, (Extra){ .value = 7 });
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            fixture.source.remove_component(cell, Extra);
            fixture.source.add_node(mirror, "application")!!;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.source.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
        };
    }
}

fn void test_landscape_read_capacity_and_late_copy_failure_roll_back() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            TrackingAllocator tracking;
            tracking.init(mem);
            defer tracking.free();
            CopyFailure failure = { .backing = &tracking };
            Fixture fixture;
            create_fixture(&fixture, &failure);
            Node* second = fixture.source.add_node(fixture.root, "second-plants")!!;
            foliage::attach_foliage(
                scene: &fixture.source,
                assets: &fixture.assets,
                node: second,
                desc: fixture.source.get(fixture.foliage_node, Foliage).desc,
            )!!;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            uint free_nodes = fixture.destination.world.entities.free_count;
            uint free_geometry = fixture.assets.geometries.free_count;
            uint free_materials = fixture.assets.materials.free_count;
            sz allocations = tracking.allocation_count();
            failure.enabled = true;
            failure.failure = 2;
            serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT;
            options.allocator = mem;
            assert(@catch(decode(
                fixture: &fixture,
                bytes: bytes,
                text_mode: text_mode,
                options: options,
            )) == c3d::CAPACITY_EXCEEDED);
            failure.enabled = false;
            assert(failure.copies == 2);
            assert(tracking.allocation_count() == allocations);
            assert(fixture.destination.world.entities.free_count == free_nodes);
            assert(fixture.destination.count(Foliage) == 0 && fixture.destination.count(Terrain) == 0);
            assert(fixture.assets.geometries.free_count == free_geometry
              && fixture.assets.materials.free_count == free_materials);
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            fixture.destination.remove(restored);
            assert(tracking.allocation_count() == allocations);
            scene::destroy_scene(&fixture.destination);
            fixture.destination = scene::create_scene(&failure, { .max_nodes = 2 });
            register_scene(&fixture.destination, &fixture.assets);
            assert(@catch(decode(&fixture, bytes, text_mode)) == c3d::CAPACITY_EXCEEDED);
            assert(fixture.destination.root.first_child == null);
            destroy_fixture(&fixture);
            assert(!tracking.has_leaks());
        };
    }
}

fn void test_landscape_writers_reject_invalid_authored_descriptors() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            float*[3] fields = {
                &fixture.source.get(fixture.terrain_node, Terrain).desc.cell_size,
                &fixture.source.get(fixture.foliage_node, Foliage).desc.rules.spacing,
                &fixture.source.get(fixture.water_node, Water).desc.cell_size,
            };
            foreach (field : fields) {
                float saved = *field;
                *field = 0;
                assert(@catch(encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )) == c3d::INVALID_ARGUMENT);
                *field = saved;
            }
        };
    }
}
