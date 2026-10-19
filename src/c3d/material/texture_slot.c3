module c3d::material;

import c3d;
import std::math;

<* Identity texture-coordinate transform. *>
const UvTransform UV_TRANSFORM_IDENTITY = { .scale = { 1, 1 } };

<*
 View textures a view can provide to the custom materials that draw in it.
*>
const uint MAX_VIEW_TEXTURES = 4; // mirrored as MAX_VIEW_TEXTURES in c3d.abi; 16 bytes of FrameRoot per view

<* Source namespace of a material texture reference. *>
enum TextureRefKind { ASSET, RENDER_TARGET, VIEW }

<* Typed texture source; targets are renderer-local and view slots are read from the drawing view. *>
struct TextureRef {
    TextureRefKind kind;
    union {
        TextureId asset;
        RenderTargetId target;
        uint view_slot;
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

<*
 Describe a map the drawing view provides, with identity coordinates by default.
 @param view_slot : "Index set with Renderer.set_view_texture."
 @param uv_set : "Zero selects UV0; one selects UV1."
 @require view_slot < MAX_VIEW_TEXTURES
 @require uv_set <= 1
*>
fn TextureSlot view_texture_slot(
    uint view_slot,
    SamplerId sampler = {},
    uint uv_set = 0,
    UvTransform transform = UV_TRANSFORM_IDENTITY,
) {
    return {
        .texture = { .kind = VIEW, .view_slot = view_slot },
        .sampler = sampler,
        .uv_set = uv_set,
        .transform = transform,
    };
}
