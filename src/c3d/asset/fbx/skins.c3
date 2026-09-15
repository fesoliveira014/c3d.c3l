module c3d::asset::fbx;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::maths;
import std::math;
import ufbx;

const int NO_JOINT_PARENT @private = -1;

fn void? convert_skins(Importer* importer) @private {
    ufbx::Scene* scene = importer.scene;
    usz skin_count;
    foreach (mesh : scene.meshes) {
        if (!mesh.skin_deformers.len) continue;
        skin_count += imported_instances(importer, mesh) * live_part_count(mesh);
    }
    if (!skin_count) return;

    importer.template.skins = alloc::new_array(importer.assets.allocator, ModelSkin, (sz)skin_count);
    usz slot;
    foreach (mesh : scene.meshes) {
        if (!mesh.skin_deformers.len) continue;
        ufbx::SkinDeformer* skin = mesh.skin_deformers[0];
        bool rigid = uses_rigid_joint(importer, mesh, skin);
        SkeletonId skeleton = skeleton_for(
            importer: importer,
            mesh:     mesh,
            skin:     skin,
            rigid:    rigid,
        )!;
        foreach (instance : mesh.instances) {
            uint node_index = importer.node_remap[instance.typed_id];
            if (node_index == NOT_IMPORTED) continue;
            // Part children are emitted directly after their mesh node.
            uint child = node_index + 1;
            foreach (&part : mesh.material_parts) {
                if (!part.num_triangles) continue;
                importer.template.skins[slot++] = {
                    .mesh_node   = child,
                    .skeleton    = skeleton,
                    .joint_nodes = joint_nodes(
                        importer:  importer,
                        skin:      skin,
                        rigid:     rigid,
                        mesh_node: child,
                    ),
                };
                child++;
            }
        }
    }
    return;
}

fn usz imported_instances(Importer* importer, ufbx::Mesh* mesh) @private {
    usz count;
    foreach (instance : mesh.instances) {
        if (importer.node_remap[instance.typed_id] != NOT_IMPORTED) count++;
    }
    return count;
}

fn bool uses_rigid_joint(Importer* importer, ufbx::Mesh* mesh, ufbx::SkinDeformer* skin) @private {
    ushort rigid_joint = (ushort)skin.clusters.len;
    usz first_slot = importer.part_offsets[mesh.typed_id];
    foreach (usz part_index, &part : mesh.material_parts) {
        GeometryId geometry = importer.geometries[first_slot + part_index];
        if (!geometry.generation) continue;
        foreach (joints : importer.assets.geometry(geometry).data.joints) {
            if (joints[0] == rigid_joint) return true;
        }
    }
    return false;
}

fn SkeletonId? skeleton_for(
    Importer* importer,
    ufbx::Mesh* mesh,
    ufbx::SkinDeformer* skin,
    bool rigid,
) @private {
    if (importer.skeletons[skin.typed_id].generation) return importer.skeletons[skin.typed_id];

    alloc::Allocator allocator = importer.assets.allocator;
    usz joint_count = skin.clusters.len + (rigid ? 1 : 0);
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(allocator, String, (sz)joint_count),
        .parents      = alloc::new_array(allocator, int, (sz)joint_count),
        .rest_pose    = alloc::new_array(allocator, maths::Transform, (sz)joint_count),
        .inverse_bind = alloc::new_array(allocator, Mat4, (sz)joint_count),
    };
    defer catch asset::free_skeleton(allocator, &skeleton);

    foreach (index, cluster : skin.clusters) {
        ufbx::Node* bone = cluster.bone_node;
        if (!bone) return c3d::ASSET_FORMAT_ERROR~;
        skeleton.joint_names[index] = copy_name(allocator, bone.name);
        skeleton.parents[index] = joint_parent(skin, bone);
        skeleton.rest_pose[index] = importer.template.nodes[importer.node_remap[bone.typed_id]].local;
        skeleton.inverse_bind[index] = matrix_of(cluster.geometry_to_bone);
    }
    if (rigid) {
        usz last = skin.clusters.len;
        skeleton.joint_names[last] = copy_name(allocator, mesh.name);
        skeleton.parents[last] = NO_JOINT_PARENT;
        skeleton.rest_pose[last] = maths::TRANSFORM_IDENTITY;
        skeleton.inverse_bind[last] = matrix::IDENTITY4;
    }

    String key = string::tformat("%s#skeleton/%d", importer.key, skin.typed_id);
    importer.skeletons[skin.typed_id] = importer.assets.add_skeleton_owned(&skeleton, key)!;
    return importer.skeletons[skin.typed_id];
}

fn int joint_parent(ufbx::SkinDeformer* skin, ufbx::Node* bone) @private {
    for (ufbx::Node* ancestor = bone.parent; ancestor; ancestor = ancestor.parent) {
        foreach (index, cluster : skin.clusters) {
            if (cluster.bone_node == ancestor) return (int)index;
        }
    }
    return NO_JOINT_PARENT;
}

fn uint[] joint_nodes(
    Importer* importer,
    ufbx::SkinDeformer* skin,
    bool rigid,
    uint mesh_node,
) @private {
    uint[] joints = alloc::new_array(importer.assets.allocator, uint, skin.clusters.len + (rigid ? 1 : 0));
    foreach (index, cluster : skin.clusters) joints[index] = importer.node_remap[cluster.bone_node.typed_id];
    if (rigid) joints[skin.clusters.len] = mesh_node;
    return joints;
}

fn Mat4 matrix_of(ufbx::Matrix source) @private {
    float[16] columns = {
        (float)source.m00, (float)source.m10, (float)source.m20, 0,
        (float)source.m01, (float)source.m11, (float)source.m21, 0,
        (float)source.m02, (float)source.m12, (float)source.m22, 0,
        (float)source.m03, (float)source.m13, (float)source.m23, 1,
    };
    return bitcast(columns, Mat4);
}
