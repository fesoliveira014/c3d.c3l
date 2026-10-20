module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::physics::cloth @public;
import c3d::scene;
import c3d::serial;

struct CrowdClothPartAuthoring @private {
    uint part;
    ClothSavedAuthoringV9 cloth; // crowd parts select no execution
}

struct CrowdClothSavedAuthoring @private {
    CrowdClothPartAuthoring[] parts;
}

uint[3] crowd_cloth_text_default_versions @private = { 1, 2, 3 };

fn void? register_crowd_cloth_codec() @private {
    describe::register_reflected(CrowdClothPartAuthoring)!;
    describe::register_reflected(CrowdClothSavedAuthoring)!;
    serial::register_described_type(
        $Type: CrowdClothPartAuthoring,
        version: 1,
        layout: 0x6db6f066b580f098,
        defaults: &defaults_crowd_cloth_part,
    )!;
    serial::register_described_type(
        $Type: CrowdClothSavedAuthoring,
        version: 4,
        layout: 0x4d46063131cdab67,
        defaults: &defaults_crowd_cloth_authoring,
    )!;
    serial::register_described_owner(CrowdCloth, CrowdClothSavedAuthoring, {
        .name = "crowd_cloth",
        .phase = BINDINGS,
        .collect = &collect_crowd_cloth,
        .project = &project_crowd_cloth,
        .validate = &validate_crowd_cloth,
        .attach = &attach_crowd_cloth,
        .text_default_versions = crowd_cloth_text_default_versions[..],
    })!;
}

fn void defaults_crowd_cloth_part(void* value) @private {
    CrowdClothPartAuthoring* part = value;
    *part = {};
    defaults_cloth_authoring_v9(&part.cloth);
}

fn void defaults_crowd_cloth_authoring(void* value) @private {
    *(CrowdClothSavedAuthoring*)value = {};
}

fn void? collect_crowd_cloth(void* component, serial::WriteContext* context) @private {
    CrowdCloth* owner = component;
    if (!owner.state || !owner.state.parts.len) return c3d::INVALID_ARGUMENT~;
    if (cloth::node_in_lod_group(context.scene, context.node)) return c3d::UNSUPPORTED~;
    AnimatedCrowd* crowd = context.scene.get(context.node, AnimatedCrowd);
    if (!crowd) return cloth::NO_MESH~;
    ModelAsset* model_asset = context.assets.models.try_get(crowd.model)!;
    ModelTemplate* template = &model_asset.data;

    foreach (&part_record : owner.state.parts) {
        if (!c3d::same_id(crowd.model, part_record.model)
          || model_asset.header.revision != part_record.model_revision) {
            return c3d::INVALID_ARGUMENT~;
        }
        if ((usz)part_record.part >= template.meshes.len) return c3d::INVALID_ARGUMENT~;
        ModelMesh* model_mesh = &template.meshes[part_record.part];
        if (!c3d::same_id(model_mesh.geometry, part_record.source)
          || !c3d::same_id(model_mesh.material, part_record.material)) {
            return c3d::INVALID_ARGUMENT~;
        }
        GeometryAsset* source_asset = context.assets.geometries.try_get(part_record.source)!;
        if (source_asset.header.revision != part_record.source_revision) return c3d::INVALID_ARGUMENT~;
        if (part_record.skinned) {
            SkeletonAsset* skeleton_asset = context.assets.skeletons.try_get(part_record.skeleton)!;
            if (skeleton_asset.header.revision != part_record.skeleton_revision) return c3d::INVALID_ARGUMENT~;
        }

        if (part_record.prepared) {
            if (!cloth::valid_crowd_part_runtime(
                scene:       context.scene,
                owner:       context.node,
                crowd:       crowd,
                part_record: part_record,
            )) {
                return c3d::INVALID_ARGUMENT~;
            }
            foreach (slot, state : part_record.states) {
                Node* out_node;
                if (!cloth::valid_crowd_slot_output(
                    scene:       context.scene,
                    owner:       context.node,
                    part_record: part_record,
                    state:       state,
                    slot:        (uint)slot,
                    out_node:    &out_node,
                ) || !context.assets.geometries.is_live(state.geometry)) {
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
    foreach (index, &part_record : owner.state.parts) {
        parts[index].part = part_record.part;
        project_cloth_recipe_v9(part_record.authoring.desc, &parts[index].cloth, context)!;
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

    ModelId crowd_model = context.authored_crowd_model(context.node.id)!;
    ModelAsset* model_asset = context.assets.models.try_get(crowd_model)!;
    ModelTemplate* template = &model_asset.data;

    foreach (i, &part : source.parts) {
        for (usz j = 0; j < (usz)i; j++) {
            if (source.parts[j].part == part.part) return c3d::INVALID_ARGUMENT~;
        }
        ClothDesc desc = cloth_desc_v9(&part.cloth, context)!;
        cloth::check_cloth_desc(desc)!;
        cloth::check_collider_owners(context.scene, desc.colliders)!;
        cloth::check_crowd_part_source_geometry(
            assets: context.assets,
            template: template,
            part: part.part,
            desc: desc,
        )!;
    }
}

fn void? attach_crowd_cloth(void* value, serial::ReadContext* context) @private {
    CrowdClothSavedAuthoring* source = value;
    if (!source.parts.len) return c3d::INVALID_ARGUMENT~;
    foreach (&part : source.parts) {
        ClothDesc desc = cloth_desc_v9(&part.cloth, context)!;
        context.scene.attach_crowd_cloth(
            assets: context.assets,
            owner: context.node,
            part: part.part,
            desc: desc,
        )!;
    }
}
