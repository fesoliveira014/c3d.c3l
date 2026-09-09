module cube_texture_example;

import std::io;
import std::io::path;
import std::math;
import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::material;
import c3d::platform;
import c3d::render;
import c3d::shader;
import gpu;
import sdl;

const uint FULLSCREEN_VERTEX_COUNT @local = 3;
const uint SUPPLIED_FACE_SIZE @local = 4;
const uint SUPPLIED_MIP_COUNT @local = 2;
const uint RGBA_CHANNELS @local = 4;
const usz BASE_FACE_BYTES @local = SUPPLIED_FACE_SIZE * SUPPLIED_FACE_SIZE * RGBA_CHANNELS;
const usz TAIL_FACE_BYTES @local = (SUPPLIED_FACE_SIZE / 2) * (SUPPLIED_FACE_SIZE / 2) * RGBA_CHANNELS;
const String[material::CUBE_FACE_COUNT] FACE_FILES @local = {
    "positive_x.png", "negative_x.png", "positive_y.png", "negative_y.png", "positive_z.png", "negative_z.png",
};
const String[material::CUBE_FACE_COUNT] FACE_NAMES @local = { "+X", "-X", "+Y", "-Y", "+Z", "-Z" };
const sdl::Scancode[material::CUBE_FACE_COUNT] FACE_KEYS @local = {
    sdl::Scancode.CODE_1, sdl::Scancode.CODE_2, sdl::Scancode.CODE_3,
    sdl::Scancode.CODE_4, sdl::Scancode.CODE_5, sdl::Scancode.CODE_6,
};
const char[material::CUBE_FACE_COUNT * RGBA_CHANNELS] FACE_COLORS @local = {
    255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255,
    255, 255, 0, 255, 255, 0, 255, 255, 0, 255, 255, 255,
};

fn TextureId? add_supplied_cube(AssetStore* assets) @local {
    @pool() {
        char[] base = mem::temp_array(char, BASE_FACE_BYTES * material::CUBE_FACE_COUNT);
        char[] tail = mem::temp_array(char, TAIL_FACE_BYTES * material::CUBE_FACE_COUNT);
        TextureMipData[material::CUBE_FACE_COUNT * SUPPLIED_MIP_COUNT] levels;
        for (uint face = 0; face < material::CUBE_FACE_COUNT; face++) {
            for (usz index = 0; index < BASE_FACE_BYTES; index++) {
                base[(usz)face * BASE_FACE_BYTES + index] = FACE_COLORS[(usz)face * RGBA_CHANNELS + index % RGBA_CHANNELS];
            }
            for (usz index = 0; index < TAIL_FACE_BYTES; index++) {
                uint next_face = (face + 1) % material::CUBE_FACE_COUNT;
                tail[(usz)face * TAIL_FACE_BYTES + index] = FACE_COLORS[(usz)next_face * RGBA_CHANNELS + index % RGBA_CHANNELS];
            }
            levels[face] = {
                .mip = 0,
                .layer = face,
                .bytes = base[(usz)face * BASE_FACE_BYTES:BASE_FACE_BYTES],
            };
            levels[material::CUBE_FACE_COUNT + face] = {
                .mip = 1,
                .layer = face,
                .bytes = tail[(usz)face * TAIL_FACE_BYTES:TAIL_FACE_BYTES],
            };
        }
        material::TextureDesc desc = material::texture_cube_desc(SUPPLIED_FACE_SIZE, RGBA8_SRGB);
        desc.generate_mips = false;
        desc.mip_levels = SUPPLIED_MIP_COUNT;

        return assets.add_texture_mips(desc, levels[..], "example/supplied_cube");
    };
}

fn void? draw_cube_frame(
    render::Renderer* renderer,
    TextureId texture,
    SamplerId sampler,
    CubeFace face,
    float lod,
    bool explicit_lod,
) @local {
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);

    if (renderer.has_output) {
        renderer.clear({ 0, 0, 0, 1 })!;
        PipelineKey key = {
            .vertex = { .shader = FULLSCREEN },
            .fragment = { .shader = CUBE_PREVIEW },
            .color_formats = { [0] = renderer.window_target.format },
            .color_count = 1,
            .depth_format = gpu::Format.UNDEFINED,
            .samples = gpu::SampleCount.ONE,
            .polygon = gpu::PolygonMode.FILL,
        };
        gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, key)!;
        gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;

        OverlayContext overlay = renderer.begin_overlay()!;
        gpu::MappedGpuSpan span = overlay.alloc(CubePreviewRoot::size)!;
        CubePreviewRoot* root = (CubePreviewRoot*)span.bytes.ptr;
        *root = {
            .source_texture = renderer.textures[texture.index].view.index,
            .source_sampler = renderer.samplers[sampler.index].index,
            .lod = lod,
            .face = (uint)face.ordinal,
            .explicit_lod = explicit_lod ? 1u : 0u,
        };
        gpu::ColorTargetState[1] colors = { gpu::color_blend_disabled() };
        gpu::GraphicsState state = render::fullscreen_state(overlay.width, overlay.height, colors[..])!;
        gpu::cmd_set_graphics_state(overlay.commands, &state)!;
        gpu::cmd_draw(
            commands: overlay.commands,
            vertex_root: (gpu::GpuAddress)0,
            fragment_root: span.address,
            vertex_count: FULLSCREEN_VERTEX_COUNT,
            instance_count: 1,
        )!;
        renderer.end_overlay(&overlay)!;
    }

    renderer.end_frame()!;
}


fn void? run(String[] args) @local {
    if (args.len != 1 && args.len != material::CUBE_FACE_COUNT + 1) {
        io::printn("usage: texture_cube [positive_x negative_x positive_y negative_y positive_z negative_z]");
        return c3d::INVALID_ARGUMENT~;
    }

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    TextureId loaded;
    @pool() {
        String[material::CUBE_FACE_COUNT] paths;
        Path source = path::tnew($$FILEPATH)!;
        for (usz face = 0; face < material::CUBE_FACE_COUNT; face++) {
            paths[face] = args.len == 1
                ? (String)source.parent()!.tappend("../assets/cube", FACE_FILES[face])!
                : args[face + 1];
        }
        loaded = image::load_cube(&assets, paths, true)!;
    };
    TextureId supplied = add_supplied_cube(&assets)!;
    SamplerId sampler = asset::SAMPLER_LINEAR_CLAMP;

    platform::Window window = platform::create_window(
        platform::default_window_desc("c3d cube texture", 512, 512))!;
    defer platform::destroy_window(&window);
    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &assets,
        desc: { .validation = true, .application_name = "c3d_cube_texture" },
    )!;
    defer render::destroy_renderer(&renderer);
    renderer.upload(loaded)!;
    renderer.upload(supplied)!;
    renderer.upload(sampler)!;

    CubeFace face = CubeFace.POSITIVE_X;
    float lod;
    bool explicit_lod;
    bool use_supplied;
    io::printn("1..6 select +X -X +Y -Y +Z -Z; C switches generated/supplied; L toggles LOD mode");
    io::printn("Plus/minus select explicit LOD; Escape release quits. Resize below 256 pixels to minify file faces.");
    while (window.poll()) {
        Input* input = &window.input;
        if (input.keys_released[(usz)sdl::Scancode.ESCAPE]) break;

        bool changed = window.resized;
        foreach (index, key : FACE_KEYS) {
            if (input.keys_pressed[(usz)key]) {
                face = (CubeFace)index;
                changed = true;
            }
        }
        if (input.keys_pressed[(usz)sdl::Scancode.C]) {
            use_supplied = !use_supplied;
            changed = true;
        }
        if (input.keys_pressed[(usz)sdl::Scancode.L]) {
            explicit_lod = !explicit_lod;
            changed = true;
        }
        bool increase = input.keys_pressed[(usz)sdl::Scancode.EQUALS]
            || input.keys_pressed[(usz)sdl::Scancode.KP_PLUS];
        bool decrease = input.keys_pressed[(usz)sdl::Scancode.MINUS]
            || input.keys_pressed[(usz)sdl::Scancode.KP_MINUS];
        if (increase || decrease) {
            lod += increase ? 1.0f : -1.0f;
            explicit_lod = true;
            changed = true;
        }

        TextureId selected = use_supplied ? supplied : loaded;
        lod = math::clamp(lod, 0.0f, (float)(renderer.textures[selected.index].mip_count - 1));
        if (changed) {
            io::printf("face %s, source %s", FACE_NAMES[face.ordinal], use_supplied ? "supplied" : "files");
            io::printf(", explicit %s, lod %.1f", explicit_lod, lod);
            io::printfn(", framebuffer %dx%d", window.width, window.height);
        }
        platform::sync_window(&window, &renderer);
        draw_cube_frame(
            renderer: &renderer,
            texture: selected,
            sampler: sampler,
            face: face,
            lod: lod,
            explicit_lod: explicit_lod,
        )!;
    }
}

fn int main(String[] args) {
    if (catch excuse = run(args)) {
        io::printfn("Cube texture example failed: %s", excuse);
        return 1;
    }
    return 0;
}
