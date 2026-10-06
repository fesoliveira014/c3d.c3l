module landscape_ground;

import std::math;
import c3d;
import c3d::asset;
import c3d::landscape::terrain;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::platform;
import c3d::scene;

<* Height-map sizes the landscape examples accept, in texels per side. *>
const uint[3] MAP_SIZES = { 1025, 2049, 4097 }; // four, five and six levels

<* Height-map size when none is chosen, in texels per side. *>
const uint DEFAULT_MAP_SIZE = 2049; // 2 km across at 1 m cells: 256 finest chunks

<* Metres between height-map texels of the ground. *>
const float CELL_SIZE = 1;

<* Material layers of the ground: grass, dirt, rock and snow. *>
const uint LAYER_COUNT = 4;

<* Node layer bit of the terrain, left out of picks. *>
const uint TERRAIN_LAYER = 1 << 1;

<* Direction the sunlight travels in, before normalization. *>
const Vec3 SUN_DIRECTION = { -0.45f, -0.6f, -0.35f };

<* Rise of one scripted brush stamp, in height texel units at the centre. *>
const float BRUSH_RISE = 600; // 2.7 m at this height scale

const float HEIGHT_SCALE @local = 300; // metres at texel 65535; ridges reach about two thirds of it
const uint HEIGHT_SEED @local = 0x7e11a1;
const uint HEIGHT_OCTAVES @local = 7; // 512 m ridges down to 8 m bumps; each octave is one noise pass per texel
const float HEIGHT_BASE_TEXELS @local = 512; // wavelength of the first octave: a few ranges per map
const float HEIGHT_GAIN @local = 0.5f; // amplitude kept per octave; higher is rougher
const float HEIGHT_VALLEY_POWER @local = 1.6f; // flattens valley floors so walking and crates have ground
const uint CONTROL_SIZE @local = 1024; // weight texels over the whole extent; 4 MiB, two metres each at 2049
const float SNOW_LINE @local = 0.62f; // share of the height scale where snow starts
const float SNOW_BAND @local = 0.08f;
const float ROCK_SLOPE @local = 0.9f; // rise over run where rock takes over
const float ROCK_BAND @local = 0.35f;
const float DIRT_SLOPE @local = 0.35f;
const float DIRT_BAND @local = 0.2f;
const uint LAYER_MAP_SIZE @local = 256; // tileable texels per layer map; 256 KiB each
const uint LAYER_NOISE_CELLS @local = 16; // lattice cells across one tile; the tile repeats without seams
const uint LAYER_DETAIL_SCALE @local = 4; // the detail octave's cells per base cell
const float LAYER_DETAIL_WEIGHT @local = 0.35f;
const uint LAYER_SEED @local = 0x51a7e;
const uint LAYER_SEED_STRIDE @local = 16;
const float DISPLAY_GAMMA @local = 2.2f; // layer colours are authored linear and stored sRGB
const uint RGBA8_BYTES @local = 4;
const uint BRUSH_RADIUS @local = 24; // texels; a stamp touches 49 x 49 texels, the typical edit
const float BRUSH_RISE_PER_SECOND @local = 1200; // texel units at the centre while B is held, 5.5 m/s
const float BRUSH_STAMP_SECONDS @local = 1.0f / 30; // held painting stamps at this period whatever the frame rate
const float EYE_HEIGHT @local = 1.8f;
const float WALK_SPEED @local = 8;
const float FLY_SPEED @local = 60;
const float FAST_MULTIPLIER @local = 4;
const float LOOK_RADIANS_PER_PIXEL @local = 0.003f;
const float PITCH_LIMIT @local = 1.5f; // avoids the poles, where the up vector degenerates
const float SUN_INTENSITY @local = 3;
const float SHADOW_DISTANCE @local = 1500; // metres; the cascades spread over it, the atlas cost is fixed
const float AMBIENT_INTENSITY @local = 0.25f;
const Vec4 SKY_COLOR @local = { 0.55f, 0.7f, 0.9f, 1 };
const HeightFog LANDSCAPE_FOG @local = { // a haze that pools below 100 m of the 300 m relief
    .density      = 0.0015f,
    .falloff      = 0.01f,
    .albedo       = { 1, 1, 1 },
    .max_distance = 400,
    .anisotropy   = 0.3f,
};

const LayerLook[LAYER_COUNT] LAYER_LOOKS @local = {
    { // grass
        .low         = { 0.16f, 0.26f, 0.08f },
        .high        = { 0.3f, 0.42f, 0.14f },
        .roughness   = 0.9f,
        .tile_metres = 4,
        .bump        = 1.5f,
    },
    { // dirt
        .low         = { 0.28f, 0.2f, 0.12f },
        .high        = { 0.42f, 0.32f, 0.2f },
        .roughness   = 0.95f,
        .tile_metres = 6,
        .bump        = 2,
    },
    { // rock
        .low         = { 0.3f, 0.29f, 0.28f },
        .high        = { 0.52f, 0.5f, 0.47f },
        .roughness   = 0.75f,
        .tile_metres = 10,
        .bump        = 4,
    },
    { // snow
        .low         = { 0.82f, 0.85f, 0.9f },
        .high        = { 0.95f, 0.96f, 0.98f },
        .roughness   = 0.5f,
        .tile_metres = 8,
        .bump        = 0.8f,
    },
};

struct NoiseSource @local {
    uint seed;
    int  period; // lattice cells before the noise repeats; 0 never repeats
}

struct LayerLook @local {
    Vec3  low;
    Vec3  high;
    float roughness;
    float tile_metres; // one tile of the layer maps covers this many metres
    float bump;        // normal-map slope at full noise contrast
}

<* The example landscape's terrain node and the desc it was added with. *>
struct Ground {
    Node*       node;
    TerrainDesc desc;
    float       extent; // metres along each side
}

<* Walking or flying viewpoint over the ground. *>
struct FlyCamera {
    Vec3  position;
    float yaw;
    float pitch;
    bool  flying;
    float ground;
}

<* Held brush that stamps at a fixed period whatever the frame rate. *>
struct Brush {
    float seconds; // held time not yet stamped
}

<*
 Rise to stamp this frame, 0 when no stamp is due.
 @param held : "Whether the brush key is down this frame."
 @param delta : "Frame seconds."
 @return "Height texel units for stamp_under."
*>
fn float Brush.rise(&self, bool held, float delta) {
    if (!held) {
        self.seconds = 0;
        return 0;
    }
    self.seconds += delta;
    uint stamps = (uint)(self.seconds / BRUSH_STAMP_SECONDS);
    self.seconds -= (float)stamps * BRUSH_STAMP_SECONDS;
    return BRUSH_RISE_PER_SECOND * BRUSH_STAMP_SECONDS * (float)stamps;
}

fn float blend(float from, float to, float amount) @local => from + (to - from) * amount;

fn float lattice_value(NoiseSource source, int x, int z) @local {
    if (source.period) {
        x = ((x % source.period) + source.period) % source.period;
        z = ((z % source.period) + source.period) % source.period;
    }
    // An integer hash of the lattice point: value noise needs no gradient table.
    uint hash = ((uint)x * 0x8da6b343) ^ ((uint)z * 0xd8163841) ^ (source.seed * 0xcb1ab31f);
    hash = (hash ^ (hash >> 13)) * 0x5bd1e995;
    hash ^= hash >> 15;
    return (float)(hash & 0xffffff) / (float)0x1000000;
}

fn float value_noise(NoiseSource source, float x, float z) @local {
    float cell_x = math::floor(x);
    float cell_z = math::floor(z);
    float fraction_x = x - cell_x;
    float fraction_z = z - cell_z;
    float blend_x = fraction_x * fraction_x * (3 - 2 * fraction_x);
    float blend_z = fraction_z * fraction_z * (3 - 2 * fraction_z);
    int lattice_x = (int)cell_x;
    int lattice_z = (int)cell_z;
    float near_row = blend(
        lattice_value(source, lattice_x, lattice_z),
        lattice_value(source, lattice_x + 1, lattice_z),
        blend_x,
    );
    float far_row = blend(
        lattice_value(source, lattice_x, lattice_z + 1),
        lattice_value(source, lattice_x + 1, lattice_z + 1),
        blend_x,
    );
    return blend(near_row, far_row, blend_z);
}

fn float ridged_height(float texel_x, float texel_z) @local {
    float total;
    float weight_sum;
    float amplitude = 1;
    float frequency = 1 / HEIGHT_BASE_TEXELS;
    for (uint octave = 0; octave < HEIGHT_OCTAVES; octave++) {
        float noise = value_noise({ .seed = HEIGHT_SEED + octave }, texel_x * frequency, texel_z * frequency);
        float ridge = 1 - math::abs(2 * noise - 1);
        total += amplitude * ridge * ridge;
        weight_sum += amplitude;
        amplitude *= HEIGHT_GAIN;
        frequency *= 2;
    }
    return math::pow(total / weight_sum, HEIGHT_VALLEY_POWER);
}

fn TextureId? add_height_map(AssetStore* assets, uint texels) @local {
    usz count = (usz)texels * texels;
    char[] pixels = alloc::new_array(assets.allocator, char, (sz)(count * ushort::size));
    ushort[] heights = ((ushort*)pixels.ptr)[:count];
    for (uint z = 0; z < texels; z++) {
        for (uint x = 0; x < texels; x++) {
            float height = math::clamp(ridged_height((float)x, (float)z), 0.0f, 1.0f);
            heights[(usz)z * texels + x] = (ushort)(height * (float)ushort::max + 0.5f);
        }
    }
    TextureDesc desc = material::texture_2d_desc(
        width:      texels,
        height:     texels,
        format:     R16_UINT,
        debug_name: "terrain_height",
    );
    desc.generate_mips = false;
    TextureId? added = assets.add_texture_owned(desc, pixels, "terrain/height");
    if (catch excuse = added) {
        alloc::free(assets.allocator, pixels.ptr);
        return excuse~;
    }
    return added;
}

fn float smooth_band(float value, float start, float width) @local {
    float t = math::clamp((value - start) / width, 0.0f, 1.0f);
    return t * t * (3 - 2 * t);
}

fn char unit_to_byte(float value) @local => (char)(math::clamp(value, 0.0f, 1.0f) * (float)char::max + 0.5f);

// Layer weights of grass, dirt, rock and snow in the red, green, blue and alpha channels.
fn TextureId? add_control_map(AssetStore* assets, ushort[] heights, uint texels) @local {
    TextureId control;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, (sz)((usz)CONTROL_SIZE * CONTROL_SIZE * RGBA8_BYTES));
        float texels_per_control = (float)(texels - 1) / (float)(CONTROL_SIZE - 1);
        float metres_per_unit = HEIGHT_SCALE / (float)ushort::max;
        for (uint row = 0; row < CONTROL_SIZE; row++) {
            for (uint column = 0; column < CONTROL_SIZE; column++) {
                uint x = (uint)((float)column * texels_per_control + 0.5f);
                uint z = (uint)((float)row * texels_per_control + 0.5f);
                uint low_x = x > 0 ? x - 1 : 0;
                uint high_x = min(x + 1, texels - 1);
                uint low_z = z > 0 ? z - 1 : 0;
                uint high_z = min(z + 1, texels - 1);
                float rise_x = ((float)heights[(usz)z * texels + high_x] - (float)heights[(usz)z * texels + low_x])
                  * metres_per_unit / ((float)(high_x - low_x) * CELL_SIZE);
                float rise_z = ((float)heights[(usz)high_z * texels + x] - (float)heights[(usz)low_z * texels + x])
                  * metres_per_unit / ((float)(high_z - low_z) * CELL_SIZE);
                float slope = math::sqrt(rise_x * rise_x + rise_z * rise_z);
                float height = (float)heights[(usz)z * texels + x] / (float)ushort::max;

                float rock = smooth_band(slope, ROCK_SLOPE, ROCK_BAND);
                float snow = smooth_band(height, SNOW_LINE, SNOW_BAND) * (1 - rock);
                float dirt = smooth_band(slope, DIRT_SLOPE, DIRT_BAND) * (1 - rock) * (1 - snow);
                float grass = math::max(1 - rock - dirt - snow, 0.0f);
                usz offset = ((usz)row * CONTROL_SIZE + column) * RGBA8_BYTES;
                pixels[offset] = unit_to_byte(grass);
                pixels[offset + 1] = unit_to_byte(dirt);
                pixels[offset + 2] = unit_to_byte(rock);
                pixels[offset + 3] = unit_to_byte(snow);
            }
        }
        // Linear: the stage divides raw weights, so an sRGB curve would skew the blend.
        TextureDesc desc = material::texture_2d_desc(
            width:      CONTROL_SIZE,
            height:     CONTROL_SIZE,
            format:     RGBA8_UNORM,
            debug_name: "terrain_control",
        );
        control = assets.add_texture(desc, pixels, "terrain/control")!;
    };
    return control;
}

fn float layer_noise(uint seed, uint x, uint z) @local {
    float cells_per_texel = (float)LAYER_NOISE_CELLS / (float)LAYER_MAP_SIZE;
    float base = value_noise(
        { .seed = seed, .period = (int)LAYER_NOISE_CELLS },
        (float)x * cells_per_texel,
        (float)z * cells_per_texel,
    );
    float detail = value_noise(
        { .seed = seed + 1, .period = (int)(LAYER_NOISE_CELLS * LAYER_DETAIL_SCALE) },
        (float)x * cells_per_texel * LAYER_DETAIL_SCALE,
        (float)z * cells_per_texel * LAYER_DETAIL_SCALE,
    );
    return blend(base, detail, LAYER_DETAIL_WEIGHT);
}

fn MaterialId? add_layer(AssetStore* assets, LayerLook look, uint index) @local {
    TextureId base_color;
    TextureId normal_map;
    @pool() {
        usz bytes = (usz)LAYER_MAP_SIZE * LAYER_MAP_SIZE * RGBA8_BYTES;
        char[] colors = alloc::new_array(tmem, char, (sz)bytes);
        char[] normals = alloc::new_array(tmem, char, (sz)bytes);
        uint seed = LAYER_SEED + index * LAYER_SEED_STRIDE;
        uint last = LAYER_MAP_SIZE - 1;
        for (uint z = 0; z < LAYER_MAP_SIZE; z++) {
            for (uint x = 0; x < LAYER_MAP_SIZE; x++) {
                float value = layer_noise(seed, x, z);
                float rise_x = layer_noise(seed, (x + 1) % LAYER_MAP_SIZE, z)
                  - layer_noise(seed, (x + last) % LAYER_MAP_SIZE, z);
                float rise_z = layer_noise(seed, x, (z + 1) % LAYER_MAP_SIZE)
                  - layer_noise(seed, x, (z + last) % LAYER_MAP_SIZE);
                Vec3 color = look.low + (look.high - look.low) * value;
                Vec3 normal = (Vec3){ -rise_x * look.bump, -rise_z * look.bump, 1 }.normalize();
                usz offset = ((usz)z * LAYER_MAP_SIZE + x) * RGBA8_BYTES;
                colors[offset] = unit_to_byte(math::pow(color.x, 1 / DISPLAY_GAMMA));
                colors[offset + 1] = unit_to_byte(math::pow(color.y, 1 / DISPLAY_GAMMA));
                colors[offset + 2] = unit_to_byte(math::pow(color.z, 1 / DISPLAY_GAMMA));
                colors[offset + 3] = char::max;
                normals[offset] = unit_to_byte(normal.x * 0.5f + 0.5f);
                normals[offset + 1] = unit_to_byte(normal.y * 0.5f + 0.5f);
                normals[offset + 2] = unit_to_byte(normal.z * 0.5f + 0.5f);
                normals[offset + 3] = char::max;
            }
        }
        TextureDesc color_desc = material::texture_2d_desc(
            width:      LAYER_MAP_SIZE,
            height:     LAYER_MAP_SIZE,
            format:     RGBA8_SRGB,
            debug_name: "terrain_layer_color",
        );
        base_color = assets.add_texture(color_desc, colors)!;
        TextureDesc normal_desc = material::texture_2d_desc(
            width:      LAYER_MAP_SIZE,
            height:     LAYER_MAP_SIZE,
            format:     RGBA8_UNORM,
            debug_name: "terrain_layer_normal",
        );
        normal_map = assets.add_texture(normal_desc, normals)!;
    };

    UvTransform tiling = { .scale = { 1 / look.tile_metres, 1 / look.tile_metres } };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.metallic = 0;
    params.roughness = look.roughness;
    params.base_color_map = material::texture_slot(texture: base_color, transform: tiling);
    params.normal_map = material::texture_slot(texture: normal_map, transform: tiling);
    return assets.add_material(material::standard(params));
}

<* True for a height-map size in MAP_SIZES. *>
fn bool is_map_size(uint size) {
    foreach (map_size : MAP_SIZES) {
        if (size == map_size) return true;
    }
    return false;
}

<*
 Generate the example landscape and add its terrain node.
 @param [&inout] scene : "Registered with terrain::register_terrain."
 @param [&inout] assets : "The store given to register_terrain."
 @param size : "Height-map texels per side."
 @param layers : "Material layers generated, grass first."
 @param lod_threshold : "Chunk split threshold in output pixels."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED
 @require is_map_size(size)
 @require layers > 0 && layers <= LAYER_COUNT
*>
fn Ground? add_ground(
    Scene* scene,
    AssetStore* assets,
    uint size,
    uint layers,
    float lod_threshold,
) {
    TerrainDesc desc = terrain::default_terrain_desc();
    desc.height_map = add_height_map(assets, size)!;
    TextureAsset* heights = assets.texture(desc.height_map);
    desc.control_map = add_control_map(
        assets:  assets,
        heights: ((ushort*)heights.pixels.ptr)[:(usz)size * size],
        texels:  size,
    )!;
    for (uint index = 0; index < layers; index++) {
        desc.layers[index] = add_layer(assets, LAYER_LOOKS[index], index)!;
    }
    desc.cell_size = CELL_SIZE;
    desc.height_scale = HEIGHT_SCALE;
    desc.lod_threshold = lod_threshold;

    Node* node = scene.add_node(name: "terrain")!;
    node.layers = TERRAIN_LAYER;
    scene.update_world();
    terrain::add_terrain(
        scene:  scene,
        assets: assets,
        node:   node,
        desc:   desc,
    )!;
    return { .node = node, .desc = desc, .extent = (float)(size - 1) * CELL_SIZE };
}

<*
 Add the sun, the sky colour and the ambient light of the landscape.
 @param [&inout] scene
 @param sky : "An atmosphere on the sun and a height fog, which replace the sky colour."
 @return? c3d::CAPACITY_EXCEEDED
*>
fn void? add_sun_and_sky(Scene* scene, bool traced_shadows, bool sky) {
    Light sun = light::directional({ 1, 0.95f, 0.85f }, SUN_INTENSITY);
    sun.shadow.max_distance = SHADOW_DISTANCE;
    sun.shadow.ray_traced = traced_shadows;
    Node* sun_node = scene.add_light(sun, name: "sun")!;
    sun_node.local.rotation = maths::look_rotation(SUN_DIRECTION.normalize(), { 0, 1, 0 });
    scene.background = { .kind = COLOR, .color = SKY_COLOR };
    scene.ambient_color = SKY_COLOR.xyz;
    scene.ambient_intensity = AMBIENT_INTENSITY;
    if (!sky) return;
    scene.add(sun_node, light::ATMOSPHERE_EARTH);
    Node* fog_node = scene.add_node(name: "fog")!;
    scene.add(fog_node, LANDSCAPE_FOG);
}

<*
 Terrain height under a world position, or the last ground off the terrain.
 @param [&in] view
*>
fn float ground_under(HeightView* view, Vec3 position, float last_ground) {
    return terrain::sample_height(view, position.x, position.z) ?? last_ground;
}

<* Unit view direction of a yaw and a pitch in radians. *>
fn Vec3 look_direction(float yaw, float pitch) {
    return { math::cos(pitch) * math::sin(yaw), math::sin(pitch), math::cos(pitch) * math::cos(yaw) };
}

<*
 Pose a camera node from a position, yaw and pitch in radians.
 @param [&inout] camera_node
*>
fn void place_camera(
    Node* camera_node,
    Vec3 position,
    float yaw,
    float pitch,
) {
    camera_node.local.position = position;
    camera_node.local.rotation = maths::look_rotation(look_direction(yaw, pitch), { 0, 1, 0 });
}

<*
 Steer the camera from this frame's mouse and keyboard input.
 @param [&inout] fly_camera
 @param [&in] input
 @param [&in] view : "The ground's height view."
 @param delta : "Frame seconds."
*>
fn void apply_fly_camera(
    FlyCamera* fly_camera,
    Input* input,
    HeightView* view,
    float delta,
) {
    if (!input.mouse_captured_by_gui && input.button_down(platform::MouseButton.RIGHT)) {
        fly_camera.yaw -= input.mouse_delta.x * LOOK_RADIANS_PER_PIXEL;
        fly_camera.pitch = math::clamp(
            fly_camera.pitch - input.mouse_delta.y * LOOK_RADIANS_PER_PIXEL,
            -PITCH_LIMIT,
            PITCH_LIMIT,
        );
    }
    Vec3 forward = look_direction(fly_camera.yaw, fly_camera.flying ? fly_camera.pitch : 0);
    Vec3 up = { 0, 1, 0 };
    Vec3 right = forward.cross(up).normalize();
    if (!input.keyboard_captured_by_gui) {
        Vec3 direction;
        if (input.key_down(platform::Scancode.W)) direction += forward;
        if (input.key_down(platform::Scancode.S)) direction -= forward;
        if (input.key_down(platform::Scancode.D)) direction += right;
        if (input.key_down(platform::Scancode.A)) direction -= right;
        if (fly_camera.flying && input.key_down(platform::Scancode.E)) direction += up;
        if (fly_camera.flying && input.key_down(platform::Scancode.Q)) direction -= up;
        float speed = fly_camera.flying ? FLY_SPEED : WALK_SPEED;
        if (input.key_down(platform::Scancode.LSHIFT)) speed *= FAST_MULTIPLIER;
        fly_camera.position += direction * (speed * delta);
    }
    fly_camera.ground = ground_under(view, fly_camera.position, fly_camera.ground);
    if (!fly_camera.flying) fly_camera.position.y = fly_camera.ground + EYE_HEIGHT;
}

fn void stamp_brush(
    Scene* scene,
    AssetStore* assets,
    Node* terrain_node,
    uint center_x,
    uint center_z,
    float rise,
) @local {
    TextureId height_map = scene.get(terrain_node, Terrain).desc.height_map;
    TextureAsset* record = assets.texture(height_map);
    uint side = record.desc.width;
    ushort* texels = (ushort*)record.pixels.ptr;
    uint first_x = center_x > BRUSH_RADIUS ? center_x - BRUSH_RADIUS : 0;
    uint first_z = center_z > BRUSH_RADIUS ? center_z - BRUSH_RADIUS : 0;
    uint last_x = min(center_x + BRUSH_RADIUS, side - 1);
    uint last_z = min(center_z + BRUSH_RADIUS, side - 1);
    float radius_squared = (float)(BRUSH_RADIUS * BRUSH_RADIUS);
    for (uint z = first_z; z <= last_z; z++) {
        for (uint x = first_x; x <= last_x; x++) {
            float offset_x = (float)x - (float)center_x;
            float offset_z = (float)z - (float)center_z;
            float falloff = 1 - (offset_x * offset_x + offset_z * offset_z) / radius_squared;
            if (falloff <= 0) continue;
            usz index = (usz)z * side + x;
            uint raised = (uint)texels[index] + (uint)(rise * falloff + 0.5f);
            texels[index] = (ushort)min(raised, (uint)ushort::max);
        }
    }
    assets.mark_texture_dirty(height_map);
    terrain::mark_dirty(scene, terrain_node, {
        .x       = first_x,
        .z       = first_z,
        .columns = last_x - first_x + 1,
        .rows    = last_z - first_z + 1,
    });
}

<*
 Raise the ground under a world position with one brush stamp.
 @param [&inout] scene
 @param [&inout] assets
 @param [&in] terrain_node : "Added by add_ground."
 @param rise : "Height texel units added at the brush centre."
 @return "False when the position lies off the height map."
 @return? c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
*>
fn bool? stamp_under(
    Scene* scene,
    AssetStore* assets,
    Node* terrain_node,
    Vec3 position,
    float rise,
) {
    HeightView view = terrain::height_view(scene, assets, terrain_node.id)!;
    Vec3 local = maths::transform_point(view.local_from_world, position);
    float column = math::round(local.x / view.cell_size);
    float row = math::round(local.z / view.cell_size);
    float last = (float)(view.texels_per_side - 1);
    if (column < 0 || row < 0 || column > last || row > last) return false;
    stamp_brush(
        scene:        scene,
        assets:       assets,
        terrain_node: terrain_node,
        center_x:     (uint)column,
        center_z:     (uint)row,
        rise:         rise,
    );
    return true;
}
