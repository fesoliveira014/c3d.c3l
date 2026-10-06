module c3d::render;

import c3d;
import c3d::camera;
import c3d::maths;
import c3d::scene;
import gpu;
import std::math;

struct ShadowCamera @private {
    Camera         lens;
    CameraMatrices matrices;
}

<* Values a shadow set is a function of within one frame. *>
struct ShadowSetKey {
    ulong scene_identity;
    ulong frame;
    Mat4  view;
    Mat4  proj;
    uint  layers;
    bool  ray_traced_shadows;
}

<* Atlas layers one light holds in a shadow set. *>
struct ShadowSetLight {
    Entity light;
    uint   first_layer;
    uint   layer_count;
}

<*
 Atlas contents of the current frame and the lights they shadow.
 Valid only for the frame that recorded it.
*>
struct ShadowSet {
    ShadowSetKey     key;
    bool             published;   // a later view with an equal key binds it instead of recording
    gpu::GpuAddress  shadows;     // ShadowGpu array in the frame's upload ring
    uint             layer_count;
    ShadowSetLight[] lights;      // max_shadow_layers entries, allocated with the renderer
    uint             light_count;
}

fn ShadowCamera? shadow_camera_of(
    Scene* scene,
    Node* camera_node,
    Node* shadow_camera,
    Vec2 viewport,
    Vec3 origin,
) @private {
    Node* node = shadow_camera ? shadow_camera : camera_node;
    Camera* lens = scene.get(node, Camera);
    if (!lens) return c3d::INVALID_ARGUMENT~;
    return {
        .lens     = *lens,
        .matrices = camera::derive_matrices(
            camera:       *lens,
            camera_world: maths::rebase(node.world, origin),
            viewport:     viewport,
        ),
    };
}

fn ShadowSetKey shadow_set_key(
    Scene* scene,
    ulong frame,
    ShadowCamera* shadow_view,
    bool ray_traced_shadows,
) @private {
    return {
        .scene_identity     = scene.identity,
        .frame              = frame,
        .view               = shadow_view.matrices.view,
        .proj               = shadow_view.matrices.proj,
        .layers             = shadow_view.lens.layers,
        .ray_traced_shadows = ray_traced_shadows,
    };
}

fn bool same_shadow_key(ShadowSetKey* first, ShadowSetKey* second) @private {
    // Bitwise: one camera read twice derives identical bits, and a tolerance would merge distinct cameras.
    return first.scene_identity == second.scene_identity
        && first.frame == second.frame
        && mem::equals(@as_char_view(first.view), @as_char_view(second.view))
        && mem::equals(@as_char_view(first.proj), @as_char_view(second.proj))
        && first.layers == second.layers
        && first.ray_traced_shadows == second.ray_traced_shadows;
}

fn bool claim_shadow_set(
    ShadowSet* set,
    ShadowSetKey* key,
    bool share,
    Stats* stats,
) @private {
    if (share && set.published && same_shadow_key(&set.key, key)) {
        stats.shadow_sets_shared++;
        return true;
    }
    set.key = *key;
    set.published = share;
    set.shadows = (gpu::GpuAddress)0;
    set.layer_count = 0;
    set.light_count = 0;
    stats.shadow_sets_recorded++;
    return false;
}

fn uint bind_shadow_set(ShadowSet* set, LightExtraction* extraction) @private {
    uint unmatched = (uint)extraction.shadows.len;
    foreach (request : extraction.shadows) {
        foreach (entry : set.lights[:set.light_count]) {
            if (!c3d::same_id(entry.light, request.light)) continue;
            LightGpu* packed = &extraction.lights[request.light_index];
            packed.shadow_first = entry.first_layer;
            packed.shadow_count = entry.layer_count;
            unmatched--;
            break;
        }
    }
    return unmatched;
}

<*
 @require renderer.frame_open, record.desc.shading != ShadingPath.PATH_TRACED
*>
fn void? resolve_shadow_set(
    Renderer* renderer,
    ViewRecord* record,
    Scene* scene,
    ShadowCamera* own_view,
    ShadowCamera* shadow_view,
    LightExtraction* view_lights,
    AtmosphereSelection* atmosphere,
    InstanceEffectsView* effects_view,
) @private {
    bool ray_traced = record.desc.ray_tracing.shadows;
    ShadowSetKey key = shadow_set_key(
        scene:              scene,
        frame:              renderer.frame_index,
        shadow_view:        shadow_view,
        ray_traced_shadows: ray_traced,
    );
    ShadowSetKey own_key = shadow_set_key(
        scene:              scene,
        frame:              renderer.frame_index,
        shadow_view:        own_view,
        ray_traced_shadows: ray_traced,
    );
    bool own_camera = same_shadow_key(&key, &own_key);
    ShadowSet* set = &renderer.shadow_set;
    bool shared = claim_shadow_set(
        set:   set,
        key:   &key,
        share: record.desc.share_shadows,
        stats: &renderer.stats,
    );
    record.stats.shadow_set_shared = shared;
    if (!shared) {
        LightExtraction set_lights = *view_lights;
        InstanceEffectsView* set_effects = effects_view;
        InstanceEffectsView shadow_effects;
        if (!own_camera) {
            LightCounts counts;
            set_lights = extract_lights(
                allocator:   tmem,
                scene:       scene,
                frustum:     &shadow_view.matrices.frustum,
                view_layers: shadow_view.lens.layers,
                capacity:    renderer.max_lights,
                counts:      &counts,
                atmosphere:  atmosphere,
                altitude:    shadow_view.matrices.position.y + renderer.frame_origin.y,
                ray_tracing: record.desc.ray_tracing,
                origin:      renderer.frame_origin,
            );
            shadow_effects = {
                .scene       = scene,
                .history     = effects_view.history,
                .fade_origin = shadow_view.matrices.position,
                .lod         = effects_view.lod,
            };
            shadow_effects.blocks.init(tmem);
            set_effects = &shadow_effects;
        }
        record_shadows(
            renderer:     renderer,
            scene:        scene,
            shadow_view:  shadow_view,
            extraction:   &set_lights,
            culling:      record.desc.instance_culling,
            effects_view: set_effects,
        )!;
    }
    uint unmatched = bind_shadow_set(set, view_lights);
    if (!own_camera) renderer.stats.shadow_lights_unshared += unmatched;
}
