module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;

struct ResultFixture @local {
    Vec3[4] positions;
    Vec3[4] normals;
    Vec4[4] tangents;
    Vec2[4] uv0;
    Vec2[4] uv1;
    Vec4[4] colors;
    uint[12] indices;
    uint[4] identities;
    uint[4] materials;
    FracturePieceView piece;
}

fn void test_fracture_result_copies_every_supported_stream_into_one_owner() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    ResultFixture[3] fixtures;
    FracturePieceView[3] sources;
    foreach (uint index, &fixture : fixtures) {
        init_result_fixture(fixture, index);
        sources[index] = fixture.piece;
    }
    FractureResult result = copy_fracture_result(&tracker, sources[..])!!;
    assert(tracker.allocation_count() == 1 && tracker.total_allocation_count() == 1);
    assert((uptr)result.storage.ptr % FracturePieceView::alignment == 0);
    assert(result.pieces.len == sources.len && result.pieces.ptr != &sources[0]);
    assert((uptr)result.pieces.ptr >= (uptr)result.storage.ptr);
    assert((uptr)(result.pieces.ptr + result.pieces.len) <= (uptr)(result.storage.ptr + result.storage.len));
    foreach (uint index, piece : result.pieces) assert_result_piece(result.storage, piece, sources[index]);
    fixtures = {};
    sources = {};
    foreach (uint index, piece : result.pieces) {
        ResultFixture expected;
        init_result_fixture(&expected, index);
        assert_result_piece(result.storage, piece, expected.piece);
    }
    destroy_fracture_result(&result);
    assert(tracker.allocation_count() == 0 && tracker.allocated() == 0);
    assert(!result.storage.ptr && !result.storage.len && !result.pieces.ptr && !result.pieces.len);
    destroy_fracture_result(&result);
    assert(tracker.allocation_count() == 0);
}

fn void test_fracture_result_survives_source_workspace_overwrite_and_destruction() @test {
    FractureWorkspace workspace = cell_workspace();
    SolidScratch scratch = begin_solid_scratch(&workspace);
    ResultFixture fixture;
    init_result_fixture(&fixture, 2);
    FracturePieceView source = fixture.piece;
    source.mesh.geometry.positions = reserve_elements(&scratch, Vec3, fixture.positions.len)!!;
    source.mesh.geometry.positions[..] = fixture.positions[..];
    source.mesh.geometry.indices = reserve_elements(&scratch, uint, fixture.indices.len)!!;
    source.mesh.geometry.indices[..] = fixture.indices[..];
    source.mesh.topology_vertices = reserve_elements(&scratch, uint, fixture.identities.len)!!;
    source.mesh.topology_vertices[..] = fixture.identities[..];
    source.mesh.triangle_materials = reserve_elements(&scratch, uint, fixture.materials.len)!!;
    source.mesh.triangle_materials[..] = fixture.materials[..];
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureResult result = copy_fracture_result(&tracker, (&source)[:1])!!;
    workspace.storage[..] = 0x5a;
    destroy_fracture_workspace(&workspace);
    source = {};
    assert_result_piece(result.storage, result.pieces[0], fixture.piece);
    assert(tracker.allocation_count() == 1 && tracker.total_allocation_count() == 1);
    destroy_fracture_result(&result);
    assert(tracker.allocation_count() == 0);
}

fn void test_fracture_result_empty_success_has_one_minimal_allocation() @test {
    FractureResult cleared;
    destroy_fracture_result(&cleared);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FracturePieceView source;
    FractureResult result = copy_fracture_result(&tracker, (&source)[:0])!!;
    assert(result.storage.ptr && result.storage.len == 1 && !result.pieces.ptr && !result.pieces.len);
    assert((uptr)result.storage.ptr % FracturePieceView::alignment == 0);
    assert(tracker.allocation_count() == 1 && tracker.total_allocation_count() == 1);
    assert(tracker.allocated() == 1);
    destroy_fracture_result(&result);
    assert(!result.storage.ptr && !result.storage.len && !result.pieces.ptr && !result.pieces.len);
    assert(tracker.allocated() == 0 && tracker.allocation_count() == 0);
    destroy_fracture_result(&result);
}

fn void test_fracture_result_allocation_failure_leaves_no_owner() @test {
    NullAllocator unavailable;
    TrackingAllocator tracker;
    tracker.init(mem);
    tracker.inner_allocator = &unavailable;
    defer tracker.free();
    ResultFixture fixture;
    init_result_fixture(&fixture, 0);
    assert(@catch(copy_fracture_result(&tracker, (&fixture.piece)[:1])) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(copy_fracture_result(&tracker, {})) == c3d::CAPACITY_EXCEEDED);
    assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 0);
    assert(tracker.allocated() == 0);
    tracker.inner_allocator = mem;
    FractureResult recovered = copy_fracture_result(&tracker, (&fixture.piece)[:1])!!;
    assert_result_piece(recovered.storage, recovered.pieces[0], fixture.piece);
    destroy_fracture_result(&recovered);
    assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 1);
}

fn void test_fracture_result_layout_overflow_faults_before_allocating() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    ResultFixture fixture;
    init_result_fixture(&fixture, 0);
    usz excessive_pieces = (usz)sz::max / FracturePieceView::size + 1;
    assert(@catch(copy_fracture_result(&tracker, (&fixture.piece)[:excessive_pieces])) == c3d::CAPACITY_EXCEEDED);
    fixture.piece.mesh.geometry.positions = (&fixture.positions[0])[:(usz)sz::max / Vec3::size + 1];
    assert(@catch(copy_fracture_result(&tracker, (&fixture.piece)[:1])) == c3d::CAPACITY_EXCEEDED);
    usz near_limit = ((usz)sz::max - FracturePieceView::size) / Vec3::size;
    fixture.piece.mesh.geometry.positions = (&fixture.positions[0])[:near_limit];
    fixture.piece.mesh.geometry.normals = (&fixture.normals[0])[:near_limit];
    assert(@catch(copy_fracture_result(&tracker, (&fixture.piece)[:1])) == c3d::CAPACITY_EXCEEDED);
    assert(tracker.allocation_count() == 0 && tracker.total_allocation_count() == 0);
}

fn void init_result_fixture(ResultFixture* fixture, uint variant) @local {
    *fixture = {};
    fixture.positions = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
    fixture.indices = { 0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3 };
    fixture.identities = { 0, 1, 2, 3 };
    fixture.materials = { variant, variant + 1, variant, variant + 2 };
    foreach (uint index, &normal : fixture.normals) {
        *normal = { 0, 0, 1 };
        fixture.tangents[index] = { 1, 0, 0, index & 1 ? -1 : 1 };
        fixture.uv0[index] = { (float)index * 0.25f, 0.5 };
        fixture.uv1[index] = { 0.75, (float)index * 0.125f };
        fixture.colors[index] = { (float)index * 0.25f, 0.5, 0.75, 1 };
    }
    fixture.positions[0].x = bitcast((uint)0x80000000, float);
    fixture.piece = {
        .mesh = {
            .geometry = {
                .topology = Topology.TRIANGLES,
                .positions = fixture.positions[..],
                .normals = fixture.normals[:variant < 2 ? fixture.normals.len : 0],
                .tangents = fixture.tangents[:variant == 0 ? fixture.tangents.len : 0],
                .uv0 = fixture.uv0[:variant < 2 ? fixture.uv0.len : 0],
                .uv1 = fixture.uv1[:variant == 0 ? fixture.uv1.len : 0],
                .colors = fixture.colors[:variant == 0 ? fixture.colors.len : 0],
                .indices = fixture.indices[..],
                .targets = ((MorphTarget*)(&fixture.positions[0]))[:0],
                .channels = ((MorphChannel*)(&fixture.positions[0]))[:0],
                .custom_data = ((char*)(&fixture.positions[0]))[:0],
                .bounds = { .min = { -1, -2, -3 }, .max = { 4, 5, 6 } },
            },
            .topology_vertices = fixture.identities[..],
            .triangle_materials = fixture.materials[..],
        },
        .origin = { (float)variant, -2.5, bitcast((uint)0x80000000, float) },
    };
}

macro assert_result_array(char[] storage, actual, expected) @local {
    assert(actual.len == expected.len);
    if (actual.len) {
        assert(actual.ptr != expected.ptr && (uptr)actual.ptr % @alignof(actual[0]) == 0);
        assert((uptr)actual.ptr >= (uptr)storage.ptr);
        assert((uptr)(actual.ptr + actual.len) <= (uptr)(storage.ptr + storage.len));
        char[] actual_bytes = ((char*)actual.ptr)[:actual.len * @sizeof(actual[0])];
        char[] expected_bytes = ((char*)expected.ptr)[:expected.len * @sizeof(actual[0])];
        foreach (usz index, byte : actual_bytes) assert(byte == expected_bytes[index]);
    } else {
        assert(!actual.ptr);
    }
}

fn void assert_result_piece(char[] storage, FracturePieceView actual, FracturePieceView expected) @local {
    assert(actual.mesh.geometry.topology == expected.mesh.geometry.topology);
    for (uint axis = 0; axis < SPACE_AXES; axis++) {
        assert(bitcast(actual.origin[axis], uint) == bitcast(expected.origin[axis], uint));
        assert(bitcast(actual.mesh.geometry.bounds.min[axis], uint)
            == bitcast(expected.mesh.geometry.bounds.min[axis], uint));
        assert(bitcast(actual.mesh.geometry.bounds.max[axis], uint)
            == bitcast(expected.mesh.geometry.bounds.max[axis], uint));
    }
    assert_result_array(storage, actual.mesh.geometry.positions, expected.mesh.geometry.positions);
    assert_result_array(storage, actual.mesh.geometry.normals, expected.mesh.geometry.normals);
    assert_result_array(storage, actual.mesh.geometry.tangents, expected.mesh.geometry.tangents);
    assert_result_array(storage, actual.mesh.geometry.uv0, expected.mesh.geometry.uv0);
    assert_result_array(storage, actual.mesh.geometry.uv1, expected.mesh.geometry.uv1);
    assert_result_array(storage, actual.mesh.geometry.colors, expected.mesh.geometry.colors);
    assert_result_array(storage, actual.mesh.geometry.indices, expected.mesh.geometry.indices);
    assert_result_array(storage, actual.mesh.topology_vertices, expected.mesh.topology_vertices);
    assert_result_array(storage, actual.mesh.triangle_materials, expected.mesh.triangle_materials);
    assert(!actual.mesh.geometry.joints.ptr && !actual.mesh.geometry.weights.ptr);
    assert(!actual.mesh.geometry.targets.ptr && !actual.mesh.geometry.channels.ptr);
    assert(!actual.mesh.geometry.custom_data.ptr && !actual.mesh.geometry.custom_stride);
}
