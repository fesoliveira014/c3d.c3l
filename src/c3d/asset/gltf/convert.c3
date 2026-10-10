module c3d::asset::gltf;

import c3d;
import c3d::asset;
import c3d::asset::image;
import c3d::camera;
import c3d::light;
import c3d::material;
import gltf;
import std::math;

const String DATA_URI_PREFIX @private = "data:";
const uint UV_SET_MAX @private = 1; // texture_slot accepts UV0 and UV1 only
const char[4] DDS_MAGIC @private = { 'D', 'D', 'S', ' ' };
const char[12] KTX1_MAGIC @private = {
  0xAB, 'K', 'T', 'X', ' ', '1', '1', 0xBB, 0x0D, 0x0A, 0x1A, 0x0A,
};
const char[12] KTX2_MAGIC @private = {
  0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, 0x0D, 0x0A, 0x1A, 0x0A,
};

fn void convert_samplers(Importer* importer) @private {
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
        importer.samplers[index] = importer.document.push_sampler(desc, key);
    }
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

fn TextureId? texture_for(
    Importer* importer,
    gltf::Texture* texture,
    bool srgb,
    TextureSemantic semantic = TextureSemantic.COLOR,
    CoveragePolicy coverage = CoveragePolicy.NONE,
    double alpha_threshold = 0,
) @private {
    if (!texture.image) return texture.has_basisu || texture.has_webp ? c3d::UNSUPPORTED~ : c3d::ASSET_FORMAT_ERROR~;

    usz image_index = gltf::image_index(importer.data, texture.image);
    TextureId[] table = semantic == TextureSemantic.COLOR
      ? (srgb ? importer.srgb_textures : importer.linear_textures) : importer.normal_textures;
    if (coverage == CoveragePolicy.NONE && !c3d::same_id(table[image_index], (TextureId){})) return table[image_index];

    char[] encoded = importer.source ? importer.source.images[image_index].encoded : (char[]){};
    if (!encoded.len) encoded = image_bytes(importer, texture.image)!;

    TextureDesc desc;
    image::Image decoded;
    defer catch image::destroy_image(&decoded);

    image::TextureContainerView container;
    bool supplied;

    if (is_texture_container(encoded)) {
        container = image::parse_texture_container(
            scratch: tmem,
            bytes: encoded,
            color_space: srgb ? image::ColorSpace.SRGB : image::ColorSpace.LINEAR,
            semantic: semantic,
        )!;
        desc = container.desc;
        supplied = !desc.generate_mips;
    } else {
        decoded = image::decode_image(importer.allocator, encoded)!;

        if (decoded.format != RGBA8_UNORM) return c3d::ASSET_FORMAT_ERROR~;

        desc = material::texture_2d_desc(
            width: decoded.width,
            height: decoded.height,
            format: decoded.format == RGBA8_UNORM && srgb ? RGBA8_SRGB : decoded.format,
            debug_name: "gltf_image",
        );
        desc.semantic = semantic;
    }

    desc.debug_name = "gltf_image";

    if (!supplied && coverage_eligible(desc)) {
        desc.coverage = coverage;
        desc.alpha_threshold = alpha_threshold;
    }

    foreach (&variant : importer.texture_variants[:importer.texture_variant_count]) {
        if (variant.image != image_index || variant.semantic != desc.semantic || variant.format != desc.format
            || variant.coverage != desc.coverage || variant.alpha_threshold != desc.alpha_threshold) continue;

        image::destroy_image(&decoded);

        if (desc.coverage == CoveragePolicy.NONE) table[image_index] = variant.texture;

        return variant.texture;
    }

    String key = texture_variant_key(importer, image_index, srgb, desc);
    TextureId id;
    if (supplied) {
        id = importer.document.push_texture_mips(desc, container.levels[:container.level_count], key)!;
    } else {
        char[] pixels = decoded.pixels;
        if (container.level_count) {
            char[] source = container.levels[0].bytes;
            pixels = alloc::new_array(importer.allocator, char, (sz)source.len);
            pixels[..] = source[..];
        }
        id = importer.document.push_texture(desc, pixels, key);
        decoded = {};
    }

    importer.texture_variants[importer.texture_variant_count++] = {
        .image = image_index,
        .semantic = desc.semantic,
        .format = desc.format,
        .coverage = desc.coverage,
        .alpha_threshold = desc.alpha_threshold,
        .texture = id,
    };

    if (desc.coverage == CoveragePolicy.NONE) table[image_index] = id;

    if (importer.source) {
        retain_source_image(importer, image_index, encoded);
        usz count = importer.source.texture_images.len;
        importer.source.texture_images = importer.source.texture_images.ptr[:count + 1];
        importer.source.texture_images[count] = image_index;
    }

    return id;
}

fn bool is_texture_container(char[] bytes) @private {
    if (bytes.len >= DDS_MAGIC.len && bytes[:DDS_MAGIC.len] == DDS_MAGIC[..]) return true;

    return bytes.len >= KTX1_MAGIC.len
      && (bytes[:KTX1_MAGIC.len] == KTX1_MAGIC[..] || bytes[:KTX2_MAGIC.len] == KTX2_MAGIC[..]);
}

fn bool coverage_eligible(TextureDesc desc) @private {
    if (!desc.generate_mips || desc.mip_levels != 1 || desc.depth || desc.storage) return false;
    if (desc.layers != 1 && !desc.is_cube) return false;

    switch (desc.format) {
        case RGBA8_UNORM:
        case RGBA8_SRGB:
        case RGBA16_FLOAT:
        case RGBA32_FLOAT: return true;
        default: return false;
    }
}

fn String texture_variant_key(
    Importer* importer,
    usz image_index,
    bool srgb,
    TextureDesc desc,
) @private {
    String role = srgb ? "srgb" : "linear";

    if (desc.coverage != CoveragePolicy.NONE) {
        ulong threshold = *(ulong*)&desc.alpha_threshold;

        return string::tformat(
            "%s#image/%d/mask/%d/%d/%x",
            importer.key,
            image_index,
            desc.format.ordinal,
            desc.coverage.ordinal,
            threshold,
        );
    }

    switch (desc.semantic) {
        case COLOR: break;
        case NORMAL_RGB: role = string::tformat("normal_rgb/%d", desc.format.ordinal);
        case NORMAL_RG: role = string::tformat("normal_rg/%d", desc.format.ordinal);
    }

    return string::tformat("%s#image/%d/%s", importer.key, image_index, role);
}

fn TextureSemantic normal_semantic(NormalEncoding encoding) @private {
    switch (encoding) {
        case RGB: return TextureSemantic.NORMAL_RGB;
        case RG: return TextureSemantic.NORMAL_RG;
    }
}

fn CoveragePolicy mask_policy(material::AlphaMode mode, float cutoff, float factor) @private {
    if (mode != material::AlphaMode.MASK) return CoveragePolicy.NONE;
    if (cutoff == 0) return CoveragePolicy.ALL_PASS;
    if (factor == 0 || (double)cutoff / factor > 1) return CoveragePolicy.ALL_FAIL;

    return CoveragePolicy.THRESHOLD;
}

fn double mask_threshold(CoveragePolicy policy, float cutoff, float factor) @private {
    return policy == CoveragePolicy.THRESHOLD ? (double)cutoff / factor : 0;
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
    return importer.file_source.read_path(tmem, join_path(importer.base_dir, encoded_uri.str_view()[:length]));
}

fn TextureSlot? texture_slot_for(
    Importer* importer,
    gltf::TextureView* view,
    bool srgb,
    TextureSemantic semantic = TextureSemantic.COLOR,
    CoveragePolicy coverage = CoveragePolicy.NONE,
    double alpha_threshold = 0,
) @private {
    if (!view.texture) return material::texture_slot();

    TextureId texture = texture_for(
        importer: importer,
        texture: view.texture,
        srgb: srgb,
        semantic: semantic,
        coverage: coverage,
        alpha_threshold: alpha_threshold,
    )!;

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
        importer.materials[index] = importer.document.push_material(converted, key);
    }
    return;
}

fn MaterialId default_material(Importer* importer) @private {
    if (!c3d::same_id(importer.default_material, (MaterialId){})) return importer.default_material;
    String key = string::tformat("%s#material/default", importer.key);
    importer.default_material = importer.document.push_material(material::standard(), key);
    return importer.default_material;
}

fn material::Material? convert_material(Importer* importer, gltf::Material* source) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = alpha_mode(source.alpha_mode);
    common.alpha_cutoff = source.alpha_cutoff;
    common.double_sided = source.double_sided != 0;
    if (!math::is_finite(common.alpha_cutoff) || !in_unit_interval(common.alpha_cutoff)) {
        return c3d::ASSET_FORMAT_ERROR~;
    }

    if (source.unlit) {
        BasicParams params = material::BASIC_PARAMS_DEFAULT;
        params.color = source.pbr_metallic_roughness.base_color_factor;

        if (!rgba_in_unit_interval(params.color)) return c3d::ASSET_FORMAT_ERROR~;

        CoveragePolicy coverage = mask_policy(common.alpha_mode, common.alpha_cutoff, params.color.w);
        params.map = texture_slot_for(
            importer: importer,
            view: &source.pbr_metallic_roughness.base_color_texture,
            srgb: true,
            coverage: coverage,
            alpha_threshold: mask_threshold(coverage, common.alpha_cutoff, params.color.w),
        )!;

        return material::basic(params, common);
    }

    StandardParams standard = standard_params(importer, source, common)!;
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
    params.clearcoat_normal_map = texture_slot_for(
        importer: importer,
        view: &source.clearcoat.clearcoat_normal_texture,
        srgb: false,
        semantic: normal_semantic(importer.options.normal_encoding),
    )!;
    params.sheen_color_map = texture_slot_for(importer, &source.sheen.sheen_color_texture, true)!;
    params.sheen_roughness_map = texture_slot_for(importer, &source.sheen.sheen_roughness_texture, false)!;
    params.specular_map = texture_slot_for(importer, &source.specular.specular_texture, false)!;
    params.specular_color_map = texture_slot_for(importer, &source.specular.specular_color_texture, true)!;
    params.anisotropy_map = texture_slot_for(importer, &source.anisotropy.anisotropy_texture, false)!;
    params.transmission_map = texture_slot_for(importer, &source.transmission.transmission_texture, false)!;
    params.thickness_map = texture_slot_for(importer, &source.volume.thickness_texture, false)!;

    bool in_range = in_unit_interval(params.clearcoat) && in_unit_interval(params.clearcoat_roughness)
        && math::is_finite(params.clearcoat_normal_scale)
        && rgb_in_unit_interval(params.sheen_color) && in_unit_interval(params.sheen_roughness)
        && params.ior >= 1 && math::is_finite(params.ior)
        && in_unit_interval(params.specular) && nonnegative_finite_rgb(params.specular_color)
        && in_unit_interval(params.anisotropy) && math::is_finite(params.anisotropy_rotation)
        && in_unit_interval(params.transmission) && nonnegative_finite(params.thickness)
        && nonnegative_finite(params.attenuation_distance) && rgb_in_unit_interval(params.attenuation_color);
    if (!in_range) return c3d::ASSET_FORMAT_ERROR~;

    return material::physical(params, common);
}

fn StandardParams? standard_params(Importer* importer, gltf::Material* source, MaterialCommon common) @private {
    gltf::PbrMetallicRoughness* pbr = &source.pbr_metallic_roughness;
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = pbr.base_color_factor;
    params.metallic = pbr.metallic_factor;
    params.roughness = pbr.roughness_factor;
    params.emissive = source.emissive_factor;
    params.emissive_strength = source.has_emissive_strength ? source.emissive_strength.emissive_strength : 1;
    params.normal_scale = view_scale(&source.normal_texture);
    params.occlusion_strength = view_scale(&source.occlusion_texture);

    if (!rgba_in_unit_interval(params.base_color)) return c3d::ASSET_FORMAT_ERROR~;

    CoveragePolicy coverage = mask_policy(common.alpha_mode, common.alpha_cutoff, params.base_color.w);
    params.base_color_map = texture_slot_for(
        importer: importer,
        view: &pbr.base_color_texture,
        srgb: true,
        coverage: coverage,
        alpha_threshold: mask_threshold(coverage, common.alpha_cutoff, params.base_color.w),
    )!;

    params.metallic_roughness_map = texture_slot_for(importer, &pbr.metallic_roughness_texture, false)!;
    params.normal_map = texture_slot_for(
        importer: importer,
        view: &source.normal_texture,
        srgb: false,
        semantic: normal_semantic(importer.options.normal_encoding),
    )!;
    params.occlusion_map = texture_slot_for(importer, &source.occlusion_texture, false)!;
    params.emissive_map = texture_slot_for(importer, &source.emissive_texture, true)!;

    bool in_range = in_unit_interval(params.metallic) && in_unit_interval(params.roughness)
        && in_unit_interval(params.occlusion_strength) && nonnegative_finite_rgb(params.emissive)
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
            bool in_range = lens.ymag > 0 && math::is_finite(lens.ymag) && lens.xmag > 0 && math::is_finite(lens.xmag)
                && math::is_finite(lens.znear) && lens.zfar > lens.znear && math::is_finite(lens.zfar);
            if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
            camera::Camera converted = camera::orthographic(2 * lens.ymag, lens.znear, lens.zfar);
            converted.aspect = lens.xmag / lens.ymag;
            return converted;
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

fn bool in_unit_interval(float value) @private {
    return value >= 0 && value <= 1;
}

fn bool rgb_in_unit_interval(Vec3 color) @private {
    return in_unit_interval(color.x) && in_unit_interval(color.y) && in_unit_interval(color.z);
}

fn bool rgba_in_unit_interval(Vec4 color) @private {
    return in_unit_interval(color.x) && in_unit_interval(color.y)
        && in_unit_interval(color.z) && in_unit_interval(color.w);
}

fn bool nonnegative_finite(float value) @private {
    return value >= 0 && math::is_finite(value);
}

fn bool nonnegative_finite_rgb(Vec3 color) @private {
    return nonnegative_finite(color.x) && nonnegative_finite(color.y) && nonnegative_finite(color.z);
}
