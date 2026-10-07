module c3d_character_serial_test @feat(C3D_CHARACTER_NAV);

import c3d;
import c3d::character @public;
import c3d::nav;
import c3d::scene;
import c3d::serial;

fn void test_nav_driven_both_formats_restore_marker_after_character_and_agent() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, false);
            defer destroy_fixture(&fixture);
            nav::register_nav(&fixture.source)!!;
            nav::register_nav(&fixture.destination)!!;
            character::register_nav_driven(&fixture.source)!!;
            character::register_nav_driven(&fixture.destination)!!;
            fixture.source.add_nav_agent(fixture.node, nav::default_nav_agent_params())!!;
            fixture.source.add_nav_driven(fixture.node)!!;
            fixture.source.set_nav_target(fixture.node, { 9, 2, 3 });
            fixture.source.get(fixture.node, NavDriven).traversal.active = true;
            fixture.source.get(fixture.node, NavDriven).traversal.t = 0.5f;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.node,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            assert(fixture.destination.has(restored, Character) && fixture.destination.has(restored, NavAgent));
            assert(fixture.destination.has(restored, NavDriven));
            assert(!fixture.destination.get(restored, NavDriven).traversal.active);
            assert(fixture.destination.get(restored, NavDriven).traversal.t == 0);
            assert(fixture.destination.get(restored, NavAgent).driven);
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
            fixture.source.remove_component(fixture.node, NavAgent);
            char[] invalid = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.node,
                text_mode: text_mode,
            )!!;
            uint before = fixture.destination.world.entities.free_count;
            assert(@catch(decode(&fixture, invalid, text_mode)) == character::NO_NAV_AGENT);
            assert(fixture.destination.world.entities.free_count == before && fixture.destination.count(NavDriven) == 1);
        };
    }
}
