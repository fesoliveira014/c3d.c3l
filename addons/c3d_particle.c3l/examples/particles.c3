module particle_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::particle;
import c3d::platform;
import c3d::render @public;
import c3d::scene;
import gpu;
import imgui;
import std::io;
import std::io::file;
import std::math;
import std::time;
import std::time::clock;

const uint WIDTH @local = 1920;
const uint HEIGHT @local = 1080;
const uint SPRITE_SIZE @local = 64;
const uint SMOKE_CAPACITY @local = 8192; // about 1 MiB of simulation and scene draw data
const uint SPARK_CAPACITY @local = 4096;
const uint DEBRIS_CAPACITY @local = 1024;
const uint DEFAULT_BENCHMARK_FRAMES @local = 300;
const uint WARMUP_FRAMES @local = 60; // warm pipelines, uploads and delayed timestamp readback
const uint PREWARM_STEPS @local = 1200; // twenty simulated seconds mix the ages before steady-state measurements
const float STEP_SECONDS @local = 1.0f / 60;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const uint SPRITE_CHANNELS @local = 4;
const ZString[3] EFFECT_NAMES @local = { "Smoke", "Sparks", "Debris" };

struct Options @local {
    bool benchmark;
    bool limit_frames;
    uint frames;
    String capture_rgba;
}

struct Demo @local {
    AssetStore assets;
    Scene scene;
    Node*[3] emitters;
    Node*[2] cameras;
    MaterialId smoke;
    MaterialId sparks;
    ParticleMaterialParams smoke_params;
    ParticleMaterialParams spark_params;
}

struct Metrics @local {
    double update_ms;
    double frame_ms;
    double[3] alive;
    double gpu_sort_ms;
    double gpu_transparent_ms;
    uint gpu_samples;
    bool sorted;
    bool transparent;
}

fn double elapsed_ms(time::Clock started) @local {
    return (double)(long)started.to_now() / NANOSECONDS_PER_MILLISECOND;
}

fn TextureId? add_sprite(AssetStore* assets) @local {
    char[SPRITE_SIZE * SPRITE_SIZE * SPRITE_CHANNELS] pixels;
    for (uint y = 0; y < SPRITE_SIZE; y++) {
        for (uint x = 0; x < SPRITE_SIZE; x++) {
            float horizontal = 2 * ((float)x + 0.5f) / SPRITE_SIZE - 1;
            float vertical = 2 * ((float)y + 0.5f) / SPRITE_SIZE - 1;
            float coverage = math::max(0.0f, 1 - horizontal * horizontal - vertical * vertical);
            uint offset = (y * SPRITE_SIZE + x) * SPRITE_CHANNELS;
            pixels[offset] = pixels[offset + 1] = pixels[offset + 2] = char::max;
            pixels[offset + 3] = (char)(coverage * coverage * char::max);
        }
    }
    return assets.add_texture(
        material::texture_2d_desc(SPRITE_SIZE, SPRITE_SIZE, PixelFormat.RGBA8_UNORM),
        pixels[..],
    );
}

fn void destroy_demo(Demo* demo) @local {
    scene::destroy_scene(&demo.scene);
    asset::destroy_asset_store(&demo.assets);
}

fn Demo? create_demo() @local {
    Demo demo = {
        .assets = asset::create_asset_store(mem, asset::default_asset_store_desc()),
        .scene = scene::create_scene(mem, { .max_nodes = 32 }),
    };
    defer catch destroy_demo(&demo);
    particle::register_particles(&demo.scene)!;
    demo.scene.background.color = { 0.018f, 0.025f, 0.04f, 1 };
    demo.scene.ambient_color = { 1, 1, 1 };
    demo.scene.ambient_intensity = 0.45f;
    ShaderId shader = particle::add_particle_shader(&demo.assets)!;
    TextureId sprite = add_sprite(&demo.assets)!;
    demo.smoke_params = { .color = { 0.8f, 0.86f, 0.95f, 1 }, .soft_distance = 0.5f, .lighting = AMBIENT };
    demo.spark_params = { .color = { 1, 0.6f, 0.1f, 1 }, .soft_distance = 0.08f };
    demo.smoke = particle::add_particle_material(
        assets: &demo.assets,
        shader: shader,
        params: demo.smoke_params,
        map: material::texture_slot(sprite),
    )!;
    demo.sparks = particle::add_particle_material(
        assets: &demo.assets,
        shader: shader,
        params: demo.spark_params,
        map: material::texture_slot(sprite),
        blend: BlendMode.ADDITIVE,
    )!;
    GeometryId box;
    GeometryId floor;
    @pool() {
        Geometry cube = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        box = demo.assets.add_geometry(&cube)!;
        Geometry plane = geometry::plane(tmem, 30, 30);
        floor = demo.assets.add_geometry(&plane)!;
    };
    MaterialId ground_material = demo.assets.add_material(material::basic({ .color = { 0.08f, 0.11f, 0.15f, 1 } }))!;
    Node* ground = demo.scene.add_mesh(floor, ground_material)!;
    demo.scene.get(ground, Mesh).cast_shadow = false;
    StandardParams surface = material::STANDARD_PARAMS_DEFAULT;
    surface.base_color = { 0.7f, 0.75f, 0.85f, 1 };
    surface.metallic = 0;
    surface.roughness = 0.7f;
    MaterialId debris_material = demo.assets.add_material(material::standard(surface))!;
    Node* sun = demo.scene.add_light(light::directional({ 1, 0.9f, 0.8f }, 2, false))!;
    sun.local.rotation = maths::look_rotation({ -0.5f, -1, -0.3f }, { 0, 1, 0 });

    ParticleSystemDesc smoke = particle::default_particle_system_desc();
    smoke.capacity = SMOKE_CAPACITY;
    smoke.material = demo.smoke;
    smoke.shape = CONE;
    smoke.radius = 0.3f;
    smoke.cone_angle = 0.25f;
    smoke.rate = 1400;
    smoke.lifetime = { .min = 5, .max = 7 };
    smoke.speed = { .min = 0.8f, .max = 1.5f };
    smoke.size = { .min = 0.18f, .max = 0.35f };
    smoke.rotation = { .min = -(float)math::PI, .max = (float)math::PI };
    smoke.spin = { .min = -0.2f, .max = 0.2f };
    smoke.color_min = { 0.6f, 0.6f, 0.6f, 0.04f };
    smoke.color_max = { 1, 1, 1, 0.09f };
    smoke.drag = 0.1f;
    smoke.gravity_scale = -0.03f;
    smoke.size_over_life.values = { 0.5f, 1, 1.5f, 2.2f, 3, 4, 5, 6 };
    float[8] opacity = { 0, 0.7f, 1, 1, 0.9f, 0.6f, 0.3f, 0 };
    foreach (index, alpha : opacity) smoke.color_over_life.values[index] = { 1, 1, 1, alpha };
    demo.emitters[0] = demo.scene.add_particle_system(smoke, name: "smoke")!;
    demo.emitters[0].local.position = { -3, 0.15f, 0 };

    ParticleSystemDesc sparks = particle::default_particle_system_desc();
    sparks.capacity = SPARK_CAPACITY;
    sparks.seed = 2;
    sparks.material = demo.sparks;
    sparks.render_mode = STRETCHED;
    sparks.shape = CONE;
    sparks.radius = 0.15f;
    sparks.cone_angle = 0.4f;
    sparks.rate = 3200;
    sparks.lifetime = { .min = 1, .max = 1.6f };
    sparks.speed = { .min = 5, .max = 8 };
    sparks.size = { .min = 0.025f, .max = 0.05f };
    sparks.gravity_scale = 1;
    sparks.drag = 0.1f;
    sparks.stretch = 0.055f;
    sparks.color_min = { 1, 0.5f, 0.2f, 0.3f };
    sparks.color_max = { 1, 1, 0.6f, 0.7f };
    foreach (index, alpha : opacity) sparks.color_over_life.values[index] = { 1, 1, 1, 1 - (float)index / 7 };
    demo.emitters[1] = demo.scene.add_particle_system(sparks, name: "sparks")!;
    demo.emitters[1].local.position = { 0, 0.2f, 0 };

    ParticleSystemDesc debris = particle::default_particle_system_desc();
    debris.capacity = DEBRIS_CAPACITY;
    debris.seed = 3;
    debris.render_mode = MESH;
    debris.material = debris_material;
    debris.geometry = box;
    debris.shape = CONE;
    debris.radius = 0.2f;
    debris.cone_angle = 0.5f;
    debris.rate = 450;
    debris.lifetime = { .min = 2, .max = 3 };
    debris.speed = { .min = 4, .max = 7 };
    debris.size = { .min = 0.06f, .max = 0.15f };
    debris.rotation = { .min = -(float)math::PI, .max = (float)math::PI };
    debris.spin = { .min = -4, .max = 4 };
    debris.gravity_scale = 1;
    debris.size_over_life.values = { 1, 1, 1, 1, 1, 0.8f, 0.4f, 0 };
    demo.emitters[2] = demo.scene.add_particle_system(debris, name: "debris")!;
    demo.emitters[2].local.position = { 3, 0.2f, 0 };

    demo.cameras[0] = demo.scene.add_camera(camera::perspective_deg(55, 0.1f, 100))!;
    demo.cameras[1] = demo.scene.add_camera(camera::perspective_deg(55, 0.1f, 100))!;
    demo.cameras[0].local.position = { 10, 7, 17 };
    demo.cameras[1].local.position = { -14, 6, 6 };
    demo.scene.update_world();
    foreach (camera : demo.cameras) camera.look_at({ 0, 3, 0 });
    demo.scene.update_world();
    return demo;
}

fn void set_emission(Demo* demo, bool active) @local {
    foreach (emitter : demo.emitters) {
        ParticleSystem* system = demo.scene.get(emitter, ParticleSystem);
        system.emitting = active;
    }
}

fn void? check_validation(Renderer* renderer) @local {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        if (entry.category.backend && entry.category.validation && entry.severity == gpu::DebugMessageSeverity.ERROR) {
            return gpu::BACKEND_ERROR~;
        }
    }
}

fn void report_metrics(String segment, Metrics totals, uint frames) @local {
    io::printfn("%s,update_ms,%.6f", segment, totals.update_ms / frames);
    io::printfn("%s,frame_cpu_ms,%.6f", segment, totals.frame_ms / frames);
    io::printfn("%s,alive_smoke,%.1f", segment, totals.alive[0] / frames);
    io::printfn("%s,alive_sparks,%.1f", segment, totals.alive[1] / frames);
    io::printfn("%s,alive_debris,%.1f", segment, totals.alive[2] / frames);
    io::printfn("%s,gpu_samples,%d", segment, totals.gpu_samples);
    if (totals.gpu_samples) {
        if (totals.sorted) {
            io::printfn("%s,gpu_sort_ms,%.6f", segment, totals.gpu_sort_ms / totals.gpu_samples);
        } else {
            io::printfn("%s,gpu_sort_ms,not_recorded", segment);
        }
        if (totals.transparent) {
            io::printfn("%s,gpu_transparent_ms,%.6f", segment, totals.gpu_transparent_ms / totals.gpu_samples);
        } else {
            io::printfn("%s,gpu_transparent_ms,not_recorded", segment);
        }
    } else {
        io::printfn("%s,gpu_sort_ms,unavailable", segment);
        io::printfn("%s,gpu_transparent_ms,unavailable", segment);
    }
}

fn void? run_benchmark(Options options) @local {
    Demo demo = create_demo()!;
    defer destroy_demo(&demo);
    Renderer renderer = render::create_renderer(mem, &demo.assets, { .validation = true, .gpu_timings = true })!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc: render::render_target_desc(WIDTH, HEIGHT, PixelFormat.RGBA8_SRGB),
    )!;
    ViewDesc desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = render::create_view(&renderer, desc)!;
    gpu::DeviceDesc device_desc;
    gpu::Adapter adapter = render::select_adapter(&renderer.runtime, &device_desc)!;
    gpu::AdapterInfo adapter_info = gpu::get_adapter_info(&adapter)!;
    io::printfn("adapter,%s", adapter_info.name);
    io::printfn("resolution,%dx%d", WIDTH, HEIGHT);
    io::printfn("frames,%d", options.frames);
    io::printn("validation,on");
    io::printn("execution,inline");
    for (uint segment = 0; segment < 2; segment++) {
        set_emission(&demo, segment != 0);
        if (segment) {
            for (uint step = 0; step < PREWARM_STEPS; step++) {
                particle::update(&demo.scene, STEP_SECONDS, { 0.4f, 0, 0 });
            }
        }
        Metrics totals;
        ulong first_measured = renderer.frame_index + WARMUP_FRAMES;
        ulong last_measured = first_measured + options.frames;
        ulong last_gpu_frame = ulong::max;
        ulong total_frames = (ulong)WARMUP_FRAMES + options.frames + render::FRAMES_IN_FLIGHT + 1;
        for (ulong frame = 0; frame < total_frames; frame++) {
            time::Clock frame_start = clock::now();
            demo.scene.update_world();
            time::Clock update_start = clock::now();
            particle::update(&demo.scene, STEP_SECONDS, { 0.4f, 0, 0 });
            double update_ms = elapsed_ms(update_start);
            renderer.begin_frame({ .time = (double)renderer.frame_index * STEP_SECONDS, .delta = STEP_SECONDS })!;
            defer catch render::abort_frame(&renderer);
            renderer.render_view(&demo.scene, demo.cameras[0], view)!;
            renderer.finish_view(view)!;
            renderer.end_frame()!;
            if (frame >= WARMUP_FRAMES && frame < (ulong)WARMUP_FRAMES + options.frames) {
                totals.update_ms += update_ms;
                totals.frame_ms += elapsed_ms(frame_start);
                foreach (index, emitter : demo.emitters) {
                    totals.alive[index] += demo.scene.get(emitter, ParticleSystem).alive;
                }
            }
            Stats* stats = &renderer.stats;
            if (stats.gpu_timing_state == GpuTimingState.READY && stats.gpu_frame_index != last_gpu_frame
                && stats.gpu_frame_index >= first_measured && stats.gpu_frame_index < last_measured) {
                totals.gpu_samples++;
                totals.gpu_sort_ms += stats.gpu_pass_ms[Pass.INSTANCE_SORT.ordinal];
                totals.gpu_transparent_ms += stats.gpu_pass_ms[Pass.FORWARD_TRANSPARENT.ordinal];
                totals.sorted = totals.sorted || stats.gpu_pass_valid[Pass.INSTANCE_SORT.ordinal];
                totals.transparent = totals.transparent || stats.gpu_pass_valid[Pass.FORWARD_TRANSPARENT.ordinal];
                last_gpu_frame = stats.gpu_frame_index;
            }
        }
        report_metrics(segment ? "active" : "empty", totals, options.frames);
    }
    if (options.capture_rgba.len) {
        char[] pixels = mem::new_array(char, WIDTH * HEIGHT * SPRITE_CHANNELS);
        defer free(pixels);
        renderer.read_render_target(target, pixels)!;
        file::save(options.capture_rgba, pixels)!;
    }
    return check_validation(&renderer);
}

fn void? configure_split(Renderer* renderer, ViewId second, bool split) @local {
    if (!renderer.output_width || !renderer.output_height) return;
    uint width = math::max(renderer.output_width, 1u);
    uint height = math::max(renderer.output_height, 1u);
    ViewDesc first = render::default_view_desc();
    first.post.anti_aliasing = AntiAliasing.NONE;
    first.viewport = { .width = split ? math::max(width / 2, 1u) : width, .height = height };
    render::configure_view(renderer, renderer.default_view, first)!;
    ViewDesc next = render::default_view_desc();
    next.post.anti_aliasing = AntiAliasing.NONE;
    next.viewport = { .x = width / 2, .width = width - width / 2, .height = height };
    return render::configure_view(renderer, second, next);
}

fn void? controls(
    Demo* demo,
    bool* split,
    float* wind,
    double update_ms,
) @local {
    if (imgui::begin("Particles", null, {})) {
        imgui::text("CPU update: %.3f ms", update_ms);
        imgui::checkbox("Second camera", split);
        imgui::slider_float(
            label: "Wind",
            v: wind,
            v_min: -2,
            v_max: 2,
        );
        foreach (index, emitter : demo.emitters) {
            ParticleSystem* system = demo.scene.get(emitter, ParticleSystem);
            imgui::push_id_int((int)index);
            imgui::text("%s", EFFECT_NAMES[index]);
            imgui::checkbox("Emitting", &system.emitting);
            if (imgui::button("Burst")) system.emit_burst(128);
            imgui::text("Alive: %u", system.alive);
            imgui::text("Dropped: %llu", system.dropped);
            imgui::pop_id();
        }
        bool ambient = demo.smoke_params.lighting == ParticleLighting.AMBIENT;
        bool material_changed = imgui::checkbox("Ambient smoke", &ambient);
        material_changed |= imgui::slider_float(
            label: "Soft distance",
            v: &demo.smoke_params.soft_distance,
            v_min: 0,
            v_max: 1,
        );
        demo.smoke_params.lighting = ambient ? ParticleLighting.AMBIENT : ParticleLighting.UNLIT;
        if (material_changed) demo.assets.@set_custom_params(demo.smoke, demo.smoke_params)!;
        Material* sparks = &demo.assets.material(demo.sparks).data;
        bool additive = sparks.common.blend_mode == BlendMode.ADDITIVE;
        if (imgui::checkbox("Additive sparks", &additive)) {
            sparks.common.blend_mode = additive ? BlendMode.ADDITIVE : BlendMode.PREMULTIPLIED_ALPHA;
            demo.assets.mark_material_dirty(demo.sparks);
        }
    }
    imgui::end();
}

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d particles", WIDTH, HEIGHT))!;
    defer platform::destroy_window(&window);
    Demo demo = create_demo()!;
    defer destroy_demo(&demo);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &demo.assets,
        desc: { .validation = true, .gpu_timings = true },
    )!;
    defer render::destroy_renderer(&renderer);
    ViewId second = render::create_view(&renderer, render::default_view_desc())!;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    set_emission(&demo, true);
    bool split = true;
    bool previous_split;
    uint previous_width;
    uint previous_height;
    float wind = 0.4f;
    double update_ms;
    double elapsed;
    uint frame;
    while (window.poll()) {
        if (options.limit_frames && frame++ >= options.frames) break;
        if (window.input.key_released(platform::Scancode.ESCAPE) && !window.input.keyboard_captured_by_gui) break;
        @pool() {
            gui_renderer.new_frame();
            defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
            controls(
                demo: &demo,
                split: &split,
                wind: &wind,
                update_ms: update_ms,
            )!;
            gui_renderer.finish_frame();
            platform::sync_window(&window, &renderer);
            if (renderer.output_width != previous_width || renderer.output_height != previous_height
                || split != previous_split) {
                configure_split(&renderer, second, split)!;
                previous_split = split;
                previous_width = renderer.output_width;
                previous_height = renderer.output_height;
            }
            demo.scene.update_world();
            time::Clock started = clock::now();
            particle::update(&demo.scene, window.clock.delta, { wind, 0, 0 });
            update_ms = elapsed_ms(started);
            elapsed += window.clock.delta;
            renderer.begin_frame({ .time = elapsed, .delta = window.clock.delta })!;
            defer catch render::abort_frame(&renderer);
            if (renderer.has_output) {
                renderer.render_view(&demo.scene, demo.cameras[0], renderer.default_view)!;
                renderer.finish_view(renderer.default_view)!;
                if (split) {
                    renderer.render_view(&demo.scene, demo.cameras[1], second)!;
                    renderer.finish_view(second)!;
                }
                OverlayContext overlay = renderer.begin_overlay()!;
                gui_renderer.record(&overlay)!;
                renderer.end_overlay(&overlay)!;
            }
            renderer.end_frame()!;
        };
    }
    return check_validation(&renderer);
}

fn String? option_value(String[] args, usz* index) @local {
    if (*index + 1 >= args.len) return c3d::INVALID_ARGUMENT~;
    (*index)++;
    return args[*index];
}

fn Options? parse_options(String[] args) @local {
    Options options = { .frames = DEFAULT_BENCHMARK_FRAMES };
    for (usz index = 1; index < args.len; index++) {
        switch (args[index]) {
            case "--benchmark": options.benchmark = true;
            case "--frames":
                options.frames = option_value(args, &index)!.to_uint()!;
                options.limit_frames = true;
            case "--capture-rgba": options.capture_rgba = option_value(args, &index)!;
            default: return c3d::INVALID_ARGUMENT~;
        }
    }
    if (!options.frames || (options.capture_rgba.len && !options.benchmark)) return c3d::INVALID_ARGUMENT~;
    return options;
}

<*
 Display smoke, sparks and debris or measure their rendering.
*>
fn int main(String[] args) {
    Options? parsed = parse_options(args);
    if (catch excuse = parsed) {
        io::eprintfn("Invalid options: %s", excuse);
        io::eprintn("Use [--benchmark] [--frames count] [--capture-rgba path].");
        return 1;
    }
    Options options = parsed;
    if (catch excuse = (options.benchmark ? run_benchmark(options) : run_interactive(options))) {
        io::eprintfn("Particles failed: %s", excuse);
        return 1;
    }
    return 0;
}
