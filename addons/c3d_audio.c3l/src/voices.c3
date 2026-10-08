module c3d::audio;

import c3d;
import c3d::asset;
import c3d::ecs;
import ma;

fn Mirror*? AudioState.ensure_mirror(&self, AudioClipId clip) {
    AudioClipAsset* record = self.assets.pool(AudioClip).try_get(clip)!;
    Mirror* mirror = &self.mirrors[clip.index];
    if (mirror.built) {
        bool current = c3d::same_id(mirror.clip, clip) && mirror.revision == record.header.revision;
        if (current) return mirror;
        self.retire_mirror_voices(clip.index);
        self.free_mirror_data(mirror);
    }
    AudioClip* data = &record.data;
    bool streamed = data.mode == AudioClipMode.STREAMED
        || (data.mode == AudioClipMode.AUTO && data.bytes.len >= self.stream_threshold_bytes);
    mirror.streamed = streamed;
    mirror.channels = data.channels;
    mirror.sample_rate = data.sample_rate;
    if (streamed) {
        mirror.bytes = alloc::new_array(self.allocator, char, (sz)data.bytes.len);
        mem::copy(mirror.bytes.ptr, data.bytes.ptr, data.bytes.len);
        mirror.frame_count = data.frame_count;
    } else {
        self.decode_mirror(mirror, data.bytes)!;
    }
    mirror.clip = clip;
    mirror.revision = record.header.revision;
    mirror.built = true;
    self.mirror_count++;
    return mirror;
}

fn void? AudioState.decode_mirror(&self, Mirror* mirror, char[] bytes) {
    ma::Decoder* decoder = (ma::Decoder*)alloc::malloc(self.allocator, (sz)ma::decoder_size());
    defer alloc::free(self.allocator, decoder);
    ma::Result opened = ma::decoder_init_memory(
        bytes: bytes.ptr,
        length: bytes.len,
        callbacks: &self.callbacks,
        decoder: decoder,
    );
    if (opened != ma::SUCCESS) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    defer (void)ma::decoder_uninit(decoder);
    ulong length;
    if (ma::decoder_get_length_in_pcm_frames(decoder, &length) != ma::SUCCESS || !length) {
        return c3d::ASSET_FORMAT_ERROR~;
    }
    float[] pcm = alloc::new_array(self.allocator, float, (sz)(length * mirror.channels));
    ulong total;
    while (total < length) {
        ulong frames_read;
        ma::Result result = ma::decoder_read_pcm_frames(
            decoder: decoder,
            frames_out: &pcm[(usz)total * mirror.channels],
            frame_count: length - total,
            frames_read: &frames_read,
        );
        total += frames_read;
        if (result != ma::SUCCESS || !frames_read) break;
    }
    if (!total) {
        alloc::free(self.allocator, pcm.ptr);
        return c3d::ASSET_FORMAT_ERROR~;
    }
    mirror.pcm = pcm;
    mirror.frame_count = total;
}

fn void AudioState.free_mirror_data(&self, Mirror* mirror) {
    if (mirror.built) self.mirror_count--;
    alloc::free(self.allocator, mirror.pcm.ptr);
    alloc::free(self.allocator, mirror.bytes.ptr);
    *mirror = {};
}

fn uint? AudioState.start(&self, StartParams params, AudioClipId clip) {
    Mirror* mirror = self.ensure_mirror(clip)!;
    uint slot = self.free_voice()!;
    Voice* voice = &self.voices[slot];

    voice.decoded = !mirror.streamed;
    if (voice.init_source(mirror, &self.callbacks) != ma::SUCCESS) return c3d::ASSET_FORMAT_ERROR~;

    uint flags = params.positioned ? 0 : ma::SOUND_FLAG_NO_SPATIALIZATION;
    ma::SoundGroup* group = params.bus == MASTER_BUS ? null : self.group(params.bus);
    ma::Result sound_result = ma::sound_init_from_data_source(
        engine: self.engine,
        data_source: voice.source,
        flags: flags,
        group: group,
        sound: voice.sound,
    );
    if (sound_result != ma::SUCCESS) {
        voice.release_source();
        return c3d::ASSET_FORMAT_ERROR~;
    }
    voice.apply(params);
    ma::sound_set_attenuation_model(voice.sound, ma::AttenuationModel.INVERSE);
    ma::sound_set_rolloff(voice.sound, ROLLOFF);
    ma::sound_set_doppler_factor(voice.sound, NO_DOPPLER);
    (void)ma::sound_start(voice.sound);

    voice.mirror = clip.index;
    voice.owner = params.owner;
    voice.position = params.position;
    voice.positioned = params.positioned;
    voice.active = true;
    self.voice_count++;
    return slot;
}

fn void Voice.apply(&self, StartParams params) {
    ma::sound_set_volume(self.sound, params.volume);
    ma::sound_set_pitch(self.sound, params.pitch);
    ma::sound_set_looping(self.sound, (ma::Bool32)(params.looping ? 1 : 0));
    if (!params.positioned) return;
    ma::sound_set_position(
        sound: self.sound,
        x: params.position.x,
        y: params.position.y,
        z: params.position.z,
    );
    ma::sound_set_min_distance(self.sound, params.min_distance);
    ma::sound_set_max_distance(self.sound, params.max_distance);
}

fn ma::Result Voice.init_source(&self, Mirror* mirror, ma::AllocationCallbacks* callbacks) {
    if (self.decoded) {
        return ma::audio_buffer_init(
            frames: mirror.pcm.ptr,
            frame_count: mirror.frame_count,
            channels: mirror.channels,
            sample_rate: mirror.sample_rate,
            callbacks: callbacks,
            buffer: (ma::AudioBuffer*)self.source,
        );
    }
    return ma::decoder_init_memory(
        bytes: mirror.bytes.ptr,
        length: mirror.bytes.len,
        callbacks: callbacks,
        decoder: (ma::Decoder*)self.source,
    );
}

fn void Voice.release_source(&self) {
    if (self.decoded) {
        ma::audio_buffer_uninit((ma::AudioBuffer*)self.source);
    } else {
        (void)ma::decoder_uninit((ma::Decoder*)self.source);
    }
}

fn uint? AudioState.free_voice(&self) {
    foreach (index, &voice : self.voices) {
        if (!voice.active) return (uint)index;
    }
    return c3d::CAPACITY_EXCEEDED~;
}

fn void AudioState.retire(&self, uint slot) {
    Voice* voice = &self.voices[slot];
    ma::sound_uninit(voice.sound);
    voice.release_source();
    *voice = { .sound = voice.sound, .source = voice.source };
    self.voice_count--;
}

fn void AudioState.retire_mirror_voices(&self, uint mirror) {
    foreach (index, &voice : self.voices) {
        if (voice.active && voice.mirror == mirror) self.retire((uint)index);
    }
}

fn void AudioState.retire_owned(&self, Entity entity) {
    foreach (index, &voice : self.voices) {
        if (voice.active && c3d::same_id(voice.owner, entity)) self.retire((uint)index);
    }
}
