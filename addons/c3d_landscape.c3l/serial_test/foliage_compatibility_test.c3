module c3d_landscape_serial_test;

import c3d;
import c3d::landscape::foliage;
import c3d::scene;
import c3d::serial;

const char[*] LANDSCAPE_V1_BINARY @private = $embed("fixtures/landscape_v1.bin");
const char[*] LANDSCAPE_V1_TEXT @private = $embed("fixtures/landscape_v1.json");
const char[*] FOLIAGE_V2_BINARY @private = $embed("fixtures/foliage_v2.bin");
const char[*] FOLIAGE_V2_TEXT @private = $embed("fixtures/foliage_v2.json");

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
            FoliageDesc* desc = &fixture.destination.get(child_named(root, "plants"), Foliage).desc;
            assert(desc.rules.seed == 53 && desc.rules.max_slope == 1 && desc.rules.density_channel == 2);
            assert(desc.rules.slope_normal == FACE && desc.trace && !desc.trace_sway);
        };
    }
}

fn void test_foliage_v2_fixtures_read_without_swayed_tracing() @test {
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

            char[] bytes = text_mode ? FOLIAGE_V2_TEXT[..] : FOLIAGE_V2_BINARY[..];
            Node* root = decode(&fixture, bytes, text_mode)!!;
            FoliageDesc* desc = &fixture.destination.get(child_named(root, "plants"), Foliage).desc;
            assert(desc.rules.seed == 53 && desc.rules.slope_normal == SMOOTH && desc.cell_size == 128);
            assert(desc.trace && !desc.trace_sway);
        };
    }
}
