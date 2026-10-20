module c3d::particle;

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
