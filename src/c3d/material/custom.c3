module c3d::material;

import c3d;

<*
 Texture slots a custom material exposes to its shader.
*>
const uint MAX_CUSTOM_TEXTURE_SLOTS = 8; // eight TextureMapGpu, 256 bytes of the heap slot; mirrored as CUSTOM_TEXTURE_SLOTS in c3d.abi

<*
 Eight empty asset slots with identity coordinates.
*>
const TextureSlot[MAX_CUSTOM_TEXTURE_SLOTS] CUSTOM_SLOTS_DEFAULT = {
    [0] = { .texture = { .kind = ASSET }, .transform = UV_TRANSFORM_IDENTITY },
    [1] = { .texture = { .kind = ASSET }, .transform = UV_TRANSFORM_IDENTITY },
    [2] = { .texture = { .kind = ASSET }, .transform = UV_TRANSFORM_IDENTITY },
    [3] = { .texture = { .kind = ASSET }, .transform = UV_TRANSFORM_IDENTITY },
    [4] = { .texture = { .kind = ASSET }, .transform = UV_TRANSFORM_IDENTITY },
    [5] = { .texture = { .kind = ASSET }, .transform = UV_TRANSFORM_IDENTITY },
    [6] = { .texture = { .kind = ASSET }, .transform = UV_TRANSFORM_IDENTITY },
    [7] = { .texture = { .kind = ASSET }, .transform = UV_TRANSFORM_IDENTITY },
};

<*
 User shader, its parameter payload and ordinary texture slots.
*>
struct CustomParams {
    ShaderId                              shader;
    char[]                                param_block;
    TextureSlot[MAX_CUSTOM_TEXTURE_SLOTS] slots;
}

<*
 Material shaded by user SPIR-V.
 @param param_block : "Copied by the store when the material is added."
 @pure
*>
fn Material custom(
    ShaderId shader,
    char[] param_block = {},
    TextureSlot[MAX_CUSTOM_TEXTURE_SLOTS] slots = CUSTOM_SLOTS_DEFAULT,
    MaterialCommon common = MATERIAL_COMMON_DEFAULT,
) {
    return {
        .kind = MaterialKind.CUSTOM,
        .common = common,
        .custom = { .shader = shader, .param_block = param_block, .slots = slots },
    };
}
