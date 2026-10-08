module audio_example;

import c3d;
import c3d::asset;
import c3d::audio;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::platform;
import c3d::render;
import c3d::scene;
import std::io;
import std::math;

const uint WIDTH @local = 1280;
const uint HEIGHT @local = 720;
const float EAR_HEIGHT @local = 1.6f;
const float ORBIT_RADIUS @local = 4;
const float ORBIT_RADIANS_PER_SECOND @local = 0.8f;
const float MARKER_SIZE @local = 0.4f;
const float VOLUME_STEP @local = 0.25f;
const float MUSIC_DISTANCE @local = 6;
const double STATS_PERIOD_SECONDS @local = 1.0;
const double HEADLESS_DELTA @local = 1.0 / 60;
const uint PUMP_FRAMES @local = 1024; // one mix chunk; a frame at 60 Hz needs 800 at 48 kHz
const uint PUMP_CHANNELS @local = 8;

struct Options @local {
    bool null_device;
    bool headless;
    bool limit_frames;
    uint frames;
}

struct Demo @local {
    AssetStore assets;
    Scene scene;
    AudioSystem audio;
    Node* camera;
    Node* orbiter;
    AudioClipId burst;
    float music_volume;
    float effects_volume;
    float angle;
    double pending_frames;
    double last_print;
}

fn void destroy_demo(Demo* demo) @local {
    scene::destroy_scene(&demo.scene);
    audio::destroy_audio_system(&demo.audio);
    asset::destroy_asset_store(&demo.assets);
}

fn void? init_demo(Demo* demo, Options options) @local {
    *demo = {
        .assets         = asset::create_asset_store(mem, asset::default_asset_store_desc()),
        .music_volume   = 1,
        .effects_volume = 1,
    };
    defer catch asset::destroy_asset_store(&demo.assets);
    audio::register_audio_clips(&demo.assets)!;

    AudioDesc desc = audio::default_audio_desc();
    desc.null_device = options.null_device;
    demo.audio = audio::create_audio_system(mem, &demo.assets, desc)!;
    defer catch audio::destroy_audio_system(&demo.audio);

    demo.scene = scene::create_scene(mem, scene::default_scene_desc());
    defer catch scene::destroy_scene(&demo.scene);
    audio::register_audio(&demo.scene, &demo.audio)!;

    AudioClipId loop = audio::add_audio_clip(&demo.assets, $embed("assets/loop.wav"), key: "audio/loop")!;
    AudioClipId music = audio::add_audio_clip(
        &demo.assets,
        $embed("assets/music.ogg"),
        AudioClipMode.STREAMED,
        "audio/music",
    )!;
    demo.burst = audio::add_audio_clip(&demo.assets, $embed("assets/burst.wav"), key: "audio/burst")!;
    demo.audio.prepare(loop)!;
    demo.audio.prepare(music)!;
    demo.audio.prepare(demo.burst)!;

    demo.camera = demo.scene.add_camera(camera::perspective_deg(60, 0.1f), name: "listener")!;
    demo.camera.local.position = { 0, EAR_HEIGHT, 0 };
    demo.scene.add(demo.camera, (AudioListener){ .active = true });

    GeometryId box;
    @pool() {
        Geometry marker = geometry::box(tmem, MARKER_SIZE, MARKER_SIZE, MARKER_SIZE);
        box = demo.assets.add_geometry(&marker)!;
    };
    MaterialId orange = demo.assets.add_material(material::basic({ .color = { 0.95f, 0.5f, 0.1f, 1 } }))!;
    MaterialId teal = demo.assets.add_material(material::basic({ .color = { 0.1f, 0.7f, 0.7f, 1 } }))!;

    demo.orbiter = demo.scene.add_mesh(box, orange, name: "orbiter")!;
    AudioEmitter orbiting = audio::AUDIO_EMITTER_DEFAULT;
    orbiting.clip = loop;
    orbiting.looping = true;
    orbiting.playing = true;
    demo.scene.add(demo.orbiter, orbiting);

    Node* speaker = demo.scene.add_mesh(box, teal, name: "music")!;
    speaker.local.position = { 0, EAR_HEIGHT, -MUSIC_DISTANCE };
    AudioEmitter background = audio::AUDIO_EMITTER_DEFAULT;
    background.clip = music;
    background.bus = audio::MUSIC_BUS;
    background.looping = true;
    background.playing = true;
    demo.scene.add(speaker, background);
}

fn float next_volume(float volume) @local {
    return volume - VOLUME_STEP <= 0 ? 1 : volume - VOLUME_STEP;
}

fn void handle_keys(Demo* demo, Input* input) @local {
    if (input.keyboard_captured_by_gui) return;
    if (input.key_pressed(platform::Scancode.CODE_1)) {
        (void)demo.audio.play(demo.burst, audio::UI_BUS);
    }
    if (input.key_pressed(platform::Scancode.CODE_2)) {
        (void)demo.audio.play_at(demo.burst, audio::EFFECTS_BUS, demo.orbiter.world_position());
    }
    if (input.key_pressed(platform::Scancode.M)) {
        demo.music_volume = next_volume(demo.music_volume);
        demo.audio.set_bus_volume(audio::MUSIC_BUS, demo.music_volume);
    }
    if (input.key_pressed(platform::Scancode.N)) {
        demo.effects_volume = next_volume(demo.effects_volume);
        demo.audio.set_bus_volume(audio::EFFECTS_BUS, demo.effects_volume);
    }
    if (input.key_pressed(platform::Scancode.S)) {
        AudioEmitter* emitter = demo.scene.get(demo.orbiter, AudioEmitter);
        emitter.playing = !emitter.playing;
    }
}

fn void pump_null_device(Demo* demo, double delta) @local {
    demo.pending_frames += delta * demo.audio.sample_rate;
    float[PUMP_FRAMES * PUMP_CHANNELS] chunk;
    while (demo.pending_frames >= 1) {
        uint frames = math::min((uint)demo.pending_frames, PUMP_FRAMES);
        demo.audio.mix(chunk[:frames * demo.audio.channels]);
        demo.pending_frames -= frames;
    }
}

fn void step_audio(Demo* demo, double delta, double total) @local {
    demo.angle += ORBIT_RADIANS_PER_SECOND * (float)delta;
    demo.orbiter.local.position = {
        ORBIT_RADIUS * math::cos(demo.angle),
        EAR_HEIGHT,
        ORBIT_RADIUS * math::sin(demo.angle),
    };
    demo.scene.update_world();
    demo.audio.update(&demo.scene);
    if (demo.audio.null_device) pump_null_device(demo, delta);
    if (total - demo.last_print >= STATS_PERIOD_SECONDS) {
        demo.last_print = total;
        AudioStats stats = demo.audio.stats();
        io::printfn(
            "voices %d, refused %d, failures %d, listeners %d, mirrors %d",
            stats.voices,
            stats.voices_refused,
            stats.start_failures,
            stats.listeners,
            stats.mirrors,
        );
    }
}

fn void? run_headless(Options options) @local {
    Demo demo;
    init_demo(&demo, options)!;
    defer destroy_demo(&demo);
    double total;
    for (uint frame = 0; frame < options.frames; frame++) {
        total += HEADLESS_DELTA;
        step_audio(&demo, HEADLESS_DELTA, total);
    }
    io::printfn("headless run finished after %d frames", options.frames);
}

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d audio", WIDTH, HEIGHT))!;
    defer platform::destroy_window(&window);
    Demo demo;
    init_demo(&demo, options)!;
    defer destroy_demo(&demo);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &demo.assets,
        desc: { .validation = true, .application_name = "c3d_audio" },
    )!;
    defer render::destroy_renderer(&renderer);

    io::printn("1 flat one-shot, 2 positioned one-shot, M music volume, N effects volume, S toggles the orbiter");
    uint frame;
    while (window.poll()) {
        if (options.limit_frames && frame++ >= options.frames) break;
        if (window.input.key_released(platform::Scancode.ESCAPE)) break;
        handle_keys(&demo, &window.input);
        step_audio(&demo, window.clock.delta, window.clock.total);
        platform::sync_window(&window, &renderer);
        renderer.render(&demo.scene, demo.camera, { .time = window.clock.total, .delta = window.clock.delta })!;
    }
    return renderer.log.check_validation();
}

fn Options? parse_options(String[] args) @local {
    Options options;
    for (usz index = 1; index < args.len; index++) {
        switch (args[index]) {
            case "--null-device": options.null_device = true;
            case "--headless":
                options.null_device = true;
                options.headless = true;
            case "--frames":
                if (index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
                options.frames = args[++index].to_uint()!;
                options.limit_frames = true;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    if (options.headless && !options.limit_frames) return c3d::INVALID_ARGUMENT~;
    return options;
}

<*
 Play a looping emitter that orbits the listener, with one-shots and bus volumes.
*>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        io::eprintfn("Invalid options: %s", excuse);
        io::eprintn("Use [--null-device] [--headless] [--frames count]; --headless needs --frames.");
        return 1;
    }
    Options options = parsed;
    if (catch excuse = (options.headless ? run_headless(options) : run_interactive(options))) {
        io::eprintfn("Audio example failed: %s", excuse);
        return 1;
    }
    return 0;
}
