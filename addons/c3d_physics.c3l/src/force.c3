module c3d::physics;

import std::math;
import c3d;
import c3d::scene;
import b3;

<*
 Push dynamic bodies away from the position with a radial impulse.
 @return? b3::INVALID_DEFINITION
*>
fn void? PhysicsWorld.explode(&self, ExplosionDesc desc) {
    b3::ExplosionDef def = b3::default_explosion_def();
    def.mask_bits = desc.mask;
    def.position = (b3::Pos)desc.position;
    def.radius = desc.radius;
    def.falloff = desc.falloff;
    def.impulse_per_area = desc.impulse_per_area;
    return b3::world_explode(self.world, def);
}

// box3d clears applied forces after every step, so persistent forces are applied before each one.
fn void apply_step_forces(PhysicsWorld* world) @private {
    world.scene.@each2(Wind, RigidBody; entity, wind, body) {
        foreach (&collider : body.colliders) {
            b3::shape_apply_wind(
                shape:     collider.shape,
                wind:      wind.velocity,
                drag:      wind.drag,
                lift:      wind.lift,
                max_speed: wind.max_speed,
                wake:      true,
            );
        }
    };
    world.scene.@each2(Force, RigidBody; entity, force, body) {
        Vec3 point = body.current.position + body.current.rotation.rotate_vec3(force.local_point);
        b3::body_apply_force(body.body, force.force, (b3::Pos)point, true);
    };
}
