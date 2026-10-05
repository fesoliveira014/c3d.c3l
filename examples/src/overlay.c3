module overlay_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::gui;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import std::io;
import std::math;
import std::time;
import std::time::clock;

const uint DEFAULT_STRESS_COUNT @local = 10000;
const uint SCENE_ITEM_RESERVE @local = 256; // every item the fixed scenes add, with room to spare
const uint DEFAULT_BENCHMARK_RECTS @local = 1000;
const uint DEFAULT_BENCHMARK_FRAMES @local = 120;
const uint DEFAULT_BENCHMARK_WIDTH @local = 1280;
const uint DEFAULT_BENCHMARK_HEIGHT @local = 720;
const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 720;
const double NANOSECONDS_PER_MILLISECOND @local = 1000000;

const uint PORTRAIT_SIZE @local = 256;
const uint PORTRAIT_LAYER @local = 2; // only the portrait camera draws the cube
const float PORTRAIT_SPIN_RADIANS_PER_SECOND @local = 1.1f;
const float CUBE_SIZE @local = 1.6f;
const float BACKDROP_RADIUS @local = 1.2f;
const float CAMERA_DISTANCE @local = 5;

const uint SKIN_SIZE @local = 32;
const uint SKIN_FRAME_PIXELS @local = 8;
const char[4] SKIN_FRAME_COLOR @local = { 40, 44, 66, 255 };
const char[4] SKIN_CENTER_COLOR @local = { 214, 220, 232, 255 };
const char[4] SKIN_HIGHLIGHT_COLOR @local = { 255, 255, 255, 255 };
const float SKIN_SLICE_UV @local = 0.25f; // SKIN_FRAME_PIXELS of SKIN_SIZE
const float SKIN_SLICE_PIXELS @local = 8;

const uint STRESS_RECT_SIZE @local = 6;
const uint STRESS_RECT_PITCH @local = 8;
const float STRESS_RECT_RADIUS @local = 2;
const float STRESS_ALPHA @local = 0.55f;

const Vec2 PANEL_MIN @local = { 24, 24 };
const Vec2 PANEL_MAX @local = { 344, 144 };
const Vec2 SKIN_ORIGIN @local = { 24, 168 };
const Vec2 SKIN_SIZE_BASE @local = { 240, 160 };
const Vec2 SKIN_SIZE_SWING @local = { 80, 40 };
const Vec2 PORTRAIT_MIN @local = { 380, 24 };
const Vec2 SCROLL_WINDOW_MIN @local = { 672, 24 };
const Vec2 SCROLL_WINDOW_MAX @local = { 992, 344 };
const Vec2 SCROLL_PANEL_MIN @local = { 692, 60 };
const Vec2 SCROLL_PANEL_MAX @local = { 972, 324 };
const uint SCROLL_ROW_COUNT @local = 40;
const float SCROLL_ROW_PITCH @local = 28;
const float SCROLL_ROW_HEIGHT @local = 24;
const float SCROLL_SPEED @local = 0.7f;
const float SAMPLE_TOP @local = 400;
const float SAMPLE_SIZE @local = 64;
const float SAMPLE_PITCH @local = 80;
const float SAMPLE_BORDERS_LEFT @local = 540;
const uint SAMPLE_COUNT @local = 6;
const float[6] SAMPLE_RADII @local = { 0, 8, 16, 24, 32, 64 };
const float[4] SAMPLE_BORDER_WIDTHS @local = { 1, 2, 4, 8 };
const float OVERSIZE_BOX @local = 12;
const float OVERSIZE_BORDER @local = 20;
const Vec4 UNEVEN_BORDERS @local = { 2, 8, 16, 4 };

const Vec4 PANEL_FILL @local = { 0.08f, 0.12f, 0.3f, 0.85f };
const Vec4 PANEL_BORDER @local = { 0.7f, 0.8f, 1, 1 };
const Vec4 SCROLL_WINDOW_FILL @local = { 0.12f, 0.12f, 0.14f, 0.9f };
const Vec4 SCROLL_PANEL_FILL @local = { 0.2f, 0.2f, 0.24f, 1 };
const Vec4 SAMPLE_FILL @local = { 0.9f, 0.55f, 0.15f, 1 };
const Vec4 SAMPLE_BORDER @local = { 0.1f, 0.1f, 0.1f, 1 };
const Vec4 WHITE @local = { 1, 1, 1, 1 };
const Vec4 BACKDROP_COLOR @local = { 0.9f, 0.25f, 0.3f, 1 };
const Vec4 CUBE_COLOR @local = { 0.2f, 0.7f, 0.9f, 1 };
const Vec2 STATS_PANEL_POSITION @local = { 1010, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 260, 90 };
const Vec2 RENDERER_PANEL_POSITION @local = { 1010, 120 };
const Vec2 RENDERER_PANEL_SIZE @local = { 260, 560 };

struct Options @local {
    uint stress_count;
    bool stress_enabled;
    bool benchmark;
    uint rects;
    uint frames;
    uint width;
    uint height;
}

struct Demo @local {
    platform::Window* window;
    Renderer*         renderer;
    Scene*            scene;
    Node*             camera_node;
    Node*             portrait_camera;
    Node*             cube;
    ViewId            portrait_view;
    RenderTargetId    portrait;
    TextureId         skin;
    OverlayList*      list;
    bool              with_portrait;
    double            prepare_ms;
    uint              overlay_draws;
}

fn void fill_skin(char[] pixels) @local {
    for (uint y = 0; y < SKIN_SIZE; y++) {
        for (uint x = 0; x < SKIN_SIZE; x++) {
            bool frame = x < SKIN_FRAME_PIXELS
                || y < SKIN_FRAME_PIXELS
                || x >= SKIN_SIZE - SKIN_FRAME_PIXELS
                || y >= SKIN_SIZE - SKIN_FRAME_PIXELS;
            // Inside the corner and edge margins the highlight keeps its one-pixel width; the centre stretches.
            bool inner_edge = x == SKIN_FRAME_PIXELS - 1 || y == SKIN_FRAME_PIXELS - 1;
            bool highlight = inner_edge
                && x >= SKIN_FRAME_PIXELS - 1
                && y >= SKIN_FRAME_PIXELS - 1
                && x <= SKIN_SIZE - SKIN_FRAME_PIXELS
                && y <= SKIN_SIZE - SKIN_FRAME_PIXELS;
            char[4] color = highlight ? SKIN_HIGHLIGHT_COLOR : (frame ? SKIN_FRAME_COLOR : SKIN_CENTER_COLOR);
            foreach (channel, value : color) pixels[(y * SKIN_SIZE + x) * 4 + (uint)channel] = value;
        }
    }
}

fn OverlayRect solid_rect(Vec2 min, Vec2 max, Vec4 fill, float radius = 0) @local {
    OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
    rect.min = min;
    rect.max = max;
    rect.fill = fill;
    rect.corner_radii = { radius, radius, radius, radius };
    return rect;
}

fn Vec4 row_color(uint index) @local {
    float phase = (float)index * 0.55f;
    return {
        0.5f + 0.4f * math::sin(phase),
        0.5f + 0.4f * math::sin(phase + 2.1f),
        0.5f + 0.4f * math::sin(phase + 4.2f),
        1,
    };
}

fn void? add_stress_rects(OverlayList* list, uint count, uint width) @local {
    uint columns = math::max(1u, width / STRESS_RECT_PITCH);
    for (uint index = 0; index < count; index++) {
        float left = (float)((index % columns) * STRESS_RECT_PITCH);
        float top = (float)((index / columns) * STRESS_RECT_PITCH);
        Vec4 color = row_color(index);
        color.w = STRESS_ALPHA;
        list.add_rect(solid_rect(
            min:    { left, top },
            max:    { left + STRESS_RECT_SIZE, top + STRESS_RECT_SIZE },
            fill:   color,
            radius: STRESS_RECT_RADIUS,
        ))!;
    }
}

fn void? add_panel(OverlayList* list) @local {
    OverlayRect panel = solid_rect(
        min:    PANEL_MIN,
        max:    PANEL_MAX,
        fill:   PANEL_FILL,
        radius: 16,
    );
    panel.border_widths = { 2, 2, 2, 2 };
    panel.border_color = PANEL_BORDER;
    list.add_rect(panel)!;
}

fn void? add_skin_window(OverlayList* list, TextureId skin, float time) @local {
    Vec2 size = {
        SKIN_SIZE_BASE.x + SKIN_SIZE_SWING.x * math::sin(time),
        SKIN_SIZE_BASE.y + SKIN_SIZE_SWING.y * math::sin(time * 0.8f),
    };
    OverlayRect window = solid_rect(
        min:  SKIN_ORIGIN,
        max:  SKIN_ORIGIN + size,
        fill: WHITE,
    );
    window.texture = { .kind = ASSET, .asset = skin };
    window.slice_uv = { SKIN_SLICE_UV, SKIN_SLICE_UV, SKIN_SLICE_UV, SKIN_SLICE_UV };
    window.slice_pixels = { SKIN_SLICE_PIXELS, SKIN_SLICE_PIXELS, SKIN_SLICE_PIXELS, SKIN_SLICE_PIXELS };
    list.add_rect(window)!;
}

fn void? add_portrait(OverlayList* list, RenderTargetId portrait) @local {
    OverlayRect rect = solid_rect(
        min:    PORTRAIT_MIN,
        max:    PORTRAIT_MIN + (Vec2){ PORTRAIT_SIZE, PORTRAIT_SIZE },
        fill:   WHITE,
        radius: 24,
    );
    rect.texture = { .kind = RENDER_TARGET, .target = portrait };
    rect.border_widths = { 3, 3, 3, 3 };
    rect.border_color = PANEL_BORDER;
    list.add_rect(rect)!;
}

fn void? add_scroll_list(OverlayList* list, float time) @local {
    list.push_clip(SCROLL_WINDOW_MIN, SCROLL_WINDOW_MAX)!;
    list.add_rect(solid_rect(
        min:    SCROLL_WINDOW_MIN,
        max:    SCROLL_WINDOW_MAX,
        fill:   SCROLL_WINDOW_FILL,
        radius: 12,
    ))!;

    list.push_clip(SCROLL_PANEL_MIN, SCROLL_PANEL_MAX)!;
    list.add_rect(solid_rect(
        min:    SCROLL_PANEL_MIN,
        max:    SCROLL_PANEL_MAX,
        fill:   SCROLL_PANEL_FILL,
        radius: 8,
    ))!;

    float content_height = SCROLL_ROW_COUNT * SCROLL_ROW_PITCH;
    float scroll_range = content_height - (SCROLL_PANEL_MAX.y - SCROLL_PANEL_MIN.y);
    float scroll = (0.5f + 0.5f * math::sin(time * SCROLL_SPEED)) * scroll_range;
    for (uint row = 0; row < SCROLL_ROW_COUNT; row++) {
        float top = SCROLL_PANEL_MIN.y - scroll + row * SCROLL_ROW_PITCH;
        list.add_rect(solid_rect(
            min:    { SCROLL_PANEL_MIN.x + 8, top },
            max:    { SCROLL_PANEL_MAX.x - 8, top + SCROLL_ROW_HEIGHT },
            fill:   row_color(row),
            radius: 6,
        ))!;
    }
    list.pop_clip();
    list.pop_clip();
}

fn void? add_samples(OverlayList* list) @local {
    for (uint index = 0; index < SAMPLE_COUNT; index++) {
        float left = PANEL_MIN.x + index * SAMPLE_PITCH;
        list.add_rect(solid_rect(
            min:    { left, SAMPLE_TOP },
            max:    { left + SAMPLE_SIZE, SAMPLE_TOP + SAMPLE_SIZE },
            fill:   SAMPLE_FILL,
            radius: SAMPLE_RADII[index],
        ))!;
    }

    foreach (index, width : SAMPLE_BORDER_WIDTHS) {
        float left = SAMPLE_BORDERS_LEFT + index * SAMPLE_PITCH;
        OverlayRect rect = solid_rect(
            min:    { left, SAMPLE_TOP },
            max:    { left + SAMPLE_SIZE, SAMPLE_TOP + SAMPLE_SIZE },
            fill:   SAMPLE_FILL,
            radius: 12,
        );
        rect.border_widths = { width, width, width, width };
        rect.border_color = SAMPLE_BORDER;
        list.add_rect(rect)!;
    }

    float oversize_left = SAMPLE_BORDERS_LEFT + SAMPLE_BORDER_WIDTHS.len * SAMPLE_PITCH;
    OverlayRect oversize = solid_rect(
        min:    { oversize_left, SAMPLE_TOP },
        max:    { oversize_left + OVERSIZE_BOX, SAMPLE_TOP + OVERSIZE_BOX },
        fill:   SAMPLE_FILL,
        radius: 4,
    );
    oversize.border_widths = { OVERSIZE_BORDER, OVERSIZE_BORDER, OVERSIZE_BORDER, OVERSIZE_BORDER };
    oversize.border_color = SAMPLE_BORDER;
    list.add_rect(oversize)!;

    float uneven_left = oversize_left + SAMPLE_PITCH;
    OverlayRect uneven = solid_rect(
        min:    { uneven_left, SAMPLE_TOP },
        max:    { uneven_left + SAMPLE_SIZE, SAMPLE_TOP + SAMPLE_SIZE },
        fill:   SAMPLE_FILL,
        radius: 12,
    );
    uneven.border_widths = UNEVEN_BORDERS;
    uneven.border_color = SAMPLE_BORDER;
    list.add_rect(uneven)!;
}

fn void? fill_scenes(Demo* demo, Options* options, float time) @local {
    OverlayList* list = demo.list;
    list.clear();
    if (options.stress_enabled) {
        list.push_clip({ 0, 0 }, { (float)demo.renderer.output_width, (float)demo.renderer.output_height })!;
        add_stress_rects(list, options.stress_count, demo.renderer.output_width)!;
        list.pop_clip();
    }
    add_panel(list)!;
    add_skin_window(list, demo.skin, time)!;
    add_portrait(list, demo.portrait)!;
    add_scroll_list(list, time)!;
    add_samples(list)!;
}

fn void? draw_frame(Demo* demo, GuiRenderer* gui_renderer, FrameInfo info) @local {
    Renderer* renderer = demo.renderer;
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        if (demo.with_portrait) {
            renderer.render_view(demo.scene, demo.portrait_camera, demo.portrait_view)!;
            renderer.finish_view(demo.portrait_view)!;
        }
        renderer.render_view(demo.scene, demo.camera_node, renderer.default_view)!;
        renderer.finish_view(renderer.default_view)!;

        time::Clock started = clock::now();
        renderer.prepare_overlay_list(demo.list)!;
        demo.prepare_ms = (double)started.to_now() / NANOSECONDS_PER_MILLISECOND;

        OverlayContext overlay = renderer.begin_overlay()!;
        uint draws_before = renderer.stats.draws;
        overlay.draw_list(demo.list)!;
        demo.overlay_draws = renderer.stats.draws - draws_before;
        if (gui_renderer) gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }

    return renderer.end_frame();
}

fn void animate(Demo* demo, float time) @local {
    Quat spin = quaternion::from_axis_angle{float}({ 0, 1, 0 }, time * PORTRAIT_SPIN_RADIANS_PER_SECOND);
    Quat tilt = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.5f);
    demo.cube.local.rotation = spin.mul(tilt).normalize();
    demo.scene.update_world();
}

fn void? run_interactive(Demo* demo, Options* options) @local {
    platform::Window* window = demo.window;
    Renderer* renderer = demo.renderer;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    uint frames;
    while (window.poll()) {
        if (options.frames && frames >= options.frames) break;
        if (window.input.key_released(platform::Scancode.ESCAPE)) break;

        gui_renderer.new_frame();
        defer if (gui_renderer.frame_open) gui_renderer.finish_frame();

        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Overlay", null, {})) {
            imgui::checkbox("Stress rects", &options.stress_enabled);
            imgui::text("Items: %u of %u", demo.list.item_count, (uint)demo.list.entries.len);
        }
        imgui::end();
        imgui::set_next_window_pos(RENDERER_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(RENDERER_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        gui::stats_panel(renderer)!;

        animate(demo, (float)window.clock.total);
        platform::sync_window(window, renderer);
        if (renderer.output_width && renderer.output_height) fill_scenes(demo, options, (float)window.clock.total)!;
        gui_renderer.finish_frame();
        if (renderer.output_width && renderer.output_height) {
            draw_frame(
                demo:         demo,
                gui_renderer: &gui_renderer,
                info:         { .time = window.clock.total, .delta = window.clock.delta },
            )!;
        }
        frames++;
    }
}

fn void? run_benchmark(Demo* demo, Options* options) @local {
    platform::Window* window = demo.window;
    Renderer* renderer = demo.renderer;

    double fill_ms;
    double prepare_ms;
    double overlay_gpu_ms;
    uint gpu_samples;
    uint draws;
    uint frame;
    while (window.poll() && frame < options.frames * 2) {
        platform::sync_window(window, renderer);
        if (!renderer.output_width || !renderer.output_height) continue;

        time::Clock started = clock::now();
        demo.list.clear();
        add_stress_rects(demo.list, options.rects, renderer.output_width)!;
        double elapsed_fill_ms = (double)started.to_now() / NANOSECONDS_PER_MILLISECOND;
        draw_frame(
            demo:         demo,
            gui_renderer: null,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;

        if (frame >= options.frames) {
            fill_ms += elapsed_fill_ms;
            prepare_ms += demo.prepare_ms;
            draws = demo.overlay_draws;
            if (renderer.stats.gpu_pass_valid[Pass.OVERLAY.ordinal]) {
                overlay_gpu_ms += renderer.stats.gpu_pass_ms[Pass.OVERLAY.ordinal];
                gpu_samples++;
            }
        }
        frame++;
    }

    double measured = (double)options.frames;
    io::printfn(
        "rects=%d width=%d height=%d fill_ms=%.4f prepare_ms=%.4f overlay_gpu_ms=%.4f draws=%d",
        options.rects,
        renderer.output_width,
        renderer.output_height,
        fill_ms / measured,
        prepare_ms / measured,
        gpu_samples ? overlay_gpu_ms / gpu_samples : 0.0,
        draws,
    );
}

fn uint[2]? parse_size(String text) @local {
    String[] parts = text.split(tmem, "x");
    if (parts.len != 2) return c3d::INVALID_ARGUMENT~;
    uint width = parts[0].to_uint() ?? 0;
    uint height = parts[1].to_uint() ?? 0;
    if (!width || !height) return c3d::INVALID_ARGUMENT~;
    return { width, height };
}

fn int main(String[] args) {
    Options options = {
        .stress_count = DEFAULT_STRESS_COUNT,
        .rects        = DEFAULT_BENCHMARK_RECTS,
        .width        = WINDOW_WIDTH,
        .height       = WINDOW_HEIGHT,
    };
    bool size_given;
    bool frames_given;
    for (usz index = 1; index < args.len; index++) {
        String argument = args[index];
        bool has_value = index + 1 < args.len;
        if (argument == "--benchmark") {
            options.benchmark = true;
        } else if (argument == "--stress") {
            options.stress_enabled = true;
            if (has_value) {
                if (try stress_count = args[index + 1].to_uint()) {
                    options.stress_count = stress_count;
                    index++;
                }
            }
        } else if (argument == "--rects" && has_value) {
            options.rects = args[++index].to_uint() ?? 0;
        } else if (argument == "--frames" && has_value) {
            options.frames = args[++index].to_uint() ?? 0;
            frames_given = true;
            if (!options.frames) return 1;
        } else if (argument == "--size" && has_value) {
            size_given = true;
            uint[2]? size = parse_size(args[++index]);
            if (catch size) return 1;
            options.width = size[0];
            options.height = size[1];
        } else {
            io::eprintn("Use overlay [--stress [N]] [--frames N] [--benchmark --rects N --frames F --size WxH].");
            return 1;
        }
    }
    if (options.benchmark) {
        if (!frames_given) options.frames = DEFAULT_BENCHMARK_FRAMES;
        if (!size_given) {
            options.width = DEFAULT_BENCHMARK_WIDTH;
            options.height = DEFAULT_BENCHMARK_HEIGHT;
        }
    }

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d overlay", options.width, options.height))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .gpu_timings = true, .application_name = "c3d_overlay" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId box;
    GeometryId ball;
    @pool() {
        Geometry box_geometry = geometry::box(tmem, CUBE_SIZE, CUBE_SIZE, CUBE_SIZE);
        box = assets.add_geometry(&box_geometry, "overlay/box")!!;
        Geometry ball_geometry = geometry::sphere(tmem, BACKDROP_RADIUS);
        ball = assets.add_geometry(&ball_geometry, "overlay/sphere")!!;
    };
    MaterialId cube_material = assets.add_material(material::basic({ .color = CUBE_COLOR }), "overlay/cube")!!;
    MaterialId backdrop_material = assets.add_material(
        material::basic({ .color = BACKDROP_COLOR }),
        "overlay/backdrop",
    )!!;

    char[SKIN_SIZE * SKIN_SIZE * 4] skin_pixels;
    fill_skin(skin_pixels[..]);
    TextureId skin = assets.add_texture(
        material::texture_2d_desc(SKIN_SIZE, SKIN_SIZE, RGBA8_SRGB),
        skin_pixels[..],
        "overlay/skin",
    )!!;

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;
    camera_node.local.position = { 0, 0, CAMERA_DISTANCE };
    scene.get(camera_node, camera::Camera).layers = camera::ALL_LAYERS & ~PORTRAIT_LAYER;
    Node* portrait_camera = scene.add_camera(camera::perspective_deg(40, 0.1f), name: "portrait")!!;
    portrait_camera.local.position = { 0, 0, CAMERA_DISTANCE };
    scene.get(portrait_camera, camera::Camera).layers = PORTRAIT_LAYER;
    Node* cube = scene.add_mesh(box, cube_material, name: "cube")!!;
    cube.layers = PORTRAIT_LAYER;
    if (!options.benchmark) scene.add_mesh(ball, backdrop_material, name: "backdrop")!!;
    scene.update_world();

    uint capacity = (options.benchmark ? options.rects : options.stress_count) + SCENE_ITEM_RESERVE;
    OverlayListDesc list_desc = { .max_items = capacity, .max_clips = render::OVERLAY_LIST_DEFAULT_CLIPS };
    OverlayList list = render::create_overlay_list(mem, list_desc);
    defer render::destroy_overlay_list(&list);

    RenderTargetId portrait = render::create_render_target(
        &renderer,
        render::render_target_desc(PORTRAIT_SIZE, PORTRAIT_SIZE, material::PixelFormat.RGBA8_SRGB),
    )!!;
    defer (void)render::destroy_render_target(&renderer, portrait);
    ViewId portrait_view = render::create_view(
        &renderer,
        render::texture_view_desc(portrait, OutputMode.DISPLAY_LDR),
    )!!;
    defer (void)render::destroy_view(&renderer, portrait_view);

    Demo demo = {
        .window          = &window,
        .renderer        = &renderer,
        .scene           = &scene,
        .camera_node     = camera_node,
        .portrait_camera = portrait_camera,
        .cube            = cube,
        .portrait        = portrait,
        .portrait_view   = portrait_view,
        .skin            = skin,
        .list            = &list,
        .with_portrait   = !options.benchmark,
    };
    renderer.prepare_scene(&scene)!!;

    fault excuse = options.benchmark
        ? @catch(run_benchmark(&demo, &options))
        : @catch(run_interactive(&demo, &options));
    if (excuse) {
        io::eprintfn("Overlay example failed: %s", excuse);
        return 1;
    }
    if (catch renderer.log.check_validation()) {
        io::eprintn("Validation reported errors.");
        return 1;
    }
    return 0;
}
