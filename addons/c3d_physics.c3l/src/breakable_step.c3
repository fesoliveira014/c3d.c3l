module c3d::physics;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;
import b3;

fn void prune_breakables(PhysicsWorld* world) @private {
    world.scene.@each(Breakable; Entity entity, Breakable* component) {
        prune_breakable(world, world.scene.node(entity), component.state);
    };
}

fn void prune_breakable(PhysicsWorld* world, Node* root, BreakableState* state) @private {
    Scene* scene = world.scene;
    uint alive;
    foreach (entity : state.pieces) if (scene.world.is_alive(entity)) alive++;
    if (alive == state.alive_pieces) return;
    state.alive_pieces = alive;

    foreach (&weld : state.welds) {
        if (weld.broken) continue;
        if (scene.world.is_alive(state.pieces[weld.piece_a])
            && scene.world.is_alive(state.pieces[weld.piece_b])) continue;
        if (weld.joint.is_valid()) b3::destroy_joint(weld.joint, true);
        weld.joint = {};
        weld.broken = true;
        state.alive_welds--;
    }

    if (state.form == ASSEMBLY && scene.has(root, PhysicsBody)) {
        PhysicsBody* authored = scene.get(root, PhysicsBody);
        RigidBody* body = scene.get(root, RigidBody);
        uint kept;
        for (uint index = 0; index < state.runtime.assembly_count; index++) {
            uint piece = state.runtime.assembly_pieces[index];
            if (!scene.world.is_alive(state.pieces[piece])) {
                if (body) {
                    b3::destroy_shape(body.colliders[index].shape, false);
                    release_snapshot(world.snapshots, body.colliders[index].snapshot);
                }
                continue;
            }
            authored.colliders[kept] = authored.colliders[index];
            if (body) body.colliders[kept] = body.colliders[index];
            state.runtime.assembly_pieces[kept++] = piece;
        }
        authored.colliders = authored.colliders[:kept];
        if (body) body.colliders = body.colliders[:kept];
        state.runtime.assembly_count = kept;
        if (!kept) world.remove_body(root);
    }
    if (!alive) state.status = LIVE;
}

fn void suspend_breakables(PhysicsWorld* world) @private {
    world.scene.@each(Breakable; Entity entity, Breakable* component) {
        BreakableState* state = component.state;
        destroy_breakable_welds(state);
        state.runtime.wake = {};
        state.status = PENDING;
        if (state.form == PIECES) {
            foreach (piece : state.pieces) {
                if (!world.scene.world.is_alive(piece)) continue;
                world.scene.get(world.scene.node(piece), PhysicsBody).body.disabled = true;
            }
        }
    };
}

fn void sync_breakables(PhysicsWorld* world) @private {
    world.scene.@each(Breakable; Entity entity, Breakable* component) {
        sync_breakable(world, world.scene.node(entity), component.state);
    };
}

fn void sync_breakable(PhysicsWorld* world, Node* root, BreakableState* state) @local {
    if (state.status != PENDING) return;
    if (!state.alive_pieces) {
        state.status = LIVE;
        return;
    }
    if (state.form == ASSEMBLY) {
        if (world.scene.has(root, RigidBody)) state.status = LIVE;
        return;
    }

    foreach (piece : state.pieces) {
        if (!world.scene.world.is_alive(piece)) continue;
        if (!world.scene.has(world.scene.node(piece), RigidBody)) return;
    }
    if (catch excuse = bind_breakable_welds(world, root, state)) {
        state.status = FAILED;
        state.failure = excuse;
        push_failure(world, root, excuse);
        return;
    }
    enable_breakable_pieces(world, state);
}

fn bool same_breakable_joint(b3::JointId first, b3::JointId second) @local {
    return first.index1 == second.index1 && first.world0 == second.world0 && first.generation == second.generation;
}

fn bool breakable_joint_event(PhysicsWorld* world, Node* root, b3::JointId joint) @private {
    Breakable* component = world.scene.get(root, Breakable);
    if (!component) return false;
    BreakableState* state = component.state;
    foreach (&weld : state.welds) {
        if (!same_breakable_joint(weld.joint, joint)) continue;
        if (weld.broken) return true;
        weld.broken = true;
        state.alive_welds--;

        if (world.break_count == world.break_storage.len) {
            world.dropped_events++;
            return true;
        }
        Node* first = world.scene.node(state.pieces[weld.piece_a]);
        Node* second = world.scene.node(state.pieces[weld.piece_b]);
        b3::BodyId body = world.scene.get(first, RigidBody).body;
        world.break_storage[world.break_count++] = {
            .root = root,
            .piece_a = first,
            .piece_b = second,
            .point = body.world_point(weld.anchor),
        };
        return true;
    }
    return false;
}

fn void collect_breakable_hit(PhysicsWorld* world, b3::ContactHitEvent event) @private {
    Node*? first = node_of(world, event.shape_id_a);
    Node*? second = node_of(world, event.shape_id_b);
    if (catch first) return;
    if (catch second) return;

    request_breakable_wake(
        world: world,
        root: first,
        visitor: event.shape_id_b.body(),
        point: event.point,
        direction: -event.normal,
        approach_speed: event.approach_speed,
    );
    request_breakable_wake(
        world: world,
        root: second,
        visitor: event.shape_id_a.body(),
        point: event.point,
        direction: event.normal,
        approach_speed: event.approach_speed,
    );
}

fn void request_breakable_wake(
    PhysicsWorld* world,
    Node* root,
    b3::BodyId visitor,
    Vec3 point,
    Vec3 direction,
    float approach_speed,
) @local {
    Breakable* component = world.scene.get(root, Breakable);
    if (!component) return;
    BreakableState* state = component.state;
    if (state.form != ASSEMBLY || state.status != LIVE || state.runtime.wake.pending) return;
    if (visitor.type() != b3::BodyType.DYNAMIC) return;
    if (visitor.mass() * approach_speed < state.desc.break_force * world.desc.tuning.fixed_dt) return;

    state.runtime.wake = {
        .visitor = visitor,
        .point = point,
        .direction = direction,
        .approach_speed = approach_speed,
        .pending = true,
    };
}

fn void finish_breakable_step(PhysicsWorld* world) @private {
    world.scene.@each(Breakable; Entity entity, Breakable* component) {
        BreakableState* state = component.state;
        foreach (&weld : state.welds) {
            if (!weld.broken) continue;
            if (weld.joint.is_valid()) b3::destroy_joint(weld.joint, true);
            weld.joint = {};
        }
        if (state.runtime.wake.pending) apply_breakable_wake(world, world.scene.node(entity), state);
    };
}

fn void apply_breakable_wake(PhysicsWorld* world, Node* root, BreakableState* state) @local {
    BreakableWake wake = state.runtime.wake;
    state.runtime.wake = {};
    b3::BodyId assembly = world.scene.get(root, RigidBody).body;
    b3::WorldTransform native_pose = assembly.transform();
    maths::Transform pose = { .position = native_pose.p, .rotation = native_pose.q, .scale = { 1, 1, 1 } };
    Vec3 assembly_velocity = assembly.world_point_velocity((b3::Pos)wake.point);
    if (catch excuse = swap_breakable_to_pieces(
        world: world,
        root: root,
        state: state,
        pose: pose,
    )) {
        push_failure(world, root, excuse);
        return;
    }

    Vec3 velocity = wake.visitor.linear_velocity();
    float closing = (wake.visitor.world_point_velocity((b3::Pos)wake.point) - assembly_velocity).dot(wake.direction);
    velocity += wake.direction * (wake.approach_speed - closing);
    wake.visitor.set_linear_velocity(velocity);
    wake.visitor.set_awake(true);
}

fn void? swap_breakable_to_pieces(
    PhysicsWorld* world,
    Node* root,
    BreakableState* state,
    maths::Transform pose,
) @private {
    if (!state.alive_pieces) {
        state.form = PIECES;
        return;
    }

    @pool() {
        maths::Transform[] poses = alloc::new_array(tmem, maths::Transform, state.pieces.len);
        foreach (index, frame : state.runtime.frames) {
            poses[index] = {
                .position = pose.position + pose.rotation.rotate_vec3(frame.position),
                .rotation = pose.rotation.mul(frame.rotation).normalize(),
                .scale = { 1, 1, 1 },
            };
        }
        b3::BodyId assembly = world.scene.get(root, RigidBody).body;
        build_breakable_pieces(
            world: world,
            state: state,
            poses: poses,
            assembly: assembly,
            assembly_pose: pose,
        )!;
        defer catch remove_breakable_piece_bodies(world, state);
        bind_breakable_welds(world, root, state)!;

        world.remove_body(root);
        state.runtime.assembly_count = 0;
        commit_breakable_pieces(world, state, poses);
    };
}
