module c3d::render;

import c3d;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::collections::map;
import std::hash::fnv32a;
import std::math;

alias InstanceEffectsCache @private = HashMap{ulong, gpu::GpuAddress};

<*
 Share of the fade band one instance takes to collapse.
*>
const float FADE_COLLAPSE_SHARE = 0.25f; // larger reads softer and thins later; smaller pops

struct InstanceEffectsView @private {
    InstanceEffectsCache blocks;
    Scene*               scene;
    ViewHistory*         history; // null on a view that keeps no history
    Vec3                 fade_origin;
    LodSelection[]       lod;
}

<*
 Draw flags the batch's sway and fade select.
 VERTEX_ALPHA sets its flag alone; only sway or fade needs a block.
 @pure
*>
fn uint instance_effect_flags(InstanceSway sway, InstanceFade fade) {
    return (sway.amplitude > 0 ? shader::DRAW_SWAY : 0)
      | (fade.end > 0 ? shader::DRAW_DISTANCE_FADE : 0)
      | (sway.weight == SwayWeight.VERTEX_ALPHA ? shader::DRAW_SWAY_VERTEX_ALPHA : 0);
}

<*
 Stable per-instance value in [0, 1) from the node-local position.
*>
fn float instance_seed(Vec3 local_position) {
    return (float)(fnv32a::hash(@as_char_view(local_position)) >> 8) / (float)(1u << 24);
}

<*
 Sway state at one time: unit direction, amplitude and phase in [0, 1].
 @param time : "Seconds of FrameInfo.time."
 @param origin : "Absolute origin of the shader's anchor coordinates."
 @param world_shift : "Total offset the scene was rebased by; added to the origin phase in double."
 @require sway.amplitude == 0 || sway.direction.length() > 0
*>
fn SwayGpu pack_sway(
    InstanceSway sway,
    double time,
    Vec3 origin = {},
    double[<3>] world_shift = {},
) {
    if (sway.amplitude == 0) return {};
    Vec3 direction = sway.direction.normalize();
    float waves_per_unit = sway.wavelength > 0 ? 1.0f / sway.wavelength : 0;
    double[<3>] anchor = { (double)origin.x, (double)origin.y, (double)origin.z };
    anchor += world_shift;
    double origin_phase = (anchor.x * (double)direction.x
      + anchor.y * (double)direction.y + anchor.z * (double)direction.z) * (double)waves_per_unit;
    double cycles = time * (double)sway.frequency - origin_phase;
    return {
        .direction_amplitude = { direction.x, direction.y, direction.z, sway.amplitude },
        .phase               = (float)(cycles - math::floor(cycles)),
        .lean                = sway.lean,
        .waves_per_unit      = waves_per_unit,
        .variation           = sway.variation,
    };
}

<*
 Sway and fade block one view's draws of a batch read.
 @param [&in] batch : "Live batch with sway or fade on."
 @param local_bounds : "Instance-local bound: the geometry's, or a crowd part's pose bound."
 @param fade_origin : "Relative position of the view's camera."
 @param previous_sway : "Sway the view last drew the batch with; the current one without history."
 @param time : "Seconds of FrameInfo.time."
 @param origin : "Absolute origin shared by anchors and camera."
 @param world_shift : "Total offset the batch's scene was rebased by."
*>
fn InstanceEffectsGpu pack_instance_effects(
    InstancedMesh* batch,
    Aabb local_bounds,
    Vec3 fade_origin,
    SwayGpu previous_sway,
    double time,
    Vec3 origin = {},
    double[<3>] world_shift = {},
) {
    float height = local_bounds.max.y - local_bounds.min.y;
    Vec3 center = (local_bounds.min + local_bounds.max) * 0.5f;
    return {
        .sway            = pack_sway(batch.sway, time, origin, world_shift),
        .previous_sway   = previous_sway,
        .anchor          = { center.x, local_bounds.min.y, center.z, height > 0 ? 1.0f / height : 0 },
        .fade_origin     = { fade_origin.x, fade_origin.y, fade_origin.z, 0 },
        .fade_start      = batch.fade.start,
        .fade_end        = batch.fade.end,
        .fade_transition = (batch.fade.end - batch.fade.start) * FADE_COLLAPSE_SHARE,
    };
}

<*
 Collapse scale of an instance at a camera distance; CPU twin of the vertex and cull stages.
 @param seed : "Instance seed in [0, 1)."
 @param distance : "World distance from the view camera to the instance anchor."
 @return "1 before the band, 0 once collapsed."
 @require fade.start >= 0 && fade.start < fade.end
 @pure
*>
fn float instance_fade_scale(InstanceFade fade, float seed, float distance) {
    float transition = (fade.end - fade.start) * FADE_COLLAPSE_SHARE;
    float vanish = fade.start + transition + seed * (fade.end - fade.start - transition);
    return math::clamp((vanish - distance) / transition, 0.0f, 1.0f);
}

fn uint batch_effect_flags(MeshCandidate* candidate) @private {
    if (candidate.lod) return instance_effect_flags(candidate.lod.state.effects.sway, candidate.lod.state.effects.fade);
    if (!candidate.batch) return 0;
    return instance_effect_flags(candidate.batch.sway, candidate.batch.fade);
}

fn gpu::GpuAddress? resolve_instance_effects(
    Renderer* renderer,
    InstanceEffectsView* effects_view,
    MeshCandidate* candidate,
    GpuGeometry* geometry,
) @private {
    if ((batch_effect_flags(candidate) & (shader::DRAW_SWAY | shader::DRAW_DISTANCE_FADE)) == 0) {
        return (gpu::GpuAddress)0;
    }
    ulong key = (ulong)(uptr)candidate.node;
    if (try existing = effects_view.blocks.get(key)) return existing;
    InstancedMesh* batch = candidate.batch;
    InstancedMesh logical;
    if (candidate.lod) {
        logical.sway = candidate.lod.state.effects.sway;
        logical.fade = candidate.lod.state.effects.fade;
        batch = &logical;
    }
    double time = renderer.info.time;
    double[<3>] world_shift = effects_view.scene.world_shift;
    ViewHistory* history = effects_view.history;
    bool has_previous = history && history.has_previous(effects_view.scene, candidate.node);
    SwayGpu current_sway = pack_sway(batch.sway, time, renderer.frame_origin, world_shift);
    SwayGpu previous_sway = has_previous
      ? pack_sway(
          sway:        history.previous_pose(effects_view.scene, candidate.node).sway,
          time:        history.time,
          origin:      history.origin,
          world_shift: world_shift,
      )
      : current_sway;
    if (candidate.lod) {
        bool valid = candidate.lod.state.mode == LodMode.INSTANCED ? candidate.lod.history_valid : !candidate.lod.reject_history;
        previous_sway = valid ? candidate.lod.history.sway : current_sway;
    }
    InstanceEffectsGpu block = pack_instance_effects(
        batch:         batch,
        local_bounds:  candidate.lod ? candidate.lod.state.object_bounds : (candidate.crowd ? candidate.crowd.pose_bounds : geometry.bounds),
        fade_origin:   effects_view.fade_origin,
        previous_sway: previous_sway,
        time:          time,
        origin:        renderer.frame_origin,
        world_shift:   world_shift,
    );
    gpu::GpuAddress address = upload_bytes(renderer, &block, InstanceEffectsGpu::size)!;
    effects_view.blocks.set(key, address);
    return address;
}
