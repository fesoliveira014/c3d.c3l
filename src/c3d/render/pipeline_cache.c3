module c3d::render;

import c3d;
import c3d::asset;
import c3d::shader;
import gpu;
import std::collections::list;
import std::collections::map;
import std::hash::fnv32a;

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

<*
 Pipelines resolved for this renderer, one per distinct key.
*>
struct PipelineCache {
    HashMap{PipelineKey, gpu::PipelineHandle} pipelines;
    HashMap{PipelineKey, bool}                rejected;
    ShaderRegistry                            registry;
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
        && self.shader.index == other.shader.index
        && self.shader.generation == other.shader.generation
        && self.shader_revision == other.shader_revision
        && (uint)self.custom == (uint)other.custom;
}

<*
 Create a registry compute pipeline into the caller's slot once; a valid slot is kept.
 @param [&inout] pipeline : "Caller-owned slot; written only after successful creation."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? acquire_compute_pipeline(
    Renderer* renderer,
    gpu::PipelineHandle* pipeline,
    ShaderName shader,
    ZString debug_name,
) @private {
    if (pipeline.is_valid()) return;

    gpu::ComputePipelineDesc description = {
        .shader     = { .spirv = renderer.pipelines.registry.get({ .shader = shader })! },
        .debug_name = debug_name,
    };
    *pipeline = gpu::create_compute_pipeline(&renderer.device, &description)!;
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

    gpu::PipelineHandle? pipeline = create_pipeline(&self.registry, device, key, custom);
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
 @param [&in] stages : "New revision's SPIR-V; the depth vertex form serves DEPTH_ONLY keys."
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
    usz created;
    defer catch foreach (handle : fresh[:created]) (void)gpu::destroy_pipeline(device, handle);

    foreach (index, key : keys) {
        if (!key_stages_present(key, stages)) continue;
        PipelineKey replacement = key;
        replacement.shader_revision = new_revision;
        CustomStageSource source = custom_stage_source(stages, replacement);
        fresh[index] = create_pipeline(&self.registry, device, replacement, &source)!;
        created++;
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
 Stage bytes a custom key selects from a shader record.
 @param [&in] stages : "Record holding the vertex pair the key's flags select."
 @pure
*>
fn CustomStageSource custom_stage_source(asset::ShaderDesc* stages, PipelineKey key) {
    bool depth = (key.vertex.flags & shader::SHADER_FLAG_DEPTH_ONLY) != 0;
    char[] vertex = depth ? stages.vertex.depth : stages.vertex.shaded;
    if (key.vertex.flags & shader::SHADER_FLAG_INSTANCED) {
        vertex = depth ? stages.vertex.instanced_depth : stages.vertex.instanced_shaded;
    }
    return {
        .vertex = vertex,
        .fragment = key.custom.gbuffer ? stages.gbuffer : stages.fragment,
    };
}

fn bool key_stages_present(PipelineKey key, asset::ShaderDesc* stages) @private {
    if (key.custom.vertex) {
        bool instanced = (key.vertex.flags & shader::SHADER_FLAG_INSTANCED) != 0;
        if ((instanced ? stages.vertex.instanced_shaded : stages.vertex.shaded).len == 0) return false;
    }
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
    return key.shader.index == shader.index && key.shader.generation == shader.generation
        && key.custom.compute == compute;
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
) @private {
    if (key.custom.compute) {
        gpu::ComputePipelineDesc compute_desc = {
            .shader     = { .spirv = custom.compute, .debug_name = "custom_compute" },
            .debug_name = "custom_compute",
        };
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
