module c3d::physics;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;
import b3;

struct BreakableReaction @private {
    BreakableStrength loads;
    BreakCriterion criterion;
    bool matched;
}

fn void prune_breakables(PhysicsWorld* world) @private {
    world.scene.@each(Breakable; Entity entity, Breakable* component) {
        prune_breakable(world, world.scene.node(entity), component.state);
    };
}

fn void prune_breakable(PhysicsWorld* world, Node* root, BreakableState* state) @private {
    Scene* scene = world.scene;
    foreach (&anchor : state.runtime.anchors) {
        if (anchor.pruned) continue;
        if (scene.world.is_alive(state.pieces[anchor.authored.piece]) && scene.world.is_alive(anchor.authored.target)) continue;
        if (anchor.joint.is_valid()) b3::destroy_joint(anchor.joint, true);
        anchor.joint = {};
        anchor.pruned = true;
        if (!anchor.broken) state.alive_anchors--;
    }
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

    if (state.runtime.prepared && state.form == ASSEMBLY && scene.has(root, PhysicsBody)) {
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
        if (state.runtime.prepared) {
            destroy_breakable_welds(state);
            foreach (&owner : state.runtime.bodies) owner.body = {};
            state.runtime.wake = {};
            state.status = PENDING;
            if (state.form == PIECES) {
                foreach (piece : state.pieces) {
                    if (!world.scene.world.is_alive(piece)) continue;
                    world.scene.get(world.scene.node(piece), PhysicsBody).body.disabled = true;
                }
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
    if (!state.runtime.prepared) return;
    if (!state.alive_pieces) {
        state.status = LIVE;
        return;
    }
    if (state.form == ASSEMBLY) {
        if (state.status != LIVE && world.scene.has(root, RigidBody)) {
            if (catch excuse = refresh_breakable_body_owner(
                world: world,
                state: state,
                node: root,
                index: (uint)state.pieces.len,
            )) {
                fail_breakable_binding(
                    world: world,
                    root: root,
                    state: state,
                    excuse: excuse,
                );
                return;
            }
            state.status = LIVE;
            state.failure = {};
        }
        return;
    }

    if (state.status != LIVE) {
        foreach (uint index, piece : state.pieces) {
            if (!world.scene.world.is_alive(piece)) continue;
            Node* node = world.scene.node(piece);
            if (!world.scene.has(node, RigidBody)) return;
            if (catch excuse = refresh_breakable_body_owner(
                world: world,
                state: state,
                node: node,
                index: index,
            )) {
                fail_breakable_binding(
                    world: world,
                    root: root,
                    state: state,
                    excuse: excuse,
                );
                return;
            }
        }
        if (catch excuse = bind_breakable_welds(
            world: world,
            root: root,
            state: state,
            require_anchors: false,
        )) {
            fail_breakable_binding(
                world: world,
                root: root,
                state: state,
                excuse: excuse,
            );
            return;
        }
        enable_breakable_pieces(world, state);
        state.failure = {};
    }
    sync_breakable_anchors(world, root, state);
}

fn bool same_breakable_joint(b3::JointId first, b3::JointId second) @private {
    return first.index1 == second.index1 && first.world0 == second.world0 && first.generation == second.generation;
}

fn bool same_breakable_body(b3::BodyId first, b3::BodyId second) @private {
    return first.index1 == second.index1 && first.world0 == second.world0 && first.generation == second.generation;
}

fn void? refresh_breakable_body_owner(
    PhysicsWorld* world,
    BreakableState* state,
    Node* node,
    uint index,
) @local {
    BreakableBodyOwner* owner = &state.runtime.bodies[index];
    PhysicsBody* authored = world.scene.get(node, PhysicsBody);
    RigidBody* body = world.scene.get(node, RigidBody);
    if (!authored || authored.colliders.ptr != owner.colliders || !body || !body.body.is_valid()) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (owner.body.index1 && !same_breakable_body(owner.body, body.body)) return c3d::INVALID_ARGUMENT~;
    owner.body = body.body;
}

fn void fail_breakable_binding(
    PhysicsWorld* world,
    Node* root,
    BreakableState* state,
    fault excuse,
) @local {
    if (state.status != FAILED || state.failure != excuse) push_failure(world, root, excuse);
    state.status = FAILED;
    state.failure = excuse;
}

fn void sync_breakable_anchors(PhysicsWorld* world, Node* root, BreakableState* state) @local {
    foreach (&anchor : state.runtime.anchors) {
        if (anchor.broken || anchor.pruned) continue;
        if (catch excuse = sync_breakable_anchor(
            world: world,
            root: root,
            state: state,
            anchor: anchor,
        )) {
            if (anchor.joint.is_valid()) b3::destroy_joint(anchor.joint, true);
            anchor.joint = {};
            if (anchor.failure != excuse) push_failure(world, root, excuse);
            anchor.failure = excuse;
        } else {
            anchor.failure = {};
        }
    }
}

fn void? sync_breakable_anchor(
    PhysicsWorld* world,
    Node* root,
    BreakableState* state,
    BreakableAnchor* anchor,
) @local {
    b3::BodyId target = breakable_anchor_target(world, anchor.authored.target)!;
    Node* piece = world.scene.node(state.pieces[anchor.authored.piece]);
    RigidBody* body = world.scene.get(piece, RigidBody);
    if (!body || !same_breakable_body(body.body, state.runtime.bodies[anchor.authored.piece].body)) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (anchor.joint.is_valid()) {
        if (same_breakable_body(anchor.joint.body_a(), body.body)
            && same_breakable_body(anchor.joint.body_b(), target)) return;
        b3::destroy_joint(anchor.joint, true);
        anchor.joint = {};
    }
    anchor.joint = create_breakable_weld(
        world: world,
        root: root.id,
        body_a: body.body,
        body_b: target,
        frame_a: anchor.authored.frame_a,
        frame_b: anchor.authored.frame_b,
        strength: anchor.strength,
        evaluation: state.evaluation,
    )!;
}

fn bool breakable_joint_event(PhysicsWorld* world, Node* root, b3::JointId joint) @private {
    Breakable* component = world.scene.get(root, Breakable);
    if (!component) return false;
    BreakableState* state = component.state;
    foreach (uint index, &weld : state.welds) {
        if (!same_breakable_joint(weld.joint, joint)) continue;
        if (weld.broken) return true;
        weld.broken = true;
        state.alive_welds--;

        push_breakable_event(
            world: world,
            root: root,
            first: state.pieces[weld.piece_a],
            second: state.pieces[weld.piece_b],
            joint: joint,
            frame: weld.frame_a,
            kind: INTERNAL_WELD,
            index: index,
            limits: weld.strength,
            reaction: {},
            phase: NATIVE_THRESHOLD,
        );
        return true;
    }
    foreach (uint index, &anchor : state.runtime.anchors) {
        if (!same_breakable_joint(anchor.joint, joint)) continue;
        if (anchor.broken || anchor.pruned) return true;
        anchor.broken = true;
        state.alive_anchors--;
        push_breakable_event(
            world: world,
            root: root,
            first: state.pieces[anchor.authored.piece],
            second: anchor.authored.target,
            joint: joint,
            frame: anchor.authored.frame_a,
            kind: ANCHOR,
            index: index,
            limits: anchor.strength,
            reaction: {},
            phase: NATIVE_THRESHOLD,
        );
        return true;
    }
    return false;
}

fn void sample_breakables(PhysicsWorld* world) @private {
    world.scene.@each(Breakable; Entity entity, Breakable* component) {
        sample_breakable(world, world.scene.node(entity), component.state);
    };
}

fn void sample_breakable(PhysicsWorld* world, Node* root, BreakableState* state) @local {
    if (!state.runtime.prepared || state.form != PIECES || state.evaluation != SAMPLED_REACTION) return;
    foreach (uint index, &weld : state.welds) {
        if (weld.broken || !weld.joint.is_valid()) continue;
        BreakableReaction reaction = sample_breakable_joint(
            joint: weld.joint,
            frame: weld.frame_a,
            axis: weld.moment_axis,
            strength: weld.strength,
        );
        if (!reaction.matched) continue;
        weld.broken = true;
        state.alive_welds--;
        push_breakable_event(
            world: world,
            root: root,
            first: state.pieces[weld.piece_a],
            second: state.pieces[weld.piece_b],
            joint: weld.joint,
            frame: weld.frame_a,
            kind: INTERNAL_WELD,
            index: index,
            limits: weld.strength,
            reaction: reaction,
            phase: POST_FIXED_STEP,
        );
    }
    foreach (uint index, &anchor : state.runtime.anchors) {
        if (anchor.broken || anchor.pruned || !anchor.joint.is_valid()) continue;
        BreakableReaction reaction = sample_breakable_joint(
            joint: anchor.joint,
            frame: anchor.authored.frame_a,
            axis: anchor.authored.moment_axis,
            strength: anchor.strength,
        );
        if (!reaction.matched) continue;
        anchor.broken = true;
        state.alive_anchors--;
        push_breakable_event(
            world: world,
            root: root,
            first: state.pieces[anchor.authored.piece],
            second: anchor.authored.target,
            joint: anchor.joint,
            frame: anchor.authored.frame_a,
            kind: ANCHOR,
            index: index,
            limits: anchor.strength,
            reaction: reaction,
            phase: POST_FIXED_STEP,
        );
    }
}

fn BreakableReaction sample_breakable_joint(
    b3::JointId joint,
    maths::Transform frame,
    Vec3 axis,
    BreakableStrength strength,
) @local {
    if (!joint.body_a().is_enabled() || !joint.body_b().is_enabled()) return {};
    Vec3 world_axis = joint.body_a().world_vector(frame.rotation.rotate_vec3(axis));
    return evaluate_breakable_reaction(
        force: joint.constraint_force(),
        torque: joint.constraint_torque(),
        axis: world_axis,
        strength: strength,
    );
}

fn BreakableReaction evaluate_breakable_reaction(
    Vec3 force,
    Vec3 torque,
    Vec3 axis,
    BreakableStrength strength,
) @private {
    float twist = torque.dot(axis);
    BreakableReaction result = {
        .loads = { .force = force.length(), .twist = math::abs(twist), .bending = (torque - axis * twist).length() },
    };
    if (strength.force < float::max && result.loads.force >= strength.force) {
        result.criterion = FORCE;
    } else if (strength.twist < float::max && result.loads.twist >= strength.twist) {
        result.criterion = TWIST;
    } else if (strength.bending < float::max && result.loads.bending >= strength.bending) {
        result.criterion = BENDING;
    } else {
        return result;
    }
    result.matched = true;
    return result;
}

fn void push_breakable_event(
    PhysicsWorld* world,
    Node* root,
    Entity first,
    Entity second,
    b3::JointId joint,
    maths::Transform frame,
    BreakableEdgeKind kind,
    uint index,
    BreakableStrength limits,
    BreakableReaction reaction,
    BreakSamplePhase phase,
) @local {
    if (world.break_count == world.break_storage.len) {
        world.dropped_events++;
        return;
    }
    world.break_storage[world.break_count++] = {
        .root = root,
        .piece_a = world.scene.node(first),
        .piece_b = world.scene.node(second),
        .point = joint.body_a().world_point(frame.position),
        .root_id = root.id,
        .endpoint_a = first,
        .endpoint_b = second,
        .edge_kind = kind,
        .edge_index = index,
        .criterion = reaction.criterion,
        .phase = phase,
        .loads = reaction.loads,
        .limits = limits,
        .loads_available = phase == POST_FIXED_STEP,
    };
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
        foreach (&anchor : state.runtime.anchors) {
            if (!anchor.broken && !anchor.pruned) continue;
            if (anchor.joint.is_valid()) b3::destroy_joint(anchor.joint, true);
            anchor.joint = {};
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
        foreach (index, frame : state.runtime.assembly_frames) {
            poses[index] = {
                .position = pose.position + pose.rotation.rotate_vec3(frame.position),
                .rotation = pose.rotation.mul(frame.rotation).normalize(),
                .scale = { 1, 1, 1 },
            };
        }
        check_breakable_anchor_frames(world, state, poses)!;
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
        state.runtime.bodies[state.pieces.len] = {};
        state.runtime.assembly_count = 0;
        commit_breakable_pieces(world, state, poses);
    };
}
