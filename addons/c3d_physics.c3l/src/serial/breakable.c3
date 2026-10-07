module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::physics::collide;
import c3d::scene;
import c3d::serial;
import std::math;

struct BreakableSavedPiece @private {
    serial::NodeReference node;
    GeometryId[] hulls;
    maths::Transform rest_frame;
}

struct BreakableAuthoring @private {
    BreakableDesc desc;
    BreakableSavedPiece[] pieces;
}

fn void? register_breakable_codec() @private {
    describe::register_reflected(BreakableDesc)!;
    describe::register_reflected(BreakableSavedPiece)!;
    describe::register_reflected(BreakableAuthoring)!;
    register_breakable_value(BreakableDesc, 0x2c215e44fb0b2d56, &defaults_breakable_desc)!;
    register_breakable_value(BreakableSavedPiece, 0xb25ba97eda215cee, &defaults_breakable_piece)!;
    register_breakable_value(BreakableAuthoring, 0xcb738bc03d840082, &defaults_breakable_authoring)!;
    serial::register_described_owner(Breakable, BreakableAuthoring, {
        .name = "breakable",
        .phase = OWNER,
        .collect = &collect_breakable,
        .project = &project_breakable,
        .validate = &validate_breakable,
        .attach = &attach_breakable,
    })!;
}

macro void? register_breakable_value($Type, ulong layout, serial::DefaultsFn defaults) @private {
    serial::register_described_type(
        $Type: $Type,
        version: 1,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void defaults_breakable_desc(void* value) @private => *(BreakableDesc*)value = default_breakable_desc();

fn void defaults_breakable_piece(void* value) @private {
    *(BreakableSavedPiece*)value = { .node = { .template_index = serial::INDEX_NONE }, .rest_frame = maths::TRANSFORM_IDENTITY };
}

fn void defaults_breakable_authoring(void* value) @private {
    *(BreakableAuthoring*)value = { .desc = default_breakable_desc() };
}

fn Mat4 serial_node_world(Node* node) @private {
    Mat4 world = node.local.to_mat4();
    for (Node* current = node; current.parent && current.transform_space == TransformSpace.PARENT; current = current.parent) {
        world = current.parent.local.to_mat4().mul(world);
    }
    return world;
}

fn maths::Transform? serial_rigid_pose(Mat4 world) @private {
    maths::Transform pose = maths::transform_from_affine(world) ?? c3d::UNSUPPORTED~!;
    if (!collide::unit_scale(pose)) return c3d::UNSUPPORTED~;
    pose.scale = { 1, 1, 1 };
    return pose;
}

fn maths::Transform serial_relative_pose(maths::Transform root, maths::Transform piece) @private {
    Quaternionf inverse = root.rotation.conjugate();
    return {
        .position = inverse.rotate_vec3(piece.position - root.position),
        .rotation = inverse.mul(piece.rotation).normalize(),
        .scale = { 1, 1, 1 },
    };
}

fn Node* serial_next_descendant(Node* root, Node* node) @private {
    if (node.first_child) return node.first_child;
    while (node != root) {
        if (node.next_sibling) return node.next_sibling;
        node = node.parent;
    }
    return null;
}

fn BreakableSavedPiece[]? project_breakable_pieces(Breakable* owner, serial::WriteContext* context) @private {
    BreakableState* state = owner.state;
    bool prepared = owner.is_prepared();
    usz count;
    foreach (entity : state.pieces) if (!prepared || context.scene.world.is_alive(entity)) count++;
    if (prepared && count < 2) return c3d::UNSUPPORTED~;
    BreakableSavedPiece[] pieces = alloc::new_array_try(tmem, BreakableSavedPiece, (sz)count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    maths::Transform root_pose = serial_rigid_pose(serial_node_world(context.node))!;
    uint next;
    foreach (uint index, entity : state.pieces) {
        if (prepared && !context.scene.world.is_alive(entity)) continue;
        serial::NodeReference reference = context.make_entity_reference(entity, true)!;
        Node* node = context.scene.node(entity);
        Node* ancestor = node.parent;
        while (ancestor && ancestor != context.node) ancestor = ancestor.parent;
        if (!ancestor) return c3d::INVALID_ARGUMENT~;
        BreakablePieceView captured = state.piece_view(index);
        pieces[next++] = {
            .node = reference,
            .hulls = captured.hulls,
            .rest_frame = prepared
              ? serial_relative_pose(root_pose, serial_rigid_pose(serial_node_world(node))!)
              : captured.rest_frame,
        };
    }
    return pieces;
}

fn bool serial_breakable_body_settings(BodyDesc body, BodyKind kind) @private {
    MotionLocks locks = body.locks;
    return body.kind == kind && body.linear_damping == 0 && body.angular_damping == 0
        && body.gravity_scale == 1 && body.allow_sleep && !body.bullet
        && !locks.linear_x && !locks.linear_y && !locks.linear_z && !locks.angular_x && !locks.angular_y && !locks.angular_z;
}

fn bool serial_breakable_collider(
    ColliderDesc* collider,
    GeometryId geometry,
    maths::Transform local,
    BreakableDesc desc,
    bool assembly,
) @private {
    SurfaceMaterialDesc material = collider.material;
    return collider.kind == HULL && c3d::same_id(collider.geometry, geometry)
        && collider.local.position == local.position && collider.local.rotation.v == local.rotation.v && collider.local.scale == local.scale
        && collider.radius == 0 && collider.half_height == 0 && collider.half_extents == (Vec3){}
        && collider.height_field.source == HEIGHTS && !collider.height_field.heights.len
        && !collider.height_field.count_x && !collider.height_field.count_z && !collider.height_field.texture.generation
        && !collider.children.len && collider.density == desc.density && collider.explosion_scale == DEFAULT_EXPLOSION_SCALE
        && material.friction == desc.material.friction && material.restitution == desc.material.restitution
        && material.rolling_resistance == desc.material.rolling_resistance
        && material.tangent_velocity == desc.material.tangent_velocity && material.id == desc.material.id
        && !collider.face_materials.len && !collider.material_indices.len && !collider.sensor && !collider.contact_events
        && collider.hit_events == (assembly || desc.hit_events)
        && collider.filter.category == desc.filter.category && collider.filter.mask == desc.filter.mask && collider.filter.group == desc.filter.group;
}

fn bool serial_breakable_body_matches(
    BreakableState* state,
    Node* root,
    Node* node,
    PhysicsBody* body,
) @private {
    if (state.form == ASSEMBLY) {
        if (node != root || !serial_breakable_body_settings(body.body, KINEMATIC)
            || body.colliders.len != state.runtime.assembly_count) return false;
        uint previous = uint::max;
        uint hull;
        foreach (index, &collider : body.colliders) {
            uint piece = state.runtime.assembly_pieces[index];
            if (piece != previous) hull = 0;
            BreakablePieceView captured = state.piece_view(piece);
            if (!serial_breakable_collider(
                collider: collider,
                geometry: captured.hulls[hull++],
                local: state.runtime.assembly_frames[piece],
                desc: state.desc,
                assembly: true,
            )) return false;
            previous = piece;
        }
        return true;
    }
    foreach (uint index, entity : state.pieces) {
        if (!c3d::same_id(entity, node.id)) continue;
        BreakablePieceView captured = state.piece_view(index);
        if (!serial_breakable_body_settings(body.body, DYNAMIC) || body.colliders.len != captured.hulls.len) return false;
        foreach (hull, &collider : body.colliders) {
            if (!serial_breakable_collider(
                collider: collider,
                geometry: captured.hulls[hull],
                local: maths::TRANSFORM_IDENTITY,
                desc: state.desc,
                assembly: false,
            )) return false;
        }
        return true;
    }
    return false;
}

fn void? collect_breakable(void* component, serial::WriteContext* context) @private {
    Breakable* owner = component;
    BreakableState* state = owner.state;
    (void)project_breakable_pieces(owner, context)!;
    for (Node* node = context.node; node; node = serial_next_descendant(context.node, node)) {
        if (node != context.node && context.scene.has(node, Breakable)) return BREAKABLE_EXISTS~;
        if (context.scene.has(node, PhysicsJoint) || context.scene.has(node, Joint) || context.scene.has(node, Ragdoll)) return c3d::INVALID_ARGUMENT~;
        PhysicsBody* body = context.scene.get(node, PhysicsBody);
        if (body) {
            if (!owner.is_prepared()) return BODY_EXISTS~;
            if (!serial_breakable_body_matches(state, context.node, node, body)) return c3d::INVALID_ARGUMENT~;
            context.omit_component(node, ecs::slot_of(PhysicsBody)!)!;
        }
        if (context.scene.has(node, RigidBody)) {
            if (!body) return c3d::INVALID_ARGUMENT~;
            context.omit_component(node, ecs::slot_of(RigidBody)!)!;
        }
    }
    if (!owner.is_prepared()) return;
    foreach (entity : state.pieces) {
        if (!context.scene.world.is_alive(entity)) continue;
        Node* node = context.scene.node(entity);
        if (state.desc.sleep_until_hit) {
            for (Node* ancestor = node.parent; ancestor != context.node; ancestor = ancestor.parent) {
                if (ancestor.transform_space == TransformSpace.PARENT) continue;
                bool piece_parent;
                foreach (piece : state.pieces) piece_parent |= c3d::same_id(piece, ancestor.id);
                if (!piece_parent) return c3d::UNSUPPORTED~;
            }
        }
        Mat4 parent_world = serial_node_world(node.parent);
        Mat4 world = serial_node_world(node);
        maths::Transform local = maths::transform_from_affine(maths::inverse_affine(parent_world).mul(world)) ?? c3d::UNSUPPORTED~!;
        context.set_transform(node, local, TransformSpace.PARENT)!;
    }
}

fn void? project_breakable(void* component, void* value, serial::WriteContext* context) @private {
    Breakable* owner = component;
    *(BreakableAuthoring*)value = { .desc = owner.state.desc, .pieces = project_breakable_pieces(owner, context)! };
}

fn BreakablePieceView[]? restore_breakable_pieces(BreakableAuthoring* source, serial::ReadContext* context) @private {
    BreakablePieceView[] pieces = alloc::new_array_try(tmem, BreakablePieceView, source.pieces.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (index, saved : source.pieces) {
        Node* node = context.resolve_node_reference(saved.node, true)!;
        pieces[index] = { .node = node.id, .hulls = saved.hulls, .rest_frame = saved.rest_frame };
    }
    return pieces;
}

fn void? validate_breakable(void* value, serial::ReadContext* context) @private {
    BreakableAuthoring* source = value;
    check_breakable_desc(source.desc)!;
    BreakablePieceView[] pieces = restore_breakable_pieces(source, context)!;
    check_captured_pieces(
        scene: context.scene,
        assets: context.assets,
        root: context.node,
        pieces: pieces,
        desc: source.desc,
    )!;
    uint body_slot = ecs::slot_of(PhysicsBody)!;
    uint joint_slot = ecs::slot_of(PhysicsJoint)!;
    uint ragdoll_slot = ecs::slot_of(Ragdoll)!;
    uint breakable_slot = ecs::slot_of(Breakable)!;
    foreach (index, node : context.nodes) {
        Node* ancestor = node;
        while (ancestor && ancestor != context.node) ancestor = ancestor.parent;
        if (!ancestor) continue;
        ComponentMask mask = context.component_masks[index];
        if (mask & ecs::slot_bit(body_slot)) return BODY_EXISTS~;
        if ((mask & ecs::slot_bit(joint_slot)) || (mask & ecs::slot_bit(ragdoll_slot))) return c3d::INVALID_ARGUMENT~;
        if (node != context.node && (mask & ecs::slot_bit(breakable_slot))) return BREAKABLE_EXISTS~;
    }
}

fn void? attach_breakable(void* value, serial::ReadContext* context) @private {
    BreakableAuthoring* source = value;
    BreakablePieceView[] pieces = restore_breakable_pieces(source, context)!;
    context.scene.attach_breakable_pieces(
        assets: context.assets,
        root: context.node,
        pieces: pieces,
        desc: source.desc,
    )!;
}
