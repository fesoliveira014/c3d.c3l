module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;
import std::math;

<* Resolved identities and indices for one material texture slot. *>
struct TextureBinding {
    TextureId texture;
    SamplerId sampler;
    uint texture_binding_revision;
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
}

<*
 Compare resolved bindings including backing-resource revisions.
 @pure
*>
fn bool texture_binding_matches(TextureBinding first, TextureBinding second) {
    return first.texture.index == second.texture.index
        && first.texture.generation == second.texture.generation
        && first.sampler.index == second.sampler.index
        && first.sampler.generation == second.sampler.generation
        && first.texture_binding_revision == second.texture_binding_revision
        && first.sampler_revision == second.sampler_revision
        && first.texture_index == second.texture_index
        && first.sampler_index == second.sampler_index
        && first.present == second.present;
}


fn TextureBinding? resolve_texture_slot(Renderer* renderer, TextureSlot slot) @private {
    if (slot.texture.kind == TextureRefKind.RENDER_TARGET) return c3d::UNSUPPORTED~;
    if (slot.uv_set > 1) return c3d::INVALID_ARGUMENT~;

    bool present = renderer.assets.textures.is_live(slot.texture.asset);
    if (present && renderer.assets.texture(slot.texture.asset).desc.is_cube) return c3d::UNSUPPORTED~;
    TextureId texture = present ? slot.texture.asset : c3d::asset::TEXTURE_WHITE;
    SamplerId sampler = renderer.assets.samplers.is_live(slot.sampler)
        ? slot.sampler : c3d::asset::SAMPLER_LINEAR_REPEAT;
    if (renderer.assets.sampler(sampler).desc.compare_enable) return c3d::INVALID_ARGUMENT~;

    TextureRes* texture_mirror = ensure_texture(renderer, texture)!;
    SamplerRes* sampler_mirror = ensure_sampler(renderer, sampler)!;
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

fn TextureBinding? resolve_gradient_map(Renderer* renderer, TextureId texture) @private {
    if (!renderer.assets.textures.is_live(texture)) return {};

    TextureAsset* record = renderer.assets.texture(texture);
    if (record.desc.is_cube || record.desc.depth != 0 || record.desc.layers != 1) {
        return c3d::UNSUPPORTED~;
    }

    TextureRes* texture_mirror = ensure_texture(renderer, texture)!;
    gpu::SamplerDesc sampler = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .mip_filter = gpu::Filter.NEAREST,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .min_lod = 0,
        .max_lod = 0,
        .anisotropy_enable = false,
        .compare_enable = false,
        .debug_name = "toon_gradient",
    };
    gpu::SamplerIndex sampler_index = gpu::intern_sampler(&renderer.device, &sampler)!;
    return {
        .texture = texture,
        .texture_binding_revision = texture_mirror.binding_revision,
        .texture_index = texture_mirror.view.index,
        .sampler_index = sampler_index,
        .present = true,
    };
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
    return texture_binding_matches(first.base_color, second.base_color)
        && texture_binding_matches(first.metallic_roughness, second.metallic_roughness)
        && texture_binding_matches(first.normal, second.normal)
        && texture_binding_matches(first.occlusion, second.occlusion)
        && texture_binding_matches(first.emissive, second.emissive)
        && texture_binding_matches(first.gradient, second.gradient);
}
