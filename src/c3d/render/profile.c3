module c3d::render @feat(C3D_PROFILE_GPU);

import c3d;
import c3d::profile @public;
import c3d::render::profile_gpu @public;
import gpu;

alias ProfileRecorder @private = profile::Recorder;
alias ProfileScopeToken @private = profile::GpuScopeToken;

struct RendererGpuProfile @private {
    profile_gpu::GpuProfiler adapter;
    ProfileScopeToken frame;
    ProfileScopeToken view;
    ProfileScopeToken[PASS_COUNT] passes;
    ViewId current_view;
    bool has_view;
}

<*
 Begin an application interval in the current GPU recording.
 @param [&inout] self : "Owns the recording and copied label storage."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::RESOURCE_IN_USE, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, !self.overlay_open
*>
fn profile::GpuScopeToken? Renderer.begin_gpu_scope(&self, String label) {
    defer catch abort_frame(self);
    return profile_gpu::begin_scope(
        profiler: &self.gpu_profile.adapter,
        commands: &self.commands,
        label: label,
        info: { .origin = profile::ScopeOrigin.APPLICATION, .kind = profile::GpuScopeKind.APPLICATION },
    );
}

<*
 Close the innermost application interval; skipped tokens do nothing.
 @param [&inout] self : "Owns the issuing GPU recording."
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::RESOURCE_IN_USE, gpu::OUT_OF_HOST_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require self.frame_open, !self.overlay_open
 @require profile_gpu::scope_is_current(&self.gpu_profile.adapter, token)
*>
fn void? Renderer.end_gpu_scope(&self, profile::GpuScopeToken token) {
    defer catch abort_frame(self);
    return profile_gpu::end_scope(&self.gpu_profile.adapter, &self.commands, token);
}

<*
 Begin an application GPU interval with a lazily admitted label.
 @return? Renderer.begin_gpu_scope!
*>
macro profile::GpuScopeToken? @gpu_begin(#renderer, #label) {
    Renderer* renderer = #renderer;
    profile_gpu::GpuProfiler* profiler = &renderer.gpu_profile.adapter;
    ulong serial = profiler.recording_serial;
    if (!profile_gpu::admit_scope(profiler, profile::ScopeOrigin.APPLICATION, serial)) return {};
    String label = #label;
    if (!profile_gpu::admit_scope(profiler, profile::ScopeOrigin.APPLICATION, serial)) return {};
    return renderer.begin_gpu_scope(label);
}

<*
 Close an application GPU interval.
 @return? Renderer.end_gpu_scope!
*>
macro void? @gpu_end(#renderer, #token) {
    Renderer* renderer = #renderer;
    profile::GpuScopeToken token = #token;
    return renderer.end_gpu_scope(token);
}

fn RendererGpuProfile? create_renderer_gpu_profile(
    Allocator allocator,
    gpu::Device* device,
    RendererDesc desc,
) @private {
    return { .adapter = profile_gpu::create_gpu_profiler(
        allocator: allocator,
        device: device,
        recorder: desc.profiler,
        desc: {
            .frame_slots = FRAMES_IN_FLIGHT,
            .scopes_per_slot = desc.gpu_scope_capacity,
            .label_bytes_per_slot = desc.gpu_label_bytes_per_slot,
            .enabled = desc.gpu_timings,
        },
    )! };
}

fn void destroy_renderer_gpu_profile(gpu::Device* device, RendererGpuProfile* profile) @private {
    profile_gpu::abandon_pending(&profile.adapter);
    if (catch excuse = profile_gpu::destroy_gpu_profiler(device, &profile.adapter)) handle_cleanup_fault(excuse);
}

fn void publish_gpu_summary(Renderer* renderer, profile_gpu::CompletedFrame completed) @private {
    if (!completed.available) return;
    Stats* stats = &renderer.stats;
    bool has_completed = stats.gpu_timing_state == READY || stats.gpu_timing_state == TRUNCATED;
    if (has_completed && completed.renderer_frame < stats.gpu_frame_index) return;
    stats.gpu_frame_index = completed.renderer_frame;
    stats.gpu_timing_state = completed.truncated ? GpuTimingState.TRUNCATED : GpuTimingState.READY;
    stats.gpu_scopes_dropped = completed.dropped_scopes;
    stats.gpu_pass_ms = {};
    stats.gpu_pass_valid = {};
    uint shadow_count;
    foreach (sample : completed.samples) {
        switch (sample.info.kind) {
            case PASS:
            case COMPUTE_DISPATCH:
                stats.gpu_pass_ms[sample.info.pass_ordinal] += (float)(sample.duration_ns / NANOSECONDS_PER_MILLISECOND);
                stats.gpu_pass_valid[sample.info.pass_ordinal] = true;
            case SHADOW_LAYER:
                renderer.shadow_timing_results[shadow_count++] = {
                    .light = { .index = sample.info.light_index, .generation = sample.info.light_generation },
                    .kind = (LightKind)sample.info.light_kind,
                    .layer_index = sample.info.layer_index,
                    .gpu_ms = (float)(sample.duration_ns / NANOSECONDS_PER_MILLISECOND),
                    .view = { .index = sample.info.view_index, .generation = sample.info.view_generation },
                };
            case APPLICATION:
            case FRAME:
            case VIEW:
        }
    }
    stats.shadow_timings = renderer.shadow_timing_results[:shadow_count];
}

fn profile::GpuScopeInfo profile_view_info(Renderer* renderer, profile::GpuScopeKind kind) @private {
    return {
        .origin = profile::ScopeOrigin.LIBRARY,
        .kind = kind,
        .has_view = renderer.gpu_profile.has_view,
        .view_index = renderer.gpu_profile.current_view.index,
        .view_generation = renderer.gpu_profile.current_view.generation,
    };
}

fn ProfileScopeToken? begin_internal_gpu_scope(
    Renderer* renderer,
    String label,
    profile::GpuScopeInfo info,
) @private {
    $if $feat(C3D_PROFILE_INTERNAL):
        return profile_gpu::begin_scope(
            profiler: &renderer.gpu_profile.adapter,
            commands: &renderer.commands,
            label: label,
            info: info,
        );
    $else
        return {};
    $endif
}

fn void? collect_gpu_profile(Renderer* renderer, uint slot_index) @private {
    profile_gpu::CompletedFrame completed = profile_gpu::collect_completed(
        device: &renderer.device,
        profiler: &renderer.gpu_profile.adapter,
        slot_index: slot_index,
    )!;
    publish_gpu_summary(renderer, completed);
}

fn void? begin_gpu_profile(Renderer* renderer) @private {
    profile_gpu::begin_recording(
        profiler: &renderer.gpu_profile.adapter,
        commands: &renderer.commands,
        slot_index: renderer.recording_slot,
        renderer_frame: renderer.frame_index,
    )!;
    renderer.gpu_profile.has_view = false;
    renderer.gpu_profile.frame = begin_internal_gpu_scope(renderer, "frame", {
        .origin = profile::ScopeOrigin.LIBRARY,
        .kind = profile::GpuScopeKind.FRAME,
    })!;
}

fn bool gpu_profile_balanced(Renderer* renderer) @private {
    profile_gpu::GpuProfiler* profiler = &renderer.gpu_profile.adapter;
    if (!profiler.recording) return true;
    uint expected_depth = renderer.gpu_profile.frame.recorded ? 1 : 0;
    return profiler.slots[profiler.current_slot].depth == expected_depth;
}

fn void? end_gpu_profile(Renderer* renderer) @private {
    end_profile_scope(renderer, renderer.gpu_profile.frame)!;
}

fn void submit_gpu_profile(Renderer* renderer) @private {
    profile_gpu::mark_submitted(&renderer.gpu_profile.adapter);
}

fn void cancel_gpu_profile(Renderer* renderer) @private {
    profile_gpu::cancel_recording(&renderer.gpu_profile.adapter);
}

fn void? begin_profile_pass(Renderer* renderer, Pass pass) @private {
    $if $feat(C3D_PROFILE_INTERNAL):
        profile::GpuScopeInfo info = profile_view_info(renderer, profile::GpuScopeKind.PASS);
        info.pass_ordinal = (uint)pass.ordinal;
        renderer.gpu_profile.passes[pass.ordinal] = begin_internal_gpu_scope(
            renderer: renderer,
            label: Pass::names[pass.ordinal],
            info: info,
        )!;
    $endif
}

fn void? end_profile_pass(Renderer* renderer, Pass pass) @private {
    $if $feat(C3D_PROFILE_INTERNAL):
        end_profile_scope(renderer, renderer.gpu_profile.passes[pass.ordinal])!;
    $endif
}

fn void? begin_profile_view(Renderer* renderer, ViewId view, String label) @private {
    $if $feat(C3D_PROFILE_INTERNAL):
        renderer.gpu_profile.current_view = view;
        renderer.gpu_profile.has_view = true;
        renderer.gpu_profile.view = begin_internal_gpu_scope(
            renderer: renderer,
            label: label,
            info: profile_view_info(renderer, profile::GpuScopeKind.VIEW),
        )!;
    $endif
}

fn void? end_profile_view(Renderer* renderer) @private {
    $if $feat(C3D_PROFILE_INTERNAL):
        end_profile_scope(renderer, renderer.gpu_profile.view)!;
        renderer.gpu_profile.has_view = false;
        renderer.gpu_profile.current_view = {};
    $endif
}

fn ProfileScopeToken? begin_profile_shadow(
    Renderer* renderer,
    Entity light,
    LightKind kind,
    uint layer_index,
) @private {
    $if $feat(C3D_PROFILE_INTERNAL):
        profile::GpuScopeInfo info = profile_view_info(renderer, profile::GpuScopeKind.SHADOW_LAYER);
        info.pass_ordinal = (uint)Pass.SHADOW_ATLAS.ordinal;
        info.light_index = light.index;
        info.light_generation = light.generation;
        info.light_kind = (uint)kind.ordinal;
        info.layer_index = layer_index;
        return begin_internal_gpu_scope(renderer, "shadow.layer", info);
    $else
        return {};
    $endif
}

fn ProfileScopeToken? begin_profile_dispatch(Renderer* renderer, ComputeShaderId shader, uint revision) @private {
    $if $feat(C3D_PROFILE_INTERNAL):
        Pass pass = renderer.frame_recorded ? Pass.CUSTOM_COMPUTE_POST : Pass.CUSTOM_COMPUTE;
        return begin_internal_gpu_scope(renderer, "compute.dispatch", {
            .origin = profile::ScopeOrigin.LIBRARY,
            .kind = profile::GpuScopeKind.COMPUTE_DISPATCH,
            .pass_ordinal = (uint)pass.ordinal,
            .shader_index = shader.index,
            .shader_generation = shader.generation,
            .shader_revision = revision,
        });
    $else
        return {};
    $endif
}

fn void? end_profile_scope(Renderer* renderer, ProfileScopeToken token) @private {
    profile_gpu::end_scope(&renderer.gpu_profile.adapter, &renderer.commands, token)!;
}

module c3d::render @feat(!C3D_PROFILE_GPU);

import c3d;
import gpu;

struct ProfileScopeToken @private {
    bool recorded;
}

<* Skip GPU arguments when GPU profiling is excluded. *>
macro @gpu_begin(#renderer, #label) {
    profile::GpuScopeToken? skipped = {};
    return skipped;
}

<* Skip GPU arguments when GPU profiling is excluded. *>
macro void? @gpu_end(#renderer, #token) {
    return skipped_gpu_end();
}

fn void? skipped_gpu_end() @private @inline {}

fn void? collect_gpu_profile(Renderer* renderer, uint slot_index) @private {}
fn void? begin_gpu_profile(Renderer* renderer) @private {}
fn void? end_gpu_profile(Renderer* renderer) @private {}
fn void submit_gpu_profile(Renderer* renderer) @private {}
fn void cancel_gpu_profile(Renderer* renderer) @private {}
fn void? begin_profile_pass(Renderer* renderer, Pass pass) @private {}
fn void? end_profile_pass(Renderer* renderer, Pass pass) @private {}
fn void? begin_profile_view(Renderer* renderer, ViewId view, String label) @private {}
fn void? end_profile_view(Renderer* renderer) @private {}
fn void? end_profile_scope(Renderer* renderer, ProfileScopeToken token) @private {}
fn ProfileScopeToken? begin_profile_dispatch(Renderer* renderer, ComputeShaderId shader, uint revision) @private {
    return {};
}
fn ProfileScopeToken? begin_profile_shadow(
    Renderer* renderer,
    Entity light,
    LightKind kind,
    uint layer_index,
) @private {
    return {};
}

fn bool gpu_profile_balanced(Renderer* renderer) @private => true;

fn void? create_renderer_gpu_profile(Allocator allocator, gpu::Device* device, RendererDesc desc) @private {}
