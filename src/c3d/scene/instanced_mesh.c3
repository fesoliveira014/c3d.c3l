module c3d::scene;

import c3d;
import c3d::ecs;
import c3d::maths;
import std::math;

<*
 Source of a swaying vertex's bend weight.
*>
enum SwayWeight {
    HEIGHT,       // squared height within the local bound; the base stays planted
    VERTEX_ALPHA, // consumed: shading and masking see vertex alpha 1
}

<*
 Wind bend of a batch's vertices along one world direction; zero amplitude is off.
*>
struct InstanceSway {
    Vec3       direction;
    float      amplitude;  // world units at bend weight 1; the batch bound grows by it
    float      frequency;  // cycles per second; an edit moves the phase at once
    float      lean;       // share of the amplitude held as a steady bend
    float      wavelength; // world units between gust crests along direction; 0 keeps the batch in phase
    float      variation;  // cycles of phase spread over the instance seeds
    SwayWeight weight;
}

<*
 Per-instance collapse over a band of camera distance; a zero end is off.
*>
struct InstanceFade {
    float start; // world units from the view camera where the first instances start to shrink
    float end;   // no instance is drawn or casts a shadow past it
}

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
    InstanceSway      sway;
    InstanceFade      fade;
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
 World-space distance the sway can move a vertex along each axis.
 @require self.amplitude == 0 || self.direction.length() > 0
*>
fn Vec3 InstanceSway.reach(self) {
    if (self.amplitude == 0) return {};
    return math::abs(self.direction.normalize()) * self.amplitude;
}

<*
 Check the programming contract of the batch's sway and fade.
 @require self.sway.amplitude >= 0 && math::is_finite(self.sway.amplitude)
 @require self.sway.amplitude == 0 || self.sway.direction.length() > 0
 @require self.sway.frequency >= 0 && math::is_finite(self.sway.frequency)
 @require self.sway.lean >= 0 && self.sway.lean <= 1
 @require self.sway.wavelength >= 0 && math::is_finite(self.sway.wavelength)
 @require self.sway.variation >= 0 && math::is_finite(self.sway.variation)
 @require self.fade.end == 0 || (self.fade.start >= 0 && self.fade.start < self.fade.end)
 @require math::is_finite(self.fade.end)
*>
fn void InstancedMesh.validate_effects(&self) {}

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
