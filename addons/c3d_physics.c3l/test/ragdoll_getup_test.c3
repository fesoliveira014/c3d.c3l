module c3d_physics_getup_test;

import std::io;
import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::maths;
import c3d::physics;
import c3d::physics::getup_fixture;
import c3d::scene;
import b3;

const float POSITION_TOLERANCE @private = 0.00002f;
const float ANGLE_TOLERANCE @private = 0.0001f;
const float CAP_TOLERANCE @private = 0.0001f;

struct Observation @private {
    float position;
    float angle;
    float penetration;
    float force;
    float torque;
    float tracking_position;
    float tracking_angle;
    float completion_time;
    uint contacts;
    uint steps;
    uint zero_updates;
    uint multiple_updates;
}

fn float rotation_distance(Quaternionf first, Quaternionf second) @private {
    Quaternionf difference = first.mul(second.conjugate()).normalize();
    if (difference.l < 0) difference = -difference;
    Vec3 vector = { difference.i, difference.j, difference.k };
    return 2 * math::atan2(vector.length(), difference.l);
}

fn void observe(
    PhysicsWorld* world,
    Humanoid* humanoid,
    Ragdoll* ragdoll,
    Observation* observation,
) @private {
    foreach (index, node : ragdoll.bone_nodes) {
        b3::BodyId body = world.body(node)!!;
        b3::WorldTransform native = body.transform();
        assert(b3::is_valid_world_transform(native));
        Vec3 mapped_position = body.world_point(ragdoll.joint_in_bone[index].position);
        Quaternionf mapped_rotation = native.q.mul(ragdoll.joint_in_bone[index].rotation).normalize();
        maths::Transform visible = maths::transform_from_mat4(humanoid.joints[ragdoll.bone_joints[index]].world);
        maths::Transform bone = maths::transform_from_mat4(node.world);
        observation.position = math::max(observation.position,
            (visible.position - mapped_position).length(), (bone.position - (Vec3)native.p).length());
        observation.angle = math::max(observation.angle,
            rotation_distance(visible.rotation, mapped_rotation), rotation_distance(bone.rotation, native.q));
        b3::ContactData[32] storage;
        foreach (contact : body.contact_data(storage[..])) {
            foreach (&manifold : contact.contact_manifolds()) {
                foreach (point : manifold.contact_points()) {
                    observation.contacts++;
                    observation.penetration = math::max(observation.penetration, -point.separation);
                }
            }
        }
    }
    RagdollRecoveryStatus status = ragdoll.recovery_status();
    observation.force = math::max(observation.force, status.force);
    observation.torque = math::max(observation.torque, status.torque);
    observation.tracking_position = math::max(observation.tracking_position, status.position_error);
    observation.tracking_angle = math::max(observation.tracking_angle, status.angle_error);
}

fn void run_getup(RagdollFacing facing, bool obstructed = false) @private {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    PhysicsWorld world = physics::create_physics_world(
        allocator: mem,
        assets: &assets,
        scene: &scene,
        desc: physics::default_physics_desc(),
    )!!;
    defer physics::destroy_physics_world(&world);
    Node* ground = scene.add_node(name: "ground")!!;
    ground.local.position = { 0, -0.5f, 0 };
    ColliderDesc floor = physics::default_collider_desc(BOX);
    floor.half_extents = { 10, 0.5f, 10 };
    scene.add_physics_body(ground, physics::default_body_desc(STATIC), (&floor)[:1])!!;
    if (obstructed) {
        Node* ceiling = scene.add_node(name: "blocker")!!;
        ceiling.local.position = { 0, 1.25f, 0 };
        ColliderDesc blocker = physics::default_collider_desc(BOX);
        blocker.half_extents = { 2, 0.15f, 2 };
        scene.add_physics_body(ceiling, physics::default_body_desc(STATIC), (&blocker)[:1])!!;
    }
    Humanoid humanoid = getup_fixture::create_humanoid(&assets, &scene)!!;
    getup_fixture::sample_getup(&humanoid, facing, 0);
    scene.update_world();
    world.update(0);
    Ragdoll* ragdoll = scene.get(humanoid.skin, Ragdoll);
    world.set_ragdoll_mode(humanoid.skin, SIMULATED);
    ragdoll.weight = 1;
    world.update_ragdolls();
    scene.update_world();
    assert(world.recover_ragdoll(humanoid.skin, humanoid.character)!! == facing);
    b3::BodyId[getup_fixture::BONE_COUNT] identities;
    b3::JointId[getup_fixture::BONE_COUNT] joint_identities;
    foreach (index, node : ragdoll.bone_nodes) {
        if (index > 0) joint_identities[index] = world.joint(node)!!;
    }
    foreach (index, node : ragdoll.bone_nodes) identities[index] = world.body(node)!!;
    Observation observation;
    float time;
    uint frame;
    bool completed;
    while (time < getup_fixture::DURATION) {
        float dt = getup_fixture::FRAME_MULTIPLIERS[frame++ % getup_fixture::FRAME_MULTIPLIERS.len] * physics::DEFAULT_FIXED_DT;
        time += dt;
        getup_fixture::sample_getup(&humanoid, facing, time);
        ragdoll.weight = math::max(1 - time / getup_fixture::SOURCE_FADE_TIME, 0.0f);
        scene.update_world();
        world.update(dt);
        if (!completed) {
            observation.steps += world.steps_last_update;
            if (world.steps_last_update == 0) observation.zero_updates++;
            if (world.steps_last_update > 1) observation.multiple_updates++;
        }
        bool completing;
        if (!completed && time >= getup_fixture::STANDING_TIME) {
            if (try world.finish_ragdoll_recovery(humanoid.skin)) {
            completed = true;
            completing = true;
            observation.completion_time = time;
            }
        }
        world.update_ragdolls();
        scene.update_world();
        if (!completed || completing) {
            observe(world: &world, humanoid: &humanoid, ragdoll: ragdoll, observation: &observation);
            world.update_ragdolls();
            scene.update_world();
            observe(world: &world, humanoid: &humanoid, ragdoll: ragdoll, observation: &observation);
            foreach (index, node : ragdoll.bone_nodes) {
                b3::BodyId body = world.body(node)!!;
                assert(body.index1 == identities[index].index1 && body.generation == identities[index].generation);
                assert(body.type() == (completing ? b3::BodyType.KINEMATIC : b3::BodyType.DYNAMIC));
                if (index > 0) {
                    b3::JointId joint = world.joint(node)!!;
                    assert(joint.index1 == joint_identities[index].index1 && joint.generation == joint_identities[index].generation);
                }
            }
        }
    }
    io::printfn(
        "getup,%s,blocked=%s,position=%.9f,angle=%.9f,penetration=%.9f,force=%.6f,torque=%.6f,tracking_position=%.6f,tracking_angle=%.6f,completion=%.6f,contacts=%d,steps=%d,zero=%d,multi=%d",
        facing,
        obstructed,
        observation.position,
        observation.angle,
        observation.penetration,
        observation.force,
        observation.torque,
        observation.tracking_position,
        observation.tracking_angle,
        observation.completion_time,
        observation.contacts,
        observation.steps,
        observation.zero_updates,
        observation.multiple_updates,
    );
    assert(observation.position <= POSITION_TOLERANCE && observation.angle <= ANGLE_TOLERANCE);
    assert(observation.force <= 200 + CAP_TOLERANCE && observation.torque <= 20 + CAP_TOLERANCE);
    assert(observation.penetration <= getup_fixture::PENETRATION_LIMIT);
    assert(observation.contacts > 0 && observation.zero_updates > 0 && observation.multiple_updates > 0);
    if (obstructed) {
        assert(!completed && ragdoll.recovery_status().phase == RagdollRecoveryPhase.BLOCKED);
        assert(@catch(world.finish_ragdoll_recovery(humanoid.skin)) == physics::RECOVERY_NOT_READY);
    } else {
        assert(completed);
        assert(ragdoll.recovery_status().phase == RagdollRecoveryPhase.INACTIVE);
        foreach (mode : ragdoll.bone_modes) assert(mode == ANIMATED);
    }
}

fn void test_supine_humanoid_recovers_through_shared_keys() @test { run_getup(FACE_UP); }
fn void test_prone_humanoid_recovers_through_shared_keys() @test { run_getup(FACE_DOWN); }
fn void test_obstructed_humanoid_remains_physical_and_incomplete() @test { run_getup(FACE_UP, true); }
