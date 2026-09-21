module c3d::render;

import c3d;
import gpu;
import std::math;

<*
 Images of the G-buffer, in attachment order.
*>
enum GBufferChannel : uint {
    BASE_COLOR_METALLIC,
    NORMAL_ROUGHNESS,
    EMISSIVE_SPECULAR,
    LAYERS,
    FLAGS,
}

<*
 Attachments a G-buffer pass writes.
*>
const uint GBUFFER_CHANNEL_COUNT = GBufferChannel::len;

<*
 Pixel format of each channel, in GBufferChannel order.
*>
const gpu::Format[GBUFFER_CHANNEL_COUNT] GBUFFER_FORMATS = {
    gpu::Format.RGBA8_UNORM,  // base color rgb, metallic a
    gpu::Format.RGBA16_FLOAT, // octahedral normal rg, roughness b, occlusion a
    gpu::Format.RGBA16_FLOAT, // emissive rgb, specular weight a
    gpu::Format.R32_UINT,     // receiver layer mask
    gpu::Format.R32_UINT,     // GBUFFER_FLAG_* bits
};

<*
 Debug name of each channel, in GBufferChannel order.
*>
const ZString[GBUFFER_CHANNEL_COUNT] GBUFFER_NAMES = {
    "gbuffer_base_color_metallic",
    "gbuffer_normal_roughness",
    "gbuffer_emissive_specular",
    "gbuffer_layers",
    "gbuffer_flags",
};

<*
 Octahedral projection of a unit vector onto [-1, 1]²; mirrored in gbuffer.glsl.
 @param normal : "Unit length."
*>
fn Vec2 encode_octahedral(Vec3 normal) {
    Vec3 projected = normal / (math::abs(normal.x) + math::abs(normal.y) + math::abs(normal.z));
    if (projected.z < 0) {
        return (Vec2){ 1 - math::abs(projected.y), 1 - math::abs(projected.x) } * fold_signs(projected.xy);
    }
    return projected.xy;
}

<*
 Unit vector of an octahedral encoding; mirrored in gbuffer.glsl.
*>
fn Vec3 decode_octahedral(Vec2 encoded) {
    Vec3 normal = { encoded.x, encoded.y, 1 - math::abs(encoded.x) - math::abs(encoded.y) };
    if (normal.z < 0) {
        normal.xy = (Vec2){ 1 - math::abs(normal.y), 1 - math::abs(normal.x) } * fold_signs(normal.xy);
    }
    return normal.normalize();
}

<*
 World position of a framebuffer texel from stored reverse-Z depth; mirrored in gbuffer.glsl.
 @param uv : "Texel center in [0, 1] with y downward."
*>
fn Vec3 reconstruct_world_position(Mat4 inv_view_proj, Vec2 uv, float depth) {
    Vec2 ndc = (uv * 2 - 1) * (Vec2){ 1, -1 };
    Vec4 world = inv_view_proj.apply({ ndc.x, ndc.y, depth, 1 });
    return world.xyz / world.w;
}

fn Vec2 fold_signs(Vec2 value) @local {
    return { value.x >= 0 ? 1 : -1, value.y >= 0 ? 1 : -1 };
}

fn void? acquire_gbuffer(Renderer* renderer, ViewRecord* record) @private {
    if (record.gbuffer[0].texture.is_valid() || !record.hdr_color.texture.is_valid()) return;
    defer catch release_gbuffer(&renderer.device, record);
    foreach (channel, &target : record.gbuffer) {
        *target = allocate_target(
            device:     &renderer.device,
            width:      record.hdr_color.width,
            height:     record.hdr_color.height,
            format:     GBUFFER_FORMATS[channel],
            usage:      { .color_attach, .sampled },
            debug_name: GBUFFER_NAMES[channel],
        )!;
    }
}

fn void retire_gbuffer(Renderer* renderer, ViewRecord* record) @private {
    if (!record.gbuffer[0].texture.is_valid()) return;
    RetireList* retire = last_submitted_retire(renderer);
    foreach (&target : record.gbuffer) {
        retire.push({ .kind = RetiredKind.ATTACHMENT_VIEW, .attachment_view = target.attachment });
        retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = target.view });
        retire.push({ .kind = RetiredKind.TEXTURE, .texture = target.texture });
        *target = {};
    }
}

fn void release_gbuffer(gpu::Device* device, ViewRecord* record) @private {
    foreach (&target : record.gbuffer) {
        if (target.texture.is_valid()) release_target(device, target);
    }
}
