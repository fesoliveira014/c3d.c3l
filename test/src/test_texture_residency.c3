module c3d::test::texture_residency;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render;

const usz UNLIMITED_FRAME_BYTES = 1 << 30;
const uint SEVEN_LEVELS = 7;
const usz CAPACITY = 8;

fn TextureResidency make_record(
    usz[4] levels,
    uint chain_mips,
    uint base,
    uint tail,
    uint required,
    ulong last_used = 0,
) @local {
    TextureResidency record = {
        .chain_mips = chain_mips,
        .tail_base = tail,
        .resident_base = base,
        .required_base = required,
        .last_used_frame = last_used,
        .eligible = true,
        .streamed = true,
        .raisable = true,
    };
    for (uint mip = 0; mip < chain_mips; mip++) record.level_bytes[mip] = levels[mip];
    return record;
}

fn TextureResidency make_pair_record(uint base, uint tail, uint required, ulong last_used = 0) @local {
    return make_record(
        levels: { 400, 200, 50, 10 },
        chain_mips: 4,
        base: base,
        tail: tail,
        required: required,
        last_used: last_used,
    );
}

fn TextureBudget budget_of(usz bytes, usz frame_bytes = UNLIMITED_FRAME_BYTES) @local {
    return { .budget_bytes = bytes, .frame_bytes = frame_bytes, .frame = 1 };
}

fn void test_level_bytes_bc1_count_whole_blocks() @test {
    material::TextureDesc desc = material::texture_2d_desc(64, 64, BC1_RGBA_SRGB);
    desc.generate_mips = false;
    desc.mip_levels = SEVEN_LEVELS;
    TextureLevelBytes bytes = render::texture_level_bytes(desc, SEVEN_LEVELS)!!;
    usz[7] expected = { 2048, 512, 128, 32, 8, 8, 8 };

    assert(bytes[:SEVEN_LEVELS] == expected[..]);
}

fn void test_level_bytes_rgba8_multiply_layers() @test {
    TextureLevelBytes bytes = render::texture_level_bytes(material::texture_cube_desc(4, RGBA8_UNORM), 3)!!;
    usz[3] expected = { 384, 96, 24 };

    assert(bytes[:3] == expected[..]);
}

fn void test_range_bytes_sums_from_base() @test {
    TextureResidency record = make_record(
        levels: { 64, 16, 4, 0 },
        chain_mips: 3,
        base: 0,
        tail: 0,
        required: 3,
    );

    assert(render::texture_range_bytes(&record, 0) == 84);
    assert(render::texture_range_bytes(&record, 1) == 20);
    assert(render::texture_range_bytes(&record, 3) == 0);
}

fn void test_tail_base_keeps_extents_at_or_under_the_tail() @test {
    assert(render::texture_tail_base(4096, 13) == 6);
    assert(render::texture_tail_base(64, 7) == 0);
    assert(render::texture_tail_base(65, 7) == 1);
    assert(render::texture_tail_base(1, 1) == 0);
    assert(render::texture_tail_base(4096, 3) == 2);
}

fn void test_required_base_follows_screen_extent() @test {
    assert(render::texture_required_base(4096, 13, 4096.0f, 0) == 0);
    assert(render::texture_required_base(4096, 13, 1024.0f, 0) == 2);
    assert(render::texture_required_base(4096, 13, 1500.0f, 0) == 1);
    assert(render::texture_required_base(4096, 13, 0.5f, 0) == 12);
    assert(render::texture_required_base(4096, 13, float::inf, 0) == 0);
    assert(render::texture_required_base(4096, 13, 4096.0f, 1) == 1);
    assert(render::texture_required_base(4096, 13, 0.5f, 1) == 12);
}

fn void test_eligibility_excludes_cubes_arrays_volumes_storage_single_mips_and_empty() @test {
    material::TextureDesc flat = material::texture_2d_desc(256, 256, RGBA8_UNORM);
    material::TextureDesc supplied = material::texture_2d_desc(256, 256, BC1_RGBA_UNORM);
    supplied.generate_mips = false;
    supplied.mip_levels = 9;
    assert(render::texture_eligible(flat, MIP_ZERO, 9));
    assert(render::texture_eligible(supplied, SUPPLIED_MIPS, 9));

    assert(!render::texture_eligible(material::texture_cube_desc(256, RGBA8_UNORM), MIP_ZERO, 9));
    material::TextureDesc array = flat;
    array.layers = 2;
    assert(!render::texture_eligible(array, MIP_ZERO, 9));
    assert(!render::texture_eligible(material::texture_3d_desc(16, 16, 16, RGBA8_UNORM), MIP_ZERO, 5));
    material::TextureDesc storage = flat;
    storage.storage = true;
    assert(!render::texture_eligible(storage, MIP_ZERO, 9));
    assert(!render::texture_eligible(flat, MIP_ZERO, 1));
    assert(!render::texture_eligible(flat, EMPTY, 9));
    material::TextureDesc unmipped = flat;
    unmipped.generate_mips = false;
    assert(!render::texture_eligible(unmipped, MIP_ZERO, 9));
}

fn void test_planner_leaves_a_budgetless_set_unchanged() @test {
    TextureResidency[2] textures = { make_pair_record(0, 2, 4), make_pair_record(0, 2, 4) };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(0), &bias, changes[..]);

    assert(plan.change_count == 0 && plan.evictions == 0 && plan.raises == 0 && plan.starved == 0);
    assert(bias == 0 && plan.total_bytes == 1320);
}

fn void test_planner_drains_to_full_residency_when_the_budget_lifts() @test {
    TextureResidency[2] textures = {
        make_record(levels: { 16384, 4096, 1024, 256 }, chain_mips: 4, base: 2, tail: 2, required: 4),
        make_record(levels: { 16384, 4096, 1024, 256 }, chain_mips: 4, base: 2, tail: 2, required: 4),
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias = 3;

    TextureResidencyPlan plan = render::plan_texture_residency(
        textures[..],
        budget_of(0, 8192),
        &bias,
        changes[..],
    );
    assert(plan.change_count == 1 && plan.raises == 1 && plan.evictions == 0 && bias == 0);
    assert(changes[0].index == 0 && changes[0].new_base == 0);

    textures[0].resident_base = 0;
    plan = render::plan_texture_residency(textures[..], budget_of(0, 8192), &bias, changes[..]);
    assert(plan.change_count == 1 && changes[0].index == 1 && changes[0].new_base == 0);
}

fn void test_planner_raises_only_within_budget() @test {
    TextureResidency[3] textures = {
        make_record(levels: { 49152, 16384, 1024, 256 }, chain_mips: 4, base: 2, tail: 2, required: 0),
        make_record(levels: { 65536, 1024, 256, 64 }, chain_mips: 4, base: 1, tail: 1, required: 0),
        make_record(levels: { 100000, 25000, 6000, 1500 }, chain_mips: 4, base: 0, tail: 2, required: 2),
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(
        textures[..],
        budget_of(230000),
        &bias,
        changes[..],
    );

    assert(plan.change_count == 1 && plan.raises == 1 && plan.starved == 1 && bias == 0);
    assert(changes[0].index == 0 && changes[0].new_base == 0);
    assert(plan.total_bytes == 200660);
}

fn void test_planner_first_raise_ignores_the_frame_allowance() @test {
    TextureResidency[2] textures = {
        make_record(levels: { 65536, 1024, 256, 64 }, chain_mips: 4, base: 1, tail: 1, required: 0),
        make_record(levels: { 65536, 1024, 256, 64 }, chain_mips: 4, base: 1, tail: 1, required: 0),
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(
        textures[..],
        budget_of(1 << 30, 1024),
        &bias,
        changes[..],
    );

    assert(plan.change_count == 1 && plan.raises == 1 && plan.starved == 1);
    assert(changes[0].index == 0 && changes[0].new_base == 0);
}

fn void test_planner_evicts_undrawn_before_biasing_drawn() @test {
    TextureResidency[2] textures = {
        make_record(levels: { 50, 8, 2, 0 }, chain_mips: 3, base: 0, tail: 1, required: 3),
        make_record(levels: { 50, 8, 2, 0 }, chain_mips: 3, base: 1, tail: 1, required: 0),
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(100), &bias, changes[..]);

    assert(bias == 0 && plan.evictions == 1 && plan.raises == 1 && plan.change_count == 2);
    assert(changes[0].index == 0 && changes[0].new_base == 1);
    assert(changes[1].index == 1 && changes[1].new_base == 0);
    assert(plan.total_bytes == 70);

    bias = 1;
    plan = render::plan_texture_residency(textures[..], budget_of(100), &bias, changes[..]);

    assert(bias == 0 && plan.evictions == 1);
    assert(changes[0].index == 0 && changes[0].new_base == 1);
}

fn void test_planner_evicts_least_recently_used_to_the_tail() @test {
    TextureResidency[3] textures = {
        make_record(levels: { 100, 20, 0, 0 }, chain_mips: 2, base: 0, tail: 1, required: 2, last_used: 5),
        make_record(levels: { 100, 20, 0, 0 }, chain_mips: 2, base: 0, tail: 1, required: 2, last_used: 3),
        make_record(levels: { 100, 20, 0, 0 }, chain_mips: 2, base: 0, tail: 1, required: 2, last_used: 9),
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(300), &bias, changes[..]);

    assert(plan.change_count == 1 && plan.evictions == 1 && plan.raises == 0);
    assert(changes[0].index == 1 && changes[0].new_base == 1);
    assert(plan.total_bytes == 260 && bias == 0);
}

fn void test_planner_never_lowers_a_drawn_texture_under_budget() @test {
    TextureResidency[1] textures = {
        make_record(levels: { 100, 20, 5, 0 }, chain_mips: 3, base: 0, tail: 1, required: 1),
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(1000), &bias, changes[..]);

    assert(plan.change_count == 0 && bias == 0);
}

fn void test_planner_bias_rises_until_the_drawn_set_fits_and_relaxes_with_headroom() @test {
    TextureResidency[2] textures = { make_pair_record(2, 2, 0), make_pair_record(2, 2, 0) };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(800), &bias, changes[..]);

    assert(bias == 1 && plan.change_count == 2 && plan.raises == 2 && plan.total_bytes == 520);
    assert(changes[0].index == 0 && changes[0].new_base == 1);
    assert(changes[1].index == 1 && changes[1].new_base == 1);

    textures[0].resident_base = 1;
    textures[1].resident_base = 1;
    plan = render::plan_texture_residency(textures[..], budget_of(1600), &bias, changes[..]);

    assert(bias == 0 && plan.change_count == 2);
    assert(changes[0].new_base == 0 && changes[1].new_base == 0);
}

fn void test_planner_counts_pinned_records_as_fixed_bytes() @test {
    TextureResidency pinned = make_record(
        levels: { 900, 90, 10, 0 },
        chain_mips: 3,
        base: 0,
        tail: 2,
        required: 2,
    );
    pinned.raisable = false;
    TextureResidency[3] textures = { pinned, make_pair_record(2, 2, 0), make_pair_record(2, 2, 0) };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(1600), &bias, changes[..]);

    assert(bias == 1 && plan.evictions == 0 && plan.change_count == 2);
    assert(changes[0].index == 1 && changes[1].index == 2);
}

fn void test_planner_raises_full_readers_regardless_of_budget() @test {
    TextureResidency reader = make_pair_record(3, 0, 4);
    reader.streamed = false;
    TextureResidency[3] textures = {
        make_record(levels: { 100, 50, 10, 5 }, chain_mips: 4, base: 2, tail: 2, required: 0),
        make_record(levels: { 300, 100, 20, 5 }, chain_mips: 4, base: 0, tail: 2, required: 4),
        reader,
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(1000), &bias, changes[..]);

    assert(plan.change_count == 3 && plan.evictions == 1 && plan.raises == 2);
    assert(changes[0].index == 1 && changes[0].new_base == 2);
    assert(changes[1].index == 2 && changes[1].new_base == 0);
    assert(changes[2].index == 0 && changes[2].new_base == 0);
    assert(plan.total_bytes == 850);
}

fn void test_planner_writes_evictions_before_raises() @test {
    TextureResidency[2] textures = {
        make_record(levels: { 50, 8, 2, 0 }, chain_mips: 3, base: 1, tail: 1, required: 0),
        make_record(levels: { 50, 8, 2, 0 }, chain_mips: 3, base: 0, tail: 1, required: 3),
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(100), &bias, changes[..]);

    assert(plan.change_count == 2);
    assert(changes[0].index == 1 && changes[0].new_base == 1);
    assert(changes[1].index == 0 && changes[1].new_base == 0);
}

fn void test_planner_reports_starved_records() @test {
    TextureResidency[2] textures = {
        make_record(levels: { 100, 50, 20, 0 }, chain_mips: 3, base: 0, tail: 2, required: 2),
        make_record(levels: { 100, 50, 20, 0 }, chain_mips: 3, base: 2, tail: 2, required: 0),
    };
    TextureResidencyChange[CAPACITY] changes;
    uint bias;

    TextureResidencyPlan plan = render::plan_texture_residency(textures[..], budget_of(190), &bias, changes[..]);

    assert(plan.change_count == 0 && plan.raises == 0 && plan.starved == 1 && bias == 0);
}

fn void test_mip_chain_from_first_mip_keeps_only_lower_levels() @test {
    char[256] pixels;
    foreach (index, &value : pixels) *value = (char)(index * 7 + 3);
    material::TextureDesc desc = material::texture_2d_desc(8, 8, RGBA8_UNORM);
    TextureMipChain full = render::create_texture_mips(mem, desc, pixels[..])!!;
    defer render::destroy_texture_mips(&full);
    TextureMipChain partial = render::create_texture_mips(mem, desc, pixels[..], first_mip: 2)!!;
    defer render::destroy_texture_mips(&partial);

    assert(partial.first_mip == 2 && partial.mip_count == 2);
    assert(partial.offsets[0] == 0 && partial.offsets[1] == 16 && partial.pixels.len == 20);
    assert(partial.pixels == full.pixels[full.offsets[2]..]);
}

fn void test_supplied_layout_from_first_mip() @test {
    char[64] level0;
    char[16] level1;
    char[4] level2;
    foreach (index, &value : level0) *value = (char)index;
    foreach (index, &value : level1) *value = (char)(100 + index);
    foreach (index, &value : level2) *value = (char)(200 + index);
    TextureMipData[3] levels = {
        { .mip = 0, .layer = 0, .bytes = level0[..] },
        { .mip = 1, .layer = 0, .bytes = level1[..] },
        { .mip = 2, .layer = 0, .bytes = level2[..] },
    };
    material::TextureDesc desc = material::texture_2d_desc(4, 4, RGBA8_UNORM);
    desc.generate_mips = false;
    desc.mip_levels = 3;

    TextureMipLayout layout = render::supplied_texture_mip_layout(desc, levels[..], first_mip: 1)!!;
    assert(layout.mip_count == 2 && layout.total_bytes == 20);
    assert(layout.offsets[0] == 0 && layout.offsets[1] == 16);

    char[20] packed;
    render::copy_supplied_texture_mips(packed[..], levels[..], first_mip: 1);
    assert(packed[:16] == level1[..] && packed[16..] == level2[..]);
}
