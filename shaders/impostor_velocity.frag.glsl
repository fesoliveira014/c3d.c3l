#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "impostor_surface.glsl"

layout(location = 0) out vec4 out_velocity;

void main() {
    vec3 world;
    vec3 local;
    uvec3 frames;
    impostor_surface(world, local, frames);
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    FrameRoot frame = FrameRoot(draw.frame);
    LodPartGpu part = LodPartGpu(draw.lod_part);
    ImpostorGpu impostor = ImpostorGpu(part.impostor);
    InstanceGpu instance = impostor_instance(draw, v_source);
    bool reject = part.reject_history != 0u;
    mat4 previous_model = draw.prev_model;
    if (draw.instance_data != 0ul && part.current != 0ul) {
        reject = ImpostorHistory(part.current).values[v_source].reject_history != 0u;
        previous_model = reject ? instance.model : ImpostorHistory(part.previous).values[v_source].model;
    }
    vec3 previous_center = (previous_model * vec4(impostor.bounds.xyz, 1.0)).xyz;
    vec3 previous_direction = impostor.previous_camera.w != 0.0
        ? impostor.previous_direction.xyz : impostor.previous_camera.xyz - previous_center;
    uvec3 previous_frames;
    vec3 previous_weights;
    impostor_frames(normalize(mat3(inverse(previous_model)) * previous_direction), impostor.frames_per_side, previous_frames, previous_weights);
    reject = reject || any(notEqual(frames, previous_frames));
    vec3 previous_world = impostor_world(draw, instance, previous_model, local, true);
    vec4 current_clip = frame.view_proj * vec4(world, 1.0);
    vec4 previous_clip = frame.prev_view_proj * vec4(previous_world, 1.0);
    vec2 current = current_clip.xy / current_clip.w - frame.jitter_time.xy;
    vec2 previous = previous_clip.xy / previous_clip.w;
    out_velocity = vec4((current - previous) * vec2(0.5, -0.5), previous_clip.z / previous_clip.w, reject ? 1.0 : 0.0);
}
