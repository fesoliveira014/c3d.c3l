module c3d::render;

import c3d::maths;
import c3d::scene;
import std::math;

const double FRAME_ORIGIN_CELL @private = 256.0; // larger cells reduce resident uploads and trace rebuilds

<*
 Select the nearest render cell for an absolute position.
 @require math::is_finite(reference_position.x)
 @require math::is_finite(reference_position.y)
 @require math::is_finite(reference_position.z)
 @pure
*>
fn Vec3 frame_origin_for(Vec3 reference_position) {
    return {
        (float)(math::floor((double)reference_position.x / FRAME_ORIGIN_CELL + 0.5) * FRAME_ORIGIN_CELL),
        (float)(math::floor((double)reference_position.y / FRAME_ORIGIN_CELL + 0.5) * FRAME_ORIGIN_CELL),
        (float)(math::floor((double)reference_position.z / FRAME_ORIGIN_CELL + 0.5) * FRAME_ORIGIN_CELL),
    };
}

fn Mat4 camera_clip_reprojection(
    Mat4 current_view_proj,
    Mat4 previous_view_proj,
    Vec3 previous_origin,
    Vec3 current_origin,
    Vec2 jitter,
) @private {
    Mat4 unjitter = matrix::IDENTITY4;
    unjitter.m03 = -jitter.x;
    unjitter.m13 = -jitter.y;
    if (current_view_proj == previous_view_proj && current_origin == previous_origin) return unjitter;

    Matrix4x4{double} current;
    Matrix4x4{double} previous;
    Matrix4x4{double} offset = { .m00 = 1, .m11 = 1, .m22 = 1, .m33 = 1 };
    Matrix4x4{double} shift;
    foreach (index, value : current_view_proj.m) current.m[index] = value;
    foreach (index, value : previous_view_proj.m) previous.m[index] = value;
    foreach (index, value : unjitter.m) shift.m[index] = value;
    offset.m03 = (double)current_origin.x - previous_origin.x;
    offset.m13 = (double)current_origin.y - previous_origin.y;
    offset.m23 = (double)current_origin.z - previous_origin.z;
    // Cancel the coordinate translations before narrowing the clip-space mapping.
    Matrix4x4{double} reprojection = previous.mul(offset).mul(current.inverse()!!).mul(shift);
    Mat4 result;
    foreach (index, value : reprojection.m) result.m[index] = (float)value;
    return result;
}

fn Mat4 shift_world(Mat4 world, Vec3 offset) @local {
    world.m03 -= offset.x;
    world.m13 -= offset.y;
    world.m23 -= offset.z;
    return world;
}

fn void shift_view_history_origin(ViewHistory* history, Vec3 offset) @private {
    history.origin -= offset;
}

fn void refresh_history_models(ViewHistory* history, Scene* scene) @private {
    foreach (index, owner : history.owners) {
        if (!scene.world.is_alive(owner)) continue;
        history.models[index] = scene.node(owner).world;
    }
}

fn void shift_lod_history(LodHistoryEntry* entry, ulong scene, Vec3 offset) @private {
    if (entry.committed.scene == scene) entry.committed.origin -= offset;
    if (entry.pending.scene == scene) entry.pending.origin -= offset;
}

fn void shift_instance_slot(GpuInstances* slot, Vec3 offset) @private {
    slot.world = shift_world(slot.world, offset);
    slot.origin -= offset;
}

fn void shift_trace_baseline(SceneTrace* trace, Vec3 offset) @private {
    foreach (&record : trace.baseline[:trace.baseline_count]) record.world = shift_world(record.world, offset);
    trace.origin -= offset;
}

fn void shift_probe_fill(ProbeVolumeRes* mirror, Vec3 offset) @private {
    mirror.fill.traced_origin -= offset;
    mirror.frame_fill.traced_origin -= offset;
}

fn Plane shift_plane(Plane plane, Vec3 offset) @private {
    if (plane.normal == (Vec3){} && plane.d == 0) return plane;
    plane.d += plane.normal.dot(offset);
    return plane;
}

<*
 Re-express the renderer's retained state of one scene after that scene moved by the offset.
 Other scenes this renderer draws are untouched.
 @param [&in] scene : "Already shifted, with world matrices current after update_world."
 @require !self.frame_open
 @require offset.y == 0
*>
fn void Renderer.shift_origin(&self, Scene* scene, Vec3 offset) {
    foreach (&record : self.views.items) {
        if (!record.live) continue;
        if (record.history.scene == scene.identity) {
            refresh_history_models(&record.history, scene);
            shift_view_history_origin(&record.history, offset);
            record.desc.clip_plane = shift_plane(record.desc.clip_plane, offset);
        }
        LodHistory* lod = &record.lod_history;
        for (uint cursor = lod.first; cursor; cursor = lod.entries[cursor - 1].next) {
            shift_lod_history(&lod.entries[cursor - 1], scene.identity, offset);
        }
    }
    foreach (&slot : self.instances.slots) {
        if (slot.key.scene == scene.identity) shift_instance_slot(slot, offset);
    }
    if (self.scene_trace.scene == scene.identity) shift_trace_baseline(&self.scene_trace, offset);
    foreach (&mirror : self.probe_volumes) {
        if (mirror.entity.generation != 0 && mirror.scene == scene.identity) shift_probe_fill(mirror, offset);
    }
}
