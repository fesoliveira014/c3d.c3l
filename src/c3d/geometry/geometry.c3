module c3d::geometry;

import c3d::maths;
import std::math;

<*
 Primitive assembly of the index or vertex stream.
*>
enum Topology {
    TRIANGLES,
    LINES,
    POINTS,
}

<*
 Per-vertex deltas of one morph target.
*>
struct MorphTarget {
    Vec3[] position_deltas;
    Vec3[] normal_deltas;
    String name;
}

<*
 Attribute arrays and indices of one mesh; carries no material.
*>
struct Geometry {
    Topology      topology;
    Vec3[]        positions;
    Vec3[]        normals;
    Vec4[]        tangents;
    Vec2[]        uv0;
    Vec2[]        uv1;
    Vec4[]        colors;
    ushort[<4>][] joints;
    Vec4[]        weights;
    uint[]        indices;
    MorphTarget[] targets;
    char[]        custom_data;
    uint          custom_stride;
    Aabb          bounds;
}
