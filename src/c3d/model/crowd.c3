module c3d::model;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Placement, pose and tint of one crowd instance.
*>
struct CrowdInstance {
    Transform placement;
    CrowdPose pose;
    Vec4      color;
}

<*
 Create a node drawing capacity animated copies of the model; one child batch per skinned part.
 Needs one scene node plus one per skinned part; meshes without a skin are not drawn.
 @param [&in] assets
 @param [&inout] scene
 @param pose_bounds : "Instance-local box covering every pose of one instance."
 @param [in] parent : "Null means the scene root."
 @param name : "Copied into the scene allocator."
 @param trace : "Every part batch's trace flag; traced placements take posed trace slots."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require capacity > 0
*>
fn Node*? add_crowd(
    AssetStore* assets,
    Scene* scene,
    ModelId model,
    uint capacity,
    Aabb pose_bounds,
    CrowdInstance[] instances = {},
    Node* parent = null,
    String name = "",
    bool trace = false,
) {
    ModelTemplate* template = &assets.models.try_get(model)!.data;
    check_crowd_template(template)!;
    check_instances(template, capacity, instances)!;
    Node* root = scene.add_node(parent, name)!;
    defer catch scene.remove(root);
    attach_crowd(
        assets: assets,
        scene: scene,
        node: root,
        model: model,
        capacity: capacity,
        pose_bounds: pose_bounds,
        instances: instances,
        trace: trace,
    )!;
    prepare_crowd(assets, scene, root)!;
    return root;
}

<*
 Attach crowd authoring without creating runtime arrays or part nodes.
 @param [&in] assets : "Resolves the model and clips; unchanged."
 @param [&inout] scene : "Owns copied instance arrays."
 @param [&in] node : "Receives AnimatedCrowd."
 @param pose_bounds : "Instance-local box covering every pose."
 @param trace : "Initial trace flag of each generated part."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require !scene.has(node, AnimatedCrowd)
*>
fn void? attach_crowd(
    AssetStore* assets,
    Scene* scene,
    Node* node,
    ModelId model,
    uint capacity,
    Aabb pose_bounds,
    CrowdInstance[] instances = {},
    bool trace = false,
) {
    if (!capacity) return c3d::INVALID_ARGUMENT~;
    ModelTemplate* template = &assets.models.try_get(model)!.data;
    check_crowd_template(template)!;
    check_instances(template, capacity, instances)!;
    AnimatedCrowd crowd = { .model = model, .pose_bounds = pose_bounds, .trace = trace };
    Allocator allocator = scene.allocator;
    defer catch {
        alloc::free(allocator, crowd.placements.ptr);
        alloc::free(allocator, crowd.poses.ptr);
        alloc::free(allocator, crowd.start_times.ptr);
        alloc::free(allocator, crowd.colors.ptr);
    }
    Transform[]? placements = alloc::new_array_try(allocator, Transform, (sz)capacity);
    if (catch placements) return c3d::CAPACITY_EXCEEDED~;
    crowd.placements = placements;
    CrowdPose[]? poses = alloc::new_array_try(allocator, CrowdPose, (sz)capacity);
    if (catch poses) return c3d::CAPACITY_EXCEEDED~;
    crowd.poses = poses;
    float[]? start_times = alloc::new_array_try(allocator, float, (sz)capacity);
    if (catch start_times) return c3d::CAPACITY_EXCEEDED~;
    crowd.start_times = start_times;
    Vec4[]? colors = alloc::new_array_try(allocator, Vec4, (sz)capacity);
    if (catch colors) return c3d::CAPACITY_EXCEEDED~;
    crowd.colors = colors;
    crowd.placements[..] = maths::TRANSFORM_IDENTITY;
    crowd.poses[..] = { .speed = 1, .loop = true };
    crowd.colors[..] = (Vec4){ 1, 1, 1, 1 };
    fill_crowd(scene, &crowd, instances);
    scene.add(node, crowd);
}

<*
 Prepare crowd runtime atomically; prepared crowds remain unchanged.
 @param [&in] assets : "Owns the model, skeleton and clips."
 @param [&inout] scene : "Owns staged runtime and generated part nodes."
 @param [&in] node : "Carries AnimatedCrowd."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, AnimatedCrowd)
*>
fn void? prepare_crowd(AssetStore* assets, Scene* scene, Node* node) {
    AnimatedCrowd crowd = *scene.get(node, AnimatedCrowd);
    if (crowd.is_prepared()) return;
    ModelTemplate* template = &assets.models.try_get(crowd.model)!.data;
    check_crowd_template(template)!;
    foreach (pose : crowd.poses[:crowd.count]) check_pose(template, pose)!;
    ModelSkin* first = &template.skins[0];
    if (!assets.skeletons.is_live(first.skeleton)) return c3d::INVALID_ID~;
    foreach (clip : template.clips) {
        if (!assets.clips.is_live(clip)) return c3d::INVALID_ID~;
    }
    foreach (&skin : template.skins) {
        ModelMesh* mesh = mesh_of(template, skin.mesh_node)!!;
        if (!assets.geometries.is_live(mesh.geometry) || !assets.materials.is_live(mesh.material)) {
            return c3d::INVALID_ID~;
        }
    }
    uint capacity = (uint)crowd.placements.len;
    foreach (clip : template.clips) crowd.max_tracks = math::max(crowd.max_tracks, (uint)assets.clip(clip).data.tracks.len);
    crowd.joint_count = (uint)first.joint_nodes.len;
    Allocator allocator = scene.allocator;
    defer catch {
        foreach (part : crowd.parts) {
            if (part.batch.generation) scene.remove(scene.node(part.batch));
        }
        alloc::free(allocator, crowd.parts.ptr);
        alloc::free(allocator, crowd.cursors.ptr);
        alloc::free(allocator, crowd.scratch_locals.ptr);
        alloc::free(allocator, crowd.scratch_worlds.ptr);
        alloc::free(allocator, crowd.palettes.ptr);
        alloc::free(allocator, crowd.morph_weights.ptr);
    }
    CrowdPart[]? parts = alloc::new_array_try(allocator, CrowdPart, template.skins.len);
    if (catch parts) return c3d::CAPACITY_EXCEEDED~;
    crowd.parts = parts;
    uint[]? cursors = alloc::new_array_try(allocator, uint, (sz)capacity * crowd.max_tracks);
    if (catch cursors) return c3d::CAPACITY_EXCEEDED~;
    crowd.cursors = cursors;
    Transform[]? locals = alloc::new_array_try(allocator, Transform, template.nodes.len);
    if (catch locals) return c3d::CAPACITY_EXCEEDED~;
    crowd.scratch_locals = locals;
    Mat4[]? worlds = alloc::new_array_try(allocator, Mat4, template.nodes.len);
    if (catch worlds) return c3d::CAPACITY_EXCEEDED~;
    crowd.scratch_worlds = worlds;
    Mat4[]? palettes = alloc::new_array_try(allocator, Mat4, (sz)capacity * crowd.joint_count);
    if (catch palettes) return c3d::CAPACITY_EXCEEDED~;
    crowd.palettes = palettes;
    foreach (usz index, &skin : template.skins) {
        ModelMesh* mesh = mesh_of(template, skin.mesh_node)!!;
        crowd.parts[index] = {
            .template_node = skin.mesh_node,
            .target_count = assets.geometry(mesh.geometry).target_count,
            .target_offset = crowd.morph_stride,
        };
        crowd.morph_stride += crowd.parts[index].target_count;
    }
    if (crowd.morph_stride) {
        float[]? weights = alloc::new_array_try(allocator, float, (sz)capacity * crowd.morph_stride);
        if (catch weights) return c3d::CAPACITY_EXCEEDED~;
        crowd.morph_weights = weights;
    }
    foreach (usz index, &skin : template.skins) {
        ModelMesh* mesh = mesh_of(template, skin.mesh_node)!!;
        Node* part = scene.add_instanced_mesh(
            geometry: mesh.geometry,
            material: mesh.material,
            capacity: capacity,
            parent: node,
            name: template.nodes[skin.mesh_node].name,
        )!;
        InstancedMesh* batch = scene.get(part, InstancedMesh);
        batch.trace = crowd.trace;
        batch.has_bounds_override = true;
        batch.colors[:crowd.count] = crowd.colors[:crowd.count];
        crowd.parts[index].batch = part.id;
    }
    *scene.get(node, AnimatedCrowd) = crowd;
    scene.write_crowd_batches(scene.get(node, AnimatedCrowd));
}

<*
 Prepare pending crowds in a subtree, retaining successful owners.
 @param [&in] assets : "Owns the model, skeleton and clips."
 @param [&inout] scene : "Prepared owners remain unchanged."
 @param [in] root : "Null selects the scene root; root is included."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? prepare_crowd_subtree(AssetStore* assets, Scene* scene, Node* root = null) {
    if (!root) root = scene.root;
    fault failure;
    scene.@each(AnimatedCrowd; entity, crowd) {
        Node* node = scene.node(entity);
        Node* ancestor = node;
        while (ancestor && ancestor != root) ancestor = ancestor.parent;
        if (ancestor) {
            if (catch excuse = prepare_crowd(assets, scene, node)) {
                if (!failure) failure = excuse;
            }
        }
    };
    if (failure) return failure~;
}

<*
 Replace authored instances and starts; update prepared part batches.
 @param [&in] assets
 @param [&inout] scene
 @param [&in] node : "Carries pending or prepared AnimatedCrowd."
 @return? c3d::INVALID_ARGUMENT
 @require scene.has(node, AnimatedCrowd)
 @require assets.models.is_live(scene.get(node, AnimatedCrowd).model)
*>
fn void? set_crowd(
    AssetStore* assets,
    Scene* scene,
    Node* node,
    CrowdInstance[] instances,
) {
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    ModelTemplate* template = &assets.model(crowd.model).data;
    check_instances(template, (uint)crowd.placements.len, instances)!;
    check_track_counts(assets, crowd, instances)!;
    fill_crowd(scene, crowd, instances);
}

fn void? check_crowd_template(ModelTemplate* template) @local {
    if (!template.skins.len) return c3d::INVALID_ARGUMENT~;
    ModelSkin* first = &template.skins[0];
    foreach (&skin : template.skins) {
        if (!c3d::same_id(skin.skeleton, first.skeleton) || !same_joints(skin.joint_nodes, first.joint_nodes)) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (catch mesh_of(template, skin.mesh_node)) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_pose(ModelTemplate* template, CrowdPose pose) @local {
    foreach (clip : template.clips) if (c3d::same_id(clip, pose.clip)) return;
    return c3d::INVALID_ARGUMENT~;
}

fn void? check_track_counts(AssetStore* assets, AnimatedCrowd* crowd, CrowdInstance[] instances) @local {
    if (!crowd.is_prepared()) return;
    foreach (instance : instances) {
        if (!assets.clips.is_live(instance.pose.clip)) continue;
        if (assets.clip(instance.pose.clip).data.tracks.len > crowd.max_tracks) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_instances(ModelTemplate* template, uint capacity, CrowdInstance[] instances) @local {
    if (instances.len > capacity) return c3d::INVALID_ARGUMENT~;
    foreach (instance : instances) check_pose(template, instance.pose)!;
}

fn void fill_crowd(Scene* scene, AnimatedCrowd* crowd, CrowdInstance[] instances) @local {
    crowd.count = (uint)instances.len;
    foreach (usz index, &instance : instances) {
        crowd.placements[index] = instance.placement;
        crowd.poses[index] = instance.pose;
        crowd.start_times[index] = instance.pose.time;
        crowd.colors[index] = instance.color;
    }
    crowd.cursors[..] = 0;
    foreach (&part : crowd.parts) {
        InstancedMesh* batch = scene.world.get(part.batch, InstancedMesh);
        batch.colors[:crowd.count] = crowd.colors[:crowd.count];
    }
    if (crowd.is_prepared()) scene.write_crowd_batches(crowd);
}

fn bool same_joints(uint[] first, uint[] second) @local {
    if (first.len != second.len) return false;
    foreach (index, joint : first) {
        if (joint != second[index]) return false;
    }
    return true;
}

fn ModelMesh*? mesh_of(ModelTemplate* template, uint node) @local {
    foreach (&mesh : template.meshes) {
        if (mesh.node == node) return mesh;
    }
    return NOT_FOUND~;
}
