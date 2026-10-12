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
import std::time::clock;

enum PreparePipelineKind @private {
    CACHE,
    COMPUTE,
    PATH_TRACER,
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
    TRACE_POSE,
    TRACE_POSE_U16,
    TRACE_REFIT,
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
}

struct PreparePipelineUnit @private {
    PreparePipelineKind kind;
    PreparePipelinePass pass;
    PrepareComputeSlot slot;
    ShaderVariant compute;
    PipelineKey key;
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
}

fn PrepareStepCost prepare_shader_cost(Renderer* renderer, PrepareUnit* unit) @private {
    if (prepare_shader_current(renderer, unit)) return {};
    ShaderRes* mirror = &renderer.shaders[unit.shader.index];
    uint old_revision = c3d::same_id(mirror.asset, unit.shader) ? mirror.revision : 0;
    asset::ShaderDesc* stages = &renderer.assets.shader(unit.shader).desc;
    uint required;
    @pool() {
        foreach (key : renderer.pipelines.keys_of(tmem, unit.shader, old_revision)) {
            if (key_stages_present(key, stages)) required++;
        }
    };
    return { .pipelines = required };
}

fn bool? run_prepare_shader_step(Renderer* renderer, PrepareUnit* unit, PrepareReport* report) @private {
    if (prepare_shader_current(renderer, unit)) return true;
    PipelineCreationCounters before = renderer.pipelines.creations;
    defer account_prepare_cache_creation(renderer, report, before);
    ShaderRes* published = resolve_shader(renderer, unit.shader)!;
    if (published.revision == unit.revision) report.copied_bytes += shader_desc_bytes(&published.desc);
    return true;
}

fn gpu::PipelineHandle* prepare_compute_slot(Renderer* renderer, PrepareComputeSlot slot) @private {
    switch (slot) {
        case CLUSTER: return &renderer.cluster_pipeline;
        case TRACE_POSE: return &renderer.posed_trace.pose_pipeline;
        case TRACE_POSE_U16: return &renderer.posed_trace.pose_u16_pipeline;
        case TRACE_REFIT: return &renderer.posed_trace.refit_pipeline;
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

fn PrepareStepCost? prepare_pipeline_cost(Renderer* renderer, PrepareUnit* unit) @private {
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
        case PATH_TRACER:
            return { .pipelines = renderer.path_tracer.pipeline.is_valid() ? 0 : 1 };
        case SHEEN_LUT:
            if (prepare_sheen_recorded(renderer)) return {};
            return {
                .staged_bytes = BrdfLutRoot::size,
                .pipelines = renderer.environment_state.pipelines.sheen_lut.is_valid() ? 0 : 1,
            };
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
        case PATH_TRACER:
            report.pipeline_lookups++;
            if (renderer.path_tracer.pipeline.is_valid()) report.pipeline_hits++;
            acquire_path_tracer(renderer, report)!;
            return true;
        case SHEEN_LUT:
            run_prepare_sheen_step(renderer, unit, report)!;
            return true;
    }
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
        ViewDesc* desc = &view.desc;
        bool traces = desc.shading == ShadingPath.PATH_TRACED || desc.ray_tracing.shadows
          || desc.ray_tracing.reflections || desc.ambient_occlusion.kind == AoKind.RAY_TRACED;
        if ((flags.skinned || flags.has_morphs) && traces) {
            append_prepare_compute(listed, PrepareComputeSlot.TRACE_POSE, TRACE_POSE);
            append_prepare_compute(
                listed: listed,
                slot: PrepareComputeSlot.TRACE_POSE_U16,
                shader_name: TRACE_POSE,
                flags: shader::SHADER_FLAG_SKINNED_U16,
            );
            append_prepare_compute(listed, PrepareComputeSlot.TRACE_REFIT, TRACE_REFIT);
        }
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
        if (desc.lights == LightSelection.CLUSTERED) {
            append_prepare_compute(listed, PrepareComputeSlot.CLUSTER, LIGHT_CULL);
        }
        if (desc.shading == ShadingPath.DEFERRED) {
            append_prepare_cache(
                listed: listed,
                key: lighting_resolve_pipeline_key(rt_shadow_flags(renderer, desc.ray_tracing.shadows)),
            );
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
        if (desc.ambient_occlusion.kind != AoKind.NONE) {
            append_prepare_compute(listed, PrepareComputeSlot.AO_BLUR, AO_BLUR);
        }
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
            listed.push({ .kind = PrepareUnitKind.PIPELINES, .pipeline = { .kind = PreparePipelineKind.PATH_TRACER } });
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
        if (post::uses_velocity(desc)) {
            append_prepare_cache(listed, post::camera_velocity_pipeline_key(post::velocity_format(desc)));
        }
        if (desc.post.anti_aliasing == AntiAliasing.TAA) {
            append_prepare_compute(listed, PrepareComputeSlot.TAA, TAA_RESOLVE);
        }
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

fn bool prepare_sheen_recorded(Renderer* renderer) @local {
    EnvironmentLutState state = renderer.environment_state.sheen_lut.state;
    return state == EnvironmentLutState.RECORDED || state == EnvironmentLutState.READY;
}

fn void? run_prepare_sheen_step(Renderer* renderer, PrepareUnit* unit, PrepareReport* report) @local {
    if (prepare_sheen_recorded(renderer)) return;
    gpu::PipelineHandle* pipeline = &renderer.environment_state.pipelines.sheen_lut;
    if (!pipeline.is_valid()) {
        std::time::Clock started = clock::now();
        report.pipelines++;
        defer report.pipeline_ns += (ulong)started.to_now();
        acquire_environment_pipeline(renderer, pipeline, SHEEN_LUT)!;
    }

    bool fresh = renderer.environment_state.sheen_lut.state == EnvironmentLutState.NONE;
    acquire_sheen_lut(renderer)!;
    if (fresh) {
        report.objects++;
        report.views++;
    }

    record_sheen_lut(renderer, &renderer.commands)!;
    report.staged_bytes += BrdfLutRoot::size;
    unit.staged.bytes = unit.bytes;
    unit.referenced_this_frame = true;
    renderer.prepares.get(unit.owner).pending_gpu = true;
    renderer.work_recorded = true;
}
