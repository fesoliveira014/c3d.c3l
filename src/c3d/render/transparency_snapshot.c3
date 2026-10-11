module c3d::render;

import c3d;
import gpu;

<*
 @require !demanded || record.hdr_color.texture.is_valid()
*>
fn void? acquire_transparency_snapshot(Renderer* renderer, ViewRecord* record, bool demanded) @private {
    if (!demanded) {
        retire_transparency_snapshot(renderer, record);
        return;
    }

    acquire_transparency_sampler(renderer)!;
    Target* image = &record.scene_pyramid.image;
    if (image.texture.is_valid() && image.width == record.hdr_color.width
      && image.height == record.hdr_color.height) {
        record.scene_filtering = true;
        return;
    }

    TransparencyPyramid replacement = allocate_transparency_pyramid(
        renderer: renderer,
        width: record.hdr_color.width,
        height: record.hdr_color.height,
        debug_name: "scene_color_pyramid",
    )!;

    retire_transparency_snapshot(renderer, record);
    record.scene_pyramid = replacement;
    record.scene_pyramid_frame_state = replacement.image.state;
    record.scene_filtering = true;
}

fn void retire_transparency_snapshot(Renderer* renderer, ViewRecord* record) @private {
    // Abort redirects pending retirements to the last submitted frame.
    RetireList* retire = renderer.frame_open ? &renderer.pending_upload_retire : last_submitted_retire(renderer);
    retire_transparency_pyramid(retire, &record.scene_pyramid);
    record.scene_pyramid_frame_state = {};
    record.scene_filtering = false;
}

<*
 @require !record.scene_filtering || record.scene_color.texture.is_valid()
 @require !record.scene_filtering || record.scene_pyramid.image.texture.is_valid()
*>
fn void? record_transparency_snapshot(Renderer* renderer, ViewRecord* record) @private {
    if (!record.scene_filtering) return;

    record_transparency_pyramid(renderer, &record.scene_color, &record.scene_pyramid)!;
    record.scene_color.transition(&renderer.commands, FRAGMENT_READ_STATE)!;
}
