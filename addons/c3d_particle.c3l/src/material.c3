module c3d::particle;

import c3d;
import c3d::asset;
import c3d::material;
import std::math;

<*
 Illumination applied by the particle effect fragment stage.
*>
enum ParticleLighting {
    UNLIT,
    AMBIENT,
}

<*
 Appearance parameters shared by a particle material.
*>
struct ParticleMaterialParams {
    Vec4 color;
    float soft_distance;
    ParticleLighting lighting;
    uint _pad0;
    uint _pad1;
}
$assert ParticleMaterialParams::size == 32;
$assert $reflect(ParticleMaterialParams.color).offset == 0;
$assert $reflect(ParticleMaterialParams.soft_distance).offset == 16;
$assert $reflect(ParticleMaterialParams.lighting).offset == 20;
$assert ParticleLighting.UNLIT.ordinal == 0; // mirrored as PARTICLE_UNLIT in particle.frag.glsl
$assert ParticleLighting.AMBIENT.ordinal == 1; // mirrored as PARTICLE_AMBIENT in particle.frag.glsl

<*
 Publish the package's depth-reading particle fragment shader.
 @param [&inout] assets : "Owns the copied stage."
 @param key : "Optional unique asset key."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn ShaderId? add_particle_shader(AssetStore* assets, String key = "") {
    ShaderDesc desc = {
        .fragment = PARTICLE_FRAGMENT_SPIRV[..],
        .param_block_size = ParticleMaterialParams::size,
        .scene_reads = { .depth },
    };
    return assets.add_shader(&desc, key);
}

<*
 Publish a blended particle material with copied parameters.
 @param [&inout] assets : "Owns the copied material payload."
 @param key : "Optional unique asset key."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT, c3d::INVALID_ID
*>
fn MaterialId? add_particle_material(
    AssetStore* assets,
    ShaderId shader,
    ParticleMaterialParams params,
    TextureSlot map = { .transform = material::UV_TRANSFORM_IDENTITY },
    BlendMode blend = BlendMode.PREMULTIPLIED_ALPHA,
    String key = "",
) {
    if (!assets.shaders.is_live(shader)) return c3d::INVALID_ID~;
    ShaderDesc* desc = &assets.shader(shader).desc;
    if (desc.param_block_size != ParticleMaterialParams::size || !desc.scene_reads.depth
        || desc.vertex.shaded.len || desc.gbuffer.len) return c3d::INVALID_ARGUMENT~;
    if (!valid_particle_color(params.color) || !math::is_finite(params.soft_distance)
        || params.soft_distance < 0) return c3d::INVALID_ARGUMENT~;
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
    slots[0] = map;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.blend_mode = blend;
    common.depth_write = false;
    common.double_sided = true;
    Material material = material::custom(
        shader: shader,
        param_block: material::@as_bytes(params),
        slots: slots,
        common: common,
    );
    return assets.add_material(material, key);
}
