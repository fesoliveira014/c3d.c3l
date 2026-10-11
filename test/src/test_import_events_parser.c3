module c3d::test::import_events_parser;

import c3d;
import c3d::anim;
import c3d::asset;

fn void test_import_events_parser_integral_spellings_and_uint_boundary() @test {
    @pool() {
        String[*] supported = { "1", "1.0", "1e0", "10e-1" };
        foreach (version : supported) {
            String source = string::tformat(
                `{"version":%s,"events":[{"time":0,"id":1.0},{"time":0,"id":1e0},{"time":0,"id":-0},{"time":0,"id":4294967295}]}`,
                version,
            );
            ClipEvent[] events = asset::parse_clip_events(tmem, source, 0)!!;
            uint[4] expected = { 1, 1, 0, uint::max };
            assert(events.len == expected.len);
            foreach (index, event : events) assert(event.id == expected[index] && event.time == 0);
        }
    };
}

fn void test_import_events_parser_rejects_fractional_out_of_domain_or_mistyped_ids() @test {
    @pool() {
        String[*] values = { "1.5", "-1", "4294967296", "4.294967296e9", `"1"` };
        foreach (value : values) {
            String source = string::tformat(`{"version":1,"events":[{"time":0,"id":%s}]}`, value);
            assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::ASSET_FORMAT_ERROR);
        }
    };
}

fn void test_import_events_parser_classifies_versions() @test {
    @pool() {
        String[*] unsupported = { "2", "0", "-1", "1e30" };
        foreach (version : unsupported) {
            String source = string::tformat(`{"version":%s,"events":[]}`, version);
            assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::UNSUPPORTED);
        }
        String[*] malformed = { "1.5", `"1"` };
        foreach (version : malformed) {
            String source = string::tformat(`{"version":%s,"events":[]}`, version);
            assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::ASSET_FORMAT_ERROR);
        }
    };
}

fn void test_import_events_parser_requires_strict_json() @test {
    @pool() {
        String[*] invalid = {
            `{"version":1,"events":[],}`,
            `{"version":1,"events":[]} // comment`,
            `{"version":1,"events":[]} false`,
            `{"version":1,"events":[{"time":1e999,"id":0}]}`,
        };
        foreach (source : invalid) {
            assert(@catch(asset::parse_clip_events(tmem, source, 1)) == c3d::ASSET_FORMAT_ERROR);
        }
    };
}

fn void test_import_events_parser_ignores_extras_without_event_table() @test {
    @pool() {
        String[*] extras = {
            `[{"c3d_events":{"version":1,"events":[{"time":0,"id":1}]}}]`,
            `"c3d_events"`,
            `{"unrelated":{"c3d_events":{"version":2}}}`,
        };
        foreach (source : extras) assert(asset::parse_gltf_clip_events(tmem, source, 0)!!.len == 0);
    };
}
