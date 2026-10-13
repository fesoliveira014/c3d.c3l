module c3d::render;

import c3d;
import c3d::asset;
import c3d::shader;
import gpu;
import std::collections::list;
import std::collections::map;
import std::hash::fnv32a;
import std::time::clock;

<*
 Color attachment slots a pipeline key describes.
*>
const usz KEY_COLOR_TARGETS = 5; // the five G-buffer channels; keeps the key at 60 bytes

<*
 Which stages of a key come from a store shader instead of the registry.
 gbuffer selects the shader's G-buffer fragment in place of fragment.
*>
bitstruct CustomStages : uint {
    bool vertex   : 0;
    bool fragment : 1;
    bool compute  : 2;
    bool gbuffer  : 3;
}

enum ComputeSlot @private {
    CLUSTER,
    TRACE_POSE,
    TRACE_POSE_U16,
    TRACE_POSE_INSTANCED,
    TRACE_POSE_INSTANCED_U16,
    TRACE_REFIT,
    SSAO,
    RT_AO,
    AO_TEMPORAL,
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
    FOCUS_HISTOGRAM,
    FOCUS_ADAPT,
}

<*
 Immutable pipeline inputs: stages, attachment formats, and the store shader when one is used.
*>
struct PipelineKey {
    ShaderVariant                  vertex;
    ShaderVariant                  fragment;
    gpu::Format[KEY_COLOR_TARGETS] color_formats;
    uint                           color_count;
    gpu::Format                    depth_format;
    gpu::SampleCount               samples;
    gpu::PolygonMode               polygon;
    ShaderId                       shader;
    uint                           shader_revision;
    CustomStages                   custom;
}
$assert PipelineKey::size == 60;

<*
 SPIR-V of the custom stages a key selects; borrowed for the create call.
*>
struct CustomStageSource {
    char[] vertex;
    char[] fragment;
    char[] compute;
}

struct PipelineCreationCounters @private {
    ulong calls;
    ulong elapsed_ns;
}

<*
 Pipelines resolved for this renderer, one per distinct key.
*>
struct PipelineCache {
    HashMap{PipelineKey, gpu::PipelineHandle} pipelines;
    HashMap{PipelineKey, bool}                rejected;
    ShaderRegistry                            registry;
    PipelineCreationCounters                  creations;
}

struct ComputeSlotTarget @private {
    gpu::PipelineHandle* pipeline;
    ShaderName shader;
    uint flags;
    ZString debug_name;
}

<*
 Hash over every field.
*>
fn uint PipelineKey.hash(&self) {
    return fnv32a::hash(((char*)self)[:PipelineKey::size]);
}

<*
 Field-wise equality.
*>
fn bool PipelineKey.equals(&self, PipelineKey other) {
    return (uint)self.vertex == (uint)other.vertex
        && (uint)self.fragment == (uint)other.fragment
        && self.color_formats == other.color_formats
        && self.color_count == other.color_count
        && self.depth_format == other.depth_format
        && self.samples == other.samples
        && self.polygon == other.polygon
        && c3d::same_id(self.shader, other.shader)
        && self.shader_revision == other.shader_revision
        && (uint)self.custom == (uint)other.custom;
}

<*
 Create a registry compute pipeline into the caller's slot once; a valid slot is kept.
 @param [&inout] pipeline : "Caller-owned slot; written only after successful creation."
 @param flags : "SHADER_FLAG_* bits of the variant; zero selects the plain entry."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? acquire_compute_pipeline(
    Renderer* renderer,
    gpu::PipelineHandle* pipeline,
    ShaderName shader,
    ZString debug_name,
    uint flags = 0,
) @private {
    if (pipeline.is_valid()) return;

    gpu::ComputePipelineDesc description = {
        .shader     = { .spirv = renderer.pipelines.registry.get({ .shader = shader, .flags = flags })! },
        .debug_name = debug_name,
    };
    *pipeline = gpu::create_compute_pipeline(&renderer.device, &description)!;
}

fn ComputeSlotTarget compute_slot_target(Renderer* renderer, ComputeSlot slot) @private {
    switch (slot) {
        case CLUSTER: return { .pipeline = &renderer.cluster_pipeline,
            .shader = LIGHT_CULL, .debug_name = "environment_processing" };
        case TRACE_POSE: return { .pipeline = &renderer.posed_trace.pose_pipeline,
            .shader = TRACE_POSE, .debug_name = "trace_pose" };
        case TRACE_POSE_U16: return { .pipeline = &renderer.posed_trace.pose_u16_pipeline,
            .shader = TRACE_POSE, .flags = shader::SHADER_FLAG_SKINNED_U16, .debug_name = "trace_pose_u16" };
        case TRACE_POSE_INSTANCED: return { .pipeline = &renderer.compute_skin.crowd_pipeline,
            .shader = TRACE_POSE, .flags = shader::SHADER_FLAG_INSTANCED, .debug_name = "trace_pose_instanced" };
        case TRACE_POSE_INSTANCED_U16: return { .pipeline = &renderer.compute_skin.crowd_u16_pipeline,
            .shader = TRACE_POSE,
            .flags = shader::SHADER_FLAG_INSTANCED | shader::SHADER_FLAG_SKINNED_U16,
            .debug_name = "trace_pose_instanced_u16" };
        case TRACE_REFIT: return { .pipeline = &renderer.posed_trace.refit_pipeline,
            .shader = TRACE_REFIT, .debug_name = "trace_refit" };
        case SSAO: return { .pipeline = &renderer.ambient_occlusion_pipelines.ssao,
            .shader = SSAO, .debug_name = "ssao" };
        case RT_AO: return { .pipeline = &renderer.ambient_occlusion_pipelines.ray_traced,
            .shader = RT_AO, .flags = trace_shader_flags(renderer), .debug_name = "rt_ao" };
        case AO_TEMPORAL: return { .pipeline = &renderer.ambient_occlusion_pipelines.temporal,
            .shader = AO_TEMPORAL, .debug_name = "ao_temporal" };
        case AO_BLUR: return { .pipeline = &renderer.ambient_occlusion_pipelines.blur,
            .shader = AO_BLUR, .debug_name = "ao_blur" };
        case REFLECTION: return { .pipeline = &renderer.reflection_pipelines.trace,
            .shader = RT_REFLECTIONS, .flags = trace_shader_flags(renderer), .debug_name = "rt_reflections" };
        case REFLECTION_BLUR: return { .pipeline = &renderer.reflection_pipelines.blur,
            .shader = RT_REFLECTION_BLUR, .debug_name = "rt_reflection_blur" };
        case SSGI_TRACE: return { .pipeline = &renderer.screen_space_gi_pipelines.trace,
            .shader = SSGI_TRACE, .debug_name = "ssgi_trace" };
        case SSGI_TEMPORAL: return { .pipeline = &renderer.screen_space_gi_pipelines.temporal,
            .shader = SSGI_TEMPORAL, .debug_name = "ssgi_temporal" };
        case SSGI_FILTER: return { .pipeline = &renderer.screen_space_gi_pipelines.filter,
            .shader = SSGI_FILTER, .debug_name = "ssgi_filter" };
        case GRADE: return { .pipeline = &renderer.post_pipelines.grade, .shader = GRADE, .debug_name = "post_grade" };
        case FXAA: return { .pipeline = &renderer.post_pipelines.fxaa, .shader = FXAA, .debug_name = "post_fxaa" };
        case BLOOM_DOWN: return { .pipeline = &renderer.post_pipelines.bloom_downsample,
            .shader = BLOOM_DOWNSAMPLE, .debug_name = "post_bloom_downsample" };
        case BLOOM_UP: return { .pipeline = &renderer.post_pipelines.bloom_upsample,
            .shader = BLOOM_UPSAMPLE, .debug_name = "post_bloom_upsample" };
        case TILE_MAX: return { .pipeline = &renderer.post_pipelines.tile_max,
            .shader = TILE_MAX, .debug_name = "post_tile_max" };
        case TILE_NEIGHBOR: return { .pipeline = &renderer.post_pipelines.tile_neighbor,
            .shader = TILE_NEIGHBOR, .debug_name = "post_tile_neighbor" };
        case DOF_COC: return { .pipeline = &renderer.post_pipelines.dof_coc,
            .shader = DOF_COC, .debug_name = "post_dof_coc" };
        case DOF_GATHER: return { .pipeline = &renderer.post_pipelines.dof_gather,
            .shader = DOF_GATHER, .debug_name = "post_dof_gather" };
        case DOF_COMPOSITE: return { .pipeline = &renderer.post_pipelines.dof_composite,
            .shader = DOF_COMPOSITE, .debug_name = "post_dof_composite" };
        case MOTION_BLUR: return { .pipeline = &renderer.post_pipelines.motion_blur,
            .shader = MOTION_BLUR, .debug_name = "post_motion_blur" };
        case TAA: return { .pipeline = &renderer.post_pipelines.taa_resolve,
            .shader = TAA_RESOLVE, .debug_name = "post_taa_resolve" };
        case EXPOSURE_HISTOGRAM: return { .pipeline = &renderer.post_pipelines.exposure_histogram,
            .shader = EXPOSURE_HISTOGRAM, .debug_name = "post_exposure_histogram" };
        case EXPOSURE_ADAPT: return { .pipeline = &renderer.post_pipelines.exposure_adapt,
            .shader = EXPOSURE_ADAPT, .debug_name = "post_exposure_adapt" };
        case FOCUS_HISTOGRAM: return { .pipeline = &renderer.post_pipelines.focus_histogram,
            .shader = FOCUS_HISTOGRAM, .debug_name = "post_focus_histogram" };
        case FOCUS_ADAPT: return { .pipeline = &renderer.post_pipelines.focus_adapt,
            .shader = FOCUS_ADAPT, .debug_name = "post_focus_adapt" };
    }
}

fn void? acquire_compute_slot(Renderer* renderer, ComputeSlot slot) @private {
    ComputeSlotTarget target = compute_slot_target(renderer, slot);
    return acquire_compute_pipeline(
        renderer: renderer,
        pipeline: target.pipeline,
        shader: target.shader,
        debug_name: target.debug_name,
        flags: target.flags,
    );
}

<*
 Pipeline for the key, created on first use from the registry or the custom stages.
 A key the backend rejected is not retried until its shader is replaced or removed.
 @param [&inout] device : "Owns the created pipeline."
 @param [in] custom : "Stages for key.custom; ignored when every bit is clear."
 @return? c3d::SHADER_NOT_FOUND, PIPELINE_REJECTED, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST
 @require !key.custom.vertex || custom.vertex.len > 0
 @require !key.custom.fragment || custom.fragment.len > 0
 @require !key.custom.gbuffer || custom.fragment.len > 0
 @require !key.custom.compute || custom.compute.len > 0
*>
fn gpu::PipelineHandle? PipelineCache.get(
    &self,
    gpu::Device* device,
    PipelineKey key,
    CustomStageSource* custom = null,
) {
    if (try existing = self.pipelines.get(key)) return existing;
    if (self.rejected.has_key(key)) return PIPELINE_REJECTED~;

    gpu::PipelineHandle? pipeline = create_pipeline(
        registry: &self.registry,
        device: device,
        key: key,
        custom: custom,
        counters: &self.creations,
    );
    if (catch excuse = pipeline) {
        if (excuse == gpu::SHADER_INVALID || excuse == gpu::PIPELINE_CREATE_FAILED) self.rejected.set(key, true);
        return excuse~;
    }
    self.pipelines.set(key, pipeline);
    return pipeline;
}

<*
 Keys of every pipeline built from the shader at the revision.
 @param allocator : "Owns the returned array."
*>
fn PipelineKey[] PipelineCache.keys_of(&self, Allocator allocator, ShaderId shader, uint revision) {
    return keys_matching(self, allocator, shader, false, revision, false);
}

<*
 Keys of every pipeline built from the compute shader at the revision.
 @param allocator : "Owns the returned array."
*>
fn PipelineKey[] PipelineCache.compute_keys_of(&self, Allocator allocator, ComputeShaderId shader, uint revision) {
    return keys_matching(self, allocator, compute_pipeline_key(shader, 0).shader, true, revision, false);
}

<*
 Rebuild every pipeline of the shader under the new revision; publish all or none.
 @param allocator : "Owns the returned handles."
 @param [&inout] device : "Owns the created pipelines."
 @param [&in] stages : "New revision's SPIR-V; each key takes the vertex form its flags name."
 @return "Superseded and dropped handles, to retire after their submitted use."
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::INVALID_ARGUMENT
 @return? gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST
*>
fn gpu::PipelineHandle[]? PipelineCache.replace_shader(
    &self,
    Allocator allocator,
    gpu::Device* device,
    ShaderId shader,
    uint old_revision,
    uint new_revision,
    asset::ShaderDesc* stages,
) {
    PipelineKey[] keys = self.keys_of(tmem, shader, old_revision);
    gpu::PipelineHandle[] fresh = alloc::new_array(tmem, gpu::PipelineHandle, keys.len);
    defer catch foreach (handle : fresh) {
        if (handle.is_valid()) (void)gpu::destroy_pipeline(device, handle);
    }

    foreach (index, key : keys) {
        if (!key_stages_present(key, stages)) continue;
        PipelineKey replacement = key;
        replacement.shader_revision = new_revision;
        CustomStageSource source = custom_stage_source(stages, replacement);
        fresh[index] = create_pipeline(
            registry: &self.registry,
            device: device,
            key: replacement,
            custom: &source,
            counters: &self.creations,
        )!;
    }

    gpu::PipelineHandle[] superseded = alloc::new_array(allocator, gpu::PipelineHandle, keys.len);
    foreach (index, key : keys) {
        superseded[index] = self.pipelines.get(key)!!;
        self.pipelines.remove(key);
        if (!key_stages_present(key, stages)) continue;
        PipelineKey replacement = key;
        replacement.shader_revision = new_revision;
        self.pipelines.set(replacement, fresh[index]);
    }
    forget_rejections(self, shader, false);
    return superseded;
}

<*
 Rebuild the compute shader's pipeline under the new revision; publish on success.
 @param allocator : "Owns the returned handles."
 @param [&inout] device : "Owns the created pipeline."
 @param spirv : "New revision's compute stage."
 @return "Superseded handles, to retire after their submitted use."
 @return? gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::INVALID_ARGUMENT
 @return? gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST
*>
fn gpu::PipelineHandle[]? PipelineCache.replace_compute_shader(
    &self,
    Allocator allocator,
    gpu::Device* device,
    ComputeShaderId shader,
    uint old_revision,
    uint new_revision,
    char[] spirv,
) {
    PipelineKey old_key = compute_pipeline_key(shader, old_revision);
    gpu::PipelineHandle[] superseded;
    if (try previous = self.pipelines.get(old_key)) {
        CustomStageSource source = { .compute = spirv };
        gpu::PipelineHandle fresh = create_pipeline(
            registry: &self.registry,
            device:   device,
            key:      compute_pipeline_key(shader, new_revision),
            custom:   &source,
            counters: &self.creations,
        )!;
        superseded = alloc::new_array(allocator, gpu::PipelineHandle, 1);
        superseded[0] = previous;
        self.pipelines.remove(old_key);
        self.pipelines.set(compute_pipeline_key(shader, new_revision), fresh);
    }
    forget_rejections(self, old_key.shader, true);
    return superseded;
}

<*
 Remove every pipeline of the shader at any revision.
 @param allocator : "Owns the returned handles."
 @return "Removed handles, to retire after their submitted use."
*>
fn gpu::PipelineHandle[] PipelineCache.remove_shader(&self, Allocator allocator, ShaderId shader) {
    return remove_matching(self, allocator, shader, false);
}

<*
 Remove every pipeline of the compute shader at any revision.
 @param allocator : "Owns the returned handles."
 @return "Removed handles, to retire after their submitted use."
*>
fn gpu::PipelineHandle[] PipelineCache.remove_compute_shader(&self, Allocator allocator, ComputeShaderId shader) {
    return remove_matching(self, allocator, compute_pipeline_key(shader, 0).shader, true);
}

<*
 Key of the compute shader's pipeline at the revision.
 @pure
*>
fn PipelineKey compute_pipeline_key(ComputeShaderId shader, uint revision) {
    return {
        .shader          = { .index = shader.index, .generation = shader.generation },
        .shader_revision = revision,
        .custom          = { .compute = true },
    };
}

<*
 Fragment variant a custom forward key takes on a view.
 @param [&in] stages : "Record whose traced forms decide the variant."
 @param fragment_flags : "Traced-shadow flags of the view, plus WEIGHTED_BLEND in a weighted draw."
 @pure
*>
fn ShaderVariant custom_fragment_variant(asset::ShaderDesc* stages, uint fragment_flags) {
    // A weighted draw never falls back to the plain form: it writes two attachments.
    bool weighted = (fragment_flags & shader::SHADER_FLAG_WEIGHTED_BLEND) != 0;
    if (!weighted && (custom_fragment_form(stages, fragment_flags) @pure).len == 0) return {};

    // The traced forms are the application's sources, so the built-in hard-only flag is not part of their key.
    return { .flags = fragment_flags & ~shader::SHADER_FLAG_RT_SHADOWS_HARD };
}

<*
 Stage bytes a custom key selects from a shader record.
 @param [&in] stages : "Record holding the forms the key's flags select."
 @pure
*>
fn CustomStageSource custom_stage_source(asset::ShaderDesc* stages, PipelineKey key) {
    return {
        .vertex   = custom_vertex_form(&stages.vertex, key.vertex.flags) @pure,
        .fragment = key.custom.gbuffer ? stages.gbuffer : custom_fragment_form(stages, key.fragment.flags) @pure,
    };
}

fn char[] custom_fragment_form(asset::ShaderDesc* stages, uint fragment_flags) @private {
    bool weighted = (fragment_flags & shader::SHADER_FLAG_WEIGHTED_BLEND) != 0;
    char[] plain = weighted ? stages.weighted_fragment.shaded : stages.fragment;
    asset::TracedFragment* traced = weighted ? &stages.weighted_fragment.traced : &stages.traced_fragment;
    if ((fragment_flags & shader::SHADER_FLAG_RT_SHADOWS) == 0) return plain;
    if (fragment_flags & shader::SHADER_FLAG_SCENE_TRACE_BVH) return traced.software;
    return traced.hardware;
}

fn char[] custom_vertex_form(asset::CustomVertex* vertex, uint flags) @private {
    bool instanced = (flags & shader::SHADER_FLAG_INSTANCED) != 0;
    if (flags & shader::SHADER_FLAG_DEPTH_ONLY) return instanced ? vertex.instanced_depth : vertex.depth;
    if (flags & shader::SHADER_FLAG_VELOCITY) return instanced ? vertex.instanced_velocity : vertex.velocity;
    return instanced ? vertex.instanced_shaded : vertex.shaded;
}

fn bool key_stages_present(PipelineKey key, asset::ShaderDesc* stages) @private {
    if (key.custom.vertex && custom_stage_source(stages, key).vertex.len == 0) return false;
    if (key.custom.fragment && custom_fragment_form(stages, key.fragment.flags).len == 0) return false;
    return !key.custom.gbuffer || stages.gbuffer.len > 0;
}

<*
 Create an empty cache over the registry.
*>
fn PipelineCache create_pipeline_cache(Allocator allocator, ShaderRegistry registry) {
    PipelineCache cache = { .registry = registry };
    cache.pipelines.init(allocator);
    cache.rejected.init(allocator);
    return cache;
}

<*
 Destroy every cached pipeline and the map. Every submission using them must be complete.
 @param [&inout] cache : "Left zeroed."
*>
fn void destroy_pipeline_cache(gpu::Device* device, PipelineCache* cache) {
    cache.pipelines.@each(; PipelineKey key, gpu::PipelineHandle pipeline) {
        (void)gpu::destroy_pipeline(device, pipeline);
    };
    cache.pipelines.free();
    cache.rejected.free();
    *cache = {};
}

fn gpu::PipelineHandle[] remove_matching(
    PipelineCache* cache,
    Allocator allocator,
    ShaderId shader,
    bool compute,
) @private {
    PipelineKey[] keys = keys_matching(cache, tmem, shader, compute, 0, true);
    gpu::PipelineHandle[] removed = alloc::new_array(allocator, gpu::PipelineHandle, keys.len);
    foreach (index, key : keys) {
        removed[index] = cache.pipelines.get(key)!!;
        cache.pipelines.remove(key);
    }
    forget_rejections(cache, shader, compute);
    return removed;
}

fn bool key_names(PipelineKey key, ShaderId shader, bool compute) @private {
    return c3d::same_id(key.shader, shader) && key.custom.compute == compute;
}

fn void forget_rejections(PipelineCache* cache, ShaderId shader, bool compute) @private {
    List{PipelineKey} keys;
    keys.tinit();
    cache.rejected.@each(; PipelineKey key, bool rejected) {
        if (key_names(key, shader, compute)) keys.push(key);
    };
    foreach (key : keys) cache.rejected.remove(key);
}

fn gpu::PipelineHandle? create_pipeline(
    ShaderRegistry* registry,
    gpu::Device* device,
    PipelineKey key,
    CustomStageSource* custom,
    PipelineCreationCounters* counters = null,
) @private {
    if (key.custom.compute) {
        gpu::ComputePipelineDesc compute_desc = {
            .shader     = { .spirv = custom.compute, .debug_name = "custom_compute" },
            .debug_name = "custom_compute",
        };
        std::time::Clock started = clock::now();
        if (counters) counters.calls++;
        defer if (counters) counters.elapsed_ns += (ulong)started.to_now();
        return gpu::create_compute_pipeline(device, &compute_desc);
    }
    bool custom_fragment = key.custom.fragment || key.custom.gbuffer;
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader   = {
            .spirv = key.custom.vertex ? custom.vertex : registry.get(key.vertex)!,
            .debug_name = key.custom.vertex ? "custom_vertex" : "c3d_vertex",
        },
        .fragment_shader = {
            .spirv = custom_fragment ? custom.fragment : registry.get(key.fragment)!,
            .debug_name = custom_fragment ? "custom_fragment" : "c3d_fragment",
        },
        .color_formats   = key.color_formats[:key.color_count],
        .depth_format    = key.depth_format,
        .sample_count    = key.samples,
        .polygon_mode    = key.polygon,
        .debug_name      = (uint)key.custom ? "custom_pipeline" : "c3d_pipeline",
    };
    std::time::Clock started = clock::now();
    if (counters) counters.calls++;
    defer if (counters) counters.elapsed_ns += (ulong)started.to_now();
    return gpu::create_graphics_pipeline(device, &desc);
}

fn PipelineKey[] keys_matching(
    PipelineCache* cache,
    Allocator allocator,
    ShaderId shader,
    bool compute,
    uint revision,
    bool any_revision,
) @private {
    List{PipelineKey} keys;
    keys.init(allocator);
    cache.pipelines.@each(; PipelineKey key, gpu::PipelineHandle pipeline) {
        if (key_names(key, shader, compute) && (any_revision || key.shader_revision == revision)) keys.push(key);
    };
    return keys.to_array(allocator);
}
