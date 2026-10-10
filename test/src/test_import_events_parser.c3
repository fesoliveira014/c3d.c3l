module c3d::test::import_events_parser;

import c3d;
import c3d::anim;
import c3d::asset;
import std::collections::object;
import std::encoding::json;

fn void test_import_events_parser_observes_standard_json_last_wins_and_signed_integer_limit() @test {
    @pool() {
        Object* parsed = json::tparse(`{"version":1,"version":2}`, JsonFlavor.JSON)!!;
        Object* version = parsed.get("version")!!;
        assert(version.is_int() && version.i == 2);
        assert(@catch(json::tparse("9223372036854775808", JsonFlavor.JSON)) == json::INVALID_NUMBER);
        Object* rounded = json::tparse("1.0000000000000000001", JsonFlavor.JSON)!!;
        assert(rounded.is_float() && rounded.f == 1);
    };
}

fn void test_import_events_parser_exact_integer_spellings_and_uint_boundary() @test {
    @pool() {
        String[*] supported = { "1", "1.0", "1e0", "10e-1", "10000e-4" };
        foreach (version : supported) {
            String source = string::tformat(
                `{"version":%s,"events":[{"time":0,"id":1.0},{"time":0,"id":1e0},{"time":0,"id":10e-1},{"time":0,"id":-0e-999999999},{"time":0,"id":429496729500e-2}]}`,
                version,
            );
            ClipEvent[] events = asset::parse_clip_events(tmem, source, 0)!!;
            uint[5] expected = { 1, 1, 1, 0, uint::max };
            assert(events.len == expected.len);
            foreach (index, event : events) assert(event.id == expected[index] && event.time == 0);
        }
    };
}

fn void test_import_events_parser_rejects_fractional_or_out_of_domain_ids_exactly() @test {
    @pool() {
        String[*] values = {
            "1.0000000000000000001", "-1", "4294967296", "4.294967296e9",
            "4294967295.00000000001", "1e-999999999", "1e999999999",
        };
        foreach (value : values) {
            String source = string::tformat(`{"version":1,"events":[{"time":0,"id":%s}]}`, value);
            assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::ASSET_FORMAT_ERROR);
        }
    };
}

fn void test_import_events_parser_classifies_arbitrary_size_integer_versions() @test {
    @pool() {
        String[*] unsupported = {
            "2", "-1", "0", "-0", "1e30", "123456789012345678901234567890", "1e999999999",
        };
        foreach (version : unsupported) {
            String source = string::tformat(`{"version":%s,"events":[]}`, version);
            assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::UNSUPPORTED);
        }
        String[*] fractional = { "1.5", "1.0000000000000000001", "1e-999999999" };
        foreach (version : fractional) {
            String source = string::tformat(`{"version":%s,"events":[]}`, version);
            assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::ASSET_FORMAT_ERROR);
        }
    };
}

fn void test_import_events_parser_scopes_decoded_duplicate_keys_to_schema_objects() @test {
    @pool() {
        String[*] invalid = {
            `{"version":1,"version":1,"events":[]}`,
            `{"version":1,"events":[{"time":0,"id":1,"id":1}]}`,
            `{"version":1,"unknown":0,"unknown":1,"events":[]}`,
            `{"version":1,"ver\u0073ion":1,"events":[]}`,
            `{"version":1,"events":[{"time":0,"id":1,"unknown":0,"unknown":1}]}`,
            `{"version":1,"events":[{"time":0,"id":1,"\u0069d":1}]}`,
        };
        foreach (source : invalid) {
            assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::ASSET_FORMAT_ERROR);
        }
        String source = `{"unrelated":{"x":1,"x":2},"huge":123456789012345678901234567890,"extreme":1e999999999,"c3d_events":{"version":1,"unknown":{"x":1,"x":2},"events":[{"time":0,"id":7,"unknown":{"x":1,"x":2}}]}}`;
        ClipEvent[] events = asset::parse_gltf_clip_events(tmem, source, 0)!!;
        assert(events.len == 1 && events[0].id == 7);
    };
}

fn void test_import_events_parser_strict_json_number_and_container_grammar() @test {
    @pool() {
        String[*] invalid = {
            `{"version":01,"events":[]}`, `{"version":1 .0,"events":[]}`,
            `{"version":1e +0,"events":[]}`, `{"version":- 1,"events":[]}`,
            `{"version":1,"events":[{"time":0,"id":1,}]}`,
            `{"version":1,"events":[],}`, `{"version":1,"events":[]} false`,
            `{"version":1,"events":[{"time":1e999999999,"id":0}]}`,
            `{"version":1,"events":[],"unknown":[1,]}`,
            `{"version":1,"events":[],"unknown":{"x":truefalse}}`,
        };
        foreach (source : invalid) {
            assert(@catch(asset::parse_clip_events(tmem, source, 1)) == c3d::ASSET_FORMAT_ERROR);
        }
    };
}

fn void test_import_events_parser_long_exponents_and_deep_unknown_values_use_bounded_storage() @test {
    @pool() {
        char[] exponent = alloc::new_array(tmem, char, 50000);
        exponent[..] = '9';
        String source = string::tformat(`{"version":1e%s,"events":[]}`, (String)exponent);
        assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::UNSUPPORTED);
        source = string::tformat(`{"version":1e-%s,"events":[]}`, (String)exponent);
        assert(@catch(asset::parse_clip_events(tmem, source, 0)) == c3d::ASSET_FORMAT_ERROR);
        char[] nested = alloc::new_array(tmem, char, 2049);
        nested[:1024] = '[';
        nested[1024] = '0';
        nested[1025:1024] = ']';
        source = string::tformat(
            `{"unknown":%s,"c3d_events":{"version":1,"events":[{"time":0,"id":8}]}}`,
            (String)nested,
        );
        ClipEvent[] events = asset::parse_gltf_clip_events(tmem, source, 0)!!;
        assert(events.len == 1 && events[0].id == 8);
    };
}
