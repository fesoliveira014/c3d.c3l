module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import c3d::spatial;
import std::math;

<*
 Slot bits the sort key gives each of the material and geometry ids.
*>
const uint SORT_KEY_SLOT_BITS = 16; // slots past 65535 alias in the key; ordering still holds within a slot

const uint SORT_KEY_PIPELINE_SHIFT @private = 48;
const uint SORT_KEY_MATERIAL_SHIFT @private = 32;
const uint SORT_KEY_GEOMETRY_SHIFT @private = 16;
const uint SHADER_FLAG_SHIFT @private = 8; // ShaderVariant.flags start at bit 8; the shader ordinal fills the byte below

<*
 Per-view list a material's draws belong to.
*>
enum DrawList {
    GBUFFER,
    OPAQUE,
    SCENE_READ,
    TRANSPARENT,
}

<*
 Mesh or batch range with bounds in the view's coordinate space.
*>
struct MeshCandidate {
    Node*          node;
    GeometryId     geometry;
    MaterialId     material;
    SkinBinding*   skin;
    float[]        morph_weights;
    MorphChannel[] morph_channels;
    Aabb           world_bounds;
    float          ndc_depth;
    float          view_depth;
    bool           receive_shadow;
    InstancedMesh* batch;
    BillboardBatch* billboards;
    ulong          scene_identity;
    AnimatedCrowd* crowd;
    uint           crowd_part;
    uint           instance_first;
    uint           instance_count;
    bool           mirrored;
    LodSelection*  lod;
    uint           lod_level;
    uint           lod_part;
    bool           impostor;
    bool           vertex_motion;
}

<*
 What extraction saw and why meshes were left out.
*>
struct ExtractCounts {
    uint visible;
    uint culled;
    uint dangling;
    uint batches_faded; // bound wholly past the batch's fade band from the view camera
    uint[scene::MAX_LOD_CHOICES] lod_objects_visible;
}

<*
 Meshes and batches of the scene inside the camera's frustum and layers, in component order.
 @param allocator : "Owns the returned array."
 @param [&inout] scene : "Pose as left by the last update_world; only batch aggregates are written."
 @param [&in] assets : "Resolves geometry bounds."
 @param [&in] camera : "Frustum, view-projection and fade origin of the view."
 @param layers : "Camera layer mask."
 @param [&inout] counts : "Zeroed first, then accumulated."
 @param clip_plane : "Culls bounds wholly on its negative side; zero culls nothing."
 @param lod : "View selections indexed by scene node slot."
 @param origin : "Absolute origin shared by camera and clip plane."
*>
fn MeshCandidate[] extract_candidates(
    Allocator allocator,
    Scene* scene,
    AssetStore* assets,
    CameraMatrices* camera,
    uint layers,
    ExtractCounts* counts,
    Plane clip_plane = {},
    LodSelection[] lod = {},
    Vec3 origin = {},
) {
    *counts = {};
    // Every emitted candidate is written whole before the slice is returned, so the array needs no zeroing.
    MeshCandidate[] candidates = alloc::alloc_array(allocator, MeshCandidate, candidate_capacity(scene));
    Frustum clip_frustum = { .planes = { [0] = clip_plane }, .plane_count = 1 };
    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective && (layers & node.layers) != 0) {
            include_mesh(
                candidates:   candidates,
                scene:        scene,
                node:         node,
                mesh:         mesh,
                assets:       assets,
                camera:       camera,
                clip_frustum: &clip_frustum,
                counts:       counts,
                origin:       origin,
            );
        }
    };
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        Node* node = scene.node(entity);
        if (batch.count && node.visible_effective && (layers & node.layers) != 0) {
            include_batch(
                candidates:   candidates,
                scene:        scene,
                node:         node,
                batch:        batch,
                assets:       assets,
                camera:       camera,
                clip_frustum: &clip_frustum,
                counts:       counts,
                origin:       origin,
            );
        }
    };
    scene.@each(BillboardBatch; Entity entity, BillboardBatch* batch) {
        Node* node = scene.node(entity);
        if (batch.count && node.visible_effective && (layers & node.layers)) {
            include_billboards(
                candidates: candidates,
                scene: scene,
                node: node,
                batch: batch,
                assets: assets,
                camera: camera,
                clip_frustum: &clip_frustum,
                counts: counts,
                origin: origin,
            );
        }
    };
    foreach (&selection : lod) {
        if (!selection.state) continue;
        if (!(layers & selection.node.layers)) continue;
        if (!maths::frustum_intersects_aabb(&camera.frustum, selection.world_bounds)
          || !maths::frustum_intersects_aabb(&clip_frustum, selection.world_bounds)) {
            counts.culled++;
            continue;
        }
        if (past_fade_band(selection.state.effects.fade, selection.world_bounds, camera.position)) {
            counts.batches_faded++;
            continue;
        }
        emit_lod_candidates(
            candidates: candidates,
            selection: selection,
            assets: assets,
            camera: camera,
            counts: counts,
            shadow: false,
        );
        if (selection.state.mode == LodMode.SINGLE) counts.lod_objects_visible[selection.level]++;
    }
    return candidates[:counts.visible];
}

<*
 Whether the batch's material can draw instanced; false for a dead custom shader.
 @param [&in] assets : "Store the ids were issued by."
 @param [&in] batch : "Live material id."
*>
fn bool instanced_material_drawable(AssetStore* assets, InstancedMesh* batch) {
    Material* material = &assets.material(batch.material).data;
    if (material.kind != MaterialKind.CUSTOM) return true;
    if (!assets.shaders.is_live(material.custom.shader)) return false;
    CustomVertex* vertex = &assets.shader(material.custom.shader).desc.vertex;
    return !vertex.shaded.len || vertex.instanced_shaded.len;
}

<*
 Select the draw list: transmission, blend, scene readers, else opaque.
 @param [&in] material : "Valid active arm."
 @param custom_reads : "Scene reads of the custom material's published shader."
 @pure
*>
fn DrawList draw_list(Material* material, SceneReads custom_reads = {}) {
    if (material.kind == MaterialKind.PHYSICAL && material.physical.transmission > 0) {
        return DrawList.SCENE_READ;
    }
    if (material.common.alpha_mode == AlphaMode.BLEND) return DrawList.TRANSPARENT;
    return material_scene_reads(material, custom_reads) != (SceneReads){} ? DrawList.SCENE_READ : DrawList.OPAQUE;
}

<*
 Scene snapshots one draw of the material samples.
 @param [&in] material : "Valid active arm."
 @param custom_reads : "Scene reads of the custom material's published shader."
 @pure
*>
fn SceneReads material_scene_reads(Material* material, SceneReads custom_reads = {}) {
    switch (material.kind) {
        case PHYSICAL: return { .color = material.physical.transmission > 0 };
        case CUSTOM: return custom_reads;
        case BASIC:
        case STANDARD:
        case TOON: return {};
    }
}

<*
 Whether the G-buffer encodes the material without loss.
 @param [&in] material : "Valid active arm."
 @param custom_gbuffer : "The custom material's shader supplies a G-buffer stage."
 @pure
*>
fn bool gbuffer_encodable(Material* material, bool custom_gbuffer = false) {
    if (material.common.alpha_mode == AlphaMode.BLEND) return false;
    switch (material.kind) {
        case BASIC:
        case TOON:
            return false;
        case CUSTOM:
            return custom_gbuffer;
        case STANDARD:
            return true;
        case PHYSICAL:
            PhysicalParams* physical = &material.physical;
            return physical.clearcoat == 0 && physical.sheen_color == (Vec3){}
                && physical.anisotropy == 0 && physical.transmission == 0
                && physical.ior == 1.5f && physical.specular_color == (Vec3){ 1, 1, 1 }
                && physical.specular_color_map.texture.kind == TextureRefKind.ASSET
                && physical.specular_color_map.texture.asset.generation == 0;
    }
}

<*
 Select the draw list on a view of the shading path; a forward view never selects GBUFFER.
 @param [&in] material : "Valid active arm."
 @param custom_gbuffer : "The custom material's shader supplies a G-buffer stage."
 @param custom_reads : "Scene reads of the custom material's published shader."
 @pure
*>
fn DrawList view_draw_list(
    Material* material,
    ShadingPath shading,
    bool custom_gbuffer = false,
    SceneReads custom_reads = {},
) {
    DrawList list = draw_list(material, custom_reads);
    if (shading == ShadingPath.DEFERRED && list == DrawList.OPAQUE && gbuffer_encodable(material, custom_gbuffer)) {
        return DrawList.GBUFFER;
    }
    return list;
}

<*
 Ordering key: pipeline, material, geometry, then front to back.
 @param vertex : "Its flags distinguish deformed pipelines."
 @param fragment : "Zero for a custom material, whose shader id takes its place."
 @param ndc_depth : "Reverse-Z depth of the bounds center, clamped to [0, 1]."
 @param custom : "Store shader of a custom material; zero otherwise."
*>
fn ulong draw_sort_key(
    ShaderVariant vertex,
    ShaderVariant fragment,
    MaterialId material,
    GeometryId geometry,
    float ndc_depth,
    ShaderId custom = {},
) {
    ulong slot_mask = (1UL << SORT_KEY_SLOT_BITS) - 1;
    ulong depth = (ulong)(ushort)((1.0f - ndc_depth) * (float)ushort::max);
    ulong stage = custom.generation ? (ulong)custom.index : (ulong)fragment.shader.ordinal;
    ulong pipeline = stage | (ulong)vertex.flags << SHADER_FLAG_SHIFT;
    return (pipeline & slot_mask) << SORT_KEY_PIPELINE_SHIFT
        | ((ulong)material.index & slot_mask) << SORT_KEY_MATERIAL_SHIFT
        | ((ulong)geometry.index & slot_mask) << SORT_KEY_GEOMETRY_SHIFT
        | depth;
}

fn void include_mesh(
    MeshCandidate[] candidates,
    Scene* scene,
    Node* node,
    Mesh* mesh,
    AssetStore* assets,
    CameraMatrices* camera,
    Frustum* clip_frustum,
    ExtractCounts* counts,
    Vec3 origin,
) @local {
    SkinBinding* skin = scene.get(node, SkinBinding);
    if (!spatial::mesh_is_live(assets, mesh, skin)) {
        counts.dangling++;
        return;
    }
    Aabb world = spatial::mesh_world_bounds(
        assets: assets,
        node:   node,
        mesh:   mesh,
        skin:   skin,
        origin: origin,
    );
    if (!maths::frustum_intersects_aabb(&camera.frustum, world)
        || !maths::frustum_intersects_aabb(clip_frustum, world)) {
        counts.culled++;
        return;
    }
    candidates[counts.visible] = {
        .node           = node,
        .geometry       = mesh.geometry,
        .material       = mesh.material,
        .skin           = skin,
        .morph_weights  = morph_weights_of(assets, mesh),
        .morph_channels = assets.geometry(mesh.geometry).data.channels,
        .world_bounds   = world,
        .ndc_depth      = center_depth(camera, world),
        .view_depth     = center_view_depth(camera, world),
        .receive_shadow = mesh.receive_shadow,
        .instance_count = 1,
        .vertex_motion  = mesh.vertex_motion,
    };
    counts.visible++;
}

fn void include_billboards(
    MeshCandidate[] candidates,
    Scene* scene,
    Node* node,
    BillboardBatch* batch,
    AssetStore* assets,
    CameraMatrices* camera,
    Frustum* clip_frustum,
    ExtractCounts* counts,
    Vec3 origin,
) @local {
    if (!spatial::billboard_batch_is_live(assets, batch)) {
        counts.dangling++;
        return;
    }
    Aabb world = spatial::billboard_world_bounds(node, batch, origin);
    if (!maths::frustum_intersects_aabb(&camera.frustum, world)
        || !maths::frustum_intersects_aabb(clip_frustum, world)) {
        counts.culled++;
        return;
    }
    candidates[counts.visible++] = {
        .node = node,
        .material = batch.material,
        .world_bounds = world,
        .ndc_depth = center_depth(camera, world),
        .view_depth = center_view_depth(camera, world),
        .billboards = batch,
        .scene_identity = scene.identity,
        .instance_count = batch.count,
    };
}

fn void include_batch(
    MeshCandidate[] candidates,
    Scene* scene,
    Node* node,
    InstancedMesh* batch,
    AssetStore* assets,
    CameraMatrices* camera,
    Frustum* clip_frustum,
    ExtractCounts* counts,
    Vec3 origin,
) @local {
    if (!batch_is_drawable(assets, batch)) {
        counts.dangling++;
        return;
    }
    batch.validate_effects();
    Aabb world = spatial::instanced_world_bounds(
        assets: assets,
        node: node,
        batch: batch,
        origin: origin,
    );
    if (!maths::frustum_intersects_aabb(&camera.frustum, world)
        || !maths::frustum_intersects_aabb(clip_frustum, world)) {
        counts.culled++;
        return;
    }
    if (past_fade_band(batch.fade, world, camera.position)) {
        counts.batches_faded++;
        return;
    }
    MeshCandidate template = {
        .node           = node,
        .geometry       = batch.geometry,
        .material       = batch.material,
        .world_bounds   = world,
        .ndc_depth      = center_depth(camera, world),
        .view_depth     = center_view_depth(camera, world),
        .receive_shadow = batch.receive_shadow,
        .batch          = batch,
        .scene_identity = scene.identity,
    };
    attach_crowd(scene, &template);
    emit_batch_candidates(candidates, counts, template);
}

<*
 Mark a batch candidate as a crowd part when its parent node carries the crowd.
 @param [&in] scene
 @param [&inout] candidate : "A batch candidate."
*>
fn void attach_crowd(Scene* scene, MeshCandidate* candidate) {
    Node* parent = candidate.node.parent;
    if (!scene.has(parent, AnimatedCrowd)) return;
    AnimatedCrowd* crowd = scene.get(parent, AnimatedCrowd);
    foreach (uint index, &part : crowd.parts) {
        if (!c3d::same_id(part.batch, candidate.node.id)) continue;
        candidate.crowd = crowd;
        candidate.crowd_part = index;
        return;
    }
}

// Every anchor lies inside the bound and no vanish distance exceeds end, so no instance of the batch is drawn.
fn bool past_fade_band(InstanceFade fade, Aabb world_bounds, Vec3 fade_origin) @local {
    if (fade.end == 0) return false;
    Vec3 nearest = math::clamp(fade_origin, world_bounds.min, world_bounds.max);
    return nearest.distance(fade_origin) > fade.end;
}

fn bool batch_is_drawable(AssetStore* assets, InstancedMesh* batch) @local {
    return spatial::instanced_mesh_is_live(assets, batch) && instanced_material_drawable(assets, batch);
}

fn void emit_batch_candidates(MeshCandidate[] candidates, ExtractCounts* counts, MeshCandidate template) @local {
    uint mirrored = template.crowd ? template.crowd.part_mirrored_count(template.crowd_part)
      : template.batch.mirrored_count();
    uint unmirrored = template.batch.count - mirrored;
    if (unmirrored) {
        candidates[counts.visible] = template;
        candidates[counts.visible].instance_count = unmirrored;
        counts.visible++;
    }
    if (mirrored) {
        candidates[counts.visible] = template;
        candidates[counts.visible].instance_first = unmirrored;
        candidates[counts.visible].instance_count = mirrored;
        candidates[counts.visible].mirrored = true;
        counts.visible++;
    }
}

fn sz candidate_capacity(Scene* scene) @local {
    sz capacity = (sz)scene.count(Mesh) + 2 * (sz)scene.count(InstancedMesh) + (sz)scene.count(BillboardBatch);
    scene.@each(LodGroup; entity, group) { capacity += 2 * (group.state.desc.parts.len + 1); };
    return capacity;
}

fn void emit_lod_candidates(
    MeshCandidate[] candidates,
    LodSelection* selection,
    AssetStore* assets,
    CameraMatrices* camera,
    ExtractCounts* counts,
    bool shadow,
) @local {
    LodGroupState* state = selection.state;
    bool instanced = state.mode == LodMode.INSTANCED;
    uint first = instanced ? 0 : selection.level;
    uint end = instanced && !selection.fallback ? (uint)state.desc.levels.len + (selection.impostor ? 1 : 0) : first + 1;
    for (uint selected = first; selected < end; selected++) {
        LodLevel level = selected_lod_level(selection, selected);
        bool impostor = selected == state.desc.levels.len;
        for (uint index = 0; index < level.part_count; index++) {
            LodPart part = state.desc.parts[impostor ? 0 : level.first_part + index];
            if (!impostor && shadow && assets.material(part.material).data.common.alpha_mode == AlphaMode.BLEND) continue;
            uint parities = instanced ? 2 : 1;
            for (uint parity = 0; parity < parities; parity++) {
                uint count = instanced ? (parity == 0 ? selection.instances.lod_unmirrored_count : state.count - selection.instances.lod_unmirrored_count) : 1;
                if (!count) continue;
                candidates[counts.visible++] = {
                    .node = selection.node,
                    .geometry = part.geometry,
                    .material = part.material,
                    .world_bounds = selection.world_bounds,
                    .ndc_depth = camera ? center_depth(camera, selection.world_bounds) : 0,
                    .view_depth = camera ? center_view_depth(camera, selection.world_bounds) : 0,
                    .receive_shadow = state.effects.receive_shadow,
                    .instance_count = count,
                    .mirrored = parity != 0,
                    .scene_identity = selection.scene_identity,
                    .lod = selection,
                    .lod_level = selected,
                    .lod_part = level.first_part + index,
                    .impostor = impostor,
                };
            }
        }
    }
}

fn float[] morph_weights_of(AssetStore* assets, Mesh* mesh) @local {
    return assets.geometry(mesh.geometry).target_count ? mesh.morph_weights : (float[]){};
}

fn float center_view_depth(CameraMatrices* camera, Aabb world) @local {
    Vec3 center = (world.min + world.max) * 0.5f;
    return -camera.view.apply({ center.x, center.y, center.z, 1.0f }).z;
}

<*
 Order transparent bounds centers from far to near, then entity identity, then instance range.
 @param first : "Live candidate with finite view depth."
 @param second : "Live candidate with finite view depth."
 @return "Negative when first orders earlier."
 @pure
*>
fn int compare_transparent_candidates(MeshCandidate first, MeshCandidate second) {
    if (first.view_depth > second.view_depth) return -1;
    if (first.view_depth < second.view_depth) return 1;
    if (first.node.id.index < second.node.id.index) return -1;
    if (first.node.id.index > second.node.id.index) return 1;
    if (first.node.id.generation < second.node.id.generation) return -1;
    if (first.node.id.generation > second.node.id.generation) return 1;
    if (first.instance_first < second.instance_first) return -1;
    return first.instance_first > second.instance_first ? 1 : 0;
}

fn float center_depth(CameraMatrices* camera, Aabb world) @local {
    Vec3 center = (world.min + world.max) * 0.5f;
    Vec4 clip = camera.view_proj.apply({ center.x, center.y, center.z, 1.0f });
    // A center on or behind the camera plane sorts as nearest; its box still straddles the near plane.
    return clip.w > 0 ? math::clamp(clip.z / clip.w, 0.0f, 1.0f) : 1.0f;
}

<*
 Collect live visible mesh and batch casters independently of layer masks.
 @param allocator : "Owns the returned candidate array."
 @param [&inout] scene : "Current transforms; only batch aggregates are written."
 @param [&in] assets : "Supplies live ids and retained geometry bounds."
 @param fade_origin : "View camera position batch fades are measured from."
 @param [&inout] counts : "Reset, then populated for broad caster inclusion."
 @param lod : "Parent view selections indexed by scene node slot."
 @param origin : "Absolute origin of bounds and fade coordinates."
*>
fn MeshCandidate[] extract_shadow_candidates(
    Allocator allocator,
    Scene* scene,
    AssetStore* assets,
    Vec3 fade_origin,
    ExtractCounts* counts,
    LodSelection[] lod = {},
    Vec3 origin = {},
) {
    *counts = {};
    MeshCandidate[] candidates = alloc::alloc_array(allocator, MeshCandidate, candidate_capacity(scene));

    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective && mesh.cast_shadow) {
            SkinBinding* skin = scene.get(node, SkinBinding);
            if (!spatial::mesh_is_live(assets, mesh, skin)) {
                counts.dangling++;
            } else {
                Material* material = &assets.material(mesh.material).data;
                if (material.common.alpha_mode != AlphaMode.BLEND) {
                    candidates[counts.visible++] = {
                        .node           = node,
                        .geometry       = mesh.geometry,
                        .material       = mesh.material,
                        .skin           = skin,
                        .morph_weights  = morph_weights_of(assets, mesh),
                        .morph_channels = assets.geometry(mesh.geometry).data.channels,
                        .world_bounds   = spatial::mesh_world_bounds(
                            assets: assets,
                            node:   node,
                            mesh:   mesh,
                            skin:   skin,
                            origin: origin,
                        ),
                        .receive_shadow = mesh.receive_shadow,
                        .instance_count = 1,
                    };
                }
            }
        }
    };
    scene.@each(InstancedMesh; Entity entity, InstancedMesh* batch) {
        Node* node = scene.node(entity);
        if (batch.count && node.visible_effective && batch.cast_shadow) {
            if (!batch_is_drawable(assets, batch)) {
                counts.dangling++;
            } else if (assets.material(batch.material).data.common.alpha_mode != AlphaMode.BLEND) {
                batch.validate_effects();
                Aabb world = spatial::instanced_world_bounds(
                    assets: assets,
                    node: node,
                    batch: batch,
                    origin: origin,
                );
                if (past_fade_band(batch.fade, world, fade_origin)) {
                    counts.batches_faded++;
                } else {
                    MeshCandidate template = {
                        .node           = node,
                        .geometry       = batch.geometry,
                        .material       = batch.material,
                        .world_bounds   = world,
                        .receive_shadow = batch.receive_shadow,
                        .batch          = batch,
                        .scene_identity = scene.identity,
                    };
                    attach_crowd(scene, &template);
                    emit_batch_candidates(candidates, counts, template);
                }
            }
        }
    };

    foreach (&selection : lod) {
        if (!selection.state || !selection.state.effects.cast_shadow) continue;
        if (past_fade_band(selection.state.effects.fade, selection.world_bounds, fade_origin)) continue;
        emit_lod_candidates(
            candidates: candidates,
            selection: selection,
            assets: assets,
            camera: null,
            counts: counts,
            shadow: true,
        );
    }
    return candidates[:counts.visible];
}
