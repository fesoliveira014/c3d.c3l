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
