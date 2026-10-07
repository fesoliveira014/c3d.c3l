module c3d::test::describe_consumers @private;

import c3d;
import c3d::describe;

const FixtureReference[4] REFERENCES = {
    { .kind = ENTITY, .token = "entity/demo", .id = { .index = 13, .generation = 5 } },
    { .kind = ENTITY, .token = "entity/owner", .id = { .index = 17, .generation = 4 } },
    { .kind = ASSET, .asset_kind = GEOMETRY, .token = "mesh/demo", .id = { .index = 23, .generation = 7 } },
    { .kind = ASSET, .asset_kind = TEXTURE, .token = "texture/fixture", .id = { .index = 23, .generation = 7 } },
};

struct FixtureReference {
    describe::Kind kind;
    AssetKind asset_kind;
    String token;
    Id id;
}

fn bool reference_kind_matches(FixtureReference* reference, describe::Info* info) {
    return reference.kind == info.kind && (info.kind == ENTITY || reference.asset_kind == info.metadata.asset_kind);
}

fn String? reference_token(describe::Info* info, void* value) {
    Id* id = (Id*)value;
    foreach (&reference : REFERENCES) {
        if (reference_kind_matches(reference, info) && c3d::same_id(reference.id, *id)) return reference.token;
    }
    return INVALID_FIXTURE~;
}

fn void? read_reference(describe::Info* info, String token, void* value) {
    foreach (&reference : REFERENCES) {
        if (!reference_kind_matches(reference, info) || reference.token != token) continue;
        *(Id*)value = reference.id;
        return;
    }
    return INVALID_FIXTURE~;
}

fn void test_fixture_reference_tokens_keep_kinds_distinct() @test @public {
    Id id = { .index = 23, .generation = 7 };
    describe::Info texture = { .kind = ASSET, .metadata = { .has_asset_kind = true, .asset_kind = TEXTURE } };
    describe::Info geometry = { .kind = ASSET, .metadata = { .has_asset_kind = true, .asset_kind = GEOMETRY } };
    assert(reference_token(&texture, &id)!! == "texture/fixture");
    assert(reference_token(&geometry, &id)!! == "mesh/demo");
    Id decoded;
    if (catch excuse = read_reference(&geometry, "texture/fixture", &decoded)) {
        assert(excuse == INVALID_FIXTURE);
    } else {
        assert(false);
    }
}
