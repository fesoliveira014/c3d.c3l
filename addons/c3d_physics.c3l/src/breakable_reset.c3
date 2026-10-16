module c3d::physics;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;
import b3;

struct BreakableStagedBody @private {
    PhysicsBody authored;
    RigidBody rigid;
}

<*
 Restore surviving pieces to captured rest with zero velocity.
 @param [&inout] root : "Owned root; current world matrices, outside stepping."
 @param [in] root_pose : "Optional rigid world pose; null keeps current pose."
 @return? BREAKABLE_EXISTS, NO_BODY, SOURCE_UNAVAILABLE
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @return? b3::INVALID_DEFINITION, b3::INVALID_HANDLE, b3::DEGENERATE_GEOMETRY
 @require self.scene.has(root, Breakable)
*>
fn void? PhysicsWorld.reset_breakable(
    &self,
    Node* root,
    BreakableForm form,
    maths::Transform* root_pose = null,
) {
    BreakableState* previous = self.scene.get(root, Breakable).state;
    check_breakable_reset_roles(self, root, previous)!;
    prune_breakable(self, root, previous);
    maths::Transform pose = root_pose ? *root_pose : breakable_pose(root)!;
    check_breakable_frame(pose)!;
    maths::Transform root_local = maths::transform_from_affine(
        maths::inverse_affine(root.transform_basis()).mul(pose.to_mat4())
    ) ?? c3d::UNSUPPORTED~!;

    @pool() {
        maths::Transform[] poses = alloc::new_array_try(tmem, maths::Transform, previous.pieces.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        maths::Transform[] locals = alloc::new_array_try(tmem, maths::Transform, previous.pieces.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        foreach (index, entity : previous.pieces) {
            if (!self.scene.world.is_alive(entity)) continue;
            Node* node = self.scene.node(entity);
            breakable_pose(node)!;
            poses[index] = compose_breakable_pose(pose, previous.runtime.frames[index]);
            check_breakable_frame(poses[index])!;
            locals[index] = poses[index];
            if (form == ASSEMBLY) {
                maths::Transform parent = breakable_rest_parent(
                    scene: self.scene,
                    root: root,
                    state: previous,
                    node: node.parent,
                    pose: pose,
                )!;
                locals[index] = relative_breakable_pose(parent, poses[index]);
            }
        }
        check_breakable_anchor_frames(self, previous, poses)!;

        BreakableStagedBody[] bodies = alloc::new_array_try(self.allocator, BreakableStagedBody, previous.pieces.len + 1)
          ?? c3d::CAPACITY_EXCEEDED~!;
        defer {
            foreach (&body : bodies) discard_breakable_body(self, body);
            alloc::free(self.allocator, bodies.ptr);
        }
        BreakableState* staged = copy_breakable_reset_state(self, previous, form)!;
        defer catch {
            destroy_breakable_welds(staged);
            alloc::free(self.scene.allocator, staged);
        }
        stage_breakable_reset_bodies(
            world: self,
            root: root,
            state: staged,
            bodies: bodies,
            poses: poses,
            root_pose: pose,
        )!;
        if (form == PIECES) {
            stage_breakable_reset_welds(
                world: self,
                root: root,
                state: staged,
                bodies: bodies,
            )!;
        }

        destroy_breakable_welds(previous);
        remove_breakable_reset_bodies(self, root, previous);
        install_breakable_reset_bodies(
            world: self,
            root: root,
            state: staged,
            bodies: bodies,
        );
        root.local = root_local;
        foreach (index, entity : staged.pieces) {
            if (!self.scene.world.is_alive(entity)) continue;
            Node* node = self.scene.node(entity);
            node.transform_space = form == ASSEMBLY ? TransformSpace.PARENT : TransformSpace.WORLD;
            node.local = locals[index];
        }
        self.scene.update_world();

        if (previous.runtime.prepared) {
            commit_breakable_reset_state(previous, staged);
            alloc::free(self.scene.allocator, staged);
            staged = previous;
        } else {
            self.scene.get(root, Breakable).state = staged;
            alloc::free(self.scene.allocator, previous);
        }
        if (form == PIECES) {
            enable_breakable_pieces(self, staged);
        } else if (staged.alive_pieces) {
            self.set_enabled(root, true);
            b3::BodyId body = self.scene.get(root, RigidBody).body;
            body.set_linear_velocity({});
            body.set_angular_velocity({});
        }
        staged.status = LIVE;
        staged.failure = {};
    };
}

fn void? check_breakable_reset_roles(PhysicsWorld* world, Node* root, BreakableState* state) @local {
    check_breakable_ancestors(world.scene, root)!;
    for (Node* node = root; node; node = next_breakable_reset_node(root, node)) {
        if (node != root && world.scene.has(node, Breakable)) return BREAKABLE_EXISTS~;
        if (world.scene.has(node, PhysicsJoint) || world.scene.has(node, Joint) || world.scene.has(node, Ragdoll)) {
            return c3d::INVALID_ARGUMENT~;
        }
        usz owner_index = state.pieces.len + 1;
        if (node == root) owner_index = state.pieces.len;
        foreach (usz index, entity : state.pieces) if (c3d::same_id(entity, node.id)) owner_index = index;
        PhysicsBody* authored = world.scene.get(node, PhysicsBody);
        RigidBody* body = world.scene.get(node, RigidBody);
        if (!authored && !body) continue;
        if (owner_index == state.pieces.len + 1) return c3d::INVALID_ARGUMENT~;
        BreakableBodyOwner owner = state.runtime.bodies[owner_index];
        if (authored && authored.colliders.ptr != owner.colliders) return c3d::INVALID_ARGUMENT~;
        if (body && (!body.body.is_valid() || !same_breakable_body(body.body, owner.body))) return c3d::INVALID_ARGUMENT~;
    }

    int capacity;
    foreach (entity : state.pieces) {
        if (!world.scene.world.is_alive(entity)) continue;
        Node* node = world.scene.node(entity);
        Node* ancestor = node;
        while (ancestor && ancestor != root) ancestor = ancestor.parent;
        if (!ancestor) return c3d::INVALID_ARGUMENT~;
        if (RigidBody* body = world.scene.get(node, RigidBody)) capacity = math::max(capacity, body.body.joint_count());
    }
    if (RigidBody* body = world.scene.get(root, RigidBody)) capacity = math::max(capacity, body.body.joint_count());
    b3::JointId[] joints = alloc::new_array_try(world.allocator, b3::JointId, capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer alloc::free(world.allocator, joints.ptr);
    for (usz index = 0; index <= state.pieces.len; index++) {
        Entity entity = index == state.pieces.len ? root.id : state.pieces[index];
        if (!world.scene.world.is_alive(entity)) continue;
        RigidBody* body = world.scene.get(world.scene.node(entity), RigidBody);
        if (!body) continue;
        foreach (joint : body.body.joints(joints)) {
            bool owned;
            foreach (weld : state.welds) if (same_breakable_joint(joint, weld.joint)) owned = true;
            foreach (anchor : state.runtime.anchors) if (same_breakable_joint(joint, anchor.joint)) owned = true;
            if (!owned) return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn Node* next_breakable_reset_node(Node* root, Node* node) @local {
    if (node.first_child) return node.first_child;
    while (node != root) {
        if (node.next_sibling) return node.next_sibling;
        node = node.parent;
    }
    return null;
}

fn maths::Transform? breakable_rest_parent(
    Scene* scene,
    Node* root,
    BreakableState* state,
    Node* node,
    maths::Transform pose,
) @local {
    if (node == root) return pose;
    if (!node) return c3d::INVALID_ARGUMENT~;
    foreach (index, entity : state.pieces) {
        if (c3d::same_id(entity, node.id)) return compose_breakable_pose(pose, state.runtime.frames[index]);
    }
    if (node.transform_space != TransformSpace.PARENT) return c3d::UNSUPPORTED~;
    check_breakable_frame(node.local)!;
    maths::Transform parent = breakable_rest_parent(
        scene: scene,
        root: root,
        state: state,
        node: node.parent,
        pose: pose,
    )!;
    return compose_breakable_pose(parent, node.local);
}

fn Weld[]? pending_breakable_reset_edges(PhysicsWorld* world, BreakableState* state) @local {
    if (state.alive_pieces < 2) return {};
    uint[] indices = alloc::new_array_try(tmem, uint, state.alive_pieces) ?? c3d::CAPACITY_EXCEEDED~!;
    uint[] offsets = alloc::new_array_try(tmem, uint, (sz)state.alive_pieces + 1) ?? c3d::CAPACITY_EXCEEDED~!;
    maths::Transform[] poses = alloc::new_array_try(tmem, maths::Transform, state.alive_pieces)
      ?? c3d::CAPACITY_EXCEEDED~!;
    SnapshotHandle[] held = alloc::new_array_try(tmem, SnapshotHandle, state.runtime.geometries.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    uint held_count;
    defer foreach (handle : held[:held_count]) release_snapshot(world.snapshots, handle);
    uint count;
    foreach (uint index, entity : state.pieces) {
        if (!world.scene.world.is_alive(entity)) continue;
        indices[count] = index;
        poses[count] = state.runtime.frames[index];
        offsets[count++] = held_count;
        for (uint hull = state.runtime.hull_offsets[index]; hull < state.runtime.hull_offsets[index + 1]; hull++) {
            held[held_count] = acquire_hull(world.snapshots, state.runtime.geometries[hull])!;
            held_count++;
        }
    }
    offsets[count] = held_count;
    Weld[] edges = build_breakable_graph(
        world: world,
        poses: poses,
        held: held[:held_count],
        offsets: offsets,
        gap: state.desc.contact_distance,
    )!;
    foreach (&edge : edges) {
        edge.piece_a = indices[edge.piece_a];
        edge.piece_b = indices[edge.piece_b];
        edge.strength = state.strength;
    }
    return edges;
}

fn BreakableState*? copy_breakable_reset_state(PhysicsWorld* world, BreakableState* source, BreakableForm form) @local {
    Weld[] edges = source.welds;
    if (!source.runtime.prepared && source.recipe_kind == LEGACY_CURRENT_POSE) edges = pending_breakable_reset_edges(world, source)!;
    BreakableState* state = allocate_breakable(
        allocator: world.scene.allocator,
        piece_count: source.pieces.len,
        weld_count: edges.len,
        hull_count: source.runtime.geometries.len,
        anchor_count: source.runtime.anchors.len,
    )!;
    state.desc = source.desc;
    state.recipe_kind = source.recipe_kind;
    state.evaluation = source.evaluation;
    state.strength = source.strength;
    state.form = form;
    state.alive_pieces = source.alive_pieces;
    state.pieces[..] = source.pieces[..];
    state.welds[..] = edges[..];
    state.runtime.geometries[..] = source.runtime.geometries[..];
    state.runtime.hull_offsets[..] = source.runtime.hull_offsets[..];
    state.runtime.frames[..] = source.runtime.frames[..];
    state.runtime.assembly_frames[..] = source.runtime.frames[..];
    state.runtime.materials[..] = source.runtime.materials[..];
    state.runtime.anchors[..] = source.runtime.anchors[..];
    state.runtime.prepared = true;
    foreach (&weld : state.welds) {
        weld.joint = {};
        weld.broken = !world.scene.world.is_alive(state.pieces[weld.piece_a])
            || !world.scene.world.is_alive(state.pieces[weld.piece_b]);
        if (!weld.broken) state.alive_welds++;
    }
    foreach (&anchor : state.runtime.anchors) {
        anchor.joint = {};
        anchor.failure = {};
        anchor.broken = false;
        if (!anchor.pruned) state.alive_anchors++;
    }
    return state;
}

fn void? stage_breakable_reset_bodies(
    PhysicsWorld* world,
    Node* root,
    BreakableState* state,
    BreakableStagedBody[] bodies,
    maths::Transform[] poses,
    maths::Transform root_pose,
) @local {
    if (!state.alive_pieces) return;
    if (state.form == ASSEMBLY) {
        ColliderDesc[] colliders = alloc::new_array_try(tmem, ColliderDesc, state.runtime.geometries.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        uint count;
        foreach (uint index, entity : state.pieces) {
            if (!world.scene.world.is_alive(entity)) continue;
            for (uint hull = state.runtime.hull_offsets[index]; hull < state.runtime.hull_offsets[index + 1]; hull++) {
                colliders[count] = breakable_collider(
                    state: state,
                    piece_index: index,
                    hull_index: hull,
                    assembly: true,
                );
                state.runtime.assembly_pieces[count++] = index;
            }
        }
        state.runtime.assembly_count = count;
        bodies[state.pieces.len] = stage_breakable_body(
            world: world,
            node: root,
            kind: KINEMATIC,
            colliders: colliders[:count],
            pose: root_pose,
        )!;
        return;
    }
    foreach (uint index, entity : state.pieces) {
        if (!world.scene.world.is_alive(entity)) continue;
        uint first = state.runtime.hull_offsets[index];
        uint count = state.runtime.hull_offsets[index + 1] - first;
        ColliderDesc[] colliders = alloc::new_array_try(tmem, ColliderDesc, count) ?? c3d::CAPACITY_EXCEEDED~!;
        foreach (uint hull, &collider : colliders) {
            *collider = breakable_collider(
                state: state,
                piece_index: index,
                hull_index: first + hull,
                assembly: false,
            );
        }
        bodies[index] = stage_breakable_body(
            world: world,
            node: world.scene.node(entity),
            kind: DYNAMIC,
            colliders: colliders,
            pose: poses[index],
        )!;
    }
}

fn BreakableStagedBody? stage_breakable_body(
    PhysicsWorld* world,
    Node* node,
    BodyKind kind,
    ColliderDesc[] colliders,
    maths::Transform pose,
) @local {
    BodyDesc desc = default_body_desc(kind);
    desc.name = node.name;
    desc.disabled = true;
    PhysicsBody authored = try_copy_physics_body(world.scene.allocator, desc, colliders)!;
    defer catch alloc::free(world.scene.allocator, authored.colliders.ptr);
    foreach (&collider : authored.colliders) check_collider(world, collider, kind)!;

    b3::BodyDef native = b3::default_body_def();
    native.type = body_type(kind);
    native.position = (b3::Pos)pose.position;
    native.rotation = pose.rotation;
    native.linear_damping = desc.linear_damping;
    native.angular_damping = desc.angular_damping;
    native.gravity_scale = desc.gravity_scale;
    native.name = (ZString)authored.body.name.ptr;
    native.enable_sleep = desc.allow_sleep;
    native.is_bullet = desc.bullet;
    native.is_enabled = false;
    native.motion_locks = motion_locks(desc.locks);
    native.user_data = pack_entity(node.id);

    Collider[] records = alloc::new_array_try(world.snapshots.allocator, Collider, colliders.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    b3::BodyId body;
    defer catch {
        if (body.is_valid()) {
            destroy_rigid_body(world.snapshots, body, records);
        } else {
            alloc::free(world.snapshots.allocator, records.ptr);
        }
    }
    body = b3::create_body(world.world, &native)!;
    foreach (index, &collider : authored.colliders) records[index] = create_shape(world, body, collider)!;
    SolidMeasure solid;
    if (kind == DYNAMIC) {
        b3::body_apply_mass_from_shapes(body);
        solid = measure_solids(records);
    }
    authored.status = LIVE;
    return {
        .authored = authored,
        .rigid = {
            .body = body,
            .kind = kind,
            .previous = pose,
            .current = pose,
            .colliders = records,
            .solid_bounds = solid.bounds,
            .solid_volume = solid.volume,
        },
    };
}

fn void discard_breakable_body(PhysicsWorld* world, BreakableStagedBody* body) @local {
    if (body.rigid.body.is_valid()) destroy_rigid_body(world.snapshots, body.rigid.body, body.rigid.colliders);
    alloc::free(world.scene.allocator, body.authored.colliders.ptr);
    *body = {};
}

fn void? stage_breakable_reset_welds(
    PhysicsWorld* world,
    Node* root,
    BreakableState* state,
    BreakableStagedBody[] bodies,
) @local {
    foreach (&weld : state.welds) {
        if (weld.broken) continue;
        weld.joint = create_breakable_weld(
            world: world,
            root: root.id,
            body_a: bodies[weld.piece_a].rigid.body,
            body_b: bodies[weld.piece_b].rigid.body,
            frame_a: weld.frame_a,
            frame_b: weld.frame_b,
            strength: weld.strength,
            evaluation: state.evaluation,
        )!;
    }
    foreach (&anchor : state.runtime.anchors) {
        if (anchor.pruned) continue;
        anchor.joint = create_breakable_weld(
            world: world,
            root: root.id,
            body_a: bodies[anchor.authored.piece].rigid.body,
            body_b: breakable_anchor_target(world, anchor.authored.target)!,
            frame_a: anchor.authored.frame_a,
            frame_b: anchor.authored.frame_b,
            strength: anchor.strength,
            evaluation: state.evaluation,
        )!;
    }
}

fn void remove_breakable_reset_bodies(PhysicsWorld* world, Node* root, BreakableState* state) @local {
    for (usz index = 0; index <= state.pieces.len; index++) {
        Entity entity = index == state.pieces.len ? root.id : state.pieces[index];
        if (!world.scene.world.is_alive(entity)) continue;
        Node* node = world.scene.node(entity);
        if (world.scene.has(node, RigidBody)) world.scene.remove_component(node, RigidBody);
        if (world.scene.has(node, PhysicsBody)) world.scene.remove_component(node, PhysicsBody);
    }
}

fn void install_breakable_reset_bodies(
    PhysicsWorld* world,
    Node* root,
    BreakableState* state,
    BreakableStagedBody[] bodies,
) @local {
    foreach (uint index, &body : bodies) {
        if (!body.rigid.body.is_valid()) continue;
        Entity entity = index == state.pieces.len ? root.id : state.pieces[index];
        Node* node = world.scene.node(entity);
        world.scene.add(node, body.authored);
        world.scene.add(node, body.rigid);
        remember_breakable_body(
            world: world,
            state: state,
            node: node,
            index: index,
        );
        *body = {};
    }
}

fn void commit_breakable_reset_state(BreakableState* state, BreakableState* staged) @local {
    state.welds[..] = staged.welds[..];
    state.runtime.anchors[..] = staged.runtime.anchors[..];
    state.runtime.bodies[..] = staged.runtime.bodies[..];
    state.runtime.assembly_frames[..] = staged.runtime.assembly_frames[..];
    state.runtime.assembly_pieces[:staged.runtime.assembly_count] = staged.runtime.assembly_pieces[:staged.runtime.assembly_count];
    state.runtime.assembly_count = staged.runtime.assembly_count;
    state.runtime.wake = {};
    state.runtime.has_mismatch = false;
    state.runtime.mismatch = {};
    state.alive_pieces = staged.alive_pieces;
    state.alive_welds = staged.alive_welds;
    state.alive_anchors = staged.alive_anchors;
    state.form = staged.form;
}
