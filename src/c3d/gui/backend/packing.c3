module c3d::gui::backend;

import c3d::shader;
import gpu;
import std::math;

<*
 Convert a logical clip rectangle into bounded framebuffer pixels.
 @param clip : "Logical minimum and maximum coordinates."
 @param display_position : "Logical display origin."
 @param framebuffer_scale : "Pixels per logical unit."
 @require framebuffer_scale.x > 0, framebuffer_scale.y > 0
 @pure
*>
fn gpu::ScissorRect gui_scissor(
    Vec4 clip,
    Vec2 display_position,
    Vec2 framebuffer_scale,
    uint width,
    uint height,
) {
    Vec2 minimum = (clip.xy - display_position) * framebuffer_scale;
    Vec2 maximum = (clip.zw - display_position) * framebuffer_scale;

    minimum.x = math::clamp(minimum.x, 0.0f, (float)width);
    minimum.y = math::clamp(minimum.y, 0.0f, (float)height);
    maximum.x = math::clamp(maximum.x, 0.0f, (float)width);
    maximum.y = math::clamp(maximum.y, 0.0f, (float)height);

    if (maximum.x <= minimum.x || maximum.y <= minimum.y) return {};

    int left = (int)math::floor(minimum.x);
    int top = (int)math::floor(minimum.y);

    return {
        .x = left,
        .y = top,
        .width = (int)math::ceil(maximum.x) - left,
        .height = (int)math::ceil(maximum.y) - top,
    };
}

<*
 Map one draw's vertices into GL clip coordinates.
 @param [&out] root : "Overwritten whole."
 @param vertices : "Base address of the combined vertex allocation."
 @param vertex_offset : "Combined list and command offset, in vertices."
 @param display_position : "Logical display origin."
 @param display_size : "Logical display extent."
 @require display_size.x > 0, display_size.y > 0
*>
fn void write_gui_vertex_root(
    GuiVertexRoot* root,
    gpu::GpuAddress vertices,
    usz vertex_offset,
    Vec2 display_position,
    Vec2 display_size,
) {
    Vec2 scale = { 2.0f / display_size.x, -2.0f / display_size.y };

    *root = {
        .vertices = (gpu::GpuAddress)((ulong)vertices + vertex_offset * GuiVertexGpu::size),
        .scale = scale,
        .translate = (Vec2){ -1, 1 } - display_position * scale,
    };
}
