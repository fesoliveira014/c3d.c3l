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
 Where a billboard batch's draw data lives.
*>
enum BillboardSource {
    BILLBOARDS, // Billboard values that core packs once per revision
    RECORDS,    // world-space records the owner writes; core copies them
    DEVICE,     // frame-origin records and a live count that compute writes
}

<*
 Sprite-sheet layout of a billboard batch; zero columns disables it.
*>
struct BillboardAtlas {
    uint columns;
    uint rows;
    uint frame_count;
    Vec2 inset; // UV units cut from each cell edge
}

<*
 Placement, dimensions, colour and sprite-sheet frame of one billboard.
*>
struct Billboard {
    Vec3 position;
    Vec2 size;
    Vec3 direction;
    float rotation;
    Vec4 color;
    float frame; // the integer part selects the cell; the fraction blends toward the next cell
}

<*
 World-space draw record of one billboard in the renderer's layout.
*>
struct BillboardRecord {
    Vec4 position_width;
    Vec4 direction_height;
    Vec4 color;
    float rotation;
    uint facing; // the batch's BillboardFacing ordinal
    float frame;
    uint _pad0;
}
$assert BillboardRecord::size == 64;

<*
 Renderer buffer holding a DEVICE batch's records and live count.
*>
struct BillboardDevice {
    BufferId buffer;
    usz records_offset; // capacity BillboardGpu records, 16-byte aligned
    usz count_offset; // one uint, 4-byte aligned, at most capacity
    uint capacity;
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
 Fixed-capacity billboards sharing one material, drawn from one source.
*>
struct BillboardBatch {
    MaterialId material;
    BillboardFacing facing;
    Billboard[] billboards; // BILLBOARDS only
    uint count;
    uint revision;
    BillboardAggregate aggregate;
    BillboardAtlas atlas;
    BillboardSource source;
    BillboardRecord[] records; // RECORDS only: capacity records, the first count live
    BillboardDevice device; // DEVICE only; a zero buffer draws nothing, and count stays zero
    bool has_bounds_override;
    Aabb local_bounds; // node-local; read when has_bounds_override is set
}

<*
 Add a node carrying a scene-owned billboard batch.
 @param billboards : "Copied; sets the live count; empty unless BILLBOARDS."
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
    BillboardAtlas atlas = {},
    BillboardSource source = BillboardSource.BILLBOARDS,
) {
    if (source != BillboardSource.BILLBOARDS && billboards.len) return c3d::INVALID_ARGUMENT~;
    if (billboards.len > capacity) return c3d::CAPACITY_EXCEEDED~;
    check_billboards(billboards)!;
    check_billboard_atlas(atlas)!;
    Node* node = self.add_node(parent, name)!;
    BillboardBatch batch = {
        .material = material,
        .facing = facing,
        .count = (uint)billboards.len,
        .revision = 1,
        .atlas = atlas,
        .source = source,
    };
    switch (source) {
        case BILLBOARDS:
            batch.billboards = alloc::new_array(self.allocator, Billboard, (sz)capacity);
            batch.billboards[:billboards.len] = billboards[..];
        case RECORDS:
            batch.records = alloc::new_array(self.allocator, BillboardRecord, (sz)capacity);
        case DEVICE:
            batch.device.capacity = capacity;
    }
    self.world.add(node.id, batch);
    return node;
}

<*
 Attach the buffer a DEVICE batch draws from, with its conservative bound.
 @param [&in] node : "Carries a DEVICE BillboardBatch."
 @param local_bounds : "Node-local bound of every record the buffer can hold."
 @require self.has(node, BillboardBatch)
 @require self.get(node, BillboardBatch).source == BillboardSource.DEVICE
 @require device.capacity == self.get(node, BillboardBatch).capacity()
 @require device.records_offset % 16 == 0 && device.count_offset % 4 == 0
*>
fn void Scene.set_billboard_device(
    &self,
    Node* node,
    BillboardDevice device,
    Aabb local_bounds,
) {
    BillboardBatch* batch = self.get(node, BillboardBatch);
    batch.device = device;
    batch.has_bounds_override = true;
    batch.local_bounds = local_bounds;
}

<*
 Replace the live billboard records within capacity.
 @param [&in] node : "Carries BillboardBatch."
 @param billboards : "Copied into scene-owned storage."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
 @require self.has(node, BillboardBatch)
 @require self.get(node, BillboardBatch).source == BillboardSource.BILLBOARDS
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
 Replace a batch's sprite-sheet layout.
 @param [&in] node : "Carries BillboardBatch."
 @return? c3d::INVALID_ARGUMENT
 @require self.has(node, BillboardBatch)
*>
fn void? Scene.set_billboard_atlas(&self, Node* node, BillboardAtlas atlas) {
    check_billboard_atlas(atlas)!;
    self.get(node, BillboardBatch).atlas = atlas;
    self.mark_billboards_dirty(node);
}

<*
 Change live count, initializing newly exposed slots.
 @param [&in] node : "Carries BillboardBatch."
 @return? c3d::CAPACITY_EXCEEDED
 @require self.has(node, BillboardBatch)
 @require self.get(node, BillboardBatch).source == BillboardSource.BILLBOARDS
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
 Records the batch can hold.
*>
fn uint BillboardBatch.capacity(&self) {
    switch (self.source) {
        case BILLBOARDS: return (uint)self.billboards.len;
        case RECORDS: return (uint)self.records.len;
        case DEVICE: return self.device.capacity;
    }
}

<*
 Instances the renderer culls; a DEVICE batch's capacity once attached.
*>
fn uint BillboardBatch.draw_count(&self) {
    if (self.source != BillboardSource.DEVICE) return self.count;

    return self.device.buffer.generation ? self.device.capacity : 0;
}

<*
 Billboard at an index of the live prefix, whatever the source.
 @require index < self.count
*>
fn Billboard BillboardBatch.billboard(&self, uint index) {
    if (self.source == BillboardSource.BILLBOARDS) return self.billboards[index];

    BillboardRecord* record = &self.records[index];
    return {
        .position = record.position_width.xyz,
        .size = { record.position_width.w, record.direction_height.w },
        .direction = record.direction_height.xyz,
        .rotation = record.rotation,
        .color = record.color,
        .frame = record.frame,
    };
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
        if (!math::is_finite(billboard.frame) || billboard.frame < 0) return false;
    }
    return true;
}

<*
 Whether an atlas is off or has a consistent grid, frame count and inset.
 @pure
*>
fn bool billboard_atlas_valid(BillboardAtlas atlas) {
    for (usz axis = 0; axis < 2; axis++) {
        if (!math::is_finite(atlas.inset[axis]) || atlas.inset[axis] < 0) return false;
    }
    if (atlas.columns == 0) return true;

    ulong cells = (ulong)atlas.columns * atlas.rows;
    if (atlas.frame_count == 0 || atlas.frame_count > cells) return false;

    return atlas.inset.x < 0.5f / atlas.columns && atlas.inset.y < 0.5f / atlas.rows;
}

fn void? check_billboards(Billboard[] billboards) @local {
    if (!billboards_valid(billboards)) return c3d::INVALID_ARGUMENT~;
}

fn void? check_billboard_atlas(BillboardAtlas atlas) @local {
    if (!billboard_atlas_valid(atlas)) return c3d::INVALID_ARGUMENT~;
}

fn void free_billboards(Entity entity, void* component, void* user) @private {
    BillboardBatch* batch = (BillboardBatch*)component;
    Allocator allocator = *(Allocator*)user;
    switch (batch.source) {
        case BILLBOARDS: alloc::free(allocator, batch.billboards.ptr);
        case RECORDS: alloc::free(allocator, batch.records.ptr);
        case DEVICE: break;
    }
}
