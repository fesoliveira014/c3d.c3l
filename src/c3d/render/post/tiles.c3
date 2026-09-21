module c3d::render::post;

import c3d;
import c3d::render @public;
import c3d::shader;
import gpu;

<*
 Reduce a storage image to the largest value of every 16x16 block, then dilate by one tile.
 @param [&inout] renderer : "Open frame with the tile pipelines available."
 @param [&inout] input : "Transitioned to storage read."
 @param [&inout] record : "tile_max and tile_neighbor receive the reductions."
 @param mode : "TILE_MODE_ALPHA or TILE_MODE_VELOCITY."
 @param tiles_x : "Tiles to reduce horizontally; the rest of the images is untouched."
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::UNSUPPORTED_FEATURE, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::SLOT_TABLE_FULL, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
*>
fn void? record_tiles(
    Renderer* renderer,
    Target* input,
    ViewRecord* record,
    uint mode,
    uint tiles_x,
    uint tiles_y,
) {
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.tile_max,
        shader:     ShaderName.TILE_MAX,
        debug_name: "post_tile_max",
    )!;
    render::acquire_compute_pipeline(
        renderer:   renderer,
        pipeline:   &renderer.post_pipelines.tile_neighbor,
        shader:     ShaderName.TILE_NEIGHBOR,
        debug_name: "post_tile_neighbor",
    )!;

    input.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
    record.tile_max.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.tile_max)!;
    record_tile_dispatch(
        renderer: renderer,
        input:    input,
        output:   &record.tile_max,
        mode:     mode,
        tiles_x:  tiles_x,
        tiles_y:  tiles_y,
    )!;

    record.tile_max.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
    record.tile_neighbor.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;
    gpu::cmd_bind_pipeline(&renderer.commands, renderer.post_pipelines.tile_neighbor)!;
    record_tile_dispatch(
        renderer: renderer,
        input:    &record.tile_max,
        output:   &record.tile_neighbor,
        mode:     mode,
        tiles_x:  tiles_x,
        tiles_y:  tiles_y,
    )!;
    record.tile_neighbor.transition(&renderer.commands, gpu::storage_at({ .compute }, { .read }))!;
    renderer.stats.post_dispatches += 2;
}

fn void? record_tile_dispatch(
    Renderer* renderer,
    Target* input,
    Target* output,
    uint mode,
    uint tiles_x,
    uint tiles_y,
) @private {
    Frame* slot = &renderer.frames[renderer.frame_index % render::FRAMES_IN_FLIGHT];
    gpu::MappedGpuSpan root = slot.upload.take(&renderer.device, TileRoot::size)!;
    *(TileRoot*)root.bytes.ptr = {
        .input_texture  = input.view.index,
        .output_texture = output.view.index,
        .width          = tiles_x,
        .height         = tiles_y,
        .mode           = mode,
    };
    return dispatch_extent(renderer, root.address, tiles_x, tiles_y);
}
