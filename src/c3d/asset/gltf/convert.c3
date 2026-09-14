module c3d::asset::gltf;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::light;
import c3d::material;
import gltf;
import std::io::file;
import std::math;

const String DATA_URI_PREFIX @private = "data:";
const uint UV_SET_MAX @private = 1; // texture_slot accepts UV0 and UV1 only

fn void? convert_samplers(Importer* importer) @private {
    foreach (index, &sampler : importer.data.samplers) {
        SamplerDesc desc = {
            .min_filter = min_filter(sampler.min_filter),
            .mag_filter = sampler.mag_filter == gltf::FILTER_NEAREST ? Filter.NEAREST : Filter.LINEAR,
            .mip_filter = mip_filter(sampler.min_filter),
            .address_u  = address_mode(sampler.wrap_s),
            .address_v  = address_mode(sampler.wrap_t),
            .address_w  = AddressMode.REPEAT,
            .debug_name = "gltf_sampler",
        };
        String key = string::tformat("%s#sampler/%d", importer.key, index);
        importer.samplers[index] = importer.assets.add_sampler(desc, key)!;
    }
    return;
}

fn Filter min_filter(gltf::FilterType filter) @private {
    switch (filter) {
        case gltf::FILTER_NEAREST:
        case gltf::FILTER_NEAREST_MIPMAP_NEAREST:
        case gltf::FILTER_NEAREST_MIPMAP_LINEAR:
            return Filter.NEAREST;
        default:
            return Filter.LINEAR;
    }
}

fn Filter mip_filter(gltf::FilterType filter) @private {
    switch (filter) {
        case gltf::FILTER_NEAREST_MIPMAP_NEAREST:
        case gltf::FILTER_LINEAR_MIPMAP_NEAREST:
            return Filter.NEAREST;
        default:
            return Filter.LINEAR;
    }
}

fn AddressMode address_mode(gltf::WrapMode wrap) @private {
    switch (wrap) {
        case gltf::WRAP_CLAMP_TO_EDGE: return AddressMode.CLAMP_TO_EDGE;
        case gltf::WRAP_MIRRORED_REPEAT: return AddressMode.MIRRORED_REPEAT;
        default: return AddressMode.REPEAT;
    }
}

fn TextureId? texture_for(Importer* importer, gltf::Texture* texture, bool srgb) @private {
    if (!texture.image) return texture.has_basisu || texture.has_webp ? c3d::UNSUPPORTED~ : c3d::ASSET_FORMAT_ERROR~;
    usz image_index = gltf::image_index(importer.data, texture.image);
    TextureId[] table = srgb ? importer.srgb_textures : importer.linear_textures;
    if (table[image_index].generation) return table[image_index];

    char[] encoded = image_bytes(importer, texture.image)!;
    image::Image decoded = image::decode_image(importer.assets.allocator, encoded)!;
    defer catch image::destroy_image(&decoded);
    if (decoded.format != RGBA8_UNORM) return c3d::ASSET_FORMAT_ERROR~;

    TextureDesc desc = material::texture_2d_desc(
        width: decoded.width,
        height: decoded.height,
        format: srgb ? RGBA8_SRGB : RGBA8_UNORM,
        debug_name: "gltf_image",
    );
    String key = string::tformat("%s#image/%d/%s", importer.key, image_index, srgb ? "srgb" : "linear");
    TextureId id = importer.assets.add_texture_owned(desc, decoded.pixels, key)!;
    table[image_index] = id;
    return id;
}

fn char[]? image_bytes(Importer* importer, gltf::Image* image) @private {
    if (image.buffer_view) return image.buffer_view.bytes();
    if (!image.uri) return c3d::ASSET_FORMAT_ERROR~;
    String uri = image.uri.str_view();
    if (uri.starts_with(DATA_URI_PREFIX)) {
        sz? comma = uri.index_of_char(',');
        if (catch comma) return c3d::ASSET_FORMAT_ERROR~;
        char[]? decoded = gltf::decode_base64(tmem, uri[(usz)comma + 1..]);
        if (catch excuse = decoded) return load_fault(excuse)~;
        return decoded;
    }
    ZString encoded_uri = uri.zstr_tcopy();
    usz length = gltf::decode_uri(encoded_uri);
    char[]? bytes = file::load(tmem, join_path(importer.base_dir, encoded_uri.str_view()[:length]));
    if (catch bytes) return c3d::ASSET_IO_ERROR~;
    return bytes;
}

fn TextureSlot? texture_slot_for(Importer* importer, gltf::TextureView* view, bool srgb) @private {
    if (!view.texture) return material::texture_slot();
    TextureId texture = texture_for(importer, view.texture, srgb)!;
    gltf::Sampler* sampler = view.texture.sampler;
    SamplerId sampler_id = sampler
        ? importer.samplers[gltf::sampler_index(importer.data, sampler)]
        : asset::SAMPLER_LINEAR_REPEAT;
    UvTransform transform = material::UV_TRANSFORM_IDENTITY;
    int uv_set = view.texcoord;
    if (view.has_transform) {
        transform = {
            .offset   = view.transform.offset,
            .scale    = view.transform.scale,
            .rotation = view.transform.rotation,
        };
        if (view.transform.has_texcoord) uv_set = view.transform.texcoord;
    }
    if (uv_set < 0 || uv_set > (int)UV_SET_MAX) return c3d::ASSET_FORMAT_ERROR~;
    return material::texture_slot(
        texture: texture,
        sampler: sampler_id,
        uv_set: (uint)uv_set,
        transform: transform,
    );
}

fn void? convert_materials(Importer* importer) @private {
    foreach (index, &source : importer.data.materials) {
        material::Material converted = convert_material(importer, source)!;
        String key = string::tformat("%s#material/%d", importer.key, index);
        importer.materials[index] = importer.assets.add_material(converted, key)!;
    }
    return;
}

fn MaterialId? default_material(Importer* importer) @private {
    if (importer.default_material.generation) return importer.default_material;
    String key = string::tformat("%s#material/default", importer.key);
    importer.default_material = importer.assets.add_material(material::standard(), key)!;
    return importer.default_material;
}

fn material::Material? convert_material(Importer* importer, gltf::Material* source) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = alpha_mode(source.alpha_mode);
    common.alpha_cutoff = source.alpha_cutoff;
    common.double_sided = source.double_sided != 0;
    if (!math::is_finite(common.alpha_cutoff)) return c3d::ASSET_FORMAT_ERROR~;

    if (source.unlit) {
        BasicParams params = material::BASIC_PARAMS_DEFAULT;
        params.color = source.pbr_metallic_roughness.base_color_factor;
        params.map = texture_slot_for(importer, &source.pbr_metallic_roughness.base_color_texture, true)!;
        if (!unit_rgba(params.color)) return c3d::ASSET_FORMAT_ERROR~;
        return material::basic(params, common);
    }

    StandardParams standard = standard_params(importer, source)!;
    bool physical = source.has_clearcoat || source.has_sheen || source.has_transmission || source.has_volume
        || source.has_ior || source.has_specular || source.has_anisotropy;
    if (!physical) return material::standard(standard, common);

    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.standard = standard;
    params.clearcoat = source.clearcoat.clearcoat_factor;
    params.clearcoat_roughness = source.clearcoat.clearcoat_roughness_factor;
    params.clearcoat_normal_scale = view_scale(&source.clearcoat.clearcoat_normal_texture);
    params.sheen_color = source.sheen.sheen_color_factor;
    params.sheen_roughness = source.sheen.sheen_roughness_factor;
    if (source.has_ior) params.ior = source.ior.ior;
    if (source.has_specular) {
        params.specular = source.specular.specular_factor;
        params.specular_color = source.specular.specular_color_factor;
    }
    params.anisotropy = source.anisotropy.anisotropy_strength;
    params.anisotropy_rotation = source.anisotropy.anisotropy_rotation;
    params.transmission = source.transmission.transmission_factor;
    params.thickness = source.volume.thickness_factor;
    params.attenuation_distance = attenuation_distance(source);
    params.attenuation_color = source.volume.attenuation_color;
    params.clearcoat_map = texture_slot_for(importer, &source.clearcoat.clearcoat_texture, false)!;
    params.clearcoat_roughness_map = texture_slot_for(importer, &source.clearcoat.clearcoat_roughness_texture, false)!;
    params.clearcoat_normal_map = texture_slot_for(importer, &source.clearcoat.clearcoat_normal_texture, false)!;
    params.sheen_color_map = texture_slot_for(importer, &source.sheen.sheen_color_texture, true)!;
    params.sheen_roughness_map = texture_slot_for(importer, &source.sheen.sheen_roughness_texture, false)!;
    params.specular_map = texture_slot_for(importer, &source.specular.specular_texture, false)!;
    params.specular_color_map = texture_slot_for(importer, &source.specular.specular_color_texture, true)!;
    params.anisotropy_map = texture_slot_for(importer, &source.anisotropy.anisotropy_texture, false)!;
    params.transmission_map = texture_slot_for(importer, &source.transmission.transmission_texture, false)!;
    params.thickness_map = texture_slot_for(importer, &source.volume.thickness_texture, false)!;

    bool in_range = unit(params.clearcoat) && unit(params.clearcoat_roughness)
        && math::is_finite(params.clearcoat_normal_scale)
        && unit_rgb(params.sheen_color) && unit(params.sheen_roughness)
        && params.ior >= 1 && math::is_finite(params.ior)
        && unit(params.specular) && nonnegative_finite_rgb(params.specular_color)
        && unit(params.anisotropy) && math::is_finite(params.anisotropy_rotation)
        && unit(params.transmission) && nonnegative_finite(params.thickness)
        && nonnegative_finite(params.attenuation_distance) && unit_rgb(params.attenuation_color);
    if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
    return material::physical(params, common);
}

fn StandardParams? standard_params(Importer* importer, gltf::Material* source) @private {
    gltf::PbrMetallicRoughness* pbr = &source.pbr_metallic_roughness;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = pbr.base_color_factor;
    params.metallic = pbr.metallic_factor;
    params.roughness = pbr.roughness_factor;
    params.emissive = source.emissive_factor;
    params.emissive_strength = source.has_emissive_strength ? source.emissive_strength.emissive_strength : 1;
    params.normal_scale = view_scale(&source.normal_texture);
    params.occlusion_strength = view_scale(&source.occlusion_texture);
    params.base_color_map = texture_slot_for(importer, &pbr.base_color_texture, true)!;
    params.metallic_roughness_map = texture_slot_for(importer, &pbr.metallic_roughness_texture, false)!;
    params.normal_map = texture_slot_for(importer, &source.normal_texture, false)!;
    params.occlusion_map = texture_slot_for(importer, &source.occlusion_texture, false)!;
    params.emissive_map = texture_slot_for(importer, &source.emissive_texture, true)!;

    bool in_range = unit_rgba(params.base_color) && unit(params.metallic) && unit(params.roughness)
        && unit(params.occlusion_strength) && nonnegative_finite_rgb(params.emissive)
        && nonnegative_finite(params.emissive_strength) && math::is_finite(params.normal_scale);
    if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
    return params;
}

fn float view_scale(gltf::TextureView* view) @private {
    return view.texture ? view.scale : 1;
}

fn float attenuation_distance(gltf::Material* source) @private {
    if (!source.has_volume || source.volume.attenuation_distance == float::max) return 0;
    return source.volume.attenuation_distance;
}

fn material::AlphaMode alpha_mode(gltf::AlphaMode mode) @private {
    switch (mode) {
        case OPAQUE: return material::AlphaMode.OPAQUE;
        case MASK: return material::AlphaMode.MASK;
        case BLEND: return material::AlphaMode.BLEND;
        case MAX_ENUM: return material::AlphaMode.OPAQUE;
    }
}

fn camera::Camera? convert_camera(gltf::Camera* source) @private {
    switch (source.type) {
        case PERSPECTIVE:
            gltf::CameraPerspective* lens = &source.perspective;
            float far = lens.has_zfar ? lens.zfar : 0;
            bool in_range = lens.yfov > 0 && math::is_finite(lens.yfov)
                && lens.znear > 0 && math::is_finite(lens.znear)
                && (far == 0 || (far > lens.znear && math::is_finite(far)));
            if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
            camera::Camera camera = camera::perspective(lens.yfov, lens.znear, far);
            if (lens.has_aspect_ratio) {
                if (!(lens.aspect_ratio > 0 && math::is_finite(lens.aspect_ratio))) return c3d::ASSET_FORMAT_ERROR~;
                camera.aspect = lens.aspect_ratio;
            }
            return camera;
        case ORTHOGRAPHIC:
            gltf::CameraOrthographic* lens = &source.orthographic;
            bool in_range = lens.ymag > 0 && math::is_finite(lens.ymag)
                && math::is_finite(lens.znear) && lens.zfar > lens.znear && math::is_finite(lens.zfar);
            if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
            return camera::orthographic(2 * lens.ymag, lens.znear, lens.zfar);
        case INVALID:
        case MAX_ENUM:
            return c3d::ASSET_FORMAT_ERROR~;
    }
}

fn light::Light? convert_light(gltf::Light* source) @private {
    Vec3 color = source.color;
    bool in_range = nonnegative_finite_rgb(color) && nonnegative_finite(source.intensity)
        && nonnegative_finite(source.range);
    if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
    switch (source.type) {
        case DIRECTIONAL:
            return light::directional(color, source.intensity);
        case POINT:
            return light::point(color, source.intensity, source.range);
        case SPOT:
            float inner = source.spot_inner_cone_angle;
            float outer = source.spot_outer_cone_angle;
            if (!(inner >= 0 && inner < outer && outer <= (float)math::PI / 2)) return c3d::ASSET_FORMAT_ERROR~;
            return light::spot(
                color: color,
                intensity: source.intensity,
                inner: inner,
                outer: outer,
                range: source.range,
            );
        case INVALID:
        case MAX_ENUM:
            return c3d::ASSET_FORMAT_ERROR~;
    }
}

fn bool unit(float value) @private {
    return value >= 0 && value <= 1;
}

fn bool unit_rgb(Vec3 color) @private {
    return unit(color.x) && unit(color.y) && unit(color.z);
}

fn bool unit_rgba(Vec4 color) @private {
    return unit(color.x) && unit(color.y) && unit(color.z) && unit(color.w);
}

fn bool nonnegative_finite(float value) @private {
    return value >= 0 && math::is_finite(value);
}

fn bool nonnegative_finite_rgb(Vec3 color) @private {
    return nonnegative_finite(color.x) && nonnegative_finite(color.y) && nonnegative_finite(color.z);
}
