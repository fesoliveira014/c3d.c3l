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

fn void free_model_instance(Entity entity, void* component, void* user) @private {
    ModelInstance* instance = (ModelInstance*)component;
    Allocator allocator = *(Allocator*)user;
    foreach (weights : instance.base_morph_weights) alloc::free(allocator, weights.ptr);
    alloc::free(allocator, instance.base_morph_weights.ptr);
    alloc::free(allocator, instance.nodes.ptr);
    alloc::free(allocator, instance.base_pose.ptr);
    alloc::free(allocator, instance.clips.ptr);
}
