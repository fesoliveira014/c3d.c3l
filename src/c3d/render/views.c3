module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::pool;
import c3d::render::post;
import gpu;

<*
 Pooled views a renderer holds at once.
*>
const uint VIEW_CAPACITY = 1; // the default window view; off-screen views raise this later

<*
 Color space the view's output keeps.
*>
enum OutputMode {
    DISPLAY_LDR,
    LINEAR_HDR,
}

<*
 CPU configuration of one view; copied into its record.
*>
struct ViewDesc {
    OutputMode color;
    PostStack  post;
}

<*
 Renderer-owned view: its configuration and working images.
*>
struct ViewRecord {
    ViewDesc         desc;
    Target           post_a;
    Target           post_b;
    gpu::TextureState frame_post_a_state;
    gpu::TextureState frame_post_b_state;
}

<*
 View records addressed by ViewId.
*>
alias ViewPool = Pool{ViewRecord, ViewId};

<*
 Display output with neutral grading.
*>
fn ViewDesc default_view_desc() {
    return { .color = OutputMode.DISPLAY_LDR, .post = post::default_post_stack() };
}

<*
 Replace the view's configuration; allocates or retires its working images.
 @param [&inout] renderer : "No open frame."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? c3d::UNSUPPORTED, c3d::ASSET_DATA_UNAVAILABLE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::UNSUPPORTED_FEATURE, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !renderer.frame_open
*>
fn void? configure_view(Renderer* renderer, ViewId view, ViewDesc desc) {
    ViewRecord* record = renderer.views.try_get(view)!;
    if (desc.color == OutputMode.LINEAR_HDR) return c3d::INVALID_ARGUMENT~;
    if (desc.post.grade.lut.generation) {
        TextureAsset* lut = renderer.assets.textures.try_get(desc.post.grade.lut)!;
        if (!lut_desc_valid(&lut.desc)) return c3d::INVALID_ARGUMENT~;
        renderer.upload_texture(desc.post.grade.lut)!;
    }

    if (desc.post.fxaa) {
        post::ensure_post_targets(renderer, record)!;
    } else {
        post::retire_post_targets(renderer, record);
    }
    record.desc = desc;
}

fn bool lut_desc_valid(material::TextureDesc* desc) @private {
    bool rgba8 = desc.format == PixelFormat.RGBA8_UNORM || desc.format == PixelFormat.RGBA8_SRGB;
    return desc.depth > 0 && desc.layers == 1 && desc.mip_levels == 1 && !desc.generate_mips && !desc.is_cube && rgba8;
}
