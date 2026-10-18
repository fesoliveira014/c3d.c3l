module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;
import std::time;
import std::time::clock;

<* Cloth substeps per performed physics step. *>
const uint DEFAULT_CLOTH_SUBSTEPS = 4; // solve cost grows linearly; fewer substeps lag fast pins
<* Constraint passes per substep. *>
const uint DEFAULT_CLOTH_ITERATIONS = 8; // edge and bend passes per substep; the stiffness lever
<* Requested substep relaxation of triangle edges. *>
const float DEFAULT_STRETCH_STIFFNESS = 1; // edges hold their rest length; lower values let the fabric stretch
<* Requested substep relaxation of bend distances. *>
const float DEFAULT_BEND_STIFFNESS = 0.5f; // soft folds; 1 makes the sheet behave like card
<* Linear velocity damping, per second. *>
const float DEFAULT_CLOTH_DAMPING = 0.5f; // about 40% of velocity lost per second; higher values look submerged
<* Contact offset of free particles, in metres. *>
const float DEFAULT_CLOTH_THICKNESS = 0.01f; // keeps particles off contact surfaces; larger values show a visible gap
<* Maximum listed contact owners for one cloth. *>
const uint MAX_CLOTH_COLLIDERS = 32; // bounds owner resolution; leaf storage has its own configured capacity
<* Consecutive slow simulated steps before a cloth rests. *>
const uint DEFAULT_CLOTH_SLEEP_STEPS = 30; // half a second at 60 Hz; fewer steps rest cloth that is only pausing

<* Source vertex equivalence used only for self-contact exclusions. *>
struct ClothSeam {
    uint first;
    uint second;
}

<* Fixed-step integration, material routing and attachment settings for one cloth. *>
struct ClothDesc {
    uint              substeps;
    uint              iterations;
    float             stretch_stiffness;
    float             bend_stiffness;
    float             damping;
    float             thickness;
    float             gravity_scale;
    uint[]            pins;
    bool              collide_ground;
    float             ground_height;
    Entity[]          colliders;
    ClothCollisionDesc collisions;
    ClothSeam[]       seams;
    uint[]            render_particles;
    bool              tangent_frame;
    uint              tangent_uv_set;
    ClothAttachment[] attachments;
    ClothBendMode     bend_mode;
    float             bend_compliance;
    ClothRestAngle[]  rest_angles;
    float[]           transport;
    ClothCutPath[]    cuts;
    ClothTearLimits   tears;
    float             sleep_speed; // m/s; a cloth whose fastest particle stays under it rests; 0 never rests (default)
    uint              sleep_steps; // consecutive simulated steps under sleep_speed before resting (default 30)
}

<* Last cloth update's CPU solve and publication costs. *>
struct ClothStats {
    double solve_seconds;
    double publish_seconds;
    uint   particles;
    uint   constraints;
    uint   pending;
    uint   resting;
    uint   held;
    uint   failed;
    uint   candidates;
    uint   contacts;
    uint   ccd_iterations;
    uint   impacts;
    double max_residual;
}

<* Distance between two particles kept near its rest length. *>
struct ClothConstraint {
    uint  first;
    uint  second;
    float rest_length;
    Vec3  rest_direction; // separates a pair that collapses onto one point
}

<* Captured collider identity and body-local contact geometry. *>
struct ClothShape {
    uint  body;
    Vec3  start;
    Vec3  end;
    float radius;
    ColliderKind kind;
    uint collider;
    uint[3] native_identity;
    bool compound_child;
    uint child;
    SnapshotHandle snapshot;
    maths::Transform local;
    Aabb bounds;
}

<* Listed rigid body whose final published pose moves its captured shapes. *>
struct ClothBody {
    Entity           owner;
    uint[4]          native_identity;
    maths::Transform solved;   // pose of the last solved substep
    maths::Transform current;  // pose sampled by the current update
    maths::Transform published; // pose used by the last accepted publication
    maths::Transform rested;    // pose recorded when the cloth began resting
    bool             live;     // owner alive with a built body this update
    bool             observed; // solved holds a pose sampled since the owner was last live
    bool             published_observed;
    bool             rested_live; // owner had a built body when the cloth began resting
}

<* Library-owned simulation state; its arrays are borrowed by readers. *>
struct ClothState {
    ClothDesc            desc; // pins/colliders borrow state arrays; other slices borrow owned authoring
    AssetStore*          assets;
    GeometryId           source;
    uint                 source_revision;
    GeometryId           geometry;
    bool                 source_vertex_motion;
    bool                 skinned;
    bool                 crowd;
    SkeletonId           skeleton;
    uint                 skeleton_revision;
    Entity               output_node;
    scene::Mesh          captured_mesh;
    uint                 base_particle_count;
    uint                 active_particle_count;
    uint                 committed_particle_count;
    uint                 committed_pin_count;
    uint                 committed_soft_count;
    uint                 committed_edge_count;
    uint                 committed_bend_count;
    uint                 committed_hinge_count;
    uint                 opening_iterations;
    bool                 topology_dirty;
    bool                 cut_applied_this_update;
    uint[]               render_to_particle;
    uint[]               particle_sources;
    uint[]               particle_source_storage;
    float[]              transport;
    float[]              transport_storage;
    Vec3[]               rest;                // node-local, per physical particle
    Vec3[]               rest_storage;
    Vec3[]               solved_reference;    // world, end of the last solved substep
    Vec3[]               solved_reference_storage;
    Vec3[]               current_reference;   // world, sampled by the current update
    Vec3[]               current_reference_storage;
    Vec3[]               staged_current_reference;
    Vec3[]               positions;           // world, last solved
    Vec3[]               position_storage;
    Vec3[]               velocities;
    Vec3[]               velocity_storage;
    Vec3[]               predicted;
    Vec3[]               predicted_storage;
    Vec3[]               accelerations;
    Vec3[]               acceleration_storage;
    Vec3[]               published;           // world, last publication
    Vec3[]               published_storage;
    float[]              inverse_masses;
    float[]              inverse_mass_storage;
    double[]             particle_masses;
    double[]             particle_mass_storage;
    uint[]               particle_bases;
    uint[]               split_parents;
    uint[]               pins;                // unique and ascending physical particle IDs
    uint[]               pin_storage;
    Vec3[]               pin_anchors;         // world, end of the last solved substep
    Vec3[]               pin_anchor_storage;
    Vec3[]               pin_targets;         // world, final pose of the current update
    Vec3[]               pin_target_storage;
    ClothSoftAttachment[] soft_attachments;
    ClothSoftAttachment[] soft_attachment_storage;
    Vec3[]               soft_anchors;        // world, end of the last solved substep
    Vec3[]               soft_anchor_storage;
    Vec3[]               soft_targets;        // world, final pose of the current update
    Vec3[]               soft_target_storage;
    Vec3[]               soft_lambdas;        // substep XPBD multipliers
    Vec3[]               soft_lambda_storage;
    ClothConstraint[]    edges;
    ClothConstraint[]    edge_storage;
    ClothConstraint[]    bends;
    ClothConstraint[]    bend_storage;
    ClothHinge[]         hinges;
    ClothHinge[]         hinge_storage;
    ClothCorner[]        corners;
    ClothTriangleUv[]    triangle_uvs;
    uint[]               material_particles;
    uint[]               material_sectors;
    uint[]               material_normal_domains;
    uint[]               material_base_normal_domains;
    uint[]               material_reference_faces;
    float[]              tangent_signs;
    Vec3[]               rest_tangents;
    Vec4[]               committed_tangents;
    Vec3[]               normal_accum;
    Vec3[]               tangent_accum;
    Vec3[]               particle_local;
    Vec3[]               particle_local_storage;
    Vec3[]               source_reference_scratch;
    SkinMat4[]           palette_scratch;
    Entity[]             joint_entities;
    Entity[]             colliders;
    ClothBody[]          bodies;
    ClothShape[]         shapes;
    Vec3[]               shape_starts;        // world, current substep
    Vec3[]               shape_ends;
    ClothContactResult   contact_result;
    ClothShape[]         shape_storage;
    ClothShape[]         staged_shapes;
    ClothBody[]          staged_bodies;
    Vec3[]               staged_solved_reference;
    Vec3[]               staged_positions;
    Vec3[]               staged_velocities;
    Vec3[]               staged_published;
    Vec3[]               staged_pin_anchors;
    Vec3[]               staged_soft_anchors;
    Vec3[]               staged_soft_targets;
    ClothHinge[]         staged_hinges;
    Vec3[]               staged_shape_starts;
    Vec3[]               staged_shape_ends;
    Vec3[]               local_output;
    Vec3[]               local_normals;
    Vec4[]               local_tangents;
    Vec4[]               staged_colors;
    Vec3[]               publication_roundtrip;
    Vec3[]               publication_roundtrip_storage;
    Vec3[]               staged_predicted;
    Vec3[]               staged_accelerations;
    Vec3[]               staged_pin_targets;
    Mat4                 published_frame;
    Aabb                 local_bounds;
    ContactFrame[]       frames;
    ClothCandidate[]     candidates;
    ClothContact[]       contacts;
    ClothFace[]          faces;
    uint[]               canonical_vertices;
    uint[]               canonical_vertex_storage;
    ulong[]              adjacent_vertices;
    ulong[]              adjacent_vertex_storage;
    ClothSelfPrimitive[] self_primitives;
    ClothSelfPrimitive[] self_primitive_storage;
    Vec3[]               sweep_start;
    Vec3[]               sweep_start_storage;
    Aabb[]               sweep_bounds;
    Aabb[]               sweep_bounds_storage;
    usz[]                path_heads;
    usz[]                path_head_storage;
    ClothPathNode[]      path_nodes;
    ContactIntervals[]   path_values;
    ContactMotion[]      body_motions;
    usz                  path_count;
    double               sweep_begin;
    double               sweep_end;
    bool                 sweep_active;
    uint[]               corner_sectors;
    uint[]               sector_bases;
    double[]             sector_shares;
    bool[]               base_pinned;
    bool[]               base_has_soft;
    float[]              base_soft_compliance;
    ClothConstraint[]    base_edges;
    ClothInteriorEdge[]  interior_edges;
    bool[]               committed_edge_cut;
    bool[]               staged_edge_cut;
    uint[]               committed_sector_to_particle;
    uint[]               staged_sector_to_particle;
    ClothCutPathMeta[]   cut_paths;
    uint[]               cut_path_edges;
    ClothCutResult[]     cut_results;
    ClothCutResult[]     staged_cut_results;
    uint[]               pending_requests;
    uint                 pending_request_count;
    ClothSettle          settle;
    uint[]               selected_paths_scratch;
    uint[]               sector_scratch;
    uint[]               sector_root_scratch;
    uint[]               split_group_starts;
    uint[]               split_group_counts;
    uint[]               split_group_members;
    double[]             split_group_masses;
    uint[]               pre_split_canonical;
    ulong[]              pre_split_adjacent;
    ClothOpeningPair[]   opening_pairs;
    ContactVector[]      opening_work_positions;
}

<* Retained source and settings; owned arrays are read-only. *>
struct ClothAuthoring {
    ClothDesc   desc;
    bool        held; // runtime hold; never serialized
    GeometryId  source;
    uint        source_revision;
    bool        source_vertex_motion;
    bool        skinned;
    SkeletonId  skeleton;
    uint        skeleton_revision;
    Entity[]    joint_entities;
    scene::Mesh captured_mesh;
}

<* Authored cloth and its optional component-owned simulation state. *>
struct Cloth {
    ClothAuthoring* authoring;
    ClothState* state;
}

<* Whether the cloth has its private geometry and simulation state. *>
fn bool Cloth.is_prepared(&self) => self.state != null;

<*
 Attach simulation over an owned geometry copy.
 @param [&inout] assets : "Owns the copy; outlives the cloth."
 @param [&in] node : "Live node with current, invertible world transform."
 @param desc : "Pins, seams, collider identities and settings are copied."
 @param [inout] world : "Required when preparing a skinned source."
 @return? NO_MESH, CLOTH_EXISTS, physics::SOURCE_UNAVAILABLE, physics::NO_BODY
 @return? CONTACT_UNRESOLVED, CONTACT_NONCONVERGENT, CONTACT_PRECISION_EXCEEDED, FRAME_UNRESOLVED, BEND_UNRESOLVED
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require self.world.is_registered(Cloth)
*>
fn void? Scene.add_cloth(
    &self,
    AssetStore* assets,
    Node* node,
    ClothDesc desc,
    PhysicsWorld* world = null,
) {
    self.attach_cloth(assets, node, desc)!;
    defer catch self.remove_component(node, Cloth);
    return prepare(
        scene:  self,
        assets: assets,
        node:   node,
        world:  world,
    );
}

<*
 Attach cloth authoring while preserving its existing source mesh.
 @param [&in] assets : "Resolves retained source geometry; unchanged."
 @param [&in] node : "Live node carrying the source Mesh."
 @param desc : "Pins, seams and collider identities are copied."
 @return? NO_MESH, CLOTH_EXISTS, physics::SOURCE_UNAVAILABLE
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require self.world.is_registered(Cloth)
*>
fn void? Scene.attach_cloth(
    &self,
    AssetStore* assets,
    Node* node,
    ClothDesc desc,
) {
    scene::Mesh* mesh = self.get(node, scene::Mesh);
    if (!mesh) return NO_MESH~;
    if (self.has(node, Cloth)) return CLOTH_EXISTS~;
    check_cloth_desc(desc)!;
    if (!assets.geometries.is_live(mesh.geometry)) return c3d::INVALID_ID~;

    GeometryAsset* source = assets.geometry(mesh.geometry);
    check_cloth_source(
        scene:  self,
        assets: assets,
        node:   node,
        mesh:   mesh,
        source: source,
    )!;
    check_collider_owners(self, desc.colliders)!;

    bool skinned = self.has(node, SkinBinding);
    ClothAuthoring* authoring;
    @pool() {
        check_cloth_authoring(&source.data, desc)!;
        Entity[] joint_entities;
        if (skinned) {
            SkinBinding* binding = self.get(node, SkinBinding);
            joint_entities = alloc::new_array(tmem, Entity, (sz)binding.joints.len);
            foreach (index, joint : binding.joints) joint_entities[index] = joint.id;
        }
        authoring = copy_authoring(self.allocator, desc, joint_entities)!;
    };

    authoring.source = mesh.geometry;
    authoring.source_revision = source.header.revision;
    authoring.source_vertex_motion = mesh.vertex_motion;
    authoring.skinned = skinned;
    authoring.captured_mesh = *mesh;
    if (skinned) {
        SkinBinding* binding = self.get(node, SkinBinding);
        authoring.skeleton = binding.skeleton;
        authoring.skeleton_revision = assets.skeleton(binding.skeleton).header.revision;
    }
    self.add(node, (Cloth){ .authoring = authoring });
}

fn void? initial_cloth_publication(
    PhysicsWorld* world,
    ClothState* state,
    Mat4 frame,
    bool colors_changed = false,
) @private {
    state.contact_result = {};
    state.contact_result.stage = ClothContactStage.ARITHMETIC;
    if (!physics::contact_arithmetic_supported()) return CONTACT_PRECISION_EXCEEDED~;

    state.contact_result.stage = ClothContactStage.BINDINGS;
    sample_bodies(world.scene, state);

    prepare_publication(world, state, false)!;

    state.contact_result.stage = ClothContactStage.PUBLICATION;
    bool changed = stage_local_positions(state, frame, true)!;
    usz unresolved = contact_pass(
        world:     world,
        state:     state,
        positions: state.publication_roundtrip,
        apply:     false,
    )!;
    if (unresolved != 0) {
        state.contact_result.stage = ClothContactStage.PUBLICATION;
        return CONTACT_PRECISION_EXCEEDED~;
    }

    state.contact_result.stage = ClothContactStage.MATERIAL;
    stage_material_frames(state, changed)!;

    state.published[..] = state.publication_roundtrip[..];
    state.positions[..] = state.published[..];
    state.predicted[..] = state.published[..];
    state.velocities[..] = (Vec3){};
    state.accelerations[..] = (Vec3){};
    state.solved_reference[..] = state.current_reference[..];
    if (state.desc.collisions.continuous) {
        state.sweep_start[..] = state.published[..];
        foreach (index, point : state.published) {
            state.sweep_bounds[index] = { .min = point, .max = point };
        }
    }

    foreach (slot, pin : state.pins) {
        state.pin_anchors[slot] = state.current_reference[pin];
        state.pin_targets[slot] = state.current_reference[pin];
    }

    foreach (slot, attachment : state.soft_attachments) {
        state.soft_anchors[slot] = state.current_reference[attachment.particle];
        state.soft_targets[slot] = state.current_reference[attachment.particle];
        state.soft_lambdas[slot] = {};
    }

    finish_body_poses(state);
    commit_local_publication(
        state:          state,
        world:          frame,
        changed:        changed,
        colors_changed: colors_changed,
    );
    state.contact_result.stage = ClothContactStage.NONE;
}

<*
 Prepare pending cloth atomically; prepared cloth remains unchanged.
 @param [&inout] scene : "Listed contact bodies have completed normal physics synchronization."
 @param [&inout] assets : "Owns private geometry; outlives the cloth."
 @param [&in] node : "Carries Cloth and its source Mesh; world matrix current."
 @param [inout] world : "Required when preparing a skinned source."
 @return? NO_MESH, physics::SOURCE_UNAVAILABLE, physics::NO_BODY
 @return? CONTACT_UNRESOLVED, CONTACT_NONCONVERGENT, CONTACT_PRECISION_EXCEEDED, FRAME_UNRESOLVED, BEND_UNRESOLVED
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, Cloth)
*>
fn void? prepare(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    PhysicsWorld* world = null,
) {
    Cloth* component = scene.get(node, Cloth);
    if (component.is_prepared()) return;

    if (world && (world.scene != scene || world.assets != assets)) return c3d::INVALID_ARGUMENT~;

    ClothAuthoring* authoring = component.authoring;
    ClothDesc desc = authoring.desc;
    scene::Mesh* mesh = scene.get(node, scene::Mesh);
    if (!mesh) return NO_MESH~;
    if (!c3d::same_id(mesh.geometry, authoring.source)) return c3d::INVALID_ARGUMENT~;
    if (!assets.geometries.is_live(authoring.source)) return c3d::INVALID_ID~;

    GeometryAsset* source = assets.geometry(authoring.source);
    if (authoring.skinned && source.header.revision != authoring.source_revision) return c3d::INVALID_ARGUMENT~;
    check_cloth_source(
        scene:  scene,
        assets: assets,
        node:   node,
        mesh:   mesh,
        source: source,
    )!;
    if (scene.has(node, SkinBinding) != authoring.skinned) return c3d::INVALID_ARGUMENT~;

    SkinBinding* binding;
    if (authoring.skinned) {
        if (!world) return c3d::INVALID_ARGUMENT~;
        binding = scene.get(node, SkinBinding);
        if (!c3d::same_id(binding.skeleton, authoring.skeleton)
            || !assets.skeletons.is_live(authoring.skeleton)
            || assets.skeleton(authoring.skeleton).header.revision != authoring.skeleton_revision
            || binding.joints.len != authoring.joint_entities.len) {
            return c3d::INVALID_ARGUMENT~;
        }
        foreach (index, expected : authoring.joint_entities) {
            if (!c3d::same_id(binding.joints[index].id, expected)) return c3d::INVALID_ARGUMENT~;
        }
    }

    @pool() {
        check_seams(desc.seams, (uint)source.data.positions.len)!;

        uint particle_count;
        uint[] render_to_particle = build_render_particle_map(&source.data, desc.render_particles, &particle_count)!;
        uint[] particle_sources = alloc::new_array(tmem, uint, (sz)particle_count);
        foreach (render_vertex, particle : render_to_particle) particle_sources[particle] = (uint)render_vertex;
        check_transport_authoring(desc.transport, particle_count)!;

        ClothAttachmentPlan attachment_plan = build_attachment_plan(
            legacy_pins:        desc.pins,
            render_to_particle: render_to_particle,
            attachments:        desc.attachments,
            particle_count:     particle_count,
        )!;

        Vec3[] rest = alloc::new_array(tmem, Vec3, (sz)particle_count);
        Vec3[] edge_positions = alloc::new_array(tmem, Vec3, (sz)particle_count);
        foreach (particle, source_vertex : particle_sources) {
            Vec3 local_position = source.data.positions[source_vertex];
            rest[particle] = local_position;
            edge_positions[particle] = maths::transform_point(node.world, local_position);
        }
        check_world_positions(edge_positions)!;

        Vec3[] initial_positions = edge_positions;
        if (authoring.skinned) {
            initial_positions = alloc::new_array(tmem, Vec3, (sz)particle_count);
            SkinMat4[] palette_scratch = alloc::new_array(tmem, SkinMat4, (sz)binding.joints.len);
            Vec3[] source_scratch = alloc::new_array(tmem, Vec3, (sz)source.data.positions.len);
            evaluate_skinned_particles(
                mesh_node:        node,
                binding:          binding,
                inverse_bind:     assets.skeleton(authoring.skeleton).data.inverse_bind,
                source:           &source.data,
                particle_sources: particle_sources,
                palette_scratch:  palette_scratch,
                source_scratch:   source_scratch,
                out_particles:    initial_positions,
            )!;
        }

        ClothSectorPlan sector_plan = build_sector_plan(
            data:                &source.data,
            render_to_particle:  render_to_particle,
            base_particle_count: particle_count,
            pin_count:           (uint)attachment_plan.pins.len,
            soft_count:          (uint)attachment_plan.soft.len,
            rest_positions:      rest,
            edge_positions:      edge_positions,
            world_positions:     authoring.skinned ? initial_positions : {},
            desc:                desc,
        )!;
        ClothMaterialPlan material_plan = build_material_plan(
            source:         &source.data,
            desc:           desc,
            corner_sectors: sector_plan.corner_sectors,
        )!;

        ClothCapture capture = capture_colliders(
            scene:      scene,
            owners:     desc.colliders,
            max_shapes: desc.collisions.max_shapes,
            world:      world,
        )!;

        GeometryId copy = assets.add_geometry(&material_plan.geometry)!;
        defer catch assets.remove_geometry(copy);

        ClothState* state = allocate_cloth_state(
            allocator:             scene.allocator,
            sector_plan:           &sector_plan,
            source_vertex_count:   (uint)source.data.positions.len,
            material_vertex_count: material_plan.material_vertex_count,
            normal_domain_count:   material_plan.normal_domain_count,
            corner_count:          (uint)material_plan.corners.len,
            face_count:            (uint)(source.data.indices.len / 3),
            bend_count:            (uint)sector_plan.initial_bends.len,
            hinge_count:           (uint)sector_plan.initial_hinges.len,
            body_count:            (uint)capture.bodies.len,
            joint_count:           authoring.skinned ? (uint)authoring.joint_entities.len : 0,
            tangent_frame:         desc.tangent_frame,
            crowd:                 false,
            collisions:            desc.collisions,
        )!;
        defer catch alloc::free(scene.allocator, state);

        authoring.source_revision = source.header.revision;
        state.desc = desc;
        state.colliders[..] = desc.colliders[..];
        state.desc.colliders = state.colliders;
        state.bodies[..] = capture.bodies[..];
        state.staged_bodies[..] = capture.bodies[..];
        state.shapes = state.shape_storage[:capture.shapes.len];
        state.shapes[..] = capture.shapes[..];
        state.assets = assets;
        state.source = authoring.source;
        state.source_revision = authoring.source_revision;
        state.geometry = copy;
        state.source_vertex_motion = authoring.source_vertex_motion;

        state.skinned = authoring.skinned;
        state.skeleton = authoring.skeleton;
        state.skeleton_revision = authoring.skeleton_revision;
        if (authoring.skinned) {
            state.joint_entities[..] = authoring.joint_entities[..];
        }

        seed_cloth_topology(
            state:             state,
            sector_plan:       &sector_plan,
            material_plan:     &material_plan,
            attachment_plan:   &attachment_plan,
            rest:              rest,
            initial_positions: initial_positions,
        );
        state.published_frame = node.world;

        authoring.captured_mesh = *mesh;
        state.captured_mesh = *mesh;

        if (authoring.skinned) {
            Node* out_node = scene.add_node(parent: node, name: "cloth_output")!;
            defer catch scene.remove(out_node);
            out_node.visible = false;
            out_node.visible_effective = false;
            out_node.layers = node.layers;
            out_node.world = node.world;
            scene.add(out_node, (ClothOutput){ .owner = node.id });
            scene.add(out_node, (scene::Mesh){
                .geometry             = copy,
                .material             = authoring.captured_mesh.material,
                .cast_shadow          = authoring.captured_mesh.cast_shadow,
                .receive_shadow       = authoring.captured_mesh.receive_shadow,
                .trace                = authoring.captured_mesh.trace,
                .vertex_motion        = true,
                .vertex_history_token = authoring.captured_mesh.vertex_history_token + 1,
            });
            state.output_node = out_node.id;

            initial_cloth_publication(world, state, node.world)!;

            scene.remove_component(node, scene::Mesh);
            out_node.visible = true;
            out_node.visible_effective = node.visible_effective;
            component.state = state;
        } else {
            mesh.reset_vertex_history();
            component.state = state;
            mesh.geometry = copy;
            mesh.vertex_motion = true;
        }
    };
}

<*
 Prepare pending cloth in a subtree, retaining successful owners.
 @param [&inout] scene : "Listed contact bodies have completed normal physics synchronization."
 @param [&inout] assets : "Owns private geometry; outlives the cloth."
 @param [in] root : "Null selects the scene root; root is included."
 @param [inout] world : "Required when preparing skinned or crowd cloth."
 @return? NO_MESH, physics::SOURCE_UNAVAILABLE, physics::NO_BODY
 @return? CONTACT_UNRESOLVED, CONTACT_NONCONVERGENT, CONTACT_PRECISION_EXCEEDED, FRAME_UNRESOLVED, BEND_UNRESOLVED
 @return? REFERENCE_UNAVAILABLE, OWNERSHIP_CHANGED
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? prepare_subtree(
    Scene* scene,
    AssetStore* assets,
    Node* root = null,
    PhysicsWorld* world = null,
) {
    if (!root) root = scene.root;
    fault failure;
    scene.@each(Cloth; entity, component) {
        Node* node = scene.node(entity);
        Node* ancestor = node;
        while (ancestor && ancestor != root) ancestor = ancestor.parent;
        if (ancestor) {
            if (catch excuse = prepare(
                scene:  scene,
                assets: assets,
                node:   node,
                world:  world,
            )) {
                if (!failure) failure = excuse;
            }
        }
    };
    scene.@each(CrowdCloth; entity, crowd_cloth) {
        if (!crowd_cloth.is_prepared()) {
            Node* node = scene.node(entity);
            Node* ancestor = node;
            while (ancestor && ancestor != root) ancestor = ancestor.parent;
            if (ancestor) {
                if (catch excuse = prepare_crowd_cloth(
                    world:  world,
                    assets: assets,
                    owner:  node,
                )) {
                    if (!failure) failure = excuse;
                }
            }
        }
    };
    if (failure) return failure~;
}

<*
 Restore the source mesh and remove cloth ownership.
 @param [&in] node : "Live node with Cloth."
 @require self.has(node, Cloth)
*>
fn void Scene.remove_cloth(&self, Node* node) {
    Cloth* cloth = self.get(node, Cloth);
    ClothAuthoring* authoring = cloth.authoring;
    ClothState* state = cloth.state;
    if (state && state.skinned) {
        ulong next_token = state.captured_mesh.vertex_history_token;
        if (state.output_node.generation && self.world.is_alive(state.output_node)) {
            Node* out_node = self.node(state.output_node);
            if (scene::Mesh* out_mesh = self.get(out_node, scene::Mesh)) {
                if (out_mesh.vertex_history_token > next_token) {
                    next_token = out_mesh.vertex_history_token;
                }
            }
            self.remove(out_node);
        }
        state.output_node = {};
        if (!self.has(node, scene::Mesh)) {
            scene::Mesh restored = state.captured_mesh;
            restored.geometry = authoring.source;
            restored.vertex_motion = authoring.source_vertex_motion;
            restored.vertex_history_token = next_token + 1;
            self.add(node, restored);
        }
    } else if (self.has(node, scene::Mesh)) {
        scene::Mesh* mesh = self.get(node, scene::Mesh);
        if (!state || c3d::same_id(mesh.geometry, state.geometry)) {
            mesh.geometry = authoring.source;
            mesh.vertex_motion = authoring.source_vertex_motion;
            if (state) mesh.reset_vertex_history();
        }
    }
    self.remove_component(node, Cloth);
}

<*
 Solve prepared cloth after final poses; pending cloth remains unchanged.
 @require self.cloth_update_serial != self.update_serial
*>
fn void PhysicsWorld.update_cloths(&self) {
    self.cloth_update_serial = self.update_serial;
    self.cloth_stats = {};
    uint steps = self.steps_last_update;

    self.scene.@each(Cloth; Entity entity, Cloth* component) {
        if (!component.is_prepared()) {
            self.cloth_stats.pending++;
        } else {
            ClothState* state = component.state;
            Node* node = self.scene.node(entity);
            bool held = component.authoring.held;
            time::Clock started = clock::now();
            double publication_seconds;
            ClothUpdateKind kind = SIMULATED;
            ClothUpdateKind? updated = update_cloth(
                world:               self,
                state:               state,
                node:                node,
                held:                held,
                steps:               steps,
                publication_seconds: &publication_seconds,
            );
            if (catch excuse = updated) {
                state.contact_result.failure = excuse;
                if (excuse != OWNERSHIP_CHANGED && !held && !state.settle.resting) {
                    time::Clock reexpression_start = clock::now();
                    if (catch reexpression_failure = reexpress_cloth(state, node.world)) {
                        state.contact_result.failure = reexpression_failure;
                        state.contact_result.stage = ClothContactStage.REEXPRESSION;
                    }
                    publication_seconds += (clock::now() - reexpression_start).to_sec();
                }
                self.cloth_stats.failed++;
            } else {
                kind = updated;
            }

            tally_cloth(
                stats:               &self.cloth_stats,
                state:               state,
                kind:                kind,
                total_seconds:       (clock::now() - started).to_sec(),
                publication_seconds: publication_seconds,
            );
        }
    };

    update_crowd_cloths(self, steps);
}

<*
 Translate all world-space state by the negated offset.
 @require offset.y == 0
*>
fn void ClothState.shift_origin(&self, Vec3 offset) {
    self.published_frame.m03 -= offset.x;
    self.published_frame.m13 -= offset.y;
    self.published_frame.m23 -= offset.z;
    foreach (&position : self.solved_reference) *position -= offset;
    foreach (&position : self.current_reference) *position -= offset;
    foreach (&position : self.staged_solved_reference) *position -= offset;
    foreach (&position : self.staged_current_reference) *position -= offset;
    foreach (&position : self.positions) *position -= offset;
    foreach (&position : self.predicted) *position -= offset;
    foreach (&position : self.published) *position -= offset;
    foreach (&position : self.pin_anchors) *position -= offset;
    foreach (&position : self.pin_targets) *position -= offset;
    foreach (&position : self.soft_anchors) *position -= offset;
    foreach (&position : self.soft_targets) *position -= offset;
    foreach (&position : self.shape_starts) *position -= offset;
    foreach (&position : self.shape_ends) *position -= offset;
    foreach (&body : self.bodies) {
        body.solved.position -= offset;
        body.current.position -= offset;
        body.published.position -= offset;
        body.rested.position -= offset;
    }
    foreach (&body : self.staged_bodies) {
        body.solved.position -= offset;
        body.current.position -= offset;
        body.published.position -= offset;
        body.rested.position -= offset;
    }
    foreach (&position : self.sweep_start) *position -= offset;
    foreach (&bounds : self.sweep_bounds) {
        bounds.min -= offset;
        bounds.max -= offset;
    }
    foreach (&motion : self.body_motions) {
        motion.last_position -= (ContactVector)offset;
        for (uint axis = 0; axis < 3; axis++) {
            motion.first.position[axis].min -= offset[axis];
            motion.first.position[axis].max -= offset[axis];
        }
    }
    foreach (&path : self.path_nodes[:self.path_count]) {
        if (path.kind == LINEAR) {
            path.start -= (ContactVector)offset;
            path.end -= (ContactVector)offset;
        }
    }
    foreach (&value : self.path_values[:self.path_count]) {
        for (uint axis = 0; axis < 3; axis++) {
            (*value)[axis].min -= offset[axis];
            (*value)[axis].max -= offset[axis];
        }
    }
    self.sweep_active = false;
    self.path_count = 0;
}

<*
 Reset collider observations without changing cloth positions or velocities.
 @param [inout] component : "Borrowed mutably for this call; null or pending is unchanged."
*>
fn void reset_contact_history(Cloth* component) {
    if (!component || !component.state) return;
    foreach (&body : component.state.bodies) body.observed = body.published_observed = false;
}

<* Default cloth settings with no pins or ground. *>
fn ClothDesc default_cloth_desc() {
    return {
        .substeps          = DEFAULT_CLOTH_SUBSTEPS,
        .iterations        = DEFAULT_CLOTH_ITERATIONS,
        .stretch_stiffness = DEFAULT_STRETCH_STIFFNESS,
        .bend_stiffness    = DEFAULT_BEND_STIFFNESS,
        .damping           = DEFAULT_CLOTH_DAMPING,
        .thickness         = DEFAULT_CLOTH_THICKNESS,
        .gravity_scale     = 1,
        .collisions        = default_cloth_collision_desc(),
        .tears             = default_cloth_tear_limits(),
        .sleep_steps       = DEFAULT_CLOTH_SLEEP_STEPS,
    };
}

<*
 Select vertices by red channel; caller owns the result.
 @param [&in] geometry : "Retained positions and equally sized colors."
 @param threshold : "Red-channel cutoff in [0, 1]; equal values are selected."
 @return "Ascending indices allocated with allocator."
 @require geometry.colors.len == geometry.positions.len
 @require threshold >= 0 && threshold <= 1
*>
fn uint[] pins_from_colors(Allocator allocator, Geometry* geometry, float threshold = 0.5f) {
    usz count;
    foreach (color : geometry.colors) {
        if (color.x >= threshold) count++;
    }
    uint[] pins = alloc::new_array(allocator, uint, (sz)count);
    usz next;
    foreach (index, color : geometry.colors) {
        if (color.x >= threshold) pins[next++] = (uint)index;
    }
    return pins;
}

fn void free_cloth(Entity entity, void* component, void* user) @private {
    Cloth* cloth = component;
    Allocator allocator = *(Allocator*)user;
    if (cloth.state) {
        cloth.state.assets.remove_geometry(cloth.state.geometry);
        alloc::free(allocator, cloth.state);
    }
    alloc::free(allocator, cloth.authoring);
}
