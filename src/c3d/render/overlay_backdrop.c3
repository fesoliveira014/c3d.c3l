module c3d::render;

import c3d;
import c3d::shader;
import gpu;
import std::math;

const gpu::Format BACKDROP_BLUR_FORMAT @local = gpu::Format.RGBA16_FLOAT; // storage-writable, unclamped on any output

const gpu::TextureState TRANSFER_DESTINATION_STATE @local = {
    .layout = gpu::TextureLayout.TRANSFER_DESTINATION,
    .stages = { .transfer },
    .access = { .write },
};

<*
 Renderer-owned images the backdrop blur works in, grown to the largest output a backdrop list was prepared for.
*>
struct OverlayBackdrop @private {
    Target              window_copy;   // the window's pixels in the swapchain format; a target is blurred in place
    Target              horizontal;    // RGBA16F: the box after the horizontal pass
    Target              blurred;       // RGBA16F: the box after the vertical pass, which the item samples
    gpu::PipelineHandle blur_pipeline;
    gpu::TextureState   frame_copy_state;       // image states as the frame began; an abort restores them
    gpu::TextureState   frame_horizontal_state;
    gpu::TextureState   frame_blurred_state;
}

fn void? prepare_overlay_backdrop(Renderer* renderer, Target* output, bool window) @private {
    OverlayBackdrop* backdrop = &renderer.overlay_backdrop;
    acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &backdrop.blur_pipeline,
        shader:     OVERLAY_BLUR,
        debug_name: "overlay_backdrop_blur",
    )!;

    uint width = math::max(backdrop.blurred.width, output.width);
    uint height = math::max(backdrop.blurred.height, output.height);
    if (width > backdrop.blurred.width || height > backdrop.blurred.height) {
        grow_backdrop_blur_images(renderer, backdrop, width, height)!;
    }
    if (!window) return;

    bool copy_fits = backdrop.window_copy.texture.is_valid()
        && backdrop.window_copy.format == output.format
        && backdrop.window_copy.width >= output.width
        && backdrop.window_copy.height >= output.height;
    if (copy_fits) return;

    Target copy = allocate_storage_target(
        device:     &renderer.device,
        width:      math::max(backdrop.window_copy.width, output.width),
        height:     math::max(backdrop.window_copy.height, output.height),
        format:     output.format,
        debug_name: "overlay_backdrop_copy",
        usage:      { .sampled, .transfer_dst },
    )!;
    retire_backdrop_image(renderer, &backdrop.window_copy);
    backdrop.window_copy = copy;
    backdrop.frame_copy_state = {};
}

<*
 Blur the pixels under a backdrop item, then reopen the pass and ready the draw.
 Ends the open pass, so state the pass held is set again by the caller's pipeline and state.
 @param [&inout] context : "Active overlay of a list prepared with this backdrop."
 @param [&in] run : "The backdrop item's box and radius."
 @param [&inout] root : "Receives the blurred image's fields."
 @param pipeline : "Bound for the draw once the pass reopens."
 @param [&in] state : "Set once the pass reopens."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::DEVICE_LOST, gpu::BACKEND_ERROR, gpu::UNSUPPORTED_FEATURE
*>
fn void? record_overlay_backdrop(
    OverlayContext* context,
    OverlayBackdropRun* run,
    OverlayBackdropRoot* root,
    gpu::PipelineHandle pipeline,
    gpu::GraphicsState* state,
) @private {
    Renderer* renderer = context.renderer;
    gpu::CommandList* commands = context.commands;
    OverlayBackdrop* backdrop = &renderer.overlay_backdrop;
    Target* output = overlay_output(renderer, context.target);
    bool window = c3d::same_id(context.target, (RenderTargetId){});

    // The box is the item's pixels grown by the radius, so every tap of a blurred pixel lies inside it.
    int reach = (int)run.radius;
    int left = math::max(run.box.x - reach, 0);
    int top = math::max(run.box.y - reach, 0);
    int right = math::min(run.box.x + run.box.width + reach, (int)output.width);
    int bottom = math::min(run.box.y + run.box.height + reach, (int)output.height);
    uint box_width = (uint)(right - left);
    uint box_height = (uint)(bottom - top);

    gpu::cmd_end_render_pass(commands)!;

    // A window cannot be sampled, so its box is copied out; a target is read in place.
    Target* source = output;
    uint source_x = (uint)left;
    uint source_y = (uint)top;
    if (window) {
        output.transition(commands, TRANSFER_SOURCE_STATE)!;
        backdrop.window_copy.transition(commands, TRANSFER_DESTINATION_STATE)!;

        gpu::TextureCopyDesc copy = {
            .src    = output.texture,
            .src_x  = (uint)left,
            .src_y  = (uint)top,
            .dst    = backdrop.window_copy.texture,
            .width  = box_width,
            .height = box_height,
        };
        gpu::cmd_copy_texture(commands, &copy)!;

        backdrop.window_copy.transition(commands, gpu::sampled_at({ .compute }))!;
        source = &backdrop.window_copy;
        source_x = 0;
        source_y = 0;
    } else {
        output.transition(commands, gpu::sampled_at({ .compute }))!;
    }

    // The horizontal pass covers the box rows the vertical pass reads; both stay within the item's columns.
    uint item_x = (uint)(run.box.x - left);
    uint item_y = (uint)(run.box.y - top);
    uint item_width = (uint)run.box.width;
    uint item_height = (uint)run.box.height;

    backdrop.horizontal.transition(commands, gpu::storage_at({ .compute }, { .write }))!;
    gpu::cmd_bind_pipeline(commands, backdrop.blur_pipeline)!;
    record_backdrop_pass(
        context: context,
        pass:    {
            .input_texture  = source.view.index,
            .output_texture = backdrop.horizontal.view.index,
            .region_x       = item_x,
            .region_width   = item_width,
            .region_height  = box_height,
            .box_width      = box_width,
            .box_height     = box_height,
            .source_x       = source_x,
            .source_y       = source_y,
            .radius         = run.radius,
        },
    )!;

    backdrop.horizontal.transition(commands, gpu::sampled_at({ .compute }))!;
    backdrop.blurred.transition(commands, gpu::storage_at({ .compute }, { .write }))!;
    record_backdrop_pass(
        context: context,
        pass:    {
            .input_texture  = backdrop.horizontal.view.index,
            .output_texture = backdrop.blurred.view.index,
            .region_x       = item_x,
            .region_y       = item_y,
            .region_width   = item_width,
            .region_height  = item_height,
            .box_width      = box_width,
            .box_height     = box_height,
            .vertical       = 1,
            .radius         = run.radius,
        },
    )!;

    backdrop.blurred.transition(commands, gpu::sampled_at({ .fragment_shader }))!;
    output.transition(commands, COLOR_ATTACHMENT_STATE)!;

    gpu::cmd_bind_pipeline(commands, pipeline)!;
    begin_overlay_pass(renderer, output)!;
    gpu::cmd_set_graphics_state(commands, state)!;

    root.backdrop_texture = backdrop.blurred.view.index;
    root.backdrop_x = (uint)left;
    root.backdrop_y = (uint)top;
    root.backdrop_width = box_width;
    root.backdrop_height = box_height;
}

fn void? record_backdrop_pass(OverlayContext* context, OverlayBlurRoot pass) @local {
    gpu::MappedGpuSpan root = context.alloc(OverlayBlurRoot::size)!;
    *(OverlayBlurRoot*)root.bytes.ptr = pass;
    return dispatch_extent(context.renderer, root.address, pass.region_width, pass.region_height);
}

fn void? grow_backdrop_blur_images(
    Renderer* renderer,
    OverlayBackdrop* backdrop,
    uint width,
    uint height,
) @local {
    Target horizontal = allocate_storage_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     BACKDROP_BLUR_FORMAT,
        debug_name: "overlay_backdrop_horizontal",
    )!;
    defer catch release_storage_target(&renderer.device, &horizontal);

    Target blurred = allocate_storage_target(
        device:     &renderer.device,
        width:      width,
        height:     height,
        format:     BACKDROP_BLUR_FORMAT,
        debug_name: "overlay_backdrop_blurred",
    )!;

    retire_backdrop_image(renderer, &backdrop.horizontal);
    retire_backdrop_image(renderer, &backdrop.blurred);
    backdrop.horizontal = horizontal;
    backdrop.blurred = blurred;
    backdrop.frame_horizontal_state = {};
    backdrop.frame_blurred_state = {};
}

// The open frame may already have recorded commands that use the image, so it leaves with that frame's slot.
fn void retire_backdrop_image(Renderer* renderer, Target* image) @local {
    if (!image.texture.is_valid()) return;

    retire_storage_target(&renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT].retire, image);
}

fn void snapshot_overlay_backdrop(Renderer* renderer) @private {
    OverlayBackdrop* backdrop = &renderer.overlay_backdrop;
    backdrop.frame_copy_state = backdrop.window_copy.state;
    backdrop.frame_horizontal_state = backdrop.horizontal.state;
    backdrop.frame_blurred_state = backdrop.blurred.state;
}

fn void restore_overlay_backdrop(Renderer* renderer) @private {
    OverlayBackdrop* backdrop = &renderer.overlay_backdrop;
    backdrop.window_copy.state = backdrop.frame_copy_state;
    backdrop.horizontal.state = backdrop.frame_horizontal_state;
    backdrop.blurred.state = backdrop.frame_blurred_state;
}

fn void free_overlay_backdrop(Renderer* renderer) @private {
    OverlayBackdrop* backdrop = &renderer.overlay_backdrop;
    if (backdrop.window_copy.texture.is_valid()) release_storage_target(&renderer.device, &backdrop.window_copy);
    if (backdrop.horizontal.texture.is_valid()) release_storage_target(&renderer.device, &backdrop.horizontal);
    if (backdrop.blurred.texture.is_valid()) release_storage_target(&renderer.device, &backdrop.blurred);
    if (backdrop.blur_pipeline.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, backdrop.blur_pipeline);
    *backdrop = {};
}
