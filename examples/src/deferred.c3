module deferred_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::render::post;
import c3d::scene;
import imgui;

const float ORBIT_RADIANS_PER_PIXEL @local = 0.005f;
const float ORBIT_PITCH_LIMIT @local = 1.5f; // just short of the poles, where the up vector degenerates
const float ORBIT_ZOOM_STEP @local = 0.9f;
const float ORBIT_DISTANCE_MIN @local = 2.0f;
const float ORBIT_DISTANCE_MAX @local = 40.0f;
const float LAMP_RADIANS_PER_SECOND @local = 0.7f;
const float LAMP_RADIUS @local = 3.5f;
const float LAMP_HEIGHT @local = 1.8f;
const float LAMP_INTENSITY @local = 18;
const float LAMP_RANGE @local = 9;
const float SUN_INTENSITY @local = 4;
const float AMBIENT_INTENSITY @local = 0.05f;
const float ENVIRONMENT_INTENSITY @local = 0.6f;
const float BACKGROUND_INTENSITY @local = 0.3f;
const float SPHERE_RADIUS @local = 0.6f;
const float CUBE_SIZE @local = 1.1f;
const float COLUMN_SPACING @local = 1.7f;
const float ROW_SPACING @local = 1.9f;
const float GROUND_SIZE @local = 16;
const float GROUND_LEVEL @local = -0.7f;
const uint COLUMNS @local = 5;
const uint DEFAULT_BULLET_COUNT @local = 64;
const uint DENSE_BULLET_COUNT @local = 255; // Leaves one slot for the moving road stripe.
const uint DECAL_TEXTURE_SIZE @local = 64; // 16 KiB per RGBA image before generated mips.
const uint RGBA_BYTES @local = 4;
const float TEXEL_MAX @local = 255;
const float BULLET_FADE_WIDTH @local = 0.16f;
const float BULLET_DENT_STRENGTH @local = 2;
const float BULLET_CORE_COLOR @local = 0.08f;
const float BULLET_RIM_COLOR @local = 0.35f;
const float BULLET_ROUGHNESS @local = 0.9f;
const uint BOX_RECEIVERS @local = 2;
const uint BOX_DECAL_COLUMNS @local = 4;
const uint BOX_DECAL_ROWS @local = 2;
const float BOX_DECAL_SPACING @local = 0.25f;
const float BOX_DECAL_SIZE @local = 0.22f;
const uint FLOOR_DECAL_COLUMNS @local = 8;
const Vec2 FLOOR_DECAL_SPAN @local = { 8, 7.5f };
const float FLOOR_DECAL_SIZE @local = 0.4f;
const float DECAL_DEPTH @local = 0.2f;
const Vec2 ROAD_PAINT_SIZE @local = { 0.65f, 3 };
const Vec2 ROAD_PAINT_EXTENT @local = { 0.65f, 0.9f };
const Vec2 CONTROLS_PANEL_POSITION @local = { 16, 16 };
const Vec2 CONTROLS_PANEL_SIZE @local = { 340, 250 };
const Vec2 POST_PANEL_POSITION @local = { 16, 282 };
const Vec2 POST_PANEL_SIZE @local = { 340, 300 };
const Vec2 TARGETS_PANEL_POSITION @local = { 920, 16 };
const Vec2 TARGETS_PANEL_SIZE @local = { 344, 690 };
const Vec2 STATS_PANEL_POSITION @local = { 372, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 300, 700 };
const double NANOSECONDS_PER_MILLISECOND @local = 1000000;

struct DecalTimings @local @feat(C3D_PROFILE_CPU & C3D_PROFILE_INTERNAL) {
    double[2] milliseconds;
    ulong capture_id;
    bool ready;
}

struct Orbit @local {
    Vec3  target;
    float distance;
    float yaw;
    float pitch;
}

struct Views @local {
    ViewId   left;
    ViewId   right;
    ViewDesc left_desc;
    ViewDesc right_desc;
    uint     width;
    uint     height;
}

struct Options @local {
    bool gpu_timings;
    bool effects;
    bool clustered;
    bool decals;
    bool dense_decals;
}

struct Materials @local {
    MaterialId ground;
    MaterialId dielectric;
    MaterialId mapped;
    MaterialId physical_plain;
    MaterialId physical_coat;
    MaterialId physical_ior;
    MaterialId toon;
    MaterialId basic;
    MaterialId glass;
    MaterialId transmissive;
    MaterialId bullet_hole;
    MaterialId road_paint;
}

fn void apply_orbit(Orbit* orbit, Input* input, Node* camera_node) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.LEFT)) {
            orbit.yaw -= input.mouse_delta.x * ORBIT_RADIANS_PER_PIXEL;
            orbit.pitch = math::clamp(orbit.pitch + input.mouse_delta.y * ORBIT_RADIANS_PER_PIXEL,
                -ORBIT_PITCH_LIMIT, ORBIT_PITCH_LIMIT);
        }
        if (input.wheel != 0) {
            float zoomed = orbit.distance * math::pow(ORBIT_ZOOM_STEP, input.wheel);
            orbit.distance = math::clamp(zoomed, ORBIT_DISTANCE_MIN, ORBIT_DISTANCE_MAX);
        }
    }

    Vec3 offset = {
        math::cos(orbit.pitch) * math::sin(orbit.yaw),
        math::sin(orbit.pitch),
        math::cos(orbit.pitch) * math::cos(orbit.yaw),
    };
    camera_node.local.position = orbit.target + offset * orbit.distance;
    camera_node.local.rotation = maths::look_rotation(-offset, { 0, 1, 0 });
}

fn PixelRect half_viewport(uint width, uint height, bool right) @local {
    uint half = width / 2;
    return { .x = right ? half : 0, .y = 0, .width = right ? width - half : half, .height = height };
}

fn void? configure_views(render::Renderer* renderer, Views* views) @local {
    views.width = renderer.swapchain_info.width;
    views.height = renderer.swapchain_info.height;
    views.left_desc.viewport = half_viewport(views.width, views.height, false);
    views.right_desc.viewport = half_viewport(views.width, views.height, true);
    render::configure_view(renderer, views.left, views.left_desc)!;
    render::configure_view(renderer, views.right, views.right_desc)!;
}

fn bool shading_radios(ZString label, ViewDesc* desc) @local {
    bool changed;
    imgui::push_id(label);
    defer imgui::pop_id();
    imgui::text_unformatted(label);
    imgui::same_line();
    if (imgui::radio_button("Forward", desc.shading == FORWARD) && desc.shading != FORWARD) {
        desc.shading = FORWARD;
        changed = true;
    }
    imgui::same_line();
    if (imgui::radio_button("Deferred", desc.shading == DEFERRED) && desc.shading != DEFERRED) {
        desc.shading = DEFERRED;
        changed = true;
    }
    return changed;
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Views* views,
    GuiRenderer* gui_renderer,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, views.left)!;
        renderer.finish_view(views.left)!;
        renderer.render_view(scene, camera_node, views.right)!;
        renderer.finish_view(views.right)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn void? run_gui(
    platform::Window* window,
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    Node* lamp_node,
    EnvironmentId environment,
    Options options,
) @local {
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    $if $feat(C3D_PROFILE_CPU) && $feat(C3D_PROFILE_INTERNAL):
        profile::Recorder recorder = profile::create_recorder(mem, {
            .frame_capacity = 2,
            .cpu_scopes_per_frame = 256,
            .max_depth = 16,
            .label_bytes_per_frame = 8192,
        })!;
        defer profile::destroy_recorder(&recorder);
        DecalTimings decal_timings;
        ulong capture_id;
    $endif

    Views views = {
        .left       = renderer.default_view,
        .left_desc  = render::default_view_desc(),
        .right_desc = render::default_view_desc(),
    };
    if (options.effects) {
        views.right_desc.post.bloom = true;
        views.right_desc.post.motion_blur = true;
        views.right_desc.post.depth_of_field = true;
        views.right_desc.post.dof_params.focus_distance = 11;
        views.left_desc.post = views.right_desc.post;
    }
    if (options.clustered) {
        views.left_desc.lights = LightSelection.CLUSTERED;
        views.right_desc.lights = LightSelection.CLUSTERED;
    }
    views.right_desc.shading = ShadingPath.DEFERRED;
    views.right = render::create_view(renderer, views.right_desc)!;
    defer (void)render::destroy_view(renderer, views.right);
    configure_views(renderer, &views)!;
    renderer.prepare_scene(scene)!;

    Orbit orbit = { .target = { 0, 0.2f, 0 }, .distance = 16, .pitch = 0.35f };
    TargetsPanelState targets = gui::default_targets_panel_state();
    float lamp_angle;
    bool orbit_lamp = true;
    bool escape_captured;

    while (window.poll()) {
        bool keyboard_was_captured = window.input.keyboard_captured_by_gui;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }

        Input* input = &window.input;
        // Text editing can drop capture on Escape down before its release arrives.
        if (input.key_pressed(platform::Scancode.ESCAPE) || input.key_released(platform::Scancode.ESCAPE)) {
            escape_captured |= keyboard_was_captured || input.keyboard_captured_by_gui;
        }
        if (input.key_released(platform::Scancode.ESCAPE)) {
            bool quit = !escape_captured;
            escape_captured = false;
            if (quit) break;
        }

        bool views_changed;
        imgui::set_next_window_pos(CONTROLS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(CONTROLS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Deferred", null, {})) {
            imgui::text_unformatted("Left and right views render the same scene and camera.");
            views_changed |= shading_radios("Left", &views.left_desc);
            views_changed |= shading_radios("Right", &views.right_desc);
            imgui::checkbox("Orbit lamp", &orbit_lamp);
            imgui::same_line();
            if (imgui::checkbox("Decals", &options.decals)) {
                scene.@each(Decal; Entity entity, Decal* decal) {
                    scene.node(entity).visible = options.decals;
                };
            }
            if (imgui::radio_button("Flat lights", views.right_desc.lights == FLAT)) {
                views.right_desc.lights = FLAT;
                views_changed = true;
            }
            imgui::same_line();
            if (imgui::radio_button("Clustered lights", views.right_desc.lights == CLUSTERED)) {
                views.right_desc.lights = CLUSTERED;
                views_changed = true;
            }
            ViewStats left_stats = renderer.view_stats(views.left)!;
            ViewStats right_stats = renderer.view_stats(views.right)!;
            imgui::text(
                "Left: %u decals, %u dropped, %u overflows",
                left_stats.decals,
                left_stats.decals_dropped,
                left_stats.decal_overflows,
            );
            imgui::text(
                "Right: %u decals, %u dropped, %u overflows",
                right_stats.decals,
                right_stats.decals_dropped,
                right_stats.decal_overflows,
            );
            imgui::text("Output: %u x %u", views.width, views.height);
            $if $feat(C3D_PROFILE_CPU) && $feat(C3D_PROFILE_INTERNAL):
                if (decal_timings.ready) {
                    imgui::text(
                        "CPU view.decals: left %.4f ms, right %.4f ms",
                        decal_timings.milliseconds[0],
                        decal_timings.milliseconds[1],
                    );
                    imgui::text("CPU capture: %llu", decal_timings.capture_id);
                } else {
                    imgui::text_unformatted("CPU view.decals: N/A (capture incomplete)");
                }
            $else
                imgui::text_unformatted("CPU view.decals: profiling excluded");
            $endif
        }
        imgui::end();

        imgui::set_next_window_pos(POST_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(POST_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (gui::post_panel(&views.right_desc, {})) {
            views.left_desc.post = views.right_desc.post;
            views_changed = true;
        }

        imgui::set_next_window_pos(TARGETS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(TARGETS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::targets_panel(renderer, views.right, &targets, environment)!;
        views.right_desc = renderer.views.get(views.right).desc;

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        if (orbit_lamp) lamp_angle += window.clock.delta * LAMP_RADIANS_PER_SECOND;
        lamp_node.local.position = { math::cos(lamp_angle) * LAMP_RADIUS, LAMP_HEIGHT, math::sin(lamp_angle) * LAMP_RADIUS };
        apply_orbit(&orbit, input, camera_node);
        scene.update_world();
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        bool resized = renderer.swapchain_info.width != views.width || renderer.swapchain_info.height != views.height;
        if (views_changed || resized) configure_views(renderer, &views)!;
        @capture_decal_times(&recorder, capture_id++, &decal_timings) {
            draw_frame(
                renderer:     renderer,
                scene:        scene,
                camera_node:  camera_node,
                views:        &views,
                gui_renderer: &gui_renderer,
                info:         { .time = window.clock.total, .delta = window.clock.delta },
            )!;
        }!;
    }
}

macro void? @capture_decal_times(#recorder, #capture_id, #timings; @body()) @local {
    $if $feat(C3D_PROFILE_CPU) && $feat(C3D_PROFILE_INTERNAL):
        profile::Recorder* recorder = #recorder;
        DecalTimings* timings = #timings;
        ulong capture_id = #capture_id;
        *timings = { .capture_id = capture_id };
        profile::@capture(recorder, capture_id) {
            @body();
        };
        profile::FrameCaptureView capture = recorder.frame(capture_id)!;
        uint view_index;
        // draw_frame records exactly the left view followed by the right view.
        foreach (scope : capture.cpu) {
            if (scope.label != "view.decals") continue;
            if (view_index < timings.milliseconds.len) {
                timings.milliseconds[view_index] = (double)scope.duration_ns / NANOSECONDS_PER_MILLISECOND;
            }
            view_index++;
        }
        timings.ready = capture.cpu_state == profile::CaptureState.READY && view_index == timings.milliseconds.len;
    $else
        @body();
    $endif
}

fn Materials? create_materials(AssetStore* assets, TextureId base_color, TextureId material_data, TextureId normal) @local {
    PhysicalParams plain = material::PHYSICAL_PARAMS_DEFAULT;
    plain.standard.base_color = { 0.2f, 0.35f, 0.9f, 1 };
    plain.standard.roughness = 0.3f;
    plain.standard.metallic = 0;
    PhysicalParams coat = plain;
    coat.standard.base_color = { 0.8f, 0.1f, 0.1f, 1 };
    coat.clearcoat = 1;
    coat.clearcoat_roughness = 0.1f;
    PhysicalParams low_ior = plain;
    low_ior.standard.base_color = { 0.9f, 0.9f, 0.9f, 1 };
    low_ior.ior = 1.0f;
    PhysicalParams transmissive = material::PHYSICAL_PARAMS_DEFAULT;
    transmissive.standard.base_color = { 0.95f, 0.95f, 1, 1 };
    transmissive.standard.roughness = 0.05f;
    transmissive.standard.metallic = 0;
    transmissive.transmission = 1;
    transmissive.thickness = 0.6f;
    MaterialCommon blended = material::MATERIAL_COMMON_DEFAULT;
    blended.alpha_mode = AlphaMode.BLEND;
    ToonParams toon = material::TOON_PARAMS_DEFAULT;
    toon.color = { 0.3f, 0.8f, 0.35f, 1 };
    toon.steps = 3;

    return {
        .ground = assets.add_material(
            material::standard({ .base_color = { 0.45f, 0.45f, 0.47f, 1 }, .metallic = 0, .roughness = 0.85f }),
            "deferred/floor",
        )!,
        .dielectric = assets.add_material(
            material::standard({ .base_color = { 0.85f, 0.3f, 0.2f, 1 }, .metallic = 0, .roughness = 0.4f }),
            "deferred/dielectric",
        )!,
        .mapped = assets.add_material(
            material::standard({
                .base_color             = { 1, 1, 1, 1 },
                .metallic               = 1,
                .roughness              = 1,
                .base_color_map         = material::texture_slot(base_color),
                .metallic_roughness_map = material::texture_slot(material_data),
                .normal_map             = material::texture_slot(normal),
            }),
            "deferred/mapped",
        )!,
        .physical_plain = assets.add_material(material::physical(plain), "deferred/physical_plain")!,
        .physical_coat = assets.add_material(material::physical(coat), "deferred/physical_coat")!,
        .physical_ior = assets.add_material(material::physical(low_ior), "deferred/physical_ior")!,
        .toon = assets.add_material(material::toon(toon), "deferred/toon")!,
        .basic = assets.add_material(material::basic({ .color = { 1, 0.85f, 0.2f, 1 } }), "deferred/basic")!,
        .glass = assets.add_material(
            material::standard({ .base_color = { 0.2f, 0.8f, 1, 0.4f }, .metallic = 0, .roughness = 0.2f }, blended),
            "deferred/glass",
        )!,
        .transmissive = assets.add_material(material::physical(transmissive), "deferred/transmissive")!,
    };
}

fn void? place_row(Scene* scene, GeometryId geometry, MaterialId[] materials, float z, String prefix) @local {
    float start = -(float)(materials.len - 1) * 0.5f * COLUMN_SPACING;
    foreach (index, material : materials) {
        Node* node = scene.add_mesh(geometry, material, name: prefix)!;
        node.local.position = { start + (float)index * COLUMN_SPACING, 0, z };
    }
}

fn void? add_decal_materials(AssetStore* assets, Materials* materials) @local {
    char[DECAL_TEXTURE_SIZE * DECAL_TEXTURE_SIZE * RGBA_BYTES] albedo_pixels;
    char[DECAL_TEXTURE_SIZE * DECAL_TEXTURE_SIZE * RGBA_BYTES] normal_pixels;
    char[DECAL_TEXTURE_SIZE * DECAL_TEXTURE_SIZE * RGBA_BYTES] paint_pixels;
    for (uint y = 0; y < DECAL_TEXTURE_SIZE; y++) {
        for (uint x = 0; x < DECAL_TEXTURE_SIZE; x++) {
            Vec2 offset = {
                ((float)x + 0.5f) * 2 / DECAL_TEXTURE_SIZE - 1,
                ((float)y + 0.5f) * 2 / DECAL_TEXTURE_SIZE - 1,
            };
            float radius = offset.length();
            float opacity = math::clamp((1 - radius) / BULLET_FADE_WIDTH, 0.0f, 1.0f);
            float shade = BULLET_CORE_COLOR
              + (BULLET_RIM_COLOR - BULLET_CORE_COLOR) * math::min(radius, 1.0f);
            float dent = BULLET_DENT_STRENGTH * math::max(1 - radius, 0.0f);
            Vec3 normal = { -offset.x * dent, -offset.y * dent, 1 };
            normal = normal.normalize() * 0.5f + (Vec3){ 0.5f, 0.5f, 0.5f };
            usz pixel = (usz)(y * DECAL_TEXTURE_SIZE + x) * RGBA_BYTES;
            for (uint channel = 0; channel < 3; channel++) {
                albedo_pixels[pixel + channel] = (char)(shade * TEXEL_MAX);
                normal_pixels[pixel + channel] = (char)(normal[channel] * TEXEL_MAX);
                paint_pixels[pixel + channel] = (char)TEXEL_MAX;
            }
            albedo_pixels[pixel + 3] = (char)(opacity * TEXEL_MAX);
            normal_pixels[pixel + 3] = (char)TEXEL_MAX;
            paint_pixels[pixel + 3] = math::abs(offset.x) < ROAD_PAINT_EXTENT.x
              && math::abs(offset.y) < ROAD_PAINT_EXTENT.y
              ? (char)TEXEL_MAX : 0;
        }
    }

    TextureId albedo = add_decal_texture(
        assets: assets,
        pixels: albedo_pixels[..],
        format: RGBA8_SRGB,
        name: "bullet_albedo",
    )!;
    TextureId normal = add_decal_texture(
        assets: assets,
        pixels: normal_pixels[..],
        format: RGBA8_UNORM,
        name: "bullet_normal",
    )!;
    TextureId paint = add_decal_texture(
        assets: assets,
        pixels: paint_pixels[..],
        format: RGBA8_SRGB,
        name: "road_paint",
    )!;
    materials.bullet_hole = assets.add_material(material::standard({
        .base_color = { 1, 1, 1, 1 },
        .roughness = BULLET_ROUGHNESS,
        .normal_scale = 1,
        .base_color_map = material::texture_slot(albedo),
        .normal_map = material::texture_slot(normal),
    }), "deferred/bullet_hole")!;
    materials.road_paint = assets.add_material(material::standard({
        .base_color = { 1, 0.8f, 0.1f, 1 },
        .roughness = 1,
        .base_color_map = material::texture_slot(paint),
    }), "deferred/road_paint")!;
}

fn TextureId? add_decal_texture(
    AssetStore* assets,
    char[] pixels,
    PixelFormat format,
    ZString name,
) @local {
    return assets.add_texture(material::texture_2d_desc(
        width: DECAL_TEXTURE_SIZE,
        height: DECAL_TEXTURE_SIZE,
        format: format,
        debug_name: name,
    ), pixels);
}

fn void? place_decals(
    Scene* scene,
    GeometryId box,
    Materials* materials,
    Node* lamp,
    uint bullet_count,
) @local {
    DecalDesc bullet = scene::default_decal_desc(materials.bullet_hole);
    bullet.size = { BOX_DECAL_SIZE, BOX_DECAL_SIZE, DECAL_DEPTH };
    bullet.decal.order = 1;
    for (uint receiver = 0; receiver < BOX_RECEIVERS; receiver++) {
        MaterialId material = receiver ? materials.physical_plain : materials.dielectric;
        Node* node = scene.add_mesh(box, material, name: "decal_receiver")!;
        node.local.position = {
            (receiver ? 1.0f : -1.0f) * (COLUMNS + 1) * 0.5f * COLUMN_SPACING,
            0,
            ROW_SPACING * 0.5f,
        };
        for (uint row = 0; row < BOX_DECAL_ROWS; row++) {
            for (uint column = 0; column < BOX_DECAL_COLUMNS; column++) {
                Node* decal = scene.add_decal(bullet, node, "bullet_hole")!;
                decal.local.position = {
                    ((float)column - (BOX_DECAL_COLUMNS - 1) * 0.5f) * BOX_DECAL_SPACING,
                    ((float)row - (BOX_DECAL_ROWS - 1) * 0.5f) * BOX_DECAL_SPACING,
                    CUBE_SIZE * 0.5f,
                };
            }
        }
    }

    uint floor_count = bullet_count - BOX_RECEIVERS * BOX_DECAL_COLUMNS * BOX_DECAL_ROWS;
    uint columns = bullet_count > DEFAULT_BULLET_COUNT ? FLOOR_DECAL_COLUMNS * 2 : FLOOR_DECAL_COLUMNS;
    uint rows = (floor_count + columns - 1) / columns;
    Quat floor_rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, -(float)math::PI / 2);
    bullet.size = { FLOOR_DECAL_SIZE, FLOOR_DECAL_SIZE, DECAL_DEPTH };
    for (uint index = 0; index < floor_count; index++) {
        Node* decal = scene.add_decal(bullet, name: "bullet_hole")!;
        decal.local.position = {
            (((float)(index % columns) + 0.5f) / columns - 0.5f) * FLOOR_DECAL_SPAN.x,
            GROUND_LEVEL,
            (((float)(index / columns) + 0.5f) / rows - 0.5f) * FLOOR_DECAL_SPAN.y,
        };
        decal.local.rotation = floor_rotation;
    }

    DecalDesc paint = scene::default_decal_desc(materials.road_paint);
    paint.size = { ROAD_PAINT_SIZE.x, ROAD_PAINT_SIZE.y, DECAL_DEPTH };
    paint.decal.weights = { .base_color = 1, .normal = 0, .roughness = 0, .metallic = 0 };
    paint.decal.order = 0;
    Node* stripe = scene.add_decal(paint, lamp, "road_paint")!;
    stripe.local.position = { 0, GROUND_LEVEL - LAMP_HEIGHT, 0 };
    stripe.local.rotation = floor_rotation;
}

fn int main(String[] args) {
    Options options = { .decals = true };
    foreach (argument : args[1..]) {
        if (argument == "--gpu-timings") {
            $if $feat(C3D_PROFILE_GPU):
                options.gpu_timings = true;
            $else
                io::eprintfn("--gpu-timings needs c3d_profile and C3D_PROFILE_GPU; see docs/views.md for the build command.");
                return 1;
            $endif
        } else if (argument == "--effects") {
            options.effects = true;
        } else if (argument == "--clustered") {
            options.clustered = true;
        } else if (argument == "--dense-decals") {
            options.dense_decals = true;
        } else {
            io::printfn("Unknown argument: %s", argument);
            return 1;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d deferred", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .gpu_timings = options.gpu_timings, .validation = true, .application_name = "c3d_deferred" },
    )!!;
    defer render::destroy_renderer(&renderer);

    TextureId studio_source;
    TextureId base_color;
    TextureId material_data;
    TextureId normal;
    @pool() {
        Path source = path::tnew($$FILEPATH)!!;
        Path assets_directory = source.parent()!!.tappend("../assets")!!;
        Path pbr_directory = assets_directory.tappend("pbr")!!;
        studio_source = image::load_hdr(
            &assets,
            (String)assets_directory.tappend("ibl/studio_small_09_1k.hdr")!!,
            "deferred/source/studio",
        )!!;
        base_color = image::load_texture(&assets, (String)pbr_directory.tappend("base_color.png")!!, true)!!;
        material_data = image::load_texture(
            assets: &assets,
            path:   (String)pbr_directory.tappend("material_data.png")!!,
            srgb:   false,
        )!!;
        normal = image::load_texture(&assets, (String)pbr_directory.tappend("normal.png")!!, false)!!;
    };
    EnvironmentId environment = assets.add_environment(
        light::texture_environment(studio_source, light::ENVIRONMENT_SETTINGS_DEFAULT),
        "deferred/environment/studio",
    )!!;

    GeometryId sphere;
    GeometryId box;
    GeometryId ground;
    @pool() {
        Geometry sphere_geometry = geometry::sphere(tmem, SPHERE_RADIUS);
        sphere = assets.add_geometry(&sphere_geometry, "deferred/sphere")!!;
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "deferred/box")!!;
        Geometry ground_geometry = geometry::plane(tmem, GROUND_SIZE, GROUND_SIZE);
        ground = assets.add_geometry(&ground_geometry, "deferred/ground")!!;
    };
    Materials materials = create_materials(&assets, base_color, material_data, normal)!!;
    add_decal_materials(&assets, &materials)!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    scene.ambient_intensity = AMBIENT_INTENSITY;
    scene.ambient_add = true;
    scene.environment = environment;
    scene.environment_intensity = ENVIRONMENT_INTENSITY;
    scene.background = scene::BACKGROUND_DEFAULT;
    scene.background.kind = BackgroundKind.ENVIRONMENT;
    scene.background.environment = environment;
    scene.background.intensity = BACKGROUND_INTENSITY;

    Node* floor = scene.add_mesh(ground, materials.ground, name: "ground")!!;
    floor.local.position = { 0, GROUND_LEVEL, 0 };
    MaterialId[COLUMNS] back_row = {
        materials.dielectric, materials.mapped, materials.physical_plain, materials.physical_coat, materials.physical_ior,
    };
    MaterialId[COLUMNS] front_row = {
        materials.toon, materials.basic, materials.glass, materials.transmissive, materials.mapped,
    };
    place_row(&scene, sphere, back_row[..], -ROW_SPACING * 0.5f, "back")!!;
    place_row(&scene, box, front_row[..], ROW_SPACING * 0.5f, "front")!!;

    Node* sun = scene.add_light(light::directional({ 1, 0.98f, 0.92f }, SUN_INTENSITY), name: "sun")!!;
    sun.local.rotation = maths::look_rotation((Vec3){ 0.35f, -0.8f, -0.45f }.normalize(), { 0, 1, 0 });
    Node* lamp = scene.add_light(light::point({ 1, 0.7f, 0.4f }, LAMP_INTENSITY, LAMP_RANGE), name: "lamp")!!;
    place_decals(
        scene: &scene,
        box: box,
        materials: &materials,
        lamp: lamp,
        bullet_count: options.dense_decals ? DENSE_BULLET_COUNT : DEFAULT_BULLET_COUNT,
    )!!;
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;

    if (catch excuse = run_gui(
        window:      &window,
        renderer:    &renderer,
        scene:       &scene,
        camera_node: camera_node,
        lamp_node:   lamp,
        environment: environment,
        options:     options,
    )) {
        io::printfn("GUI failed: %s", excuse);
        return 1;
    }
    return 0;
}
