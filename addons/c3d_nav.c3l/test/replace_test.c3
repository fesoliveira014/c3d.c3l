module c3d_nav_test;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::nav @public;
import c3d::scene;

const uint REPLACE_TRIANGLE_BUDGET @private = 100;
const uint REPLACE_SEGMENTS @private = 20; // 800 triangles; the cursor passes the replacement's two
const uint REPLACE_SYNC_ROUNDS @private = 16;

fn void test_replace_source_geometry_restarts_tile_job() @test {
    BuilderFixture* fixture = mem::new(BuilderFixture);
    defer free(fixture);
    NavBuilderDesc desc = nav::default_nav_builder_desc(tile_grid_bounds(1));
    desc.rasterize_budget = REPLACE_TRIANGLE_BUDGET;
    setup_with_desc(fixture, desc);
    defer teardown(fixture);
    float tile = fixture.builder.tile_world_size;
    Node* floor = add_plane(
        fixture:    fixture,
        size:       { tile, tile },
        position:   { tile * 0.5f, 0, tile * 0.5f },
        segments_x: REPLACE_SEGMENTS,
        segments_z: REPLACE_SEGMENTS,
    );
    fixture.builder.sync_sources(&fixture.scene, &fixture.assets);
    TileJob* job = rasterize(fixture);
    assert(job.state == RASTERIZING && job.triangle_cursor > 2);

    GeometryId geometry = fixture.scene.get(floor, scene::Mesh).geometry;
    @pool() {
        Geometry coarse = geometry::plane(tmem, tile, tile);
        fixture.assets.replace_geometry(geometry, &coarse)!!;
    };

    NavSyncResult result;
    for (uint round = 0; round < REPLACE_SYNC_ROUNDS && (!round || result.pending > 0); round++) {
        result = nav::nav_sync(
            builder: &fixture.builder,
            mesh:    &fixture.mesh,
            scene:   &fixture.scene,
            assets:  &fixture.assets,
            budget:  4,
        );
        assert(result.failed == 0);
    }
    assert(result.pending == 0);
    assert(fixture.scene.get(floor, NavSourceRuntime).geometry_revision == 2);
    assert(fixture.builder.tile_mesh(0, 0).len > 0);
}
