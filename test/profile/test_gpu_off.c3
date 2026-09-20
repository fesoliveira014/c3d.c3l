module c3d::test::gpu_off @feat(!C3D_PROFILE_GPU);

import c3d::render;
import c3d::profile;

fn void test_gpu_off_wrappers_erase_arguments_and_preserve_optionals() @test {
    skipped_scope()!!;
}

fn void? skipped_scope() @private {
    bool reached;
    profile::GpuScopeToken scope = render::@gpu_begin(missing_renderer, missing_label())!;
    render::@gpu_end(missing_renderer, missing_token)!;
    reached = true;
    assert(reached && !scope.recorded);
}
