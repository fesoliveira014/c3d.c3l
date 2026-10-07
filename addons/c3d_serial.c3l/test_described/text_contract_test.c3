module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;
import std::io;

int[2] owned_default_numbers @private = { 3, 5 };
uint[1] old_number_text_versions @private = { 1 };

struct TextOwned @private {
    String label;
    int[] numbers;
}

struct SavedState @private {
    Node* node;
    Node fields;
    MaterialId material;
    uint material_revision;
    uint materials_free;
    uint geometries_free;
    uint nodes_free;
    sz keys;
}

fn void defaults_text_owned(void* raw) @private {
    *(TextOwned*)raw = { .label = "default-label", .numbers = owned_default_numbers[..] };
}

fn void? attach_text_owned(void* raw, ReadContext* context) @private {
    TextOwned value = *(TextOwned*)raw;
    value.label = value.label.copy(mem);
    value.numbers = alloc::clone_slice(mem, value.numbers);
    context.scene.add(context.node, value);
}

fn void remove_text_owned(Entity entity, void* raw, void* user) @private {
    TextOwned* value = raw;
    alloc::free(mem, value.label.ptr);
    alloc::free(mem, value.numbers.ptr);
}

fn void register_text_owned(Fixture* fixture) @private {
    describe::register_reflected(TextOwned)!!;
    serial::register_described_type(
        $Type: TextOwned,
        version: 1,
        layout: serial::description_layout(describe::get(TextOwned)!!)!!,
        defaults: &defaults_text_owned,
    )!!;
    serial::register_described(TextOwned, { .name = "text_owned", .attach = &attach_text_owned })!!;
    fixture.source.register(TextOwned)!!;
    fixture.destination.register(TextOwned)!!;
    fixture.source.set_remove_hook(TextOwned, &remove_text_owned, null);
    fixture.destination.set_remove_hook(TextOwned, &remove_text_owned, null);
}

fn SavedState save_existing_state(Fixture* fixture) @private {
    Node* existing = fixture.destination.add_node(name: "existing")!!;
    fixture.destination.add_node(existing, "retained-child")!!;
    fixture.destination.add(existing, (Number){ .count = 123, .gain = 0.25f });
    existing.local.position = { 4, 5, 6 };
    existing.local.scale = { 2, 3, 4 };
    existing.transform_space = WORLD;
    existing.layers = 7;
    existing.visible = false;
    fixture.destination.update_world();
    MaterialId material = fixture.assets.add_material({}, "unchanged")!!;
    return {
        .node = existing,
        .fields = *existing,
        .material = material,
        .material_revision = fixture.assets.material(material).header.revision,
        .materials_free = fixture.assets.materials.free_count,
        .geometries_free = fixture.assets.geometries.free_count,
        .nodes_free = fixture.destination.world.entities.free_count,
        .keys = fixture.assets.keys.len(),
    };
}

fn void assert_existing_state(Fixture* fixture, SavedState* saved) @private {
    Node* node = saved.node;
    Node* fields = &saved.fields;
    assert(fixture.destination.world.entities.free_count == saved.nodes_free);
    assert(fixture.destination.count(Owner) == 0 && fixture.destination.count(Number) == 1);
    assert(fixture.destination.get(node, Number).count == 123 && fixture.destination.get(node, Number).gain == 0.25f);
    assert(node.name == fields.name && node.name.ptr == fields.name.ptr);
    assert(c3d::same_id(node.id, fields.id) && node.transform_space == fields.transform_space);
    assert(node.local.position == fields.local.position && node.local.rotation.v == fields.local.rotation.v);
    assert(node.local.scale == fields.local.scale && node.world == fields.world);
    assert(node.layers == fields.layers && node.visible == fields.visible);
    assert(node.visible_effective == fields.visible_effective && node.parent == fields.parent);
    assert(node.first_child == fields.first_child && node.next_sibling == fields.next_sibling);
    assert(fixture.assets.materials.free_count == saved.materials_free && fixture.assets.geometries.free_count == saved.geometries_free);
    assert(fixture.assets.keys.len() == saved.keys && fixture.assets.material(saved.material).header.revision == saved.material_revision);
    assert(c3d::same_id(fixture.assets.find_material("unchanged")!!, saved.material));
}

fn void test_text_all_reader_acquisitions_rollback_without_changing_existing_state() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        register_text_owned(&fixture);
        Node* source = fixture_tree(&fixture);
        TextOwned authored = { .label = "copied-overlay", .numbers = owned_default_numbers[..] };
        ReadContext context = { .scene = &fixture.source, .node = source };
        attach_text_owned(&authored, &context)!!;
        String text = fixture_text(&fixture, source);
        SavedState saved = save_existing_state(&fixture);
        FailingAllocator counter;
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.allocator = &counter;
        Node* restored = serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: text,
            parent: saved.node,
            options: options,
        )!!;
        uint attempts = counter.attempts;
        assert(!counter.outstanding);
        TextOwned* owned = fixture.destination.get(restored, TextOwned);
        assert(owned.label == "copied-overlay" && owned.numbers == owned_default_numbers[..]);
        assert(owned.numbers.ptr != &owned_default_numbers[0]);
        fixture.destination.remove(restored);
        for (uint failure = 1; failure <= attempts; failure++) {
            counter = { .failure = failure };
            assert(@catch(serial::read_subtree_text(
                scene: &fixture.destination,
                assets: &fixture.assets,
                text: text,
                parent: saved.node,
                options: options,
            )) == c3d::CAPACITY_EXCEEDED);
            assert(!counter.outstanding && !fixture.destination.count(TextOwned));
            assert_existing_state(&fixture, &saved);
        }
        assert(owned_default_numbers == (int[2]){ 3, 5 });
        io::printfn("Text allocation injection: %s acquisition sites passed.", attempts);
    };
}

fn void test_text_late_attachment_fault_preserves_existing_state_and_reusable_diagnostic() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        defer register_described_codecs();
        Node* source = fixture_tree(&fixture);
        String text = fixture_text(&fixture, source);
        SavedState saved = save_existing_state(&fixture);
        serial::register_described(Number, {
            .name = "number", .phase = REFERENCES, .attach = &fail_number_attachment,
        })!!;
        FailingAllocator counter;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.allocator = &counter;
        options.diagnostic = &diagnostic;
        uint removed = fixture.removed;
        assert(@catch(serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: text,
            parent: saved.node,
            options: options,
        )) == c3d::INVALID_ARGUMENT);
        assert(!counter.outstanding && fixture.removed == removed + 1);
        assert_existing_state(&fixture, &saved);
        assert(diagnostic.has_text_position && diagnostic.type_name == "number");
        register_described_codecs();
        Node* restored = serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: text,
            parent: saved.node,
            options: options,
        )!!;
        assert(!diagnostic.cause && !diagnostic.has_text_position && !diagnostic.type_name.len);
        fixture.destination.remove(restored);
        assert_existing_state(&fixture, &saved);
    };
}

fn void test_text_embedded_span_has_relative_diagnostics_and_owned_values() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        Node* source = fixture_tree(&fixture);
        String text = fixture_text(&fixture, source);
        String prefix = `{"metadata":{"name":"outer"},"scene":`;
        String wrapper = string::tformat("%s%s,\"tail\":[3]}", prefix, text);
        String span = wrapper[prefix.len:text.len];
        Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, span)!!;
        ((char[])wrapper)[..] = ' ';
        assert(fixture.destination.get(restored.first_child, Owner).items[0].label == "first");
        assert(fixture.destination.get(restored, Number).count == 21);
        String invalid = `{"version":2,"nodes":[]}`;
        wrapper = string::tformat("%s%s}", prefix, invalid);
        span = wrapper[prefix.len:invalid.len];
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        assert(@catch(serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: span,
            options: options,
        )) == c3d::UNSUPPORTED);
        assert(diagnostic.pointer == "/version" && diagnostic.byte_offset == 11);
        assert(diagnostic.line == 1 && diagnostic.byte_column == 12);
        assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, wrapper)) == c3d::ASSET_FORMAT_ERROR);
    };
}

fn void test_text_mixed_subtree_import_omits_only_reported_binary_components() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        register_opaque();
        fixture.source.register(Opaque)!!;
        fixture.destination.register(Opaque)!!;
        Node* source = fixture_tree(&fixture);
        fixture.source.add(source, (Opaque){ .value = 7 });
        fixture.source.add(source.first_child, (Opaque){ .value = 11 });
        OmissionReport report = serial::create_omission_report(mem);
        defer serial::destroy_omission_report(&report);
        TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
        options.omit_binary_only = true;
        options.omissions = &report;
        String text = fixture_text(&fixture, source, options);
        assert(report.components.len == 2);
        Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
        assert(!fixture.destination.has(restored, Opaque) && !fixture.destination.has(restored.first_child, Opaque));
        assert(fixture.destination.get(restored, Number).count == 21);
        assert(fixture.destination.get(restored.first_child, Owner).items[1].label == "second");
        assert(fixture.source.get(source, Opaque).value == 7 && fixture.source.get(source.first_child, Opaque).value == 11);
    };
}

fn String component_text(String components) @private {
    return string::tformat(`{"version":1,"nodes":[{"id":0,"parent":null,"name":"","local":%s,"transform_space":"PARENT","layers":1,"visible":true,"components":%s}]}`,
        LOCAL_JSON, components);
}

fn void test_text_versions_and_unknown_components_follow_explicit_policy() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        defer register_described_codecs();
        String text = component_text(`{"number":{"version":1,"value":{"count":11}}}`);
        uint before = fixture.destination.world.entities.free_count;
        assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, text)) == c3d::UNSUPPORTED);
        assert(fixture.destination.world.entities.free_count == before);
        serial::register_described(Number, {
            .name = "number", .phase = REFERENCES, .text_default_versions = old_number_text_versions[..],
        })!!;
        Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
        Number* number = fixture.destination.get(restored, Number);
        assert(number.count == 11 && number.gain == 0.5f && !number.target.index);
        fixture.destination.remove(restored);
        text = component_text(`{"number":{"version":3,"value":{}}}`);
        assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, text)) == c3d::UNSUPPORTED);
        text = component_text(`{"unknown":{"version":7,"value":{"nested":[1,true,null]}}}`);
        assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, text)) == c3d::UNSUPPORTED);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.skip_unknown = true;
        restored = serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: text,
            options: options,
        )!!;
        assert(!fixture.destination.count(Number));
        fixture.destination.remove(restored);
        text = component_text(`{"unknown":{"version":7,"value":{"nested":[1,]}}}`);
        assert(@catch(serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: text,
            options: options,
        )) == c3d::ASSET_FORMAT_ERROR);
        assert(fixture.destination.world.entities.free_count == before);
    };
}
