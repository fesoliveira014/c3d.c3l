module c3d::render;

import c3d;
import c3d::shader;
import gpu;
import std::collections::map;
import std::hash::fnv32a;

<*
 Color attachment slots a pipeline key describes.
*>
const usz KEY_COLOR_TARGETS = 4; // hdr_color, velocity, and two spare; keeps the key at 40 bytes

<*
 Immutable pipeline inputs: stages and attachment formats.
*>
struct PipelineKey {
    ShaderVariant                  vertex;
    ShaderVariant                  fragment;
    gpu::Format[KEY_COLOR_TARGETS] color_formats;
    uint                           color_count;
    gpu::Format                    depth_format;
    gpu::SampleCount               samples;
    gpu::PolygonMode               polygon;
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
        && self.polygon == other.polygon;
}

<*
 Pipeline for the key, created on first use from the registry's stages.
 @param [&inout] device : "Owns the created pipeline."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY, gpu::DEVICE_LOST
*>
fn gpu::PipelineHandle? PipelineCache.get(&self, gpu::Device* device, PipelineKey key) {
    if (try existing = self.pipelines.get(key)) return existing;

    gpu::GraphicsPipelineDesc desc = {
        .vertex_shader   = { .spirv = self.registry.get(key.vertex)!, .debug_name = "c3d_vertex" },
        .fragment_shader = { .spirv = self.registry.get(key.fragment)!, .debug_name = "c3d_fragment" },
        .color_formats   = key.color_formats[:key.color_count],
        .depth_format    = key.depth_format,
        .sample_count    = key.samples,
        .polygon_mode    = key.polygon,
        .debug_name      = "c3d_pipeline",
    };
    gpu::PipelineHandle pipeline = gpu::create_graphics_pipeline(device, &desc)!;
    self.pipelines.set(key, pipeline);
    return pipeline;
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
