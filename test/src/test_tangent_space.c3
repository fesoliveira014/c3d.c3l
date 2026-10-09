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
const char[] CURATED_STAGES @local = $embed("../fixtures/tangent_space/curated.stages.bin");

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

fn uint take_u32(char[] bytes, usz* offset) @local {
    assert(*offset <= bytes.len - uint::size);

    uint value;
    mem::copy(&value, &bytes[*offset], uint::size);
    *offset += uint::size;

    return value;
}

fn MikkFullMesh take_mesh(char[] bytes, usz* offset) @local {
    uint vertex_count = take_u32(bytes, offset);
    uint face_count = take_u32(bytes, offset);
    uint uv_set = take_u32(bytes, offset);
    MikkVertex[] vertices = alloc::new_array(tmem, MikkVertex, vertex_count);
    mem::copy(vertices.ptr, &bytes[*offset], vertices.len * MikkVertex::size);
    *offset += vertices.len * MikkVertex::size;
    int[] sizes = alloc::new_array(tmem, int, face_count);
    mem::copy(sizes.ptr, &bytes[*offset], sizes.len * int::size);
    *offset += sizes.len * int::size;
    int[] offsets = alloc::new_array(tmem, int, face_count);
    int corner_count = 0;

    foreach (face, size : sizes) {
        offsets[face] = corner_count;
        corner_count += size;
    }

    uint[] indices = alloc::new_array(tmem, uint, corner_count);
    mem::copy(indices.ptr, &bytes[*offset], indices.len * uint::size);
    *offset += indices.len * uint::size;

    return {
        .vertices = vertices,
        .indices = indices,
        .face_offsets = offsets,
        .face_sizes = sizes,
        .uv_set = uv_set,
    };
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
    assert(actual.sign == expected.sign);
    assert(geometry::mikk_finite_vector(actual.direction));

    double[3] first = { actual.direction.x, actual.direction.y, actual.direction.z };
    double[3] second = { expected.direction.x, expected.direction.y, expected.direction.z };
    double first_squared = first[0] * first[0] + first[1] * first[1] + first[2] * first[2];
    double second_squared = second[0] * second[0] + second[1] * second[1] + second[2] * second[2];

    if (second_squared == 0) {
        assert(first_squared == 0);

        return;
    }

    assert(first_squared > 0);

    double first_length = math::sqrt(first_squared);
    double second_length = math::sqrt(second_squared);

    for (int i = 0; i < 3; i++) {
        first[i] /= first_length;
        second[i] /= second_length;
    }

    double[3] cross = {
        first[1] * second[2] - first[2] * second[1],
        first[2] * second[0] - first[0] * second[2],
        first[0] * second[1] - first[1] * second[0],
    };

    double cosine = first[0] * second[0] + first[1] * second[1] + first[2] * second[2];
    double sine = math::sqrt(cross[0] * cross[0] + cross[1] * cross[1] + cross[2] * cross[2]);
    double angle = math::atan2(sine, cosine);

    assert(math::is_finite(angle) && angle <= 1e-4);
    assert(geometry::mikk_equal_vectors(actual.direction, expected.direction));
}

fn Geometry mesh_geometry(MikkFullMesh mesh) @local {
    Geometry source = {
        .positions = alloc::new_array(tmem, Vec3, mesh.vertices.len),
        .normals = alloc::new_array(tmem, Vec3, mesh.vertices.len),
        .uv0 = alloc::new_array(tmem, Vec2, mesh.vertices.len),
        .uv1 = alloc::new_array(tmem, Vec2, mesh.vertices.len),
        .indices = mesh.indices,
    };

    foreach (index, vertex : mesh.vertices) {
        source.positions[index] = { vertex.position.x, vertex.position.y, vertex.position.z };
        source.normals[index] = { vertex.normal.x, vertex.normal.y, vertex.normal.z };
        source.uv0[index] = { vertex.uv0[0], vertex.uv0[1] };
        source.uv1[index] = { vertex.uv1[0], vertex.uv1[1] };
    }

    source.finalize();

    return source;
}

fn void compare_stages(MikkFullMesh source, char[] bytes, usz* offset) @local {
    uint triangle_count = take_u32(bytes, offset);
    uint expected_good = take_u32(bytes, offset);
    MikkTriangle[] triangles = alloc::new_array(tmem, MikkTriangle, triangle_count);

    assert(geometry::mikk_initialize_faces(triangles, source) == (int)triangle_count);

    int[] welded = alloc::new_array(tmem, int, (sz)triangle_count * 3);

    foreach (face, triangle : triangles) {
        for (int corner = 0; corner < 3; corner++) welded[face * 3 + corner] = triangle.vertices[corner];
    }

    geometry::mikk_weld_vertices(tmem, welded, source)!!;

    assert(mem::equals(((char*)welded.ptr)[:welded.len * int::size], bytes[*offset:welded.len * int::size]));

    *offset += welded.len * int::size;

    foreach (face, &triangle : triangles) {
        for (int corner = 0; corner < 3; corner++) triangle.vertices[corner] = welded[face * 3 + corner];
    }

    int good_count = geometry::mikk_mark_and_pack_degenerates(triangles, source);

    assert(good_count == (int)expected_good);

    MikkTriangle[] good = triangles[:good_count];

    foreach (&triangle : good) geometry::mikk_initialize_triangle(triangle, source);
    geometry::mikk_force_quad_orientation(good, source);
    geometry::mikk_build_neighbors(tmem, good)!!;

    foreach (triangle : good) {
        int[12] record = {
            triangle.face, triangle.output_offset,
            triangle.vertex_numbers[0], triangle.vertex_numbers[1], triangle.vertex_numbers[2],
            triangle.vertices[0], triangle.vertices[1], triangle.vertices[2],
            triangle.neighbors[0], triangle.neighbors[1], triangle.neighbors[2], triangle.flags,
        };

        assert(mem::equals(((char*)&record)[:@sizeof(record)], bytes[*offset:@sizeof(record)]));

        *offset += @sizeof(record);
    }
}

fn void test_pinned_tangents_and_intermediate_stages() @test {
    @pool() {
        usz input_offset = 0;
        usz expected_offset = 0;
        usz stage_offset = 0;

        assert(take_u32(CURATED_INPUT, &input_offset) == 0x4d4b5032);

        uint count = take_u32(CURATED_INPUT, &input_offset);

        assert(count == 31);
        assert(take_u32(CURATED_EXPECTED, &expected_offset) == 0x4d4b5032);
        assert(take_u32(CURATED_EXPECTED, &expected_offset) == count);
        assert(take_u32(CURATED_STAGES, &stage_offset) == 0x53544732);
        assert(take_u32(CURATED_STAGES, &stage_offset) == count);

        for (uint case_index = 0; case_index < count; case_index++) {
            MikkFullMesh mesh = take_mesh(CURATED_INPUT, &input_offset);
            MikkTangent[] expected = take_expected(CURATED_EXPECTED, &expected_offset);
            MikkTangent[] actual = geometry::mikk_generate_full(tmem, mesh)!!;

            assert(actual.len == expected.len);

            foreach (corner, tangent : actual) compare_tangent(tangent, expected[corner]);

            compare_stages(mesh, CURATED_STAGES, &stage_offset);

            bool triangles_only = true;

            foreach (size : mesh.face_sizes) if (size != 3) triangles_only = false;

            if (!triangles_only) continue;

            Geometry source = mesh_geometry(mesh);

            TangentGeometry owner = geometry::create_tangent_geometry(mem, &source, mesh.uv_set)!!;
            defer geometry::destroy_tangent_geometry(&owner);

            assert(owner.tangent_provenance.origin == TangentOrigin.GENERATED);
            assert(owner.tangent_provenance.uv_set == mesh.uv_set);
            assert(owner.tangent_provenance.derivation_revision == 0);

            foreach (corner, index : owner.data.indices) {
                Vec4 tangent = owner.data.tangents[index];

                compare_tangent({
                    .direction = { .x = tangent.x, .y = tangent.y, .z = tangent.z },
                    .sign = tangent.w,
                }, expected[corner]);

                assert(owner.data.positions[index] == source.positions[source.indices[corner]]);
            }
        }

        assert(input_offset == CURATED_INPUT.len && expected_offset == CURATED_EXPECTED.len
          && stage_offset == CURATED_STAGES.len);
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
            TangentGeometry owner = geometry::create_tangent_geometry(&tracker, &source)!!;
            defer geometry::destroy_tangent_geometry(&owner);

            TangentGeometry repeated = geometry::create_tangent_geometry(&tracker, &source)!!;
            defer geometry::destroy_tangent_geometry(&repeated);

            assert(owner.data.positions.len == 6 && owner.data.indices.len == source.indices.len);
            assert(owner.data.indices == repeated.data.indices && owner.data.tangents == repeated.data.tangents);
            assert(owner.data.indices[0] != owner.data.indices[3] && owner.data.indices[2] != owner.data.indices[4]);
            assert(source.positions.len == 4 && source.indices == (uint[6]){ 0, 1, 2, 0, 2, 3 }[..]);
            assert(!source.tangents.len && owner.data.positions.ptr != source.positions.ptr);

            foreach (corner, destination : owner.data.indices) {
                uint original = source.indices[corner];

                assert(owner.data.positions[destination] == source.positions[original]);
                assert(owner.data.normals[destination] == source.normals[original]);
                assert(owner.data.uv0[destination] == source.uv0[original]);
                assert(owner.data.uv1[destination] == source.uv1[original]);
                assert(owner.data.colors[destination] == source.colors[original]);
                assert(owner.data.joints[destination] == source.joints[original]);
                assert(owner.data.weights[destination] == source.weights[original]);
                assert(owner.data.custom_data[(usz)destination * 7:7] == source.custom_data[(usz)original * 7:7]);

                foreach (index, target : owner.data.targets) {
                    assert(target.position_deltas[destination] == source.targets[index].position_deltas[original]);
                    assert(target.normal_deltas[destination] == source.targets[index].normal_deltas[original]);
                    assert(target.name == source.targets[index].name && target.name.ptr != source.targets[index].name.ptr);
                }
            }

            assert(owner.data.custom_stride == source.custom_stride
              && owner.data.bounds.min == source.bounds.min && owner.data.bounds.max == source.bounds.max);
            assert(owner.data.channels[0].name == source.channels[0].name
              && owner.data.channels[0].name.ptr != source.channels[0].name.ptr);
            assert(owner.data.channels[0].full_weights == source.channels[0].full_weights
              && owner.data.channels[0].full_weights.ptr != source.channels[0].full_weights.ptr);
            assert(owner.data.channels[0].first_target == source.channels[0].first_target);
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

            TangentGeometry? result = geometry::create_tangent_geometry(&failing, &source);

            if (catch excuse = result) {
                assert(excuse == c3d::CAPACITY_EXCEEDED);
            } else {
                TangentGeometry owner = result;

                geometry::destroy_tangent_geometry(&owner);

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
        source.normals = {};

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::INVALID_ARGUMENT);

        source = valid;
        source.uv0 = {};

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::UNSUPPORTED);
        assert(@catch(geometry::create_tangent_geometry(mem, &valid, 2)) == c3d::UNSUPPORTED);

        source = valid;
        source.topology = Topology.LINES;

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::UNSUPPORTED);

        source = valid;
        source.indices = source.indices[:5];

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::INVALID_ARGUMENT);

        source = valid;
        source.uv0 = source.uv0[:3];

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::INVALID_ARGUMENT);

        source = valid;
        uint original = source.indices[0];
        source.indices[0] = 4;

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::INVALID_ARGUMENT);

        source.indices[0] = original;
        source = valid;
        source.custom_stride = 7;
        source.custom_data = alloc::new_array(tmem, char, 27);

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::INVALID_ARGUMENT);

        source = valid;
        Vec3 original_position = source.positions[0];
        source.positions[0].x = float::inf;

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::INVALID_ARGUMENT);

        source.positions[0] = original_position;
        source = valid;
        source.positions = source.positions.ptr[:(usz)uint::max + 1];
        source.normals = source.normals.ptr[:(usz)uint::max + 1];
        source.uv0 = source.uv0.ptr[:(usz)uint::max + 1];

        assert(@catch(geometry::create_tangent_geometry(mem, &source)) == c3d::INVALID_ARGUMENT);

        source = valid;
        source.tangents = alloc::new_array(tmem, Vec4, 1);
        source.tangents[0] = { 0, 0, 0, 0 };

        TangentGeometry owner = geometry::create_tangent_geometry(mem, &source)!!;
        defer geometry::destroy_tangent_geometry(&owner);

        assert(owner.data.positions.len == 6 && source.tangents.len == 1 && source.tangents[0].w == 0);
    };
}

fn void test_tangent_generation_has_no_small_mesh_cap_and_preserves_nonindexed_topology() @test {
    @pool() {
        Geometry source = mirrored_geometry();
        source.indices = alloc::new_array(tmem, uint, 600 * 3);

        foreach (corner, &index : source.indices) *index = (uint)(corner % 3);

        TangentGeometry owner = geometry::create_tangent_geometry(mem, &source)!!;
        defer geometry::destroy_tangent_geometry(&owner);

        assert(owner.data.indices.len == 1800 && owner.data.positions.len == 4);

        foreach (index : owner.data.indices) assert(owner.data.tangents[index] == (Vec4){ 1, 0, 0, 1 });

        source = mirrored_geometry();
        source.positions = source.positions[:3];
        source.normals = source.normals[:3];
        source.uv0 = source.uv0[:3];
        source.indices = {};

        TangentGeometry nonindexed = geometry::create_tangent_geometry(mem, &source)!!;
        defer geometry::destroy_tangent_geometry(&nonindexed);

        assert(!nonindexed.data.indices.len && nonindexed.data.positions.len == 3);
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

        assert(record.tangent_provenance.origin == TangentOrigin.AUTHORED);
        assert(record.data.tangents[0] == (Vec4){ 2, 3, 4, -1 });
        assert(record.data.tangents[1] == (Vec4){ 5, 6, 7, 1 });
        assert(source.tangents[0].w == -8 && source.tangents[1].w == 3);

        uint revision = record.header.revision;
        source.tangents[0] = { 0, 0, 0, 1 };

        assert(@catch(assets.replace_geometry(id, &source)) == c3d::INVALID_ARGUMENT);
        assert(record.header.revision == revision && record.data.tangents[0] == (Vec4){ 2, 3, 4, -1 });

        source.tangents[0] = { 1, 0, 0, 0 };

        assert(@catch(assets.add_geometry(&source)) == c3d::INVALID_ARGUMENT);

        source.tangents[0] = { 1, 0, 0, float::inf };

        assert(@catch(assets.add_geometry(&source)) == c3d::INVALID_ARGUMENT);
    };
}

fn void test_generated_tangent_publication_ownership_revision_and_release() @test {
    @pool() {
        Geometry source = all_stream_geometry();
        TrackingAllocator tracker;
        tracker.init(mem);
        defer tracker.free();

        {
            AssetStoreDesc desc = asset::default_asset_store_desc();
            desc.max_geometries = 1;

            AssetStore assets = asset::create_asset_store(&tracker, desc);
            defer asset::destroy_asset_store(&assets);

            TangentGeometry owner = geometry::create_tangent_geometry(&tracker, &source)!!;
            defer geometry::destroy_tangent_geometry(&owner);

            Vec3* transferred = owner.data.positions.ptr;

            GeometryId id = assets.add_tangent_geometry_owned(&owner, "generated")!!;

            assert(!owner.data.positions.len && owner.allocator == null);

            GeometryAsset* record = assets.geometry(id);

            assert(record.data.positions.ptr == transferred && record.joints_u16);
            assert(record.skin_bounds.joints.len > 0 && record.morph_bounds.len == 2);
            assert(record.tangent_provenance.origin == TangentOrigin.GENERATED
              && record.tangent_provenance.derivation_revision == record.header.revision);

            TangentGeometry capacity = geometry::create_tangent_geometry(&tracker, &source)!!;
            defer geometry::destroy_tangent_geometry(&capacity);

            Vec3* retained = capacity.data.positions.ptr;

            assert(@catch(assets.add_tangent_geometry_owned(&capacity, "other")) == c3d::CAPACITY_EXCEEDED);
            assert(capacity.data.positions.ptr == retained && record.header.revision == 1);

            Geometry incompatible = mirrored_geometry();

            TangentGeometry replacement = geometry::create_tangent_geometry(&tracker, &incompatible)!!;
            defer geometry::destroy_tangent_geometry(&replacement);

            retained = replacement.data.positions.ptr;

            assert(@catch(assets.replace_tangent_geometry_owned(id, &replacement)) == c3d::INCOMPATIBLE_STRUCTURE);
            assert(replacement.data.positions.ptr == retained && record.data.positions.ptr == transferred);

            assets.replace_tangent_geometry_owned(id, &capacity)!!;

            assert(!capacity.data.positions.len && record.header.revision == 2
              && record.tangent_provenance.derivation_revision == 2);

            assets.mark_geometry_dirty(id);

            assert(record.header.revision == 3 && record.tangent_provenance.derivation_revision == 2);

            assets.regenerate_geometry_tangents(id, 1)!!;

            assert(record.header.revision == 4 && record.tangent_provenance.derivation_revision == 4
              && record.tangent_provenance.uv_set == 1);

            TangentProvenance before_release = record.tangent_provenance;
            assets.release_geometry_cpu(id);

            assert(!record.data.positions.len
              && record.tangent_provenance.origin == before_release.origin
              && record.tangent_provenance.uv_set == before_release.uv_set
              && record.tangent_provenance.derivation_revision == before_release.derivation_revision);

            assets.mark_geometry_dirty(id);

            assert(record.header.revision == 5 && record.tangent_provenance.derivation_revision == 4);
            assert(@catch(assets.regenerate_geometry_tangents(id)) == c3d::ASSET_DATA_UNAVAILABLE);
            assert(@catch(assets.regenerate_geometry_tangents((GeometryId){})) == c3d::INVALID_ID);
        }

        assert(!tracker.has_leaks());
    };
}

fn void test_generated_reference_zero_directions_publish_with_their_origin() @test {
    @pool() {
        usz input_offset = 8;
        MikkFullMesh mesh;

        for (uint index = 0; index <= 6; index++) mesh = take_mesh(CURATED_INPUT, &input_offset);

        Geometry source = mesh_geometry(mesh);

        AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);

        TangentGeometry owner = geometry::create_tangent_geometry(mem, &source, mesh.uv_set)!!;
        defer geometry::destroy_tangent_geometry(&owner);

        bool zero_found = false;

        foreach (tangent : owner.data.tangents) {
            if (tangent.x == 0 && tangent.y == 0 && tangent.z == 0) zero_found = true;
        }

        assert(zero_found);
        assert(@catch(assets.add_geometry(&owner.data)) == c3d::INVALID_ARGUMENT);

        GeometryId id = assets.add_tangent_geometry_owned(&owner)!!;

        assert(assets.geometry(id).tangent_provenance.origin == TangentOrigin.GENERATED);

        assets.release_geometry_cpu(id);

        assert(@catch(assets.regenerate_geometry_tangents(id)) == c3d::ASSET_DATA_UNAVAILABLE);

        Geometry empty;

        GeometryId empty_id = assets.add_geometry(&empty)!!;

        assert(@catch(assets.regenerate_geometry_tangents(empty_id)) == c3d::INVALID_ARGUMENT);
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

        TangentGeometry owner = geometry::create_tangent_geometry(mem, &source)!!;
        defer geometry::destroy_tangent_geometry(&owner);

        assert(owner.data.positions.len == 6 && owner.data.indices == indices);
        assert(owner.data.colors == colors && owner.data.colors.ptr != colors.ptr);
    };
}
