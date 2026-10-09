module c3d::render::acceptance;

import c3d;
import c3d::asset @public;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::test::loading_fixtures;
import gpu;
import std::math;

const char[*] PREPARATION_TYPE_SOURCE @private = $embed("sample_prepare_types.comp.glsl");
const uint PREPARATION_TYPE_GROUP_SIZE @private = 8; // mirrored as local_size_x/y in sample_prepare_types.comp.glsl
const uint PREPARATION_TYPE_FRAME_LIMIT @private = 512; // covers one-row cube/slice copies plus completion slots
const ulong PREPARATION_CUBE_MINIMUM_TEXELS @private = 6; // floor(96 * two output texels / 30)
const uint PREPARATION_REPLACEMENT_SEED @private = loading_fixtures::PREPARATION_IMAGE_SEED ^ 0x9e3779b9;

enum TextureSampleDimension : uint @private {
    TWO_D,
    CUBE,
    VOLUME,
}

struct PreparationTypeRoot @private { // mirrored as PreparationTypeRoot in sample_prepare_types.comp.glsl
    gpu::GpuAddress output_address;
    uint mip;
    uint width;
    uint height;
    uint depth;
    uint dimension;
    uint layer;
}
$assert PreparationTypeRoot::size == 32;

fn ContainerSampler? preparation_type_sampler(Fixture* fixture) @private {
    ContainerSampler sampler = create_container_sampler(fixture)!;
    defer catch destroy_container_sampler(fixture, &sampler);
    sampler.shader = add_compute_shader(fixture, (String)PREPARATION_TYPE_SOURCE[..])!;
    return sampler;
}

fn uint[]? preparation_type_sample(
    Fixture* fixture,
    ContainerSampler* sampler,
    TextureId texture,
    uint mip,
    uint layer,
    TextureSampleDimension dimension,
) @private {
    Renderer* renderer = &fixture.renderer;
    material::TextureDesc desc = fixture.assets.texture(texture).desc;
    uint width = material::texture_mip_extent(desc.width, mip);
    uint height = material::texture_mip_extent(desc.height, mip);
    PreparationTypeRoot root = {
        .output_address = renderer.buffer_address(sampler.output),
        .mip = mip, .width = width, .height = height, .depth = desc.depth,
        .dimension = (uint)dimension, .layer = layer,
    };
    BufferId[1] writes = { sampler.output };
    DispatchTexture[1] textures = { render::read_texture(texture, asset::SAMPLER_NEAREST) };
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.dispatch({
        .shader = sampler.shader,
        .root = ((char*)&root)[:PreparationTypeRoot::size],
        .groups = {
            (width + PREPARATION_TYPE_GROUP_SIZE - 1) / PREPARATION_TYPE_GROUP_SIZE,
            (height + PREPARATION_TYPE_GROUP_SIZE - 1) / PREPARATION_TYPE_GROUP_SIZE,
            1,
        },
        .writes = writes[..], .textures = textures[..],
    })!;
    container_record_readback(fixture, sampler)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, sampler.readback.span)!;
    uint[] pixels = alloc::new_array(tmem, uint, (sz)width * height);
    mem::copy(pixels.ptr, sampler.readback.bytes.ptr, pixels.len * uint::size);
    return pixels;
}

fn PrepareId? preparation_texture_only(Fixture* fixture, TextureId texture) @private {
    ModelTemplate template = { .nodes = alloc::new_array(fixture.allocator, NodeTemplate, 1) };
    defer catch asset::free_model_template(fixture.allocator, &template);
    template.nodes[0] = {
        .parent = -1, .local = maths::TRANSFORM_IDENTITY, .visible = true, .layers = uint::max,
    };
    ModelId model = fixture.assets.add_model_owned(&template)!;
    Renderer* renderer = &fixture.renderer;
    PrepareId id = renderer.begin_prepare_model(model)!;
    PrepareRecord* record = renderer.prepares.get(id);
    render::release_prepare_record(renderer, record);
    record.units = alloc::new_array(renderer.allocator, PrepareUnit, 2);
    TextureAsset* source = fixture.assets.texture(texture);
    record.units[0] = {
        .kind = PrepareUnitKind.TEXTURE, .texture = texture, .revision = source.header.revision,
        .bytes = render::prepare_texture_bytes(renderer, texture, true),
        .texels = source.source_kind == TextureSourceKind.MIP_ZERO && source.desc.generate_mips
          ? (ulong)source.desc.width * source.desc.height * source.desc.layers : 0,
        .full_reader = true,
    };
    record.units[1] = { .kind = PrepareUnitKind.FINISH };
    record.bytes_total = record.units[0].bytes;
    record.texels_total = record.units[0].texels;
    record.bytes_done = 0;
    record.texels_done = 0;
    record.units_done = 0;
    record.next = 0;
    record.state = PrepareState.PENDING;
    record.phase = PreparePhase.DEPENDENCIES;
    record.pending_gpu = false;
    render::bind_prepare_record(renderer, id);
    return id;
}

fn void preparation_texture_block_then_drain(
    Fixture* fixture,
    TextureId texture,
    PrepareId id,
    usz row_bytes,
    ulong generated_limit,
) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::TextureHandle previous = renderer.textures[texture.index].texture;
    uint binding_revision = renderer.textures[texture.index].binding_revision;
    renderer.begin_frame()!!;
    PrepareReport blocked = renderer.advance_prepares_within({
        .staged_bytes = row_bytes - 1,
        .generated_texels = generated_limit ? 1 : 0,
    })!!;
    assert(blocked.staged_bytes == 0 && blocked.generated_texels == 0);
    if (generated_limit) {
        assert(blocked.reason == PrepareStopReason.GENERATED_TEXELS);
        assert(blocked.required.generated_texels == PREPARATION_CUBE_MINIMUM_TEXELS);
    } else {
        assert(blocked.reason == PrepareStopReason.STAGED_BYTES);
        assert(blocked.required.staged_bytes == row_bytes);
    }
    assert(renderer.textures[texture.index].texture == previous);
    assert(renderer.textures[texture.index].binding_revision == binding_revision);
    assert(!renderer.prepares.get(id).units[0].done);
    renderer.end_frame()!!;

    bool saw_partial;
    ulong bytes;
    ulong generated = blocked.generated_texels;
    PrepareProgress progress = renderer.prepare_progress(id);
    for (uint frame = 0; frame < PREPARATION_TYPE_FRAME_LIMIT && progress.state != PrepareState.READY; frame++) {
        renderer.begin_frame()!!;
        PrepareReport report = renderer.advance_prepares_within({
            .staged_bytes = row_bytes, .generated_texels = generated_limit,
        })!!;
        assert(report.staged_bytes <= row_bytes);
        if (generated_limit) assert(report.generated_texels <= generated_limit);
        assert(report.reason == PrepareStopReason.NONE || report.reason == PrepareStopReason.STAGED_BYTES
          || report.reason == PrepareStopReason.GENERATED_TEXELS);
        if (report.reason == PrepareStopReason.STAGED_BYTES) assert(report.required.staged_bytes <= row_bytes);
        if (report.reason == PrepareStopReason.GENERATED_TEXELS) {
            assert(generated_limit && report.required.generated_texels <= generated_limit);
        }
        bytes += report.staged_bytes;
        generated += report.generated_texels;
        PrepareRecord* record = renderer.prepares.get(id);
        if (!record.units[0].done) {
            assert(renderer.textures[texture.index].texture == previous);
            assert(renderer.textures[texture.index].binding_revision == binding_revision);
            if (record.units[0].staged.bytes) saw_partial = true;
        }
        renderer.end_frame()!!;
        progress = renderer.prepare_progress(id);
        assert(progress.state != PrepareState.FAILED);
    }
    assert(progress.state == PrepareState.READY);
    assert(saw_partial && renderer.textures[texture.index].texture != previous);
    assert(bytes == progress.bytes_total && progress.bytes_done == progress.bytes_total);
    assert(generated == progress.texels_total && progress.texels_done == progress.texels_total);
    assert(progress.units_done == progress.units_total);
}

fn void preparation_cube_compare(
    Fixture* fixture,
    ContainerSampler* sampler,
    TextureId stepped,
    TextureId synchronous,
    char[] expected_base,
) @private {
    material::TextureDesc desc = fixture.assets.texture(stepped).desc;
    TextureMipChain reference = render::create_texture_mips(fixture.allocator, desc, expected_base)!!;
    defer render::destroy_texture_mips(&reference);
    for (uint mip = 0; mip < reference.mip_count; mip++) {
        uint width = material::texture_mip_extent(desc.width, mip);
        uint height = material::texture_mip_extent(desc.height, mip);
        for (uint face = 0; face < material::CUBE_FACE_COUNT; face++) {
            @pool() {
                uint[] actual = preparation_type_sample(
                    fixture: fixture,
                    sampler: sampler,
                    texture: stepped,
                    mip: mip,
                    layer: face,
                    dimension: TextureSampleDimension.CUBE,
                )!!;
                uint[] expected = preparation_type_sample(
                    fixture: fixture,
                    sampler: sampler,
                    texture: synchronous,
                    mip: mip,
                    layer: face,
                    dimension: TextureSampleDimension.CUBE,
                )!!;
                assert(actual == expected);
                usz offset = reference.offsets[mip] + (usz)face * width * height * uint::size;
                uint[] cpu = ((uint*)(reference.pixels.ptr + offset))[:(usz)width * height];
                assert(actual == cpu, "cube face %d mip %d", face, mip);
            };
        }
    }
}

fn void test_prepare_generated_cube_bands_match_all_synchronous_faces_and_mips() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ContainerSampler sampler = preparation_type_sampler(&fixture)!!;
    defer destroy_container_sampler(&fixture, &sampler);
    @pool() {
        material::TextureDesc desc = material::texture_cube_desc(4, RGBA8_UNORM);
        usz bytes = 6 * 4 * 4 * uint::size;
        char[] original = loading_fixtures::preparation_texture_bytes(tmem, bytes);
        char[] replacement = loading_fixtures::preparation_texture_bytes(tmem, bytes, PREPARATION_REPLACEMENT_SEED);
        TextureId stepped = fixture.assets.add_texture(desc, original)!!;
        fixture.renderer.upload_texture(stepped)!!;
        fixture.assets.replace_texture(stepped, desc, replacement)!!;
        TextureId synchronous = fixture.assets.add_texture(desc, replacement)!!;
        PrepareId id = preparation_texture_only(&fixture, stepped)!!;
        preparation_texture_block_then_drain(
            fixture: &fixture,
            texture: stepped,
            id: id,
            row_bytes: 16,
            generated_limit: 7,
        );
        fixture.renderer.end_prepare(id)!!;
        fixture.renderer.upload_texture(synchronous)!!;
        preparation_cube_compare(
            fixture: &fixture,
            sampler: &sampler,
            stepped: stepped,
            synchronous: synchronous,
            expected_base: replacement,
        );
    };
    check_validation(&fixture.renderer);
}

fn void test_prepare_volume_bands_match_every_synchronous_slice() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ContainerSampler sampler = preparation_type_sampler(&fixture)!!;
    defer destroy_container_sampler(&fixture, &sampler);
    @pool() {
        material::TextureDesc desc = material::texture_3d_desc(
            width: 8,
            height: 4,
            depth: 3,
            format: RGBA8_UNORM,
        );
        usz bytes = 8 * 4 * 3 * uint::size;
        char[] original = loading_fixtures::preparation_texture_bytes(tmem, bytes);
        char[] replacement = loading_fixtures::preparation_texture_bytes(tmem, bytes, PREPARATION_REPLACEMENT_SEED);
        TextureId stepped = fixture.assets.add_texture(desc, original)!!;
        fixture.renderer.upload_texture(stepped)!!;
        fixture.assets.replace_texture(stepped, desc, replacement)!!;
        TextureId synchronous = fixture.assets.add_texture(desc, replacement)!!;
        PrepareId id = preparation_texture_only(&fixture, stepped)!!;
        preparation_texture_block_then_drain(
            fixture: &fixture,
            texture: stepped,
            id: id,
            row_bytes: 32,
            generated_limit: 0,
        );
        fixture.renderer.end_prepare(id)!!;
        fixture.renderer.upload_texture(synchronous)!!;
        for (uint slice = 0; slice < desc.depth; slice++) {
            @pool() {
                uint[] actual = preparation_type_sample(
                    fixture: &fixture,
                    sampler: &sampler,
                    texture: stepped,
                    mip: 0,
                    layer: slice,
                    dimension: TextureSampleDimension.VOLUME,
                )!!;
                uint[] expected = preparation_type_sample(
                    fixture: &fixture,
                    sampler: &sampler,
                    texture: synchronous,
                    mip: 0,
                    layer: slice,
                    dimension: TextureSampleDimension.VOLUME,
                )!!;
                assert(actual == expected);
                usz slice_texels = (usz)desc.width * desc.height;
                uint[] cpu = ((uint*)replacement.ptr + (usz)slice * slice_texels)[:slice_texels];
                assert(actual == cpu, "volume slice %d", slice);
            };
        }
    };
    check_validation(&fixture.renderer);
}

fn void preparation_compressed_bands(PixelFormat format) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ContainerSampler sampler = create_container_sampler(&fixture)!!;
    defer destroy_container_sampler(&fixture, &sampler);
    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(7, 5, format);
        desc.generate_mips = false;
        desc.mip_levels = 3;
        usz block_bytes = material::texture_block_bytes(format);
        usz bytes = block_bytes * 6;
        char[] original = loading_fixtures::preparation_texture_bytes(tmem, bytes);
        char[] replacement = loading_fixtures::preparation_texture_bytes(tmem, bytes, PREPARATION_REPLACEMENT_SEED);
        TextureMipData[3] initial;
        TextureMipData[3] levels;
        usz offset;
        for (uint mip = 0; mip < desc.mip_levels; mip++) {
            usz level_bytes = mip ? block_bytes : block_bytes * 4;
            initial[mip] = { .mip = mip, .bytes = original[offset:level_bytes] };
            levels[mip] = { .mip = mip, .bytes = replacement[offset:level_bytes] };
            offset += level_bytes;
        }
        TextureId stepped = fixture.assets.add_texture_mips(desc, initial[..])!!;
        fixture.renderer.upload_texture(stepped)!!;
        fixture.assets.replace_texture_mips(stepped, desc, levels[..])!!;
        TextureId synchronous = fixture.assets.add_texture_mips(desc, levels[..])!!;
        PrepareId id = preparation_texture_only(&fixture, stepped)!!;
        preparation_texture_block_then_drain(
            fixture: &fixture,
            texture: stepped,
            id: id,
            row_bytes: block_bytes * 2,
            generated_limit: 0,
        );
        fixture.renderer.end_prepare(id)!!;
        fixture.renderer.upload_texture(synchronous)!!;
        for (uint mip = 0; mip < desc.mip_levels; mip++) {
            @pool() {
                uint[] actual = container_sample_mip(
                    fixture: &fixture,
                    sampler: &sampler,
                    texture: stepped,
                    mip: mip,
                )!!;
                uint[] expected = container_sample_mip(
                    fixture: &fixture,
                    sampler: &sampler,
                    texture: synchronous,
                    mip: mip,
                )!!;
                assert(actual == expected);
                if (mip == 0) {
                    bool varied;
                    foreach (pixel : expected) varied |= pixel != expected[0];
                    assert(varied);
                }
            };
        }
    };
    check_validation(&fixture.renderer);
}

fn void test_prepare_supplied_bc1_bands_match_synchronous_npot_mips() @test {
    preparation_compressed_bands(BC1_RGBA_UNORM);
}

fn void test_prepare_supplied_bc7_bands_match_synchronous_npot_mips() @test {
    preparation_compressed_bands(BC7_UNORM);
}

fn ContainerSampler? preparation_resident_sampler(Fixture* fixture) @private {
    Renderer* renderer = &fixture.renderer;
    usz bytes = (usz)256 * 128 * uint::size;
    ContainerSampler sampler = { .shader = add_compute_shader(fixture, (String)CONTAINER_LOD_SOURCE[..])! };
    sampler.output = renderer.create_buffer({ .size = bytes, .debug_name = "resident_preparation_output" })!;
    defer catch renderer.destroy_buffer(sampler.output)!!;
    gpu::AllocationDesc desc = {
        .size = bytes, .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ, .access = { .graphics },
        .debug_name = "resident_preparation_readback",
    };
    sampler.readback = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    return sampler;
}

fn uint[]? preparation_resident_sample(
    Fixture* fixture,
    ContainerSampler* sampler,
    TextureId texture,
    uint relative_mip,
) @private {
    Renderer* renderer = &fixture.renderer;
    TextureRes* image = &renderer.textures[texture.index];
    uint width = gpu::texture_mip_dimension(image.width, relative_mip);
    uint height = gpu::texture_mip_dimension(image.height, relative_mip);
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    ComputeShaderRes* shader = render::resolve_compute_shader(renderer, sampler.shader)!;
    CustomStageSource stages = { .compute = fixture.assets.compute_shader(sampler.shader).desc.compute };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(
        &renderer.device, render::compute_pipeline_key(sampler.shader, shader.revision), &stages)!;
    SamplerRes* nearest = render::resolve_sampler(renderer, asset::SAMPLER_NEAREST)!;
    render::record_pending_copies(renderer, &renderer.commands)!;
    Frame* slot = &renderer.frames[renderer.recording_slot];
    ContainerLodRoot parameters = {
        .output_address = renderer.buffer_address(sampler.output),
        .lod = relative_mip, .width = width, .height = height,
    };
    gpu::MappedGpuSpan parameter_data = slot.upload.take(
        device: &renderer.device,
        size: ContainerLodRoot::size,
        alignment: render::STREAM_ALIGNMENT,
    )!;
    mem::copy(parameter_data.bytes.ptr, &parameters, ContainerLodRoot::size);
    DispatchTexturesGpu bindings;
    bindings.slots[0] = { .texture_index = image.view.index, .sampler_index = nearest.index };
    gpu::MappedGpuSpan binding_data = slot.upload.take(
        device: &renderer.device,
        size: DispatchTexturesGpu::size,
        alignment: render::STREAM_ALIGNMENT,
    )!;
    *(DispatchTexturesGpu*)binding_data.bytes.ptr = bindings;
    gpu::MappedGpuSpan root_data = slot.upload.take(
        device: &renderer.device,
        size: DispatchRoot::size,
        alignment: render::STREAM_ALIGNMENT,
    )!;
    *(DispatchRoot*)root_data.bytes.ptr = { .parameters = parameter_data.address, .textures = binding_data.address };
    gpu::Barrier to_compute = { .before = { .all }, .after = { .compute } };
    gpu::cmd_barrier(&renderer.commands, &to_compute)!;
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    gpu::cmd_dispatch(
        &renderer.commands,
        root_data.address,
        {
            (width + CONTAINER_GROUP_SIZE - 1) / CONTAINER_GROUP_SIZE,
            (height + CONTAINER_GROUP_SIZE - 1) / CONTAINER_GROUP_SIZE,
            1,
        },
    )!;
    renderer.work_recorded = true;
    container_record_readback(fixture, sampler)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, sampler.readback.span)!;
    uint[] pixels = alloc::new_array(tmem, uint, (sz)width * height);
    mem::copy(pixels.ptr, sampler.readback.bytes.ptr, (sz)(pixels.len * uint::size));
    return pixels;
}

fn ModelId? preparation_initial_consumer(Fixture* fixture, TextureId texture, ShaderId shader) @private {
    if (!shader.generation) return preparation_texture_model(fixture, texture);
    PulseBlock block = { .color = { 1, 1, 1, 1 } };
    MaterialId material = fixture.assets.add_material(material::custom(
        shader: shader,
        param_block: material::@as_bytes(block),
        slots: { [0] = material::texture_slot(texture,
        asset::SAMPLER_NEAREST) },
    ))!;
    return preparation_asset_model(
        fixture: fixture,
        geometry: fixture.box,
        material: material,
        morphed: false,
    );
}

fn void test_prepare_initial_tail_and_full_reader_match_synchronous_residency() @test {
    foreach (mode : (uint[3]){ 0, 1, 2 }) {
        bool streaming = mode != 1;
        bool full_reader = mode == 2;
        Fixture fixture;
        create_fixture(
            allocator: mem,
            fixture: &fixture,
            texture_budget_bytes: streaming ? (usz)16 : 0,
        )!!;
        defer destroy_fixture(&fixture);
        ContainerSampler sampler = preparation_resident_sampler(&fixture)!!;
        defer destroy_container_sampler(&fixture, &sampler);
        @pool() {
            material::TextureDesc desc = material::texture_2d_desc(256, 128, RGBA8_UNORM);
            char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, 256 * 128 * 4);
            TextureId stepped = fixture.assets.add_texture(desc, pixels)!!;
            TextureId synchronous = fixture.assets.add_texture(desc, pixels)!!;
            ShaderId shader;
            if (full_reader) shader = add_pulse_shader(&fixture)!!;
            ModelId model = preparation_initial_consumer(&fixture, stepped, shader)!!;
            PrepareId id = fixture.renderer.begin_prepare_model(model)!!;
            PrepareUnit* unit = null;
            foreach (&candidate : fixture.renderer.prepares.get(id).units) {
                if (candidate.kind == PrepareUnitKind.TEXTURE && c3d::same_id(candidate.texture, stepped)) unit = candidate;
            }
            assert(unit);
            uint mips = material::texture_mip_count(desc.width, desc.height);
            uint expected_base = streaming && !full_reader ? render::texture_tail_base(desc.width, mips) : 0;
            assert(expected_base == (streaming && !full_reader ? 2 : 0));
            usz expected_bytes;
            for (uint mip = expected_base; mip < mips; mip++) expected_bytes += material::texture_mip_bytes(desc, mip)!!;
            assert(expected_bytes == (expected_base ? (usz)10924 : (usz)174764));
            assert(unit.texture_base == expected_base && unit.bytes == expected_bytes && unit.full_reader == full_reader);
            usz planned_bytes = unit.bytes;
            usz staged_texture;
            usz staged_report;
            PrepareProgress progress = fixture.renderer.prepare_progress(id);
            for (uint frame = 0; frame < PREPARATION_TYPE_FRAME_LIMIT && progress.state != PrepareState.READY; frame++) {
                usz before = unit.staged.bytes;
                fixture.renderer.begin_frame()!!;
                PrepareReport report = fixture.renderer.advance_prepares_within({
                    .staged_bytes = 4096, .generated_texels = 4096, .pipelines = 1,
                })!!;
                assert(report.staged_bytes <= 4096 && report.generated_texels <= 4096 && report.pipelines <= 1);
                usz delta = unit.staged.bytes - before;
                assert(delta <= report.staged_bytes);
                assert(fixture.renderer.stats.upload_bytes == report.staged_bytes);
                staged_texture += delta;
                staged_report += report.staged_bytes;
                fixture.renderer.end_frame()!!;
                progress = fixture.renderer.prepare_progress(id);
                assert(progress.state != PrepareState.FAILED);
            }
            assert(progress.state == PrepareState.READY && staged_texture == planned_bytes && staged_report >= staged_texture);
            assert(progress.bytes_done == progress.bytes_total && progress.texels_done == progress.texels_total);
            assert(fixture.renderer.residencies[stepped.index].resident_base == expected_base);
            assert(fixture.renderer.residencies[stepped.index].full_reader == full_reader);
            fixture.renderer.end_prepare(id)!!;
            if (full_reader) {
                ModelId reference_model = preparation_initial_consumer(&fixture, synchronous, shader)!!;
                MaterialId reference_material = fixture.assets.model(reference_model).data.meshes[0].material;
                fixture.renderer.upload_material(reference_material)!!;
            } else {
                fixture.renderer.upload_texture(synchronous)!!;
            }
            assert(fixture.renderer.residencies[synchronous.index].resident_base == expected_base);
            assert(fixture.renderer.textures[stepped.index].mip_count == mips - expected_base);
            TextureMipChain reference = render::create_texture_mips(fixture.allocator, desc, pixels)!!;
            defer render::destroy_texture_mips(&reference);
            uint actual_base = fixture.renderer.residencies[stepped.index].resident_base;
            bool actual_full_reader = fixture.renderer.residencies[stepped.index].full_reader;
            for (uint mip = expected_base; mip < mips; mip++) {
                @pool() {
                    uint relative = mip - expected_base;
                    uint[] actual = preparation_resident_sample(
                        fixture: &fixture,
                        sampler: &sampler,
                        texture: stepped,
                        relative_mip: relative,
                    )!!;
                    uint[] expected = preparation_resident_sample(
                        fixture: &fixture,
                        sampler: &sampler,
                        texture: synchronous,
                        relative_mip: relative,
                    )!!;
                    assert(actual == expected);
                    uint width = material::texture_mip_extent(desc.width, mip);
                    uint height = material::texture_mip_extent(desc.height, mip);
                    uint[] cpu = ((uint*)(reference.pixels.ptr + reference.offsets[mip]))[:(usz)width * height];
                    assert(actual == cpu);
                };
            }
            assert(fixture.renderer.residencies[stepped.index].resident_base == actual_base);
            assert(fixture.renderer.residencies[stepped.index].full_reader == actual_full_reader);
            assert(fixture.renderer.texture_budget_bytes == (streaming ? (usz)16 : 0));
        };
        check_validation(&fixture.renderer);
    }
}
