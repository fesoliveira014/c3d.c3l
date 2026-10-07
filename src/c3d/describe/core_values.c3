module c3d::describe;

import c3d::maths;
import c3d::scene;

<*
 Register shared scene value descriptions without component slots.
 @return? DESCRIPTION_CONFLICT
*>
fn void? register_core_values() {
    register_reflected(Transform)!;
    register_reflected(Aabb)!;
    register_reflected(Sphere)!;
    register_reflected(InstanceSway)!;
    register_reflected(InstanceFade)!;
    register_reflected(Impostor)!;
    register_reflected(LodPart)!;
    register_reflected(LodLevel)!;
    register_reflected(LodDesc)!;
    register_reflected(LodEffects)!;
    register_reflected(Billboard)!;
    register_reflected(Mesh)!;
}
