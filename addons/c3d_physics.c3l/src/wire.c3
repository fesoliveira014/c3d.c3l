module c3d::physics;

import std::math;
import std::math::matrix;
import c3d;
import c3d::maths;
import b3;

const uint COMPOUND_RING_SEGMENTS @private = 16; // 48 lines per sphere; the wire density lever
const usz  BOX_EDGE_POINTS @private = 24;
const float AXIS_PARALLEL_THRESHOLD @private = 0.99f; // an axis this close to Y takes X as its basis reference

struct WireWriter @private {
    Vec3[] points;
    usz    count;
}

fn void write_ring(WireWriter* writer, Vec3 center, Vec3 axis, float radius) @private {
    Vec3 reference = math::abs(axis.y) < AXIS_PARALLEL_THRESHOLD ? (Vec3){ 0, 1, 0 } : (Vec3){ 1, 0, 0 };
    Vec3 side = axis.cross(reference).normalize() * radius;
    Vec3 forward = axis.cross(side).normalize() * radius;
    float step = (float)math::PI * 2 / COMPOUND_RING_SEGMENTS;
    for (uint segment = 0; segment < COMPOUND_RING_SEGMENTS; segment++) {
        float start = segment * step;
        float end = start + step;
        writer.points[writer.count++] = center + side * math::cos(start) + forward * math::sin(start);
        writer.points[writer.count++] = center + side * math::cos(end) + forward * math::sin(end);
    }
}

fn void write_capsule(WireWriter* writer, b3::Capsule capsule) @private {
    Vec3 axis = (capsule.center2 - capsule.center1).normalize();
    foreach (center : (Vec3[2]){ capsule.center1, capsule.center2 }) {
        write_ring(
            writer: writer,
            center: center,
            axis:   axis,
            radius: capsule.radius,
        );
    }
    Vec3 reference = math::abs(axis.y) < AXIS_PARALLEL_THRESHOLD ? (Vec3){ 0, 1, 0 } : (Vec3){ 1, 0, 0 };
    Vec3 side = axis.cross(reference).normalize() * capsule.radius;
    Vec3 forward = axis.cross(side).normalize() * capsule.radius;
    foreach (offset : (Vec3[4]){ side, -side, forward, -forward }) {
        writer.points[writer.count++] = capsule.center1 + offset;
        writer.points[writer.count++] = capsule.center2 + offset;
    }
}

fn void write_box(WireWriter* writer, maths::Transform local, Vec3 half_extents) @private {
    Mat4 placement = local.to_mat4();
    Vec3[8] corners;
    for (uint corner = 0; corner < 8; corner++) {
        Vec3 sign = { corner & 1 ? 1 : -1, corner & 2 ? 1 : -1, corner & 4 ? 1 : -1 };
        corners[corner] = maths::transform_point(placement, half_extents * sign);
    }
    for (uint corner = 0; corner < 8; corner++) {
        foreach (bit : (uint[3]){ 1, 2, 4 }) {
            if (corner & bit) continue;
            writer.points[writer.count++] = corners[corner];
            writer.points[writer.count++] = corners[corner | bit];
        }
    }
}

fn Vec3[] hull_wire(Allocator allocator, b3::HullData* hull) @private {
    WireWriter writer = { .points = alloc::new_array(allocator, Vec3, (sz)hull.edge_count) };
    write_hull(&writer, hull, matrix::IDENTITY4);
    return writer.points;
}

fn void write_hull(WireWriter* writer, b3::HullData* hull, Mat4 placement) @private {
    b3::HullHalfEdge* edges = (b3::HullHalfEdge*)((char*)hull + hull.edge_offset);
    Vec3* points = (Vec3*)((char*)hull + hull.point_offset);
    for (int edge = 0; edge < hull.edge_count; edge++) {
        if (edges[edge].twin < edge) continue;
        writer.points[writer.count++] = maths::transform_point(placement, points[edges[edge].origin]);
        writer.points[writer.count++] = maths::transform_point(placement, points[edges[edges[edge].twin].origin]);
    }
}
