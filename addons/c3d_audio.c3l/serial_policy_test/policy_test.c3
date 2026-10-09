module c3d_audio_serial_policy_test;

import c3d::asset;
import c3d::audio @public;
import c3d::ecs @public;
import c3d::scene;
import c3d::serial @public;
import c3d_audio_test;

fn void test_every_audio_component_has_one_expected_serialization_policy() @test {
    assert(ecs::registered_type_count == 0);
    serial::register_core_codecs()!!;
    AssetStore assets = c3d_audio_test::make_store(mem);
    defer asset::destroy_asset_store(&assets);
    AudioSystem system = c3d_audio_test::make_system(mem, &assets);
    defer audio::destroy_audio_system(&system);
    uint core_count = ecs::registered_type_count;
    Scene scene = c3d_audio_test::make_scene(mem, &system);
    defer scene::destroy_scene(&scene);
    uint registered_count = ecs::registered_type_count;
    audio::register_serial_codecs()!!;
    assert(registered_count == core_count + 3 && ecs::registered_type_count == registered_count);
    uint emitter = ecs::assigned_slot(AudioEmitter)!!;
    uint listener = ecs::assigned_slot(AudioListener)!!;
    uint link = ecs::assigned_slot(AudioVoiceLink)!!;
    assert(emitter != listener && emitter != link && listener != link);
    for (uint slot = core_count; slot < registered_count; slot++) {
        serial::CodecEntry* entry = &serial::codecs[slot];
        uint policies = (uint)(entry.described != null)
          + (uint)(entry.codec.name.len != 0 && entry.described == null) + (uint)entry.transient;
        assert(policies == 1);
        if (slot == link) {
            assert(entry.transient && !entry.described && !entry.codec.name.len);
        } else {
            assert(entry.described && !entry.transient && entry.codec.version == 1);
            assert(entry.codec.name == (slot == emitter ? "audio_emitter" : "audio_listener"));
        }
    }
    audio::register_serial_codecs()!!;
    serial::register_core_codecs()!!;
    assert(ecs::registered_type_count == registered_count);
}
