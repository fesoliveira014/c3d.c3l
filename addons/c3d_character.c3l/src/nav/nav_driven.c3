module c3d::character @feat(C3D_CHARACTER_NAV);

import std::math;
import c3d::ecs;
import c3d::maths;
import c3d::nav;
import c3d::physics;
import c3d::scene;

<*
 Marker: the node's crowd agent steers this character.
*>
struct NavDriven {
    AgentAnimation traversal;    // the agent's off-mesh traversal, copied by drive_characters
}

<*
 Hand the node's steering to its crowd agent; drive_characters writes Character.desired from then on.
 @return? NAV_DRIVEN_EXISTS, NO_NAV_AGENT
 @require self.has(node, Character), self.world.is_registered(NavDriven)
*>
fn void? Scene.add_nav_driven(&self, Node* node) {
    if (self.has(node, NavDriven)) return NAV_DRIVEN_EXISTS~;
    NavAgent* agent = self.get(node, NavAgent);
    if (!agent) return NO_NAV_AGENT~;
    agent.driven = true;
    agent.mark_changed();
    self.add(node, (NavDriven){});
}

<*
 Return the node's steering to the application and stop it; the agent keeps planning.
 @require self.has(node, NavDriven)
*>
fn void Scene.remove_nav_driven(&self, Node* node) {
    self.remove_component(node, NavDriven);
    NavAgent* agent = self.get(node, NavAgent);
    if (agent) {
        agent.driven = false;
        agent.mark_changed();
    }
    Character* character = self.get(node, Character);
    if (character) character.desired = {};
}

<*
 Register the NavDriven component.
 @param [&inout] scene : "Gains the NavDriven store."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_nav_driven(Scene* scene) {
    scene.register(NavDriven)!;
}

<*
 Copy each driven agent's velocity and traversal into its character.
 Call after crowd_update and before physics.update.
 @param [&inout] scene : "Registered through register_character and register_nav_driven."
 @param [&in] crowd : "The crowd crowd_update stepped this frame."
 @require scene.world.is_registered(NavDriven), scene.world.is_registered(CrowdAgentRuntime)
*>
fn void drive_characters(Scene* scene, Crowd* crowd) {
    scene.@each2(NavDriven, Character; entity, driven, character) {
        CrowdAgentRuntime* runtime = scene.world.get(entity, CrowdAgentRuntime);
        CrowdAgent* agent = runtime ? crowd.agent(runtime.index) : null;
        if (agent && agent.state != INVALID) {
            character.desired = { agent.velocity.x, 0, agent.velocity.z };
            driven.traversal = crowd.animations[runtime.index];
        } else {
            character.desired = {};
            driven.traversal = {};
        }
    };
}

fn void shift_nav_driven(Scene* scene, Vec3 offset) @private {
    scene.@each(NavDriven; Entity entity, NavDriven* driven) {
        driven.traversal.initial_position -= offset;
        driven.traversal.start -= offset;
        driven.traversal.end -= offset;
    };
}

// The steps of an update run ahead of the crowd's clock by their elapsed time, so the update's last step lands on
// the crowd's next t and the clamp holds the capsule at the end until the crowd ends the traversal.
fn bool traverse_off_mesh(
    PhysicsWorld* world,
    Scene* scene,
    Node* node,
    Character* character,
    float elapsed,
    float fixed_dt,
) @private {
    NavDriven* driven = scene.get(node, NavDriven);
    if (!driven || !driven.traversal.active) return false;

    AgentAnimation* traversal = &driven.traversal;
    Vec3 feet = traversal.position_at(math::min(traversal.t + elapsed, traversal.t_max));
    character.previous = character.current;
    character.current = feet + center_offset(character.desc);
    character.velocity = (character.current - character.previous) / fixed_dt;
    if (character.desc.push_bodies) {
        (void)world.set_kinematic_target(
            node:     node,
            position: feet,
            rotation: maths::transform_from_mat4(node.world).rotation,
        );
    }
    return true;
}
