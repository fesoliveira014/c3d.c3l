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
<* Maximum listed bodies and primitive shapes one cloth tests. *>
const uint MAX_CLOTH_COLLIDERS = 32; // bounds particle-by-shape work; the cape's bone capsules fit

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
}

<* Last cloth update's CPU solve and publication costs. *>
struct ClothStats {
    double solve_seconds;
    double publish_seconds;
    uint   particles;
    uint   constraints;
}

<* Distance between two particles kept near its rest length. *>
struct ClothConstraint {
    uint  first;
    uint  second;
    float rest_length;
    Vec3  rest_direction; // separates a pair that collapses onto one point
}

<* Body-local sphere or capsule kept outside of; equal endpoints make a sphere. *>
struct ClothShape {
    uint  body;
    Vec3  start;
    Vec3  end;
    float radius;
}

<* Listed rigid body whose final published pose moves its captured shapes. *>
struct ClothBody {
    Entity           owner;
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
}

<* Simulated mesh with component-owned state. *>
struct Cloth {
    ClothState* state;
}

<*
 Attach simulation over an owned geometry copy.
 @param [&inout] assets : "Owns the copy; outlives the cloth."
 @param [&in] node : "Live node with current, invertible world transform."
 @param desc : "Pins, collider ids and their sphere and capsule shapes are copied."
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
    @pool() {
        uint vertex_count = (uint)source.data.positions.len;
        uint[] pins = unique_pins(desc.pins, vertex_count)!;
        Vec3[] world = alloc::new_array(tmem, Vec3, (sz)vertex_count);
        foreach (index, position : source.data.positions) world[index] = maths::transform_point(node.world, position);
        check_world_positions(world)!;
        ClothTopology topology = build_topology(&source.data, world)!;
        ClothCapture capture = capture_colliders(self, desc.colliders)!;
        GeometryId copy = copy_cloth_geometry(assets, &source.data)!;
        defer catch assets.remove_geometry(copy);
        ClothState* state = allocate_cloth_state(
            allocator:    self.allocator,
            vertex_count: vertex_count,
            pin_count:    (uint)pins.len,
            edge_count:   (uint)topology.edges.len,
            bend_count:   (uint)topology.bends.len,
            body_count:   (uint)capture.bodies.len,
            shape_count:  (uint)capture.shapes.len,
        )!;
        state.desc = desc;
        state.desc.pins = state.pins;
        state.colliders[..] = desc.colliders[..];
        state.desc.colliders = state.colliders;
        state.bodies[..] = capture.bodies[..];
        state.shapes[..] = capture.shapes[..];
        state.assets = assets;
        state.source = mesh.geometry;
        state.geometry = copy;
        state.source_vertex_motion = mesh.vertex_motion;
        state.rest[..] = source.data.positions[..];
        state.positions[..] = world[..];
        state.published[..] = world[..];
        state.inverse_masses[..] = 1;
        state.pins[..] = pins[..];
        foreach (slot, pin : pins) {
            state.inverse_masses[pin] = 0;
            state.pin_anchors[slot] = world[pin];
            state.pin_targets[slot] = world[pin];
        }
        state.edges[..] = topology.edges[..];
        state.bends[..] = topology.bends[..];
        self.add(node, (Cloth){ .state = state });
        mesh.geometry = copy;
        mesh.vertex_motion = true;
    };
}

<*
 Restore the source mesh and remove cloth ownership.
 @param [&in] node : "Live node with Cloth and its owned Mesh."
 @require self.has(node, Cloth), self.has(node, scene::Mesh)
*>
fn void Scene.remove_cloth(&self, Node* node) {
    ClothState* state = self.get(node, Cloth).state;
    scene::Mesh* mesh = self.get(node, scene::Mesh);
    mesh.geometry = state.source;
    mesh.vertex_motion = state.source_vertex_motion;
    self.remove_component(node, Cloth);
}

<*
 Solve and publish cloth after final node poses.
 @require self.cloth_update_serial != self.update_serial
*>
fn void PhysicsWorld.update_cloths(&self) {
    self.cloth_update_serial = self.update_serial;
    self.cloth_stats = {};
    uint steps = self.steps_last_update;
    PhysicsTuning* tuning = &self.desc.tuning;
    self.scene.@each(Cloth; Entity entity, Cloth* component) {
        ClothState* state = component.state;
        Node* node = self.scene.node(entity);
        time::Clock started = clock::now();
        foreach (slot, pin : state.pins) state.pin_targets[slot] = maths::transform_point(node.world, state.rest[pin]);
        sample_bodies(self.scene, state);
        if (steps) {
            solve_cloth(
                state:   state,
                wind:    self.scene.get(node, Wind),
                gravity: tuning.gravity,
                step_dt: tuning.fixed_dt,
                steps:   steps,
            );
        }
        time::Clock published = clock::now();
        publish_cloth(state, node.world);
        self.cloth_stats.solve_seconds += (published - started).to_sec();
        self.cloth_stats.publish_seconds += (clock::now() - published).to_sec();
        self.cloth_stats.particles += (uint)state.positions.len;
        self.cloth_stats.constraints += (uint)(state.edges.len + state.bends.len);
    };
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
    ClothState* state = ((Cloth*)component).state;
    state.assets.remove_geometry(state.geometry);
    alloc::free(*(Allocator*)user, state);
}
