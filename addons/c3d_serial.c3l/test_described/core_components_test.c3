module c3d::serial::test_described;

import c3d;
import c3d::camera;
import c3d::describe;
import c3d::light;
import c3d::scene;
import c3d::serial @public;
import std::math;

fn void test_core_values_round_trip_both_encodings_with_owned_mesh_weights() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* source = fixture.source.add_node(name: "values")!!;
        float[] weights = alloc::new_array(fixture.source.allocator, float, 2);
        weights[0] = 0.25f;
        weights[1] = 0.75f;
        fixture.source.add(source, (Mesh){ .cast_shadow = true, .trace = true, .morph_weights = weights });
        fixture.source.add(source, camera::perspective_deg(50, 0.2f));
        fixture.source.add(source, light::directional({ 0.4f, 0.5f, 0.8f }, 2));
        fixture.source.add(source, light::probe_volume({ 3, 4, 5 }, { 3, 4, 5 }));
        fixture.source.add(source, light::ATMOSPHERE_EARTH);
        fixture.source.add(source, light::HEIGHT_FOG_DEFAULT);
        fixture.source.add(source, light::reflection_probe({ 2, 3, 4 }, {}));
        fixture.source.add(source, scene::default_decal_desc({}).decal);
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        assert(bytes == serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!);
        assert(text == serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!);
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            Mesh* mesh = fixture.destination.get(restored, Mesh);
            assert(mesh.morph_weights.ptr != weights.ptr && mesh.morph_weights.len == 2);
            assert(mesh.morph_weights[0] == 0.25f && mesh.morph_weights[1] == 0.75f);
            assert(fixture.destination.get(restored, ProbeVolume).counts == (uint[<3>]){ 3, 4, 5 });
            assert(fixture.destination.get(restored, Camera).near == 0.2f);
            assert(fixture.destination.get(restored, Light).intensity == 2);
            assert(fixture.destination.get(restored, Atmosphere).planet_radius == light::ATMOSPHERE_EARTH.planet_radius);
            assert(fixture.destination.get(restored, HeightFog).falloff == light::HEIGHT_FOG_DEFAULT.falloff);
            assert(fixture.destination.get(restored, ReflectionProbe).half_extents == (Vec3){ 2, 3, 4 });
            assert(fixture.destination.get(restored, Decal).weights.normal == 1);
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            assert(text == serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(restored);
        }
        assert(weights[0] == 0.25f && weights[1] == 0.75f);
    };
}

fn void test_core_value_validity_rejects_invalid_writes_and_text_reads() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* source = fixture.source.add_node(name: "checked")!!;
        fixture.source.add(source, light::probe_volume({ 3, 4, 5 }, { 3, 4, 5 }));
        fixture.source.add(source, light::ATMOSPHERE_EARTH);
        fixture.source.add(source, light::HEIGHT_FOG_DEFAULT);
        fixture.source.add(source, light::reflection_probe({ 2, 3, 4 }, {}));
        String valid = fixture_text(&fixture, source);
        String[4] names = { "c3d.ProbeVolume", "c3d.Atmosphere", "c3d.HeightFog", "c3d.ReflectionProbe" };
        String[4] fields = { "counts", "planet_radius", "falloff", "half_extents" };
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: valid,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        uint components = member(&document, member(&document, 0, "nodes") + 1, "components");
        foreach (index, name : names) {
            switch (index) {
                case 0: fixture.source.get(source, ProbeVolume).counts.x = 0;
                case 1: fixture.source.get(source, Atmosphere).planet_radius = -1;
                case 2: fixture.source.get(source, HeightFog).falloff = -1;
                case 3: fixture.source.get(source, ReflectionProbe).half_extents.x = -1;
            }
            assert(@catch(serial::write_subtree(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
            )) == c3d::INVALID_ARGUMENT);
            assert(@catch(serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
            )) == c3d::INVALID_ARGUMENT);
            *fixture.source.get(source, ProbeVolume) = light::probe_volume({ 3, 4, 5 }, { 3, 4, 5 });
            *fixture.source.get(source, Atmosphere) = light::ATMOSPHERE_EARTH;
            *fixture.source.get(source, HeightFog) = light::HEIGHT_FOG_DEFAULT;
            *fixture.source.get(source, ReflectionProbe) = light::reflection_probe({ 2, 3, 4 }, {});
            uint value = member(&document, member(&document, components, name), "value");
            uint token = member(&document, value, fields[index]);
            if (document.values[token].kind == ARRAY) token++;
            TextValue field = document.values[token];
            String invalid = string::tformat("%s%s%s", valid[:field.offset], index == 0 ? "0" : "-1",
                valid[field.offset + field.length..]);
            uint before = fixture.destination.world.entities.free_count;
            assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, invalid)) == c3d::INVALID_ARGUMENT);
            assert(fixture.destination.world.entities.free_count == before && fixture.destination.root.first_child == null);
        }
        assert(fixture_text(&fixture, source) == valid);
    };
}

fn void test_core_mesh_copy_failure_attaches_nothing() @test {
    Fixture fixture;
    create_fixture(&fixture);
    defer destroy_fixture(&fixture);
    serial::register_core_codecs()!!;
    Node* node = fixture.destination.add_node()!!;
    float[2] weights = { 0.25f, 0.75f };
    Mesh mesh = { .morph_weights = weights[..] };
    FailingAllocator counter = { .failure = 1 };
    fixture.destination.allocator = &counter;
    defer fixture.destination.allocator = mem;
    ReadContext context = { .scene = &fixture.destination, .node = node };
    serial::CodecEntry* entry = &serial::codecs[c3d::ecs::assigned_slot(Mesh)!!];
    assert(@catch(entry.described.codec.attach(&mesh, &context)) == c3d::CAPACITY_EXCEEDED);
    assert(!fixture.destination.has(node, Mesh) && !counter.outstanding);
    assert(weights == (float[2]){ 0.25f, 0.75f });
}
