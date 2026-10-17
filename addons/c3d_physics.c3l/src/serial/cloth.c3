module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::physics::cloth @public;
import c3d::scene;
import c3d::serial;

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
}

uint[4] cloth_text_default_versions @private = { 1, 2, 3, 4 };

fn void? register_cloth_codec() @private {
    describe::register_reflected(ClothSeam)!;
    describe::register_reflected(ClothAttachment)!;
    describe::register_reflected(ClothRestAngle)!;
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
        $Type: ClothSavedAuthoring,
        version: 5,
        layout: 0xd34de4a8e9f1a9ca,
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
    };
}

fn void? collect_cloth(void* component, serial::WriteContext* context) @private {
    Cloth* owner = component;
    Mesh* mesh = context.scene.get(context.node, Mesh);
    if (!mesh) return cloth::NO_MESH~;

    GeometryId expected = owner.is_prepared() ? owner.state.geometry : owner.authoring.source;
    if (!c3d::same_id(mesh.geometry, expected)) return c3d::INVALID_ARGUMENT~;

    Mesh projected = *mesh;
    projected.geometry = owner.authoring.source;
    projected.vertex_motion = owner.authoring.source_vertex_motion;

    ClothDesc desc = owner.authoring.desc;
    cloth::check_cloth_desc(desc)!;
    GeometryAsset* source = context.assets.geometries.try_get(projected.geometry)!;
    cloth::check_cloth_source(
        scene: context.scene,
        node: context.node,
        mesh: &projected,
        source: source,
    )!;
    cloth::check_cloth_authoring(&source.data, desc)!;
    context.project_component(context.node, projected)!;
}

fn void? project_cloth(void* component, void* value, serial::WriteContext* context) @private {
    Cloth* owner = component;
    ClothDesc desc = owner.authoring.desc;
    serial::NodeReference[] colliders = alloc::new_array(tmem, serial::NodeReference, desc.colliders.len);
    foreach (index, entity : desc.colliders) colliders[index] = context.make_entity_reference(entity, true)!;

    *(ClothSavedAuthoring*)value = {
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
    };
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
    };
}

fn void? validate_cloth(void* value, serial::ReadContext* context) @private {
    ClothSavedAuthoring* source = value;
    Mesh* mesh = context.authored(Mesh, Mesh, context.node.id)!;
    if (!mesh) return cloth::NO_MESH~;
    if (context.has_component(SkinBinding)) return c3d::UNSUPPORTED~;

    ClothDesc desc = cloth_desc(source, context)!;
    cloth::check_cloth_desc(desc)!;
    GeometryAsset* geometry = context.assets.geometries.try_get(mesh.geometry)!;
    cloth::check_cloth_source(
        scene: context.scene,
        node: context.node,
        mesh: mesh,
        source: geometry,
    )!;
    cloth::check_collider_owners(context.scene, desc.colliders)!;
    cloth::check_cloth_authoring(&geometry.data, desc)!;
}

fn void? attach_cloth(void* value, serial::ReadContext* context) @private {
    ClothSavedAuthoring* source = value;
    ClothDesc desc = cloth_desc(source, context)!;
    context.scene.attach_cloth(assets: context.assets, node: context.node, desc: desc)!;
}
