module c3d::anim;

<* Copied transition state; it exposes no owned history or writable playback storage. *>
struct AnimationInertialStatus {
    bool enabled;
    bool active;
    double elapsed;
    double duration;
}

<* Read this Animator's prepared inertia and current transition state. *>
fn AnimationInertialStatus Animator.inertial_status(&self) {
    if (!self.inertial_storage) return {};

    InertialControl* control = &self.inertial_storage.rows[0].control;
    return {
        .enabled = true,
        .active = control.active,
        .elapsed = control.elapsed,
        .duration = control.duration,
    };
}
