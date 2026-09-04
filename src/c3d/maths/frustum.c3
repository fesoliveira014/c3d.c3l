module c3d::maths;

import std::math;

<*
 Plane in Hessian normal form; a point is inside when dot(normal, point) + d is not negative.
*>
struct Plane
{
    Vec3  normal;
    float d;
}

<*
 View frustum as six inward-facing planes.
*>
struct Frustum
{
    Plane[6] planes;
}

fn Plane normalized_plane(Vec4 coefficients) @private
{
    Vec3 normal = { coefficients.x, coefficients.y, coefficients.z };
    float length = normal.length();
    return { .normal = normal / length, .d = coefficients.w / length };
}

<*
 Extract the six clipping planes of a reverse-Z view-projection matrix.
*>
fn Frustum frustum_from_view_proj(Mat4 view_proj)
{
    Vec4 row_x = { view_proj.m00, view_proj.m01, view_proj.m02, view_proj.m03 };
    Vec4 row_y = { view_proj.m10, view_proj.m11, view_proj.m12, view_proj.m13 };
    Vec4 row_z = { view_proj.m20, view_proj.m21, view_proj.m22, view_proj.m23 };
    Vec4 row_w = { view_proj.m30, view_proj.m31, view_proj.m32, view_proj.m33 };

    // Depth is reverse-Z, so the row that gives near under a [0, 1] mapping gives far here.
    return {
        .planes = {
            normalized_plane(row_w + row_x),
            normalized_plane(row_w - row_x),
            normalized_plane(row_w + row_y),
            normalized_plane(row_w - row_y),
            normalized_plane(row_w - row_z),
            normalized_plane(row_z),
        },
    };
}

<*
 Whether any part of the box lies inside the frustum.
*>
fn bool frustum_intersects_aabb(Frustum* frustum, Aabb bounds)
{
    foreach (&plane : frustum.planes) {
        Vec3 positive = {
            plane.normal.x >= 0 ? bounds.max.x : bounds.min.x,
            plane.normal.y >= 0 ? bounds.max.y : bounds.min.y,
            plane.normal.z >= 0 ? bounds.max.z : bounds.min.z,
        };
        if (plane.normal.dot(positive) + plane.d < 0) return false;
    }
    return true;
}
