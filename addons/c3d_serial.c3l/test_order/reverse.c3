module c3d::serial::order_test;

import c3d::scene;

fn void register_types(Scene* scene) @private {
    register_second(scene);
    register_first(scene);
}
