module c3d::landscape::foliage;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::landscape::terrain;
import c3d::maths;
import c3d::scene;
import std::math;

const float EDIT_REACH_TEXELS @private = 2; // a texel shapes the triangles on both sides; one more covers rounding

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

fn CellRange whole_grid(FoliageRuntime* runtime) @private {
    return { .end_column = runtime.cells_per_side, .end_row = runtime.cells_per_side };
}

// Cells whose candidates can sample a texel of the rectangle, through both node transforms.
fn CellRange cells_meeting(ScatterFrame* frame, FoliageRuntime* runtime, TexelRect rect) @private {
    float texel = frame.ground.cell_size;
    float first_x = ((float)rect.x - EDIT_REACH_TEXELS) * texel;
    float first_z = ((float)rect.z - EDIT_REACH_TEXELS) * texel;
    float last_x = ((float)(rect.x + rect.columns) + EDIT_REACH_TEXELS) * texel;
    float last_z = ((float)(rect.z + rect.rows) + EDIT_REACH_TEXELS) * texel;
    Mat4 layer_from_ground = maths::inverse_affine(frame.layer_world).mul(frame.ground.world);
    Vec2 low = { float::max, float::max };
    Vec2 high = { -float::max, -float::max };
    Vec2[4] corners = { { first_x, first_z }, { last_x, first_z }, { first_x, last_z }, { last_x, last_z } };
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

fn void place_cells(
    Scene* scene,
    ScatterFrame* frame,
    FoliageRuntime* runtime,
    CellRange range,
) @private {
    for (uint row = range.first_row; row < range.end_row; row++) {
        for (uint column = range.first_column; column < range.end_column; column++) {
            Entity cell = runtime.cells[row * runtime.cells_per_side + column];
            if (!cell.generation) continue;
            Node* node = scene.node(cell);
            if (runtime.desc.lod) {
                LodGroupState* state = scene.get(node, LodGroup).state;
                runtime.instances -= state.count;
                uint count = place_cell(
                    frame:      frame,
                    column:     column,
                    row:        row,
                    transforms: state.transforms,
                    colors:     state.colors,
                );
                scene.set_lod_instances(node, state.transforms[:count], state.colors[:count])!!;
                runtime.instances += count;
                runtime.placed_cells++;
                continue;
            }
            InstancedMesh* batch = scene.get(node, InstancedMesh);
            runtime.instances -= batch.count;
            batch.count = place_cell(
                frame:      frame,
                column:     column,
                row:        row,
                transforms: batch.transforms,
                colors:     batch.colors,
            );
            runtime.instances += batch.count;
            scene.mark_instances_dirty(node);
            runtime.placed_cells++;
        }
    }
}

// All or nothing: counts, then the node budget, then every allocation, before any cell changes.
fn void? rescatter(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc* desc,
    ScatterFrame* frame,
    FoliageRuntime* runtime,
) @private {
    uint side = runtime.cells_per_side;
    runtime.count_passes++;
    @pool() {
        uint[] counts = alloc::new_array(tmem, uint, (sz)runtime.cells.len);
        uint new_nodes;
        for (uint row = 0; row < side; row++) {
            for (uint column = 0; column < side; column++) {
                uint index = row * side + column;
                counts[index] = count_cell(frame, column, row);
                if (counts[index] && !runtime.cells[index].generation) new_nodes++;
            }
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
    };
    place_cells(
        scene:   scene,
        frame:   frame,
        runtime: runtime,
        range:   whole_grid(runtime),
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
        if (count <= capacity_of(scene, runtime.cells[index])) continue;
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
