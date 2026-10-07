module c3d::serial::test_described;

import c3d;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;

struct WrappedNumber @private {
    Number authoring;
    uint runtime;
}
uint validation_count @private;

fn void? project_wrapped_number(void* component, void* value, WriteContext* context) @private {
    *(Number*)value = ((WrappedNumber*)component).authoring;
}

fn void? attach_wrapped_number(void* value, ReadContext* context) @private {
    context.scene.add(context.node, (WrappedNumber){ .authoring = *(Number*)value });
}
fn void? validate_number_before_attachment(void* value, ReadContext* context) @private {
    assert(context.scene.count(Owner) == 0);
    validation_count++;
    Owner* owner = context.authored(Owner, Owner, ((Number*)value).target)!;
    if (!owner || owner.items.len != 2) return c3d::INVALID_ARGUMENT~;
}

fn void? fail_owner_collection(void* value, WriteContext* context) @private {
    context.diagnostic.asset_key = serial::copy_serial_string(context.diagnostic.allocator, "missing-asset")!;
    return c3d::INVALID_ID~;
}

fn void test_described_preflight_validates_once_and_borrows_other_authoring() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        defer register_described_codecs();
        Node* source = fixture_tree(&fixture);
        char[] bytes = fixture_bytes(&fixture, source);
        serial::register_described(Number, {
            .name = "number", .phase = REFERENCES, .validate = &validate_number_before_attachment,
        })!!;
        validation_count = 0;
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        assert(validation_count == 1 && fixture.destination.has(restored.first_child, Owner));
        fixture.destination.remove(restored);
        fixture.source.remove_component(source.first_child, Owner);
        bytes = fixture_bytes(&fixture, source);
        uint free_before = fixture.destination.world.entities.free_count;
        uint removed_before = fixture.removed;
        assert(@catch(serial::read_subtree(&fixture.destination, &fixture.assets, bytes)) == c3d::INVALID_ARGUMENT);
        assert(fixture.destination.world.entities.free_count == free_before && fixture.removed == removed_before);
        assert(fixture.destination.count(Owner) == 0 && fixture.destination.count(Number) == 0);
    };
}

fn void test_described_binding_conflicts_and_collection_diagnostics() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        defer register_described_codecs();
        assert(@catch(serial::register_described(Owner, { .name = "number", .attach = &attach_owner })) == c3d::INVALID_ARGUMENT);
        assert(@catch(serial::register_described(Owner, { .name = "owner" })) == c3d::INVALID_ARGUMENT);
        Node* source = fixture_tree(&fixture);
        serial::register_described(Owner, {
            .name = "owner", .collect = &fail_owner_collection, .attach = &attach_owner,
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
        assert(diagnostic.node_path == "/nodes/1" && diagnostic.type_name == "owner" && !diagnostic.has_text_position);
        assert(fixture.source.has(source.first_child, Owner) && fixture.removed == 0);
        register_described_codecs();
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

fn void test_described_owner_projects_separate_authoring_and_omits_runtime() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        fixture.source.register(WrappedNumber)!!;
        fixture.destination.register(WrappedNumber)!!;
        assert(@catch(serial::register_described_owner(WrappedNumber, Number, {
            .name = "wrapped", .attach = &attach_wrapped_number,
        })) == c3d::INVALID_ARGUMENT);
        serial::register_described_owner(WrappedNumber, Number, {
            .name = "wrapped", .project = &project_wrapped_number, .attach = &attach_wrapped_number,
        })!!;
        Node* source = fixture.source.add_node(name: "owner")!!;
        fixture.source.add(source, (WrappedNumber){ .authoring = { .count = 42, .gain = 0.75f }, .runtime = 99 });
        char[] bytes = fixture_bytes(&fixture, source);
        Node* restored = serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
        WrappedNumber* component = fixture.destination.get(restored, WrappedNumber);
        assert(component.authoring.count == 42 && component.authoring.gain == 0.75f && component.runtime == 0);
        assert(fixture.source.get(source, WrappedNumber).runtime == 99 && !fixture.destination.has(restored, Number));
    };
}
