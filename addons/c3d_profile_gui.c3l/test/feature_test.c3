module c3d_profile_gui_feature_test;

import c3d::gui;

fn void test_panel_surface_requires_gui_and_capture_features() @test {
    $if $feat(C3D_PROFILE_GUI) && ($feat(C3D_PROFILE_CPU) || $feat(C3D_PROFILE_GPU)):
        $assert $defined(gui::ProfilerPanel);
        $assert $defined(gui::create_profiler_panel);
        $assert $defined(gui::destroy_profiler_panel);
    $else
        $assert !$defined(gui::ProfilerPanel);
        $assert !$defined(gui::create_profiler_panel);
        $assert !$defined(gui::destroy_profiler_panel);
        $assert !$defined(gui::PROFILE_STORAGE_OVERFLOW);
    $endif
}
