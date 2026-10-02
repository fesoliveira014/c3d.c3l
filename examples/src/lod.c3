module lod_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::profile;
import c3d::render;
import c3d::scene;
import gpu;
import imgui;
import std::io;
import std::math;

const uint PLACEMENT_COUNT @local = 5000; // 100 columns by 50 rows; shared by every part and level
const uint FIELD_COLUMNS @local = 100;
const float FIELD_SPACING @local = 3;
const uint OUTPUT_WIDTH @local = 1280;
const uint OUTPUT_HEIGHT @local = 720;
const uint WARMUP_FRAMES @local = 30; // excludes pipeline creation and initial history from measurements
const uint MEASURED_FRAMES @local = 60;
const uint FRAME_DELAY @local = render::FRAMES_IN_FLIGHT + 1; // drains every measured GPU submission
const uint RUN_FRAMES @local = WARMUP_FRAMES + MEASURED_FRAMES + FRAME_DELAY;
const float BASE_BIAS @local = 20; // all five thousand placements exceed the finest threshold
const double NANOSECONDS_PER_MILLISECOND @local = 1000000;
const String[3] WAYPOINT_NAMES @local = { "near", "middle", "far" };
const Vec3[3] WAYPOINTS @local = { { 0, 5, 8 }, { 0, 40, 90 }, { 0, 140, 280 } };
const Vec3[3] LOOK_AT @local = { { 0, 2, -25 }, { 0, 1, -75 }, { 0, 1, -75 } };

struct Field @local {
    Node* group;
    Node* camera;
    uint[3] triangles;
}

struct Sample @local {
    float cpu_record_ms;
    double extract_ms;
    double gpu_ms;
    double cull_ms;
    uint draws;
    uint direct_triangles;
    uint[3] selected;
    uint[3] visible;
    uint fallbacks;
    bool counts_ready;
    bool timings_ready;
}

struct Controls @local {
    uint waypoint;
    float bias;
    bool forced_base;
}

fn void set_waypoint(Node* camera, uint waypoint) @local {
    camera.local.position = WAYPOINTS[waypoint];
    camera.local.rotation = maths::look_rotation((LOOK_AT[waypoint] - WAYPOINTS[waypoint]).normalize(), { 0, 1, 0 });
}

fn Field? build_field(AssetStore* assets, Scene* scene) @local {
    Field field;
    @pool() {
        Geometry[5] geometry = {
            geometry::cylinder(
                allocator: tmem,
                radius_top: 0.1f,
                radius_bottom: 0.15f,
                height: 2,
                slices: 24,
            ),
            geometry::sphere(
                allocator: tmem,
                radius: 1.2f,
                slices: 24,
                stacks: 12,
            ),
            geometry::cylinder(
                allocator: tmem,
                radius_top: 0.1f,
                radius_bottom: 0.15f,
                height: 2,
                slices: 6,
            ),
            geometry::cone(
                allocator: tmem,
                radius: 1.2f,
                height: 3.3f,
                slices: 10,
            ),
            geometry::cone(
                allocator: tmem,
                radius: 1.2f,
                height: 4.38f,
                slices: 4,
            ),
        };
        GeometryId[5] ids;
        foreach (index, &mesh : geometry) ids[index] = assets.add_geometry(mesh)!;
        field.triangles = {
            (uint)(geometry[0].indices.len + geometry[1].indices.len) / 3,
            (uint)(geometry[2].indices.len + geometry[3].indices.len) / 3,
            (uint)geometry[4].indices.len / 3,
        };
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.metallic = 0;
        params.roughness = 0.85f;
        params.base_color = { 0.22f, 0.11f, 0.045f, 1 };
        MaterialId bark = assets.add_material(material::standard(params))!;
        params.base_color = { 0.1f, 0.38f, 0.16f, 1 };
        MaterialId leaves = assets.add_material(material::standard(params))!;
        LodLevel[3] levels = {
            { .first_part = 0, .part_count = 2, .min_screen_size = 0.09f },
            { .first_part = 2, .part_count = 2, .min_screen_size = 0.035f },
            { .first_part = 4, .part_count = 1, .min_screen_size = 0 },
        };
        LodPart[5] parts;
        foreach (index, &part : parts) {
            Transform local = maths::TRANSFORM_IDENTITY;
            local.position.y = index == 0 || index == 2 ? 1 : index == 4 ? 2.19f : 2.7f;
            if (index == 1) local.scale.y = 1.4f;
            *part = { .geometry = ids[index], .material = index == 0 || index == 2 ? bark : leaves, .local = local.to_mat4() };
        }
        field.group = scene.add_instanced_lod_group(
            assets: assets,
            desc: { .levels = levels[..], .parts = parts[..] },
            capacity: PLACEMENT_COUNT,
            name: "trees",
        )!;
        scene.resize_lod_instances(field.group, PLACEMENT_COUNT)!;
        LodGroupState* state = scene.get(field.group, LodGroup).state;
        foreach (uint index, &transform : state.transforms) {
            uint hash = (uint)((ulong)index * 1664525 + 1013904223);
            float jitter = (float)(hash & 1023) / 1023;
            transform.position = {
                ((float)(index % FIELD_COLUMNS) - 49.5f) * FIELD_SPACING + jitter * 0.5f,
                0,
                -(float)(index / FIELD_COLUMNS) * FIELD_SPACING - jitter * 0.5f,
            };
            transform.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, jitter * (float)math::TWO_PI);
            if (index % 17 == 0) transform.scale.x = -1;
            state.colors[index] = { 0.8f + 0.2f * jitter, 0.9f + 0.1f * jitter, 0.75f + 0.25f * jitter, 1 };
        }
        scene.mark_lod_instances_dirty(field.group);
        scene.set_lod_effects(field.group, {
            .sway = { .direction = { 1, 0, 0.3f }, .amplitude = 0.18f, .frequency = 0.5f,
                .lean = 0.25f, .wavelength = 12, .variation = 0.25f, .weight = SwayWeight.HEIGHT },
            .cast_shadow = true,
            .receive_shadow = true,
        });
        Geometry ground = geometry::plane(tmem, 330, 190);
        GeometryId ground_id = assets.add_geometry(&ground)!;
        params.base_color = { 0.3f, 0.32f, 0.25f, 1 };
        MaterialId ground_material = assets.add_material(material::standard(params))!;
        Node* ground_node = scene.add_mesh(ground_id, ground_material, name: "ground")!;
        ground_node.local.position = { 0, -0.01f, -75 };
    };
    Light sunlight = light::directional({ 1, 0.97f, 0.9f }, 3);
    sunlight.shadow.cascades = 3;
    sunlight.shadow.max_distance = 500;
    Node* sun = scene.add_light(sunlight, name: "sun")!;
    sun.local.rotation = maths::look_rotation((Vec3){ -0.4f, -1, -0.5f }.normalize(), { 0, 1, 0 });
    scene.ambient_intensity = 0.25f;
    scene.background.color = { 0.16f, 0.23f, 0.32f, 1 };
    field.camera = scene.add_camera(camera::perspective_deg(55, 0.1f, 1000), name: "camera")!;
    set_waypoint(field.camera, 0);
    scene.update_world();
    return field;
}

fn ViewDesc view_desc(RenderTargetId target, Controls controls, bool window) @local {
    ViewDesc desc = window ? render::default_view_desc() : render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    desc.lod_bias = controls.forced_base ? BASE_BIAS : controls.bias;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    return desc;
}

fn void? draw_frame(
    Renderer* renderer,
    Scene* scene,
    Node* camera,
    ViewId view,
    GuiRenderer* gui_renderer = null,
    double time = 1,
) @local {
    renderer.begin_frame({ .time = time, .delta = 0 })!;
    defer catch render::abort_frame(renderer);
    if (gui_renderer && !renderer.has_output) return renderer.end_frame();
    renderer.render_view(scene, camera, view)!;
    renderer.finish_view(view)!;
    if (gui_renderer) {
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    renderer.end_frame()!;
}

fn bool validation_clean(Renderer* renderer) @local {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = renderer.log.recent(entries[..]);
    bool clean = true;
    foreach (entry : entries[:count]) {
        if (entry.category.backend && entry.category.validation) {
            clean = false;
            io::eprintfn("Validation message: %s", (ZString)&entry.text);
        }
    }
    return clean;
}

fn void? measure_waypoint(
    Renderer* renderer,
    Scene* scene,
    Field* field,
    ViewId view,
    profile::Recorder* recorder,
    Controls controls,
    Sample[] samples,
) @local {
    foreach (&sample : samples) *sample = {};
    ulong first = renderer.frame_index;
    for (uint frame = 0; frame < RUN_FRAMES; frame++) {
        ulong current = renderer.frame_index;
        profile::@capture(recorder, current) {
            draw_frame(
                renderer: renderer,
                scene: scene,
                camera: field.camera,
                view: view,
            )!;
        };
        samples[frame].cpu_record_ms = renderer.stats.cpu_record_ms;
        samples[frame].draws = renderer.stats.draws;
        samples[frame].direct_triangles = renderer.stats.triangles;
        profile::FrameCaptureView captured = recorder.frame(current)!;
        foreach (scope : captured.cpu) {
            if (scope.label == "view.extract") samples[frame].extract_ms += (double)scope.duration_ns / NANOSECONDS_PER_MILLISECOND;
        }
        Stats* stats = &renderer.stats;
        if (stats.lod_counts_valid && stats.lod_frame_index >= first && stats.lod_frame_index < first + samples.len) {
            Sample* completed = &samples[stats.lod_frame_index - first];
            foreach (uint level : { 0u, 1u, 2u }) {
                completed.selected[level] = stats.lod_selected[level];
                completed.visible[level] = stats.lod_visible[level];
            }
            completed.fallbacks = stats.lod_fallbacks;
            completed.counts_ready = true;
        }
        if (stats.gpu_timing_state == GpuTimingState.READY && stats.gpu_frame_index >= first && stats.gpu_frame_index < first + samples.len) {
            Sample* completed = &samples[stats.gpu_frame_index - first];
            completed.gpu_ms = 0;
            foreach (timing : stats.gpu_pass_ms) completed.gpu_ms += timing;
            completed.cull_ms = stats.gpu_pass_ms[Pass.INSTANCE_CULL.ordinal];
            completed.timings_ready = true;
        }
    }
    double cpu;
    double extract;
    double gpu_time;
    double cull;
    ulong geometry_work;
    uint fallback_frames;
    foreach (sample : samples[WARMUP_FRAMES:MEASURED_FRAMES]) {
        if (!sample.counts_ready || !sample.timings_ready) return c3d::INVALID_ARGUMENT~;
        cpu += sample.cpu_record_ms;
        extract += sample.extract_ms;
        gpu_time += sample.gpu_ms;
        cull += sample.cull_ms;
        foreach (index, visible : sample.visible) geometry_work += (ulong)visible * field.triangles[index];
        fallback_frames += sample.fallbacks != 0 ? 1 : 0;
        if (sample.selected[0] + sample.selected[1] + sample.selected[2] != PLACEMENT_COUNT) return c3d::INVALID_ARGUMENT~;
    }
    Sample last = samples[WARMUP_FRAMES + MEASURED_FRAMES - 1];
    io::printfn(
        "waypoint=%s mode=%s frames=%d..%d selected=%d,%d,%d visible=%d,%d,%d fallback_frames=%d",
        WAYPOINT_NAMES[controls.waypoint],
        controls.forced_base ? "base" : "lod",
        first + WARMUP_FRAMES,
        first + WARMUP_FRAMES + MEASURED_FRAMES - 1,
        last.selected[0],
        last.selected[1],
        last.selected[2],
        last.visible[0],
        last.visible[1],
        last.visible[2],
        fallback_frames,
    );
    io::printfn(
        "draw_commands=%d cpu_counted_triangles=%d visible_main_lod_triangles=%.0f cpu_record_ms=%.4f extract_ms=%.4f gpu_pass_ms=%.4f instance_cull_ms=%.4f",
        last.draws,
        last.direct_triangles,
        (double)geometry_work / MEASURED_FRAMES,
        cpu / MEASURED_FRAMES,
        extract / MEASURED_FRAMES,
        gpu_time / MEASURED_FRAMES,
        cull / MEASURED_FRAMES,
    );
    if (fallback_frames || !validation_clean(renderer)) return c3d::INVALID_ARGUMENT~;
}

fn void? run_benchmark() @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Field field = build_field(&assets, &scene)!;
    profile::Recorder recorder = profile::create_recorder(mem, {
        .frame_capacity = 8, .cpu_scopes_per_frame = 64, .max_depth = 8,
        .gpu_scopes_per_frame = 256, .label_bytes_per_frame = 8192,
    })!;
    defer profile::destroy_recorder(&recorder);
    Renderer renderer = render::create_renderer(mem, &assets, {
        .validation = true, .gpu_timings = true, .profiler = &recorder,
        .shadow_resolution = 1024, .application_name = "c3d_lod",
    })!;
    defer render::destroy_renderer(&renderer);
    RenderTargetId target = render::create_render_target(
        &renderer, render::render_target_desc(OUTPUT_WIDTH, OUTPUT_HEIGHT, PixelFormat.RGBA8_UNORM),
    )!;
    ViewId view = render::create_view(&renderer, view_desc(target, {}, false))!;
    renderer.prepare_scene(&scene)!;
    gpu::AdapterList adapters = gpu::enumerate_adapters(&renderer.runtime)!;
    io::printfn("selected_adapter=%s", renderer.adapter_name);
    for (uint index = 0; index < adapters.count; index++) {
        gpu::Adapter adapter = adapters.get(index)!;
        gpu::AdapterInfo info = gpu::get_adapter_info(&adapter)!;
        gpu::AdapterDiagnostics diagnostics = gpu::get_adapter_diagnostics(&adapter)!;
        io::printfn(
            "adapter=%s driver=%s version=%d details=%s",
            info.name,
            diagnostics.driver_name,
            diagnostics.driver_version,
            diagnostics.driver_info,
        );
    }
    io::printfn(
        "output=%dx%d placements=%d triangles_per_level=%d,%d,%d validation=on",
        OUTPUT_WIDTH,
        OUTPUT_HEIGHT,
        PLACEMENT_COUNT,
        field.triangles[0],
        field.triangles[1],
        field.triangles[2],
    );
    Sample[] samples = mem::new_array(Sample, RUN_FRAMES);
    defer free(samples);
    for (uint waypoint = 0; waypoint < 3; waypoint++) {
        set_waypoint(field.camera, waypoint);
        scene.update_world();
        foreach (bool forced : { false, true }) {
            Controls controls = { .waypoint = waypoint, .forced_base = forced };
            render::configure_view(&renderer, view, view_desc(target, controls, false))!;
            render::reset_view_history(&renderer, view)!;
            measure_waypoint(
                renderer: &renderer,
                scene: &scene,
                field: &field,
                view: view,
                recorder: &recorder,
                controls: controls,
                samples: samples,
            )!;
        }
    }
}

fn void? run_window(uint frame_limit) @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Field field = build_field(&assets, &scene)!;
    platform::Window window = platform::create_window(platform::default_window_desc("c3d whole-object LOD", OUTPUT_WIDTH, OUTPUT_HEIGHT))!;
    defer platform::destroy_window(&window);
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .gpu_timings = true, .shadow_resolution = 1024, .application_name = "c3d_lod" },
    )!;
    defer render::destroy_renderer(&renderer);
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    render::configure_view(&renderer, renderer.default_view, view_desc({}, {}, true))!;
    renderer.prepare_scene(&scene)!;
    Controls controls;
    uint frames;
    while (window.poll()) {
        if (frame_limit && frames >= frame_limit) break;
        if (window.input.key_released(platform::Scancode.ESCAPE)) break;
        gui_renderer.new_frame();
        defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
        bool changed;
        imgui::set_next_window_pos({ 10, 10 }, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size({ 330, 255 }, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Whole-object LOD", null, {})) {
            imgui::text_unformatted("5,000 trees, three whole-object mesh levels");
            foreach (uint index, name : WAYPOINT_NAMES) {
                if (index) imgui::same_line();
                if (imgui::button(name.zstr_tcopy())) {
                    controls.waypoint = index;
                    set_waypoint(field.camera, index);
                    changed = true;
                }
            }
            changed |= imgui::slider_float(
                label: "LOD bias",
                v: &controls.bias,
                v_min: -3,
                v_max: 3,
            );
            changed |= imgui::checkbox("Force full-detail meshes", &controls.forced_base);
            if (renderer.stats.lod_counts_valid) {
                imgui::text("Completed frame: %llu", renderer.stats.lod_frame_index);
                foreach (uint index, count : renderer.stats.lod_visible[:3]) {
                    imgui::text("Level %u: %u visible placements", index, count);
                }
                imgui::text("Fallback groups: %u", renderer.stats.lod_fallbacks);
            }
            imgui::text_unformatted("Escape closes the example.");
        }
        imgui::end();
        gui::stats_panel(&renderer)!;
        gui_renderer.finish_frame();
        scene.update_world();
        platform::sync_window(&window, &renderer);
        if (changed) render::configure_view(&renderer, renderer.default_view, view_desc({}, controls, true))!;
        if (renderer.output_width && renderer.output_height) draw_frame(
            renderer: &renderer,
            scene: &scene,
            camera: field.camera,
            view: renderer.default_view,
            gui_renderer: &gui_renderer,
            time: window.clock.total,
        )!;
        frames++;
    }
    if (!validation_clean(&renderer)) return c3d::INVALID_ARGUMENT~;
}

<* Compare whole-object mesh levels at three deterministic camera positions. *>
fn int main(String[] args) {
    bool benchmark;
    uint frames;
    for (usz index = 1; index < args.len; index++) {
        if (args[index] == "--benchmark") {
            benchmark = true;
        } else if (args[index] == "--frames" && index + 1 < args.len) {
            frames = args[++index].to_uint() ?? 0;
            if (!frames) return 1;
        } else {
            io::eprintn("Use lod [--benchmark] [--frames N].");
            return 1;
        }
    }
    fault excuse = benchmark ? @catch(run_benchmark()) : @catch(run_window(frames));
    if (excuse) {
        io::eprintfn("LOD example failed: %s", excuse);
        return 1;
    }
    return 0;
}
