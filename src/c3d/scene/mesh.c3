module c3d::scene;

import c3d;
import c3d::maths;

<*
 Drawable geometry and material pair on a node.
*>
struct Mesh {
    GeometryId geometry;
    MaterialId material;
    bool       cast_shadow;
    bool       receive_shadow;
    float[]    morph_weights;
    bool       has_bounds_override;
    Aabb       local_bounds;
}
