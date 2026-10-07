module c3d::character;

import std::math;
import c3d;
import c3d::anim;
import c3d::maths;
import c3d::ecs;
import c3d::physics;
import c3d::scene;

<*
 Planes one move keeps; the mover solver's cost lever.
*>
const usz MAX_CHARACTER_PLANES = 16; // 16 * 48 bytes in every Character store slot; a corner touches three

<*
 Collide, solve and cast passes per fixed step.
*>
const uint CHARACTER_SOLVE_ITERATIONS = 4; // three slide passes per move; a step retry adds two raised passes

const float DEFAULT_RADIUS @local = 0.4f;
const float DEFAULT_HALF_HEIGHT @local = 0.6f; // a 2 m capsule with the default radius
const float DEFAULT_STEP_HEIGHT @local = 0.35f; // above a stair riser, below a knee-high ledge
const float DEFAULT_MAX_SLOPE_DEGREES @local = 50;
const float DEFAULT_SKIN @local = 0.005f; // one box3d linear slop; a thicker skin leaves a visible gap

<*
 Capsule and movement limits of a character.
*>
struct CharacterDesc {
    float           radius;
    float           half_height;        // capsule segment half length along world Y
    float           step_height;        // highest ledge climbed in one move
    float           max_slope_degrees;  // steeper planes are walls
    float           skin;               // gap kept between the capsule and every surface
    bool            push_bodies;        // carry a kinematic body that shoves bodies outside filter.mask
    CollisionFilter filter;             // mask: what the capsule collides with; category: the push body's shape
}

<*
 Kinematic capsule bound to a node; the system writes the node's position every update.
*>
struct Character {
    CharacterDesc                    desc;
    Vec3                             velocity;       // world space, after the last step
    Vec3                             desired;        // horizontal intent for the next steps
    bool                             grounded;
    Vec3                             ground_normal;
    Entity                           ground;         // node under the capsule; zero in the air
    Vec3                             previous;       // capsule center before the last step
    Vec3                             current;        // capsule center after the last step
    bool                             jump_requested;
    float                            jump_speed;
    MoverPlane[MAX_CHARACTER_PLANES] planes;         // gathered in the last step
    uint                             plane_count;
}

<*
 Characters of one physics world; owns the mover pass.
*>
struct CharacterSystem {
    Allocator       allocator;
    CharacterState* state;            // the pass context; one heap block
}

<*
 What the mover pass reads and counts.
*>
struct CharacterState {
    PhysicsWorld* world;
    Scene*        scene;
    uint          stepped;            // character steps in the last update
    uint          stepped_so_far;     // character steps of the update in progress
    float         elapsed_so_far;     // fixed steps of the update in progress, in seconds
}

<*
 Author a character on the node; with push_bodies, also a KINEMATIC PhysicsBody with one CAPSULE collider.
 The node origin is the capsule's lowest point.
 @param [&in] node : "Its world position is the initial feet position; update_world first."
 @return? CHARACTER_EXISTS, physics::BODY_EXISTS
 @require self.world.is_registered(Character), desc.radius > 0, desc.half_height > 0
*>
fn void? Scene.add_character(&self, Node* node, CharacterDesc desc) {
    if (self.has(node, Character)) return CHARACTER_EXISTS~;
    Vec3 center = node.world_position() + center_offset(desc);
    self.add(node, (Character){ .desc = desc, .previous = center, .current = center });
    if (!desc.push_bodies) return;

    defer catch self.remove_component(node, Character);
    ColliderDesc collider = push_collider(desc);
    self.add_physics_body(node, physics::default_body_desc(KINEMATIC), (&collider)[:1])!;
}

<*
 Replace the character's desc after add_character; keeps the feet and the motion.
 @param [&inout] node : "Carries the Character; its position is unchanged."
 @return? physics::BODY_EXISTS
 @require self.has(node, Character), desc.radius > 0, desc.half_height > 0
*>
fn void? Scene.set_character_desc(&self, Node* node, CharacterDesc desc) {
    CharacterDesc previous = self.get(node, Character).desc;
    if (desc.push_bodies && !previous.push_bodies) {
        ColliderDesc collider = push_collider(desc);
        self.add_physics_body(node, physics::default_body_desc(KINEMATIC), (&collider)[:1])!;
    } else if (!desc.push_bodies && previous.push_bodies && self.has(node, PhysicsBody)) {
        self.remove_component(node, PhysicsBody);
    } else if (desc.push_bodies && push_shape_changed(previous, desc) && self.has(node, PhysicsBody)) {
        PhysicsBody* body = self.get(node, PhysicsBody);
        body.colliders[0] = push_collider(desc);
        body.mark_changed();
    }

    Character* character = self.get(node, Character);
    Vec3 shift = center_offset(desc) - center_offset(previous);
    character.previous += shift;
    character.current += shift;
    character.desc = desc;
}

<*
 Remove the character and, when present, its push body.
 @require self.has(node, Character)
*>
fn void Scene.remove_character(&self, Node* node) {
    if (self.get(node, Character).desc.push_bodies && self.has(node, PhysicsBody)) {
        self.remove_component(node, PhysicsBody);
    }
    self.remove_component(node, Character);
}

<*
 Set the horizontal intent the next fixed steps use; the last call before a step wins.
 @require self.has(node, Character)
*>
fn void Scene.move_character(&self, Node* node, Vec3 desired_velocity) {
    self.get(node, Character).desired = desired_velocity;
}

<*
 Apply a root-motion turn and set horizontal mover intent.
 @param [&inout] node : "Current world matrix; authored facing changes now."
 @param delta : "Motion in this character node's local frame."
 @param dt : "Finite positive animation-update seconds."
 @require self.has(node, Character), dt > 0 && math::is_finite(dt)
*>
fn void Scene.move_character_root_motion(
    &self,
    Node* node,
    RootMotionDelta delta,
    float dt,
) {
    Vec3 velocity = maths::transform_dir(node.world, delta.translation) / dt;
    velocity.y = 0;
    self.move_character(node, velocity);

    node.local.rotation = node.local.rotation.mul(delta.rotation).normalize();
}

<*
 Launch the character upward on its next step when grounded; dropped in the air.
 @require self.has(node, Character)
*>
fn void Scene.jump_character(&self, Node* node, float speed) {
    Character* character = self.get(node, Character);
    character.jump_requested = true;
    character.jump_speed = speed;
}

<*
 Move the capsule without sweeping and write the node now.
 @param position : "The capsule's lowest point, as the node origin."
 @require self.has(node, Character)
*>
fn void Scene.teleport_character(&self, Node* node, Vec3 position) {
    Character* character = self.get(node, Character);
    Vec3 center = position + center_offset(character.desc);
    character.previous = center;
    character.current = center;
    // The old ground is behind; its velocity must not carry the next step.
    character.grounded = false;
    character.ground = {};
    character.plane_count = 0;
    node.set_world_position(position);
}

<*
 Default character: 0.4 m radius, 0.6 m half height, 0.35 m step, 50 degree slope, 5 mm skin, no push body.
*>
fn CharacterDesc default_character_desc() {
    return {
        .radius            = DEFAULT_RADIUS,
        .half_height       = DEFAULT_HALF_HEIGHT,
        .step_height       = DEFAULT_STEP_HEIGHT,
        .max_slope_degrees = DEFAULT_MAX_SLOPE_DEGREES,
        .skin              = DEFAULT_SKIN,
        .filter            = physics::FILTER_ALL,
    };
}

<*
 Register the Character component.
 @param [&inout] scene : "Gains the Character store."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? register_character(Scene* scene) {
    scene.register(Character)!;
}

<*
 System stepping every Character of the scene inside the world's fixed steps.
 The mover pass stays registered on the world until destroy_character_system.
 @param [&inout] world : "Receives the mover pass; outlives the system."
 @param [&in] scene : "Registered through register_character; the world's scene."
 @return? c3d::CAPACITY_EXCEEDED
 @require world.mover_pass.step == null
*>
fn CharacterSystem? create_character_system(Allocator allocator, PhysicsWorld* world, Scene* scene) {
    CharacterState*? state = alloc::new_try(allocator, CharacterState, { .world = world, .scene = scene });
    if (catch state) return c3d::CAPACITY_EXCEEDED~;
    world.set_mover_pass({ .step = &step_characters, .write = &write_characters, .context = state });
    return { .allocator = allocator, .state = state };
}

<*
 Remove the mover pass, then free the state.
 @param [&inout] system : "Left zeroed."
*>
fn void destroy_character_system(CharacterSystem* system) {
    system.state.world.set_mover_pass({});
    alloc::free(system.allocator, system.state);
    *system = {};
}

fn Vec3 center_offset(CharacterDesc desc) @private => { 0, desc.half_height + desc.radius, 0 };

fn ColliderDesc push_collider(CharacterDesc desc) @private {
    ColliderDesc collider = physics::default_collider_desc(CAPSULE);
    collider.local.position = center_offset(desc);
    collider.radius = desc.radius;
    collider.half_height = desc.half_height;
    // The capsule stops short of everything its mask names, so the push body touches all categories to shove the rest.
    collider.filter = { .category = desc.filter.category, .mask = ulong::max, .group = desc.filter.group };
    return collider;
}

fn bool push_shape_changed(CharacterDesc previous, CharacterDesc desc) @local {
    return previous.radius != desc.radius || previous.half_height != desc.half_height
        || previous.filter.category != desc.filter.category || previous.filter.group != desc.filter.group;
}
