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
const usz MATERIAL_STRIDE = (((usz)PhysicalMaterialGpu::size + STREAM_ALIGNMENT - 1)
  / STREAM_ALIGNMENT) * STREAM_ALIGNMENT;
$assert MATERIAL_STRIDE % STREAM_ALIGNMENT == 0;
$assert MATERIAL_STRIDE >= BasicMaterialGpu::size;
$assert MATERIAL_STRIDE >= StandardMaterialGpu::size;
$assert MATERIAL_STRIDE >= ToonMaterialGpu::size;
$assert MATERIAL_STRIDE >= PhysicalMaterialGpu::size;

<*
 Common material options packed into shader flags.
*>
bitstruct MaterialFlags : uint {
    bool alpha_mask   : 0;
    bool double_sided : 1;
    bool alpha_blend  : 2;
}
$assert shader::MATERIAL_ALPHA_MASK == 1 << 0;
$assert shader::MATERIAL_DOUBLE_SIDED == 1 << 1;
$assert shader::MATERIAL_ALPHA_BLEND == 1 << 2;

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
 Material and referenced sources stay stable until the open frame closes.
 @param [&inout] self : "Completes closed-frame uploads without a window."
 @return? c3d::INVALID_ID, c3d::SHADER_NOT_FOUND
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::UNSUPPORTED_FEATURE, gpu::COMMAND_RECORDING_ERROR, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED
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
        .alpha_blend = material.common.alpha_mode == AlphaMode.BLEND,
    };

    switch (material.kind) {
        case BASIC:
            BasicMaterialGpu* packed = (BasicMaterialGpu*)block.ptr;
            *packed = {
                .kind = (uint)material.kind.ordinal,
                .flags = (uint)flags,
                .alpha_cutoff = material.common.alpha_cutoff,
                .map_flags = texture_map_flags(
                    slot: material.basic.map,
                    binding: bindings.base_color,
                    map_bit: shader::MATERIAL_MAP_BASE_COLOR,
                ),
                .color = material.basic.color,
                .map = pack_texture_map(material.basic.map, bindings.base_color),
            };
        case STANDARD:
            *(StandardMaterialGpu*)block.ptr = pack_standard_material(
                kind: material.kind,
                common: material.common,
                params: &material.standard,
                bindings: &bindings,
            );
        case PHYSICAL:
            PhysicalParams* params = &material.physical;
            uint map_flags;
            if (params.clearcoat > 0) {
                map_flags = texture_map_flags(
                    slot: params.clearcoat_map,
                    binding: bindings.clearcoat,
                    map_bit: shader::PHYSICAL_MAP_CLEARCOAT,
                );
                map_flags |= texture_map_flags(
                    slot: params.clearcoat_roughness_map,
                    binding: bindings.clearcoat_roughness,
                    map_bit: shader::PHYSICAL_MAP_CLEARCOAT_ROUGHNESS,
                );
                map_flags |= texture_map_flags(
                    slot: params.clearcoat_normal_map,
                    binding: bindings.clearcoat_normal,
                    map_bit: shader::PHYSICAL_MAP_CLEARCOAT_NORMAL,
                );
            }
            if (material_uses_sheen(material)) {
                map_flags |= texture_map_flags(
                    slot: params.sheen_color_map,
                    binding: bindings.sheen_color,
                    map_bit: shader::PHYSICAL_MAP_SHEEN_COLOR,
                );
                map_flags |= texture_map_flags(
                    slot: params.sheen_roughness_map,
                    binding: bindings.sheen_roughness,
                    map_bit: shader::PHYSICAL_MAP_SHEEN_ROUGHNESS,
                );
            }
            *(PhysicalMaterialGpu*)block.ptr = {
                .standard = pack_standard_material(
                    kind: material.kind,
                    common: material.common,
                    params: &params.standard,
                    bindings: &bindings,
                ),
                .sheen_color_roughness = {
                    params.sheen_color.r, params.sheen_color.g, params.sheen_color.b, params.sheen_roughness,
                },
                .clearcoat = params.clearcoat,
                .clearcoat_roughness = params.clearcoat_roughness,
                .clearcoat_normal_scale = params.clearcoat_normal_scale,
                .map_flags = map_flags,
                .clearcoat_map = pack_texture_map(
                    slot: params.clearcoat_map,
                    binding: bindings.clearcoat,
                ),
                .clearcoat_roughness_map = pack_texture_map(
                    slot: params.clearcoat_roughness_map,
                    binding: bindings.clearcoat_roughness,
                ),
                .clearcoat_normal_map = pack_texture_map(
                    slot: params.clearcoat_normal_map,
                    binding: bindings.clearcoat_normal,
                ),
                .sheen_color_map = pack_texture_map(
                    slot: params.sheen_color_map,
                    binding: bindings.sheen_color,
                ),
                .sheen_roughness_map = pack_texture_map(
                    slot: params.sheen_roughness_map,
                    binding: bindings.sheen_roughness,
                ),
            };
        case TOON:
            ToonParams* params = &material.toon;
            uint map_flags = texture_map_flags(
                slot: params.map,
                binding: bindings.base_color,
                map_bit: shader::MATERIAL_MAP_BASE_COLOR,
            );
            if (bindings.gradient.present) map_flags |= shader::TOON_MAP_GRADIENT;

            ToonMaterialGpu* packed = (ToonMaterialGpu*)block.ptr;
            *packed = {
                .kind = (uint)material.kind.ordinal,
                .flags = (uint)flags,
                .alpha_cutoff = material.common.alpha_cutoff,
                .map_flags = map_flags,
                .color = params.color,
                .rim_color_strength = {
                    params.rim_color.r,
                    params.rim_color.g,
                    params.rim_color.b,
                    params.rim_strength,
                },
                .rim_power = params.rim_power,
                .steps = params.steps,
                .gradient_texture = bindings.gradient.texture_index,
                .gradient_sampler = bindings.gradient.sampler_index,
                .map = pack_texture_map(params.map, bindings.base_color),
            };
    }
}

fn StandardMaterialGpu pack_standard_material(
    MaterialKind kind,
    MaterialCommon common,
    StandardParams* params,
    MaterialBindings* bindings,
) @private {
    MaterialFlags flags = {
        .alpha_mask = common.alpha_mode == AlphaMode.MASK,
        .double_sided = common.double_sided,
        .alpha_blend = common.alpha_mode == AlphaMode.BLEND,
    };
    uint map_flags = texture_map_flags(
        slot: params.base_color_map,
        binding: bindings.base_color,
        map_bit: shader::MATERIAL_MAP_BASE_COLOR,
    );
    map_flags |= texture_map_flags(
        slot: params.metallic_roughness_map,
        binding: bindings.metallic_roughness,
        map_bit: shader::MATERIAL_MAP_METALLIC_ROUGHNESS,
    );
    map_flags |= texture_map_flags(
        slot: params.normal_map,
        binding: bindings.normal,
        map_bit: shader::MATERIAL_MAP_NORMAL,
    );
    map_flags |= texture_map_flags(
        slot: params.occlusion_map,
        binding: bindings.occlusion,
        map_bit: shader::MATERIAL_MAP_OCCLUSION,
    );
    map_flags |= texture_map_flags(
        slot: params.emissive_map,
        binding: bindings.emissive,
        map_bit: shader::MATERIAL_MAP_EMISSIVE,
    );

    return {
        .kind = (uint)kind.ordinal,
        .flags = (uint)flags,
        .alpha_cutoff = common.alpha_cutoff,
        .metallic = params.metallic,
        .base_color = params.base_color,
        .emissive_strength = { params.emissive.r, params.emissive.g, params.emissive.b, params.emissive_strength },
        .roughness = params.roughness,
        .normal_scale = params.normal_scale,
        .occlusion_strength = params.occlusion_strength,
        .map_flags = map_flags,
        .base_color_map = pack_texture_map(params.base_color_map, bindings.base_color),
        .metallic_roughness_map = pack_texture_map(params.metallic_roughness_map, bindings.metallic_roughness),
        .normal_map = pack_texture_map(params.normal_map, bindings.normal),
        .occlusion_map = pack_texture_map(params.occlusion_map, bindings.occlusion),
        .emissive_map = pack_texture_map(params.emissive_map, bindings.emissive),
    };
}

fn TextureMapGpu pack_texture_map(TextureSlot slot, TextureBinding binding) @private {
    Vec4 row0;
    Vec4 row1;
    texture_uv_rows(slot.transform, &row0, &row1);

    return {
        .texture_index = binding.texture_index,
        .sampler_index = binding.sampler_index,
        .uv_offset = { row0.z, row1.z },
        .uv_linear = { row0.x, row0.y, row1.x, row1.y },
    };
}

fn uint texture_map_flags(TextureSlot slot, TextureBinding binding, uint map_bit) @private {
    uint flags = binding.present ? map_bit : 0;
    if (slot.uv_set == 1) flags |= map_bit << shader::MATERIAL_MAP_UV1_SHIFT;
    return flags;
}

fn MaterialBindings? resolve_material_bindings(Renderer* renderer, Material* material) @private {
    switch (material.kind) {
        case BASIC:
            return { .base_color = resolve_texture_slot(renderer, material.basic.map)! };
        case STANDARD:
            return resolve_standard_bindings(renderer, &material.standard);
        case PHYSICAL:
            PhysicalParams* params = &material.physical;
            MaterialBindings bindings = resolve_standard_bindings(renderer, &params.standard)!;
            if (params.clearcoat > 0) {
                bindings.clearcoat = resolve_texture_slot(renderer, params.clearcoat_map)!;
                bindings.clearcoat_roughness = resolve_texture_slot(renderer, params.clearcoat_roughness_map)!;
                bindings.clearcoat_normal = resolve_texture_slot(renderer, params.clearcoat_normal_map)!;
            }
            if (material_uses_sheen(material)) {
                bindings.sheen_color = resolve_texture_slot(renderer, params.sheen_color_map)!;
                bindings.sheen_roughness = resolve_texture_slot(renderer, params.sheen_roughness_map)!;
            }
            return bindings;
        case TOON:
            return {
                .base_color = resolve_texture_slot(renderer, material.toon.map)!,
                .gradient = resolve_gradient_map(renderer, material.toon.gradient_map)!,
            };
    }
}

fn MaterialBindings? resolve_standard_bindings(Renderer* renderer, StandardParams* params) @private {
    return {
        .base_color = resolve_texture_slot(renderer, params.base_color_map)!,
        .metallic_roughness = resolve_texture_slot(renderer, params.metallic_roughness_map)!,
        .normal = resolve_texture_slot(renderer, params.normal_map)!,
        .occlusion = resolve_texture_slot(renderer, params.occlusion_map)!,
        .emissive = resolve_texture_slot(renderer, params.emissive_map)!,
    };
}

fn bool material_uses_sheen(Material* material) @private {
    return material.kind == MaterialKind.PHYSICAL
        && (material.physical.sheen_color.r > 0 || material.physical.sheen_color.g > 0
            || material.physical.sheen_color.b > 0);
}

fn MaterialRes*? ensure_material(Renderer* renderer, MaterialId material) @private {
    MaterialAsset* record = renderer.assets.material(material);
    MaterialRes* mirror = &renderer.materials[material.index];
    MaterialBindings bindings = resolve_material_bindings(renderer, &record.data)!;
    if (material_uses_sheen(&record.data)) ensure_sheen_lut(renderer)!;

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

<*
 Pack a masked caster's base alpha and texture coordinates.
 @param [&out] root : "Overwritten completely."
 @param [&in] material : "Valid Basic, Standard, Physical or Toon masked material."
 @param binding : "Resolved active-family base map."
 @require material.common.alpha_mode == AlphaMode.MASK
*>
fn void write_shadow_material_block(BasicMaterialGpu* root, Material* material, TextureBinding binding) {
    TextureSlot slot;
    Vec4 color;
    switch (material.kind) {
        case BASIC:
            slot = material.basic.map;
            color = material.basic.color;
        case STANDARD:
            slot = material.standard.base_color_map;
            color = material.standard.base_color;
        case PHYSICAL:
            slot = material.physical.standard.base_color_map;
            color = material.physical.standard.base_color;
        case TOON:
            slot = material.toon.map;
            color = material.toon.color;
    }
    MaterialFlags flags = { .alpha_mask = true, .double_sided = material.common.double_sided };
    *root = {
        .kind = (uint)material.kind.ordinal,
        .flags = (uint)flags,
        .alpha_cutoff = material.common.alpha_cutoff,
        .map_flags = texture_map_flags(slot, binding, shader::MATERIAL_MAP_BASE_COLOR),
        .color = color,
        .map = pack_texture_map(slot, binding),
    };
}
