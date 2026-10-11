module c3d::asset::image;

import c3d;
import c3d::asset;
import c3d::material;

struct ImportedTexture @private {
    TextureDesc desc;
    char[] pixels;                  // mip zero owned by the importer allocator while mips are generated
    TextureContainerView container; // borrowed supplied levels otherwise
}

fn TextureSemantic normal_semantic(NormalEncoding encoding) @private {
    switch (encoding) {
        case RGB: return TextureSemantic.NORMAL_RGB;
        case RG: return TextureSemantic.NORMAL_RG;
    }
}

fn ImportedTexture? decode_imported_texture(
    Allocator allocator,
    char[] encoded,
    bool srgb,
    TextureSemantic semantic,
    ZString debug_name,
) @private {
    if (is_texture_container(encoded)) {
        TextureContainerView container = parse_texture_container(
            scratch: tmem,
            bytes: encoded,
            color_space: srgb ? ColorSpace.SRGB : ColorSpace.LINEAR,
            semantic: semantic,
        )!;
        container.desc.debug_name = debug_name;

        if (!container.desc.generate_mips) return { .desc = container.desc, .container = container };

        char[] base = container.levels[0].bytes;
        char[] pixels = alloc::new_array(allocator, char, (sz)base.len);
        pixels[..] = base[..];

        return { .desc = container.desc, .pixels = pixels };
    }

    Image decoded = decode_image(allocator, encoded)!;

    if (decoded.format != RGBA8_UNORM) {
        destroy_image(&decoded);
        return c3d::ASSET_FORMAT_ERROR~;
    }

    TextureDesc desc = material::texture_2d_desc(
        width: decoded.width,
        height: decoded.height,
        format: srgb ? RGBA8_SRGB : RGBA8_UNORM,
        debug_name: debug_name,
    );
    desc.semantic = semantic;

    return { .desc = desc, .pixels = decoded.pixels };
}

fn String imported_texture_key(String model_key, usz image_index, bool srgb, TextureDesc desc) @private {
    String role = srgb ? "srgb" : "linear";

    switch (desc.semantic) {
        case COLOR: break;
        case NORMAL_RGB: role = string::tformat("normal_rgb/%d", desc.format.ordinal);
        case NORMAL_RG: role = string::tformat("normal_rg/%d", desc.format.ordinal);
    }

    return string::tformat("%s#image/%d/%s", model_key, image_index, role);
}

fn TextureId? push_imported_texture(ModelDocument* document, ImportedTexture* texture, String key) @private {
    if (!texture.desc.generate_mips) {
        return document.push_texture_mips(texture.desc, texture.container.levels[:texture.container.level_count], key);
    }

    TextureId id = document.push_texture(texture.desc, texture.pixels, key);
    texture.pixels = {};

    return id;
}
