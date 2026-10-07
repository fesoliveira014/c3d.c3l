module c3d::serial::test_described;

import c3d;
import c3d::scene;
import c3d::serial;

uint checked_targets @private;
uint checked_total @private;

fn void? validate_many_references(void* value, ReadContext* context) @private {
    Number* target = context.authored(Number, Number, ((Number*)value).target)!;
    if (!target) return c3d::INVALID_ARGUMENT~;
    checked_targets++;
    checked_total += target.count;
}

fn void test_authoring_resolves_many_records_in_binary_and_text() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 65);
        defer destroy_fixture(&fixture);
        defer register_described_codecs();
        Node*[64] nodes;
        nodes[0] = fixture.source.add_node(name: "root")!!;
        for (uint index = 1; index < nodes.len; index++) nodes[index] = fixture.source.add_node(nodes[0])!!;
        foreach (index, node : nodes) {
            fixture.source.add(node, (Number){
                .count = (uint)index, .target = nodes[(index + 1) % nodes.len].id,
            });
        }
        char[] bytes = fixture_bytes(&fixture, nodes[0]);
        String text = fixture_text(&fixture, nodes[0]);
        serial::register_described(Number, {
            .name = "number", .phase = REFERENCES, .validate = &validate_many_references,
        })!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            checked_targets = 0;
            checked_total = 0;
            Node* restored = encoding
              ? serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!
              : serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
            assert(checked_targets == 64 && checked_total == 64 * 63 / 2);
            assert(fixture.destination.count(Number) == 64);
            fixture.destination.remove(restored);
            assert(!fixture.destination.count(Number));
        }
    };
}
