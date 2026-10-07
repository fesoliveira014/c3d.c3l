module c3d_serial_all_test;

import c3d::ecs;
import c3d::scene;
import c3d::serial @public;
import std::io;
import std::time;
import std::time::clock;

fn int main(String[] args) {
    uint copies = 1;
    uint run = 1;
    foreach (argument : args[1..]) {
        if (argument.starts_with("--copies=")) { copies = argument[9..].to_uint()!!; }
        else if (argument.starts_with("--run=")) { run = argument[6..].to_uint()!!; }
        else { return 1; }
    }
    if (copies != 1 && copies != 10 && copies != 100) return 1;
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, 8192, 512);
        defer destroy_fixture(&fixture);
        Systems source_systems;
        create_systems(
            systems: &source_systems,
            scene: &fixture.source,
            assets: &fixture.assets,
            max_agents: 128,
        );
        defer destroy_systems(&source_systems);
        prepare_scene(
            systems: &source_systems,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: fixture.source.root,
        );
        char[] snapshot;
        @pool() {
            snapshot = serial::write_subtree(
                allocator: mem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.source.root,
            )!!;
        };
        defer alloc::free(mem, snapshot.ptr);
        for (uint index = 0; index < copies; index++) {
            @pool() { (void)serial::read_subtree(&fixture.destination, &fixture.assets, snapshot)!!; };
        }
        Systems systems;
        create_systems(
            systems: &systems,
            scene: &fixture.destination,
            assets: &fixture.assets,
            max_agents: 128,
        );
        defer destroy_systems(&systems);
        prepare_scene(
            systems: &systems,
            scene: &fixture.destination,
            assets: &fixture.assets,
            root: fixture.destination.root,
        );
        assert_presence(&fixture.destination, true);
        uint nodes;
        uint components;
        foreach (&node : fixture.destination.nodes) {
            if (!fixture.destination.world.is_alive(node.id)) continue;
            nodes++;
            ComponentMask mask = fixture.destination.world.mask(node.id);
            for (uint slot = 0; slot < ecs::MAX_COMPONENT_TYPES; slot++) {
                if (mask & ecs::slot_bit(slot)) components++;
            }
        }
        char[] expected;
        @pool() {
            expected = serial::write_subtree(
                allocator: mem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: fixture.destination.root,
            )!!;
        };
        defer alloc::free(mem, expected.ptr);
        @pool() {
            time::Clock started = clock::now();
            WriteState state = serial::select_export(&fixture.destination, fixture.destination.root)!!;
            WriteContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .state = &state };
            time::Clock collection_started = clock::now();
            serial::collect_export(&context)!!;
            long collection_ns = (long)(clock::now() - collection_started);
            serial::finish_export(&context, fixture.destination.root)!!;
            long prepare_ns = (long)(clock::now() - started);
            Writer measure = serial::measuring_writer();
            time::Clock component_started = clock::now();
            serial::write_components(&context, &measure)!!;
            measure.finish()!!;
            long component_ns = (long)(clock::now() - component_started);
            char[] components_bytes = alloc::new_array(tmem, char, (sz)measure.written());
            Writer writer = serial::writer_over(components_bytes);
            state.filling = true;
            component_started = clock::now();
            serial::write_components(&context, &writer)!!;
            writer.finish()!!;
            component_ns += (long)(clock::now() - component_started);
            SubtreeHeader header = serial::read_header(expected)!!;
            assert(components_bytes == serial::chunk_bytes(expected, header.chunk_count, COMPONENTS));
            uint retained = state.count;
            usz records = (usz)state.payload_sizes.len();
            usz claims = (usz)state.claims.len();
            @pool() {
                started = clock::now();
                char[] bytes = serial::write_subtree(
                    allocator: tmem,
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: fixture.destination.root,
                )!!;
                long total_ns = (long)(clock::now() - started);
                assert(bytes == expected);
                io::printfn("%d,%d,%d,%d,%d,%d,%d,%d,%.6f,%.6f,%.6f,%.6f",
                    copies, run, nodes, components, retained, records, claims, bytes.len,
                    (double)prepare_ns / 1_000_000, (double)collection_ns / 1_000_000,
                    (double)component_ns / 1_000_000, (double)total_ns / 1_000_000);
            };
        };
    };
    return 0;
}
