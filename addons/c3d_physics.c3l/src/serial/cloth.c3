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

struct ClothSavedAuthoring @private {
    uint substeps;
    uint iterations;
    float stretch_stiffness;
    float bend_stiffness;
    float damping;
    float thickness;
    float gravity_scale;
    uint[] pins;
    bool collide_ground;
    float ground_height;
    serial::NodeReference[] colliders;
    float contact_tolerance;
    uint contact_iterations;
    uint max_shapes;
    uint max_candidates;
    uint max_contacts;
    bool self_collision;
    ClothSeam[] seams;
    bool continuous;
    uint max_ccd_iterations;
    uint[] render_particles;
    bool tangent_frame;
    uint tangent_uv_set;
    ClothAttachment[] attachments;
    ClothBendMode bend_mode;
    float bend_compliance;
    ClothRestAngle[] rest_angles;
    float[] transport;
    ClothCutPath[] cuts;
    ClothTearLimits tears;
}

uint[6] cloth_text_default_versions @private = { 1, 2, 3, 4, 5, 6 };

fn void? register_cloth_codec() @private {
    describe::register_reflected(ClothSeam)!;
    describe::register_reflected(ClothAttachment)!;
    describe::register_reflected(ClothRestAngle)!;
    describe::register_reflected(ClothCutPath)!;
    describe::register_reflected(ClothTearLimits)!;
    describe::register_reflected(ClothSavedAuthoring)!;
    serial::register_described_type(
        $Type: ClothSeam,
        version: 1,
        layout: 0xfe476ea9aad09958,
        defaults: &defaults_cloth_seam,
    )!;
    serial::register_described_type(
        $Type: ClothAttachment,
        version: 1,
        layout: 0x5391de8db10669ce,
        defaults: &defaults_cloth_attachment,
    )!;
    serial::register_described_type(
        $Type: ClothRestAngle,
        version: 1,
        layout: 0x641a4e016afcfbeb,
        defaults: &defaults_cloth_rest_angle,
    )!;
    serial::register_described_type(
        $Type: ClothCutPath,
        version: 1,
        layout: 0x194f332270e8c8dc,
        defaults: &defaults_cloth_cut_path,
    )!;
    serial::register_described_type(
        $Type: ClothTearLimits,
        version: 1,
        layout: 0x4abf68fd1a972e55,
        defaults: &defaults_cloth_tear_limits,
    )!;
    serial::register_described_type(
        $Type: ClothSavedAuthoring,
        version: 7,
        layout: 0x12911e3cd68aec15,
        defaults: &defaults_cloth_authoring,
    )!;
    serial::register_described_owner(Cloth, ClothSavedAuthoring, {
        .name = "cloth",
        .phase = OWNER,
        .collect = &collect_cloth,
        .project = &project_cloth,
        .validate = &validate_cloth,
        .attach = &attach_cloth,
        .text_default_versions = cloth_text_default_versions[..],
    })!;
    serial::register_transient(ClothOutput, &collect_cloth_output)!;
}

fn void defaults_cloth_seam(void* value) @private {
    *(ClothSeam*)value = {};
}

fn void defaults_cloth_attachment(void* value) @private {
    *(ClothAttachment*)value = {};
}

fn void defaults_cloth_rest_angle(void* value) @private {
    *(ClothRestAngle*)value = {};
}

fn void defaults_cloth_cut_path(void* value) @private {
    *(ClothCutPath*)value = {};
}

fn void defaults_cloth_tear_limits(void* value) @private {
    *(ClothTearLimits*)value = cloth::default_cloth_tear_limits();
}

fn void defaults_cloth_authoring(void* value) @private {
    ClothDesc desc = cloth::default_cloth_desc();
    ClothSavedAuthoring* authoring = value;
    *authoring = {
        .substeps = desc.substeps,
        .iterations = desc.iterations,
        .stretch_stiffness = desc.stretch_stiffness,
        .bend_stiffness = desc.bend_stiffness,
        .damping = desc.damping,
        .thickness = desc.thickness,
        .gravity_scale = desc.gravity_scale,
        .collide_ground = desc.collide_ground,
        .ground_height = desc.ground_height,
        .contact_tolerance = desc.collisions.contact_tolerance,
        .contact_iterations = desc.collisions.contact_iterations,
        .max_shapes = desc.collisions.max_shapes,
        .max_candidates = desc.collisions.max_candidates,
        .max_contacts = desc.collisions.max_contacts,
        .self_collision = desc.collisions.self_collision,
        .seams = desc.seams,
        .continuous = desc.collisions.continuous,
        .max_ccd_iterations = desc.collisions.max_ccd_iterations,
        .render_particles = desc.render_particles,
        .tangent_frame = desc.tangent_frame,
        .tangent_uv_set = desc.tangent_uv_set,
        .attachments = desc.attachments,
        .bend_mode = desc.bend_mode,
        .bend_compliance = desc.bend_compliance,
        .rest_angles = desc.rest_angles,
        .transport = desc.transport,
        .cuts = desc.cuts,
        .tears = desc.tears,
    };
}

fn void? collect_cloth_output(void* component, serial::WriteContext* context) @private {
    ClothOutput* output = component;
    if (!context.scene.world.is_alive(output.owner)) return c3d::INVALID_ARGUMENT~;
    Node* owner = context.scene.node(output.owner);
    if (!context.contains_node(owner) || context.node.parent != owner) return c3d::INVALID_ARGUMENT~;
    if (!output.crowd) {
        Cloth* cloth = context.scene.get(owner, Cloth);
        if (!cloth || !cloth.is_prepared() || !cloth.authoring.skinned
          || !c3d::same_id(cloth.state.output_node, context.node.id)) {
            return c3d::INVALID_ARGUMENT~;
        }
        return;
    }
    CrowdCloth* crowd = context.scene.get(owner, CrowdCloth);
    if (!crowd || !crowd.state) return c3d::INVALID_ARGUMENT~;
    foreach (&part : crowd.state.parts) {
        if (part.part != output.part || !part.prepared) continue;
        foreach (out_entity : part.outputs) {
            if (c3d::same_id(out_entity, context.node.id)) return;
        }
        return c3d::INVALID_ARGUMENT~;
    }
    return c3d::INVALID_ARGUMENT~;
}

fn void? collect_cloth(void* component, serial::WriteContext* context) @private {
    Cloth* owner = component;

    if (!owner.authoring.skinned) {
        if (context.scene.has(context.node, SkinBinding)) return c3d::INVALID_ARGUMENT~;
        Mesh* mesh = context.scene.get(context.node, Mesh);
        if (!mesh) return cloth::NO_MESH~;

        GeometryId expected = owner.is_prepared() ? owner.state.geometry : owner.authoring.source;
        if (!c3d::same_id(mesh.geometry, expected)) return c3d::INVALID_ARGUMENT~;
        (void)context.assets.geometries.try_get(owner.authoring.source)!;

        Mesh projected = *mesh;
        projected.geometry = owner.authoring.source;
        projected.vertex_motion = owner.authoring.source_vertex_motion;
        context.project_component(context.node, projected)!;
        return;
    }

    SkinBinding* skin = context.scene.get(context.node, SkinBinding);
    if (!skin || !c3d::same_id(skin.skeleton, owner.authoring.skeleton)) return c3d::INVALID_ARGUMENT~;
    SkeletonAsset* skeleton = context.assets.skeletons.try_get(skin.skeleton)!;
    if (skeleton.header.revision != owner.authoring.skeleton_revision) return c3d::INVALID_ARGUMENT~;
    if (skin.joints.len != owner.authoring.joint_entities.len) return c3d::INVALID_ARGUMENT~;
    foreach (index, expected_joint : owner.authoring.joint_entities) {
        Node* joint = skin.joints[index];
        if (!joint || !context.scene.world.is_alive(expected_joint)
          || !c3d::same_id(joint.id, expected_joint)
          || context.scene.node(expected_joint) != joint) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    GeometryAsset* source = context.assets.geometries.try_get(owner.authoring.source)!;
    if (source.header.revision != owner.authoring.source_revision) return c3d::INVALID_ARGUMENT~;

    if (!owner.is_prepared()) {
        Mesh* mesh = context.scene.get(context.node, Mesh);
        if (!mesh) return cloth::NO_MESH~;
        if (!c3d::same_id(mesh.geometry, owner.authoring.source)) return c3d::INVALID_ARGUMENT~;
        Mesh projected = *mesh;
        projected.geometry = owner.authoring.source;
        projected.vertex_motion = owner.authoring.source_vertex_motion;
        context.project_component(context.node, projected)!;
        return;
    }

    if (!cloth::valid_skinned_output_node(context.scene, owner.state, context.node)) {
        return c3d::INVALID_ARGUMENT~;
    }
    Node* out_node = context.scene.node(owner.state.output_node);
    Mesh projected = owner.state.captured_mesh;
    projected.geometry = owner.authoring.source;
    projected.vertex_motion = owner.authoring.source_vertex_motion;

    context.omit_component(out_node, ecs::slot_of(Mesh)!)!;
    context.omit_node(out_node)!;
    context.project_absent_component(context.node, projected)!;
}

fn void? project_cloth_recipe(ClothDesc desc, ClothSavedAuthoring* value, serial::WriteContext* context) @private {
    serial::NodeReference[] colliders = alloc::new_array(tmem, serial::NodeReference, desc.colliders.len);
    foreach (index, entity : desc.colliders) colliders[index] = context.make_entity_reference(entity, true)!;

    *value = {
        .substeps = desc.substeps,
        .iterations = desc.iterations,
        .stretch_stiffness = desc.stretch_stiffness,
        .bend_stiffness = desc.bend_stiffness,
        .damping = desc.damping,
        .thickness = desc.thickness,
        .gravity_scale = desc.gravity_scale,
        .pins = desc.pins,
        .collide_ground = desc.collide_ground,
        .ground_height = desc.ground_height,
        .colliders = colliders,
        .contact_tolerance = desc.collisions.contact_tolerance,
        .contact_iterations = desc.collisions.contact_iterations,
        .max_shapes = desc.collisions.max_shapes,
        .max_candidates = desc.collisions.max_candidates,
        .max_contacts = desc.collisions.max_contacts,
        .self_collision = desc.collisions.self_collision,
        .seams = desc.seams,
        .continuous = desc.collisions.continuous,
        .max_ccd_iterations = desc.collisions.max_ccd_iterations,
        .render_particles = desc.render_particles,
        .tangent_frame = desc.tangent_frame,
        .tangent_uv_set = desc.tangent_uv_set,
        .attachments = desc.attachments,
        .bend_mode = desc.bend_mode,
        .bend_compliance = desc.bend_compliance,
        .rest_angles = desc.rest_angles,
        .transport = desc.transport,
        .cuts = desc.cuts,
        .tears = desc.tears,
    };
}

fn void? project_cloth(void* component, void* value, serial::WriteContext* context) @private {
    Cloth* owner = component;
    project_cloth_recipe(owner.authoring.desc, (ClothSavedAuthoring*)value, context)!;
}

fn ClothDesc? cloth_desc(ClothSavedAuthoring* source, serial::ReadContext* context) @private {
    Entity[] colliders = alloc::new_array(tmem, Entity, source.colliders.len);
    foreach (index, reference : source.colliders) colliders[index] = context.resolve_node_reference(reference, true)!.id;

    return {
        .substeps = source.substeps,
        .iterations = source.iterations,
        .stretch_stiffness = source.stretch_stiffness,
        .bend_stiffness = source.bend_stiffness,
        .damping = source.damping,
        .thickness = source.thickness,
        .gravity_scale = source.gravity_scale,
        .pins = source.pins,
        .collide_ground = source.collide_ground,
        .ground_height = source.ground_height,
        .colliders = colliders,
        .collisions = {
            .contact_tolerance = source.contact_tolerance,
            .contact_iterations = source.contact_iterations,
            .max_shapes = source.max_shapes,
            .max_candidates = source.max_candidates,
            .max_contacts = source.max_contacts,
            .self_collision = source.self_collision,
            .continuous = source.continuous,
            .max_ccd_iterations = source.max_ccd_iterations,
        },
        .seams = source.seams,
        .render_particles = source.render_particles,
        .tangent_frame = source.tangent_frame,
        .tangent_uv_set = source.tangent_uv_set,
        .attachments = source.attachments,
        .bend_mode = source.bend_mode,
        .bend_compliance = source.bend_compliance,
        .rest_angles = source.rest_angles,
        .transport = source.transport,
        .cuts = source.cuts,
        .tears = source.tears,
    };
}

fn void? validate_cloth(void* value, serial::ReadContext* context) @private {
    ClothSavedAuthoring* source = value;
    Mesh* mesh = context.authored(Mesh, Mesh, context.node.id)!;
    if (!mesh) return cloth::NO_MESH~;
    if (context.has_component(LodGroup)) return c3d::UNSUPPORTED~;

    ClothDesc desc = cloth_desc(source, context)!;
    cloth::check_cloth_desc(desc)!;
    GeometryAsset* geometry = context.assets.geometries.try_get(mesh.geometry)!;

    if (context.has_component(SkinBinding)) {
        serial::SkinAuthoring* skin = context.authored(SkinBinding, serial::SkinAuthoring, context.node.id)!;
        if (!skin) return c3d::INVALID_ARGUMENT~;
        SkeletonAsset* skeleton = context.assets.skeletons.try_get(skin.skeleton)!;
        if (!skin.joints.len || skin.joints.len != skeleton.data.parents.len
          || skin.joints.len != skeleton.data.inverse_bind.len) {
            return c3d::INVALID_ARGUMENT~;
        }
        foreach (joint_ref : skin.joints) (void)context.resolve_node_reference(joint_ref, true)!;
        if (mesh.morph_weights.len || mesh.has_bounds_override) {
            return c3d::UNSUPPORTED~;
        }
        if (cloth::node_in_lod_group(context.scene, context.node)) return c3d::UNSUPPORTED~;
        cloth::check_cloth_material(context.assets, mesh.material, false)!;
        cloth::check_cloth_geometry(geometry)!;
        if (!geometry.data.joints.len && !geometry.data.weights.len) return c3d::UNSUPPORTED~;
        cloth::check_skin_geometry(&geometry.data, skin.joints.len)!;
    } else {
        cloth::check_cloth_source(
            scene: context.scene,
            assets: context.assets,
            node: context.node,
            mesh: mesh,
            source: geometry,
        )!;
    }
    cloth::check_collider_owners(context.scene, desc.colliders)!;
    cloth::check_cloth_authoring(&geometry.data, desc)!;
}

fn void? attach_cloth(void* value, serial::ReadContext* context) @private {
    ClothSavedAuthoring* source = value;
    ClothDesc desc = cloth_desc(source, context)!;
    context.scene.attach_cloth(assets: context.assets, node: context.node, desc: desc)!;
}
