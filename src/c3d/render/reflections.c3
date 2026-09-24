module c3d::render;

import c3d;
import c3d::shader;
import gpu;

<*
 Roughness above which a pixel keeps the raster environment reflection.
*>
const float RT_REFLECTION_ROUGHNESS_DEFAULT = 0.5f; // above it one ray per pixel reads as grain

fn void? acquire_reflection_images(Renderer* renderer, ViewRecord* record) @private {
    if (!record.desc.ray_tracing.reflections || record.reflection.texture.is_valid()) return;
    if (!record.hdr_color.texture.is_valid()) return;

    defer catch release_reflection_images(&renderer.device, record);
    record.reflection = allocate_storage_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "reflection",
    )!;
    record.reflection_blur = allocate_storage_target(
        device:     &renderer.device,
        width:      record.hdr_color.width,
        height:     record.hdr_color.height,
        format:     gpu::Format.RGBA16_FLOAT,
        debug_name: "reflection_blur",
    )!;
}

fn void retire_reflection_images(Renderer* renderer, ViewRecord* record) @private {
    if (!record.reflection.texture.is_valid()) return;

    RetireList* retire = last_submitted_retire(renderer);
    retire_storage_target(retire, &record.reflection);
    retire_storage_target(retire, &record.reflection_blur);
}

fn void release_reflection_images(gpu::Device* device, ViewRecord* record) @private {
    if (record.reflection.texture.is_valid()) release_storage_target(device, &record.reflection);
    if (record.reflection_blur.texture.is_valid()) release_storage_target(device, &record.reflection_blur);
}
