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
 Bounds precision, material face policy, every layer.
*>
const PickOptions PICK_OPTIONS_DEFAULT = {
    .precision = PickPrecision.BOUNDS,
    .faces     = PickFaces.MATERIAL,
    .layers    = camera::ALL_LAYERS,
};

<*
 How far a query looks into each mesh.
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
 Query settings; PICK_OPTIONS_DEFAULT picks bounds on every layer.
*>
struct PickOptions {
    PickPrecision precision;
    PickFaces     faces;
    uint          layers;
}

<*
 One mesh the ray met; node and indices are borrows.
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
 Meshes the ray meets, nearest first; empty when nothing is hit.
 @param allocator : "Owns the returned array."
 @param [&in] assets : "Resolves geometry, material and skeleton records."
 @param [&in] scene : "Pose as left by the last update_world."
 @param ray : "World space; direction normalized."
*>
fn PickHit[] pick(
    Allocator allocator,
    AssetStore* assets,
    Scene* scene,
    Ray ray,
    PickOptions options = PICK_OPTIONS_DEFAULT,
) {
    PickHit[] hits = alloc::new_array(allocator, PickHit, scene.count(Mesh));
    usz count;
    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.visible_effective && (options.layers & node.layers) != 0) {
            SkinBinding* skin = scene.get(node, SkinBinding);
            if (mesh_is_live(assets, mesh, skin)) {
                bool hit = hit_mesh(
                    assets:  assets,
                    node:    node,
                    mesh:    mesh,
                    skin:    skin,
                    ray:     ray,
                    options: options,
                    hit:     &hits[count],
                );
                if (hit) count++;
            }
        }
    };
    sort::quicksort(hits[:count], &by_distance);
    return hits[:count];
}

fn bool hit_mesh(
    AssetStore* assets,
    Node* node,
    Mesh* mesh,
    SkinBinding* skin,
    Ray ray,
    PickOptions options,
    PickHit* hit,
) @local {
    Aabb bounds = mesh_world_bounds(
        assets: assets,
        node:   node,
        mesh:   mesh,
        skin:   skin,
    );
    float distance;
    if (!maths::ray_intersects_aabb(ray, bounds, &distance)) return false;
    *hit = {
        .node     = node,
        .distance = distance,
        .position = ray.origin + ray.direction * distance,
    };

    GeometryAsset* record = assets.geometry(mesh.geometry);
    if (options.precision != PickPrecision.TRIANGLES || !triangles_are_static(record, mesh, skin)) return true;
    PickFaces faces = options.faces;
    if (faces == PickFaces.MATERIAL) {
        faces = assets.material(mesh.material).data.common.double_sided ? PickFaces.BOTH : PickFaces.FRONT;
    }
    return nearest_triangle(
        ray:      ray,
        world:    node.world,
        geometry: &record.data,
        faces:    faces,
        hit:      hit,
    );
}

fn bool triangles_are_static(GeometryAsset* record, Mesh* mesh, SkinBinding* skin) @local {
    return !skin && !mesh.has_bounds_override && record.target_count == 0
        && record.data.topology == Topology.TRIANGLES && record.data.positions.len > 0;
}

fn bool nearest_triangle(
    Ray ray,
    Mat4 world,
    Geometry* geometry,
    PickFaces faces,
    PickHit* hit,
) @local {
    Mat4 inverse = maths::inverse_affine(world);
    Ray local = {
        .origin    = maths::transform_point(inverse, ray.origin),
        .direction = maths::transform_dir(inverse, ray.direction),
    };
    usz triangle_count = geometry.indices.len ? geometry.indices.len / 3 : geometry.positions.len / 3;
    bool found;
    for (usz triangle = 0; triangle < triangle_count; triangle++) {
        Vec3[3] corners = corner_positions(geometry, triangle);
        Vec3 edge_ab = corners[1] - corners[0];
        Vec3 edge_ac = corners[2] - corners[0];
        if (faces == PickFaces.FRONT && edge_ab.cross(edge_ac).dot(local.direction) >= 0) continue;
        float distance;
        Vec3 barycentric;
        bool met = maths::ray_intersects_triangle(
            ray:         local,
            a:           corners[0],
            b:           corners[1],
            c:           corners[2],
            distance:    &distance,
            barycentric: &barycentric,
        );
        if (!met) continue;
        if (found && distance >= hit.distance) continue;
        found = true;
        hit.distance = distance;
        hit.triangle_index = (uint)triangle;
        hit.barycentric = barycentric;
    }
    if (found) {
        hit.position = ray.origin + ray.direction * hit.distance;
        hit.triangle_hit = true;
    }
    return found;
}

fn Vec3[3] corner_positions(Geometry* geometry, usz triangle) @local {
    usz first = triangle * 3;
    if (geometry.indices.len == 0) {
        return { geometry.positions[first], geometry.positions[first + 1], geometry.positions[first + 2] };
    }
    return {
        geometry.positions[geometry.indices[first]],
        geometry.positions[geometry.indices[first + 1]],
        geometry.positions[geometry.indices[first + 2]],
    };
}

fn int by_distance(PickHit first, PickHit second) @local {
    if (first.distance < second.distance) return -1;
    if (first.distance > second.distance) return 1;
    if (first.node.id.index < second.node.id.index) return -1;
    return first.node.id.index > second.node.id.index ? 1 : 0;
}
