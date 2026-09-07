module c3d::render;

import gpu;

<*
 Full-area viewport with the Vulkan Y flip, so shaders keep GL conventions.
 @pure
*>
fn gpu::Viewport flipped_viewport(uint width, uint height) {
    return {
        .x         = 0.0f,
        .y         = (float)height,
        .width     = (float)width,
        .height    = -(float)height,
        .min_depth = 0.0f,
        .max_depth = 1.0f,
    };
}

<*
 Complete state for a fullscreen pass: flipped viewport, no depth, no culling.
 @param color_targets : "Caller-owned; borrowed by the returned state."
 @return? gpu::INVALID_ARGUMENT
*>
fn gpu::GraphicsState? fullscreen_state(uint width, uint height, gpu::ColorTargetState[] color_targets) {
    gpu::GraphicsState state = gpu::render_geometry_state(width, height)!;
    state.viewport = flipped_viewport(width, height);
    state.color.targets = color_targets;
    return state;
}
