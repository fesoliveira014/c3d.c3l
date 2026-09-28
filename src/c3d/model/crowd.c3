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
) {
    ModelTemplate* template = &assets.models.try_get(model)!.data;
    if (!template.skins.len) return c3d::INVALID_ARGUMENT~;
    ModelSkin* first = &template.skins[0];
    foreach (&skin : template.skins) {
        if (!c3d::same_id(skin.skeleton, first.skeleton) || !same_joints(skin.joint_nodes, first.joint_nodes)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    check_instances(template, capacity, instances)!;
    foreach (&skin : template.skins) {
        if (catch mesh_of(template, skin.mesh_node)) return c3d::INVALID_ARGUMENT~;
    }

    uint max_tracks;
    foreach (clip : template.clips) max_tracks = math::max(max_tracks, (uint)assets.clip(clip).data.tracks.len);
    Allocator allocator = scene.allocator;
    Node* root = scene.add_node(parent, name)!;
    defer catch scene.remove(root);

    AnimatedCrowd crowd = {
        .model          = model,
        .joint_count    = (uint)first.joint_nodes.len,
        .max_tracks     = max_tracks,
        .pose_bounds    = pose_bounds,
        .parts          = alloc::new_array(allocator, CrowdPart, template.skins.len),
        .placements     = alloc::new_array(allocator, Transform, (sz)capacity),
        .poses          = alloc::new_array(allocator, CrowdPose, (sz)capacity),
        .cursors        = alloc::new_array(allocator, uint, (sz)capacity * max_tracks),
        .scratch_locals = alloc::new_array(allocator, Transform, template.nodes.len),
        .scratch_worlds = alloc::new_array(allocator, Mat4, template.nodes.len),
        .palettes       = alloc::new_array(allocator, Mat4, (sz)capacity * first.joint_nodes.len),
    };
    foreach (usz index, &skin : template.skins) {
        ModelMesh* mesh = mesh_of(template, skin.mesh_node)!!;
        crowd.parts[index] = {
            .template_node = skin.mesh_node,
            .target_count  = assets.geometry(mesh.geometry).target_count,
            .target_offset = crowd.morph_stride,
        };
        crowd.morph_stride += crowd.parts[index].target_count;
    }
    if (crowd.morph_stride) crowd.morph_weights = alloc::new_array(allocator, float, (sz)capacity * crowd.morph_stride);
    scene.add(root, crowd);

    foreach (usz index, &skin : template.skins) {
        ModelMesh* mesh = mesh_of(template, skin.mesh_node)!!;
        Node* part = scene.add_instanced_mesh(
            geometry: mesh.geometry,
            material: mesh.material,
            capacity: capacity,
            parent:   root,
            name:     template.nodes[skin.mesh_node].name,
        )!;
        InstancedMesh* batch = scene.get(part, InstancedMesh);
        batch.trace = false;
        batch.has_bounds_override = true;
        scene.get(root, AnimatedCrowd).parts[index].batch = part.id;
    }
    fill_crowd(scene, scene.get(root, AnimatedCrowd), instances);
    return root;
}

<*
 Replace the live instances of every part; count becomes instances.len.
 @param [&in] assets
 @param [&inout] scene
 @return? c3d::INVALID_ARGUMENT
 @require scene.has(node, AnimatedCrowd)
 @require assets.models.is_live(scene.get(node, AnimatedCrowd).model)
*>
fn void? set_crowd(AssetStore* assets, Scene* scene, Node* node, CrowdInstance[] instances) {
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    ModelTemplate* template = &assets.model(crowd.model).data;
    check_instances(template, (uint)crowd.placements.len, instances)!;
    fill_crowd(scene, crowd, instances);
}

fn void? check_instances(ModelTemplate* template, uint capacity, CrowdInstance[] instances) @local {
    if (instances.len > capacity) return c3d::INVALID_ARGUMENT~;
    foreach (&instance : instances) {
        bool known;
        foreach (clip : template.clips) known = known || c3d::same_id(clip, instance.pose.clip);
        if (!known) return c3d::INVALID_ARGUMENT~;
    }
}

fn void fill_crowd(Scene* scene, AnimatedCrowd* crowd, CrowdInstance[] instances) @local {
    crowd.count = (uint)instances.len;
    foreach (usz index, &instance : instances) {
        crowd.placements[index] = instance.placement;
        crowd.poses[index] = instance.pose;
    }
    crowd.cursors[..] = 0;
    foreach (&part : crowd.parts) {
        InstancedMesh* batch = scene.world.get(part.batch, InstancedMesh);
        foreach (usz index, &instance : instances) batch.colors[index] = instance.color;
    }
    scene.write_crowd_batches(crowd);
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
