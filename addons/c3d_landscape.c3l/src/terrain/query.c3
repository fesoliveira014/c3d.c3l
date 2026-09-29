module c3d::landscape::terrain;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

const float RIGID_TOLERANCE @private = 0.0001f; // rounding left by composing node transforms

<*
 Borrowed world-space view of one terrain's heights.
 Invalidated by replacing, releasing or removing the height map, or by removing the terrain.
*>
struct HeightView {
    ushort[] texels;       // borrowed; row-major, x fastest
    uint     texels_per_side;
    float    cell_size;
    float    height_scale;
    Mat4     world;        // node world matrix when the view was taken
    Mat4     local_from_world;
}

struct CellPoint @private {
    Vec3  local;
    Vec2  fraction;
    float corner_00;
    float corner_10;
    float corner_01;
    float corner_11;
}

<*
 View of the node's terrain heights in world space.
 Applies to queries only; rendering takes any node transform.
 @param [&in] scene
 @param [&in] assets
 @return? c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require !scene.world.is_alive(node) || upright_rigid(scene.node(node).world) : "Translation and rotation about Y."
*>
fn HeightView? height_view(Scene* scene, AssetStore* assets, Entity node) {
    if (!scene.world.is_alive(node) || !scene.world.has(node, Terrain)) return c3d::INVALID_ID~;
    TerrainDesc* desc = &scene.world.get(node, Terrain).desc;
    if (!assets.textures.is_live(desc.height_map)) return c3d::INVALID_ID~;
    // The pool read keeps the store read-only; AssetStore.texture takes it as inout.
    TextureAsset* texture = assets.textures.get(desc.height_map);
    check_height_map(texture)!;
    Mat4 world = scene.node(node).world;
    return {
        .texels           = height_texels(texture),
        .texels_per_side  = texture.desc.width,
        .cell_size        = desc.cell_size,
        .height_scale     = desc.height_scale,
        .world            = world,
        .local_from_world = maths::inverse_affine(world),
    };
}

<*
 World height of the surface on the height field's triangles.
 @param [&in] view
 @return? NOT_FOUND
*>
fn float? sample_height(HeightView* view, float world_x, float world_z) {
    CellPoint point = cell_point(view, world_x, world_z)!;
    float height;
    if (point.fraction.x + point.fraction.y <= 1) {
        height = point.corner_00 + point.fraction.x * (point.corner_10 - point.corner_00)
          + point.fraction.y * (point.corner_01 - point.corner_00);
    } else {
        height = point.corner_11 + (1 - point.fraction.x) * (point.corner_01 - point.corner_11)
          + (1 - point.fraction.y) * (point.corner_10 - point.corner_11);
    }
    return maths::transform_point(view.world, { point.local.x, height, point.local.z }).y;
}

<*
 World face normal of the height-field triangle under the point.
 @param [&in] view
 @return? NOT_FOUND
*>
fn Vec3? sample_normal(HeightView* view, float world_x, float world_z) {
    CellPoint point = cell_point(view, world_x, world_z)!;
    Vec3 local;
    if (point.fraction.x + point.fraction.y <= 1) {
        local = { point.corner_00 - point.corner_10, view.cell_size, point.corner_00 - point.corner_01 };
    } else {
        local = { point.corner_01 - point.corner_11, view.cell_size, point.corner_10 - point.corner_11 };
    }
    return maths::transform_dir(view.world, local.normalize());
}

// Cell (x, z) splits along its diagonal from (x + 1, z) to (x, z + 1), as box3d's height field does.
fn CellPoint? cell_point(HeightView* view, float world_x, float world_z) @private {
    Vec3 local = maths::transform_point(view.local_from_world, { world_x, 0, world_z });
    float column = local.x / view.cell_size;
    float row = local.z / view.cell_size;
    float last = (float)(view.texels_per_side - 1);
    if (column < 0 || row < 0 || column > last || row > last) return NOT_FOUND~;
    uint cell_x = min((uint)column, view.texels_per_side - 2);
    uint cell_z = min((uint)row, view.texels_per_side - 2);
    float unit = view.height_scale / TEXEL_MAX;
    usz first = (usz)cell_z * view.texels_per_side + cell_x;
    usz next_row = first + view.texels_per_side;
    return {
        .local     = local,
        .fraction  = { column - cell_x, row - cell_z },
        .corner_00 = view.texels[first] * unit,
        .corner_10 = view.texels[first + 1] * unit,
        .corner_01 = view.texels[next_row] * unit,
        .corner_11 = view.texels[next_row + 1] * unit,
    };
}

fn bool upright_rigid(Mat4 world) @private {
    Vec3 axis_x = { world.m00, world.m10, world.m20 };
    Vec3 axis_y = { world.m01, world.m11, world.m21 };
    Vec3 axis_z = { world.m02, world.m12, world.m22 };
    return (axis_y - (Vec3){ 0, 1, 0 }).length() <= RIGID_TOLERANCE
      && math::abs(axis_x.length() - 1) <= RIGID_TOLERANCE
      && math::abs(axis_z.length() - 1) <= RIGID_TOLERANCE;
}
