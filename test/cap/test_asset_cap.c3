module c3d::test::asset_cap;

import c3d;
import c3d::asset;

struct Filler <INDEX> @local {
    int value;
}

fn void test_kind_cap_faults() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    uint faults;
    $for var $index = 0; $index < asset::MAX_CUSTOM_ASSET_TYPES + 1; $index++:
        if (catch excuse = assets.register(Filler{$index}, 1)) {
            assert(excuse == c3d::CAPACITY_EXCEEDED);
            faults++;
        }
    $endfor

    assert(faults >= 1);
    assert(!assets.is_registered(Filler{asset::MAX_CUSTOM_ASSET_TYPES}));
}
