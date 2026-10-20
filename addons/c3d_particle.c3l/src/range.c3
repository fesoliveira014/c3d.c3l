module c3d::particle;

import c3d;
import std::math;

struct ParticleSpan @private {
    uint begin;
    uint end;
}

fn uint block_count(uint particles) @private {
    return (uint)(((ulong)particles + PARTICLE_BLOCK - 1) / PARTICLE_BLOCK);
}

fn ParticleSpan particle_span(uint alive, uint block) @private {
    ulong begin = (ulong)block * PARTICLE_BLOCK;
    return { .begin = (uint)begin, .end = (uint)math::min(begin + PARTICLE_BLOCK, (ulong)alive) };
}

// A single block has nothing to split, and a zero hook runs every block in one call, in order.
fn bool blocks_run_in_order(ParallelFor parallel, uint blocks) @private {
    return blocks <= 1 || !parallel.run;
}

fn void run_blocks(
    ParallelFor parallel,
    ParallelRangeFn range,
    void* data,
    uint blocks,
) @private {
    if (blocks_run_in_order(parallel, blocks)) {
        range(data, 0, blocks);
        return;
    }

    parallel.for_ranges(
        range: range,
        data: data,
        count: blocks,
        batch: BLOCKS_PER_RANGE,
    );
}
