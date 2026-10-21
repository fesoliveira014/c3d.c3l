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

<*
 Most collider shapes a device cloth contacts at once.
*>
const uint MAX_DEVICE_SHAPES = 32; // 3 KiB of ring per step at 96 B a shape; more faults CAPACITY_EXCEEDED from the device update

<*
 Where one sphere or capsule of a listed owner stands at the start and the end of a request.
*>
struct ClothDeviceShape @private {
    maths::Transform solved;  // pose of the owner at the start of the request
    maths::Transform current; // pose of the owner at its end
    Vec3             start;   // owner-local end points of the segment; a sphere has both at its center
    Vec3             end;
    float            reach;   // radius and the contact offset
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
    uint  shape_count;      // shapes of the request; only the first MAX_DEVICE_SHAPES are stored
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
        foreach (&shape : shapes) {
            if (!device_shape_kind(shape.kind)) return c3d::UNSUPPORTED~;
        }
    $endif
}

fn bool device_colors_fit(ClothState* state) @private {
    if (!state.edge_colors) return false;

    return state.desc.bend_stiffness == 0 || !state.bends.len || state.bend_colors != 0;
}

fn bool device_shape_kind(ColliderKind kind) @local {
    switch (kind) {
        case SPHERE:
        case CAPSULE:
            return true;
        case BOX:
        case HULL:
        case MESH:
        case HEIGHT_FIELD:
        case COMPOUND:
            return false;
    }
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
    if (!sample_device_shapes(world, state)) {
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

// The shapes are captured into the staged storage first, so a rebinding is told from the committed shapes.
fn bool sample_device_shapes(PhysicsWorld* world, ClothState* state) @local {
    ClothDeviceStep* device = &state.device;
    device.shape_count = 0;
    if (!state.bodies.len) return true;

    ClothShape[] committed = state.shapes;
    ClothShape[] storage = state.shape_storage;
    state.shape_storage = state.staged_shapes;
    state.contact_result = { .stage = ClothContactStage.BINDINGS };
    if (catch excuse = capture_device_shapes(world, state)) {
        state.shape_storage = storage;
        state.shapes = committed;
        state.contact_result.failure = excuse;
        world.cloth_stats.failed++;
        return false;
    }

    ClothShape[] refreshed = state.shapes;
    state.shape_storage = storage;
    state.shapes = storage[:refreshed.len];
    state.shapes[..] = refreshed[..];
    finish_body_poses(state);
    state.contact_result = {};
    return true;
}

fn void? capture_device_shapes(PhysicsWorld* world, ClothState* state) @local {
    refresh_colliders(world, state)!;
    sample_bodies(world.scene, state);

    ClothDeviceStep* device = &state.device;
    foreach (&shape : state.shapes) {
        ClothBody* body = &state.bodies[shape.body];
        if (!body.live) continue;
        if (!device_shape_kind(shape.kind)) return c3d::UNSUPPORTED~;

        if (device.shape_count < state.device_shapes.len) {
            Mat4 local = shape.local.to_mat4();
            state.device_shapes[device.shape_count] = {
                .solved  = body.solved,
                .current = body.current,
                .start   = maths::transform_point(local, shape.start),
                .end     = maths::transform_point(local, shape.end),
                .reach   = shape.radius + state.desc.thickness,
            };
        }
        device.shape_count++;
    }
}
