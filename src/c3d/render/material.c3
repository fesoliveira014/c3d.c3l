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
$assert MATERIAL_STRIDE >= CustomMaterialGpu::size;
$assert material::MAX_CUSTOM_TEXTURE_SLOTS == shader::CUSTOM_TEXTURE_SLOTS;
$assert (uint)MaterialKind.BASIC.ordinal == shader::MATERIAL_KIND_BASIC;
$assert (uint)MaterialKind.STANDARD.ordinal == shader::MATERIAL_KIND_STANDARD;
$assert (uint)MaterialKind.TOON.ordinal == shader::MATERIAL_KIND_TOON;
$assert (uint)MaterialKind.PHYSICAL.ordinal == shader::MATERIAL_KIND_PHYSICAL;
$assert (uint)MaterialKind.CUSTOM.ordinal == shader::MATERIAL_KIND_CUSTOM;

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
    MaterialId         asset;
    uint               revision;
    gpu::GpuAddress    address;
    MaterialBindings   bindings;
    ShaderId           shader;
    uint               shader_revision;
    ulong              resolved_epoch;
    uint               sampled_target_bits;
    gpu::GpuAllocation payload;
    gpu::GpuAddress    payload_address;
    usz                payload_size;
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
        resolve_material(self, material)!;
        return;
    }
    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    resolve_material(self, material)!;
    return submit_pending(self);
}

<*
 Write the packed block of a material.
 @param block : "Aligned to STREAM_ALIGNMENT; active fields overwritten."
 @param [&in] material : "Valid active material arm and texture coordinates."
 @param parameters : "Custom payload address; zero for built-in kinds."
 @require block.len >= MATERIAL_STRIDE, (uptr)block.ptr % STREAM_ALIGNMENT == 0
*>
fn void write_material_block(
    char[] block,
    Material* material,
    MaterialBindings bindings,
    gpu::GpuAddress parameters = (gpu::GpuAddress)0,
    uint custom_capabilities = 0,
) {
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
            uint extension_map_flags;
            if (params.specular > 0) {
                extension_map_flags = texture_map_flags(
                    slot: params.specular_map,
                    binding: bindings.specular,
                    map_bit: shader::PHYSICAL_EXTENSION_MAP_SPECULAR,
                );
                extension_map_flags |= texture_map_flags(
                    slot: params.specular_color_map,
                    binding: bindings.specular_color,
                    map_bit: shader::PHYSICAL_EXTENSION_MAP_SPECULAR_COLOR,
                );
            }
            if (params.anisotropy > 0) {
                extension_map_flags |= texture_map_flags(
                    slot: params.anisotropy_map,
                    binding: bindings.anisotropy,
                    map_bit: shader::PHYSICAL_EXTENSION_MAP_ANISOTROPY,
                );
            }
            if (draw_list(material) == DrawList.TRANSMISSION) {
                extension_map_flags |= texture_map_flags(
                    slot: params.transmission_map,
                    binding: bindings.transmission,
                    map_bit: shader::PHYSICAL_EXTENSION_MAP_TRANSMISSION,
                );
                extension_map_flags |= texture_map_flags(
                    slot: params.thickness_map,
                    binding: bindings.thickness,
                    map_bit: shader::PHYSICAL_EXTENSION_MAP_THICKNESS,
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
                .specular_color_weight = {
                    params.specular_color.r, params.specular_color.g, params.specular_color.b, params.specular,
                },
                .ior = params.ior,
                .extension_map_flags = extension_map_flags,
                .anisotropy = params.anisotropy,
                .anisotropy_rotation = params.anisotropy_rotation,
                .specular_map = pack_texture_map(
                    slot: params.specular_map,
                    binding: bindings.specular,
                ),
                .specular_color_map = pack_texture_map(
                    slot: params.specular_color_map,
                    binding: bindings.specular_color,
                ),
                .anisotropy_map = pack_texture_map(
                    slot: params.anisotropy_map,
                    binding: bindings.anisotropy,
                ),
                .attenuation_color_distance = {
                    params.attenuation_color.r,
                    params.attenuation_color.g,
                    params.attenuation_color.b,
                    params.attenuation_distance,
                },
                .transmission = params.transmission,
                .thickness = params.thickness,
                .transmission_map = pack_texture_map(
                    slot: params.transmission_map,
                    binding: bindings.transmission,
                ),
                .thickness_map = pack_texture_map(
                    slot: params.thickness_map,
                    binding: bindings.thickness,
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
        case CUSTOM:
            CustomMaterialGpu* packed = (CustomMaterialGpu*)block.ptr;
            *packed = {
                .kind = (uint)material.kind.ordinal,
                .flags = (uint)flags,
                .alpha_cutoff = material.common.alpha_cutoff,
                .map_flags = custom_map_flags(&material.custom.slots, &bindings.custom),
                .parameters = parameters,
                .capabilities = custom_capabilities,
            };
            foreach (index, slot : material.custom.slots) {
                packed.slots[index] = pack_texture_map(slot, bindings.custom[index]);
            }
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

fn uint custom_map_flags(
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS]* slots,
    TextureBinding[material::MAX_CUSTOM_TEXTURE_SLOTS]* bindings,
) @private {
    uint flags;
    foreach (index, slot : *slots) {
        uint slot_bit = 1u << index;
        if ((*bindings)[index].present) flags |= slot_bit;
        if (slot.uv_set == 1) flags |= slot_bit << shader::CUSTOM_MAP_UV1_SHIFT;
    }
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
            if (params.specular > 0) {
                bindings.specular = resolve_texture_slot(renderer, params.specular_map)!;
                bindings.specular_color = resolve_texture_slot(renderer, params.specular_color_map)!;
            }
            if (params.anisotropy > 0) {
                bindings.anisotropy = resolve_texture_slot(renderer, params.anisotropy_map)!;
            }
            if (draw_list(material) == DrawList.TRANSMISSION) {
                bindings.transmission = resolve_texture_slot(renderer, params.transmission_map)!;
                bindings.thickness = resolve_texture_slot(renderer, params.thickness_map)!;
            }
            return bindings;
        case TOON:
            return {
                .base_color = resolve_texture_slot(renderer, material.toon.map)!,
                .gradient = resolve_gradient_map(renderer, material.toon.gradient_map)!,
            };
        case CUSTOM:
            MaterialBindings bindings;
            foreach (index, slot : material.custom.slots) {
                bindings.custom[index] = resolve_texture_slot(renderer, slot)!;
            }
            return bindings;
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

fn void begin_material_scope(Renderer* renderer) @private {
    renderer.material_epoch++;
    renderer.material_scope_active = true;
}

fn void end_material_scope(Renderer* renderer) @private {
    renderer.material_scope_active = false;
}

fn MaterialRes*? resolve_material(Renderer* renderer, MaterialId material) @private {
    MaterialRes* mirror = &renderer.materials[material.index];
    bool same_asset = c3d::same_id(mirror.asset, material);
    if (renderer.material_scope_active && same_asset && mirror.resolved_epoch == renderer.material_epoch) {
        renderer.sampled_target_bits |= mirror.sampled_target_bits;
        return mirror;
    }

    uint outer_target_bits = renderer.sampled_target_bits;
    renderer.sampled_target_bits = 0;
    defer renderer.sampled_target_bits |= outer_target_bits;
    resolve_material_dependencies(renderer, material)!;
    mirror.sampled_target_bits = renderer.sampled_target_bits;
    mirror.resolved_epoch = renderer.material_scope_active ? renderer.material_epoch : 0;
    renderer.stats.material_resolutions++;
    return mirror;
}

fn MaterialRes*? resolve_material_dependencies(Renderer* renderer, MaterialId material) @private {
    MaterialAsset* record = renderer.assets.material(material);
    MaterialRes* mirror = &renderer.materials[material.index];
    MaterialBindings bindings = resolve_material_bindings(renderer, &record.data)!;
    if (material_uses_sheen(&record.data)) acquire_sheen_lut(renderer)!;

    bool same_asset = c3d::same_id(mirror.asset, material);
    bool custom = record.data.kind == MaterialKind.CUSTOM;
    ShaderId shader;
    uint shader_revision;
    uint capabilities;
    if (custom) {
        shader = record.data.custom.shader;
        if (!renderer.assets.shaders.is_live(shader)) return c3d::INVALID_ID~;
        ShaderRes* shader_mirror = resolve_shader(renderer, shader)!;
        asset::ShaderDesc* stages = &renderer.assets.shader(shader).desc;
        if (record.data.custom.param_block.len != stages.param_block_size) return c3d::INVALID_ARGUMENT~;
        shader_revision = shader_mirror.revision;
        if (stages.gbuffer.len) capabilities = shader::CUSTOM_CAPABILITY_GBUFFER;
    }
    bool same_shader = c3d::same_id(mirror.shader, shader) && mirror.shader_revision == shader_revision;
    if (same_asset && same_shader && mirror.revision == record.header.revision
        && material_bindings_match(mirror.bindings, bindings)) return mirror;

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::GpuAddress parameters;
    if (custom) parameters = resolve_custom_payload(renderer, mirror, record.data.custom.param_block)!;
    gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, MATERIAL_STRIDE, STREAM_ALIGNMENT)!;
    write_material_block(
        block:               staging.bytes,
        material:            &record.data,
        bindings:            bindings,
        parameters:          parameters,
        custom_capabilities: capabilities,
    );
    usz offset = (usz)material.index * MATERIAL_STRIDE;
    gpu::GpuSpan destination = renderer.material_heap_span.checked_subspan(offset, MATERIAL_STRIDE)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination });
    // The slot may still be read by the frame in flight, whichever material owned it then.
    renderer.pending_overwrite = true;

    mirror.asset = material;
    mirror.revision = record.header.revision;
    mirror.bindings = bindings;
    mirror.shader = shader;
    mirror.shader_revision = shader_revision;
    mirror.address = gpu::get_span_address(&renderer.device, destination)!;
    renderer.stats.uploads++;
    renderer.stats.upload_bytes += (uint)MATERIAL_STRIDE;
    return mirror;
}

fn gpu::GpuAddress? resolve_custom_payload(Renderer* renderer, MaterialRes* mirror, char[] bytes) @private {
    if (!bytes.len) {
        retire_custom_payload(renderer, mirror);
        return (gpu::GpuAddress)0;
    }
    if (mirror.payload_size != bytes.len) {
        retire_custom_payload(renderer, mirror);
        gpu::AllocationDesc desc = {
            .size         = bytes.len,
            .alignment    = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access       = { .graphics },
            .debug_name   = "custom_material_payload",
        };
        mirror.payload = gpu::allocate_memory(&renderer.device, &desc)!;
        mirror.payload_size = bytes.len;
        mirror.payload_address = gpu::get_span_address(
            &renderer.device,
            gpu::get_allocation_span(&renderer.device, mirror.payload)!,
        )!;
    } else {
        renderer.pending_overwrite = true;
    }

    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan staging = slot.upload.take(&renderer.device, bytes.len, STREAM_ALIGNMENT)!;
    staging.bytes[:bytes.len] = bytes[..];
    gpu::GpuSpan destination = gpu::get_allocation_span(&renderer.device, mirror.payload)!;
    renderer.pending_copies.push({ .src = staging.span, .dst = destination.checked_subspan(0, bytes.len)! });
    renderer.stats.upload_bytes += (uint)bytes.len;
    return mirror.payload_address;
}

fn void retire_custom_payload(Renderer* renderer, MaterialRes* mirror) @private {
    if (mirror.payload.is_valid()) {
        renderer.pending_upload_retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = mirror.payload });
    }
    mirror.payload = {};
    mirror.payload_size = 0;
    mirror.payload_address = (gpu::GpuAddress)0;
}

fn void sweep_materials(Renderer* renderer) @private {
    foreach (&mirror : renderer.materials) {
        if (!mirror.asset.generation || renderer.assets.materials.is_live(mirror.asset)) continue;
        retire_custom_payload(renderer, mirror);
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
    foreach (&mirror : renderer.materials) {
        if (mirror.payload.is_valid()) (void)gpu::free_allocation(&renderer.device, &mirror.payload);
    }
    alloc::free(renderer.allocator, renderer.materials.ptr);
}

<*
 Pack a masked caster's base alpha and texture coordinates.
 @param [&out] root : "Overwritten completely."
 @param [&in] material : "Valid Basic, Standard, Physical or Toon masked material."
 @param binding : "Resolved active-family base map."
 @require material.common.alpha_mode == AlphaMode.MASK, material.kind != MaterialKind.CUSTOM
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
        case CUSTOM: unreachable();
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
