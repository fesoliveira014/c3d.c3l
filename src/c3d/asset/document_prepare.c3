module c3d::asset;

import c3d;
import c3d::anim;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::collections::map;
import std::math;

struct PreparedGeometry @private {
    GeometryShape shape;
    TangentProvenance tangent_provenance;
    Vec4[] normalized_tangents;
    bool joints_u16;
    SkinBounds skin_bounds;
    Aabb[] morph_bounds;
}

struct PreparedModelDocument @private {
    ModelDocument document;
    CoverageStatistics[] textures;
    PreparedGeometry[] geometries;
    HashMap{String, bool} named;
    ulong incoming_items;
    bool all_keys_named;
    bool clip_targets_valid;
}

struct PublicationEstimate @private {
    ulong items_used;
    ulong required_items;
    bool required_exact;
    bool admitted;
}

fn PreparedModelDocument? prepare_model_document(ModelDocument* document) @private {
    PreparedModelDocument prepared = {
        .document = { .allocator = document.allocator },
        .all_keys_named = true,
        .clip_targets_valid = true,
    };
    defer catch destroy_prepared_model_document(&prepared);

    @pool() {
        String[] keys = document_keys(document);
        prepared.named.init(document.allocator, (keys.len ? (sz)keys.len * 2 : 1));

        foreach (key : keys) {
            if (!key.len) {
                prepared.all_keys_named = false;
                continue;
            }

            if (prepared.named.has_key(key)) return c3d::INVALID_ARGUMENT~;

            prepared.named.set(key, true);
        }

        foreach (&entry : document.materials) {
            if (entry.data.kind == MaterialKind.CUSTOM) return c3d::INVALID_ARGUMENT~;
        }

        prepared.textures = alloc::new_array(document.allocator, CoverageStatistics, document.textures.len);

        foreach (index, &entry : document.textures) {
            check_format_use(entry.desc)!;

            switch (entry.source_kind) {
                case MIP_ZERO:
                    if (entry.supplied_mips.len) return c3d::INVALID_ARGUMENT~;

                    prepared.textures[index] = create_coverage_statistics(entry.desc, entry.pixels)!;
                case SUPPLIED_MIPS:
                    if (entry.pixels.len) return c3d::INVALID_ARGUMENT~;
                    (void)check_texture_mips(entry.desc, entry.supplied_mips)!;

                    prepared.textures[index] = texture_statistics_identity(entry.desc, SUPPLIED_MIPS, 0);
                case EMPTY:
                    return c3d::UNSUPPORTED~;
            }
        }

        foreach (&entry : document.clips) check_clip_events(&entry.data)!;

        check_independent_references(document)!;

        foreach (clip : document.template.clips) {
            if (clip.generation) continue;

            foreach (target : document.clips[document_index(clip)].data.targets) {
                if (target >= document.template.nodes.len) prepared.clip_targets_valid = false;
            }
        }

        check_independent_lods(document)!;

        prepared.geometries = alloc::new_array(document.allocator, PreparedGeometry, document.geometries.len);

        foreach (index, &entry : document.geometries) {
            check_influences(&entry.data)!;

            TangentProvenance provenance = entry.tangent_provenance;
            if (provenance.origin != TangentOrigin.GENERATED) {
                provenance = authored_tangent_provenance(&entry.data);
            }

            geometry::check_tangent_stream(&entry.data, provenance)!;

            provenance.derivation_revision = 0;
            prepared.geometries[index] = {
                .shape = build_geometry_shape(document.allocator, &entry.data),
                .tangent_provenance = provenance,
                .joints_u16 = entry.data.joints_exceed_byte(),
                .skin_bounds = geometry::build_skin_bounds(document.allocator, &entry.data),
                .morph_bounds = geometry::build_morph_bounds(document.allocator, &entry.data),
            };
            if (provenance.origin == TangentOrigin.AUTHORED) {
                foreach (tangent : entry.data.tangents) {
                    if (tangent.w == -1 || tangent.w == 1) continue;

                    Vec4[] normalized = copy_slice(document.allocator, entry.data.tangents);

                    foreach (&value : normalized) value.w = value.w < 0 ? -1 : 1;

                    prepared.geometries[index].normalized_tangents = normalized;
                    break;
                }
            }
        }

        prepared.incoming_items = publication_items(
            document: document,
            prepared: &prepared,
            store: null,
            old: {},
        );
    };

    prepared.document = *document;

    *document = { .allocator = document.allocator };

    return prepared;
}

fn void destroy_prepared_model_document(PreparedModelDocument* prepared) @private {
    Allocator allocator = prepared.document.allocator;

    foreach (&derived : prepared.geometries) {
        alloc::free(allocator, derived.normalized_tangents.ptr);
        alloc::free(allocator, derived.shape.target_streams.ptr);
        geometry::free_skin_bounds(allocator, &derived.skin_bounds);
        geometry::free_morph_bounds(allocator, &derived.morph_bounds);
    }

    alloc::free(allocator, prepared.geometries.ptr);
    alloc::free(allocator, prepared.textures.ptr);
    prepared.named.free();
    destroy_model_document(&prepared.document);

    *prepared = { .document = { .allocator = allocator } };
}

macro bool local_reference_valid(id, usz count) @local => id.generation || (id.index > 0 && id.index <= count);

fn void? check_independent_references(ModelDocument* document) @local {
    foreach (mesh : document.template.meshes) {
        if (!local_reference_valid(mesh.geometry, document.geometries.len)
          || !local_reference_valid(mesh.material, document.materials.len)) return c3d::INVALID_ARGUMENT~;
    }
    foreach (skin : document.template.skins) {
        if (!local_reference_valid(skin.skeleton, document.skeletons.len)) return c3d::INVALID_ARGUMENT~;
    }
    foreach (clip : document.template.clips) {
        if (!local_reference_valid(clip, document.clips.len)) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_lod_part_bounds(Aabb bounds, Mat4 local) @local {
    bounds = maths::aabb_transform(bounds, local);
    for (uint axis = 0; axis < 3; axis++) {
        if (!math::is_finite(bounds.min[axis]) || !math::is_finite(bounds.max[axis])
          || bounds.min[axis] > bounds.max[axis]) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_independent_lods(ModelDocument* document) @local {
    ModelTemplate* template = &document.template;
    foreach (index, &group : template.lod_groups) {
        if (group.node >= template.nodes.len) return c3d::INVALID_ARGUMENT~;
        scene::validate_lod_layout(group.desc)!;
        foreach (previous : template.lod_groups[:index]) {
            if (previous.node == group.node) return c3d::INVALID_ARGUMENT~;
        }
        foreach (mesh : template.meshes) {
            if (mesh.node == group.node) return c3d::INVALID_ARGUMENT~;
        }
        foreach (skin : template.skins) {
            if (skin.mesh_node == group.node) return c3d::INVALID_ARGUMENT~;
        }
        foreach (part : group.desc.parts) {
            if (!local_reference_valid(part.geometry, document.geometries.len)
              || !local_reference_valid(part.material, document.materials.len)) return c3d::INVALID_ARGUMENT~;
            if (part.geometry.generation) continue;
            Geometry* geometry = &document.geometries[document_index(part.geometry)].data;
            if (geometry.targets.len || geometry.joints.len) return c3d::INVALID_ARGUMENT~;
            check_lod_part_bounds(geometry.bounds, part.local)!;
        }
    }
}

fn void? check_prepared_references(AssetStore* store, PreparedModelDocument* prepared) @private {
    ModelDocument* document = &prepared.document;
    check_template_references(store, document)!;
    foreach (&group : document.template.lod_groups) {
        foreach (part : group.desc.parts) {
            if (part.geometry.generation) {
                if (!store.geometries.is_live(part.geometry)) return c3d::INVALID_ARGUMENT~;
                GeometryAsset* geometry = store.geometry(part.geometry);
                if (geometry.target_count || geometry.skin_bounds.joints.len || geometry.data.joints.len) {
                    return c3d::INVALID_ARGUMENT~;
                }
                check_lod_part_bounds(geometry.data.bounds, part.local)!;
            }
            if (part.material.generation) {
                if (!store.materials.is_live(part.material)) return c3d::INVALID_ARGUMENT~;
                Material* material = &store.material(part.material).data;
                if (material.kind == MaterialKind.CUSTOM) {
                    if (!store.shaders.is_live(material.custom.shader)) return c3d::INVALID_ARGUMENT~;
                    if (store.shader(material.custom.shader).desc.vertex.shaded.len && !group.desc.has_bounds_override) {
                        return c3d::INVALID_ARGUMENT~;
                    }
                }
            }
        }
    }
}

fn ModelId? publish_prepared_model_document(AssetStore* store, PreparedModelDocument* prepared) @private {
    ModelDocument* document = &prepared.document;
    ModelId model;

    @pool() {
        if (document.key.len && store.keys.has_key(document.key)) return c3d::INVALID_ARGUMENT~;

        prepared.named.@each(; String key, bool value) { check_key(store, key)!; };

        bool fits = store.samplers.free_count >= document.samplers.len
          && store.textures.free_count >= document.textures.len
          && store.materials.free_count >= document.materials.len
          && store.geometries.free_count >= document.geometries.len
          && store.skeletons.free_count >= document.skeletons.len
          && store.clips.free_count >= document.clips.len && store.models.free_count >= 1;
        if (!fits) return c3d::CAPACITY_EXCEEDED~;

        check_prepared_references(store, prepared)!;

        PublishedIds ids = {
            .samplers = alloc::new_array(tmem, SamplerId, document.samplers.len),
            .textures = alloc::new_array(tmem, TextureId, document.textures.len),
            .materials = alloc::new_array(tmem, MaterialId, document.materials.len),
            .geometries = alloc::new_array(tmem, GeometryId, document.geometries.len),
            .skeletons = alloc::new_array(tmem, SkeletonId, document.skeletons.len),
            .clips = alloc::new_array(tmem, ClipId, document.clips.len),
        };

        foreach (index, &entry : document.samplers) ids.samplers[index] = store.add_sampler(entry.desc, entry.key)!!;

        foreach (index, &entry : document.textures) {
            ids.textures[index] = add_prepared_texture(store, entry, prepared.textures[index]);
            entry.pixels = {};
            entry.supplied_mips = {};
        }

        foreach (index, &entry : document.materials) {
            material::@each_texture_reference(&entry.data; TextureId* texture, SamplerId* sampler) {
                *texture = @remapped(*texture, ids.textures);
                if (sampler) *sampler = @remapped(*sampler, ids.samplers);
            };

            ids.materials[index] = store.add_material(entry.data, entry.key)!!;
        }

        foreach (index, &entry : document.geometries) {
            ids.geometries[index] = add_prepared_geometry(
                store: store,
                geometry: &entry.data,
                derived: &prepared.geometries[index],
                key: entry.key,
            );
            entry.data = {};
        }

        foreach (index, &entry : document.skeletons) {
            ids.skeletons[index] = store.add_skeleton_owned(&entry.data, entry.key)!!;
            entry.data = {};
        }

        foreach (index, &entry : document.clips) {
            ids.clips[index] = add_prepared_clip(store, &entry.data, entry.key);
            entry.data = {};
        }

        remap_template(&document.template, &ids);
        model = store.add_model_owned(&document.template, document.key)!!;
        document.template = {};
    };

    destroy_prepared_model_document(prepared);

    return model;
}

fn ModelReplaceReport? replace_prepared_model_document(
    AssetStore* store,
    ModelId model,
    PreparedModelDocument* prepared,
    AssetRef[] missing = {},
) @private {
    if (!store.models.is_live(model)) return c3d::INVALID_ID~;
    ModelReplaceReport report;
    @pool() {
        PublishedIds ids = match_entries(store, model, prepared)!;
        check_replacement(
            store: store,
            model: model,
            prepared: prepared,
            ids: &ids,
        )!;
        report.missing = collect_missing(store, prepared, missing);
        apply_replacement(
            store: store,
            model: model,
            prepared: prepared,
            ids: &ids,
            report: &report,
        );
    };
    destroy_prepared_model_document(prepared);
    return report;
}

fn ulong add_publication_items(ulong first, ulong second) @private {
    return first > ulong::max - second ? ulong::max : first + second;
}

fn ulong publication_items(
    ModelDocument* document,
    PreparedModelDocument* prepared,
    AssetStore* store,
    AssetRef old,
) @private {
    ulong items;
    if (document) {
        items = 1;
        items = add_publication_items(items, document.samplers.len);
        items = add_publication_items(items, document.textures.len);
        items = add_publication_items(items, document.materials.len);
        items = add_publication_items(items, document.geometries.len);
        items = add_publication_items(items, document.skeletons.len);
        items = add_publication_items(items, document.clips.len);
        ModelTemplate* template = &document.template;
        items = add_publication_items(items, template.nodes.len);
        items = add_publication_items(items, template.meshes.len);
        items = add_publication_items(items, template.skins.len);
        items = add_publication_items(items, template.clips.len);
        items = add_publication_items(items, template.lod_groups.len);
        foreach (skin : template.skins) items = add_publication_items(items, skin.joint_nodes.len);
        foreach (group : template.lod_groups) {
            items = add_publication_items(items, group.desc.levels.len);
            items = add_publication_items(items, group.desc.parts.len);
        }
        foreach (&entry : document.geometries) {
            items = add_publication_items(items, entry.data.targets.len);
            items = add_publication_items(items, entry.data.channels.len);
        }
        foreach (&entry : document.skeletons) {
            items = add_publication_items(items, entry.data.parents.len);
            items = add_publication_items(items, entry.data.joint_names.len);
        }
        foreach (&entry : document.clips) {
            items = add_publication_items(items, entry.data.targets.len);
            items = add_publication_items(items, entry.data.tracks.len);
            items = add_publication_items(items, 1);
        }
        items = add_publication_items(items, prepared.named.table.len);
        items = add_publication_items(items, (ulong)prepared.named.len());
        return items;
    }
    items = 1;
    switch (old.kind) {
        case MODEL:
            ModelTemplate* template = &store.models.items[old.id.index].data;
            items = add_publication_items(items, template.nodes.len);
            items = add_publication_items(items, template.meshes.len);
            items = add_publication_items(items, template.skins.len);
            items = add_publication_items(items, template.lod_groups.len);
        case GEOMETRY:
            Geometry* geometry = &store.geometries.items[old.id.index].data;
            items = add_publication_items(items, geometry.targets.len);
            items = add_publication_items(items, geometry.channels.len);
        case SKELETON:
            items = add_publication_items(items, store.skeletons.items[old.id.index].data.joint_names.len);
        case CLIP:
            items = add_publication_items(items, store.clips.items[old.id.index].data.tracks.len);
        case TEXTURE:
        case SAMPLER:
        case MATERIAL:
        case SHADER:
        case COMPUTE_SHADER:
        case ENVIRONMENT:
        case CUSTOM:
        case FONT:
    }
    return items;
}

fn PublicationEstimate estimate_model_publication(
    AssetStore* store,
    PreparedModelDocument* prepared,
    ModelId model,
    ulong allowance,
    bool bounded,
) @private {
    bool live_model = model.generation && store.models.is_live(model);
    ulong estimation = add_publication_items(prepared.named.table.len, (ulong)prepared.named.len());
    if (live_model) estimation = add_publication_items(estimation, 1);
    if (model.generation) {
        estimation = add_publication_items(estimation, store.keys.table.len);
        estimation = add_publication_items(estimation, (ulong)store.keys.len());
    }
    PublicationEstimate estimate = {
        .required_items = add_publication_items(prepared.incoming_items, estimation),
    };
    if (bounded && (estimate.required_items == ulong::max || allowance < estimate.required_items)) return estimate;
    estimate.items_used = estimation;
    ulong attempt = prepared.incoming_items;
    if (live_model) {
        attempt = add_publication_items(attempt, publication_items(
            document: null,
            prepared: null,
            store: store,
            old: typed_ref(AssetKind.MODEL, model),
        ));
    }
    foreach (bucket : prepared.named.table) {
        for (map::Entry{String, bool}* entry = bucket; entry; entry = entry.next) {
            if (!model.generation || entry.key == prepared.document.key) continue;
            if (try old = store.find(entry.key)) {
                if (old.kind == AssetKind.GEOMETRY || old.kind == AssetKind.SKELETON || old.kind == AssetKind.CLIP
                  || old.kind == AssetKind.TEXTURE || old.kind == AssetKind.MATERIAL || old.kind == AssetKind.SAMPLER) {
                    attempt = add_publication_items(attempt, publication_items(
                        document: null,
                        prepared: null,
                        store: store,
                        old: old,
                    ));
                }
            }
        }
    }
    if (model.generation) {
        ulong inventory = add_publication_items(store.keys.table.len, (ulong)store.keys.len());
        attempt = add_publication_items(attempt, inventory);
        foreach (bucket : store.keys.table) {
            for (map::Entry{String, AssetRef}* entry = bucket; entry; entry = entry.next) {
                if (is_missing_part(prepared.document.key, entry.key, &prepared.named)) {
                    attempt = add_publication_items(attempt, 1);
                }
            }
        }
    }
    estimate.required_items = add_publication_items(estimate.items_used, attempt);
    estimate.required_exact = estimate.required_items != ulong::max;
    estimate.admitted = !bounded || (estimate.required_items != ulong::max && estimate.required_items <= allowance);
    return estimate;
}

fn TextureId add_prepared_texture(AssetStore* store, DocumentTexture* entry, CoverageStatistics statistics) @private {
    statistics.revision = 1;

    TextureId id = store.textures.add({})!!;
    *store.textures.get(id) = {
        .header = { .key = copy_string(store.allocator, entry.key), .revision = 1 },
        .desc = entry.desc,
        .source_kind = entry.source_kind,
        .pixels = entry.pixels,
        .supplied_mips = entry.supplied_mips,
        .coverage_statistics = statistics,
    };

    register_key(store, entry.key, typed_ref(AssetKind.TEXTURE, id));

    return id;
}

fn void replace_prepared_texture(
    AssetStore* store,
    TextureId texture,
    DocumentTexture* entry,
    CoverageStatistics statistics,
) @private {
    TextureAsset* record = store.texture(texture);
    statistics.revision = record.header.revision + 1;

    apply_texture(
        allocator: store.allocator,
        record: record,
        desc: entry.desc,
        source_kind: entry.source_kind,
        pixels: entry.pixels,
        supplied_mips: entry.supplied_mips,
        statistics: statistics,
    );
}
