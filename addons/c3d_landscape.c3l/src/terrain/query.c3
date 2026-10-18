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
 The border ring is read in place: take a new view after a tile link or a neighbour edit.
*>
struct HeightView {
    ushort[] texels;       // borrowed; row-major, x fastest
    uint     texels_per_side;
    float    cell_size;
    float    height_scale;
    ushort[] border;       // borrowed; the tile's border ring, a row per BorderEdge; empty off a set
    uint     border_edges; // BorderEdge bits whose ring row holds a linked neighbour's texels
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
    HeightView view = {
        .texels           = height_texels(texture),
        .texels_per_side  = texture.desc.width,
        .cell_size        = desc.cell_size,
        .height_scale     = desc.height_scale,
        .world            = world,
        .local_from_world = maths::inverse_affine(world),
    };

    if (scene.world.has(node, TerrainRuntime)) {
        TerrainRuntime* runtime = scene.world.get(node, TerrainRuntime);
        if (runtime.border_ring.generation) capture_border(&view, assets, runtime);
    }
    return view;
}

// The pool read keeps the store read-only; AssetStore.texture takes it as inout.
fn void capture_border(HeightView* view, AssetStore* assets, TerrainRuntime* runtime) @private {
    TextureAsset* ring = assets.textures.get(runtime.border_ring);
    view.border = ((ushort*)ring.pixels.ptr)[:(usz)view.texels_per_side * BorderEdge::len];
    view.border_edges = runtime.ring_edges;
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

<*
 Smooth normal the terrain shades with, at a world point.
 @param [&in] view
 @return? NOT_FOUND
*>
fn Vec3? sample_smooth_normal(HeightView* view, float world_x, float world_z) {
    CellPoint point = cell_point(view, world_x, world_z)!;
    uint last = view.texels_per_side - 1;
    float column = point.local.x / view.cell_size;
    float row = point.local.z / view.cell_size;
    uint base_x = min((uint)column, last);
    uint base_z = min((uint)row, last);
    uint next_x = min(base_x + 1, last);
    uint next_z = min(base_z + 1, last);
    float weight_x = column - (float)base_x;
    float weight_z = row - (float)base_z;

    Vec2 near_row = blend_gradients(
        texel_gradient(view, base_x, base_z),
        texel_gradient(view, next_x, base_z),
        weight_x,
    );
    Vec2 far_row = blend_gradients(
        texel_gradient(view, base_x, next_z),
        texel_gradient(view, next_x, next_z),
        weight_x,
    );
    Vec2 gradient = blend_gradients(near_row, far_row, weight_z);
    Vec3 local = { -gradient.x, 1, -gradient.y };
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

fn float texel_height(HeightView* view, uint x, uint z) @private {
    return view.height_scale * (float)view.texels[(usz)z * view.texels_per_side + x] / TEXEL_MAX;
}

fn float border_height(HeightView* view, BorderEdge edge, uint along) @private {
    return view.height_scale * (float)view.border[(usz)edge.ordinal * view.texels_per_side + along] / TEXEL_MAX;
}

// The fragment stage's gradient: central differences, the ring across a linked edge, one-sided elsewhere.
fn Vec2 texel_gradient(HeightView* view, uint x, uint z) @private {
    uint last = view.texels_per_side - 1;
    uint low_x = x > 0 ? x - 1 : 0;
    uint high_x = min(x + 1, last);
    uint low_z = z > 0 ? z - 1 : 0;
    uint high_z = min(z + 1, last);

    float low_height_x = texel_height(view, low_x, z);
    float high_height_x = texel_height(view, high_x, z);
    float low_height_z = texel_height(view, x, low_z);
    float high_height_z = texel_height(view, x, high_z);
    Vec2 span = { (float)(high_x - low_x), (float)(high_z - low_z) };

    if (x == 0 && (view.border_edges & BorderEdge.WEST.bit())) {
        low_height_x = border_height(view, WEST, z);
        span.x += 1;
    }
    if (x == last && (view.border_edges & BorderEdge.EAST.bit())) {
        high_height_x = border_height(view, EAST, z);
        span.x += 1;
    }
    if (z == 0 && (view.border_edges & BorderEdge.NORTH.bit())) {
        low_height_z = border_height(view, NORTH, x);
        span.y += 1;
    }
    if (z == last && (view.border_edges & BorderEdge.SOUTH.bit())) {
        high_height_z = border_height(view, SOUTH, x);
        span.y += 1;
    }

    Vec2 difference = { high_height_x - low_height_x, high_height_z - low_height_z };
    return (difference / span) / view.cell_size;
}

fn Vec2 blend_gradients(Vec2 from, Vec2 to, float amount) @private => from * (1 - amount) + to * amount;

fn bool upright_rigid(Mat4 world) @private {
    Vec3 axis_x = { world.m00, world.m10, world.m20 };
    Vec3 axis_y = { world.m01, world.m11, world.m21 };
    Vec3 axis_z = { world.m02, world.m12, world.m22 };
    return (axis_y - (Vec3){ 0, 1, 0 }).length() <= RIGID_TOLERANCE
      && math::abs(axis_x.length() - 1) <= RIGID_TOLERANCE
      && math::abs(axis_z.length() - 1) <= RIGID_TOLERANCE;
}
