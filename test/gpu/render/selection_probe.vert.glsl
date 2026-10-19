#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"
#include "quadtree_morph.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SelectionProbeParams {
    vec4 color;
    vec4 motion;
    uint64_t output_address;
};

layout(buffer_reference, std430, buffer_reference_align = 16) buffer SelectionProbeOutput {
    vec4 values[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer SelectionProbeDepths {
    uint values[];
};

const uint FRAME_VECTORS = 4u;
const uint NODE_FIRST = 8u;
const float FAR_DISTANCE = 1.0e6;

void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    uint index = uint(gl_VertexIndex);
    if (index == 0u) {
        SelectionProbeOutput probe = SelectionProbeOutput(SelectionProbeParams(material.parameters).output_address);
        // The depth form runs only in shadow layers when the view has no depth prepass; it fills the second group.
#ifdef DEPTH_ONLY
        uint first = FRAME_VECTORS;
#else
        uint first = 0u;
#endif
        probe.values[first] = frame.selection_camera;
        probe.values[first + 1u] = frame.previous_selection_camera;
        probe.values[first + 2u] = frame.camera_position;
        probe.values[first + 3u] = vec4(
            float((frame.flags & FRAME_SELECTION_ORTHOGRAPHIC) != 0u),
            float(frame.proj[3][3] == 1.0),
            0.0,
            0.0
        );
#ifdef INSTANCED
        if ((draw.flags & DRAW_QUADTREE) != 0u) {
            InstanceEffectsGpu effects = InstanceEffectsGpu(draw.instance_effects);
            QuadtreeGpu tree = QuadtreeGpu(effects.instance_quadtree);
            uint source = instance_source(draw);
            uint depth = SelectionProbeDepths(effects.instance_depths).values[source];
            float world_scale = quadtree_world_scale(draw.model);
            float pixel_scale = frame.selection_camera.w;
            probe.values[NODE_FIRST + source] = vec4(
                float(depth),
                quadtree_morph(tree, depth, FAR_DISTANCE, pixel_scale, world_scale),
                quadtree_morph(tree, depth, 0.0, pixel_scale, world_scale),
                quadtree_range(tree, depth, pixel_scale, world_scale)
            );
        }
#endif
    }

    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    apply_mesh_deformation(vertex, draw, geometry, index);
    write_mesh_outputs(vertex, draw, frame, geometry);
}
