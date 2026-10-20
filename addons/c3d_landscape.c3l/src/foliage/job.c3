module c3d::landscape::foliage;

import c3d;
import c3d::asset;
import c3d::landscape;
import c3d::landscape::terrain @public;
import c3d::scene;
import std::math;

const float REBASE_TOLERANCE @private = 0.01f; // metres; a position far from the origin rounds on the float grid
const usz CELL_ARRAYS @private = 4; // per listed cell: grid index, candidate count, output offset and placed count

<*
 Detached scatter of one foliage layer: counts, then placements, over disjoint cells.
 Only the job functions read its fields.
*>
struct ScatterJob {
    Entity        layer;
    Entity        ground;
    bool          pending;          // the layer had no runtime when the job was taken
    bool          reserved;         // reserve_output succeeded
    ScatterFrame  frame;            // rules, pose, grid and the borrowed sources
    ScatterInputs inputs;           // what the cells are placed against
    uint          height_revision;  // of the ground's height map
    uint          height_replaced;
    char*         height_pixels;
    uint          scatter_revision; // of the layer's runtime; zero while pending
    double[<3>]   world_shift;
    uint[]        cells;            // grid index of each listed cell, each once
    uint[]        counts;           // candidates that pass the density stage
    uint[]        offsets;          // first slot of each cell in the output arrays
    uint[]        placed;           // instances written
    Transform[]   transforms;
    Vec4[]        colors;
}

<*
 Capture a layer's pending scatter for detached ranges.
 Covers a layer attached but not prepared, and a prepared layer whose pose or density changed.
 @param [&in] scene : "World matrices current; the job reads the scene here only."
 @param [&in] assets
 @param scratch : "Holds the job's cell arrays; the job never frees them."
 @return? terrain::NOT_PREPARED
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require !scene.world.is_alive(layer) || terrain::upright_rigid(scene.node(layer).world)
*>
fn ScatterJob? scatter_job(
    Scene* scene,
    AssetStore* assets,
    Entity layer,
    Allocator scratch,
) {
    if (!scene.world.is_alive(layer) || !scene.world.has(layer, Foliage)) return c3d::INVALID_ID~;

    Node* node = scene.node(layer);
    FoliageRuntime* runtime = scene.has(node, FoliageRuntime) ? scene.get(node, FoliageRuntime) : null;
    FoliageDesc desc = runtime ? runtime.desc : scene.get(node, Foliage).desc;
    if (!runtime) check_authoring(scene, assets, &desc)!;
    if (!scene.world.is_alive(desc.ground) || !scene.world.has(desc.ground, Terrain)) return c3d::INVALID_ID~;

    Node* ground = scene.node(desc.ground);
    if (!terrain::is_prepared(scene, ground)) return terrain::NOT_PREPARED~;

    TerrainRuntime* ground_runtime = scene.get(ground, TerrainRuntime);
    TextureAsset* height_map = assets.textures.try_get(scene.get(ground, Terrain).desc.height_map)!;
    if (ground_runtime.has_pending || height_map.header.revision != ground_runtime.revision) {
        return terrain::NOT_PREPARED~;
    }

    ScatterInputs current = current_inputs(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   &desc,
    )!;
    if (runtime && !has_pending_scatter(runtime, current)) return c3d::INVALID_ARGUMENT~;

    ScatterFrame frame = scatter_frame(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   &desc,
    )!;
    uint cells_per_side = frame.grid.cells_per_side;
    if (cells_per_side > MAX_CELLS_PER_SIDE) return c3d::INVALID_ARGUMENT~;

    CellRange[MAX_CHANGED_RANGES] ranges;
    usz range_count = 1;
    if (runtime) {
        range_count = changed_ranges(
            scene:   scene,
            assets:  assets,
            desc:    &desc,
            frame:   &frame,
            runtime: runtime,
            current: current,
            ranges:  ranges[..],
        );
    } else {
        ranges[0] = whole_grid(cells_per_side);
    }

    usz cell_total;
    @distinct_cells(ranges[:range_count]; uint column, uint row) {
        cell_total++;
    };
    ScatterJob job = {
        .layer            = layer,
        .ground           = desc.ground,
        .pending          = !runtime,
        .frame            = frame,
        .inputs           = current,
        .height_revision  = height_map.header.revision,
        .height_replaced  = height_map.header.replaced_revision,
        .height_pixels    = height_map.pixels.ptr,
        .scatter_revision = runtime ? runtime.scatter_revision : 0,
        .world_shift      = scene.world_shift,
    };
    if (!cell_total) return job;

    uint[]? storage = alloc::new_array_try(scratch, uint, (sz)(cell_total * CELL_ARRAYS));
    if (catch storage) return c3d::CAPACITY_EXCEEDED~;

    job.cells = storage[:cell_total];
    job.counts = storage[cell_total:cell_total];
    job.offsets = storage[2 * cell_total:cell_total];
    job.placed = storage[3 * cell_total:cell_total];
    usz position;
    @distinct_cells(ranges[:range_count]; uint column, uint row) {
        job.cells[position++] = row * cells_per_side + column;
    };
    return job;
}

<*
 Cells the job lists.
*>
fn uint ScatterJob.cell_count(&self) => (uint)self.cells.len;

<*
 Count the candidates of the listed cells.
 @param [&in] self : "No edit, link change, replacement or removal of the ground, ring or density map during a range."
 @param first : "Position in the job's cell list."
 @require first + count <= self.cell_count()
*>
fn void ScatterJob.count_range(&self, uint first, uint count) {
    uint cells_per_side = self.frame.grid.cells_per_side;
    for (uint position = first; position < first + count; position++) {
        uint index = self.cells[position];
        self.counts[position] = count_cell(&self.frame, index % cells_per_side, index / cells_per_side);
    }
}

<*
 Instances the output arrays must hold once every count range has run.
*>
fn usz ScatterJob.instance_count(&self) {
    usz total;
    foreach (count : self.counts) total += count;
    return total;
}

<*
 Assign each cell its slots in the output arrays; on the owner thread, after every count range.
 @param [&inout] self
 @param [inout] transforms : "At least instance_count slots; outlive the commit."
 @param [inout] colors : "At least instance_count slots; outlive the commit."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? ScatterJob.reserve_output(&self, Transform[] transforms, Vec4[] colors) {
    usz total = self.instance_count();
    if (transforms.len < total || colors.len < total) return c3d::CAPACITY_EXCEEDED~;

    usz offset;
    foreach (position, count : self.counts) {
        self.offsets[position] = (uint)offset;
        offset += count;
    }
    self.transforms = transforms;
    self.colors = colors;
    self.reserved = true;
}

<*
 Write the instances of the listed cells at their slots.
 @param [&in] self : "No edit, link change, replacement or removal of the ground, ring or density map during a range."
 @param first : "Position in the job's cell list."
 @require self.reserved
 @require first + count <= self.cell_count()
*>
fn void ScatterJob.place_range(&self, uint first, uint count) {
    uint cells_per_side = self.frame.grid.cells_per_side;
    for (uint position = first; position < first + count; position++) {
        uint index = self.cells[position];
        usz offset = self.offsets[position];
        usz capacity = self.counts[position];
        self.placed[position] = place_cell(
            frame:      &self.frame,
            column:     index % cells_per_side,
            row:        index / cells_per_side,
            transforms: self.transforms[offset:capacity],
            colors:     self.colors[offset:capacity],
        );
    }
}

<*
 Publish the job's cells on the owner thread; faults leave the scene as it was.
 Commit before the next update: an update that scatters the layer first makes the job stale.
 @param [&inout] scene
 @param [&in] assets
 @param [&in] job : "Counted, reserved and placed over every listed cell; unchanged."
 @return? landscape::STALE, c3d::CAPACITY_EXCEEDED, c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @require job.reserved
*>
fn void? commit_scatter(Scene* scene, AssetStore* assets, ScatterJob* job) {
    ScatterInputs current = check_job_sources(scene, assets, job)!;
    Node* node = scene.node(job.layer);
    if (scene.has(node, FoliageRuntime)) {
        FoliageRuntime* runtime = scene.get(node, FoliageRuntime);
        apply_scatter(
            scene:   scene,
            assets:  assets,
            node:    node,
            runtime: runtime,
            job:     job,
        )!;
        runtime.placed = current;
        runtime.rejection = {};
        runtime.scatter_revision++;
        return;
    }

    FoliageDesc desc = scene.get(node, Foliage).desc;
    check_authoring(scene, assets, &desc)!;
    FoliageRuntime runtime = create_runtime(scene.allocator, job.frame.grid.cells_per_side, desc)!;
    defer catch free_runtime(&runtime);
    runtime.sway = layer_sway(desc.sway, {});
    apply_scatter(
        scene:   scene,
        assets:  assets,
        node:    node,
        runtime: &runtime,
        job:     job,
    )!;
    runtime.placed = current;
    runtime.scatter_revision++;
    scene.add(node, runtime);
}

// A layer is pending when its pose moved or its density changed; ground and ring edits are re-placed in update.
fn bool has_pending_scatter(FoliageRuntime* runtime, ScatterInputs current) @private {
    ScatterInputs* placed = &runtime.placed;
    bool moved = current.layer_world != placed.layer_world || current.ground_world != placed.ground_world;
    return moved || current.density_revision != placed.density_revision;
}

// Equal fields of every rule a placement reads; ScatterRules has no equality of its own.
fn bool same_rules(ScatterRules* first, ScatterRules* second) @private {
    $assert ScatterRules::size == 68 : "same_rules compares every field";
    return c3d::same_id(first.density_map, second.density_map)
      && first.density_channel == second.density_channel
      && first.spacing == second.spacing
      && first.seed == second.seed
      && first.max_slope == second.max_slope
      && first.min_altitude == second.min_altitude
      && first.max_altitude == second.max_altitude
      && first.min_scale == second.min_scale
      && first.max_scale == second.max_scale
      && first.min_tint == second.min_tint
      && first.max_tint == second.max_tint
      && first.slope_normal == second.slope_normal;
}

// Both poses moved by the origin shift alone: x and z by the shift, nothing else, within float rounding.
fn bool is_rebased(Mat4 before, Mat4 after, Vec3 shift) @private {
    Mat4 expected = before;
    expected.m03 -= shift.x;
    expected.m23 -= shift.z;
    return math::abs(expected.m - after.m).max() <= REBASE_TOLERANCE;
}

fn bool poses_hold(
    Scene* scene,
    ScatterJob* job,
    ScatterInputs current,
) @private {
    ScatterInputs* taken = &job.inputs;
    if (current.layer_world == taken.layer_world && current.ground_world == taken.ground_world) return true;
    if (scene.world_shift == job.world_shift) return false;

    double[<3>] moved = scene.world_shift - job.world_shift;
    Vec3 shift = { (float)moved[0], (float)moved[1], (float)moved[2] };
    return is_rebased(taken.layer_world, current.layer_world, shift)
      && is_rebased(taken.ground_world, current.ground_world, shift);
}

// Faults STALE unless everything the job read still holds, and returns the inputs the cells are placed against now.
fn ScatterInputs? check_job_sources(Scene* scene, AssetStore* assets, ScatterJob* job) @private {
    if (!scene.world.is_alive(job.layer) || !scene.world.is_alive(job.ground)) return landscape::STALE~;
    if (!scene.world.has(job.layer, Foliage) || !scene.world.has(job.ground, Terrain)) return landscape::STALE~;
    if (!scene.world.has(job.ground, TerrainRuntime)) return landscape::STALE~;

    Node* node = scene.node(job.layer);
    FoliageRuntime* runtime = scene.has(node, FoliageRuntime) ? scene.get(node, FoliageRuntime) : null;
    if (job.pending == (runtime != null)) return landscape::STALE~;
    if ((runtime ? runtime.scatter_revision : 0) != job.scatter_revision) return landscape::STALE~;

    FoliageDesc* desc = runtime ? &runtime.desc : &scene.get(node, Foliage).desc;
    if (!c3d::same_id(desc.ground, job.ground) || desc.cell_size != job.frame.cell_size) return landscape::STALE~;
    if (!same_rules(&desc.rules, &job.frame.rules)) return landscape::STALE~;

    TextureId height_map = scene.get(scene.node(job.ground), Terrain).desc.height_map;
    if (!assets.textures.is_live(height_map) || !assets.textures.is_live(desc.rules.density_map)) {
        return landscape::STALE~;
    }

    TextureAsset* texture = assets.textures.get(height_map);
    if (texture.header.revision != job.height_revision) return landscape::STALE~;
    if (texture.header.replaced_revision != job.height_replaced) return landscape::STALE~;
    if (texture.pixels.ptr != job.height_pixels) return landscape::STALE~;

    ScatterInputs current = current_inputs(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   desc,
    )!;
    ScatterInputs* taken = &job.inputs;
    if (current.ground_revision != taken.ground_revision || current.density_revision != taken.density_revision) {
        return landscape::STALE~;
    }
    if (current.ring_revision != taken.ring_revision || current.ring_edges != taken.ring_edges) {
        return landscape::STALE~;
    }
    if (!poses_hold(scene, job, current)) return landscape::STALE~;

    return current;
}

// The job's cells replace the layer's cells all or nothing; the layer's bookkeeping is the caller's.
fn void? apply_scatter(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageRuntime* runtime,
    ScatterJob* job,
) @private {
    @pool() {
        uint[] counts = alloc::new_array(tmem, uint, (sz)runtime.cells.len);
        counts[..] = NOT_COUNTED;
        foreach (position, index : job.cells) counts[index] = job.counts[position];

        install_counts(
            scene:   scene,
            assets:  assets,
            node:    node,
            desc:    &runtime.desc,
            runtime: runtime,
            counts:  counts,
        )!;
    };
    runtime.count_passes++;

    foreach (position, index : job.cells) {
        Entity cell = runtime.cells[index];
        if (!cell.generation) continue;

        Node* target = scene.node(cell);
        CellStorage storage = cell_storage(scene, runtime, target);
        uint count = job.placed[position];
        usz offset = job.offsets[position];
        storage.transforms[:count] = job.transforms[offset:count];
        storage.colors[:count] = job.colors[offset:count];
        publish_cell(
            scene:   scene,
            runtime: runtime,
            node:    target,
            count:   count,
        );
    }
}
