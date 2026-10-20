module c3d_particle_serial_test;

import c3d;
import c3d::particle @public;
import c3d::scene;
import c3d::serial;
import std::math;

const char[*] PARTICLE_V1_BINARY @private = $embed("fixtures/particle_v1.bin");
const char[*] PARTICLE_V1_TEXT @private = $embed("fixtures/particle_v1.json");
const char[*] PARTICLE_V2_BINARY @private = $embed("fixtures/particle_v2.bin");
const char[*] PARTICLE_V2_TEXT @private = $embed("fixtures/particle_v2.json");
const char[*] PARTICLE_V3_BINARY @private = $embed("fixtures/particle_v3.bin");
const char[*] PARTICLE_V3_TEXT @private = $embed("fixtures/particle_v3.json");
const char[*] PARTICLE_V4_BINARY @private = $embed("fixtures/particle_v4.bin");
const char[*] PARTICLE_V4_TEXT @private = $embed("fixtures/particle_v4.json");
const char[*] PARTICLE_V5_BINARY @private = $embed("fixtures/particle_v5.bin");
const char[*] PARTICLE_V5_TEXT @private = $embed("fixtures/particle_v5.json");

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

fn void test_particle_v3_fixtures_read_without_collision() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, MESH);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? PARTICLE_V3_TEXT[..] : PARTICLE_V3_BINARY[..];
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            ParticleSystem* system = fixture.destination.get(restored, ParticleSystem);
            assert(system.desc.saturation == DROP_OLDEST && !system.emitting && !system.is_prepared());
            assert(system.desc.sub_emitter_count == 1 && system.desc.max_events == 6);
            assert(system.desc.sub_emitters[0].trigger == DEATH && system.desc.sub_emitters[0].count == 3);
            assert(system.desc.sub_emitters[0].inherit_velocity == 0.25f && system.desc.sub_emitters[0].on_evict);
            assert(system.desc.collision.response == NONE && !system.desc.collision.ground_plane);
            assert(system.desc.capacity == 7 && system.desc.seed == 12345 && system.desc.render_mode == MESH);
        };
    }
}

fn void test_particle_v4_fixtures_read_without_flipbook() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, MESH);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? PARTICLE_V4_TEXT[..] : PARTICLE_V4_BINARY[..];
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            ParticleSystem* system = fixture.destination.get(restored, ParticleSystem);
            assert(system.desc.sub_emitter_count == 1 && system.desc.max_events == 6);
            assert(system.desc.collision.response == BOUNCE && system.desc.collision.ground_plane);
            assert(system.desc.collision.max_queries == 9 && system.desc.collision.impact_speed == 2.5f);
            assert(system.desc.flipbook.columns == 0 && !system.desc.flipbook.random_start);
            assert(system.desc.capacity == 7 && system.desc.seed == 12345 && system.desc.render_mode == MESH);
        };
    }
}

fn void test_particle_v5_fixtures_read_without_turbulence() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, MESH);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? PARTICLE_V5_TEXT[..] : PARTICLE_V5_BINARY[..];
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            ParticleSystem* system = fixture.destination.get(restored, ParticleSystem);
            assert(system.desc.flipbook.columns == 4 && system.desc.flipbook.frame_count == 11);
            assert(system.desc.collision.response == BOUNCE && system.desc.render_mode == STRETCHED);
            assert(system.desc.turbulence.strength == 0 && system.desc.turbulence.octaves == 0);
            assert(system.desc.turbulence.scroll == (Vec3){});
        };
    }
}
