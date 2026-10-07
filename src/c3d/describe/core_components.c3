module c3d::describe;

import c3d::camera;
import c3d::light;
import c3d::scene;

<*
 Register core value components and their nested descriptions.
 @return? DESCRIPTION_CONFLICT, c3d::CAPACITY_EXCEEDED
*>
fn void? register_core_components() {
    register_core_values()!;
    register_reflected(ShadowSettings)!;
    register_reflected(ProbeUpdateDesc)!;
    register_reflected(DecalWeights)!;
    register_reflected_component(Mesh)!;
    register_reflected_component(Camera)!;
    register_reflected_component(Light)!;
    register_reflected_component(ProbeVolume)!;
    register_reflected_component(Atmosphere)!;
    register_reflected_component(HeightFog)!;
    register_reflected_component(ReflectionProbe)!;
    register_reflected_component(Decal)!;
}
