module c3d::physics::cloth;

import c3d;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;

<*
 Where a prepared cloth solves.
*>
enum ClothExecution {
    CPU, // update_cloths solves and publishes it
    GPU, // c3d::render::cloth_gpu solves it; update_cloths prepares its inputs
}

struct ClothDeviceStep @private {
    Mat4  anchor;           // owner world matrix at the end of the previous request
    Mat4  target;           // owner world matrix at the end of this request
    Vec3  gravity;
    float step_seconds;     // fixed step length
    uint  steps;            // fixed steps the next device update solves; the update takes them
    Wind  wind;             // the owner's Wind at this request
    bool  wind_present;
    bool  rebase_reference; // a held skinned cloth starts its first step from the pose it wakes at
}

fn void? check_cloth_execution(
    ClothDesc* desc,
    ClothShape[] shapes,
) @private {
    if (desc.execution == ClothExecution.CPU) return;

    $if !$feat(C3D_PHYSICS_GPU):
        return c3d::UNSUPPORTED~;
    $else
        if (desc.bend_mode != ClothBendMode.DISTANCE) return c3d::UNSUPPORTED~;
        if (desc.collisions.self_collision || desc.collisions.continuous || desc.cuts.len) return c3d::UNSUPPORTED~;
        if (desc.tangent_frame || desc.seams.len || desc.render_particles.len) return c3d::UNSUPPORTED~;
        if (desc.sleep_speed != 0) return c3d::UNSUPPORTED~;
        if (shapes.len > 1 || (shapes.len == 1 && !point_sphere(&shapes[0]))) return c3d::UNSUPPORTED~;
    $endif
}

<*
 Whether the device can project every constraint set of the cloth.
*>
fn bool device_colors_fit(ClothState* state) @private {
    if (!state.edge_colors) return false;

    return state.desc.bend_stiffness == 0 || !state.bends.len || state.bend_colors != 0;
}

fn bool point_sphere(ClothShape* shape) @local {
    return shape.kind == ColliderKind.SPHERE && shape.start == shape.end;
}

// A held cloth follows its owner without carrying the device state.
fn void collect_device_cloth(PhysicsWorld* world, ClothState* state, Node* node, bool held) @private {
    ClothDeviceStep* device = &state.device;
    if (state.skinned && !follow_skinned_output(world, state, node)) {
        device.steps = 0;
        return;
    }
    if (held) {
        device.steps = 0;
        device.anchor = node.world;
        device.target = node.world;
        device.rebase_reference = state.skinned;
        world.cloth_stats.held++;
        return;
    }

    uint steps = world.steps_last_update;
    device.steps = steps;
    if (!steps) return;

    if (state.skinned && !sample_device_reference(world, state, node)) {
        device.steps = 0;
        return;
    }
    device.anchor = device.target;
    device.target = node.world;
    device.gravity = world.desc.tuning.gravity;
    device.step_seconds = world.desc.tuning.fixed_dt;

    Wind* wind = world.scene.get(node, Wind);
    device.wind_present = wind != null;
    if (wind) device.wind = *wind;
}

fn bool follow_skinned_output(PhysicsWorld* world, ClothState* state, Node* node) @local {
    state.contact_result = { .stage = ClothContactStage.PUBLICATION };
    if (catch excuse = check_ordinary_output_ownership(world.scene, state, node)) {
        deactivate_output_node(world.scene, state.output_node);
        state.contact_result.failure = excuse;
        world.cloth_stats.failed++;
        return false;
    }

    sync_skinned_output(world.scene, state, node);
    state.contact_result = {};
    return true;
}

// The previous request's reference becomes the solved one, as it does after a CPU solve.
fn bool sample_device_reference(PhysicsWorld* world, ClothState* state, Node* node) @local {
    state.solved_reference[..] = state.current_reference[..];
    state.contact_result = { .stage = ClothContactStage.REFERENCE };
    if (catch excuse = sample_ordinary_reference(
        scene:  world.scene,
        assets: world.assets,
        owner:  node,
        state:  state,
    )) {
        state.contact_result.failure = excuse;
        world.cloth_stats.failed++;
        return false;
    }

    if (state.device.rebase_reference) {
        state.solved_reference[..] = state.current_reference[..];
        state.device.rebase_reference = false;
    }
    state.contact_result = {};
    return true;
}
