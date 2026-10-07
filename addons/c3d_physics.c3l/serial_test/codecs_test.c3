module c3d_physics_serial_test;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import c3d::serial;
import std::core::mem::allocators;
import std::math;
import b3;

struct CopyFailure (Allocator) @private {
    Allocator backing;
    bool enabled;
    uint copies;
}

fn void*? CopyFailure.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.enabled && size > 64 && ++self.copies == 2) return mem::OUT_OF_MEMORY~;
    return self.backing.acquire(size, init_type, alignment);
}

fn void*? CopyFailure.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    return self.backing.resize(pointer, size, alignment);
}

fn void CopyFailure.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
}

fn void test_physics_serial_registration() @test {
    physics::register_serial_codecs()!!;
    assert(serial::described_type(CollisionFilter)!!.layout == 0xada86db77bf9d58b);
    assert(serial::described_type(ColliderDesc)!!.layout == 0xdd2a19f055eaf423);
    assert(serial::described_type(physics::BodyAuthoring)!!.layout == 0xed9972ba2248fa8b);
    assert(serial::described_type(physics::JointAuthoring)!!.layout == 0x448b33882e32ee3e);
    @pool() {
        String schema = serial::write_schema(tmem)!!;
        assert(schema.contains("physics_body") && schema.contains("physics_joint"));
        assert(schema.contains("height_field") && schema.contains("face_materials"));
    };
}

fn void test_physics_body_both_formats_copy_all_nested_authoring() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            SurfaceMaterialDesc[2] surfaces = {
                { .friction = 0.1f, .restitution = 0.2f, .rolling_resistance = 0.3f, .tangent_velocity = { 1, 2, 3 }, .id = (SurfaceMaterialId)ulong::max },
                { .friction = 0.7f, .id = (SurfaceMaterialId)123456789 },
            };
            char[3] material_indices = { 0, 1, 255 };
            float[4] heights = { -1, 0.5f, 2, 3 };
            CompoundChild[2] children = {
                physics::default_compound_child(HULL), physics::default_compound_child(MESH),
            };
            foreach (index, &child : children) {
                child.geometry = fixture.geometry;
                child.local.position = { (float)index, 2, 3 };
                child.radius = 0.5f;
                child.half_height = 0.75f;
                child.half_extents = { 1, 2, 3 };
                child.material = surfaces[index];
                child.face_materials = &surfaces;
                child.material_indices = &material_indices;
            }
            ColliderDesc[7] colliders;
            foreach (index, &collider : colliders) {
                *collider = physics::default_collider_desc((ColliderKind)index);
                collider.local.position = { (float)index, 1, -2 };
                collider.radius = 0.4f;
                collider.half_height = 1;
                collider.half_extents = { 2, 3, 4 };
                collider.geometry = fixture.geometry;
                collider.height_field = { .heights = &heights, .count_x = 2, .count_z = 2, .texture = fixture.texture };
                collider.children = &children;
                collider.density = 456;
                collider.explosion_scale = 1.75f;
                collider.material = surfaces[0];
                collider.face_materials = &surfaces;
                collider.material_indices = &material_indices;
                collider.sensor = index == 0;
                collider.contact_events = true;
                collider.hit_events = true;
                collider.filter = { .category = 8, .mask = 16, .group = -123 };
            }
            BodyDesc body = physics::default_body_desc(KINEMATIC);
            body.name = "copied \"body\"";
            body.linear_velocity = { 1, 2, 3 };
            body.angular_velocity = { 4, 5, 6 };
            body.linear_damping = 0.2f;
            body.angular_damping = 0.3f;
            body.gravity_scale = -0.5f;
            body.allow_sleep = false;
            body.bullet = true;
            body.disabled = true;
            body.locks = { .linear_x = true, .linear_z = true, .angular_y = true };
            fixture.source.add_physics_body(fixture.root, body, &colliders)!!;
            fixture.source.add(fixture.root, (Wind){ .velocity = { 1, 2, 3 }, .drag = 0.3f, .lift = 0.4f, .max_speed = 8 });
            fixture.source.add(fixture.root, (Force){ .force = { 4, 5, 6 }, .local_point = { 7, 8, 9 } });
            fixture.source.add(fixture.root, (Buoyancy){ .fluid_density = 1025, .linear_drag = 7, .submerged_fraction = 0.75f });
            fixture.source.get(fixture.root, PhysicsBody).status = FAILED;
            fixture.source.get(fixture.root, PhysicsBody).failure = physics::SOURCE_UNAVAILABLE;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            PhysicsBody* actual = fixture.destination.get(restored, PhysicsBody);
            PhysicsBody* original = fixture.source.get(fixture.root, PhysicsBody);
            assert(actual.status == PENDING && !actual.failure && actual.failed_revisions == 0);
            assert(actual.body.name == body.name && actual.body.name.ptr != original.body.name.ptr);
            assert(actual.body.linear_velocity == body.linear_velocity && actual.body.angular_velocity == body.angular_velocity);
            assert(actual.colliders.len == 7 && actual.colliders.ptr != original.colliders.ptr);
            foreach (index, collider : actual.colliders) {
                assert(collider.kind == (ColliderKind)index && collider.filter.group == -123);
                assert(collider.face_materials.ptr != original.colliders[index].face_materials.ptr);
                assert(collider.children.ptr != original.colliders[index].children.ptr);
                assert(collider.children[1].material_indices == material_indices[..]);
                assert(collider.height_field.heights == heights[..]);
                assert((ulong)collider.material.id == ulong::max);
            }
            assert(fixture.destination.get(restored, Buoyancy).submerged_fraction == 0);
            assert(fixture.destination.get(restored, Wind).lift == 0.4f);
            assert(fixture.destination.get(restored, Force).local_point == (Vec3){ 7, 8, 9 });
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
        };
    }
}

fn void test_physics_joints_both_formats_cover_every_kind_and_normal_sync() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Node* anchor = add_sphere(
                scene: &fixture.source,
                parent: fixture.root,
                name: "anchor",
                kind: STATIC,
            );
            foreach (kind : JointKind::values) {
                Node* body = add_sphere(
                    scene: &fixture.source,
                    parent: fixture.root,
                    name: JointKind::names[kind.ordinal],
                    kind: DYNAMIC,
                );
                body.local.position = { 0, 2, 0 };
                JointDesc joint = physics::default_joint_desc(kind, anchor.id);
                joint.frame.position = { 0.1f, 0.2f, 0.3f };
                joint.force_threshold = 1e20f;
                joint.torque_threshold = 1e20f;
                joint.collide_connected = false;
                fixture.source.add_physics_joint(body, joint)!!;
            }
            fixture.source.update_world();
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )!!;
            Node* restored = decode(&fixture, bytes, text_mode)!!;
            assert(fixture.destination.count(PhysicsJoint) == JointKind::values.len && fixture.destination.count(Joint) == 0);
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
            PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            world.update(0);
            assert(world.build_failures().len == 0);
            assert(fixture.destination.count(RigidBody) == JointKind::values.len + 1);
            assert(fixture.destination.count(Joint) == JointKind::values.len);
            fixture.destination.@each(PhysicsJoint; entity, joint) {
                assert(joint.status == LIVE && !joint.failure);
                assert(joint.desc.frame.position == (Vec3){ 0.1f, 0.2f, 0.3f });
                assert(fixture.destination.node(joint.desc.other).name == "anchor");
            };
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            )!!);
        };
    }
}

fn void test_physics_late_body_copy_failure_rolls_back_owned_arrays() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        TrackingAllocator tracking;
        tracking.init(mem);
        defer tracking.free();
        {
            CopyFailure failure = { .backing = &tracking };
            Fixture fixture;
            create_fixture(&fixture, &failure);
            defer destroy_fixture(&fixture);
            add_sphere(
                scene: &fixture.source,
                parent: fixture.root,
                name: "first",
                kind: STATIC,
            );
            add_sphere(
                scene: &fixture.source,
                parent: fixture.root,
                name: "second",
                kind: DYNAMIC,
            );
            @pool() {
                char[] bytes = encode(
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: fixture.root,
                    text_mode: text_mode,
                )!!;
                uint before = fixture.destination.world.entities.free_count;
                serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT;
                options.allocator = mem;
                failure.enabled = true;
                assert(@catch(decode(
                    fixture: &fixture,
                    bytes: bytes,
                    text_mode: text_mode,
                    options: options,
                )) == c3d::CAPACITY_EXCEEDED);
                failure.enabled = false;
                assert(failure.copies == 2);
                assert(fixture.destination.world.entities.free_count == before && fixture.destination.count(PhysicsBody) == 0);
                assert(fixture.destination.root.first_child == null);
                assert(@ok(decode(&fixture, bytes, text_mode)));
            };
        }
        assert(!tracking.has_leaks());
    }
}

fn void test_physics_joint_required_reference_rejects_deleted_reused_nodes() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Node* first = add_sphere(
                scene: &fixture.source,
                parent: fixture.root,
                name: "first",
                kind: STATIC,
            );
            Node* second = add_sphere(
                scene: &fixture.source,
                parent: fixture.root,
                name: "second",
                kind: DYNAMIC,
            );
            Entity removed = first.id;
            fixture.source.add_physics_joint(second, physics::default_joint_desc(DISTANCE, first.id))!!;
            fixture.source.remove(first);
            Node* replacement = fixture.source.add_node(fixture.root, "replacement")!!;
            assert(replacement.id.index == removed.index && !c3d::same_id(replacement.id, removed));
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == physics::NO_BODY);
        };
    }
}

fn void test_physics_export_rejects_empty_body_and_self_joint() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Node* body = add_sphere(
                scene: &fixture.source,
                parent: fixture.root,
                name: "body",
                kind: DYNAMIC,
            );
            PhysicsBody* authoring = fixture.source.get(body, PhysicsBody);
            ColliderDesc[] original = authoring.colliders;
            authoring.colliders = {};
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            authoring.colliders = original;
            fixture.source.add_physics_joint(body, physics::default_joint_desc(DISTANCE, fixture.root.id))!!;
            PhysicsJoint* joint = fixture.source.get(body, PhysicsJoint);
            joint.desc.other = body.id;
            assert(@catch(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )) == c3d::INVALID_ARGUMENT);
            joint.desc.other = fixture.root.id;
            assert(@ok(encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.root,
                text_mode: text_mode,
            )));
        };
    }
}
