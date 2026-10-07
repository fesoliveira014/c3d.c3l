module c3d::render;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;
import std::sort;

$assert DecalGpu::size == 160;

<* Unit volume transformed by each decal node. *>
const Aabb DECAL_LOCAL_BOUNDS = {
    .min = { -shader::DECAL_HALF_EXTENT, -shader::DECAL_HALF_EXTENT, -shader::DECAL_HALF_EXTENT },
    .max = { shader::DECAL_HALF_EXTENT, shader::DECAL_HALF_EXTENT, shader::DECAL_HALF_EXTENT },
};

<* Borrowed decal and placement selected for a view. *>
struct DecalCandidate {
    Node* node;
    Decal* decal;
}

<* View inclusion and budget results for decals. *>
struct DecalCounts {
    uint packed;
    uint culled;
    uint dropped;
    uint dangling;
}

<*
 Select eligible decals in application order within the view budget.
 @param allocator : "Owns the returned array."
 @param [&in] scene : "Current transforms and valid decal components."
 @param [&in] assets : "Resolves material liveness and kind."
 @param [in] frustum : "Frame-relative planes; null disables frustum culling."
 @param view_layers : "Camera visibility mask."
 @param capacity : "Maximum candidates retained after ordering."
 @param [&inout] counts : "Overwritten with this view's results."
 @param origin : "Absolute origin shared by the frustum."
 @require capacity > 0
*>
fn DecalCandidate[] extract_decals(
    Allocator allocator,
    Scene* scene,
    AssetStore* assets,
    Frustum* frustum,
    uint view_layers,
    uint capacity,
    DecalCounts* counts,
    Vec3 origin = {},
) {
    *counts = {};
    DecalCandidate[] candidates = alloc::new_array(allocator, DecalCandidate, scene.count(Decal));
    scene.@each(Decal; Entity entity, Decal* decal) {
        Node* node = scene.node(entity);
        if (node.visible_effective && (node.layers & view_layers) && decal.receiver_layers) {
            include_decal(
                candidates: candidates,
                node: node,
                decal: decal,
                assets: assets,
                frustum: frustum,
                counts: counts,
                origin: origin,
            );
        }
    };
    candidates = candidates[:counts.packed];
    sort::quicksort(candidates, &compare_decal_candidates);
    uint selected_count = math::min(counts.packed, capacity);
    counts.dropped = counts.packed - selected_count;
    counts.packed = selected_count;
    return candidates[:counts.packed];
}

<*
 Order decals by authored order, entity index and generation.
 @return "Negative when first applies earlier."
 @pure
*>
fn int compare_decal_candidates(DecalCandidate first, DecalCandidate second) {
    if (first.decal.order != second.decal.order) return first.decal.order < second.decal.order ? -1 : 1;
    if (first.node.id.index != second.node.id.index) return first.node.id.index < second.node.id.index ? -1 : 1;
    if (first.node.id.generation != second.node.id.generation) {
        return first.node.id.generation < second.node.id.generation ? -1 : 1;
    }
    return 0;
}

<*
 Pack a selected decal relative to the frame origin.
 @param [&in] node : "Finite, nonsingular affine world transform."
 @param [&in] decal : "Valid component description."
 @param material : "Address of the resolved standard material block."
 @param origin : "Absolute origin shared by receiver positions."
 @require decal_world_valid(maths::rebase(node.world, origin))
*>
fn DecalGpu pack_decal(
    Node* node,
    Decal* decal,
    gpu::GpuAddress material,
    Vec3 origin = {},
) {
    Mat4 world = maths::rebase(node.world, origin);
    Mat4 inverse = maths::inverse_affine(world);
    Vec3 tangent = normalized_decal_axis({ world.m00, world.m10, world.m20 });
    Vec3 projection = normalized_decal_axis({ world.m02, world.m12, world.m22 });
    float cosine = math::cos(decal.fade_angle);
    float band = math::min(shader::DECAL_FADE_BAND, 1.0f - cosine);
    return {
        .world_to_local_0 = { inverse.m00, inverse.m01, inverse.m02, inverse.m03 },
        .world_to_local_1 = { inverse.m10, inverse.m11, inverse.m12, inverse.m13 },
        .world_to_local_2 = { inverse.m20, inverse.m21, inverse.m22, inverse.m23 },
        .local_to_world_0 = { world.m00, world.m01, world.m02, world.m03 },
        .local_to_world_1 = { world.m10, world.m11, world.m12, world.m13 },
        .local_to_world_2 = { world.m20, world.m21, world.m22, world.m23 },
        .projection_fade = { projection.x, projection.y, projection.z, band > 0 ? 1.0f / band : 0 },
        .tangent = { tangent.x, tangent.y, tangent.z, world.determinant() < 0 ? 1 : -1 },
        .weights = {
            decal.weights.base_color,
            decal.weights.normal,
            decal.weights.roughness,
            decal.weights.metallic,
        },
        .material = material,
        .receiver_layers = decal.receiver_layers,
        .fade_cosine = cosine,
    };
}

// mirrored as decal_angle_weight in decals.glsl
<*
 Angular opacity from the packed fade parameters.
 @param facing_cosine : "Geometric normal dotted with projection direction."
 @param inverse_band : "Reciprocal fade width; zero selects the hard limit."
 @pure
*>
fn float decal_angle_weight(float facing_cosine, float fade_cosine, float inverse_band) {
    if (inverse_band == 0) return facing_cosine >= 1 ? 1 : 0;
    return math::clamp((facing_cosine - fade_cosine) * inverse_band, 0.0f, 1.0f);
}

// mirrored as decal_intersects in light_cull.comp.glsl
<*
 Whether the transformed decal box intersects every clipping half-space.
 @param [&in] decal : "Packed frame-relative affine volume."
 @param planes : "Inward-facing planes in the same frame space."
 @pure
*>
fn bool decal_intersects_planes(DecalGpu* decal, Plane[] planes) {
    Vec3 center = { decal.local_to_world_0.w, decal.local_to_world_1.w, decal.local_to_world_2.w };
    Vec3 half_x = (Vec3){ decal.local_to_world_0.x, decal.local_to_world_1.x, decal.local_to_world_2.x }
      * shader::DECAL_HALF_EXTENT;
    Vec3 half_y = (Vec3){ decal.local_to_world_0.y, decal.local_to_world_1.y, decal.local_to_world_2.y }
      * shader::DECAL_HALF_EXTENT;
    Vec3 half_z = (Vec3){ decal.local_to_world_0.z, decal.local_to_world_1.z, decal.local_to_world_2.z }
      * shader::DECAL_HALF_EXTENT;
    foreach (plane : planes) {
        float radius = math::abs(plane.normal.dot(half_x)) + math::abs(plane.normal.dot(half_y))
          + math::abs(plane.normal.dot(half_z));
        if (plane.normal.dot(center) + plane.d < -radius) return false;
    }
    return true;
}

fn bool decal_world_valid(Mat4 world) @private {
    float determinant = world.determinant();
    if (determinant == 0 || !math::is_finite(determinant)) return false;
    Mat4 inverse = maths::inverse_affine(world);
    foreach (value : ((float*)&inverse)[:Mat4::size / float::size]) {
        if (!math::is_finite(value)) return false;
    }
    return true;
}

fn Vec3 normalized_decal_axis(Vec3 axis) @local {
    float largest = math::max(math::abs(axis.x), math::max(math::abs(axis.y), math::abs(axis.z)));
    return (axis / largest).normalize();
}

fn void include_decal(
    DecalCandidate[] candidates,
    Node* node,
    Decal* decal,
    AssetStore* assets,
    Frustum* frustum,
    DecalCounts* counts,
    Vec3 origin,
) @local {
    if (!assets.materials.is_live(decal.material)
      || assets.material(decal.material).data.kind != MaterialKind.STANDARD) {
        counts.dangling++;
        return;
    }
    Mat4 world = maths::rebase(node.world, origin);
    if (!decal_world_valid(world)) return;
    Aabb bounds = maths::aabb_transform(DECAL_LOCAL_BOUNDS, world);
    if (frustum && !maths::frustum_intersects_aabb(frustum, bounds)) {
        counts.culled++;
        return;
    }
    candidates[counts.packed++] = { .node = node, .decal = decal };
}
