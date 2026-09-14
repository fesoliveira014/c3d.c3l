module c3d::model;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;

<*
 Create live nodes for the template under the parent and return the instance root.
 @param [&in] assets : "Supplies the template; unchanged."
 @param [&inout] scene : "Owns the new nodes and instance arrays."
 @param [in] parent : "Null means the scene root."
 @param name : "Copied into the scene allocator."
 @return? c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
fn Node*? instantiate(
    AssetStore* assets,
    Scene* scene,
    ModelId model,
    Node* parent = null,
    String name = "",
) {
    ModelTemplate* template = &assets.models.try_get(model)!.data;
    Node* root = scene.add_node(parent, name)!;
    defer catch scene.remove(root);

    Allocator allocator = scene.allocator;
    Node*[] nodes = alloc::new_array(allocator, Node*, template.nodes.len);
    Transform[] base_pose = alloc::new_array(allocator, Transform, template.nodes.len);
    float[][] base_morph_weights = alloc::new_array(allocator, float[], template.meshes.len);
    scene.add(root, (ModelInstance){
        .source             = model,
        .nodes              = nodes,
        .base_pose          = base_pose,
        .base_morph_weights = base_morph_weights,
        .clips              = copy_slice(allocator, template.clips),
    });

    foreach (index, &node_template : template.nodes) {
        Node* node_parent = node_template.parent < 0 ? root : nodes[node_template.parent];
        Node* node = scene.add_node(node_parent, node_template.name)!;
        node.local = node_template.local;
        node.layers = node_template.layers;
        node.visible = node_template.visible;
        nodes[index] = node;
        base_pose[index] = node_template.local;
    }

    foreach (index, &mesh : template.meshes) {
        base_morph_weights[index] = copy_slice(allocator, mesh.default_morph_weights);
        scene.add(nodes[mesh.node], (Mesh){
            .geometry       = mesh.geometry,
            .material       = mesh.material,
            .cast_shadow    = true,
            .receive_shadow = true,
            .morph_weights  = copy_slice(allocator, mesh.default_morph_weights),
        });
    }
    foreach (&skin : template.skins) {
        Node*[] joints = alloc::new_array(allocator, Node*, skin.joint_nodes.len);
        foreach (index, joint : skin.joint_nodes) joints[index] = nodes[joint];
        scene.add(nodes[skin.mesh_node], (SkinBinding){ .skeleton = skin.skeleton, .joints = joints });
    }
    foreach (&camera : template.cameras) scene.add(nodes[camera.node], camera.value);
    foreach (&light : template.lights) scene.add(nodes[light.node], light.value);

    return root;
}

macro copy_slice(Allocator allocator, slice) @local {
    var $Element = $Typeof(slice[0]);
    if (!slice.len) return ($Element[]){};
    $Element[] copy = alloc::new_array(allocator, $Element, slice.len);
    copy[..] = slice[..];
    return copy;
}
