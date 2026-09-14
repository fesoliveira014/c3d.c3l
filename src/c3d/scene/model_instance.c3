module c3d::scene;

import c3d;
import c3d::ecs;
import c3d::maths;

<*
 Live node table and authored baselines of one instantiated model; lives on its synthetic root.
*>
struct ModelInstance {
    ModelId     source;
    Node*[]     nodes;
    Transform[] base_pose;
    float[][]   base_morph_weights;
    ClipId[]    clips;
}

<*
 Skeleton and live joint nodes of a skinned mesh node.
*>
struct SkinBinding {
    SkeletonId skeleton;
    Node*[]    joints;
}

fn void free_model_instance(Entity entity, void* component, void* user) @private {
    ModelInstance* instance = (ModelInstance*)component;
    Allocator allocator = *(Allocator*)user;
    foreach (weights : instance.base_morph_weights) alloc::free(allocator, weights.ptr);
    alloc::free(allocator, instance.base_morph_weights.ptr);
    alloc::free(allocator, instance.nodes.ptr);
    alloc::free(allocator, instance.base_pose.ptr);
    alloc::free(allocator, instance.clips.ptr);
}

fn void free_skin_binding(Entity entity, void* component, void* user) @private {
    SkinBinding* binding = (SkinBinding*)component;
    alloc::free(*(Allocator*)user, binding.joints.ptr);
}
