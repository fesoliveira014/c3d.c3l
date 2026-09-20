module c3d::gui @feat(C3D_PROFILE_GUI & (C3D_PROFILE_CPU | C3D_PROFILE_GPU));

import c3d::profile;

fn void refresh_panel(ProfilerPanel* panel) @private {
    panel.frame_count = panel.recorder.frame_ids(panel.frame_ids);
    if (!panel.following) return;
    for (usz remaining = panel.frame_count; remaining > 0; remaining--) {
        profile::FrameCaptureView frame = panel.recorder.frame(panel.frame_ids[remaining - 1])!!;
        if (frame.cpu_state == profile::CaptureState.PENDING) continue;
        $if $feat(C3D_PROFILE_GPU):
            if (frame.gpu_state == profile::CaptureState.PENDING) continue;
        $endif
        copy_snapshot(panel, frame);
        return;
    }
    panel.has_snapshot = false;
}

<* @return? profile::NOT_FOUND *>
fn void? select_frame(ProfilerPanel* panel, ulong frame_id) @private {
    profile::FrameCaptureView frame = panel.recorder.frame(frame_id)!;
    copy_snapshot(panel, frame);
    panel.following = false;
}

<*
 @param [&inout] panel : "Owned storage on the recorder's thread."
 @param frame : "Current recorder borrow consumed before mutation."
*>
fn void copy_snapshot(ProfilerPanel* panel, profile::FrameCaptureView frame) @private {
    panel.snapshot = frame;
    panel.snapshot.cpu = panel.cpu[:frame.cpu.len];
    panel.snapshot.cpu[..] = frame.cpu[..];
    usz label_used;
    foreach (&sample : panel.snapshot.cpu) {
        char[] label = panel.labels[label_used : sample.label.len];
        label[..] = ((char[])sample.label)[..];
        sample.label = (String)label;
        label_used += label.len;
    }
    $if $feat(C3D_PROFILE_GPU):
        panel.snapshot.gpu = panel.gpu[:frame.gpu.len];
        panel.snapshot.gpu[..] = frame.gpu[..];
        foreach (&sample : panel.snapshot.gpu) {
            char[] label = panel.labels[label_used : sample.label.len];
            label[..] = ((char[])sample.label)[..];
            sample.label = (String)label;
            label_used += label.len;
        }
    $endif
    panel.has_snapshot = true;
    panel.has_selected_scope = false;
    panel.source_evicted = false;
}

<* @require panel.has_snapshot *>
fn void pause_panel(ProfilerPanel* panel) @private {
    panel.following = false;
}

fn void resume_panel(ProfilerPanel* panel) @private {
    panel.following = true;
    panel.has_selected_scope = false;
    panel.source_evicted = false;
    refresh_panel(panel);
}
