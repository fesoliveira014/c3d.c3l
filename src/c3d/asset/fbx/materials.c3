module c3d::asset::fbx;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::material;
import std::io::file;
import std::math;
import ufbx;

const uint RGBA_CHANNELS @private = 4;
const uint RED @private = 0;
const uint GREEN @private = 1;
const uint BLUE @private = 2;
const uint ALPHA @private = 3;
const uint CHANNEL_MAX @private = char::max;

fn void? convert_materials(Importer* importer) @private {
    foreach (source : importer.scene.materials) {
        material::Material converted = convert_material(importer, source)!;
        String key = string::tformat("%s#material/%d", importer.key, source.typed_id);
        importer.materials[source.typed_id] = importer.assets.add_material(converted, key)!;
    }
    return;
}

fn MaterialId? default_material(Importer* importer) @private {
    if (importer.default_material.generation) return importer.default_material;
    String key = string::tformat("%s#material/default", importer.key);
    importer.default_material = importer.assets.add_material(material::standard(), key)!;
    return importer.default_material;
}

fn material::Material? convert_material(Importer* importer, ufbx::Material* source) @private {
    ufbx::MaterialPbrMaps* pbr = &source.pbr;
    bool glossiness = source.features.roughness_as_glossiness.enabled;
    vector::Vec3 base_color = map_color(&pbr.base_color, { 1, 1, 1 }) * map_factor(&pbr.base_factor);
    vector::Vec3 emissive = map_color(&pbr.emission_color, { 0, 0, 0 }) * map_factor(&pbr.emission_factor);
    float metallic = map_scalar(&pbr.metalness, 0);
    float roughness = map_scalar(&pbr.roughness, 1);
    if (glossiness && !pbr.roughness.texture) roughness = 1 - roughness;
    float opacity = map_scalar(&pbr.opacity, 1);

    bool finite = finite_rgb(base_color) && finite_rgb(emissive)
        && math::is_finite(metallic) && math::is_finite(roughness) && math::is_finite(opacity);
    bool emissive_nonnegative = emissive.x >= 0 && emissive.y >= 0 && emissive.z >= 0;
    if (!finite || !emissive_nonnegative) return c3d::ASSET_FORMAT_ERROR~;

    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = opacity < 1 || pbr.opacity.texture ? AlphaMode.BLEND : AlphaMode.OPAQUE;

    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = {
        math::clamp(base_color.x, 0.0f, 1.0f),
        math::clamp(base_color.y, 0.0f, 1.0f),
        math::clamp(base_color.z, 0.0f, 1.0f),
        math::clamp(opacity, 0.0f, 1.0f),
    };
    params.metallic = math::clamp(metallic, 0.0f, 1.0f);
    params.roughness = math::clamp(roughness, 0.0f, 1.0f);
    params.emissive = emissive;
    params.base_color_map = base_color_slot(importer, source)!;
    params.metallic_roughness_map = metallic_roughness_slot(importer, source, glossiness)!;
    params.normal_map = texture_slot_for(importer, pbr.normal_map.texture, false)!;
    params.occlusion_map = texture_slot_for(importer, pbr.ambient_occlusion.texture, false)!;
    params.emissive_map = texture_slot_for(importer, pbr.emission_color.texture, true)!;
    return material::standard(params, common);
}

fn float map_factor(ufbx::MaterialMap* map) @private {
    return map.has_value ? (float)map.value_real : 1;
}

fn float map_scalar(ufbx::MaterialMap* map, float fallback) @private {
    // A connected FBX texture replaces the property value.
    if (map.texture) return 1;
    return map.has_value ? (float)map.value_real : fallback;
}

fn vector::Vec3 map_color(ufbx::MaterialMap* map, vector::Vec3 fallback) @private {
    if (map.texture) return { 1, 1, 1 };
    if (!map.has_value) return fallback;
    return { (float)map.value_vec3.x, (float)map.value_vec3.y, (float)map.value_vec3.z };
}

fn bool finite_rgb(vector::Vec3 color) @private {
    return math::is_finite(color.x) && math::is_finite(color.y) && math::is_finite(color.z);
}

fn TextureSlot? texture_slot_for(Importer* importer, ufbx::Texture* texture, bool srgb) @private {
    if (!texture) return material::texture_slot();
    ufbx::Texture* file = file_texture(texture)!;
    TextureId id = plain_texture(importer, file, srgb)!;
    return material::texture_slot(id, sampler_for(importer, file)!);
}

fn TextureSlot? base_color_slot(Importer* importer, ufbx::Material* source) @private {
    ufbx::Texture* base = source.pbr.base_color.texture;
    ufbx::Texture* opacity = source.pbr.opacity.texture;
    if (!opacity) return texture_slot_for(importer, base, true);
    ufbx::Texture* opacity_file = file_texture(opacity)!;
    ufbx::Texture* base_file = base ? file_texture(base)! : null;
    if (base_file == opacity_file) return texture_slot_for(importer, base, true);
    TextureId id = base_opacity_texture(importer, base_file, opacity_file)!;
    return material::texture_slot(id, sampler_for(importer, base_file ?: opacity_file)!);
}

fn TextureSlot? metallic_roughness_slot(Importer* importer, ufbx::Material* source, bool glossiness) @private {
    ufbx::Texture* roughness = source.pbr.roughness.texture;
    ufbx::Texture* metalness = source.pbr.metalness.texture;
    if (!roughness && !metalness) return material::texture_slot();
    ufbx::Texture* roughness_file = roughness ? file_texture(roughness)! : null;
    ufbx::Texture* metalness_file = metalness ? file_texture(metalness)! : null;
    TextureId id = metallic_roughness_texture(
        importer:   importer,
        roughness:  roughness_file,
        metalness:  metalness_file,
        glossiness: glossiness,
    )!;
    return material::texture_slot(id, sampler_for(importer, roughness_file ?: metalness_file)!);
}

fn ufbx::Texture*? file_texture(ufbx::Texture* texture) @private {
    ufbx::Texture* file = texture;
    if (texture.type != ufbx::TextureType.FILE) {
        if (!texture.file_textures.len) return c3d::UNSUPPORTED~;
        file = texture.file_textures[0];
    }
    if (file.has_uv_transform) return c3d::UNSUPPORTED~;
    return file;
}

fn char[]? texture_bytes(Importer* importer, ufbx::Texture* texture) @private {
    if (texture.content.len) return texture.content;
    if (texture.relative_filename.len) {
        String relative = texture.relative_filename.treplace("\\", "/");
        if (try bytes = file::load(tmem, join_path(importer.base_dir, relative))) return bytes;
    }
    if (texture.absolute_filename.len) {
        if (try bytes = file::load(tmem, texture.absolute_filename.treplace("\\", "/"))) return bytes;
    }
    return c3d::ASSET_IO_ERROR~;
}

fn image::Image? decode(Importer* importer, ufbx::Texture* texture, alloc::Allocator allocator) @private {
    char[] bytes = texture_bytes(importer, texture)!;
    image::Image decoded = image::decode_image(allocator, bytes)!;
    if (decoded.format != RGBA8_UNORM) {
        image::destroy_image(&decoded);
        return c3d::ASSET_FORMAT_ERROR~;
    }
    return decoded;
}

fn TextureId? plain_texture(Importer* importer, ufbx::Texture* texture, bool srgb) @private {
    TextureId[] table = srgb ? importer.srgb_textures : importer.linear_textures;
    if (table[texture.typed_id].generation) return table[texture.typed_id];

    image::Image decoded = decode(importer, texture, importer.assets.allocator)!;
    defer catch image::destroy_image(&decoded);
    TextureDesc desc = material::texture_2d_desc(
        width:      decoded.width,
        height:     decoded.height,
        format:     srgb ? RGBA8_SRGB : RGBA8_UNORM,
        debug_name: "fbx_image",
    );
    String key = string::tformat("%s#image/%d/%s", importer.key, texture.typed_id, srgb ? "srgb" : "linear");
    TextureId id = importer.assets.add_texture_owned(desc, decoded.pixels, key)!;
    table[texture.typed_id] = id;
    return id;
}

fn SamplerId? sampler_for(Importer* importer, ufbx::Texture* texture) @private {
    bool repeat_u = texture.wrap_u == ufbx::WrapMode.REPEAT;
    bool repeat_v = texture.wrap_v == ufbx::WrapMode.REPEAT;
    if (repeat_u == repeat_v) return repeat_u ? asset::SAMPLER_LINEAR_REPEAT : asset::SAMPLER_LINEAR_CLAMP;

    usz slot = repeat_u ? MIXED_REPEAT_CLAMP : MIXED_CLAMP_REPEAT;
    if (importer.mixed_samplers[slot].generation) return importer.mixed_samplers[slot];
    SamplerDesc desc = material::sampler_desc(Filter.LINEAR, AddressMode.REPEAT, "fbx_sampler");
    desc.address_u = repeat_u ? AddressMode.REPEAT : AddressMode.CLAMP_TO_EDGE;
    desc.address_v = repeat_v ? AddressMode.REPEAT : AddressMode.CLAMP_TO_EDGE;
    String key = string::tformat("%s#sampler/%s", importer.key, repeat_u ? "repeat_clamp" : "clamp_repeat");
    importer.mixed_samplers[slot] = importer.assets.add_sampler(desc, key)!;
    return importer.mixed_samplers[slot];
}

fn TextureId find_derived(
    Importer* importer,
    uint first,
    uint second,
    bool metallic_roughness,
    bool invert_roughness = false,
) @private {
    foreach (&derived : importer.derived_textures[:importer.derived_count]) {
        bool same = derived.first == first && derived.second == second
            && derived.metallic_roughness == metallic_roughness
            && derived.invert_roughness == invert_roughness;
        if (same) return derived.texture;
    }
    return {};
}

fn TextureId? metallic_roughness_texture(
    Importer* importer,
    ufbx::Texture* roughness,
    ufbx::Texture* metalness,
    bool glossiness,
) @private {
    uint roughness_id = roughness ? roughness.typed_id : NO_TEXTURE;
    uint metalness_id = metalness ? metalness.typed_id : NO_TEXTURE;
    TextureId existing = find_derived(
        importer:           importer,
        first:              roughness_id,
        second:             metalness_id,
        metallic_roughness: true,
        invert_roughness:   glossiness,
    );
    if (existing.generation) return existing;

    image::Image roughness_image;
    image::Image metalness_image;
    if (roughness) roughness_image = decode(importer, roughness, tmem)!;
    if (metalness) metalness_image = decode(importer, metalness, tmem)!;
    uint width = math::max(roughness_image.width, metalness_image.width);
    uint height = math::max(roughness_image.height, metalness_image.height);

    alloc::Allocator allocator = importer.assets.allocator;
    char[] pixels = alloc::new_array(allocator, char, (sz)width * height * RGBA_CHANNELS);
    defer catch alloc::free(allocator, pixels.ptr);
    for (uint y = 0; y < height; y++) {
        for (uint x = 0; x < width; x++) {
            usz texel = ((usz)y * width + x) * RGBA_CHANNELS;
            uint rough = CHANNEL_MAX;
            uint metal = CHANNEL_MAX;
            if (roughness) {
                rough = red_at(
                    source: &roughness_image,
                    x:      x,
                    y:      y,
                    width:  width,
                    height: height,
                );
                if (glossiness) rough = CHANNEL_MAX - rough;
            }
            if (metalness) {
                metal = red_at(
                    source: &metalness_image,
                    x:      x,
                    y:      y,
                    width:  width,
                    height: height,
                );
            }
            pixels[texel + RED] = 0;
            pixels[texel + GREEN] = (char)rough;
            pixels[texel + BLUE] = (char)metal;
            pixels[texel + ALPHA] = (char)CHANNEL_MAX;
        }
    }

    TextureDesc desc = material::texture_2d_desc(
        width:      width,
        height:     height,
        format:     RGBA8_UNORM,
        debug_name: "fbx_metallic_roughness",
    );
    String key = string::tformat(
        "%s#image/%s+%s/metallic_roughness/%s",
        importer.key,
        texture_label(roughness_id),
        texture_label(metalness_id),
        glossiness ? "inverted" : "direct",
    );
    TextureId id = importer.assets.add_texture_owned(desc, pixels, key)!;
    importer.derived_textures[importer.derived_count++] = {
        .first              = roughness_id,
        .second             = metalness_id,
        .metallic_roughness = true,
        .invert_roughness   = glossiness,
        .texture            = id,
    };
    return id;
}

fn TextureId? base_opacity_texture(Importer* importer, ufbx::Texture* base, ufbx::Texture* opacity) @private {
    uint base_id = base ? base.typed_id : NO_TEXTURE;
    TextureId existing = find_derived(
        importer:           importer,
        first:              base_id,
        second:             opacity.typed_id,
        metallic_roughness: false,
    );
    if (existing.generation) return existing;

    image::Image base_image;
    if (base) base_image = decode(importer, base, tmem)!;
    image::Image opacity_image = decode(importer, opacity, tmem)!;
    uint width = base ? base_image.width : opacity_image.width;
    uint height = base ? base_image.height : opacity_image.height;

    alloc::Allocator allocator = importer.assets.allocator;
    char[] pixels = alloc::new_array(allocator, char, (sz)width * height * RGBA_CHANNELS);
    defer catch alloc::free(allocator, pixels.ptr);
    for (uint y = 0; y < height; y++) {
        for (uint x = 0; x < width; x++) {
            usz texel = ((usz)y * width + x) * RGBA_CHANNELS;
            uint base_alpha = CHANNEL_MAX;
            if (base) {
                pixels[texel : RGBA_CHANNELS] = base_image.pixels[texel : RGBA_CHANNELS];
                base_alpha = base_image.pixels[texel + ALPHA];
            } else {
                pixels[texel + RED] = (char)CHANNEL_MAX;
                pixels[texel + GREEN] = (char)CHANNEL_MAX;
                pixels[texel + BLUE] = (char)CHANNEL_MAX;
            }
            uint coverage = red_at(
                source: &opacity_image,
                x:      x,
                y:      y,
                width:  width,
                height: height,
            );
            pixels[texel + ALPHA] = (char)((base_alpha * coverage + CHANNEL_MAX / 2) / CHANNEL_MAX);
        }
    }

    TextureDesc desc = material::texture_2d_desc(
        width:      width,
        height:     height,
        format:     RGBA8_SRGB,
        debug_name: "fbx_base_opacity",
    );
    String key = string::tformat("%s#image/%s+%d/srgb", importer.key, texture_label(base_id), opacity.typed_id);
    TextureId id = importer.assets.add_texture_owned(desc, pixels, key)!;
    importer.derived_textures[importer.derived_count++] = {
        .first              = base_id,
        .second             = opacity.typed_id,
        .metallic_roughness = false,
        .texture            = id,
    };
    return id;
}

fn uint red_at(
    image::Image* source,
    uint x,
    uint y,
    uint width,
    uint height,
) @private {
    ulong source_x = (ulong)x * source.width / width;
    ulong source_y = (ulong)y * source.height / height;
    return source.pixels[(usz)(source_y * source.width + source_x) * RGBA_CHANNELS + RED];
}

fn String texture_label(uint id) @private {
    return id == NO_TEXTURE ? "-" : string::tformat("%d", id);
}
