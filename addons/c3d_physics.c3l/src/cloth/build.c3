module c3d::physics::cloth;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::physics @public;
import c3d::scene;
import std::math;
import std::sort;

const float MIN_TRIANGLE_AREA @private = 1e-12f; // square metres; a smaller triangle has no stable normal
const Vec3 COLLAPSED_AXIS @private = { 0, 1, 0 }; // separates a constraint whose rest length is zero

struct ClothCounts @local {
    uint               base_vertices;
    uint               vertices;
    uint               sectors;
    uint               source_vertices;
    uint               material_vertices;
    uint               normal_domains;
    uint               corners;
    uint               pins;
    uint               soft_attachments;
    uint               edges;
    uint               base_edges;
    uint               interior_edges;
    uint               faces;
    uint               bends;
    uint               hinges;
    uint               cut_paths;
    uint               cut_path_edges;
    uint               max_requests;
    uint               opening_iterations;
    uint               bodies;
    uint               joints;
    bool               tangent_frame;
    bool               crowd;
    ClothCollisionDesc collisions;
}

fn ClothAuthoring* carve_authoring(
    BlockCursor* cursor,
    ClothDesc desc,
    Entity[] joint_entities = {},
) @local {
    usz total_cut_vertices;
    foreach (cut : desc.cuts) total_cut_vertices += cut.vertices.len;

    ClothAuthoring[] owners = physics::carve(cursor, ClothAuthoring, 1);
    uint[] pins = physics::carve(cursor, uint, desc.pins.len);
    Entity[] colliders = physics::carve(cursor, Entity, desc.colliders.len);
    ClothSeam[] seams = physics::carve(cursor, ClothSeam, desc.seams.len);
    uint[] render_particles = physics::carve(cursor, uint, desc.render_particles.len);
    ClothAttachment[] attachments = physics::carve(cursor, ClothAttachment, desc.attachments.len);
    ClothRestAngle[] rest_angles = physics::carve(cursor, ClothRestAngle, desc.rest_angles.len);
    float[] transport = physics::carve(cursor, float, desc.transport.len);
    ClothCutPath[] cuts = physics::carve(cursor, ClothCutPath, desc.cuts.len);
    uint[] cut_vertices = physics::carve(cursor, uint, total_cut_vertices);
    Entity[] joints = physics::carve(cursor, Entity, joint_entities.len);
    if (!cursor.base) return null;

    pins[..] = desc.pins[..];
    colliders[..] = desc.colliders[..];
    seams[..] = desc.seams[..];
    render_particles[..] = desc.render_particles[..];
    attachments[..] = desc.attachments[..];
    rest_angles[..] = desc.rest_angles[..];
    transport[..] = desc.transport[..];
    usz cut_vertex_cursor;
    foreach (index, cut : desc.cuts) {
        uint[] copied_vertices = cut_vertices[cut_vertex_cursor:cut.vertices.len];
        copied_vertices[..] = cut.vertices[..];
        cut_vertex_cursor += cut.vertices.len;
        cuts[index] = cut;
        cuts[index].vertices = copied_vertices;
    }
    joints[..] = joint_entities[..];

    ClothDesc copied = desc;
    copied.pins = pins;
    copied.colliders = colliders;
    copied.seams = seams;
    copied.render_particles = render_particles;
    copied.attachments = attachments;
    copied.rest_angles = rest_angles;
    copied.transport = transport;
    copied.cuts = cuts;

    owners[0] = {
        .desc           = copied,
        .joint_entities = joints,
    };
    return owners.ptr;
}

fn ClothAuthoring*? copy_authoring(
    Allocator allocator,
    ClothDesc desc,
    Entity[] joint_entities = {},
) @private {
    BlockCursor measure;
    carve_authoring(&measure, desc, joint_entities);
    if (measure.offset > (usz)sz::max) return c3d::CAPACITY_EXCEEDED~;

    char*? allocation = alloc::malloc_try(allocator, (sz)measure.offset);
    if (catch allocation) return c3d::CAPACITY_EXCEEDED~;

    BlockCursor fill = { .base = allocation };
    return carve_authoring(&fill, desc, joint_entities);
}

fn void? check_cloth_desc(ClothDesc desc) @private {
    if (!desc.substeps || !desc.iterations) return c3d::INVALID_ARGUMENT~;
    if (!unit_interval(desc.stretch_stiffness) || !unit_interval(desc.bend_stiffness)) return c3d::INVALID_ARGUMENT~;
    if (!(desc.damping >= 0) || !math::is_finite(desc.damping)) return c3d::INVALID_ARGUMENT~;
    if (!(desc.thickness >= 0) || !math::is_finite(desc.thickness)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(desc.gravity_scale) || !math::is_finite(desc.ground_height)) return c3d::INVALID_ARGUMENT~;
    if (desc.tangent_uv_set > 1) return c3d::INVALID_ARGUMENT~;
    check_attachment_desc(desc.attachments)!;
    check_bend_desc(desc)!;
    check_transport_desc(desc.transport)!;
    check_tear_desc(desc)!;

    ClothCollisionDesc collision = desc.collisions;
    if (!math::is_finite(collision.contact_tolerance) || collision.contact_tolerance <= 0) return c3d::INVALID_ARGUMENT~;
    if (!collision.contact_iterations || !collision.max_shapes || !collision.max_candidates || !collision.max_contacts
        || !collision.max_ccd_iterations) {
        return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_cloth_geometry(GeometryAsset* source) @private {
    Geometry* data = &source.data;
    if (!data.positions.len) return physics::SOURCE_UNAVAILABLE~;
    if (data.targets.len || source.target_count || data.channels.len || data.custom_data.len) return c3d::UNSUPPORTED~;
    if (data.topology != Topology.TRIANGLES || !data.indices.len) return c3d::UNSUPPORTED~;
    if (data.indices.len % 3) return c3d::INVALID_ARGUMENT~;
    foreach (index : data.indices) {
        if (index >= data.positions.len) return c3d::INVALID_ARGUMENT~;
    }
    foreach (position : data.positions) {
        if (!finite_vector(position)) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_cloth_mesh(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    scene::Mesh* mesh,
    GeometryAsset* source,
) @private {
    if (mesh.morph_weights.len || mesh.has_bounds_override) return c3d::UNSUPPORTED~;
    if (node_in_lod_group(scene, node)) return c3d::UNSUPPORTED~;
    check_cloth_material(assets, mesh.material, false)!;
    check_cloth_geometry(source)!;
}

fn void? check_cloth_source(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    scene::Mesh* mesh,
    GeometryAsset* source,
) @private {
    check_cloth_mesh(
        scene:  scene,
        assets: assets,
        node:   node,
        mesh:   mesh,
        source: source,
    )!;

    Geometry* data = &source.data;
    if (scene.has(node, SkinBinding)) {
        if (!data.joints.len && !data.weights.len) return c3d::UNSUPPORTED~;
        check_skin_binding(
            scene:  scene,
            assets: assets,
            node:   node,
            data:   data,
        )!;
    } else if (data.joints.len || data.weights.len || source.shape.skinned) {
        return c3d::UNSUPPORTED~;
    }
}

fn void? check_cloth_authoring(Geometry* data, ClothDesc desc) @private {
    uint render_count = (uint)data.positions.len;
    check_seams(desc.seams, render_count)!;

    uint particle_count;
    uint[] render_to_particle = build_render_particle_map(data, desc.render_particles, &particle_count)!;
    check_transport_authoring(desc.transport, particle_count)!;

    uint normal_domain_count;
    (void)build_normal_domains(data, render_to_particle, &normal_domain_count)!;

    if (desc.tangent_frame) (void)select_tangent_uvs(data, desc)!;

    ClothAttachmentPlan attachment_plan = build_attachment_plan(
        legacy_pins:        desc.pins,
        render_to_particle: render_to_particle,
        attachments:        desc.attachments,
        particle_count:     particle_count,
    )!;

    Vec3[] rest = alloc::new_array(tmem, Vec3, (sz)particle_count);
    foreach (render_vertex, particle : render_to_particle) rest[particle] = data.positions[render_vertex];

    ClothSectorPlan sector_plan = build_sector_plan(
        data:                data,
        render_to_particle:  render_to_particle,
        base_particle_count: particle_count,
        pin_count:           (uint)attachment_plan.pins.len,
        soft_count:          (uint)attachment_plan.soft.len,
        rest_positions:      rest,
        edge_positions:      {},
        world_positions:     {},
        desc:                desc,
    )!;
    (void)build_material_plan(data, desc, sector_plan.corner_sectors)!;
}

fn void? check_world_positions(Vec3[] world) @private {
    foreach (position : world) {
        if (!finite_vector(position)) return c3d::INVALID_ARGUMENT~;
    }
}

fn ClothState*? allocate_cloth_state(
    Allocator allocator,
    ClothSectorPlan* sector_plan,
    uint source_vertex_count,
    uint material_vertex_count,
    uint normal_domain_count,
    uint corner_count,
    uint face_count,
    uint bend_count,
    uint hinge_count,
    uint body_count,
    uint joint_count,
    bool tangent_frame,
    bool crowd,
    ClothCollisionDesc collisions,
) @private {
    ClothCounts counts = {
        .base_vertices      = sector_plan.base_particle_count,
        .vertices           = sector_plan.max_particles,
        .sectors            = sector_plan.sector_count,
        .source_vertices    = source_vertex_count,
        .material_vertices  = material_vertex_count,
        .normal_domains     = normal_domain_count,
        .corners            = corner_count,
        .pins               = sector_plan.max_pins,
        .soft_attachments   = sector_plan.max_soft,
        .edges              = sector_plan.max_edges,
        .base_edges         = (uint)sector_plan.base_edges.len,
        .interior_edges     = (uint)sector_plan.interior_edges.len,
        .faces              = face_count,
        .bends              = bend_count,
        .hinges             = hinge_count,
        .cut_paths          = (uint)sector_plan.cut_paths.len,
        .cut_path_edges     = (uint)sector_plan.cut_path_edges.len,
        .max_requests       = sector_plan.max_requests,
        .opening_iterations = sector_plan.opening_iterations,
        .bodies             = body_count,
        .joints             = joint_count,
        .tangent_frame      = tangent_frame,
        .crowd              = crowd,
        .collisions         = collisions,
    };

    BlockCursor measure;
    carve_cloth_state(&measure, counts);
    if (measure.offset > (usz)sz::max) return c3d::CAPACITY_EXCEEDED~;

    char*? allocation = alloc::malloc_try(allocator, (sz)measure.offset);
    if (catch allocation) return c3d::CAPACITY_EXCEEDED~;

    BlockCursor fill = { .base = allocation };
    return carve_cloth_state(&fill, counts);
}

fn ClothState* carve_cloth_state(BlockCursor* cursor, ClothCounts counts) @local {
    ClothState[] states = physics::carve(cursor, ClothState, 1);
    bool self_collision = counts.collisions.self_collision;
    bool continuous = counts.collisions.continuous;
    bool tangents = counts.tangent_frame;
    bool has_cuts = counts.cut_paths > 0;
    uint sector_scratch_count = has_cuts ? math::max(counts.sectors, counts.material_vertices) : 0;
    ClothState state = {
        .base_particle_count           = counts.base_vertices,
        .active_particle_count         = counts.base_vertices,
        .committed_particle_count      = counts.base_vertices,
        .opening_iterations            = counts.opening_iterations,
        .render_to_particle            = physics::carve(cursor, uint, counts.source_vertices),
        .particle_source_storage       = physics::carve(cursor, uint, counts.vertices),
        .transport_storage             = physics::carve(cursor, float, counts.vertices),
        .rest_storage                  = physics::carve(cursor, Vec3, counts.vertices),
        .solved_reference_storage      = physics::carve(cursor, Vec3, counts.vertices),
        .current_reference_storage     = physics::carve(cursor, Vec3, counts.vertices),
        .staged_current_reference      = physics::carve(cursor, Vec3, has_cuts ? counts.vertices : 0),
        .position_storage              = physics::carve(cursor, Vec3, counts.vertices),
        .velocity_storage              = physics::carve(cursor, Vec3, counts.vertices),
        .predicted_storage             = physics::carve(cursor, Vec3, counts.vertices),
        .acceleration_storage          = physics::carve(cursor, Vec3, counts.vertices),
        .published_storage             = physics::carve(cursor, Vec3, counts.vertices),
        .inverse_mass_storage          = physics::carve(cursor, float, counts.vertices),
        .particle_mass_storage         = physics::carve(cursor, double, has_cuts ? counts.vertices : 0),
        .particle_bases                = physics::carve(cursor, uint, has_cuts ? counts.vertices : 0),
        .split_parents                 = physics::carve(cursor, uint, has_cuts ? counts.vertices : 0),
        .pin_storage                   = physics::carve(cursor, uint, counts.pins),
        .pin_anchor_storage            = physics::carve(cursor, Vec3, counts.pins),
        .pin_target_storage            = physics::carve(cursor, Vec3, counts.pins),
        .soft_attachment_storage       = physics::carve(cursor, ClothSoftAttachment, counts.soft_attachments),
        .soft_anchor_storage           = physics::carve(cursor, Vec3, counts.soft_attachments),
        .soft_target_storage           = physics::carve(cursor, Vec3, counts.soft_attachments),
        .soft_lambda_storage           = physics::carve(cursor, Vec3, counts.soft_attachments),
        .edge_storage                  = physics::carve(cursor, ClothConstraint, counts.edges),
        .bend_storage                  = physics::carve(cursor, ClothConstraint, counts.bends),
        .hinge_storage                 = physics::carve(cursor, ClothHinge, counts.hinges),
        .corners                       = physics::carve(cursor, ClothCorner, counts.corners),
        .triangle_uvs                  = physics::carve(cursor, ClothTriangleUv, counts.faces),
        .material_particles            = physics::carve(cursor, uint, counts.material_vertices),
        .material_sectors              = physics::carve(cursor, uint, has_cuts ? counts.material_vertices : 0),
        .material_normal_domains       = physics::carve(cursor, uint, counts.material_vertices),
        .material_base_normal_domains  = physics::carve(cursor, uint, has_cuts ? counts.material_vertices : 0),
        .material_reference_faces      = physics::carve(cursor, uint, counts.material_vertices),
        .tangent_signs                 = physics::carve(cursor, float, tangents ? counts.material_vertices : 0),
        .rest_tangents                 = physics::carve(cursor, Vec3, tangents ? counts.material_vertices : 0),
        .committed_tangents            = physics::carve(cursor, Vec4, tangents ? counts.material_vertices : 0),
        .normal_accum                  = physics::carve(cursor, Vec3, counts.normal_domains),
        .tangent_accum                 = physics::carve(cursor, Vec3, tangents ? counts.material_vertices : 0),
        .particle_local_storage        = physics::carve(cursor, Vec3, counts.vertices),
        .source_reference_scratch      = physics::carve(cursor, Vec3, counts.joints ? counts.source_vertices : 0),
        .palette_scratch               = physics::carve(cursor, SkinMat4, counts.joints),
        .joint_entities                = physics::carve(cursor, Entity, counts.joints),
        .colliders                     = physics::carve(cursor, Entity, counts.bodies),
        .bodies                        = physics::carve(cursor, ClothBody, counts.bodies),
        .shape_storage                 = physics::carve(cursor, ClothShape, counts.collisions.max_shapes),
        .shape_starts                  = physics::carve(cursor, Vec3, counts.collisions.max_shapes),
        .shape_ends                    = physics::carve(cursor, Vec3, counts.collisions.max_shapes),
        .staged_shapes                 = physics::carve(cursor, ClothShape, counts.collisions.max_shapes),
        .staged_bodies                 = physics::carve(cursor, ClothBody, counts.bodies),
        .staged_solved_reference       = physics::carve(cursor, Vec3, counts.vertices),
        .staged_positions              = physics::carve(cursor, Vec3, counts.vertices),
        .staged_velocities             = physics::carve(cursor, Vec3, counts.vertices),
        .staged_published              = physics::carve(cursor, Vec3, counts.vertices),
        .staged_pin_anchors            = physics::carve(cursor, Vec3, counts.pins),
        .staged_soft_anchors           = physics::carve(cursor, Vec3, counts.soft_attachments),
        .staged_soft_targets           = physics::carve(cursor, Vec3, counts.soft_attachments),
        .staged_hinges                 = physics::carve(cursor, ClothHinge, counts.hinges),
        .staged_shape_starts           = physics::carve(cursor, Vec3, counts.collisions.max_shapes),
        .staged_shape_ends             = physics::carve(cursor, Vec3, counts.collisions.max_shapes),
        .local_output                  = physics::carve(cursor, Vec3, counts.material_vertices),
        .local_normals                 = physics::carve(cursor, Vec3, counts.material_vertices),
        .local_tangents                = physics::carve(cursor, Vec4, tangents ? counts.material_vertices : 0),
        .staged_colors                 = physics::carve(cursor, Vec4, counts.crowd ? counts.material_vertices : 0),
        .publication_roundtrip_storage = physics::carve(cursor, Vec3, counts.vertices),
        .staged_predicted              = physics::carve(cursor, Vec3, counts.vertices),
        .staged_accelerations          = physics::carve(cursor, Vec3, counts.vertices),
        .staged_pin_targets            = physics::carve(cursor, Vec3, counts.pins),
        .frames                        = physics::carve(cursor, ContactFrame, counts.collisions.max_shapes),
        .candidates                    = physics::carve(cursor, ClothCandidate, counts.collisions.max_candidates),
        .contacts                      = physics::carve(cursor, ClothContact, counts.collisions.max_contacts),
        .faces                         = physics::carve(cursor, ClothFace, self_collision ? counts.faces : 0),
        .canonical_vertex_storage      = physics::carve(cursor, uint, self_collision ? counts.vertices : 0),
        .adjacent_vertex_storage       = physics::carve(cursor, ulong, self_collision ? counts.edges : 0),
        .self_primitive_storage        = physics::carve(
            cursor: cursor,
            $Type:  ClothSelfPrimitive,
            count:  self_collision ? (usz)counts.vertices + counts.edges + counts.faces : 0,
        ),
        .sweep_start_storage           = physics::carve(cursor, Vec3, continuous ? counts.vertices : 0),
        .sweep_bounds_storage          = physics::carve(cursor, Aabb, continuous ? counts.vertices : 0),
        .path_head_storage             = physics::carve(cursor, usz, continuous ? counts.vertices : 0),
        .path_nodes                    = physics::carve(
            cursor: cursor,
            $Type:  ClothPathNode,
            count:  continuous ? (usz)counts.vertices + 4UL * counts.collisions.max_contacts : 0,
        ),
        .path_values                   = physics::carve(
            cursor: cursor,
            $Type:  ContactIntervals,
            count:  continuous ? (usz)counts.vertices + 4UL * counts.collisions.max_contacts : 0,
        ),
        .body_motions                  = physics::carve(cursor, ContactMotion, continuous ? counts.bodies : 0),
        .corner_sectors                = physics::carve(cursor, uint, has_cuts ? counts.corners : 0),
        .sector_bases                  = physics::carve(cursor, uint, counts.sectors),
        .sector_shares                 = physics::carve(cursor, double, counts.sectors),
        .base_pinned                   = physics::carve(cursor, bool, has_cuts ? counts.base_vertices : 0),
        .base_has_soft                 = physics::carve(cursor, bool, has_cuts ? counts.base_vertices : 0),
        .base_soft_compliance          = physics::carve(cursor, float, has_cuts ? counts.base_vertices : 0),
        .base_edges                    = physics::carve(cursor, ClothConstraint, has_cuts ? counts.base_edges : 0),
        .interior_edges                = physics::carve(cursor, ClothInteriorEdge, counts.interior_edges),
        .committed_edge_cut            = physics::carve(cursor, bool, counts.interior_edges),
        .staged_edge_cut               = physics::carve(cursor, bool, counts.interior_edges),
        .committed_sector_to_particle  = physics::carve(cursor, uint, counts.sectors),
        .staged_sector_to_particle     = physics::carve(cursor, uint, counts.sectors),
        .cut_paths                     = physics::carve(cursor, ClothCutPathMeta, counts.cut_paths),
        .cut_path_edges                = physics::carve(cursor, uint, counts.cut_path_edges),
        .cut_results                   = physics::carve(cursor, ClothCutResult, counts.cut_paths),
        .staged_cut_results            = physics::carve(cursor, ClothCutResult, counts.cut_paths),
        .pending_requests              = physics::carve(cursor, uint, counts.max_requests),
        .selected_paths_scratch        = physics::carve(cursor, uint, counts.cut_paths),
        .sector_scratch                = physics::carve(cursor, uint, sector_scratch_count),
        .sector_root_scratch           = physics::carve(cursor, uint, sector_scratch_count),
        .split_group_starts            = physics::carve(cursor, uint, has_cuts ? counts.vertices : 0),
        .split_group_counts            = physics::carve(cursor, uint, has_cuts ? counts.vertices : 0),
        .split_group_members           = physics::carve(cursor, uint, has_cuts ? counts.vertices : 0),
        .split_group_masses            = physics::carve(cursor, double, has_cuts ? counts.vertices : 0),
        .pre_split_canonical           = physics::carve(cursor, uint, has_cuts && self_collision ? counts.vertices : 0),
        .pre_split_adjacent            = physics::carve(cursor, ulong, has_cuts && self_collision ? counts.edges : 0),
        .opening_pairs                 = physics::carve(
            cursor: cursor,
            $Type:  ClothOpeningPair,
            count:  has_cuts && self_collision ? counts.collisions.max_candidates : 0,
        ),
        .opening_work_positions        = physics::carve(
            cursor: cursor,
            $Type:  ContactVector,
            count:  has_cuts && self_collision ? counts.vertices : 0,
        ),
    };
    if (!cursor.base) return null;
    states[0] = state;
    states[0].velocity_storage[..] = (Vec3){};
    states[0].staged_velocities[..] = (Vec3){};
    states[0].shape_starts[..] = (Vec3){};
    states[0].shape_ends[..] = (Vec3){};
    states[0].path_nodes[..] = (ClothPathNode){};
    states[0].path_values[..] = (ContactIntervals){};
    states[0].body_motions[..] = (ContactMotion){};
    if (has_cuts) {
        states[0].base_pinned[..] = false;
        states[0].base_has_soft[..] = false;
        states[0].base_soft_compliance[..] = 0;
        states[0].committed_edge_cut[..] = false;
        states[0].staged_edge_cut[..] = false;
        states[0].cut_results[..] = (ClothCutResult){};
        states[0].staged_cut_results[..] = (ClothCutResult){};
    }
    return states.ptr;
}

fn bool unit_interval(float value) @private => value >= 0 && value <= 1 && math::is_finite(value);

fn bool finite_vector(Vec3 value) @private => math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
