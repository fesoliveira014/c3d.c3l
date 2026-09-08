module assets_example;

import std::io;
import std::math;
import c3d;
import c3d::asset;
import c3d::geometry;

fn Geometry make_quad(Allocator allocator) @local {
    Vec3[] positions = alloc::new_array(allocator, Vec3, 4);
    positions[0] = { 0, 0, 0 };
    positions[1] = { 1, 0, 0 };
    positions[2] = { 1, 1, 0 };
    positions[3] = { 0, 1, 0 };
    Vec2[] uv0 = alloc::new_array(allocator, Vec2, 4);
    uv0[0] = { 0, 0 };
    uv0[1] = { 1, 0 };
    uv0[2] = { 1, 1 };
    uv0[3] = { 0, 1 };
    uint[] indices = alloc::new_array(allocator, uint, 6);
    indices[..] = (uint[6]){ 0, 1, 2, 0, 2, 3 }[..];
    return {
        .positions = positions,
        .uv0       = uv0,
        .indices   = indices,
        .bounds    = { .min = { 0, 0, 0 }, .max = { 1, 1, 0 } },
    };
}

fn int main() {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    GeometryId quad;
    @pool() {
        Geometry temporary = make_quad(tmem);
        quad = assets.add_geometry(&temporary, "example/quad")!!;
    };
    GeometryAsset* record = assets.geometry(quad);
    io::printfn("added example/quad: %d vertices, %d indices, revision %d",
        record.vertex_count, record.index_count, record.header.revision);

    record.data.positions[0].y = 2;
    assets.mark_geometry_dirty(quad);
    io::printfn("edited vertex 0 to %s, revision %d", record.data.positions[0], record.header.revision);

    AssetRef found = assets.find("example/quad")!!;
    GeometryId by_key = assets.find_geometry("example/quad")!!;
    io::printfn("find: kind %s index %d; find_geometry matches: %s",
        found.kind, found.id.index, by_key.index == quad.index && by_key.generation == quad.generation);

    assets.release_geometry_cpu(quad);
    io::printfn("released: positions.len %d, vertex_count %d, bounds max %s, revision %d",
        record.data.positions.len, record.vertex_count, record.data.bounds.max, record.header.revision);

    assets.remove_geometry(quad);
    io::printfn("removed: is_live %s", assets.geometries.is_live(quad));
    if (catch excuse = assets.find("example/quad")) {
        io::printfn("find after removal: %s", excuse);
    }

    TextureAsset* checker = assets.texture(asset::TEXTURE_CHECKER);
    io::printfn("builtin checker: %dx%d %s, %d bytes, key %s",
        checker.desc.width, checker.desc.height, checker.desc.format, checker.pixels.len, checker.header.key);
    return 0;
}
