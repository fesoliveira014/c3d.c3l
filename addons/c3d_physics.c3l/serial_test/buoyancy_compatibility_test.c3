module c3d_physics_serial_test;

import c3d;
import c3d::physics @public;
import c3d::scene;
import c3d::serial @public;

const char[*] BUOYANCY_V1_BINARY @private = $embed("fixtures/buoyancy_v1.bin");
const char[*] BUOYANCY_V1_TEXT @private = $embed("fixtures/buoyancy_v1.json");

fn void test_buoyancy_v1_fixtures_read_with_no_drag_coefficient() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? BUOYANCY_V1_TEXT[..] : BUOYANCY_V1_BINARY[..];
            Node* root = decode(&fixture, bytes, text_mode)!!;
            Buoyancy* buoyancy = fixture.destination.get(root, Buoyancy);
            assert(buoyancy.fluid_density == 1025 && buoyancy.linear_drag == 7 && buoyancy.drag_coefficient == 0);
        };
    }
}
