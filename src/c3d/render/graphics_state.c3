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
 Viewport over the rectangle with the Vulkan Y flip.
 @pure
*>
fn gpu::Viewport rect_viewport(PixelRect rect) {
    return {
        .x         = (float)rect.x,
        .y         = (float)(rect.y + rect.height),
        .width     = (float)rect.width,
        .height    = -(float)rect.height,
        .min_depth = 0.0f,
        .max_depth = 1.0f,
    };
}

<*
 Scissor over the rectangle.
 @pure
*>
fn gpu::ScissorRect rect_scissor(PixelRect rect) {
    return { .x = (int)rect.x, .y = (int)rect.y, .width = (int)rect.width, .height = (int)rect.height };
}

<*
 Complete state for a fullscreen pass over the rectangle: flipped viewport, no depth, no culling.
 @param rect : "Inside the attachment; a zero extent covers it."
 @param color_targets : "Caller-owned; borrowed by the returned state."
 @return? gpu::INVALID_ARGUMENT
*>
fn gpu::GraphicsState? fullscreen_state(
    uint width,
    uint height,
    PixelRect rect,
    gpu::ColorTargetState[] color_targets,
) {
    gpu::GraphicsState state = gpu::render_geometry_state(width, height)!;
    if (rect.width == 0 || rect.height == 0) rect = { .width = width, .height = height };
    state.viewport = rect_viewport(rect);
    state.scissor = rect_scissor(rect);
    state.color.targets = color_targets;
    return state;
}
