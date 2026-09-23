module c3d::render::post;

import c3d::maths;
import std::math;

<*
 Temporal jitter of a sample index, in NDC for the working extent.
 @require width > 0 && height > 0
 @pure
*>
fn Vec2 taa_jitter(uint sample_index, uint width, uint height) {
    uint point = sample_index % TAA_SAMPLE_COUNT + 1;
    float pixel_x = maths::halton(point, 2) - 0.5f;
    float pixel_y = maths::halton(point, 3) - 0.5f;
    return { 2 * pixel_x / (float)width, -2 * pixel_y / (float)height };
}
