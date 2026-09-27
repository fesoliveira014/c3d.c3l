module c3d::character;

import std::math;
import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::physics;
import c3d::scene;

const uint STEP_RETRY_PASSES @local = 1; // the raised capsule slides once; a second obstacle ends the climb

struct CharacterQuery @local {
    PhysicsWorld*   world;
    Entity          node;              // rejected by every query, so the push body never blocks its own capsule
    CollisionFilter filter;
    float           half_height;
    float           radius;            // capsule radius plus skin
    float           skin;
    float           walkable_normal_y;
}

fn void step_characters(void* context, PhysicsWorld* world, float fixed_dt) @private {
    CharacterState* state = context;
    Scene* scene = state.scene;
    state.elapsed_so_far += fixed_dt;
    scene.@each(Character; entity, character) {
        step_character(
            world:     world,
            node:      scene.node(entity),
            character: character,
            fixed_dt:  fixed_dt,
        );
        state.stepped_so_far++;
    };
}

fn void write_characters(void* context, PhysicsWorld* world, float alpha) @private {
    CharacterState* state = context;
    Scene* scene = state.scene;
    scene.@each(Character; entity, character) {
        Vec3 center = character.previous + (character.current - character.previous) * alpha;
        scene.node(entity).set_world_position(center - center_offset(character.desc));
    };
    state.stepped = state.stepped_so_far;
    state.stepped_so_far = 0;
    state.elapsed_so_far = 0;
}

fn void step_character(
    PhysicsWorld* world,
    Node* node,
    Character* character,
    float fixed_dt,
) @local {
    CharacterDesc desc = character.desc;
    character.previous = character.current;
    character.velocity.x = character.desired.x;
    character.velocity.z = character.desired.z;
    if (character.grounded) {
        character.velocity.y = 0;
    } else {
        character.velocity.y += world.desc.tuning.gravity.y * fixed_dt;
    }
    if (character.jump_requested && character.grounded) {
        character.velocity.y = character.jump_speed;
        character.grounded = false;
    }
    character.jump_requested = false;
    bool started_grounded = character.grounded;
    Vec3 target = character.current + (character.velocity + ground_carry(world, character)) * fixed_dt;

    CharacterQuery query = {
        .world             = world,
        .node              = node.id,
        .filter            = desc.filter,
        .half_height       = desc.half_height,
        .radius            = desc.radius + desc.skin,
        .skin              = desc.skin,
        .walkable_normal_y = (float)math::cos(math::deg_to_rad(desc.max_slope_degrees)),
    };
    character.plane_count = slide(
        query:    &query,
        position: &character.current,
        target:   target,
        planes:   character.planes[..],
        passes:   CHARACTER_SOLVE_ITERATIONS - STEP_RETRY_PASSES,
    );
    bool climbed = started_grounded
        && horizontal_length(target - character.current) > desc.skin
        && step_up(&query, character, target);
    character.velocity = physics::clip_vector(character.velocity, character.planes[:character.plane_count]);
    if (!climbed) update_ground(character, query.walkable_normal_y);
    if (started_grounded && !character.grounded) snap_down(&query, character);

    if (desc.push_bodies) {
        // NO_BODY until sync_bodies builds the push body, or after the application removed it.
        (void)world.set_kinematic_target(
            node:     node,
            position: character.current - center_offset(desc),
            rotation: maths::transform_from_mat4(node.world).rotation,
        );
    }
}

fn Vec3 ground_carry(PhysicsWorld* world, Character* character) @local {
    if (!character.grounded || !world.scene.world.is_alive(character.ground)) return {};
    return world.point_velocity(world.scene.node(character.ground), character.current) ?? (Vec3){};
}

fn uint slide(
    CharacterQuery* query,
    Vec3* position,
    Vec3 target,
    MoverPlane[] planes,
    uint passes,
) @local {
    uint plane_count;
    for (uint pass = 0; pass < passes; pass++) {
        plane_count = collide(query, *position, planes);
        flatten_steep_planes(planes[:plane_count], query.walkable_normal_y);
        MoverSolve solve = physics::solve_planes(target - *position, planes[:plane_count]);
        Vec3 moved = cast(query, *position, solve.delta);
        *position += moved;
        if (moved.length_sq() < query.skin * query.skin) break;
    }
    return plane_count;
}

// A capsule meets a ledge about a radius short of its center: a probe a radius further tells a step from a steep
// face, and a kept retry may rest on the edge, grounded on any upward contact, until the contact turns walkable.
fn bool step_up(CharacterQuery* query, Character* character, Vec3 target) @local {
    CharacterDesc desc = character.desc;
    Vec3 blocked = character.current;
    Vec3 raised = blocked + cast(query, blocked, { 0, desc.step_height, 0 });
    float drop = raised.y - blocked.y + query.skin;
    float highest_step = blocked.y - desc.half_height - desc.radius + desc.step_height;
    Vec3 remainder = { target.x - blocked.x, 0, target.z - blocked.z };

    MoverPlane[MAX_CHARACTER_PLANES] planes;
    Vec3 probe = raised_move(
        query:      query,
        raised:     raised,
        horizontal: remainder + remainder.normalize() * desc.radius,
        drop:       drop,
        planes:     planes[..],
    );
    uint plane_count = collide(query, probe, planes[..]);
    if (!has_walkable_plane(planes[:plane_count], query.walkable_normal_y, highest_step)) return false;

    Vec3 retry = raised_move(
        query:      query,
        raised:     raised,
        horizontal: remainder,
        drop:       drop,
        planes:     planes[..],
    );
    if (horizontal_length(target - retry) >= horizontal_length(target - blocked) - query.skin) return false;
    plane_count = collide(query, retry, planes[..]);
    if (!supported_within(planes[:plane_count], highest_step)) return false;

    character.current = retry;
    character.planes[:plane_count] = planes[:plane_count];
    character.plane_count = plane_count;
    update_ground(character, 0);
    flatten_steep_planes(character.planes[:plane_count], query.walkable_normal_y);
    return true;
}

// Grounded steps hold velocity.y at zero, so without the snap a downhill walk or a low step launches the capsule.
fn void snap_down(CharacterQuery* query, Character* character) @local {
    float reach = character.desc.step_height + query.skin;
    Vec3 snapped = character.current + cast(query, character.current, { 0, -reach, 0 });
    MoverPlane[MAX_CHARACTER_PLANES] planes;
    uint plane_count = collide(query, snapped, planes[..]);
    if (!has_walkable_plane(planes[:plane_count], query.walkable_normal_y, float::max)) return;

    character.current = snapped;
    character.planes[:plane_count] = planes[:plane_count];
    character.plane_count = plane_count;
    flatten_steep_planes(character.planes[:plane_count], query.walkable_normal_y);
    update_ground(character, query.walkable_normal_y);
}

fn Vec3 raised_move(
    CharacterQuery* query,
    Vec3 raised,
    Vec3 horizontal,
    float drop,
    MoverPlane[] planes,
) @local {
    Vec3 position = raised;
    slide(
        query:    query,
        position: &position,
        target:   raised + horizontal,
        planes:   planes,
        passes:   STEP_RETRY_PASSES,
    );
    return position + cast(query, position, { 0, -drop, 0 });
}

fn uint collide(CharacterQuery* query, Vec3 center, MoverPlane[] planes) @local {
    usz count = query.world.collide_mover(
        capsule:    query_capsule(query, center),
        out_planes: planes,
        filter:     query.filter,
        accept:     &accept_other_nodes,
        context:    &query.node,
    );
    return (uint)count;
}

fn Vec3 cast(CharacterQuery* query, Vec3 center, Vec3 translation) @local {
    float fraction = query.world.cast_mover(
        capsule:     query_capsule(query, center),
        translation: translation,
        filter:      query.filter,
        accept:      &accept_other_nodes,
        context:     &query.node,
    );
    return translation * fraction;
}

fn MoverCapsule query_capsule(CharacterQuery* query, Vec3 center) @local {
    return { .center = center, .half_height = query.half_height, .radius = query.radius };
}

fn bool accept_other_nodes(Entity entity, void* context) @local {
    return !c3d::same_id(entity, *(Entity*)context);
}

// A steep plane solved as it is turns horizontal input into climbing; as a vertical wall it only blocks.
fn void flatten_steep_planes(MoverPlane[] planes, float walkable_normal_y) @local {
    foreach (&plane : planes) {
        if (plane.normal.y <= 0 || plane.normal.y >= walkable_normal_y) continue;
        Vec3 horizontal = { plane.normal.x, 0, plane.normal.z };
        float length = horizontal.length();
        plane.normal = horizontal / length;
        plane.offset /= length;
    }
}

fn bool has_walkable_plane(MoverPlane[] planes, float walkable_normal_y, float highest_contact) @local {
    foreach (&plane : planes) {
        if (plane.normal.y >= walkable_normal_y && plane.point.y <= highest_contact) return true;
    }
    return false;
}

fn bool supported_within(MoverPlane[] planes, float highest_contact) @local {
    bool supported;
    foreach (&plane : planes) {
        if (plane.normal.y <= 0) continue;
        if (plane.point.y > highest_contact) return false;
        supported = true;
    }
    return supported;
}

fn void update_ground(Character* character, float min_normal_y) @local {
    character.grounded = false;
    character.ground = {};
    character.ground_normal = {};
    foreach (&plane : character.planes[:character.plane_count]) {
        if (plane.normal.y < min_normal_y || plane.normal.y <= character.ground_normal.y) continue;
        character.grounded = true;
        character.ground = plane.entity;
        character.ground_normal = plane.normal;
    }
}

fn float horizontal_length(Vec3 vector) @local => math::sqrt(vector.x * vector.x + vector.z * vector.z);
