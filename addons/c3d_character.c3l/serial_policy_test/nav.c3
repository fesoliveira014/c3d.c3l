module c3d_character_policy_test @feat(C3D_CHARACTER_NAV);

import c3d::nav;
import c3d::scene;

fn void register_nav_dependencies(Scene* scene) @private {
    nav::register_serial_codecs()!!;
    nav::register_nav(scene)!!;
}
