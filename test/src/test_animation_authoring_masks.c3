module c3d::test::animation_authoring_masks;

import c3d;
import c3d::anim @public;
import c3d::asset;
import c3d::maths;
import std::math;

struct MaskAllocationProbe (Allocator) @local {
    Allocator backing;
    sz remaining;
    sz outstanding;
    sz attempts;
}

fn void*? MaskAllocationProbe.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    self.attempts++;
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    void* pointer = self.backing.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return pointer;
}

fn void*? MaskAllocationProbe.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    self.attempts++;
    if (self.remaining <= 0) return mem::OUT_OF_MEMORY~;
    self.remaining--;
    return self.backing.resize(pointer, size, alignment);
}

fn void MaskAllocationProbe.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
    self.outstanding--;
}

fn AssetStore mask_store() @local {
    return asset::create_asset_store(mem, {
        .max_geometries = 1,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials = 1,
        .max_samplers = 1,
        .max_environments = 1,
        .max_models = 4,
        .max_skeletons = 1,
        .max_clips = 1,
        .max_shaders = 1,
        .max_compute_shaders = 1,
        .max_fonts = 1,
    });
}

fn ModelId mask_model(AssetStore* assets) @local {
    NodeTemplate[8] nodes = {
        { .parent = -1, .name = "root" },
        { .parent = 0, .name = "arm" },
        { .parent = 1, .name = "elbow" },
        { .parent = 2, .name = "wrist" },
        { .parent = 3, .name = "hand" },
        { .parent = 4, .name = "finger" },
        { .parent = 0, .name = "arm" },
        { .parent = 6, .name = "mesh" },
    };
    ModelTemplate template = { .nodes = alloc::new_array(assets.allocator, NodeTemplate, nodes.len) };
    foreach (index, node : nodes) {
        template.nodes[index] = node;
        template.nodes[index].name = node.name.copy(assets.allocator);
        template.nodes[index].local = maths::TRANSFORM_IDENTITY;
        template.nodes[index].visible = true;
    }
    return assets.add_model_owned(&template)!!;
}

fn void test_animation_authoring_weighted_mask_exact_names_duplicates_and_empty() @test {
    AssetStore assets = mask_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = mask_model(&assets);
    String[3] names = { "arm", "mesh", "arm" };
    float[3] weights = { 0.25f, 1, 0.75f };
    WeightedJointMask mask = anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
    )!!;
    defer anim::destroy_weighted_joint_mask(&mask);
    float[8] expected = { 0, 0.75f, 0, 0, 0, 0, 0.75f, 1 };
    assert(mask.nodes == expected[..]);
    assert(c3d::same_id(mask.model, model));
    anim::validate_weighted_joint_mask(&assets, model, &mask)!!;

    weights[..] = 0;
    names[..] = "root";
    assert(mask.nodes == expected[..]);
    foreach (index, node : assets.model(model).data.nodes) {
        assert(mask.model_names[index] == node.name);
        assert(mask.model_names[index].ptr != node.name.ptr);
        assert(mask.model_parents[index] == node.parent);
    }

    WeightedJointMask empty = anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &assets,
        model: model,
        names: {},
        weights: {},
    )!!;
    defer anim::destroy_weighted_joint_mask(&empty);
    assert(empty.nodes.len == 8);
    foreach (weight : empty.nodes) assert(weight == 0);
}

fn void test_animation_authoring_feathered_mask_literal_ramp_and_full_subtree() @test {
    AssetStore assets = mask_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = mask_model(&assets);
    String[1] names = { "arm" };
    float[1] weights = { 0.8f };
    uint[1] depths = { 3 };
    WeightedJointMask mask = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
        depths: depths[..],
    )!!;
    defer anim::destroy_weighted_joint_mask(&mask);
    float[8] expected = { 0, 0.2f, 0.4f, 0.6f, 0.8f, 0.8f, 0.2f, 0.4f };
    foreach (index, value : expected) assert(math::abs(mask.nodes[index] - value) <= 1e-7f);

    depths[0] = 0;
    WeightedJointMask full = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
        depths: depths[..],
    )!!;
    defer anim::destroy_weighted_joint_mask(&full);
    String[1] boolean_names = { "arm" };
    JointMask boolean = anim::create_joint_mask(mem, &assets.model(model).data, boolean_names[..])!!;
    defer anim::destroy_joint_mask(&boolean);
    foreach (index, included : boolean.nodes) assert(full.nodes[index] == (included ? 0.8f : 0));
}

fn void test_animation_authoring_feathered_overlap_order_uses_maximum() @test {
    AssetStore assets = mask_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = mask_model(&assets);
    String[2] names = { "arm", "wrist" };
    float[2] weights = { 0.8f, 0.5f };
    uint[2] depths = { 3, 0 };
    WeightedJointMask forward = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
        depths: depths[..],
    )!!;
    defer anim::destroy_weighted_joint_mask(&forward);
    names[0] = "wrist";
    names[1] = "arm";
    weights[0] = 0.5f;
    weights[1] = 0.8f;
    depths[0] = 0;
    depths[1] = 3;
    WeightedJointMask reverse = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
        depths: depths[..],
    )!!;
    defer anim::destroy_weighted_joint_mask(&reverse);
    assert(forward.nodes == reverse.nodes);
    assert(math::abs(forward.nodes[3] - 0.6f) <= 1e-7f);
    assert(forward.nodes[4] == 0.8f);
}

fn void test_animation_authoring_feathered_maximum_depth_does_not_wrap() @test {
    AssetStore assets = mask_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = mask_model(&assets);
    String[1] names = { "arm" };
    float[1] weights = { 1 };
    uint[1] depths = { uint::max };
    WeightedJointMask mask = anim::create_feathered_joint_mask(
        allocator: mem,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
        depths: depths[..],
    )!!;
    defer anim::destroy_weighted_joint_mask(&mask);
    assert(mask.nodes[1] == 0x1p-32f);
    assert(mask.nodes[2] == 0x1p-31f);
    assert(mask.nodes[3] == 3 * 0x1p-32f);
    assert(mask.nodes[5] == 5 * 0x1p-32f);
    assert(mask.nodes[6] == mask.nodes[1]);
}

fn void test_animation_authoring_weighted_mask_faults_precede_allocation() @test {
    AssetStore assets = mask_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = mask_model(&assets);
    MaskAllocationProbe allocator = { .backing = mem };
    String[1] names = { "arm" };
    float[1] weights;
    foreach (invalid : (float[5]){ -0.01f, 1.01f, float::nan, float::inf, -float::inf }) {
        weights[0] = invalid;
        if (catch excuse = anim::create_weighted_joint_mask(
            allocator: &allocator,
            assets: &assets,
            model: model,
            names: names[..],
            weights: weights[..],
        )) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false);
        }
    }
    if (catch excuse = anim::create_weighted_joint_mask(
        allocator: &allocator,
        assets: &assets,
        model: model,
        names: names[..],
        weights: {},
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    weights[0] = 0.5f;
    names[0] = "missing";
    if (catch excuse = anim::create_weighted_joint_mask(
        allocator: &allocator,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
    )) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false);
    }
    assert(allocator.attempts == 0 && allocator.outstanding == 0);
}

fn void test_animation_authoring_weighted_mask_identity_layout_and_value_admission() @test {
    AssetStore assets = mask_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = mask_model(&assets);
    ModelId foreign = mask_model(&assets);
    String[1] names = { "arm" };
    float[1] weights = { 0.5f };
    WeightedJointMask mask = anim::create_weighted_joint_mask(
        allocator: mem,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
    )!!;
    defer anim::destroy_weighted_joint_mask(&mask);
    if (catch excuse = anim::validate_weighted_joint_mask(&assets, foreign, &mask)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    mask.model_names[1][0] = 'x';
    assert(assets.model(model).data.nodes[1].name == "arm");
    if (catch excuse = anim::validate_weighted_joint_mask(&assets, model, &mask)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    mask.model_names[1][0] = 'a';
    mask.model_parents[3] = 0;
    if (catch excuse = anim::validate_weighted_joint_mask(&assets, model, &mask)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    mask.model_parents[3] = 2;
    mask.nodes[1] = float::nan;
    if (catch excuse = anim::validate_weighted_joint_mask(&assets, model, &mask)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    mask.nodes[1] = 0.5f;
    anim::validate_weighted_joint_mask(&assets, model, &mask)!!;

    float[] complete_row = mask.nodes;
    mask.nodes = mask.nodes[:7];
    if (catch excuse = anim::validate_weighted_joint_mask(&assets, model, &mask)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    mask.nodes = complete_row;

    assets.remove_model(model);
    if (catch excuse = anim::validate_weighted_joint_mask(&assets, model, &mask)) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }
    assert(mask.model_names[1] == "arm" && mask.model_parents[3] == 2);
}

fn void test_animation_authoring_feathered_mask_shape_and_stale_id_faults() @test {
    AssetStore assets = mask_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = mask_model(&assets);
    MaskAllocationProbe allocator = { .backing = mem };
    String[1] names = { "arm" };
    float[1] weights = { 0.5f };
    uint[1] depths = { 3 };
    if (catch excuse = anim::create_feathered_joint_mask(
        allocator: &allocator,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
        depths: {},
    )) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assets.remove_model(model);
    if (catch excuse = anim::create_feathered_joint_mask(
        allocator: &allocator,
        assets: &assets,
        model: model,
        names: names[..],
        weights: weights[..],
        depths: depths[..],
    )) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }
    assert(allocator.attempts == 0 && allocator.outstanding == 0);
}

fn void test_animation_authoring_weighted_mask_allocation_failures_release_every_owner() @test {
    AssetStore assets = mask_store();
    defer asset::destroy_asset_store(&assets);
    ModelId model = mask_model(&assets);
    String[1] names = { "arm" };
    float[1] weights = { 0.5f };
    uint[1] depths = { 2 };
    for (uint feathered = 0; feathered < 2; feathered++) {
        bool succeeded;
        for (sz allowance = 0; allowance < 16; allowance++) {
            MaskAllocationProbe allocator = { .backing = mem, .remaining = allowance };
            WeightedJointMask? attempt;
            if (feathered) {
                attempt = anim::create_feathered_joint_mask(
                    allocator: &allocator,
                    assets: &assets,
                    model: model,
                    names: names[..],
                    weights: weights[..],
                    depths: depths[..],
                );
            } else {
                attempt = anim::create_weighted_joint_mask(
                    allocator: &allocator,
                    assets: &assets,
                    model: model,
                    names: names[..],
                    weights: weights[..],
                );
            }
            if (catch excuse = attempt) {
                assert(excuse == c3d::CAPACITY_EXCEEDED);
            } else {
                WeightedJointMask mask = attempt;
                assert(mask.nodes.len == 8);
                anim::destroy_weighted_joint_mask(&mask);
                assert(mask.nodes.len == 0 && mask.model_names.len == 0 && mask.model_parents.len == 0);
                succeeded = true;
            }
            assert(allocator.outstanding == 0);
            if (succeeded) break;
        }
        assert(succeeded);
    }
}
