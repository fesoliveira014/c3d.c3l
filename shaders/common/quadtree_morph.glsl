#ifndef C3D_QUADTREE_MORPH_GLSL
#define C3D_QUADTREE_MORPH_GLSL

// Box-range selection of a quadtree batch: the range of a depth and the morph of a vertex toward its parent level.
// Selection and vertex stages read the same QuadtreeGpu, so they agree on every range.
//
// Notation: s is the view's pixel scale, T the split threshold, h the hysteresis, b the morph band, e and g the
// extent and box diagonal of a depth scaled by the node world's largest axis scale, D the finest depth.
//   R_D = e_D s / T
//   R_d = max(e_d s / T, (R_{d+1} (1 + h) + g_{d+1}) / (1 - b))
// A node of depth d splits when the camera is nearer than R_d to its box, or nearer than R_d (1 + h) when it
// split in the view's previous rendering. A leaf never splits.
//
// For h < 1 and b < 1 the recurrence gives two conditions:
//  1. No pop at a merge. A depth-d node's vertices morph from 0 at R_{d-1} (1 - b) to 1 at R_{d-1}. The parent merges
//     at a box distance of R_d (1 + h), where its vertices lie within R_d (1 + h) + g_d <= R_{d-1} (1 - b), so it is
//     unmorphed. Its children were at morph 1, which is the parent's surface. At a split every child vertex is at
//     least R_d from the camera, so at morph 1.
//  2. One level between neighbours. A drawn depth-d node is at least R_d from the camera. A drawn depth-(d+2) node
//     needs its depth-(d+1) parent within R_{d+1} (1 + h), which puts the depth-d node within
//     R_{d+1} (1 + h) + g_{d+1} <= R_d. The two cannot be drawn together.
//
// A view that is too small or too wide for the natural ranges raises them to the clamp, which draws more detail
// and keeps both conditions. b <= (1 - h) / 2 keeps the clamp ratio (1 + h) / (1 - b) at or below 2, so the clamp
// does not compound past the natural doubling of the ranges.
//
// An orthographic view has no distance term: selection becomes a size test, every node of a depth takes the level
// its extent gives, and the morph is 0. A stage skips quadtree_morph when quadtree_selection_orthographic holds. That
// test reads FrameRoot.flags, not frame.proj: a shadow layer's proj is the light's, orthographic for a directional
// cascade whatever the selecting view is.

// mirrored as quadtree_world_scale in quadtree.c3
float quadtree_world_scale(mat4 node_world) {
    return max(length(node_world[0].xyz), max(length(node_world[1].xyz), length(node_world[2].xyz)));
}

// Selection range of a depth in a perspective view, in world units. pixel_scale is FrameRoot.selection_camera.w.
float quadtree_range(QuadtreeGpu tree, uint depth, float pixel_scale, float world_scale) {
    float per_extent = pixel_scale * world_scale / tree.split_pixels;
    uint finest = tree.depth_count - 1u;
    float range = tree.levels[finest].extent * per_extent;

    for (uint level = finest; level > depth; level--) {
        float natural = tree.levels[level - 1u].extent * per_extent;
        float clamped = (range * (1.0 + tree.hysteresis) + tree.levels[level].diagonal * world_scale)
            / (1.0 - tree.morph_band);
        range = max(natural, clamped);
    }

    return range;
}

// Morph of a vertex toward the parent level in a perspective view: 0 at R_{d-1} (1 - b), 1 at R_{d-1}; 0 for a root
// and under the sphere metric. vertex_distance is the distance from the selection camera to the vertex.
float quadtree_morph(QuadtreeGpu tree, uint depth, float vertex_distance, float pixel_scale, float world_scale) {
    if (depth == 0u || tree.metric != QUADTREE_METRIC_BOX_RANGES) return 0.0;

    float parent = quadtree_range(tree, depth - 1u, pixel_scale, world_scale);
    float band = parent * tree.morph_band;

    return band > 0.0 ? clamp((vertex_distance - (parent - band)) / band, 0.0, 1.0) : step(parent, vertex_distance);
}

// Whether the camera that selected this pass's levels is orthographic. A shadow layer carries its owning view's answer.
bool quadtree_selection_orthographic(FrameRoot frame) {
    return (frame.flags & FRAME_SELECTION_ORTHOGRAPHIC) != 0u;
}

#endif
