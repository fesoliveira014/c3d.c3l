module upload_example;

import std::io;
import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::render;

fn void print_mirror(String label, render::Renderer* renderer, GeometryId box) @local {
    render::GpuGeometry* mirror = &renderer.geometries[box.index];
    io::printfn("  %s: uploads %d, bytes %d, block %d bytes, allocation %d, revision %d",
        label, renderer.stats.uploads, renderer.stats.upload_bytes,
        mirror.layout.total_bytes, mirror.allocation.index, mirror.revision);
}

fn int main() {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = render::create_renderer(
        allocator: mem,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_upload" },
    )!!;
    defer render::destroy_renderer(&renderer);

    GeometryId box;
    @pool() {
        Geometry generated = geometry::box(tmem, 1, 1, 1);
        box = assets.add_geometry(&generated, "example/box")!!;
    };

    io::printn("first upload");
    renderer.upload(box)!!;
    print_mirror("box", &renderer, box);

    io::printn("edit one position, same layout: reused in place");
    GeometryAsset* record = assets.geometry(box);
    record.data.positions[0].y += 0.25f;
    record.data.finalize();
    assets.mark_geometry_dirty(box);
    renderer.upload(box)!!;
    print_mirror("box", &renderer, box);

    io::printn("add tangents, new layout: replaced");
    record.data.compute_tangents(assets.allocator);
    assets.mark_geometry_dirty(box);
    renderer.upload(box)!!;
    print_mirror("box", &renderer, box);

    io::printn("remove and sweep");
    assets.remove_geometry(box);
    renderer.begin_frame()!!;
    renderer.end_frame()!!;
    io::printfn("  mirror dead %s", renderer.geometries[box.index].asset.generation == 0);
    if (catch excuse = renderer.upload(box)) io::printfn("  upload of a removed id: %s", excuse);
    return 0;
}
