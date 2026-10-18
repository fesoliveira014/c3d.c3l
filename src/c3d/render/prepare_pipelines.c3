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
    TRACE_POSE,
}

struct PreparePipelineUnit @private {
    PreparePipelineKind kind;
    PreparePipelinePass pass;
    ComputeSlot slot;
    PipelineKey key;
}

struct PreparePipelineIdentity @private {
    PreparePipelineKind kind;
    PreparePipelinePass pass;
    ComputeSlot slot;
    PipelineKey key;
    GeometryId geometry;
    MaterialId material;
}

fn uint PreparePipelineIdentity.hash(&self) {
    return fnv32a::hash(((char*)self)[:PreparePipelineIdentity::size]);
}

fn bool PreparePipelineIdentity.equals(&self, PreparePipelineIdentity other) {
    return self.kind == other.kind && self.pass == other.pass && self.slot == other.slot
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

// The custom stages come from the published mirror, which the material resolution or shader unit made current.
fn PipelineKey? prepare_cache_key(Renderer* renderer, PreparePipelineUnit* request) @private {
    PipelineKey key = request.key;
    if (!key.shader.generation) return key;
    ShaderRes* mirror = &renderer.shaders[key.shader.index];
    asset::ShaderDesc* desc = &mirror.desc;
    key.shader_revision = mirror.revision;
    uint instanced = key.vertex.flags & shader::SHADER_FLAG_INSTANCED;

    switch (request.pass) {
        case FORWARD:
            key.custom = { .vertex = desc.vertex.shaded.len > 0, .fragment = true };
            key.fragment = custom_fragment_variant(desc, key.fragment.flags);
            if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = instanced };
        case GBUFFER:
            key.custom = { .vertex = desc.vertex.shaded.len > 0, .gbuffer = true };
            if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = instanced };
        case DEPTH:
            key.custom = { .vertex = desc.vertex.depth.len > 0 };
            if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_DEPTH_ONLY | instanced };
        case VELOCITY:
            key.custom = { .vertex = (instanced ? desc.vertex.instanced_velocity : desc.vertex.velocity).len > 0 };
            if (key.custom.vertex) key.vertex = { .shader = MESH, .flags = shader::SHADER_FLAG_VELOCITY | instanced };
        case TRACE_POSE:
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
            PipelineKey? key = prepare_cache_key(renderer, &unit.pipeline);
            if (catch excuse = key) return {};
            bool cached = renderer.pipelines.pipelines.has_key(key) || renderer.pipelines.rejected.has_key(key);
            return { .pipelines = cached ? 0 : 1 };
        case COMPUTE:
            return { .pipelines = compute_slot_target(renderer, unit.pipeline.slot).pipeline.is_valid() ? 0 : 1 };
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
        case SHEEN_LUT: run_prepare_sheen_step(renderer, unit, report)!;
        case CACHE:
        case COMPUTE:
        case PATH_TRACER: acquire_prepare_pipeline(renderer, &unit.pipeline, report)!;
    }
    return true;
}

<*
 @require request.kind != PreparePipelineKind.SHEEN_LUT && request.kind != PreparePipelineKind.VALIDATE
*>
fn void? acquire_prepare_pipeline(Renderer* renderer, PreparePipelineUnit* request, PrepareReport* report) @private {
    switch (request.kind) {
        case CACHE:
            renderer.stats.pipeline_lookups++;
            PipelineKey? selected = prepare_cache_key(renderer, request);
            if (catch excuse = selected) {
                if (excuse == PIPELINE_REJECTED) return;
                return excuse~;
            }
            PipelineKey key = selected;
            PipelineCreationCounters before = renderer.pipelines.creations;
            defer account_prepare_cache_creation(renderer, report, before);
            CustomStageSource source;
            if ((uint)key.custom) source = custom_stage_source(&renderer.shaders[key.shader.index].desc, key);
            if (catch excuse = renderer.pipelines.get(&renderer.device, key, &source)) {
                if (key.shader.generation && pipeline_rejected(renderer, key.shader, excuse)) return;
                return excuse~;
            }

        case COMPUTE:
            if (compute_slot_target(renderer, request.slot).pipeline.is_valid()) return;
            std::time::Clock started = clock::now();
            report.pipelines++;
            defer report.pipeline_ns += (ulong)started.to_now();
            acquire_compute_slot(renderer, request.slot)!;

        case PATH_TRACER:
            acquire_path_tracer(renderer, report)!;

        case SHEEN_LUT:
        case VALIDATE:
            unreachable("not a listed pipeline request");
    }
}

fn void? acquire_prepare_pipelines(Renderer* renderer, PreparePipelineUnit[] requests) @private {
    PrepareReport report;
    foreach (&request : requests) acquire_prepare_pipeline(renderer, request, &report)!;
}

fn void list_prepare_compute(List{PreparePipelineUnit}* requests, ComputeSlot slot) @local {
    requests.push({ .kind = PreparePipelineKind.COMPUTE, .slot = slot });
}

fn void list_prepare_key(
    List{PreparePipelineUnit}* requests,
    PipelineKey key,
    PreparePipelinePass pass = PreparePipelinePass.REGISTRY,
    ShaderId shader = {},
) @local {
    key.shader = shader;
    requests.push({ .kind = PreparePipelineKind.CACHE, .pass = pass, .key = key });
}

fn void append_prepare_material_pipelines(Renderer* renderer, MaterialId material, List{PrepareUnit}* listed) @private {
    if (!renderer.assets.materials.is_live(material)) return;
    if (!material_uses_sheen(&renderer.assets.material(material).data)) return;
    listed.push({ .kind = PrepareUnitKind.PIPELINES, .bytes = BrdfLutRoot::size,
        .pipeline = { .kind = PreparePipelineKind.SHEEN_LUT } });
}

fn bool prepare_custom_gbuffer(Renderer* renderer, Material* material) @local {
    if (material.kind != MaterialKind.CUSTOM || !renderer.assets.shaders.is_live(material.custom.shader)) return false;
    ShaderId shader = material.custom.shader;
    ShaderRes* mirror = &renderer.shaders[shader.index];
    if (c3d::same_id(mirror.asset, shader) && mirror.desc.gbuffer.len) return true;
    return renderer.assets.shader(shader).desc.gbuffer.len > 0;
}

fn SceneReads prepare_custom_reads(Renderer* renderer, Material* material) @local {
    if (material.kind != MaterialKind.CUSTOM || !renderer.assets.shaders.is_live(material.custom.shader)) return {};
    ShaderId shader = material.custom.shader;
    SceneReads reads = renderer.assets.shader(shader).desc.scene_reads;
    ShaderRes* mirror = &renderer.shaders[shader.index];
    if (c3d::same_id(mirror.asset, shader)) reads |= mirror.desc.scene_reads;
    return reads;
}

fn void list_mesh_pipelines(
    Renderer* renderer,
    List{PreparePipelineUnit}* requests,
    GeometryFlags flags,
    Material* material,
    bool morphed,
    bool depth,
    bool instanced = false,
    bool crowd = false,
    bool skinned = true,
    bool crowd_part = false,
    bool posed = false,
    bool soft_shadows = false,
    bool trace_sway = false,
) @private {
    bool deforms = instanced ? crowd_part && (morphed || crowd) : morphed || skinned;
    if (renderer.compute_skinning && deforms && (flags.skinned || flags.has_morphs)) {
        // Compute skinning draws the plain forms; the deformed ones remain for meshes it leaves out.
        list_prepare_compute(requests, instanced ? ComputeSlot.TRACE_POSE_INSTANCED : ComputeSlot.TRACE_POSE);
        list_prepare_compute(requests, instanced ? ComputeSlot.TRACE_POSE_INSTANCED_U16 : ComputeSlot.TRACE_POSE_U16);
        list_mesh_pipelines(
            renderer: renderer,
            requests: requests,
            flags: flags,
            material: material,
            morphed: false,
            depth: depth,
            instanced: instanced,
            skinned: false,
            posed: instanced,
            soft_shadows: soft_shadows,
        );
    }
    bool wireframe = material.common.wireframe && renderer.caps.line_polygon_mode;
    gpu::PolygonMode polygon = wireframe ? gpu::PolygonMode.LINE : gpu::PolygonMode.FILL;
    uint instanced_flags = instanced ? shader::SHADER_FLAG_INSTANCED : 0;
    if (posed) instanced_flags |= shader::SHADER_FLAG_POSED_INSTANCED;
    bool deformed = skinned && (!instanced || crowd);
    ShaderVariant vertex = mesh_vertex_variant(
        flags: flags,
        morphed: morphed,
        skinned: deformed,
        base_flags: instanced_flags,
    );
    ShaderId custom = material.kind == MaterialKind.CUSTOM ? material.custom.shader : (ShaderId){};
    bool custom_gbuffer = prepare_custom_gbuffer(renderer, material);
    SceneReads custom_reads = prepare_custom_reads(renderer, material);

    PipelineKey forward = forward_pipeline_key(
        material: material,
        vertex: vertex,
        polygon: polygon,
        shadow_flags: 0,
    );
    list_prepare_key(
        requests: requests,
        key: forward,
        pass: PreparePipelinePass.FORWARD,
        shader: custom,
    );

    if (renderer.has_deferred_view() && gbuffer_encodable(material, custom_gbuffer)) {
        PipelineKey gbuffer = gbuffer_pipeline_key(vertex, gbuffer_fragment(material), polygon);
        list_prepare_key(
            requests: requests,
            key: gbuffer,
            pass: PreparePipelinePass.GBUFFER,
            shader: custom,
        );
    }

    ShaderVariant depth_vertex = mesh_vertex_variant(
        flags: flags,
        morphed: morphed,
        skinned: deformed,
        base_flags: shader::SHADER_FLAG_DEPTH_ONLY | instanced_flags,
    );
    bool vertex_color = material.common.alpha_mode == AlphaMode.MASK && (flags.has_colors || instanced);
    if (depth && material.common.alpha_mode != AlphaMode.BLEND) {
        PipelineKey caster = shadow_pipeline_key(
            vertex: depth_vertex,
            wireframe: wireframe,
            vertex_color: vertex_color,
        );
        list_prepare_key(
            requests: requests,
            key: caster,
            pass: PreparePipelinePass.DEPTH,
            shader: custom,
        );
    }

    foreach (&view : renderer.views.items) {
        if (!view.live) continue;
        ViewDesc* desc = &view.desc;
        bool traces = desc.shading == ShadingPath.PATH_TRACED || desc.ray_tracing.shadows
          || desc.ray_tracing.reflections || desc.ambient_occlusion.kind == AoKind.RAY_TRACED;

        if ((flags.skinned || flags.has_morphs) && traces) {
            list_prepare_compute(requests, ComputeSlot.TRACE_POSE);
            list_prepare_compute(requests, ComputeSlot.TRACE_POSE_U16);
            list_prepare_compute(requests, ComputeSlot.TRACE_REFIT);
        }
        if (traces && trace_sway) list_prepare_compute(requests, ComputeSlot.TRACE_SWAY);
        if (traces && custom.generation) {
            list_prepare_key(
                requests: requests,
                key: trace_pose_pipeline_key(instanced),
                pass: PreparePipelinePass.TRACE_POSE,
                shader: custom,
            );
        }

        DrawList list = view_draw_list(
            material: material,
            shading: desc.shading,
            custom_gbuffer: custom_gbuffer,
            custom_reads: custom_reads,
        );
        gpu::SampleCount samples = draw_list_samples(desc, list);
        bool multisample = samples != gpu::SampleCount.ONE;
        uint shadow_flags = rt_shadow_flags(renderer, desc.ray_tracing.shadows, soft_shadows);
        if (list == DrawList.GBUFFER && multisample) {
            PipelineKey view_gbuffer = gbuffer_pipeline_key(
                vertex: vertex,
                fragment: gbuffer_fragment(material),
                polygon: polygon,
                samples: samples,
            );
            list_prepare_key(
                requests: requests,
                key: view_gbuffer,
                pass: PreparePipelinePass.GBUFFER,
                shader: custom,
            );
        } else if ((desc.ray_tracing.shadows && list != DrawList.GBUFFER) || multisample) {
            PipelineKey view_forward = forward_pipeline_key(
                material: material,
                vertex: vertex,
                polygon: polygon,
                shadow_flags: shadow_flags,
                samples: samples,
            );
            list_prepare_key(
                requests: requests,
                key: view_forward,
                pass: PreparePipelinePass.FORWARD,
                shader: custom,
            );
        }

        if (multisample && depth && material.common.alpha_mode != AlphaMode.BLEND && view_draws_prepass(desc)) {
            PipelineKey view_caster = shadow_pipeline_key(
                vertex: depth_vertex,
                wireframe: wireframe,
                vertex_color: vertex_color,
                samples: samples,
            );
            list_prepare_key(
                requests: requests,
                key: view_caster,
                pass: PreparePipelinePass.DEPTH,
                shader: custom,
            );
        }

        if (list == DrawList.TRANSPARENT && weighted_blend_eligible(material, desc.transparency)) {
            PipelineKey weighted = forward_pipeline_key(
                material: material,
                vertex: vertex,
                polygon: polygon,
                shadow_flags: shadow_flags,
                weighted: true,
            );
            list_prepare_key(
                requests: requests,
                key: weighted,
                pass: PreparePipelinePass.FORWARD,
                shader: custom,
            );
        }

        if (desc.ray_tracing.reflections && desc.shading == ShadingPath.FORWARD && list == DrawList.OPAQUE) {
            ReflectionPrepass reflection = gbuffer_encodable(material)
              ? ReflectionPrepass.WRITTEN : ReflectionPrepass.MASKED;
            PipelineKey thin = shadow_pipeline_key(
                vertex: reflection == ReflectionPrepass.WRITTEN ? vertex : depth_vertex,
                wireframe: wireframe,
                material: material,
                vertex_color: vertex_color,
                reflection: reflection,
                samples: samples,
            );
            list_prepare_key(
                requests: requests,
                key: thin,
                pass: PreparePipelinePass.DEPTH,
                shader: custom,
            );
        }

        if (list == DrawList.OPAQUE && material_outlined(material)) {
            list_prepare_key(requests, outline_pipeline_key(vertex, polygon, samples), PreparePipelinePass.FORWARD);
            if (post::uses_velocity(desc)) {
                PipelineKey outline_velocity = post::geometry_velocity_pipeline_key(
                    vertex: outline_vertex_variant(vertex),
                    polygon: polygon,
                    format: post::velocity_format(desc),
                    samples: samples,
                );
                list_prepare_key(
                    requests: requests,
                    key: outline_velocity,
                    pass: PreparePipelinePass.VELOCITY,
                );
            }
        }

        if (post::uses_velocity(desc) && writes_own_depth(material)) {
            PipelineKey velocity = post::geometry_velocity_pipeline_key(
                vertex: vertex,
                polygon: polygon,
                format: post::velocity_format(desc),
                samples: samples,
            );
            list_prepare_key(
                requests: requests,
                key: velocity,
                pass: PreparePipelinePass.VELOCITY,
                shader: custom,
            );
        }
    }
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
        ? renderer.geometries[geometry.index].layout.flags
        : geometry_layout_from_width(&source.data, source.joints_u16).flags;
    listed.push({ .kind = PrepareUnitKind.PIPELINES, .geometry = geometry, .material = material,
        .pipeline = { .kind = PreparePipelineKind.VALIDATE } });

    List{PreparePipelineUnit} requests;
    requests.init(tmem);
    list_mesh_pipelines(
        renderer: renderer,
        requests: &requests,
        flags: flags,
        material: &renderer.assets.material(material).data,
        morphed: morphed,
        depth: true,
    );
    append_prepare_requests(
        listed: listed,
        requests: requests.array_view(),
        geometry: geometry,
        material: material,
    );
}

fn void list_view_pipelines(
    Renderer* renderer,
    SceneReads reads,
    List{PreparePipelineUnit}* requests,
    bool soft_shadows = false,
) @private {
    if (reads.color) list_prepare_key(requests, composite_pipeline_key(HDR_FORMAT));
    if (reads.depth) list_prepare_key(requests, composite_pipeline_key(SCENE_DEPTH_FORMAT));

    foreach (&view : renderer.views.items) {
        if (!view.live) continue;
        ViewDesc* desc = &view.desc;
        if (desc.lights == LightSelection.CLUSTERED) {
            list_prepare_compute(requests, ComputeSlot.CLUSTER);
            if (desc.clusters.depth_pruning) {
                list_prepare_compute(requests, ComputeSlot.CLUSTER_PRUNED);
                list_prepare_compute(requests, ComputeSlot.CLUSTER_DEPTH);
            }
        }
        if (desc.shading == ShadingPath.DEFERRED) {
            uint shadow_flags = rt_shadow_flags(renderer, desc.ray_tracing.shadows, soft_shadows);
            list_prepare_key(requests, lighting_resolve_pipeline_key(shadow_flags, msaa_sample_count(desc.msaa)));
        }

        if (msaa_normal_copy_wanted(desc)) {
            gpu::Format normals = GBUFFER_FORMATS[GBufferChannel.NORMAL_ROUGHNESS.ordinal];
            list_prepare_key(requests, sample_zero_pipeline_key(normals));
        }

        if (msaa_specular_copy_wanted(desc)) {
            gpu::Format specular = GBUFFER_FORMATS[GBufferChannel.EMISSIVE_SPECULAR.ordinal];
            list_prepare_key(requests, sample_zero_pipeline_key(specular));
        }

        if (desc.transparency == TransparencyMode.WEIGHTED) {
            list_prepare_key(requests, weighted_composite_pipeline_key());
        }

        AmbientOcclusionDesc* ambient_occlusion = &desc.ambient_occlusion;
        bool bent_normals = ambient_occlusion.bent_normals;
        if (ambient_occlusion.kind != AoKind.NONE) {
            list_prepare_compute(requests, ambient_occlusion_estimate_slot(ambient_occlusion.kind, bent_normals));
            if (ambient_occlusion_accumulates(desc)) {
                list_prepare_compute(requests, ambient_occlusion_temporal_slot(bent_normals));
            }
            list_prepare_compute(requests, ambient_occlusion_blur_slot(bent_normals));
        }

        if (desc.ray_tracing.reflections) {
            list_prepare_compute(requests, ComputeSlot.REFLECTION);
            if (reflection_half_resolution(desc)) list_prepare_compute(requests, ComputeSlot.REFLECTION_UPSAMPLE);
            if (reflection_accumulates(desc)) list_prepare_compute(requests, ComputeSlot.REFLECTION_TEMPORAL);
            list_prepare_compute(requests, ComputeSlot.REFLECTION_BLUR);
        }

        if (desc.screen_space_gi.enabled) {
            switch (desc.screen_space_gi.trace) {
                case LINEAR: list_prepare_compute(requests, ComputeSlot.SSGI_TRACE);
                case HIERARCHICAL:
                    list_prepare_compute(requests, ComputeSlot.SSGI_TRACE);
                    list_prepare_compute(requests, ComputeSlot.SSGI_TRACE_HIERARCHICAL);
                    list_prepare_compute(requests, ComputeSlot.DEPTH_PYRAMID);
            }
            list_prepare_compute(requests, ComputeSlot.SSGI_TEMPORAL);
            list_prepare_compute(requests, ComputeSlot.SSGI_FILTER);
        }

        if (desc.shading == ShadingPath.PATH_TRACED) requests.push({ .kind = PreparePipelineKind.PATH_TRACER });

        if (desc.post.bloom) {
            list_prepare_compute(requests, ComputeSlot.BLOOM_DOWN);
            list_prepare_compute(requests, ComputeSlot.BLOOM_UP);
        }
        if (desc.post.depth_of_field) {
            list_prepare_compute(requests, ComputeSlot.DOF_COC);
            list_prepare_compute(requests, ComputeSlot.DOF_GATHER);
            list_prepare_compute(requests, ComputeSlot.DOF_COMPOSITE);
        }

        if (post::auto_focus_active(desc)) {
            list_prepare_compute(requests, ComputeSlot.FOCUS_HISTOGRAM);
            list_prepare_compute(requests, ComputeSlot.FOCUS_ADAPT);
        }

        if (desc.post.motion_blur || desc.post.depth_of_field) {
            list_prepare_compute(requests, ComputeSlot.TILE_MAX);
            list_prepare_compute(requests, ComputeSlot.TILE_NEIGHBOR);
        }
        if (desc.post.motion_blur) list_prepare_compute(requests, ComputeSlot.MOTION_BLUR);
        if (post::uses_velocity(desc)) {
            PipelineKey camera_velocity = post::camera_velocity_pipeline_key(
                format:  post::velocity_format(desc),
                samples: msaa_sample_count(desc.msaa),
            );
            list_prepare_key(requests, camera_velocity);
        }

        if (desc.msaa != MsaaSamples.ONE && post::uses_velocity(desc)) {
            list_prepare_key(requests, sample_zero_pipeline_key(post::velocity_format(desc)));
        }

        if (desc.msaa != MsaaSamples.ONE && msaa_reflection_gbuffer_wanted(desc)) {
            list_prepare_key(requests, sample_zero_pipeline_key(REFLECTION_SURFACE_FORMAT));
        }

        if (desc.post.anti_aliasing == AntiAliasing.TAA) {
            list_prepare_compute(requests, ComputeSlot.TAA);
        }
        if (post::auto_exposure_active(desc)) {
            list_prepare_compute(requests, ComputeSlot.EXPOSURE_HISTOGRAM);
            list_prepare_compute(requests, ComputeSlot.EXPOSURE_ADAPT);
        }

        if (!view.hdr_color.texture.is_valid()) continue;
        gpu::Format output_format = view_output_format(renderer, desc);
        if (desc.post.anti_aliasing == AntiAliasing.FXAA) {
            list_prepare_compute(requests, ComputeSlot.GRADE);
            list_prepare_compute(requests, ComputeSlot.FXAA);
            list_prepare_key(requests, post::fxaa_fragment_pipeline_key(output_format));
        } else {
            list_prepare_key(requests, post::display_pipeline_key(output_format));
        }
    }
}

fn void append_prepare_requests(
    List{PrepareUnit}* listed,
    PreparePipelineUnit[] requests,
    GeometryId geometry = {},
    MaterialId material = {},
) @local {
    foreach (request : requests) {
        bool keyed = request.kind == PreparePipelineKind.CACHE;
        listed.push({
            .kind = PrepareUnitKind.PIPELINES,
            .geometry = keyed ? geometry : (GeometryId){},
            .material = keyed ? material : (MaterialId){},
            .pipeline = request,
        });
    }
}

fn void append_prepare_finish(Renderer* renderer, List{PrepareUnit}* listed) @private {
    SceneReads reads;
    foreach (unit : *listed) {
        if (unit.kind != PrepareUnitKind.MATERIAL || !renderer.assets.materials.is_live(unit.material)) continue;
        Material* data = &renderer.assets.material(unit.material).data;
        reads |= material_scene_reads(data, prepare_custom_reads(renderer, data));
    }

    List{PreparePipelineUnit} requests;
    requests.init(tmem);
    list_view_pipelines(renderer, reads, &requests);
    append_prepare_requests(listed, requests.array_view());
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
                .kind = pipeline.kind, .pass = pipeline.pass, .slot = pipeline.slot, .key = pipeline.key,
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

    acquire_sheen_lut(renderer)!;
    record_sheen_lut(renderer, &renderer.commands)!;
    report.staged_bytes += BrdfLutRoot::size;
    unit.referenced_this_frame = true;
    renderer.prepares.get(unit.owner).pending_gpu = true;
    renderer.work_recorded = true;
}
