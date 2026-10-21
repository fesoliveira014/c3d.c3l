# Terrain with physics and navigation

The [terrain](terrain.md) package imports neither `c3d::physics` nor `c3d::nav`. It supplies neutral values, `collision_input` and `height_range`, and the application writes the few lines that put them into the other package's types. This page shows the collider, the navigation grid and the order in which edits reach each of them. A collider selects `c3d_physics` and `b3` in `project.json`; a navigation grid selects `c3d_nav`.

## Add a collider

The terrain follows the physics height field's conventions: the same origin corner, row order, spacing, split and `texel / 65535` scaling. Build the collider on the terrain node as a static body, from the values `terrain::collision_input` returns.

`collision_input(&scene, node.id)` returns a `TerrainCollisionInput { height_map, scale, neighbours }`: the terrain's map, `{ cell_size, height_scale, cell_size }`, and the maps of the linked tiles on the west, east, north and south, empty where the tile has none. Call it after `update_world`. It works on a pending terrain.

```c3
TerrainCollisionInput input = terrain::collision_input(&scene, terrain_node.id)!;
ColliderDesc collider = physics::default_collider_desc(HEIGHT_FIELD);
collider.height_field = { .source = TEXTURE, .texture = input.height_map };
foreach (side, neighbour : input.neighbours) collider.height_field.neighbours[side].texture = neighbour;
collider.local.scale = input.scale;
physics.add_body(terrain_node, physics::default_body_desc(STATIC), (&collider)[:1])!;
```

- It faults `INVALID_ID` for a dead node or one without `Terrain`, and `UNSUPPORTED` when a world axis length of the node differs from 1 by more than 1e-4: physics drops node scale, so a scaled terrain would draw a different surface from its collider. Rotation is honoured.
- Physics refuses a collider-local offset on a height field, which is why the node's translation is the height offset.
- A tile passes its linked neighbours' maps, so a body crosses a tile seam as it crosses the interior of one field. The corners are not read. The application supplies any neighbour `material_indices` itself.

An edited terrain tiles the collider into windows, so a stroke re-cooks the part it touched and not the whole map:

```c3
physics::add_height_field_windows(
    scene:        &scene,
    assets:       &assets,
    node:         terrain_node.id,
    collider:     &collider,
    window_cells: 256,
)!;
```

Each window is a static body on a child node of the terrain, cooked from its own `window_cells`-square part of the height map. Windows quantize over the full height range, so they meet exactly at their seams, and tiles of one set with equal `height_scale` meet exactly at the tile seam. [Collision queries](collision_queries.md#prepared-height-fields) and the [physics README](../addons/c3d_physics.c3l/README.md#height-field-windows) state the window and neighbour contracts.

A live physics body is not re-cooked on a texture revision. `PhysicsBody.mark_changed()` rebuilds the whole field at the next `PhysicsWorld.update`; `physics::mark_height_field_windows_changed(scene, node, SampleRect)` rebuilds only the windows whose samples meet the rectangle. Mark once when a stroke ends: collision is stale during the stroke and correct after it.

## Build a navigation grid

A navigation grid reads heights through `nav::grid_sampled_source` and a `GridHeightSampler` callback. The callback over `sample_height` is the whole adapter; a point outside the map faults `NOT_FOUND`, which the grid reads as absent.

```c3
fn GridHeightSample? terrain_height(void* context, float world_x, float world_z) {
    HeightView* view = context;
    float? height = terrain::sample_height(view, world_x, world_z);
    if (catch height) return {};

    return { .height = height, .present = true };
}

HeightView view = terrain::height_view(&scene, &assets, ground.id)!;
TerrainHeightRange range = terrain::height_range(&scene, ground.id)!;
GridHeightSampler sampler = {
    .origin    = origin,
    .cell_size = cell_size,
    .sample    = &terrain_height,
    .context   = &view,
    .diagonal  = MAX_MIN_TO_MIN_MAX,
    .area      = nav::WALKABLE_AREA,
};
GridSourceDesc source = nav::grid_sampled_source(
    sampler:    &sampler,
    min_height: range.minimum - padding,
    max_height: range.maximum + padding,
)!;
```

- **Lattice.** The grid is axis-aligned in world XZ, whatever the terrain's yaw. `origin` is the world position of lattice vertex (0, 0) and `cell_size` is `NavBuildConfig.cell_size`; neither has to match the terrain's. `view` and `sampler` must outlive the cache and stay at their addresses.
- **Surface.** At a lattice vertex the grid's height is `sample_height`. Between vertices it interpolates over its own triangles, so it differs from the terrain by the terrain's curvature over one grid cell. With an unrotated terrain, the same cell size, an origin on a texel corner and `MAX_MIN_TO_MIN_MAX`, the two surfaces coincide.
- **Live texels.** The callback reads the map in place, so a texel write must not overlap a call of the sampler. `GridCache.update`, `GridCache.capture_next` and `GridTileBuilder.build` call it on the thread that calls them. A worker running `build_grid_cache_job` reads only a copy.
- **Height range.** `grid_sampled_source` takes the range every sampled height lies in. A cache refuses a source whose `1 + round((max_height - min_height) / cell_height)` reaches 8191 with `INVALID_ARGUMENT`, about 409 m at the grid's default `cell_height` of 0.05 (`default_grid_build_config`; the scene builder's default is 0.2). A terrain whose `height_scale` fits can use `[world_y, world_y + height_scale]` with `world_y` the node's world Y. Otherwise pad `height_range` by the headroom the edits need.
- **Retaking the range.** A floor outside the declared range fails its tile build with `INVALID_ARGUMENT`, and `set_source` refuses a change of range. When `height_range`, read after `update`, leaves the range of the source, create a new `GridCache` and `NavMesh` with the new range, at the cost of a full rebuild.
- **Tile sets.** Keep one `HeightView` per tile and pick the tile of a point with `floor((world − set_origin) / tile_extent)`, clamped to the set. Duplicated seam texels give both tiles the same height on the seam. The pick assumes a set node without rotation or scale. Take the union of the tiles' `height_range` values, padded once.

The [navigation package](../addons/c3d_nav.c3l/README.md) covers grid sources, caches and rebasing.

## Keep collider and navigation in step

**Height edit.**

1. Write the texels in place.
2. `terrain::mark_dirty(&scene, &assets, node, rect)!`.
3. Physics, once the stroke ends: with windows, `physics::mark_height_field_windows_changed(&scene, node.id, samples)!` where `samples` is a `SampleRect` of the same rectangle; with one collider, `scene.get(node, PhysicsBody).mark_changed()`.
4. Navigation: `grid.mark_dirty(cells, revision)`, where `revision` is a `ulong` the application advances with every edit and `cells` is a `GridRange` of every grid cell the change reaches. Use `nav::grid_vertex_cells` when the lattice is the texel lattice shifted by whole texels, else `nav::grid_world_cells` of the rectangle's world bounds grown by one texel.
5. On a tile set, repeat 3 and 4 for the neighbour strips that [`propagate_edit`](terrain.md#propagate-an-edit) reports. Navigation needs one world rectangle that covers both tiles.

After `terrain::update`, compare `height_range` with the range of the navigation source.

**Link or unlink.** Rebuild the colliders of both tiles from a new `collision_input`: remove the body or the windows and add them again. `mark_changed` keeps the neighbours of the stored description, so it does not follow a link change.

**Replacement** of the pixel array behind the height map, or a replaced or restored map: retake the views; call `PhysicsBody.mark_changed()` or add the windows again; call `grid.set_source(source, identity, revision)` with a new revision over the retaken views.

**Pending terrain.** `collision_input` and the sampler work on a pending terrain. `terrain::mark_dirty` and `height_range` need it prepared.

**Removal.** Remove the navigation cache first, because its sampler borrows the views and the views borrow the texels; then the collider; then the terrain.

**Origin rebasing.** Call `scene.shift_origin(offset)`, `scene.update_world()` and `physics.shift_origin(&scene, offset)`. Retake the views, because their world matrices predate the shift. Then shift navigation with `NavMesh.shift_origin`, `NavQuery.shift_origin`, `Crowd.shift_origin` and `GridCache.shift_origin(offset)`, which rebuilds no tile. Subtract the offset from `sampler.origin`; a later `set_source` takes `GridCache.source_origin()` as its origin. [Large worlds](large_world.md#navigation-grid-caches) states the order.

## See also

- [Terrain](terrain.md) and its [reference](terrain_reference.md).
- [Collision queries](collision_queries.md), [navigation package](../addons/c3d_nav.c3l/README.md), [large worlds](large_world.md).
