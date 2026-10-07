module c3d::serial::test_described;

import c3d;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;

fn void test_authoring_index_resolves_sparse_nodes_and_per_node_entries() @test {
    Fixture fixture;
    create_fixture(&fixture, 128);
    defer destroy_fixture(&fixture);
    Node* outside = fixture.destination.add_node(name: "outside")!!;
    for (uint index = 0; index < 24; index++) fixture.destination.add_node()!!;
    Node* first = fixture.destination.add_node(name: "first")!!;
    Node* second = fixture.destination.add_node(name: "second")!!;
    Node*[2] nodes = { second, first };
    Number first_value = { .count = 17 };
    Number second_value = { .count = 23 };
    Owner owner;
    defaults_owner(&owner);
    uint number_slot = ecs::slot_of(Number)!!;
    uint owner_slot = ecs::slot_of(Owner)!!;
    serial::ReadAuthoring[3] entries = {
        { .record = 1, .slot = number_slot, .version = 2, .value = &first_value },
        { .record = 0, .slot = number_slot, .version = 2, .value = &second_value },
        { .record = 1, .slot = owner_slot, .version = 1, .value = &owner },
    };
    FailingAllocator counter;
    serial::Acquisitions owned = { .allocator = &counter };
    defer owned.release();
    ReadContext context = {
        .scene = &fixture.destination,
        .nodes = nodes[..],
        .authoring = entries[..],
        .read_owned = &owned,
    };
    serial::index_read_authoring(&context)!!;
    assert(counter.attempts == 1 && counter.outstanding == 1);
    assert(serial::read_node_record(&context, first.id)!! == 1);
    assert(serial::read_node_record(&context, second.id)!! == 0);
    assert(context.authored(Number, Number, first.id)!! == &first_value);
    assert(context.authored(Number, Number, second.id)!! == &second_value);
    assert(context.authored(Owner, Owner, first.id)!! == &owner);
    assert(context.authored(Owner, Owner, second.id)!! == null);
    assert(@catch(context.authored(Number, Owner, first.id)) == c3d::UNSUPPORTED);
    assert(@catch(context.authored(Number, Number, outside.id)) == c3d::INVALID_ID);
    Entity stale = second.id;
    fixture.destination.remove(second);
    assert(@catch(context.authored(Number, Number, stale)) == c3d::INVALID_ID);
    owned.release();
    assert(!counter.outstanding);
}

fn void test_authoring_index_storage_depends_only_on_document_size() @test {
    sz previous_bytes;
    foreach (capacity : (uint[2]){ 64, 4096 }) {
        Scene scene = scene::create_scene(mem, { .max_nodes = capacity });
        defer scene::destroy_scene(&scene);
        Node*[2] nodes = { scene.add_node()!!, scene.add_node()!! };
        serial::ReadAuthoring[1] entries = { { .record = 1 } };
        FailingAllocator counter;
        serial::Acquisitions owned = { .allocator = &counter };
        defer owned.release();
        ReadContext context = {
            .scene = &scene,
            .nodes = nodes[..],
            .authoring = entries[..],
            .read_owned = &owned,
        };
        serial::index_read_authoring(&context)!!;
        assert(counter.attempts == 1);
        if (previous_bytes) assert(counter.acquired_bytes == previous_bytes);
        previous_bytes = counter.acquired_bytes;
    }
}
