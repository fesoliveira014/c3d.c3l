module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::physics::cloth @public;
import c3d::scene;
import c3d::serial;
import std::math;

struct CrowdClothPartAuthoring @private {
    uint part;
    ClothSavedAuthoring cloth;
}

struct CrowdClothSavedAuthoring @private {
    CrowdClothPartAuthoring[] parts;
}

fn void? register_crowd_cloth_codec() @private {
    describe::register_reflected(CrowdClothPartAuthoring)!;
    describe::register_reflected(CrowdClothSavedAuthoring)!;
    serial::register_described_type(
        $Type: CrowdClothPartAuthoring,
        version: 1,
        layout: 0xcb65f4fd2d137930,
        defaults: &defaults_crowd_cloth_part,
    )!;
    serial::register_described_type(
        $Type: CrowdClothSavedAuthoring,
        version: 1,
        layout: 0xb81640a6a67efd0a,
        defaults: &defaults_crowd_cloth_authoring,
    )!;
    serial::register_described_owner(CrowdCloth, CrowdClothSavedAuthoring, {
        .name = "crowd_cloth",
        .phase = BINDINGS,
        .collect = &collect_crowd_cloth,
        .project = &project_crowd_cloth,
        .validate = &validate_crowd_cloth,
        .attach = &attach_crowd_cloth,
    })!;
}

fn void defaults_crowd_cloth_part(void* value) @private {
    CrowdClothPartAuthoring* part = value;
    *part = {};
    defaults_cloth_authoring(&part.cloth);
}

fn void defaults_crowd_cloth_authoring(void* value) @private {
    *(CrowdClothSavedAuthoring*)value = {};
}

fn void? check_crowd_cloth_source_geometry(
    AssetStore* assets,
    ModelTemplate* template,
    uint part,
    ClothDesc desc,
) @local {
    if ((usz)part >= template.meshes.len) return c3d::INVALID_ARGUMENT~;
    ModelMesh* model_mesh = &template.meshes[part];
    if (model_mesh.default_morph_weights.len) return c3d::UNSUPPORTED~;
    cloth::check_cloth_material(assets, model_mesh.material, true)!;

    GeometryAsset* source = assets.geometries.try_get(model_mesh.geometry)!;
    Geometry* data = &source.data;
    if (!data.positions.len) return physics::SOURCE_UNAVAILABLE~;
    if (data.targets.len || source.target_count || data.channels.len || data.custom_data.len) {
        return c3d::UNSUPPORTED~;
    }
    if (data.topology != Topology.TRIANGLES || !data.indices.len) return c3d::UNSUPPORTED~;
    if (data.indices.len % 3) return c3d::INVALID_ARGUMENT~;
    foreach (index : data.indices) {
        if (index >= data.positions.len) return c3d::INVALID_ARGUMENT~;
    }
    foreach (position : data.positions) {
        if (!cloth::finite_vector(position)) return c3d::INVALID_ARGUMENT~;
    }

    bool skinned;
    foreach (&skin : template.skins) {
        if (skin.mesh_node == model_mesh.node) {
            skinned = true;
            SkeletonAsset* skel_record = assets.skeletons.try_get(skin.skeleton)!;
            if (!skin.joint_nodes.len || skin.joint_nodes.len != skel_record.data.parents.len
              || skin.joint_nodes.len != skel_record.data.inverse_bind.len) {
                return c3d::INVALID_ARGUMENT~;
            }
            cloth::check_skin_geometry(data, skin.joint_nodes.len)!;
            break;
        }
    }
    if (!skinned) {
        if (data.joints.len || data.weights.len || source.shape.skinned) return c3d::UNSUPPORTED~;
    }
    cloth::check_cloth_authoring(data, desc)!;
}

fn void? collect_crowd_cloth(void* component, serial::WriteContext* context) @private {
    CrowdCloth* owner = component;
    if (!owner.state || !owner.state.parts.len) return c3d::INVALID_ARGUMENT~;
    if (cloth::node_in_lod_group(context.scene, context.node)) return c3d::UNSUPPORTED~;
    AnimatedCrowd* crowd = context.scene.get(context.node, AnimatedCrowd);
    if (!crowd) return cloth::NO_MESH~;
    ModelAsset* model_asset = context.assets.models.try_get(crowd.model)!;
    ModelTemplate* template = &model_asset.data;

    foreach (i, &part_rec : owner.state.parts) {
        for (usz j = 0; j < (usz)i; j++) {
            if (owner.state.parts[j].part == part_rec.part) return c3d::INVALID_ARGUMENT~;
        }
        if (!part_rec.authoring) return c3d::INVALID_ARGUMENT~;
        if (!c3d::same_id(crowd.model, part_rec.model)
          || model_asset.header.revision != part_rec.model_revision) {
            return c3d::INVALID_ARGUMENT~;
        }
        if ((usz)part_rec.part >= template.meshes.len) return c3d::INVALID_ARGUMENT~;
        ModelMesh* model_mesh = &template.meshes[part_rec.part];
        if (!c3d::same_id(model_mesh.geometry, part_rec.source)
          || !c3d::same_id(model_mesh.material, part_rec.material)) {
            return c3d::INVALID_ARGUMENT~;
        }
        GeometryAsset* source_asset = context.assets.geometries.try_get(part_rec.source)!;
        if (source_asset.header.revision != part_rec.source_revision) return c3d::INVALID_ARGUMENT~;
        if (part_rec.skinned) {
            SkeletonAsset* skel_asset = context.assets.skeletons.try_get(part_rec.skeleton)!;
            if (skel_asset.header.revision != part_rec.skeleton_revision) return c3d::INVALID_ARGUMENT~;
        }

        ClothDesc desc = part_rec.authoring.desc;
        cloth::check_cloth_desc(desc)!;
        check_crowd_cloth_source_geometry(
            assets: context.assets,
            template: template,
            part: part_rec.part,
            desc: desc,
        )!;

        if (part_rec.prepared) {
            if (!crowd.is_prepared() || crowd.playback != part_rec.playback_identity) {
                return c3d::INVALID_ARGUMENT~;
            }
            if (crowd.placements.len != part_rec.capacity || crowd.count > part_rec.capacity
              || crowd.colors.len < part_rec.capacity || (usz)part_rec.part >= crowd.parts.len) {
                return c3d::INVALID_ARGUMENT~;
            }
            CrowdPart* crowd_part = &crowd.parts[part_rec.part];
            if (!c3d::same_id(crowd_part.batch, part_rec.original_batch)
              || !context.scene.world.is_alive(part_rec.original_batch)) {
                return c3d::INVALID_ARGUMENT~;
            }
            Node* batch_node = context.scene.node(part_rec.original_batch);
            if (batch_node.parent != context.node || batch_node.visible) return c3d::INVALID_ARGUMENT~;
            if (part_rec.outputs.len != part_rec.states.len || part_rec.outputs.len != (usz)part_rec.capacity) {
                return c3d::INVALID_ARGUMENT~;
            }

            foreach (slot, out_entity : part_rec.outputs) {
                if (!out_entity.generation || !context.scene.world.is_alive(out_entity)) {
                    return c3d::INVALID_ARGUMENT~;
                }
                Node* out_node = context.scene.node(out_entity);
                if (out_node.parent != context.node
                  || out_node.transform_space != TransformSpace.PARENT
                  || out_node.local.position != (Vec3){}
                  || out_node.local.rotation.v != maths::TRANSFORM_IDENTITY.rotation.v
                  || out_node.local.scale != (Vec3){ 1, 1, 1 }) {
                    return c3d::INVALID_ARGUMENT~;
                }
                ClothOutput* marker = context.scene.get(out_node, ClothOutput);
                Mesh* out_mesh = context.scene.get(out_node, Mesh);
                ClothState* state = part_rec.states[slot];
                if (!marker || !c3d::same_id(marker.owner, context.node.id)
                  || !marker.crowd || marker.part != part_rec.part
                  || !out_mesh || !state || !c3d::same_id(out_mesh.geometry, state.geometry)
                  || context.scene.has(out_node, SkinBinding)
                  || !context.assets.geometries.is_live(state.geometry)) {
                    return c3d::INVALID_ARGUMENT~;
                }
                context.omit_component(out_node, ecs::slot_of(Mesh)!)!;
                context.omit_node(out_node)!;
            }
        }
    }
}

fn void? project_crowd_cloth(void* component, void* value, serial::WriteContext* context) @private {
    CrowdCloth* owner = component;
    if (!owner.state || !owner.state.parts.len) return c3d::INVALID_ARGUMENT~;
    CrowdClothPartAuthoring[] parts = alloc::new_array(tmem, CrowdClothPartAuthoring, owner.state.parts.len);
    foreach (index, &part_rec : owner.state.parts) {
        parts[index].part = part_rec.part;
        project_cloth_recipe(part_rec.authoring.desc, &parts[index].cloth, context)!;
    }
    *(CrowdClothSavedAuthoring*)value = {
        .parts = parts,
    };
}

fn void? validate_crowd_cloth(void* value, serial::ReadContext* context) @private {
    CrowdClothSavedAuthoring* source = value;
    if (!context.has_component(AnimatedCrowd)) return cloth::NO_MESH~;
    if (context.has_component(LodGroup) || cloth::node_in_lod_group(context.scene, context.node)) {
        return c3d::UNSUPPORTED~;
    }
    if (!source.parts.len) return c3d::INVALID_ARGUMENT~;

    serial::CrowdAuthoringV4* crowd_auth = context.authored(AnimatedCrowd, serial::CrowdAuthoringV4, context.node.id)!;
    ModelTemplate* template = null;
    if (crowd_auth) {
        ModelAsset* model_asset = context.assets.models.try_get(crowd_auth.model)!;
        template = &model_asset.data;
    }

    foreach (i, &part : source.parts) {
        for (usz j = 0; j < (usz)i; j++) {
            if (source.parts[j].part == part.part) return c3d::INVALID_ARGUMENT~;
        }
        ClothDesc desc = cloth_desc(&part.cloth, context)!;
        cloth::check_cloth_desc(desc)!;
        cloth::check_collider_owners(context.scene, desc.colliders)!;
        if (template) {
            check_crowd_cloth_source_geometry(
                assets: context.assets,
                template: template,
                part: part.part,
                desc: desc,
            )!;
        }
    }
}

fn void? attach_crowd_cloth(void* value, serial::ReadContext* context) @private {
    CrowdClothSavedAuthoring* source = value;
    if (!source.parts.len) return c3d::INVALID_ARGUMENT~;
    foreach (&part : source.parts) {
        ClothDesc desc = cloth_desc(&part.cloth, context)!;
        context.scene.attach_crowd_cloth(
            assets: context.assets,
            owner: context.node,
            part: part.part,
            desc: desc,
        )!;
    }
}
