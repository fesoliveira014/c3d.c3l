module c3d::serial::test_described;

import c3d;
import c3d::ecs;
import c3d::scene;
import c3d::serial @public;
import std::io;
import std::time;
import std::time::clock;

const uint LOOKUP_SAMPLES @private = 5;
const double NANOSECONDS_PER_MILLISECOND @private = 1_000_000.0;

uint lookup_calls @private;
ulong lookup_sum @private;
time::NanoDuration lookup_elapsed @private;

fn void? validate_number_lookup(void* value, ReadContext* context) @private {
    time::Clock started = clock::now();
    Number* target = context.authored(Number, Number, ((Number*)value).target)!;
    lookup_elapsed += clock::now() - started;
    if (!target) return c3d::INVALID_ARGUMENT~;
    lookup_calls++;
    lookup_sum += target.count;
}

fn double median_lookup_sample(double[LOOKUP_SAMPLES] samples) @private {
    for (uint index = 1; index < LOOKUP_SAMPLES; index++) {
        double value = samples[index];
        uint position = index;
        while (position && samples[position - 1] > value) {
            samples[position] = samples[position - 1];
            position--;
        }
        samples[position] = value;
    }
    return samples[LOOKUP_SAMPLES / 2];
}

fn void test_text_authoring_lookup_large_document() @test {
    defer register_described_codecs();
    foreach (count : (uint[3]){ 1024, 4096, 8192 }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture, count + 1);
            defer destroy_fixture(&fixture);
            Node*[] nodes = alloc::new_array(tmem, Node*, count);
            nodes[0] = fixture.source.add_node(name: "root")!!;
            for (uint index = 1; index < count; index++) {
                nodes[index] = fixture.source.add_node(nodes[0], "node")!!;
            }
            foreach (index, node : nodes) {
                fixture.source.add(node, (Number){
                    .count = (uint)index, .gain = 0.25f, .target = nodes[(index + 1) % count].id,
                });
            }
            String text = fixture_text(&fixture, nodes[0]);
            double[LOOKUP_SAMPLES] plain_samples;
            double[LOOKUP_SAMPLES] validated_samples;
            double[LOOKUP_SAMPLES] lookup_samples;
            for (uint round = 0; round < (LOOKUP_SAMPLES + 1) * 2; round++) {
                bool validating = (round & 1) != 0;
                serial::register_described(Number, {
                    .name = "number", .phase = REFERENCES, .validate = validating ? &validate_number_lookup : null,
                })!!;
                lookup_calls = 0;
                lookup_sum = 0;
                lookup_elapsed = (time::NanoDuration)0;
                time::Clock started = clock::now();
                Node* restored = serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                double milliseconds = (double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND;
                if (validating) {
                    assert(lookup_calls == count && lookup_sum == (ulong)count * ((ulong)count - 1) / 2);
                } else {
                    assert(lookup_calls == 0);
                }
                assert(fixture.destination.count(Number) == count);
                fixture.destination.remove(restored);
                assert(fixture.destination.count(Number) == 0);
                if (round < 2) continue;
                uint sample = round / 2 - 1;
                if (validating) {
                    validated_samples[sample] = milliseconds;
                    lookup_samples[sample] = (double)lookup_elapsed / NANOSECONDS_PER_MILLISECOND;
                } else {
                    plain_samples[sample] = milliseconds;
                }
            }
            foreach (sample, plain_time : plain_samples) {
                io::printfn("Authored sample nodes=%s sample=%s plain_ms=%.3f validated_ms=%.3f lookup_ms=%.3f",
                    count, sample + 1, plain_time, validated_samples[sample], lookup_samples[sample]);
            }
            double plain = median_lookup_sample(plain_samples);
            double validated = median_lookup_sample(validated_samples);
            double lookups = median_lookup_sample(lookup_samples);
            io::printfn("Authored lookup nodes=%s bytes=%s reads=%s plain_ms=%.3f validated_ms=%.3f lookup_ms=%.3f",
                count, text.len, LOOKUP_SAMPLES, plain, validated, lookups);
        };
    }
}
