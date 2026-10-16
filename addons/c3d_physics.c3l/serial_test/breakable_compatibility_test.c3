module c3d_physics_serial_test;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import c3d::serial @public;
import std::core::mem::allocators;
import b3;

const char[*] BREAKABLE_V1_BINARY @private = $embed("fixtures/breakable_v1.bin");
const char[*] BREAKABLE_V1_TEXT @private = $embed("fixtures/breakable_v1.json");

struct LegacyDecodeProbe @private {
    serial::ReadFn original;
    RejectSize* rejector;
    bool truncate;
    bool entered;
}

LegacyDecodeProbe legacy_decode_probe @private;

fn void test_breakable_v1_fixtures_keep_current_pose_recipes() @test {
    serial::register_core_codecs()!!;
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);

            char[] bytes = text_mode ? BREAKABLE_V1_TEXT[..] : BREAKABLE_V1_BINARY[..];
            Node* root = decode(&fixture, bytes, text_mode)!!;
            Breakable* owner = fixture.destination.get(root, Breakable);
            assert(owner && !owner.is_prepared());
            assert(owner.state.pieces.len == 3 && owner.state.desc.break_force == 2000);
            assert(owner.state.form == PIECES && root.local.position == (Vec3){ 3, 4, 5 });
            assert(owner.state.piece_view(2).rest_frame.position == (Vec3){ 4, 0, 0 });
            assert(fixture.destination.count(PhysicsBody) == 0 && fixture.destination.count(RigidBody) == 0);

            PhysicsWorld world = create_world(&fixture.destination, &fixture.assets);
            defer physics::destroy_physics_world(&world);
            world.prepare_breakable(root)!!;
            owner = fixture.destination.get(root, Breakable);
            assert(owner.is_prepared() && owner.state.welds.len == 1);
            assert(owner.state.welds[0].piece_a == 0 && owner.state.welds[0].piece_b == 1);
            foreach (entity : owner.state.pieces) {
                b3::BodyId body = world.body(fixture.destination.node(entity))!!;
                assert(body.linear_velocity() == (Vec3){} && body.angular_velocity() == (Vec3){});
            }
        };
    }
}

fn void? read_breakable_v1_with_fault(serial::Reader* reader, serial::ReadContext* context) @private {
    legacy_decode_probe.entered = true;
    if (legacy_decode_probe.truncate) {
        reader.bytes = reader.bytes[:reader.bytes.len - 1];
    } else {
        legacy_decode_probe.rejector.enabled = true;
    }
    defer legacy_decode_probe.rejector.enabled = false;
    return legacy_decode_probe.original(reader, context);
}

fn void test_breakable_v1_decoder_faults_restore_the_existing_destination() @test {
    serial::register_core_codecs()!!;
    foreach (truncated : (bool[2]){ true, false }) {
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();
        {
            @pool() {
                Fixture fixture;
                create_fixture(&fixture, &tracker);
                defer destroy_fixture(&fixture);
                Node* existing = fixture.destination.add_mesh(
                    geometry: fixture.geometry,
                    material: {},
                    name: "existing",
                )!!;
                Entity existing_id = existing.id;
                uint free_nodes = fixture.destination.world.entities.free_count;
                uint free_geometries = fixture.assets.geometries.free_count;
                sz allocations = tracker.allocation_count();
                RejectSize rejector = {
                    .backing = &tracker,
                    .size = (sz)(3 * BreakableSavedPieceV1::size
                        + BreakableSavedPieceV1::alignment - 1 + serial::Acquisition::size),
                };
                serial::SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
                defer serial::destroy_serial_diagnostic(&diagnostic);

                serial::BinaryCompatibility* compatibility = &serial::codecs[ecs::assigned_slot(Breakable)!!]
                    .described.codec.binary_compatibility[0];
                serial::ReadFn original = compatibility.read;
                compatibility.read = &read_breakable_v1_with_fault;
                defer compatibility.read = original;
                legacy_decode_probe = { .original = original, .rejector = &rejector, .truncate = truncated };
                defer legacy_decode_probe = {};
                defer rejector.enabled = false;
                fault excuse = @catch(decode(
                    fixture: &fixture,
                    bytes: BREAKABLE_V1_BINARY[..],
                    text_mode: false,
                    options: { .allocator = &rejector, .diagnostic = &diagnostic },
                ));
                compatibility.read = original;
                assert(legacy_decode_probe.entered && !rejector.enabled);
                assert(excuse == (truncated ? c3d::ASSET_FORMAT_ERROR : c3d::CAPACITY_EXCEEDED));
                assert(rejector.failures == (truncated ? 0 : 1));
                assert(diagnostic.type_name == "breakable" && diagnostic.cause == excuse);
                assert(fixture.destination.world.entities.free_count == free_nodes);
                assert(fixture.destination.world.is_alive(existing_id) && fixture.destination.count(scene::Mesh) == 1);
                assert(fixture.destination.count(Breakable) == 0 && fixture.destination.count(PhysicsBody) == 0);
                assert(fixture.assets.geometries.free_count == free_geometries && tracker.allocation_count() == allocations);
            };
        }
        assert(!tracker.has_leaks());
    }
}
