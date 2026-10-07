module c3d::asset::gltf;

import c3d;
import c3d::asset;
import gltf;
import std::collections::list;
import std::collections::object;
import std::encoding::json;

alias SourceNames @private = List{String};

fn void? inspect_source_extensions(Importer* importer, SourceDiagnostic* diagnostic) @private {
    Object*? parsed = json::tparse((String)importer.data.json, JsonFlavor.JSON);
    if (catch parsed) return c3d::ASSET_FORMAT_ERROR~;
    if (!parsed.is_map()) return c3d::ASSET_FORMAT_ERROR~;
    Object* materials = source_array(parsed, "materials", importer.data.materials.len)!;
    Object* textures = source_array(parsed, "textures", importer.data.textures.len)!;
    foreach (usz index, &material : importer.data.materials) {
        if (catch excuse = inspect_material_extensions(
            importer: importer,
            material: material,
            index: index,
            object: materials.get_at((sz)index),
            diagnostic: diagnostic,
        )) {
            if (diagnostic) diagnostic.material_index = index;
            return excuse~;
        }
    }
    foreach (usz index, texture : importer.data.textures) {
        SourceNames names;
        names.tinit();
        if (catch excuse = collect_source_extensions(textures.get_at((sz)index), &names)) {
            if (diagnostic) diagnostic.texture_index = index;
            return excuse~;
        }
        importer.source.textures[index].extensions = copy_source_names(importer.allocator, &names);
    }
    return;
}

fn Object*? source_array(Object* root, String name, usz expected) @private {
    Object* array = root.get(name) ?? null;
    if (!array) {
        if (expected) return c3d::ASSET_FORMAT_ERROR~;
        return null;
    }
    if (!array.is_array() || (usz)array.len() != expected) return c3d::ASSET_FORMAT_ERROR~;
    return array;
}

fn void? inspect_material_extensions(
    Importer* importer,
    gltf::Material* material,
    usz index,
    Object* object,
    SourceDiagnostic* diagnostic,
) @private {
    SourceNames names;
    names.tinit();
    collect_source_extensions(object, &names)!;
    foreach (slot : source_material_slots(material)) {
        Object* block = source_slot_block(object, slot.block)!;
        Object* info = block ? block.get(slot.name) ?? null : null;
        usz texture_index = slot.view.texture
            ? gltf::texture_index(importer.data, slot.view.texture) : NO_SOURCE_INDEX;
        bool matches = (info != null) == (slot.view.texture != null);
        if (info) {
            if (!info.is_map()) {
                matches = false;
            } else {
                Object* value = info.get("index") ?? null;
                matches &= value && value.is_int() && value.i >= 0 && (usz)value.i == texture_index;
            }
        }
        if (!matches) {
            if (diagnostic) diagnostic.texture_index = texture_index;
            return c3d::ASSET_FORMAT_ERROR~;
        }
        if (info) {
            if (catch excuse = collect_source_extensions(info, &names)) {
                if (diagnostic) diagnostic.texture_index = texture_index;
                return excuse~;
            }
        }
    }
    importer.source.materials[index].extensions = copy_source_names(importer.allocator, &names);
    return;
}

fn Object*? source_slot_block(Object* material, String block) @private {
    if (!block.len) return material;
    Object* parent = material;
    if (block.starts_with("KHR_")) {
        parent = material.get("extensions") ?? null;
        if (!parent) return null;
        if (!parent.is_map()) return c3d::ASSET_FORMAT_ERROR~;
    }
    Object* result = parent.get(block) ?? null;
    if (result && !result.is_map()) return c3d::ASSET_FORMAT_ERROR~;
    return result;
}

fn void? collect_source_extensions(Object* object, SourceNames* names) @private {
    if (!object.is_map()) return c3d::ASSET_FORMAT_ERROR~;
    Object* extensions = object.get("extensions") ?? null;
    if (!extensions) return;
    if (!extensions.is_map()) return c3d::ASSET_FORMAT_ERROR~;
    extensions.@each_entry(; String name, Object* value) {
        sz insertion;
        while (insertion < names.len() && (*names)[insertion].compare_to(name) < 0) insertion++;
        if (insertion == names.len() || (*names)[insertion] != name) names.insert_at(insertion, name);
    };
    return;
}

fn String[] copy_source_names(Allocator allocator, SourceNames* names) @private {
    String[] copied = alloc::new_array(allocator, String, names.len());
    foreach (index, name : *names) copied[index] = asset::copy_string(allocator, name);
    return copied;
}
