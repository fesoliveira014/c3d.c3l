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

struct ClothTopology @private {
    ClothConstraint[] edges;
    ClothConstraint[] bends;
    ClothHinge[]      hinges;
}

struct ClothCounts @local {
    uint               vertices;
    uint               source_vertices;
    uint               material_vertices;
    uint               normal_domains;
    uint               corners;
    uint               pins;
    uint               soft_attachments;
    uint               edges;
    uint               faces;
    uint               bends;
    uint               hinges;
    uint               bodies;
    uint               joints;
    bool               tangent_frame;
    bool               crowd;
    ClothCollisionDesc collisions;
}

struct EdgeRecord @local {
    uint low;
    uint high;
    uint opposite;
    bool forward;
}

fn ClothAuthoring* carve_authoring(
    BlockCursor* cursor,
    ClothDesc desc,
    Entity[] joint_entities = {},
) @local {
    ClothAuthoring[] owners = physics::carve(cursor, ClothAuthoring, 1);
    uint[] pins = physics::carve(cursor, uint, desc.pins.len);
    Entity[] colliders = physics::carve(cursor, Entity, desc.colliders.len);
    ClothSeam[] seams = physics::carve(cursor, ClothSeam, desc.seams.len);
    uint[] render_particles = physics::carve(cursor, uint, desc.render_particles.len);
    ClothAttachment[] attachments = physics::carve(cursor, ClothAttachment, desc.attachments.len);
    ClothRestAngle[] rest_angles = physics::carve(cursor, ClothRestAngle, desc.rest_angles.len);
    float[] transport = physics::carve(cursor, float, desc.transport.len);
    Entity[] joints = physics::carve(cursor, Entity, joint_entities.len);
    if (!cursor.base) return null;

    pins[..] = desc.pins[..];
    colliders[..] = desc.colliders[..];
    seams[..] = desc.seams[..];
    render_particles[..] = desc.render_particles[..];
    attachments[..] = desc.attachments[..];
    rest_angles[..] = desc.rest_angles[..];
    transport[..] = desc.transport[..];
    joints[..] = joint_entities[..];

    ClothDesc copied = desc;
    copied.pins = pins;
    copied.colliders = colliders;
    copied.seams = seams;
    copied.render_particles = render_particles;
    copied.attachments = attachments;
    copied.rest_angles = rest_angles;
    copied.transport = transport;

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

fn void? check_cloth_source(
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

    (void)build_attachment_plan(
        legacy_pins:        desc.pins,
        render_to_particle: render_to_particle,
        attachments:        desc.attachments,
        particle_count:     particle_count,
    )!;

    Vec3[] rest = alloc::new_array(tmem, Vec3, (sz)particle_count);
    foreach (render_vertex, particle : render_to_particle) rest[particle] = data.positions[render_vertex];

    (void)build_topology(
        data:               data,
        render_to_particle: render_to_particle,
        rest_positions:     rest,
        edge_positions:     {},
        world_positions:    {},
        desc:               desc,
    )!;
}

fn void? check_world_positions(Vec3[] world) @private {
    foreach (position : world) {
        if (!finite_vector(position)) return c3d::INVALID_ARGUMENT~;
    }
}

fn ClothTopology? build_topology(
    Geometry* data,
    uint[] render_to_particle,
    Vec3[] rest_positions,
    Vec3[] edge_positions,
    Vec3[] world_positions,
    ClothDesc desc,
) @private {
    usz triangle_count = data.indices.len / 3;
    EdgeRecord[] records = alloc::new_array(tmem, EdgeRecord, (sz)(triangle_count * 3));

    for (usz triangle = 0; triangle < triangle_count; triangle++) {
        uint[3] corners = {
            render_to_particle[data.indices[3 * triangle]],
            render_to_particle[data.indices[3 * triangle + 1]],
            render_to_particle[data.indices[3 * triangle + 2]],
        };
        if (corners[0] == corners[1] || corners[1] == corners[2] || corners[2] == corners[0]) {
            return c3d::INVALID_ARGUMENT~;
        }

        Vec3 rest_normal = (rest_positions[corners[1]] - rest_positions[corners[0]])
          .cross(rest_positions[corners[2]] - rest_positions[corners[0]]);
        if (rest_normal.length() * 0.5f <= MIN_TRIANGLE_AREA) return c3d::INVALID_ARGUMENT~;

        if (edge_positions.len) {
            Vec3 edge_normal = (edge_positions[corners[1]] - edge_positions[corners[0]])
              .cross(edge_positions[corners[2]] - edge_positions[corners[0]]);
            if (edge_normal.length() * 0.5f <= MIN_TRIANGLE_AREA) return c3d::INVALID_ARGUMENT~;
        }

        if (world_positions.len) {
            Vec3 world_normal = (world_positions[corners[1]] - world_positions[corners[0]])
              .cross(world_positions[corners[2]] - world_positions[corners[0]]);
            if (world_normal.length() * 0.5f <= MIN_TRIANGLE_AREA) return c3d::INVALID_ARGUMENT~;
        }

        for (uint side = 0; side < 3; side++) {
            uint first = corners[side];
            uint second = corners[(side + 1) % 3];
            records[3 * triangle + side] = {
                .low      = math::min(first, second),
                .high     = math::max(first, second),
                .opposite = corners[(side + 2) % 3],
                .forward  = first < second,
            };
        }
    }
    sort::quicksort(records, &by_edge);

    bool dihedral = desc.bend_mode == DIHEDRAL;
    usz edge_count;
    usz interior_count;
    for (usz start = 0; start < records.len;) {
        usz end = start + 1;
        while (end < records.len && same_edge(records[start], records[end])) end++;
        if (end - start > 2) return c3d::INVALID_ARGUMENT~;
        if (end - start == 2) {
            if ((dihedral && records[start].forward == records[start + 1].forward)
                || records[start].opposite == records[start + 1].opposite) {
                return c3d::INVALID_ARGUMENT~;
            }
            interior_count++;
        }
        edge_count++;
        start = end;
    }

    bool[] matched_overrides = alloc::new_array(tmem, bool, (sz)desc.rest_angles.len);
    Vec3[] constraint_positions = edge_positions.len
      ? edge_positions
      : (world_positions.len ? world_positions : rest_positions);
    ClothTopology topology = {
        .edges  = alloc::new_array(tmem, ClothConstraint, (sz)edge_count),
        .bends  = alloc::new_array(tmem, ClothConstraint, dihedral ? 0 : (sz)interior_count),
        .hinges = alloc::new_array(tmem, ClothHinge, dihedral ? (sz)interior_count : 0),
    };

    usz edge;
    usz bend;
    for (usz start = 0; start < records.len;) {
        usz end = start + 1;
        while (end < records.len && same_edge(records[start], records[end])) end++;
        topology.edges[edge++] = rest_constraint(constraint_positions, records[start].low, records[start].high);
        if (end - start == 2) {
            uint p0 = records[start].low;
            uint p1 = records[start].high;
            uint p2 = records[start].opposite;
            uint p3 = records[start + 1].opposite;

            if (!dihedral) {
                topology.bends[bend++] = rest_constraint(constraint_positions, p2, p3);
            } else {
                Vec3[4] rest_points = { rest_positions[p0], rest_positions[p1], rest_positions[p2], rest_positions[p3] };
                double? evaluated_rest = evaluate_hinge_angle(rest_points);
                if (catch evaluated_rest) return c3d::INVALID_ARGUMENT~;

                float rest_angle = (float)evaluated_rest;
                foreach (override_index, override : desc.rest_angles) {
                    if (override.first == p0 && override.second == p1) {
                        matched_overrides[override_index] = true;
                        rest_angle = override.angle;
                        break;
                    }
                }

                float last_angle = (float)evaluated_rest;
                Vec3[] initial_positions = world_positions.len ? world_positions : edge_positions;
                if (initial_positions.len) {
                    Vec3[4] world_points = {
                        initial_positions[p0],
                        initial_positions[p1],
                        initial_positions[p2],
                        initial_positions[p3],
                    };
                    double? evaluated_world = evaluate_hinge_angle(world_points);
                    if (catch evaluated_world) return c3d::INVALID_ARGUMENT~;
                    last_angle = (float)evaluated_world;
                }

                topology.hinges[bend++] = {
                    .p0         = p0,
                    .p1         = p1,
                    .p2         = p2,
                    .p3         = p3,
                    .rest_angle = rest_angle,
                    .last_angle = last_angle,
                    .lambda     = 0,
                };
            }
        }
        start = end;
    }

    foreach (matched : matched_overrides) {
        if (!matched) return c3d::INVALID_ARGUMENT~;
    }

    return topology;
}

fn ClothState*? allocate_cloth_state(
    Allocator allocator,
    uint vertex_count,
    uint source_vertex_count,
    uint material_vertex_count,
    uint normal_domain_count,
    uint corner_count,
    uint pin_count,
    uint soft_count,
    uint edge_count,
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
        .vertices          = vertex_count,
        .source_vertices   = source_vertex_count,
        .material_vertices = material_vertex_count,
        .normal_domains    = normal_domain_count,
        .corners           = corner_count,
        .pins              = pin_count,
        .soft_attachments  = soft_count,
        .edges             = edge_count,
        .faces             = face_count,
        .bends             = bend_count,
        .hinges            = hinge_count,
        .bodies            = body_count,
        .joints            = joint_count,
        .tangent_frame     = tangent_frame,
        .crowd             = crowd,
        .collisions        = collisions,
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
    ClothState state = {
        .render_to_particle       = physics::carve(cursor, uint, counts.source_vertices),
        .particle_sources         = physics::carve(cursor, uint, counts.vertices),
        .transport                = physics::carve(cursor, float, counts.vertices),
        .rest                     = physics::carve(cursor, Vec3, counts.vertices),
        .solved_reference         = physics::carve(cursor, Vec3, counts.vertices),
        .current_reference        = physics::carve(cursor, Vec3, counts.vertices),
        .positions                = physics::carve(cursor, Vec3, counts.vertices),
        .velocities               = physics::carve(cursor, Vec3, counts.vertices),
        .predicted                = physics::carve(cursor, Vec3, counts.vertices),
        .accelerations            = physics::carve(cursor, Vec3, counts.vertices),
        .published                = physics::carve(cursor, Vec3, counts.vertices),
        .inverse_masses           = physics::carve(cursor, float, counts.vertices),
        .pins                     = physics::carve(cursor, uint, counts.pins),
        .pin_anchors              = physics::carve(cursor, Vec3, counts.pins),
        .pin_targets              = physics::carve(cursor, Vec3, counts.pins),
        .soft_attachments         = physics::carve(cursor, ClothSoftAttachment, counts.soft_attachments),
        .soft_anchors             = physics::carve(cursor, Vec3, counts.soft_attachments),
        .soft_targets             = physics::carve(cursor, Vec3, counts.soft_attachments),
        .soft_lambdas             = physics::carve(cursor, Vec3, counts.soft_attachments),
        .edges                    = physics::carve(cursor, ClothConstraint, counts.edges),
        .bends                    = physics::carve(cursor, ClothConstraint, counts.bends),
        .hinges                   = physics::carve(cursor, ClothHinge, counts.hinges),
        .corners                  = physics::carve(cursor, ClothCorner, counts.corners),
        .triangle_uvs             = physics::carve(cursor, ClothTriangleUv, counts.faces),
        .material_particles       = physics::carve(cursor, uint, counts.material_vertices),
        .material_normal_domains  = physics::carve(cursor, uint, counts.material_vertices),
        .material_ref_faces       = physics::carve(cursor, uint, counts.material_vertices),
        .tangent_signs            = physics::carve(cursor, float, tangents ? counts.material_vertices : 0),
        .rest_tangents            = physics::carve(cursor, Vec3, tangents ? counts.material_vertices : 0),
        .committed_tangents       = physics::carve(cursor, Vec4, tangents ? counts.material_vertices : 0),
        .normal_accum             = physics::carve(cursor, Vec3, counts.normal_domains),
        .tangent_accum            = physics::carve(cursor, Vec3, tangents ? counts.material_vertices : 0),
        .particle_local           = physics::carve(cursor, Vec3, counts.vertices),
        .source_reference_scratch = physics::carve(cursor, Vec3, counts.joints ? counts.source_vertices : 0),
        .palette_scratch          = physics::carve(cursor, SkinMat4, counts.joints),
        .joint_entities           = physics::carve(cursor, Entity, counts.joints),
        .colliders                = physics::carve(cursor, Entity, counts.bodies),
        .bodies                   = physics::carve(cursor, ClothBody, counts.bodies),
        .shape_storage            = physics::carve(cursor, ClothShape, counts.collisions.max_shapes),
        .shape_starts             = physics::carve(cursor, Vec3, counts.collisions.max_shapes),
        .shape_ends               = physics::carve(cursor, Vec3, counts.collisions.max_shapes),
        .staged_shapes            = physics::carve(cursor, ClothShape, counts.collisions.max_shapes),
        .staged_bodies            = physics::carve(cursor, ClothBody, counts.bodies),
        .staged_solved_reference  = physics::carve(cursor, Vec3, counts.vertices),
        .staged_positions         = physics::carve(cursor, Vec3, counts.vertices),
        .staged_velocities          = physics::carve(cursor, Vec3, counts.vertices),
        .staged_published           = physics::carve(cursor, Vec3, counts.vertices),
        .staged_pin_anchors         = physics::carve(cursor, Vec3, counts.pins),
        .staged_soft_anchors        = physics::carve(cursor, Vec3, counts.soft_attachments),
        .staged_soft_targets        = physics::carve(cursor, Vec3, counts.soft_attachments),
        .staged_hinges              = physics::carve(cursor, ClothHinge, counts.hinges),
        .staged_shape_starts        = physics::carve(cursor, Vec3, counts.collisions.max_shapes),
        .staged_shape_ends          = physics::carve(cursor, Vec3, counts.collisions.max_shapes),
        .local_output               = physics::carve(cursor, Vec3, counts.material_vertices),
        .local_normals              = physics::carve(cursor, Vec3, counts.material_vertices),
        .local_tangents             = physics::carve(cursor, Vec4, tangents ? counts.material_vertices : 0),
        .staged_colors              = physics::carve(cursor, Vec4, counts.crowd ? counts.material_vertices : 0),
        .publication_roundtrip      = physics::carve(cursor, Vec3, counts.vertices),
        .staged_predicted           = physics::carve(cursor, Vec3, counts.vertices),
        .staged_accelerations       = physics::carve(cursor, Vec3, counts.vertices),
        .staged_pin_targets         = physics::carve(cursor, Vec3, counts.pins),
        .frames                     = physics::carve(cursor, ContactFrame, counts.collisions.max_shapes),
        .candidates                 = physics::carve(cursor, ClothCandidate, counts.collisions.max_candidates),
        .contacts                   = physics::carve(cursor, ClothContact, counts.collisions.max_contacts),
        .faces                      = physics::carve(cursor, ClothFace, self_collision ? counts.faces : 0),
        .canonical_vertices         = physics::carve(cursor, uint, self_collision ? counts.vertices : 0),
        .adjacent_vertices          = physics::carve(cursor, ulong, self_collision ? counts.edges : 0),
        .self_primitives            = physics::carve(
            cursor: cursor,
            $Type:  ClothSelfPrimitive,
            count:  self_collision ? (usz)counts.vertices + counts.edges + counts.faces : 0,
        ),
        .sweep_start                = physics::carve(cursor, Vec3, continuous ? counts.vertices : 0),
        .sweep_bounds               = physics::carve(cursor, Aabb, continuous ? counts.vertices : 0),
        .path_heads                 = physics::carve(cursor, usz, continuous ? counts.vertices : 0),
        .path_nodes                 = physics::carve(
            cursor: cursor,
            $Type:  ClothPathNode,
            count:  continuous ? (usz)counts.vertices + 4UL * counts.collisions.max_contacts : 0,
        ),
        .path_values                = physics::carve(
            cursor: cursor,
            $Type:  ContactIntervals,
            count:  continuous ? (usz)counts.vertices + 4UL * counts.collisions.max_contacts : 0,
        ),
        .body_motions               = physics::carve(cursor, ContactMotion, continuous ? counts.bodies : 0),
    };
    if (!cursor.base) return null;
    states[0] = state;
    states[0].velocities[..] = (Vec3){};
    states[0].shape_starts[..] = (Vec3){};
    states[0].shape_ends[..] = (Vec3){};
    states[0].path_nodes[..] = (ClothPathNode){};
    states[0].path_values[..] = (ContactIntervals){};
    states[0].body_motions[..] = (ContactMotion){};
    return states.ptr;
}

fn ClothConstraint rest_constraint(Vec3[] world, uint first, uint second) @local {
    Vec3 delta = world[second] - world[first];
    float length = delta.length();
    return {
        .first          = first,
        .second         = second,
        .rest_length    = length,
        .rest_direction = length > 0 ? delta / length : COLLAPSED_AXIS,
    };
}

fn bool same_edge(EdgeRecord first, EdgeRecord second) @local => first.low == second.low && first.high == second.high;

fn int by_edge(EdgeRecord first, EdgeRecord second) @local {
    if (first.low != second.low) return first.low < second.low ? -1 : 1;
    if (first.high != second.high) return first.high < second.high ? -1 : 1;
    if (first.forward != second.forward) return first.forward ? -1 : 1;
    return 0;
}

fn bool unit_interval(float value) @private => value >= 0 && value <= 1 && math::is_finite(value);

fn bool finite_vector(Vec3 value) @private => math::is_finite(value.x) && math::is_finite(value.y) && math::is_finite(value.z);
