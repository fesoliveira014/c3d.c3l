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
const usz KEY_COLOR_TARGETS = 4; // hdr_color, velocity, and two spare; keeps the key at 56 bytes

<*
 Which stages of a key come from a store shader instead of the registry.
*>
bitstruct CustomStages : uint {
    bool vertex   : 0;
    bool fragment : 1;
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
$assert PipelineKey::size == 56;

<*
 SPIR-V of the custom stages a key selects; borrowed for the create call.
*>
struct CustomStageSource {
    char[] vertex;
    char[] fragment;
}

<*
 Pipelines resolved for this renderer, one per distinct key.
*>
struct PipelineCache {
    HashMap{PipelineKey, gpu::PipelineHandle} pipelines;
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
 Pipeline for the key, created on first use from the registry or the custom stages.
 @param [&inout] device : "Owns the created pipeline."
 @param [in] custom : "Stages for key.custom; ignored when both bits are clear."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST
 @require !key.custom.vertex || custom.vertex.len > 0
 @require !key.custom.fragment || custom.fragment.len > 0
*>
fn gpu::PipelineHandle? PipelineCache.get(&self, gpu::Device* device, PipelineKey key, CustomStageSource* custom = null) {
    if (try existing = self.pipelines.get(key)) return existing;

    gpu::PipelineHandle pipeline = create_pipeline(&self.registry, device, key, custom)!;
    self.pipelines.set(key, pipeline);
    return pipeline;
}

<*
 Keys of every pipeline built from the shader at the revision.
 @param allocator : "Owns the returned array."
*>
fn PipelineKey[] PipelineCache.keys_of(&self, Allocator allocator, ShaderId shader, uint revision) {
    return keys_matching(self, allocator, shader, revision, false);
}

<*
 Rebuild every pipeline of the shader under the new revision; publish all or none.
 @param allocator : "Owns the returned handles."
 @param [&inout] device : "Owns the created pipelines."
 @param [&in] stages : "New revision's SPIR-V; the depth vertex form serves DEPTH_ONLY keys."
 @return "Superseded handles, to retire after their submitted use."
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
        PipelineKey replacement = key;
        replacement.shader_revision = new_revision;
        self.pipelines.set(replacement, fresh[index]);
    }
    return superseded;
}

<*
 Remove every pipeline of the shader at any revision.
 @param allocator : "Owns the returned handles."
 @return "Removed handles, to retire after their submitted use."
*>
fn gpu::PipelineHandle[] PipelineCache.remove_shader(&self, Allocator allocator, ShaderId shader) {
    PipelineKey[] keys = keys_matching(self, tmem, shader, 0, true);
    gpu::PipelineHandle[] removed = alloc::new_array(allocator, gpu::PipelineHandle, keys.len);
    foreach (index, key : keys) {
        removed[index] = self.pipelines.get(key)!!;
        self.pipelines.remove(key);
    }
    return removed;
}

<*
 Stage bytes a custom key selects from a shader record.
 @param [&in] stages : "Record whose vertex forms both exist when key.custom.vertex is set."
 @pure
*>
fn CustomStageSource custom_stage_source(asset::ShaderDesc* stages, PipelineKey key) {
    bool depth = (key.vertex.flags & shader::SHADER_FLAG_DEPTH_ONLY) != 0;
    return {
        .vertex = depth ? stages.vertex.depth : stages.vertex.shaded,
        .fragment = stages.fragment,
    };
}

<*
 Create an empty cache over the registry.
*>
fn PipelineCache create_pipeline_cache(Allocator allocator, ShaderRegistry registry) {
    PipelineCache cache = { .registry = registry };
    cache.pipelines.init(allocator);
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
    *cache = {};
}

fn gpu::PipelineHandle? create_pipeline(
    ShaderRegistry* registry,
    gpu::Device* device,
    PipelineKey key,
    CustomStageSource* custom,
) @private {
    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader   = {
            .spirv = key.custom.vertex ? custom.vertex : registry.get(key.vertex)!,
            .debug_name = key.custom.vertex ? "custom_vertex" : "c3d_vertex",
        },
        .fragment_shader = {
            .spirv = key.custom.fragment ? custom.fragment : registry.get(key.fragment)!,
            .debug_name = key.custom.fragment ? "custom_fragment" : "c3d_fragment",
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
    uint revision,
    bool any_revision,
) @private {
    List{PipelineKey} keys;
    keys.init(allocator);
    cache.pipelines.@each(; PipelineKey key, gpu::PipelineHandle pipeline) {
        if (key.shader.index == shader.index && key.shader.generation == shader.generation
            && (any_revision || key.shader_revision == revision)) {
            keys.push(key);
        }
    };
    return keys.to_array(allocator);
}
