module c3d_physics_collide_test;

import c3d;
import std::math;
import b3;

const uint QUERY_FACE_VERTICES @private = 32;
const uint QUERY_CONTACT_POINTS @private = 64;
const int QUERY_MESH_HEIGHT @private = 256;
const uint QUERY_GRID_SIDE @private = 9;
const float QUERY_MIN_SCALE @private = 0.01f;
const float QUERY_AABB_MARGIN @private = 0.05f; // native traversal margin at one length unit per metre
const ulong QUERY_CANARY @private = 0xa13fc507ea9462bd;
const b3::Transform QUERY_IDENTITY @private = { .q = { .v = { 0, 0, 0, 1 } } };

struct QuerySurfaceFixture @private {
    Vec3[QUERY_GRID_SIDE * QUERY_GRID_SIDE] vertices;
    float[QUERY_GRID_SIDE * QUERY_GRID_SIDE] heights;
    int[6 * (QUERY_GRID_SIDE - 1) * (QUERY_GRID_SIDE - 1)] indices;
    char[(QUERY_GRID_SIDE - 1) * (QUERY_GRID_SIDE - 1)] materials;
    uint side;
    uint vertex_count;
    uint triangle_count;
}

struct QueryContactScratch @private {
    ulong[2] before;
    b3::LocalManifoldPoint[QUERY_CONTACT_POINTS] points;
    ulong[2] after;
}

struct QueryShortScratch @private {
    ulong[2] before;
    b3::LocalManifoldPoint[4] points;
    ulong[2] after;
}

struct QueryTriangleObservation @private {
    uint count;
}

$assert QueryContactScratch::members[2].offset == QueryContactScratch::members[1].offset
    + QUERY_CONTACT_POINTS * b3::LocalManifoldPoint::size;
$assert QueryShortScratch::members[2].offset == QueryShortScratch::members[1].offset
    + 4 * b3::LocalManifoldPoint::size;

fn Vec3[] query_prism_points(uint sides, float center_y = 0.49f) @private {
    Vec3[] points = alloc::new_array(tmem, Vec3, (sz)(2 * sides));
    for (uint index = 0; index < sides; index++) {
        float angle = 2 * (float)math::PI * (float)index / (float)sides;
        points[index] = { math::cos(angle), center_y - 0.5f, math::sin(angle) };
        points[index + sides] = { math::cos(angle), center_y + 0.5f, math::sin(angle) };
    }
    return points;
}

fn uint query_max_face_vertices(b3::HullData* hull) @private {
    b3::HullFace* faces = (b3::HullFace*)((char*)hull + hull.face_offset);
    b3::HullHalfEdge* edges = (b3::HullHalfEdge*)((char*)hull + hull.edge_offset);
    uint maximum;
    foreach (face : faces[:hull.face_count]) {
        uint count;
        uint edge = face.edge;
        do {
            count++;
            assert(count <= (uint)hull.edge_count);
            edge = edges[edge].next;
        } while (edge != face.edge);
        maximum = math::max(maximum, count);
    }
    return maximum;
}

fn void? query_hull_admission(b3::HullData* hull) @private {
    if (hull.vertex_count > b3::MAX_HULL_VERTICES || query_max_face_vertices(hull) > QUERY_FACE_VERTICES) {
        return c3d::CAPACITY_EXCEEDED~;
    }
}

fn void? query_depth_admission(int height) @private {
    if (height > QUERY_MESH_HEIGHT) return c3d::CAPACITY_EXCEEDED~;
}

fn void? query_scale_admission(Vec3 scale) @private {
    foreach (value : scale) {
        if (!math::is_finite(value) || value == 0) return c3d::INVALID_ARGUMENT~;
        if (math::abs(value) < QUERY_MIN_SCALE) return c3d::UNSUPPORTED~;
    }
}

fn float? query_positive_quantity(double value) @private {
    if (!math::is_finite(value) || value <= 0 || value > (double)float::max) return b3::DEGENERATE_GEOMETRY~;
    float represented = (float)value;
    if (represented == 0) return b3::DEGENERATE_GEOMETRY~;
    return represented;
}

fn void? query_cell_admission(float coordinate, float spacing) @private {
    float quotient = coordinate / spacing;
    if (!math::is_finite(quotient)) return c3d::UNSUPPORTED~;
    double index = math::floor((double)quotient);
    if (index < (double)int::min || index > (double)int::max) return c3d::UNSUPPORTED~;
}

fn float? query_relative_component(float first, float second) @private {
    double difference = (double)first - (double)second;
    if (difference < -(double)float::max || difference > (double)float::max) return c3d::UNSUPPORTED~;
    return (float)difference;
}

fn QuerySurfaceFixture query_surface_fixture(uint side) @private {
    assert(side >= 2 && side <= QUERY_GRID_SIDE);
    QuerySurfaceFixture fixture = {
        .side = side,
        .vertex_count = side * side,
        .triangle_count = 2 * (side - 1) * (side - 1),
    };
    for (uint row = 0; row < side; row++) {
        for (uint column = 0; column < side; column++) {
            fixture.vertices[row * side + column] = { (float)column, 0, (float)row };
        }
    }
    uint next;
    for (uint row = 0; row + 1 < side; row++) {
        for (uint column = 0; column + 1 < side; column++) {
            int first = (int)(row * side + column);
            int opposite = first + (int)side + 1;
            fixture.indices[next++] = first;
            fixture.indices[next++] = first + (int)side;
            fixture.indices[next++] = first + 1;
            fixture.indices[next++] = opposite;
            fixture.indices[next++] = first + 1;
            fixture.indices[next++] = first + (int)side;
        }
    }
    return fixture;
}

fn b3::MeshData* query_surface_mesh(QuerySurfaceFixture* fixture) @private {
    b3::MeshDef desc = {
        .vertices = fixture.vertices[:fixture.vertex_count].ptr,
        .indices = fixture.indices[:fixture.triangle_count * 3].ptr,
        .vertex_count = (int)fixture.vertex_count,
        .triangle_count = (int)fixture.triangle_count,
    };
    return b3::create_mesh(&desc)!!;
}

fn b3::HeightFieldData* query_surface_field(QuerySurfaceFixture* fixture, Vec3 scale = { 1, 1, 1 }) @private {
    b3::HeightFieldDef desc = {
        .heights = fixture.heights[:fixture.vertex_count].ptr,
        .material_indices = fixture.materials[:fixture.triangle_count / 2].ptr,
        .scale = scale,
        .count_x = (int)fixture.side,
        .count_z = (int)fixture.side,
    };
    return b3::create_height_field(&desc)!!;
}

fn bool query_observe_triangle(
    Vec3 first,
    Vec3 second,
    Vec3 third,
    int triangle_index,
    void* context,
) @private {
    QueryTriangleObservation* observation = context;
    Vec3 normal = (second - first).cross(third - first).normalize();
    assert(near_vector(normal, { 0, 1, 0 }));
    observation.count++;
    return true;
}
