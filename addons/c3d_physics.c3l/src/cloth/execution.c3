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
    Mat4  anchor;       // owner world matrix at the end of the previous request
    Mat4  target;       // owner world matrix at the end of this request
    Vec3  gravity;
    float step_seconds; // fixed step length
    uint  steps;        // fixed steps the next device update solves; the update takes them
}

fn void? check_cloth_execution(
    Scene* scene,
    Node* node,
    ClothDesc* desc,
    bool skinned,
    usz soft_count,
    ClothShape[] shapes,
) @private {
    if (desc.execution == ClothExecution.CPU) return;

    $if !$feat(C3D_PHYSICS_GPU):
        return c3d::UNSUPPORTED~;
    $else
        if (desc.bend_mode != ClothBendMode.DISTANCE || desc.bend_stiffness != 0) return c3d::UNSUPPORTED~;
        if (desc.collisions.self_collision || desc.collisions.continuous || desc.cuts.len) return c3d::UNSUPPORTED~;
        if (desc.tangent_frame || desc.seams.len || desc.render_particles.len) return c3d::UNSUPPORTED~;
        if (desc.sleep_speed != 0 || skinned || soft_count || scene.has(node, Wind)) return c3d::UNSUPPORTED~;
        if (shapes.len > 1 || (shapes.len == 1 && !point_sphere(&shapes[0]))) return c3d::UNSUPPORTED~;
        foreach (weight : desc.transport) {
            if (weight != 0) return c3d::UNSUPPORTED~;
        }
    $endif
}

fn bool point_sphere(ClothShape* shape) @local {
    return shape.kind == ColliderKind.SPHERE && shape.start == shape.end;
}

// A held cloth follows its owner without carrying the device state.
fn void collect_device_cloth(PhysicsWorld* world, ClothState* state, Node* node, bool held) @private {
    ClothDeviceStep* device = &state.device;
    if (held) {
        device.steps = 0;
        device.anchor = node.world;
        device.target = node.world;
        world.cloth_stats.held++;
        return;
    }

    uint steps = world.steps_last_update;
    device.steps = steps;
    if (!steps) return;

    device.anchor = device.target;
    device.target = node.world;
    device.gravity = world.desc.tuning.gravity;
    device.step_seconds = world.desc.tuning.fixed_dt;
}
