module text_example;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::gui;
import c3d::material;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import std::core::string::conv;
import std::io;
import std::math;
import std::time;
import std::time::clock;

const uint WINDOW_WIDTH @local = 1280;
const uint WINDOW_HEIGHT @local = 800;
const uint DEFAULT_BENCHMARK_GLYPHS @local = 10000;
const uint DEFAULT_BENCHMARK_FRAMES @local = 120;
const double NANOSECONDS_PER_MILLISECOND @local = 1000000;
const uint MAX_LINE_GLYPHS @local = 512; // the longest sample line, with room for the benchmark rows
const uint LIST_ITEM_RESERVE @local = 512; // runs and rects of the fixed pages
const uint LIST_GLYPH_RESERVE @local = 4096; // glyphs of the fixed pages

const float[8] SAMPLE_SIZES @local = { 10, 12, 14, 18, 24, 36, 48, 72 };
const float[4] COMPARE_SIZES @local = { 11, 12, 13, 14 };
const float MARGIN @local = 24;
const float LINE_GAP @local = 1.25f; // line pitch in ems
const float ZOOM_MIN @local = 8;
const float ZOOM_MAX @local = 400;
const float ZOOM_RADIANS_PER_SECOND @local = 0.4f;
const float BENCHMARK_SIZE @local = 14;
const float COMPARE_COLUMN @local = 640;

const String LATIN_SAMPLE @local = "The quick brown fox jumps over the lazy dog 0123456789";
const String MIXED_SAMPLE @local = "Text 文字 Текст Κείμενο テキスト";
const String[4] SCRIPT_SAMPLES @local = {
    "Съешь же ещё этих мягких французских булок",
    "Ξεσκεπάζω την ψυχοφθόρα βδελυγμία",
    "我能吞下玻璃而不伤身体。",
    "いろはにほへと ちりぬるを カタカナとひらがな",
};
const String ZOOM_SAMPLE @local = "Zoom 缩放 ズーム";
// One hundred distinct GB2312 level 1 hanzi: the first-seen paragraph of --stats and the CJK line of --benchmark.
const String CJK_PARAGRAPH @local = "啦袱奥震钨递畜卞恤诈捣罕疚萄挖鞍蒋鸣吝馏整了怒月诌"
    "劣钓炕牟簧饰莉冲读腰婚幸奏荧皱别扔价茶怯椽稍蚜耗黎"
    "逊毅拱而覆肃治孤舔搓钻姑釉程脸湿速砾硷慎但我却悬里"
    "插评争纸磅当深稀逸催党鹤瓢闲叭跟蔓辟兜执滩娠纵武怨";

const Vec4 TEXT_COLOR @local = { 0.93f, 0.92f, 0.88f, 1 };
const Vec4 LABEL_COLOR @local = { 0.55f, 0.75f, 1, 1 };
const Vec2 STATS_PANEL_POSITION @local = { 1010, 16 };
const Vec2 STATS_PANEL_SIZE @local = { 260, 120 };

struct Options @local {
    bool compare;
    bool stats;
    bool benchmark;
    uint glyphs;
    uint frames;
    uint width;
    uint height;
}

struct Fonts @local {
    AssetStore* assets;
    FontId      latin;
    FontId      cjk;
}

struct TextLine @local {
    String text;
    Vec2   origin; // baseline start in output pixels; y is rounded
    float  size;
    Vec4   color;
}

// One RGBA8 image of a line rasterized by stb_truetype at whole-pixel pen positions.
struct BitmapLine @local {
    TextureId texture;
    Vec2      size;
    float     ascent;
}

struct Demo @local {
    platform::Window* window;
    Renderer*         renderer;
    Scene*            scene;
    Node*             camera_node;
    Fonts             fonts;
    OverlayList*      list;
    BitmapLine[8]     bitmaps; // COMPARE_SIZES by row: Latin then CJK
    bool              compare;
    bool              zoom_paused;
    float             zoom_time;
    double            prepare_ms;
    uint              overlay_draws;
}

fn FontId? add_example_font(AssetStore* assets, char[] file, String key) @local {
    return assets.add_font(file, asset::default_font_desc(), key);
}

fn Fonts? load_fonts(AssetStore* assets) @local {
    return {
        .assets = assets,
        .latin  = add_example_font(assets, $embed("../assets/fonts/NotoSans-Regular.ttf"), "text/latin")!,
        .cjk    = add_example_font(assets, $embed("../assets/fonts/NotoSansCJKsc-Regular-GB2312-L1.otf"), "text/cjk")!,
    };
}

// Splits the line where the Latin font lacks a glyph, so CJK runs fall back to the CJK font.
fn float? add_line(Fonts* fonts, OverlayList* list, TextLine line) @local {
    String text = line.text;
    float pen = line.origin.x;
    usz start;
    while (start < text.len) {
        bool latin = covers(fonts, text, start);
        usz end = start;
        while (end < text.len && covers(fonts, text, end) == latin) end += code_point_size(text, end);

        FontId font = latin ? fonts.latin : fonts.cjk;
        String segment = text[start:end - start];
        GlyphPlacement[MAX_LINE_GLYPHS] placements;
        usz count = fonts.assets.place_text(font, segment, placements[..])!;
        list.add_glyphs({
            .font        = font,
            .glyphs      = placements[:count],
            .origin      = { pen, math::round(line.origin.y) },
            .size_pixels = line.size,
            .color       = line.color,
        })!;
        pen += fonts.assets.measure_text(font, segment, line.size)!.width;
        start = end;
    }
    return pen - line.origin.x;
}

fn bool covers(Fonts* fonts, String text, usz offset) @local {
    sz size = (sz)(text.len - offset);
    Char32 code_point = conv::utf8_to_char32(&text[offset], &size) ?? 0;
    return code_point == ' ' || @ok(fonts.assets.find_glyph(fonts.latin, code_point));
}

fn usz code_point_size(String text, usz offset) @local {
    sz size = (sz)(text.len - offset);
    (void)conv::utf8_to_char32(&text[offset], &size);
    return (usz)size;
}

fn void? fill_page(Demo* demo, float width) @local {
    OverlayList* list = demo.list;
    list.clear();
    float y = MARGIN;
    foreach (size : SAMPLE_SIZES) {
        y += size * LINE_GAP;
        add_line(&demo.fonts, list, {
            .text   = LATIN_SAMPLE,
            .origin = { MARGIN, y },
            .size   = size,
            .color  = TEXT_COLOR,
        })!;
    }

    y += 36 * LINE_GAP;
    add_line(&demo.fonts, list, { .text = MIXED_SAMPLE, .origin = { MARGIN, y }, .size = 36, .color = LABEL_COLOR })!;
    foreach (sample : SCRIPT_SAMPLES) {
        y += 24 * LINE_GAP;
        add_line(&demo.fonts, list, { .text = sample, .origin = { MARGIN, y }, .size = 24, .color = TEXT_COLOR })!;
    }

    float wave = 0.5f - 0.5f * math::cos(demo.zoom_time * ZOOM_RADIANS_PER_SECOND);
    float zoom_size = ZOOM_MIN + (ZOOM_MAX - ZOOM_MIN) * wave;
    list.push_clip({ 0, y + 8 }, { width, (float)demo.renderer.output_height })!;
    add_line(&demo.fonts, list, {
        .text   = ZOOM_SAMPLE,
        .origin = { MARGIN, y + 8 + zoom_size },
        .size   = zoom_size,
        .color  = TEXT_COLOR,
    })!;
    list.pop_clip();
}

fn void? fill_compare_page(Demo* demo) @local {
    OverlayList* list = demo.list;
    list.clear();
    float y = MARGIN;
    foreach (row, size : COMPARE_SIZES) {
        y += 18 * LINE_GAP;
        String label = string::tformat("%d px: Slug, then stb_truetype bitmaps", (int)size);
        add_line(&demo.fonts, list, { .text = label, .origin = { MARGIN, y }, .size = 14, .color = LABEL_COLOR })!;
        String[2] samples = { LATIN_SAMPLE, SCRIPT_SAMPLES[2] };
        foreach (index, sample : samples) {
            float column = MARGIN + (float)index * COMPARE_COLUMN;
            float baseline = y + size * LINE_GAP;
            add_line(&demo.fonts, list, {
                .text   = sample,
                .origin = { column, baseline },
                .size   = size,
                .color  = TEXT_COLOR,
            })!;

            BitmapLine* bitmap = &demo.bitmaps[row * 2 + index];
            Vec2 top_left = { column, math::round(baseline + size * LINE_GAP) - bitmap.ascent };
            OverlayRect rect = render::OVERLAY_RECT_DEFAULT;
            rect.min = top_left;
            rect.max = top_left + bitmap.size;
            rect.fill = TEXT_COLOR;
            rect.texture = { .kind = ASSET, .asset = bitmap.texture };
            rect.sampler = asset::SAMPLER_NEAREST;
            list.add_rect(rect)!;
        }
        y += size * LINE_GAP * 2;
    }
}

// Rasterizes the line once with stb_truetype at pixel-snapped pen positions, white with coverage in alpha.
fn BitmapLine? rasterize_line(Fonts* fonts, FontId font, String text, float size) @local {
    AssetStore* assets = fonts.assets;
    GlyphPlacement[MAX_LINE_GLYPHS] placements;
    usz count = assets.place_text(font, text, placements[..])!;
    TextExtent extent = assets.measure_text(font, text, size)!;
    uint width = (uint)math::ceil(extent.width) + 2;
    uint ascent = (uint)math::ceil(extent.ascent);
    uint height = ascent + (uint)math::ceil(-extent.descent) + 1;

    char[] pixels = alloc::new_array(assets.allocator, char, (sz)width * height * 4);
    defer catch alloc::free(assets.allocator, pixels.ptr);
    for (usz index = 0; index < pixels.len; index += 4) {
        pixels[index] = 255;
        pixels[index + 1] = 255;
        pixels[index + 2] = 255;
    }

    @pool() {
        foreach (placement : placements[:count]) {
            float pen = placement.position.x * size;
            float whole = math::floor(pen);
            Vec2 subpixel = { pen - whole, 0 };
            GlyphBitmapBox box = assets.glyph_bitmap_box(
                font:        font,
                glyph:       placement.glyph,
                size_pixels: size,
                subpixel:    subpixel,
            );
            uint box_width = (uint)(box.max_x - box.min_x);
            uint box_height = (uint)(box.max_y - box.min_y);
            if (!box_width || !box_height) continue;

            char[] coverage = alloc::new_array(tmem, char, (sz)box_width * box_height);
            assets.rasterize_glyph(
                font:        font,
                glyph:       placement.glyph,
                size_pixels: size,
                subpixel:    subpixel,
                coverage:    coverage,
            );
            for (uint row = 0; row < box_height; row++) {
                for (uint column = 0; column < box_width; column++) {
                    int x = (int)whole + box.min_x + (int)column;
                    int y = (int)ascent + box.min_y + (int)row;
                    if (x < 0 || y < 0 || x >= (int)width || y >= (int)height) continue;
                    usz alpha = ((usz)y * width + (usz)x) * 4 + 3;
                    pixels[alpha] = math::max(pixels[alpha], coverage[row * box_width + column]);
                }
            }
        }
    };

    material::TextureDesc desc = material::texture_2d_desc(width, height, RGBA8_UNORM);
    desc.generate_mips = false;
    TextureId texture = assets.add_texture_owned(desc, pixels)!;
    return { .texture = texture, .size = { (float)width, (float)height }, .ascent = (float)ascent };
}

fn void? build_bitmaps(Demo* demo) @local {
    foreach (row, size : COMPARE_SIZES) {
        demo.bitmaps[row * 2] = rasterize_line(
            fonts: &demo.fonts,
            font:  demo.fonts.latin,
            text:  LATIN_SAMPLE,
            size:  size,
        )!;
        demo.bitmaps[row * 2 + 1] = rasterize_line(
            fonts: &demo.fonts,
            font:  demo.fonts.cjk,
            text:  SCRIPT_SAMPLES[2],
            size:  size,
        )!;
    }
}

fn void? draw_frame(Demo* demo, GuiRenderer* gui_renderer, FrameInfo info) @local {
    Renderer* renderer = demo.renderer;
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
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

fn void? run_interactive(Demo* demo, Options* options) @local {
    platform::Window* window = demo.window;
    Renderer* renderer = demo.renderer;
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);

    uint frames;
    while (window.poll()) {
        if (options.frames && frames >= options.frames) break;
        if (window.input.key_released(platform::Scancode.ESCAPE)) break;
        if (window.input.key_pressed(platform::Scancode.SPACE)) demo.zoom_paused = !demo.zoom_paused;
        if (!demo.zoom_paused) demo.zoom_time += (float)window.clock.delta;

        gui_renderer.new_frame();
        defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
        imgui::set_next_window_pos(STATS_PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
        imgui::set_next_window_size(STATS_PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
        if (imgui::begin("Text", null, {})) {
            imgui::text("Glyphs: %u of %u", demo.list.glyph_count, (uint)demo.list.glyphs.len);
            imgui::text("Prepare: %.3f ms", demo.prepare_ms);
            imgui::text("Space pauses the zoom");
        }
        imgui::end();

        platform::sync_window(window, renderer);
        if (renderer.output_width && renderer.output_height) {
            @pool() {
                if (demo.compare) {
                    fill_compare_page(demo)!;
                } else {
                    fill_page(demo, (float)renderer.output_width)!;
                }
            };
        }
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

fn void? fill_benchmark(Demo* demo, uint glyphs) @local {
    OverlayList* list = demo.list;
    list.clear();
    float y = MARGIN + BENCHMARK_SIZE;
    add_line(&demo.fonts, list, {
        .text   = CJK_PARAGRAPH,
        .origin = { MARGIN, y },
        .size   = BENCHMARK_SIZE,
        .color  = TEXT_COLOR,
    })!;
    while (list.glyph_count < glyphs) {
        y += BENCHMARK_SIZE * LINE_GAP;
        if (y > (float)demo.renderer.output_height) y = MARGIN + BENCHMARK_SIZE;
        add_line(&demo.fonts, list, {
            .text   = LATIN_SAMPLE,
            .origin = { MARGIN, y },
            .size   = BENCHMARK_SIZE,
            .color  = TEXT_COLOR,
        })!;
    }
}

fn void? run_benchmark(Demo* demo, Options* options) @local {
    platform::Window* window = demo.window;
    Renderer* renderer = demo.renderer;

    double fill_ms;
    double prepare_ms;
    double first_prepare_ms;
    double overlay_gpu_ms;
    uint gpu_samples;
    uint draws;
    uint frame;
    while (window.poll() && frame < options.frames * 2) {
        platform::sync_window(window, renderer);
        if (!renderer.output_width || !renderer.output_height) continue;

        time::Clock started = clock::now();
        fill_benchmark(demo, options.glyphs)!;
        double elapsed_fill_ms = (double)started.to_now() / NANOSECONDS_PER_MILLISECOND;
        draw_frame(
            demo:         demo,
            gui_renderer: null,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;

        if (!frame) first_prepare_ms = demo.prepare_ms;
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
        "glyphs=%d width=%d height=%d fill_ms=%.4f prepare_ms=%.4f first_prepare_ms=%.4f overlay_gpu_ms=%.4f draws=%d",
        demo.list.glyph_count,
        renderer.output_width,
        renderer.output_height,
        fill_ms / measured,
        prepare_ms / measured,
        first_prepare_ms,
        gpu_samples ? overlay_gpu_ms / gpu_samples : 0.0,
        draws,
    );
}

// Code points of each range as one UTF-8 string; unmapped ones place .notdef once.
fn String range_text(Char32 first, Char32 last) @local {
    DString text;
    text.init(tmem);
    for (Char32 code_point = first; code_point <= last; code_point++) text.append_char32(code_point);
    return text.str_view();
}

fn void? place_all(AssetStore* assets, FontId font, String text) @local {
    GlyphPlacement[MAX_LINE_GLYPHS] placements;
    usz start;
    while (start < text.len) {
        usz end = start;
        for (uint count = 0; count < MAX_LINE_GLYPHS && end < text.len; count++) end += code_point_size(text, end);
        assets.place_text(font, text[start:end - start], placements[..])!;
        start = end;
    }
}

fn void print_font_stats(String name, FontAsset* font) @local {
    double glyphs = (double)font.glyph_count;
    io::printfn(
        "%s: glyphs=%d curve_texels=%d (%.1f per glyph) band_texels=%d (%.1f per glyph) "
        "store_bytes_per_glyph=%.0f gpu_bytes_per_glyph=%.0f curve_rows=%d band_rows=%d",
        name,
        font.glyph_count,
        font.curve_texels,
        (double)font.curve_texels / glyphs,
        font.band_texels,
        (double)font.band_texels / glyphs,
        (16.0 * font.curve_texels + 4.0 * font.band_texels) / glyphs,
        (8.0 * font.curve_texels + 4.0 * font.band_texels) / glyphs,
        (font.curve_texels + asset::FONT_TEXTURE_WIDTH - 1) / asset::FONT_TEXTURE_WIDTH,
        (font.band_texels + asset::FONT_TEXTURE_WIDTH - 1) / asset::FONT_TEXTURE_WIDTH,
    );
}

fn void? run_stats() @local {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    FontDesc largest = {
        .max_glyphs   = 8192,
        .curve_texels = asset::FONT_TEXTURE_WIDTH * asset::FONT_MAX_ROWS,
        .band_texels  = asset::FONT_TEXTURE_WIDTH * asset::FONT_MAX_ROWS,
    };

    FontId paragraph_font = assets.add_font($embed("../assets/fonts/NotoSansCJKsc-Regular-GB2312-L1.otf"), largest)!;
    GlyphPlacement[MAX_LINE_GLYPHS] placements;
    time::Clock started = clock::now();
    assets.place_text(paragraph_font, CJK_PARAGRAPH, placements[..])!;
    double place_ms = (double)started.to_now() / NANOSECONDS_PER_MILLISECOND;
    io::printfn("first-seen paragraph: %d hanzi place_ms=%.3f", assets.font(paragraph_font).glyph_count, place_ms);

    FontId latin = assets.add_font($embed("../assets/fonts/NotoSans-Regular.ttf"), largest)!;
    FontId cjk = assets.add_font($embed("../assets/fonts/NotoSansCJKsc-Regular-GB2312-L1.otf"), largest)!;
    @pool() {
        place_all(&assets, latin, range_text(0x20, 0x17F))!;
        place_all(&assets, latin, range_text(0x370, 0x3FF))!;
        place_all(&assets, latin, range_text(0x400, 0x4FF))!;
        place_all(&assets, cjk, range_text(0x20, 0x7E))!;
        place_all(&assets, cjk, range_text(0x3000, 0x30FF))!;
        place_all(&assets, cjk, range_text(0x4E00, 0x9FA5))!;
        place_all(&assets, cjk, range_text(0xFF01, 0xFF5E))!;
    };
    print_font_stats("latin", assets.font(latin));
    print_font_stats("cjk", assets.font(cjk));
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
        .glyphs = DEFAULT_BENCHMARK_GLYPHS,
        .width  = WINDOW_WIDTH,
        .height = WINDOW_HEIGHT,
    };
    bool frames_given;
    for (usz index = 1; index < args.len; index++) {
        String argument = args[index];
        bool has_value = index + 1 < args.len;
        if (argument == "--compare") {
            options.compare = true;
        } else if (argument == "--stats") {
            options.stats = true;
        } else if (argument == "--benchmark") {
            options.benchmark = true;
        } else if (argument == "--glyphs" && has_value) {
            options.glyphs = args[++index].to_uint() ?? 0;
        } else if (argument == "--frames" && has_value) {
            options.frames = args[++index].to_uint() ?? 0;
            frames_given = true;
            if (!options.frames) return 1;
        } else if (argument == "--size" && has_value) {
            uint[2]? size = parse_size(args[++index]);
            if (catch size) return 1;
            options.width = size[0];
            options.height = size[1];
        } else {
            io::eprintn("Use text [--compare] [--stats] [--frames N] [--benchmark --glyphs N --frames F --size WxH].");
            return 1;
        }
    }
    if (options.stats) {
        if (catch excuse = run_stats()) {
            io::eprintfn("Text statistics failed: %s", excuse);
            return 1;
        }
        return 0;
    }
    if (options.benchmark && !frames_given) options.frames = DEFAULT_BENCHMARK_FRAMES;

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d text", options.width, options.height))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .gpu_timings = true, .application_name = "c3d_text" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    Node* camera_node = scene.add_camera(camera::perspective_deg(50, 0.1f), name: "camera")!!;
    scene.update_world();

    uint glyph_capacity = (options.benchmark ? options.glyphs + MAX_LINE_GLYPHS : 0) + LIST_GLYPH_RESERVE;
    OverlayList list = render::create_overlay_list(mem, {
        .max_items  = glyph_capacity / 4 + LIST_ITEM_RESERVE,
        .max_clips  = render::OVERLAY_LIST_DEFAULT_CLIPS,
        .max_glyphs = glyph_capacity,
    });
    defer render::destroy_overlay_list(&list);

    Demo demo = {
        .window      = &window,
        .renderer    = &renderer,
        .scene       = &scene,
        .camera_node = camera_node,
        .fonts       = load_fonts(&assets)!!,
        .list        = &list,
        .compare     = options.compare,
    };
    if (options.compare) build_bitmaps(&demo)!!;

    fault excuse = options.benchmark
        ? @catch(run_benchmark(&demo, &options))
        : @catch(run_interactive(&demo, &options));
    if (excuse) {
        io::eprintfn("Text example failed: %s", excuse);
        return 1;
    }
    if (catch renderer.log.check_validation()) {
        io::eprintn("Validation reported errors.");
        return 1;
    }
    return 0;
}
