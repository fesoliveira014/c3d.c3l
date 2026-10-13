module c3d::asset::image;

import std::math;
import c3d;
import c3d::asset;

<*
 Largest LUT edge length the parser accepts.
*>
const uint MAX_LUT_SIZE = 64; // 64 cubed texels are 1 MiB of RGBA8, held in the store and again on the device

const uint LUT_MIN_SIZE @local = 2;
const uint LUT_TEXEL_BYTES @local = 4;

<*
 Parsed 3D lookup table of RGBA8 texels, red fastest, owned by one allocator.
*>
struct Lut3d {
    Allocator allocator;
    uint size;
    Vec3 domain_min;
    Vec3 domain_max;
    char[] rgba;
}

<*
 Parse a .cube 3D LUT; texel values clamp to [0, 1].
 @param text : "Borrowed; read during the call."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
*>
fn Lut3d? parse_lut_cube(Allocator allocator, char[] text) {
    Lut3d lut = { .allocator = allocator, .domain_max = { 1, 1, 1 } };
    defer catch alloc::free(allocator, lut.rgba.ptr);

    usz offset;
    bool has_title;
    bool has_domain_min;
    bool has_domain_max;

    Splitter lines = ((String)text).tokenize("\n");
    while (try line = lines.next()) {
        String rest = line;
        String first = next_token(&rest);
        if (!first.len || first[0] == '#') continue;

        if (first[0].is_alpha()) {
            if (offset > 0) return c3d::ASSET_FORMAT_ERROR~;

            switch (first) {
                case "TITLE":
                    if (has_title) return c3d::ASSET_FORMAT_ERROR~;

                    has_title = true;
                case "LUT_1D_SIZE":
                    return c3d::UNSUPPORTED~;
                case "LUT_3D_SIZE":
                    if (lut.size) return c3d::ASSET_FORMAT_ERROR~;

                    lut.size = read_size(&rest)!;
                    lut.rgba = alloc::new_array(allocator, char, (sz)lut.size * lut.size * lut.size * LUT_TEXEL_BYTES);
                case "DOMAIN_MIN":
                    if (has_domain_min) return c3d::ASSET_FORMAT_ERROR~;

                    lut.domain_min = read_triple(&rest)!;
                    has_domain_min = true;
                case "DOMAIN_MAX":
                    if (has_domain_max) return c3d::ASSET_FORMAT_ERROR~;

                    lut.domain_max = read_triple(&rest)!;
                    has_domain_max = true;
                default:
                    return c3d::ASSET_FORMAT_ERROR~;
            }

            continue;
        }

        // Without a size the array is empty, so this also rejects a row ahead of LUT_3D_SIZE.
        if (offset == lut.rgba.len) return c3d::ASSET_FORMAT_ERROR~;

        rest = line;
        Vec3 texel = read_triple(&rest)!;
        for (usz channel = 0; channel < 3; channel++) {
            lut.rgba[offset++] = (char)(math::clamp(texel[channel], 0.0f, 1.0f) * (float)char::max + 0.5f);
        }

        lut.rgba[offset++] = char::max;
    }

    if (!lut.size || offset != lut.rgba.len) return c3d::ASSET_FORMAT_ERROR~;

    for (usz channel = 0; channel < 3; channel++) {
        if (lut.domain_min[channel] >= lut.domain_max[channel]) return c3d::ASSET_FORMAT_ERROR~;
    }

    return lut;
}

<*
 Read and parse a .cube 3D LUT.
 @param file_source : "Read during the call; a null read selects the file system."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED
 @require path.len > 0
*>
fn Lut3d? load_lut_cube(Allocator allocator, String path, FileSource file_source = {}) {
    char[] bytes = file_source.read_path(mem, path)!;
    defer free(bytes.ptr);

    return parse_lut_cube(allocator, bytes);
}

<*
 Release the texels and clear the table.
 @param [&inout] lut : "Live table; cleared after release."
*>
fn void destroy_lut3d(Lut3d* lut) {
    alloc::free(lut.allocator, lut.rgba.ptr);
    *lut = {};
}

fn String next_token(String* rest) @local {
    String trimmed = rest.trim_left();
    usz length;
    while (length < trimmed.len && !trimmed[length].is_space()) length++;

    *rest = trimmed[length..];
    return trimmed[:length];
}

fn float? read_float(String token) @local {
    float value = token.to_float() ?? c3d::ASSET_FORMAT_ERROR~!;
    if (!math::is_finite(value)) return c3d::ASSET_FORMAT_ERROR~;

    return value;
}

fn Vec3? read_triple(String* rest) @local {
    Vec3 triple;
    for (usz channel = 0; channel < 3; channel++) {
        triple[channel] = read_float(next_token(rest))!;
    }

    if (next_token(rest).len) return c3d::ASSET_FORMAT_ERROR~;

    return triple;
}

fn uint? read_size(String* rest) @local {
    int size = next_token(rest).to_int() ?? c3d::ASSET_FORMAT_ERROR~!;
    if (next_token(rest).len) return c3d::ASSET_FORMAT_ERROR~;
    if (size < (int)LUT_MIN_SIZE || size > (int)MAX_LUT_SIZE) return c3d::UNSUPPORTED~;

    return (uint)size;
}
