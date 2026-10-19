module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::serial @public;
import std::math;

const char[] INSTANCES_V1_BINARY @local = $embed("../../../test/fixtures/instances_v1/instances-v1.bin");
const char[] INSTANCES_V1_TEXT @local = $embed("../../../test/fixtures/instances_v1/instances-v1.jsonc");
const char[] INSTANCES_V2_BINARY @local = $embed("../../../test/fixtures/instances_v2/instances-v2.bin");
const char[] INSTANCES_V2_TEXT @local = $embed("../../../test/fixtures/instances_v2/instances-v2.jsonc");
const char[] INSTANCES_V3_BINARY @local = $embed("../../../test/fixtures/instances_v3/instances-v3.bin");
const char[] INSTANCES_V3_TEXT @local = $embed("../../../test/fixtures/instances_v3/instances-v3.jsonc");

fn Node* child_named(Node* parent, String name) @private {
    for (Node* child = parent.first_child; child; child = child.next_sibling) {
        if (child.name == name) return child;
    }
    unreachable("missing child");
}

fn void test_core_batches_preserve_live_values_and_capacity_in_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = fixture.assets.add_geometry(&geometry, "box")!!;
        MaterialId material_id = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }), "white")!!;
        Node* root = fixture.source.add_node(name: "batches")!!;
        Transform[1] transforms = { maths::TRANSFORM_IDENTITY };
        transforms[0].position = { 1, 2, 3 };
        transforms[0].scale = { 2, 3, 4 };
        Vec4[1] colors = { { 0.1f, 0.2f, 0.3f, 0.4f } };
        fixture.source.add_instanced_mesh(
            geometry: geometry_id,
            material: material_id,
            capacity: 4,
            transforms: transforms[..],
            colors: colors[..],
            parent: root,
            name: "instances",
        )!!;
        Billboard[1] billboards = { scene::BILLBOARD_DEFAULT };
        billboards[0].rotation = 0.5f;
        fixture.source.add_billboards(
            material: material_id,
            capacity: 3,
            billboards: billboards[..],
            facing: DIRECTIONAL,
            parent: root,
            name: "billboards",
        )!!;
        Mat4 basis = matrix::IDENTITY4;
        basis.m01 = 0.25f;
        basis.m03 = 2;
        LodPart[1] parts = { { .geometry = geometry_id, .material = material_id, .local = basis } };
        LodLevel[1] levels = { { .part_count = 1 } };
        LodDesc desc = { .parts = parts[..], .levels = levels[..] };
        fixture.source.add_lod_group(
            assets: &fixture.assets,
            desc: desc,
            parent: root,
            name: "single",
        )!!;
        fixture.source.add_instanced_lod_group(
            assets: &fixture.assets,
            desc: desc,
            capacity: 5,
            transforms: transforms[..],
            colors: colors[..],
            parent: root,
            name: "lod_instances",
        )!!;
        LodEffects effects = {
            .sway = { .direction = { 1, 0, 0 }, .amplitude = 0.5f, .frequency = 0.8f,
                .lean = 0.1f, .wavelength = 3, .variation = 0.2f },
            .fade = { .start = 10, .end = 20 },
        };
        InstancedMesh* source_batch = fixture.source.get(child_named(root, "instances"), InstancedMesh);
        source_batch.sway = effects.sway;
        source_batch.fade = effects.fade;
        source_batch.cast_shadow = false;
        source_batch.receive_shadow = false;
        source_batch.trace = false;
        source_batch.has_bounds_override = true;
        source_batch.local_bounds = { .min = { -2, -2, -2 }, .max = { 2, 2, 2 } };
        (void)source_batch.mirrored_count();
        Node* source_single = child_named(root, "single");
        Node* source_instanced = child_named(root, "lod_instances");
        fixture.source.set_lod_effects(source_single, effects);
        fixture.source.set_lod_effects(source_instanced, effects);
        TextureDesc atlas_desc = material::texture_2d_desc(8, 16, PixelFormat.RGBA8_UNORM);
        atlas_desc.generate_mips = false;
        char[512] pixels;
        TextureId atlas = fixture.assets.add_texture(atlas_desc, pixels[..], "atlas")!!;
        fixture.source.set_lod_impostor(
            assets: &fixture.assets,
            node: source_single,
            impostor: { .atlas = atlas, .bounds = { .radius = 5 }, .frames_per_side = 2, .cell_size = 4 },
            min_screen_size: 0.02f,
        )!!;
        LodGroupState* source_group = fixture.source.get(source_instanced, LodGroup).state;
        (void)source_group.placement_bounds(&fixture.assets);
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: root,
        )!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            InstancedMesh* batch = fixture.destination.get(child_named(restored, "instances"), InstancedMesh);
            assert(batch.count == 1 && batch.transforms.len == 4 && batch.colors.len == 4);
            assert(batch.transforms[0].position == transforms[0].position && batch.colors[0] == colors[0]);
            assert(batch.sway.amplitude == 0.5f && batch.fade.end == 20 && batch.has_bounds_override);
            assert(!batch.cast_shadow && !batch.receive_shadow && !batch.trace);
            assert(batch.local_bounds.min == (Vec3){ -2, -2, -2 } && !batch.aggregate.mirrored_revision);
            assert(batch.transforms[3].scale == (Vec3){ 1, 1, 1 } && batch.colors[3] == (Vec4){ 1, 1, 1, 1 });
            assert(batch.transforms.ptr != source_batch.transforms.ptr);
            Node* restored_billboards = child_named(restored, "billboards");
            BillboardBatch* billboard_batch = fixture.destination.get(restored_billboards, BillboardBatch);
            assert(billboard_batch.count == 1 && billboard_batch.billboards.len == 3);
            assert(billboard_batch.facing == DIRECTIONAL && billboard_batch.billboards[0].rotation == 0.5f);
            assert(billboard_batch.billboards[2].size == (Vec2){ 1, 1 });
            LodGroupState* single = fixture.destination.get(child_named(restored, "single"), LodGroup).state;
            assert(single.mode == SINGLE && single.count == 1 && !single.transforms.len);
            assert(single.desc.parts[0].local.m01 == 0.25f && single.desc.parts[0].local.m03 == 2);
            assert(single.has_impostor && c3d::same_id(single.impostor.atlas, atlas));
            assert(single.impostor.bounds.radius == 5 && single.impostor.frames_per_side == 2);
            assert(single.impostor.cell_size == 4 && single.impostor_min_screen_size == 0.02f);
            assert(single.desc.parts.ptr != fixture.source.get(source_single, LodGroup).state.desc.parts.ptr);
            LodGroupState* instanced = fixture.destination.get(child_named(restored, "lod_instances"), LodGroup).state;
            assert(instanced.mode == INSTANCED && instanced.count == 1 && instanced.transforms.len == 5);
            assert(instanced.effects.sway.amplitude == 0.5f && instanced.effects.fade.end == 20);
            assert(!instanced.effects.cast_shadow && !instanced.effects.receive_shadow && !instanced.effects.trace);
            assert(instanced.identity != source_group.identity);
            assert(!instanced.bounds_revision && !instanced.aggregate_revision);
            assert(instanced.transforms[0].position == transforms[0].position && instanced.colors[0] == colors[0]);
            assert(instanced.transforms[4].scale == (Vec3){ 1, 1, 1 } && instanced.colors[4] == (Vec4){ 1, 1, 1, 1 });
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            assert(text == serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_core_batch_writers_reject_invalid_live_billboards_and_effects() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* root = fixture.source.add_node()!!;
        Node* instances = fixture.source.add_instanced_mesh(
            geometry: (GeometryId){},
            material: (MaterialId){},
            capacity: 2,
            parent: root,
        )!!;
        Billboard[1] billboards = { scene::BILLBOARD_DEFAULT };
        Node* billboard_node = fixture.source.add_billboards(
            material: (MaterialId){},
            capacity: 2,
            billboards: billboards[..],
            parent: root,
        )!!;
        String valid = fixture_text(&fixture, root);
        for (uint invalid = 0; invalid < 2; invalid++) {
            if (invalid == 0) {
                fixture.source.get(billboard_node, BillboardBatch).billboards[0].size.x = -1;
            } else {
                fixture.source.get(instances, InstancedMesh).sway.amplitude = -1;
            }
            assert(@catch(serial::write_subtree(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: root,
            )) == c3d::INVALID_ARGUMENT);
            assert(@catch(serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: root,
            )) == c3d::INVALID_ARGUMENT);
            fixture.source.get(billboard_node, BillboardBatch).billboards[0] = scene::BILLBOARD_DEFAULT;
            fixture.source.get(instances, InstancedMesh).sway = {};
        }
        assert(fixture_text(&fixture, root) == valid);
    };
}

fn void test_core_batch_copy_failures_leave_no_attached_component() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        Node* node = fixture.destination.add_node()!!;
        FailingAllocator counter;
        fixture.destination.allocator = &counter;
        defer fixture.destination.allocator = mem;
        ReadContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .node = node };
        InstanceAuthoring instances = { .capacity = 2 };
        serial::CodecEntry* instance_entry = &serial::codecs[c3d::ecs::assigned_slot(InstancedMesh)!!];
        for (uint failure = 1; failure <= 2; failure++) {
            counter = { .failure = failure };
            assert(@catch(instance_entry.described.codec.attach(&instances, &context)) == c3d::CAPACITY_EXCEEDED);
            assert(!fixture.destination.has(node, InstancedMesh) && !counter.outstanding);
        }
        BillboardAuthoring billboards = { .capacity = 2 };
        serial::CodecEntry* billboard_entry = &serial::codecs[c3d::ecs::assigned_slot(BillboardBatch)!!];
        counter = { .failure = 1 };
        assert(@catch(billboard_entry.described.codec.attach(&billboards, &context)) == c3d::CAPACITY_EXCEEDED);
        assert(!fixture.destination.has(node, BillboardBatch) && !counter.outstanding);
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = fixture.assets.add_geometry(&geometry, "box")!!;
        MaterialId material_id = fixture.assets.add_material(material::basic({}), "white")!!;
        LodPart[1] parts = { { .geometry = geometry_id, .material = material_id, .local = matrix::IDENTITY4 } };
        LodLevel[1] levels = { { .part_count = 1 } };
        LodAuthoring lod = { .desc = { .parts = parts[..], .levels = levels[..] }, .mode = SINGLE };
        serial::CodecEntry* lod_entry = &serial::codecs[c3d::ecs::assigned_slot(LodGroup)!!];
        counter = { .failure = 1 };
        assert(@catch(lod_entry.described.codec.attach(&lod, &context)) == c3d::CAPACITY_EXCEEDED);
        assert(!fixture.destination.has(node, LodGroup) && !counter.outstanding);
    };
}

fn void test_instanced_quadtree_round_trips() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;

        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = fixture.assets.add_geometry(&geometry, "box")!!;
        MaterialId material_id = fixture.assets.add_material(material::basic({}), "white")!!;

        Transform[7] transforms;
        foreach (index, &transform : transforms) {
            *transform = maths::TRANSFORM_IDENTITY;
            transform.position = { (float)index, 0, 0 };
        }
        Node* root = fixture.source.add_node(name: "root")!!;
        Node* source_node = fixture.source.add_instanced_mesh(
            geometry: geometry_id,
            material: material_id,
            capacity: 8,
            transforms: transforms[..],
            parent: root,
            name: "tree",
        )!!;
        InstancedMesh* source_batch = fixture.source.get(source_node, InstancedMesh);
        source_batch.trace = false;
        uint[7] parents = { scene::QUADTREE_ROOT, 0, 0, 1, 1, 2, 2 };
        fixture.source.set_instance_quadtree(source_node, parents[..], 96, 0.25f)!!;
        QuadtreeLevel[3] levels = {
            { .extent = 4, .diagonal = 5.7f },
            { .extent = 2, .diagonal = 2.9f },
            { .extent = 1, .diagonal = 1.5f },
        };

        for (uint ranged = 0; ranged < 2; ranged++) {
            if (ranged) fixture.source.set_quadtree_ranges(source_node, levels[..], 0.25f)!!;

            char[] bytes = serial::write_subtree(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: root,
            )!!;
            String text = serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: root,
            )!!;

            for (uint encoding = 0; encoding < 2; encoding++) {
                Node* restored = encoding == 0
                  ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
                  : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
                InstancedMesh* batch = fixture.destination.get(child_named(restored, "tree"), InstancedMesh);
                assert(batch.count == 7 && batch.transforms.len == 8);
                assert(batch.quadtree.parents == parents[..]);
                assert(batch.quadtree.parents.ptr != source_batch.quadtree.parents.ptr);
                assert(batch.quadtree.split_pixels == 96 && batch.quadtree.hysteresis == 0.25f);
                assert(batch.quadtree.leaves == source_batch.quadtree.leaves);
                assert(batch.quadtree.leaf_count == 4 && batch.quadtree.revision != 0);
                batch.validate_quadtree();
                assert(batch.quadtree.metric == (ranged ? QuadtreeMetric.BOX_RANGES : QuadtreeMetric.SPHERE_PIXELS));
                assert(batch.quadtree.morph_band == (ranged ? 0.25f : 0));
                if (ranged) {
                    foreach (depth, level : levels) {
                        assert(batch.quadtree.levels[depth].extent == level.extent);
                        assert(batch.quadtree.levels[depth].diagonal == level.diagonal);
                    }
                }

                assert(bytes == serial::write_subtree(
                    allocator: tmem,
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                )!!);
                assert(text == serial::write_subtree_text(
                    allocator: tmem,
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    root: restored,
                )!!);
                fixture.destination.remove(restored);
            }
        }
    };
}

fn void test_instanced_quadtree_attach_faults_leave_no_component() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;

        Node* node = fixture.destination.add_node()!!;
        ReadContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .node = node };
        serial::CodecEntry* entry = &serial::codecs[c3d::ecs::assigned_slot(InstancedMesh)!!];
        uint[2] parents = { scene::QUADTREE_ROOT, 0 };
        Transform[2] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
        InstanceAuthoring source = {
            .capacity = 2,
            .transforms = transforms[..],
            .trace = true,
            .quadtree_parents = parents[..],
            .split_pixels = 96,
            .hysteresis = 0.25f,
        };

        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::UNSUPPORTED);
        assert(!fixture.destination.has(node, InstancedMesh));

        source.trace = false;
        source.quadtree_parents = parents[:1];
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.destination.has(node, InstancedMesh));

        source.quadtree_parents = parents[..];
        source.split_pixels = float::nan;
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.destination.has(node, InstancedMesh));

        source.split_pixels = 96;
        source.transforms[1].scale.x = -1;
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::UNSUPPORTED);
        assert(!fixture.destination.has(node, InstancedMesh));

        source.transforms[1].scale.x = 1;
        source.metric = QuadtreeMetric.BOX_RANGES;
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.destination.has(node, InstancedMesh));

        QuadtreeLevel[1] short_levels = {{ .extent = 2, .diagonal = 3 }};
        source.levels = short_levels[..];
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.destination.has(node, InstancedMesh));

        source.metric = QuadtreeMetric.SPHERE_PIXELS;
        assert(@catch(entry.described.codec.attach(&source, &context)) == c3d::INVALID_ARGUMENT);
        assert(!fixture.destination.has(node, InstancedMesh));

        source.levels = {};
        entry.described.codec.attach(&source, &context)!!;
        assert(fixture.destination.get(node, InstancedMesh).quadtree.parents == parents[..]);
    };
}

fn void test_instanced_quadtree_writers_reject_a_broken_contract() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;

        Transform[2] transforms = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
        Node* root = fixture.source.add_node()!!;
        Node* node = fixture.source.add_instanced_mesh(
            geometry: (GeometryId){},
            material: (MaterialId){},
            capacity: 2,
            transforms: transforms[..],
            parent: root,
        )!!;
        InstancedMesh* batch = fixture.source.get(node, InstancedMesh);
        batch.trace = false;
        uint[2] parents = { scene::QUADTREE_ROOT, 0 };
        fixture.source.set_instance_quadtree(node, parents[..], 96, 0.25f)!!;
        String valid = fixture_text(&fixture, root);

        for (uint broken = 0; broken < 3; broken++) {
            if (broken == 0) {
                batch.trace = true;
            } else if (broken == 1) {
                batch.transforms[1].scale.x = -1;
                fixture.source.mark_instances_dirty(node);
            } else {
                batch.quadtree.hysteresis = float::nan;
            }
            assert(@catch(serial::write_subtree(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: root,
            )) == c3d::INVALID_ARGUMENT);
            assert(@catch(serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.source,
                assets: &fixture.assets,
                root: root,
            )) == c3d::INVALID_ARGUMENT);
            batch.trace = false;
            batch.transforms[1].scale.x = 1;
            fixture.source.mark_instances_dirty(node);
            batch.quadtree.hysteresis = 0.25f;
        }
        assert(fixture_text(&fixture, root) == valid);
    };
}

fn void test_instanced_v1_fixtures_read_without_a_quadtree() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;

        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = fixture.assets.add_geometry(&geometry, "instances_v1/box")!!;
        MaterialId material_id = fixture.assets.add_material(material::basic({}), "instances_v1/material")!!;

        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, INSTANCES_V1_BINARY)!!
              : serial::read_subtree_text(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    text: (String)INSTANCES_V1_TEXT,
                )!!;
            InstancedMesh* batch = fixture.destination.get(restored, InstancedMesh);
            assert(batch.count == 5 && batch.transforms.len == 6 && batch.colors.len == 6);
            assert(c3d::same_id(batch.geometry, geometry_id) && c3d::same_id(batch.material, material_id));
            assert(batch.transforms[4].position == (Vec3){ 4, 0, -4 });
            assert(batch.colors[0] == (Vec4){ 0.1f, 0.2f, 0.3f, 1 });
            assert(batch.transforms[5].scale == (Vec3){ 1, 1, 1 } && batch.colors[5] == (Vec4){ 1, 1, 1, 1 });
            assert(batch.cast_shadow && !batch.receive_shadow && !batch.trace);
            assert(batch.fade.start == 10 && batch.fade.end == 20);
            assert(restored.local.position == (Vec3){ 3, -1, 5 } && restored.layers == 5);

            assert(!batch.quadtree.parents.len && !batch.quadtree.leaves.len && !batch.quadtree.revision);
            assert(batch.quadtree.split_pixels == 0 && batch.quadtree.hysteresis == 0);
            assert(batch.is_leaf(0) && batch.leaf_instances() == 5);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_instanced_codec_layout_fingerprints() @test {
    describe::register_core_values()!!;
    describe::register_reflected(InstanceAuthoringV1)!!;
    describe::register_reflected(InstanceAuthoringV2)!!;
    describe::register_reflected(InstanceAuthoringV3)!!;
    describe::register_reflected(InstanceAuthoring)!!;
    assert(serial::description_layout(describe::get(InstanceAuthoringV1)!!)!! == 0x59d3aec48200fec8);
    assert(serial::description_layout(describe::get(InstanceAuthoringV2)!!)!! == 0x7f422a9bb5bb80ce);
    assert(serial::description_layout(describe::get(InstanceAuthoringV3)!!)!! == 0x5d8d9a7cc4cd085d);
    assert(serial::description_layout(describe::get(InstanceAuthoring)!!)!! == 0x538fec02e9ba976c);
}

fn void test_instanced_v2_fixtures_read_the_quadtree_without_trace_sway() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;

        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = fixture.assets.add_geometry(&geometry, "instances_v2/box")!!;
        MaterialId material_id = fixture.assets.add_material(material::basic({}), "instances_v2/material")!!;

        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, INSTANCES_V2_BINARY)!!
              : serial::read_subtree_text(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    text: (String)INSTANCES_V2_TEXT,
                )!!;
            InstancedMesh* batch = fixture.destination.get(restored, InstancedMesh);
            assert(batch.count == 5 && batch.transforms.len == 6 && batch.colors.len == 6);
            assert(c3d::same_id(batch.geometry, geometry_id) && c3d::same_id(batch.material, material_id));
            assert(batch.transforms[4].position == (Vec3){ 4, 0, -4 });
            assert(batch.cast_shadow && !batch.receive_shadow && !batch.trace && !batch.trace_sway);
            assert(batch.fade.start == 10 && batch.fade.end == 20);
            assert(restored.local.position == (Vec3){ 3, -1, 5 } && restored.layers == 5);

            uint[5] parents = { scene::QUADTREE_ROOT, 0, 0, 0, 0 };
            assert(batch.quadtree.parents == parents[..]);
            assert(batch.quadtree.split_pixels == 96 && batch.quadtree.hysteresis == 0.25f);
            assert(!batch.is_leaf(0) && batch.is_leaf(4) && batch.leaf_instances() == 4);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_instanced_v3_fixtures_read_box_ranges_as_sphere_pixels() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;

        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        GeometryId geometry_id = fixture.assets.add_geometry(&geometry, "instances_v3/box")!!;
        MaterialId material_id = fixture.assets.add_material(material::basic({}), "instances_v3/material")!!;

        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, INSTANCES_V3_BINARY)!!
              : serial::read_subtree_text(
                    scene: &fixture.destination,
                    assets: &fixture.assets,
                    text: (String)INSTANCES_V3_TEXT,
                )!!;
            InstancedMesh* batch = fixture.destination.get(restored, InstancedMesh);
            assert(batch.count == 5 && batch.transforms.len == 6 && batch.colors.len == 6);
            assert(c3d::same_id(batch.geometry, geometry_id) && c3d::same_id(batch.material, material_id));
            assert(batch.cast_shadow && !batch.receive_shadow && !batch.trace && batch.trace_sway);
            assert(batch.fade.start == 10 && batch.fade.end == 20);

            uint[5] parents = { scene::QUADTREE_ROOT, 0, 0, 0, 0 };
            assert(batch.quadtree.parents == parents[..]);
            assert(batch.quadtree.split_pixels == 96 && batch.quadtree.hysteresis == 0.25f);
            assert(batch.quadtree.metric == QuadtreeMetric.SPHERE_PIXELS && batch.quadtree.morph_band == 0);
            fixture.destination.remove(restored);
        }
    };
}
