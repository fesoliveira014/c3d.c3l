module c3d::serial::test_described;

import c3d;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import c3d::serial @public;

enum TransientClaim @private { NO_CLAIM, NODE_CLAIM, COMPONENT_CLAIM, LOCAL_CLAIM, PROJECTION_CLAIM, SPACE_CLAIM }

struct SelectionBefore @private { Node* child; }
struct SelectionOwner @private { Node* child; uint value; }
struct SelectionAfter @private { Node* child; }
struct GeneratedGuard @private { Node* owner; TransientClaim claim; }

fn void test_transient_collection_preserves_selection_across_owner_omissions() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            register_selection_callbacks(&fixture);
            Node* root = fixture.source.add_node(name: "owner")!!;
            Node* generated = fixture.source.add_node(root, "generated")!!;
            Node* authored = fixture.source.add_node(root, "authored")!!;
            fixture.source.add(root, (SelectionBefore){ .child = generated });
            fixture.source.add(root, (SelectionOwner){ .child = generated, .value = 7 });
            fixture.source.add(root, (SelectionAfter){ .child = generated });
            fixture.source.add(generated, (GeneratedGuard){ .owner = root });
            fixture.source.add(authored, (Number){ .count = 42 });
            uint available = fixture.source.world.entities.free_count;
            char[] bytes = encode_selection(fixture: &fixture, root: root, text_mode: text_mode)!!;
            Node* loaded = text_mode
              ? serial::read_subtree_text(&fixture.destination, &fixture.assets, (String)bytes)!!
              : serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
            assert(fixture.destination.get(loaded, SelectionOwner).value == 7);
            assert(loaded.first_child.name == "authored" && loaded.first_child.next_sibling == null);
            assert(fixture.destination.get(loaded.first_child, Number).count == 42);
            assert(fixture.destination.count(GeneratedGuard) == 0);
            assert(fixture.destination.count(SelectionBefore) == 0 && fixture.destination.count(SelectionAfter) == 0);
            assert(fixture.source.world.entities.free_count == available);
            assert(fixture.source.get(root, SelectionOwner).child == generated && generated.parent == root);
            assert(fixture.source.has(generated, GeneratedGuard) && fixture.source.get(authored, Number).count == 42);
            assert(bytes == encode_selection(fixture: &fixture, root: root, text_mode: text_mode)!!);
            SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
            defer serial::destroy_serial_diagnostic(&diagnostic);
            assert(@catch(encode_selection(
                fixture: &fixture,
                root: generated,
                text_mode: text_mode,
                diagnostic: &diagnostic,
            )) == c3d::INVALID_ARGUMENT);
            assert(diagnostic.cause == c3d::INVALID_ARGUMENT && diagnostic.node_path == "/nodes/0");
            assert(diagnostic.type_name == GeneratedGuard::qname);
        };
    }
}

fn void test_transient_registration_rejects_replacement_and_collection_rejects_claims() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        register_selection_callbacks(&fixture);
        uint slot = ecs::assigned_slot(GeneratedGuard)!!;
        serial::register_transient(GeneratedGuard, &collect_generated)!!;
        assert(@catch(serial::register_transient(GeneratedGuard, &collect_other)) == c3d::INVALID_ARGUMENT);
        assert(serial::codecs[slot].codec.collect == &collect_generated && !serial::codecs[slot].codec.name.len);
        Node* node = fixture.source.add_node(name: "transient")!!;
        Node* child = fixture.source.add_node(node, "child")!!;
        fixture.source.add(node, (GeneratedGuard){ .owner = child });
        foreach (text_mode : (bool[2]){ false, true }) {
            foreach (claim : (TransientClaim[5]){ NODE_CLAIM, COMPONENT_CLAIM, LOCAL_CLAIM, PROJECTION_CLAIM, SPACE_CLAIM }) {
                fixture.source.get(node, GeneratedGuard).claim = claim;
                assert(@catch(encode_selection(fixture: &fixture, root: node, text_mode: text_mode)) == c3d::INVALID_ARGUMENT);
                assert(fixture.source.has(node, GeneratedGuard) && node.local.position == maths::TRANSFORM_IDENTITY.position);
            }
        }
    };
}

fn void register_selection_callbacks(Fixture* fixture) @local {
    serial::register_transient(SelectionBefore, &collect_before)!!;
    serial::register_described_owner(SelectionOwner, Number, {
        .name = "selection_owner",
        .collect = &collect_selection_owner,
        .project = &project_selection_owner,
        .attach = &attach_selection_owner,
    })!!;
    serial::register_transient(SelectionAfter, &collect_after)!!;
    serial::register_transient(GeneratedGuard, &collect_generated)!!;
    assert(ecs::assigned_slot(SelectionBefore)!! < ecs::assigned_slot(SelectionOwner)!!);
    assert(ecs::assigned_slot(SelectionOwner)!! < ecs::assigned_slot(SelectionAfter)!!);
    foreach (scene : (Scene*[2]){ &fixture.source, &fixture.destination }) {
        scene.register(SelectionBefore)!!;
        scene.register(SelectionOwner)!!;
        scene.register(SelectionAfter)!!;
        scene.register(GeneratedGuard)!!;
    }
}

fn void? collect_before(void* component, WriteContext* context) @local {
    Node* child = ((SelectionBefore*)component).child;
    assert(context.contains_node(child) && context.state.projection[child.id.index].node_owner == 0);
}

fn void? collect_after(void* component, WriteContext* context) @local {
    Node* child = ((SelectionAfter*)component).child;
    assert(context.contains_node(child) && context.state.projection[child.id.index].node_owner != 0);
}

fn void? collect_selection_owner(void* component, WriteContext* context) @local {
    context.omit_node(((SelectionOwner*)component).child)!;
}

fn void? project_selection_owner(void* component, void* value, WriteContext* context) @local {
    *(Number*)value = { .count = ((SelectionOwner*)component).value };
}

fn void? attach_selection_owner(void* value, ReadContext* context) @local {
    context.scene.add(context.node, (SelectionOwner){ .value = ((Number*)value).count });
}

fn void? collect_generated(void* component, WriteContext* context) @local {
    GeneratedGuard* guard = component;
    if (!context.contains_node(guard.owner)) return c3d::INVALID_ARGUMENT~;
    switch (guard.claim) {
        case NODE_CLAIM: context.omit_node(guard.owner)!;
        case COMPONENT_CLAIM: context.omit_component(context.node, ecs::assigned_slot(GeneratedGuard)!!)!;
        case LOCAL_CLAIM: context.set_local(context.node, maths::TRANSFORM_IDENTITY)!;
        case PROJECTION_CLAIM: context.project_component(context.node, *guard)!;
        case SPACE_CLAIM: context.set_transform(context.node, maths::TRANSFORM_IDENTITY, TransformSpace.PARENT)!;
        case NO_CLAIM:
    }
}

fn void? collect_other(void* component, WriteContext* context) @local {}

fn char[]? encode_selection(
    Fixture* fixture,
    Node* root,
    bool text_mode,
    SerialDiagnostic* diagnostic = null,
) @local {
    if (text_mode) return (char[])serial::write_subtree_text(
        allocator: tmem,
        scene: &fixture.source,
        assets: &fixture.assets,
        root: root,
        options: { .limits = serial::TEXT_LIMITS_DEFAULT, .diagnostic = diagnostic },
    )!;
    return serial::write_subtree(
        allocator: tmem,
        scene: &fixture.source,
        assets: &fixture.assets,
        root: root,
        options: { .diagnostic = diagnostic },
    );
}
