module c3d_physics_cloth_gpu_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::physics;
import c3d::physics::cloth;
import c3d::render::cloth_gpu;
import c3d::scene;
import std::math;

const uint GRID_CELLS @local = 4;

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    MaterialId material;
}

fn void setup(Fixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, { .max_nodes = 8 });
    physics::register_physics(&fixture.scene)!!;
    fixture.material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!!;
}

fn void teardown(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_hanging_sheet(Fixture* fixture, float bend_stiffness) @local {
    uint side = GRID_CELLS + 1;
    Geometry grid = {
        .positions = alloc::new_array(tmem, Vec3, (sz)(side * side)),
        .indices   = alloc::new_array(tmem, uint, (sz)(6 * GRID_CELLS * GRID_CELLS)),
    };
    for (uint row = 0; row < side; row++) {
        for (uint column = 0; column < side; column++) {
            grid.positions[row * side + column] = { (float)column / GRID_CELLS, -(float)row / GRID_CELLS, 0 };
        }
    }
    usz next;
    for (uint row = 0; row < GRID_CELLS; row++) {
        for (uint column = 0; column < GRID_CELLS; column++) {
            uint top_left = row * side + column;
            uint bottom_left = top_left + side;
            uint[6] corners = { top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
            grid.indices[next:6] = corners[..];
            next += 6;
        }
    }
    grid.finalize();
    GeometryId geometry = fixture.assets.add_geometry(&grid)!!;
    Node* node = fixture.scene.add_mesh(geometry, fixture.material)!!;
    fixture.scene.update_world();

    uint[] pins = alloc::new_array(tmem, uint, (sz)side);
    foreach (index, &pin : pins) *pin = (uint)index;
    ClothDesc desc = cloth::default_cloth_desc();
    desc.pins = pins;
    desc.bend_stiffness = bend_stiffness;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    return node;
}

fn void test_gpu_cloth_subset_takes_a_bendless_sheet_and_rejects_bends() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    @pool() {
        Node* bendless = add_hanging_sheet(&fixture, 0);
        cloth_gpu::check_gpu_cloth(&fixture.scene, bendless)!!;

        Node* bent = add_hanging_sheet(&fixture, cloth::DEFAULT_BEND_STIFFNESS);
        assert(@catch(cloth_gpu::check_gpu_cloth(&fixture.scene, bent)) == c3d::UNSUPPORTED);
    };
}
