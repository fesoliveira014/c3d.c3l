module c3d::render::acceptance;

import c3d;
import c3d::asset @public;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::render @public;
import c3d::test::loading_fixtures;
import gpu;
import std::math;

const uint PREPARATION_TEST_WIDTH @private = 37;
const uint PREPARATION_TEST_HEIGHT @private = 19;
const uint PREPARATION_TEST_FRAME_LIMIT @private = 512; // covers legal one-row work and covering completion

fn ModelId? preparation_texture_model(Fixture* fixture, TextureId texture) @private {
    MaterialId material_id = fixture.assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map = material::texture_slot(texture, asset::SAMPLER_NEAREST),
    }))!;
    ModelTemplate template = {
        .nodes = alloc::new_array(fixture.allocator, NodeTemplate, 1),
        .meshes = alloc::new_array(fixture.allocator, ModelMesh, 1),
    };
    defer catch asset::free_model_template(fixture.allocator, &template);
    template.nodes[0] = { .parent = -1, .local = maths::TRANSFORM_IDENTITY, .visible = true, .layers = uint::max };
    template.meshes[0] = { .node = 0, .geometry = fixture.box, .material = material_id };
    return fixture.assets.add_model_owned(&template);
}

fn ContainerSampler? preparation_sampler(Fixture* fixture, uint width = PREPARATION_TEST_WIDTH, uint height = PREPARATION_TEST_HEIGHT) @private {
    Renderer* renderer = &fixture.renderer;
    usz bytes = (usz)width * height * uint::size;
    ContainerSampler sampler = { .shader = add_compute_shader(fixture, (String)CONTAINER_LOD_SOURCE[..])! };
    sampler.output = renderer.create_buffer({ .size = bytes, .debug_name = "preparation_output" })!;
    defer catch (void)renderer.destroy_buffer(sampler.output);
    gpu::AllocationDesc desc = {
        .size = bytes,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "preparation_readback",
    };
    sampler.readback = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    return sampler;
}

fn void preparation_compare_mips(Fixture* fixture, TextureId stepped, TextureId synchronous) @private {
    material::TextureDesc desc = fixture.assets.texture(stepped).desc;
    ContainerSampler sampler = preparation_sampler(fixture, desc.width, desc.height)!!;
    defer destroy_container_sampler(fixture, &sampler);
    uint mips = material::texture_mip_count(desc.width, desc.height);
    for (uint mip = 0; mip < mips; mip++) {
        @pool() {
            uint[] actual = container_sample_mip(
                fixture: fixture,
                sampler: &sampler,
                texture: stepped,
                mip: mip,
            )!!;
            uint[] expected = container_sample_mip(
                fixture: fixture,
                sampler: &sampler,
                texture: synchronous,
                mip: mip,
            )!!;
            assert(actual == expected);
        };
    }
}

fn void preparation_drain(
    Renderer* renderer,
    PrepareId id,
    PrepareLimits limits,
    bool complete_generation = true,
) @private {
    PrepareProgress progress = renderer.prepare_progress(id);
    for (uint frame = 0; frame < PREPARATION_TEST_FRAME_LIMIT && progress.state != PrepareState.READY; frame++) {
        renderer.begin_frame()!!;
        PrepareReport report = renderer.advance_prepares_within(limits)!!;
        if (limits.staged_bytes) assert(report.staged_bytes <= limits.staged_bytes);
        if (limits.generated_texels) assert(report.generated_texels <= limits.generated_texels);
        if (limits.pipelines) assert(report.pipelines <= limits.pipelines);
        renderer.end_frame()!!;
        if (report.reason != PrepareStopReason.NONE && report.reason != PrepareStopReason.TIME) {
            if (limits.staged_bytes) limits.staged_bytes = math::max(limits.staged_bytes, report.required.staged_bytes);
            if (limits.generated_texels) limits.generated_texels = math::max(limits.generated_texels, report.required.generated_texels);
            if (limits.pipelines) limits.pipelines = math::max(limits.pipelines, report.required.pipelines);
        }
        progress = renderer.prepare_progress(id);
        assert(progress.state != PrepareState.FAILED);
    }
    assert(progress.state == PrepareState.READY);
    assert(progress.bytes_done == progress.bytes_total && progress.units_done == progress.units_total);
    if (complete_generation) {
        assert(progress.texels_done == progress.texels_total);
    } else {
        assert(progress.texels_done <= progress.texels_total);
    }
}

fn void test_prepare_generated_srgb_bands_match_synchronous_mips() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(PREPARATION_TEST_WIDTH, PREPARATION_TEST_HEIGHT, RGBA8_SRGB);
        char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)desc.width * desc.height * 4);
        TextureId stepped = fixture.assets.add_texture(desc, pixels)!!;
        TextureId synchronous = fixture.assets.add_texture(desc, pixels)!!;
        ModelId model = preparation_texture_model(&fixture, stepped)!!;
        PrepareId id = renderer.begin_prepare_model(model)!!;
        preparation_drain(renderer, id, {
            .staged_bytes = (usz)desc.width * 4 - 1,
            .generated_texels = 64,
            .pipelines = 1,
        });
        renderer.end_prepare(id)!!;
        renderer.upload_texture(synchronous)!!;
        preparation_compare_mips(&fixture, stepped, synchronous);
    };
    check_validation(renderer);
}

fn void test_prepare_finalized_abort_regenerates_identical_mips() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(PREPARATION_TEST_WIDTH, PREPARATION_TEST_HEIGHT, RGBA8_UNORM);
        char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)desc.width * desc.height * 4);
        TextureId texture = fixture.assets.add_texture(desc, pixels)!!;
        renderer.upload_texture(texture)!!;
        gpu::TextureHandle old = renderer.textures[texture.index].texture;
        foreach (&value : fixture.assets.texture(texture).pixels) *value ^= 17;
        fixture.assets.mark_texture_dirty(texture);
        TextureId expected = fixture.assets.add_texture(desc, fixture.assets.texture(texture).pixels)!!;
        ModelId model = preparation_texture_model(&fixture, texture)!!;
        PrepareId id = renderer.begin_prepare_model(model)!!;
        renderer.begin_frame()!!;
        PrepareReport recorded = renderer.advance_prepares_within({})!!;
        ulong output_texels = render::generated_texture_mip_layout(desc)!!.output_texels;
        assert(recorded.staged_bytes > 0 && recorded.generated_texels == output_texels);
        assert(renderer.textures[texture.index].texture != old);
        render::abort_frame(renderer);
        assert(renderer.textures[texture.index].texture == old);
        gpu::TextureView alive = gpu::create_texture_view(&renderer.device, old, null)!!;
        gpu::destroy_texture_view(&renderer.device, alive)!!;
        preparation_drain(renderer, id, {});
        renderer.upload_texture(expected)!!;
        preparation_compare_mips(&fixture, texture, expected);
        renderer.end_prepare(id)!!;
        assert(renderer.prepare_progress(id).failure == c3d::INVALID_ID);
    };
    check_validation(renderer);
}

fn PrepareUnit*? preparation_texture_unit(Renderer* renderer, PrepareId id, TextureId texture) @private {
    PrepareRecord* record = renderer.prepares.get(id);
    foreach (&unit : record.units) {
        if (unit.kind == PrepareUnitKind.TEXTURE && c3d::same_id(unit.texture, texture)) return unit;
    }
    return c3d::INVALID_ID~;
}

fn void preparation_partial_restart(uint change) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(PREPARATION_TEST_WIDTH, PREPARATION_TEST_HEIGHT, RGBA8_UNORM);
        char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)desc.width * desc.height * 4);
        TextureId texture = fixture.assets.add_texture(desc, pixels)!!;
        renderer.upload_texture(texture)!!;
        gpu::TextureHandle old = renderer.textures[texture.index].texture;
        foreach (&value : fixture.assets.texture(texture).pixels) *value ^= 3;
        fixture.assets.mark_texture_dirty(texture);
        ModelId model = preparation_texture_model(&fixture, texture)!!;
        PrepareId id = renderer.begin_prepare_model(model)!!;
        renderer.begin_frame()!!;
        PrepareReport partial = renderer.advance_prepares_within({ .staged_bytes = (usz)desc.width * 4 })!!;
        assert(partial.staged_bytes == (usz)desc.width * 4);
        assert(renderer.textures[texture.index].texture == old);
        renderer.end_frame()!!;
        PrepareUnit* unit = preparation_texture_unit(renderer, id, texture)!!;
        assert(unit.staged.bytes > 0 && !unit.done);
        uint before = renderer.prepare_progress(id).restarts;
        switch (change) {
            case 0:
                foreach (&value : fixture.assets.texture(texture).pixels) *value ^= 5;
                fixture.assets.mark_texture_dirty(texture);
            case 1:
                MaterialId material_id = fixture.assets.model(model).data.meshes[0].material;
                fixture.assets.mark_material_dirty(material_id);
            case 2:
                fixture.assets.mark_sampler_dirty(asset::SAMPLER_NEAREST);
            case 3:
                ModelTemplate* current = &fixture.assets.model(model).data;
                ModelTemplate next = {
                    .nodes = alloc::new_array(fixture.allocator, NodeTemplate, current.nodes.len),
                    .meshes = alloc::new_array(fixture.allocator, ModelMesh, current.meshes.len),
                };
                next.nodes[..] = current.nodes[..];
                next.meshes[..] = current.meshes[..];
                fixture.assets.replace_model_owned(model, &next)!!;
        }
        preparation_drain(renderer, id, {});
        assert(renderer.prepare_progress(id).restarts > before);
        TextureId expected = fixture.assets.add_texture(desc, fixture.assets.texture(texture).pixels)!!;
        renderer.upload_texture(expected)!!;
        preparation_compare_mips(&fixture, texture, expected);
        renderer.end_prepare(id)!!;
    };
    check_validation(renderer);
}

fn void test_prepare_partial_submissions_restart_on_texture_material_sampler_and_model_revisions() @test {
    for (uint change = 0; change < 4; change++) preparation_partial_restart(change);
}

fn void preparation_source_release(bool base_submitted) @private {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(PREPARATION_TEST_WIDTH, PREPARATION_TEST_HEIGHT, RGBA8_UNORM);
        char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)desc.width * desc.height * 4);
        TextureId texture = fixture.assets.add_texture(desc, pixels)!!;
        TextureId expected = fixture.assets.add_texture(desc, pixels)!!;
        ModelId model = preparation_texture_model(&fixture, texture)!!;
        PrepareId id = renderer.begin_prepare_model(model)!!;
        uint frames;
        do {
            renderer.begin_frame()!!;
            PrepareReport report = renderer.advance_prepares_within({ .staged_bytes = (usz)desc.width * 4 })!!;
            assert(report.staged_bytes <= (usz)desc.width * 4);
            renderer.end_frame()!!;
            assert(++frames < PREPARATION_TEST_FRAME_LIMIT);
        } while (base_submitted && preparation_texture_unit(renderer, id, texture)!!.staged.mip == 0);
        assert(!preparation_texture_unit(renderer, id, texture)!!.done);
        fixture.assets.release_texture_cpu(texture);
        if (base_submitted) {
            preparation_drain(renderer, id, {});
            renderer.upload_texture(expected)!!;
            preparation_compare_mips(&fixture, texture, expected);
        } else {
            renderer.begin_frame()!!;
            renderer.advance_prepares_within({})!!;
            renderer.end_frame()!!;
            PrepareProgress progress = renderer.prepare_progress(id);
            assert(progress.state == PrepareState.FAILED && progress.failure == c3d::ASSET_DATA_UNAVAILABLE);
        }
        renderer.end_prepare(id)!!;
    };
    check_validation(renderer);
}

fn void test_prepare_source_release_distinguishes_needed_base_from_owned_generated_levels() @test {
    preparation_source_release(false);
    preparation_source_release(true);
}

fn void test_prepare_end_and_removed_model_retain_actual_submitted_resource_lifetimes() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    @pool() {
        material::TextureDesc desc = material::texture_2d_desc(PREPARATION_TEST_WIDTH, PREPARATION_TEST_HEIGHT, RGBA8_UNORM);
        char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)desc.width * desc.height * 4);
        TextureId texture = fixture.assets.add_texture(desc, pixels)!!;
        ModelId model = preparation_texture_model(&fixture, texture)!!;
        PrepareId pending = renderer.begin_prepare_model(model)!!;
        renderer.end_prepare(pending)!!;
        assert(renderer.prepare_progress(pending).failure == c3d::INVALID_ID);
        PrepareId partial = renderer.begin_prepare_model(model)!!;
        renderer.begin_frame()!!;
        renderer.advance_prepares_within({ .staged_bytes = (usz)desc.width * 4 })!!;
        renderer.end_frame()!!;
        assert(!preparation_texture_unit(renderer, partial, texture)!!.done);
        renderer.end_prepare(partial)!!;
        render::wait_frames(renderer)!!;
        PrepareId removed = renderer.begin_prepare_model(model)!!;
        renderer.begin_frame()!!;
        renderer.advance_prepares_within({ .staged_bytes = (usz)desc.width * 4 })!!;
        renderer.end_frame()!!;
        fixture.assets.remove_model(model);
        renderer.begin_frame()!!;
        renderer.advance_prepares_within({})!!;
        renderer.end_frame()!!;
        PrepareProgress failed = renderer.prepare_progress(removed);
        assert(failed.state == PrepareState.FAILED && failed.failure == c3d::INVALID_ID);
        renderer.end_prepare(removed)!!;
    };
    check_validation(renderer);
}

fn void test_prepare_removed_active_texture_does_not_reuse_its_chain_for_next_texture() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    @pool() {
        material::TextureDesc first_desc = material::texture_2d_desc(48, 17, RGBA8_UNORM);
        material::TextureDesc second_desc = material::texture_2d_desc(PREPARATION_TEST_WIDTH, PREPARATION_TEST_HEIGHT, RGBA8_UNORM);
        TextureId first = fixture.assets.add_texture(first_desc,
            loading_fixtures::preparation_texture_bytes(tmem, (usz)first_desc.width * first_desc.height * 4))!!;
        char[] second_pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)second_desc.width * second_desc.height * 4,
            loading_fixtures::PREPARATION_IMAGE_SEED ^ 0x9e3779b9);
        TextureId second = fixture.assets.add_texture(second_desc, second_pixels)!!;
        TextureId expected = fixture.assets.add_texture(second_desc, second_pixels)!!;
        ModelId model = preparation_texture_model(&fixture, first)!!;
        MaterialId second_material = fixture.assets.add_material(material::basic({
            .color = { 1, 1, 1, 1 }, .map = material::texture_slot(second, asset::SAMPLER_NEAREST),
        }))!!;
        ModelTemplate* template = &fixture.assets.model(model).data;
        alloc::free(fixture.allocator, template.meshes.ptr);
        template.meshes = alloc::new_array(fixture.allocator, ModelMesh, 2);
        MaterialId first_material = fixture.assets.add_material(material::basic({
            .color = { 1, 1, 1, 1 }, .map = material::texture_slot(first, asset::SAMPLER_NEAREST),
        }))!!;
        template.meshes[0] = { .node = 0, .geometry = fixture.box, .material = first_material };
        template.meshes[1] = { .node = 0, .geometry = fixture.box, .material = second_material };
        PrepareId id = renderer.begin_prepare_model(model)!!;
        renderer.begin_frame()!!;
        PrepareReport prefix = renderer.advance_prepares_within({ .generated_texels = 128 })!!;
        ulong output_texels = render::generated_texture_mip_layout(first_desc)!!.output_texels;
        assert(prefix.generated_texels > 0 && prefix.generated_texels < output_texels);
        PrepareRecord* record = renderer.prepares.get(id);
        PrepareUnit* active = preparation_texture_unit(renderer, id, first)!!;
        assert(record.chain_active && record.chain_unit == active.index && !active.done);
        renderer.end_frame()!!;
        fixture.assets.remove_texture(first);
        preparation_drain(
            renderer: renderer,
            id: id,
            limits: {},
            complete_generation: false,
        );
        renderer.upload_texture(expected)!!;
        preparation_compare_mips(&fixture, second, expected);
        renderer.end_prepare(id)!!;
    };
    check_validation(renderer);
}

fn void test_prepare_partial_geometry_revision_restarts_and_preserves_prior_mirror() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    @pool() {
        ModelId model = preparation_texture_model(&fixture, asset::TEXTURE_WHITE)!!;
        renderer.prepare_model(model)!!;
        render::wait_frames(renderer)!!;
        gpu::GpuAllocation old = renderer.geometries[fixture.box.index].allocation;
        Geometry* source = &fixture.assets.geometry(fixture.box).data;
        foreach (&position : source.positions) position.x += 0.125f;
        source.finalize();
        fixture.assets.mark_geometry_dirty(fixture.box);
        PrepareId id = renderer.begin_prepare_model(model)!!;
        renderer.begin_frame()!!;
        PrepareReport first = renderer.advance_prepares_within({ .staged_bytes = 16 })!!;
        assert(first.staged_bytes == 16);
        renderer.end_frame()!!;
        PrepareUnit* partial = preparation_asset_unit(
            renderer: renderer,
            id: id,
            kind: PrepareUnitKind.GEOMETRY,
            geometry: fixture.box,
            material: {},
        );
        assert(partial.staged.bytes == 16 && !partial.done);
        gpu::GpuAllocation candidate = partial.geometry_candidate.allocation;
        assert(candidate.is_valid() && renderer.geometries[fixture.box.index].allocation == old);
        foreach (&position : source.positions) position.y += 0.075f;
        source.finalize();
        fixture.assets.mark_geometry_dirty(fixture.box);
        GeometryId synchronous = fixture.assets.add_geometry(source)!!;
        renderer.begin_frame()!!;
        PrepareReport restarted = renderer.advance_prepares_within({ .staged_bytes = 16 })!!;
        assert(renderer.prepare_progress(id).restarts == 1 && restarted.staged_bytes == 16);
        assert(renderer.geometries[fixture.box.index].allocation == old);
        gpu::get_allocation_span(&renderer.device, old)!!;
        partial = preparation_asset_unit(
            renderer: renderer,
            id: id,
            kind: PrepareUnitKind.GEOMETRY,
            geometry: fixture.box,
            material: {},
        );
        assert(partial.revision == fixture.assets.geometry(fixture.box).header.revision);
        assert(partial.staged.bytes == 16 && partial.geometry_candidate.allocation != candidate);
        renderer.end_frame()!!;
        preparation_drain(renderer, id, { .staged_bytes = 1024, .pipelines = 1 });
        renderer.end_prepare(id)!!;
        renderer.upload_geometry(synchronous)!!;
        MaterialId material = fixture.assets.model(model).data.meshes[0].material;
        DeformedScene actual = create_single_box_scene(
            fixture: &fixture,
            geometry: fixture.box,
            material: material,
            sunlit: false,
        )!!;
        defer scene::destroy_scene(&actual.scene);
        DeformedScene expected = create_single_box_scene(
            fixture: &fixture,
            geometry: synchronous,
            material: material,
            sunlit: false,
        )!!;
        defer scene::destroy_scene(&expected.scene);
        preparation_asset_draw_parity(&fixture, &actual, &expected);
    };
    check_validation(renderer);
}

fn void test_prepare_end_submitted_and_ready_preserves_cached_mips() @test {
    foreach (end_ready : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        @pool() {
            material::TextureDesc desc = material::texture_2d_desc(
                width: PREPARATION_TEST_WIDTH,
                height: PREPARATION_TEST_HEIGHT,
                format: RGBA8_UNORM,
            );
            char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)desc.width * desc.height * 4);
            TextureId texture = fixture.assets.add_texture(desc, pixels)!!;
            TextureId expected = fixture.assets.add_texture(desc, pixels)!!;
            renderer.upload_texture(expected)!!;
            render::wait_frames(renderer)!!;
            ModelId model = preparation_texture_model(&fixture, texture)!!;
            PrepareId original = renderer.begin_prepare_model(model)!!;
            renderer.begin_frame()!!;
            PrepareReport report = renderer.advance_prepares_within({})!!;
            assert(report.staged_bytes > 0);
            renderer.end_frame()!!;
            PrepareRecord* record = renderer.prepares.get(original);
            assert(record.state == PrepareState.SUBMITTED && record.units_done == record.units.len);
            gpu::CompletionPoint covering = record.last_submission;
            assert(covering.is_valid());
            gpu::TextureHandle published = renderer.textures[texture.index].texture;
            assert(published.is_valid());
            if (end_ready) {
                gpu::wait_completion(covering)!!;
                assert(renderer.prepare_progress(original).state == PrepareState.READY);
            }
            renderer.end_prepare(original)!!;
            assert(renderer.textures[texture.index].texture == published);
            assert(@catch(renderer.end_prepare(original)) == c3d::INVALID_ID);
            PrepareProgress stale = renderer.prepare_progress(original);
            assert(stale.state == PrepareState.FAILED && stale.failure == c3d::INVALID_ID);
            gpu::wait_completion(covering)!!;
            preparation_compare_mips(&fixture, texture, expected);

            PrepareId reused = renderer.begin_prepare_model(model)!!;
            renderer.begin_frame()!!;
            PrepareReport warm = renderer.advance_prepares_within({})!!;
            assert(warm.staged_bytes == 0 && warm.pipelines == 0);
            renderer.end_frame()!!;
            render::wait_frames(renderer)!!;
            assert(renderer.prepare_progress(reused).state == PrepareState.READY);
            renderer.end_prepare(reused)!!;
            assert(renderer.textures[texture.index].texture == published);
            preparation_compare_mips(&fixture, texture, expected);
            check_validation(renderer);
        };
    }
}
