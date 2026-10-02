module c3d::asset::gltf;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::scene;
import gltf;
import std::collections::object;
import std::encoding::json;
import std::math;

const float[scene::MAX_LOD_LEVELS - 1] DEFAULT_LOD_SIZES @local = { 0.2f, 0.1f, 0.05f, 0.025f };

struct ImportedLod @local {
    uint[scene::MAX_LOD_LEVELS] roots;
    float[scene::MAX_LOD_LEVELS] sizes;
    uint count;
    bool supported;
}

fn void? convert_lod_groups(Importer* importer) @private {
    gltf::Data* data = importer.data;
    bool required;
    foreach (extension : data.extensions_required) required |= extension.str_view() == "MSFT_lod";
    if (required) {
        foreach (&material : data.materials) {
            foreach (extension : material.extensions[:material.extensions_count]) {
                if (extension.name.str_view() == "MSFT_lod") return c3d::UNSUPPORTED~;
            }
        }
    }
    ImportedLod[] descriptions = alloc::new_array(tmem, ImportedLod, data.nodes.len);
    uint[] owners = alloc::new_array(tmem, uint, data.nodes.len);
    owners[..] = uint::max;
    foreach (uint index, &node : data.nodes) {
        foreach (extension : node.extensions[:node.extensions_count]) {
            if (extension.name.str_view() != "MSFT_lod") continue;
            if (descriptions[index].count) return c3d::ASSET_FORMAT_ERROR~;
            descriptions[index] = parse_lod(importer, index, extension.data.str_view())!;
        }
    }
    foreach (uint owner, &description : descriptions) {
        if (!description.count) continue;
        description.supported = true;
        foreach (root : description.roots[:description.count]) {
            claim_lod_subtree(
                data: data,
                node: &data.nodes[root],
                owner: owner,
                owners: owners,
                supported: &description.supported,
            )!;
        }
    }
    usz count;
    foreach (index, description : descriptions) {
        if (!description.count) continue;
        if (!description.supported) {
            if (required) return c3d::UNSUPPORTED~;
            continue;
        }
        if (importer.node_remap[index] != usz::max) count++;
    }
    ModelTemplate* template = &importer.template;
    template.lod_groups = alloc::new_array(importer.allocator, ModelLodGroup, (sz)count);
    bool[] suppressed = alloc::new_array(tmem, bool, template.nodes.len);
    usz slot;
    foreach (uint owner, description : descriptions) {
        if (!description.count || !description.supported || importer.node_remap[owner] == usz::max) continue;
        ModelLodGroup* group = &template.lod_groups[slot++];
        group.node = (uint)importer.node_remap[owner];
        group.desc.levels = alloc::new_array(importer.allocator, LodLevel, description.count);
        usz part_count;
        foreach (root : description.roots[:description.count]) part_count += count_lod_parts(&data.nodes[root]);
        if (part_count > uint::max) return c3d::ASSET_FORMAT_ERROR~;
        group.desc.parts = alloc::new_array(importer.allocator, LodPart, (sz)part_count);
        Mat4 base = node_transform(&data.nodes[owner])!.to_mat4();
        if (base.determinant() == 0) return c3d::ASSET_FORMAT_ERROR~;
        Mat4 inverse = maths::inverse_affine(base);
        uint next;
        foreach (uint level, root : description.roots[:description.count]) {
            uint first = next;
            emit_lod_parts(
                importer: importer,
                node: &data.nodes[root],
                parent: inverse,
                parts: group.desc.parts,
                next: &next,
            )!;
            group.desc.levels[level] = {
                .first_part = first,
                .part_count = next - first,
                .min_screen_size = description.sizes[level],
            };
        }
        if (catch scene::validate_lod_layout(group.desc)) return c3d::ASSET_FORMAT_ERROR~;
        foreach (index, node_owner : owners) {
            if (node_owner != owner || importer.node_remap[index] == usz::max) continue;
            gltf::Node* node = &data.nodes[index];
            if (!node.mesh) continue;
            usz first = importer.node_remap[index] + 1;
            suppressed[first:node.mesh.primitives.len] = true;
        }
    }
    usz kept;
    foreach (mesh : template.meshes) {
        if (suppressed[mesh.node]) {
            alloc::free(importer.allocator, mesh.default_morph_weights.ptr);
        } else {
            template.meshes[kept++] = mesh;
        }
    }
    template.meshes = template.meshes[:kept];
}

fn ImportedLod? parse_lod(Importer* importer, uint owner, String extension) @local {
    Object*? parsed = json::tparse(extension, JsonFlavor.JSON);
    if (catch parsed) return c3d::ASSET_FORMAT_ERROR~;
    if (!parsed.is_map()) return c3d::ASSET_FORMAT_ERROR~;
    Object*? ids = parsed.get("ids");
    if (catch ids) return c3d::ASSET_FORMAT_ERROR~;
    if (!ids.is_array() || !ids.len() || ids.len() >= scene::MAX_LOD_LEVELS) return c3d::ASSET_FORMAT_ERROR~;
    ImportedLod description = { .count = (uint)ids.len() + 1 };
    description.roots[0] = owner;
    for (sz index = 0; index < ids.len(); index++) {
        Object* value = ids.get_at(index);
        if (!value.is_int() || value.i < 0 || value.i >= importer.data.nodes.len) return c3d::ASSET_FORMAT_ERROR~;
        description.roots[index + 1] = (uint)value.i;
        description.sizes[index] = DEFAULT_LOD_SIZES[index];
    }
    gltf::Node* node = &importer.data.nodes[owner];
    if (!node.extras.data) return description;
    Object*? extras = json::tparse(node.extras.data.str_view(), JsonFlavor.JSON);
    if (catch extras) return c3d::ASSET_FORMAT_ERROR~;
    if (!extras.is_map()) return description;
    Object*? coverage = extras.get("MSFT_screencoverage");
    if (catch coverage) return description;
    if (!coverage.is_array() || coverage.len() != description.count) return c3d::ASSET_FORMAT_ERROR~;
    double previous = double::max;
    for (uint index = 0; index < description.count; index++) {
        Object* value = coverage.get_at(index);
        if (!value.is_float() && !value.is_int()) return c3d::ASSET_FORMAT_ERROR~;
        double size = coverage.get_float_at(index)!!;
        if (!math::is_finite(size) || size < 0 || size > float::max) {
            return c3d::ASSET_FORMAT_ERROR~;
        }
        if (index < description.count - 1) {
            if (size == 0 || size >= previous) return c3d::ASSET_FORMAT_ERROR~;
            description.sizes[index] = (float)size;
        }
        previous = size;
    }
    return description;
}

fn void? claim_lod_subtree(
    gltf::Data* data,
    gltf::Node* node,
    uint owner,
    uint[] owners,
    bool* supported,
) @local {
    usz index = gltf::node_index(data, node);
    if (owners[index] != uint::max) return c3d::ASSET_FORMAT_ERROR~;
    owners[index] = owner;
    if (node.skin) *supported = false;
    if (node.mesh) {
        foreach (primitive : node.mesh.primitives) {
            if (primitive.targets.len) *supported = false;
        }
    }
    foreach (animation : data.animations) {
        foreach (channel : animation.channels) {
            if (channel.target_node == node && (index != owner || channel.target_path == gltf::AnimationPathType.WEIGHTS)) {
                *supported = false;
            }
        }
    }
    foreach (child : node.children) claim_lod_subtree(
        data: data,
        node: child,
        owner: owner,
        owners: owners,
        supported: supported,
    )!;
}

fn usz count_lod_parts(gltf::Node* node) @local {
    usz count = node.mesh ? node.mesh.primitives.len : 0;
    foreach (child : node.children) count += count_lod_parts(child);
    return count;
}

fn void? emit_lod_parts(
    Importer* importer,
    gltf::Node* node,
    Mat4 parent,
    LodPart[] parts,
    uint* next,
) @local {
    Mat4 local = parent.mul(node_transform(node)!.to_mat4());
    if (node.mesh) {
        usz first = importer.mesh_offsets[gltf::mesh_index(importer.data, node.mesh)];
        foreach (usz index, primitive : node.mesh.primitives) {
            MaterialId material = primitive.material
              ? importer.materials[gltf::material_index(importer.data, primitive.material)] : default_material(importer);
            parts[(*next)++] = { .geometry = importer.geometries[first + index], .material = material, .local = local };
        }
    }
    foreach (child : node.children) emit_lod_parts(
        importer: importer,
        node: child,
        parent: local,
        parts: parts,
        next: next,
    )!;
}
