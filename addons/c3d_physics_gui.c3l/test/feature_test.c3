module c3d_physics_gui_feature_test;

import c3d::gui @public;

fn void test_panel_surface_requires_the_feature() @test {
    $if $feat(C3D_PHYSICS_GUI):
        $assert $defined(gui::PhysicsPanel);
        $assert $defined(gui::create_physics_panel);
        $assert $defined(gui::expose_physics_components);
    $else
        $assert !$defined(gui::PhysicsPanel);
        $assert !$defined(gui::create_physics_panel);
        $assert !$defined(gui::expose_physics_components);
    $endif
    $if $feat(C3D_PHYSICS_GUI) && $feat(C3D_PHYSICS_GUI_CHARACTER):
        $assert $defined(gui::character_inspector);
    $else
        $assert !$defined(gui::character_inspector);
    $endif
}
