module c3d::asset;

import c3d;
import c3d::material;
import c3d::scene;
import std::collections::map;
import std::sort;

<*
 Parts a model replacement replaced, added and left in the store unnamed.
*>
struct ModelReplaceReport {
    uint replaced;
    uint added;
    uint missing;
}

struct MissingPart @private {
    AssetRef ref;
    String   key;
}

const Id ADDED_ID @private = { .index = uint::max }; // table slot of an entry that has no record yet

<*
 Replace a model and its keyed parts from a decoded document.
 Decides every fault before the first change; the store is unchanged on a fault.
 @param [&inout] document : "Emptied on success; intact on a fault."
 @param missing : "Receives the first missing parts by kind, then key."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::INCOMPATIBLE_STRUCTURE
 @require self.models.is_live(model)
 @require document.allocator == self.allocator, self.allocator != tmem
*>
fn ModelReplaceReport? AssetStore.replace_document(
    &self,
    ModelId model,
    ModelDocument* document,
    AssetRef[] missing = {},
) {
    PreparedModelDocument prepared = prepare_model_document(document)!;
    defer destroy_prepared_model_document(&prepared);
    ModelReplaceReport? report = replace_prepared_model_document(
        store: self,
        model: model,
        prepared: &prepared,
        missing: missing,
    );
    if (catch excuse = report) {
        *document = prepared.document;
        prepared.document = { .allocator = document.allocator };
        return excuse~;
    }
    return report;
}

fn bool same_model_structure(ModelTemplate* current, ModelTemplate* next) @private {
    if (current.nodes.len != next.nodes.len
        || current.meshes.len != next.meshes.len
        || current.skins.len != next.skins.len
        || current.lod_groups.len != next.lod_groups.len) return false;
    foreach (index, &node : next.nodes) {
        if (current.nodes[index].parent != node.parent) return false;
    }
    // Equal ids name records whose counts the structural rules of their kind hold fixed.
    foreach (index, &mesh : next.meshes) {
        ModelMesh* existing = &current.meshes[index];
        if (existing.node != mesh.node
            || !c3d::same_id(existing.geometry, mesh.geometry)
            || !c3d::same_id(existing.material, mesh.material)) return false;
    }
    foreach (index, &skin : next.skins) {
        ModelSkin* existing = &current.skins[index];
        if (existing.mesh_node != skin.mesh_node
            || !c3d::same_id(existing.skeleton, skin.skeleton)
            || existing.joint_nodes.len != skin.joint_nodes.len) return false;
        foreach (joint, node : skin.joint_nodes) {
            if (existing.joint_nodes[joint] != node) return false;
        }
    }
    foreach (index, &group : next.lod_groups) {
        ModelLodGroup* existing = &current.lod_groups[index];
        if (existing.node != group.node || !same_lod_desc(&existing.desc, &group.desc)) return false;
    }
    return true;
}

fn bool same_lod_desc(LodDesc* first, LodDesc* second) @local {
    if (first.levels.len != second.levels.len
        || first.parts.len != second.parts.len
        || first.has_bounds_override != second.has_bounds_override) return false;
    foreach (index, level : first.levels) {
        LodLevel other = second.levels[index];
        if (level.first_part != other.first_part
            || level.part_count != other.part_count
            || bitcast(level.min_screen_size, uint) != bitcast(other.min_screen_size, uint)) return false;
    }
    foreach (index, part : first.parts) {
        LodPart other = second.parts[index];
        if (!c3d::same_id(part.geometry, other.geometry) || !c3d::same_id(part.material, other.material)) return false;
        for (uint coefficient = 0; coefficient < 16; coefficient++) {
            if (bitcast(part.local.m[coefficient], uint) != bitcast(other.local.m[coefficient], uint)) return false;
        }
    }
    for (uint axis = 0; axis < 3; axis++) {
        if (bitcast(first.local_bounds.min[axis], uint) != bitcast(second.local_bounds.min[axis], uint)
            || bitcast(first.local_bounds.max[axis], uint) != bitcast(second.local_bounds.max[axis], uint)) {
            return false;
        }
    }
    return true;
}

macro bool is_added(id) @private => id.index == ADDED_ID.index && !id.generation;

macro uint count_added(ids) @private {
    uint count;
    foreach (id : ids) {
        if (is_added(id)) count++;
    }
    return count;
}

macro bool is_known_reference(id, usz entry_count, pool) @private {
    if (id.generation) return pool.is_live(id);
    return id.index >= 1 && id.index <= entry_count;
}

fn Id? entry_id(AssetStore* store, String key, AssetKind kind, uint builtin_count = 0) @private {
    AssetRef? found = store.find(key);
    if (catch excuse = found) {
        if (excuse == NOT_FOUND) return ADDED_ID;
        return excuse~;
    }
    if (found.kind != kind || found.id.index < builtin_count) return c3d::INVALID_ARGUMENT~;
    return found.id;
}

fn PublishedIds? match_entries(AssetStore* store, ModelId model, PreparedModelDocument* prepared) @private {
    ModelDocument* document = &prepared.document;
    if (document.key != store.models.get(model).header.key) return c3d::INVALID_ARGUMENT~;
    if (!prepared.all_keys_named) return c3d::INVALID_ARGUMENT~;

    PublishedIds ids = {
        .samplers   = alloc::new_array(tmem, SamplerId, (sz)document.samplers.len),
        .textures   = alloc::new_array(tmem, TextureId, (sz)document.textures.len),
        .materials  = alloc::new_array(tmem, MaterialId, (sz)document.materials.len),
        .geometries = alloc::new_array(tmem, GeometryId, (sz)document.geometries.len),
        .skeletons  = alloc::new_array(tmem, SkeletonId, (sz)document.skeletons.len),
        .clips      = alloc::new_array(tmem, ClipId, (sz)document.clips.len),
    };
    foreach (index, &entry : document.samplers) {
        ids.samplers[index] = (SamplerId)entry_id(store, entry.key, AssetKind.SAMPLER, BUILTIN_SAMPLER_COUNT)!;
    }
    foreach (index, &entry : document.textures) {
        ids.textures[index] = (TextureId)entry_id(store, entry.key, AssetKind.TEXTURE, BUILTIN_TEXTURE_COUNT)!;
    }
    foreach (index, &entry : document.materials) {
        ids.materials[index] = (MaterialId)entry_id(store, entry.key, AssetKind.MATERIAL)!;
    }
    foreach (index, &entry : document.geometries) {
        ids.geometries[index] = (GeometryId)entry_id(store, entry.key, AssetKind.GEOMETRY)!;
    }
    foreach (index, &entry : document.skeletons) {
        ids.skeletons[index] = (SkeletonId)entry_id(store, entry.key, AssetKind.SKELETON)!;
    }
    foreach (index, &entry : document.clips) {
        ids.clips[index] = (ClipId)entry_id(store, entry.key, AssetKind.CLIP)!;
    }
    return ids;
}

fn void? check_replacement(
    AssetStore* store,
    ModelId model,
    PreparedModelDocument* prepared,
    PublishedIds* ids,
) @private {
    ModelDocument* document = &prepared.document;
    check_prepared_references(store, prepared)!;

    foreach (index, &entry : document.textures) {
        if (is_added(ids.textures[index])) continue;
        check_texture_structure(store.texture(ids.textures[index]).desc, entry.desc)!;
    }
    foreach (index, &entry : document.geometries) {
        if (is_added(ids.geometries[index])) continue;
        check_geometry_structure_prepared(
            current: store.geometry(ids.geometries[index]),
            next: &entry.data,
            derived: &prepared.geometries[index].shape,
        )!;
    }
    foreach (index, &entry : document.skeletons) {
        if (is_added(ids.skeletons[index])) continue;
        check_skeleton_structure(&store.skeleton(ids.skeletons[index]).data, &entry.data)!;
    }
    foreach (index, &entry : document.clips) {
        if (is_added(ids.clips[index])) continue;
        AnimationClip* existing = &store.clip(ids.clips[index]).data;
        if (existing.name != entry.data.name) return c3d::INCOMPATIBLE_STRUCTURE~;
        check_clip_structure(existing, &entry.data)!;
    }

    ModelTemplate resolved = resolve_template(&document.template, ids);
    if (!same_model_structure(&store.model(model).data, &resolved)) return c3d::INCOMPATIBLE_STRUCTURE~;
    if (!prepared.clip_targets_valid) return c3d::INVALID_ARGUMENT~;

    bool fits = store.samplers.free_count >= count_added(ids.samplers)
        && store.textures.free_count >= count_added(ids.textures)
        && store.materials.free_count >= count_added(ids.materials)
        && store.geometries.free_count >= count_added(ids.geometries)
        && store.skeletons.free_count >= count_added(ids.skeletons)
        && store.clips.free_count >= count_added(ids.clips);
    if (!fits) return c3d::CAPACITY_EXCEEDED~;
    return;
}

fn void? check_template_references(AssetStore* store, ModelDocument* document) @private {
    ModelTemplate* template = &document.template;
    foreach (&mesh : template.meshes) {
        if (!is_known_reference(mesh.geometry, document.geometries.len, &store.geometries)
            || !is_known_reference(mesh.material, document.materials.len, &store.materials)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    foreach (&skin : template.skins) {
        if (!is_known_reference(skin.skeleton, document.skeletons.len, &store.skeletons)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    foreach (clip : template.clips) {
        if (!is_known_reference(clip, document.clips.len, &store.clips)) return c3d::INVALID_ARGUMENT~;
    }
    return;
}

fn ModelTemplate resolve_template(ModelTemplate* template, PublishedIds* ids) @private {
    ModelTemplate resolved = *template;
    resolved.meshes = copy_slice(tmem, template.meshes);
    resolved.skins = copy_slice(tmem, template.skins);
    resolved.clips = copy_slice(tmem, template.clips);
    resolved.lod_groups = copy_slice(tmem, template.lod_groups);
    foreach (&group : resolved.lod_groups) group.desc.parts = copy_slice(tmem, group.desc.parts);
    remap_template(&resolved, ids);
    return resolved;
}

fn void apply_replacement(
    AssetStore* store,
    ModelId model,
    PreparedModelDocument* prepared,
    PublishedIds* ids,
    ModelReplaceReport* report,
) @private {
    ModelDocument* document = &prepared.document;
    foreach (index, &entry : document.samplers) {
        if (is_added(ids.samplers[index])) {
            ids.samplers[index] = store.add_sampler(entry.desc, entry.key)!!;
            report.added++;
        } else {
            store.replace_sampler(ids.samplers[index], entry.desc);
            report.replaced++;
        }
    }
    foreach (index, &entry : document.textures) {
        if (is_added(ids.textures[index])) {
            ids.textures[index] = add_prepared_texture(store, entry);
            report.added++;
        } else {
            replace_prepared_texture(store, ids.textures[index], entry);
            report.replaced++;
        }
        entry.pixels = {};
    }
    foreach (index, &entry : document.materials) {
        material::@each_texture_reference(&entry.data; TextureId* texture, SamplerId* sampler) {
            *texture = @remapped(*texture, ids.textures);
            if (sampler) *sampler = @remapped(*sampler, ids.samplers);
        };
        if (is_added(ids.materials[index])) {
            ids.materials[index] = store.add_material(entry.data, entry.key)!!;
            report.added++;
        } else {
            store.replace_material(ids.materials[index], entry.data);
            report.replaced++;
        }
    }
    foreach (index, &entry : document.geometries) {
        if (is_added(ids.geometries[index])) {
            ids.geometries[index] = add_prepared_geometry(
                store: store,
                geometry: &entry.data,
                derived: &prepared.geometries[index],
                key: entry.key,
            );
            report.added++;
        } else {
            replace_prepared_geometry(
                store: store,
                geometry: ids.geometries[index],
                source: &entry.data,
                derived: &prepared.geometries[index],
            );
            report.replaced++;
        }
        entry.data = {};
    }
    foreach (index, &entry : document.skeletons) {
        if (is_added(ids.skeletons[index])) {
            ids.skeletons[index] = store.add_skeleton_owned(&entry.data, entry.key)!!;
            report.added++;
        } else {
            replace_prepared_skeleton(store, ids.skeletons[index], &entry.data);
            report.replaced++;
        }
        entry.data = {};
    }
    foreach (index, &entry : document.clips) {
        if (is_added(ids.clips[index])) {
            ids.clips[index] = add_prepared_clip(store, &entry.data, entry.key);
            report.added++;
        } else {
            replace_prepared_clip(store, ids.clips[index], &entry.data);
            report.replaced++;
        }
        entry.data = {};
    }

    remap_template(&document.template, ids);
    ModelAsset* record = store.models.get(model);
    free_model_template(store.allocator, &record.data);
    record.data = document.template;
    document.template = {};
    mark_replaced(&record.header);
}

fn bool is_missing_part(String prefix, String key, HashMap{String, bool}* named) @private {
    return key.len > prefix.len + 1
        && key.starts_with(prefix)
        && key[prefix.len] == '#'
        && !key[prefix.len + 1..].contains_char('#')
        && !named.has_key(key);
}

fn uint collect_missing(AssetStore* store, PreparedModelDocument* prepared, AssetRef[] missing) @private {
    ModelDocument* document = &prepared.document;
    HashMap{String, bool}* named = &prepared.named;

    usz count;
    store.keys.@each(; String key, AssetRef ref) {
        if (is_missing_part(document.key, key, named)) count++;
    };
    MissingPart[] parts = alloc::new_array(tmem, MissingPart, (sz)count);
    usz next;
    store.keys.@each(; String key, AssetRef ref) {
        if (is_missing_part(document.key, key, named)) parts[next++] = { .ref = ref, .key = key };
    };

    sort::mergesort(parts, &compare_missing_parts);
    usz limit = missing.len < parts.len ? missing.len : parts.len;
    for (usz index = 0; index < limit; index++) missing[index] = parts[index].ref;
    return (uint)count;
}

fn int compare_missing_parts(MissingPart first, MissingPart second) @local {
    if (first.ref.kind != second.ref.kind) {
        return first.ref.kind.ordinal < second.ref.kind.ordinal ? -1 : 1;
    }
    return first.key.compare_to(second.key);
}
