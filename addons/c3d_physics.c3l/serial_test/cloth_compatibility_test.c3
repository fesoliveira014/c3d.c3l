module c3d_physics_serial_test;

import c3d;
import c3d::physics @public;
import c3d::scene;
import c3d::serial @public;

// Emitted by the Mesh version-1 and Cloth version-9 codecs at f055af03: a cloth over a mesh that predates trace_only.
const char[*] CLOTH_MESH_V1_BINARY @private = $embed("fixtures/cloth_mesh_v1.bin");

fn void test_cloth_on_a_version_one_mesh_reads_and_validates() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;

        Node* root = decode(&fixture, CLOTH_MESH_V1_BINARY[..], false)!!;
        Node* fabric = child_named(root, "fabric");
        Cloth* owner = fixture.destination.get(fabric, Cloth);
        Mesh* mesh = fixture.destination.get(fabric, Mesh);
        assert(owner && !owner.is_prepared());
        assert(c3d::same_id(mesh.geometry, fixture.geometry));
        assert(!mesh.cast_shadow && !mesh.trace && !mesh.trace_only);
        assert(owner.authoring.desc.pins == (uint[4]){ 3, 1, 1, 0 }[..]);
        assert(owner.authoring.desc.colliders.len == 1);
    };
}
