module c3d::asset::gltf;

import c3d;
import c3d::asset;
import gltf;

const usz SOURCE_MATERIAL_SLOT_COUNT @private = 21;

<* Source index absent from the input document. *>
const usz NO_SOURCE_INDEX = usz::max;

<* Source node absent from the decoded template. *>
const usz NO_TEMPLATE_NODE = usz::max;

<* Material and texture-view extensions represented by decoded materials. *>
const String[] SUPPORTED_MATERIAL_EXTENSIONS = {
    "KHR_materials_clearcoat",
    "KHR_materials_sheen",
    "KHR_materials_transmission",
    "KHR_materials_volume",
    "KHR_materials_ior",
    "KHR_materials_specular",
    "KHR_materials_anisotropy",
    "KHR_materials_emissive_strength",
    "KHR_materials_unlit",
    "KHR_texture_transform",
};

<* Encoded source image retained independently of decoded pixels. *>
struct SourceImage {
    char[] encoded;
    String declared_mime_type;
}

<* Original glTF sampler values; zero filters denote unspecified values. *>
struct SourceSampler {
    int min_filter;
    int mag_filter;
    int wrap_s;
    int wrap_t;
}

<* Source image-sampler pairing and its decoded color-space references. *>
struct SourceTexture {
    usz image;
    usz sampler;
    TextureId srgb;
    TextureId linear;
    String[] extensions;
}

<* Source material name, extensions and referenced source textures. *>
struct SourceMaterial {
    String name;
    String[] extensions;
    usz[] textures;
}

<* Independent owner of source indices, encodings and importer metadata. *>
struct SourceRecord {
    Allocator allocator;
    SourceImage[] images;
    SourceSampler[] samplers;
    SourceTexture[] textures;
    SourceMaterial[] materials;
    usz[] texture_images;
    usz[] template_nodes;
    String[] extensions_required;
}

<* Locate a malformed source structure without owning error storage. *>
struct SourceDiagnostic {
    usz material_index;
    usz texture_index;
}

struct SourceSlot @private {
    String block;
    String name;
    gltf::TextureView* view;
}

<*
 Decode one file and retain independent source metadata.
 @param allocator : "Owns the document and separate source record."
 @param [&out] source : "Receives source metadata only on success."
 @param [out] diagnostic : "Optional; reset at entry, set only on failure."
 @param file_source : "Must outlive the call; a null read selects the file system."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require path.len > 0, allocator != tmem
*>
fn ModelDocument? decode_model_with_source(
    Allocator allocator,
    String path,
    SourceRecord* source,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
    SourceDiagnostic* diagnostic = null,
    FileSource file_source = {},
) {
    reset_source_diagnostic(diagnostic);
    return decode_file(
        allocator: allocator,
        path: path,
        options: options,
        file_source: file_source,
        source: source,
        diagnostic: diagnostic,
    );
}

<*
 Decode borrowed bytes and retain independent source metadata.
 @param allocator : "Owns the document and separate source record."
 @param bytes : "Borrowed for the call."
 @param key : "Model key and prefix of every content key."
 @param [&out] source : "Receives source metadata only on success."
 @param [out] diagnostic : "Optional; reset at entry, set only on failure."
 @param file_source : "Must outlive the call; a null read selects the file system."
 @return? c3d::ASSET_IO_ERROR, c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require bytes.len > 0, key.len > 0, allocator != tmem
*>
fn ModelDocument? decode_model_memory_with_source(
    Allocator allocator,
    char[] bytes,
    String base_dir,
    String key,
    SourceRecord* source,
    LoadOptions options = asset::LOAD_OPTIONS_DEFAULT,
    SourceDiagnostic* diagnostic = null,
    FileSource file_source = {},
) {
    reset_source_diagnostic(diagnostic);
    return decode_memory(
        allocator: allocator,
        bytes: bytes,
        base_dir: base_dir,
        key: key,
        options: options,
        file_source: file_source,
        source: source,
        diagnostic: diagnostic,
    );
}

<*
 Release source metadata independently of its decoded document.
 @param [&inout] source : "Cleared after releasing owned arrays."
*>
fn void destroy_source_record(SourceRecord* source) {
    Allocator allocator = source.allocator;
    foreach (image : source.images) {
        alloc::free(allocator, image.encoded.ptr);
        asset::free_string(allocator, image.declared_mime_type);
    }
    foreach (texture : source.textures) free_source_names(allocator, texture.extensions);
    foreach (material : source.materials) {
        asset::free_string(allocator, material.name);
        free_source_names(allocator, material.extensions);
        alloc::free(allocator, material.textures.ptr);
    }
    free_source_names(allocator, source.extensions_required);
    alloc::free(allocator, source.images.ptr);
    alloc::free(allocator, source.samplers.ptr);
    alloc::free(allocator, source.textures.ptr);
    alloc::free(allocator, source.materials.ptr);
    alloc::free(allocator, source.texture_images.ptr);
    alloc::free(allocator, source.template_nodes.ptr);
    *source = {};
}

fn void reset_source_diagnostic(SourceDiagnostic* diagnostic) @private {
    if (diagnostic) *diagnostic = {
        .material_index = NO_SOURCE_INDEX,
        .texture_index = NO_SOURCE_INDEX,
    };
}

fn SourceRecord create_source_record(Importer* importer) @private {
    Allocator allocator = importer.allocator;
    gltf::Data* data = importer.data;
    SourceRecord source = {
        .allocator = allocator,
        .images = alloc::new_array(allocator, SourceImage, data.images.len),
        .samplers = alloc::new_array(allocator, SourceSampler, data.samplers.len),
        .textures = alloc::new_array(allocator, SourceTexture, data.textures.len),
        .materials = alloc::new_array(allocator, SourceMaterial, data.materials.len),
        .texture_images = alloc::new_array(allocator, usz, (sz)importer.document.bounds.textures)[:0],
        .template_nodes = alloc::new_array(allocator, usz, data.nodes.len),
        .extensions_required = alloc::new_array(allocator, String, data.extensions_required.len),
    };
    foreach (index, sampler : data.samplers) source.samplers[index] = {
        .min_filter = (int)sampler.min_filter,
        .mag_filter = (int)sampler.mag_filter,
        .wrap_s = (int)sampler.wrap_s,
        .wrap_t = (int)sampler.wrap_t,
    };
    foreach (index, extension : data.extensions_required) {
        source.extensions_required[index] = copy_name(allocator, extension);
    }
    return source;
}

fn void? finish_source_record(Importer* importer, SourceDiagnostic* diagnostic) @private {
    SourceRecord* source = importer.source;
    gltf::Data* data = importer.data;
    source.template_nodes[..] = importer.node_remap[..];
    foreach (index, texture : data.textures) {
        SourceTexture* entry = &source.textures[index];
        entry.image = texture.image ? gltf::image_index(data, texture.image) : NO_SOURCE_INDEX;
        entry.sampler = texture.sampler ? gltf::sampler_index(data, texture.sampler) : NO_SOURCE_INDEX;
        if (texture.image) {
            entry.srgb = importer.srgb_textures[entry.image];
            entry.linear = importer.linear_textures[entry.image];
        }
    }
    foreach (index, &material : data.materials) {
        SourceMaterial* entry = &source.materials[index];
        entry.name = copy_name(source.allocator, material.name);
        bool[] used = alloc::new_array(tmem, bool, data.textures.len);
        usz count;
        foreach (slot : source_material_slots(material)) {
            if (!slot.view.texture) continue;
            usz texture_index = gltf::texture_index(data, slot.view.texture);
            if (!used[texture_index]) count++;
            used[texture_index] = true;
        }
        entry.textures = alloc::new_array(source.allocator, usz, (sz)count);
        usz next;
        foreach (usz texture_index, is_used : used) if (is_used) entry.textures[next++] = texture_index;
    }
    return inspect_source_extensions(importer, diagnostic);
}

fn void retain_source_image(Importer* importer, usz index, char[] encoded) @private {
    SourceRecord* source = importer.source;
    SourceImage* image = &source.images[index];
    if (image.encoded.len) return;
    image.encoded = alloc::new_array(source.allocator, char, encoded.len);
    image.encoded[..] = encoded[..];
    gltf::Image* original = &importer.data.images[index];
    if (original.mime_type) {
        image.declared_mime_type = copy_name(source.allocator, original.mime_type);
    } else if (original.uri) {
        String uri = original.uri.str_view();
        if (uri.starts_with(DATA_URI_PREFIX)) {
            String type = uri[DATA_URI_PREFIX.len..];
            sz separator = type.index_of_char(';') ?? type.index_of_char(',')!!;
            image.declared_mime_type = asset::copy_string(source.allocator, type[:separator]);
        }
    }
}

fn void free_source_names(Allocator allocator, String[] names) @private {
    foreach (name : names) asset::free_string(allocator, name);
    alloc::free(allocator, names.ptr);
}

fn SourceSlot[SOURCE_MATERIAL_SLOT_COUNT] source_material_slots(gltf::Material* material) @private {
    return {
        { .block = "pbrMetallicRoughness", .name = "baseColorTexture", .view = &material.pbr_metallic_roughness.base_color_texture },
        { .block = "pbrMetallicRoughness", .name = "metallicRoughnessTexture", .view = &material.pbr_metallic_roughness.metallic_roughness_texture },
        { .name = "normalTexture", .view = &material.normal_texture },
        { .name = "occlusionTexture", .view = &material.occlusion_texture },
        { .name = "emissiveTexture", .view = &material.emissive_texture },
        { .block = "KHR_materials_clearcoat", .name = "clearcoatTexture", .view = &material.clearcoat.clearcoat_texture },
        { .block = "KHR_materials_clearcoat", .name = "clearcoatRoughnessTexture", .view = &material.clearcoat.clearcoat_roughness_texture },
        { .block = "KHR_materials_clearcoat", .name = "clearcoatNormalTexture", .view = &material.clearcoat.clearcoat_normal_texture },
        { .block = "KHR_materials_sheen", .name = "sheenColorTexture", .view = &material.sheen.sheen_color_texture },
        { .block = "KHR_materials_sheen", .name = "sheenRoughnessTexture", .view = &material.sheen.sheen_roughness_texture },
        { .block = "KHR_materials_transmission", .name = "transmissionTexture", .view = &material.transmission.transmission_texture },
        { .block = "KHR_materials_volume", .name = "thicknessTexture", .view = &material.volume.thickness_texture },
        { .block = "KHR_materials_specular", .name = "specularTexture", .view = &material.specular.specular_texture },
        { .block = "KHR_materials_specular", .name = "specularColorTexture", .view = &material.specular.specular_color_texture },
        { .block = "KHR_materials_anisotropy", .name = "anisotropyTexture", .view = &material.anisotropy.anisotropy_texture },
        { .block = "KHR_materials_pbrSpecularGlossiness", .name = "diffuseTexture", .view = &material.pbr_specular_glossiness.diffuse_texture },
        { .block = "KHR_materials_pbrSpecularGlossiness", .name = "specularGlossinessTexture", .view = &material.pbr_specular_glossiness.specular_glossiness_texture },
        { .block = "KHR_materials_iridescence", .name = "iridescenceTexture", .view = &material.iridescence.iridescence_texture },
        { .block = "KHR_materials_iridescence", .name = "iridescenceThicknessTexture", .view = &material.iridescence.iridescence_thickness_texture },
        { .block = "KHR_materials_diffuse_transmission", .name = "diffuseTransmissionTexture", .view = &material.diffuse_transmission.diffuse_transmission_texture },
        { .block = "KHR_materials_diffuse_transmission", .name = "diffuseTransmissionColorTexture", .view = &material.diffuse_transmission.diffuse_transmission_color_texture },
    };
}
