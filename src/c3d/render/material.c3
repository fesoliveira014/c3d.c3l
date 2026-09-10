module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::shader;
import gpu;
import std::math;

<*
 Bytes one material block occupies in the heap.
*>
const usz MATERIAL_STRIDE = (((usz)(BasicMaterialGpu::size > StandardMaterialGpu::size
  ? BasicMaterialGpu::size : StandardMaterialGpu::size) + STREAM_ALIGNMENT - 1)
  / STREAM_ALIGNMENT) * STREAM_ALIGNMENT;
$assert MATERIAL_STRIDE % STREAM_ALIGNMENT == 0;

<*
 Common material options packed into shader flags.
*>
bitstruct MaterialFlags : uint {
    bool alpha_mask   : 0; // mirrored as MATERIAL_ALPHA_MASK in basic.frag.glsl and standard.frag.glsl
    bool double_sided : 1; // mirrored as MATERIAL_DOUBLE_SIDED in standard.frag.glsl
}

<*
 Renderer-owned heap slot of one material record.
*>
struct MaterialRes {
    MaterialId      asset;
    uint            revision;
    gpu::GpuAddress address;
    MaterialBindings bindings;
}

<*
 Upload the material now, or record its upload into the open frame.
 Completes without a window when no frame is open.
 @param [&inout] self : "Owns map preparation and material heap copies."
 @return? c3d::INVALID_ID
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_RESOURCE_STATE, gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::WAIT_TIMEOUT
*>
fn void? Renderer.upload_material(&self, MaterialId material) {
    if (!self.assets.materials.is_live(material)) return c3d::INVALID_ID~;
    if (self.frame_open) {
        ensure_material(self, material)!;
        return;
    }
    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    ensure_material(self, material)!;
    return submit_pending(self);
}

<*
 Write the packed block of a material.
 @param block : "Aligned to STREAM_ALIGNMENT; active fields overwritten."
 @param [&in] material : "Valid active material arm and texture coordinates."
 @require block.len >= MATERIAL_STRIDE, (uptr)block.ptr % STREAM_ALIGNMENT == 0
*>
fn void write_material_block(char[] block, Material* material, MaterialBindings bindings) {
    MaterialFlags flags = {
        .alpha_mask = material.common.alpha_mode == AlphaMode.MASK,
        .double_sided = material.common.double_sided,
    };

    switch (material.kind) {
        case BASIC:
            Vec4 row0;
            Vec4 row1;
            texture_uv_rows(material.basic.map.transform, &row0, &row1);
            TextureBinding binding = bindings.base_color;
            BasicMaterialGpu* packed = (BasicMaterialGpu*)block.ptr;
            *packed = {
                .kind = (uint)material.kind.ordinal,
                .flags = (uint)flags,
                .alpha_cutoff = material.common.alpha_cutoff,
                .color = material.basic.color,
                .map_texture = binding.texture_index,
                .map_sampler = binding.sampler_index,
                .map_uv_set = material.basic.map.uv_set,
                .map_present = binding.present ? 1u : 0u,
                .map_uv_row0 = row0,
                .map_uv_row1 = row1,
            };
        case STANDARD:
            StandardParams* params = &material.standard;
            Vec4 base_color_row0;
            Vec4 base_color_row1;
            texture_uv_rows(params.base_color_map.transform, &base_color_row0, &base_color_row1);

            Vec4 metallic_roughness_row0;
            Vec4 metallic_roughness_row1;
            texture_uv_rows(
                transform: params.metallic_roughness_map.transform,
                row0: &metallic_roughness_row0,
                row1: &metallic_roughness_row1,
            );

            Vec4 normal_row0;
            Vec4 normal_row1;
            texture_uv_rows(params.normal_map.transform, &normal_row0, &normal_row1);

            Vec4 occlusion_row0;
            Vec4 occlusion_row1;
            texture_uv_rows(params.occlusion_map.transform, &occlusion_row0, &occlusion_row1);

            Vec4 emissive_row0;
            Vec4 emissive_row1;
            texture_uv_rows(params.emissive_map.transform, &emissive_row0, &emissive_row1);

            StandardMaterialGpu* packed = (StandardMaterialGpu*)block.ptr;
            *packed = {
                .kind = (uint)material.kind.ordinal,
                .flags = (uint)flags,
                .alpha_cutoff = material.common.alpha_cutoff,
                .metallic = params.metallic,
                .base_color = params.base_color,
                .emissive_strength = { params.emissive.r, params.emissive.g, params.emissive.b, params.emissive_strength },
                .roughness = params.roughness,
                .normal_scale = params.normal_scale,
                .occlusion_strength = params.occlusion_strength,
                .base_color_texture = bindings.base_color.texture_index,
                .base_color_sampler = bindings.base_color.sampler_index,
                .base_color_uv_set = params.base_color_map.uv_set,
                .base_color_present = bindings.base_color.present ? 1u : 0u,
                .base_color_uv_row0 = base_color_row0,
                .base_color_uv_row1 = base_color_row1,
                .metallic_roughness_texture = bindings.metallic_roughness.texture_index,
                .metallic_roughness_sampler = bindings.metallic_roughness.sampler_index,
                .metallic_roughness_uv_set = params.metallic_roughness_map.uv_set,
                .metallic_roughness_present = bindings.metallic_roughness.present ? 1u : 0u,
                .metallic_roughness_uv_row0 = metallic_roughness_row0,
                .metallic_roughness_uv_row1 = metallic_roughness_row1,
                .normal_texture = bindings.normal.texture_index,
                .normal_sampler = bindings.normal.sampler_index,
                .normal_uv_set = params.normal_map.uv_set,
                .normal_present = bindings.normal.present ? 1u : 0u,
                .normal_uv_row0 = normal_row0,
                .normal_uv_row1 = normal_row1,
                .occlusion_texture = bindings.occlusion.texture_index,
                .occlusion_sampler = bindings.occlusion.sampler_index,
                .occlusion_uv_set = params.occlusion_map.uv_set,
                .occlusion_present = bindings.occlusion.present ? 1u : 0u,
                .occlusion_uv_row0 = occlusion_row0,
                .occlusion_uv_row1 = occlusion_row1,
                .emissive_texture = bindings.emissive.texture_index,
                .emissive_sampler = bindings.emissive.sampler_index,
                .emissive_uv_set = params.emissive_map.uv_set,
                .emissive_present = bindings.emissive.present ? 1u : 0u,
                .emissive_uv_row0 = emissive_row0,
                .emissive_uv_row1 = emissive_row1,
            };
    }
}

fn MaterialBindings? resolve_material_bindings(Renderer* renderer, Material* material) @private {
    switch (material.kind) {
        case BASIC:
            return { .base_color = resolve_texture_slot(renderer, material.basic.map)! };
        case STANDARD:
            if (material.common.alpha_mode == AlphaMode.BLEND) return c3d::UNSUPPORTED~;

            StandardParams* params = &material.standard;
            return {
                .base_color = resolve_texture_slot(renderer, params.base_color_map)!,
                .metallic_roughness = resolve_texture_slot(renderer, params.metallic_roughness_map)!,
                .normal = resolve_texture_slot(renderer, params.normal_map)!,
                .occlusion = resolve_texture_slot(renderer, params.occlusion_map)!,
                .emissive = resolve_texture_slot(renderer, params.emissive_map)!,
            };
    }
}

fn MaterialRes*? ensure_material(Renderer* renderer, MaterialId material) @private {
    MaterialAsset* record = renderer.assets.material(material);
    MaterialRes* mirror = &renderer.materials[material.index];
    MaterialBindings bindings = resolve_material_bindings(renderer, &record.data)!;

    bool same_asset = mirror.asset.index == material.index && mirror.asset.generation == material.generation;
    if (same_asset && mirror.revision == record.header.revision
        && material_bindings_match(mirror.bindings, bindings)) return mirror;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, MATERIAL_STRIDE, STREAM_ALIGNMENT)!;
    write_material_block(staging.bytes, &record.data, bindings);
    usz offset = (usz)material.index * MATERIAL_STRIDE;
    gpu::GpuSpan destination = renderer.material_heap_span.checked_subspan(offset, MATERIAL_STRIDE)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination });
    // The slot may still be read by the frame in flight, whichever material owned it then.
    renderer.pending_overwrite = true;

    mirror.asset = material;
    mirror.revision = record.header.revision;
    mirror.bindings = bindings;
    mirror.address = gpu::get_span_address(&renderer.device, destination)!;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)MATERIAL_STRIDE;
    return mirror;
}

fn void sweep_materials(Renderer* renderer) @private {
    foreach (&mirror : renderer.materials) {
        if (!mirror.asset.generation || renderer.assets.materials.is_live(mirror.asset)) continue;
        *mirror = {};
    }
}

fn gpu::GpuAllocation? allocate_material_heap(gpu::Device* device, usz slot_count) @private {
    gpu::AllocationDesc desc = {
        .size         = slot_count * MATERIAL_STRIDE,
        .alignment    = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access       = { .graphics },
        .debug_name   = "material_heap",
    };
    return gpu::allocate_memory(device, &desc);
}

fn void free_material_heap(Renderer* renderer) @private {
    if (renderer.material_heap.is_valid()) (void)gpu::free_allocation(&renderer.device, &renderer.material_heap);
    alloc::free(renderer.allocator, renderer.materials.ptr);
}
