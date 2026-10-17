module c3d::physics::cloth;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;

<* Transient marker on an owned unskinned cloth output node. *>
struct ClothOutput {
    Entity          owner;
    bool            crowd;
    uint            part;
    CrowdInstanceId instance;
}

fn void? check_transport_desc(float[] transport) @private {
    foreach (value : transport) {
        if (!unit_interval(value)) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_transport_authoring(float[] transport, uint particle_count) @private {
    if (transport.len && transport.len != particle_count) return c3d::INVALID_ARGUMENT~;
}

fn bool node_in_lod_group(Scene* scene, Node* node) @private {
    for (Node* current = node; current; current = current.parent) {
        if (scene.has(current, LodGroup)) return true;
    }
    return false;
}

fn void? check_cloth_material(AssetStore* assets, MaterialId material, bool require_live) @private {
    if (!material.generation) {
        if (require_live) return c3d::INVALID_ID~;
        return;
    }
    if (!assets.materials.is_live(material)) {
        if (require_live) return c3d::INVALID_ID~;
        return;
    }
    Material* mat = &assets.material(material).data;
    if (mat.kind != MaterialKind.CUSTOM) return;
    if (!assets.shaders.is_live(mat.custom.shader)) {
        if (require_live) return c3d::INVALID_ID~;
        return;
    }
    CustomVertex* vertex = &assets.shader(mat.custom.shader).desc.vertex;
    if (vertex.shaded.len || vertex.depth.len || vertex.instanced_shaded.len
        || vertex.instanced_depth.len || vertex.velocity.len || vertex.instanced_velocity.len) {
        return c3d::UNSUPPORTED~;
    }
}

fn void? check_skin_geometry(Geometry* data, usz joint_count) @private {
    uint render_count = (uint)data.positions.len;
    if (data.joints.len != render_count || data.weights.len != render_count) {
        return c3d::INVALID_ARGUMENT~;
    }
    foreach (vertex, joints : data.joints) {
        Vec4 weights = data.weights[vertex];
        for (usz slot = 0; slot < 4; slot++) {
            if (!math::is_finite(weights[slot])) return c3d::INVALID_ARGUMENT~;
            if ((usz)joints[slot] >= joint_count) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? check_skin_binding(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    Geometry* data,
) @private {
    SkinBinding* binding = scene.get(node, SkinBinding);
    if (!binding) return c3d::INVALID_ARGUMENT~;
    if (!assets.skeletons.is_live(binding.skeleton)) return c3d::INVALID_ID~;
    Skeleton* skeleton = &assets.skeleton(binding.skeleton).data;
    if (!binding.joints.len
        || binding.joints.len != skeleton.inverse_bind.len
        || binding.joints.len != skeleton.parents.len) {
        return c3d::INVALID_ARGUMENT~;
    }
    foreach (joint : binding.joints) {
        if (!joint || !scene.world.is_alive(joint.id) || scene.node(joint.id) != joint) {
            return c3d::INVALID_ID~;
        }
    }
    check_skin_geometry(data, binding.joints.len)!;
}

alias SkinMat4 @private = float[<4>][4];

fn void? evaluate_skinned_particles(
    Node* mesh_node,
    SkinBinding* binding,
    Mat4[] inverse_bind,
    Geometry* source,
    uint[] render_to_particle,
    uint[] particle_sources,
    SkinMat4[] palette_scratch,
    Vec3[] source_scratch,
    Vec3[] out_particles,
) @private {
    anim::evaluate_skin_palette(
        output:       palette_scratch,
        mesh_node:    mesh_node,
        binding:      binding,
        inverse_bind: inverse_bind,
    );
    anim::evaluate_skin_positions(
        output:  source_scratch,
        source:  source,
        palette: palette_scratch,
        world:   mesh_node.world,
    )!;
    foreach (particle, source_vertex : particle_sources) {
        out_particles[particle] = source_scratch[source_vertex];
    }
    foreach (render_vertex, particle : render_to_particle) {
        if (source_scratch[render_vertex] != out_particles[particle]) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? evaluate_rigid_particles(Mat4 world, Vec3[] rest, Vec3[] out_particles) @private {
    foreach (value : world.m) {
        if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    }
    foreach (particle, local_pos : rest) {
        Vec3 point = maths::transform_point(world, local_pos);
        if (!finite_vector(point)) return c3d::INVALID_ARGUMENT~;
        out_particles[particle] = point;
    }
}

fn void deactivate_output_node(Scene* scene, Entity output_entity) @private {
    if (!output_entity.generation || !scene.world.is_alive(output_entity)) return;
    Node* out_node = scene.node(output_entity);
    out_node.visible = false;
    out_node.visible_effective = false;
}

fn void? check_ordinary_output_ownership(Scene* scene, ClothState* state, Node* owner) @private {
    if (!state.skinned) {
        scene::Mesh* mesh = scene.get(owner, scene::Mesh);
        if (!mesh || !c3d::same_id(mesh.geometry, state.geometry) || scene.has(owner, SkinBinding)) {
            return OWNERSHIP_CHANGED~;
        }
        return;
    }

    if (scene.has(owner, scene::Mesh) || !scene.world.is_alive(state.output_node)) {
        deactivate_output_node(scene, state.output_node);
        return OWNERSHIP_CHANGED~;
    }

    Node* out_node = scene.node(state.output_node);
    ClothOutput* marker = scene.get(out_node, ClothOutput);
    scene::Mesh* out_mesh = scene.get(out_node, scene::Mesh);
    if (out_node.parent != owner
        || out_node.transform_space != TransformSpace.PARENT
        || out_node.local.position != (Vec3){}
        || out_node.local.rotation.v != maths::TRANSFORM_IDENTITY.rotation.v
        || out_node.local.scale != (Vec3){ 1, 1, 1 }
        || !out_node.visible
        || !marker
        || !c3d::same_id(marker.owner, owner.id)
        || marker.crowd
        || !out_mesh
        || !c3d::same_id(out_mesh.geometry, state.geometry)
        || !c3d::same_id(out_mesh.material, state.captured_mesh.material)
        || out_mesh.cast_shadow != state.captured_mesh.cast_shadow
        || out_mesh.receive_shadow != state.captured_mesh.receive_shadow
        || out_mesh.trace != state.captured_mesh.trace
        || !out_mesh.vertex_motion
        || out_mesh.morph_weights.len != 0
        || out_mesh.morph_weights.ptr != null
        || out_mesh.has_bounds_override
        || scene.has(out_node, SkinBinding)) {
        deactivate_output_node(scene, state.output_node);
        return OWNERSHIP_CHANGED~;
    }
    if (catch check_cloth_material(state.assets, out_mesh.material, false)) {
        deactivate_output_node(scene, state.output_node);
        return OWNERSHIP_CHANGED~;
    }
}

fn void? sample_ordinary_reference(
    Scene* scene,
    AssetStore* assets,
    Node* owner,
    ClothState* state,
) @private {
    if (node_in_lod_group(scene, owner)) return REFERENCE_UNAVAILABLE~;
    if (!state.skinned) {
        return evaluate_rigid_particles(owner.world, state.rest, state.current_reference);
    }

    if (!assets.geometries.is_live(state.source)) return REFERENCE_UNAVAILABLE~;
    GeometryAsset* source_record = assets.geometry(state.source);
    if (source_record.header.revision != state.source_revision) return REFERENCE_UNAVAILABLE~;
    Geometry* source_data = &source_record.data;
    if (!source_data.positions.len
        || source_data.joints.len != source_data.positions.len
        || source_data.weights.len != source_data.positions.len) {
        return REFERENCE_UNAVAILABLE~;
    }

    SkinBinding* binding = scene.get(owner, SkinBinding);
    if (!binding
        || !c3d::same_id(binding.skeleton, state.skeleton)
        || !assets.skeletons.is_live(state.skeleton)) {
        return REFERENCE_UNAVAILABLE~;
    }
    SkeletonAsset* skeleton_record = assets.skeleton(state.skeleton);
    if (skeleton_record.header.revision != state.skeleton_revision
        || binding.joints.len != state.joint_entities.len
        || skeleton_record.data.inverse_bind.len != state.joint_entities.len) {
        return REFERENCE_UNAVAILABLE~;
    }

    foreach (index, expected : state.joint_entities) {
        Node* joint = binding.joints[index];
        if (!joint
            || !scene.world.is_alive(expected)
            || !c3d::same_id(joint.id, expected)
            || scene.node(expected) != joint) {
            return REFERENCE_UNAVAILABLE~;
        }
    }

    return evaluate_skinned_particles(
        mesh_node:          owner,
        binding:            binding,
        inverse_bind:       skeleton_record.data.inverse_bind,
        source:             source_data,
        render_to_particle: state.render_to_particle,
        particle_sources:   state.particle_sources,
        palette_scratch:    state.palette_scratch,
        source_scratch:     state.source_reference_scratch,
        out_particles:      state.current_reference,
    );
}
