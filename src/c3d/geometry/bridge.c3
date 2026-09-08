module c3d::geometry;

import c3d::maths;
import cg;
import cg::half_edge;
import cg::primitives;
import cg::render;
import std::math;

<*
 Triangle geometry from a half-edge mesh, copied into the allocator.
 @param [&in] mesh : "Polygons are fan-triangulated; uvs are copied when present."
 @param smooth_normals : "Shared vertices with averaged normals; flat unrolls every face."
 @return? cg::INVALID_TOPOLOGY, cg::INVALID_HALF_EDGE_REFERENCE, cg::INVALID_VERTEX_REFERENCE
 @return? cg::INVALID_FACE_REFERENCE, cg::INVALID_TWIN, cg::INVALID_FACE_CYCLE
 @return? cg::NON_PLANAR_FACE, cg::DEGENERATE_INPUT, cg::EMPTY_INPUT
*>
fn Geometry? from_half_edge(Allocator allocator, cg::HalfEdgeMesh* mesh, bool smooth_normals = true) {
    cg::render::RenderOptions options = {
        .normal_mode = (uint)(smooth_normals ? cg::render::RenderNormalMode.RENDER_NORMAL_SMOOTH
                                             : cg::render::RenderNormalMode.RENDER_NORMAL_FLAT),
        .uv_mode     = (uint)(mesh.uvs.len ? cg::render::RenderUvMode.RENDER_UV_SOURCE
                                           : cg::render::RenderUvMode.RENDER_UV_NONE),
    };
    cg::render::RenderingData data = mesh.to_rendering_data(mem, options)!;
    defer data.destroy();
    Geometry geometry = {
        .topology  = Topology.TRIANGLES,
        .positions = copy_slice(allocator, data.vertices),
        .normals   = copy_slice(allocator, data.normals),
        .uv0       = copy_slice(allocator, data.uvs),
        .indices   = copy_slice(allocator, data.indices),
    };
    geometry.finalize();
    return geometry;
}

<*
 Half-edge mesh over the geometry's triangles, positions, normals and uv0.
 @param allocator : "Heap allocator; the mesh's destroy frees with the global free."
 @param [&in] geometry : "Indexed triangles."
 @return? cg::EMPTY_INPUT, cg::INVALID_TRIANGLE_INDEX_COUNT, cg::ATTRIBUTE_COUNT_MISMATCH
 @return? cg::INDEX_OUT_OF_RANGE, cg::NON_MANIFOLD_INPUT, cg::DUPLICATE_HALF_EDGE
 @require geometry.topology == Topology.TRIANGLES, geometry.indices.len > 0
*>
fn cg::HalfEdgeMesh? to_half_edge(Allocator allocator, Geometry* geometry) {
    return cg::half_edge::from_triangles_with_attrs(
        alloc:     allocator,
        positions: geometry.positions,
        normals:   geometry.normals,
        uvs:       geometry.uv0,
        indices:   geometry.indices,
    );
}

<*
 Subdivided icosahedron on a sphere, with exact normals and spherical uvs.
 @return? cg::DEGENERATE_INPUT, cg::INVALID_TOPOLOGY, cg::NON_PLANAR_FACE
*>
fn Geometry? icosphere(Allocator allocator, float radius, uint subdivisions = 2) {
    cg::HalfEdgeMesh mesh = cg::primitives::icosphere(mem, (int)subdivisions, radius)!;
    defer mesh.destroy();
    Geometry geometry = from_half_edge(allocator, &mesh)!;
    geometry.uv0 = alloc::new_array(allocator, Vec2, geometry.positions.len);
    foreach (index, position : geometry.positions) {
        geometry.normals[index] = position / radius;
        geometry.uv0[index] = {
            0.5f + math::atan2(position.z, position.x) / (float)math::TWO_PI,
            0.5f - math::asin(position.y / radius) / (float)math::PI,
        };
    }
    return geometry;
}

macro copy_slice(Allocator allocator, slice) @local {
    var $Element = $Typeof(slice[0]);
    $Element[] copy = alloc::new_array(allocator, $Element, slice.len);
    copy[..] = slice[..];
    return copy;
}
