module c3d::instrumentation @private;

$assert !$feat(C3D_PROFILE_INTERNAL) || $feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU)
  : "C3D_PROFILE_INTERNAL requires C3D_PROFILE_CPU or C3D_PROFILE_GPU.";

module c3d::instrumentation @private @feat(C3D_PROFILE_CPU & C3D_PROFILE_INTERNAL);

import c3d::profile @public;

macro @scope(#label; @body()) {
    profile::@internal_scope(#label) {
        @body();
    };
}

module c3d::instrumentation @private @feat(!(C3D_PROFILE_CPU & C3D_PROFILE_INTERNAL));

macro @scope(#label; @body()) {
    @body();
}
