module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::serial @public;
import std::math;

const char[] LEGACY_MESH_BINARY @local = $embed("../../../test/fixtures/trace_fields_legacy/mesh-v1.bin");
const char[] LEGACY_MESH_TEXT @local = $embed("../../../test/fixtures/trace_fields_legacy/mesh-v1.jsonc");
const char[] LEGACY_INSTANCES_BINARY @local = $embed("../../../test/fixtures/trace_fields_legacy/instances-v1.bin");
const char[] LEGACY_INSTANCES_TEXT @local = $embed("../../../test/fixtures/trace_fields_legacy/instances-v1.jsonc");
const char[] LEGACY_LOD_BINARY @local = $embed("../../../test/fixtures/trace_fields_legacy/lod-v2.bin");
const char[] LEGACY_LOD_TEXT @local = $embed("../../../test/fixtures/trace_fields_legacy/lod-v2.jsonc");
const char[] MESH_V2_BINARY @local = $embed("../../../test/fixtures/mesh_v2/mesh-v2.bin");
const char[] MESH_V2_TEXT @local = $embed("../../../test/fixtures/mesh_v2/mesh-v2.jsonc");

fn Node*? read_encoded(
    Fixture* fixture,
    char[] binary,
    char[] text,
    uint encoding,
) @local {
    if (encoding == 0) return serial::read_subtree(&fixture.destination, &fixture.assets, binary);
    return serial::read_subtree_text(&fixture.destination, &fixture.assets, (String)text);
}

fn void add_trace_field_assets(Fixture* fixture) @local {
    Geometry geometry = geometry::box(
        allocator: tmem,
        width: 1,
        height: 1,
        depth: 1,
    );
    fixture.assets.add_geometry(&geometry, "trace_fields/box")!!;
    fixture.assets.add_material(material::basic({}), "trace_fields/material")!!;
}

fn void test_older_payloads_read_the_trace_fields_as_off() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        add_trace_field_assets(&fixture);
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = read_encoded(
                fixture:  &fixture,
                binary:   LEGACY_MESH_BINARY,
                text:     LEGACY_MESH_TEXT,
                encoding: encoding,
            )!!;
            Mesh* mesh = fixture.destination.get(restored, Mesh);
            assert(!mesh.cast_shadow && mesh.receive_shadow && mesh.trace && !mesh.trace_only);
            assert(mesh.morph_weights.len == 1 && mesh.morph_weights[0] == 0.25f && mesh.vertex_motion);
            assert(mesh.has_bounds_override && mesh.local_bounds.max == (Vec3){ 3, 2, 1 });
            fixture.destination.remove(restored);

            restored = read_encoded(
                fixture:  &fixture,
                binary:   LEGACY_INSTANCES_BINARY,
                text:     LEGACY_INSTANCES_TEXT,
                encoding: encoding,
            )!!;
            InstancedMesh* batch = fixture.destination.get(restored, InstancedMesh);
            assert(batch.count == 2 && batch.transforms.len == 4 && batch.transforms[1].position == (Vec3){ 4, 5, 6 });
            assert(!batch.cast_shadow && batch.receive_shadow && batch.trace && !batch.trace_sway);
            assert(batch.sway.amplitude == 0.5f && batch.fade.end == 20 && batch.has_bounds_override);
            fixture.destination.remove(restored);

            restored = read_encoded(
                fixture:  &fixture,
                binary:   LEGACY_LOD_BINARY,
                text:     LEGACY_LOD_TEXT,
                encoding: encoding,
            )!!;
            LodGroupState* group = fixture.destination.get(restored, LodGroup).state;
            assert(group.mode == INSTANCED && group.count == 1 && group.transforms.len == 3);
            assert(!group.effects.cast_shadow && group.effects.receive_shadow && !group.effects.trace);
            assert(group.effects.sway.amplitude == 0.5f && group.effects.fade.end == 20 && !group.effects.trace_sway);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_mesh_version_2_payloads_read_the_trace_facing_as_material() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        fixture.assets.add_geometry(&geometry, "mesh_v2/box")!!;
        fixture.assets.add_material(material::basic({}), "mesh_v2/material")!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = read_encoded(
                fixture:  &fixture,
                binary:   MESH_V2_BINARY,
                text:     MESH_V2_TEXT,
                encoding: encoding,
            )!!;
            Mesh* mesh = fixture.destination.get(restored, Mesh);
            assert(!mesh.cast_shadow && mesh.receive_shadow && mesh.trace && mesh.trace_only);
            assert(mesh.trace_facing == TraceFacing.MATERIAL);
            assert(mesh.morph_weights.len == 1 && mesh.morph_weights[0] == 0.25f && mesh.vertex_motion);
            assert(mesh.has_bounds_override && mesh.local_bounds.max == (Vec3){ 3, 2, 1 });
            fixture.destination.remove(restored);
        }
    };
}

fn void test_trace_fields_round_trip_in_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        add_trace_field_assets(&fixture);
        GeometryId geometry = fixture.assets.find_geometry("trace_fields/box")!!;
        MaterialId material = fixture.assets.find_material("trace_fields/material")!!;
        Node* root = fixture.source.add_node(name: "root")!!;
        Node* mesh = fixture.source.add_mesh(
            geometry: geometry,
            material: material,
            parent:   root,
            name:     "mesh",
        )!!;
        fixture.source.get(mesh, Mesh).trace_only = true;
        fixture.source.get(mesh, Mesh).trace_facing = TraceFacing.FRONT;
        Node* both = fixture.source.add_mesh(
            geometry: geometry,
            material: material,
            parent:   root,
            name:     "both",
        )!!;
        fixture.source.get(both, Mesh).trace_facing = TraceFacing.BOTH;
        Transform[1] transforms = { maths::TRANSFORM_IDENTITY };
        Node* batch = fixture.source.add_instanced_mesh(
            geometry:   geometry,
            material:   material,
            capacity:   2,
            transforms: transforms[..],
            parent:     root,
            name:       "batch",
        )!!;
        fixture.source.get(batch, InstancedMesh).trace_sway = true;
        LodPart[1] parts = { { .geometry = geometry, .material = material, .local = matrix::IDENTITY4 } };
        LodLevel[1] levels = { { .part_count = 1 } };
        LodDesc desc = { .parts = parts[..], .levels = levels[..] };
        Node* group = fixture.source.add_lod_group(
            assets: &fixture.assets,
            desc:   desc,
            parent: root,
            name:   "group",
        )!!;
        LodEffects effects = fixture.source.get(group, LodGroup).state.effects;
        effects.trace_sway = true;
        fixture.source.set_lod_effects(group, effects);

        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene:     &fixture.source,
            assets:    &fixture.assets,
            root:      root,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene:     &fixture.source,
            assets:    &fixture.assets,
            root:      root,
        )!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            Mesh* restored_mesh = fixture.destination.get(child_named(restored, "mesh"), Mesh);
            assert(restored_mesh.trace_only && restored_mesh.trace_facing == TraceFacing.FRONT);
            assert(fixture.destination.get(child_named(restored, "both"), Mesh).trace_facing == TraceFacing.BOTH);
            assert(fixture.destination.get(child_named(restored, "batch"), InstancedMesh).trace_sway);
            assert(fixture.destination.get(child_named(restored, "group"), LodGroup).state.effects.trace_sway);
            fixture.destination.remove(restored);
        }
    };
}
