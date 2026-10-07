module c3d::model;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;

<*
 Create live nodes for the template under the parent and return the instance root.
 @param [&in] assets : "Supplies the template; unchanged."
 @param [&inout] scene : "Owns the new nodes and instance arrays."
 @param [in] parent : "Null means the scene root."
 @param name : "Copied into the scene allocator."
 @return? c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
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
    Entity[] node_entities = alloc::new_array(allocator, Entity, template.nodes.len);
    Transform[] base_pose = alloc::new_array(allocator, Transform, template.nodes.len);
    uint[] mesh_nodes = alloc::new_array(allocator, uint, template.meshes.len);
    float[][] base_morph_weights = alloc::new_array(allocator, float[], template.meshes.len);
    ModelInstance* instance = scene.add(root, (ModelInstance){
        .source             = model,
        .nodes              = nodes,
        .node_entities      = node_entities,
        .base_pose          = base_pose,
        .mesh_nodes         = mesh_nodes,
        .base_morph_weights = base_morph_weights,
        .clips              = copy_slice(allocator, template.clips),
    });

    foreach (index, &node_template : template.nodes) {
        Node* node_parent = node_template.parent < 0 ? root : instance.present_node((usz)node_template.parent);
        ModelLodGroup* group;
        foreach (&candidate : template.lod_groups) {
            if (candidate.node == index) {
                group = candidate;
                break;
            }
        }
        Node* node;
        if (group) {
            node = scene.add_lod_group(
                assets: assets,
                desc: group.desc,
                parent: node_parent,
                name: node_template.name,
            )!;
        } else {
            node = scene.add_node(node_parent, node_template.name)!;
        }
        node.local = node_template.local;
        node.layers = node_template.layers;
        node.visible = node_template.visible;
        nodes[index] = node;
        node_entities[index] = node.id;
        base_pose[index] = node_template.local;
    }

    foreach (index, &mesh : template.meshes) {
        mesh_nodes[index] = mesh.node;
        base_morph_weights[index] = copy_slice(allocator, mesh.default_morph_weights);
        scene.add(instance.present_node(mesh.node), (Mesh){
            .geometry       = mesh.geometry,
            .material       = mesh.material,
            .cast_shadow    = true,
            .receive_shadow = true,
            .trace          = true,
            .morph_weights  = copy_slice(allocator, mesh.default_morph_weights),
        });
    }
    foreach (&skin : template.skins) {
        Node*[] joints = alloc::new_array(allocator, Node*, skin.joint_nodes.len);
        foreach (index, joint : skin.joint_nodes) joints[index] = instance.present_node(joint);
        scene.add(instance.present_node(skin.mesh_node), (SkinBinding){ .skeleton = skin.skeleton, .joints = joints });
    }
    foreach (&camera : template.cameras) scene.add(instance.present_node(camera.node), camera.value);
    foreach (&light : template.lights) scene.add(instance.present_node(light.node), light.value);

    return root;
}

macro copy_slice(Allocator allocator, slice) @local {
    var $Element = $Typeof(slice[0]);
    if (!slice.len) return ($Element[]){};
    $Element[] copy = alloc::new_array(allocator, $Element, slice.len);
    copy[..] = slice[..];
    return copy;
}
