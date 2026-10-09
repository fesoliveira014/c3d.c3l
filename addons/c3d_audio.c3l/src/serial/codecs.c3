module c3d::audio @feat(C3D_AUDIO_SERIAL);

import c3d;
import c3d::describe;
import c3d::serial;

const ulong EMITTER_LAYOUT @private = 0xed08d996db474b09;
const ulong LISTENER_LAYOUT @private = 0x5ecfccc35cc46d45;

<*
 Register audio component codecs.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn void? register_serial_codecs() {
    describe::register_reflected_component(AudioEmitter)!;
    describe::register_reflected_component(AudioListener)!;
    serial::register_described_type(
        $Type: AudioEmitter,
        version: 1,
        layout: EMITTER_LAYOUT,
        defaults: &defaults_emitter,
    )!;
    serial::register_described_type(
        $Type: AudioListener,
        version: 1,
        layout: LISTENER_LAYOUT,
        defaults: &defaults_listener,
    )!;
    serial::register_described(AudioEmitter, { .name = "audio_emitter" })!;
    serial::register_described(AudioListener, { .name = "audio_listener" })!;
    serial::register_transient(AudioVoiceLink)!;
}

fn void defaults_emitter(void* value) @private => *(AudioEmitter*)value = AUDIO_EMITTER_DEFAULT;
fn void defaults_listener(void* value) @private => *(AudioListener*)value = {};
