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

const ulong BREAKABLE_DESC_LAYOUT @local = 0x2c215e44fb0b2d56;
const ulong BREAKABLE_PIECE_V1_LAYOUT @local = 0xb25ba97eda215cee;
const ulong BREAKABLE_V1_LAYOUT @local = 0xcb738bc03d840082;
const ulong BREAKABLE_STRENGTH_LAYOUT @local = 0x0d6fc483cf9886be;
const ulong BREAKABLE_WELD_LAYOUT @local = 0x16bf22d79c5a8446;
const ulong BREAKABLE_ANCHOR_LAYOUT @local = 0x7a639e9c3384159f;
const ulong BREAKABLE_PIECE_LAYOUT @local = 0x85c34ac7097a964f;
const ulong BREAKABLE_LAYOUT @local = 0xc1049a0339d716a2;

struct BreakableSavedPieceV1 @private {
    serial::NodeReference node;
    GeometryId[] hulls;
    maths::Transform rest_frame;
}

struct BreakableAuthoringV1 @private {
    BreakableDesc desc;
    BreakableSavedPieceV1[] pieces;
}

struct BreakableSavedPiece @private {
    serial::NodeReference node;
    GeometryId[] hulls;
    maths::Transform rest_frame;
    BreakableStrength strength;
    bool has_strength;
}

struct BreakableSavedAnchor @private {
    uint piece;
    serial::NodeReference target;
    maths::Transform frame_a;
    maths::Transform frame_b;
    Vec3 moment_axis;
    BreakableStrength target_strength;
    BreakableStrength strength_override;
    bool has_target_strength;
    bool has_strength_override;
}

struct BreakableAuthoring @private {
    BreakableDesc desc;
    BreakableSavedPiece[] pieces;
    BreakableRecipeKind recipe_kind;
    BreakableEvaluation evaluation;
    BreakableStrength strength;
    BreakableWeldDesc[] welds;
    BreakableSavedAnchor[] anchors;
}

serial::BinaryCompatibility[1] breakable_binary_compatibility @local = {
    { .version = 1, .read = &read_breakable_v1 },
};
uint[1] breakable_text_default_versions @local = { 1 };

fn void? register_breakable_descriptions() @private {
    describe::register_reflected(BreakableDesc)!;
    describe::register_reflected(BreakableSavedPieceV1)!;
    describe::register_reflected(BreakableAuthoringV1)!;
    describe::register_reflected(BreakableStrength)!;
    describe::register_reflected(BreakableWeldDesc)!;
    describe::register_reflected(BreakableSavedAnchor)!;
    describe::register_reflected(BreakableSavedPiece)!;
    describe::register_reflected(BreakableAuthoring)!;
}

fn void? register_breakable_codec() @private {
    register_breakable_descriptions()!;
    register_breakable_value(BreakableDesc, BREAKABLE_DESC_LAYOUT, &defaults_breakable_desc)!;
    register_breakable_value(BreakableSavedPieceV1, BREAKABLE_PIECE_V1_LAYOUT, &defaults_breakable_piece_v1)!;
    register_breakable_value(BreakableAuthoringV1, BREAKABLE_V1_LAYOUT, &defaults_breakable_authoring_v1)!;
    register_breakable_value(BreakableStrength, BREAKABLE_STRENGTH_LAYOUT, &defaults_breakable_strength)!;
    register_breakable_value(BreakableWeldDesc, BREAKABLE_WELD_LAYOUT, &defaults_breakable_weld)!;
    register_breakable_value(BreakableSavedAnchor, BREAKABLE_ANCHOR_LAYOUT, &defaults_breakable_anchor)!;
    serial::register_described_type(
        $Type: BreakableSavedPiece,
        version: 2,
        layout: BREAKABLE_PIECE_LAYOUT,
        defaults: &defaults_breakable_piece,
    )!;
    serial::register_described_type(
        $Type: BreakableAuthoring,
        version: 2,
        layout: BREAKABLE_LAYOUT,
        defaults: &defaults_breakable_authoring,
    )!;
    serial::register_described_owner(Breakable, BreakableAuthoring, {
        .name = "breakable",
        .phase = OWNER,
        .collect = &collect_breakable,
        .project = &project_breakable,
        .validate = &validate_breakable,
        .attach = &attach_breakable,
        .binary_compatibility = breakable_binary_compatibility[..],
        .text_default_versions = breakable_text_default_versions[..],
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

fn void defaults_breakable_piece_v1(void* value) @private {
    *(BreakableSavedPieceV1*)value = { .node = { .template_index = serial::INDEX_NONE }, .rest_frame = maths::TRANSFORM_IDENTITY };
}

fn void defaults_breakable_authoring_v1(void* value) @private {
    *(BreakableAuthoringV1*)value = { .desc = default_breakable_desc() };
}

fn void defaults_breakable_strength(void* value) @private => *(BreakableStrength*)value = default_breakable_strength();

fn void defaults_breakable_weld(void* value) @private {
    *(BreakableWeldDesc*)value = {
        .frame_a = maths::TRANSFORM_IDENTITY,
        .frame_b = maths::TRANSFORM_IDENTITY,
        .moment_axis = { 1, 0, 0 },
        .strength_override = default_breakable_strength(),
    };
}

fn void defaults_breakable_anchor(void* value) @private {
    *(BreakableSavedAnchor*)value = {
        .target = { .template_index = serial::INDEX_NONE },
        .frame_a = maths::TRANSFORM_IDENTITY,
        .frame_b = maths::TRANSFORM_IDENTITY,
        .moment_axis = { 1, 0, 0 },
        .target_strength = default_breakable_strength(),
        .strength_override = default_breakable_strength(),
    };
}

fn void defaults_breakable_piece(void* value) @private {
    *(BreakableSavedPiece*)value = {
        .node = { .template_index = serial::INDEX_NONE },
        .rest_frame = maths::TRANSFORM_IDENTITY,
        .strength = default_breakable_strength(),
    };
}

fn void defaults_breakable_authoring(void* value) @private {
    *(BreakableAuthoring*)value = { .desc = default_breakable_desc(), .strength = default_breakable_strength() };
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
    foreach (entity : state.pieces) if (context.scene.world.is_alive(entity)) count++;
    if (count < 2) return c3d::UNSUPPORTED~;

    BreakableSavedPiece[] pieces = alloc::new_array(tmem, BreakableSavedPiece, (sz)count);
    maths::Transform root_pose = serial_rigid_pose(serial_node_world(context.node))!;
    uint next;
    foreach (uint index, entity : state.pieces) {
        if (!context.scene.world.is_alive(entity)) continue;
        serial::NodeReference reference = context.make_entity_reference(entity, true)!;
        Node* node = context.scene.node(entity);
        Node* ancestor = node.parent;
        while (ancestor && ancestor != context.node) ancestor = ancestor.parent;
        if (!ancestor) return c3d::INVALID_ARGUMENT~;

        BreakablePieceView captured = state.piece_view(index);
        pieces[next++] = {
            .node = reference,
            .hulls = captured.hulls,
            .rest_frame = prepared && state.recipe_kind == LEGACY_CURRENT_POSE
              ? serial_relative_pose(root_pose, serial_rigid_pose(serial_node_world(node))!)
              : captured.rest_frame,
            .strength = captured.strength,
            .has_strength = captured.has_strength,
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
    if (state.recipe_kind == AUTHORED_REST) {
        uint[] indices = serial_breakable_indices(state, context.scene);
        (void)project_breakable_anchors(owner, context, indices)!;
    }

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

    if (!owner.is_prepared() && state.recipe_kind == LEGACY_CURRENT_POSE) return;
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
        Mat4 parent_world = state.recipe_kind == AUTHORED_REST
          ? serial_breakable_rest_world(state, context.node, node.parent) : serial_node_world(node.parent);
        Mat4 world = state.recipe_kind == AUTHORED_REST
          ? serial_breakable_rest_world(state, context.node, node) : serial_node_world(node);
        maths::Transform local = maths::transform_from_affine(maths::inverse_affine(parent_world).mul(world)) ?? c3d::UNSUPPORTED~!;
        context.set_transform(node, local, TransformSpace.PARENT)!;
    }
}

fn void? project_breakable(void* component, void* value, serial::WriteContext* context) @private {
    Breakable* owner = component;
    BreakableState* state = owner.state;
    BreakableAuthoring* authoring = value;
    *authoring = {
        .desc = state.desc,
        .pieces = project_breakable_pieces(owner, context)!,
        .recipe_kind = state.recipe_kind,
        .evaluation = state.evaluation,
        .strength = state.strength,
    };
    if (state.recipe_kind == LEGACY_CURRENT_POSE) return;
    uint[] indices = serial_breakable_indices(state, context.scene);
    authoring.welds = project_breakable_welds(state, indices);
    authoring.anchors = project_breakable_anchors(owner, context, indices)!;
}

fn BreakablePieceView[]? restore_breakable_pieces(BreakableAuthoring* source, serial::ReadContext* context) @private {
    BreakablePieceView[] pieces = alloc::new_array(tmem, BreakablePieceView, source.pieces.len);
    foreach (index, saved : source.pieces) {
        Node* node = context.resolve_node_reference(saved.node, true)!;
        pieces[index] = {
            .node = node.id,
            .hulls = saved.hulls,
            .rest_frame = saved.rest_frame,
            .strength = saved.strength,
            .has_strength = saved.has_strength,
        };
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

    if (source.recipe_kind == LEGACY_CURRENT_POSE) {
        if (source.welds.len || source.anchors.len || source.evaluation != NATIVE_FORCE) return c3d::INVALID_ARGUMENT~;
        return;
    }

    BreakableRecipeDesc recipe = restore_breakable_recipe(source, context)!;
    check_breakable_recipe(
        scene: context.scene,
        assets: context.assets,
        root: context.node,
        recipe: recipe,
    )!;
    foreach (anchor : recipe.anchors) {
        BodyAuthoring* target = context.authored(PhysicsBody, BodyAuthoring, anchor.target)!;
        if (!target || target.body.kind != STATIC || !target.colliders.len) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? attach_breakable(void* value, serial::ReadContext* context) @private {
    BreakableAuthoring* source = value;
    if (source.recipe_kind == AUTHORED_REST) {
        context.scene.attach_breakable_recipe(
            assets: context.assets,
            root: context.node,
            recipe: restore_breakable_recipe(source, context)!,
        )!;
        return;
    }
    BreakablePieceView[] pieces = restore_breakable_pieces(source, context)!;
    context.scene.attach_breakable_pieces(
        assets: context.assets,
        root: context.node,
        pieces: pieces,
        desc: source.desc,
    )!;
}

fn uint[] serial_breakable_indices(BreakableState* state, Scene* scene) @private {
    uint[] indices = alloc::new_array(tmem, uint, state.pieces.len);
    uint count;
    foreach (index, entity : state.pieces) indices[index] = scene.world.is_alive(entity) ? count++ : serial::INDEX_NONE;
    return indices;
}

fn BreakableWeldDesc[] project_breakable_welds(BreakableState* state, uint[] indices) @private {
    BreakableWeldDesc[] welds = alloc::new_array(tmem, BreakableWeldDesc, state.welds.len);
    uint count;
    foreach (uint index, weld : state.welds) {
        if (indices[weld.piece_a] == serial::INDEX_NONE || indices[weld.piece_b] == serial::INDEX_NONE) continue;
        BreakableWeldView view = state.weld_view(index);
        welds[count++] = {
            .piece_a = indices[view.piece_a],
            .piece_b = indices[view.piece_b],
            .frame_a = view.frame_a,
            .frame_b = view.frame_b,
            .moment_axis = view.moment_axis,
            .strength_override = view.strength_override,
            .has_strength_override = view.has_strength_override,
        };
    }
    return welds[:count];
}

fn BreakableSavedAnchor[]? project_breakable_anchors(
    Breakable* owner,
    serial::WriteContext* context,
    uint[] indices,
) @private {
    BreakableState* state = owner.state;
    BreakableSavedAnchor[] anchors = alloc::new_array(tmem, BreakableSavedAnchor, state.runtime.anchors.len);
    maths::Transform root_pose = serial_rigid_pose(serial_node_world(context.node))!;
    uint count;
    foreach (anchor : state.runtime.anchors) {
        BreakableAnchorDesc authored = anchor.authored;
        if (anchor.pruned || indices[authored.piece] == serial::INDEX_NONE || !context.scene.world.is_alive(authored.target)) continue;
        Node* target = context.scene.node(authored.target);
        PhysicsBody* body = context.scene.get(target, PhysicsBody);
        if (!body || body.body.kind != STATIC || !body.colliders.len) return c3d::INVALID_ARGUMENT~;
        for (Node* ancestor = target; ancestor; ancestor = ancestor.parent) {
            if (context.scene.has(ancestor, Breakable) || context.scene.has(ancestor, Ragdoll)) return c3d::INVALID_ARGUMENT~;
        }

        maths::Transform piece_pose = compose_breakable_pose(root_pose, state.runtime.frames[authored.piece]);
        maths::Transform frame_a = compose_breakable_pose(piece_pose, authored.frame_a);
        maths::Transform frame_b = compose_breakable_pose(serial_rigid_pose(serial_node_world(target))!, authored.frame_b);
        if (!breakable_frames_agree(frame_a, frame_b)) return c3d::INVALID_ARGUMENT~;
        anchors[count++] = {
            .piece = indices[authored.piece],
            .target = context.make_entity_reference(authored.target, true, c3d::INVALID_ARGUMENT)!,
            .frame_a = authored.frame_a,
            .frame_b = authored.frame_b,
            .moment_axis = authored.moment_axis,
            .target_strength = authored.target_strength,
            .strength_override = authored.strength_override,
            .has_target_strength = authored.has_target_strength,
            .has_strength_override = authored.has_strength_override,
        };
    }
    return anchors[:count];
}

fn Mat4 serial_breakable_rest_world(BreakableState* state, Node* root, Node* node) @private {
    if (node == root) return serial_node_world(root);
    foreach (index, entity : state.pieces) {
        if (c3d::same_id(entity, node.id)) return serial_node_world(root).mul(state.runtime.frames[index].to_mat4());
    }
    Mat4 local = node.local.to_mat4();
    if (node.transform_space == TransformSpace.WORLD || !node.parent) return local;
    return serial_breakable_rest_world(state, root, node.parent).mul(local);
}

fn BreakableRecipeDesc? restore_breakable_recipe(BreakableAuthoring* source, serial::ReadContext* context) @private {
    BreakableRecipeDesc recipe = {
        .pieces = restore_breakable_pieces(source, context)!,
        .welds = source.welds,
        .settings = source.desc,
        .strength = source.strength,
        .evaluation = source.evaluation,
    };
    recipe.anchors = alloc::new_array(tmem, BreakableAnchorDesc, source.anchors.len);
    foreach (index, saved : source.anchors) {
        Node* target = context.resolve_node_reference(saved.target, true, c3d::INVALID_ARGUMENT)!;
        recipe.anchors[index] = {
            .piece = saved.piece,
            .target = target.id,
            .frame_a = saved.frame_a,
            .frame_b = saved.frame_b,
            .moment_axis = saved.moment_axis,
            .target_strength = saved.target_strength,
            .strength_override = saved.strength_override,
            .has_target_strength = saved.has_target_strength,
            .has_strength_override = saved.has_strength_override,
        };
    }
    return recipe;
}

fn void? read_breakable_v1(serial::Reader* reader, serial::ReadContext* context) @private {
    BreakableAuthoringV1* legacy = context.read_value(BreakableAuthoringV1, reader)!;
    BreakableSavedPiece[] pieces = alloc::new_array(tmem, BreakableSavedPiece, legacy.pieces.len);
    foreach (index, saved : legacy.pieces) {
        pieces[index] = { .node = saved.node, .hulls = saved.hulls, .rest_frame = saved.rest_frame };
    }
    BreakableAuthoring source = {
        .desc = legacy.desc,
        .pieces = pieces,
        .strength = default_breakable_strength(legacy.desc.break_force),
    };
    validate_breakable(&source, context)!;
    attach_breakable(&source, context)!;
}
