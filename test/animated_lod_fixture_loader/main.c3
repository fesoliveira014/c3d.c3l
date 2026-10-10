module c3d::test::animated_lod_fixture_loader;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::test::animated_lod_fixtures;
import std::io;

fn void? run(String repository) @private {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    AnimatedLodFixtures fixtures = animated_lod_fixtures::load_animated_lod_fixtures(&assets, repository)!;
    ModelTemplate* model = &assets.model(fixtures.model).data;
    io::printfn("Source nodes=%s clips=%s", model.nodes.len, model.clips.len);
    for (uint primitive = 0; primitive < animated_lod_fixtures::LOD_PRIMITIVES; primitive++) {
        for (uint level = 0; level < animated_lod_fixtures::LOD_LEVELS; level++) {
            Geometry* geometry = &assets.geometry(fixtures.levels[primitive][level]).data;
            io::printfn("primitive=%s level=%s", primitive, level);
            io::printfn("vertices=%s triangles=%s", geometry.positions.len, geometry.indices.len / 3);
            io::printfn("index_stride=%s joints_u16=%s",
                fixtures.layouts[primitive][level].index_stride, fixtures.layouts[primitive][level].flags.joints_u16);
        }
    }
    io::printn("Source identity, four fixture hashes, binds, selected corners and raw streams verified.");
}

<* Load the immutable reduced fixtures without creating a renderer or device. *>
fn int main(String[] arguments) {
    if (arguments.len > 2) {
        io::eprintn("Usage: animated_lod_fixture_loader [REPOSITORY_ROOT]");
        return 2;
    }
    @pool() {
        if (catch excuse = run(arguments.len == 2 ? arguments[1] : ".")) {
            io::eprintfn("Fixture loading failed: %s", excuse);
            return 1;
        }
    };
    return 0;
}
