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
