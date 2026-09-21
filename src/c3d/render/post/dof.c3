module c3d::render::post;

import c3d;
import c3d::render @public;
import c3d::shader;
import gpu;

<*
 Record depth of field over the scene input into hdr_color.
 @param [&inout] renderer : "Open frame with its forward passes recorded; scene_input returns to hdr_color."
 @param [&inout] record : "Its DoF layers and tiles change state."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require record.dof_near.texture.is_valid(), record.tile_max.texture.is_valid()
*>
fn void? record_dof(Renderer* renderer, ViewRecord* record) {
    acquire_dof_pipelines(renderer)!;
    open_post_chain(renderer, record)!;
    Target* input = record.scene_input;
    bool in_place = input == &record.hdr_color;
    uint half_width = record.dof_near.width;
    uint half_height = record.dof_near.height;

    input.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.depth.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.dof_near.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    record.dof_far.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.dof_coc)!;
    record_dof_dispatch(renderer, record, shader::DOF_PASS_COC, in_place)!;

    record_tiles(
        renderer: renderer,
        input:    &record.dof_near,
        record:   record,
        mode:     shader::TILE_MODE_ALPHA,
        tiles_x:  tile_count(half_width),
        tiles_y:  tile_count(half_height),
    )!;

    record.dof_near.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.dof_far.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.dof_near_blur.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    record.dof_far_blur.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.dof_gather)!;
    record_dof_dispatch(renderer, record, shader::DOF_PASS_GATHER_NEAR, in_place)!;
    record_dof_dispatch(renderer, record, shader::DOF_PASS_GATHER_FAR, in_place)!;

    record.dof_near_blur.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    record.dof_far_blur.transition(&renderer.commands, gpu::sampled_at({ .compute }))!;
    gpu::TextureAccess access = in_place ? (gpu::TextureAccess){ .read, .write } : (gpu::TextureAccess){ .write };
    record.hdr_color.transition(&renderer.commands, gpu::storage_at({ .compute }, access))!;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.dof_composite)!;
    record_dof_dispatch(renderer, record, shader::DOF_PASS_COMPOSITE, in_place)!;

    renderer.stats.post_dispatches += 4;
    record.scene_input = &record.hdr_color;
}

fn void? acquire_dof_pipelines(Renderer* renderer) @private {
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.dof_coc,
        shader:     ShaderName.DOF_COC,
        debug_name: "post_dof_coc",
    )!;
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.dof_gather,
        shader:     ShaderName.DOF_GATHER,
        debug_name: "post_dof_gather",
    )!;
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.dof_composite,
        shader:     ShaderName.DOF_COMPOSITE,
        debug_name: "post_dof_composite",
    )!;
}

fn void? record_dof_dispatch(
    Renderer* renderer,
    ViewRecord* record,
    uint pass,
    bool in_place,
) @private {
    DofParams* params = &record.desc.post.dof_params;
    bool full = pass == shader::DOF_PASS_COMPOSITE;
    Target* output;
    switch (pass) {
        case shader::DOF_PASS_COC: output = &record.dof_near;
        case shader::DOF_PASS_GATHER_NEAR: output = &record.dof_near_blur;
        case shader::DOF_PASS_GATHER_FAR: output = &record.dof_far_blur;
        default: output = &record.hdr_color;
    }
    Target* near = full ? &record.dof_near_blur : &record.dof_near;
    Target* far = full ? &record.dof_far_blur : &record.dof_far;

    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, DofRoot::size)!;
    *(DofRoot*)root.bytes.ptr = {
        .color_texture  = record.scene_input.view.index,
        .depth_texture  = record.depth.view.index,
        .sampler_index  = renderer.linear_clamp_sampler,
        .near_texture   = near.view.index,
        .far_texture    = far.view.index,
        .tile_texture   = record.tile_neighbor.view.index,
        .output_texture = output.view.index,
        .width          = output.width,
        .height         = output.height,
        .pass           = pass,
        .in_place       = in_place ? 1 : 0,
        .orthographic   = record.projection_terms.orthographic ? 1 : 0,
        .max_coc        = params.max_coc,
        .aperture_scale = dof_aperture_scale(params, record.dof_near.height),
        .focus_distance = params.focus_distance,
        .proj_22        = record.projection_terms.m22,
        .proj_23        = record.projection_terms.m23,
        .half_texel     = { 1.0f / (float)record.dof_near.width, 1.0f / (float)record.dof_near.height },
        .full_texel     = { 1.0f / (float)record.hdr_color.width, 1.0f / (float)record.hdr_color.height },
    };
    return dispatch_extent(renderer, root.address, output.width, output.height);
}
