module c3d::landscape::foliage;

import c3d;
import c3d::asset;
import c3d::landscape::terrain;
import c3d::maths;
import c3d::scene;
import std::math;

const uint RGBA8_BYTES @private = 4;
const float TEXEL_UNIT_MAX @private = 255;
const float HASH_UNIT_SCALE @private = 1.0f / 16777216.0f; // the top 24 bits, which a float holds exactly

enum Channel @private {
    JITTER_X,
    JITTER_Z,
    ACCEPT,
    YAW,
    SCALE,
    TINT,
}

struct ScatterFrame @private {
    HeightView    ground;
    ScatterRules* rules;
    Mat4          layer_world;
    float         layer_height;  // world y of the layer origin
    float         cell_size;
    uint          strata;        // candidates along one cell edge
    float         extent;        // metres along one edge of the ground terrain
    char[]        density;       // RGBA8 texels, row-major
    uint          density_width;
    uint          density_height;
    float         min_normal_y;  // cos(max_slope)
}

struct Candidate @private {
    uint  key;
    float local_x; // layer-local
    float local_z;
    float world_x;
    float world_z;
}

fn ScatterFrame? scatter_frame(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    FoliageDesc* desc,
) @private {
    if (!scene.world.is_alive(desc.ground) || !scene.world.has(desc.ground, TerrainRuntime)) {
        return c3d::INVALID_ID~;
    }
    HeightView ground = terrain::height_view(scene, assets, desc.ground)!;
    if (!assets.textures.is_live(desc.rules.density_map)) return c3d::INVALID_ID~;
    TextureAsset* density = assets.textures.get(desc.rules.density_map);
    check_density_map(density)!;
    return {
        .ground         = ground,
        .rules          = &desc.rules,
        .layer_world    = node.world,
        .layer_height   = maths::translation(node.world).y,
        .cell_size      = desc.cell_size,
        .strata         = max((uint)math::round(desc.cell_size / desc.rules.spacing), 1u),
        .extent         = (float)(ground.texels_per_side - 1) * ground.cell_size,
        .density        = density.pixels,
        .density_width  = density.desc.width,
        .density_height = density.desc.height,
        .min_normal_y   = math::cos(desc.rules.max_slope),
    };
}

fn void? check_density_map(TextureAsset* texture) @private {
    TextureDesc desc = texture.desc;
    if (texture.source_kind != MIP_ZERO || desc.format != RGBA8_UNORM) return c3d::UNSUPPORTED~;
    if (desc.layers != 1 || desc.depth != 0 || desc.is_cube) return c3d::UNSUPPORTED~;
    if (texture.pixels.len != (usz)desc.width * desc.height * RGBA8_BYTES) return c3d::INVALID_ARGUMENT~;
}

// Jarzynski and Olano 2020, the permutation of noise.glsl's pcg_hash.
fn uint pcg_hash(uint value) @private {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// Stateless per candidate, so a cell places the same instances in any order and on any thread.
fn uint candidate_key(
    uint seed,
    uint column,
    uint row,
    uint candidate,
) @private {
    return pcg_hash(pcg_hash(pcg_hash(pcg_hash(seed) ^ column) ^ row) ^ candidate);
}

fn float channel_unit(uint key, Channel channel) @private {
    return (float)(pcg_hash(key + (uint)channel.ordinal) >> 8) * HASH_UNIT_SCALE;
}

fn Candidate candidate_at(
    ScatterFrame* frame,
    uint column,
    uint row,
    uint candidate,
) @private {
    uint key = candidate_key(
        seed:      frame.rules.seed,
        column:    column,
        row:       row,
        candidate: candidate,
    );
    float stratum = frame.cell_size / (float)frame.strata;
    float local_x = (float)column * frame.cell_size
      + ((float)(candidate % frame.strata) + channel_unit(key, JITTER_X)) * stratum;
    float local_z = (float)row * frame.cell_size
      + ((float)(candidate / frame.strata) + channel_unit(key, JITTER_Z)) * stratum;
    Vec3 world = maths::transform_point(frame.layer_world, { local_x, 0, local_z });
    return {
        .key     = key,
        .local_x = local_x,
        .local_z = local_z,
        .world_x = world.x,
        .world_z = world.z,
    };
}

// The density stage: the only stage that sets a cell's capacity. Outside the ground's extent nothing grows.
fn bool passes_density(ScatterFrame* frame, Candidate* candidate) @private {
    Vec3 local = maths::transform_point(frame.ground.local_from_world, { candidate.world_x, 0, candidate.world_z });
    float u = local.x / frame.extent;
    float v = local.z / frame.extent;
    if (u < 0 || v < 0 || u > 1 || v > 1) return false;
    return channel_unit(candidate.key, ACCEPT) < density_at(frame, u, v);
}

// Bilinear between texel centres with clamped edges, as the GPU samples the terrain's control map.
fn float density_at(ScatterFrame* frame, float u, float v) @private {
    float x = u * (float)frame.density_width - 0.5f;
    float z = v * (float)frame.density_height - 0.5f;
    float floor_x = math::floor(x);
    float floor_z = math::floor(z);
    float fraction_x = x - floor_x;
    float fraction_z = z - floor_z;
    int left = (int)floor_x;
    int top = (int)floor_z;
    float near_row = blend(
        density_texel(frame, left, top),
        density_texel(frame, left + 1, top),
        fraction_x,
    );
    float far_row = blend(
        density_texel(frame, left, top + 1),
        density_texel(frame, left + 1, top + 1),
        fraction_x,
    );
    return blend(near_row, far_row, fraction_z);
}

fn float blend(float from, float to, float amount) @private => from + (to - from) * amount;

fn float density_texel(ScatterFrame* frame, int x, int z) @private {
    usz column = (usz)math::clamp(x, 0, (int)frame.density_width - 1);
    usz row = (usz)math::clamp(z, 0, (int)frame.density_height - 1);
    usz offset = (row * frame.density_width + column) * RGBA8_BYTES + frame.rules.density_channel;
    return (float)frame.density[offset] / TEXEL_UNIT_MAX;
}

fn uint count_cell(ScatterFrame* frame, uint column, uint row) @private {
    uint count;
    for (uint candidate = 0; candidate < frame.strata * frame.strata; candidate++) {
        Candidate at = candidate_at(
            frame:     frame,
            column:    column,
            row:       row,
            candidate: candidate,
        );
        if (passes_density(frame, &at)) count++;
    }
    return count;
}

// Every filter after the density stage only removes, so a cell never outgrows its count.
fn uint place_cell(
    ScatterFrame* frame,
    uint column,
    uint row,
    Transform[] transforms,
    Vec4[] colors,
) @private {
    ScatterRules* rules = frame.rules;
    uint count;
    for (uint candidate = 0; candidate < frame.strata * frame.strata; candidate++) {
        Candidate at = candidate_at(
            frame:     frame,
            column:    column,
            row:       row,
            candidate: candidate,
        );
        if (!passes_density(frame, &at)) continue;
        float? height = terrain::sample_height(&frame.ground, at.world_x, at.world_z);
        if (catch height) continue;
        if (height < rules.min_altitude || height > rules.max_altitude) continue;
        Vec3? normal = terrain::sample_normal(&frame.ground, at.world_x, at.world_z);
        if (catch normal) continue;
        if (normal.y < frame.min_normal_y) continue;

        float scale = blend(rules.min_scale, rules.max_scale, channel_unit(at.key, SCALE));
        float yaw = channel_unit(at.key, YAW) * 2 * (float)math::PI;
        Vec3 tint = rules.min_tint + (rules.max_tint - rules.min_tint) * channel_unit(at.key, TINT);
        transforms[count] = {
            .position = { at.local_x, height - frame.layer_height, at.local_z },
            .rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, yaw),
            .scale    = { scale, scale, scale },
        };
        colors[count] = { tint.x, tint.y, tint.z, 1 };
        count++;
    }
    return count;
}
