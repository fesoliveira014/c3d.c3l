module c3d_particle_serial_test;

import c3d;
import c3d::particle @public;
import c3d::scene;
import c3d::serial;

const char[*] PARTICLE_V1_BINARY @private = $embed("fixtures/particle_v1.bin");
const char[*] PARTICLE_V1_TEXT @private = $embed("fixtures/particle_v1.json");
const char[*] PARTICLE_V2_BINARY @private = $embed("fixtures/particle_v2.bin");
const char[*] PARTICLE_V2_TEXT @private = $embed("fixtures/particle_v2.json");

fn void test_particle_v1_fixtures_read_as_refuse() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, MESH);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? PARTICLE_V1_TEXT[..] : PARTICLE_V1_BINARY[..];
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            ParticleSystem* system = fixture.destination.get(restored, ParticleSystem);
            assert(system.desc.saturation == REFUSE && !system.emitting && !system.is_prepared());
            assert(system.desc.sub_emitter_count == 0 && system.desc.max_events == 0);
            assert(system.desc.capacity == 7 && system.desc.seed == 12345 && system.desc.render_mode == MESH);
            assert(system.desc.rate == 7 && system.desc.shape == CONE && system.desc.stretch == 2);
        };
    }
}

fn void test_particle_v2_fixtures_read_without_sub_emitters() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, MESH);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? PARTICLE_V2_TEXT[..] : PARTICLE_V2_BINARY[..];
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            ParticleSystem* system = fixture.destination.get(restored, ParticleSystem);
            assert(system.desc.saturation == DROP_OLDEST && !system.emitting && !system.is_prepared());
            assert(system.desc.sub_emitter_count == 0 && system.desc.max_events == 0);
            assert(system.desc.capacity == 7 && system.desc.seed == 12345 && system.desc.render_mode == MESH);
            assert(system.desc.rate == 7 && system.desc.shape == CONE && system.desc.stretch == 2);
        };
    }
}
