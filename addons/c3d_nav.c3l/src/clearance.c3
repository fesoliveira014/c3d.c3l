module c3d::nav;

import std::math;
import c3d;

<* Select whole-source-cell erosion or bounded additional horizontal erosion. *>
enum ClearanceMode : uint {
    WHOLE_CELL,
    SUB_CELL,
}

struct ClearanceSettings @private {
    uint subdivision;
    double pitch;
    double storage_limit;
    double interval_limit;
    double capture_radius;
}

fn bool valid_clearance_metadata(
    ClearanceMode mode,
    float source_pitch,
    float stored_pitch,
    uint subdivision,
    float maximum_error,
) @private {
    if ((uint)mode > (uint)ClearanceMode.SUB_CELL) return false;
    if (!math::is_finite(source_pitch) || source_pitch <= 0) return false;
    if (subdivision == 0 || subdivision >= MESH_NULL_INDEX) return false;
    if (stored_pitch != (float)((double)source_pitch / subdivision)) return false;

    if (mode == ClearanceMode.WHOLE_CELL) return subdivision == 1;

    return math::is_finite(maximum_error) && maximum_error > 0
        && (double)subdivision * maximum_error >= 2.0 * source_pitch;
}

fn ClearanceSettings? clearance_settings(NavBuildConfig config) @private {
    double subdivision = math::max(1.0, math::ceil(2.0 * config.cell_size / config.clearance_max_error));
    if (!math::is_finite(subdivision) || subdivision >= MESH_NULL_INDEX) return c3d::CAPACITY_EXCEEDED~;

    uint count = (uint)subdivision;
    if ((double)count * config.clearance_max_error < 2.0 * config.cell_size) count++;
    if (count >= MESH_NULL_INDEX) return c3d::CAPACITY_EXCEEDED~;

    return {
        .subdivision = count,
        .pitch = (double)config.cell_size / count,
        .storage_limit = (double)config.clearance_max_error / 16,
        .interval_limit = (double)config.clearance_max_error / 32,
        .capture_radius = (double)config.agent_radius + (double)config.clearance_max_error / 8,
    };
}
