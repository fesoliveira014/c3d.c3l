module c3d::scene;

import c3d;
import c3d::ecs;
import c3d::maths;
import std::math;

<*
 Unit white billboard pointing along local positive Y.
*>
const Billboard BILLBOARD_DEFAULT = {
    .size = { 1, 1 },
    .direction = { 0, 1, 0 },
    .color = { 1, 1, 1, 1 },
};

<*
 Orientation of a billboard in each rendered view.
*>
enum BillboardFacing {
    CAMERA,
    DIRECTIONAL,
}

<*
 Placement, dimensions and colour of one billboard.
*>
struct Billboard {
    Vec3 position;
    Vec2 size;
    Vec3 direction;
    float rotation;
    Vec4 color;
}

<*
 Library-owned world bounds of a billboard batch.
*>
struct BillboardAggregate {
    Mat4 world;
    Aabb bounds;
    uint revision;
}

<*
 Fixed scene-owned array of billboards sharing one material.
*>
struct BillboardBatch {
    MaterialId material;
    BillboardFacing facing;
    Billboard[] billboards;
    uint count;
    uint revision;
    BillboardAggregate aggregate;
}

<*
 Add a node carrying a scene-owned billboard batch.
 @param billboards : "Copied; determines the live count."
 @param [in] parent : "Null selects the root."
 @param name : "Copied into the scene allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require capacity > 0
*>
fn Node*? Scene.add_billboards(
    &self,
    MaterialId material,
    uint capacity,
    Billboard[] billboards = {},
    BillboardFacing facing = BillboardFacing.CAMERA,
    Node* parent = null,
    String name = "",
) {
    if (billboards.len > capacity) return c3d::CAPACITY_EXCEEDED~;
    check_billboards(billboards)!;
    Node* node = self.add_node(parent, name)!;
    BillboardBatch batch = {
        .material = material,
        .facing = facing,
        .billboards = alloc::new_array(self.allocator, Billboard, (sz)capacity),
        .count = (uint)billboards.len,
        .revision = 1,
    };
    batch.billboards[:billboards.len] = billboards[..];
    self.world.add(node.id, batch);
    return node;
}

<*
 Replace the live billboard records within capacity.
 @param [&in] node : "Carries BillboardBatch."
 @param billboards : "Copied into scene-owned storage."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require self.has(node, BillboardBatch)
*>
fn void? Scene.set_billboards(&self, Node* node, Billboard[] billboards) {
    BillboardBatch* batch = self.get(node, BillboardBatch);
    if (billboards.len > batch.billboards.len) return c3d::CAPACITY_EXCEEDED~;
    check_billboards(billboards)!;
    batch.billboards[:billboards.len] = billboards[..];
    batch.count = (uint)billboards.len;
    self.mark_billboards_dirty(node);
}

<*
 Change live count, initializing newly exposed slots.
 @param [&in] node : "Carries BillboardBatch."
 @return? c3d::CAPACITY_EXCEEDED
 @require self.has(node, BillboardBatch)
*>
fn void? Scene.resize_billboards(&self, Node* node, uint count) {
    BillboardBatch* batch = self.get(node, BillboardBatch);
    if (count > batch.billboards.len) return c3d::CAPACITY_EXCEEDED~;
    if (count > batch.count) batch.billboards[batch.count:count - batch.count] = BILLBOARD_DEFAULT;
    batch.count = count;
    self.mark_billboards_dirty(node);
}

<*
 Publish in-place changes to the batch's render data.
 @param [&in] node : "Carries valid BillboardBatch data."
 @require self.has(node, BillboardBatch)
*>
fn void Scene.mark_billboards_dirty(&self, Node* node) {
    BillboardBatch* batch = self.get(node, BillboardBatch);
    batch.revision = batch.revision == uint::max ? 1 : batch.revision + 1;
}

<*
 Transform a billboard's centre, dimensions and direction into world space.
 @param world : "Published affine node transform."
 @pure
*>
fn Billboard world_billboard(Mat4 world, Billboard billboard) {
    Vec3 width_axis = maths::transform_dir(world, { 1, 0, 0 }) @pure;
    Vec3 height_axis = maths::transform_dir(world, { 0, 1, 0 }) @pure;
    billboard.position = maths::transform_point(world, billboard.position) @pure;
    billboard.size *= { width_axis.length(), height_axis.length() };
    billboard.direction = maths::transform_dir(world, billboard.direction) @pure;
    float length = billboard.direction.length();
    if (length > 0) billboard.direction /= length;
    return billboard;
}

<*
 Whether billboard values satisfy the scene placement domain.
 @pure
*>
fn bool billboards_valid(Billboard[] billboards) {
    foreach (billboard : billboards) {
        for (usz axis = 0; axis < 3; axis++) {
            if (!math::is_finite(billboard.position[axis]) || !math::is_finite(billboard.direction[axis])) {
                return false;
            }
        }
        for (usz channel = 0; channel < 4; channel++) {
            if (!math::is_finite(billboard.color[channel])) return false;
        }
        if (!math::is_finite(billboard.rotation) || !math::is_finite(billboard.size.x)
            || !math::is_finite(billboard.size.y) || billboard.size.x < 0 || billboard.size.y < 0) {
            return false;
        }
    }
    return true;
}

fn void? check_billboards(Billboard[] billboards) @local {
    if (!billboards_valid(billboards)) return c3d::INVALID_ARGUMENT~;
}

fn void free_billboards(Entity entity, void* component, void* user) @private {
    BillboardBatch* batch = (BillboardBatch*)component;
    alloc::free(*(Allocator*)user, batch.billboards.ptr);
}
