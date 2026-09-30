module landscape_foliage;

import std::math;
import c3d;
import c3d::asset;
import c3d::landscape::foliage;
import c3d::material;
import landscape_ground;

<* Node layer bit of the foliage layers, beside the terrain's bit so picks can leave either out. *>
const uint FOLIAGE_LAYER = 1 << 2;

<* Metres along a cell edge of the tree layer. *>
const float TREE_CELL_SIZE = 64; // a quarter of the grass cells: trees are sparse and fade far

<* Fade end of the tree layer when none is chosen, in metres. *>
const float DEFAULT_TREE_FADE_END = 400;

const uint GRASS_TARGET_INSTANCES @local = 200_000; // at every map size; the spacing follows the extent
const uint GRASS_SEED @local = 0x9a55;
const float GRASS_MAX_SLOPE @local = (float)math::PI * 0.25f;
const float GRASS_MIN_SCALE @local = 0.7f;
const float GRASS_MAX_SCALE @local = 1.3f;
const float GRASS_MIN_TINT @local = 0.8f;
const Vec4 GRASS_COLOR @local = { 0.2f, 0.42f, 0.1f, 1 };
const float GRASS_ROUGHNESS @local = 0.85f;
const uint GRASS_BLADES @local = 5;
const float BLADE_HEIGHT @local = 0.5f;
const float BLADE_WIDTH @local = 0.05f;
const float BLADE_MID_WIDTH_SHARE @local = 0.6f;
const float BLADE_LEAN @local = 0.12f; // metres the tip leans out from the clump centre
const float BLADE_MID_LEAN_SHARE @local = 0.25f; // the lean grows with the squared height: a quarter at half height
const float BLADE_NORMAL_LIFT @local = 0.4f; // tilts blade normals up so the clump shades like a surface
const float CLUMP_RADIUS @local = 0.06f;
const uint VERTICES_PER_BLADE @local = 5; // two base, two middle, one tip
const uint INDICES_PER_BLADE @local = 9;

const uint TREE_TARGET_INSTANCES @local = 5_000;
const uint TREE_SEED @local = 0x7ee5;
const float TREE_MAX_SLOPE @local = (float)math::PI / 6;
const float TREE_LINE @local = 0.55f; // share of the height scale; below the ground's snow line at 0.62
const float TREE_MIN_SCALE @local = 0.8f;
const float TREE_MAX_SCALE @local = 1.3f;
const float TREE_MIN_TINT @local = 0.85f;
const float TREE_FADE_START_SHARE @local = 0.625f; // 250 m at the default end
const uint TRUNK_SIDES @local = 8;
const float TRUNK_HEIGHT @local = 4;
const float TRUNK_BASE_RADIUS @local = 0.25f;
const float TRUNK_TOP_RADIUS @local = 0.12f;
const float TRUNK_TOP_ALPHA @local = 0.25f; // bend weight; the trunk barely sways
const uint CANOPY_QUADS @local = 4;
const float CANOPY_BOTTOM @local = 2.5f;
const float CANOPY_TOP @local = 8.5f;
const float CANOPY_HALF_WIDTH @local = 2.5f;
const float CANOPY_BOTTOM_ALPHA @local = 0.5f;
const uint QUAD_VERTICES @local = 4;
const uint QUAD_INDICES @local = 6;
const uint TRUNK_VERTICES @local = (TRUNK_SIDES + 1) * 2; // the seam column repeats for its texture coordinate
const uint TRUNK_INDICES @local = TRUNK_SIDES * QUAD_INDICES;
const uint CANOPY_VERTICES @local = CANOPY_QUADS * QUAD_VERTICES;
const uint CANOPY_INDICES @local = CANOPY_QUADS * QUAD_INDICES;
const float TREE_ALPHA_CUTOFF @local = 0.5f;
const uint ATLAS_SIZE @local = 256; // 256 KiB; bark in the left half, leaves in the right
const float ATLAS_INSET @local = 4.0f / ATLAS_SIZE; // four texels: bilinear and mip taps stay inside each half
const uint BARK_SEED @local = 0xa71a5;
const uint LEAF_SEED @local = 0x1eaf;
const uint LEAF_SHADE_SEED @local = 0x5ade;
const float BARK_STREAKS @local = 24; // noise cells across the bark half; stretched along v
const float BARK_STRETCH @local = 8;
const Vec3 BARK_DARK @local = { 0.16f, 0.1f, 0.06f };
const Vec3 BARK_LIGHT @local = { 0.36f, 0.25f, 0.15f };
const float LEAF_NOISE_CELLS @local = 16;
const float LEAF_SHADE_CELLS @local = 32; // finer than the cut-out, so single leaves vary in shade
const float LEAF_CUT @local = 0.5f; // the noise and rim blend above it is leaf, alpha 255; below, cut out
const float LEAF_NOISE_WEIGHT @local = 0.5f; // share of the cut the noise decides; the rest rounds the canopy
const float LEAF_EDGE_POWER @local = 2;
const Vec3 LEAF_DARK @local = { 0.06f, 0.2f, 0.04f };
const Vec3 LEAF_LIGHT @local = { 0.2f, 0.45f, 0.1f };
const float DISPLAY_GAMMA @local = 2.2f; // atlas colours are authored linear and stored sRGB
const uint RGBA8_BYTES @local = 4;
const float HASH_UNIT @local = 1.0f / 16777216.0f; // the top 24 bits of a hash, which a float holds exactly

const SwayTemplate TREE_SWAY @local = {
    .amplitude       = 0.3f,
    .full_bend_speed = 15,
    .frequency       = 0.35f,
    .lean            = 0.4f,
    .wavelength      = 24,
    .variation       = 0.3f,
    .weight          = SwayWeight.VERTEX_ALPHA,
};

fn uint pcg_hash(uint value) @local {
    uint state = value * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

fn float lattice_value(uint seed, int x, int z) @local {
    return (float)(pcg_hash(seed ^ pcg_hash((uint)x ^ pcg_hash((uint)z))) >> 8) * HASH_UNIT;
}

fn float value_noise(uint seed, float x, float z) @local {
    float floor_x = math::floor(x);
    float floor_z = math::floor(z);
    float fraction_x = x - floor_x;
    float fraction_z = z - floor_z;
    float smooth_x = fraction_x * fraction_x * (3 - 2 * fraction_x);
    float smooth_z = fraction_z * fraction_z * (3 - 2 * fraction_z);
    int left = (int)floor_x;
    int top = (int)floor_z;
    float near_row = blend(lattice_value(seed, left, top), lattice_value(seed, left + 1, top), smooth_x);
    float far_row = blend(lattice_value(seed, left, top + 1), lattice_value(seed, left + 1, top + 1), smooth_x);
    return blend(near_row, far_row, smooth_z);
}

fn float blend(float from, float to, float amount) @local => from + (to - from) * amount;

fn char unit_to_byte(float value) @local => (char)(math::clamp(value, 0.0f, 1.0f) * (float)char::max + 0.5f);

fn void write_texel(
    char[] pixels,
    usz index,
    Vec3 linear,
    bool opaque,
) @local {
    usz offset = index * RGBA8_BYTES;
    pixels[offset] = unit_to_byte(math::pow(linear.x, 1 / DISPLAY_GAMMA));
    pixels[offset + 1] = unit_to_byte(math::pow(linear.y, 1 / DISPLAY_GAMMA));
    pixels[offset + 2] = unit_to_byte(math::pow(linear.z, 1 / DISPLAY_GAMMA));
    pixels[offset + 3] = opaque ? char::max : 0;
}

fn TextureId? add_leaf_atlas(AssetStore* assets) @local {
    TextureId atlas;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)ATLAS_SIZE * ATLAS_SIZE * RGBA8_BYTES);
        uint half = ATLAS_SIZE / 2;
        for (uint row = 0; row < ATLAS_SIZE; row++) {
            for (uint column = 0; column < ATLAS_SIZE; column++) {
                usz index = (usz)row * ATLAS_SIZE + column;
                float v = (float)row / (float)ATLAS_SIZE;
                if (column < half) {
                    float u = (float)column / (float)half;
                    float streak = value_noise(BARK_SEED, u * BARK_STREAKS, v * BARK_STREAKS / BARK_STRETCH);
                    write_texel(
                        pixels: pixels,
                        index:  index,
                        linear: BARK_DARK + (BARK_LIGHT - BARK_DARK) * streak,
                        opaque: true,
                    );
                    continue;
                }
                float u = (float)(column - half) / (float)half;
                Vec2 centred = { u * 2 - 1, v * 2 - 1 };
                float rim = 1 - math::pow(math::min(centred.length(), 1.0f), LEAF_EDGE_POWER);
                float noise = value_noise(LEAF_SEED, u * LEAF_NOISE_CELLS, v * LEAF_NOISE_CELLS);
                float shade = value_noise(LEAF_SHADE_SEED, u * LEAF_SHADE_CELLS, v * LEAF_SHADE_CELLS);
                write_texel(
                    pixels: pixels,
                    index:  index,
                    linear: LEAF_DARK + (LEAF_LIGHT - LEAF_DARK) * shade,
                    opaque: blend(rim, noise, LEAF_NOISE_WEIGHT) > LEAF_CUT,
                );
            }
        }
        TextureDesc desc = material::texture_2d_desc(
            width:      ATLAS_SIZE,
            height:     ATLAS_SIZE,
            format:     RGBA8_SRGB,
            debug_name: "vegetation_atlas",
        );
        atlas = assets.add_texture(desc, pixels, "vegetation/atlas")!;
    };
    return atlas;
}

fn GeometryId? add_grass_clump(AssetStore* assets) @local {
    GeometryId clump;
    @pool() {
        Geometry grass = {
            .topology  = TRIANGLES,
            .positions = alloc::new_array(tmem, Vec3, (sz)(GRASS_BLADES * VERTICES_PER_BLADE)),
            .normals   = alloc::new_array(tmem, Vec3, (sz)(GRASS_BLADES * VERTICES_PER_BLADE)),
            .indices   = alloc::new_array(tmem, uint, (sz)(GRASS_BLADES * INDICES_PER_BLADE)),
        };
        for (uint blade = 0; blade < GRASS_BLADES; blade++) {
            float angle = 2 * (float)math::PI * (float)blade / (float)GRASS_BLADES;
            Vec3 outward = { math::cos(angle), 0, math::sin(angle) };
            Vec3 across = { -outward.z, 0, outward.x };
            Vec3 base = outward * CLUMP_RADIUS;
            Vec3 middle = base + outward * (BLADE_LEAN * BLADE_MID_LEAN_SHARE) + (Vec3){ 0, BLADE_HEIGHT * 0.5f, 0 };
            Vec3 tip = base + outward * BLADE_LEAN + (Vec3){ 0, BLADE_HEIGHT, 0 };
            float half_width = BLADE_WIDTH * 0.5f;
            float middle_half_width = half_width * BLADE_MID_WIDTH_SHARE;
            uint first = blade * VERTICES_PER_BLADE;
            grass.positions[first] = base - across * half_width;
            grass.positions[first + 1] = base + across * half_width;
            grass.positions[first + 2] = middle - across * middle_half_width;
            grass.positions[first + 3] = middle + across * middle_half_width;
            grass.positions[first + 4] = tip;
            Vec3 normal = (outward + (Vec3){ 0, BLADE_NORMAL_LIFT, 0 }).normalize();
            for (uint corner = 0; corner < VERTICES_PER_BLADE; corner++) grass.normals[first + corner] = normal;
            uint[INDICES_PER_BLADE] corners = { 0, 1, 2, 2, 1, 3, 2, 3, 4 };
            foreach (uint index, corner : corners) grass.indices[blade * INDICES_PER_BLADE + index] = first + corner;
        }
        grass.finalize();
        clump = assets.add_geometry(&grass, "vegetation/grass")!;
    };
    return clump;
}

// Vertex alpha is the sway weight: 0 plants the trunk's base, 1 frees the canopy's top.
fn GeometryId? add_tree(AssetStore* assets) @local {
    GeometryId tree;
    @pool() {
        Geometry shape = {
            .topology  = TRIANGLES,
            .positions = alloc::new_array(tmem, Vec3, (sz)(TRUNK_VERTICES + CANOPY_VERTICES)),
            .normals   = alloc::new_array(tmem, Vec3, (sz)(TRUNK_VERTICES + CANOPY_VERTICES)),
            .uv0       = alloc::new_array(tmem, Vec2, (sz)(TRUNK_VERTICES + CANOPY_VERTICES)),
            .colors    = alloc::new_array(tmem, Vec4, (sz)(TRUNK_VERTICES + CANOPY_VERTICES)),
            .indices   = alloc::new_array(tmem, uint, (sz)(TRUNK_INDICES + CANOPY_INDICES)),
        };
        float bark_width = 0.5f - 2 * ATLAS_INSET;
        for (uint side = 0; side <= TRUNK_SIDES; side++) {
            float share = (float)side / (float)TRUNK_SIDES;
            float angle = 2 * (float)math::PI * share;
            Vec3 radial = { math::cos(angle), 0, math::sin(angle) };
            float u = ATLAS_INSET + share * bark_width;
            uint bottom = side * 2;
            shape.positions[bottom] = radial * TRUNK_BASE_RADIUS;
            shape.positions[bottom + 1] = radial * TRUNK_TOP_RADIUS + (Vec3){ 0, TRUNK_HEIGHT, 0 };
            shape.normals[bottom] = radial;
            shape.normals[bottom + 1] = radial;
            shape.uv0[bottom] = { u, 1 - ATLAS_INSET };
            shape.uv0[bottom + 1] = { u, ATLAS_INSET };
            shape.colors[bottom] = { 1, 1, 1, 0 };
            shape.colors[bottom + 1] = { 1, 1, 1, TRUNK_TOP_ALPHA };
        }
        for (uint side = 0; side < TRUNK_SIDES; side++) {
            uint first = side * 2;
            uint[QUAD_INDICES] corners = { first, first + 1, first + 2, first + 2, first + 1, first + 3 };
            foreach (uint index, corner : corners) shape.indices[side * QUAD_INDICES + index] = corner;
        }

        float leaf_left = 0.5f + ATLAS_INSET;
        float leaf_right = 1 - ATLAS_INSET;
        for (uint quad = 0; quad < CANOPY_QUADS; quad++) {
            float angle = (float)math::PI * (float)quad / (float)CANOPY_QUADS;
            Vec3 along = { math::cos(angle), 0, math::sin(angle) };
            Vec3 normal = { -along.z, 0, along.x };
            uint first = TRUNK_VERTICES + quad * QUAD_VERTICES;
            Vec3 low = { 0, CANOPY_BOTTOM, 0 };
            Vec3 high = { 0, CANOPY_TOP, 0 };
            shape.positions[first] = low - along * CANOPY_HALF_WIDTH;
            shape.positions[first + 1] = low + along * CANOPY_HALF_WIDTH;
            shape.positions[first + 2] = high - along * CANOPY_HALF_WIDTH;
            shape.positions[first + 3] = high + along * CANOPY_HALF_WIDTH;
            shape.uv0[first] = { leaf_left, 1 - ATLAS_INSET };
            shape.uv0[first + 1] = { leaf_right, 1 - ATLAS_INSET };
            shape.uv0[first + 2] = { leaf_left, ATLAS_INSET };
            shape.uv0[first + 3] = { leaf_right, ATLAS_INSET };
            for (uint corner = 0; corner < QUAD_VERTICES; corner++) {
                shape.normals[first + corner] = normal;
                shape.colors[first + corner] = { 1, 1, 1, corner < 2 ? CANOPY_BOTTOM_ALPHA : 1 };
            }
            uint[QUAD_INDICES] corners = { first, first + 1, first + 2, first + 2, first + 1, first + 3 };
            foreach (uint index, corner : corners) shape.indices[TRUNK_INDICES + quad * QUAD_INDICES + index] = corner;
        }
        shape.finalize();
        tree = assets.add_geometry(&shape, "vegetation/tree")!;
    };
    return tree;
}

fn MaterialId? add_grass_material(AssetStore* assets) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = GRASS_COLOR;
    params.metallic = 0;
    params.roughness = GRASS_ROUGHNESS;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    return assets.add_material(material::standard(params, common), "vegetation/grass_material");
}

fn MaterialId? add_tree_material(AssetStore* assets, TextureId atlas) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.base_color_map = material::texture_slot(texture: atlas);
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = MASK;
    common.alpha_cutoff = TREE_ALPHA_CUTOFF;
    common.double_sided = true;
    return assets.add_material(material::standard(params, common), "vegetation/tree_material");
}

fn float channel_mean(TextureAsset* texture, uint channel) @local {
    double sum;
    usz texels = (usz)texture.desc.width * texture.desc.height;
    for (usz index = 0; index < texels; index++) sum += (double)texture.pixels[index * RGBA8_BYTES + channel];
    return (float)(sum / (double)texels / (double)char::max);
}

// Candidates per layer follow the extent, so a layer holds about its target at every map size.
fn float spacing_for(AssetStore* assets, Ground* ground, uint target) @local {
    float mean_density = channel_mean(assets.texture(ground.desc.control_map), 0);
    return ground.extent * math::sqrt(mean_density / (float)target);
}

<*
 Grass over the ground's grass weights: its clump, material and scatter rules.
 @param [&inout] assets : "Gains the clump geometry and its material."
 @param [&in] ground
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn FoliageDesc? grass_layer_desc(AssetStore* assets, Ground* ground) {
    FoliageDesc desc = foliage::default_foliage_desc();
    desc.geometry = add_grass_clump(assets)!;
    desc.material = add_grass_material(assets)!;
    desc.ground = ground.node.id;
    desc.rules.density_map = ground.desc.control_map;
    desc.rules.spacing = spacing_for(assets, ground, GRASS_TARGET_INSTANCES);
    desc.rules.seed = GRASS_SEED;
    desc.rules.max_slope = GRASS_MAX_SLOPE;
    desc.rules.min_scale = GRASS_MIN_SCALE;
    desc.rules.max_scale = GRASS_MAX_SCALE;
    desc.rules.min_tint = { GRASS_MIN_TINT, GRASS_MIN_TINT, GRASS_MIN_TINT };
    return desc;
}

<*
 Swaying trees over the ground's grass weights, below the tree line.
 @param [&inout] assets : "Gains the tree geometry, its leaf atlas and material."
 @param [&in] ground
 @param fade_end : "Metres from the camera where the trees have faded out."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn FoliageDesc? tree_layer_desc(AssetStore* assets, Ground* ground, float fade_end) {
    FoliageDesc desc = foliage::default_foliage_desc();
    desc.geometry = add_tree(assets)!;
    desc.material = add_tree_material(assets, add_leaf_atlas(assets)!)!;
    desc.ground = ground.node.id;
    desc.cell_size = TREE_CELL_SIZE;
    desc.rules.density_map = ground.desc.control_map;
    desc.rules.spacing = spacing_for(assets, ground, TREE_TARGET_INSTANCES);
    desc.rules.seed = TREE_SEED;
    desc.rules.max_slope = TREE_MAX_SLOPE;
    desc.rules.max_altitude = ground.desc.height_scale * TREE_LINE;
    desc.rules.min_scale = TREE_MIN_SCALE;
    desc.rules.max_scale = TREE_MAX_SCALE;
    desc.rules.min_tint = { TREE_MIN_TINT, TREE_MIN_TINT, TREE_MIN_TINT };
    desc.sway = TREE_SWAY;
    desc.fade = { .start = fade_end * TREE_FADE_START_SHARE, .end = fade_end };
    desc.cast_shadow = true;
    desc.trace = true;
    return desc;
}
