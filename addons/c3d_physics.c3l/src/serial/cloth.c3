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
}

fn void? register_cloth_codec() @private {
    describe::register_reflected(ClothSavedAuthoring)!;
    serial::register_described_type(
        $Type: ClothSavedAuthoring,
        version: 1,
        layout: 0x32d4e314fd540124,
        defaults: &defaults_cloth_authoring,
    )!;
    serial::register_described_owner(Cloth, ClothSavedAuthoring, {
        .name = "cloth",
        .phase = OWNER,
        .collect = &collect_cloth,
        .project = &project_cloth,
        .validate = &validate_cloth,
        .attach = &attach_cloth,
    })!;
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
    (void)cloth::unique_pins(desc.pins, (uint)source.data.positions.len)!;
    context.project_component(context.node, projected)!;
}

fn void? project_cloth(void* component, void* value, serial::WriteContext* context) @private {
    Cloth* owner = component;
    ClothDesc desc = owner.authoring.desc;
    serial::NodeReference[] colliders = alloc::new_array_try(tmem, serial::NodeReference, desc.colliders.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
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
    };
}

fn ClothDesc? cloth_desc(ClothSavedAuthoring* source, serial::ReadContext* context) @private {
    Entity[] colliders = alloc::new_array_try(tmem, Entity, source.colliders.len) ?? c3d::CAPACITY_EXCEEDED~!;
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
    (void)cloth::unique_pins(desc.pins, (uint)geometry.data.positions.len)!;
}

fn void? attach_cloth(void* value, serial::ReadContext* context) @private {
    ClothSavedAuthoring* source = value;
    ClothDesc desc = cloth_desc(source, context)!;
    context.scene.attach_cloth(assets: context.assets, node: context.node, desc: desc)!;
}
