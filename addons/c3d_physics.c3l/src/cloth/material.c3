module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import std::math;

const float FRAME_VECTOR_EPSILON @private = 1e-6f;
const float UV_AREA_EPSILON @local = 1e-20f;

<* Prepared routing and tangent reference for one triangle corner. *>
struct ClothCorner {
    uint  source_vertex;
    uint  material_vertex;
    uint  particle;
    uint  normal_domain;
    uint  tangent_domain;
    float tangent_sign;
    Vec3  rest_tangent;
}

struct ClothTriangleUv @private {
    float c1;
    float c2;
    bool  valid;
}

struct ClothMaterialPlan @private {
    uint              particle_count;
    uint              material_vertex_count;
    uint              normal_domain_count;
    uint[]            render_to_particle;
    uint[]            particle_sources;
    uint[]            material_particles;
    uint[]            material_normal_domains;
    uint[]            material_ref_faces;
    float[]           tangent_signs;
    Vec3[]            rest_tangents;
    Vec4[]            initial_tangents;
    ClothCorner[]     corners;
    ClothTriangleUv[] triangle_uvs;
    Geometry          geometry;
}

fn uint map_render_vertex(uint[] render_particles, uint render_vertex) @private {
    return render_particles.len ? render_particles[render_vertex] : render_vertex;
}

fn uint[]? build_render_particle_map(
    Geometry* source,
    uint[] render_particles,
    uint* out_particle_count,
) @private {
    uint render_count = (uint)source.positions.len;
    uint[] map = alloc::new_array(tmem, uint, (sz)render_count);

    if (!render_particles.len) {
        foreach (index, &target : map) *target = (uint)index;
        *out_particle_count = render_count;
    } else {
        if (render_particles.len != render_count) return c3d::INVALID_ARGUMENT~;

        bool[] seen = alloc::new_array(tmem, bool, (sz)render_count);
        uint[] first_render = alloc::new_array(tmem, uint, (sz)render_count);
        uint max_particle;
        uint unique_count;

        foreach (index, particle : render_particles) {
            if (particle >= render_count) return c3d::INVALID_ARGUMENT~;
            if (!seen[particle]) {
                seen[particle] = true;
                first_render[particle] = (uint)index;
                unique_count++;
                if (particle > max_particle) max_particle = particle;
            } else if (source.positions[index] != source.positions[first_render[particle]]) {
                return c3d::INVALID_ARGUMENT~;
            }
            map[index] = particle;
        }

        if (!unique_count || max_particle + 1 != unique_count) return c3d::INVALID_ARGUMENT~;
        *out_particle_count = unique_count;

        bool[] referenced = alloc::new_array(tmem, bool, (sz)*out_particle_count);
        foreach (index : source.indices) referenced[map[index]] = true;
        foreach (used : referenced) {
            if (!used) return c3d::INVALID_ARGUMENT~;
        }
    }

    return map;
}

fn uint[]? build_normal_domains(
    Geometry* source,
    uint[] render_to_particle,
    uint* out_domain_count,
) @private {
    uint render_count = (uint)source.positions.len;
    if (source.normals.len && source.normals.len != render_count) return c3d::INVALID_ARGUMENT~;

    Vec3[] unit_authored;
    if (source.normals.len) {
        unit_authored = alloc::new_array(tmem, Vec3, (sz)render_count);
        foreach (index, normal : source.normals) {
            if (!finite_vector(normal) || !(normal.length() > FRAME_VECTOR_EPSILON)) {
                return c3d::INVALID_ARGUMENT~;
            }
            unit_authored[index] = normal.normalize();
        }
    }

    uint[] domains = alloc::new_array(tmem, uint, (sz)render_count);
    uint domain_count;
    for (uint vertex = 0; vertex < render_count; vertex++) {
        uint assigned = uint::max;
        uint particle = render_to_particle[vertex];

        for (uint earlier = 0; earlier < vertex; earlier++) {
            if (render_to_particle[earlier] != particle) continue;
            if (unit_authored.len
                && (unit_authored[earlier] - unit_authored[vertex]).length() > FRAME_VECTOR_EPSILON) {
                continue;
            }
            assigned = domains[earlier];
            break;
        }

        if (assigned == uint::max) assigned = domain_count++;
        domains[vertex] = assigned;
    }

    *out_domain_count = domain_count;
    return domains;
}

fn ClothMaterialPlan? build_material_plan(Geometry* source, ClothDesc desc) @private {
    uint render_count = (uint)source.positions.len;
    uint corner_count = (uint)source.indices.len;
    uint triangle_count = corner_count / 3;

    uint particle_count;
    uint[] render_to_particle = build_render_particle_map(source, desc.render_particles, &particle_count)!;

    uint normal_domain_count;
    uint[] render_normal_domains = build_normal_domains(source, render_to_particle, &normal_domain_count)!;

    uint[] particle_sources = alloc::new_array(tmem, uint, (sz)particle_count);
    foreach (render_vertex, particle : render_to_particle) particle_sources[particle] = (uint)render_vertex;

    ClothMaterialPlan plan = {
        .particle_count      = particle_count,
        .normal_domain_count = normal_domain_count,
        .render_to_particle  = render_to_particle,
        .particle_sources    = particle_sources,
        .corners             = alloc::new_array(tmem, ClothCorner, (sz)corner_count),
        .triangle_uvs        = alloc::new_array(tmem, ClothTriangleUv, (sz)triangle_count),
    };

    if (!desc.tangent_frame) {
        plan.material_vertex_count = render_count;
        plan.material_particles = render_to_particle;
        plan.material_normal_domains = render_normal_domains;
        plan.material_ref_faces = alloc::new_array(tmem, uint, (sz)render_count);

        foreach (corner_index, source_vertex : source.indices) {
            uint face = (uint)(corner_index / 3);
            plan.material_ref_faces[source_vertex] = face;
            plan.corners[corner_index] = {
                .source_vertex   = source_vertex,
                .material_vertex = source_vertex,
                .particle        = render_to_particle[source_vertex],
                .normal_domain   = render_normal_domains[source_vertex],
                .tangent_domain  = source_vertex,
                .tangent_sign    = 1,
                .rest_tangent    = { 1, 0, 0 },
            };
        }

        plan.geometry = {
            .topology  = Topology.TRIANGLES,
            .positions = alloc::new_array(tmem, Vec3, (sz)render_count),
            .normals   = alloc::new_array(tmem, Vec3, (sz)render_count),
            .uv0       = source.uv0,
            .uv1       = source.uv1,
            .colors    = source.colors,
            .indices   = source.indices,
            .bounds    = source.bounds,
        };
        plan.geometry.positions[..] = source.positions[..];
    } else {
        if (desc.tangent_uv_set > 1) return c3d::INVALID_ARGUMENT~;
        Vec2[] selected_uv = desc.tangent_uv_set == 0 ? source.uv0 : source.uv1;
        if (selected_uv.len != render_count) return c3d::INVALID_ARGUMENT~;
        foreach (uv : selected_uv) {
            if (!math::is_finite(uv.x) || !math::is_finite(uv.y)) return c3d::INVALID_ARGUMENT~;
        }

        Geometry tangent_source = *source;
        if (!tangent_source.normals.len) {
            tangent_source.normals = alloc::new_array(tmem, Vec3, (sz)render_count);
            Vec3[] domain_accum = alloc::new_array(tmem, Vec3, (sz)normal_domain_count);
            for (uint face = 0; face < triangle_count; face++) {
                uint i0 = source.indices[3 * face];
                uint i1 = source.indices[3 * face + 1];
                uint i2 = source.indices[3 * face + 2];
                Vec3 p0 = source.positions[particle_sources[render_to_particle[i0]]];
                Vec3 p1 = source.positions[particle_sources[render_to_particle[i1]]];
                Vec3 p2 = source.positions[particle_sources[render_to_particle[i2]]];
                Vec3 cross = (p1 - p0).cross(p2 - p0);
                domain_accum[render_normal_domains[i0]] += cross;
                domain_accum[render_normal_domains[i1]] += cross;
                domain_accum[render_normal_domains[i2]] += cross;
            }
            foreach (&accum : domain_accum) {
                float len = accum.length();
                if (!(len > 2 * MIN_TRIANGLE_AREA)) return c3d::INVALID_ARGUMENT~;
                *accum /= len;
            }
            foreach (vertex, &normal : tangent_source.normals) {
                *normal = domain_accum[render_normal_domains[vertex]];
            }
        }

        Geometry? generated = geometry::create_tangent_geometry(
            allocator: tmem,
            source:    &tangent_source,
            uv_set:    desc.tangent_uv_set,
        );
        if (catch excuse = generated) {
            if (excuse == c3d::CAPACITY_EXCEEDED) return c3d::CAPACITY_EXCEEDED~;
            return c3d::INVALID_ARGUMENT~;
        }

        uint material_count = (uint)generated.positions.len;
        plan.material_vertex_count = material_count;
        plan.material_particles = alloc::new_array(tmem, uint, (sz)material_count);
        plan.material_normal_domains = alloc::new_array(tmem, uint, (sz)material_count);
        plan.material_ref_faces = alloc::new_array(tmem, uint, (sz)material_count);
        plan.tangent_signs = alloc::new_array(tmem, float, (sz)material_count);
        plan.rest_tangents = alloc::new_array(tmem, Vec3, (sz)material_count);
        plan.initial_tangents = alloc::new_array(tmem, Vec4, (sz)material_count);
        plan.tangent_signs[..] = 1;
        plan.rest_tangents[..] = { 1, 0, 0 };

        bool[] seen_material = alloc::new_array(tmem, bool, (sz)material_count);
        foreach (corner_index, source_vertex : source.indices) {
            uint material_vertex = generated.indices[corner_index];
            uint particle = render_to_particle[source_vertex];
            uint normal_domain = render_normal_domains[source_vertex];
            Vec4 raw_tangent = generated.tangents[material_vertex];
            float sign = raw_tangent.w < 0 ? -1.0f : 1.0f;
            Vec3 direction = { raw_tangent.x, raw_tangent.y, raw_tangent.z };
            Vec3 rest_tangent = finite_vector(direction) && direction.length() > FRAME_VECTOR_EPSILON
              ? direction.normalize()
              : (Vec3){ 1, 0, 0 };

            if (!seen_material[material_vertex]) {
                seen_material[material_vertex] = true;
                plan.material_particles[material_vertex] = particle;
                plan.material_normal_domains[material_vertex] = normal_domain;
                plan.material_ref_faces[material_vertex] = (uint)(corner_index / 3);
                plan.tangent_signs[material_vertex] = sign;
                plan.rest_tangents[material_vertex] = rest_tangent;
            }

            plan.corners[corner_index] = {
                .source_vertex   = source_vertex,
                .material_vertex = material_vertex,
                .particle        = particle,
                .normal_domain   = normal_domain,
                .tangent_domain  = material_vertex,
                .tangent_sign    = sign,
                .rest_tangent    = rest_tangent,
            };
        }

        for (uint face = 0; face < triangle_count; face++) {
            Vec2 uv0 = selected_uv[source.indices[3 * face]];
            Vec2 uv1 = selected_uv[source.indices[3 * face + 1]];
            Vec2 uv2 = selected_uv[source.indices[3 * face + 2]];
            float du1 = uv1.x - uv0.x;
            float dv1 = uv1.y - uv0.y;
            float du2 = uv2.x - uv0.x;
            float dv2 = uv2.y - uv0.y;
            float signed_area = du1 * dv2 - dv1 * du2;
            if (math::is_finite(signed_area) && math::abs(signed_area) > UV_AREA_EPSILON) {
                float sign = signed_area > 0 ? 1.0f : -1.0f;
                plan.triangle_uvs[face] = {
                    .c1    = sign * dv2,
                    .c2    = -sign * dv1,
                    .valid = true,
                };
            }
        }

        plan.geometry = generated;
        plan.initial_tangents[..] = generated.tangents[..];
    }

    Vec3[] particle_rest = alloc::new_array(tmem, Vec3, (sz)particle_count);
    foreach (particle, source_vertex : particle_sources) particle_rest[particle] = source.positions[source_vertex];

    Vec3[] normal_accum = alloc::new_array(tmem, Vec3, (sz)normal_domain_count);
    Vec3[] tangent_accum = desc.tangent_frame
      ? alloc::new_array(tmem, Vec3, (sz)plan.material_vertex_count)
      : {};

    compute_material_frames(
        corners:                plan.corners,
        triangle_uvs:           plan.triangle_uvs,
        material_normal_domains: plan.material_normal_domains,
        material_ref_faces:     plan.material_ref_faces,
        tangent_signs:          plan.tangent_signs,
        rest_tangents:          plan.rest_tangents,
        rest_positions:         particle_rest,
        current_positions:      particle_rest,
        committed_tangents:     plan.initial_tangents,
        normal_accum:           normal_accum,
        tangent_accum:          tangent_accum,
        out_normals:            plan.geometry.normals,
        out_tangents:           plan.geometry.tangents,
    )!;

    if (desc.tangent_frame) plan.initial_tangents[..] = plan.geometry.tangents[..];
    plan.geometry.finalize();
    return plan;
}

fn Vec3? resolve_tangent_direction(
    Vec3 normal,
    Vec3 accumulated,
    Vec3 last_committed,
    Vec3 transported_rest,
) @private {
    if (!finite_vector(normal) || !(normal.length() > FRAME_VECTOR_EPSILON)) return FRAME_UNRESOLVED~;
    Vec3 unit_normal = normal.normalize();

    if (finite_vector(accumulated)) {
        Vec3 projected = accumulated - unit_normal * unit_normal.dot(accumulated);
        if (finite_vector(projected) && projected.length() > FRAME_VECTOR_EPSILON) return projected.normalize();
    }

    if (finite_vector(last_committed)) {
        Vec3 projected = last_committed - unit_normal * unit_normal.dot(last_committed);
        if (finite_vector(projected) && projected.length() > FRAME_VECTOR_EPSILON) return projected.normalize();
    }

    if (finite_vector(transported_rest)) {
        Vec3 projected = transported_rest - unit_normal * unit_normal.dot(transported_rest);
        if (finite_vector(projected) && projected.length() > FRAME_VECTOR_EPSILON) return projected.normalize();
    }

    float abs_x = math::abs(unit_normal.x);
    float abs_y = math::abs(unit_normal.y);
    float abs_z = math::abs(unit_normal.z);
    Vec3 axis = abs_x <= abs_y && abs_x <= abs_z
      ? (Vec3){ 1, 0, 0 }
      : (abs_y <= abs_z ? (Vec3){ 0, 1, 0 } : (Vec3){ 0, 0, 1 });
    Vec3 fallback = axis - unit_normal * unit_normal.dot(axis);
    if (!finite_vector(fallback) || !(fallback.length() > FRAME_VECTOR_EPSILON)) return FRAME_UNRESOLVED~;
    return fallback.normalize();
}

fn Vec3 transport_face_vector(
    ClothCorner[] corners,
    Vec3[] rest_positions,
    Vec3[] current_positions,
    uint face_index,
    Vec3 rest_vector,
) @local {
    usz base = (usz)face_index * 3;
    if (base + 2 >= corners.len || !finite_vector(rest_vector)) return {};

    uint p0 = corners[base].particle;
    uint p1 = corners[base + 1].particle;
    uint p2 = corners[base + 2].particle;

    Vec3 r_edge = rest_positions[p1] - rest_positions[p0];
    Vec3 r_norm = r_edge.cross(rest_positions[p2] - rest_positions[p0]);
    Vec3 c_edge = current_positions[p1] - current_positions[p0];
    Vec3 c_norm = c_edge.cross(current_positions[p2] - current_positions[p0]);
    if (r_edge.length() <= FRAME_VECTOR_EPSILON || r_norm.length() <= 2 * MIN_TRIANGLE_AREA
        || c_edge.length() <= FRAME_VECTOR_EPSILON || c_norm.length() <= 2 * MIN_TRIANGLE_AREA) {
        return {};
    }

    r_edge = r_edge.normalize();
    r_norm = r_norm.normalize();
    Vec3 r_binorm = r_norm.cross(r_edge);

    c_edge = c_edge.normalize();
    c_norm = c_norm.normalize();
    Vec3 c_binorm = c_norm.cross(c_edge);

    return c_edge * rest_vector.dot(r_edge)
      + c_binorm * rest_vector.dot(r_binorm)
      + c_norm * rest_vector.dot(r_norm);
}

fn void? compute_material_frames(
    ClothCorner[] corners,
    ClothTriangleUv[] triangle_uvs,
    uint[] material_normal_domains,
    uint[] material_ref_faces,
    float[] tangent_signs,
    Vec3[] rest_tangents,
    Vec3[] rest_positions,
    Vec3[] current_positions,
    Vec4[] committed_tangents,
    Vec3[] normal_accum,
    Vec3[] tangent_accum,
    Vec3[] out_normals,
    Vec4[] out_tangents,
) @private {
    normal_accum[..] = (Vec3){};
    if (out_tangents.len) tangent_accum[..] = (Vec3){};

    usz triangle_count = corners.len / 3;
    for (usz face = 0; face < triangle_count; face++) {
        ClothCorner c0 = corners[3 * face];
        ClothCorner c1 = corners[3 * face + 1];
        ClothCorner c2 = corners[3 * face + 2];

        Vec3 p0 = current_positions[c0.particle];
        Vec3 p1 = current_positions[c1.particle];
        Vec3 p2 = current_positions[c2.particle];

        Vec3 e1 = p1 - p0;
        Vec3 e2 = p2 - p0;
        Vec3 cross = e1.cross(e2);
        if (!finite_vector(cross)) return FRAME_UNRESOLVED~;
        if (out_tangents.len && !(cross.length() > 2 * MIN_TRIANGLE_AREA)) return FRAME_UNRESOLVED~;

        normal_accum[c0.normal_domain] += cross;
        normal_accum[c1.normal_domain] += cross;
        normal_accum[c2.normal_domain] += cross;

        if (out_tangents.len && triangle_uvs[face].valid) {
            ClothTriangleUv uv = triangle_uvs[face];
            Vec3 raw_tangent = e1 * uv.c1 + e2 * uv.c2;
            float raw_length = raw_tangent.length();
            if (finite_vector(raw_tangent) && raw_length > UV_AREA_EPSILON) {
                Vec3 unit_tangent = raw_tangent / raw_length;
                Vec3[3] tri_pos = { p0, p1, p2 };
                uint[3] domains = { c0.tangent_domain, c1.tangent_domain, c2.tangent_domain };
                for (uint corner = 0; corner < 3; corner++) {
                    Vec3 prev_edge = tri_pos[(corner + 2) % 3] - tri_pos[corner];
                    Vec3 next_edge = tri_pos[(corner + 1) % 3] - tri_pos[corner];
                    float prod = prev_edge.length() * next_edge.length();
                    if (prod > UV_AREA_EPSILON) {
                        float cosine = math::clamp(prev_edge.dot(next_edge) / prod, -1.0f, 1.0f);
                        float angle = (float)math::acos((double)cosine);
                        tangent_accum[domains[corner]] += unit_tangent * angle;
                    }
                }
            }
        }
    }

    foreach (&accum : normal_accum) {
        float length = accum.length();
        if (!finite_vector(*accum)) return FRAME_UNRESOLVED~;
        if (out_tangents.len && !(length > 2 * MIN_TRIANGLE_AREA)) return FRAME_UNRESOLVED~;
        if (length > 0) *accum /= length;
    }

    foreach (vertex, &out_normal : out_normals) {
        *out_normal = normal_accum[material_normal_domains[vertex]];
    }

    if (out_tangents.len) {
        foreach (vertex, &out_tangent : out_tangents) {
            Vec3 normal = out_normals[vertex];
            Vec3 last = committed_tangents.len
              ? (Vec3){ committed_tangents[vertex].x, committed_tangents[vertex].y, committed_tangents[vertex].z }
              : (Vec3){};
            Vec3 transported = transport_face_vector(
                corners:           corners,
                rest_positions:    rest_positions,
                current_positions: current_positions,
                face_index:        material_ref_faces[vertex],
                rest_vector:       rest_tangents[vertex],
            );
            Vec3 direction = resolve_tangent_direction(
                normal:           normal,
                accumulated:      tangent_accum[vertex],
                last_committed:   last,
                transported_rest: transported,
            )!;
            float sign = tangent_signs.len && tangent_signs[vertex] < 0 ? -1.0f : 1.0f;
            *out_tangent = { direction.x, direction.y, direction.z, sign };
        }
    }
}
