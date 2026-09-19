module c3d::test::instrumentation_disabled @feat(!(C3D_PROFILE_CPU & C3D_PROFILE_INTERNAL));

import c3d::instrumentation @public;

fn void test_disabled_scope_runs_body_without_resolving_label() @test {
    uint bodies;
    instrumentation::@scope(unavailable_profile_label) {
        bodies++;
    };
    assert(bodies == 1);
}
