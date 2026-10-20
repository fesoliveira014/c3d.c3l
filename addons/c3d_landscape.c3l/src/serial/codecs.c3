module c3d::landscape @feat(C3D_LANDSCAPE_SERIAL);

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::describe;
import c3d::ecs;
import c3d::landscape::foliage @public;
import c3d::landscape::terrain @public;
import c3d::landscape::water @public;
import c3d::material;
import c3d::scene;
import c3d::serial;
import std::math;

const ulong TERRAIN_V1_LAYOUT @private = 0x7638a7507fa65b33;
const ulong TERRAIN_V2_LAYOUT @private = 0xbbb8c4e5931f82a4;
const ulong TERRAIN_V3_LAYOUT @private = 0xa32420a76628fd33;
const ulong TERRAIN_LAYOUT @private = 0x93bc20cf0d28ef4d;
const ulong TERRAIN_TILE_LAYOUT @private = 0x3fe780c7be5416e1;
const ulong TERRAIN_SET_LAYOUT @private = 0x6b17270c6b53663f;
const ulong SCATTER_V1_LAYOUT @private = 0x788326d1092caa6b;
const ulong SCATTER_LAYOUT @private = 0x40955fefc693491e;
const ulong SWAY_LAYOUT @private = 0x750cddc9cb008976;
const ulong FOLIAGE_V1_LAYOUT @private = 0x20330122082bd780;
const ulong FOLIAGE_V2_LAYOUT @private = 0x797c3ed45915c1ed;
const ulong FOLIAGE_LAYOUT @private = 0xbf8d67f654870b2c;
const ulong WAVE_LAYOUT @private = 0xb7ea583c7a255cb9;
const ulong WATER_V1_LAYOUT @private = 0x74434d01389bb922;
const ulong WATER_V2_LAYOUT @private = 0x718815cf64669e4e;
const ulong WATER_V3_LAYOUT @private = 0x90996b184cb03fab;
const ulong WATER_V4_LAYOUT @private = 0x80dcad9164b35ea9;
const ulong WATER_SIMULATION_LAYOUT @private = 0x2c6503594d42a697;
const ulong WATER_SPECTRUM_LAYOUT @private = 0x28afc5f2289d18ba;
const ulong WATER_LAYOUT @private = 0x778206e41e29aa24;

struct TerrainDescV1 @private {
    TextureId  height_map;
    TextureId  control_map;
    float      cell_size;
    float      height_scale;
    MaterialId[material::MAX_CUSTOM_MATERIAL_REFERENCES] layers;
    float      lod_threshold;
    float      lod_hysteresis;
    bool       cast_shadow;
    bool       receive_shadow;
}

struct TerrainDescV2 @private {
    TextureId  height_map;
    TextureId  control_map;
    float      cell_size;
    float      height_scale;
    MaterialId[material::MAX_CUSTOM_MATERIAL_REFERENCES] layers;
    float      lod_threshold;
    float      lod_hysteresis;
    SlopeProjection slope_projection;
    float      triplanar_sharpness;
    bool       cast_shadow;
    bool       receive_shadow;
}

struct TerrainDescV3 @private {
    TextureId  height_map;
    TextureId  control_map;
    float      cell_size;
    float      height_scale;
    MaterialId[material::MAX_CUSTOM_MATERIAL_REFERENCES] layers;
    float      lod_threshold;
    float      lod_hysteresis;
    float      morph_band;
    SlopeProjection slope_projection;
    float      triplanar_sharpness;
    bool       cast_shadow;
    bool       receive_shadow;
}

serial::BinaryCompatibility[3] terrain_binary_compatibility @local = {
    { .version = 1, .read = &read_terrain_v1 },
    { .version = 2, .read = &read_terrain_v2 },
    { .version = 3, .read = &read_terrain_v3 },
};
uint[3] terrain_text_default_versions @local = { 1, 2, 3 };

struct WaterDescV1 @private {
    Wave[water::MAX_WAVES] waves;
    uint                   wave_count;
    GeometryId             geometry;
    float                  extent;
    float                  cell_size;
    Vec3                   absorption_color;
    float                  absorption_distance;
    Vec3                   scatter_color;
    float                  roughness;
    float                  refraction_strength;
    float                  reflection_distortion;
    float                  foam_depth;
    float                  foam_crest;
    float                  ripple_drift;
    MaterialId             ripples;
    MaterialId             foam;
    bool                   march_reflections;
}

struct WaterDescV2 @private {
    Wave[water::MAX_WAVES] waves;
    uint                   wave_count;
    GeometryId             geometry;
    float                  extent;
    float                  cell_size;
    Vec3                   absorption_color;
    float                  absorption_distance;
    Vec3                   scatter_color;
    float                  roughness;
    float                  refraction_strength;
    float                  reflection_distortion;
    float                  foam_depth;
    float                  foam_crest;
    float                  ripple_drift;
    MaterialId             ripples;
    MaterialId             foam;
    bool                   march_reflections;
    uint                   max_mirrors;
    uint                   reflection_view_slot;
}

struct WaterDescV3 @private {
    Wave[water::MAX_WAVES] waves;
    uint                   wave_count;
    GeometryId             geometry;
    float                  extent;
    float                  cell_size;
    Vec3                   absorption_color;
    float                  absorption_distance;
    Vec3                   scatter_color;
    float                  roughness;
    float                  refraction_strength;
    float                  reflection_distortion;
    float                  foam_depth;
    float                  foam_crest;
    float                  ripple_drift;
    MaterialId             ripples;
    MaterialId             foam;
    bool                   march_reflections;
    uint                   max_mirrors;
    uint                   reflection_view_slot;
    bool                   trace;
}

struct WaterDescV4 @private {
    Wave[water::MAX_WAVES] waves;
    uint                   wave_count;
    GeometryId             geometry;
    float                  extent;
    float                  cell_size;
    Vec3                   absorption_color;
    float                  absorption_distance;
    Vec3                   scatter_color;
    float                  roughness;
    float                  refraction_strength;
    float                  reflection_distortion;
    float                  foam_depth;
    float                  foam_crest;
    float                  ripple_drift;
    MaterialId             ripples;
    MaterialId             foam;
    bool                   march_reflections;
    uint                   max_mirrors;
    uint                   reflection_view_slot;
    bool                   trace;
    WaterMode              mode;
    float                  depth;
}

serial::BinaryCompatibility[4] water_binary_compatibility @local = {
    { .version = 1, .read = &read_water_v1 },
    { .version = 2, .read = &read_water_v2 },
    { .version = 3, .read = &read_water_v3 },
    { .version = 4, .read = &read_water_v4 },
};
uint[4] water_text_default_versions @local = { 1, 2, 3, 4 };

struct TerrainSetAuthoring @private {
    uint  texels;
    float cell_size;
    float height_scale;
}

struct ScatterRulesV1 @private {
    TextureId density_map;
    uint density_channel;
    float spacing;
    uint seed;
    float max_slope;
    float min_altitude;
    float max_altitude;
    float min_scale;
    float max_scale;
    Vec3 min_tint;
    Vec3 max_tint;
}

struct FoliageAuthoringV1 @private {
    GeometryId geometry;
    MaterialId material;
    LodDesc[] lod;
    Entity ground;
    float cell_size;
    ScatterRulesV1 rules;
    SwayTemplate sway;
    InstanceFade fade;
    bool cast_shadow;
    bool receive_shadow;
    bool trace;
}

struct FoliageAuthoringV2 @private {
    GeometryId geometry;
    MaterialId material;
    LodDesc[] lod;
    Entity ground;
    float cell_size;
    ScatterRules rules;
    SwayTemplate sway;
    InstanceFade fade;
    bool cast_shadow;
    bool receive_shadow;
    bool trace;
}

struct FoliageAuthoring @private {
    GeometryId geometry;
    MaterialId material;
    LodDesc[] lod;
    Entity ground;
    float cell_size;
    ScatterRules rules;
    SwayTemplate sway;
    InstanceFade fade;
    bool cast_shadow;
    bool receive_shadow;
    bool trace;
    bool trace_sway;
}

serial::BinaryCompatibility[2] foliage_binary_compatibility @local = {
    { .version = 1, .read = &read_foliage_v1 },
    { .version = 2, .read = &read_foliage_v2 },
};
uint[2] foliage_text_default_versions @local = { 1, 2 };

<*
 Register landscape authoring codecs and generated-state ownership.
 @return? describe::DESCRIPTION_CONFLICT, describe::MISSING_DESCRIPTION
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
*>
fn void? register_serial_codecs() {
    serial::register_core_value_types()!;
    register_value(TerrainDescV1, TERRAIN_V1_LAYOUT, &defaults_terrain_v1)!;
    describe::register_reflected(TerrainDescV2)!;
    serial::register_described_type(
        $Type: TerrainDescV2,
        version: 2,
        layout: TERRAIN_V2_LAYOUT,
        defaults: &defaults_terrain_v2,
    )!;
    describe::register_reflected(TerrainDescV3)!;
    serial::register_described_type(
        $Type: TerrainDescV3,
        version: 3,
        layout: TERRAIN_V3_LAYOUT,
        defaults: &defaults_terrain_v3,
    )!;
    describe::register_reflected(TerrainDesc)!;
    serial::register_described_type(
        $Type: TerrainDesc,
        version: 4,
        layout: TERRAIN_LAYOUT,
        defaults: &defaults_terrain,
    )!;
    register_value(TerrainTile, TERRAIN_TILE_LAYOUT, &defaults_terrain_tile)!;
    register_value(TerrainSetAuthoring, TERRAIN_SET_LAYOUT, &defaults_terrain_set)!;
    register_value(ScatterRulesV1, SCATTER_V1_LAYOUT, &defaults_scatter_v1)!;
    register_value(ScatterRules, SCATTER_LAYOUT, &defaults_scatter)!;
    register_value(SwayTemplate, SWAY_LAYOUT, &defaults_sway)!;
    register_value(FoliageAuthoringV1, FOLIAGE_V1_LAYOUT, &defaults_foliage_v1)!;
    describe::register_reflected(FoliageAuthoringV2)!;
    serial::register_described_type(
        $Type: FoliageAuthoringV2,
        version: 2,
        layout: FOLIAGE_V2_LAYOUT,
        defaults: &defaults_foliage_v2,
    )!;
    describe::register_reflected(FoliageAuthoring)!;
    serial::register_described_type(
        $Type: FoliageAuthoring,
        version: 3,
        layout: FOLIAGE_LAYOUT,
        defaults: &defaults_foliage,
    )!;
    register_value(Wave, WAVE_LAYOUT, &defaults_wave)!;
    register_value(WaterDescV1, WATER_V1_LAYOUT, &defaults_water_v1)!;
    describe::register_reflected(WaterDescV2)!;
    serial::register_described_type(
        $Type: WaterDescV2,
        version: 2,
        layout: WATER_V2_LAYOUT,
        defaults: &defaults_water_v2,
    )!;
    describe::register_reflected(WaterDescV3)!;
    serial::register_described_type(
        $Type: WaterDescV3,
        version: 3,
        layout: WATER_V3_LAYOUT,
        defaults: &defaults_water_v3,
    )!;
    describe::register_reflected(WaterDescV4)!;
    serial::register_described_type(
        $Type: WaterDescV4,
        version: 4,
        layout: WATER_V4_LAYOUT,
        defaults: &defaults_water_v4,
    )!;
    register_value(WaterSimulation, WATER_SIMULATION_LAYOUT, &defaults_water_simulation)!;
    register_value(WaterSpectrum, WATER_SPECTRUM_LAYOUT, &defaults_water_spectrum)!;
    describe::register_reflected(WaterDesc)!;
    serial::register_described_type(
        $Type: WaterDesc,
        version: 5,
        layout: WATER_LAYOUT,
        defaults: &defaults_water,
    )!;
    serial::register_described_owner(Terrain, TerrainDesc, {
        .name = "terrain",
        .phase = VALUE,
        .collect = &collect_terrain,
        .project = &project_terrain,
        .validate = &validate_terrain,
        .attach = &attach_terrain,
        .binary_compatibility = terrain_binary_compatibility[..],
        .text_default_versions = terrain_text_default_versions[..],
    })!;
    serial::register_described(TerrainTile, { .name = "terrain_tile", .phase = VALUE })!;
    serial::register_described_owner(TerrainSet, TerrainSetAuthoring, {
        .name = "terrain_set",
        .phase = VALUE,
        .project = &project_terrain_set,
        .validate = &validate_terrain_set,
        .attach = &attach_terrain_set,
    })!;
    serial::register_described_owner(Foliage, FoliageAuthoring, {
        .name = "foliage",
        .phase = OWNER,
        .collect = &collect_foliage,
        .project = &project_foliage,
        .validate = &validate_foliage,
        .attach = &attach_foliage,
        .binary_compatibility = foliage_binary_compatibility[..],
        .text_default_versions = foliage_text_default_versions[..],
    })!;
    serial::register_described_owner(Water, WaterDesc, {
        .name = "water",
        .phase = OWNER,
        .collect = &collect_water,
        .project = &project_water,
        .validate = &validate_water,
        .attach = &attach_water,
        .binary_compatibility = water_binary_compatibility[..],
        .text_default_versions = water_text_default_versions[..],
    })!;
    serial::register_transient(TerrainRuntime, &collect_terrain_runtime)!;
    serial::register_transient(FoliageRuntime, &collect_foliage_runtime)!;
    serial::register_transient(foliage::FoliageCellOwner, &collect_foliage_cell)!;
    serial::register_transient(WaterRuntime, &collect_water_runtime)!;
    serial::register_transient(WaterMirror, &collect_water_mirror)!;
}

macro void? register_value($Type, ulong layout, serial::DefaultsFn defaults) @private {
    describe::register_reflected($Type)!;
    serial::register_described_type(
        $Type: $Type,
        version: 1,
        layout: layout,
        defaults: defaults,
    )!;
}

fn void defaults_terrain(void* value) @private => *(TerrainDesc*)value = terrain::default_terrain_desc();

fn void defaults_terrain_v1(void* value) @private {
    TerrainDesc defaults = terrain::default_terrain_desc();
    *(TerrainDescV1*)value = {
        .lod_threshold = defaults.lod_threshold,
        .lod_hysteresis = defaults.lod_hysteresis,
        .cast_shadow = defaults.cast_shadow,
        .receive_shadow = defaults.receive_shadow,
    };
}

fn void defaults_terrain_v2(void* value) @private {
    *(TerrainDescV2*)value = terrain_desc_v2(terrain::default_terrain_desc());
}

fn TerrainDescV2 terrain_desc_v2(TerrainDesc desc) @private {
    return {
        .height_map          = desc.height_map,
        .control_map         = desc.control_map,
        .cell_size           = desc.cell_size,
        .height_scale        = desc.height_scale,
        .layers              = desc.layers,
        .lod_threshold       = desc.lod_threshold,
        .lod_hysteresis      = desc.lod_hysteresis,
        .slope_projection    = desc.slope_projection,
        .triplanar_sharpness = desc.triplanar_sharpness,
        .cast_shadow         = desc.cast_shadow,
        .receive_shadow      = desc.receive_shadow,
    };
}

fn TerrainDesc terrain_desc_from_v2(TerrainDescV2 legacy) @private {
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = legacy.height_map;
    desc.control_map = legacy.control_map;
    desc.cell_size = legacy.cell_size;
    desc.height_scale = legacy.height_scale;
    desc.layers = legacy.layers;
    desc.lod_threshold = legacy.lod_threshold;
    desc.lod_hysteresis = legacy.lod_hysteresis;
    desc.slope_projection = legacy.slope_projection;
    desc.triplanar_sharpness = legacy.triplanar_sharpness;
    desc.cast_shadow = legacy.cast_shadow;
    desc.receive_shadow = legacy.receive_shadow;
    return desc;
}

fn void defaults_terrain_v3(void* value) @private {
    *(TerrainDescV3*)value = terrain_desc_v3(terrain::default_terrain_desc());
}

fn TerrainDescV3 terrain_desc_v3(TerrainDesc desc) @private {
    return {
        .height_map          = desc.height_map,
        .control_map         = desc.control_map,
        .cell_size           = desc.cell_size,
        .height_scale        = desc.height_scale,
        .layers              = desc.layers,
        .lod_threshold       = desc.lod_threshold,
        .lod_hysteresis      = desc.lod_hysteresis,
        .morph_band          = desc.morph_band,
        .slope_projection    = desc.slope_projection,
        .triplanar_sharpness = desc.triplanar_sharpness,
        .cast_shadow         = desc.cast_shadow,
        .receive_shadow      = desc.receive_shadow,
    };
}

fn TerrainDesc terrain_desc_from_v3(TerrainDescV3 legacy) @private {
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = legacy.height_map;
    desc.control_map = legacy.control_map;
    desc.cell_size = legacy.cell_size;
    desc.height_scale = legacy.height_scale;
    desc.layers = legacy.layers;
    desc.lod_threshold = legacy.lod_threshold;
    desc.lod_hysteresis = legacy.lod_hysteresis;
    desc.morph_band = legacy.morph_band;
    desc.slope_projection = legacy.slope_projection;
    desc.triplanar_sharpness = legacy.triplanar_sharpness;
    desc.cast_shadow = legacy.cast_shadow;
    desc.receive_shadow = legacy.receive_shadow;
    return desc;
}

fn void defaults_terrain_tile(void* value) @private => *(TerrainTile*)value = {};
fn void defaults_terrain_set(void* value) @private => *(TerrainSetAuthoring*)value = {};
fn void defaults_scatter_v1(void* value) @private {
    *(ScatterRulesV1*)value = scatter_rules_v1(foliage::default_foliage_desc().rules);
}
fn void defaults_scatter(void* value) @private => *(ScatterRules*)value = foliage::default_foliage_desc().rules;
fn void defaults_sway(void* value) @private => *(SwayTemplate*)value = foliage::default_foliage_desc().sway;
fn void defaults_foliage_v1(void* value) @private {
    *(FoliageAuthoringV1*)value = foliage_authoring_v1(foliage_value(foliage::default_foliage_desc()));
}
fn void defaults_foliage_v2(void* value) @private {
    *(FoliageAuthoringV2*)value = foliage_authoring_v2(foliage_value(foliage::default_foliage_desc()));
}
fn void defaults_foliage(void* value) @private {
    *(FoliageAuthoring*)value = foliage_value(foliage::default_foliage_desc());
}
fn void defaults_wave(void* value) @private => *(Wave*)value = {};
fn void defaults_water(void* value) @private => *(WaterDesc*)value = water::default_water_desc();
fn void defaults_water_simulation(void* value) @private {
    *(WaterSimulation*)value = water::default_water_desc().simulation;
}
fn void defaults_water_spectrum(void* value) @private => *(WaterSpectrum*)value = {};

fn void defaults_water_v1(void* value) @private {
    *(WaterDescV1*)value = water_desc_v1(water::default_water_desc());
}

fn WaterDescV1 water_desc_v1(WaterDesc desc) @private {
    return {
        .waves                 = desc.waves,
        .wave_count            = desc.wave_count,
        .geometry              = desc.geometry,
        .extent                = desc.extent,
        .cell_size             = desc.cell_size,
        .absorption_color      = desc.absorption_color,
        .absorption_distance   = desc.absorption_distance,
        .scatter_color         = desc.scatter_color,
        .roughness             = desc.roughness,
        .refraction_strength   = desc.refraction_strength,
        .reflection_distortion = desc.reflection_distortion,
        .foam_depth            = desc.foam_depth,
        .foam_crest            = desc.foam_crest,
        .ripple_drift          = desc.ripple_drift,
        .ripples               = desc.ripples,
        .foam                  = desc.foam,
        .march_reflections     = desc.march_reflections,
    };
}

fn void defaults_water_v2(void* value) @private {
    *(WaterDescV2*)value = water_desc_v2(water::default_water_desc());
}

fn WaterDescV2 water_desc_v2(WaterDesc desc) @private {
    return {
        .waves                 = desc.waves,
        .wave_count            = desc.wave_count,
        .geometry              = desc.geometry,
        .extent                = desc.extent,
        .cell_size             = desc.cell_size,
        .absorption_color      = desc.absorption_color,
        .absorption_distance   = desc.absorption_distance,
        .scatter_color         = desc.scatter_color,
        .roughness             = desc.roughness,
        .refraction_strength   = desc.refraction_strength,
        .reflection_distortion = desc.reflection_distortion,
        .foam_depth            = desc.foam_depth,
        .foam_crest            = desc.foam_crest,
        .ripple_drift          = desc.ripple_drift,
        .ripples               = desc.ripples,
        .foam                  = desc.foam,
        .march_reflections     = desc.march_reflections,
        .max_mirrors           = desc.max_mirrors,
        .reflection_view_slot  = desc.reflection_view_slot,
    };
}

fn void defaults_water_v3(void* value) @private {
    *(WaterDescV3*)value = water_desc_v3(water::default_water_desc());
}

fn WaterDescV3 water_desc_v3(WaterDesc desc) @private {
    return {
        .waves                 = desc.waves,
        .wave_count            = desc.wave_count,
        .geometry              = desc.geometry,
        .extent                = desc.extent,
        .cell_size             = desc.cell_size,
        .absorption_color      = desc.absorption_color,
        .absorption_distance   = desc.absorption_distance,
        .scatter_color         = desc.scatter_color,
        .roughness             = desc.roughness,
        .refraction_strength   = desc.refraction_strength,
        .reflection_distortion = desc.reflection_distortion,
        .foam_depth            = desc.foam_depth,
        .foam_crest            = desc.foam_crest,
        .ripple_drift          = desc.ripple_drift,
        .ripples               = desc.ripples,
        .foam                  = desc.foam,
        .march_reflections     = desc.march_reflections,
        .max_mirrors           = desc.max_mirrors,
        .reflection_view_slot  = desc.reflection_view_slot,
        .trace                 = desc.trace,
    };
}

fn void defaults_water_v4(void* value) @private {
    *(WaterDescV4*)value = water_desc_v4(water::default_water_desc());
}

fn WaterDescV4 water_desc_v4(WaterDesc desc) @private {
    return {
        .waves                 = desc.waves,
        .wave_count            = desc.wave_count,
        .geometry              = desc.geometry,
        .extent                = desc.extent,
        .cell_size             = desc.cell_size,
        .absorption_color      = desc.absorption_color,
        .absorption_distance   = desc.absorption_distance,
        .scatter_color         = desc.scatter_color,
        .roughness             = desc.roughness,
        .refraction_strength   = desc.refraction_strength,
        .reflection_distortion = desc.reflection_distortion,
        .foam_depth            = desc.foam_depth,
        .foam_crest            = desc.foam_crest,
        .ripple_drift          = desc.ripple_drift,
        .ripples               = desc.ripples,
        .foam                  = desc.foam,
        .march_reflections     = desc.march_reflections,
        .max_mirrors           = desc.max_mirrors,
        .reflection_view_slot  = desc.reflection_view_slot,
        .trace                 = desc.trace,
        .mode                  = desc.mode,
        .depth                 = desc.depth,
    };
}

fn WaterDesc water_desc_from_v4(WaterDescV4 legacy) @private {
    WaterDesc desc = water_desc_from_v3({
        .waves                 = legacy.waves,
        .wave_count            = legacy.wave_count,
        .geometry              = legacy.geometry,
        .extent                = legacy.extent,
        .cell_size             = legacy.cell_size,
        .absorption_color      = legacy.absorption_color,
        .absorption_distance   = legacy.absorption_distance,
        .scatter_color         = legacy.scatter_color,
        .roughness             = legacy.roughness,
        .refraction_strength   = legacy.refraction_strength,
        .reflection_distortion = legacy.reflection_distortion,
        .foam_depth            = legacy.foam_depth,
        .foam_crest            = legacy.foam_crest,
        .ripple_drift          = legacy.ripple_drift,
        .ripples               = legacy.ripples,
        .foam                  = legacy.foam,
        .march_reflections     = legacy.march_reflections,
        .max_mirrors           = legacy.max_mirrors,
        .reflection_view_slot  = legacy.reflection_view_slot,
        .trace                 = legacy.trace,
    });
    desc.mode = legacy.mode;
    desc.depth = legacy.depth;
    return desc;
}

fn WaterDesc water_desc_from_v3(WaterDescV3 legacy) @private {
    WaterDesc desc = water::default_water_desc();
    desc.waves = legacy.waves;
    desc.wave_count = legacy.wave_count;
    desc.geometry = legacy.geometry;
    desc.extent = legacy.extent;
    desc.cell_size = legacy.cell_size;
    desc.absorption_color = legacy.absorption_color;
    desc.absorption_distance = legacy.absorption_distance;
    desc.scatter_color = legacy.scatter_color;
    desc.roughness = legacy.roughness;
    desc.refraction_strength = legacy.refraction_strength;
    desc.reflection_distortion = legacy.reflection_distortion;
    desc.foam_depth = legacy.foam_depth;
    desc.foam_crest = legacy.foam_crest;
    desc.ripple_drift = legacy.ripple_drift;
    desc.ripples = legacy.ripples;
    desc.foam = legacy.foam;
    desc.march_reflections = legacy.march_reflections;
    desc.max_mirrors = legacy.max_mirrors;
    desc.reflection_view_slot = legacy.reflection_view_slot;
    desc.trace = legacy.trace;
    return desc;
}

fn WaterDesc water_desc_from_v2(WaterDescV2 legacy) @private {
    WaterDesc desc = water::default_water_desc();
    desc.waves = legacy.waves;
    desc.wave_count = legacy.wave_count;
    desc.geometry = legacy.geometry;
    desc.extent = legacy.extent;
    desc.cell_size = legacy.cell_size;
    desc.absorption_color = legacy.absorption_color;
    desc.absorption_distance = legacy.absorption_distance;
    desc.scatter_color = legacy.scatter_color;
    desc.roughness = legacy.roughness;
    desc.refraction_strength = legacy.refraction_strength;
    desc.reflection_distortion = legacy.reflection_distortion;
    desc.foam_depth = legacy.foam_depth;
    desc.foam_crest = legacy.foam_crest;
    desc.ripple_drift = legacy.ripple_drift;
    desc.ripples = legacy.ripples;
    desc.foam = legacy.foam;
    desc.march_reflections = legacy.march_reflections;
    desc.max_mirrors = legacy.max_mirrors;
    desc.reflection_view_slot = legacy.reflection_view_slot;
    return desc;
}

fn WaterDesc water_desc_from_v1(WaterDescV1 legacy) @private {
    WaterDesc desc = water::default_water_desc();
    desc.waves = legacy.waves;
    desc.wave_count = legacy.wave_count;
    desc.geometry = legacy.geometry;
    desc.extent = legacy.extent;
    desc.cell_size = legacy.cell_size;
    desc.absorption_color = legacy.absorption_color;
    desc.absorption_distance = legacy.absorption_distance;
    desc.scatter_color = legacy.scatter_color;
    desc.roughness = legacy.roughness;
    desc.refraction_strength = legacy.refraction_strength;
    desc.reflection_distortion = legacy.reflection_distortion;
    desc.foam_depth = legacy.foam_depth;
    desc.foam_crest = legacy.foam_crest;
    desc.ripple_drift = legacy.ripple_drift;
    desc.ripples = legacy.ripples;
    desc.foam = legacy.foam;
    desc.march_reflections = legacy.march_reflections;
    return desc;
}

fn FoliageAuthoring foliage_value(FoliageDesc desc) @private {
    return {
        .geometry = desc.geometry,
        .material = desc.material,
        .lod = desc.lod ? desc.lod[:1] : (LodDesc[]){},
        .ground = desc.ground,
        .cell_size = desc.cell_size,
        .rules = desc.rules,
        .sway = desc.sway,
        .fade = desc.fade,
        .cast_shadow = desc.cast_shadow,
        .receive_shadow = desc.receive_shadow,
        .trace = desc.trace,
        .trace_sway = desc.trace_sway,
    };
}

fn FoliageDesc foliage_desc(FoliageAuthoring* value) @private {
    return {
        .geometry = value.geometry,
        .material = value.material,
        .lod = value.lod.len ? &value.lod[0] : null,
        .ground = value.ground,
        .cell_size = value.cell_size,
        .rules = value.rules,
        .sway = value.sway,
        .fade = value.fade,
        .cast_shadow = value.cast_shadow,
        .receive_shadow = value.receive_shadow,
        .trace = value.trace,
        .trace_sway = value.trace_sway,
    };
}

fn ScatterRulesV1 scatter_rules_v1(ScatterRules rules) @private {
    return {
        .density_map     = rules.density_map,
        .density_channel = rules.density_channel,
        .spacing         = rules.spacing,
        .seed            = rules.seed,
        .max_slope       = rules.max_slope,
        .min_altitude    = rules.min_altitude,
        .max_altitude    = rules.max_altitude,
        .min_scale       = rules.min_scale,
        .max_scale       = rules.max_scale,
        .min_tint        = rules.min_tint,
        .max_tint        = rules.max_tint,
    };
}

fn ScatterRules scatter_rules_from_v1(ScatterRulesV1 legacy) @private {
    return {
        .density_map     = legacy.density_map,
        .density_channel = legacy.density_channel,
        .spacing         = legacy.spacing,
        .seed            = legacy.seed,
        .max_slope       = legacy.max_slope,
        .min_altitude    = legacy.min_altitude,
        .max_altitude    = legacy.max_altitude,
        .min_scale       = legacy.min_scale,
        .max_scale       = legacy.max_scale,
        .min_tint        = legacy.min_tint,
        .max_tint        = legacy.max_tint,
    };
}

fn FoliageAuthoringV1 foliage_authoring_v1(FoliageAuthoring value) @private {
    return {
        .geometry       = value.geometry,
        .material       = value.material,
        .lod            = value.lod,
        .ground         = value.ground,
        .cell_size      = value.cell_size,
        .rules          = scatter_rules_v1(value.rules),
        .sway           = value.sway,
        .fade           = value.fade,
        .cast_shadow    = value.cast_shadow,
        .receive_shadow = value.receive_shadow,
        .trace          = value.trace,
    };
}

fn FoliageAuthoringV2 foliage_authoring_v2(FoliageAuthoring value) @private {
    return {
        .geometry       = value.geometry,
        .material       = value.material,
        .lod            = value.lod,
        .ground         = value.ground,
        .cell_size      = value.cell_size,
        .rules          = value.rules,
        .sway           = value.sway,
        .fade           = value.fade,
        .cast_shadow    = value.cast_shadow,
        .receive_shadow = value.receive_shadow,
        .trace          = value.trace,
    };
}

fn FoliageAuthoring foliage_authoring_from_v2(FoliageAuthoringV2 legacy) @private {
    return {
        .geometry       = legacy.geometry,
        .material       = legacy.material,
        .lod            = legacy.lod,
        .ground         = legacy.ground,
        .cell_size      = legacy.cell_size,
        .rules          = legacy.rules,
        .sway           = legacy.sway,
        .fade           = legacy.fade,
        .cast_shadow    = legacy.cast_shadow,
        .receive_shadow = legacy.receive_shadow,
        .trace          = legacy.trace,
    };
}

fn FoliageAuthoring foliage_authoring_from_v1(FoliageAuthoringV1 legacy) @private {
    return {
        .geometry       = legacy.geometry,
        .material       = legacy.material,
        .lod            = legacy.lod,
        .ground         = legacy.ground,
        .cell_size      = legacy.cell_size,
        .rules          = scatter_rules_from_v1(legacy.rules),
        .sway           = legacy.sway,
        .fade           = legacy.fade,
        .cast_shadow    = legacy.cast_shadow,
        .receive_shadow = legacy.receive_shadow,
        .trace          = legacy.trace,
    };
}

fn void? project_terrain(void* component, void* value, serial::WriteContext* context) @private {
    *(TerrainDesc*)value = ((Terrain*)component).desc;
    terrain::check_terrain_desc(context.assets, (TerrainDesc*)value)!;
}

fn bool terrain_set_valid(TerrainSetAuthoring* authoring) @private {
    return authoring.texels > 1 && authoring.cell_size > 0 && authoring.height_scale > 0;
}

fn void? project_terrain_set(void* component, void* value, serial::WriteContext* context) @private {
    TerrainSet* set = component;
    TerrainSetAuthoring* authoring = value;
    *authoring = {
        .texels       = set.texels,
        .cell_size    = set.cell_size,
        .height_scale = set.height_scale,
    };
    if (!terrain_set_valid(authoring)) return c3d::INVALID_ARGUMENT~;
}

fn void? project_foliage(void* component, void* value, serial::WriteContext* context) @private {
    FoliageDesc desc = ((Foliage*)component).desc;
    foliage::check_authoring(context.scene, context.assets, &desc)!;
    *(FoliageAuthoring*)value = foliage_value(desc);
}

fn void? project_water(void* component, void* value, serial::WriteContext* context) @private {
    *(WaterDesc*)value = ((Water*)component).desc;
    water::check_authoring(context.scene, context.assets, (WaterDesc*)value)!;
}

fn void? validate_terrain(void* value, serial::ReadContext* context) @private {
    if (context.has_component(InstancedMesh)) return c3d::INVALID_ARGUMENT~;
    terrain::check_terrain_desc(context.assets, (TerrainDesc*)value)!;
}

fn void? validate_terrain_set(void* value, serial::ReadContext* context) @private {
    if (!terrain_set_valid((TerrainSetAuthoring*)value)) return c3d::INVALID_ARGUMENT~;
}

fn void? validate_foliage(void* value, serial::ReadContext* context) @private {
    FoliageAuthoring* authoring = value;
    if (authoring.lod.len > 1) return c3d::INVALID_ARGUMENT~;
    FoliageDesc desc = foliage_desc(authoring);
    foliage::check_desc(&desc)!;
    if (!context.scene.world.is_alive(desc.ground)) return c3d::INVALID_ID~;
    bool terrain_present;
    uint terrain_slot = ecs::slot_of(Terrain)!;
    foreach (index, node : context.nodes) {
        if (c3d::same_id(node.id, desc.ground)) {
            terrain_present = (context.component_masks[index] & ecs::slot_bit(terrain_slot)) != 0;
        }
    }
    if (!terrain_present) return c3d::INVALID_ID~;
    if (desc.lod) {
        scene::validate_lod_desc(context.assets, *desc.lod, LodMode.INSTANCED)!;
    } else if (!context.assets.geometries.is_live(desc.geometry) || !context.assets.materials.is_live(desc.material)) {
        return c3d::INVALID_ID~;
    }
    TextureAsset* density = context.assets.textures.try_get(desc.rules.density_map)!;
    foliage::check_density_map(density)!;
}

fn void? validate_water(void* value, serial::ReadContext* context) @private {
    if (context.has_component(Mesh) || context.has_component(InstancedMesh)) return c3d::INVALID_ARGUMENT~;
    WaterDesc* desc = value;
    water::check_desc(context.assets, desc)!;
    if (!desc.ground.generation) return;
    if (!context.scene.world.is_alive(desc.ground)) return c3d::INVALID_ID~;
    bool terrain_present;
    uint terrain_slot = ecs::slot_of(Terrain)!;
    foreach (index, node : context.nodes) {
        if (c3d::same_id(node.id, desc.ground)) {
            terrain_present = (context.component_masks[index] & ecs::slot_bit(terrain_slot)) != 0;
        }
    }
    if (!terrain_present) return c3d::INVALID_ARGUMENT~;
}

fn void? attach_terrain(void* value, serial::ReadContext* context) @private {
    terrain::attach_terrain(
        scene: context.scene,
        assets: context.assets,
        node: context.node,
        desc: *(TerrainDesc*)value,
    )!;
}

fn void? read_terrain_v1(serial::Reader* reader, serial::ReadContext* context) @private {
    TerrainDescV1* legacy = context.read_value(TerrainDescV1, reader)!;
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = legacy.height_map;
    desc.control_map = legacy.control_map;
    desc.cell_size = legacy.cell_size;
    desc.height_scale = legacy.height_scale;
    desc.layers = legacy.layers;
    desc.lod_threshold = legacy.lod_threshold;
    desc.lod_hysteresis = legacy.lod_hysteresis;
    desc.cast_shadow = legacy.cast_shadow;
    desc.receive_shadow = legacy.receive_shadow;

    validate_terrain(&desc, context)!;
    attach_terrain(&desc, context)!;
}

fn void? read_terrain_v2(serial::Reader* reader, serial::ReadContext* context) @private {
    TerrainDescV2* legacy = context.read_value(TerrainDescV2, reader)!;
    TerrainDesc desc = terrain_desc_from_v2(*legacy);

    validate_terrain(&desc, context)!;
    attach_terrain(&desc, context)!;
}

fn void? read_terrain_v3(serial::Reader* reader, serial::ReadContext* context) @private {
    TerrainDescV3* legacy = context.read_value(TerrainDescV3, reader)!;
    TerrainDesc desc = terrain_desc_from_v3(*legacy);

    validate_terrain(&desc, context)!;
    attach_terrain(&desc, context)!;
}

fn void? attach_terrain_set(void* value, serial::ReadContext* context) @private {
    TerrainSetAuthoring* authoring = value;
    context.scene.add(context.node, (TerrainSet){
        .texels       = authoring.texels,
        .cell_size    = authoring.cell_size,
        .height_scale = authoring.height_scale,
    });
}

fn void? attach_foliage(void* value, serial::ReadContext* context) @private {
    foliage::attach_foliage(
        scene: context.scene,
        assets: context.assets,
        node: context.node,
        desc: foliage_desc((FoliageAuthoring*)value),
    )!;
}

fn void? read_foliage_v1(serial::Reader* reader, serial::ReadContext* context) @private {
    FoliageAuthoringV1* legacy = context.read_value(FoliageAuthoringV1, reader)!;
    FoliageAuthoring source = foliage_authoring_from_v1(*legacy);
    validate_foliage(&source, context)!;
    attach_foliage(&source, context)!;
}

fn void? read_foliage_v2(serial::Reader* reader, serial::ReadContext* context) @private {
    FoliageAuthoringV2* legacy = context.read_value(FoliageAuthoringV2, reader)!;
    FoliageAuthoring source = foliage_authoring_from_v2(*legacy);
    validate_foliage(&source, context)!;
    attach_foliage(&source, context)!;
}

fn void? read_water_v1(serial::Reader* reader, serial::ReadContext* context) @private {
    WaterDescV1* legacy = context.read_value(WaterDescV1, reader)!;
    WaterDesc desc = water_desc_from_v1(*legacy);
    validate_water(&desc, context)!;
    attach_water(&desc, context)!;
}

fn void? read_water_v2(serial::Reader* reader, serial::ReadContext* context) @private {
    WaterDescV2* legacy = context.read_value(WaterDescV2, reader)!;
    WaterDesc desc = water_desc_from_v2(*legacy);
    validate_water(&desc, context)!;
    attach_water(&desc, context)!;
}

fn void? read_water_v3(serial::Reader* reader, serial::ReadContext* context) @private {
    WaterDescV3* legacy = context.read_value(WaterDescV3, reader)!;
    WaterDesc desc = water_desc_from_v3(*legacy);
    validate_water(&desc, context)!;
    attach_water(&desc, context)!;
}

fn void? read_water_v4(serial::Reader* reader, serial::ReadContext* context) @private {
    WaterDescV4* legacy = context.read_value(WaterDescV4, reader)!;
    WaterDesc desc = water_desc_from_v4(*legacy);
    validate_water(&desc, context)!;
    attach_water(&desc, context)!;
}

fn void? attach_water(void* value, serial::ReadContext* context) @private {
    water::attach_water(
        scene: context.scene,
        assets: context.assets,
        node: context.node,
        desc: *(WaterDesc*)value,
    )!;
}

fn void? collect_terrain(void* component, serial::WriteContext* context) @private {
    TerrainRuntime* runtime = context.scene.get(context.node, TerrainRuntime);
    if (!runtime) return;
    InstancedMesh* batch = context.scene.get(context.node, InstancedMesh);
    if (!batch || !c3d::same_id(batch.material, runtime.material)) return c3d::INVALID_ARGUMENT~;
    GeometryId grid = context.assets.find_geometry("c3d_landscape/terrain_grid") ?? c3d::INVALID_ARGUMENT~!;
    if (!c3d::same_id(batch.geometry, grid)) return c3d::INVALID_ARGUMENT~;
    context.omit_component(context.node, ecs::slot_of(InstancedMesh)!)!;

    if (!runtime.trace_grid.generation) return;

    if (!context.scene.world.is_alive(runtime.trace_grid)) return c3d::INVALID_ARGUMENT~;
    Node* trace_grid = context.scene.node(runtime.trace_grid);
    Mesh* mesh = context.scene.get(trace_grid, Mesh);
    if (!mesh || trace_grid.parent != context.node || !mesh.trace_only
        || !c3d::same_id(mesh.material, runtime.material)) return c3d::INVALID_ARGUMENT~;

    context.omit_component(trace_grid, ecs::slot_of(Mesh)!)!;
    context.omit_node(trace_grid)!;
}

fn void? collect_terrain_runtime(void* component, serial::WriteContext* context) @private {
    if (!context.scene.has(context.node, Terrain)) return c3d::INVALID_ARGUMENT~;
}

fn void? collect_foliage(void* component, serial::WriteContext* context) @private {
    FoliageRuntime* runtime = context.scene.get(context.node, FoliageRuntime);
    if (!runtime) return;
    foreach (uint cell_index, entity : runtime.cells) {
        if (!entity.generation) continue;
        if (!context.scene.world.is_alive(entity)) return c3d::INVALID_ARGUMENT~;
        Node* cell = context.scene.node(entity);
        foliage::FoliageCellOwner* owner = context.scene.get(cell, foliage::FoliageCellOwner);
        if (!owner || !c3d::same_id(owner.layer, context.node.id) || owner.cell_index != cell_index
            || cell.parent != context.node) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (runtime.desc.lod) {
            if (!context.scene.has(cell, LodGroup)) return c3d::INVALID_ARGUMENT~;
            context.omit_component(cell, ecs::slot_of(LodGroup)!)!;
        } else {
            if (!context.scene.has(cell, InstancedMesh)) return c3d::INVALID_ARGUMENT~;
            context.omit_component(cell, ecs::slot_of(InstancedMesh)!)!;
        }
        context.omit_node(cell)!;
    }
}

fn void? collect_foliage_runtime(void* component, serial::WriteContext* context) @private {
    if (!context.scene.has(context.node, Foliage)) return c3d::INVALID_ARGUMENT~;
}

fn void? collect_foliage_cell(void* component, serial::WriteContext* context) @private {
    foliage::FoliageCellOwner* owner = component;
    if (!context.scene.world.is_alive(owner.layer)) return c3d::INVALID_ARGUMENT~;
    Node* layer = context.scene.node(owner.layer);
    if (!context.contains_node(layer) || context.node.parent != layer || !context.scene.has(layer, Foliage)) {
        return c3d::INVALID_ARGUMENT~;
    }
    FoliageRuntime* runtime = context.scene.get(layer, FoliageRuntime);
    if (!runtime || owner.cell_index >= runtime.cells.len
        || !c3d::same_id(runtime.cells[owner.cell_index], context.node.id)) return c3d::INVALID_ARGUMENT~;
}

fn void? collect_water(void* component, serial::WriteContext* context) @private {
    WaterRuntime* runtime = context.scene.get(context.node, WaterRuntime);
    if (!runtime) return;
    if (runtime.desc.mode == WaterMode.OCEAN) {
        InstancedMesh* batch = context.scene.get(context.node, InstancedMesh);
        if (!batch || !c3d::same_id(batch.material, runtime.material) || !c3d::same_id(batch.geometry, runtime.grid)) {
            return c3d::INVALID_ARGUMENT~;
        }
        context.omit_component(context.node, ecs::slot_of(InstancedMesh)!)!;
    } else {
        Mesh* mesh = context.scene.get(context.node, Mesh);
        if (!mesh || !c3d::same_id(mesh.material, runtime.material) || !c3d::same_id(mesh.geometry, runtime.grid)) {
            return c3d::INVALID_ARGUMENT~;
        }
        context.omit_component(context.node, ecs::slot_of(Mesh)!)!;
    }
    if (!context.scene.world.is_alive(runtime.medium_node)) return c3d::INVALID_ARGUMENT~;
    Node* medium_node = context.scene.node(runtime.medium_node);
    if (medium_node.parent != context.node) return c3d::INVALID_ARGUMENT~;
    if (context.contains_node(medium_node)) {
        if (context.scene.has(medium_node, MediumVolume)) {
            context.omit_component(medium_node, ecs::slot_of(MediumVolume)!)!;
        }
        context.omit_node(medium_node)!;
    }
    foreach (slot, mirror_id : runtime.mirrors) {
        if (!mirror_id.generation) continue;
        if (!context.scene.world.is_alive(mirror_id)) return c3d::INVALID_ARGUMENT~;
        Node* mirror = context.scene.node(mirror_id);
        WaterMirror* owner = context.scene.get(mirror, WaterMirror);
        if (!owner || !c3d::same_id(owner.water, context.node.id) || owner.slot != slot
            || mirror.parent != context.scene.root || !context.scene.has(mirror, Camera)) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (context.contains_node(mirror)) {
            context.omit_component(mirror, ecs::slot_of(Camera)!)!;
            context.omit_node(mirror)!;
        }
    }
}

fn void? collect_water_runtime(void* component, serial::WriteContext* context) @private {
    if (!context.scene.has(context.node, Water)) return c3d::INVALID_ARGUMENT~;
}

fn void? collect_water_mirror(void* component, serial::WriteContext* context) @private {
    WaterMirror* owner = component;
    if (!context.scene.world.is_alive(owner.water)) return c3d::INVALID_ARGUMENT~;
    Node* water_node = context.scene.node(owner.water);
    if (!context.contains_node(water_node) || !context.scene.has(water_node, Water)) return c3d::INVALID_ARGUMENT~;
    WaterRuntime* runtime = context.scene.get(water_node, WaterRuntime);
    if (!runtime || owner.slot >= water::MAX_MIRRORS || !c3d::same_id(runtime.mirrors[owner.slot], context.node.id)) {
        return c3d::INVALID_ARGUMENT~;
    }
}
