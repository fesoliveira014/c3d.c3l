module c3d::render;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::light;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

$assert ReflectionProbeSetGpu::size == 16 + ReflectionProbeGpu::size * shader::REFLECTION_PROBE_CAPACITY;
$assert shader::REFLECTION_PROJECTION_BOX == (uint)ReflectionProjection.BOX.ordinal;
$assert shader::REFLECTION_PROJECTION_INFINITE == (uint)ReflectionProjection.INFINITE.ordinal;

const float REFLECTION_NO_EXIT @local = float::max; // mirrored as REFLECTION_NO_EXIT in reflection_probe.glsl

// A probe a view keeps, from gathering through packing.
struct ReflectionCandidate @private {
    Entity           entity;
    ReflectionProbe* probe;
    Node*            node;
    float            distance;    // camera to the box, 0 inside
    float            box_volume;  // product of the half extents
    EnvironmentRes*  environment; // set once the environment resolves
}

// Probes a view could not keep.
struct ReflectionCounts @private {
    uint dropped;     // past the nearest REFLECTION_PROBE_CAPACITY
    uint dangling;    // live probes naming a dead environment
    uint unavailable; // CPU copy released before this renderer uploaded it
}

// Mirrored as ReflectionSelection in reflection_probe.glsl.
struct ReflectionSelection @private {
    uint  count;
    uint  first;
    uint  second;
    float first_weight;
    float second_weight;
    float global_weight;
    Vec3  first_position;
    Vec3  second_position;
}

<*
 @require light::reflection_probe_valid(probe)
*>
fn ReflectionProbeGpu reflection_probe_record(
    ReflectionProbe* probe,
    Mat4 world,
    Vec3 origin,
    gpu::TextureIndex specular_cube,
    gpu::TextureIndex sheen_cube,
) @private {
    Vec3 axis_x = (Vec3){ world.m00, world.m10, world.m20 }.normalize();
    Vec3 axis_y = (Vec3){ world.m01, world.m11, world.m21 }.normalize();
    Vec3 axis_z = (Vec3){ world.m02, world.m12, world.m22 }.normalize();
    Vec3 center = maths::translation(world) - origin;
    Vec3 extent = probe.half_extents;
    Vec3 capture = probe.capture_offset;
    // At most the smallest half extent, so every box reaches full weight at its centre.
    float blend = math::min(probe.blend_distance, math::min(extent.x, extent.y, extent.z));
    return {
        .center_intensity = { center.x, center.y, center.z, probe.intensity },
        .axis_x_extent    = { axis_x.x, axis_x.y, axis_x.z, extent.x },
        .axis_y_extent    = { axis_y.x, axis_y.y, axis_y.z, extent.y },
        .axis_z_extent    = { axis_z.x, axis_z.y, axis_z.z, extent.z },
        .capture_blend    = { capture.x, capture.y, capture.z, blend },
        .specular_cube    = specular_cube,
        .sheen_cube       = sheen_cube,
        .projection       = (uint)probe.projection.ordinal,
    };
}

fn Vec3 reflection_probe_local(ReflectionProbeGpu* probe, Vec3 relative) @private {
    return {
        probe.axis_x_extent.xyz.dot(relative),
        probe.axis_y_extent.xyz.dot(relative),
        probe.axis_z_extent.xyz.dot(relative),
    };
}

fn Vec3 reflection_probe_world(ReflectionProbeGpu* probe, Vec3 local_direction) @private {
    return probe.axis_x_extent.xyz * local_direction.x
        + probe.axis_y_extent.xyz * local_direction.y
        + probe.axis_z_extent.xyz * local_direction.z;
}

fn Vec3 reflection_probe_extent(ReflectionProbeGpu* probe) @local {
    return { probe.axis_x_extent.w, probe.axis_y_extent.w, probe.axis_z_extent.w };
}

// Mirrored as reflection_probe_weight in reflection_probe.glsl.
fn float reflection_probe_weight(ReflectionProbeGpu* probe, Vec3 local_position) @private {
    Vec3 inside = reflection_probe_extent(probe) - math::abs(local_position);
    float face_distance = math::min(inside.x, inside.y, inside.z);
    if (face_distance < 0) return 0;
    float blend = probe.capture_blend.w;
    return blend > 0 ? math::min(face_distance / blend, 1.0f) : 1;
}

// Mirrored as reflection_probe_select in reflection_probe.glsl.
fn ReflectionSelection reflection_probe_select(ReflectionProbeSetGpu* set, Vec3 position) @private {
    ReflectionSelection selection = { .global_weight = 1 };
    float second_weight;
    for (uint index = 0; index < set.count; index++) {
        ReflectionProbeGpu* probe = &set.probes[index];
        Vec3 local_position = reflection_probe_local(probe, position - probe.center_intensity.xyz);
        float weight = reflection_probe_weight(probe, local_position);
        if (weight == 0) continue;
        if (selection.count == 0) {
            selection.count = 1;
            selection.first = index;
            selection.first_weight = weight;
            selection.first_position = local_position;
            if (weight == 1) break;
        } else {
            selection.count = 2;
            selection.second = index;
            selection.second_position = local_position;
            second_weight = weight;
            break;
        }
    }
    selection.second_weight = (1 - selection.first_weight) * second_weight;
    selection.global_weight = (1 - selection.first_weight) * (1 - second_weight);
    return selection;
}

// Mirrored as reflection_box_direction in reflection_probe.glsl.
fn Vec3 reflection_box_direction(ReflectionProbeGpu* probe, Vec3 local_position, Vec3 direction) @private {
    if (probe.projection == shader::REFLECTION_PROJECTION_INFINITE) return direction;
    Vec3 local_direction = reflection_probe_local(probe, direction);
    Vec3 extent = reflection_probe_extent(probe);
    Vec3 exits = { REFLECTION_NO_EXIT, REFLECTION_NO_EXIT, REFLECTION_NO_EXIT };
    for (usz axis = 0; axis < 3; axis++) {
        if (local_direction[axis] > 0) {
            exits[axis] = (extent[axis] - local_position[axis]) / local_direction[axis];
        } else if (local_direction[axis] < 0) {
            exits[axis] = (-extent[axis] - local_position[axis]) / local_direction[axis];
        }
    }
    float exit_distance = math::min(exits.x, exits.y, exits.z);
    Vec3 exit_point = local_position + local_direction * exit_distance;
    return reflection_probe_world(probe, exit_point - probe.capture_blend.xyz);
}

<*
 @require light::reflection_probe_valid(probe)
*>
fn float reflection_probe_distance(ReflectionProbe* probe, Mat4 world, Vec3 point) @private {
    ReflectionProbeGpu record = reflection_probe_record(
        probe:         probe,
        world:         world,
        origin:        point,
        specular_cube: (gpu::TextureIndex)0,
        sheen_cube:    (gpu::TextureIndex)0,
    );
    Vec3 camera = reflection_probe_local(&record, -record.center_intensity.xyz);
    Vec3 outside = math::max(math::abs(camera) - probe.half_extents, (Vec3){});
    return outside.length();
}

<*
 @require kept.len == shader::REFLECTION_PROBE_CAPACITY
*>
fn usz gather_reflection_probes(
    Scene* scene,
    AssetStore* assets,
    ViewCamera* view_camera,
    ReflectionCandidate[] kept,
    ReflectionCounts* counts,
) @private {
    Vec3 camera_position = maths::translation(view_camera.world);
    usz count;
    scene.@each(ReflectionProbe; Entity entity, ReflectionProbe* probe) {
        Node* node = scene.node(entity);
        if (reflection_probe_seen(node, view_camera)) {
            if (assets.environments.is_live(probe.environment)) {
                count = keep_nearest_reflection_probe(
                    kept:      kept,
                    count:     count,
                    candidate: {
                        .entity     = entity,
                        .probe      = probe,
                        .node       = node,
                        .distance   = reflection_probe_distance(probe, node.world, camera_position),
                        .box_volume = probe.half_extents.x * probe.half_extents.y * probe.half_extents.z,
                    },
                    counts:    counts,
                );
            } else if (probe.environment.generation) {
                counts.dangling++;
            }
        }
    };
    return count;
}

<*
 @require count <= kept.len, kept.len > 0
*>
fn usz keep_nearest_reflection_probe(
    ReflectionCandidate[] kept,
    usz count,
    ReflectionCandidate candidate,
    ReflectionCounts* counts,
) @private {
    usz position = count;
    while (position > 0 && reflection_nearer(&candidate, &kept[position - 1])) position--;
    if (position == kept.len) {
        counts.dropped++;
        return count;
    }
    if (count == kept.len) {
        counts.dropped++;
        count--;
    }
    for (usz index = count; index > position; index--) kept[index] = kept[index - 1];
    kept[position] = candidate;
    return count + 1;
}

fn void sort_reflection_candidates(ReflectionCandidate[] candidates) @private {
    for (usz index = 1; index < candidates.len; index++) {
        ReflectionCandidate moved = candidates[index];
        usz position = index;
        while (position > 0 && reflection_selected_before(&moved, &candidates[position - 1])) {
            candidates[position] = candidates[position - 1];
            position--;
        }
        candidates[position] = moved;
    }
}

<*
 @require picks.len == shader::REFLECTION_PROBE_CAPACITY
*>
fn usz? select_view_reflection_probes(
    Renderer* renderer,
    Scene* scene,
    ViewCamera* view_camera,
    bool sheen,
    ReflectionCandidate[] picks,
) @private {
    ReflectionCounts counts;
    usz gathered = gather_reflection_probes(
        scene:       scene,
        assets:      renderer.assets,
        view_camera: view_camera,
        kept:        picks,
        counts:      &counts,
    );
    usz count;
    foreach (&gathered_pick : picks[:gathered]) {
        EnvironmentRes*? resolved = resolve_environment(
            renderer:    renderer,
            environment: gathered_pick.probe.environment,
            lighting:    true,
            sheen:       sheen,
        );
        if (catch excuse = resolved) {
            if (excuse != c3d::ASSET_DATA_UNAVAILABLE) return excuse~;
            counts.unavailable++;
            continue;
        }
        ReflectionCandidate pick = *gathered_pick;
        pick.environment = resolved;
        picks[count++] = pick;
    }
    sort_reflection_candidates(picks[:count]);
    renderer.stats.reflection_probes_dropped += counts.dropped;
    renderer.stats.reflection_probes_unavailable += counts.unavailable;
    renderer.stats.dangling_refs += counts.dangling;
    return count;
}

fn gpu::GpuAddress? pack_reflection_probes(Renderer* renderer, ReflectionCandidate[] picks, bool sheen) @private {
    if (!picks.len) return (gpu::GpuAddress)0;
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan span = slot.upload.take(&renderer.device, ReflectionProbeSetGpu::size, STREAM_ALIGNMENT)!;
    ReflectionProbeSetGpu* set = (ReflectionProbeSetGpu*)span.bytes.ptr;
    *set = {
        .count         = (uint)picks.len,
        .brdf_lut      = renderer.environment_state.brdf_lut.view.index,
        .sampler_index = renderer.environment_state.sampler,
    };
    foreach (index, &pick : picks) {
        set.probes[index] = reflection_probe_record(
            probe:         pick.probe,
            world:         pick.node.world,
            origin:        renderer.frame_origin,
            specular_cube: pick.environment.specular_view.index,
            sheen_cube:    sheen ? pick.environment.sheen_view.index : (gpu::TextureIndex)0,
        );
    }
    return span.address;
}

fn void? prepare_reflection_probes(Renderer* renderer, Scene* scene, bool sheen) @private {
    scene.@each(ReflectionProbe; Entity entity, ReflectionProbe* probe) {
        if (renderer.assets.environments.is_live(probe.environment)) {
            EnvironmentRes*? resolved = resolve_environment(
                renderer:    renderer,
                environment: probe.environment,
                lighting:    true,
                sheen:       sheen,
            );
            if (catch excuse = resolved) {
                if (excuse != c3d::ASSET_DATA_UNAVAILABLE) return excuse~;
            }
        }
    };
}

fn bool reflection_probe_seen(Node* node, ViewCamera* view_camera) @local {
    if (c3d::same_id(node.id, view_camera.excluded_probe)) return false;
    return node.visible_effective && (node.layers & view_camera.camera.layers) != 0;
}

fn bool reflection_nearer(ReflectionCandidate* first, ReflectionCandidate* second) @local {
    if (first.distance != second.distance) return first.distance < second.distance;
    return first.entity.index < second.entity.index;
}

fn bool reflection_selected_before(ReflectionCandidate* first, ReflectionCandidate* second) @local {
    if (first.probe.priority != second.probe.priority) return first.probe.priority > second.probe.priority;
    if (first.box_volume != second.box_volume) return first.box_volume < second.box_volume;
    return first.entity.index < second.entity.index;
}
