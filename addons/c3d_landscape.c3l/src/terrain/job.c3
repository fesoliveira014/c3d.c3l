module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import c3d::landscape;
import c3d::scene;
import std::math;

<*
 Detached bounds build of one terrain: its finest chunks as ranges, the reductions and publication at commit.
 Only the job functions read its fields.
*>
struct BoundsJob {
    Entity         node;
    bool           pending;          // the node had no runtime when the job was taken
    TextureId      height_map;
    uint           height_revision;
    uint           height_replaced;
    char*          height_pixels;
    uint           runtime_revision; // the height-map revision the bounds reflected; unread while pending
    bool           has_marked;       // the runtime had a pending rectangle
    TexelRect      marked;           // unread without has_marked
    Mat4           world;
    ushort[]       texels;           // borrowed from the height map
    TerrainRuntime staged;           // the shape and arrays the leaf kernels write; owns nothing
}

struct TraceShape @private {
    bool traced;
    uint level;
}

<*
 Capture a terrain's whole bounds build for detached ranges.
 @param [&in] scene : "World matrices current; the job reads the scene here only."
 @param [&in] assets
 @param [&in] node : "A pending terrain, or a prepared one whose height map changed."
 @param scratch : "Holds the job's leaf arrays; the job never frees them."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, Terrain)
*>
fn BoundsJob? bounds_job(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    Allocator scratch,
) {
    TerrainDesc desc = scene.get(node, Terrain).desc;
    TerrainRuntime* runtime = scene.has(node, TerrainRuntime) ? scene.get(node, TerrainRuntime) : null;
    if (!assets.textures.is_live(desc.height_map)) return c3d::INVALID_ID~;

    TextureAsset* texture = assets.textures.get(desc.height_map);
    check_height_map(texture)!;
    if (runtime) {
        if (texture.desc.width != runtime.texels) return c3d::INVALID_ARGUMENT~;
        if (texture.header.revision == runtime.revision || is_region_refresh(runtime, texture)) {
            return c3d::INVALID_ARGUMENT~;
        }
    } else {
        check_terrain_desc(assets, &desc)!;
    }

    TraceShape shape = trace_shape(runtime, &desc);
    TerrainRuntime staged = {
        .texels      = texture.desc.width,
        .level_count = level_count_of(texture.desc.width)!,
        .trace_level = shape.level,
    };
    uint leaves = level_side(&staged, 0) * level_side(&staged, 0);
    ushort[]? bounds = alloc::new_array_try(scratch, ushort, (sz)leaves * 2);
    if (catch bounds) return c3d::CAPACITY_EXCEEDED~;

    staged.minimum = bounds[:leaves];
    staged.maximum = bounds[leaves:leaves];
    if (shape.traced) {
        float[]? gaps = alloc::new_array_try(scratch, float, (sz)leaves * staged.level_count);
        if (catch gaps) return c3d::CAPACITY_EXCEEDED~;

        staged.trace_deviation = gaps[:leaves];
        staged.drawn_chunk_deviation = gaps[leaves..];
    }

    BoundsJob job = {
        .node            = node.id,
        .pending         = !runtime,
        .height_map      = desc.height_map,
        .height_revision = texture.header.revision,
        .height_replaced = texture.header.replaced_revision,
        .height_pixels   = texture.pixels.ptr,
        .world           = node.world,
        .texels          = height_texels(texture),
        .staged          = staged,
    };
    if (runtime) {
        job.runtime_revision = runtime.revision;
        job.has_marked = runtime.has_pending;
        job.marked = runtime.pending;
    }
    return job;
}

<*
 Finest chunks the job builds, which the ranges split.
*>
fn uint BoundsJob.range_count(&self) => (uint)self.staged.minimum.len;

<*
 Build the bounds of the listed finest chunks, row by row.
 @param [&in] self : "No edit, replacement or removal of the height map during a range."
 @param first : "Position in the finest chunks."
 @require first + count <= self.range_count()
*>
fn void BoundsJob.run_range(&self, uint first, uint count) {
    uint chunks_per_side = level_side(&self.staged, 0);
    for (uint position = first; position < first + count; position++) {
        QuadNode leaf = { .x = position % chunks_per_side, .z = position / chunks_per_side };
        build_leaf(&self.staged, self.texels, leaf);
        if (self.staged.trace_deviation.len) refresh_chunk_gaps(&self.staged, self.texels, leaf);
    }
}

<*
 Publish the job's bounds on the owner thread, as prepare or update would.
 Commit before the next update: an update that rebuilds the terrain first makes the job stale.
 @param [&inout] scene : "Registered with register_terrain."
 @param [&inout] assets : "The store given to register_terrain."
 @param [&in] job : "Every finest chunk built by a range; unchanged."
 @return? landscape::STALE, c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? commit_bounds(Scene* scene, AssetStore* assets, BoundsJob* job) {
    check_job_sources(scene, assets, job)!;
    Node* node = scene.node(job.node);
    if (job.pending) {
        return prepare_pending(
            scene:  scene,
            assets: assets,
            node:   node,
            job:    job,
        );
    }

    return update_node(
        scene:  scene,
        assets: assets,
        node:   node,
        job:    job,
    );
}

fn TraceShape trace_shape(TerrainRuntime* runtime, TerrainDesc* desc) @private {
    if (runtime) return { .traced = runtime.trace_deviation.len > 0, .level = runtime.trace_level };

    return { .traced = desc.trace, .level = desc.trace ? desc.trace_level : 0 };
}

fn bool is_same_rect(TexelRect first, TexelRect second) @private {
    return first.x == second.x && first.z == second.z && first.columns == second.columns && first.rows == second.rows;
}

// Faults STALE unless everything the ranges read and the commit reuses still holds.
fn void? check_job_sources(Scene* scene, AssetStore* assets, BoundsJob* job) @private {
    if (!scene.world.is_alive(job.node) || !scene.world.has(job.node, Terrain)) return landscape::STALE~;

    Node* node = scene.node(job.node);
    bool prepared = scene.has(node, TerrainRuntime);
    if (job.pending == prepared || node.world != job.world) return landscape::STALE~;

    TerrainDesc* desc = &scene.get(node, Terrain).desc;
    if (!c3d::same_id(desc.height_map, job.height_map) || !assets.textures.is_live(job.height_map)) {
        return landscape::STALE~;
    }

    TextureAsset* texture = assets.texture(job.height_map);
    if (texture.header.revision != job.height_revision) return landscape::STALE~;
    if (texture.header.replaced_revision != job.height_replaced || texture.pixels.ptr != job.height_pixels) {
        return landscape::STALE~;
    }

    TerrainRuntime* runtime = prepared ? scene.get(node, TerrainRuntime) : null;
    if (runtime) {
        if (runtime.revision != job.runtime_revision || runtime.has_pending != job.has_marked) {
            return landscape::STALE~;
        }
        if (runtime.has_pending && !is_same_rect(runtime.pending, job.marked)) return landscape::STALE~;
    }

    TraceShape shape = trace_shape(runtime, desc);
    if (shape.traced != (job.staged.trace_deviation.len > 0) || shape.level != job.staged.trace_level) {
        return landscape::STALE~;
    }
}

// The finest chunks of the runtime are the first entries of its bound arrays.
fn void adopt_leaves(TerrainRuntime* runtime, BoundsJob* job) @private {
    runtime.minimum[:job.staged.minimum.len][..] = job.staged.minimum[..];
    runtime.maximum[:job.staged.maximum.len][..] = job.staged.maximum[..];
    runtime.trace_deviation[..] = job.staged.trace_deviation[..];
    runtime.drawn_chunk_deviation[..] = job.staged.drawn_chunk_deviation[..];
}
