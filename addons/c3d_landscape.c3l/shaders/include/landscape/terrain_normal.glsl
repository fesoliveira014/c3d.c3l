#ifndef LANDSCAPE_TERRAIN_NORMAL_GLSL
#define LANDSCAPE_TERRAIN_NORMAL_GLSL

#include "landscape/terrain_height.glsl"

// Central differences; at the map's border a present tile neighbour supplies the outside texel from the border
// ring, and any other border is one-sided.
vec2 terrain_gradient(uint height_texture, uint border_texture, TerrainParams params, ivec2 texel) {
    ivec2 last = ivec2(int(params.texels) - 1);
    ivec2 low = max(texel - 1, ivec2(0));
    ivec2 high = min(texel + 1, last);
    float low_x = terrain_height(height_texture, params, ivec2(low.x, texel.y));
    float high_x = terrain_height(height_texture, params, ivec2(high.x, texel.y));
    float low_z = terrain_height(height_texture, params, ivec2(texel.x, low.y));
    float high_z = terrain_height(height_texture, params, ivec2(texel.x, high.y));
    vec2 span = vec2(high - low);
    if (texel.x == 0 && terrain_has_border(params, TERRAIN_BORDER_WEST)) {
        low_x = terrain_border_height(border_texture, params, TERRAIN_BORDER_WEST, texel.y);
        span.x += 1.0;
    }
    if (texel.x == last.x && terrain_has_border(params, TERRAIN_BORDER_EAST)) {
        high_x = terrain_border_height(border_texture, params, TERRAIN_BORDER_EAST, texel.y);
        span.x += 1.0;
    }
    if (texel.y == 0 && terrain_has_border(params, TERRAIN_BORDER_NORTH)) {
        low_z = terrain_border_height(border_texture, params, TERRAIN_BORDER_NORTH, texel.x);
        span.y += 1.0;
    }
    if (texel.y == last.y && terrain_has_border(params, TERRAIN_BORDER_SOUTH)) {
        high_z = terrain_border_height(border_texture, params, TERRAIN_BORDER_SOUTH, texel.x);
        span.y += 1.0;
    }
    return vec2((high_x - low_x) / span.x, (high_z - low_z) / span.y) / params.cell_size;
}

// Integer heights have no filtered read: blend the four surrounding texels' gradients by hand.
vec3 terrain_local_normal(uint height_texture, uint border_texture, TerrainParams params, vec2 texel_position) {
    ivec2 last = ivec2(int(params.texels) - 1);
    ivec2 base = min(ivec2(floor(texel_position)), last);
    ivec2 next = min(base + 1, last);
    vec2 weight = texel_position - vec2(base);
    vec2 near_row = mix(
        terrain_gradient(height_texture, border_texture, params, base),
        terrain_gradient(height_texture, border_texture, params, ivec2(next.x, base.y)),
        weight.x
    );
    vec2 far_row = mix(
        terrain_gradient(height_texture, border_texture, params, ivec2(base.x, next.y)),
        terrain_gradient(height_texture, border_texture, params, next),
        weight.x
    );
    vec2 gradient = mix(near_row, far_row, weight.y);
    return normalize(vec3(-gradient.x, 1.0, -gradient.y));
}

#endif
