module c3d::nav;

import std::math;
import c3d;

const uint BORDER_PADDING @local = 3; // voxels past the erosion radius; mirrors RecastDemo's walkableRadius + 3
const uint MIN_WALKABLE_HEIGHT @local = 3; // the compact heightfield's lower bound

<* Build parameters in world units; one per NavBuilder. *>
struct NavBuildConfig {
    float cell_size;                // metres; XZ voxel size
    float cell_height;              // metres; Y voxel size
    uint  tile_size;                // voxels per tile side, without the border
    float agent_height;             // metres
    float agent_radius;
    float agent_max_climb;
    float agent_max_slope_degrees;
    float region_min_size;          // voxels; squared into min_region_area
    float region_merge_size;        // voxels; squared into merge_region_area
    float edge_max_length;          // metres
    float edge_max_error;           // voxels
    uint  verts_per_poly;
}

<* Voxel parameters derived once from a NavBuildConfig; what build_tile reads. *>
struct TileConfig {
    uint  width;                    // tile_size + 2 * border_size
    uint  height;
    uint  border_size;              // walkable_radius + 3
    uint  walkable_height;          // ceil(agent_height / cell_height)
    uint  walkable_climb;           // floor(agent_max_climb / cell_height)
    uint  walkable_radius;          // ceil(agent_radius / cell_size)
    uint  max_edge_length;          // edge_max_length / cell_size
    uint  min_region_area;
    uint  merge_region_area;
    float cell_size;
    float cell_height;
    float slope_degrees;
    float max_simplification_error;
    uint  verts_per_poly;
}

<*
 RecastDemo defaults: 0.3 by 0.2 m cells, a 2 m agent of radius 0.6 climbing 0.9 at 45 degrees, 32-voxel tiles.
*>
fn NavBuildConfig default_nav_build_config() {
    return {
        .cell_size               = 0.3f,
        .cell_height             = 0.2f,
        .tile_size               = 32,
        .agent_height            = 2.0f,
        .agent_radius            = 0.6f,
        .agent_max_climb         = 0.9f,
        .agent_max_slope_degrees = 45,
        .region_min_size         = 8,
        .region_merge_size       = 20,
        .edge_max_length         = 12,
        .edge_max_error          = 1.3f,
        .verts_per_poly          = MAX_VERTS_PER_POLY,
    };
}

<*
 Voxel parameters of the config.
 @return? c3d::INVALID_ARGUMENT
*>
fn TileConfig? tile_config(NavBuildConfig config) {
    if (config.cell_size <= 0 || config.cell_height <= 0 || config.tile_size == 0) return c3d::INVALID_ARGUMENT~;
    if (config.agent_max_slope_degrees < 0 || config.agent_max_slope_degrees >= 90) return c3d::INVALID_ARGUMENT~;
    if (config.verts_per_poly < 3 || config.verts_per_poly > MAX_VERTS_PER_POLY) return c3d::INVALID_ARGUMENT~;

    int walkable_height = (int)math::ceil(config.agent_height / config.cell_height);
    int walkable_climb = (int)math::floor(config.agent_max_climb / config.cell_height);
    int walkable_radius = (int)math::ceil(config.agent_radius / config.cell_size);
    int max_edge_length = (int)(config.edge_max_length / config.cell_size);
    if (walkable_height < (int)MIN_WALKABLE_HEIGHT || walkable_climb < 0) return c3d::INVALID_ARGUMENT~;
    if (max_edge_length < 0) return c3d::INVALID_ARGUMENT~;
    if (walkable_radius < 0 || walkable_radius > (int)MAX_EROSION_RADIUS) return c3d::INVALID_ARGUMENT~;

    uint border_size = (uint)walkable_radius + BORDER_PADDING;
    return {
        .width                    = config.tile_size + border_size * 2,
        .height                   = config.tile_size + border_size * 2,
        .border_size              = border_size,
        .walkable_height          = (uint)walkable_height,
        .walkable_climb           = (uint)walkable_climb,
        .walkable_radius          = (uint)walkable_radius,
        .max_edge_length          = (uint)max_edge_length,
        .min_region_area          = (uint)(config.region_min_size * config.region_min_size),
        .merge_region_area        = (uint)(config.region_merge_size * config.region_merge_size),
        .cell_size                = config.cell_size,
        .cell_height              = config.cell_height,
        .slope_degrees            = config.agent_max_slope_degrees,
        .max_simplification_error = config.edge_max_error,
        .verts_per_poly           = config.verts_per_poly,
    };
}
