module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render::post @public;
import c3d::shader;
import gpu;
import std::collections::list;
import std::collections::map;
import std::hash::fnv32a;
import std::math;
import std::time::clock;

const uint PREPARE_SHADER_STAGE_COUNT @private = 10; // every owned ShaderDesc byte array; spans check time between copies

enum PreparePipelineKind @private {
    CACHE,
    COMPUTE,
    RAY,
    SBT,
    SHEEN_LUT,
    VALIDATE,
}

enum PreparePipelinePass @private {
    REGISTRY,
    FORWARD,
    GBUFFER,
    DEPTH,
    VELOCITY,
}

enum PrepareComputeSlot @private {
    CLUSTER,
    SSAO,
    RT_AO,
    AO_BLUR,
    REFLECTION,
    REFLECTION_BLUR,
    SSGI_TRACE,
    SSGI_TEMPORAL,
    SSGI_FILTER,
    GRADE,
    FXAA,
    BLOOM_DOWN,
    BLOOM_UP,
    TILE_MAX,
    TILE_NEIGHBOR,
    DOF_COC,
    DOF_GATHER,
    DOF_COMPOSITE,
    MOTION_BLUR,
    TAA,
    EXPOSURE_HISTOGRAM,
    EXPOSURE_ADAPT,
    SHEEN_LUT,
}

struct PreparePipelineUnit @private {
    PreparePipelineKind kind;
    PreparePipelinePass pass;
    PrepareComputeSlot slot;
    ShaderVariant compute;
    PipelineKey key;
    gpu::GpuAllocation candidate;
    char[] handles;
    usz step_bytes;
    EnvironmentLutState sheen_checkpoint;
    EnvironmentLut lut_candidate;
    gpu::SamplerIndex lut_sampler;
    bool lut_sampler_ready;
}

struct PrepareShaderUnit @private {
    asset::ShaderDesc desc;
    uint stage;
    usz offset;
    ulong copied;
    bool initialized;
}

struct PreparePipelineIdentity @private {
    PreparePipelineKind kind;
    PreparePipelinePass pass;
    PrepareComputeSlot slot;
    ShaderVariant compute;
    PipelineKey key;
    GeometryId geometry;
    MaterialId material;
}

fn uint PreparePipelineIdentity.hash(&self) {
    return fnv32a::hash(((char*)self)[:PreparePipelineIdentity::size]);
}

fn bool PreparePipelineIdentity.equals(&self, PreparePipelineIdentity other) {
    return self.kind == other.kind && self.pass == other.pass && self.slot == other.slot
        && self.compute.shader == other.compute.shader && self.compute.flags == other.compute.flags
        && self.key.equals(other.key)
        && c3d::same_id(self.geometry, other.geometry) && c3d::same_id(self.material, other.material);
}

fn char[]* prepare_shader_stage(asset::ShaderDesc* desc, uint stage) @private {
    switch (stage) {
        case 0: return &desc.fragment;
        case 1: return &desc.gbuffer;
        case 2: return &desc.traced_fragment.hardware;
        case 3: return &desc.traced_fragment.software;
        case 4: return &desc.vertex.shaded;
        case 5: return &desc.vertex.depth;
        case 6: return &desc.vertex.instanced_shaded;
        case 7: return &desc.vertex.instanced_depth;
        case 8: return &desc.vertex.velocity;
        case 9: return &desc.vertex.instanced_velocity;
        default: unreachable("invalid shader stage cursor");
    }
}

fn bool prepare_shader_current(Renderer* renderer, PrepareUnit* unit) @private {
    if (!renderer.assets.shaders.is_live(unit.shader)) return true;
    ShaderRes* mirror = &renderer.shaders[unit.shader.index];
    return c3d::same_id(mirror.asset, unit.shader)
        && (mirror.revision == unit.revision || mirror.rejected_revision == unit.revision);
}

fn void account_prepare_cache_creation(
    Renderer* renderer,
    PrepareReport* report,
    PipelineCreationCounters before,
) @private {
    PipelineCreationCounters after = renderer.pipelines.creations;
    report.pipelines += (uint)(after.calls - before.calls);
    report.pipeline_ns += after.elapsed_ns - before.elapsed_ns;
    report.pipeline_keys += (uint)(after.keys - before.keys);
}

fn PrepareStepCost? prepare_shader_cost(Renderer* renderer, PrepareUnit* unit, PrepareBudget* budget) @private {
    if (prepare_shader_current(renderer, unit)) return {};
    PrepareShaderUnit* job = &unit.shader_job;
    if (!job.initialized || job.stage < PREPARE_SHADER_STAGE_COUNT) return {};
    ShaderRes* mirror = &renderer.shaders[unit.shader.index];
    uint old_revision = c3d::same_id(mirror.asset, unit.shader) ? mirror.revision : 0;
    uint required;
    @pool() {
        PipelineKey[] keys = renderer.pipelines.keys_of(tmem, unit.shader, old_revision);
        budget.report.pipeline_keys += (uint)keys.len;
        foreach (key : keys) if (key_stages_present(key, &job.desc)) required++;
    };
    return { .pipelines = required };
}

fn bool? run_prepare_shader_step(Renderer* renderer, PrepareUnit* unit, PrepareReport* report) @private {
    if (prepare_shader_current(renderer, unit)) {
        free_prepare_shader_unit(renderer, unit);
        return true;
    }
    PrepareShaderUnit* job = &unit.shader_job;
    ShaderAsset* source = renderer.assets.shader(unit.shader);
    if (!job.initialized) {
        job.desc.param_block_size = source.desc.param_block_size;
        job.desc.scene_reads = source.desc.scene_reads;
        job.initialized = true;
    }
    while (job.stage < PREPARE_SHADER_STAGE_COUNT) {
        char[] input = *prepare_shader_stage(&source.desc, job.stage);
        if (job.offset == input.len) {
            job.stage++;
            job.offset = 0;
            continue;
        }
        char[]* output = prepare_shader_stage(&job.desc, job.stage);
        if (!output.len) *output = alloc::alloc_array(renderer.allocator, char, (sz)input.len);
        usz bytes = math::min((usz)input.len - job.offset, PREPARE_SPAN_BYTES);
        mem::copy(output.ptr + job.offset, input.ptr + job.offset, (sz)bytes);
        job.offset += bytes;
        job.copied += bytes;
        report.copied_bytes += bytes;
        if (job.offset == input.len) {
            job.stage++;
            job.offset = 0;
            while (job.stage < PREPARE_SHADER_STAGE_COUNT && !prepare_shader_stage(&source.desc, job.stage).len) job.stage++;
        }
        return false;
    }
    PipelineCreationCounters before = renderer.pipelines.creations;
    defer account_prepare_cache_creation(renderer, report, before);
    if (catch excuse = adopt_prepared_shader(
        renderer: renderer,
        shader: unit.shader,
        revision: unit.revision,
        owned: &job.desc,
    )) {
        if (!pipeline_rejected(renderer, unit.shader, excuse)) return excuse~;
        free_prepare_shader_unit(renderer, unit);
        return true;
    }
    *job = {};
    return true;
}

fn void free_prepare_shader_unit(Renderer* renderer, PrepareUnit* unit) @private {
    asset::free_shader_desc(renderer.allocator, &unit.shader_job.desc);
    unit.shader_job = {};
}

fn gpu::PipelineHandle* prepare_compute_slot(Renderer* renderer, PrepareComputeSlot slot) @private {
    switch (slot) {
        case CLUSTER: return &renderer.cluster_pipeline;
        case SSAO: return &renderer.ambient_occlusion_pipelines.ssao;
        case RT_AO: return &renderer.ambient_occlusion_pipelines.ray_traced;
        case AO_BLUR: return &renderer.ambient_occlusion_pipelines.blur;
        case REFLECTION: return &renderer.reflection_pipelines.trace;
        case REFLECTION_BLUR: return &renderer.reflection_pipelines.blur;
        case SSGI_TRACE: return &renderer.screen_space_gi_pipelines.trace;
        case SSGI_TEMPORAL: return &renderer.screen_space_gi_pipelines.temporal;
        case SSGI_FILTER: return &renderer.screen_space_gi_pipelines.filter;
        case GRADE: return &renderer.post_pipelines.grade;
        case FXAA: return &renderer.post_pipelines.fxaa;
        case BLOOM_DOWN: return &renderer.post_pipelines.bloom_downsample;
        case BLOOM_UP: return &renderer.post_pipelines.bloom_upsample;
        case TILE_MAX: return &renderer.post_pipelines.tile_max;
        case TILE_NEIGHBOR: return &renderer.post_pipelines.tile_neighbor;
        case DOF_COC: return &renderer.post_pipelines.dof_coc;
        case DOF_GATHER: return &renderer.post_pipelines.dof_gather;
        case DOF_COMPOSITE: return &renderer.post_pipelines.dof_composite;
        case MOTION_BLUR: return &renderer.post_pipelines.motion_blur;
        case TAA: return &renderer.post_pipelines.taa_resolve;
        case EXPOSURE_HISTOGRAM: return &renderer.post_pipelines.exposure_histogram;
        case EXPOSURE_ADAPT: return &renderer.post_pipelines.exposure_adapt;
        case SHEEN_LUT: return &renderer.environment_state.pipelines.sheen_lut;
    }
}

fn bool prepare_pipeline_dead(Renderer* renderer, PrepareUnit* unit) @private {
    if (unit.geometry.generation && !renderer.assets.geometries.is_live(unit.geometry)) return true;
    if (unit.material.generation) {
        if (!renderer.assets.materials.is_live(unit.material)) return true;
        Material* data = &renderer.assets.material(unit.material).data;
        if (data.kind == MaterialKind.CUSTOM && !renderer.assets.shaders.is_live(data.custom.shader)) return true;
    }
    return unit.pipeline.key.shader.generation && !renderer.assets.shaders.is_live(unit.pipeline.key.shader);
}

fn bool prepare_pipeline_dependencies_current(Renderer* renderer, PrepareUnit* unit) @private {
    if (prepare_pipeline_dead(renderer, unit)) return true;
    if (unit.geometry.generation) {
        GeometryAsset* source = renderer.assets.geometry(unit.geometry);
        GpuGeometry* mirror = &renderer.geometries[unit.geometry.index];
        if (!c3d::same_id(mirror.asset, unit.geometry) || mirror.revision != source.header.revision) return false;
    }
    if (unit.material.generation) {
        MaterialAsset* source = renderer.assets.material(unit.material);
        MaterialRes* mirror = &renderer.materials[unit.material.index];
        if (!c3d::same_id(mirror.asset, unit.material) || mirror.revision != source.header.revision) return false;
    }
    ShaderId shader_id = unit.pipeline.key.shader;
    if (shader_id.generation) {
        ShaderAsset* source = renderer.assets.shader(shader_id);
        ShaderRes* mirror = &renderer.shaders[shader_id.index];
        if (!c3d::same_id(mirror.asset, shader_id)) return false;
        if (mirror.revision != source.header.revision && mirror.rejected_revision != source.header.revision) return false;
    }
    return true;
}

fn PipelineKey? prepare_cache_key(Renderer* renderer, PrepareUnit* unit) @private {
    PipelineKey key = unit.pipeline.key;
    if (!key.shader.generation) return key;
    ShaderRes* mirror = &renderer.shaders[key.shader.index];
    asset::ShaderDesc* desc = &mirror.desc;
    key.shader_revision = mirror.revision;
    switch (unit.pipeline.pass) {
        case FORWARD:
            key.custom = { .vertex = desc.vertex.shaded.len > 0, .fragment = true };
            key.fragment = custom_fragment_variant(desc, key.fragment.flags);
            if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = key.vertex.flags & shader::SHADER_FLAG_INSTANCED };
        case GBUFFER:
            key.custom = { .vertex = desc.vertex.shaded.len > 0, .gbuffer = true };
            if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = key.vertex.flags & shader::SHADER_FLAG_INSTANCED };
        case DEPTH:
            key.custom = { .vertex = desc.vertex.depth.len > 0 };
            if (key.custom.vertex) key.vertex = {
                .shader = MESH,
                .flags = shader::SHADER_FLAG_DEPTH_ONLY | (key.vertex.flags & shader::SHADER_FLAG_INSTANCED),
            };
        case VELOCITY:
            key.custom = { .vertex = desc.vertex.velocity.len > 0 };
            if (key.custom.vertex) key.vertex = {
                .shader = MESH,
                .flags = shader::SHADER_FLAG_VELOCITY | (key.vertex.flags & shader::SHADER_FLAG_INSTANCED),
            };
        case REGISTRY:
    }
    if (!(uint)key.custom) {
        key.shader = {};
        key.shader_revision = 0;
        return key;
    }
    if (!key_stages_present(key, desc)) return PIPELINE_REJECTED~;
    return key;
}

fn PrepareStepCost? prepare_pipeline_cost(Renderer* renderer, PrepareUnit* unit, PrepareBudget* budget) @private {
    if (prepare_pipeline_dead(renderer, unit)) return {};
    switch (unit.pipeline.kind) {
        case VALIDATE:
            validate_normal_geometry(
                geometry: &renderer.geometries[unit.geometry.index],
                material: &renderer.assets.material(unit.material).data,
                bindings: &renderer.materials[unit.material.index].bindings,
                line_polygon_mode: renderer.caps.line_polygon_mode,
            )!;
            return {};
        case CACHE:
            PipelineKey? key = prepare_cache_key(renderer, unit);
            if (catch excuse = key) return {};
            bool cached = renderer.pipelines.pipelines.has_key(key) || renderer.pipelines.rejected.has_key(key);
            return { .pipelines = cached ? 0 : 1 };
        case COMPUTE:
            return { .pipelines = prepare_compute_slot(renderer, unit.pipeline.slot).is_valid() ? 0 : 1 };
        case RAY:
            return { .pipelines = renderer.path_tracer.pipeline.is_valid() ? 0 : 1 };
        case SBT:
            if (renderer.path_tracer.sbt.is_valid()) return {};
            if (!unit.pipeline.handles.len || !unit.pipeline.candidate.is_valid()) return {};
            usz available = prepare_byte_allowance(budget);
            unit.pipeline.step_bytes = available ? math::min(unit.bytes - unit.staged.bytes, available) : (usz)1;
            return { .staged_bytes = unit.pipeline.step_bytes };
        case SHEEN_LUT:
            EnvironmentLutState state = renderer.environment_state.sheen_lut.state;
            if (state == EnvironmentLutState.RECORDED || state == EnvironmentLutState.READY) return {};
            if (state == EnvironmentLutState.NONE && (!unit.pipeline.lut_candidate.texture.is_valid()
              || !unit.pipeline.lut_candidate.view.is_valid() || !unit.pipeline.lut_sampler_ready)) return {};
            return { .staged_bytes = BrdfLutRoot::size };
    }
}

fn bool? run_prepare_pipeline_step(Renderer* renderer, PrepareUnit* unit, PrepareReport* report) @private {
    if (prepare_pipeline_dead(renderer, unit)) return true;
    switch (unit.pipeline.kind) {
        case VALIDATE: return true;
        case CACHE:
            report.pipeline_lookups++;
            renderer.stats.pipeline_lookups++;
            PipelineKey? selected = prepare_cache_key(renderer, unit);
            if (catch excuse = selected) {
                if (excuse == PIPELINE_REJECTED) return true;
                return excuse~;
            }
            PipelineKey key = selected;
            bool hit = renderer.pipelines.pipelines.has_key(key);
            if (hit) report.pipeline_hits++;
            PipelineCreationCounters before = renderer.pipelines.creations;
            defer account_prepare_cache_creation(renderer, report, before);
            CustomStageSource source;
            if ((uint)key.custom) source = custom_stage_source(&renderer.shaders[key.shader.index].desc, key);
            if (catch excuse = renderer.pipelines.get(&renderer.device, key, &source)) {
                if (key.shader.generation && pipeline_rejected(renderer, key.shader, excuse)) return true;
                return excuse~;
            }
            return true;
        case COMPUTE:
            gpu::PipelineHandle* slot = prepare_compute_slot(renderer, unit.pipeline.slot);
            report.pipeline_lookups++;
            if (slot.is_valid()) {
                report.pipeline_hits++;
                return true;
            }
            gpu::ComputePipelineDesc description = {
                .shader = { .spirv = renderer.pipelines.registry.get(unit.pipeline.compute)! },
                .debug_name = "prepared_compute",
            };
            std::time::Clock started = clock::now();
            report.pipelines++;
            defer report.pipeline_ns += (ulong)started.to_now();
            *slot = gpu::create_compute_pipeline(&renderer.device, &description)!;
            return true;
        case RAY:
            report.pipeline_lookups++;
            if (renderer.path_tracer.pipeline.is_valid()) {
                report.pipeline_hits++;
                return true;
            }
            acquire_path_tracer_pipeline(renderer, report)!;
            return true;
        case SBT:
            return run_prepare_sbt_step(renderer, unit, report);
        case SHEEN_LUT:
            return run_prepare_sheen_step(renderer, unit, report);
    }
}

fn bool prepare_pipeline_has_gpu_data(PrepareUnit* unit) @private {
    return unit.pipeline.kind == PreparePipelineKind.SBT || unit.pipeline.kind == PreparePipelineKind.SHEEN_LUT;
}

fn void checkpoint_prepare_pipeline_unit(Renderer* renderer, PrepareUnit* unit) @private {
    if (unit.pipeline.kind == PreparePipelineKind.SHEEN_LUT) {
        unit.pipeline.sheen_checkpoint = renderer.environment_state.sheen_lut.state;
    }
}

fn void rollback_prepare_pipeline_unit(Renderer* renderer, PrepareUnit* unit) @private {
    if (unit.pipeline.kind == PreparePipelineKind.SHEEN_LUT
      && unit.pipeline.sheen_checkpoint != EnvironmentLutState.READY
      && renderer.environment_state.sheen_lut.state == EnvironmentLutState.NONE) {
        unit.staged.bytes = 0;
        unit.done = false;
    }
}

fn void free_prepare_pipeline_unit(Renderer* renderer, PrepareUnit* unit) @private {
    if (unit.pipeline.candidate.is_valid()) retire_prepare_allocation(renderer, unit, unit.pipeline.candidate);
    alloc::free(renderer.allocator, unit.pipeline.handles.ptr);
    unit.pipeline.candidate = {};
    unit.pipeline.handles = {};
    TextureRes lut = { .texture = unit.pipeline.lut_candidate.texture, .view = unit.pipeline.lut_candidate.view };
    if (lut.texture.is_valid() || lut.view.is_valid()) retire_prepare_texture(renderer, unit, &lut);
    unit.pipeline.lut_candidate = {};
    unit.pipeline.lut_sampler = {};
    unit.pipeline.lut_sampler_ready = false;
}

fn void append_prepare_compute(
    List{PrepareUnit}* listed,
    PrepareComputeSlot slot,
    ShaderName shader_name,
    uint flags = 0,
) @private {
    listed.push({
        .kind = PrepareUnitKind.PIPELINES,
        .pipeline = { .kind = PreparePipelineKind.COMPUTE, .slot = slot, .compute = { .shader = shader_name, .flags = flags } },
    });
}

fn void append_prepare_cache(
    List{PrepareUnit}* listed,
    PipelineKey key,
    PreparePipelinePass pass = PreparePipelinePass.REGISTRY,
    GeometryId geometry = {},
    MaterialId material = {},
) @private {
    listed.push({
        .kind = PrepareUnitKind.PIPELINES,
        .geometry = geometry,
        .material = material,
        .pipeline = { .kind = PreparePipelineKind.CACHE, .pass = pass, .key = key },
    });
}

fn void append_prepare_material_pipelines(Renderer* renderer, MaterialId material, List{PrepareUnit}* listed) @private {
    if (!renderer.assets.materials.is_live(material)) return;
    if (!material_uses_sheen(&renderer.assets.material(material).data)) return;
    append_prepare_compute(listed, PrepareComputeSlot.SHEEN_LUT, ShaderName.SHEEN_LUT);
    listed.push({ .kind = PrepareUnitKind.PIPELINES, .bytes = BrdfLutRoot::size,
        .pipeline = { .kind = PreparePipelineKind.SHEEN_LUT } });
}

fn void append_prepare_mesh_key(
    Renderer* renderer,
    List{PrepareUnit}* listed,
    PipelineKey key,
    PreparePipelinePass pass,
    GeometryId geometry,
    MaterialId material,
) @private {
    Material* data = &renderer.assets.material(material).data;
    if (data.kind == MaterialKind.CUSTOM) {
        key.shader = data.custom.shader;
        if (renderer.assets.shaders.is_live(key.shader)) key.shader_revision = renderer.assets.shader(key.shader).header.revision;
    }
    append_prepare_cache(
        listed: listed,
        key: key,
        pass: pass,
        geometry: geometry,
        material: material,
    );
}

fn void append_prepare_pipelines(
    Renderer* renderer,
    GeometryId geometry,
    MaterialId material,
    bool morphed,
    List{PrepareUnit}* listed,
) @private {
    GeometryAsset* source = renderer.assets.geometry(geometry);
    GeometryFlags flags = geometry_current(renderer, geometry)
        ? renderer.geometries[geometry.index].layout.flags : geometry_layout_from_width(&source.data, source.joints_u16).flags;
    Material* data = &renderer.assets.material(material).data;
    bool wireframe = data.common.wireframe && renderer.caps.line_polygon_mode;
    gpu::PolygonMode polygon = wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL;
    listed.push({ .kind = PrepareUnitKind.PIPELINES, .geometry = geometry, .material = material,
        .pipeline = { .kind = PreparePipelineKind.VALIDATE } });
    ShaderVariant vertex = mesh_vertex_variant(flags, morphed, true);
    PipelineKey forward = forward_pipeline_key(
        material: data,
        vertex: vertex,
        polygon: polygon,
        shadow_flags: 0,
    );
    append_prepare_mesh_key(
        renderer: renderer,
        listed: listed,
        key: forward,
        pass: PreparePipelinePass.FORWARD,
        geometry: geometry,
        material: material,
    );
    if (data.common.alpha_mode != AlphaMode.BLEND) {
        ShaderVariant depth_vertex = mesh_vertex_variant(
            flags: flags,
            morphed: morphed,
            skinned: true,
            base_flags: shader::SHADER_FLAG_DEPTH_ONLY,
        );
        PipelineKey depth = {
            .vertex = depth_vertex,
            .fragment = { .shader = DEPTH_ONLY,
                .flags = data.common.alpha_mode == AlphaMode.MASK && flags.has_colors ? shader::SHADER_FLAG_VERTEX_COLOR : 0 },
            .depth_format = DEPTH_FORMAT,
            .samples = gpu::SampleCount.ONE,
            .polygon = polygon,
        };
        append_prepare_mesh_key(
            renderer: renderer,
            listed: listed,
            key: depth,
            pass: PreparePipelinePass.DEPTH,
            geometry: geometry,
            material: material,
        );
    }
    bool custom_gbuffer;
    if (data.kind == MaterialKind.CUSTOM && renderer.assets.shaders.is_live(data.custom.shader)) {
        custom_gbuffer = renderer.assets.shader(data.custom.shader).desc.gbuffer.len > 0;
        ShaderRes* mirror = &renderer.shaders[data.custom.shader.index];
        if (c3d::same_id(mirror.asset, data.custom.shader)) custom_gbuffer |= mirror.desc.gbuffer.len > 0;
    }
    if (gbuffer_encodable(data, custom_gbuffer)) {
        PipelineKey gbuffer = gbuffer_pipeline_key(vertex, gbuffer_fragment(data), polygon);
        append_prepare_mesh_key(
            renderer: renderer,
            listed: listed,
            key: gbuffer,
            pass: PreparePipelinePass.GBUFFER,
            geometry: geometry,
            material: material,
        );
    }
    foreach (&view : renderer.views.items) {
        if (!view.live) continue;
        if (view.desc.ray_tracing.shadows) {
            PipelineKey traced = forward_pipeline_key(
                material: data,
                vertex: vertex,
                polygon: polygon,
                shadow_flags: rt_shadow_flags(renderer, true),
            );
            append_prepare_mesh_key(
                renderer: renderer,
                listed: listed,
                key: traced,
                pass: PreparePipelinePass.FORWARD,
                geometry: geometry,
                material: material,
            );
        }
        if (post::uses_velocity(&view.desc) && writes_own_depth(data)) {
            PipelineKey velocity = post::geometry_velocity_pipeline_key(
                vertex: vertex,
                polygon: polygon,
                format: post::velocity_format(&view.desc),
            );
            append_prepare_mesh_key(
                renderer: renderer,
                listed: listed,
                key: velocity,
                pass: PreparePipelinePass.VELOCITY,
                geometry: geometry,
                material: material,
            );
        }
    }
}

fn void append_prepare_view_pipelines(Renderer* renderer, SceneReads reads, List{PrepareUnit}* listed) @private {
    if (reads.color) append_prepare_cache(listed, composite_pipeline_key(HDR_FORMAT));
    if (reads.depth) append_prepare_cache(listed, composite_pipeline_key(SCENE_DEPTH_FORMAT));
    foreach (&view : renderer.views.items) {
        if (!view.live) continue;
        ViewDesc* desc = &view.desc;
        if (desc.lights == LightSelection.CLUSTERED) append_prepare_compute(listed, PrepareComputeSlot.CLUSTER, LIGHT_CULL);
        if (desc.shading == ShadingPath.DEFERRED) {
            append_prepare_cache(listed, lighting_resolve_pipeline_key(rt_shadow_flags(renderer, desc.ray_tracing.shadows)));
        }
        switch (desc.ambient_occlusion.kind) {
            case NONE: break;
            case SSAO: append_prepare_compute(listed, PrepareComputeSlot.SSAO, SSAO);
            case RAY_TRACED:
                append_prepare_compute(
                    listed: listed,
                    slot: PrepareComputeSlot.RT_AO,
                    shader_name: RT_AO,
                    flags: trace_shader_flags(renderer),
                );
        }
        if (desc.ambient_occlusion.kind != AoKind.NONE) append_prepare_compute(listed, PrepareComputeSlot.AO_BLUR, AO_BLUR);
        if (desc.ray_tracing.reflections) {
            append_prepare_compute(
                listed: listed,
                slot: PrepareComputeSlot.REFLECTION,
                shader_name: RT_REFLECTIONS,
                flags: trace_shader_flags(renderer),
            );
            append_prepare_compute(listed, PrepareComputeSlot.REFLECTION_BLUR, RT_REFLECTION_BLUR);
        }
        if (desc.screen_space_gi.enabled) {
            append_prepare_compute(listed, PrepareComputeSlot.SSGI_TRACE, SSGI_TRACE);
            append_prepare_compute(listed, PrepareComputeSlot.SSGI_TEMPORAL, SSGI_TEMPORAL);
            append_prepare_compute(listed, PrepareComputeSlot.SSGI_FILTER, SSGI_FILTER);
        }
        if (desc.shading == ShadingPath.PATH_TRACED) {
            listed.push({ .kind = PrepareUnitKind.PIPELINES, .pipeline = { .kind = PreparePipelineKind.RAY } });
            listed.push({ .kind = PrepareUnitKind.PIPELINES,
                .bytes = (usz)renderer.caps.ray_tracing_pipelines.shader_group_handle_size * 3,
                .pipeline = { .kind = PreparePipelineKind.SBT } });
        }
        if (desc.post.bloom) {
            append_prepare_compute(listed, PrepareComputeSlot.BLOOM_DOWN, BLOOM_DOWNSAMPLE);
            append_prepare_compute(listed, PrepareComputeSlot.BLOOM_UP, BLOOM_UPSAMPLE);
        }
        if (desc.post.depth_of_field) {
            append_prepare_compute(listed, PrepareComputeSlot.DOF_COC, DOF_COC);
            append_prepare_compute(listed, PrepareComputeSlot.DOF_GATHER, DOF_GATHER);
            append_prepare_compute(listed, PrepareComputeSlot.DOF_COMPOSITE, DOF_COMPOSITE);
        }
        if (desc.post.motion_blur || desc.post.depth_of_field) {
            append_prepare_compute(listed, PrepareComputeSlot.TILE_MAX, TILE_MAX);
            append_prepare_compute(listed, PrepareComputeSlot.TILE_NEIGHBOR, TILE_NEIGHBOR);
        }
        if (desc.post.motion_blur) append_prepare_compute(listed, PrepareComputeSlot.MOTION_BLUR, MOTION_BLUR);
        if (post::uses_velocity(desc)) append_prepare_cache(listed, post::camera_velocity_pipeline_key(post::velocity_format(desc)));
        if (desc.post.anti_aliasing == AntiAliasing.TAA) append_prepare_compute(listed, PrepareComputeSlot.TAA, TAA_RESOLVE);
        if (post::auto_exposure_active(desc)) {
            append_prepare_compute(listed, PrepareComputeSlot.EXPOSURE_HISTOGRAM, EXPOSURE_HISTOGRAM);
            append_prepare_compute(listed, PrepareComputeSlot.EXPOSURE_ADAPT, EXPOSURE_ADAPT);
        }
        if (!view.hdr_color.texture.is_valid()) continue;
        gpu::Format output_format = view_output_format(renderer, desc);
        if (desc.post.anti_aliasing == AntiAliasing.FXAA) {
            append_prepare_compute(listed, PrepareComputeSlot.GRADE, GRADE);
            append_prepare_compute(listed, PrepareComputeSlot.FXAA, FXAA);
            append_prepare_cache(listed, post::fxaa_fragment_pipeline_key(output_format));
        } else {
            append_prepare_cache(listed, post::display_pipeline_key(output_format));
        }
    }
}

fn void append_prepare_finish(Renderer* renderer, List{PrepareUnit}* listed) @private {
    SceneReads reads;
    foreach (unit : *listed) {
        if (unit.kind != PrepareUnitKind.MATERIAL || !renderer.assets.materials.is_live(unit.material)) continue;
        Material* data = &renderer.assets.material(unit.material).data;
        SceneReads custom_reads;
        if (data.kind == MaterialKind.CUSTOM && renderer.assets.shaders.is_live(data.custom.shader)) {
            custom_reads = renderer.assets.shader(data.custom.shader).desc.scene_reads;
            ShaderRes* mirror = &renderer.shaders[data.custom.shader.index];
            if (c3d::same_id(mirror.asset, data.custom.shader)) custom_reads |= mirror.desc.scene_reads;
        }
        reads |= material_scene_reads(data, custom_reads);
    }
    append_prepare_view_pipelines(renderer, reads, listed);
    listed.push({ .kind = PrepareUnitKind.FINISH });
}

fn void deduplicate_prepare_pipeline_units(List{PrepareUnit}* listed) @private {
    HashMap{PreparePipelineIdentity, bool} seen;
    seen.tinit(listed.len() ? listed.len() * 2 : 1);
    List{PrepareUnit} unique;
    unique.tinit(listed.len());
    foreach (unit : *listed) {
        if (unit.kind == PrepareUnitKind.PIPELINES) {
            PreparePipelineUnit pipeline = unit.pipeline;
            PreparePipelineIdentity identity = {
                .kind = pipeline.kind, .pass = pipeline.pass, .slot = pipeline.slot,
                .compute = pipeline.compute, .key = pipeline.key,
                .geometry = pipeline.kind == PreparePipelineKind.VALIDATE ? unit.geometry : (GeometryId){},
                .material = pipeline.kind == PreparePipelineKind.VALIDATE ? unit.material : (MaterialId){},
            };
            if (seen.has_key(identity)) continue;
            seen.set(identity, true);
        }
        unique.push(unit);
    }
    *listed = unique;
}

fn bool? run_prepare_sbt_step(Renderer* renderer, PrepareUnit* unit, PrepareReport* report) @private {
    if (renderer.path_tracer.sbt.is_valid()) {
        free_prepare_pipeline_unit(renderer, unit);
        return true;
    }
    PreparePipelineUnit* job = &unit.pipeline;
    gpu::RayTracingPipelineCaps* caps = &renderer.caps.ray_tracing_pipelines;
    SbtLayout layout = sbt_layout(
        handle_size: caps.shader_group_handle_size,
        handle_alignment: caps.shader_group_handle_alignment,
        base_alignment: caps.shader_group_base_alignment,
    );
    gpu::RayTracingPipelineInfo info = gpu::get_ray_tracing_pipeline_info(&renderer.device, renderer.path_tracer.pipeline)!;
    usz handle_size = caps.shader_group_handle_size;
    if (!job.handles.len) {
        char[] handles = alloc::alloc_array(renderer.allocator, char, (sz)(info.total_group_count * handle_size));
        defer catch alloc::free(renderer.allocator, handles.ptr);
        gpu::get_ray_tracing_shader_group_handles(
            device: &renderer.device,
            pipeline: renderer.path_tracer.pipeline,
            first_group: 0,
            group_count: info.total_group_count,
            out: handles,
        )!;
        job.handles = handles;
        report.copied_bytes += handles.len;
        return false;
    }
    if (!job.candidate.is_valid()) {
        gpu::AllocationDesc desc = {
            .size = layout.total_bytes,
            .alignment = caps.shader_group_base_alignment,
            .memory_class = gpu::MemoryClass.CPU_WRITE,
            .access = { .graphics },
            .debug_name = "path_tracer_sbt",
        };
        report.allocations++;
        job.candidate = gpu::allocate_memory(&renderer.device, &desc)!;
        return false;
    }
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, job.candidate)!;
    gpu::MappedGpuSpan mapped = gpu::mapped_gpu_span(&renderer.device, span)!;
    usz[3] groups = { info.ray_generation.first_group, info.miss.first_group, info.hit.first_group };
    usz[3] offsets = { 0, layout.miss_offset, layout.hit_offset };
    usz remaining = job.step_bytes;
    while (remaining) {
        usz group = unit.staged.bytes / handle_size;
        usz offset = unit.staged.bytes % handle_size;
        usz bytes = math::min(remaining, handle_size - offset);
        mem::copy(
            dst: mapped.bytes.ptr + offsets[group] + offset,
            src: job.handles.ptr + groups[group] * handle_size + offset,
            len: (sz)bytes,
        );
        unit.staged.bytes += bytes;
        report.staged_bytes += bytes;
        remaining -= bytes;
    }
    gpu::flush_mapped_span(&renderer.device, span)!;
    if (unit.staged.bytes < unit.bytes) return false;
    usz stride = layout.record_stride;
    gpu::RayTracingShaderBindingTable regions = {
        .ray_generation = { .span = span.checked_subspan(0, stride)!, .stride = stride },
        .miss = { .span = span.checked_subspan(layout.miss_offset, stride)!, .stride = stride },
        .hit = { .span = span.checked_subspan(layout.hit_offset, stride)!, .stride = stride },
    };
    install_prepare_sbt(
        renderer: renderer,
        unit: unit,
        allocation: job.candidate,
        regions: regions,
    );
    job.candidate = {};
    alloc::free(renderer.allocator, job.handles.ptr);
    job.handles = {};
    return true;
}

fn bool? run_prepare_sheen_step(Renderer* renderer, PrepareUnit* unit, PrepareReport* report) @private {
    EnvironmentLut* published = &renderer.environment_state.sheen_lut;
    PreparePipelineUnit* job = &unit.pipeline;
    if (published.state == EnvironmentLutState.RECORDED || published.state == EnvironmentLutState.READY) {
        free_prepare_pipeline_unit(renderer, unit);
        return true;
    }
    bool private_lut = published.state == EnvironmentLutState.NONE;
    if (private_lut) {
        if (!job.lut_candidate.texture.is_valid()) {
            gpu::TextureDesc description = {
                .width = shader::SHEEN_LUT_SIZE,
                .height = shader::SHEEN_LUT_SIZE,
                .mip_levels = 1,
                .array_layers = 1,
                .format = gpu::Format.RGBA16_FLOAT,
                .usage = { .sampled, .storage },
                .access = { .graphics },
                .debug_name = "sheen_albedo",
            };
            report.objects++;
            job.lut_candidate.texture = gpu::create_texture(&renderer.device, &description)!;
            return false;
        }
        if (!job.lut_candidate.view.is_valid()) {
            report.views++;
            job.lut_candidate.view = gpu::create_texture_view(&renderer.device, job.lut_candidate.texture, null)!;
            return false;
        }
        if (!job.lut_sampler_ready) {
            gpu::SamplerDesc sampler = {
                .min_filter = gpu::Filter.LINEAR,
                .mag_filter = gpu::Filter.LINEAR,
                .mip_filter = gpu::Filter.NEAREST,
                .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
                .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
                .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
                .min_lod = 0,
                .max_lod = 0,
                .debug_name = "sheen_albedo",
            };
            job.lut_sampler = gpu::intern_sampler(&renderer.device, &sampler)!;
            job.lut_sampler_ready = true;
            return false;
        }
    } else if (job.lut_candidate.texture.is_valid()) {
        free_prepare_pipeline_unit(renderer, unit);
    }
    EnvironmentLut* lut = private_lut ? &job.lut_candidate : published;
    gpu::TextureBarrier write = gpu::texture_transition(
        texture: lut.texture,
        before: {},
        after: gpu::storage_at({ .compute }, { .write }),
    )!;
    gpu::cmd_texture_barrier(&renderer.commands, &write)!;
    gpu::MappedGpuSpan root = take_prepare_staging(
        renderer: renderer,
        bytes: BrdfLutRoot::size,
        alignment: STREAM_ALIGNMENT,
        report: report,
    )!;
    *(BrdfLutRoot*)root.bytes.ptr = { .output_texture = lut.view.index, .size = shader::SHEEN_LUT_SIZE };
    report.staged_bytes += BrdfLutRoot::size;
    unit.staged.bytes = unit.bytes;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.environment_state.pipelines.sheen_lut)!;
    gpu::cmd_dispatch(&renderer.commands, root.address, {
        shader::SHEEN_LUT_SIZE / ENVIRONMENT_IMAGE_GROUP_SIZE,
        shader::SHEEN_LUT_SIZE / ENVIRONMENT_IMAGE_GROUP_SIZE,
        1,
    })!;
    gpu::TextureBarrier ready = gpu::texture_transition(
        texture: lut.texture,
        before: write.after,
        after: gpu::sampled_at({ .fragment_shader }),
    )!;
    gpu::cmd_texture_barrier(&renderer.commands, &ready)!;
    lut.state = EnvironmentLutState.RECORDED;
    if (private_lut) {
        *published = *lut;
        renderer.environment_state.sheen_sampler = job.lut_sampler;
        job.lut_candidate = {};
    }
    return true;
}
