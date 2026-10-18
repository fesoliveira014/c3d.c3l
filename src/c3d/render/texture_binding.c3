module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;
import std::math;

<* Resolved identities and indices for one material texture slot. *>
struct TextureBinding {
    TextureId texture;
    RenderTargetId target;
    SamplerId sampler;
    uint texture_binding_revision;
    TextureSemantic semantic;
    uint sampler_revision;
    gpu::TextureIndex texture_index;
    gpu::SamplerIndex sampler_index;
    bool present;
}

<* Resolved texture slots for the active material family. *>
struct MaterialBindings {
    TextureBinding base_color;
    TextureBinding metallic_roughness;
    TextureBinding normal;
    TextureBinding occlusion;
    TextureBinding emissive;
    TextureBinding gradient;
    TextureBinding clearcoat;
    TextureBinding clearcoat_roughness;
    TextureBinding clearcoat_normal;
    TextureBinding sheen_color;
    TextureBinding sheen_roughness;
    TextureBinding specular;
    TextureBinding specular_color;
    TextureBinding anisotropy;
    TextureBinding transmission;
    TextureBinding thickness;
    TextureBinding[material::MAX_CUSTOM_TEXTURE_SLOTS] custom;
}

<*
 Compare resolved bindings including backing-resource revisions.
 @pure
*>
fn bool texture_binding_matches(TextureBinding first, TextureBinding second) {
    return c3d::same_id(first.texture, second.texture)
        && c3d::same_id(first.target, second.target)
        && c3d::same_id(first.sampler, second.sampler)
        && first.texture_binding_revision == second.texture_binding_revision
        && first.semantic == second.semantic
        && first.sampler_revision == second.sampler_revision
        && first.texture_index == second.texture_index
        && first.sampler_index == second.sampler_index
        && first.present == second.present;
}

// Budgeted preparation passes resolve = false: its earlier steps made these mirrors current.
fn TextureBinding? resolve_texture_slot(
    Renderer* renderer,
    TextureSlot slot,
    bool resolve = true,
    bool custom_read = false,
) @private {
    if (slot.uv_set > 1) return c3d::INVALID_ARGUMENT~;

    SamplerId sampler = renderer.assets.samplers.is_live(slot.sampler)
        ? slot.sampler : c3d::asset::SAMPLER_LINEAR_REPEAT;

    if (renderer.assets.sampler(sampler).desc.compare_enable) return c3d::INVALID_ARGUMENT~;

    SamplerRes* sampler_mirror = resolve ? resolve_sampler(renderer, sampler)! : &renderer.samplers[sampler.index];

    if (slot.texture.kind == TextureRefKind.VIEW) {
        if (!custom_read) return c3d::UNSUPPORTED~;
        if (slot.texture.view_slot >= material::MAX_VIEW_TEXTURES) return c3d::INVALID_ARGUMENT~;

        // The flagged index selects the drawing view's texture in the shader; the slot reads as absent without one.
        return {
            .sampler = sampler,
            .sampler_revision = sampler_mirror.revision,
            .texture_index = (gpu::TextureIndex)(shader::VIEW_TEXTURE_FLAG | slot.texture.view_slot),
            .sampler_index = sampler_mirror.index,
        };
    }

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
        // Built-in stages sample as float; integer texels are read only through gpu_fetch_uint.
        if (desc.is_cube || (desc.format == R16_UINT && !custom_read)) return c3d::UNSUPPORTED~;
    }

    TextureId texture = present ? slot.texture.asset : c3d::asset::TEXTURE_WHITE;
    TextureRes* texture_mirror = resolve
        ? resolve_texture(renderer, texture, full_reader: custom_read)!
        : &renderer.textures[texture.index];

    return {
        .texture = texture,
        .sampler = sampler,
        .texture_binding_revision = texture_mirror.binding_revision,
        .semantic = texture_binding_semantic(renderer, texture, texture_mirror),
        .sampler_revision = sampler_mirror.revision,
        .texture_index = texture_mirror.view.index,
        .sampler_index = sampler_mirror.index,
        .present = present,
    };
}

fn TextureBinding? resolve_gradient_map(Renderer* renderer, TextureId texture, bool resolve = true) @private {
    if (!renderer.assets.textures.is_live(texture)) return {};

    TextureAsset* record = renderer.assets.texture(texture);

    if (record.desc.is_cube || record.desc.depth != 0 || record.desc.layers != 1 || record.desc.format == R16_UINT) {
        return c3d::UNSUPPORTED~;
    }

    TextureRes* texture_mirror = resolve
        ? resolve_texture(renderer, texture, full_reader: true)!
        : &renderer.textures[texture.index];

    if (resolve) acquire_toon_gradient_sampler(renderer)!;

    return {
        .texture = texture,
        .texture_binding_revision = texture_mirror.binding_revision,
        .semantic = texture_binding_semantic(renderer, texture, texture_mirror),
        .texture_index = texture_mirror.view.index,
        .sampler_index = renderer.toon_gradient_sampler,
        .present = true,
    };
}

fn void? acquire_toon_gradient_sampler(Renderer* renderer) @private {
    if (renderer.toon_gradient_sampler.is_valid()) return;

    gpu::SamplerDesc sampler = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .mip_filter = gpu::Filter.NEAREST,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .debug_name = "toon_gradient",
    };
    renderer.toon_gradient_sampler = gpu::intern_sampler(&renderer.device, &sampler)!;
}

fn TextureSemantic texture_binding_semantic(Renderer* renderer, TextureId texture, TextureRes* mirror) @private {
    TextureSemantic semantic = mirror.semantic;

    // CPU descriptors can advance again before captured uploads commit.
    foreach (pending : renderer.pending_texture_uploads) {
        if (c3d::same_id(pending.asset, texture) && pending.texture == mirror.texture) semantic = pending.semantic;
    }

    return semantic;
}

<*
 Pack a texture transform into two affine rows.
 @param [&out] row0 : "First row, padding zeroed."
 @param [&out] row1 : "Second row, padding zeroed."
 @pure
*>
fn void texture_uv_rows(UvTransform transform, Vec4* row0, Vec4* row1) {
    float cosine = math::cos(transform.rotation);
    float sine = math::sin(transform.rotation);
    *row0 = { cosine * transform.scale.x, -sine * transform.scale.y, transform.offset.x, 0 };
    *row1 = { sine * transform.scale.x, cosine * transform.scale.y, transform.offset.y, 0 };
}

<*
 Compare every resolved material dependency.
 @pure
*>
fn bool material_bindings_match(MaterialBindings first, MaterialBindings second) {
    foreach (index, binding : first.custom) {
        if (!texture_binding_matches(binding, second.custom[index])) return false;
    }

    return texture_binding_matches(first.base_color, second.base_color)
        && texture_binding_matches(first.metallic_roughness, second.metallic_roughness)
        && texture_binding_matches(first.normal, second.normal)
        && texture_binding_matches(first.occlusion, second.occlusion)
        && texture_binding_matches(first.emissive, second.emissive)
        && texture_binding_matches(first.gradient, second.gradient)
        && texture_binding_matches(first.clearcoat, second.clearcoat)
        && texture_binding_matches(first.clearcoat_roughness, second.clearcoat_roughness)
        && texture_binding_matches(first.clearcoat_normal, second.clearcoat_normal)
        && texture_binding_matches(first.sheen_color, second.sheen_color)
        && texture_binding_matches(first.sheen_roughness, second.sheen_roughness)
        && texture_binding_matches(first.specular, second.specular)
        && texture_binding_matches(first.specular_color, second.specular_color)
        && texture_binding_matches(first.anisotropy, second.anisotropy)
        && texture_binding_matches(first.transmission, second.transmission)
        && texture_binding_matches(first.thickness, second.thickness);
}
