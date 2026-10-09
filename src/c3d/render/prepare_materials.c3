module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::shader;
import gpu;

fn usz material_prepare_bytes(Renderer* renderer, MaterialId material) @private {
    Material* source = &renderer.assets.material(material).data;
    usz payload = source.kind == MaterialKind.CUSTOM ? source.custom.param_block.len : 0;
    return payload > usz::max - MATERIAL_STRIDE ? usz::max : payload + MATERIAL_STRIDE;
}

fn bool texture_prepare_current(Renderer* renderer, TextureId texture, bool full_reader) @private {
    if (!texture_current(renderer, texture)) return false;
    TextureResidency* residency = &renderer.residencies[texture.index];
    return !full_reader || !(residency.streamed && residency.resident_base > 0);
}

fn bool material_prepare_dependencies_current(Renderer* renderer, MaterialId material) @private {
    Material* source = &renderer.assets.material(material).data;
    bool current = true;
    material::@each_texture_reference(source; TextureId* texture, SamplerId* sampler) {
        bool live = renderer.assets.textures.is_live(*texture);
        TextureId selected = live ? *texture : asset::TEXTURE_WHITE;
        if (!texture_prepare_current(renderer, selected, false)) current = false;
        if (sampler) {
            SamplerId selected_sampler = renderer.assets.samplers.is_live(*sampler) ? *sampler : asset::SAMPLER_LINEAR_REPEAT;
            SamplerRes* mirror = &renderer.samplers[selected_sampler.index];
            if (!c3d::same_id(mirror.asset, selected_sampler)
                || mirror.revision != renderer.assets.sampler(selected_sampler).header.revision) current = false;
        } else if (live && !renderer.toon_gradient_sampler.is_valid()) {
            current = false;
        }
    };
    if (material_uses_sheen(source) && renderer.environment_state.sheen_lut.state == EnvironmentLutState.NONE) return false;
    if (source.kind == MaterialKind.TOON && renderer.assets.textures.is_live(source.toon.gradient_map)) {
        if (!texture_prepare_current(renderer, source.toon.gradient_map, true)) return false;
    }
    if (source.kind != MaterialKind.CUSTOM) return current;
    ShaderId shader_id = source.custom.shader;
    if (!renderer.assets.shaders.is_live(shader_id)) return false;
    ShaderRes* shader_mirror = &renderer.shaders[shader_id.index];
    uint revision = renderer.assets.shader(shader_id).header.revision;
    if (!c3d::same_id(shader_mirror.asset, shader_id)
        || (shader_mirror.revision != revision && shader_mirror.rejected_revision != revision)) return false;
    foreach (reference : source.custom.references) {
        if (!reference.generation) continue;
        if (!renderer.assets.materials.is_live(reference)) return false;
        if (renderer.assets.material(reference).data.kind != MaterialKind.STANDARD) return false;
        MaterialRes* mirror = &renderer.materials[reference.index];
        if (!c3d::same_id(mirror.asset, reference)
            || mirror.revision != renderer.assets.material(reference).header.revision) return false;
        if (!material_prepare_dependencies_current(renderer, reference)) return false;
    }
    bool masked = source.common.alpha_mode == AlphaMode.MASK;
    foreach (index, slot : source.custom.slots) {
        if (index == 0 && masked) continue;
        if (slot.texture.kind != TextureRefKind.ASSET || !renderer.assets.textures.is_live(slot.texture.asset)) continue;
        if (!texture_prepare_current(renderer, slot.texture.asset, true)) return false;
    }
    return current;
}

fn bool? material_prepare_current(Renderer* renderer, MaterialId material) @private {
    if (!material_prepare_dependencies_current(renderer, material)) return false;
    MaterialAsset* source = renderer.assets.material(material);
    MaterialRes* mirror = &renderer.materials[material.index];
    if (!c3d::same_id(mirror.asset, material) || mirror.revision != source.header.revision) return false;
    MaterialBindings bindings = material_prepare_bindings(renderer, &source.data)!;
    if (!material_bindings_match(mirror.bindings, bindings)) return false;
    if (source.data.kind == MaterialKind.CUSTOM) {
        ShaderRes* shader_mirror = &renderer.shaders[source.data.custom.shader.index];
        if (!c3d::same_id(mirror.shader, source.data.custom.shader) || mirror.shader_revision != shader_mirror.revision) return false;
    }
    return true;
}

<*
 Pack the final material block from current dependencies and private payload.
 @param [&inout] renderer : "Render target bindings record sample demand."
 @param [&inout] candidate : "Receives material bindings and published asset metadata."
 @return? c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require block.len >= MATERIAL_STRIDE, (uptr)block.ptr % STREAM_ALIGNMENT == 0
 @require material_prepare_dependencies_current(renderer, material)
*>
fn void? material_prepare_block(
    Renderer* renderer,
    MaterialId material,
    MaterialRes* candidate,
    char[] block,
) @private {
    MaterialAsset* source = renderer.assets.material(material);
    MaterialBindings bindings = material_prepare_bindings(renderer, &source.data)!;
    uint capabilities;
    gpu::GpuAddress[material::MAX_CUSTOM_MATERIAL_REFERENCES] references;
    ShaderId shader_id;
    uint shader_revision;
    if (source.data.kind == MaterialKind.CUSTOM) {
        check_custom_references(renderer.assets, &source.data.custom)!;
        ShaderRes* published = &renderer.shaders[source.data.custom.shader.index];
        if (source.data.custom.param_block.len != published.desc.param_block_size) return c3d::INVALID_ARGUMENT~;
        shader_id = published.asset;
        shader_revision = published.revision;
        if (published.desc.gbuffer.len) capabilities = shader::CUSTOM_CAPABILITY_GBUFFER;
        foreach (index, reference : source.data.custom.references) {
            if (reference.generation) references[index] = renderer.materials[reference.index].address;
        }
    }
    write_material_block(
        block: block,
        material: &source.data,
        bindings: bindings,
        parameters: candidate.payload_address,
        custom_capabilities: capabilities,
        custom_references: references,
    );
    candidate.asset = material;
    candidate.revision = source.header.revision;
    candidate.bindings = bindings;
    candidate.shader = shader_id;
    candidate.shader_revision = shader_revision;
    candidate.resolved_epoch = 0;
}

fn TextureBinding? material_prepare_texture_slot(Renderer* renderer, TextureSlot slot, bool custom_read = false) @private {
    if (slot.uv_set > 1) return c3d::INVALID_ARGUMENT~;
    SamplerId sampler = renderer.assets.samplers.is_live(slot.sampler) ? slot.sampler : asset::SAMPLER_LINEAR_REPEAT;
    if (renderer.assets.sampler(sampler).desc.compare_enable) return c3d::INVALID_ARGUMENT~;
    SamplerRes* sampler_mirror = &renderer.samplers[sampler.index];
    if (slot.texture.kind == TextureRefKind.RENDER_TARGET && renderer.targets.is_live(slot.texture.target)) {
        TargetRecord* target = renderer.targets.get(slot.texture.target);
        target.sample_pending = true;
        return {
            .target = slot.texture.target,
            .sampler = sampler,
            .texture_binding_revision = target.revision,
            .sampler_revision = sampler_mirror.revision,
            .texture_index = target.target.view.index,
            .sampler_index = sampler_mirror.index,
            .present = true,
        };
    }
    bool present = slot.texture.kind == TextureRefKind.ASSET && renderer.assets.textures.is_live(slot.texture.asset);
    if (present) {
        material::TextureDesc desc = renderer.assets.texture(slot.texture.asset).desc;
        if (desc.is_cube || (desc.format == PixelFormat.R16_UINT && !custom_read)) return c3d::UNSUPPORTED~;
    }
    TextureId texture = present ? slot.texture.asset : asset::TEXTURE_WHITE;
    TextureRes* texture_mirror = &renderer.textures[texture.index];
    return {
        .texture = texture,
        .sampler = sampler,
        .texture_binding_revision = texture_mirror.binding_revision,
        .sampler_revision = sampler_mirror.revision,
        .texture_index = texture_mirror.view.index,
        .sampler_index = sampler_mirror.index,
        .present = present,
    };
}

fn TextureBinding? material_prepare_gradient_map(Renderer* renderer, TextureId texture) @private {
    if (!renderer.assets.textures.is_live(texture)) return {};
    material::TextureDesc desc = renderer.assets.texture(texture).desc;
    if (desc.is_cube || desc.depth || desc.layers != 1 || desc.format == PixelFormat.R16_UINT) return c3d::UNSUPPORTED~;
    TextureRes* mirror = &renderer.textures[texture.index];
    return {
        .texture = texture,
        .texture_binding_revision = mirror.binding_revision,
        .texture_index = mirror.view.index,
        .sampler_index = renderer.toon_gradient_sampler,
        .present = true,
    };
}

fn MaterialBindings? material_prepare_bindings(Renderer* renderer, Material* material) @private {
    switch (material.kind) {
        case BASIC:
            return { .base_color = material_prepare_texture_slot(renderer, material.basic.map)! };
        case STANDARD:
            return material_prepare_standard_bindings(renderer, &material.standard);
        case PHYSICAL:
            PhysicalParams* params = &material.physical;
            MaterialBindings bindings = material_prepare_standard_bindings(renderer, &params.standard)!;
            if (params.clearcoat > 0) {
                bindings.clearcoat = material_prepare_texture_slot(renderer, params.clearcoat_map)!;
                bindings.clearcoat_roughness = material_prepare_texture_slot(
                    renderer: renderer,
                    slot: params.clearcoat_roughness_map,
                )!;
                bindings.clearcoat_normal = material_prepare_texture_slot(renderer, params.clearcoat_normal_map)!;
            }
            if (material_uses_sheen(material)) {
                bindings.sheen_color = material_prepare_texture_slot(renderer, params.sheen_color_map)!;
                bindings.sheen_roughness = material_prepare_texture_slot(renderer, params.sheen_roughness_map)!;
            }
            if (params.specular > 0) {
                bindings.specular = material_prepare_texture_slot(renderer, params.specular_map)!;
                bindings.specular_color = material_prepare_texture_slot(renderer, params.specular_color_map)!;
            }
            if (params.anisotropy > 0) {
                bindings.anisotropy = material_prepare_texture_slot(renderer, params.anisotropy_map)!;
            }
            if (params.transmission > 0) {
                bindings.transmission = material_prepare_texture_slot(renderer, params.transmission_map)!;
                bindings.thickness = material_prepare_texture_slot(renderer, params.thickness_map)!;
            }
            return bindings;
        case TOON:
            return {
                .base_color = material_prepare_texture_slot(renderer, material.toon.map)!,
                .gradient = material_prepare_gradient_map(renderer, material.toon.gradient_map)!,
            };
        case CUSTOM:
            MaterialBindings bindings;
            // The depth stage and traced coverage sample slot 0 of a masked material.
            bool masked = material.common.alpha_mode == AlphaMode.MASK;
            foreach (index, slot : material.custom.slots) {
                bindings.custom[index] = material_prepare_texture_slot(
                    renderer: renderer,
                    slot: slot,
                    custom_read: index > 0 || !masked,
                )!;
            }
            return bindings;
    }
}

fn MaterialBindings? material_prepare_standard_bindings(Renderer* renderer, StandardParams* params) @private {
    return {
        .base_color = material_prepare_texture_slot(renderer, params.base_color_map)!,
        .metallic_roughness = material_prepare_texture_slot(renderer, params.metallic_roughness_map)!,
        .normal = material_prepare_texture_slot(renderer, params.normal_map)!,
        .occlusion = material_prepare_texture_slot(renderer, params.occlusion_map)!,
        .emissive = material_prepare_texture_slot(renderer, params.emissive_map)!,
    };
}
