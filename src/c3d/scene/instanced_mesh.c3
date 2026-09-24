module c3d::scene;

import c3d;
import c3d::ecs;
import c3d::maths;
import std::math;

<*
 Batch of one geometry and material; instances live in [0, count) of capacity-sized arrays.
*>
struct InstancedMesh {
    GeometryId  geometry;
    MaterialId  material;
    Transform[] transforms;
    Vec4[]      colors;
    uint        count;
    bool        cast_shadow;
    bool        receive_shadow;
    bool        trace;
    bool        has_bounds_override;
    Aabb        local_bounds;
}

<*
 Live instances whose transform mirrors space.
 @pure
*>
fn uint InstancedMesh.mirrored_count(&self) {
    uint mirrored;
    foreach (transform : self.transforms[:self.count]) {
        if (transform_mirrored(transform)) mirrored++;
    }
    return mirrored;
}

<*
 Whether the transform mirrors space.
 @pure
*>
fn bool transform_mirrored(Transform transform) {
    return transform.scale.x * transform.scale.y * transform.scale.z < 0;
}

fn void free_instanced_mesh(Entity entity, void* component, void* user) @private {
    InstancedMesh* batch = (InstancedMesh*)component;
    Allocator allocator = *(Allocator*)user;
    alloc::free(allocator, batch.transforms.ptr);
    alloc::free(allocator, batch.colors.ptr);
}
