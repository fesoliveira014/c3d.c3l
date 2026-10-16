module c3d_physics_cloth_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::physics;
import c3d::physics::cloth;
import c3d::scene;
import std::io;
import std::math;
import std::math::quaternion;
import std::core::mem::allocators;

const sz CAPTURE_POOL_BYTES @private = 4096;
const sz CAPTURE_VMEM_BYTES @private = 64 * mem::KB;
const uint CAPTURE_SHAPE_LIMIT @private = 1024;

fn Node* bounded_probe(
    Fixture* fixture,
    Vec3 point,
    Entity[] colliders,
    ClothCollisionDesc collisions,
) @private {
    Node* node = add_cloth_node(fixture, add_triangle(fixture, point, PROBE_REACH));
    uint[2] pins = { 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    desc.colliders = colliders;
    desc.collisions = collisions;
    fixture.scene.add_cloth(&fixture.assets, node, desc)!!;
    return node;
}

fn fault prepare_with_small_capture_pool(
    Fixture* fixture,
    Node* node,
    ClothDesc desc,
    bool eager,
) @private {
    // Small topology scratch fits; the shape capture exceeds this owned pool.
    char[2 * CAPTURE_POOL_BYTES] storage;
    ArenaAllocator backing;
    backing.init(storage[..]);
    TempAllocator* pool = allocators::new_temp_allocator(
        allocator: &backing,
        size: CAPTURE_POOL_BYTES,
        reserve: 64,
        min_size: CAPTURE_POOL_BYTES / 8,
        realloc_size: CAPTURE_POOL_BYTES,
    )!!;
    defer pool.free();
    Allocator previous = allocators::current_temp;
    TempAllocator* previous_top = allocators::top_temp;
    allocators::top_temp = pool;
    allocators::current_temp = pool;
    defer {
        allocators::current_temp = previous;
        allocators::top_temp = previous_top;
    }
    $if $feat(VMEM_TEMP):
        TempAllocator* child = pool.derive_allocator()!!;
        child.vmem.free();
        child.vmem.init(CAPTURE_VMEM_BYTES, CAPTURE_VMEM_BYTES)!!;
        assert(ClothShape::size * desc.collisions.max_shapes > child.vmem.memory.size);
    $else
        assert(ClothShape::size * desc.collisions.max_shapes > storage.len);
    $endif
    if (eager) return @catch(fixture.scene.add_cloth(&fixture.assets, node, desc));
    return @catch(cloth::prepare(&fixture.scene, &fixture.assets, node));
}

fn void test_cloth_contact_capacity_rollback_and_recovery() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    setup(&fixture, desc: weightless(), allocator: &tracker);
    defer teardown(&fixture);
    ColliderDesc[2] colliders = { sphere(0.5f), sphere(0.5f) };
    Node* body = add_body_node(&fixture, colliders[:1], kind: STATIC);
    Entity[1] owners = { body.id };
    Node* independent = add_probe(&fixture, { 10, 0.5f, 0 }, {});
    GeometryId contact_plane;
    @pool() {
        Geometry plane = geometry::plane(tmem, 2, 2);
        foreach (&position : plane.positions) position.y = 0.1f;
        plane.finalize();
        contact_plane = fixture.assets.add_geometry(&plane)!!;
    };
    ClothState* continuing = state_of(&fixture, independent);
    continuing.velocities[0] = { 1, 0, 0 };

    for (uint capacity_case = 0; capacity_case < 2; capacity_case++) {
        ClothCollisionDesc limits = cloth::default_cloth_collision_desc();
        limits.max_candidates = capacity_case == 0 ? 1 : 8;
        limits.max_contacts = capacity_case == 0 ? 8 : 1;
        Node* probe = bounded_probe(
            fixture: &fixture, point: { 0, 0.1f, 0 }, colliders: owners[..], collisions: limits,
        );
        ClothState* state = state_of(&fixture, probe);
        publish(&fixture);
        assert(!state.contact_result.failure);
        Vec3[3] solved, velocities, predicted, acceleration, published, local;
        Vec3[2] anchors, targets;
        solved[..] = state.positions[..];
        velocities[..] = state.velocities[..];
        predicted[..] = state.predicted[..];
        acceleration[..] = state.accelerations[..];
        published[..] = state.published[..];
        local[..] = geometry_of(&fixture, probe).data.positions[..];
        anchors[..] = state.pin_anchors[..];
        targets[..] = state.pin_targets[..];
        ClothBody saved_body = state.bodies[0];
        uint revision = geometry_of(&fixture, probe).header.revision;
        float other_x = continuing.positions[0].x;
        fixture.physics.remove_body(body);
        fixture.physics.add_body(body, physics::default_body_desc(STATIC), colliders[..])!!;
        fixture.physics.update(physics::DEFAULT_FIXED_DT);
        fixture.scene.update_world();
        sz allocations = tracker.total_allocation_count();
        fixture.physics.update_cloths();
        assert(tracker.total_allocation_count() == allocations);
        assert(state.contact_result.failure == c3d::CAPACITY_EXCEEDED);
        assert(state.contact_result.stage == (capacity_case == 0 ? ClothContactStage.CANDIDATES : ClothContactStage.CONTACTS));
        assert(state.contact_result.candidates == (capacity_case == 0 ? 1 : 2));
        assert(state.contact_result.peak_candidates == (capacity_case == 0 ? 1 : 2));
        assert(state.contact_result.contacts == (capacity_case == 0 ? 0 : 1));
        assert(state.contact_result.peak_contacts == (capacity_case == 0 ? 0 : 1));
        assert(state.contact_result.unresolved == (capacity_case == 0 ? 0 : 2));
        assert(fixture.physics.cloth_stats.failed == 1 && continuing.positions[0].x > other_x);
        foreach (index, value : solved) {
            assert(state.positions[index] == value && state.velocities[index] == velocities[index]);
            assert(state.predicted[index] == predicted[index] && state.accelerations[index] == acceleration[index]);
            assert(state.published[index] == published[index]);
            assert(geometry_of(&fixture, probe).data.positions[index] == local[index]);
        }
        foreach (index, value : anchors) assert(state.pin_anchors[index] == value && state.pin_targets[index] == targets[index]);
        assert(state.bodies[0].native_identity == saved_body.native_identity);
        assert(state.bodies[0].solved.position == saved_body.solved.position);
        assert(geometry_of(&fixture, probe).header.revision == revision);

        if (capacity_case == 0) {
            fixture.physics.remove_body(body);
            ColliderDesc mesh = physics::default_collider_desc(MESH);
            mesh.geometry = contact_plane;
            fixture.physics.add_body(body, physics::default_body_desc(STATIC), (&mesh)[:1])!!;
            publish(&fixture);
            assert(state.contact_result.failure == c3d::CAPACITY_EXCEEDED);
            assert(state.contact_result.stage == ClothContactStage.CANDIDATES);
            assert(state.contact_result.candidates == 1 && state.contact_result.peak_candidates == 1);
            assert(state.contact_result.contacts == 0 && state.contact_result.peak_contacts == 0);
            assert(geometry_of(&fixture, probe).header.revision == revision);
            probe.local.position.x = 2;
            publish(&fixture);
            assert(state.contact_result.failure == c3d::CAPACITY_EXCEEDED);
            assert(geometry_of(&fixture, probe).header.revision == revision + 1);
            foreach (index, value : published) {
                assert(near(published_world(&fixture, probe, (uint)index), value, CONTACT_TOLERANCE));
                assert(state.positions[index] == solved[index] && state.velocities[index] == velocities[index]);
            }
            foreach (index, value : anchors) assert(state.pin_anchors[index] == value);
            local[..] = geometry_of(&fixture, probe).data.positions[..];
            revision = geometry_of(&fixture, probe).header.revision;
            probe.local.position.x = 1e20f;
            publish(&fixture);
            assert(state.contact_result.failure == cloth::CONTACT_PRECISION_EXCEEDED);
            assert(state.contact_result.stage == ClothContactStage.REEXPRESSION);
            assert(geometry_of(&fixture, probe).header.revision == revision);
            foreach (index, value : local) {
                assert(geometry_of(&fixture, probe).data.positions[index] == value);
                assert(state.positions[index] == solved[index] && state.published[index] == published[index]);
            }
            probe.local.position = {};
        }

        fixture.physics.remove_body(body);
        fixture.physics.add_body(body, physics::default_body_desc(STATIC), colliders[:1])!!;
        publish(&fixture);
        assert(!state.contact_result.failure && state.contact_result.stage == ClothContactStage.NONE);
        assert(published_world(&fixture, probe, 0).length() >= 0.51f - CONTACT_TOLERANCE);
        fixture.scene.remove_cloth(probe);
        fixture.scene.remove(probe);
    }
}

fn void test_cloth_unresolved_contacts_preserve_pins_and_publication() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc ceiling = physics::default_collider_desc(BOX);
    ceiling.half_extents = { 2, 1, 2 };
    Node* body = add_body_node(&fixture, (&ceiling)[:1], { 0, 1.01f, 0 }, STATIC);
    Entity[1] owners = { body.id };
    Node* probe = add_cloth_node(&fixture, add_triangle(&fixture, { 0, 0.005f, 0 }, 0.5f));
    uint[2] pins = { 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    desc.colliders = owners[..];
    desc.collide_ground = true;
    fixture.scene.add_cloth(&fixture.assets, probe, desc)!!;
    ClothState* state = state_of(&fixture, probe);
    Vec3[3] original;
    original[..] = state.positions[..];
    uint revision = geometry_of(&fixture, probe).header.revision;
    publish(&fixture);
    assert(state.contact_result.failure == cloth::CONTACT_UNRESOLVED);
    assert(state.contact_result.stage == ClothContactStage.RESOLVE && state.contact_result.unresolved > 0);
    assert(state.contact_result.pinned_overlaps > 0);
    assert(geometry_of(&fixture, probe).header.revision == revision);
    foreach (index, value : original) {
        assert(state.positions[index] == value && state.published[index] == value);
        assert(published_world(&fixture, probe, (uint)index) == value);
    }
    body.local.position.y = 2;
    publish(&fixture);
    assert(!state.contact_result.failure && state.contact_result.pinned_overlaps > 0);
    assert(published_world(&fixture, probe, 0).y >= desc.thickness - CONTACT_TOLERANCE);
    foreach (pin : pins) assert(published_world(&fixture, probe, pin) == original[pin]);
}

fn void test_cloth_contact_rounding_mode_rejects_without_mutation() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* probe = add_probe(&fixture, { 0, 0, 0 }, {});
    ClothState* state = state_of(&fixture, probe);
    uint revision = geometry_of(&fixture, probe).header.revision;
    int saved = $$get_rounding_mode();
    defer $$set_rounding_mode(saved);
    $$set_rounding_mode((int)math::RoundingMode.TOWARD_INFINITY);
    publish(&fixture);
    assert($$get_rounding_mode() == (int)math::RoundingMode.TOWARD_INFINITY);
    assert(state.contact_result.failure == cloth::CONTACT_PRECISION_EXCEEDED);
    assert(state.contact_result.stage == ClothContactStage.ARITHMETIC);
    assert(geometry_of(&fixture, probe).header.revision == revision);
    assert(state.positions[0] == (Vec3){} && state.published[0] == (Vec3){});
    $$set_rounding_mode(saved);
    publish(&fixture);
    assert(!state.contact_result.failure);
}

fn void test_cloth_rebuild_refreshes_cooked_and_compound_generations() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    PhysicsDesc world_desc = weightless();
    world_desc.snapshot_capacity = 2;
    setup(&fixture, desc: world_desc, allocator: &tracker);
    defer teardown(&fixture);
    GeometryId geometry;
    @pool() {
        Geometry box = geometry::box(allocator: tmem, width: 2, height: 1, depth: 2);
        geometry = fixture.assets.add_geometry(&box)!!;
    };
    ColliderDesc hull = physics::default_collider_desc(HULL);
    hull.geometry = geometry;
    Node* body = add_body_node(&fixture, (&hull)[:1], kind: STATIC);
    Entity owner = body.id;
    Entity[1] owners = { owner };
    ClothCollisionDesc limits = cloth::default_cloth_collision_desc();
    limits.max_shapes = 2;
    Node* probe = bounded_probe(
        fixture: &fixture, point: { 0, 0.4f, 0 }, colliders: owners[..], collisions: limits,
    );
    ClothState* state = state_of(&fixture, probe);
    publish(&fixture);
    assert(!state.contact_result.failure && state.contact_result.contacts > 0);
    assert(math::abs(published_world(&fixture, probe, 0).y - 0.51f) <= CONTACT_TOLERANCE);
    SnapshotHandle old_snapshot = state.shapes[0].snapshot;
    uint[4] native_identity = state.bodies[0].native_identity;

    @pool() {
        Geometry taller = geometry::box(allocator: tmem, width: 2, height: 2, depth: 2);
        fixture.assets.replace_geometry(geometry, &taller)!!;
    };
    fixture.scene.get(body, PhysicsBody).mark_changed();
    fixture.physics.update(0);
    fixture.scene.update_world();
    sz allocations = tracker.total_allocation_count();
    fixture.physics.update_cloths();
    assert(tracker.total_allocation_count() == allocations);
    assert(!state.contact_result.failure);
    assert(state.bodies[0].native_identity != native_identity);
    assert(state.shapes[0].snapshot.index != old_snapshot.index || state.shapes[0].snapshot.generation != old_snapshot.generation);
    assert(math::abs(published_world(&fixture, probe, 0).y - 1.01f) <= CONTACT_TOLERANCE);
    publish(&fixture);
    assert(!state.contact_result.failure);

    CompoundChild[3] children;
    children[0] = physics::default_compound_child(HULL);
    children[0].geometry = geometry;
    children[1] = physics::default_compound_child(SPHERE);
    children[1].radius = 0.25f;
    children[1].local.position = { 2, 0, 0 };
    children[2] = children[1];
    children[2].local.position = { -2, 0, 0 };
    ColliderDesc compound = physics::default_collider_desc(COMPOUND);
    compound.children = children[..];
    Vec3 saved = state.published[0];
    uint revision = geometry_of(&fixture, probe).header.revision;
    fixture.physics.remove_body(body);
    fixture.physics.add_body(body, physics::default_body_desc(STATIC), (&compound)[:1])!!;
    publish(&fixture);
    assert(state.contact_result.failure == c3d::CAPACITY_EXCEEDED && state.contact_result.stage == ClothContactStage.BINDINGS);
    assert(state.shapes.len == 1 && state.published[0] == saved);
    assert(geometry_of(&fixture, probe).header.revision == revision);

    fixture.physics.remove_body(body);
    assert(fixture.physics.snapshots.slots[old_snapshot.index].generation != old_snapshot.generation);
    compound.children = children[:2];
    fixture.physics.add_body(body, physics::default_body_desc(STATIC), (&compound)[:1])!!;
    fixture.physics.update(0);
    fixture.scene.update_world();
    allocations = tracker.total_allocation_count();
    fixture.physics.update_cloths();
    assert(tracker.total_allocation_count() == allocations);
    assert(!state.contact_result.failure && state.shapes.len == 2);
    assert(math::abs(published_world(&fixture, probe, 0).y - 1.01f) <= CONTACT_TOLERANCE);

    fixture.physics.teleport(node: body, position: { 0, 0.2f, 0 }, rotation: quaternion::IDENTITY);
    publish(&fixture);
    assert(!state.contact_result.failure);
    assert(math::abs(published_world(&fixture, probe, 0).y - 1.21f) <= CONTACT_TOLERANCE);
    fixture.scene.remove(body);
    Node* replacement = add_body_node(&fixture, (&hull)[:1], kind: STATIC);
    assert(replacement.id.index == owner.index && replacement.id.generation != owner.generation);
    publish(&fixture);
    assert(!state.contact_result.failure && state.shapes.len == 0);
    assert(near(published_world(&fixture, probe, 0), { 0, 0.4f, 0 }));
}

fn void test_cloth_contact_settings_reject_invalid_values_atomically() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    Node* node = add_cloth_node(&fixture, add_grid(&fixture, 1));
    for (uint setting = 0; setting < 6; setting++) {
        ClothDesc desc = cloth::default_cloth_desc();
        switch (setting) {
            case 0: desc.collisions.contact_tolerance = 0;
            case 1: desc.collisions.contact_tolerance = bitcast(0x7fc00000u, float);
            case 2: desc.collisions.contact_iterations = 0;
            case 3: desc.collisions.max_shapes = 0;
            case 4: desc.collisions.max_candidates = 0;
            case 5: desc.collisions.max_contacts = 0;
        }
        assert(rejected_atomically(&fixture, node, desc) == c3d::INVALID_ARGUMENT);
    }
}

fn void test_cloth_mesh_asymmetric_bounds_keep_near_edge_contact() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    GeometryId geometry;
    @pool() {
        Geometry triangle = {
            .positions = alloc::new_array(tmem, Vec3, 6),
            .indices = alloc::new_array(tmem, uint, 6),
        };
        triangle.positions[..] = ((Vec3[6]){ { -0.001f, 0, -1 }, { -0.001f, 0, 1 }, { 1, 0, 0 }, { 65536, 0, 0 }, { 65536, 0, 32 }, { 65568, 0, 0 } })[..];
        triangle.indices[..] = { 0, 1, 2, 3, 4, 5 }[..];
        triangle.finalize();
        geometry = fixture.assets.add_geometry(&triangle)!!;
    };
    ColliderDesc mesh = physics::default_collider_desc(MESH);
    mesh.geometry = geometry;
    Node* body = add_body_node(&fixture, (&mesh)[:1], kind: STATIC);
    Entity[1] owners = { body.id };
    Node* probe = add_cloth_node(&fixture, add_triangle(&fixture, { -0.0005f, 0, 0 }, PROBE_REACH));
    uint[2] pins = { 1, 2 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.stretch_stiffness = 0;
    desc.bend_stiffness = 0;
    desc.thickness = 0.0002f;
    desc.collisions.contact_tolerance = 0.00001f;
    desc.colliders = owners[..];
    fixture.scene.add_cloth(&fixture.assets, probe, desc)!!;
    publish(&fixture);
    ClothState* state = state_of(&fixture, probe);
    assert(!state.contact_result.failure);
    assert(state.contact_result.contacts > 0);
    assert(math::abs(published_world(&fixture, probe, 0).y) >= desc.thickness - desc.collisions.contact_tolerance);
    // A valid nonzero mesh scale need not have a finite binary32 reciprocal.
    fixture.physics.remove_body(body);
    mesh.local.scale = { 1e-40f, 1e-40f, 1e-40f };
    fixture.physics.add_body(body, physics::default_body_desc(STATIC), (&mesh)[:1])!!;
    Node* tiny = bounded_probe(
        fixture: &fixture, point: {}, colliders: owners[..], collisions: cloth::default_cloth_collision_desc(),
    );
    publish(&fixture);
    ClothState* tiny_state = state_of(&fixture, tiny);
    assert(!tiny_state.contact_result.failure && tiny_state.contact_result.contacts > 0);
    assert(math::abs(published_world(&fixture, tiny, 0).y) >= 0.01f - CONTACT_TOLERANCE);
}

fn void test_cloth_zero_step_box_uses_exact_final_endpoint() @test {
    Fixture fixture;
    setup(&fixture, weightless());
    defer teardown(&fixture);
    ColliderDesc box = physics::default_collider_desc(BOX);
    box.half_extents = { 0.5f, 0.5f, 0.5f };
    Node* body = add_body_node(&fixture, (&box)[:1], { 65536, 0, 0 }, STATIC);
    Entity[1] owners = { body.id };
    Node* probe = bounded_probe(
        fixture: &fixture,
        point: { -0.409f, 0, 0 },
        colliders: owners[..],
        collisions: cloth::default_cloth_collision_desc(),
    );
    publish(&fixture);
    ClothState* state = state_of(&fixture, probe);
    assert(!state.contact_result.failure && state.bodies[0].solved.position.x == 65536);
    Vec3 solved = state.positions[0];
    Vec3 velocity = state.velocities[0];
    fixture.physics.update(0);
    body.local.position.x = 0.1f;
    fixture.scene.update_world();
    fixture.physics.update_cloths();
    Vec3 output = published_world(&fixture, probe, 0);
    double separation = (double)body.local.position.x - box.half_extents.x - output.x;
    io::printfn("endpoint_case,solved_x,%.9f,current_x,%.9f,contact_frame_x,%.9f,published_x,%.9f,separation,%.9f",
        state.bodies[0].solved.position.x, body.local.position.x, state.shape_starts[0].x, output.x, separation);
    assert(!state.contact_result.failure);
    assert(separation >= (double)state.desc.thickness - state.desc.collisions.contact_tolerance);
    assert(state.shape_starts[0].x == body.local.position.x);
    assert(state.positions[0] == solved && state.velocities[0] == velocity);
    assert(state.bodies[0].solved.position.x == 65536);
}

fn void test_cloth_capture_scratch_failure_preserves_pending_and_eager_ownership() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    Fixture fixture;
    setup(&fixture, desc: weightless(), allocator: &tracking);
    defer {
        teardown(&fixture);
        assert(!tracking.has_leaks());
    }
    GeometryId source = add_grid(&fixture, 1);
    Node* pending_node = add_cloth_node(&fixture, source);
    Node* eager_node = add_cloth_node(&fixture, source);
    fixture.scene.get(pending_node, scene::Mesh).vertex_motion = true;
    uint[2] pins = { 0, 1 };
    ClothDesc desc = pinned_desc(pins[..]);
    desc.collisions.max_shapes = CAPTURE_SHAPE_LIMIT;
    fixture.scene.attach_cloth(&fixture.assets, pending_node, desc)!!;
    Cloth* pending = fixture.scene.get(pending_node, Cloth);
    ClothAuthoring* authoring = pending.authoring;
    uint geometries = fixture.assets.geometries.free_count;
    uint nodes = fixture.scene.world.entities.free_count;
    uint revision = fixture.assets.geometry(source).header.revision;
    Allocator previous_temp = allocators::current_temp;
    TempAllocator* previous_top = allocators::top_temp;
    assert(prepare_with_small_capture_pool(
        fixture: &fixture,
        node: pending_node,
        desc: desc,
        eager: false,
    ) == c3d::CAPACITY_EXCEEDED);
    assert(allocators::current_temp.ptr == previous_temp.ptr && allocators::top_temp == previous_top);
    assert(!pending.is_prepared() && pending.authoring == authoring);
    assert(authoring.desc.collisions.max_shapes == CAPTURE_SHAPE_LIMIT && authoring.desc.pins == pins[..]);
    assert(c3d::same_id(fixture.scene.get(pending_node, scene::Mesh).geometry, source));
    assert(fixture.scene.get(pending_node, scene::Mesh).vertex_motion);
    assert(fixture.assets.geometries.free_count == geometries && fixture.scene.world.entities.free_count == nodes);
    assert(fixture.assets.geometry(source).header.revision == revision);

    assert(prepare_with_small_capture_pool(
        fixture: &fixture,
        node: eager_node,
        desc: desc,
        eager: true,
    ) == c3d::CAPACITY_EXCEEDED);
    assert(allocators::current_temp.ptr == previous_temp.ptr && allocators::top_temp == previous_top);
    assert(!fixture.scene.has(eager_node, Cloth) && fixture.scene.count(Cloth) == 1);
    assert(c3d::same_id(fixture.scene.get(eager_node, scene::Mesh).geometry, source));
    assert(!fixture.scene.get(eager_node, scene::Mesh).vertex_motion);
    assert(fixture.assets.geometries.free_count == geometries && fixture.scene.world.entities.free_count == nodes);
    assert(pending.authoring == authoring && !pending.is_prepared());
    $if $feat(VMEM_TEMP):
        io::printn("capture_scratch_backend,vmem");
    $else
        io::printn("capture_scratch_backend,fixed_arena");
    $endif

    cloth::prepare(&fixture.scene, &fixture.assets, pending_node)!!;
    fixture.scene.add_cloth(&fixture.assets, eager_node, desc)!!;
    assert(pending.is_prepared() && fixture.scene.get(eager_node, Cloth).is_prepared());
    assert(pending.authoring == authoring);
}
