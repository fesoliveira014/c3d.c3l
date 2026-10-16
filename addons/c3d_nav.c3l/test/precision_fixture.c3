module c3d_nav_test;

import std::math;
import c3d;
import c3d::geometry;
import c3d::nav;

const uint PRECISION_FIXTURE_VERSION @private = 1;
const uint PRECISION_FIXTURE_SEGMENTS @private = 24;

enum PrecisionFixtureKind : uint @private {
    FLAT,
    RAMP,
    RIDGE,
    BRIDGE,
}

fn NavBuildConfig precision_fixture_config(DetailMode mode) @private {
    NavBuildConfig config = nav::default_nav_build_config();
    config.cell_size = 0.5f;
    config.cell_height = 0.05f;
    config.tile_size = 8;
    config.agent_height = 1;
    config.agent_radius = 0;
    config.agent_max_climb = 0.3f;
    config.agent_max_slope_degrees = 60;
    config.region_min_size = 0;
    config.region_merge_size = 0;
    config.detail_mode = mode;
    config.detail_max_error = 0.01f;
    return config;
}

fn float precision_source_height(PrecisionFixtureKind kind, float x, float z) @private {
    switch (kind) {
        case FLAT:
        case BRIDGE: return 0;
        case RAMP: return 0.25f * x + 0.125f * z;
        case RIDGE: return 0.5f - 0.25f * math::abs(x - 4);
    }
}

fn void setup_precision_fixture(
    BuilderFixture* fixture,
    PrecisionFixtureKind kind,
    bool cached,
    DetailMode mode,
) @private {
    NavBuildConfig config = precision_fixture_config(mode);
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(2, config), config);
    desc.cache_layers = cached;
    setup_with_desc(fixture, desc);
    GeometryId floor;
    @pool() {
        Geometry geometry = geometry::plane(
            allocator: tmem,
            width: 12,
            depth: 12,
            segments_x: PRECISION_FIXTURE_SEGMENTS,
            segments_z: PRECISION_FIXTURE_SEGMENTS,
        );
        foreach (&position : geometry.positions) {
            position.y = precision_source_height(kind, position.x + 4, position.z + 4);
        }
        geometry.finalize();
        floor = fixture.assets.add_geometry(&geometry)!!;
    };
    add_source_node(fixture, floor, { 4, 0, 4 });
    if (kind == PrecisionFixtureKind.BRIDGE) add_plane(fixture, { 12, 12 }, { 4, 3, 4 });
    fixture.scene.update_world();
}
