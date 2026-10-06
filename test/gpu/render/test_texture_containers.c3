module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::material;
import c3d::render @public;
import gpu;
import std::io;

const char[*] CONTAINER_LOD_SOURCE @private = $embed("sample_lod.comp.glsl");
const uint CONTAINER_GROUP_SIZE @private = 8; // mirrored as local_size_x and local_size_y in sample_lod.comp.glsl
const uint CONTAINER_MAX_EXTENT @private = 64;
const usz CONTAINER_OUTPUT_BYTES @private = (usz)CONTAINER_MAX_EXTENT * CONTAINER_MAX_EXTENT * uint::size;
const uint CONTAINER_ORIENTATION_EXTENT @private = 4;
const uint CONTAINER_ORIENTATION_MIPS @private = 3;
const uint CONTAINER_BC_EXTENT @private = 64;
const usz[7] CONTAINER_BC_OFFSETS @private = { 0, 2048, 2560, 2688, 2720, 2728, 2736 };
const usz[7] CONTAINER_BC_BYTES @private = { 2048, 512, 128, 32, 8, 8, 8 };
const uint[7] CONTAINER_BC_COLORS @private = {
    0xFF0000FF, 0xFF00FF00, 0xFFFF0000, 0xFF00FFFF, 0xFFFF00FF, 0xFFFFFF00, 0xFFFFFFFF,
}; // packUnorm4x8 of red, green, blue, yellow, magenta, cyan and white

struct ContainerLodRoot @private { // mirrored as LodSampleRoot in sample_lod.comp.glsl
    gpu::GpuAddress output_address;
    uint lod;
    uint width;
    uint height;
    uint padding;
}
$assert ContainerLodRoot::size == 24;

struct ContainerSampler @private {
    ComputeShaderId shader;
    BufferId output;
    gpu::MappedGpuSpan readback;
}

struct ContainerRealTool @private {
    char[] bytes;
    PixelFormat format;
    uint width;
    uint height;
    usz[2][] spans; // offset and length of each level, base first
}

fn ContainerSampler? create_container_sampler(Fixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;
    ContainerSampler sampler = { .shader = add_compute_shader(fixture, (String)CONTAINER_LOD_SOURCE[..])! };
    sampler.output = renderer.create_buffer({ .size = CONTAINER_OUTPUT_BYTES, .debug_name = "container_output" })!;
    gpu::AllocationDesc readback_desc = {
        .size = CONTAINER_OUTPUT_BYTES,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "container_readback",
    };
    sampler.readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
    return sampler;
}

fn void destroy_container_sampler(Fixture* fixture, ContainerSampler* sampler) @private {
    render::wait_frames(&fixture.renderer)!!;
    gpu::GpuAllocation allocation = sampler.readback.span.allocation();
    gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
    fixture.renderer.destroy_buffer(sampler.output)!!;
}

fn bool? container_upload(Renderer* renderer, TextureId texture) @private {
    if (catch excuse = renderer.upload_texture(texture)) {
        if (excuse != gpu::UNSUPPORTED_FEATURE) return excuse~;
        io::eprintfn("skipped: BC unsupported on %s", renderer.adapter_name);
        return false;
    }
    return true;
}

fn uint[]? container_sample_mip(
    Fixture* fixture,
    ContainerSampler* sampler,
    TextureId texture,
    uint mip,
) @private {
    Renderer* renderer = &fixture.renderer;
    material::TextureDesc desc = fixture.assets.texture(texture).desc;
    uint width = material::texture_mip_extent(desc.width, mip);
    uint height = material::texture_mip_extent(desc.height, mip);
    ContainerLodRoot root = {
        .output_address = renderer.buffer_address(sampler.output),
        .lod = mip,
        .width = width,
        .height = height,
    };
    BufferId[1] writes = { sampler.output };
    DispatchTexture[1] textures = { render::read_texture(texture, asset::SAMPLER_NEAREST) };
    uint columns = (width + CONTAINER_GROUP_SIZE - 1) / CONTAINER_GROUP_SIZE;
    uint rows = (height + CONTAINER_GROUP_SIZE - 1) / CONTAINER_GROUP_SIZE;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.dispatch({
        .shader = sampler.shader,
        .root = ((char*)&root)[:ContainerLodRoot::size],
        .groups = { columns, rows, 1 },
        .writes = writes[..],
        .textures = textures[..],
    })!;
    container_record_readback(fixture, sampler)!;
    renderer.end_frame()!;

    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, sampler.readback.span)!;
    uint[] pixels = alloc::new_array(tmem, uint, (sz)width * height);
    mem::copy(pixels.ptr, sampler.readback.bytes.ptr, (sz)(pixels.len * uint::size));
    return pixels;
}

fn void? container_record_readback(Fixture* fixture, ContainerSampler* sampler) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::Barrier copied_writes = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &copied_writes)!;
    gpu::BufferCopyDesc buffer_copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(sampler.output).allocation)!,
        .dst = sampler.readback.span,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &buffer_copy)!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    return gpu::cmd_barrier(&renderer.commands, &host_read);
}

fn void container_compare_mips(
    Fixture* fixture,
    ContainerSampler* sampler,
    TextureId loaded,
    TextureId supplied,
) @private {
    uint mip_count = fixture.assets.texture(supplied).desc.mip_levels;
    assert(fixture.assets.texture(loaded).desc.mip_levels == mip_count);
    for (uint mip = 0; mip < mip_count; mip++) {
        @pool() {
            uint[] from_container = container_sample_mip(fixture, sampler, loaded, mip)!!;
            uint[] from_records = container_sample_mip(fixture, sampler, supplied, mip)!!;
            assert(from_container == from_records, "mip %d", mip);
        };
    }
}

fn char[] container_orientation_level(Allocator allocator, uint mip) @private {
    char[4][CONTAINER_ORIENTATION_MIPS] markers = { { 255, 0, 0, 255 }, { 0, 255, 0, 255 }, { 0, 0, 255, 255 } };
    uint size = CONTAINER_ORIENTATION_EXTENT >> mip;
    char[] texels = alloc::new_array(allocator, char, (sz)size * size * 4);
    for (uint y = 0; y < size; y++) {
        for (uint x = 0; x < size; x++) {
            char[4] texel = { (char)(16 + 48 * x), (char)(16 + 48 * y), (char)(64 * mip + 32), 255 };
            if (x == 0 && y == 0) texel = markers[mip];
            texels[(y * size + x) * 4:4] = texel[..];
        }
    }
    return texels;
}

fn TextureId? container_supplied(AssetStore* assets, ContainerRealTool* row) @private {
    TextureMipData[material::TEXTURE_MIP_CAPACITY] levels;
    foreach (uint mip, span : row.spans) levels[mip] = { .mip = mip, .bytes = row.bytes[span[0]:span[1]] };
    material::TextureDesc desc = material::texture_2d_desc(row.width, row.height, row.format);
    desc.generate_mips = false;
    desc.mip_levels = (uint)row.spans.len;
    return assets.add_texture_mips(desc, levels[:row.spans.len]);
}

fn void test_container_orientation_samples_like_supplied_mips() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ContainerSampler sampler = create_container_sampler(&fixture)!!;
    defer destroy_container_sampler(&fixture, &sampler);

    TextureId supplied;
    @pool() {
        TextureMipData[CONTAINER_ORIENTATION_MIPS] levels;
        foreach (uint mip, &level : levels) *level = { .mip = mip, .bytes = container_orientation_level(tmem, mip) };
        material::TextureDesc desc = material::texture_2d_desc(
            width:  CONTAINER_ORIENTATION_EXTENT,
            height: CONTAINER_ORIENTATION_EXTENT,
            format: RGBA8_UNORM,
        );
        desc.generate_mips = false;
        desc.mip_levels = CONTAINER_ORIENTATION_MIPS;
        supplied = fixture.assets.add_texture_mips(desc, levels[..])!!;
    };
    fixture.renderer.upload_texture(supplied)!!;
    uint[CONTAINER_ORIENTATION_MIPS] markers = { 0xFF0000FF, 0xFF00FF00, 0xFFFF0000 };
    for (uint mip = 0; mip < CONTAINER_ORIENTATION_MIPS; mip++) {
        @pool() {
            assert(container_sample_mip(&fixture, &sampler, supplied, mip)!![0] == markers[mip], "mip %d", mip);
        };
    }

    char[][3] files = {
        $embed("../../fixtures/texture/orientation_4x4.dds"),
        $embed("../../fixtures/texture/orientation_4x4.ktx"),
        $embed("../../fixtures/texture/orientation_4x4.ktx2"),
    };
    foreach (file : files) {
        TextureId loaded = image::add_texture_container(&fixture.assets, file)!!;
        fixture.renderer.upload_texture(loaded)!!;
        container_compare_mips(&fixture, &sampler, loaded, supplied);
    }
    check_validation(&fixture.renderer);
}

fn void test_container_bc_chain_samples_like_supplied_mips() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ContainerSampler sampler = create_container_sampler(&fixture)!!;
    defer destroy_container_sampler(&fixture, &sampler);

    char[] chain = $embed("../../../examples/assets/bc1_mips.bin");
    TextureMipData[CONTAINER_BC_BYTES.len] levels;
    foreach (uint mip, &level : levels) {
        *level = { .mip = mip, .bytes = chain[CONTAINER_BC_OFFSETS[mip]:CONTAINER_BC_BYTES[mip]] };
    }
    material::TextureDesc desc = material::texture_2d_desc(CONTAINER_BC_EXTENT, CONTAINER_BC_EXTENT, BC1_RGBA_SRGB);
    desc.generate_mips = false;
    desc.mip_levels = levels.len;
    TextureId supplied = fixture.assets.add_texture_mips(desc, levels[..])!!;
    TextureId loaded = image::add_texture_container(&fixture.assets, $embed("../../../examples/assets/bc1_mips.dds"))!!;
    if (!container_upload(&fixture.renderer, supplied)!!) return;
    fixture.renderer.upload_texture(loaded)!!;

    container_compare_mips(&fixture, &sampler, loaded, supplied);
    foreach (uint mip, color : CONTAINER_BC_COLORS) {
        @pool() {
            assert(container_sample_mip(&fixture, &sampler, loaded, mip)!![0] == color, "mip %d", mip);
        };
    }
    check_validation(&fixture.renderer);
}

fn void test_real_tool_containers_sample_like_supplied_mips() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ContainerSampler sampler = create_container_sampler(&fixture)!!;
    defer destroy_container_sampler(&fixture, &sampler);

    ContainerRealTool[4] rows = {
        {
            .bytes = $embed("../../fixtures/texture/ktxtest/format_bc4_unorm.ktx"),
            .format = BC4_UNORM, .width = 64, .height = 64,
            .spans = {
                { 68, 2048 }, { 2120, 512 }, { 2636, 128 }, { 2768, 32 },
                { 2804, 8 }, { 2816, 8 }, { 2828, 8 },
            },
        },
        {
            .bytes = $embed("../../fixtures/texture/ktx2_samples/2d_bc7.ktx2"),
            .format = BC7_SRGB, .width = 40, .height = 40,
            .spans = { { 976, 1600 }, { 576, 400 }, { 432, 144 }, { 368, 64 }, { 352, 16 }, { 336, 16 } },
        },
        {
            .bytes = $embed("../../fixtures/texture/bcnencoder/decoding_dds_bc5.dds"),
            .format = BC5_UNORM, .width = 64, .height = 64,
            .spans = {
                { 148, 4096 }, { 4244, 1024 }, { 5268, 256 }, { 5524, 64 },
                { 5588, 16 }, { 5604, 16 }, { 5620, 16 },
            },
        },
        {
            .bytes = $embed("../../fixtures/texture/openimageio/dds_npot_bc3_mips.dds"),
            .format = BC3_UNORM, .width = 13, .height = 7,
            .spans = { { 128, 128 }, { 256, 32 }, { 288, 16 }, { 304, 16 } },
        },
    };
    foreach (&row : rows) {
        TextureId supplied = container_supplied(&fixture.assets, row)!!;
        TextureId loaded = image::add_texture_container(&fixture.assets, row.bytes)!!;
        if (!container_upload(&fixture.renderer, supplied)!!) return;
        fixture.renderer.upload_texture(loaded)!!;
        container_compare_mips(&fixture, &sampler, loaded, supplied);
    }
    check_validation(&fixture.renderer);
}
