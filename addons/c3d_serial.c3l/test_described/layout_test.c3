module c3d::serial::test_described;

import c3d;
import c3d::describe;
import c3d::serial;

fn void test_described_layout_fingerprint() @test {
    initialize_descriptions();
    assert(serial::description_layout(describe::get(Number)!!)!! == NUMBER_LAYOUT);
    assert(serial::description_layout(describe::get(Item)!!)!! == ITEM_LAYOUT);
    assert(serial::description_layout(describe::get(Owner)!!)!! == OWNER_LAYOUT);
    if (catch excuse = serial::register_described_type(
        $Type: Number,
        version: 2,
        layout: NUMBER_LAYOUT ^ 1,
        defaults: &defaults_number,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    if (catch excuse = serial::register_described_type(
        $Type: Number,
        version: 2,
        layout: NUMBER_LAYOUT,
        defaults: null,
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
}
