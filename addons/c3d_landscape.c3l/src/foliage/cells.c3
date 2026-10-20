module c3d::landscape::foliage;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::landscape::terrain;
import c3d::maths;
import c3d::scene;
import std::math;

const float EDIT_REACH_TEXELS @private = 2; // a texel reaches one texel in face normals and two in smooth normals
const usz RING_STRIPS @private = 4; // one per border of a tile; twin of BorderEdge::len, the length ring_strips returns
const usz MAX_CHANGED_RANGES @private = 2 + RING_STRIPS; // density region, ground refresh and the ring strips
const uint NOT_COUNTED @private = uint::max; // a cell outside the ranges of a partial re-scatter

struct CellRange @private {
    uint first_column;
    uint first_row;
    uint end_column; // exclusive
    uint end_row;
}

struct StagedCell @private {
    LodGroup    lod;
    Transform[] transforms;
    Vec4[]      colors;
    Node*       created; // null when the cell already has a node
}

struct CellStorage @private {
    Transform[] transforms;
    Vec4[]      colors;
}

fn FoliageRuntime? create_runtime(Allocator allocator, uint cells_per_side, FoliageDesc desc) @private {
    sz count = (sz)cells_per_side * cells_per_side;
    sz bytes = count * Entity::size;
    sz desc_offset, levels_offset, parts_offset;
    if (desc.lod) {
        desc_offset = mem::aligned_offset(bytes, LodDesc::alignment);
        levels_offset = mem::aligned_offset(desc_offset + LodDesc::size, LodLevel::alignment);
        parts_offset = mem::aligned_offset(levels_offset + (sz)desc.lod.levels.len * LodLevel::size, LodPart::alignment);
        bytes = parts_offset + (sz)desc.lod.parts.len * LodPart::size;
    }
    char*? allocation = alloc::malloc_try(allocator, bytes);
    if (catch allocation) return c3d::CAPACITY_EXCEEDED~;
    Entity[] cells = ((Entity*)allocation)[:count];
    cells[..] = {};
    if (desc.lod) {
        LodDesc* copy = (LodDesc*)(allocation + desc_offset);
        *copy = *desc.lod;
        copy.levels = ((LodLevel*)(allocation + levels_offset))[:desc.lod.levels.len];
        copy.parts = ((LodPart*)(allocation + parts_offset))[:desc.lod.parts.len];
        copy.levels[..] = desc.lod.levels[..];
        copy.parts[..] = desc.lod.parts[..];
        desc.lod = copy;
    }
    return { .allocator = allocator, .desc = desc, .cells_per_side = cells_per_side, .cells = cells };
}

fn void free_runtime(FoliageRuntime* runtime) @private {
    alloc::free(runtime.allocator, runtime.cells.ptr);
    *runtime = {};
}

fn CellRange whole_grid(uint cells_per_side) @private {
    return { .end_column = cells_per_side, .end_row = cells_per_side };
}

// Cells whose candidates can sample a texel of the rectangle, through both node transforms.
fn CellRange cells_meeting(ScatterFrame* frame, FoliageRuntime* runtime, TexelRect rect) @private {
    float texel = frame.ground.cell_size;
    Vec2 first = { ((float)rect.x - EDIT_REACH_TEXELS) * texel, ((float)rect.z - EDIT_REACH_TEXELS) * texel };
    Vec2 last = {
        ((float)(rect.x + rect.columns) + EDIT_REACH_TEXELS) * texel,
        ((float)(rect.z + rect.rows) + EDIT_REACH_TEXELS) * texel,
    };
    return cells_meeting_extent(
        frame:   frame,
        runtime: runtime,
        first:   first,
        last:    last,
    );
}

// Cells whose candidates can sample a texel of the density region, widened as an edit is; the map spans the ground.
fn CellRange cells_meeting_density(ScatterFrame* frame, FoliageRuntime* runtime, TextureRegion region) @private {
    float texel_x = frame.extent / (float)frame.density_width;
    float texel_z = frame.extent / (float)frame.density_height;
    Vec2 first = { ((float)region.x - EDIT_REACH_TEXELS) * texel_x, ((float)region.y - EDIT_REACH_TEXELS) * texel_z };
    Vec2 last = {
        ((float)(region.x + region.width) + EDIT_REACH_TEXELS) * texel_x,
        ((float)(region.y + region.height) + EDIT_REACH_TEXELS) * texel_z,
    };
    return cells_meeting_extent(
        frame:   frame,
        runtime: runtime,
        first:   first,
        last:    last,
    );
}

// The corners are metres in the ground's space.
fn CellRange cells_meeting_extent(
    ScatterFrame* frame,
    FoliageRuntime* runtime,
    Vec2 first,
    Vec2 last,
) @private {
    Mat4 layer_from_ground = maths::inverse_affine(frame.layer_world).mul(frame.ground.world);
    Vec2 low = { float::max, float::max };
    Vec2 high = { -float::max, -float::max };
    Vec2[4] corners = { { first.x, first.y }, { last.x, first.y }, { first.x, last.y }, { last.x, last.y } };
    foreach (corner : corners) {
        Vec3 local = maths::transform_point(layer_from_ground, { corner.x, 0, corner.y });
        low = { math::min(low.x, local.x), math::min(low.y, local.z) };
        high = { math::max(high.x, local.x), math::max(high.y, local.z) };
    }
    float side = (float)runtime.cells_per_side;
    float first_column = math::clamp(math::floor(low.x / frame.cell_size), 0.0f, side);
    float first_row = math::clamp(math::floor(low.y / frame.cell_size), 0.0f, side);
    float end_column = math::clamp(math::floor(high.x / frame.cell_size) + 1, 0.0f, side);
    float end_row = math::clamp(math::floor(high.y / frame.cell_size) + 1, 0.0f, side);
    return {
        .first_column = (uint)first_column,
        .first_row    = (uint)first_row,
        .end_column   = (uint)end_column,
        .end_row      = (uint)end_row,
    };
}

// Each cell once, where ranges overlap.
macro void @distinct_cells(CellRange[] ranges; @body(uint column, uint row)) @private {
    foreach (range_index, range : ranges) {
        for (uint row = range.first_row; row < range.end_row; row++) {
            for (uint column = range.first_column; column < range.end_column; column++) {
                if (in_ranges(ranges[:range_index], column, row)) continue;

                @body(column, row);
            }
        }
    }
}

fn void place_ranges(
    Scene* scene,
    ScatterFrame* frame,
    FoliageRuntime* runtime,
    CellRange[] ranges,
) @private {
    @distinct_cells(ranges; uint column, uint row) {
        place_existing_cell(
            scene:   scene,
            frame:   frame,
            runtime: runtime,
            column:  column,
            row:     row,
        );
    };
}

fn bool in_ranges(CellRange[] ranges, uint column, uint row) @private {
    foreach (range : ranges) {
        if (column >= range.first_column && column < range.end_column
          && row >= range.first_row && row < range.end_row) return true;
    }
    return false;
}

fn void place_existing_cell(
    Scene* scene,
    ScatterFrame* frame,
    FoliageRuntime* runtime,
    uint column,
    uint row,
) @private {
    Entity cell = runtime.cells[row * runtime.cells_per_side + column];
    if (!cell.generation) return;

    Node* node = scene.node(cell);
    CellStorage storage = cell_storage(scene, runtime, node);
    uint count = place_cell(
        frame:      frame,
        column:     column,
        row:        row,
        transforms: storage.transforms,
        colors:     storage.colors,
    );
    publish_cell(
        scene:   scene,
        runtime: runtime,
        node:    node,
        count:   count,
    );
}

fn CellStorage cell_storage(Scene* scene, FoliageRuntime* runtime, Node* node) @private {
    if (runtime.desc.lod) {
        LodGroupState* state = scene.get(node, LodGroup).state;
        return { .transforms = state.transforms, .colors = state.colors };
    }
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    return { .transforms = batch.transforms, .colors = batch.colors };
}

// The cell's arrays already hold the instances.
fn void publish_cell(
    Scene* scene,
    FoliageRuntime* runtime,
    Node* node,
    uint count,
) @private {
    if (runtime.desc.lod) {
        runtime.instances -= scene.get(node, LodGroup).state.count;
        scene.publish_lod_instances(node, count);
    } else {
        InstancedMesh* batch = scene.get(node, InstancedMesh);
        runtime.instances -= batch.count;
        batch.count = count;
        scene.mark_instances_dirty(node);
    }
    runtime.instances += count;
    runtime.placed_cells++;
}

fn void? rescatter(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc* desc,
    ScatterFrame* frame,
    FoliageRuntime* runtime,
    CellRange[] ranges,
) @private {
    runtime.count_passes++;
    @pool() {
        uint[] counts = alloc::new_array(tmem, uint, (sz)runtime.cells.len);
        counts[..] = NOT_COUNTED;
        @distinct_cells(ranges; uint column, uint row) {
            counts[(usz)row * runtime.cells_per_side + column] = count_cell(frame, column, row);
        };
        install_counts(
            scene:   scene,
            assets:  assets,
            node:    node,
            desc:    desc,
            runtime: runtime,
            counts:  counts,
        )!;
    };
    place_ranges(
        scene:   scene,
        frame:   frame,
        runtime: runtime,
        ranges:  ranges,
    );
}

// All or nothing: the node budget, then every allocation, before any cell changes. Runs inside a @pool.
fn void? install_counts(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc* desc,
    FoliageRuntime* runtime,
    uint[] counts,
) @private {
    uint new_nodes;
    foreach (index, count : counts) {
        if (count != NOT_COUNTED && count && !runtime.cells[index].generation) new_nodes++;
    }
    if (new_nodes > scene.world.entities.free_count) return c3d::CAPACITY_EXCEEDED~;

    StagedCell[] staged = alloc::new_array(tmem, StagedCell, (sz)runtime.cells.len);
    stage_cells(
        scene:   scene,
        assets:  assets,
        node:    node,
        runtime: runtime,
        counts:  counts,
        staged:  staged,
    )!;
    commit_cells(
        scene:   scene,
        desc:    desc,
        runtime: runtime,
        counts:  counts,
        staged:  staged,
    );
}

fn uint capacity_of(Scene* scene, Entity cell) @private {
    if (!cell.generation) return 0;
    if (scene.world.has(cell, LodGroup)) return (uint)scene.world.get(cell, LodGroup).state.transforms.len;
    return (uint)scene.world.get(cell, InstancedMesh).transforms.len;
}

fn void? stage_cells(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageRuntime* runtime,
    uint[] counts,
    StagedCell[] staged,
) @private {
    defer catch release_staged(scene, staged);
    foreach (index, count : counts) {
        if (count == NOT_COUNTED || count <= capacity_of(scene, runtime.cells[index])) continue;
        if (runtime.desc.lod) {
            staged[index].lod = scene::create_lod_group(
                allocator: scene.allocator,
                assets:    assets,
                desc:      *runtime.desc.lod,
                capacity:  count,
            )!;
            staged[index].transforms = staged[index].lod.state.transforms;
            staged[index].colors = staged[index].lod.state.colors;
        } else {
            Transform[]? transforms = alloc::new_array_try(scene.allocator, Transform, (sz)count);
            if (catch transforms) return c3d::CAPACITY_EXCEEDED~;
            staged[index].transforms = transforms;
            Vec4[]? colors = alloc::new_array_try(scene.allocator, Vec4, (sz)count);
            if (catch colors) return c3d::CAPACITY_EXCEEDED~;
            staged[index].colors = colors;
        }
        if (runtime.cells[index].generation) continue;
        staged[index].created = scene.add_node(parent: node)!;
        staged[index].created.layers = node.layers;
        scene.add(staged[index].created, (FoliageCellOwner){ .layer = node.id, .cell_index = (uint)index });
    }
}

fn void release_staged(Scene* scene, StagedCell[] staged) @private {
    foreach (&cell : staged) {
        if (cell.lod.state) {
            scene::destroy_lod_group(scene.allocator, &cell.lod);
        } else {
            alloc::free(scene.allocator, cell.transforms.ptr);
            alloc::free(scene.allocator, cell.colors.ptr);
        }
        if (cell.created) scene.remove(cell.created);
    }
}

// Cannot fail: every node and array it needs was staged.
fn void commit_cells(
    Scene* scene,
    FoliageDesc* desc,
    FoliageRuntime* runtime,
    uint[] counts,
    StagedCell[] staged,
) @private {
    foreach (index, count : counts) {
        if (count == NOT_COUNTED) continue;

        Entity cell = runtime.cells[index];
        StagedCell* grown = &staged[index];
        if (!count) {
            if (!cell.generation) continue;
            Node* emptied = scene.node(cell);
            runtime.instances -= desc.lod ? scene.get(emptied, LodGroup).state.count : scene.get(emptied, InstancedMesh).count;
            scene.remove(emptied);
            runtime.cells[index] = {};
            runtime.cell_nodes--;
            continue;
        }
        if (!grown.transforms.len) continue;
        if (desc.lod) {
            Node* target = grown.created ? grown.created : scene.node(cell);
            if (grown.created) {
                runtime.cells[index] = target.id;
                runtime.cell_nodes++;
            } else {
                runtime.instances -= scene.get(target, LodGroup).state.count;
                scene.remove_component(target, LodGroup);
            }
            scene.add(target, grown.lod);
            scene.set_lod_effects(target, {
                .cast_shadow = desc.cast_shadow,
                .receive_shadow = desc.receive_shadow,
                .trace = desc.trace,
                .trace_sway = desc.trace_sway,
                .sway = runtime.sway,
                .fade = desc.fade,
            });
            continue;
        }
        if (grown.created) {
            scene.add(grown.created, (InstancedMesh){
                .geometry       = desc.geometry,
                .material       = desc.material,
                .transforms     = grown.transforms,
                .colors         = grown.colors,
                .cast_shadow    = desc.cast_shadow,
                .receive_shadow = desc.receive_shadow,
                .trace          = desc.trace,
                .trace_sway     = desc.trace_sway,
                .sway           = runtime.sway,
                .fade           = desc.fade,
                .revision       = 1,
            });
            runtime.cells[index] = grown.created.id;
            runtime.cell_nodes++;
            continue;
        }
        InstancedMesh* batch = scene.world.get(cell, InstancedMesh);
        alloc::free(scene.allocator, batch.transforms.ptr);
        alloc::free(scene.allocator, batch.colors.ptr);
        runtime.instances -= batch.count;
        batch.transforms = grown.transforms;
        batch.colors = grown.colors;
        batch.count = 0;
    }
}
