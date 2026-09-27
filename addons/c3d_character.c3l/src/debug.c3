module c3d::character;

import std::math;
import c3d::debug;
import c3d::ecs;
import c3d::scene;

const uint  CAPSULE_COLOR @local = 0xFFFF8040;
const uint  PLANE_COLOR @local = debug::COLOR_YELLOW;
const uint  GROUND_COLOR @local = debug::COLOR_GREEN;
const float NORMAL_LENGTH @local = 0.25f; // metres; visible at character scale without crossing the capsule

<*
 What CharacterSystem.debug_draw appends.
*>
struct CharacterDebugOptions {
    bool capsules;
    bool planes;     // last gathered planes as short normals from their points
    bool ground;     // ground normal
}

<*
 Append capsules, gathered planes and ground normals to the sink.
 @param [&inout] sink : "Cleared by the application."
*>
fn void CharacterSystem.debug_draw(&self, debug::DebugDraw* sink, CharacterDebugOptions options) {
    Scene* scene = self.state.scene;
    scene.@each(Character; entity, character) {
        Vec3 center = scene.node(entity).world_position();
        CharacterDesc desc = character.desc;
        if (options.capsules) {
            sink.capsule(
                center:      center,
                axis:        { 0, 1, 0 },
                half_height: desc.half_height,
                radius:      desc.radius,
                rgba:        CAPSULE_COLOR,
            );
        }
        if (options.planes) {
            foreach (&plane : character.planes[:character.plane_count]) {
                sink.line(plane.point, plane.point + plane.normal * NORMAL_LENGTH, PLANE_COLOR);
            }
        }
        if (options.ground && character.grounded) {
            Vec3 foot = center - (Vec3){ 0, desc.half_height + desc.radius, 0 };
            sink.line(foot, foot + character.ground_normal * NORMAL_LENGTH, GROUND_COLOR);
        }
    };
}
