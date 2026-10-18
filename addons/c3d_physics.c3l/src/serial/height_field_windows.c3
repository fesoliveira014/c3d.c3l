module c3d::physics @feat(C3D_PHYSICS_SERIAL);

import c3d;
import c3d::describe;
import c3d::ecs;
import c3d::scene;
import c3d::serial;

const ulong HEIGHT_FIELD_WINDOWS_LAYOUT @private = 0xcf98f73f7a381f48;

struct HeightFieldWindowsAuthoring @private {
    uint         window_cells;
    ColliderDesc collider;
}

fn void? register_height_field_windows_codec() @private {
    describe::register_reflected(HeightFieldWindowsAuthoring)!;
    register_physics_value(HeightFieldWindowsAuthoring, HEIGHT_FIELD_WINDOWS_LAYOUT, &defaults_height_field_windows)!;
    serial::register_described_owner(HeightFieldWindows, HeightFieldWindowsAuthoring, {
        .name = "height_field_windows",
        .phase = OWNER,
        .collect = &collect_height_field_windows,
        .project = &project_height_field_windows,
        .validate = &validate_height_field_windows,
        .attach = &attach_height_field_windows,
    })!;
    serial::register_transient(HeightFieldWindowOwner, &collect_height_field_window)!;
}

fn void defaults_height_field_windows(void* value) @private {
    *(HeightFieldWindowsAuthoring*)value = { .collider = default_collider_desc(HEIGHT_FIELD) };
}

fn void? project_height_field_windows(void* component, void* value, serial::WriteContext* context) @private {
    HeightFieldWindows* windows = component;
    (void)check_window_template(context.assets, &windows.collider, windows.window_cells)!;
    *(HeightFieldWindowsAuthoring*)value = { .window_cells = windows.window_cells, .collider = windows.collider };
}

fn void? validate_height_field_windows(void* value, serial::ReadContext* context) @private {
    HeightFieldWindowsAuthoring* source = value;
    if (source.window_cells < 1) return c3d::INVALID_ARGUMENT~;
    (void)check_window_template(context.assets, &source.collider, source.window_cells)!;
}

fn void? attach_height_field_windows(void* value, serial::ReadContext* context) @private {
    HeightFieldWindowsAuthoring* source = value;
    add_height_field_windows(
        scene:        context.scene,
        assets:       context.assets,
        node:         context.node.id,
        collider:     &source.collider,
        window_cells: source.window_cells,
    )!;
}

// The window nodes and their bodies regenerate on load, so only the owner and the template are written.
fn void? collect_height_field_windows(void* component, serial::WriteContext* context) @private {
    HeightFieldWindows* windows = component;
    uint body_slot = ecs::slot_of(PhysicsBody)!;
    foreach (uint index, entity : windows.nodes) {
        if (!context.scene.world.is_alive(entity)) return c3d::INVALID_ARGUMENT~;

        Node* window = context.scene.node(entity);
        HeightFieldWindowOwner* owner = context.scene.get(window, HeightFieldWindowOwner);
        if (!owner || !c3d::same_id(owner.terrain, context.node.id) || owner.index != index
            || window.parent != context.node || !context.scene.has(window, PhysicsBody)) {
            return c3d::INVALID_ARGUMENT~;
        }

        context.omit_component(window, body_slot)!;
        context.omit_node(window)!;
    }
}

fn void? collect_height_field_window(void* component, serial::WriteContext* context) @private {
    HeightFieldWindowOwner* owner = component;
    if (!context.scene.world.is_alive(owner.terrain)) return c3d::INVALID_ARGUMENT~;

    Node* terrain = context.scene.node(owner.terrain);
    if (!context.contains_node(terrain) || context.node.parent != terrain || !context.scene.has(terrain, HeightFieldWindows)) {
        return c3d::INVALID_ARGUMENT~;
    }

    HeightFieldWindows* windows = context.scene.get(terrain, HeightFieldWindows);
    if (owner.index >= windows.nodes.len || !c3d::same_id(windows.nodes[owner.index], context.node.id)) {
        return c3d::INVALID_ARGUMENT~;
    }
}
