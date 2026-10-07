module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::landscape @public;
import c3d::material;
import c3d::maths;
import std::math;

const uint REFLECTION_SLOT @private = 0; // mirrored as WATER_REFLECTION_SLOT in landscape/water_reflection.glsl
const uint RIPPLE_REFERENCE @private = 0; // mirrored as WATER_RIPPLES in water.frag.glsl
const uint FOAM_REFERENCE @private = 1; // mirrored as WATER_FOAM in water.frag.glsl
const uint QUAD_INDICES @private = 6;
const float DIRECTION_TOLERANCE @private = 0.001f; // unit directions written by hand or read from files
const float NYQUIST_CELLS @private = 2; // grid cells per wavelength below which a wave aliases
const String SHADER_KEY @private = "c3d_landscape/water_shader";
const String GRID_KEY_PREFIX @private = "c3d_landscape/water_grid";

// Descs come from files as well as code, so every value check is a fault; negated so NaN faults too.
fn void? check_desc(AssetStore* assets, WaterDesc* desc) @private {
    if (desc.wave_count > MAX_WAVES) return c3d::INVALID_ARGUMENT~;
    float steepness_sum;
    float shortest = float::max;
    foreach (&wave : desc.waves[:desc.wave_count]) {
        if (!(wave.amplitude >= 0) || !math::is_finite(wave.amplitude)) return c3d::INVALID_ARGUMENT~;
        if (!(wave.wavelength > 0) || !math::is_finite(wave.wavelength)) return c3d::INVALID_ARGUMENT~;
        if (!math::is_finite(wave.speed)) return c3d::INVALID_ARGUMENT~;
        if (!(math::abs(wave.direction.length() - 1) <= DIRECTION_TOLERANCE)) return c3d::INVALID_ARGUMENT~;
        if (!(wave.steepness >= 0) || !math::is_finite(wave.steepness)) return c3d::INVALID_ARGUMENT~;
        steepness_sum += wave.steepness;
        shortest = min(shortest, wave.wavelength);
    }
    // The inversion converges while the horizontal map contracts: its Jacobian is at most the mean steepness.
    if (desc.wave_count && !(steepness_sum < (float)desc.wave_count)) return c3d::INVALID_ARGUMENT~;
    if (desc.geometry.generation) {
        if (!assets.geometries.is_live(desc.geometry)) return c3d::INVALID_ID~;
        Aabb bounds = assets.geometries.get(desc.geometry).data.bounds;
        if (bounds.min.y != 0 || bounds.max.y != 0) return c3d::INVALID_ARGUMENT~;
    } else {
        if (!(desc.extent > 0) || !math::is_finite(desc.extent)) return c3d::INVALID_ARGUMENT~;
        if (!(desc.cell_size > 0) || !math::is_finite(desc.cell_size)) return c3d::INVALID_ARGUMENT~;
        if (!(desc.extent / desc.cell_size <= MAX_GRID_CELLS)) return c3d::INVALID_ARGUMENT~;
        if (desc.wave_count && !(shortest >= NYQUIST_CELLS * desc.cell_size)) return c3d::INVALID_ARGUMENT~;
    }
    Vec3 absorption = desc.absorption_color;
    if (!(absorption.x > 0 && absorption.y > 0 && absorption.z > 0)) return c3d::INVALID_ARGUMENT~;
    if (!(absorption.x <= 1 && absorption.y <= 1 && absorption.z <= 1)) return c3d::INVALID_ARGUMENT~;
    if (!(desc.absorption_distance > 0) || !math::is_finite(desc.absorption_distance)) return c3d::INVALID_ARGUMENT~;
    Vec3 scatter = desc.scatter_color;
    if (!(scatter.x >= 0 && scatter.y >= 0 && scatter.z >= 0)) return c3d::INVALID_ARGUMENT~;
    if (!math::is_finite(scatter.x) || !math::is_finite(scatter.y) || !math::is_finite(scatter.z)) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (!(desc.roughness >= 0 && desc.roughness <= 1)) return c3d::INVALID_ARGUMENT~;
    if (!(desc.foam_crest >= 0 && desc.foam_crest < 1)) return c3d::INVALID_ARGUMENT~;
    float[4] unbounded = { desc.refraction_strength, desc.reflection_distortion, desc.foam_depth, desc.ripple_drift };
    foreach (value : unbounded) {
        if (!(value >= 0) || !math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    }
    check_reference(assets, desc.ripples)!;
    return check_reference(assets, desc.foam);
}

fn void? check_reference(AssetStore* assets, MaterialId reference) @private {
    if (!reference.generation) return;
    if (!assets.materials.is_live(reference)) return c3d::INVALID_ID~;
    if (assets.materials.get(reference).data.kind != MaterialKind.STANDARD) return c3d::INVALID_ARGUMENT~;
}

fn bool same_shape(WaterDesc* first, WaterDesc* second) @private {
    if (!c3d::same_id(first.geometry, second.geometry)) return false;
    return first.geometry.generation || (first.extent == second.extent && first.cell_size == second.cell_size);
}

// One shader per store: every water body shares its pipelines.
fn ShaderId? water_shader(AssetStore* assets, bool* created = null) @private {
    if (created) *created = false;
    if (try found = assets.find_shader(SHADER_KEY)) return found;
    ShaderDesc desc = {
        .fragment         = landscape::WATER_FRAGMENT_SPIRV[..],
        .traced_fragment  = {
            .hardware = landscape::WATER_FRAGMENT_RT_SHADOWS_SPIRV[..],
            .software = landscape::WATER_FRAGMENT_RT_SHADOWS_SCENE_TRACE_BVH_SPIRV[..],
        },
        .vertex           = {
            .shaded   = landscape::WATER_VERTEX_SPIRV[..],
            .depth    = landscape::WATER_VERTEX_DEPTH_ONLY_SPIRV[..],
            .velocity = landscape::WATER_VERTEX_VELOCITY_SPIRV[..],
        },
        .param_block_size = WaterParams::size,
        .scene_reads      = { .color, .depth },
    };
    ShaderId shader = assets.add_shader(&desc, SHADER_KEY)!;
    if (created) *created = true;
    return shader;
}

// One grid per shape and store; the key holds the exact extent and cell size.
fn GeometryId? water_grid(
    AssetStore* assets,
    float extent,
    float cell_size,
    bool* created = null,
) @private {
    if (created) *created = false;
    GeometryId grid;
    @pool() {
        String key = string::tformat("%s/%a/%a", GRID_KEY_PREFIX, extent, cell_size);
        if (try found = assets.find_geometry(key)) return found;
        Geometry geometry = grid_geometry(tmem, extent, (uint)math::ceil(extent / cell_size));
        grid = assets.add_geometry(&geometry, key)!;
    };
    if (created) *created = true;
    return grid;
}

fn Geometry grid_geometry(Allocator allocator, float extent, uint cells) @private {
    uint row = cells + 1;
    Geometry grid = {
        .topology  = TRIANGLES,
        .positions = alloc::new_array(allocator, Vec3, (sz)row * row),
        .indices   = alloc::new_array(allocator, uint, (sz)QUAD_INDICES * cells * cells),
    };
    for (uint z = 0; z < row; z++) {
        for (uint x = 0; x < row; x++) {
            grid.positions[z * row + x] = { ((float)x / cells - 0.5f) * extent, 0, ((float)z / cells - 0.5f) * extent };
        }
    }
    usz slot;
    for (uint z = 0; z < cells; z++) {
        for (uint x = 0; x < cells; x++) {
            uint corner = z * row + x;
            // Counter-clockwise from above, as the terrain grid: the surface faces +Y.
            uint[QUAD_INDICES] quad = { corner, corner + row, corner + 1, corner + 1, corner + row, corner + row + 1 };
            grid.indices[slot : QUAD_INDICES] = quad[..];
            slot += QUAD_INDICES;
        }
    }
    grid.finalize();
    return grid;
}

fn Aabb rest_bounds(AssetStore* assets, WaterDesc* desc) @private {
    if (desc.geometry.generation) return assets.geometries.get(desc.geometry).data.bounds;
    float half = desc.extent / 2;
    return { .min = { -half, 0, -half }, .max = { half, 0, half } };
}

// Displacement leaves the rest bounds by the total amplitude in y and the largest crest shift in x and z.
fn Aabb drawn_bounds(Aabb rest, WaterDesc* desc) @private {
    Vec3 growth = { largest_shift(desc), total_amplitude(desc), largest_shift(desc) };
    return { .min = rest.min - growth, .max = rest.max + growth };
}
