#ifndef C3D_VIEW_CLIP_GLSL
#define C3D_VIEW_CLIP_GLSL

// Vertex stages only. A stage that includes this file writes gl_ClipDistance[0] on every path;
// the declaration makes the distance an output, and an unwritten one is undefined.
out float gl_ClipDistance[1];

// 1 without FRAME_CLIP_PLANE: shadow layers and probe updates write their roots without a plane and never clip.
float view_clip_distance(FrameRoot frame, vec3 world_position) {
    return (frame.flags & FRAME_CLIP_PLANE) != 0u
        ? dot(frame.clip_plane.xyz, world_position) + frame.clip_plane.w
        : 1.0;
}

#endif
