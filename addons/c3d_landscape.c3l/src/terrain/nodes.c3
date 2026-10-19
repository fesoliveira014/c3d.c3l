module c3d::landscape::terrain;

import c3d;
import c3d::maths;
import c3d::scene;
import std::math;

fn Aabb node_box(TerrainRuntime* runtime, TerrainDesc* desc, QuadNode node) @private {
    uint index = node_index(runtime, node);
    float edge = (float)(CHUNK_CELLS << node.level) * desc.cell_size;
    float unit = desc.height_scale / TEXEL_MAX;
    return {
        .min = { (float)node.x * edge, (float)runtime.minimum[index] * unit, (float)node.z * edge },
        .max = { (float)(node.x + 1) * edge, (float)runtime.maximum[index] * unit, (float)(node.z + 1) * edge },
    };
}

fn void write_node_record(
    TerrainRuntime* runtime,
    TerrainDesc* desc,
    InstancedMesh* batch,
    QuadNode node,
) @private {
    uint index = node_index(runtime, node);
    Aabb box = node_box(runtime, desc, node);
    uint span = CHUNK_CELLS << node.level;
    // A flat node keeps a nonzero box height: instance culling and picking invert the instance matrix.
    float height = max(box.max.y - box.min.y, desc.height_scale / TEXEL_MAX);
    batch.transforms[index] = {
        .position = box.min,
        .rotation = quaternion::IDENTITY,
        .scale    = { box.max.x - box.min.x, height, box.max.z - box.min.z },
    };
    batch.colors[index] = { (float)(node.x * span), (float)(node.z * span), (float)span, box.min.y };
}

fn void write_node_records(TerrainRuntime* runtime, TerrainDesc* desc, InstancedMesh* batch) @private {
    for (uint level = 0; level < runtime.level_count; level++) {
        uint side = level_side(runtime, level);
        for (uint z = 0; z < side; z++) {
            for (uint x = 0; x < side; x++) {
                write_node_record(
                    runtime: runtime,
                    desc:    desc,
                    batch:   batch,
                    node:    { .level = level, .x = x, .z = z },
                );
            }
        }
    }
}

fn void write_parents(TerrainRuntime* runtime, uint[] parents) @private {
    for (uint level = 0; level < runtime.level_count; level++) {
        uint side = level_side(runtime, level);
        bool top = level + 1 == runtime.level_count;
        for (uint z = 0; z < side; z++) {
            for (uint x = 0; x < side; x++) {
                uint index = node_index(runtime, { .level = level, .x = x, .z = z });
                if (top) {
                    parents[index] = scene::QUADTREE_ROOT;
                } else {
                    parents[index] = node_index(runtime, { .level = level + 1, .x = x >> 1, .z = z >> 1 });
                }
            }
        }
    }
}

fn void? install_quadtree(Scene* scene, Node* node, TerrainRuntime* runtime, TerrainDesc* desc) @private {
    @pool() {
        uint[] parents = alloc::new_array(tmem, uint, (sz)node_count(runtime));
        write_parents(runtime, parents);
        scene.set_instance_quadtree(
            node:         node,
            parents:      parents,
            split_pixels: desc.lod_threshold,
            hysteresis:   desc.lod_hysteresis,
        )!;
    };
    apply_quadtree_ranges(scene, node, runtime, desc)!;
}

fn void hide_batch(Scene* scene, Node* node) @private {
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    if (batch.quadtree.parents.len) {
        scene.set_instance_quadtree(
            node:         node,
            parents:      {},
            split_pixels: 0,
            hysteresis:   0,
        )!!;
    }

    if (batch.count) {
        batch.count = 0;
        scene.mark_instances_dirty(node);
    }
}

// Records change in place, so every view keeps its selection history; a hidden batch gets its topology back.
fn void? publish_nodes(Scene* scene, Node* node, TerrainRuntime* runtime, TerrainDesc* desc) @private {
    InstancedMesh* batch = scene.get(node, InstancedMesh);
    bool hidden = !batch.quadtree.parents.len;
    write_node_records(runtime, desc, batch);
    if (hidden) batch.count = node_count(runtime);

    scene.mark_instances_dirty(node);
    if (hidden) {
        defer catch hide_batch(scene, node);
        install_quadtree(scene, node, runtime, desc)!;
    }
}

// The thresholds are not topology: an edit keeps every view's history.
fn void apply_lod_tunables(InstancedMesh* batch, TerrainDesc* desc) @private {
    if (!batch.quadtree.parents.len) return;

    batch.quadtree.split_pixels = desc.lod_threshold;
    batch.quadtree.hysteresis = desc.lod_hysteresis;
}

// Indexed by depth: the root is depth 0, and the finest level is the last entry.
fn void level_bounds(TerrainRuntime* runtime, TerrainDesc* desc, QuadtreeLevel[] levels) @private {
    float unit = desc.height_scale / TEXEL_MAX;
    for (uint level = 0; level < runtime.level_count; level++) {
        float edge = (float)(CHUNK_CELLS << level) * desc.cell_size;
        uint side = level_side(runtime, level);
        // A flat node keeps a nonzero box height, as its record does.
        float tallest = unit;
        for (uint index = runtime.level_offset[level]; index < runtime.level_offset[level] + side * side; index++) {
            tallest = max(tallest, (float)(runtime.maximum[index] - runtime.minimum[index]) * unit);
        }
        levels[runtime.level_count - 1 - level] = {
            .extent   = edge,
            .diagonal = math::sqrt(2 * edge * edge + tallest * tallest),
        };
    }
}

fn bool morph_outdated(InstancedMesh* batch, TerrainDesc* desc) @private {
    InstanceQuadtree* quadtree = &batch.quadtree;
    if (!quadtree.parents.len) return false;
    if (!(desc.morph_band > 0)) return quadtree.metric == QuadtreeMetric.BOX_RANGES;

    return quadtree.metric != QuadtreeMetric.BOX_RANGES || quadtree.morph_band != desc.morph_band;
}

// The batch keeps its parameters when nothing differs: a changed block uploads again for every view.
fn void? apply_quadtree_ranges(Scene* scene, Node* node, TerrainRuntime* runtime, TerrainDesc* desc) @private {
    InstanceQuadtree* quadtree = &scene.get(node, InstancedMesh).quadtree;
    if (!quadtree.parents.len) return;

    if (!(desc.morph_band > 0)) {
        if (quadtree.metric == QuadtreeMetric.BOX_RANGES) scene.set_quadtree_ranges(node, {}, 0)!;
        return;
    }

    QuadtreeLevel[MAX_TERRAIN_LEVELS] storage;
    QuadtreeLevel[] levels = storage[:runtime.level_count];
    level_bounds(runtime, desc, levels);
    bool unchanged = quadtree.metric == QuadtreeMetric.BOX_RANGES && quadtree.morph_band == desc.morph_band;
    foreach (depth, level : levels) {
        unchanged = unchanged && quadtree.levels[depth].extent == level.extent
            && quadtree.levels[depth].diagonal == level.diagonal;
    }
    if (unchanged) return;

    scene.set_quadtree_ranges(node, levels, desc.morph_band)!;
}
