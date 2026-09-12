module c3d::gui::backend;

import c3d::gui;
import c3d::render;
import c3d::shader;
import gpu;
import imgui;
import std::math;

const sz RESET_RENDER_STATE_CALLBACK @local = -8; // ImGui's legacy callback ABI; never call this sentinel

<*
 Owned GPU resources for an ImGui overlay.
*>
struct GuiBackend {
    Allocator allocator;
    Renderer* renderer;
    gpu::TextureHandle font_texture;
    gpu::TextureView font_view;
    PipelineCache pipelines;
    gpu::SamplerIndex sampler;
    usz index_stride;
    gpu::IndexType index_type;
}

$assert imgui::DrawVert::size == GuiVertexGpu::size;
$assert $reflect(imgui::DrawVert.pos).offset == $reflect(GuiVertexGpu.position_x).offset;
$assert $reflect(imgui::DrawVert.uv).offset == $reflect(GuiVertexGpu.uv_x).offset;
$assert $reflect(imgui::DrawVert.col).offset == $reflect(GuiVertexGpu.rgba).offset;

<*
 Create overlay resources and synchronously upload the font atlas.
 @param [&inout] renderer : "Stable borrow; owns setup recording and retirement."
 @param rgba_pixels : "Complete tightly packed RGBA8 atlas from current ImGui context."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::UNSUPPORTED_FEATURE, gpu::WAIT_TIMEOUT, gpu::RESOURCE_IN_USE
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gui::UNSUPPORTED_INDEX_WIDTH
 @require !renderer.frame_open, renderer.swapchain.is_valid()
 @require width > 0, height > 0
*>
fn GuiBackend? create_gui_backend(
    Allocator allocator,
    Renderer* renderer,
    char[] rgba_pixels,
    uint width,
    uint height,
) {
    usz index_stride = imgui::draw_idx_size();
    gpu::IndexType index_type;

    switch (index_stride) {
        case ushort::size: index_type = gpu::IndexType.U16;
        case uint::size: index_type = gpu::IndexType.U32;
        default: return gui::UNSUPPORTED_INDEX_WIDTH~;
    }

    GuiBackend backend = {
        .allocator = allocator,
        .renderer = renderer,
        .pipelines = render::create_pipeline_cache(allocator, renderer.pipelines.registry),
        .index_stride = index_stride,
        .index_type = index_type,
    };
    defer catch render::destroy_pipeline_cache(&renderer.device, &backend.pipelines);

    gpu::TextureDesc texture_desc = {
        .width = width,
        .height = height,
        .format = gpu::Format.RGBA8_UNORM,
        .usage = { .sampled, .transfer_dst },
        .access = { .graphics },
        .debug_name = "imgui_font_atlas",
    };
    backend.font_texture = gpu::create_texture(&renderer.device, &texture_desc)!;
    defer catch renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT].retire.push({
        .kind = RetiredKind.TEXTURE,
        .texture = backend.font_texture,
    });

    backend.font_view = gpu::create_texture_view(&renderer.device, backend.font_texture, null)!;
    defer catch renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT].retire.push({
        .kind = RetiredKind.TEXTURE_VIEW,
        .texture_view = backend.font_view,
    });

    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.LINEAR,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .debug_name = "imgui_sampler",
    };
    backend.sampler = gpu::intern_sampler(&renderer.device, &sampler_desc)!;

    resolve_pipeline(&backend, renderer.swapchain_info.format)!;
    renderer.upload_rgba8_texture(backend.font_texture, rgba_pixels)!;

    imgui::font_atlas::set_tex_id(imgui::io_get_fonts(), (ulong)(uint)backend.font_view.index);
    imgui::BackendFlags flags = imgui::io_get_backend_flags();
    flags.renderer_has_vtx_offset = true;
    imgui::io_set_backend_flags(flags);

    return backend;
}

<*
 Release overlay resources after renderer submissions complete.
 @param [&inout] backend : "Cleared on success; preserved if waiting fails."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::DEVICE_BUSY
 @return? gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !backend.renderer.frame_open
*>
fn void? destroy_gui_backend(GuiBackend* backend) {
    render::wait_frames(backend.renderer)!;

    render::destroy_pipeline_cache(&backend.renderer.device, &backend.pipelines);
    (void)gpu::destroy_texture_view(&backend.renderer.device, backend.font_view);
    (void)gpu::destroy_texture(&backend.renderer.device, backend.font_texture);

    *backend = {};
}

<*
 Copy finalized ImGui geometry and record its clipped draws.
 @param [&inout] backend : "Owns output-format pipelines and font resources."
 @param [&in] draw_data : "Finalized native data, borrowed until next new_frame."
 @param [&inout] overlay : "Active pass borrowing the matching renderer."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::UNSUPPORTED_FEATURE, c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID
 @return? gpu::PIPELINE_CREATE_FAILED, gpu::SLOT_TABLE_FULL
 @require draw_data != null
 @require overlay.renderer == backend.renderer, backend.renderer.overlay_open
*>
fn void? record_gui(GuiBackend* backend, imgui::DrawData draw_data, OverlayContext* overlay) {
    usz vertex_count = (usz)imgui::draw_data_total_vtx_count(draw_data);
    usz index_count = (usz)imgui::draw_data_total_idx_count(draw_data);
    int list_count = imgui::draw_data_cmd_list_count(draw_data);

    gpu::MappedGpuSpan vertices;
    gpu::MappedGpuSpan indices;
    if (vertex_count) vertices = overlay.alloc(vertex_count * GuiVertexGpu::size)!;
    if (index_count) indices = overlay.alloc(index_count * backend.index_stride)!;

    usz vertex_base;
    usz index_base;
    for (int index = 0; index < list_count; index++) {
        imgui::DrawList list = imgui::draw_data_cmd_list(draw_data, index);
        usz list_vertices = (usz)imgui::draw_list_vtx_count(list);
        usz list_indices = (usz)imgui::draw_list_idx_count(list);

        if (list_vertices) {
            mem::copy(&vertices.bytes[vertex_base * GuiVertexGpu::size],
                imgui::draw_list_vtx_ptr(list), (sz)(list_vertices * GuiVertexGpu::size));
        }

        if (list_indices) {
            mem::copy(&indices.bytes[index_base * backend.index_stride],
                imgui::draw_list_idx_ptr(list), (sz)(list_indices * backend.index_stride));
        }

        vertex_base += list_vertices;
        index_base += list_indices;
    }

    Vec2 display_position;
    Vec2 display_size;
    Vec2 framebuffer_scale;
    imgui::draw_data_display_pos(draw_data, &display_position.x, &display_position.y);
    imgui::draw_data_display_size(draw_data, &display_size.x, &display_size.y);
    imgui::draw_data_framebuffer_scale(draw_data, &framebuffer_scale.x, &framebuffer_scale.y);

    gpu::PipelineHandle pipeline = resolve_pipeline(backend, overlay.color_format)!;

    gpu::ColorTargetState[1] colors = { gpu::color_blend_disabled() };
    colors[0].blend = {
        .enable = true,
        .src_color = gpu::BlendFactor.SRC_ALPHA,
        .dst_color = gpu::BlendFactor.ONE_MINUS_SRC_ALPHA,
        .color_op = gpu::BlendOp.ADD,
        .src_alpha = gpu::BlendFactor.ONE,
        .dst_alpha = gpu::BlendFactor.ONE_MINUS_SRC_ALPHA,
        .alpha_op = gpu::BlendOp.ADD,
    };

    gpu::GraphicsState state = render::fullscreen_state(overlay.width, overlay.height, colors[..])!;
    state.raster = { .topology = gpu::PrimitiveTopology.TRIANGLES, .cull_mode = gpu::CullMode.NONE };
    state.depth = {};
    state.stencil = {};
    restore_state(overlay.commands, pipeline, &state)!;

    vertex_base = 0;
    index_base = 0;
    for (int index = 0; index < list_count; index++) {
        imgui::DrawList list = imgui::draw_data_cmd_list(draw_data, index);
        int command_count = imgui::draw_list_cmd_count(list);
        imgui::DrawCmd* draw_commands = imgui::draw_list_cmd_ptr(list);

        for (int command_index = 0; command_index < command_count; command_index++) {
            imgui::DrawCmd* command = &draw_commands[command_index];

            if (command.user_callback) {
                if ((sz)command.user_callback != RESET_RENDER_STATE_CALLBACK) {
                    command.user_callback(list, command);
                }

                restore_state(overlay.commands, pipeline, &state)!;
                continue;
            }

            if (!command.elem_count) continue;

            gpu::ScissorRect scissor = gui_scissor(
                clip: command.clip_rect,
                display_position: display_position,
                framebuffer_scale: framebuffer_scale,
                width: overlay.width,
                height: overlay.height,
            );
            if (!scissor.width || !scissor.height) continue;

            gpu::MappedGpuSpan vertex_root = overlay.alloc(GuiVertexRoot::size)!;
            write_gui_vertex_root(
                root: (GuiVertexRoot*)vertex_root.bytes.ptr,
                vertices: vertices.address,
                vertex_offset: vertex_base + command.vtx_offset,
                display_position: display_position,
                display_size: display_size,
            );

            gpu::MappedGpuSpan fragment_root = overlay.alloc(GuiFragmentRoot::size)!;
            *(GuiFragmentRoot*)fragment_root.bytes.ptr = {
                .source_texture = (gpu::TextureIndex)(uint)imgui::texture_ref::get_tex_id(&command.tex_ref),
                .source_sampler = backend.sampler,
            };

            usz byte_offset = (index_base + command.idx_offset) * backend.index_stride;
            usz byte_count = (usz)command.elem_count * backend.index_stride;
            gpu::GpuSpan index_span = indices.span.checked_subspan(byte_offset, byte_count)!;

            gpu::cmd_set_scissor(overlay.commands, &scissor);
            gpu::cmd_draw_indexed(
                commands: overlay.commands,
                vertex_root: vertex_root.address,
                fragment_root: fragment_root.address,
                index_span: index_span,
                index_count: command.elem_count,
                instance_count: 1,
                index_type: backend.index_type,
            )!;

            backend.renderer.stats.draws++;
            backend.renderer.stats.triangles += command.elem_count / 3;
        }

        vertex_base += (usz)imgui::draw_list_vtx_count(list);
        index_base += (usz)imgui::draw_list_idx_count(list);
    }
}

fn gpu::PipelineHandle? resolve_pipeline(GuiBackend* backend, gpu::Format format) @local {
    PipelineKey key = {
        .vertex = { .shader = IMGUI_VERTEX },
        .fragment = { .shader = IMGUI_FRAGMENT },
        .color_formats = { [0] = format },
        .color_count = 1,
        .depth_format = gpu::Format.UNDEFINED,
        .samples = gpu::SampleCount.ONE,
        .polygon = gpu::PolygonMode.FILL,
    };

    return backend.pipelines.get(&backend.renderer.device, key);
}

fn void? restore_state(gpu::CommandList* commands, gpu::PipelineHandle pipeline,
  gpu::GraphicsState* state) @local {
    gpu::cmd_bind_pipeline(commands, pipeline)!;
    gpu::cmd_set_graphics_state(commands, state)!;
}
