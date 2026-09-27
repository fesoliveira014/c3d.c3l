module c3d_nav_test;

import std::math;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::nav;
import c3d::scene;

const uint BUILD_ALL_BUDGET @private = 64; // tiles per nav_sync call when a test builds everything

struct BuilderFixture @private {
    AssetStore assets;
    Scene      scene;
    NavBuilder builder;
}

fn void setup(BuilderFixture* fixture, Aabb bounds, NavBuildConfig config = nav::default_nav_build_config()) @private {
    setup_with_desc(fixture, nav::default_nav_builder_desc(bounds, config));
}

fn void setup_with_desc(BuilderFixture* fixture, NavBuilderDesc desc) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    nav::register_nav(&fixture.scene)!!;
    fixture.builder = nav::create_nav_builder(mem, &fixture.scene, desc)!!;
}

fn void teardown(BuilderFixture* fixture) @private {
    nav::destroy_nav_builder(&fixture.builder);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_plane(
    BuilderFixture* fixture,
    Vec2 size,
    Vec3 position,
    uint segments_x = 1,
    uint segments_z = 1,
) @private {
    GeometryId plane;
    @pool() {
        Geometry geometry = geometry::plane(tmem, size.x, size.y, segments_x, segments_z);
        plane = fixture.assets.add_geometry(&geometry)!!;
    };
    return add_source_node(fixture, plane, position);
}

fn Node* add_box(BuilderFixture* fixture, Vec3 size, Vec3 position) @private {
    GeometryId box;
    @pool() {
        Geometry geometry = geometry::box(tmem, size.x, size.y, size.z);
        box = fixture.assets.add_geometry(&geometry)!!;
    };
    return add_source_node(fixture, box, position);
}

fn Node* add_source_node(BuilderFixture* fixture, GeometryId geometry, Vec3 position) @private {
    Node* node = fixture.scene.add_mesh(geometry, {})!!;
    node.local.position = position;
    fixture.scene.update_world();
    fixture.scene.add_nav_source(node)!!;
    return node;
}

fn NavSyncResult build_everything(BuilderFixture* fixture) @private {
    return nav::nav_sync(
        builder: &fixture.builder,
        scene:   &fixture.scene,
        assets:  &fixture.assets,
        budget:  BUILD_ALL_BUDGET,
    );
}

// Square bounds of whole tiles from the origin, one metre below the floor to five above.
fn Aabb tile_grid_bounds(uint tiles, NavBuildConfig config = nav::default_nav_build_config()) @private {
    float side = (float)tiles * (config.tile_size * config.cell_size);
    return { .min = { 0, -1, 0 }, .max = { side, 5, side } };
}

fn Vec3 world_vertex(TileMeshView view, ushort vertex) @private {
    TileMeshHeader* header = view.header;
    ushort* voxel = &view.verts[vertex * 3];
    Vec3 position = { (float)voxel[0], (float)voxel[1], (float)voxel[2] };
    return header.bounds.min + position * (Vec3){ header.cell_size, header.cell_height, header.cell_size };
}

fn ushort[] view_polygon(TileMeshView view, uint poly) @private {
    uint stride = view.header.verts_per_poly;
    return view.polys[(usz)poly * stride * 2:stride];
}

fn ushort[] view_neighbours(TileMeshView view, uint poly) @private {
    uint stride = view.header.verts_per_poly;
    return view.polys[(usz)poly * stride * 2 + stride:stride];
}
