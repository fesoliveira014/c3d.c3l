module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::render @public;
import c3d::shader;
import c3d::scene;
import gpu;
import std::io;
import std::math;

const uint TILE_TEXELS @private = shader::POST_TILE_SIZE * shader::POST_TILE_SIZE;
const uint[<2>][*] TILE_EXTENTS @private = {
    { 1, 1 }, { 1, 19 }, { 19, 1 }, { 3, 5 }, { 15, 17 },
    { 17, 15 }, { 31, 33 }, { 33, 31 }, { 256, 256 },
};

enum TilePattern @private {
    ZERO,
    ISOLATED_MAXIMUM,
    TIED_MAXIMUM,
    MIXED,
}

fn Vec4 tile_input_value(uint x, uint y, TilePattern pattern) @private {
    uint lane = (y % shader::POST_TILE_SIZE) * shader::POST_TILE_SIZE + x % shader::POST_TILE_SIZE;
    uint tile = (y / shader::POST_TILE_SIZE) * shader::POST_TILE_SIZE + x / shader::POST_TILE_SIZE;
    uint first = tile % TILE_TEXELS;
    switch (pattern) {
        case ZERO: return {};
        case ISOLATED_MAXIMUM: return lane == first ? (Vec4){ 3, 4, 0, 1 } : (Vec4){};
        case TIED_MAXIMUM:
            if (lane == first) return { 3, 4, 0, 0.75f };
            if (lane > first) return { -4, 3, 0, 0.75f };
            return {};
        case MIXED:
            return {
                (float)((int)((x * 7 + y * 3) % 9) - 4),
                (float)((int)((x * 5 + y * 11) % 9) - 4),
                0,
                (float)((x * 13 + y * 7) % 31) / 32,
            };
    }
}

fn Vec2 tile_reference(
    uint[<2>] extent,
    uint[<2>] tile,
    TilePattern pattern,
    uint mode,
) @private {
    Vec2 selected;
    float largest = -1;
    for (uint row = 0; row < shader::POST_TILE_SIZE; row++) {
        for (uint column = 0; column < shader::POST_TILE_SIZE; column++) {
            uint x = tile.x * shader::POST_TILE_SIZE + column;
            uint y = tile.y * shader::POST_TILE_SIZE + row;
            Vec4 value;
            if (x < extent.x && y < extent.y) value = tile_input_value(x, y, pattern);
            Vec2 candidate = mode == shader::TILE_MODE_ALPHA ? (Vec2){ value.w, 0 } : (Vec2){ value.x, value.y };
            float metric = mode == shader::TILE_MODE_ALPHA ? value.w : candidate.dot(candidate);
            if (metric > largest) {
                largest = metric;
                selected = candidate;
            }
        }
    }
    return selected;
}

fn void? check_tile_reduction(
    Fixture* fixture,
    uint[<2>] extent,
    TilePattern pattern,
    uint mode,
    gpu::Format format,
) @private {
    Renderer* renderer = &fixture.renderer;
    uint channels = format == gpu::Format.RG16_FLOAT ? 2u : 4u;
    uint[<2>] tiles = {
        (extent.x + shader::POST_TILE_SIZE - 1) / shader::POST_TILE_SIZE + 1,
        (extent.y + shader::POST_TILE_SIZE - 1) / shader::POST_TILE_SIZE + 1,
    };
    Target input = render::allocate_storage_target(
        device: &renderer.device,
        width: extent.x,
        height: extent.y,
        format: format,
        debug_name: "tile_input",
        usage: { .storage, .transfer_dst },
    )!;
    defer render::release_storage_target(&renderer.device, &input);
    Target output = render::allocate_storage_target(
        device: &renderer.device,
        width: tiles.x,
        height: tiles.y,
        format: gpu::Format.RG16_FLOAT,
        debug_name: "tile_output",
        usage: { .storage, .transfer_src },
    )!;
    defer render::release_storage_target(&renderer.device, &output);
    gpu::AllocationDesc allocation = {
        .size = (usz)tiles.x * tiles.y * 2 * ushort::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "tile_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &allocation)!;
    defer {
        gpu::GpuAllocation owned = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &owned)!!;
    }

    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(
        &renderer.device,
        (usz)extent.x * extent.y * channels * ushort::size,
    )!;
    ushort* pixels = (ushort*)staging.bytes.ptr;
    for (uint y = 0; y < extent.y; y++) {
        for (uint x = 0; x < extent.x; x++) {
            Vec4 value = tile_input_value(x, y, pattern);
            usz first = ((usz)y * extent.x + x) * channels;
            for (uint channel = 0; channel < channels; channel++) {
                pixels[first + channel] = asset::encode_texture_half(value[channel]);
            }
        }
    }
    input.transition(&renderer.commands, {
        .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
        .stages = { .transfer },
        .access = { .write },
    })!;
    gpu::BufferTextureCopyDesc upload = { .src = staging.span, .texture = input.texture };
    gpu::cmd_copy_buffer_to_texture(&renderer.commands, &upload)!;
    input.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
    output.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, shader::TileRoot::size)!;
    *(shader::TileRoot*)root.bytes.ptr = {
        .input_texture = input.view.index,
        .output_texture = output.view.index,
        .width = tiles.x,
        .height = tiles.y,
        .mode = mode,
    };
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.tile_max)!;
    gpu::cmd_dispatch(&renderer.commands, root.address, { tiles.x, tiles.y, 1 })!;
    renderer.work_recorded = true;
    output.transition(&renderer.commands, render::TRANSFER_SOURCE_STATE)!;
    gpu::TextureBufferCopyDesc copy = { .texture = output.texture, .dst = readback.span };
    gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
    gpu::Barrier to_host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &to_host)!;
    renderer.end_frame()!;
    assert(renderer.frame_submitted);
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;

    check_validation(renderer);
    ushort* actual = (ushort*)readback.bytes.ptr;
    for (uint y = 0; y < tiles.y; y++) {
        for (uint x = 0; x < tiles.x; x++) {
            Vec2 expected = tile_reference(
                extent: extent,
                tile: { x, y },
                pattern: pattern,
                mode: mode,
            );
            ushort[2] packed = { asset::encode_texture_half(expected.x), asset::encode_texture_half(expected.y) };
            usz first = ((usz)y * tiles.x + x) * 2;
            assert(actual[first] == packed[0] && actual[first + 1] == packed[1],
                "Tile mismatch: extent %s, tile (%s, %s), pattern %s, mode %s, format %s, actual %x/%x expected %x/%x",
                extent, x, y, pattern, mode, format, actual[first], actual[first + 1], packed[0], packed[1]);
        }
    }
}

fn void test_post_tile_reduction_matches_row_major_selection() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    render::acquire_compute_slot(&fixture.renderer, ComputeSlot.TILE_MAX)!!;
    uint checked = 0;
    foreach (extent : TILE_EXTENTS) {
        foreach (pattern : TilePattern::values) {
            check_tile_reduction(
                fixture: &fixture,
                extent: extent,
                pattern: pattern,
                mode: shader::TILE_MODE_ALPHA,
                format: gpu::Format.RGBA16_FLOAT,
            )!!;
            check_tile_reduction(
                fixture: &fixture,
                extent: extent,
                pattern: pattern,
                mode: shader::TILE_MODE_VELOCITY,
                format: gpu::Format.RG16_FLOAT,
            )!!;
            check_tile_reduction(
                fixture: &fixture,
                extent: extent,
                pattern: pattern,
                mode: shader::TILE_MODE_VELOCITY,
                format: gpu::Format.RGBA16_FLOAT,
            )!!;
            checked += 3;
        }
    }
    io::eprintfn("Tile selection: %s input cases passed with exact RG16 output.", checked);
}

fn void test_post_tile_reduction_runs_dof_blur_and_combined() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    DeformedScene colored = create_single_box_scene(&fixture, fixture.colored_box, fixture.plain, false)!!;
    defer scene::destroy_scene(&colored.scene);
    Renderer* renderer = &fixture.renderer;
    for (uint mode = 1; mode <= 3; mode++) {
        ViewDesc desc = render::texture_view_desc(fixture.ldr_target, OutputMode.DISPLAY_LDR);
        desc.render_scale = 0.7f;
        desc.post.depth_of_field = (mode & 1) != 0;
        desc.post.motion_blur = (mode & 2) != 0;
        render::configure_view(renderer, fixture.display_view, desc)!!;
        colored.camera.local.position.x = 0;
        render_display_and_sample(&fixture, &colored)!!;
        colored.camera.local.position.x = 0.1f;
        render_display_and_sample(&fixture, &colored)!!;
        uint pixel = read_pixel(&fixture);
        check_opaque_color(pixel);
        io::eprintfn("Post tile mode %s: pixel %08x, dispatches %s.", mode, pixel, renderer.stats.post_dispatches);
        check_validation(renderer);
    }
}