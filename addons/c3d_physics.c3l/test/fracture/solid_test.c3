module c3d::physics::fracture;

import c3d;
import c3d::geometry;
import std::math;

const Vec3[4] TETRA_POSITIONS @local = { {}, { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } };
const uint[12] TETRA_CORNERS @local = { 0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3 };
const usz SOLID_TEST_BYTES @local = MIN_FRACTURE_SCRATCH_BYTES + 8192;

struct SolidFixture @private {
    Vec3[12] positions;
    uint[24] indices;
    uint[12] identities;
    uint[8] materials;
    SolidMeshView mesh;
}

fn void test_solid_topology_preserves_seams_and_uses_bounded_scratch() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    FractureLimits limits = solid_limits();
    FractureWorkspace workspace = create_fracture_workspace(&tracker, limits)!!;
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidTopology first = build_solid_topology(&scratch, fixture.mesh)!!;
    assert(first.vertices.len == 4 && first.shell_count == 1);
    foreach (uint corner, twin : first.twins) {
        assert(first.twins[twin] == corner && twin != corner);
        uint start = fixture.identities[fixture.indices[corner]];
        uint end = fixture.identities[fixture.indices[next_solid_corner(twin)]];
        assert(start == end);
    }
    foreach (root : first.shell_roots) assert(root == 0);
    foreach (vertex : first.vertices) assert(vertex.degree == 3);
    assert(scratch.used < scratch.peak && scratch.peak < workspace.storage.len);
    usz peak = scratch.peak;
    for (uint repeat = 0; repeat < 3; repeat++) {
        scratch = begin_solid_scratch(&workspace);
        assert(build_solid_topology(&scratch, fixture.mesh)!!.shell_count == 1);
        assert(scratch.peak == peak);
    }
    for (uint corner = 0; corner < 12; corner++) {
        fixture.positions[corner] = TETRA_POSITIONS[TETRA_CORNERS[corner]];
        fixture.identities[corner] = TETRA_CORNERS[corner];
        fixture.indices[corner] = corner;
    }
    fixture.mesh.geometry.positions = fixture.positions[..];
    fixture.mesh.topology_vertices = fixture.identities[..];
    scratch = begin_solid_scratch(&workspace);
    SolidTopology seams = build_solid_topology(&scratch, fixture.mesh)!!;
    assert(seams.vertices.len == 4 && seams.shell_count == 1);
    foreach (uint corner, index : fixture.mesh.geometry.indices) assert(index == corner);
    assert(tracker.total_allocation_count() == 1);
    fixture.positions[0].x = bitcast((uint)0x80000000, float);
    scratch = begin_solid_scratch(&workspace);
    assert(build_solid_topology(&scratch, fixture.mesh)!!.shell_count == 1);
    fixture.positions[0].x = 0.25f;
    scratch = begin_solid_scratch(&workspace);
    assert(@catch(build_solid_topology(&scratch, fixture.mesh)) == c3d::INVALID_ARGUMENT);
    assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES);
}

fn void test_solid_topology_rejects_open_winding_edge_and_vertex_nonmanifolds() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    fixture.mesh.geometry.indices = fixture.indices[:9];
    fixture.mesh.triangle_materials = fixture.materials[:3];
    assert_solid_fault(&workspace, fixture.mesh, INVALID_SOLID);
    tetra_fixture(&fixture);
    fixture.indices[1] = 1;
    fixture.indices[2] = 2;
    assert_solid_fault(&workspace, fixture.mesh, INVALID_SOLID);
    tetra_fixture(&fixture);
    fixture.indices[0] = fixture.indices[1];
    assert_solid_fault(&workspace, fixture.mesh, INVALID_SOLID);
    tetra_fixture(&fixture);
    fixture.indices[12:3] = fixture.indices[:3];
    fixture.mesh.geometry.indices = fixture.indices[:15];
    fixture.mesh.triangle_materials = fixture.materials[:5];
    assert_solid_fault(&workspace, fixture.mesh, INVALID_SOLID);
    tetra_fixture(&fixture);
    for (uint vertex = 1; vertex < 4; vertex++) fixture.positions[vertex + 3] = -TETRA_POSITIONS[vertex];
    for (uint vertex = 4; vertex < 7; vertex++) fixture.identities[vertex] = vertex;
    for (uint corner = 0; corner < 12; corner++) {
        uint vertex = TETRA_CORNERS[corner];
        fixture.indices[corner + 12] = vertex ? vertex + 3 : 0;
    }
    fixture.mesh.geometry.positions = fixture.positions[:7];
    fixture.mesh.geometry.indices = fixture.indices[..];
    fixture.mesh.topology_vertices = fixture.identities[:7];
    fixture.mesh.triangle_materials = fixture.materials[..];
    assert_solid_fault(&workspace, fixture.mesh, INVALID_SOLID);
    tetra_fixture(&fixture);
    for (uint vertex = 0; vertex < 4; vertex++) {
        fixture.positions[vertex + 4] = TETRA_POSITIONS[vertex] + (Vec3){ 3, 0, 0 };
        fixture.identities[vertex + 4] = vertex + 4;
    }
    for (uint corner = 0; corner < 12; corner++) fixture.indices[corner + 12] = TETRA_CORNERS[corner] + 4;
    fixture.mesh.geometry.positions = fixture.positions[:8];
    fixture.mesh.geometry.indices = fixture.indices[..];
    fixture.mesh.topology_vertices = fixture.identities[:8];
    fixture.mesh.triangle_materials = fixture.materials[..];
    SolidScratch scratch = begin_solid_scratch(&workspace);
    SolidTopology disconnected = build_solid_topology(&scratch, fixture.mesh)!!;
    assert(disconnected.shell_count == 2);
    foreach (uint face, root : disconnected.shell_roots) assert(root == (face < 4 ? 0 : 4));
}

fn void test_solid_stream_faults_distinguish_malformed_and_unsupported_input() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    SolidMeshView source = fixture.mesh;
    source.geometry.topology = Topology.LINES;
    assert_solid_fault(&workspace, source, c3d::UNSUPPORTED);
    source = fixture.mesh;
    ushort[<4>][4] joints;
    source.geometry.joints = joints[..];
    assert_solid_fault(&workspace, source, c3d::UNSUPPORTED);
    source = fixture.mesh;
    Vec4[4] attributes;
    source.geometry.weights = attributes[..];
    assert_solid_fault(&workspace, source, c3d::UNSUPPORTED);
    source = fixture.mesh;
    MorphTarget[1] targets;
    source.geometry.targets = targets[..];
    assert_solid_fault(&workspace, source, c3d::UNSUPPORTED);
    source = fixture.mesh;
    MorphChannel[1] channels;
    source.geometry.channels = channels[..];
    assert_solid_fault(&workspace, source, c3d::UNSUPPORTED);
    source = fixture.mesh;
    source.geometry.custom_stride = 4;
    assert_solid_fault(&workspace, source, c3d::UNSUPPORTED);
    source = fixture.mesh;
    char[1] custom_data;
    source.geometry.custom_data = custom_data[..];
    assert_solid_fault(&workspace, source, c3d::UNSUPPORTED);
    source = fixture.mesh;
    source.geometry.positions = {};
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    source = fixture.mesh;
    source.geometry.indices = source.geometry.indices[:11];
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    source = fixture.mesh;
    source.triangle_materials = source.triangle_materials[:3];
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    source = fixture.mesh;
    source.topology_vertices = source.topology_vertices[:3];
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    source = fixture.mesh;
    source.geometry.colors = attributes[:3];
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    fixture.indices[0] = 4;
    assert_solid_fault(&workspace, fixture.mesh, c3d::INVALID_ARGUMENT);
    fixture.indices[0] = 0;
    fixture.identities[0] = 4;
    assert_solid_fault(&workspace, fixture.mesh, c3d::INVALID_ARGUMENT);
    fixture.identities[0] = 0;
    foreach (uint bits : { 0x7f800000, 0xff800000, 0x7fc00000 }) {
        fixture.positions[0].x = bitcast(bits, float);
        assert_solid_fault(&workspace, fixture.mesh, c3d::INVALID_ARGUMENT);
    }
    fixture.positions[0] = {};
    source = fixture.mesh;
    source.geometry.colors = attributes[..];
    attributes[3].w = bitcast((uint)0x7fc00000, float);
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    attributes[3].w = 1;
    check_solid_streams(source)!!;
    Vec2[4] texture_coordinates;
    texture_coordinates[2].y = bitcast((uint)0x7f800000, float);
    source.geometry.uv0 = texture_coordinates[..];
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    source.geometry.uv0 = {};
    source.geometry.uv1 = texture_coordinates[..];
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    source = fixture.mesh;
    Vec3[4] normals;
    normals[1].z = bitcast((uint)0x7f800000, float);
    source.geometry.normals = normals[..];
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
    source.geometry.normals = {};
    attributes[2].x = bitcast((uint)0x7fc00000, float);
    source.geometry.tangents = attributes[..];
    assert_solid_fault(&workspace, source, c3d::INVALID_ARGUMENT);
}

fn void test_solid_scratch_capacity_failure_restores_cursor_and_reuses_workspace() @test {
    FractureWorkspace workspace = solid_workspace();
    defer destroy_fracture_workspace(&workspace);
    SolidFixture fixture;
    tetra_fixture(&fixture);
    SolidScratch scratch = begin_solid_scratch(&workspace);
    build_solid_topology(&scratch, fixture.mesh)!!;
    usz required = scratch.peak;
    foreach (usz available : { MIN_FRACTURE_SCRATCH_BYTES, required - 1, required }) {
        scratch = begin_solid_scratch(&workspace);
        scratch.storage = scratch.storage[:available];
        if (available == required) {
            assert(build_solid_topology(&scratch, fixture.mesh)!!.shell_count == 1);
        } else {
            assert(@catch(build_solid_topology(&scratch, fixture.mesh)) == c3d::CAPACITY_EXCEEDED);
            assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES);
        }
    }
    scratch = begin_solid_scratch(&workspace);
    assert(@catch(scratch.reserve(usz::max, SolidEdge::size, SolidEdge::alignment)) == c3d::CAPACITY_EXCEEDED);
    assert(scratch.used == MIN_FRACTURE_SCRATCH_BYTES);
    char[128] alignment_storage;
    for (usz offset = 0; offset < 8; offset++) {
        SolidScratch alignment_scratch = { .storage = alignment_storage[offset..] };
        void* reserved = alignment_scratch.reserve(3, ulong::size, 32)!!;
        assert((uptr)reserved % 32 == 0);
        assert(alignment_scratch.peak == alignment_scratch.used && alignment_scratch.used <= alignment_storage.len - offset);
    }
    fixture.positions[4] = { 9, 9, 9 };
    fixture.identities[4] = 5;
    fixture.mesh.geometry.positions = fixture.positions[:6];
    fixture.mesh.topology_vertices = fixture.identities[:6];
    assert_solid_fault(&workspace, fixture.mesh, c3d::INVALID_ARGUMENT);
    tetra_fixture(&fixture);
    scratch = begin_solid_scratch(&workspace);
    assert(build_solid_topology(&scratch, fixture.mesh)!!.shell_count == 1);
}

fn void tetra_fixture(SolidFixture* fixture) @private {
    *fixture = {};
    fixture.positions[:4] = TETRA_POSITIONS[..];
    fixture.indices[:12] = TETRA_CORNERS[..];
    for (uint vertex = 0; vertex < 4; vertex++) fixture.identities[vertex] = vertex;
    fixture.mesh = {
        .geometry = { .positions = fixture.positions[:4], .indices = fixture.indices[:12] },
        .topology_vertices = fixture.identities[:4],
        .triangle_materials = fixture.materials[:4],
    };
}

fn FractureWorkspace solid_workspace() @private {
    return create_fracture_workspace(mem, solid_limits())!!;
}

fn FractureLimits solid_limits() @private {
    return {
        .scratch_bytes = SOLID_TEST_BYTES,
        .max_vertices = 64,
        .max_triangles = 64,
        .max_pieces = 8,
        .max_sites = 8,
        .max_hulls = 8,
        .resolution_m = 0.0001f,
    };
}

fn void assert_solid_fault(FractureWorkspace* workspace, SolidMeshView source, fault expected) @local {
    SolidScratch scratch = begin_solid_scratch(workspace);
    scratch.reserve(1, ulong::size, ulong::alignment)!!;
    usz saved = scratch.used;
    assert(@catch(build_solid_topology(&scratch, source)) == expected);
    assert(scratch.used == saved && scratch.exact.count == 0);
}
