module c3d_landscape_serial_test;

import c3d;
import c3d::landscape::foliage;
import c3d::scene;
import c3d::serial;

const char[*] LANDSCAPE_V1_BINARY @private = $embed("fixtures/landscape_v1.bin");
const char[*] LANDSCAPE_V1_TEXT @private = $embed("fixtures/landscape_v1.json");

fn void test_foliage_v1_fixtures_read_with_faceted_slope_normals() @test {
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

            char[] bytes = text_mode ? LANDSCAPE_V1_TEXT[..] : LANDSCAPE_V1_BINARY[..];
            Node* root = decode(&fixture, bytes, text_mode)!!;
            ScatterRules* rules = &fixture.destination.get(child_named(root, "plants"), Foliage).desc.rules;
            assert(rules.seed == 53 && rules.max_slope == 1 && rules.density_channel == 2);
            assert(rules.slope_normal == FACE);
        };
    }
}
