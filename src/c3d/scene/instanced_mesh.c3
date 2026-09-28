module c3d::scene;

import c3d;
import c3d::ecs;
import c3d::maths;
import std::math;

<*
 Derived summary of a batch's live instances, kept by the library; zero until first read.
*>
struct InstanceAggregate {
    Aabb       bounds;            // node-local: each live instance's transform applied to the geometry bound
    GeometryId geometry;          // identity bounds were computed for, with geometry_revision and bounds_revision
    uint       geometry_revision;
    uint       bounds_revision;   // batch revision of bounds; 0 = not computed, since a revision is never 0
    uint       mirrored;
    uint       mirrored_revision; // batch revision of mirrored; 0 = not computed
}

<*
 Batch of one geometry and material; instances live in [0, count) of capacity-sized arrays.
 In-place edits of transforms or colors reach the renderer, bounds and history only through mark_instances_dirty.
 aggregate is kept by the library from the arrays under revision; applications do not write it.
*>
struct InstancedMesh {
    GeometryId        geometry;
    MaterialId        material;
    Transform[]       transforms;
    Vec4[]            colors;
    uint              count;
    bool              cast_shadow;
    bool              receive_shadow;
    bool              trace;
    bool              has_bounds_override;
    Aabb              local_bounds;
    uint              revision; // compared for equality only; never 0, so a renderer slot at 0 always uploads
    InstanceAggregate aggregate;
}

<*
 Live instances whose transform mirrors space, as of the current revision.
 Writes aggregate when stale.
*>
fn uint InstancedMesh.mirrored_count(&self) {
    if (self.aggregate.mirrored_revision == self.revision) return self.aggregate.mirrored;
    uint mirrored;
    foreach (transform : self.transforms[:self.count]) {
        if (transform_mirrored(transform)) mirrored++;
    }
    self.aggregate.mirrored = mirrored;
    self.aggregate.mirrored_revision = self.revision;
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
