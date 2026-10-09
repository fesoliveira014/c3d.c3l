module c3d::render;

import gpu;
import std::collections::list;

<*
 Which arm of a retirement record is live.
*>
enum RetiredKind : int {
    ALLOCATION,
    TEXTURE,
    TEXTURE_VIEW,
    TEXTURE_COVERAGE,
    ATTACHMENT_VIEW,
    PIPELINE,
    ACCELERATION_STRUCTURE,
    ACCELERATION_STRUCTURE_VIEW,
}

<*
 One owned resource awaiting its covering completion point.
*>
struct Retired {
    RetiredKind kind;
    union {
        gpu::GpuAllocation               allocation;
        gpu::TextureHandle               texture;
        gpu::TextureView                 texture_view;
        TextureCoverageResource*         coverage_resource;
        gpu::AttachmentViewHandle        attachment_view;
        gpu::PipelineHandle              pipeline;
        gpu::AccelerationStructureHandle acceleration_structure;
        gpu::AccelerationStructureView   acceleration_structure_view;
    }
}

<*
 Retirement records held by one frame slot.
*>
alias RetireList = List{Retired};

<*
 Destroy every retired object and empty the list.
 @param [&inout] retire : "Emptied; its storage is kept for the next frame."
 @require retire.is_initialized()
*>
fn void drain_retired(gpu::Device* device, RetireList* retire) {
    foreach (&record : *retire) {
        switch (record.kind) {
            case ALLOCATION:
                (void)gpu::free_allocation(device, &record.allocation);

            case TEXTURE:
                (void)gpu::destroy_texture(device, record.texture);

            case TEXTURE_VIEW:
                (void)gpu::destroy_texture_view(device, record.texture_view);

            case TEXTURE_COVERAGE:
                destroy_texture_coverage_resource(record.coverage_resource);

            case ATTACHMENT_VIEW:
                (void)gpu::destroy_attachment_view(device, record.attachment_view);

            case PIPELINE:
                (void)gpu::destroy_pipeline(device, record.pipeline);

            case ACCELERATION_STRUCTURE:
                (void)gpu::destroy_acceleration_structure(device, record.acceleration_structure);

            case ACCELERATION_STRUCTURE_VIEW:
                (void)gpu::destroy_acceleration_structure_view(device, record.acceleration_structure_view);
        }
    }

    retire.clear();
}

fn RetireList* last_submitted_retire(Renderer* renderer) @private {
    return &renderer.frames[renderer.last_submitted_slot].retire;
}
