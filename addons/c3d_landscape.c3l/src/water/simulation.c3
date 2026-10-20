module c3d::landscape::water;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::landscape::terrain @public;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::math;

<*
 Fixed steps per second of a simulated surface.
*>
const uint SIMULATION_RATE = 60; // the stepped state never depends on the frame rate; each step is a pass over the grid

<*
 Largest ratio of wave speed times substep to vertex spacing.
*>
const float CFL_LIMIT = 0.5f; // under the five-point stencil's stability limit of 0.707; a lower value costs substeps

<*
 Substeps one fixed step runs at most.
*>
const uint MAX_SIMULATION_SUBSTEPS = 8; // bounds the cost of a step; a faster wave or a finer grid is refused

<*
 Fixed steps one update runs at most.
*>
const uint MAX_SIMULATION_STEPS_PER_UPDATE = 4; // a longer hitch drops its excess time: the ripple slows, not the frame

<*
 Cells along the side of a simulated body, at most.
*>
const uint MAX_SIMULATION_CELLS = 256; // 66,049 vertices: 1 MiB of texture rewritten on every awake frame

<*
 Cells along the side of a simulated body, at least.
*>
const uint MIN_SIMULATION_CELLS = 16; // a coarser lattice cannot show a ripple

<*
 Metres a simulated height is clamped to, up and down.
*>
const float SIMULATION_MAX_HEIGHT = 1; // sizes the mesh bounds; the medium and the clip plane follow the reach instead

<*
 Height in metres under which a simulated body can settle.
*>
const float SETTLED_HEIGHT = 0.0005f; // half a millimetre, well under the 1 cm agreement with the drawn surface

<*
 Vertical speed in metres per second under which a simulated body can settle.
*>
const float SETTLED_SPEED = 0.002f; // moves a height by SETTLED_HEIGHT in a quarter of a second

<*
 Wave speed a default desc simulates at, in metres per second.
*>
const float DEFAULT_WAVE_SPEED = 3; // crosses a 30 m pond in ten seconds

<*
 Decay rate of the surface's velocity a default desc simulates at, per second.
*>
const float DEFAULT_DAMPING = 0.5f; // a ripple's amplitude falls by half in about three seconds

const double SIMULATION_STEP @private = 1.0 / SIMULATION_RATE;
const uint TEXEL_FLOATS @private = 4; // RGBA32_FLOAT, the store's only two-channel-capable float format

<*
 Heights, speeds, dry cells and clock of one simulated water body, written by the library.
*>
struct SimulationState {
    uint      texels;          // vertices along a side
    float     spacing;         // metres between vertices
    float     origin;          // node-local x and z of the first vertex
    float[]   height;          // after the last step
    float[]   prior;           // after the step before
    float[]   speed;           // metres per second after the last step
    bool[]    wet;             // false where the ground stands at or above the rest plane
    usz       wet_count;
    TextureId texture;         // owned: this frame's drawn heights and the previous frame's
    float     reach;           // largest height magnitude since the body woke; the medium and the clip plane follow it
    float     fraction;        // share of a step the drawn heights are past the prior ones
    double    accumulator;     // seconds past the last whole step
    double    last_time;
    bool      started;         // last_time holds a frame time
    bool      awake;           // stepping and uploading; false once settled, until an impulse
    bool      masked;          // the dry cells were taken from a ground
    Entity    ground;          // the node the mask was taken from
    uint      ground_revision;
    Mat4      ground_world;
    Mat4      body_world;
}

// A query's node-local position and the corners and weights of the drawn triangle under it.
struct GridPoint @private {
    Vec3     local;
    usz[3]   vertex;
    float[3] weight;
}

struct LatticeRange @private {
    uint first_column;
    uint last_column;
    uint first_row;
    uint last_row;
}

fn uint simulation_cells(WaterDesc* desc) @private => (uint)math::ceil(desc.extent / desc.cell_size);

fn float simulation_spacing(WaterDesc* desc) @private => desc.extent / (float)simulation_cells(desc);

// Substeps per fixed step that keep wave speed times substep within CFL_LIMIT vertex spacings.
fn uint simulation_substeps(WaterDesc* desc) @private {
    float travel = desc.simulation.wave_speed * (float)SIMULATION_STEP;
    float needed = math::ceil(travel / (CFL_LIMIT * simulation_spacing(desc)));
    if (needed > (float)MAX_SIMULATION_SUBSTEPS) return MAX_SIMULATION_SUBSTEPS + 1;
    return needed < 1 ? 1 : (uint)needed;
}

// Everything at rest, one texel per vertex, all wet.
fn SimulationState*? create_simulation(AssetStore* assets, WaterDesc* desc) @private {
    Allocator allocator = assets.allocator;
    uint texels = simulation_cells(desc) + 1;
    sz count = (sz)texels * texels;

    char[] pixels = alloc::new_array(allocator, char, count * TEXEL_FLOATS * float::size);
    defer catch alloc::free(allocator, pixels.ptr);
    TextureDesc texture_desc = material::texture_2d_desc(texels, texels, RGBA32_FLOAT, "water_simulation");
    texture_desc.generate_mips = false;
    TextureId texture = assets.add_texture_owned(texture_desc, pixels)!;

    SimulationState* state = alloc::new(allocator, SimulationState);
    *state = {
        .texels    = texels,
        .spacing   = simulation_spacing(desc),
        .origin    = -desc.extent / 2,
        .height    = alloc::new_array(allocator, float, count),
        .prior     = alloc::new_array(allocator, float, count),
        .speed     = alloc::new_array(allocator, float, count),
        .wet       = alloc::new_array(allocator, bool, count),
        .wet_count = (usz)count,
        .texture   = texture,
    };
    state.wet[..] = true;
    return state;
}

fn void release_simulation(AssetStore* assets, SimulationState* state) @private {
    Allocator allocator = assets.allocator;
    if (assets.textures.is_live(state.texture)) assets.remove_texture(state.texture);
    alloc::free(allocator, state.height.ptr);
    alloc::free(allocator, state.prior.ptr);
    alloc::free(allocator, state.speed.ptr);
    alloc::free(allocator, state.wet.ptr);
    alloc::free(allocator, state);
}

<*
 Push a simulated surface down at a world point.
 Wakes a settled body.
 @param [&inout] scene
 @param node : "Prepared water with the SIMULATED wave model."
 @param world_position : "On the surface; the node carries no scale."
 @param radius : "Metres to the rim of the bump; finite and positive."
 @param strength : "Downward metres per second at the centre; the rest of the surface rises to balance it."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? add_impulse(
    Scene* scene,
    Entity node,
    Vec3 world_position,
    float radius,
    float strength,
) {
    if (!scene.world.is_alive(node) || !scene.world.has(node, WaterRuntime)) return c3d::INVALID_ID~;
    SimulationState* state = scene.world.get(node, WaterRuntime).simulation;
    if (!state) return c3d::INVALID_ID~;
    bool finite_position = math::is_finite(world_position.x) && math::is_finite(world_position.y)
        && math::is_finite(world_position.z);
    if (!finite_position) return c3d::INVALID_ARGUMENT~;
    if (!(radius > 0) || !math::is_finite(radius)) return c3d::INVALID_ARGUMENT~;
    if (!(strength >= 0) || !math::is_finite(strength)) return c3d::INVALID_ARGUMENT~;
    if (strength == 0) return;

    Vec3 local = maths::transform_point(maths::inverse_affine(scene.node(node).world), world_position);
    float centre_column = (local.x - state.origin) / state.spacing;
    float centre_row = (local.z - state.origin) / state.spacing;
    float reach = radius / state.spacing;
    float last = (float)(state.texels - 1);
    if (centre_column + reach < 0 || centre_row + reach < 0) return;
    if (centre_column - reach > last || centre_row - reach > last) return;

    uint first_column = (uint)max(math::ceil(centre_column - reach), 0.0f);
    uint last_column = (uint)min(math::floor(centre_column + reach), last);
    uint first_row = (uint)max(math::ceil(centre_row - reach), 0.0f);
    uint last_row = (uint)min(math::floor(centre_row + reach), last);
    double pushed;
    for (uint row = first_row; row <= last_row; row++) {
        for (uint column = first_column; column <= last_column; column++) {
            usz index = (usz)row * state.texels + column;
            if (!state.wet[index]) continue;
            float across = ((float)column - centre_column) / reach;
            float down = ((float)row - centre_row) / reach;
            float squared = across * across + down * down;
            if (squared >= 1) continue;

            float falloff = 1 - squared;
            float push = strength * falloff * falloff;
            state.speed[index] -= push;
            pushed += (double)push;
        }
    }
    if (pushed == 0) return;

    float rise = (float)(pushed / (double)state.wet_count);
    foreach (index, &speed : state.speed) {
        if (state.wet[index]) *speed += rise;
    }
    state.awake = true;
}

fn void advance_simulation(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    WaterRuntime* runtime,
    double time,
) @private {
    SimulationState* state = runtime.simulation;
    follow_ground(scene, assets, node, runtime);

    double elapsed = state.started ? max(time - state.last_time, 0.0) : 0.0;
    state.started = true;
    state.last_time = time;
    if (!state.awake) return;

    state.accumulator += elapsed;
    float reach_before = state.reach;
    uint substeps = simulation_substeps(&runtime.desc);
    uint steps;
    while (state.accumulator >= SIMULATION_STEP && steps < MAX_SIMULATION_STEPS_PER_UPDATE) {
        step_simulation(state, &runtime.desc.simulation, substeps);
        state.accumulator -= SIMULATION_STEP;
        steps++;
    }
    if (state.accumulator >= SIMULATION_STEP) {
        state.accumulator -= math::floor(state.accumulator / SIMULATION_STEP) * SIMULATION_STEP;
    }
    state.fraction = (float)(state.accumulator / SIMULATION_STEP);

    if (steps > 0 && is_settled(state)) settle(state);
    if (state.reach != reach_before) write_medium(scene, node, runtime);
    upload_simulation(assets, state);
}

// Leapfrog substeps; the prior heights are the ones the whole step starts from.
fn void step_simulation(SimulationState* state, WaterSimulation* simulation, uint substeps) @private {
    state.prior[..] = state.height[..];
    float interval = (float)SIMULATION_STEP / (float)substeps;
    float stiffness = simulation.wave_speed * simulation.wave_speed * interval / (state.spacing * state.spacing);
    float decay = math::exp(-simulation.damping * interval);
    for (uint substep = 0; substep < substeps; substep++) {
        accelerate(state, stiffness, decay);
        float peak = drift(state, interval);
        state.reach = max(state.reach, peak);
    }
}

// Walls reflect: a neighbour that is past the edge or dry counts as the vertex's own height.
fn void accelerate(SimulationState* state, float stiffness, float decay) @private {
    uint texels = state.texels;
    for (uint row = 0; row < texels; row++) {
        for (uint column = 0; column < texels; column++) {
            usz index = (usz)row * texels + column;
            if (!state.wet[index]) continue;

            float centre = state.height[index];
            float west = column > 0 ? wall_height(state, index - 1, centre) : centre;
            float east = column + 1 < texels ? wall_height(state, index + 1, centre) : centre;
            float north = row > 0 ? wall_height(state, index - texels, centre) : centre;
            float south = row + 1 < texels ? wall_height(state, index + texels, centre) : centre;
            float laplacian = west + east + north + south - 4 * centre;
            state.speed[index] = (state.speed[index] + stiffness * laplacian) * decay;
        }
    }
}

fn float wall_height(SimulationState* state, usz index, float centre) @private {
    return state.wet[index] ? state.height[index] : centre;
}

// Moves the wet heights by their speeds and returns the largest magnitude among them.
fn float drift(SimulationState* state, float interval) @private {
    float peak;
    foreach (index, &height : state.height) {
        if (!state.wet[index]) continue;

        *height = math::clamp(*height + state.speed[index] * interval, -SIMULATION_MAX_HEIGHT, SIMULATION_MAX_HEIGHT);
        peak = max(peak, math::abs(*height));
    }
    return peak;
}

fn bool is_settled(SimulationState* state) @private {
    foreach (index, height : state.height) {
        if (math::abs(height) >= SETTLED_HEIGHT || math::abs(state.speed[index]) >= SETTLED_SPEED) return false;
    }
    return true;
}

// The grid snaps to rest and the next upload draws it flat.
fn void settle(SimulationState* state) @private {
    state.height[..] = 0;
    state.prior[..] = 0;
    state.speed[..] = 0;
    state.accumulator = 0;
    state.fraction = 0;
    state.reach = 0;
    state.awake = false;
}

fn float drawn_height(SimulationState* state, usz index) @private {
    return state.prior[index] + (state.height[index] - state.prior[index]) * state.fraction;
}

// Rewrites the texture in place: this frame's drawn heights, and the last frame's while awake.
fn void upload_simulation(AssetStore* assets, SimulationState* state) @private {
    TextureAsset* texture = assets.texture(state.texture);
    float[TEXEL_FLOATS]* texels = (float[TEXEL_FLOATS]*)texture.pixels.ptr;
    foreach (index, &texel : texels[:state.height.len]) {
        float previous = state.awake ? (*texel)[0] : 0;
        *texel = { drawn_height(state, (usz)index), previous, 0, 0 };
    }
    assets.mark_texture_dirty(state.texture);
}

// Keeps the dry cells in step with the ground: the whole mask when the ground, a node or the revision log changed
// beyond what a rectangle says, the refreshed region otherwise, and none without a usable ground.
fn void follow_ground(
    Scene* scene,
    AssetStore* assets,
    Node* node,
    WaterRuntime* runtime,
) @private {
    SimulationState* state = runtime.simulation;
    Entity ground = runtime.desc.ground;
    bool usable = ground.generation && scene.world.is_alive(ground) && scene.world.has(ground, TerrainRuntime)
        && terrain::upright_rigid(scene.node(ground).world);
    if (!usable) {
        if (state.masked) clear_mask(state);
        return;
    }
    HeightView? found = terrain::height_view(scene, assets, ground);
    if (catch found) {
        if (state.masked) clear_mask(state);
        return;
    }
    HeightView view = found;

    Node* ground_node = scene.node(ground);
    uint revision = scene.get(ground_node, TerrainRuntime).revision;
    bool whole = !state.masked || !c3d::same_id(state.ground, ground)
        || ground_node.world != state.ground_world || node.world != state.body_world;
    if (!whole && revision != state.ground_revision) {
        TexelRect? refreshed = terrain::refreshed_since(scene, ground_node, state.ground_revision);
        if (catch refreshed) {
            whole = true;
        } else if (refreshed.columns) {
            mask_range(
                state: state,
                view:  &view,
                world: node.world,
                range: rect_range(state, &view, node.world, refreshed),
            );
        }
    }
    if (whole) {
        mask_range(
            state: state,
            view:  &view,
            world: node.world,
            range: { .last_column = state.texels - 1, .last_row = state.texels - 1 },
        );
    }
    state.masked = true;
    state.ground = ground;
    state.ground_revision = revision;
    state.ground_world = ground_node.world;
    state.body_world = node.world;
}

fn void clear_mask(SimulationState* state) @private {
    state.wet[..] = true;
    state.wet_count = state.wet.len;
    state.masked = false;
    state.ground = {};
}

// Vertices a refreshed terrain rectangle can change: its texels and the cells around them, in the body's lattice.
fn LatticeRange rect_range(
    SimulationState* state,
    HeightView* view,
    Mat4 body_world,
    TexelRect rect,
) @private {
    Mat4 local_from_world = maths::inverse_affine(body_world);
    float low_x = ((float)rect.x - 1) * view.cell_size;
    float high_x = (float)(rect.x + rect.columns) * view.cell_size;
    float low_z = ((float)rect.z - 1) * view.cell_size;
    float high_z = (float)(rect.z + rect.rows) * view.cell_size;
    Vec2 low = { float::max, float::max };
    Vec2 high = { -float::max, -float::max };
    Vec2[4] corners = { { low_x, low_z }, { high_x, low_z }, { low_x, high_z }, { high_x, high_z } };
    foreach (corner : corners) {
        Vec3 world = maths::transform_point(view.world, { corner.x, 0, corner.y });
        Vec3 local = maths::transform_point(local_from_world, world);
        low = { min(low.x, local.x), min(low.y, local.z) };
        high = { max(high.x, local.x), max(high.y, local.z) };
    }

    float last = (float)(state.texels - 1);
    return {
        .first_column = (uint)math::clamp(math::floor((low.x - state.origin) / state.spacing), 0.0f, last),
        .last_column  = (uint)math::clamp(math::ceil((high.x - state.origin) / state.spacing), 0.0f, last),
        .first_row    = (uint)math::clamp(math::floor((low.y - state.origin) / state.spacing), 0.0f, last),
        .last_row     = (uint)math::clamp(math::ceil((high.y - state.origin) / state.spacing), 0.0f, last),
    };
}

// A vertex is dry where the ground stands at or above the rest plane; a vertex off the ground's extent is wet.
fn void mask_range(
    SimulationState* state,
    HeightView* view,
    Mat4 world,
    LatticeRange range,
) @private {
    float rest_height = maths::translation(world).y;
    for (uint row = range.first_row; row <= range.last_row; row++) {
        for (uint column = range.first_column; column <= range.last_column; column++) {
            usz index = (usz)row * state.texels + column;
            Vec3 point = maths::transform_point(world, {
                state.origin + (float)column * state.spacing,
                0,
                state.origin + (float)row * state.spacing,
            });
            bool dry;
            if (try ground_height = terrain::sample_height(view, point.x, point.z)) dry = ground_height >= rest_height;
            state.wet[index] = !dry;
            if (dry) {
                state.height[index] = 0;
                state.prior[index] = 0;
                state.speed[index] = 0;
            }
        }
    }

    usz wet_count;
    foreach (wet : state.wet) wet_count += wet ? 1 : 0;
    state.wet_count = wet_count;
}

// The drawn triangle under a world point, on the split the built grid's indices make.
fn GridPoint? grid_point(SurfaceView* view, float world_x, float world_z) @private {
    SimulationState* state = view.simulation;
    Vec3 local = maths::transform_point(view.local_from_world, { world_x, 0, world_z });
    float column = (local.x - state.origin) / state.spacing;
    float row = (local.z - state.origin) / state.spacing;
    float last = (float)(state.texels - 1);
    if (!(column >= 0 && row >= 0 && column <= last && row <= last)) return NOT_FOUND~;

    uint cell_column = min((uint)column, state.texels - 2);
    uint cell_row = min((uint)row, state.texels - 2);
    float across = column - (float)cell_column;
    float down = row - (float)cell_row;
    usz corner = (usz)cell_row * state.texels + cell_column;
    usz next = corner + state.texels;

    // The diagonal runs from (x + 1, z) to (x, z + 1): the quad's two triangles in water_grid's index order.
    if (across + down <= 1) {
        return {
            .local  = local,
            .vertex = { corner, corner + 1, next },
            .weight = { 1 - across - down, across, down },
        };
    }
    return {
        .local  = local,
        .vertex = { next + 1, next, corner + 1 },
        .weight = { across + down - 1, 1 - across, 1 - down },
    };
}

fn float blended_height(SimulationState* state, GridPoint* point) @private {
    float height;
    foreach (corner, vertex : point.vertex) height += point.weight[corner] * drawn_height(state, vertex);
    return height;
}

fn float? simulated_height(SurfaceView* view, float world_x, float world_z) @private {
    GridPoint point = grid_point(view, world_x, world_z)!;
    float height = blended_height(view.simulation, &point);
    return maths::transform_point(view.world, { point.local.x, height, point.local.z }).y;
}

// The velocity is the slope in time of the heights the frame draws: they move linearly over a step.
fn WaterSample? simulated_detail(SurfaceView* view, float world_x, float world_z) @private {
    SimulationState* state = view.simulation;
    GridPoint point = grid_point(view, world_x, world_z)!;
    float height = blended_height(state, &point);
    Vec3 normal;
    float climb;
    foreach (corner, vertex : point.vertex) {
        float weight = point.weight[corner];
        normal += vertex_normal(state, vertex) * weight;
        climb += weight * (state.height[vertex] - state.prior[vertex]) / (float)SIMULATION_STEP;
    }

    return {
        .height   = maths::transform_point(view.world, { point.local.x, height, point.local.z }).y,
        .normal   = maths::transform_dir(view.world, normal.normalize()),
        .velocity = maths::transform_dir(view.world, { 0, climb, 0 }),
        .residual = 0,
    };
}

// Twin of water_simulated_point in landscape/water_simulation.glsl: central differences of the drawn heights, one-sided
// at the edges.
fn Vec3 vertex_normal(SimulationState* state, usz vertex) @private {
    uint texels = state.texels;
    uint column = (uint)(vertex % texels);
    uint row = (uint)(vertex / texels);
    uint west = column > 0 ? column - 1 : 0;
    uint east = min(column + 1, texels - 1);
    uint north = row > 0 ? row - 1 : 0;
    uint south = min(row + 1, texels - 1);
    float across = (drawn_height(state, (usz)row * texels + east) - drawn_height(state, (usz)row * texels + west))
        / ((float)(east - west) * state.spacing);
    float down = (drawn_height(state, (usz)south * texels + column) - drawn_height(state, (usz)north * texels + column))
        / ((float)(south - north) * state.spacing);
    Vec3 slope = { -across, 1, -down };
    return slope.normalize();
}
