module c3d::landscape::terrain;

import c3d;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Sides of a collider that can continue into a linked tile: west, east, north, south.
*>
const uint COLLISION_SIDES = 4;

<*
 Collider values that reproduce a terrain's surface under the physics height-field convention.
*>
struct TerrainCollisionInput {
    TextureId                  height_map; // the terrain's own map, as a TEXTURE height-field source
    Vec3                       scale;      // { cell_size, height_scale, cell_size }, as the collider's local scale
    TextureId[COLLISION_SIDES] neighbours; // linked tiles' maps: west, east, north, south; empty where none
}

<*
 World height range of a prepared terrain.
*>
struct TerrainHeightRange {
    float minimum; // metres, the node's world Y included
    float maximum;
}

<*
 Collider values for a terrain node.
 Rebuild the colliders of both tiles when a link changes.
 @param [&in] scene : "World matrices current."
 @return? c3d::INVALID_ID, c3d::UNSUPPORTED
*>
fn TerrainCollisionInput? collision_input(Scene* scene, Entity node) {
    if (!scene.world.is_alive(node) || !scene.world.has(node, Terrain)) return c3d::INVALID_ID~;
    if (!has_unit_axes(scene.node(node).world)) return c3d::UNSUPPORTED~;

    TerrainDesc* desc = &scene.world.get(node, Terrain).desc;
    TerrainCollisionInput input = {
        .height_map = desc.height_map,
        .scale      = { desc.cell_size, desc.height_scale, desc.cell_size },
    };
    TerrainSet* set = parent_set(scene, scene.node(node));
    if (!set) return input;

    foreach (direction : TerrainNeighbour::values[:COLLISION_SIDES]) {
        if (try neighbour = set.neighbour(node, direction)) {
            input.neighbours[direction.ordinal] = scene.world.get(neighbour, Terrain).desc.height_map;
        }
    }
    return input;
}

<*
 World height range of a prepared terrain, current after update.
 @param [&in] scene : "World matrices current."
 @return? c3d::INVALID_ID, NOT_PREPARED
 @require !scene.world.is_alive(node) || upright_rigid(scene.node(node).world) : "Translation and rotation about Y."
*>
fn TerrainHeightRange? height_range(Scene* scene, Entity node) {
    if (!scene.world.is_alive(node) || !scene.world.has(node, Terrain)) return c3d::INVALID_ID~;
    if (!scene.world.has(node, TerrainRuntime)) return NOT_PREPARED~;

    TerrainRuntime* runtime = scene.world.get(node, TerrainRuntime);
    uint root = runtime.level_offset[runtime.level_count - 1];
    float unit = scene.world.get(node, Terrain).desc.height_scale / TEXEL_MAX;
    Mat4 world = scene.node(node).world;
    return {
        .minimum = maths::transform_point(world, { 0, (float)runtime.minimum[root] * unit, 0 }).y,
        .maximum = maths::transform_point(world, { 0, (float)runtime.maximum[root] * unit, 0 }).y,
    };
}

fn bool has_unit_axes(Mat4 world) @private {
    Vec3 axis_x = { world.m00, world.m10, world.m20 };
    Vec3 axis_y = { world.m01, world.m11, world.m21 };
    Vec3 axis_z = { world.m02, world.m12, world.m22 };
    return math::abs(axis_x.length() - 1) <= RIGID_TOLERANCE
      && math::abs(axis_y.length() - 1) <= RIGID_TOLERANCE
      && math::abs(axis_z.length() - 1) <= RIGID_TOLERANCE;
}
