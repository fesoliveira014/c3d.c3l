module c3d::asset;

import c3d;
import c3d::material;

<*
 Builtin textures every store holds.
*>
const uint BUILTIN_TEXTURE_COUNT = 4;

<*
 Builtin samplers every store holds.
*>
const uint BUILTIN_SAMPLER_COUNT = 5;

const uint CHECKER_SIZE @local = 8; // 256 bytes per store; two cells across at CHECKER_CELL
const uint CHECKER_CELL @local = 4; // visible at 1:1 on a small quad; one texel would alias
const uint BYTES_PER_RGBA8 @local = 4;
const float BUILTIN_ANISOTROPY @local = 16; // common hardware maximum; the renderer clamps to caps

<*
 One white texel, key builtin/white.
*>
const TextureId TEXTURE_WHITE = { .index = 0, .generation = 1 };

<*
 One black texel, key builtin/black.
*>
const TextureId TEXTURE_BLACK = { .index = 1, .generation = 1 };

<*
 One +Z tangent-space normal, key builtin/flat_normal.
*>
const TextureId TEXTURE_FLAT_NORMAL = { .index = 2, .generation = 1 };

<*
 8x8 gray checkerboard, key builtin/checker.
*>
const TextureId TEXTURE_CHECKER = { .index = 3, .generation = 1 };

<*
 Trilinear, repeat, key builtin/linear_repeat.
*>
const SamplerId SAMPLER_LINEAR_REPEAT = { .index = 0, .generation = 1 };

<*
 Trilinear, clamp to edge, key builtin/linear_clamp.
*>
const SamplerId SAMPLER_LINEAR_CLAMP = { .index = 1, .generation = 1 };

<*
 Nearest, repeat, key builtin/nearest.
*>
const SamplerId SAMPLER_NEAREST = { .index = 2, .generation = 1 };

<*
 Trilinear, repeat, 16x anisotropy clamped by the renderer; key builtin/anisotropic.
*>
const SamplerId SAMPLER_ANISOTROPIC = { .index = 3, .generation = 1 };

<*
 Linear clamp with GREATER_EQUAL compare, key builtin/shadow.
*>
const SamplerId SAMPLER_SHADOW = { .index = 4, .generation = 1 };

fn void add_builtins(AssetStore* store) @private {
    char[BYTES_PER_RGBA8] white = { 255, 255, 255, 255 };
    char[BYTES_PER_RGBA8] black = { 0, 0, 0, 255 };
    char[BYTES_PER_RGBA8] flat_normal = { 128, 128, 255, 255 };
    store.add_texture(builtin_texture_desc(1, RGBA8_UNORM, "builtin_white"), white[..], "builtin/white")!!;
    store.add_texture(builtin_texture_desc(1, RGBA8_UNORM, "builtin_black"), black[..], "builtin/black")!!;
    store.add_texture(builtin_texture_desc(1, RGBA8_UNORM, "builtin_flat_normal"), flat_normal[..], "builtin/flat_normal")!!;
    @pool() {
        char[] checker = alloc::new_array(tmem, char, CHECKER_SIZE * CHECKER_SIZE * BYTES_PER_RGBA8);
        for (uint y = 0; y < CHECKER_SIZE; y++) {
            for (uint x = 0; x < CHECKER_SIZE; x++) {
                bool light = ((x / CHECKER_CELL + y / CHECKER_CELL) & 1) == 0;
                char gray = light ? 200 : 80;
                usz offset = (usz)(y * CHECKER_SIZE + x) * BYTES_PER_RGBA8;
                checker[offset..offset + 2] = gray;
                checker[offset + 3] = 255;
            }
        }
        store.add_texture(builtin_texture_desc(CHECKER_SIZE, RGBA8_SRGB, "builtin_checker"), checker, "builtin/checker")!!;
    };

    store.add_sampler(material::sampler_desc(LINEAR, REPEAT, "builtin_linear_repeat"), "builtin/linear_repeat")!!;
    store.add_sampler(material::sampler_desc(LINEAR, CLAMP_TO_EDGE, "builtin_linear_clamp"), "builtin/linear_clamp")!!;
    store.add_sampler(material::sampler_desc(NEAREST, REPEAT, "builtin_nearest"), "builtin/nearest")!!;
    SamplerDesc anisotropic = material::sampler_desc(LINEAR, REPEAT, "builtin_anisotropic");
    anisotropic.anisotropy_enable = true;
    anisotropic.max_anisotropy = BUILTIN_ANISOTROPY;
    store.add_sampler(anisotropic, "builtin/anisotropic")!!;
    SamplerDesc shadow = material::sampler_desc(LINEAR, CLAMP_TO_EDGE, "builtin_shadow");
    shadow.compare_enable = true;
    shadow.compare = GREATER_EQUAL;
    store.add_sampler(shadow, "builtin/shadow")!!;
}

fn TextureDesc builtin_texture_desc(uint size, PixelFormat format, ZString debug_name) @local {
    TextureDesc desc = material::texture_2d_desc(
        width:      size,
        height:     size,
        format:     format,
        debug_name: debug_name,
    );
    desc.generate_mips = size > 1;
    return desc;
}
