module c3d::render::post;

import c3d::material;

const uint LUT_CHANNELS @private = 4;

<*
 Identity RGBA8 3D LUT with x fastest, then y, then z.
 @param allocator : "Owns the returned pixels."
 @require size > 1
*>
fn char[] identity_lut(Allocator allocator, uint size) {
    usz texels = (usz)size * size * size;
    char[] pixels = alloc::new_array(allocator, char, (sz)(texels * LUT_CHANNELS));
    uint last = size - 1;
    uint half = last / 2;
    usz offset;
    for (uint z = 0; z < size; z++) {
        for (uint y = 0; y < size; y++) {
            for (uint x = 0; x < size; x++) {
                pixels[offset++] = (char)((x * char::max + half) / last);
                pixels[offset++] = (char)((y * char::max + half) / last);
                pixels[offset++] = (char)((z * char::max + half) / last);
                pixels[offset++] = char::max;
            }
        }
    }
    return pixels;
}

<*
 Single-mip RGBA8 3D description of a LUT cube.
 @require size > 1
*>
fn material::TextureDesc identity_lut_desc(uint size, ZString debug_name = "identity_lut") {
    return material::texture_3d_desc(
        width:      size,
        height:     size,
        depth:      size,
        format:     PixelFormat.RGBA8_UNORM,
        debug_name: debug_name,
    );
}
