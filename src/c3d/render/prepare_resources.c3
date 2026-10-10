module c3d::render;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import gpu;
import std::math;
import std::time;
import std::time::clock;

enum PrepareResourceStep @private {
    TEXTURE_IMAGE,
    TEXTURE_VIEW,
    TEXTURE_STORAGE_VIEW,
    GENERATION_STORAGE,
    GENERATE,
    TEXTURE_COPY,
    EMPTY_TEXTURE,
    GEOMETRY_STORAGE,
    GEOMETRY_COPY,
    MATERIAL_STORAGE,
    MATERIAL_PAYLOAD,
    MATERIAL_BLOCK,
    SAMPLER,
    TOON_SAMPLER,
    SHADER,
    PIPELINE,
    FINISH,
}

struct PrepareStepPlan @private {
    PrepareResourceStep kind;
    PrepareStepCost cost;
    TextureBand band;
    usz offset;
    usz bytes;
}

fn PrepareStepPlan? plan_prepare_step(
    Renderer* renderer,
    PrepareRecord* record,
    PrepareUnit* unit,
    PrepareBudget* budget,
) @private {
    switch (unit.kind) {
        case TEXTURE:
            return plan_prepare_texture(
                renderer: renderer,
                record: record,
                unit: unit,
                budget: budget,
            );
        case GEOMETRY:
            GeometryAsset* source = renderer.assets.geometry(unit.geometry);
            if (!source.data.positions.len) return c3d::ASSET_DATA_UNAVAILABLE~;
            record.phase = PreparePhase.UPLOAD;
            if (!unit.geometry_candidate.allocation.is_valid()) return { .kind = PrepareResourceStep.GEOMETRY_STORAGE };
            GeometryPrepareRange range = geometry_prepare_range(
                layout: &unit.geometry_candidate.layout,
                offset: unit.staged.bytes,
                allowance: prepare_byte_allowance(budget),
            );
            if (!range.bytes) {
                range = geometry_prepare_range(&unit.geometry_candidate.layout, unit.staged.bytes, range.minimum);
            }
            return { .kind = PrepareResourceStep.GEOMETRY_COPY, .offset = range.offset, .bytes = range.bytes,
                .cost = { .staged_bytes = range.bytes } };
        case MATERIAL:
            record.phase = PreparePhase.UPLOAD;
            Material* material = &renderer.assets.material(unit.material).data;
            usz payload_bytes = material.kind == MaterialKind.CUSTOM ? material.custom.param_block.len : 0;
            if (payload_bytes && !unit.material_candidate.payload.is_valid()) {
                return { .kind = PrepareResourceStep.MATERIAL_STORAGE };
            }
            if (unit.staged.bytes < payload_bytes) {
                usz remaining = payload_bytes - unit.staged.bytes;
                usz minimum = math::min(remaining, STREAM_ALIGNMENT);
                usz bytes = math::min(remaining, prepare_byte_allowance(budget));
                if (bytes < minimum) bytes = minimum;
                if (bytes < remaining) bytes -= bytes % STREAM_ALIGNMENT;
                return { .kind = PrepareResourceStep.MATERIAL_PAYLOAD, .offset = unit.staged.bytes, .bytes = bytes,
                    .cost = { .staged_bytes = bytes } };
            }
            if (!material_prepare_dependencies_current(renderer, unit.material)) return c3d::INVALID_ARGUMENT~;
            return { .kind = PrepareResourceStep.MATERIAL_BLOCK, .bytes = MATERIAL_STRIDE,
                .cost = { .staged_bytes = MATERIAL_STRIDE } };
        case SAMPLER: return { .kind = PrepareResourceStep.SAMPLER };
        case TOON_SAMPLER: return { .kind = PrepareResourceStep.TOON_SAMPLER };
        case SHADER:
            record.phase = PreparePhase.DEPENDENCIES;
            return { .kind = PrepareResourceStep.SHADER, .cost = prepare_shader_cost(renderer, unit, budget)! };
        case PIPELINES:
            record.phase = PreparePhase.PIPELINES;
            return { .kind = PrepareResourceStep.PIPELINE, .cost = prepare_pipeline_cost(renderer, unit, budget)! };
        case FINISH:
            record.phase = PreparePhase.FINISH;
            return { .kind = PrepareResourceStep.FINISH };
    }
}

<*
 Validate the retained CPU source before creating a preparation image.
 @param [&in] source : "Borrowed texture source and metadata."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
*>
fn void? check_prepare_texture_source(TextureAsset* source) @private {
    switch (source.source_kind) {
        case MIP_ZERO:
            check_texture_mip_zero(source.desc, source.pixels)!;
            asset::check_coverage_statistics(source.desc, &source.coverage_statistics, source.header.revision)!;

        case SUPPLIED_MIPS: supplied_texture_mip_layout(source.desc, source.supplied_mips)!;

        case EMPTY: break;
    }
}

fn PrepareStepPlan? plan_prepare_texture(
    Renderer* renderer,
    PrepareRecord* record,
    PrepareUnit* unit,
    PrepareBudget* budget,
) @local {
    TextureAsset* source = renderer.assets.texture(unit.texture);
    material::TextureDesc desc = record.chain_active && record.chain_unit == unit.index
      ? record.generation_desc : source.desc;
    if (!unit.texture_candidate.texture.is_valid()) {
        check_prepare_texture_source(source)!;

        return { .kind = PrepareResourceStep.TEXTURE_IMAGE };
    }

    if (source.source_kind != EMPTY) {
        texture_band(
            desc: desc,
            mip: 0,
            layer: 0,
            slice: 0,
            first_block_row: 0,
            block_rows: 1,
        )!;
    }

    if (!unit.texture_candidate.view.is_valid()) return { .kind = PrepareResourceStep.TEXTURE_VIEW };

    usz storage_count = desc.storage ? (usz)unit.texture_candidate.mip_count * desc.layers : 0;
    if (unit.creation_next < storage_count) return { .kind = PrepareResourceStep.TEXTURE_STORAGE_VIEW };
    unit.initialized = true;
    if (source.source_kind == EMPTY) return { .kind = PrepareResourceStep.EMPTY_TEXTURE };
    if (source.source_kind == MIP_ZERO && desc.generate_mips) {
        GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!;
        if (layout.output_texels && !record.chain_active) return { .kind = PrepareResourceStep.GENERATION_STORAGE };
        if (layout.output_texels && record.generation_mip <= layout.mip_count) {
            record.phase = PreparePhase.GENERATION;
            uint height = material::texture_mip_extent(desc.height, record.generation_mip);
            uint rows = math::min(PREPARE_GENERATION_ROWS, height - record.generation_row);
            uint width = material::texture_mip_extent(desc.width, record.generation_mip);

            ulong before = texture_scan_charge(
                base_texels: layout.base_texels,
                position: record.generation_outputs,
                output_total: layout.output_texels,
                passes: layout.passes,
            );
            ulong charge;

            while (true) {
                ulong after = texture_scan_charge(
                    base_texels: layout.base_texels,
                    position: record.generation_outputs + (ulong)width * rows,
                    output_total: layout.output_texels,
                    passes: layout.passes,
                );
                charge = after - before;
                ulong remaining = budget.limits.generated_texels > budget.report.generated_texels
                    ? budget.limits.generated_texels - budget.report.generated_texels : 0;
                if (!budget.limits.generated_texels || charge <= remaining || rows == 1) break;
                rows = math::max(1u, rows / 2);
            }

            TextureBand band = texture_band(
                desc: desc,
                mip: record.generation_mip,
                layer: record.generation_layer,
                slice: 0,
                first_block_row: record.generation_row,
                block_rows: rows,
            )!;

            return { .kind = PrepareResourceStep.GENERATE, .band = band, .cost = { .generated_texels = charge } };
        }
    }

    record.phase = PreparePhase.UPLOAD;
    TextureBand first = texture_band(
        desc: desc,
        mip: unit.staged.mip,
        layer: unit.staged.layer,
        slice: unit.staged.slice,
        first_block_row: unit.staged.row,
        block_rows: 1,
    )!;
    uint block_height = material::texture_is_compressed(desc.format) ? TEXEL_BLOCK_EXTENT : 1;
    uint height = material::texture_mip_extent(desc.height, unit.staged.mip);
    uint rows_left = (height + block_height - 1) / block_height - unit.staged.row;
    usz allowance = prepare_byte_allowance(budget);
    uint rows = allowance < first.row_bytes ? 1 : (uint)math::min((usz)rows_left, allowance / first.row_bytes);

    TextureBand band = texture_band(
        desc: desc,
        mip: unit.staged.mip,
        layer: unit.staged.layer,
        slice: unit.staged.slice,
        first_block_row: unit.staged.row,
        block_rows: rows,
    )!;

    return { .kind = PrepareResourceStep.TEXTURE_COPY, .band = band, .bytes = band.byte_count,
        .cost = { .staged_bytes = band.byte_count } };
}

fn bool? run_prepare_step(
    Renderer* renderer,
    PrepareRecord* record,
    PrepareUnit* unit,
    PrepareStepPlan* plan,
    PrepareReport* report,
) @private {
    switch (plan.kind) {
        case TEXTURE_IMAGE:
            TextureAsset* source = renderer.assets.texture(unit.texture);
            uint chain_mips = texture_chain_mips(source);
            bool eligible = texture_eligible(source.desc, source.source_kind, chain_mips);
            gpu::TextureDesc desc = texture_gpu_description(
                desc: source.desc,
                format: texture_format(source.desc.format),
                chain_mips: chain_mips,
                base: unit.texture_base,
                copy_source: eligible,
            );
            report.objects++;
            unit.texture_candidate = {
                .asset = unit.texture, .revision = unit.revision,
                .texture = gpu::create_texture(&renderer.device, &desc)!,
                .width = desc.width, .height = desc.height, .depth = desc.depth,
                .mip_count = desc.mip_levels, .layers = desc.array_layers,
                .is_cube = source.desc.is_cube, .copy_source = eligible, .format = desc.format,
                .semantic = source.desc.semantic,
            };

            if (source.desc.coverage == CoveragePolicy.THRESHOLD) {
                unit.texture_candidate.coverage_resource = create_texture_coverage_resource(
                    allocator: renderer.allocator,
                    desc: source.desc,
                    statistics: &source.coverage_statistics,
                    revision: unit.revision,
                );
            }

            unit.staged.mip = unit.texture_base;
            uint chain_extent = math::max(source.desc.width, source.desc.height);
            uint tail_base = eligible ? texture_tail_base(chain_extent, chain_mips) : 0;
            unit.residency_candidate = {
                .chain_mips = chain_mips, .chain_width = source.desc.width, .chain_height = source.desc.height,
                .format = source.desc.format, .level_bytes = texture_level_bytes(source.desc, chain_mips)!,
                .tail_base = tail_base,
                .resident_base = unit.texture_base, .required_base = chain_mips,
                .last_used_frame = renderer.frame_index, .eligible = eligible,
                .full_reader = unit.full_reader || renderer.residencies[unit.texture.index].full_reader,
                .streamed = eligible && !(unit.full_reader || renderer.residencies[unit.texture.index].full_reader),
                .raisable = texture_source_present(source), .regenerates = source.source_kind == MIP_ZERO,
            };

            return false;

        case TEXTURE_VIEW:
            gpu::TextureViewDesc desc = { .cube = unit.texture_candidate.is_cube };
            report.views++;
            unit.texture_candidate.view = gpu::create_texture_view(
                device: &renderer.device,
                texture: unit.texture_candidate.texture,
                desc: &desc,
            )!;
            TextureAsset* source = renderer.assets.texture(unit.texture);
            if (source.desc.storage) {
                unit.texture_candidate.storage_views = alloc::new_array(
                    allocator: renderer.allocator,
                    $Type: gpu::TextureView,
                    elements: (sz)unit.texture_candidate.mip_count * unit.texture_candidate.layers,
                );
            }

            return false;

        case TEXTURE_STORAGE_VIEW:
            uint mip_count = unit.texture_candidate.mip_count;
            uint mip = unit.creation_next % mip_count;
            uint layer = unit.creation_next / mip_count;
            gpu::TextureViewDesc desc = { .base_mip = mip, .mip_count = 1, .base_layer = layer, .layer_count = 1 };
            report.views++;
            unit.texture_candidate.storage_views[unit.creation_next] =
                gpu::create_texture_view(
                    device: &renderer.device,
                    texture: unit.texture_candidate.texture,
                    desc: &desc,
                )!;
            unit.creation_next++;

            return false;

        case GENERATION_STORAGE:
            TextureAsset* source = renderer.assets.texture(unit.texture);
            record.chain = create_generated_texture_mips(renderer.allocator, source.desc)!;
            record.chain_active = true;
            record.chain_unit = unit.index;
            record.generation_mip = 1;
            record.generation_layer = 0;
            record.generation_row = 0;
            record.generation_outputs = 0;
            record.generation_desc = source.desc;
            record.generation_statistics = source.coverage_statistics;

            if (source.desc.coverage == CoveragePolicy.THRESHOLD) {
                record.coverage = begin_texture_coverage(
                    desc: source.desc,
                    mip: 1,
                    face: 0,
                    statistics: &record.generation_statistics,
                );
            }

            unit.generated_done = 0;

            return false;

        case GENERATE:
            TextureAsset* source = renderer.assets.texture(unit.texture);
            material::TextureDesc desc = record.generation_desc;
            bool coverage = desc.coverage == CoveragePolicy.THRESHOLD;
            std::time::Clock started = clock::now();
            defer report.generation_ns = prepare_add(report.generation_ns, (ulong)started.to_now());

            if (!coverage || record.coverage.phase == 0) {
                write_texture_filter_band(
                    desc: desc,
                    mip: plan.band.mip,
                    layer: plan.band.layer,
                    first_row: plan.band.y,
                    row_count: plan.band.height,
                    mip_zero: source.pixels,
                    chain: &record.chain,
                    coverage: coverage ? &record.coverage : null,
                )!;
            } else {
                usz layer_bytes = material::texture_mip_bytes(desc, plan.band.mip)!;
                char[] destination = record.chain.pixels[
                    record.chain.offsets[plan.band.mip - 1] + (usz)plan.band.layer * layer_bytes:layer_bytes];
                write_texture_coverage_band(
                    desc: desc,
                    destination: destination,
                    state: &record.coverage,
                    row_count: plan.band.height,
                );
            }

            ulong actual_outputs = (ulong)plan.band.width * plan.band.height;
            record.generation_outputs += actual_outputs;
            record.generation_row += plan.band.height;
            unit.generated_done = prepare_add(unit.generated_done, plan.cost.generated_texels);
            record.texels_done = prepare_add(record.texels_done, plan.cost.generated_texels);
            report.generated_texels = prepare_add(report.generated_texels, plan.cost.generated_texels);
            if (coverage) {
                record.coverage.reserved += actual_outputs;
                record.coverage.row = record.generation_row;
            }

            if (record.generation_row == material::texture_mip_extent(desc.height, record.generation_mip)) {
                bool completed = true;

                if (coverage) {
                    ulong reserved_before = record.coverage.reserved;
                    finish_texture_coverage_pass(&record.coverage);

                    ulong skipped = record.coverage.reserved - reserved_before;

                    if (skipped) {
                        GeneratedTextureLayout layout = generated_texture_mip_layout(desc)!;
                        ulong before = texture_scan_charge(
                            base_texels: layout.base_texels,
                            position: record.generation_outputs,
                            output_total: layout.output_texels,
                            passes: layout.passes,
                        );

                        record.generation_outputs += skipped;

                        ulong after = texture_scan_charge(
                            base_texels: layout.base_texels,
                            position: record.generation_outputs,
                            output_total: layout.output_texels,
                            passes: layout.passes,
                        );

                        ulong credit = after - before;
                        unit.generated_done = prepare_add(unit.generated_done, credit);
                        record.texels_done = prepare_add(record.texels_done, credit);
                    }

                    completed = record.coverage.phase == texture_generation_passes(desc);
                }

                record.generation_row = 0;

                if (completed) {
                    if (coverage) store_texture_coverage_result(
                        resource: unit.texture_candidate.coverage_resource,
                        state: &record.coverage,
                    );

                    if (++record.generation_layer == desc.layers) {
                        record.generation_layer = 0;
                        record.generation_mip++;
                    }

                    if (coverage && record.generation_mip <= record.chain.mip_count) {
                        record.coverage = begin_texture_coverage(
                            desc: desc,
                            mip: record.generation_mip,
                            face: record.generation_layer,
                            statistics: &record.generation_statistics,
                        );
                    }
                }
            }

            return false;

        case TEXTURE_COPY:
            return run_prepare_texture_copy(
                renderer: renderer,
                record: record,
                unit: unit,
                band: &plan.band,
                report: report,
            );

        case EMPTY_TEXTURE:
            transition_prepare_texture(renderer, unit, renderer.sampled_state)!;
            install_prepare_texture(renderer, record, unit);
            renderer.stats.uploads++;

            return true;

        case GEOMETRY_STORAGE:
            GeometryAsset* source = renderer.assets.geometry(unit.geometry);
            GeometryLayout layout = geometry_layout_from_width(&source.data, source.joints_u16);
            gpu::AllocationDesc desc = {
                .size = layout.total_bytes,
                .alignment = STREAM_ALIGNMENT,
                .memory_class = gpu::MemoryClass.GPU_PRIVATE,
                .access = { .graphics },
                .debug_name = "prepared_geometry"
            };
            report.allocations++;
            gpu::GpuAllocation allocation = gpu::allocate_memory(&renderer.device, &desc)!;
            unit.geometry_candidate.allocation = allocation;
            gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, allocation)!;
            unit.geometry_candidate = { .asset = unit.geometry, .revision = unit.revision, .allocation = allocation,
                .root = gpu::get_span_address(&renderer.device, span)!,
                .layout = layout, .topology = source.data.topology, .bounds = source.data.bounds };
            unit.geometry_candidate.positions = span.checked_subspan(
                offset: layout.positions,
                size: (usz)layout.vertex_count * Vec3::size,
            )!;
            if (layout.index_count) unit.geometry_candidate.indices = span.checked_subspan(
                offset: layout.indices,
                size: (usz)layout.index_count * layout.index_stride,
            )!;
            unit.initialized = true;

            return false;

        case GEOMETRY_COPY:
            GeometryAsset* source = renderer.assets.geometry(unit.geometry);
            gpu::MappedGpuSpan staging = take_prepare_staging(
                renderer: renderer,
                bytes: plan.bytes,
                alignment: STREAM_ALIGNMENT,
                report: report,
            )!;
            write_geometry_range(
                destination: staging.bytes,
                geometry: &source.data,
                layout: &unit.geometry_candidate.layout,
                base: unit.geometry_candidate.root,
                offset: plan.offset,
            );
            report.staged_bytes += plan.bytes;
            renderer.stats.upload_bytes += (uint)plan.bytes;
            gpu::GpuSpan target = gpu::get_allocation_span(&renderer.device, unit.geometry_candidate.allocation)!
                .checked_subspan(plan.offset, plan.bytes)!;
            record_prepare_buffer_copy(
                renderer: renderer,
                unit: unit,
                source: staging.span,
                target: target,
            )!;
            unit.staged.bytes += plan.bytes;
            record.bytes_done += plan.bytes;
            if (unit.staged.bytes == unit.bytes) {
                install_prepare_geometry(renderer, record, unit);
                renderer.stats.uploads++;

                return true;
            }

            return false;

        case MATERIAL_STORAGE:
            Material* source = &renderer.assets.material(unit.material).data;
            gpu::AllocationDesc desc = {
                .size = source.custom.param_block.len,
                .alignment = STREAM_ALIGNMENT,
                .memory_class = gpu::MemoryClass.GPU_PRIVATE,
                .access = { .graphics },
                .debug_name = "prepared_material_payload"
            };
            report.allocations++;
            unit.material_candidate.payload = gpu::allocate_memory(&renderer.device, &desc)!;
            unit.material_candidate.payload_size = source.custom.param_block.len;
            unit.material_candidate.payload_address = gpu::get_span_address(
                device: &renderer.device,
                span: gpu::get_allocation_span(&renderer.device, unit.material_candidate.payload)!,
            )!;

            return false;

        case MATERIAL_PAYLOAD:
            Material* source = &renderer.assets.material(unit.material).data;
            gpu::MappedGpuSpan staging = take_prepare_staging(
                renderer: renderer,
                bytes: plan.bytes,
                alignment: STREAM_ALIGNMENT,
                report: report,
            )!;
            staging.bytes[..] = source.custom.param_block[plan.offset:plan.bytes];
            report.staged_bytes += plan.bytes;
            renderer.stats.upload_bytes += (uint)plan.bytes;
            gpu::GpuSpan target = gpu::get_allocation_span(&renderer.device, unit.material_candidate.payload)!
                .checked_subspan(plan.offset, plan.bytes)!;
            record_prepare_buffer_copy(
                renderer: renderer,
                unit: unit,
                source: staging.span,
                target: target,
            )!;
            unit.staged.bytes += plan.bytes;
            record.bytes_done += plan.bytes;

            return false;

        case MATERIAL_BLOCK:
            gpu::MappedGpuSpan staging = take_prepare_staging(
                renderer: renderer,
                bytes: MATERIAL_STRIDE,
                alignment: STREAM_ALIGNMENT,
                report: report,
            )!;
            material_prepare_block(
                renderer: renderer,
                material: unit.material,
                candidate: &unit.material_candidate,
                block: staging.bytes,
            )!;
            report.staged_bytes += MATERIAL_STRIDE;
            renderer.stats.upload_bytes += (uint)MATERIAL_STRIDE;
            gpu::GpuSpan target = renderer.material_heap_span.checked_subspan(
                offset: (usz)unit.material.index * MATERIAL_STRIDE,
                size: MATERIAL_STRIDE,
            )!;
            unit.material_candidate.address = gpu::get_span_address(&renderer.device, target)!;
            record_prepare_buffer_copy(
                renderer: renderer,
                unit: unit,
                source: staging.span,
                target: target,
            )!;
            unit.staged.bytes += MATERIAL_STRIDE;
            record.bytes_done += MATERIAL_STRIDE;
            install_prepare_material(renderer, record, unit);
            renderer.stats.uploads++;

            return true;

        case SAMPLER:
            resolve_sampler(renderer, unit.sampler)!;

            return true;

        case TOON_SAMPLER:
            gpu::SamplerDesc desc = { .min_filter = gpu::Filter.NEAREST, .mag_filter = gpu::Filter.NEAREST,
                .mip_filter = gpu::Filter.NEAREST, .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
                .address_v = gpu::AddressMode.CLAMP_TO_EDGE, .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
                .debug_name = "toon_gradient" };
            renderer.toon_gradient_sampler = gpu::intern_sampler(&renderer.device, &desc)!;

            return true;

        case SHADER: return run_prepare_shader_step(renderer, unit, report);

        case PIPELINE:
            usz staged_before = report.staged_bytes;
            bool? done = run_prepare_pipeline_step(renderer, unit, report);
            if (prepare_pipeline_has_gpu_data(unit) && report.staged_bytes != staged_before) {
                unit.referenced_this_frame = true;
                record.pending_gpu = true;
                renderer.work_recorded = true;
                refresh_prepare_progress(record);
            }

            return done;

        case FINISH: return true;
    }
}

fn gpu::MappedGpuSpan? take_prepare_staging(
    Renderer* renderer,
    usz bytes,
    usz alignment,
    PrepareReport* report,
) @private {
    UploadRing* upload = &renderer.frames[renderer.recording_slot].upload;
    if (align_up(upload.head, alignment) + bytes > upload.mapped.bytes.len) report.allocations++;
    gpu::MappedGpuSpan? result = upload.take(&renderer.device, bytes, alignment);
    return result;
}

fn void? record_prepare_buffer_copy(
    Renderer* renderer,
    PrepareUnit* unit,
    gpu::GpuSpan source,
    gpu::GpuSpan target,
) @local {
    gpu::Barrier before = { .before = renderer.consumer_stages, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &before)!;
    gpu::BufferCopyDesc copy = { .src = source, .dst = target };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier after = { .before = { .transfer }, .after = renderer.consumer_stages };
    gpu::cmd_barrier(&renderer.commands, &after)!;
    renderer.work_recorded = true;
    unit.referenced_this_frame = true;
    renderer.prepares.get(unit.owner).pending_gpu = true;
}

fn void? transition_prepare_texture(Renderer* renderer, PrepareUnit* unit, gpu::TextureState after) @local {
    gpu::TextureBarrier barrier = gpu::texture_transition(
        texture: unit.texture_candidate.texture,
        before: unit.texture_candidate.state,
        after: after,
    )!;
    gpu::cmd_texture_barrier(&renderer.commands, &barrier)!;
    unit.texture_candidate.state = after;
    unit.referenced_this_frame = true;
    renderer.prepares.get(unit.owner).pending_gpu = true;
    renderer.work_recorded = true;
}

fn bool? run_prepare_texture_copy(
    Renderer* renderer,
    PrepareRecord* record,
    PrepareUnit* unit,
    TextureBand* band,
    PrepareReport* report,
) @local {
    TextureAsset* source = renderer.assets.texture(unit.texture);
    char[] bytes;

    switch (source.source_kind) {
        case MIP_ZERO:
            if (band.mip && source.desc.generate_mips) {
                usz offset = record.chain.offsets[band.mip - 1] + band.source_offset;
                bytes = record.chain.pixels[offset:band.byte_count];
            } else {
                if (!source.pixels.len) return c3d::ASSET_DATA_UNAVAILABLE~;
                if (source.pixels.len != band.layer_bytes * source.desc.layers) return c3d::INVALID_ARGUMENT~;
                bytes = source.pixels[band.source_offset:band.byte_count];
            }

        case SUPPLIED_MIPS:
            if (!source.supplied_mips.len) return c3d::ASSET_DATA_UNAVAILABLE~;

            usz index = (usz)band.mip * source.desc.layers + band.layer;
            if (index >= source.supplied_mips.len) return c3d::INVALID_ARGUMENT~;

            TextureMipData* mip = &source.supplied_mips[index];
            usz offset = band.source_offset - (usz)band.layer * band.layer_bytes;
            if (mip.mip != band.mip || mip.layer != band.layer || mip.bytes.len != band.layer_bytes) {
                return c3d::INVALID_ARGUMENT~;
            }

            bytes = mip.bytes[offset:band.byte_count];

        case EMPTY: return c3d::INVALID_ARGUMENT~;
    }

    bool filtered_source = source.source_kind == TextureSourceKind.MIP_ZERO && source.desc.generate_mips
      && (source.desc.width > 1 || source.desc.height > 1);
    if (!filtered_source) check_texture_normal_pixels(source.desc, bytes)!;
    gpu::MappedGpuSpan staging = take_prepare_staging(
        renderer: renderer,
        bytes: band.byte_count,
        alignment: band.alignment,
        report: report,
    )!;
    staging.bytes[..] = bytes[..];
    report.staged_bytes += band.byte_count;
    renderer.stats.upload_bytes += (uint)band.byte_count;
    gpu::TextureState destination = { .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
        .stages = { .transfer }, .access = { .write } };
    transition_prepare_texture(renderer, unit, destination)!;
    gpu::BufferTextureCopyDesc copy = {
        .src = staging.span, .texture = unit.texture_candidate.texture, .mip = band.mip - unit.texture_base,
        .base_layer = band.layer, .layer_count = 1, .x = band.x, .y = band.y, .z = band.z,
        .width = band.width, .height = band.height, .depth = band.depth,
    };
    gpu::cmd_copy_buffer_to_texture(&renderer.commands, &copy)!;
    renderer.work_recorded = true;
    unit.referenced_this_frame = true;
    record.pending_gpu = true;
    unit.staged.bytes += band.byte_count;
    record.bytes_done += band.byte_count;
    uint block_height = material::texture_is_compressed(source.desc.format) ? TEXEL_BLOCK_EXTENT : 1;
    uint rows = (material::texture_mip_extent(source.desc.height, unit.staged.mip) + block_height - 1) / block_height;
    unit.staged.row += band.block_rows;
    if (unit.staged.row == rows) {
        unit.staged.row = 0;
        uint depth = source.desc.depth ? material::texture_mip_extent(source.desc.depth, unit.staged.mip) : 1;
        if (++unit.staged.slice == depth) {
            unit.staged.slice = 0;
            if (++unit.staged.layer == source.desc.layers) {
                unit.staged.layer = 0;
                unit.staged.mip++;
            }
        }
    }

    if (unit.staged.mip == texture_chain_mips(source)) {
        transition_prepare_texture(renderer, unit, renderer.sampled_state)!;
        unit.residency_candidate.raisable = texture_source_present(source);
        install_prepare_texture(renderer, record, unit);
        if (record.chain_active && record.chain_unit == unit.index) clear_prepare_chain(record);
        renderer.stats.uploads++;

        return true;
    }

    return false;
}

fn void clear_prepare_chain(PrepareRecord* record) @private {
    if (record.chain_active) destroy_texture_mips(&record.chain);
    record.chain_active = false;
    record.generation_outputs = 0;
    record.generation_mip = 0;
    record.generation_layer = 0;
    record.generation_row = 0;
    record.coverage = {};
    record.generation_desc = {};
    record.generation_statistics = {};
}
