module c3d::physics::cloth;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;
import std::time;
import std::time::clock;

<* Cloth substeps per performed physics step. *>
const uint DEFAULT_CLOTH_SUBSTEPS = 4; // solve cost grows linearly; fewer substeps lag fast pins
<* Constraint passes per substep. *>
const uint DEFAULT_CLOTH_ITERATIONS = 8; // edge and bend passes per substep; the stiffness lever
<* Requested substep relaxation of triangle edges. *>
const float DEFAULT_STRETCH_STIFFNESS = 1; // edges hold their rest length; lower values let the fabric stretch
<* Requested substep relaxation of bend distances. *>
const float DEFAULT_BEND_STIFFNESS = 0.5f; // soft folds; 1 makes the sheet behave like card
<* Linear velocity damping, per second. *>
const float DEFAULT_CLOTH_DAMPING = 0.5f; // about 40% of velocity lost per second; higher values look submerged
<* Contact offset of free particles, in metres. *>
const float DEFAULT_CLOTH_THICKNESS = 0.01f; // keeps particles off contact surfaces; larger values show a visible gap
<* Maximum listed contact owners for one cloth. *>
const uint MAX_CLOTH_COLLIDERS = 32; // bounds owner resolution; leaf storage has its own configured capacity

<* Fixed-step integration and attachment settings for one cloth. *>
struct ClothDesc {
    uint     substeps;
    uint     iterations;
    float    stretch_stiffness;
    float    bend_stiffness;
    float    damping;
    float    thickness;
    float    gravity_scale;
    uint[]   pins;
    bool     collide_ground;
    float    ground_height;
    Entity[] colliders;
    ClothCollisionDesc collisions;
}

<* Last cloth update's CPU solve and publication costs. *>
struct ClothStats {
    double solve_seconds;
    double publish_seconds;
    uint   particles;
    uint   constraints;
    uint   pending;
    uint   failed;
    uint   candidates;
    uint   contacts;
    double max_residual;
}

<* Distance between two particles kept near its rest length. *>
struct ClothConstraint {
    uint  first;
    uint  second;
    float rest_length;
    Vec3  rest_direction; // separates a pair that collapses onto one point
}

<* Captured collider identity and body-local contact geometry. *>
struct ClothShape {
    uint  body;
    Vec3  start;
    Vec3  end;
    float radius;
    ColliderKind kind;
    uint collider;
    uint[3] native_identity;
    bool compound_child;
    uint child;
    SnapshotHandle snapshot;
    maths::Transform local;
    Aabb bounds;
}

<* Listed rigid body whose final published pose moves its captured shapes. *>
struct ClothBody {
    Entity           owner;
    uint[4]          native_identity;
    maths::Transform solved;   // pose of the last solved substep
    maths::Transform current;  // pose sampled by the current update
    bool             live;     // owner alive with a built body this update
    bool             observed; // solved holds a pose sampled since the owner was last live
}

<* Library-owned simulation state; its arrays are borrowed by readers. *>
struct ClothState {
    ClothDesc         desc;            // desc.pins and desc.colliders borrow pins and colliders
    AssetStore*       assets;
    GeometryId        source;
    GeometryId        geometry;
    bool              source_vertex_motion;
    Vec3[]            rest;            // node-local
    Vec3[]            positions;       // world, last solved
    Vec3[]            velocities;
    Vec3[]            predicted;
    Vec3[]            accelerations;
    Vec3[]            published;       // world, last publication
    float[]           inverse_masses;
    uint[]            pins;            // unique and ascending
    Vec3[]            pin_anchors;     // world, end of the last solved substep
    Vec3[]            pin_targets;     // world, final pose of the current update
    ClothConstraint[] edges;
    ClothConstraint[] bends;
    Entity[]          colliders;
    ClothBody[]       bodies;
    ClothShape[]      shapes;
    Vec3[]            shape_starts;    // world, current substep
    Vec3[]            shape_ends;
    ClothContactResult contact_result;
    ClothShape[]      shape_storage;
    ClothShape[]      staged_shapes;
    ClothBody[]       staged_bodies;
    Vec3[]            staged_positions;
    Vec3[]            staged_velocities;
    Vec3[]            staged_published;
    Vec3[]            staged_pin_anchors;
    Vec3[]            staged_shape_starts;
    Vec3[]            staged_shape_ends;
    Vec3[]            local_output;
    Vec3[]            local_normals;
    Vec3[]            publication_roundtrip;
    Vec3[]            staged_predicted;
    Vec3[]            staged_accelerations;
    Vec3[]            staged_pin_targets;
    Mat4              published_frame;
    Aabb              local_bounds;
    ContactFrame[]    frames;
    ClothCandidate[]  candidates;
    ClothContact[]    contacts;
}

<* Retained source and settings; owned arrays are read-only. *>
struct ClothAuthoring {
    ClothDesc desc;
    GeometryId source;
    bool source_vertex_motion;
}

<* Authored cloth and its optional component-owned simulation state. *>
struct Cloth {
    ClothAuthoring* authoring;
    ClothState* state;
}

<* Whether the cloth has its private geometry and simulation state. *>
fn bool Cloth.is_prepared(&self) => self.state != null;

<*
 Attach simulation over an owned geometry copy.
 @param [&inout] assets : "Owns the copy; outlives the cloth."
 @param [&in] node : "Live node with current, invertible world transform."
 @param desc : "Pins, collider identities and settings are copied."
 @return? NO_MESH, CLOTH_EXISTS, physics::SOURCE_UNAVAILABLE, physics::NO_BODY
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require self.world.is_registered(Cloth)
*>
fn void? Scene.add_cloth(
    &self,
    AssetStore* assets,
    Node* node,
    ClothDesc desc,
) {
    self.attach_cloth(assets, node, desc)!;
    defer catch self.remove_component(node, Cloth);
    return prepare(self, assets, node);
}

<*
 Attach cloth authoring while preserving its existing source mesh.
 @param [&in] assets : "Resolves retained source geometry; unchanged."
 @param [&in] node : "Live node carrying the source Mesh."
 @param desc : "Pins and collider identities are copied."
 @return? NO_MESH, CLOTH_EXISTS, physics::SOURCE_UNAVAILABLE
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require self.world.is_registered(Cloth)
*>
fn void? Scene.attach_cloth(
    &self,
    AssetStore* assets,
    Node* node,
    ClothDesc desc,
) {
    scene::Mesh* mesh = self.get(node, scene::Mesh);
    if (!mesh) return NO_MESH~;
    if (self.has(node, Cloth)) return CLOTH_EXISTS~;
    check_cloth_desc(desc)!;
    if (!assets.geometries.is_live(mesh.geometry)) return c3d::INVALID_ID~;
    GeometryAsset* source = assets.geometry(mesh.geometry);
    check_cloth_source(
        scene:  self,
        node:   node,
        mesh:   mesh,
        source: source,
    )!;
    check_collider_owners(self, desc.colliders)!;
    @pool() {
        (void)unique_pins(desc.pins, (uint)source.data.positions.len)!;
    };
    ClothAuthoring* authoring = copy_authoring(self.allocator, desc)!;
    authoring.source = mesh.geometry;
    authoring.source_vertex_motion = mesh.vertex_motion;
    self.add(node, (Cloth){ .authoring = authoring });
}

<*
 Prepare pending cloth atomically; prepared cloth remains unchanged.
 @param [&inout] scene : "Listed contact bodies have completed normal physics synchronization."
 @param [&inout] assets : "Owns private geometry; outlives the cloth."
 @param [&in] node : "Carries Cloth and its source Mesh; world matrix current."
 @return? NO_MESH, physics::SOURCE_UNAVAILABLE, physics::NO_BODY
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, Cloth)
*>
fn void? prepare(Scene* scene, AssetStore* assets, Node* node) {
    Cloth* component = scene.get(node, Cloth);
    if (component.is_prepared()) return;
    ClothAuthoring* authoring = component.authoring;
    ClothDesc desc = authoring.desc;
    scene::Mesh* mesh = scene.get(node, scene::Mesh);
    if (!mesh) return NO_MESH~;
    if (!c3d::same_id(mesh.geometry, authoring.source)) return c3d::INVALID_ARGUMENT~;
    if (!assets.geometries.is_live(authoring.source)) return c3d::INVALID_ID~;
    GeometryAsset* source = assets.geometry(authoring.source);
    check_cloth_source(
        scene: scene,
        node: node,
        mesh: mesh,
        source: source,
    )!;
    @pool() {
        uint vertex_count = (uint)source.data.positions.len;
        uint[] pins = unique_pins(desc.pins, vertex_count)!;
        Vec3[] world = alloc::new_array(tmem, Vec3, (sz)vertex_count);
        foreach (index, position : source.data.positions) world[index] = maths::transform_point(node.world, position);
        check_world_positions(world)!;
        ClothTopology topology = build_topology(&source.data, world)!;
        ClothCapture capture = capture_colliders(scene, desc.colliders, desc.collisions.max_shapes)!;
        GeometryId copy = copy_cloth_geometry(assets, &source.data)!;
        defer catch assets.remove_geometry(copy);
        ClothState* state = allocate_cloth_state(
            allocator:    scene.allocator,
            vertex_count: vertex_count,
            pin_count:    (uint)pins.len,
            edge_count:   (uint)topology.edges.len,
            bend_count:   (uint)topology.bends.len,
            body_count:   (uint)capture.bodies.len,
            collisions:   desc.collisions,
        )!;
        state.desc = desc;
        state.desc.pins = state.pins;
        state.colliders[..] = desc.colliders[..];
        state.desc.colliders = state.colliders;
        state.bodies[..] = capture.bodies[..];
        state.shapes = state.shape_storage[:capture.shapes.len];
        state.shapes[..] = capture.shapes[..];
        state.assets = assets;
        state.source = authoring.source;
        state.geometry = copy;
        state.source_vertex_motion = authoring.source_vertex_motion;
        state.rest[..] = source.data.positions[..];
        state.positions[..] = world[..];
        state.predicted[..] = world[..];
        state.accelerations[..] = (Vec3){};
        state.published[..] = world[..];
        state.published_frame = node.world;
        state.inverse_masses[..] = 1;
        state.pins[..] = pins[..];
        foreach (slot, pin : pins) {
            state.inverse_masses[pin] = 0;
            state.pin_anchors[slot] = world[pin];
            state.pin_targets[slot] = world[pin];
        }
        state.edges[..] = topology.edges[..];
        state.bends[..] = topology.bends[..];
        component.state = state;
        mesh.geometry = copy;
        mesh.vertex_motion = true;
    };
}

<*
 Prepare pending cloth in a subtree, retaining successful owners.
 @param [&inout] scene : "Listed contact bodies have completed normal physics synchronization."
 @param [&inout] assets : "Owns private geometry; outlives the cloth."
 @param [in] root : "Null selects the scene root; root is included."
 @return? NO_MESH, physics::SOURCE_UNAVAILABLE, physics::NO_BODY
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? prepare_subtree(Scene* scene, AssetStore* assets, Node* root = null) {
    if (!root) root = scene.root;
    fault failure;
    scene.@each(Cloth; entity, component) {
        Node* node = scene.node(entity);
        Node* ancestor = node;
        while (ancestor && ancestor != root) ancestor = ancestor.parent;
        if (ancestor) {
            if (catch excuse = prepare(scene, assets, node)) {
                if (!failure) failure = excuse;
            }
        }
    };
    if (failure) return failure~;
}

<*
 Restore the source mesh and remove cloth ownership.
 @param [&in] node : "Live node with Cloth and its owned Mesh."
 @require self.has(node, Cloth), self.has(node, scene::Mesh)
*>
fn void Scene.remove_cloth(&self, Node* node) {
    ClothAuthoring* authoring = self.get(node, Cloth).authoring;
    scene::Mesh* mesh = self.get(node, scene::Mesh);
    mesh.geometry = authoring.source;
    mesh.vertex_motion = authoring.source_vertex_motion;
    self.remove_component(node, Cloth);
}

<*
 Solve prepared cloth after final poses; pending cloth remains unchanged.
 @require self.cloth_update_serial != self.update_serial
*>
fn void PhysicsWorld.update_cloths(&self) {
    self.cloth_update_serial = self.update_serial;
    self.cloth_stats = {};
    uint steps = self.steps_last_update;
    self.scene.@each(Cloth; Entity entity, Cloth* component) {
        if (!component.is_prepared()) {
            self.cloth_stats.pending++;
        } else {
            ClothState* state = component.state;
            Node* node = self.scene.node(entity);
            time::Clock started = clock::now();
            double publication_seconds;
            if (catch excuse = update_cloth(
                world: self,
                state: state,
                node: node,
                steps: steps,
                publication_seconds: &publication_seconds,
            )) {
                state.contact_result.failure = excuse;
                time::Clock reexpression_start = clock::now();
                if (catch reexpression_failure = reexpress_cloth(state, node.world)) {
                    state.contact_result.failure = reexpression_failure;
                    state.contact_result.stage = ClothContactStage.REEXPRESSION;
                }
                publication_seconds += (clock::now() - reexpression_start).to_sec();
                self.cloth_stats.failed++;
            }
            double total_seconds = (clock::now() - started).to_sec();
            self.cloth_stats.solve_seconds += math::max(0.0, total_seconds - publication_seconds);
            self.cloth_stats.publish_seconds += publication_seconds;
            self.cloth_stats.candidates += state.contact_result.candidates;
            self.cloth_stats.contacts += state.contact_result.contacts;
            self.cloth_stats.max_residual = math::max(self.cloth_stats.max_residual, state.contact_result.max_residual);
            self.cloth_stats.particles += (uint)state.positions.len;
            self.cloth_stats.constraints += (uint)(state.edges.len + state.bends.len);
        }
    };
}

<*
 Translate all world-space state by the negated offset.
 @require offset.y == 0
*>
fn void ClothState.shift_origin(&self, Vec3 offset) {
    self.published_frame.m03 -= offset.x;
    self.published_frame.m13 -= offset.y;
    self.published_frame.m23 -= offset.z;
    foreach (&position : self.positions) *position -= offset;
    foreach (&position : self.predicted) *position -= offset;
    foreach (&position : self.published) *position -= offset;
    foreach (&position : self.pin_anchors) *position -= offset;
    foreach (&position : self.pin_targets) *position -= offset;
    foreach (&position : self.shape_starts) *position -= offset;
    foreach (&position : self.shape_ends) *position -= offset;
    foreach (&body : self.bodies) {
        body.solved.position -= offset;
        body.current.position -= offset;
    }
}

<* Default cloth settings with no pins or ground. *>
fn ClothDesc default_cloth_desc() {
    return {
        .substeps          = DEFAULT_CLOTH_SUBSTEPS,
        .iterations        = DEFAULT_CLOTH_ITERATIONS,
        .stretch_stiffness = DEFAULT_STRETCH_STIFFNESS,
        .bend_stiffness    = DEFAULT_BEND_STIFFNESS,
        .damping           = DEFAULT_CLOTH_DAMPING,
        .thickness         = DEFAULT_CLOTH_THICKNESS,
        .gravity_scale     = 1,
        .collisions        = default_cloth_collision_desc(),
    };
}

<*
 Select vertices by red channel; caller owns the result.
 @param [&in] geometry : "Retained positions and equally sized colors."
 @param threshold : "Red-channel cutoff in [0, 1]; equal values are selected."
 @return "Ascending indices allocated with allocator."
 @require geometry.colors.len == geometry.positions.len
 @require threshold >= 0 && threshold <= 1
*>
fn uint[] pins_from_colors(Allocator allocator, Geometry* geometry, float threshold = 0.5f) {
    usz count;
    foreach (color : geometry.colors) {
        if (color.x >= threshold) count++;
    }
    uint[] pins = alloc::new_array(allocator, uint, (sz)count);
    usz next;
    foreach (index, color : geometry.colors) {
        if (color.x >= threshold) pins[next++] = (uint)index;
    }
    return pins;
}

fn void free_cloth(Entity entity, void* component, void* user) @private {
    Cloth* cloth = component;
    Allocator allocator = *(Allocator*)user;
    if (cloth.state) {
        cloth.state.assets.remove_geometry(cloth.state.geometry);
        alloc::free(allocator, cloth.state);
    }
    alloc::free(allocator, cloth.authoring);
}
