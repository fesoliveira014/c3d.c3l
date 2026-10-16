module grid_example;

import std::io;
import std::math;
import std::time;
import std::time::clock;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::nav;
import c3d::platform;
import c3d::render;
import c3d::scene;
import c3d::spatial;
import imgui;

const int      MAP_SIDE @local = 48; // cells; three nav tiles per side
const int      TILE_CELLS @local = 16;
const int      MAP_TILES @local = MAP_SIDE / TILE_CELLS;
const float    CELL_SIZE @local = 1; // metres; the coarse mode erodes whole source cells
const float    MAP_WORLD_SIZE @local = MAP_SIDE * CELL_SIZE;
const float    MAP_TOP @local = 6; // metres; every floor and ceiling lies below it
const float    TERRACE_STEP @local = 0.6f; // metres; within the 0.9 m climb
const float    STAIR_STEP @local = 0.5f;
const float    BRIDGE_HEIGHT @local = 3;
const float    BRIDGE_THICKNESS @local = 0.3f; // the deck's underside is the ceiling of the corridor below
const float    WALL_HEIGHT @local = 2;
const uint     AGENT_COUNT @local = 10;
const uint     CROWD_CAPACITY @local = 16;
const uint     SCENE_NODE_CAPACITY @local = 1024; // a node per wall cell and per block run, two per agent
const int[<2>] SPAWN_CELL @local = { 7, 40 }; // open ground south of the long walls
const int      SPAWN_SPACING @local = 3; // cells between agents
const int      SPAWN_ROW @local = 5; // agents per row
const int[<2>] ORDINARY_TILE @local = { 0, 0 };
const int[<2>] FAN_IN_TILE @local = { 1, 1 };
const int      FAN_IN_WEST_WALL @local = 14; // outside tile column 1; one-cell erosion stops at x = 16
const int      FAN_IN_EAST_WALL @local = 33; // outside tile column 1; one-cell erosion stops at x = 32
const int      FAN_IN_NORTH_WALL @local = 25; // bounds the hall in tile (1, 1) to one rectangle polygon
const int      FAN_IN_HALL_START @local = 26;
const int      FAN_IN_SEAM_Z @local = 32; // tile border between (1, 1) and (1, 2)
const int      FAN_IN_STRIP_END @local = 36; // four cells deep of alternating step strips in tile (1, 2)
const int[<2>] FAN_IN_SPAWN_CELL @local = { 17, 28 }; // western half of the hall in tile (1, 1)
const int      FAN_IN_SPAWN_SPACING @local = 2;
const Vec3     FAN_IN_GOAL @local = { 18.5f, 0, 40.5f }; // western side of tile (1, 2), south of the strips
const Vec3     FAN_IN_CAMERA_START @local = { 24, 18, 48 };
const float    FAN_IN_CAMERA_PITCH @local = -0.75f;
const float    AGENT_BODY_RADIUS @local = 0.6f; // the default agent's radius, so drawn bodies show real overlap
const float    AGENT_BODY_HEIGHT @local = 0.8f; // between the hemisphere centres; two metres tall in all
const float    AGENT_BODY_LIFT @local = 1; // metres from the agent's floor point to the capsule's centre
const float    MIN_STEP @local = 0.001f; // seconds; the crowd needs a positive step
const float    MAX_STEP @local = 0.05f; // seconds; a stalled frame does not throw agents across walls
const float    PICK_NUDGE @local = 0.01f; // metres along the ray; a hit on a wall's side lands inside the wall
const usz      PATH_POINT_CAPACITY @local = 64;
const float    GRID_LIFT @local = 0.02f; // metres; cell lines draw just above the ground
const uint     GRID_LINE_COLOR @local = 0xFF505050;
const uint     TILE_LINE_COLOR @local = 0xFFFFFFFF;
const uint     PATH_COLOR @local = 0xFF20E0FF;
const uint     GOAL_COLOR @local = 0xFF4040FF;
const float    MARKER_RADIUS @local = 0.35f;
const double   NANOSECONDS_PER_MILLISECOND @local = 1_000_000.0;
const float    FREE_LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float    FREE_PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float    FREE_SPEED @local = 10;
const float    FREE_FAST_MULTIPLIER @local = 4;
const float    FREE_SPEED_WHEEL_STEP @local = 1.25f;
const Vec3     CAMERA_START @local = { 24, 30, 56 };
const float    CAMERA_START_PITCH @local = -0.8f;
const Vec2     PANEL_POSITION @local = { 16, 16 };
const Vec2     PANEL_SIZE @local = { 470, 460 };
const int[<2>] PATCH_ORIGIN @local = { 36, 36 };
const int PATCH_SIDE @local = 8;
const float PATCH_BASE @local = 0.05f;
const float PATCH_RISE @local = 0.6f;
const float PATCH_CEILING_BASE @local = 2;
const float PATCH_CEILING_RISE @local = 2;
const Vec3 PATCH_CAMERA_START @local = { 40, 12, 52 };
const uint SUB_CELL_SUBDIVISION @local = 4;
const float DETAIL_HEIGHT_ERROR @local = 0.01f;
const usz DETAIL_SCRATCH_BYTES @local = 2 * 1024 * 1024;
const usz SUB_CELL_SCRATCH_BYTES @local = 8 * 1024 * 1024; // two floors over a 24x24 window, four clipped fans per floor
const usz DEBUG_LINE_CAPACITY @local = 131072; // 4 MiB of vertices for complete detail and crowd paths

// '.' ground, '#' wall, '1' to '3' terraces, 'a' to 'f' stair steps, 'P' platform, '=' bridge over the corridor.
const String[] LEVEL_MAP @local = {
    "################################################",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#......#....................111111111111.......#",
    "#......#....................111111111111.......#",
    "#......#....................112222222211.......#",
    "#......#....................112222222211.......#",
    "#......###########..........112233332211.......#",
    "#......#....................112233332211.......#",
    "#......#....................112233332211.......#",
    "#......#....................112233332211.......#",
    "#......#....................112222222211.......#",
    "#......#....................112222222211.......#",
    "#......#....................111111111111.......#",
    "#......#....................111111111111.......#",
    "#......#.......................................#",
    "#......#.......................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............PPPPPP....PPPPPP................#",
    "#..............PPPPPP....PPPPPP................#",
    "#........abcdefPPPPPP====PPPPPPfedcba..........#",
    "#........abcdefPPPPPP====PPPPPPfedcba..........#",
    "#........abcdefPPPPPP====PPPPPPfedcba..........#",
    "#........abcdefPPPPPP====PPPPPPfedcba..........#",
    "#..............PPPPPP====PPPPPP................#",
    "#..............PPPPPP....PPPPPP................#",
    "#..............PPPPPP....PPPPPP................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#.......##############....##################...#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "#..............................................#",
    "################################################",
};

enum PatchSurface @local {
    PLANE,
    RAMP,
    SADDLE,
}

struct FreeCamera @local {
    Vec3  position;
    float yaw;
    float pitch;
    float speed;
}

struct Controls @local {
    NavMeshDebugOptions mesh;
    bool                cells;
    bool                paths;
}

// The application's own grid storage; the builder reads it through level_floors.
struct GridLevel @local {
    char[MAP_SIDE * MAP_SIDE]  cells;
    Node*[MAP_SIDE * MAP_SIDE] walls;
    GeometryId                 cube;
    MaterialId                 wall_material;
    MaterialId                 agent_material;
    Node*                      camera_node;
    bool                       patch_enabled;
    PatchSurface               surface;
    bool                       alternate_diagonal;
    bool                       sloped_ceiling;
    bool                       narrow_passage;
    GeometryId                 patch_geometry;
    GeometryId                 ceiling_geometry;
    Node*                      ceiling_node;
    Node*[2]                   passage_walls;
}

struct Agents @local {
    Node*[AGENT_COUNT] nodes;
    Vec3               goal;
    bool               has_goal;
}

struct RebuildStats @local {
    uint  last_tiles;
    uint  total_tiles;
    float last_milliseconds;
}

struct TileInstallTiming @local {
    float build_milliseconds;
    float install_milliseconds;
    uint  free_links;
}

struct GridPick @local {
    Vec3     position;
    int[<2>] cell;
}

fn Vec3 free_forward(FreeCamera* camera) @local {
    return {
        math::cos(camera.pitch) * math::sin(camera.yaw),
        math::sin(camera.pitch),
        math::cos(camera.pitch) * math::cos(camera.yaw),
    };
}

fn void apply_free_camera(
    FreeCamera* camera,
    Input* input,
    Node* camera_node,
    float delta_seconds,
) @local {
    if (!input.mouse_captured_by_gui) {
        if (input.button_down(platform::MouseButton.RIGHT)) {
            camera.yaw -= input.mouse_delta.x * FREE_LOOK_RADIANS_PER_PIXEL;
            camera.pitch = math::clamp(
                camera.pitch - input.mouse_delta.y * FREE_LOOK_RADIANS_PER_PIXEL,
                -FREE_PITCH_LIMIT,
                FREE_PITCH_LIMIT,
            );
        }
        if (input.wheel != 0) camera.speed *= math::pow(FREE_SPEED_WHEEL_STEP, input.wheel);
    }
    Vec3 forward = free_forward(camera);
    Vec3 up = { 0, 1, 0 };
    Vec3 right = forward.cross(up).normalize();
    if (!input.keyboard_captured_by_gui) {
        Vec3 direction;
        if (input.key_down(platform::Scancode.W)) direction += forward;
        if (input.key_down(platform::Scancode.S)) direction -= forward;
        if (input.key_down(platform::Scancode.D)) direction += right;
        if (input.key_down(platform::Scancode.A)) direction -= right;
        if (input.key_down(platform::Scancode.E)) direction += up;
        if (input.key_down(platform::Scancode.Q)) direction -= up;
        float speed = camera.speed * (input.key_down(platform::Scancode.LSHIFT) ? FREE_FAST_MULTIPLIER : 1);
        camera.position += direction * (speed * delta_seconds);
    }
    camera_node.local.position = camera.position;
    camera_node.local.rotation = maths::look_rotation(forward, up);
}

// Top of the solid under a cell's surface; a wall's top is solid but not walkable.
fn float surface_height(char cell) @local {
    switch (cell) {
        case '#':
            return WALL_HEIGHT;
        case '1'..'3':
            return (float)(cell - '0') * TERRACE_STEP;
        case 'a'..'f':
            return (float)(cell - 'a' + 1) * STAIR_STEP;
        case 'P':
        case '=':
            return BRIDGE_HEIGHT;
        default:
            return 0;
    }
}

fn usz level_floors(
    void* context,
    int cell_x,
    int cell_z,
    GridFloor[] out_floors,
) @local {
    if (cell_x < 0 || cell_z < 0 || cell_x >= MAP_SIDE || cell_z >= MAP_SIDE) return 0;
    GridLevel* level = context;
    if (level.patch_enabled && patch_contains({ cell_x, cell_z })) {
        out_floors[0] = patch_floor(level, cell_x - PATCH_ORIGIN.x, cell_z - PATCH_ORIGIN.y);
        return 1;
    }
    char cell = level.cells[cell_x + cell_z * MAP_SIDE];
    float top = surface_height(cell);
    if (cell == '=') {
        out_floors[0] = { .height = 0, .ceiling = top - BRIDGE_THICKNESS, .area = nav::WALKABLE_AREA };
        out_floors[1] = { .height = top, .ceiling = float::max, .area = nav::WALKABLE_AREA };
        return 2;
    }
    char area = cell == '#' ? nav::NULL_AREA : nav::WALKABLE_AREA;
    out_floors[0] = { .height = top, .ceiling = float::max, .area = area };
    return 1;
}

fn MaterialId? add_colour(AssetStore* assets, Vec4 color, String key) @local {
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = color;
    params.metallic = 0;
    params.roughness = 0.85f;
    return assets.add_material(material::standard(params), key);
}

fn bool patch_contains(int[<2>] cell) @local {
    return cell.x >= PATCH_ORIGIN.x && cell.x < PATCH_ORIGIN.x + PATCH_SIDE
        && cell.y >= PATCH_ORIGIN.y && cell.y < PATCH_ORIGIN.y + PATCH_SIDE;
}

fn float patch_height(GridLevel* level, int x, int z) @local {
    switch (level.surface) {
        case PLANE: return PATCH_BASE;
        case RAMP: return PATCH_BASE + PATCH_RISE * (float)x / (float)PATCH_SIDE;
        case SADDLE: return PATCH_BASE + (((x + z) & 1) != 0 ? PATCH_RISE : 0);
    }
}

fn GridFloor patch_floor(GridLevel* level, int x, int z) @local {
    GridFloor floor = {
        .height = PATCH_BASE,
        .ceiling = float::max,
        .area = level.narrow_passage && (x == 2 || x == 5) ? nav::NULL_AREA : nav::WALKABLE_AREA,
        .floor_kind = level.surface == PatchSurface.PLANE ? GridSurfaceKind.FLAT : GridSurfaceKind.CORNERS,
        .ceiling_kind = level.sloped_ceiling ? GridSurfaceKind.CORNERS : GridSurfaceKind.FLAT,
        .diagonal = level.alternate_diagonal ? GridDiagonal.MAX_MIN_TO_MIN_MAX : GridDiagonal.MIN_MIN_TO_MAX_MAX,
    };
    int[4] corners_x = { x, x + 1, x + 1, x };
    int[4] corners_z = { z, z, z + 1, z + 1 };
    for (uint corner = 0; corner < 4; corner++) {
        floor.floor_corners[corner] = patch_height(level, corners_x[corner], corners_z[corner]);
        floor.ceiling_corners[corner] = PATCH_CEILING_BASE
            + PATCH_CEILING_RISE * (float)corners_x[corner] / (float)PATCH_SIDE;
    }
    return floor;
}

fn Geometry patch_mesh(Allocator allocator, GridLevel* level, bool ceiling) @local {
    Geometry geometry = { .positions = alloc::new_array(allocator, Vec3, PATCH_SIDE * PATCH_SIDE * 6) };
    usz written;
    for (int z = 0; z < PATCH_SIDE; z++) {
        for (int x = 0; x < PATCH_SIDE; x++) {
            GridFloor floor = patch_floor(level, x, z);
            float first_x = (float)(PATCH_ORIGIN.x + x) * CELL_SIZE;
            float first_z = (float)(PATCH_ORIGIN.y + z) * CELL_SIZE;
            Vec3[4] corners = {
                { first_x, 0, first_z },
                { first_x + CELL_SIZE, 0, first_z },
                { first_x + CELL_SIZE, 0, first_z + CELL_SIZE },
                { first_x, 0, first_z + CELL_SIZE },
            };
            for (uint corner = 0; corner < 4; corner++) {
                corners[corner].y = ceiling ? floor.ceiling_corners[corner] : floor.floor_corners[corner];
            }
            uint[6] order = level.alternate_diagonal ? (uint[6]){ 0, 3, 1, 1, 3, 2 }
              : (uint[6]){ 0, 2, 1, 0, 3, 2 };
            foreach (corner : order) geometry.positions[written++] = corners[corner];
        }
    }
    geometry.compute_normals(allocator, false);
    geometry.finalize();
    return geometry;
}

fn void? add_patch(AssetStore* assets, Scene* scene, GridLevel* level) @local {
    MaterialId floor_material = add_colour(assets, { 0.3f, 0.6f, 0.85f, 1 }, "grid/authored_floor_material")!;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.depth_write = false;
    common.double_sided = true;
    BasicParams ceiling_params = material::BASIC_PARAMS_DEFAULT;
    ceiling_params.color = { 1, 0.65f, 0.2f, 0.2f };
    MaterialId ceiling_material = assets.add_material(material::basic(ceiling_params, common), "grid/authored_ceiling_material")!;
    @pool() {
        Geometry floor = patch_mesh(tmem, level, false);
        Geometry ceiling = patch_mesh(tmem, level, true);
        level.patch_geometry = assets.add_geometry(&floor, "grid/authored_floor")!;
        level.ceiling_geometry = assets.add_geometry(&ceiling, "grid/authored_ceiling")!;
    };
    scene.add_mesh(level.patch_geometry, floor_material, name: "authored floor")!;
    level.ceiling_node = scene.add_mesh(level.ceiling_geometry, ceiling_material, name: "sloped ceiling")!;
    level.ceiling_node.visible = level.sloped_ceiling;
    for (uint side = 0; side < 2; side++) {
        float x = (float)(PATCH_ORIGIN.x + (side ? 5 : 2)) * CELL_SIZE;
        level.passage_walls[side] = add_box(
            scene: scene,
            cube: level.cube,
            material: level.wall_material,
            box: {
                .min = { x, 0, (float)PATCH_ORIGIN.y * CELL_SIZE },
                .max = { x + CELL_SIZE, WALL_HEIGHT + PATCH_RISE, (float)(PATCH_ORIGIN.y + PATCH_SIDE) * CELL_SIZE },
            },
        )!;
        level.passage_walls[side].visible = level.narrow_passage;
    }
}

fn Node*? add_box(
    Scene* scene,
    GeometryId cube,
    MaterialId material,
    Aabb box,
) @local {
    Node* node = scene.add_mesh(cube, material)!;
    node.local.position = (box.min + box.max) * 0.5f;
    node.local.scale = box.max - box.min;
    return node;
}

fn Node*? add_wall(Scene* scene, GridLevel* level, int[<2>] cell) @local {
    return add_box(
        scene:    scene,
        cube:     level.cube,
        material: level.wall_material,
        box:      {
            .min = { (float)cell.x * CELL_SIZE, 0, (float)cell.y * CELL_SIZE },
            .max = { (float)(cell.x + 1) * CELL_SIZE, WALL_HEIGHT, (float)(cell.y + 1) * CELL_SIZE },
        },
    );
}

// One box per run of equal raised cells along a row; walls get a node per cell so a click can remove one.
fn void? add_blocks(Scene* scene, GridLevel* level, MaterialId[4] materials) @local {
    for (int cell_z = 0; cell_z < MAP_SIDE; cell_z++) {
        int run_start;
        for (int cell_x = 0; cell_x <= MAP_SIDE; cell_x++) {
            char current = cell_x < MAP_SIDE ? level.cells[cell_x + cell_z * MAP_SIDE] : '.';
            char first = level.cells[run_start + cell_z * MAP_SIDE];
            if (cell_x < MAP_SIDE && current == first) continue;
            if (first != '.' && first != '#') {
                float top = surface_height(first);
                float bottom = first == '=' ? top - BRIDGE_THICKNESS : 0;
                add_box(
                    scene:    scene,
                    cube:     level.cube,
                    material: materials[block_kind(first)],
                    box:      {
                        .min = { (float)run_start * CELL_SIZE, bottom, (float)cell_z * CELL_SIZE },
                        .max = { (float)cell_x * CELL_SIZE, top, (float)(cell_z + 1) * CELL_SIZE },
                    },
                )!;
            }
            run_start = cell_x;
        }
        for (int cell_x = 0; cell_x < MAP_SIDE; cell_x++) {
            int cell = cell_x + cell_z * MAP_SIDE;
            if (level.cells[cell] == '#') level.walls[cell] = add_wall(scene, level, { cell_x, cell_z })!;
        }
    }
}

fn usz block_kind(char cell) @local {
    switch (cell) {
        case '1'..'3':
            return 0;
        case 'a'..'f':
            return 1;
        case 'P':
            return 2;
        default:
            return 3;
    }
}

// One wide hall polygon in tile (1, 1) faces 16 alternating floor and step segments across the z = 32 border.
fn void apply_fan_in(GridLevel* level) @local {
    for (int cell_x = FAN_IN_WEST_WALL; cell_x <= FAN_IN_EAST_WALL; cell_x++) {
        level.cells[cell_x + FAN_IN_NORTH_WALL * MAP_SIDE] = '#';
    }
    for (int cell_z = FAN_IN_HALL_START; cell_z <= FAN_IN_STRIP_END; cell_z++) {
        level.cells[FAN_IN_WEST_WALL + cell_z * MAP_SIDE] = '#';
        level.cells[FAN_IN_EAST_WALL + cell_z * MAP_SIDE] = '#';
        for (int cell_x = FAN_IN_WEST_WALL + 1; cell_x < FAN_IN_EAST_WALL; cell_x++) {
            bool strip = cell_z >= FAN_IN_SEAM_Z && cell_z < FAN_IN_STRIP_END && cell_x >= TILE_CELLS &&
                cell_x < TILE_CELLS * 2 && (cell_x & 1) != 0;
            level.cells[cell_x + cell_z * MAP_SIDE] = strip ? 'a' : '.';
        }
    }
}

fn GridLevel*? build_level(
    AssetStore* assets,
    Scene* scene,
    bool fan_in,
    bool bounded_detail,
) @local {
    GridLevel* level = mem::new(GridLevel);
    defer catch free(level);
    foreach (cell_z, row : LEVEL_MAP) level.cells[cell_z * MAP_SIDE:MAP_SIDE] = row[..];
    if (fan_in) apply_fan_in(level);
    level.patch_enabled = bounded_detail;
    if (bounded_detail) {
        for (int cell_z = PATCH_ORIGIN.y; cell_z < PATCH_ORIGIN.y + PATCH_SIDE; cell_z++) {
            for (int cell_x = PATCH_ORIGIN.x; cell_x < PATCH_ORIGIN.x + PATCH_SIDE; cell_x++) {
                level.cells[cell_x + cell_z * MAP_SIDE] = '.';
            }
        }
    }

    MaterialId ground_material = add_colour(assets, { 0.5f, 0.56f, 0.5f, 1 }, "grid/ground")!;
    level.wall_material = add_colour(assets, { 0.45f, 0.45f, 0.5f, 1 }, "grid/wall")!;
    level.agent_material = add_colour(assets, { 0.2f, 0.7f, 0.35f, 1 }, "grid/agent")!;
    MaterialId[4] block_materials = {
        add_colour(assets, { 0.8f, 0.68f, 0.45f, 1 }, "grid/terrace")!,
        add_colour(assets, { 0.9f, 0.5f, 0.25f, 1 }, "grid/stair")!,
        add_colour(assets, { 0.3f, 0.5f, 0.9f, 1 }, "grid/platform")!,
        add_colour(assets, { 0.55f, 0.35f, 0.2f, 1 }, "grid/bridge")!,
    };

    GeometryId ground;
    @pool() {
        Geometry cube = geometry::box(tmem, 1, 1, 1);
        level.cube = assets.add_geometry(&cube, "grid/cube")!;
        Geometry plane = geometry::plane(tmem, MAP_WORLD_SIZE, MAP_WORLD_SIZE);
        ground = assets.add_geometry(&plane, "grid/ground_plane")!;
    };
    Node* ground_node = scene.add_mesh(ground, ground_material, name: "ground")!;
    ground_node.local.position = { MAP_WORLD_SIZE * 0.5f, 0, MAP_WORLD_SIZE * 0.5f };
    add_blocks(scene, level, block_materials)!;
    if (bounded_detail) add_patch(assets, scene, level)!;

    Node* sun = scene.add_light(light::directional({ 1, 0.95f, 0.85f }, 3), name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.3f }).normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = { 0.55f, 0.7f, 0.9f, 1 } };
    level.camera_node = scene.add_camera(camera::perspective_deg(60, 0.1f), name: "camera")!;
    return level;
}

fn TileInstallTiming? install_tile(GridTileBuilder* builder, NavMesh* mesh, int[<2>] tile) @local {
    NavBuildConfig config = builder.config;
    time::Clock build_start = clock::now();
    char[] tile_mesh = builder.build(tile.x, tile.y)!;

    time::Clock install_start = clock::now();
    mesh.install_tile_mesh(
        tile_mesh:   tile_mesh,
        connections: {},
        params:      {
            .tile_x          = tile.x,
            .tile_z          = tile.y,
            .walkable_height = config.agent_height,
            .walkable_radius = config.agent_radius,
            .walkable_climb  = config.agent_max_climb,
            .build_bv_tree   = true,
        },
    )!;
    time::Clock finished = clock::now();

    return {
        .build_milliseconds   = (float)((double)(install_start - build_start) / NANOSECONDS_PER_MILLISECOND),
        .install_milliseconds = (float)((double)(finished - install_start) / NANOSECONDS_PER_MILLISECOND),
        .free_links           = mesh.free_links(),
    };
}

// A cell inside a neighbour's border changes that tile's window too, so it is rebuilt as well.
fn uint? rebuild_around(GridTileBuilder* builder, NavMesh* mesh, int[<2>] cell) @local {
    int border = (int)builder.tile_config.border_size;
    int[<2>] first = math::max((cell - border) / TILE_CELLS, (int[<2>]){ 0, 0 });
    int[<2>] last = math::min((cell + border) / TILE_CELLS, (int[<2>]){ MAP_TILES - 1, MAP_TILES - 1 });
    uint rebuilt;
    for (int tile_z = first.y; tile_z <= last.y; tile_z++) {
        for (int tile_x = first.x; tile_x <= last.x; tile_x++) {
            (void)install_tile(builder, mesh, { tile_x, tile_z })!;
            rebuilt++;
        }
    }
    return rebuilt;
}

// Only ground and wall cells toggle, so a wall never lands inside a raised block.
fn bool is_toggleable(GridLevel* level, int[<2>] cell) @local {
    if (cell.x < 0 || cell.y < 0 || cell.x >= MAP_SIDE || cell.y >= MAP_SIDE) return false;
    if (level.patch_enabled && patch_contains(cell)) return false;
    char kind = level.cells[cell.x + cell.y * MAP_SIDE];
    return kind == '.' || kind == '#';
}

fn void? toggle_wall(Scene* scene, GridLevel* level, int[<2>] cell) @local {
    int index = cell.x + cell.y * MAP_SIDE;
    if (level.cells[index] == '#') {
        level.cells[index] = '.';
        scene.remove(level.walls[index]);
        level.walls[index] = null;
        return;
    }
    level.cells[index] = '#';
    level.walls[index] = add_wall(scene, level, cell)!;
}

fn void? spawn_agents(
    AssetStore* assets,
    Scene* scene,
    GridLevel* level,
    Agents* agents,
    bool fan_in,
) @local {
    GeometryId body;
    @pool() {
        Geometry capsule = geometry::capsule(tmem, AGENT_BODY_RADIUS, AGENT_BODY_HEIGHT);
        body = assets.add_geometry(&capsule, "grid/agent_body")!;
    };

    int[<2>] start_cell = fan_in ? FAN_IN_SPAWN_CELL : SPAWN_CELL;
    int spacing = fan_in ? FAN_IN_SPAWN_SPACING : SPAWN_SPACING;
    for (int index = 0; index < (int)AGENT_COUNT; index++) {
        int[<2>] cell = start_cell + (int[<2>]){ index % SPAWN_ROW, index / SPAWN_ROW } * spacing;
        Node* node = scene.add_node(name: "agent")!;
        node.local.position = { ((float)cell.x + 0.5f) * CELL_SIZE, 0, ((float)cell.y + 0.5f) * CELL_SIZE };
        Node* mesh = scene.add_mesh(body, level.agent_material, parent: node)!;
        mesh.local.position = { 0, AGENT_BODY_LIFT, 0 };
        agents.nodes[index] = node;
    }
    scene.update_world();
    NavAgentParams params = nav::default_nav_agent_params();
    foreach (node : agents.nodes) scene.add_nav_agent(node, params)!;
}

fn GridPick? pick(
    AssetStore* assets,
    Scene* scene,
    Node* camera_node,
    Vec2 pixel,
    Vec2 viewport,
) @local {
    camera::Camera* camera = scene.get(camera_node, camera::Camera);
    CameraMatrices matrices = camera::derive_matrices(*camera, camera_node.world, viewport);
    Ray ray = camera::screen_to_ray(&matrices, pixel, viewport);
    @pool() {
        PickHit[] hits = spatial::pick(
            allocator: tmem,
            assets:    assets,
            scene:     scene,
            ray:       ray,
            options:   { .precision = TRIANGLES, .faces = MATERIAL, .layers = camera::ALL_LAYERS },
        );
        if (!hits.len) return NOT_FOUND~;
        Vec3 inside = hits[0].position + ray.direction * PICK_NUDGE;
        return {
            .position = hits[0].position,
            .cell     = { (int)math::floor(inside.x / CELL_SIZE), (int)math::floor(inside.z / CELL_SIZE) },
        };
    };
}

fn void send_agents(Scene* scene, Agents* agents, Vec3 goal) @local {
    agents.goal = goal;
    agents.has_goal = true;
    foreach (node : agents.nodes) scene.set_nav_target(node, goal);
}

// The edited tiles are built and installed within the frame of the click, before the crowd update.
fn void? edit_wall(
    Scene* scene,
    GridLevel* level,
    GridTileBuilder* builder,
    NavMesh* mesh,
    RebuildStats* stats,
    int[<2>] cell,
) @local {
    if (!is_toggleable(level, cell)) return;
    time::Clock started = clock::now();
    toggle_wall(scene, level, cell)!;
    stats.last_tiles = rebuild_around(builder, mesh, cell)!;
    stats.last_milliseconds = (float)((double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND);
    stats.total_tiles += stats.last_tiles;
}

fn bool draw_panel(
    Controls* controls,
    RebuildStats* stats,
    GridLevel* level,
    GridTileBuilder* builder,
    debug::DebugDraw* sink,
) @local {
    bool changed;
    imgui::set_next_window_pos(PANEL_POSITION, imgui::COND_FIRST_USE_EVER);
    imgui::set_next_window_size(PANEL_SIZE, imgui::COND_FIRST_USE_EVER);
    if (imgui::begin("Grid navmesh", null, {})) {
        imgui::text("Click sends every agent; Ctrl+click toggles a wall on the ground");
        imgui::text("Right drag looks, WASDQE move");
        imgui::checkbox("Cells and tiles", &controls.cells);
        imgui::checkbox("Polygons", &controls.mesh.polys);
        imgui::checkbox("Detail triangles", &controls.mesh.detail);
        imgui::checkbox("Portals", &controls.mesh.links);
        imgui::checkbox("Paths", &controls.paths);
        imgui::separator();
        imgui::text("Surface: %s", level.patch_enabled ? "bounded".ptr : "coarse".ptr);
        bool sub_cell = builder.config.clearance_mode == ClearanceMode.SUB_CELL;
        imgui::text("Clearance: %s", sub_cell ? "sub-cell".ptr : "whole-cell".ptr);
        imgui::text("Build radius: %.3f m", builder.config.agent_radius);
        if (level.patch_enabled) imgui::text("Height error: %.3f m", builder.config.detail_max_error);
        imgui::text("Sub-cell error: %.3f m", builder.config.clearance_max_error);
        if (sub_cell) {
            imgui::same_line();
            imgui::text("N=%u", builder.tile_config.subdivision);
        }
        imgui::separator();
        imgui::text("Authored patch: southeast corner");
        imgui::begin_disabled(!level.patch_enabled);
        if (imgui::radio_button("Plane", level.surface == PatchSurface.PLANE) && level.surface != PatchSurface.PLANE) {
            level.surface = PatchSurface.PLANE;
            changed = true;
        }
        imgui::same_line();
        if (imgui::radio_button("Ramp", level.surface == PatchSurface.RAMP) && level.surface != PatchSurface.RAMP) {
            level.surface = PatchSurface.RAMP;
            changed = true;
        }
        imgui::same_line();
        if (imgui::radio_button("Saddle", level.surface == PatchSurface.SADDLE) && level.surface != PatchSurface.SADDLE) {
            level.surface = PatchSurface.SADDLE;
            changed = true;
        }
        changed |= imgui::checkbox("Alternate saddle diagonal", &level.alternate_diagonal);
        changed |= imgui::checkbox("Sloped ceiling", &level.sloped_ceiling);
        changed |= imgui::checkbox("Two-cell passage", &level.narrow_passage);
        imgui::end_disabled();
        if (!level.patch_enabled) imgui::text("Use --detail or --sub-cell to edit the authored patch");
        imgui::separator();
        imgui::text("Tiles rebuilt by the last edit: %u in %.2f ms", stats.last_tiles, stats.last_milliseconds);
        imgui::text("Tiles rebuilt since start: %u", stats.total_tiles);
        imgui::text("Debug lines: %u emitted, %u dropped", (uint)sink.vertices.len() / 2, (uint)sink.dropped);
    }
    imgui::end();
    return changed;
}

fn void? update_patch(
    AssetStore* assets,
    Scene* scene,
    GridLevel* level,
    GridTileBuilder* builder,
    NavMesh* mesh,
    RebuildStats* stats,
) @local {
    time::Clock started = clock::now();
    @pool() {
        Geometry floor = patch_mesh(tmem, level, false);
        Geometry ceiling = patch_mesh(tmem, level, true);
        assets.replace_geometry(level.patch_geometry, &floor)!;
        assets.replace_geometry(level.ceiling_geometry, &ceiling)!;
    };
    level.ceiling_node.visible = level.sloped_ceiling;
    foreach (wall : level.passage_walls) wall.visible = level.narrow_passage;
    scene.update_world();
    int border = (int)builder.tile_config.border_size;
    int[<2>] first = math::max((PATCH_ORIGIN - border) / TILE_CELLS, (int[<2>]){ 0, 0 });
    int[<2>] last = math::min((PATCH_ORIGIN + PATCH_SIDE - 1 + border) / TILE_CELLS,
        (int[<2>]){ MAP_TILES - 1, MAP_TILES - 1 });
    stats.last_tiles = 0;
    for (int z = first.y; z <= last.y; z++) {
        for (int x = first.x; x <= last.x; x++) {
            (void)install_tile(builder, mesh, { x, z })!;
            stats.last_tiles++;
        }
    }
    stats.last_milliseconds = (float)((double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND);
    stats.total_tiles += stats.last_tiles;
}

fn void draw_cells(debug::DebugDraw* sink) @local {
    for (int line = 0; line <= MAP_SIDE; line++) {
        float offset = (float)line * CELL_SIZE;
        uint color = line % TILE_CELLS == 0 ? TILE_LINE_COLOR : GRID_LINE_COLOR;
        sink.line({ offset, GRID_LIFT, 0 }, { offset, GRID_LIFT, MAP_WORLD_SIZE }, color);
        sink.line({ 0, GRID_LIFT, offset }, { MAP_WORLD_SIZE, GRID_LIFT, offset }, color);
    }
}

fn void draw_paths(Crowd* crowd, debug::DebugDraw* sink) @local {
    StraightPoint[PATH_POINT_CAPACITY] points;
    foreach (&agent : crowd.agents) {
        if (!agent.active || !agent.corridor.count) continue;
        PathResult? path = crowd.query.straight_path(
            start:      agent.position,
            end:        agent.corridor.target,
            path:       agent.corridor.polys(),
            out_points: points[..],
        );
        if (try path) nav::debug_draw_path(sink, points[:path.count], PATH_COLOR);
    }
}

fn void draw_debug(
    NavMesh* mesh,
    Crowd* crowd,
    Agents* agents,
    Controls* controls,
    debug::DebugDraw* sink,
) @local {
    sink.clear();
    if (controls.cells) draw_cells(sink);
    mesh.debug_draw(sink, controls.mesh);
    crowd.debug_draw(sink, { .agents = true });
    if (controls.paths) draw_paths(crowd, sink);
    if (!agents.has_goal) return;
    sink.circle(
        center: agents.goal,
        normal: { 0, 1, 0 },
        radius: MARKER_RADIUS,
        rgba:   GOAL_COLOR,
    );
}

fn void? draw_frame(
    render::Renderer* renderer,
    Scene* scene,
    Node* camera_node,
    GuiRenderer* gui_renderer,
    debug::DebugDraw* sink,
    FrameInfo info,
) @local {
    renderer.begin_frame(info)!;
    defer catch render::abort_frame(renderer);
    if (renderer.has_output) {
        renderer.render_view(scene, camera_node, renderer.default_view, sink)!;
        renderer.finish_view(renderer.default_view)!;
        OverlayContext overlay = renderer.begin_overlay()!;
        gui_renderer.record(&overlay)!;
        renderer.end_overlay(&overlay)!;
    }
    return renderer.end_frame();
}

fn void? run(
    platform::Window* window,
    render::Renderer* renderer,
    AssetStore* assets,
    Scene* scene,
    bool fan_in,
    NavBuildConfig config,
    uint frame_limit,
) @local {
    bool bounded_detail = config.detail_mode == DetailMode.BOUNDED;
    bool sub_cell = config.clearance_mode == ClearanceMode.SUB_CELL;
    GridLevel* level = build_level(
        assets: assets,
        scene: scene,
        fan_in: fan_in,
        bounded_detail: bounded_detail,
    )!;
    defer free(level);
    scene.update_world();

    GridSourceDesc source = {
        .min_height = 0,
        .max_height = MAP_TOP,
        .floors     = &level_floors,
        .context    = level,
    };
    GridTileBuilder builder = nav::create_grid_tile_builder(
        allocator: mem,
        config: config,
        source: source,
        scratch_bytes: sub_cell ? SUB_CELL_SCRATCH_BYTES : bounded_detail ? DETAIL_SCRATCH_BYTES : nav::DEFAULT_GRID_SCRATCH_BYTES,
    )!;
    defer nav::destroy_grid_tile_builder(&builder);
    NavMesh mesh = nav::create_nav_mesh(mem, builder.mesh_desc(MAP_TILES * MAP_TILES))!;
    defer nav::destroy_nav_mesh(&mesh);
    for (int tile_z = 0; tile_z < MAP_TILES; tile_z++) {
        for (int tile_x = 0; tile_x < MAP_TILES; tile_x++) (void)install_tile(&builder, &mesh, { tile_x, tile_z })!;
    }

    if (fan_in) {
        TileInstallTiming ordinary = install_tile(&builder, &mesh, ORDINARY_TILE)!;
        TileInstallTiming seam = install_tile(&builder, &mesh, FAN_IN_TILE)!;
        io::printfn(
            "ordinary tile (%d, %d): build %.3f ms, install %.3f ms, free_links %d",
            ORDINARY_TILE.x,
            ORDINARY_TILE.y,
            ordinary.build_milliseconds,
            ordinary.install_milliseconds,
            ordinary.free_links,
        );
        io::printfn(
            "fan-in tile (%d, %d): build %.3f ms, install %.3f ms, free_links %d",
            FAN_IN_TILE.x,
            FAN_IN_TILE.y,
            seam.build_milliseconds,
            seam.install_milliseconds,
            seam.free_links,
        );
    }

    Crowd crowd = nav::create_crowd(
        allocator: mem,
        desc:      { .max_agents = CROWD_CAPACITY, .max_agent_radius = AGENT_BODY_RADIUS },
        mesh:      &mesh,
        scene:     scene,
    )!;
    defer nav::destroy_crowd(&crowd);
    Agents agents;
    spawn_agents(
        assets: assets,
        scene:  scene,
        level:  level,
        agents: &agents,
        fan_in: fan_in,
    )!;
    if (fan_in) send_agents(scene, &agents, FAN_IN_GOAL);

    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, renderer, window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw sink = debug::create_debug_draw(mem, DEBUG_LINE_CAPACITY);
    defer debug::destroy_debug_draw(&sink);

    FreeCamera camera = {
        .position = fan_in ? FAN_IN_CAMERA_START : bounded_detail ? PATCH_CAMERA_START : CAMERA_START,
        .yaw      = (float)math::PI,
        .pitch    = fan_in ? FAN_IN_CAMERA_PITCH : CAMERA_START_PITCH,
        .speed    = FREE_SPEED,
    };
    Controls controls = {
        .mesh  = { .polys = true, .links = true, .detail = bounded_detail },
        .cells = true,
        .paths = true,
    };
    RebuildStats stats;
    renderer.prepare_scene(scene)!;

    uint frames;
    while (window.poll()) {
        Input* input = &window.input;
        if (input.key_released(platform::Scancode.ESCAPE) && !input.keyboard_captured_by_gui) break;
        gui_renderer.new_frame();
        defer {
            if (gui_renderer.frame_open) gui_renderer.finish_frame();
        }
        if (draw_panel(
            controls: &controls,
            stats: &stats,
            level: level,
            builder: &builder,
            sink: &sink,
        )) {
            update_patch(
                assets: assets,
                scene: scene,
                level: level,
                builder: &builder,
                mesh: &mesh,
                stats: &stats,
            )!;
        }

        if (input.button_pressed(platform::MouseButton.LEFT) && !input.mouse_captured_by_gui) {
            GridPick? picked = pick(
                assets:      assets,
                scene:       scene,
                camera_node: level.camera_node,
                pixel:       input.mouse_position,
                viewport:    { (float)window.width, (float)window.height },
            );
            if (try picked) {
                if (input.key_down(platform::Scancode.LCTRL)) {
                    edit_wall(
                        scene:   scene,
                        level:   level,
                        builder: &builder,
                        mesh:    &mesh,
                        stats:   &stats,
                        cell:    picked.cell,
                    )!;
                } else {
                    send_agents(scene, &agents, picked.position);
                }
            }
        }
        apply_free_camera(
            camera:        &camera,
            input:         input,
            camera_node:   level.camera_node,
            delta_seconds: window.clock.delta,
        );
        scene.update_world();

        // A reinstalled tile retires its polygon refs; the crowd replans the corridors through it.
        nav::crowd_update(
            scene: scene,
            crowd: &crowd,
            dt:    math::clamp(window.clock.delta, MIN_STEP, MAX_STEP),
        );
        scene.update_world();

        draw_debug(
            mesh:     &mesh,
            crowd:    &crowd,
            agents:   &agents,
            controls: &controls,
            sink:     &sink,
        );
        gui_renderer.finish_frame();

        platform::sync_window(window, renderer);
        draw_frame(
            renderer:     renderer,
            scene:        scene,
            camera_node:  level.camera_node,
            gui_renderer: &gui_renderer,
            sink:         &sink,
            info:         { .time = window.clock.total, .delta = window.clock.delta },
        )!;
        if (frame_limit && ++frames >= frame_limit) break;
    }
}

fn int main(String[] args) {
    bool fan_in;
    bool custom_clearance_error;
    NavBuildConfig config = nav::default_grid_build_config(CELL_SIZE);
    config.tile_size = (uint)TILE_CELLS;
    uint frame_limit;
    for (usz index = 1; index < args.len; index++) {
        String arg = args[index];
        if (arg == "--fan-in") {
            fan_in = true;
        } else if (arg == "--detail") {
            config.detail_mode = DetailMode.BOUNDED;
        } else if (arg == "--sub-cell") {
            config.detail_mode = DetailMode.BOUNDED;
            config.clearance_mode = ClearanceMode.SUB_CELL;
        } else if (arg == "--radius" && index + 1 < args.len) {
            float? parsed = args[++index].to_float();
            if (catch parsed) return 1;
            config.agent_radius = parsed;
        } else if (arg == "--clearance-error" && index + 1 < args.len) {
            float? parsed = args[++index].to_float();
            if (catch parsed) return 1;
            config.clearance_max_error = parsed;
            custom_clearance_error = true;
        } else if (arg == "--frames" && index + 1 < args.len) {
            uint? parsed = args[++index].to_uint();
            if (catch parsed) return 1;
            frame_limit = parsed;
        } else {
            io::eprintfn("Unknown argument: %s; use --fan-in, --detail, --sub-cell, --radius R, --clearance-error E or --frames N", arg);
            return 1;
        }
    }
    if (config.detail_mode == DetailMode.BOUNDED) config.detail_max_error = DETAIL_HEIGHT_ERROR;
    if (config.clearance_mode == ClearanceMode.SUB_CELL && !custom_clearance_error) {
        config.clearance_max_error = 2.0f * CELL_SIZE / (float)SUB_CELL_SUBDIVISION;
    }
    platform::Window window = platform::create_window(platform::default_window_desc("c3d grid", 1280, 720))!!;
    defer platform::destroy_window(&window);

    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);

    render::Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window:    &window,
        assets:    &assets,
        desc:      { .validation = true, .application_name = "c3d_grid" },
    )!!;
    defer render::destroy_renderer(&renderer);

    Scene scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer scene::destroy_scene(&scene);
    nav::register_nav(&scene)!!;

    if (catch excuse = run(
        window:   &window,
        renderer: &renderer,
        assets:   &assets,
        scene:    &scene,
        fan_in:   fan_in,
        config:   config,
        frame_limit: frame_limit,
    )) {
        io::eprintfn("grid example failed: %s", excuse);
        return 1;
    }
    io::printfn("closed after %d frames, %.2fs", window.clock.frame, window.clock.total);
    return 0;
}
