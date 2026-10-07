module c3d::physics;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import c3d::physics::collide;
import std::collections::list;
import std::math;
import b3;

<* Default gap for connecting authored hulls, in meters. *>
const float DEFAULT_CONTACT_DISTANCE = 0.01f; // joins narrow export seams; larger gaps remain separate

<* Default weld reaction threshold, in newtons. *>
const float DEFAULT_BREAK_FORCE = 2000; // tune to piece mass and expected loads; lower thresholds release more constraints

<* Representation of an intact or released fracture graph. *>
enum BreakableForm {
    ASSEMBLY,
    PIECES,
}

<* Captured fracture strength, collision properties and initial representation. *>
struct BreakableDesc {
    float break_force;
    float contact_distance;
    float density;
    SurfaceMaterialDesc material;
    CollisionFilter filter;
    bool hit_events;
    bool sleep_until_hit;
}

<* Author one physical piece from ordered collision hulls. *>
struct BreakablePieceDesc {
    Entity node;
    GeometryId[] hulls;
}

<* Borrow captured piece identity, hulls and root-relative rest frame. *>
struct BreakablePieceView {
    Entity node;
    GeometryId[] hulls;
    maths::Transform rest_frame;
}

<* Read one captured weld without native or damage state. *>
struct BreakableWeldView {
    uint piece_a;
    uint piece_b;
    Vec3 anchor;
    maths::Transform frame_b;
}

<* One captured graph edge and its world-owned native joint. *>
struct Weld {
    uint piece_a;
    uint piece_b;
    Vec3 anchor;
    maths::Transform frame_b;
    bool broken;
    b3::JointId joint;
}

<* Library-owned fracture state; arrays remain borrowed by readers. *>
struct BreakableState {
    BreakableDesc desc;
    Entity[] pieces;
    Weld[] welds;
    uint alive_pieces;
    uint alive_welds;
    BreakableForm form;
    BodyStatus status;
    fault failure;
    BreakableRuntime* runtime;
}

<* Own a fracture's state for the component lifetime. *>
struct Breakable {
    BreakableState* state;
}

<* Broken weld from the last update; node pointers are frame borrows. *>
struct BreakEvent {
    Node* root;
    Node* piece_a;
    Node* piece_b;
    Vec3 point;
}

struct BreakableWake @private {
    b3::BodyId visitor;
    Vec3 point;
    Vec3 direction;
    float approach_speed;
    bool pending;
}

struct BreakableRuntime @private {
    GeometryId[] geometries;
    uint[] hull_offsets;
    maths::Transform[] frames;
    uint[] assembly_pieces;
    uint assembly_count;
    BreakableWake wake;
}

<*
 Read captured piece authoring; hulls borrow until breakable removal.
 @param [&in] self : "Valid until remove_breakable or component removal."
 @require index < self.pieces.len
*>
fn BreakablePieceView BreakableState.piece_view(&self, uint index) {
    uint first_hull = self.runtime.hull_offsets[index];
    uint hull_count = self.runtime.hull_offsets[index + 1] - first_hull;
    return {
        .node = self.pieces[index],
        .hulls = self.runtime.geometries[first_hull:hull_count],
        .rest_frame = self.runtime.frames[index],
    };
}

<*
 Read captured weld authoring.
 @param [&in] self : "Live captured breakable state."
 @require index < self.welds.len
*>
fn BreakableWeldView BreakableState.weld_view(&self, uint index) {
    Weld weld = self.welds[index];
    return { .piece_a = weld.piece_a, .piece_b = weld.piece_b, .anchor = weld.anchor, .frame_b = weld.frame_b };
}

<*
 Create a fracture graph and its initial bodies transactionally.
 @param [&in] root : "Live scene node with current world matrices."
 @return? BREAKABLE_EXISTS, BODY_EXISTS, SOURCE_UNAVAILABLE
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @return? b3::INVALID_DEFINITION, b3::INVALID_HANDLE, b3::DEGENERATE_GEOMETRY
 @require self.scene.world.is_registered(Breakable), root != self.scene.root
 @require self.scene.world.is_alive(root.id)
*>
fn void? PhysicsWorld.add_breakable(&self, Node* root, BreakableDesc desc) {
    check_breakable_desc(desc)!;
    check_breakable_ancestors(self, root)!;
    if (self.scene.has(root, scene::Mesh)) return c3d::INVALID_ARGUMENT~;
    maths::Transform root_pose = breakable_pose(root)!;
    uint count = check_breakable_tree(
        world: self,
        root: root,
        node: root,
        assembly: desc.sleep_until_hit,
    )!;
    if (count < 2) return c3d::INVALID_ARGUMENT~;

    @pool() {
        Entity[] entities = alloc::new_array(tmem, Entity, count);
        uint index;
        collect_breakable_pieces(
            scene: self.scene,
            node: root,
            pieces: entities,
            index: &index,
        );
        BreakablePieceDesc[] pieces = alloc::new_array(tmem, BreakablePieceDesc, count);
        foreach (piece_index, entity : entities) {
            scene::Mesh* mesh = self.scene.get(self.scene.node(entity), scene::Mesh);
            pieces[piece_index] = { .node = entity, .hulls = (&mesh.geometry)[:1] };
        }
        author_breakable(
            world: self,
            root: root,
            pieces: pieces,
            desc: desc,
            root_pose: root_pose,
        )!;
    };
}

<*
 Create a fracture graph from ordered pieces transactionally.
 @param [&in] root : "Live scene node with current world matrices."
 @param pieces : "Copied identities and hulls in caller order."
 @return? BREAKABLE_EXISTS, BODY_EXISTS, SOURCE_UNAVAILABLE
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @return? b3::INVALID_DEFINITION, b3::INVALID_HANDLE, b3::DEGENERATE_GEOMETRY
 @require self.scene.world.is_registered(Breakable), root != self.scene.root
 @require self.scene.world.is_alive(root.id)
*>
fn void? PhysicsWorld.add_breakable_pieces(
    &self,
    Node* root,
    BreakablePieceDesc[] pieces,
    BreakableDesc desc,
) {
    check_breakable_desc(desc)!;
    check_breakable_ancestors(self, root)!;
    check_breakable_roles(self.scene, root)!;
    maths::Transform root_pose = breakable_pose(root)!;
    if (pieces.len < 2 || pieces.len > uint::max) return c3d::INVALID_ARGUMENT~;
    foreach (index, piece : pieces) {
        if (!self.scene.world.is_alive(piece.node)) return c3d::INVALID_ID~;
        if (!piece.hulls.len) return c3d::INVALID_ARGUMENT~;
        Node* node = self.scene.node(piece.node);
        if (node == root) return c3d::INVALID_ARGUMENT~;
        Node* ancestor = node;
        while (ancestor != root) {
            if (!ancestor) return c3d::INVALID_ARGUMENT~;
            if (desc.sleep_until_hit && ancestor.transform_space != TransformSpace.PARENT) return c3d::UNSUPPORTED~;
            foreach (other : pieces) {
                if (c3d::same_id(other.node, ancestor.id) && !c3d::same_id(other.node, piece.node)) {
                    return c3d::INVALID_ARGUMENT~;
                }
            }
            ancestor = ancestor.parent;
        }
        foreach (earlier : pieces[:index]) if (c3d::same_id(earlier.node, piece.node)) return c3d::INVALID_ARGUMENT~;
        breakable_pose(node)!;
        foreach (geometry : piece.hulls) if (!self.assets.geometries.is_live(geometry)) return c3d::INVALID_ID~;
    }
    @pool() {
        author_breakable(
            world: self,
            root: root,
            pieces: pieces,
            desc: desc,
            root_pose: root_pose,
        )!;
    };
}

<*
 Remove owned bodies and welds, preserving nodes and meshes.
 @param [&in] root : "Carries this world's breakable."
 @require self.scene.has(root, Breakable)
*>
fn void PhysicsWorld.remove_breakable(&self, Node* root) {
    BreakableState* state = self.scene.get(root, Breakable).state;
    destroy_breakable_welds(state);
    if (state.form == ASSEMBLY) {
        if (self.scene.has(root, PhysicsBody)) self.remove_body(root);
    } else {
        remove_breakable_piece_bodies(self, state);
    }
    self.scene.remove_component(root, Breakable);
}

<*
 Release a ready assembly into pieces; live PIECES is unchanged.
 @param [&in] root : "Carries this world's breakable; worlds are current."
 @return? NO_BODY, SOURCE_UNAVAILABLE, c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED, b3::INVALID_DEFINITION, b3::INVALID_HANDLE, b3::DEGENERATE_GEOMETRY
 @require self.scene.has(root, Breakable)
*>
fn void? PhysicsWorld.wake_breakable(&self, Node* root) {
    BreakableState* state = self.scene.get(root, Breakable).state;
    if (state.status != LIVE) return NO_BODY~;
    if (state.form == PIECES) return;
    prune_breakable(self, root, state);
    maths::Transform pose = breakable_pose(root)!;
    swap_breakable_to_pieces(
        world: self,
        root: root,
        state: state,
        pose: pose,
    )!;
}

<* Borrow weld breaks until the next update or node removal. *>
fn BreakEvent[] PhysicsWorld.breaks(&self) => self.break_storage[:self.break_count];

<* Default fracture strength, collision properties and sleeping assembly. *>
fn BreakableDesc default_breakable_desc() {
    return {
        .break_force = DEFAULT_BREAK_FORCE,
        .contact_distance = DEFAULT_CONTACT_DISTANCE,
        .density = DEFAULT_DENSITY,
        .material = default_surface_material(),
        .filter = FILTER_ALL,
        .sleep_until_hit = true,
    };
}

fn void? author_breakable(
    PhysicsWorld* world,
    Node* root,
    BreakablePieceDesc[] pieces,
    BreakableDesc desc,
    maths::Transform root_pose,
) @local {
    usz hull_count;
    foreach (piece : pieces) {
        if (piece.hulls.len > uint::max - hull_count) return c3d::CAPACITY_EXCEEDED~;
        hull_count += piece.hulls.len;
    }
    maths::Transform[] poses = alloc::new_array(tmem, maths::Transform, pieces.len);
    maths::Transform[] frames = alloc::new_array(tmem, maths::Transform, pieces.len);
    uint[] offsets = alloc::new_array(tmem, uint, pieces.len + 1);
    SnapshotHandle[] held = alloc::new_array(tmem, SnapshotHandle, (sz)hull_count);
    uint held_count;
    defer foreach (handle : held[:held_count]) release_snapshot(world.snapshots, handle);
    foreach (index, piece : pieces) {
        poses[index] = breakable_pose(world.scene.node(piece.node))!;
        frames[index] = relative_breakable_pose(root_pose, poses[index]);
        offsets[index] = held_count;
        foreach (geometry : piece.hulls) {
            held[held_count] = acquire_hull(world, geometry)!;
            held_count++;
        }
    }
    offsets[pieces.len] = held_count;
    Weld[] edges = build_breakable_graph(
        world: world,
        poses: frames,
        held: held,
        offsets: offsets,
        gap: desc.contact_distance,
    )!;
    BreakableState* state = allocate_breakable(
        allocator: world.scene.allocator,
        piece_count: pieces.len,
        weld_count: edges.len,
        hull_count: hull_count,
    );
    defer catch alloc::free(world.scene.allocator, state);
    state.desc = desc;
    state.welds[..] = edges[..];
    state.runtime.frames[..] = frames[..];
    state.runtime.hull_offsets[..] = offsets[..];
    foreach (index, piece : pieces) {
        state.pieces[index] = piece.node;
        state.runtime.geometries[offsets[index]:piece.hulls.len] = piece.hulls[..];
    }
    state.alive_pieces = (uint)pieces.len;
    state.alive_welds = (uint)edges.len;
    state.form = desc.sleep_until_hit ? ASSEMBLY : PIECES;
    if (desc.sleep_until_hit) {
        author_breakable_assembly(
            world: world,
            root: root,
            state: state,
            pose: root_pose,
        )!;
        world.scene.add(root, (Breakable){ .state = state });
        world.set_enabled(root, true);
        state.status = LIVE;
    } else {
        build_breakable_pieces(
            world: world,
            state: state,
            poses: poses,
            assembly: {},
            assembly_pose: root_pose,
        )!;
        defer catch remove_breakable_piece_bodies(world, state);
        bind_breakable_welds(world, root, state)!;
        world.scene.add(root, (Breakable){ .state = state });
        commit_breakable_pieces(world, state, poses);
    }
}

fn void? check_breakable_ancestors(PhysicsWorld* world, Node* root) @local {
    for (Node* ancestor = root.parent; ancestor; ancestor = ancestor.parent) {
        if (world.scene.has(ancestor, Breakable)) return BREAKABLE_EXISTS~;
    }
}

fn void? check_breakable_roles(Scene* scene, Node* node) @local {
    if (scene.has(node, Breakable)) return BREAKABLE_EXISTS~;
    if (scene.has(node, PhysicsBody) || scene.has(node, RigidBody)) return BODY_EXISTS~;
    if (scene.has(node, PhysicsJoint) || scene.has(node, Joint) || scene.has(node, Ragdoll)) {
        return c3d::INVALID_ARGUMENT~;
    }
    for (Node* child = node.first_child; child; child = child.next_sibling) check_breakable_roles(scene, child)!;
}

fn void? check_breakable_desc(BreakableDesc desc) @local {
    if (!math::is_finite(desc.break_force) || desc.break_force < 0
        || !math::is_finite(desc.contact_distance) || desc.contact_distance < 0
        || !math::is_finite(desc.density) || desc.density <= 0) return c3d::INVALID_ARGUMENT~;

    SurfaceMaterialDesc material = desc.material;
    if (!math::is_finite(material.friction) || material.friction < 0
        || !math::is_finite(material.restitution) || material.restitution < 0
        || !math::is_finite(material.rolling_resistance) || material.rolling_resistance < 0) {
        return c3d::INVALID_ARGUMENT~;
    }
    for (uint axis = 0; axis < 3; axis++) {
        if (!math::is_finite(material.tangent_velocity[axis])) return c3d::INVALID_ARGUMENT~;
    }
}

fn maths::Transform? breakable_pose(Node* node) @private {
    maths::Transform? pose = maths::transform_from_affine(node.world);
    if (catch pose) return c3d::UNSUPPORTED~;
    if (!collide::unit_scale(pose)) return c3d::UNSUPPORTED~;
    pose.scale = { 1, 1, 1 };
    return pose;
}

fn uint? check_breakable_tree(
    PhysicsWorld* world,
    Node* root,
    Node* node,
    bool assembly,
) @local {
    Scene* scene = world.scene;
    if (scene.has(node, Breakable)) return BREAKABLE_EXISTS~;
    if (scene.has(node, PhysicsBody) || scene.has(node, RigidBody)) return BODY_EXISTS~;
    if (scene.has(node, PhysicsJoint) || scene.has(node, Joint) || scene.has(node, Ragdoll)) {
        return c3d::INVALID_ARGUMENT~;
    }

    uint count;
    if (scene.has(node, scene::Mesh)) {
        scene::Mesh* mesh = scene.get(node, scene::Mesh);
        if (!world.assets.geometries.is_live(mesh.geometry)) return c3d::INVALID_ID~;
        if (scene.has(node, SkinBinding) || mesh.morph_weights.len) return c3d::UNSUPPORTED~;
        breakable_pose(node)!;
        if (assembly) {
            for (Node* current = node; current != root; current = current.parent) {
                if (current.transform_space != TransformSpace.PARENT) return c3d::UNSUPPORTED~;
            }
        }
        count = 1;
    }
    for (Node* child = node.first_child; child; child = child.next_sibling) {
        count += check_breakable_tree(
            world: world,
            root: root,
            node: child,
            assembly: assembly,
        )!;
    }
    return count;
}

fn void collect_breakable_pieces(
    Scene* scene,
    Node* node,
    Entity[] pieces,
    uint* index,
) @local {
    if (scene.has(node, scene::Mesh)) pieces[(*index)++] = node.id;
    for (Node* child = node.first_child; child; child = child.next_sibling) {
        collect_breakable_pieces(
            scene: scene,
            node: child,
            pieces: pieces,
            index: index,
        );
    }
}

fn maths::Transform relative_breakable_pose(maths::Transform first, maths::Transform second) @local {
    Quat inverse = first.rotation.conjugate();
    return {
        .position = inverse.rotate_vec3(second.position - first.position),
        .rotation = inverse.mul(second.rotation).normalize(),
        .scale = { 1, 1, 1 },
    };
}

fn bool breakable_bounds_near(b3::Aabb first, b3::Aabb second, float gap) @local {
    for (uint axis = 0; axis < 3; axis++) {
        if (first.lower_bound[axis] > second.upper_bound[axis] + gap
            || second.lower_bound[axis] > first.upper_bound[axis] + gap) return false;
    }
    return true;
}

fn Weld[]? build_breakable_graph(
    PhysicsWorld* world,
    maths::Transform[] poses,
    SnapshotHandle[] held,
    uint[] offsets,
    float gap,
) @local {
    b3::Aabb[] bounds = alloc::new_array(tmem, b3::Aabb, held.len);
    foreach (index, pose : poses) {
        for (uint hull = offsets[index]; hull < offsets[index + 1]; hull++) {
            bounds[hull] = snapshot_of(world.snapshots, held[hull]).hull.compute_aabb(body_frame(pose));
        }
    }
    List{Weld} edges;
    edges.init(tmem);

    for (uint first = 0; first < poses.len; first++) {
        for (uint second = first + 1; second < poses.len; second++) {
            b3::DistanceOutput nearest;
            bool found;
            for (uint first_hull = offsets[first]; first_hull < offsets[first + 1]; first_hull++) {
                b3::HullData* hull_a = snapshot_of(world.snapshots, held[first_hull]).hull;
                for (uint second_hull = offsets[second]; second_hull < offsets[second + 1]; second_hull++) {
                    if (!breakable_bounds_near(bounds[first_hull], bounds[second_hull], gap)) continue;
                    b3::HullData* hull_b = snapshot_of(world.snapshots, held[second_hull]).hull;
                    b3::DistanceOutput closest = b3::shape_distance({
                        .proxy_a = {
                            .points = (Vec3*)((char*)hull_a + hull_a.point_offset),
                            .count = hull_a.vertex_count,
                        },
                        .proxy_b = {
                            .points = (Vec3*)((char*)hull_b + hull_b.point_offset),
                            .count = hull_b.vertex_count,
                        },
                        .transform = body_frame(relative_breakable_pose(poses[first], poses[second])),
                    })!;
                    if (closest.distance > gap || (found && closest.distance >= nearest.distance)) continue;
                    nearest = closest;
                    found = true;
                }
            }
            if (!found) continue;
            Vec3 anchor = (nearest.point_a + nearest.point_b) * 0.5f;
            maths::Transform frame = poses[first];
            frame.position += frame.rotation.rotate_vec3(anchor);
            edges.push({
                .piece_a = first,
                .piece_b = second,
                .anchor = anchor,
                .frame_b = relative_breakable_pose(poses[second], frame),
            });
        }
    }
    return edges.array_view();
}

fn BreakableState* carve_breakable(
    BlockCursor* cursor,
    usz piece_count,
    usz weld_count,
    usz hull_count,
) @local {
    BreakableState[] states = carve(cursor, BreakableState, 1);
    BreakableRuntime[] runtimes = carve(cursor, BreakableRuntime, 1);
    Entity[] pieces = carve(cursor, Entity, piece_count);
    Weld[] welds = carve(cursor, Weld, weld_count);
    GeometryId[] geometries = carve(cursor, GeometryId, hull_count);
    uint[] hull_offsets = carve(cursor, uint, piece_count + 1);
    maths::Transform[] frames = carve(cursor, maths::Transform, piece_count);
    uint[] assembly_pieces = carve(cursor, uint, hull_count);
    if (!cursor.base) return null;

    *runtimes.ptr = {
        .geometries = geometries,
        .hull_offsets = hull_offsets,
        .frames = frames,
        .assembly_pieces = assembly_pieces,
    };
    *states.ptr = { .pieces = pieces, .welds = welds, .runtime = runtimes.ptr };
    return states.ptr;
}

fn BreakableState* allocate_breakable(
    Allocator allocator,
    usz piece_count,
    usz weld_count,
    usz hull_count,
) @local {
    BlockCursor measure;
    carve_breakable(
        cursor: &measure,
        piece_count: piece_count,
        weld_count: weld_count,
        hull_count: hull_count,
    );
    BlockCursor fill = { .base = alloc::malloc(allocator, (sz)measure.offset) };
    return carve_breakable(
        cursor: &fill,
        piece_count: piece_count,
        weld_count: weld_count,
        hull_count: hull_count,
    );
}

fn ColliderDesc breakable_collider(
    BreakableState* state,
    uint piece_index,
    uint hull_index,
    bool assembly,
) @local {
    ColliderDesc collider = default_collider_desc(HULL);
    collider.geometry = state.runtime.geometries[hull_index];
    collider.local = assembly ? state.runtime.frames[piece_index] : maths::TRANSFORM_IDENTITY;
    collider.density = state.desc.density;
    collider.material = state.desc.material;
    collider.filter = state.desc.filter;
    collider.hit_events = assembly || state.desc.hit_events;
    return collider;
}

fn void? author_breakable_assembly(
    PhysicsWorld* world,
    Node* root,
    BreakableState* state,
    maths::Transform pose,
) @local {
    ColliderDesc[] colliders = alloc::new_array(tmem, ColliderDesc, state.runtime.geometries.len);
    for (uint index = 0; index < state.pieces.len; index++) {
        for (uint hull = state.runtime.hull_offsets[index]; hull < state.runtime.hull_offsets[index + 1]; hull++) {
            colliders[hull] = breakable_collider(
                state: state,
                piece_index: index,
                hull_index: hull,
                assembly: true,
            );
            state.runtime.assembly_pieces[hull] = index;
        }
    }
    state.runtime.assembly_count = (uint)colliders.len;
    BodyDesc body = default_body_desc(KINEMATIC);
    body.name = root.name;
    body.disabled = true;
    world.scene.add_physics_body(root, body, colliders)!;
    defer catch world.remove_body(root);
    build_body_at(
        world: world,
        node: root,
        physics_body: world.scene.get(root, PhysicsBody),
        pose: pose,
    )!;
}

fn void destroy_breakable_welds(BreakableState* state) @private {
    foreach (&weld : state.welds) {
        if (weld.joint.is_valid()) b3::destroy_joint(weld.joint, true);
        weld.joint = {};
    }
}

fn void remove_breakable_piece_bodies(PhysicsWorld* world, BreakableState* state) @private {
    foreach (entity : state.pieces) {
        if (!world.scene.world.is_alive(entity)) continue;
        Node* node = world.scene.node(entity);
        if (world.scene.has(node, PhysicsBody)) world.remove_body(node);
    }
}

fn void? bind_breakable_welds(PhysicsWorld* world, Node* root, BreakableState* state) @private {
    defer catch destroy_breakable_welds(state);
    foreach (&weld : state.welds) {
        if (weld.broken) continue;
        b3::WeldJointDef def = b3::default_weld_joint_def();
        def.base.body_id_a = world.scene.get(world.scene.node(state.pieces[weld.piece_a]), RigidBody).body;
        def.base.body_id_b = world.scene.get(world.scene.node(state.pieces[weld.piece_b]), RigidBody).body;
        def.base.local_frame_a = { .p = weld.anchor, .q = quaternion::IDENTITY };
        def.base.local_frame_b = body_frame(weld.frame_b);
        def.base.force_threshold = state.desc.break_force;
        def.base.collide_connected = false;
        def.base.user_data = pack_entity(root.id);
        weld.joint = b3::create_weld_joint(world.world, &def)!;
    }
}

fn void? build_breakable_pieces(
    PhysicsWorld* world,
    BreakableState* state,
    maths::Transform[] poses,
    b3::BodyId assembly,
    maths::Transform assembly_pose,
) @private {
    defer catch remove_breakable_piece_bodies(world, state);
    Vec3 velocity;
    Vec3 angular;
    Vec3 center;
    if (assembly.is_valid()) {
        velocity = assembly.linear_velocity();
        angular = assembly.angular_velocity();
        center = assembly_pose.position + assembly_pose.rotation.rotate_vec3(assembly.local_center());
    }

    foreach (uint index, entity : state.pieces) {
        if (!world.scene.world.is_alive(entity)) continue;
        Node* node = world.scene.node(entity);
        uint first_hull = state.runtime.hull_offsets[index];
        uint end_hull = state.runtime.hull_offsets[index + 1];
        ColliderDesc[] colliders = alloc::new_array(tmem, ColliderDesc, (sz)(end_hull - first_hull));
        for (uint hull = first_hull; hull < end_hull; hull++) {
            colliders[hull - first_hull] = breakable_collider(
                state: state,
                piece_index: index,
                hull_index: hull,
                assembly: false,
            );
        }
        BodyDesc body = default_body_desc(DYNAMIC);
        body.name = node.name;
        body.disabled = true;
        world.scene.add_physics_body(node, body, colliders)!;
        build_body_at(
            world: world,
            node: node,
            physics_body: world.scene.get(node, PhysicsBody),
            pose: poses[index],
        )!;

        b3::BodyId built = world.scene.get(node, RigidBody).body;
        PhysicsBody* authored = world.scene.get(node, PhysicsBody);
        authored.body.linear_velocity = velocity + angular.cross((Vec3)built.world_center() - center);
        authored.body.angular_velocity = angular;
    }
}

fn void enable_breakable_pieces(PhysicsWorld* world, BreakableState* state) @private {
    foreach (entity : state.pieces) {
        if (!world.scene.world.is_alive(entity)) continue;
        Node* node = world.scene.node(entity);
        BodyDesc desc = world.scene.get(node, PhysicsBody).body;
        world.set_enabled(node, true);
        b3::BodyId body = world.scene.get(node, RigidBody).body;
        body.set_linear_velocity(desc.linear_velocity);
        body.set_angular_velocity(desc.angular_velocity);
    }
    state.status = LIVE;
}

fn void commit_breakable_pieces(PhysicsWorld* world, BreakableState* state, maths::Transform[] poses) @private {
    foreach (index, entity : state.pieces) {
        if (!world.scene.world.is_alive(entity)) continue;
        Node* node = world.scene.node(entity);
        node.transform_space = TransformSpace.WORLD;
        node.local = poses[index];
    }
    state.form = PIECES;
    enable_breakable_pieces(world, state);
}

fn void free_breakable(Entity entity, void* component, void* user) @private {
    BreakableState* state = ((Breakable*)component).state;
    destroy_breakable_welds(state);
    alloc::free(*(Allocator*)user, state);
}
