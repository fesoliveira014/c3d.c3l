module c3d::serial::test;

import c3d;
import c3d::scene;
import c3d::serial @public;

fn void? diagnostic_collect_failure(void* value, WriteContext* context) @private {
    context.diagnostic.asset_key = serial::copy_serial_string(context.diagnostic.allocator, "missing-asset")!;
    return c3d::INVALID_ID~;
}

fn void? diagnostic_read_failure(Reader* reader, ReadContext* context) @private {
    assert(context.allocator.ptr == context.scene.allocator.ptr);
    return c3d::CAPACITY_EXCEEDED~;
}

fn void? diagnostic_unconsumed_payload(Reader* reader, ReadContext* context) @private {}
fn void test_binary_collection_diagnostic_preserves_owner_details_and_clears_on_reuse() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        defer register_codecs();
        Node* source = value_tree(&fixture);
        serial::register_codec(Value, {
            .name = "value", .version = 1, .phase = REFERENCES,
            .collect = &diagnostic_collect_failure, .write = &write_value, .read = &read_value,
        })!!;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            options: { .diagnostic = &diagnostic },
        )) == c3d::INVALID_ID);
        assert(diagnostic.cause == c3d::INVALID_ID && diagnostic.asset_key == "missing-asset");
        assert(diagnostic.node_path == "/nodes/0" && diagnostic.type_name == "value" && !diagnostic.has_text_position);
        assert(fixture.source.has(source, Value) && fixture.removed == 0);
        register_codecs();
        assert(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            options: { .diagnostic = &diagnostic },
        )!!.len > 0);
        assert(!diagnostic.cause && !diagnostic.asset_key.len && !diagnostic.node_path.len && !diagnostic.type_name.len);
    };
}

fn void test_binary_read_diagnostic_survives_subtree_rollback() @test {
    @pool() {
        Fixture fixture;
        init_fixture(&fixture);
        defer free_fixture(&fixture);
        defer register_codecs();
        Node* source = fixture.source.add_node(name: "source")!!;
        fixture.source.add(source, (Versioned){ .first = 7, .second = 13 });
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        serial::register_codec(Versioned, {
            .name = "versioned", .version = 2, .write = &write_versioned, .read = &diagnostic_read_failure,
        })!!;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        uint free_before = fixture.destination.world.entities.free_count;
        assert(@catch(serial::read_subtree(
            scene: &fixture.destination,
            assets: &fixture.assets,
            bytes: bytes,
            options: options,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(fixture.destination.world.entities.free_count == free_before && !fixture.destination.root.first_child);
        assert(diagnostic.cause == c3d::CAPACITY_EXCEEDED && diagnostic.node_path == "/nodes/0");
        assert(diagnostic.type_name == "versioned" && !diagnostic.has_text_position);
        serial::register_codec(Versioned, {
            .name = "versioned", .version = 2, .write = &write_versioned, .read = &diagnostic_unconsumed_payload,
        })!!;
        assert(@catch(serial::read_subtree(
            scene: &fixture.destination,
            assets: &fixture.assets,
            bytes: bytes,
            options: options,
        )) == c3d::ASSET_FORMAT_ERROR);
        assert(diagnostic.cause == c3d::ASSET_FORMAT_ERROR && diagnostic.node_path == "/nodes/0");
        assert(diagnostic.type_name == "versioned" && fixture.destination.world.entities.free_count == free_before);
    };
}
