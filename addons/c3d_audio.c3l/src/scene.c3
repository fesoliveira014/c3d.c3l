module c3d::audio;

import c3d;
import c3d::asset;
import c3d::asset::custom;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import ma;
import std::math;

<*
 Sound that follows its node.
*>
struct AudioEmitter {
    AudioClipId clip;
    BusId       bus;
    float       volume;       // linear gain
    float       pitch;        // playback rate multiplier
    float       min_distance; // metres at full volume
    float       max_distance; // metres where attenuation stops
    bool        looping;
    bool        playing;      // the system clears it when a non-looping sound ends
}

<*
 Default emitter on the effects bus.
*>
const AudioEmitter AUDIO_EMITTER_DEFAULT = {
    .bus          = EFFECTS_BUS,
    .volume       = 1,
    .pitch        = 1,
    .min_distance = 1,
    .max_distance = 100,
};

<*
 Node the mixer hears from; forward is -Z, up is +Y.
*>
struct AudioListener {
    bool active;
}

enum LinkState : char @private {
    IDLE,
    PLAYING,
    FAILED,
}

struct AudioVoiceLink @private {
    uint        voice;
    AudioClipId clip;
    BusId       bus;
    LinkState   state;
}

const Vec3 FORWARD @private = { 0, 0, -1 };

<*
 Register the emitter and listener components with remove hooks bound to the system; one scene per system.
 @param [&inout] scene : "No audio registration has occurred in this scene."
 @param [&inout] system : "Outlives the scene; no scene registered yet."
 @return? c3d::CAPACITY_EXCEEDED
 @require system.state.scene_identity == 0
*>
fn void? register_audio(Scene* scene, AudioSystem* system) {
    scene.register(AudioEmitter)!;
    scene.register(AudioListener)!;
    scene.register(AudioVoiceLink)!;
    scene.set_remove_hook(AudioEmitter, &remove_emitter, system.state);
    system.state.scene_identity = scene.identity;
}

<*
 Copy listener and emitter state into the mixer and retire finished voices.
 May block briefly while a retired voice leaves the audio thread.
 @param [&inout] scene : "The registered scene, if any; world matrices are current."
 @require !self.state.scene_identity || self.state.scene_identity == scene.identity
*>
fn void AudioSystem.update(&self, Scene* scene) {
    AudioState* state = self.state;
    state.update_listener(scene);
    state.retire_ended(scene);
    state.retire_stale_mirrors(scene);
    scene.@each(AudioEmitter; entity, emitter) {
        state.update_emitter(scene, entity, emitter);
    };
    remove_orphan_links(scene);
}

fn void remove_emitter(Entity entity, void* component, void* user) @private {
    AudioState* state = user;
    state.retire_owned(entity);
}

fn void AudioState.update_listener(&self, Scene* scene) {
    uint active;
    Vec3 position;
    Vec3 forward = FORWARD;
    scene.@each(AudioListener; entity, listener) {
        if (listener.active) {
            if (!active) {
                Mat4 world = scene.node(entity).world;
                position = maths::translation(world);
                forward = maths::transform_dir(world, FORWARD);
            }
            active++;
        }
    };
    self.listeners = active;
    ma::engine_listener_set_position(
        engine: self.engine,
        listener_index: 0,
        x: position.x,
        y: position.y,
        z: position.z,
    );
    ma::engine_listener_set_direction(
        engine: self.engine,
        listener_index: 0,
        x: forward.x,
        y: forward.y,
        z: forward.z,
    );
}

fn void AudioState.retire_ended(&self, Scene* scene) {
    foreach (index, &voice : self.voices) {
        if (!voice.active || !ma::sound_at_end(voice.sound)) continue;
        Entity owner = voice.owner;
        self.retire((uint)index);
        end_owned_playback(scene, owner);
    }
}

fn void AudioState.retire_stale_mirrors(&self, Scene* scene) {
    CustomPool{AudioClip}* pool = self.assets.pool(AudioClip);
    foreach (index, &mirror : self.mirrors) {
        if (!mirror.built) continue;
        bool current = pool.is_live(mirror.clip) && pool.get(mirror.clip).header.revision == mirror.revision;
        if (current) continue;
        foreach (slot, &voice : self.voices) {
            if (!voice.active || voice.mirror != index) continue;
            Entity owner = voice.owner;
            self.retire((uint)slot);
            end_owned_playback(scene, owner);
        }
        self.free_mirror_data(mirror);
    }
}

fn void end_owned_playback(Scene* scene, Entity owner) @private {
    if (!owner.generation) return;
    AudioEmitter* emitter = scene.world.get(owner, AudioEmitter);
    if (emitter && !emitter.looping) emitter.playing = false;
}

fn uint AudioState.linked_voice(&self, AudioVoiceLink* link, Entity entity) {
    if (link.voice >= self.voices.len) return NO_VOICE;
    Voice* voice = &self.voices[link.voice];
    return voice.active && c3d::same_id(voice.owner, entity) ? link.voice : NO_VOICE;
}

fn void AudioState.update_emitter(&self, Scene* scene, Entity entity, AudioEmitter* emitter) {
    AudioVoiceLink* link = scene.world.get(entity, AudioVoiceLink);
    if (!link) {
        if (!emitter.playing) return;
        link = scene.world.add(entity, (AudioVoiceLink){ .voice = NO_VOICE });
    }
    uint voice = self.linked_voice(link, entity);
    if (!emitter.playing) {
        if (voice != NO_VOICE) self.retire(voice);
        *link = { .voice = NO_VOICE };
        return;
    }
    bool changed = link.state != LinkState.IDLE
        && (!c3d::same_id(link.clip, emitter.clip) || link.bus != emitter.bus);
    if (changed) {
        if (voice != NO_VOICE) self.retire(voice);
        *link = { .voice = NO_VOICE };
    }
    switch (link.state) {
        case FAILED:
            return;
        case PLAYING:
            if (voice == NO_VOICE) {
                if (!emitter.looping) {
                    emitter.playing = false;
                    *link = { .voice = NO_VOICE };
                    return;
                }
                self.start_emitter(scene, entity, emitter, link);
                return;
            }
            self.voices[voice].apply(emitter_params(scene, entity, emitter));
        case IDLE:
            self.start_emitter(scene, entity, emitter, link);
    }
}

fn void AudioState.start_emitter(
    &self,
    Scene* scene,
    Entity entity,
    AudioEmitter* emitter,
    AudioVoiceLink* link,
) {
    StartParams params = emitter_params(scene, entity, emitter);
    params.owner = entity;
    link.clip = emitter.clip;
    link.bus = emitter.bus;
    uint? slot = self.start(params, emitter.clip);
    if (catch excuse = slot) {
        link.state = LinkState.FAILED;
        link.voice = NO_VOICE;
        if (excuse == c3d::CAPACITY_EXCEEDED) {
            self.voices_refused++;
        } else {
            self.start_failures++;
        }
        return;
    }
    link.state = LinkState.PLAYING;
    link.voice = slot;
}

fn StartParams emitter_params(Scene* scene, Entity entity, AudioEmitter* emitter) @private {
    return {
        .bus          = emitter.bus,
        .volume       = emitter.volume,
        .pitch        = emitter.pitch,
        .positioned   = true,
        .position     = scene.node(entity).world_position(),
        .min_distance = emitter.min_distance,
        .max_distance = emitter.max_distance,
        .looping      = emitter.looping,
    };
}

fn void remove_orphan_links(Scene* scene) @private {
    while (true) {
        Entity orphan;
        scene.@each(AudioVoiceLink; entity, link) {
            if (!scene.world.has(entity, AudioEmitter)) orphan = entity;
        };
        if (!orphan.generation) return;
        scene.remove_component(scene.node(orphan), AudioVoiceLink);
    }
}
