module c3d::scene;

import c3d;
import c3d::ecs;
import c3d::maths;
import std::math;

<*
 Range marks a batch remembers.
*>
const uint INSTANCE_RANGE_MARKS = 4; // 56 B per batch; a renderer slot more marks behind uploads the whole batch

<*
 Sentinel parent of a quadtree root instance.
*>
const uint QUADTREE_ROOT = uint::max; // mirrored as QUADTREE_ROOT in c3d.abi

<*
 Longest chain of ancestors a quadtree instance may have.
*>
const uint MAX_QUADTREE_DEPTH = 8; // mirrored as MAX_QUADTREE_DEPTH in c3d.abi; each selection thread walks this many ancestors

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
    uint       bounds_edited;     // instances range-marked since the bound was last computed tight
    uint       mirrored;
    uint       mirrored_revision; // batch revision of mirrored; 0 = not computed
}

<*
 Instances [first, end) of a batch.
*>
struct InstanceSpan {
    uint first;
    uint end;
}

<*
 Per-view level-of-detail selection over a batch whose instances form a quadtree.
 revision, leaves and leaf_count are kept by the library; applications call Scene.set_instance_quadtree.
*>
struct InstanceQuadtree {
    uint[] parents;      // parent instance per instance; QUADTREE_ROOT for a root; empty disables the mode
    float  split_pixels; // a node splits when its projected height exceeds this many pixels of the view's working extent
    float  hysteresis;   // a split node merges below split_pixels / (1 + hysteresis)
    uint   revision;     // topology revision: advanced when parents change, never by record edits; never 0 once set
    bool[] leaves;       // per instance: no other instance names it as parent
    uint   leaf_count;
}

<*
 Span a range mark edited and the batch revision the mark produced.
*>
struct InstanceRangeMark {
    uint         revision;
    InstanceSpan span;
}

<*
 Recent range marks of a batch, oldest first; any other revision advance empties it.
*>
struct InstanceRangeLog {
    uint                                    base_revision; // revision before the first mark; read only while count > 0
    uint                                    count;
    InstanceRangeMark[INSTANCE_RANGE_MARKS] marks;
}

<*
 Batch of one geometry and material; instances live in [0, count) of capacity-sized arrays.
 In-place edits of transforms or colors reach the renderer, bounds and history only through
 mark_instances_dirty or mark_instances_range_dirty.
 aggregate and ranges are kept by the library from the arrays under revision; applications do not write them.
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
    bool              trace_sway; // trace the built-in sway pose per instance; overflow traces at rest
    bool              has_bounds_override;
    Aabb              local_bounds;
    InstanceSway      sway;
    InstanceFade      fade;
    uint              revision; // compared for equality only; never 0, so a renderer slot at 0 always uploads
    InstanceAggregate aggregate;
    InstanceRangeLog  ranges;
    InstanceQuadtree  quadtree;
}

<*
 Span covering both.
 @pure
*>
fn InstanceSpan InstanceSpan.merge(self, InstanceSpan other) {
    return { .first = math::min(self.first, other.first), .end = math::max(self.end, other.end) };
}

<*
 Record a mark, merging the two oldest marks when the log is full.
 @param base_revision : "Batch revision before the mark; kept only when the log was empty."
*>
fn void InstanceRangeLog.append(&self, uint base_revision, InstanceRangeMark mark) {
    if (!self.count) self.base_revision = base_revision;
    if (self.count == INSTANCE_RANGE_MARKS) {
        self.marks[1].span = self.marks[0].span.merge(self.marks[1].span);
        for (uint index = 1; index < self.count; index++) self.marks[index - 1] = self.marks[index];
        self.count--;
    }
    self.marks[self.count++] = mark;
}

<*
 Union of the marks made after the revision.
 @return "Empty when the log does not reach back to the revision."
*>
fn InstanceSpan InstanceRangeLog.span_since(&self, uint revision) {
    uint first_after = self.count;
    if (self.count && revision == self.base_revision) first_after = 0;
    foreach (index, mark : self.marks[:self.count]) {
        if (mark.revision == revision) first_after = (uint)index + 1;
    }
    if (first_after >= self.count) return {};

    InstanceSpan span = self.marks[first_after].span;
    foreach (mark : self.marks[first_after + 1:self.count - first_after - 1]) span = span.merge(mark.span);
    return span;
}

<*
 Live instances whose transform mirrors space, as of the current revision.
 Writes aggregate when stale.
*>
fn uint InstancedMesh.mirrored_count(&self) {
    InstanceAggregate* aggregate = &self.aggregate;
    if (aggregate.mirrored_revision == self.revision) return aggregate.mirrored;

    InstanceSpan span = self.ranges.span_since(aggregate.mirrored_revision);
    bool still_none = span.end > span.first && !aggregate.mirrored
      && !span_mirrored(self.transforms[span.first:span.end - span.first]);
    if (still_none) {
        aggregate.mirrored_revision = self.revision;
        return 0;
    }

    uint mirrored;
    foreach (transform : self.transforms[:self.count]) {
        if (transform_mirrored(transform)) mirrored++;
    }
    aggregate.mirrored = mirrored;
    aggregate.mirrored_revision = self.revision;
    return mirrored;
}

<*
 Check that the parents form a quadtree over count instances and the thresholds are usable.
 @param [&in] quadtree : "Only parents, split_pixels and hysteresis are read."
 @return? c3d::INVALID_ARGUMENT
*>
fn void? check_instance_quadtree(InstanceQuadtree* quadtree, uint count) {
    if (quadtree.parents.len != count) return c3d::INVALID_ARGUMENT~;

    // Negated so NaN faults too.
    if (!(quadtree.split_pixels >= 0) || !math::is_finite(quadtree.split_pixels)) return c3d::INVALID_ARGUMENT~;
    if (!(quadtree.hysteresis >= 0) || !math::is_finite(quadtree.hysteresis)) return c3d::INVALID_ARGUMENT~;

    foreach (parent : quadtree.parents) {
        uint ancestor = parent;
        uint depth;
        while (ancestor != QUADTREE_ROOT) {
            if (ancestor >= count || depth == MAX_QUADTREE_DEPTH) return c3d::INVALID_ARGUMENT~;

            ancestor = quadtree.parents[ancestor];
            depth++;
        }
    }
}

<*
 Whether the instance has no children; true for every instance of a batch without a quadtree.
*>
fn bool InstancedMesh.is_leaf(&self, uint instance) {
    return !self.quadtree.parents.len || self.quadtree.leaves[instance];
}

<*
 Count of instances the CPU walkers visit: the leaves, or every live instance.
*>
fn uint InstancedMesh.leaf_instances(&self) {
    return self.quadtree.parents.len ? self.quadtree.leaf_count : self.count;
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
 @require instance_effects_valid(self.sway, self.fade)
*>
fn void InstancedMesh.validate_effects(&self) {}

<*
 Check the programming contract of the batch's quadtree.
 @require instance_quadtree_valid(self)
*>
fn void InstancedMesh.validate_quadtree(&self) {}

<*
 Whether the transform mirrors space.
 @pure
*>
fn bool transform_mirrored(Transform transform) {
    return transform.scale.x * transform.scale.y * transform.scale.z < 0;
}

fn bool span_mirrored(Transform[] transforms) @local {
    foreach (transform : transforms) {
        if (transform_mirrored(transform)) return true;
    }
    return false;
}

<*
 Whether sway and fade satisfy the instance effect domain.
 @pure
*>
fn bool instance_effects_valid(InstanceSway sway, InstanceFade fade) {
    return sway.amplitude >= 0 && math::is_finite(sway.amplitude)
      && (sway.amplitude == 0 || sway.direction.length() > 0)
      && sway.frequency >= 0 && math::is_finite(sway.frequency)
      && sway.lean >= 0 && sway.lean <= 1
      && sway.wavelength >= 0 && math::is_finite(sway.wavelength)
      && sway.variation >= 0 && math::is_finite(sway.variation)
      && (fade.end == 0 || (fade.start >= 0 && fade.start < fade.end))
      && math::is_finite(fade.end);
}

<*
 Whether the quadtree is well formed and the batch can draw it.
 Instance records pack unmirrored instances first, so a mirrored instance would move the records off their parents.
*>
fn bool instance_quadtree_valid(InstancedMesh* batch) {
    return @ok(check_instance_quadtree(&batch.quadtree, batch.count)) && !batch.trace && batch.mirrored_count() == 0;
}

fn void free_instanced_mesh(Entity entity, void* component, void* user) @private {
    InstancedMesh* batch = (InstancedMesh*)component;
    Allocator allocator = *(Allocator*)user;
    alloc::free(allocator, batch.transforms.ptr);
    alloc::free(allocator, batch.colors.ptr);
    alloc::free(allocator, batch.quadtree.parents.ptr);
    alloc::free(allocator, batch.quadtree.leaves.ptr);
}
