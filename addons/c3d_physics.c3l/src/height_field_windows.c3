module c3d::physics;

import std::math;
import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;

struct MapCells @private {
    uint x;
    uint z;
}

<*
 Rectangle of height-map samples, columns along x and rows along z.
*>
struct SampleRect {
    uint x;
    uint z;
    uint columns;
    uint rows;
}

<*
 Collision windows that tile a terrain node's height field, one static body each.
 The node list and the collider copy are owned; the collider's window is zero.
*>
struct HeightFieldWindows {
    uint         window_cells;
    uint         columns;
    uint         rows;
    Entity[]     nodes; // row-major
    ColliderDesc collider;
}

<*
 Places a window node in the list of the terrain node that owns it.
*>
struct HeightFieldWindowOwner {
    Entity terrain;
    uint   index;
}

<*
 Tile the node's height field with static window bodies under it.
 Window nodes sit under the node; their bodies build on the next world update.
 @param [&inout] scene : "Registered with register_physics."
 @param [&inout] assets
 @param node : "Live, with a current world matrix, and without windows."
 @param [&in] collider : "A HEIGHT_FIELD collider over a TEXTURE source; its window is ignored."
 @param window_cells : "Cells along each side of a window; edge windows take the remainder."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::INVALID_ID, c3d::UNSUPPORTED
 @require window_cells >= 1, scene.world.is_registered(HeightFieldWindows)
*>
fn void? add_height_field_windows(
    Scene* scene,
    AssetStore* assets,
    Entity node,
    ColliderDesc* collider,
    uint window_cells,
) {
    if (!scene.world.is_alive(node)) return c3d::INVALID_ID~;
    if (scene.world.has(node, HeightFieldWindows)) return c3d::INVALID_ARGUMENT~;

    MapCells map = check_window_template(assets, collider, window_cells)!;
    uint columns = map.x / window_cells + (map.x % window_cells ? 1 : 0);
    uint rows = map.z / window_cells + (map.z % window_cells ? 1 : 0);

    HeightFieldWindows windows = try_copy_windows(
        allocator:    scene.allocator,
        window_cells: window_cells,
        columns:      columns,
        rows:         rows,
        collider:     collider,
    )!;
    defer catch alloc::free(scene.allocator, windows.nodes.ptr);

    uint created;
    defer catch {
        foreach (entity : windows.nodes[:created]) scene.remove(scene.node(entity));
    }

    Node* terrain = scene.node(node);
    for (uint row = 0; row < rows; row++) {
        for (uint column = 0; column < columns; column++) {
            HeightFieldWindow window = {
                .x       = column * window_cells,
                .z       = row * window_cells,
                .count_x = math::min(window_cells, map.x - column * window_cells),
                .count_z = math::min(window_cells, map.z - row * window_cells),
            };
            Node* window_node = scene.add_node(terrain, string::tformat("terrain_window_%d_%d", column, row))!;
            windows.nodes[created++] = window_node.id;
            window_node.local.position = {
                (float)window.x * windows.collider.local.scale.x,
                0,
                (float)window.z * windows.collider.local.scale.z,
            };
            window_node.world = terrain.world.mul(window_node.local.to_mat4());

            @pool() {
                ColliderDesc window_collider = windows.collider;
                window_collider.height_field.window = window;
                window_collider.material_indices = window_materials(windows.collider.material_indices, map.x, window);
                scene.add(window_node, try_copy_physics_body(
                    allocator: scene.allocator,
                    body:      default_body_desc(STATIC),
                    colliders: (&window_collider)[:1],
                )!);
            };
            scene.add(window_node, (HeightFieldWindowOwner){ .terrain = node, .index = row * columns + column });
        }
    }
    scene.world.add(node, windows);
}

<*
 Mark changed every window whose samples the rectangle touches.
 Neighbouring windows share their edge samples, so an edge marks both and a corner marks four.
 @param [&inout] scene
 @param node : "Carries HeightFieldWindows."
 @param rect : "Samples written in the height map."
 @return "Windows marked."
 @return? c3d::INVALID_ID
 @require rect.columns > 0 && rect.rows > 0
*>
fn uint? mark_height_field_windows_changed(Scene* scene, Entity node, SampleRect rect) {
    if (!scene.world.is_alive(node)) return c3d::INVALID_ID~;
    HeightFieldWindows* windows = scene.world.get(node, HeightFieldWindows);
    if (!windows) return c3d::INVALID_ID~;

    uint cells = windows.window_cells;
    uint first_column = rect.x ? (rect.x - 1) / cells : 0;
    uint first_row = rect.z ? (rect.z - 1) / cells : 0;
    uint last_column = math::min((rect.x + rect.columns - 1) / cells, windows.columns - 1);
    uint last_row = math::min((rect.z + rect.rows - 1) / cells, windows.rows - 1);

    uint marked;
    for (uint row = first_row; row <= last_row; row++) {
        for (uint column = first_column; column <= last_column; column++) {
            Entity entity = windows.nodes[row * windows.columns + column];
            if (!scene.world.is_alive(entity)) continue;

            PhysicsBody* body = scene.world.get(entity, PhysicsBody);
            if (!body) continue;

            body.mark_changed();
            marked++;
        }
    }
    return marked;
}

<*
 Remove the node's window bodies and their nodes.
 Invalidates component pointers of every store the window nodes used.
 @param [&inout] scene
 @param node : "Live; without windows this does nothing."
*>
fn void remove_height_field_windows(Scene* scene, Entity node) {
    HeightFieldWindows* windows = scene.world.get(node, HeightFieldWindows);
    if (!windows) return;

    foreach (entity : windows.nodes) {
        if (scene.world.is_alive(entity)) scene.remove(scene.node(entity));
    }
    scene.world.remove(node, HeightFieldWindows);
}

// The template must be a texture field whose first window builds; later windows are never larger.
fn MapCells? check_window_template(AssetStore* assets, ColliderDesc* collider, uint window_cells) @private {
    if (collider.kind != HEIGHT_FIELD || collider.height_field.source != TEXTURE) return c3d::INVALID_ARGUMENT~;

    check_height_map(assets, collider.height_field.texture)!;
    TextureDesc source = assets.texture(collider.height_field.texture).desc;
    MapCells map = { .x = source.width - 1, .z = source.height - 1 };
    if (collider.material_indices.len && collider.material_indices.len != (usz)map.x * map.z) {
        return c3d::INVALID_ARGUMENT~;
    }

    HeightFieldWindow first_window = {
        .count_x = math::min(window_cells, map.x),
        .count_z = math::min(window_cells, map.z),
    };
    (void)height_grid(source, first_window)!;
    return map;
}

fn void free_height_field_windows(Entity entity, void* component, void* user) @private {
    HeightFieldWindows* windows = component;
    alloc::free(*(Allocator*)user, windows.nodes.ptr);
}

fn HeightFieldWindows? try_copy_windows(
    Allocator allocator,
    uint window_cells,
    uint columns,
    uint rows,
    ColliderDesc* collider,
) @local {
    BlockCursor measure;
    carve_windows(&measure, window_cells, columns, rows, collider);
    char*? block = alloc::malloc_try(allocator, (sz)measure.offset);
    if (catch block) return c3d::CAPACITY_EXCEEDED~;

    BlockCursor fill = { .base = block };
    return carve_windows(&fill, window_cells, columns, rows, collider);
}

// One walk serves both passes, like the body copy: with a null base it only measures.
fn HeightFieldWindows carve_windows(
    BlockCursor* cursor,
    uint window_cells,
    uint columns,
    uint rows,
    ColliderDesc* collider,
) @local {
    Entity[] nodes = carve(cursor, Entity, (usz)columns * rows);
    ColliderDesc copy = *collider;
    copy.children = {};
    copy.height_field.heights = {};
    copy.height_field.window = {};
    copy.face_materials = carve_copy(cursor, collider.face_materials);
    copy.material_indices = carve_copy(cursor, collider.material_indices);
    return {
        .window_cells = window_cells,
        .columns      = columns,
        .rows         = rows,
        .nodes        = nodes,
        .collider     = copy,
    };
}

// The window's rows of the map-wide per-cell indices; empty when the map has none.
fn char[] window_materials(char[] indices, uint row_cells, HeightFieldWindow window) @local {
    if (!indices.len) return {};

    char[] slice = alloc::new_array(tmem, char, (sz)((usz)window.count_x * window.count_z));
    for (uint row = 0; row < window.count_z; row++) {
        usz source = (usz)(window.z + row) * row_cells + window.x;
        slice[(usz)row * window.count_x:window.count_x] = indices[source:window.count_x];
    }
    return slice;
}
