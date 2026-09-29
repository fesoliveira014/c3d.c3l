module c3d::landscape::terrain;

import c3d;
import c3d::camera;
import c3d::maths;
import std::math;

struct SelectFrame @private {
    TerrainRuntime* runtime;
    InstancedMesh*  batch;
    TerrainDesc*    desc;
    Mat4            world;
    float           world_scale;
    Camera          camera;
    Vec3            camera_position;
    float           output_height;
}

// Covers the whole extent; views cull chunks on the GPU, so shadow layers keep casters behind the camera.
fn void select_chunks(SelectFrame* frame) @private {
    TerrainRuntime* runtime = frame.runtime;
    frame.batch.count = 0;
    runtime.chunks_per_level = {};
    runtime.lod_switches = 0;
    visit(frame, { .level = runtime.level_count - 1 });
}

fn void visit(SelectFrame* frame, QuadNode node) @private {
    TerrainRuntime* runtime = frame.runtime;
    Aabb box = node_box(frame, node);
    if (node.level == 0) {
        emit(frame, node, box);
        return;
    }
    uint index = node_index(runtime, node);
    bool was_split = runtime.split[index];
    float size = camera::projected_size(
        camera:          frame.camera,
        camera_position: frame.camera_position,
        bounds:          world_sphere(frame, box),
        output_height:   frame.output_height,
    );
    float threshold = frame.desc.lod_threshold;
    bool split = was_split ? size >= threshold / (1 + frame.desc.lod_hysteresis) : size > threshold;
    runtime.split[index] = split;
    if (split != was_split) runtime.lod_switches++;
    if (!split) {
        if (was_split) clear_splits(runtime, node);
        emit(frame, node, box);
        return;
    }
    for (uint child = 0; child < 4; child++) visit(frame, child_of(node, child));
}

// A split flag holds only while every ancestor is split, so a merge clears the subtree's flags.
fn void clear_splits(TerrainRuntime* runtime, QuadNode node) @private {
    if (node.level == 1) return;
    for (uint child = 0; child < 4; child++) {
        QuadNode below = child_of(node, child);
        uint index = node_index(runtime, below);
        if (!runtime.split[index]) continue;
        runtime.split[index] = false;
        clear_splits(runtime, below);
    }
}

fn Aabb node_box(SelectFrame* frame, QuadNode node) @private {
    TerrainRuntime* runtime = frame.runtime;
    uint index = node_index(runtime, node);
    float edge = (float)(CHUNK_CELLS << node.level) * frame.desc.cell_size;
    float unit = frame.desc.height_scale / TEXEL_MAX;
    return {
        .min = { (float)node.x * edge, (float)runtime.minimum[index] * unit, (float)node.z * edge },
        .max = { (float)(node.x + 1) * edge, (float)runtime.maximum[index] * unit, (float)(node.z + 1) * edge },
    };
}

fn Sphere world_sphere(SelectFrame* frame, Aabb box) @private {
    return {
        .center = maths::transform_point(frame.world, (box.min + box.max) * 0.5f),
        .radius = (box.max - box.min).length() * 0.5f * frame.world_scale,
    };
}

fn float largest_axis_scale(Mat4 world) @private {
    float axis_x = (Vec3){ world.m00, world.m10, world.m20 }.length();
    float axis_y = (Vec3){ world.m01, world.m11, world.m21 }.length();
    float axis_z = (Vec3){ world.m02, world.m12, world.m22 }.length();
    return max(axis_x, axis_y, axis_z);
}

// Writes in place; update marks the batch only when the selection or the bounds changed.
fn void emit(SelectFrame* frame, QuadNode node, Aabb box) @private {
    InstancedMesh* batch = frame.batch;
    uint span = CHUNK_CELLS << node.level;
    // A flat chunk keeps a nonzero box height: instance culling and picking invert the instance matrix.
    float height = max(box.max.y - box.min.y, frame.desc.height_scale / TEXEL_MAX);
    batch.transforms[batch.count] = {
        .position = box.min,
        .rotation = quaternion::IDENTITY,
        .scale    = { box.max.x - box.min.x, height, box.max.z - box.min.z },
    };
    batch.colors[batch.count] = { (float)(node.x * span), (float)(node.z * span), (float)span, box.min.y };
    batch.count++;
    frame.runtime.chunks_per_level[node.level]++;
}
