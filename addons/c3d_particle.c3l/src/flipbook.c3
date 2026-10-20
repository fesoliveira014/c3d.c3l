module c3d::particle;

import c3d::scene;
import std::math;

fn BillboardAtlas flipbook_atlas(ParticleFlipbook* flipbook) @private {
    return {
        .columns = flipbook.columns,
        .rows = flipbook.rows,
        .frame_count = flipbook.frame_count,
        .inset = flipbook.inset,
    };
}

fn uint flipbook_start_frame(uint seed, uint frame_count) @private {
    uint sample = pcg_hash(pcg_hash(seed)); // a second hash keeps the frame independent of the colour fraction
    float fraction = (float)(sample >> RANDOM_UNIT_SHIFT) * RANDOM_UNIT_SCALE;
    return math::min((uint)(fraction * frame_count), frame_count - 1);
}

fn float flipbook_frame(ParticleFlipbook* flipbook, uint seed, float age, float lifetime) @private {
    double frames = flipbook.frame_count;
    double position = flipbook.random_start ? flipbook_start_frame(seed, flipbook.frame_count) : 0;
    switch (flipbook.mode) {
        case OVER_LIFE:
            double life = math::clamp((double)age / lifetime, 0.0, 1.0);
            position += flipbook.blend
              ? life * (frames - 1) : math::min(math::floor(life * frames), frames - 1);
        case FPS:
            double elapsed = (double)age * flipbook.fps;
            position += flipbook.blend ? elapsed : math::floor(elapsed);
    }
    double wrapped = position - math::floor(position / frames) * frames;
    return (float)math::clamp(wrapped, 0.0, frames);
}
