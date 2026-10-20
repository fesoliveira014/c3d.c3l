module c3d::scene;

import c3d;
import c3d::maths;

<*
 Which faces of a mesh traced rays meet.
*>
enum TraceFacing : char {
    MATERIAL, // the material's double_sided decides
    FRONT,    // front faces only, whatever the material says
    BOTH,     // both faces, whatever the material says
}

<*
 Drawable geometry and material pair on a node.
*>
struct Mesh {
    GeometryId  geometry;
    MaterialId  material;
    bool        cast_shadow;
    bool        receive_shadow;
    bool        trace;
    bool        trace_only; // a traced proxy for drawn geometry, never drawn; raster, picking and the index skip it
    TraceFacing trace_facing; // overrides the material's double_sided for traces only; raster is unaffected
    float[]     morph_weights;
    bool        has_bounds_override;
    Aabb        local_bounds;
    bool        vertex_motion;
    ulong       vertex_history_token @tag("transient", true);
}

$assert Mesh::size == 80;

<*
 Advance the vertex correspondence token so views reject their prior vertex history.
*>
fn void Mesh.reset_vertex_history(&self) => self.vertex_history_token++;
