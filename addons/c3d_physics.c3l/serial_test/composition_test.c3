module c3d_physics_serial_test;

import c3d::nav;
import c3d::physics::cloth;
import c3d::scene;
import c3d::serial;

fn void test_cloth_source_mesh_remains_available_to_nav_source_in_both_formats() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            nav::register_serial_codecs()!!;
            nav::register_nav(&fixture.source)!!;
            nav::register_nav(&fixture.destination)!!;
            Node* node = add_cloth_fixture(&fixture);
            fixture.source.add_nav_source(node)!!;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            Node* restored_cloth = child_named(restored, "fabric");
            assert(fixture.destination.has(restored_cloth, Mesh));
            assert(fixture.destination.has(restored_cloth, NavSource));
            assert(fixture.destination.has(restored_cloth, Cloth) && !fixture.destination.get(restored_cloth, Cloth).is_prepared());
            assert(!fixture.destination.get(restored_cloth, NavSource).geometry.generation);
            NavBuilder builder = nav::create_nav_builder(mem, &fixture.destination, nav::default_nav_builder_desc({
                .min = { -2, -2, -2 }, .max = { 2, 3, 2 },
            }))!!;
            defer nav::destroy_nav_builder(&builder);
            NavMesh mesh = nav::create_nav_mesh_for(mem, &builder)!!;
            defer nav::destroy_nav_mesh(&mesh);
            NavSyncResult result = nav::nav_sync(
                builder: &builder,
                mesh: &mesh,
                scene: &fixture.destination,
                assets: &fixture.assets,
                budget: 8,
            );
            assert(result.failed == 0 && fixture.destination.has(restored_cloth, NavSourceRuntime));
        };
    }
}
