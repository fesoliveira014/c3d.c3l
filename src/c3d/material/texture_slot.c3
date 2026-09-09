module c3d::material;

import c3d;
import std::math;

<* Identity texture-coordinate transform. *>
const UvTransform UV_TRANSFORM_IDENTITY = { .scale = { 1, 1 } };

<* Source namespace of a material texture reference. *>
enum TextureRefKind { ASSET, RENDER_TARGET }

<* Typed texture source; targets are renderer-local. *>
struct TextureRef {
    TextureRefKind kind;
    union {
        TextureId asset;
        RenderTargetId target;
    }
}

<* Scale, then rotate about the origin, then translate UVs. *>
struct UvTransform {
    Vec2 offset;
    Vec2 scale;
    float rotation;
}

<* Texture, sampler and coordinate selection for one material map. *>
struct TextureSlot {
    TextureRef texture;
    SamplerId sampler;
    uint uv_set;
    UvTransform transform;
}

<*
 Describe an asset map with identity coordinates by default.
 @param uv_set : "Zero selects UV0; one selects UV1."
 @require uv_set <= 1
*>
fn TextureSlot texture_slot(
    TextureId texture = {},
    SamplerId sampler = {},
    uint uv_set = 0,
    UvTransform transform = UV_TRANSFORM_IDENTITY,
) {
    return {
        .texture = { .kind = ASSET, .asset = texture },
        .sampler = sampler,
        .uv_set = uv_set,
        .transform = transform,
    };
}
