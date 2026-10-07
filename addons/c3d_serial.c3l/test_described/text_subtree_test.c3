module c3d::serial::test_described;

import c3d;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;

const String LOCAL_JSON @private = `{"position":[0,0,0],"rotation":[0,0,0,1],"scale":[1,1,1]}`;

fn String graph_json(uint[] ids, uint[] parents, String[] names = {}) @private {
    char[8192] bytes;
    JsonOutput output = { .writer = serial::writer_over(bytes[..]), .limits = serial::TEXT_LIMITS_DEFAULT };
    output.begin("", true)!!;
    output.unsigned("version", 1)!!;
    output.begin("nodes", false)!!;
    foreach (index, id : ids) {
        output.begin("", true)!!;
        output.unsigned("id", id)!!;
        if (parents[index] == serial::INDEX_NONE) {
            output.literal("parent", "null")!!;
        } else {
            output.unsigned("parent", parents[index])!!;
        }
        output.string("name", names.len ? names[index] : id == 2 ? "" : "same")!!;
        output.literal("local", LOCAL_JSON)!!;
        output.string("transform_space", "PARENT")!!;
        output.unsigned("layers", 1)!!;
        output.boolean("visible", true)!!;
        output.begin("components", true)!!;
        output.end()!!;
        output.end()!!;
    }
    output.end()!!;
    output.end()!!;
    return ((String)bytes[:output.writer.written()]).tcopy();
}

fn void test_text_subtree_round_trip_matches_binary_values() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        Node* source = fixture_tree(&fixture);
        char[] expected = fixture_bytes(&fixture, source);
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        String repeated = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        assert(text == repeated);
        Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
        char[] binary = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.destination,
            assets: &fixture.assets,
            root: restored,
        )!!;
        assert(binary == expected);
        fixture.source.remove(source);
        Owner* owner = fixture.destination.get(restored.first_child, Owner);
        assert(owner.items[0].label == "first" && owner.items[1].amount == short::max);
        repeated = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.destination,
            assets: &fixture.assets,
            root: restored,
        )!!;
        assert(text == repeated);
    };
}

fn void test_text_node_ids_accept_arbitrary_order_and_reject_invalid_graphs() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        String text = graph_json({ 0, 2, 1 }, { 2, serial::INDEX_NONE, 2 });
        Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
        assert(restored.name == "" && restored.first_child.name == "same");
        assert(restored.first_child.next_sibling.name == "same");
        fixture.destination.remove(restored);
        uint before = fixture.destination.world.entities.free_count;
        String[6] invalid = {
            graph_json({ 0, 2, 0 }, { 2, serial::INDEX_NONE, 2 }),
            graph_json({ 0, 1, 2 }, { 1, 0, serial::INDEX_NONE }),
            graph_json({ 0, 1, 2 }, { serial::INDEX_NONE, serial::INDEX_NONE, 0 }),
            graph_json({ 0, 1, 2 }, { serial::INDEX_NONE, 3, 0 }),
            graph_json({ 0, 1, 2 }, { 1, 2, 0 }),
            graph_json({ 0, 1, 5 }, { serial::INDEX_NONE, 0, 0 }),
        };
        foreach (candidate : invalid) {
            if (catch excuse = serial::read_subtree_text(&fixture.destination, &fixture.assets, candidate)) {
                assert(excuse == c3d::ASSET_FORMAT_ERROR);
            } else {
                assert(false);
            }
            assert(fixture.destination.world.entities.free_count == before);
            assert(fixture.destination.root.first_child == null);
        }
    };
}

fn void? fail_number_attachment(void* value, ReadContext* context) @private {
    assert(context.scene.count(Owner) == 1);
    return c3d::INVALID_ARGUMENT~;
}

fn void test_text_preflight_validates_once_before_any_component_attaches() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        defer register_described_codecs();
        Node* source = fixture_tree(&fixture);
        String text = fixture_text(&fixture, source);
        serial::register_described(Number, {
            .name = "number", .phase = REFERENCES, .validate = &validate_number_before_attachment,
        })!!;
        validation_count = 0;
        Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
        assert(validation_count == 1 && fixture.destination.has(restored.first_child, Owner));
        fixture.destination.remove(restored);
        fixture.source.remove_component(source.first_child, Owner);
        uint before = fixture.destination.world.entities.free_count;
        assert(@catch(serial::read_subtree_text(
            &fixture.destination, &fixture.assets, fixture_text(&fixture, source),
        )) == c3d::INVALID_ARGUMENT);
        assert(fixture.destination.world.entities.free_count == before);
        assert(!fixture.destination.count(Owner) && !fixture.destination.count(Number));
    };
}

fn void test_text_late_attachment_fault_removes_earlier_owned_components() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        defer register_described_codecs();
        Node* source = fixture_tree(&fixture);
        String text = fixture_text(&fixture, source);
        serial::register_described(Number, {
            .name = "number", .phase = REFERENCES, .attach = &fail_number_attachment,
        })!!;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        uint before = fixture.destination.world.entities.free_count;
        assert(@catch(serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: text,
            options: options,
        )) == c3d::INVALID_ARGUMENT);
        assert(fixture.destination.world.entities.free_count == before && fixture.removed == 1);
        assert(!fixture.destination.count(Owner) && !fixture.destination.count(Number));
        assert(diagnostic.has_text_position && diagnostic.node_path == "/nodes/0");
        assert(diagnostic.type_name == "number" && diagnostic.pointer == "/nodes/0/components/number/value");
    };
}

fn void test_text_sibling_order_is_independent_of_descendant_ids() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        String noncanonical = graph_json(
            { 0, 1, 2, 3, 4 },
            { serial::INDEX_NONE, 4, 3, 0, 0 },
            { "n0", "n1", "n2", "n3", "n4" },
        );
        String canonical = graph_json(
            { 0, 1, 2, 3, 4 },
            { serial::INDEX_NONE, 0, 1, 0, 3 },
            { "n0", "n3", "n2", "n4", "n1" },
        );
        Node* first = serial::read_subtree_text(&fixture.destination, &fixture.assets, noncanonical)!!;
        Node* second = serial::read_subtree_text(&fixture.destination, &fixture.assets, canonical)!!;
        assert(first.first_child.name == "n4" && first.first_child.next_sibling.name == "n3");
        assert(first.first_child.first_child.name == "n1" && first.first_child.next_sibling.first_child.name == "n2");
        char[] first_bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.destination,
            assets: &fixture.assets,
            root: first,
        )!!;
        char[] second_bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.destination,
            assets: &fixture.assets,
            root: second,
        )!!;
        assert(first_bytes == second_bytes);
    };
}
