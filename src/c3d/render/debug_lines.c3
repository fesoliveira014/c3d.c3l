module c3d::render;

import c3d;
import c3d::debug;
import c3d::light;
import c3d::shader;
import gpu;
import std::math;

<*
 Alpha of the second, depth-free draw; readable through geometry without hiding it.
*>
const float DEBUG_OVERLAY_ALPHA = 0.25f;

<*
 Retained shadow camera of the last recorded frame.
*>
struct ShadowFrustum {
    Mat4      inv_view_proj;
    LightKind kind;
}

$assert DebugVertexGpu::size == DebugVertex::size;
$assert $reflect(DebugVertexGpu.x).offset == $reflect(DebugVertex.position).offset;
$assert $reflect(DebugVertexGpu.rgba).offset == $reflect(DebugVertex.rgba).offset;

<*
 Append the shadow cameras of the last recorded frame as frusta.
 @param [&in] self : "Cameras stay from the last frame that recorded shadows."
 @param [&inout] draw : "Receives one frustum per shadow layer."
*>
fn void Renderer.draw_shadow_frusta(&self, DebugDraw* draw, uint rgba) {
    foreach (frustum : self.shadow_frusta[:self.shadow_frustum_count]) {
        draw.frustum(frustum.inv_view_proj, rgba);
    }
}

fn void? record_debug_lines(
    Renderer* renderer,
    ViewRecord* record,
    Mat4 view_proj,
    DebugDraw* debug,
) @private {
    DebugVertex[] vertices = debug.vertices.array_view();
    Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan vertex_span = slot.upload.take(
        device:    &renderer.device,
        size:      vertices.len * DebugVertexGpu::size,
        alignment: STREAM_ALIGNMENT,
    )!;
    mem::copy(vertex_span.bytes.ptr, vertices.ptr, vertices.len * DebugVertexGpu::size);

    gpu::MappedGpuSpan solid_root = slot.upload.take(&renderer.device, DebugLinesRoot::size)!;
    *(DebugLinesRoot*)solid_root.bytes.ptr = {
        .vertices  = vertex_span.address,
        .alpha     = 1,
        .view_proj = bitcast(view_proj, Mat4f),
    };
    gpu::MappedGpuSpan overlay_root = slot.upload.take(&renderer.device, DebugLinesRoot::size)!;
    *(DebugLinesRoot*)overlay_root.bytes.ptr = {
        .vertices  = vertex_span.address,
        .alpha     = DEBUG_OVERLAY_ALPHA,
        .view_proj = bitcast(view_proj, Mat4f),
    };

    PipelineKey key = {
        .vertex        = { .shader = LINES_VERTEX },
        .fragment      = { .shader = LINES_FRAGMENT },
        .color_formats = { [0] = record.hdr_color.format },
        .color_count   = 1,
        .depth_format  = record.depth.format,
        .samples       = gpu::SampleCount.ONE,
        .polygon       = gpu::PolygonMode.FILL,
    };
    gpu::PipelineHandle pipeline = renderer.pipelines.get(&renderer.device, key)!;

    uint width = record.hdr_color.width;
    uint height = record.hdr_color.height;
    gpu::ColorTargetDesc[1] colors = {{
        .view     = record.hdr_color.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    }};
    gpu::DepthTargetDesc depth = {
        .view     = record.depth.attachment,
        .load_op  = gpu::LoadOp.LOAD,
        .store_op = gpu::StoreOp.STORE,
    };
    gpu::RenderPassDesc pass = {
        .colors = colors[..],
        .depth  = &depth,
        .width  = width,
        .height = height,
    };

    begin_profile_pass(renderer, Pass.DEBUG_LINES)!;
    gpu::cmd_bind_pipeline(&renderer.commands, pipeline)!;
    record.hdr_color.transition(&renderer.commands, COLOR_ATTACHMENT_STATE)!;
    record.depth.transition(&renderer.commands, DEPTH_ATTACHMENT_STATE)!;
    gpu::cmd_begin_render_pass(&renderer.commands, &pass)!;

    gpu::ColorTargetState[1] color_targets = { gpu::alpha_blend() };
    gpu::GraphicsState state = gpu::render_geometry_state(width, height)!;
    state.viewport = flipped_viewport(width, height);
    state.color.targets = color_targets[..];
    state.raster.topology = gpu::PrimitiveTopology.LINES;
    state.raster.cull_mode = gpu::CullMode.NONE;
    state.depth = {
        .test_enable  = true,
        .write_enable = false,
        .compare      = gpu::CompareOp.GREATER,
    };
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    gpu::cmd_draw(
        commands:       &renderer.commands,
        vertex_root:    solid_root.address,
        fragment_root:  solid_root.address,
        vertex_count:   (uint)vertices.len,
        instance_count: 1,
    )!;

    state.depth.test_enable = false;
    gpu::cmd_set_graphics_state(&renderer.commands, &state)!;
    gpu::cmd_draw(
        commands:       &renderer.commands,
        vertex_root:    overlay_root.address,
        fragment_root:  overlay_root.address,
        vertex_count:   (uint)vertices.len,
        instance_count: 1,
    )!;

    gpu::cmd_end_render_pass(&renderer.commands)!;
    end_profile_pass(renderer, Pass.DEBUG_LINES)!;

    renderer.stats.draws += 2;
    renderer.stats.debug_lines += (uint)vertices.len / 2;
}
