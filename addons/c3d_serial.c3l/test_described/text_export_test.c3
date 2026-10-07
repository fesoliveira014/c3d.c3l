module c3d::serial::test_described;

import c3d;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;

fn String fixture_text(Fixture* fixture, Node* source, TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT) @private {
    return serial::write_subtree_text(
        allocator: tmem,
        scene: &fixture.source,
        assets: &fixture.assets,
        root: source,
        options: options,
    )!!;
}

fn void test_text_export_is_deterministic_and_emits_all_described_fields() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        Node* source = fixture_tree(&fixture);
        source.transform_space = WORLD;
        source.local.position = { 2, 3, 4 };
        String text = fixture_text(&fixture, source);
        assert(text == fixture_text(&fixture, source));
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        uint nodes = member(&document, 0, "nodes");
        assert(document.values[nodes].children == 2);
        uint root = nodes + 1;
        assert(document.values[member(&document, root, "parent")].kind == NIL);
        assert(document.values[member(&document, root, "transform_space")].string == "WORLD");
        uint components = member(&document, root, "components");
        uint number = member(&document, member(&document, components, "number"), "value");
        assert(document.values[number].children == 3);
        assert(serial::text_read_float(&document, member(&document, number, "gain"), &diagnostic)!! == 0.0f);
        assert(bitcast(serial::text_read_float(&document, member(&document, number, "gain"), &diagnostic)!!, uint) == 0x80000000U);
        uint child = document.values[root].end;
        components = member(&document, child, "components");
        uint owner = member(&document, member(&document, components, "owner"), "value");
        assert(document.values[owner].children == 5);
        assert(document.values[member(&document, owner, "total")].string == "18446744073709551615");
        assert(document.values[member(&document, owner, "precision")].string == "f64:7ff0000000000001");
        assert(fixture.source.get(source.first_child, Owner).items[0].label == "first");
    };
}

fn void test_text_binary_only_export_requires_explicit_complete_report() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        register_opaque();
        fixture.source.register(Opaque)!!;
        Node* source = fixture_tree(&fixture);
        fixture.source.add(source, (Opaque){ .value = 7 });
        fixture.source.add(source.first_child, (Opaque){ .value = 11 });
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        assert(@catch(serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            options: options,
        )) == c3d::UNSUPPORTED);
        assert(diagnostic.node_path == "/nodes/0" && diagnostic.type_name == "opaque");
        OmissionReport report = serial::create_omission_report(mem);
        defer serial::destroy_omission_report(&report);
        options.omit_binary_only = true;
        assert(@catch(serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            options: options,
        )) == c3d::INVALID_ARGUMENT);
        assert(diagnostic.cause == c3d::INVALID_ARGUMENT && !diagnostic.node_path.len);
        options.omissions = &report;
        String text = fixture_text(&fixture, source, options);
        assert(report.components.len == 2);
        assert(report.components[0].node_path == "/nodes/0" && report.components[1].node_path == "/nodes/1");
        foreach (entry : report.components) assert(entry.type_name == "opaque");
        assert(!diagnostic.cause);
        TextDocument document = serial::parse_text(
            allocator: mem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        uint nodes = member(&document, 0, "nodes");
        for (uint node = nodes + 1; node < document.values[nodes].end; node = document.values[node].end) {
            uint components = member(&document, node, "components");
            assert(serial::json_member(&document, components, "opaque") == serial::INDEX_NONE);
            assert(document.values[components].children == 1);
        }
        fixture.source.remove_component(source, Opaque);
        fixture.source.remove_component(source.first_child, Opaque);
        fixture_text(&fixture, source, options);
        assert(!report.components.len && !diagnostic.cause);
    };
}

fn void test_text_export_allocation_faults_clear_partial_omission_reports() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        register_opaque();
        fixture.source.register(Opaque)!!;
        Node* source = fixture_tree(&fixture);
        fixture.source.add(source, (Opaque){ .value = 7 });
        fixture.source.add(source.first_child, (Opaque){ .value = 11 });
        FailingAllocator counter;
        OmissionReport report = serial::create_omission_report(&counter);
        defer serial::destroy_omission_report(&report);
        TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
        options.omit_binary_only = true;
        options.omissions = &report;
        fixture_text(&fixture, source, options);
        uint attempts = counter.attempts;
        assert(attempts == 5);
        serial::clear_omission_report(&report);
        assert(!counter.outstanding);
        for (uint failure = 1; failure <= attempts; failure++) {
            counter = { .failure = failure };
            assert(@catch(serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: source,
                options: options,
            )) == c3d::CAPACITY_EXCEEDED);
            assert(!report.components.len && !counter.outstanding);
        }
        fixture.source.remove_component(source, Opaque);
        fixture.source.remove_component(source.first_child, Opaque);
        counter = { .failure = 1 };
        assert(@catch(serial::write_subtree_text(
            allocator: &counter,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )) == c3d::CAPACITY_EXCEEDED);
        assert(!counter.outstanding && fixture.removed == 0);
    };
}

fn void test_text_export_preserves_collection_diagnostics_and_clears_on_reuse() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        defer register_described_codecs();
        Node* source = fixture_tree(&fixture);
        serial::register_described(Owner, {
            .name = "owner", .collect = &fail_owner_collection, .attach = &attach_owner,
        })!!;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        assert(@catch(serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            options: options,
        )) == c3d::INVALID_ID);
        assert(diagnostic.asset_key == "missing-asset" && diagnostic.node_path == "/nodes/1");
        assert(diagnostic.type_name == "owner" && !diagnostic.has_text_position);
        register_described_codecs();
        fixture_text(&fixture, source, options);
        assert(!diagnostic.cause && !diagnostic.asset_key.len && !diagnostic.type_name.len);
        options.limits.max_bytes = 0;
        assert(@catch(serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            options: options,
        )) == c3d::INVALID_ARGUMENT);
        assert(diagnostic.cause == c3d::INVALID_ARGUMENT);
    };
}
