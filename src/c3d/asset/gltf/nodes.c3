module c3d::asset::gltf;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import gltf;
import std::math;

const int TEMPLATE_ROOT_PARENT @private = -1;

struct ImportCounts @private {
    usz nodes;
    usz meshes;
    usz cameras;
    usz lights;
}

macro @each_root(Importer* importer; @body(root)) @private {
    gltf::Data* data = importer.data;
    if (data.scene) {
        foreach (root : data.scene.nodes) @body(root);
    } else {
        foreach (&node : data.nodes) {
            if (!node.parent) @body(node);
        }
    }
}

fn void? build_template(Importer* importer) @private {
    ImportCounts counts;
    @each_root(importer; root) {
        count_subtree(importer, root, &counts);
    };

    Allocator allocator = importer.assets.allocator;
    importer.template = {
        .nodes   = alloc::new_array(allocator, NodeTemplate, (sz)counts.nodes),
        .meshes  = alloc::new_array(allocator, ModelMesh, (sz)counts.meshes),
        .cameras = alloc::new_array(allocator, ModelCamera, (sz)counts.cameras),
        .lights  = alloc::new_array(allocator, ModelLight, (sz)counts.lights),
    };

    ImportCounts cursor;
    @each_root(importer; root) {
        emit_subtree(importer, root, TEMPLATE_ROOT_PARENT, &cursor)!;
    };
    return;
}

fn void count_subtree(Importer* importer, gltf::Node* node, ImportCounts* counts) @private {
    counts.nodes++;
    if (node.mesh) {
        counts.nodes += node.mesh.primitives.len;
        counts.meshes += node.mesh.primitives.len;
    }
    if (node.camera && importer.options.cameras) counts.cameras++;
    if (node.light && importer.options.lights) counts.lights++;
    foreach (child : node.children) count_subtree(importer, child, counts);
}

fn void? emit_subtree(
    Importer* importer,
    gltf::Node* node,
    int parent,
    ImportCounts* cursor,
) @private {
    gltf::Data* data = importer.data;
    Allocator allocator = importer.assets.allocator;
    ModelTemplate* template = &importer.template;

    uint index = (uint)cursor.nodes++;
    importer.node_remap[gltf::node_index(data, node)] = index;
    template.nodes[index] = {
        .parent  = parent,
        .name    = copy_name(allocator, node.name),
        .local   = node_transform(node)!,
        .layers  = scene::DEFAULT_LAYERS,
        .visible = true,
    };

    if (node.mesh) {
        usz mesh_index = gltf::mesh_index(data, node.mesh);
        float[] weights = node.weights.len ? node.weights : node.mesh.weights;
        foreach (usz primitive_index, &primitive : node.mesh.primitives) {
            if (weights.len && weights.len != primitive.targets.len) return c3d::ASSET_FORMAT_ERROR~;
            uint child = (uint)cursor.nodes++;
            template.nodes[child] = {
                .parent  = (int)index,
                .name    = string::format(allocator, "%s/primitive/%d", template.nodes[index].name, primitive_index),
                .local   = maths::TRANSFORM_IDENTITY,
                .layers  = scene::DEFAULT_LAYERS,
                .visible = true,
            };
            MaterialId material;
            if (primitive.material) {
                material = importer.materials[gltf::material_index(data, primitive.material)];
            } else {
                material = default_material(importer)!;
            }
            template.meshes[cursor.meshes++] = {
                .node                  = child,
                .geometry              = importer.geometries[importer.mesh_offsets[mesh_index] + primitive_index],
                .material              = material,
                .default_morph_weights = default_weights(allocator, weights, primitive.targets.len),
            };
        }
    }
    if (node.camera && importer.options.cameras) {
        template.cameras[cursor.cameras++] = { .node = index, .value = convert_camera(node.camera)! };
    }
    if (node.light && importer.options.lights) {
        template.lights[cursor.lights++] = { .node = index, .value = convert_light(node.light)! };
    }

    foreach (child : node.children) emit_subtree(importer, child, (int)index, cursor)!;
    return;
}

fn Transform? node_transform(gltf::Node* node) @private {
    if (!node.has_matrix) {
        return {
            .position = node.translation,
            .rotation = { .v = node.rotation },
            .scale    = node.scale,
        };
    }
    Transform? decomposed = maths::transform_from_affine(bitcast(node.matrix, Mat4));
    if (catch decomposed) return c3d::ASSET_FORMAT_ERROR~;
    return decomposed;
}

fn float[] default_weights(Allocator allocator, float[] weights, usz target_count) @private {
    if (!target_count) return {};
    float[] defaults = alloc::new_array(allocator, float, (sz)target_count);
    if (weights.len) defaults[..] = weights[..];
    return defaults;
}
