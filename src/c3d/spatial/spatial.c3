module c3d::spatial;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::math;
import std::sort;

<*
 Defaults of one picking query: bounds precision, the material's side policy, every layer.
*>
const PickOptions PICK_OPTIONS_DEFAULT = {
    .precision = PickPrecision.BOUNDS,
    .faces     = PickFaces.MATERIAL,
    .layers    = camera::ALL_LAYERS,
};

<*
 Depth of the intersection one query computes.
*>
enum PickPrecision {
    BOUNDS,
    TRIANGLES,
}

<*
 Which triangle sides a triangle query accepts.
*>
enum PickFaces {
    MATERIAL,
    BOTH,
    FRONT,
}

<*
 Result filters of one picking query.
*>
struct PickOptions {
    PickPrecision precision;
    PickFaces     faces;
    uint          layers;
}

<*
 One object the ray meets.
*>
struct PickHit {
    Node* node;
    bool  instanced;
    uint  instance_index;
    float distance;
    Vec3  position;
    bool  triangle_hit;
    uint  triangle_index;
    Vec3  barycentric;
}

<*
 Objects the ray meets, nearest first; an empty slice means no hit.
 @param allocator : "Owns the returned array."
 @param [&in] assets : "Resolves geometry bounds and the material side."
 @param [&in] scene : "Pose as left by the last Scene.update_world."
 @param ray : "World space; the distances are world units when the direction is normalized."
 @param options : "Precision, accepted sides and layer mask."
 @require ray.direction.is_normalized()
*>
fn PickHit[] pick(
    Allocator allocator,
    AssetStore* assets,
    Scene* scene,
    Ray ray,
    PickOptions options = PICK_OPTIONS_DEFAULT,
) {
    PickHit[] hits = alloc::new_array(allocator, PickHit, scene.count(Mesh));
    uint count = 0;

    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective && (options.layers & node.layers) != 0
            && assets.geometries.is_live(mesh.geometry)) {
            GeometryAsset* record = assets.geometry(mesh.geometry);
            Aabb bounds = mesh.has_bounds_override ? mesh.local_bounds : record.data.bounds;
            Mat4 inverse_world = maths::inverse_affine(node.world);
            Ray local_ray = {
                .origin    = maths::transform_point(inverse_world, ray.origin),
                .direction = maths::transform_dir(inverse_world, ray.direction),
            };

            float entry;
            if (maths::ray_intersects_aabb(local_ray, bounds, &entry)) {
                PickHit hit = {
                    .node     = node,
                    .distance = entry,
                    .position = ray.origin + ray.direction * entry,
                };
                bool found = true;
                if (options.precision == PickPrecision.TRIANGLES
                    && triangles_usable(
                        scene:  scene,
                        node:   node,
                        mesh:   mesh,
                        record: record,
                    )) {
                    found = nearest_triangle(
                        hit:       &hit,
                        ray:       ray,
                        local_ray: local_ray,
                        assets:    assets,
                        material:  mesh.material,
                        record:    record,
                        faces:     options.faces,
                    );
                }
                if (found) {
                    hits[count] = hit;
                    count++;
                }
            }
        }
    };

    sort::quicksort(hits[:count], &by_distance);
    return hits[:count];
}

fn bool nearest_triangle(
    PickHit* hit,
    Ray ray,
    Ray local_ray,
    AssetStore* assets,
    MaterialId material,
    GeometryAsset* record,
    PickFaces faces,
) @local {
    bool indexed = record.data.indices.len > 0;
    usz corners = indexed ? record.data.indices.len : record.data.positions.len;
    float nearest = math::FLOAT_MAX;

    for (usz index = 0; index < corners / 3; index++) {
        uint[<3>] corner = { (uint)(index * 3), (uint)(index * 3 + 1), (uint)(index * 3 + 2) };
        if (indexed) {
            foreach (&vertex : corner) *vertex = record.data.indices[*vertex];
        }
        Vec3 first = record.data.positions[corner[0]];
        Vec3 second = record.data.positions[corner[1]];
        Vec3 third = record.data.positions[corner[2]];

        float distance;
        Vec3 barycentric;
        if (!intersect_triangle(
            ray:         local_ray,
            first:       first,
            second:      second,
            third:       third,
            distance:    &distance,
            barycentric: &barycentric,
        )) continue;
        if (distance >= nearest) continue;

        Vec3 normal = (second - first).cross(third - first);
        bool back_side = normal.dot(local_ray.origin - first) <= 0;
        if (back_side && !accepts_back_side(assets, material, faces)) continue;

        nearest = distance;
        *hit = {
            .node           = hit.node,
            .distance       = distance,
            .position       = ray.origin + ray.direction * distance,
            .triangle_hit   = true,
            .triangle_index = (uint)index,
            .barycentric    = barycentric,
        };
    }

    return nearest < math::FLOAT_MAX;
}

fn bool accepts_back_side(AssetStore* assets, MaterialId material, PickFaces faces) @local {
    switch (faces) {
        case MATERIAL:
            return !assets.materials.is_live(material)
                || assets.material(material).data.common.double_sided;
        case BOTH:
            return true;
        case FRONT:
            return false;
    }
}

fn bool triangles_usable(
    Scene* scene,
    Node* node,
    Mesh* mesh,
    GeometryAsset* record,
) @local {
    if (record.data.topology != Topology.TRIANGLES || !record.data.positions.len) return false;
    if (scene.get(node, SkinBinding) != null || mesh.has_bounds_override) return false;

    foreach (weight : mesh.morph_weights) {
        if (weight != 0) return false;
    }
    return true;
}

fn bool intersect_triangle(
    Ray ray,
    Vec3 first,
    Vec3 second,
    Vec3 third,
    float* distance,
    Vec3* barycentric,
) @local {
    Vec3 edge1 = second - first;
    Vec3 edge2 = third - first;
    Vec3 pvec = ray.direction.cross(edge2);
    float determinant = edge1.dot(pvec);
    if (determinant == 0) return false;

    float inverse_determinant = 1.0f / determinant;
    Vec3 tvec = ray.origin - first;
    float u = tvec.dot(pvec) * inverse_determinant;
    if (u < 0 || u > 1) return false;

    Vec3 qvec = tvec.cross(edge1);
    float v = ray.direction.dot(qvec) * inverse_determinant;
    if (v < 0 || u + v > 1) return false;

    float parameter = edge2.dot(qvec) * inverse_determinant;
    if (parameter <= 0) return false;

    *distance = parameter;
    *barycentric = { 1 - u - v, u, v };
    return true;
}

fn int by_distance(PickHit first, PickHit second) @local {
    if (first.distance < second.distance) return -1;
    if (first.distance > second.distance) return 1;
    if (first.node.id.index < second.node.id.index) return -1;
    return first.node.id.index > second.node.id.index ? 1 : 0;
}
