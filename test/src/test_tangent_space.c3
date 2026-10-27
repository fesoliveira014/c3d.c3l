module c3d::test::tangent_space;

import c3d;
import c3d::asset;
import c3d::geometry @public;
import c3d::maths;
import std::core::mem;
import std::core::mem::alloc;
import std::core::mem::allocators;
import std::math;

const char[] CURATED_INPUT @local = $embed("../fixtures/tangent_space/curated.input.bin");
const char[] CURATED_EXPECTED @local = $embed("../fixtures/tangent_space/curated.expected.bin");

struct CuratedVertex @local {
    float[3] position;
    float[3] normal;
    float[2] uv0;
    float[2] uv1;
}

struct TangentFaultAllocator (Allocator) @local {
    Allocator allocator;
    int attempt;
    int fail_at;
}

fn void*? TangentFaultAllocator.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.attempt++ == self.fail_at) return mem::OUT_OF_MEMORY~;

    return self.allocator.acquire(size, init_type, alignment);
}

fn void*? TangentFaultAllocator.resize(
    &self,
    void* pointer,
    sz new_size,
    sz alignment,
) @dynamic {
    if (self.attempt++ == self.fail_at) return mem::OUT_OF_MEMORY~;

    return self.allocator.resize(pointer, new_size, alignment);
}

fn void TangentFaultAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.allocator.release(pointer, aligned);
}

fn sz tangent_allocation_bytes(TrackingAllocator* tracker, void* pointer) @local {
    foreach (allocation : tracker.allocations_tlist()) {
        if (allocation.ptr == pointer) return allocation.size;
    }

    unreachable();
}

fn uint take_u32(char[] bytes, usz* offset) @local {
    assert(*offset <= bytes.len - uint::size);

    uint value;
    mem::copy(&value, &bytes[*offset], uint::size);
    *offset += uint::size;

    return value;
}

fn Geometry take_mesh(char[] bytes, usz* offset, uint* uv_set) @local {
    uint vertex_count = take_u32(bytes, offset);
    uint face_count = take_u32(bytes, offset);
    *uv_set = take_u32(bytes, offset);

    CuratedVertex[] vertices = alloc::new_array(tmem, CuratedVertex, vertex_count);
    mem::copy(vertices.ptr, &bytes[*offset], vertices.len * CuratedVertex::size);
    *offset += vertices.len * CuratedVertex::size;

    for (uint face = 0; face < face_count; face++) assert(take_u32(bytes, offset) == 3);

    uint[] indices = alloc::new_array(tmem, uint, (sz)face_count * 3);
    mem::copy(indices.ptr, &bytes[*offset], indices.len * uint::size);
    *offset += indices.len * uint::size;

    Geometry source = {
        .positions = alloc::new_array(tmem, Vec3, vertex_count),
        .normals = alloc::new_array(tmem, Vec3, vertex_count),
        .uv0 = alloc::new_array(tmem, Vec2, vertex_count),
        .uv1 = alloc::new_array(tmem, Vec2, vertex_count),
        .indices = indices,
    };

    foreach (index, vertex : vertices) {
        source.positions[index] = { vertex.position[0], vertex.position[1], vertex.position[2] };
        source.normals[index] = { vertex.normal[0], vertex.normal[1], vertex.normal[2] };
        source.uv0[index] = { vertex.uv0[0], vertex.uv0[1] };
        source.uv1[index] = { vertex.uv1[0], vertex.uv1[1] };
    }

    source.finalize();

    return source;
}

fn MikkFullMesh mikk_mesh(Geometry* source, uint uv_set) @local {
    MikkVertex[] vertices = alloc::new_array(tmem, MikkVertex, source.positions.len);
    Vec2[] selected = uv_set == 0 ? source.uv0 : source.uv1;

    foreach (index, position : source.positions) {
        Vec3 normal = source.normals[index];
        vertices[index] = {
            .position = { .x = position.x, .y = position.y, .z = position.z },
            .normal = { .x = normal.x, .y = normal.y, .z = normal.z },
            .uv = { selected[index].x, selected[index].y },
        };
    }

    return { .vertices = vertices, .indices = source.indices };
}

fn MikkTangent[] take_expected(char[] bytes, usz* offset) @local {
    assert(take_u32(bytes, offset) == 1);

    uint count = take_u32(bytes, offset);
    MikkTangent[] tangents = alloc::new_array(tmem, MikkTangent, count);
    mem::copy(tangents.ptr, &bytes[*offset], tangents.len * MikkTangent::size);
    *offset += tangents.len * MikkTangent::size;

    return tangents;
}

fn void compare_tangent(MikkTangent actual, MikkTangent expected) @local {
    assert(actual.sign == expected.sign && geometry::mikk_equal_vectors(actual.direction, expected.direction));
}

fn void test_pinned_tangents_match_curated_corpus() @test {
    @pool() {
        usz input_offset = 0;
        usz expected_offset = 0;

        assert(take_u32(CURATED_INPUT, &input_offset) == 0x4d4b5032);

        uint count = take_u32(CURATED_INPUT, &input_offset);

        assert(count == 27);
        assert(take_u32(CURATED_EXPECTED, &expected_offset) == 0x4d4b5032);
        assert(take_u32(CURATED_EXPECTED, &expected_offset) == count);

        for (uint case_index = 0; case_index < count; case_index++) {
            uint uv_set;
            Geometry source = take_mesh(CURATED_INPUT, &input_offset, &uv_set);
            MikkTangent[] expected = take_expected(CURATED_EXPECTED, &expected_offset);
            MikkTangent[] actual = geometry::mikk_generate_full(tmem, mikk_mesh(&source, uv_set))!!;

            assert(actual.len == expected.len);

            foreach (corner, tangent : actual) compare_tangent(tangent, expected[corner]);

            Geometry generated = geometry::create_tangent_geometry(mem, &source, uv_set)!!;
            defer asset::free_geometry(mem, &generated);

            foreach (corner, index : generated.indices) {
                Vec4 tangent = generated.tangents[index];

                compare_tangent({
                    .direction = { .x = tangent.x, .y = tangent.y, .z = tangent.z },
                    .sign = tangent.w,
                }, expected[corner]);

                assert(generated.positions[index] == source.positions[source.indices[corner]]);
            }
        }

        assert(input_offset == CURATED_INPUT.len && expected_offset == CURATED_EXPECTED.len);
    };
}

fn Geometry mirrored_geometry() @local {
    Vec3[] positions = alloc::new_array(tmem, Vec3, 4);
    positions[..] = (Vec3[4]){ { 0, 0, 0 }, { 1, 0, 0 }, { 0, 1, 0 }, { -1, 0, 0 } }[..];
    Vec3[] normals = alloc::new_array(tmem, Vec3, 4);
    normals[..] = (Vec3){ 0, 0, 1 };
    Vec2[] uv0 = alloc::new_array(tmem, Vec2, 4);
    uv0[..] = (Vec2[4]){ { 0, 0 }, { 1, 0 }, { 0, 1 }, { 1, 0 } }[..];
    uint[] indices = alloc::new_array(tmem, uint, 6);
    indices[..] = (uint[6]){ 0, 1, 2, 0, 2, 3 }[..];
    Geometry source = { .positions = positions, .normals = normals, .uv0 = uv0, .indices = indices };
    source.finalize();

    return source;
}

fn Geometry all_stream_geometry() @local {
    Geometry source = mirrored_geometry();
    source.uv1 = alloc::new_array(tmem, Vec2, 4);
    source.colors = alloc::new_array(tmem, Vec4, 4);
    source.joints = alloc::new_array(tmem, ushort[<4>], 4);
    source.weights = alloc::new_array(tmem, Vec4, 4);
    source.targets = alloc::new_array(tmem, MorphTarget, 2);
    source.channels = alloc::new_array(tmem, MorphChannel, 1);
    source.custom_stride = 7;
    source.custom_data = alloc::new_array(tmem, char, 4 * 7);

    foreach (vertex, position : source.positions) {
        source.uv1[vertex] = { position.x, position.y };
        source.colors[vertex] = { (float)vertex, 0.25f, 0.75f, 1 };
        source.joints[vertex] = { (ushort)(300 + vertex), 1, 2, 65535 };
        source.weights[vertex] = { 0.75f, 0.25f, 0, 0 };

        for (usz byte = 0; byte < 7; byte++) source.custom_data[(usz)vertex * 7 + byte] = (char)((usz)vertex * 7 + byte);
    }

    foreach (target_index, &target : source.targets) {
        target.position_deltas = alloc::new_array(tmem, Vec3, 4);
        target.normal_deltas = alloc::new_array(tmem, Vec3, 4);
        target.name = target_index == 0 ? "shape_a" : "shape_b";

        foreach (vertex, &delta : target.position_deltas) {
            *delta = { (float)vertex, (float)target_index, 0.5f };
            target.normal_deltas[vertex] = { 0.25f, (float)vertex, (float)target_index };
        }
    }

    float[] full_weights = alloc::new_array(tmem, float, 2);
    full_weights[..] = (float[2]){ 0.25f, 0.75f }[..];
    source.channels[0] = { .name = "expression", .first_target = 0, .full_weights = full_weights };

    return source;
}

fn void test_tangent_splits_copy_every_stream_without_merging_source_vertices() @test {
    @pool() {
        Geometry source = all_stream_geometry();
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();

        {
            Geometry owner = geometry::create_tangent_geometry(&tracker, &source)!!;
            defer asset::free_geometry(&tracker, &owner);

            Geometry repeated = geometry::create_tangent_geometry(&tracker, &source)!!;
            defer asset::free_geometry(&tracker, &repeated);

            assert(owner.positions.len == 6 && owner.indices.len == source.indices.len);
            assert(owner.indices == repeated.indices && owner.tangents == repeated.tangents);
            assert(owner.indices[0] != owner.indices[3] && owner.indices[2] != owner.indices[4]);
            assert(source.positions.len == 4 && source.indices == (uint[6]){ 0, 1, 2, 0, 2, 3 }[..]);
            assert(!source.tangents.len && owner.positions.ptr != source.positions.ptr);
            assert(tangent_allocation_bytes(&tracker, owner.tangents.ptr)
              == (sz)(owner.positions.len * Vec4::size));
            assert(tangent_allocation_bytes(&tracker, repeated.tangents.ptr)
              == (sz)(repeated.positions.len * Vec4::size));

            foreach (corner, destination : owner.indices) {
                uint original = source.indices[corner];

                assert(owner.positions[destination] == source.positions[original]);
                assert(owner.normals[destination] == source.normals[original]);
                assert(owner.uv0[destination] == source.uv0[original]);
                assert(owner.uv1[destination] == source.uv1[original]);
                assert(owner.colors[destination] == source.colors[original]);
                assert(owner.joints[destination] == source.joints[original]);
                assert(owner.weights[destination] == source.weights[original]);
                assert(owner.custom_data[(usz)destination * 7:7] == source.custom_data[(usz)original * 7:7]);

                foreach (index, target : owner.targets) {
                    assert(target.position_deltas[destination] == source.targets[index].position_deltas[original]);
                    assert(target.normal_deltas[destination] == source.targets[index].normal_deltas[original]);
                    assert(target.name == source.targets[index].name && target.name.ptr != source.targets[index].name.ptr);
                }
            }

            assert(owner.custom_stride == source.custom_stride
              && owner.bounds.min == source.bounds.min && owner.bounds.max == source.bounds.max);
            assert(owner.channels[0].name == source.channels[0].name
              && owner.channels[0].name.ptr != source.channels[0].name.ptr);
            assert(owner.channels[0].full_weights == source.channels[0].full_weights
              && owner.channels[0].full_weights.ptr != source.channels[0].full_weights.ptr);
            assert(owner.channels[0].first_target == source.channels[0].first_target);
        }

        assert(!tracker.has_leaks());
    };
}

fn void test_tangent_generation_is_atomic_at_every_allocation_failure() @test {
    @pool() {
        Geometry source = all_stream_geometry();
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();

        bool succeeded = false;

        for (int fail_at = 0; fail_at < 128; fail_at++) {
            TangentFaultAllocator failing = { .allocator = &tracker, .fail_at = fail_at };

            Geometry? result = geometry::create_tangent_geometry(&failing, &source);

            if (catch excuse = result) {
                assert(excuse == c3d::CAPACITY_EXCEEDED);
            } else {
                Geometry generated = result;

                asset::free_geometry(&failing, &generated);

                succeeded = true;
            }

            assert(!tracker.has_leaks());
            assert(source.positions.len == 4 && !source.tangents.len && source.indices[3] == 0);
            assert(source.channels[0].name == "expression" && source.channels[0].full_weights[1] == 0.75f);
            assert(source.targets[1].position_deltas[3] == (Vec3){ 3, 1, 0.5f });
            assert(source.custom_data[27] == 27);

            if (succeeded) break;
        }

        assert(succeeded);
    };
}

fn void test_tangent_generation_validates_real_inputs_and_discards_old_tangents() @test {
    @pool() {
        Geometry valid = mirrored_geometry();
        Geometry source = valid;
        source.indices = source.indices[:5];

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::INVALID_ARGUMENT);

        source = valid;
        source.uv0 = {};

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::UNSUPPORTED);

        source = valid;
        source.tangents = alloc::new_array(tmem, Vec4, 1);
        source.tangents[0] = { 0, 0, 0, 0 };

        Geometry generated = geometry::create_tangent_geometry(mem, &source)!!;
        defer asset::free_geometry(mem, &generated);

        assert(generated.positions.len == 6 && source.tangents.len == 1 && source.tangents[0].w == 0);
    };
}

fn void test_tangent_generation_has_no_small_mesh_cap_and_preserves_nonindexed_topology() @test {
    @pool() {
        Geometry source = mirrored_geometry();
        source.indices = alloc::new_array(tmem, uint, 600 * 3);

        foreach (corner, &index : source.indices) *index = (uint)(corner % 3);

        Geometry generated = geometry::create_tangent_geometry(mem, &source)!!;
        defer asset::free_geometry(mem, &generated);

        assert(generated.indices.len == 1800 && generated.positions.len == 4);

        foreach (index : generated.indices) assert(generated.tangents[index] == (Vec4){ 1, 0, 0, 1 });

        source = mirrored_geometry();
        source.positions = source.positions[:3];
        source.normals = source.normals[:3];
        source.uv0 = source.uv0[:3];
        source.indices = {};

        Geometry nonindexed = geometry::create_tangent_geometry(mem, &source)!!;
        defer asset::free_geometry(mem, &nonindexed);

        assert(!nonindexed.indices.len && nonindexed.positions.len == 3);
    };
}

fn void test_authored_tangents_keep_xyz_and_accept_mixed_nonunit_signs() @test {
    @pool() {
        Geometry source = mirrored_geometry();
        source.tangents = alloc::new_array(tmem, Vec4, 4);
        source.tangents[..] = (Vec4[4]){ { 2, 3, 4, -8 }, { 5, 6, 7, 3 }, { 1, 2, 3, -0.25f }, { 8, 9, 10, 0.5f } }[..];

        AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);

        GeometryId id = assets.add_geometry(&source)!!;

        GeometryAsset* record = assets.geometry(id);

        assert(record.data.tangents[0] == (Vec4){ 2, 3, 4, -1 });
        assert(record.data.tangents[1] == (Vec4){ 5, 6, 7, 1 });
        assert(source.tangents[0].w == -8 && source.tangents[1].w == 3);

        source.tangents[0].x = 7;
        assets.replace_geometry(id, &source)!!;

        assert(record.header.revision == 2);
        assert(record.data.tangents[0] == (Vec4){ 7, 3, 4, -1 });

        uint revision = record.header.revision;
        source.tangents[0] = { float::nan, 0, 0, 1 };

        assert(@catch(assets.replace_geometry(id, &source)) == c3d::INVALID_ARGUMENT);
        assert(record.header.revision == revision && record.data.tangents[0] == (Vec4){ 7, 3, 4, -1 });

        source.tangents[0] = { 1, 0, 0, 0 };

        assert(@catch(assets.add_geometry(&source)) == c3d::INVALID_ARGUMENT);

        source.tangents[0] = { 1, 0, 0, float::inf };

        assert(@catch(assets.add_geometry(&source)) == c3d::INVALID_ARGUMENT);
    };
}

fn void test_generated_geometry_transfers_to_the_store_and_regenerates_explicitly() @test {
    @pool() {
        Geometry source = all_stream_geometry();
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();

        {
            AssetStore assets = asset::create_asset_store(&tracker, asset::default_asset_store_desc());
            defer asset::destroy_asset_store(&assets);

            Geometry generated = geometry::create_tangent_geometry(&tracker, &source)!!;
            Vec3* transferred = generated.positions.ptr;

            GeometryId id = assets.add_geometry_owned(&generated, "generated")!!;
            GeometryAsset* record = assets.geometry(id);

            assert(record.data.positions.ptr == transferred && record.joints_u16);
            assert(record.skin_bounds.joints.len > 0 && record.morph_bounds.len == 2);

            assets.regenerate_geometry_tangents(id, 1)!!;

            assert(record.header.revision == 2 && record.data.tangents.len == record.data.positions.len);

            assets.release_geometry_cpu(id);

            assert(@catch(assets.regenerate_geometry_tangents(id)) == c3d::ASSET_DATA_UNAVAILABLE);
            assert(@catch(assets.regenerate_geometry_tangents((GeometryId){})) == c3d::INVALID_ID);

            Geometry empty;
            GeometryId empty_id = assets.add_geometry(&empty)!!;

            assert(@catch(assets.regenerate_geometry_tangents(empty_id)) == c3d::INVALID_ARGUMENT);
        }

        assert(!tracker.has_leaks());
    };
}

fn void test_generated_zero_directions_publish() @test {
    @pool() {
        usz input_offset = 8;
        uint uv_set;
        Geometry source;

        for (uint index = 0; index <= 6; index++) source = take_mesh(CURATED_INPUT, &input_offset, &uv_set);

        AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);

        Geometry generated = geometry::create_tangent_geometry(mem, &source, uv_set)!!;
        bool zero_found = false;

        foreach (tangent : generated.tangents) {
            if (tangent.x == 0 && tangent.y == 0 && tangent.z == 0) zero_found = true;
        }

        assert(zero_found);

        (void)assets.add_geometry_owned(&generated)!!;
    };
}

fn void test_equal_attributes_do_not_merge_distinct_source_vertices() @test {
    @pool() {
        Geometry source = mirrored_geometry();
        Vec3[] positions = alloc::new_array(tmem, Vec3, 6);
        Vec3[] normals = alloc::new_array(tmem, Vec3, 6);
        Vec2[] uv0 = alloc::new_array(tmem, Vec2, 6);
        Vec4[] colors = alloc::new_array(tmem, Vec4, 6);
        uint[] indices = alloc::new_array(tmem, uint, 6);

        for (uint vertex = 0; vertex < 6; vertex++) {
            positions[vertex] = source.positions[vertex % 3];
            normals[vertex] = source.normals[vertex % 3];
            uv0[vertex] = source.uv0[vertex % 3];
            colors[vertex] = { (float)vertex, 0, 0, 1 };
            indices[vertex] = vertex;
        }

        source = { .positions = positions, .normals = normals, .uv0 = uv0, .colors = colors, .indices = indices };

        Geometry generated = geometry::create_tangent_geometry(mem, &source)!!;
        defer asset::free_geometry(mem, &generated);

        assert(generated.positions.len == 6 && generated.indices == indices);
        assert(generated.colors == colors && generated.colors.ptr != colors.ptr);
    };
}
