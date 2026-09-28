module c3d::scene;

import c3d;
import c3d::ecs;
import c3d::maths;
import std::math;

<*
 Per-instance animation state; one clip, no blending.
*>
struct CrowdPose {
    ClipId clip;
    float  time;
    float  speed;
    bool   loop;
}

<*
 One skinned part a crowd draws through its own child batch.
*>
struct CrowdPart {
    Entity batch;
    uint   template_node;
    uint   target_count;
    uint   target_offset;
}

<*
 Animated instances of one model sharing one skeleton; part batches are its child nodes.
 Arrays are capacity-sized, palettes joint-major per instance in model space.
*>
struct AnimatedCrowd {
    ModelId     model;
    uint        count;
    uint        joint_count;
    uint        max_tracks;
    uint        morph_stride;
    Aabb        pose_bounds;
    CrowdPart[] parts;
    Transform[] placements;
    CrowdPose[] poses;
    uint[]      cursors;
    Transform[] scratch_locals;
    Mat4[]      scratch_worlds;
    Mat4[]      palettes;
    float[]     morph_weights;
}

fn void free_crowd(Entity entity, void* component, void* user) @private {
    AnimatedCrowd* crowd = (AnimatedCrowd*)component;
    Allocator allocator = *(Allocator*)user;
    alloc::free(allocator, crowd.parts.ptr);
    alloc::free(allocator, crowd.placements.ptr);
    alloc::free(allocator, crowd.poses.ptr);
    alloc::free(allocator, crowd.cursors.ptr);
    alloc::free(allocator, crowd.scratch_locals.ptr);
    alloc::free(allocator, crowd.scratch_worlds.ptr);
    alloc::free(allocator, crowd.palettes.ptr);
    alloc::free(allocator, crowd.morph_weights.ptr);
}

<*
 Copy the live placements and count into every part batch and bound them.
 @param [&inout] crowd
*>
fn void Scene.write_crowd_batches(&self, AnimatedCrowd* crowd) {
    Aabb bounds = crowd.pose_bounds;
    foreach (usz index, placement : crowd.placements[:crowd.count]) {
        Aabb placed = maths::aabb_transform(crowd.pose_bounds, placement.to_mat4());
        bounds = index == 0 ? placed : maths::aabb_merge(bounds, placed);
    }
    foreach (&part : crowd.parts) {
        InstancedMesh* batch = self.world.get(part.batch, InstancedMesh);
        batch.transforms[:crowd.count] = crowd.placements[:crowd.count];
        batch.count = crowd.count;
        batch.local_bounds = bounds;
    }
}
