module c3d::asset::fbx;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::scene;
import std::math;
import ufbx;

const int TEMPLATE_ROOT_PARENT @private = -1;
const float MAX_SPOT_HALF_ANGLE @private = (float)math::PI / 2;

struct ImportCounts @private {
    usz nodes;
    usz meshes;
    usz cameras;
    usz lights;
}

fn void? build_template(Importer* importer) @private {
    ufbx::Node* root = importer.scene.root_node;
    ImportCounts counts;
    foreach (child : root.children) count_subtree(importer, child, &counts);

    alloc::Allocator allocator = importer.assets.allocator;
    importer.template = {
        .nodes   = alloc::new_array(allocator, NodeTemplate, (sz)counts.nodes),
        .meshes  = alloc::new_array(allocator, ModelMesh, (sz)counts.meshes),
        .cameras = alloc::new_array(allocator, ModelCamera, (sz)counts.cameras),
        .lights  = alloc::new_array(allocator, ModelLight, (sz)counts.lights),
    };

    ImportCounts cursor;
    foreach (child : root.children) {
        emit_subtree(
            importer: importer,
            node:     child,
            parent:   TEMPLATE_ROOT_PARENT,
            cursor:   &cursor,
        )!;
    }
    return;
}

fn void count_subtree(Importer* importer, ufbx::Node* node, ImportCounts* counts) @private {
    counts.nodes++;
    if (node.mesh) {
        usz parts = live_part_count(node.mesh);
        counts.nodes += parts;
        counts.meshes += parts;
    }
    if (node.camera && importer.options.cameras) counts.cameras++;
    if (node.light && importer.options.lights && light_supported(node.light)) counts.lights++;
    foreach (child : node.children) count_subtree(importer, child, counts);
}

fn void? emit_subtree(
    Importer* importer,
    ufbx::Node* node,
    int parent,
    ImportCounts* cursor,
) @private {
    ModelTemplate* template = &importer.template;
    uint index = (uint)cursor.nodes++;
    importer.node_remap[node.typed_id] = index;
    template.nodes[index] = {
        .parent  = parent,
        .name    = copy_name(importer.assets.allocator, node.name),
        .local   = transform_of(node.local_transform),
        .layers  = scene::DEFAULT_LAYERS,
        .visible = node.visible,
    };

    if (node.mesh) {
        emit_parts(
            importer: importer,
            node:     node,
            index:    index,
            cursor:   cursor,
        )!;
    }
    if (node.camera && importer.options.cameras) {
        template.cameras[cursor.cameras++] = { .node = index, .value = convert_camera(node.camera)! };
    }
    if (node.light && importer.options.lights && light_supported(node.light)) {
        template.lights[cursor.lights++] = { .node = index, .value = convert_light(node.light)! };
    }

    foreach (child : node.children) {
        emit_subtree(
            importer: importer,
            node:     child,
            parent:   (int)index,
            cursor:   cursor,
        )!;
    }
    return;
}

fn void? emit_parts(
    Importer* importer,
    ufbx::Node* node,
    uint index,
    ImportCounts* cursor,
) @private {
    alloc::Allocator allocator = importer.assets.allocator;
    ModelTemplate* template = &importer.template;
    ufbx::Mesh* mesh = node.mesh;
    maths::Transform local = node.has_geometry_transform
        ? transform_of(node.geometry_transform)
        : maths::TRANSFORM_IDENTITY;
    foreach (usz part_index, &part : mesh.material_parts) {
        if (!part.num_triangles) continue;
        uint child = (uint)cursor.nodes++;
        template.nodes[child] = {
            .parent  = (int)index,
            .name    = string::format(allocator, "%s/part/%d", template.nodes[index].name, part_index),
            .local   = local,
            .layers  = scene::DEFAULT_LAYERS,
            .visible = true,
        };
        template.meshes[cursor.meshes++] = {
            .node                  = child,
            .geometry              = importer.geometries[importer.part_offsets[mesh.typed_id] + part_index],
            .material              = part_material(importer, node, part)!,
            .default_morph_weights = default_morph_weights(allocator, mesh),
        };
    }
    return;
}

fn MaterialId? part_material(Importer* importer, ufbx::Node* node, ufbx::MeshPart* part) @private {
    ufbx::Material* source;
    if (part.index < node.materials.len) {
        source = node.materials[part.index];
    } else if (part.index < node.mesh.materials.len) {
        source = node.mesh.materials[part.index];
    }
    if (source) return importer.materials[source.typed_id];
    return default_material(importer);
}

fn float[] default_morph_weights(alloc::Allocator allocator, ufbx::Mesh* mesh) @private {
    usz channels = channel_count(mesh);
    if (!channels) return {};
    float[] weights = alloc::new_array(allocator, float, (sz)channels);
    usz slot;
    @each_channel(mesh; ufbx::BlendChannel* channel) {
        weights[slot++] = (float)channel.weight;
    };
    return weights;
}

fn maths::Transform transform_of(ufbx::Transform source) @private {
    return {
        .position = narrow_vec3(source.translation),
        .rotation = { .v = {
            (float)source.rotation.x,
            (float)source.rotation.y,
            (float)source.rotation.z,
            (float)source.rotation.w,
        } },
        .scale    = narrow_vec3(source.scale),
    };
}

fn bool light_supported(ufbx::Light* source) @private {
    switch (source.type) {
        case POINT:
        case DIRECTIONAL:
        case SPOT:
            return true;
        case AREA:
        case VOLUME:
            return false;
    }
}

fn light::Light? convert_light(ufbx::Light* source) @private {
    vector::Vec3 color = narrow_vec3(source.color);
    float intensity = (float)source.intensity;
    bool in_range = finite_rgb(color) && color.x >= 0 && color.y >= 0 && color.z >= 0
        && math::is_finite(intensity) && intensity >= 0;
    if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
    switch (source.type) {
        case POINT:
            return light::point(color, intensity);
        case DIRECTIONAL:
            return light::directional(color, intensity);
        case SPOT:
            // FBX cone angles are full angles in degrees; c3d takes half angles in radians.
            float inner = (float)math::deg_to_rad(source.inner_angle) / 2;
            float outer = (float)math::deg_to_rad(source.outer_angle) / 2;
            if (!(inner >= 0 && inner < outer && outer <= MAX_SPOT_HALF_ANGLE)) return c3d::ASSET_FORMAT_ERROR~;
            return light::spot(
                color:     color,
                intensity: intensity,
                inner:     inner,
                outer:     outer,
            );
        case AREA:
        case VOLUME:
            return c3d::UNSUPPORTED~;
    }
}

fn camera::Camera? convert_camera(ufbx::Camera* source) @private {
    float near = (float)source.near_plane;
    float far = (float)source.far_plane;
    switch (source.projection_mode) {
        case PERSPECTIVE:
            float field_of_view = (float)math::deg_to_rad(source.field_of_view_deg.y);
            bool in_range = field_of_view > 0 && math::is_finite(field_of_view)
                && near > 0 && math::is_finite(near) && (far == 0 || (far > near && math::is_finite(far)));
            if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
            camera::Camera value = camera::perspective(field_of_view, near, far);
            float aspect = (float)source.aspect_ratio;
            if (aspect > 0 && math::is_finite(aspect)) value.aspect = aspect;
            return value;
        case ORTHOGRAPHIC:
            float height = (float)source.orthographic_size.y;
            bool in_range = height > 0 && math::is_finite(height)
                && math::is_finite(near) && far > near && math::is_finite(far);
            if (!in_range) return c3d::ASSET_FORMAT_ERROR~;
            return camera::orthographic(height, near, far);
    }
}
