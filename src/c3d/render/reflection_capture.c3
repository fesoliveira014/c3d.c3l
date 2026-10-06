module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;
import std::time;
import std::time::clock;

const uint REFLECTION_CAPTURE_TEXEL_BYTES @local = 8; // RGBA16_FLOAT

<* Face edge of a default reflection capture, in texels. *>
const uint DEFAULT_REFLECTION_CAPTURE_SIZE = 128; // 768 KiB source and CPU copy, 1 MiB filtered; work scales by texels

<* Largest face edge a reflection capture accepts, in texels. *>
const uint MAX_REFLECTION_CAPTURE_SIZE = 1024; // 48 MiB source cube, CPU copy and readback, about 64 MiB filtered

<* Near plane of a default reflection capture, in world units. *>
const float DEFAULT_REFLECTION_CAPTURE_NEAR = 0.05f; // clips what lies closer than 5 cm to the capture point

<* Faces of a default reflection capture: 128 texels, every layer, no far plane. *>
const ReflectionCaptureDesc REFLECTION_CAPTURE_DESC_DEFAULT = {
    .size   = DEFAULT_REFLECTION_CAPTURE_SIZE,
    .near   = DEFAULT_REFLECTION_CAPTURE_NEAR,
    .far    = 0,
    .layers = camera::ALL_LAYERS,
};

<* Face size, depth range and layers of a reflection capture. *>
struct ReflectionCaptureDesc {
    uint  size;   // face edge in texels; a power of two
    float near;   // world units
    float far;    // world units; 0 selects an infinite far plane
    uint  layers; // nodes the faces render, as Camera.layers
}

<* Measured cost of the last reflection capture. *>
struct ReflectionCaptureStats {
    double elapsed_ms;     // checks, six face frames, readback and the copy into the cube
    usz    cube_bytes;     // store pixels of the cube
    usz    readback_bytes; // temporary GPU readback of the six faces
}

<*
 Capture the probe's surroundings into a new store-owned cube environment.
 Renders six frames and waits; the cube is filtered when the environment is next prepared.
 @param [&inout] scene : "World transforms are current; only batch aggregates are written."
 @param [&in] probe_node : "Live member of scene carrying a ReflectionProbe."
 @param key : "Asset key of the new environment; the cube texture has none."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @return? c3d::ASSET_DATA_UNAVAILABLE, c3d::SHADER_NOT_FOUND, c3d::RESOURCE_IN_USE
 @return? gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE, gpu::COMMAND_RECORDING_ERROR
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::SURFACE_LOST
 @require !self.frame_open
*>
fn EnvironmentId? Renderer.capture_reflection_probe(
    &self,
    Scene* scene,
    Node* probe_node,
    ReflectionCaptureDesc desc = REFLECTION_CAPTURE_DESC_DEFAULT,
    String key = "",
) {
    time::Clock started = clock::now();
    self.last_reflection_capture = {};
    capture_probe(scene, probe_node, desc)!;
    asset::check_key(self.assets, key)!;
    if (!self.assets.textures.free_count || !self.assets.environments.free_count) return c3d::CAPACITY_EXCEEDED~;
    if (!self.views.free_count || !self.targets.free_count) return c3d::CAPACITY_EXCEEDED~;

    usz cube_bytes = reflection_cube_bytes(desc.size);
    char[] pixels = alloc::new_array(self.assets.allocator, char, (sz)cube_bytes);
    material::TextureDesc cube_desc = material::texture_cube_desc(desc.size, RGBA16_FLOAT, "reflection_capture");
    cube_desc.generate_mips = false;
    TextureId? added = self.assets.add_texture_owned(cube_desc, pixels);
    if (catch excuse = added) {
        alloc::free(self.assets.allocator, pixels.ptr);
        return excuse~;
    }
    TextureId texture = added;
    defer catch self.assets.remove_texture(texture);
    render_reflection_faces(
        renderer:   self,
        scene:      scene,
        probe_node: probe_node,
        desc:       desc,
        cube:       pixels,
    )!;

    EnvironmentSettings settings = light::ENVIRONMENT_SETTINGS_DEFAULT;
    settings.specular_size = desc.size;
    EnvironmentId environment = self.assets.add_environment(light::texture_environment(texture, settings), key)!;
    self.last_reflection_capture = {
        .elapsed_ms     = elapsed_ms(started),
        .cube_bytes     = cube_bytes,
        .readback_bytes = cube_bytes,
    };
    return environment;
}

<*
 Capture the probe again into the cube its environment borrows.
 Keeps both ids and advances the texture revision; renders six frames and waits.
 @param [&inout] scene : "World transforms are current; only batch aggregates are written."
 @param [&in] probe_node : "Live member of scene carrying a ReflectionProbe."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED, c3d::UNSUPPORTED
 @return? c3d::ASSET_DATA_UNAVAILABLE, c3d::SHADER_NOT_FOUND, c3d::RESOURCE_IN_USE
 @return? gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE, gpu::COMMAND_RECORDING_ERROR
 @return? gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::SURFACE_LOST
 @require !self.frame_open
*>
fn void? Renderer.recapture_reflection_probe(
    &self,
    Scene* scene,
    Node* probe_node,
    ReflectionCaptureDesc desc = REFLECTION_CAPTURE_DESC_DEFAULT,
) {
    time::Clock started = clock::now();
    self.last_reflection_capture = {};
    ReflectionProbe* probe = capture_probe(scene, probe_node, desc)!;
    EnvironmentAsset* environment = self.assets.environments.try_get(probe.environment)!;
    if (environment.desc.kind != EnvironmentSourceKind.TEXTURE) return c3d::INVALID_ARGUMENT~;
    TextureId texture_id = environment.desc.source;
    TextureAsset* texture = self.assets.textures.try_get(texture_id)!;
    usz cube_bytes = reflection_cube_bytes(desc.size);
    if (!captured_cube_matches(texture, desc.size, cube_bytes)) return c3d::INVALID_ARGUMENT~;
    if (!self.views.free_count || !self.targets.free_count) return c3d::CAPACITY_EXCEEDED~;

    bool released = !texture.pixels.len;
    char[] pixels = released ? alloc::new_array(self.assets.allocator, char, (sz)cube_bytes) : texture.pixels;
    defer catch {
        if (released) alloc::free(self.assets.allocator, pixels.ptr);
    }
    render_reflection_faces(
        renderer:   self,
        scene:      scene,
        probe_node: probe_node,
        desc:       desc,
        cube:       pixels,
    )!;
    if (released) self.assets.restore_texture_cpu(texture_id, pixels);
    self.assets.mark_texture_dirty(texture_id);
    self.last_reflection_capture = {
        .elapsed_ms     = elapsed_ms(started),
        .cube_bytes     = cube_bytes,
        .readback_bytes = cube_bytes,
    };
}


fn bool reflection_capture_desc_valid(ReflectionCaptureDesc desc) @private {
    bool power_of_two = desc.size != 0 && (desc.size & (desc.size - 1)) == 0;
    if (!power_of_two || desc.size < asset::MIN_ENVIRONMENT_SPECULAR_SIZE || desc.size > MAX_REFLECTION_CAPTURE_SIZE) {
        return false;
    }
    if (!math::is_finite(desc.near) || desc.near <= 0) return false;
    return desc.far == 0 || (math::is_finite(desc.far) && desc.far > desc.near);
}

fn Camera reflection_capture_camera(ReflectionCaptureDesc desc) @private {
    Camera face = camera::perspective((float)math::PI / 2, desc.near, desc.far);
    face.aspect = 1;
    face.layers = desc.layers;
    return face;
}

// Right-handed face cameras; assembly mirrors each image horizontally into the cube's face convention.
fn Mat4 reflection_capture_face_world(CubeFace face, Vec3 position) @private {
    Vec3 forward;
    Vec3 up;
    switch (face) {
        case POSITIVE_X:
            forward = { 1, 0, 0 };
            up = { 0, 1, 0 };
        case NEGATIVE_X:
            forward = { -1, 0, 0 };
            up = { 0, 1, 0 };
        case POSITIVE_Y:
            forward = { 0, 1, 0 };
            up = { 0, 0, -1 };
        case NEGATIVE_Y:
            forward = { 0, -1, 0 };
            up = { 0, 0, 1 };
        case POSITIVE_Z:
            forward = { 0, 0, 1 };
            up = { 0, 1, 0 };
        case NEGATIVE_Z:
            forward = { 0, 0, -1 };
            up = { 0, 1, 0 };
    }
    Vec3 right = forward.cross(up);
    Mat4 world = matrix::IDENTITY4;
    world.m00 = right.x;
    world.m10 = right.y;
    world.m20 = right.z;
    world.m01 = up.x;
    world.m11 = up.y;
    world.m21 = up.z;
    world.m02 = -forward.x;
    world.m12 = -forward.y;
    world.m22 = -forward.z;
    world.m03 = position.x;
    world.m13 = position.y;
    world.m23 = position.z;
    return world;
}

<*
 @require face.len == (usz)size * size * REFLECTION_CAPTURE_TEXEL_BYTES, rendered.len == face.len
*>
fn void mirror_capture_face(char[] face, char[] rendered, uint size) @private {
    ulong[] destination = ((ulong*)face.ptr)[:(usz)size * size];
    ulong[] source = ((ulong*)rendered.ptr)[:(usz)size * size];
    for (usz y = 0; y < size; y++) {
        usz row = y * size;
        for (usz x = 0; x < size; x++) destination[row + x] = source[row + size - 1 - x];
    }
}

fn Vec3 reflection_capture_position(ReflectionProbe* probe, Mat4 world) @private {
    ReflectionProbeGpu record = reflection_probe_record(
        probe:         probe,
        world:         world,
        origin:        {},
        specular_cube: (gpu::TextureIndex)0,
        sheen_cube:    (gpu::TextureIndex)0,
    );
    return record.center_intensity.xyz + reflection_probe_world(&record, probe.capture_offset);
}

fn usz reflection_cube_bytes(uint size) @local {
    return (usz)size * size * REFLECTION_CAPTURE_TEXEL_BYTES * material::CUBE_FACE_COUNT;
}

fn ReflectionProbe*? capture_probe(Scene* scene, Node* probe_node, ReflectionCaptureDesc desc) @local {
    if (!scene.world.is_alive(probe_node.id) || scene.node(probe_node.id) != probe_node) return c3d::INVALID_ID~;
    ReflectionProbe* probe = scene.get(probe_node, ReflectionProbe);
    if (!probe || !light::reflection_probe_valid(probe) || !reflection_capture_desc_valid(desc)) {
        return c3d::INVALID_ARGUMENT~;
    }
    return probe;
}

fn bool captured_cube_matches(TextureAsset* texture, uint size, usz cube_bytes) @local {
    material::TextureDesc desc = texture.desc;
    if (!desc.is_cube || desc.format != RGBA16_FLOAT || desc.layers != material::CUBE_FACE_COUNT) return false;
    if (desc.width != size || desc.height != size || texture.source_kind != MIP_ZERO) return false;
    return !texture.pixels.len || texture.pixels.len == cube_bytes;
}

<*
 @require !renderer.frame_open, cube.len == reflection_cube_bytes(desc.size)
*>
fn void? render_reflection_faces(
    Renderer* renderer,
    Scene* scene,
    Node* probe_node,
    ReflectionCaptureDesc desc,
    char[] cube,
) @private {
    Vec3 capture = reflection_capture_position(scene.get(probe_node, ReflectionProbe), probe_node.world);
    usz face_bytes = (usz)desc.size * desc.size * REFLECTION_CAPTURE_TEXEL_BYTES;
    wait_frames(renderer)!;
    RenderTargetId target = create_render_target(renderer, render_target_desc(desc.size, desc.size))!;
    defer (void)destroy_render_target(renderer, target);
    ViewDesc view_desc = texture_view_desc(target);
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = create_view(renderer, view_desc)!;
    defer (void)destroy_view(renderer, view);
    gpu::AllocationDesc readback_desc = {
        .size         = face_bytes * material::CUBE_FACE_COUNT,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access       = { .graphics },
        .debug_name   = "reflection_capture_readback",
    };
    gpu::GpuAllocation readback = gpu::allocate_memory(&renderer.device, &readback_desc)!;
    defer (void)gpu::free_allocation(&renderer.device, &readback);
    gpu::GpuSpan span = gpu::get_allocation_span(&renderer.device, readback)!;

    ViewCamera view_camera = {
        .camera         = reflection_capture_camera(desc),
        .excluded_probe = probe_node.id,
        .height_fog     = false,
    };
    foreach (face : CubeFace::values) {
        view_camera.world = reflection_capture_face_world(face, capture);
        begin_renderer_frame(renderer, { .reference_position = capture }, false)!;
        defer catch {
            if (renderer.frame_open) abort_frame(renderer);
        }
        record_camera_view(
            renderer:    renderer,
            scene:       scene,
            view_camera: &view_camera,
            view:        view,
            debug:       null,
        )!;
        renderer.finish_view(view)!;
        TextureReadback face_readback = {
            .target      = &renderer.targets.get(target).target,
            .destination = span.unchecked_subspan((usz)face.ordinal * face_bytes, face_bytes),
        };
        record_texture_readback(&renderer.commands, &face_readback)!;
        renderer.end_frame()!;
    }
    wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, span)!;
    char[] mapped = gpu::mapped_gpu_span(&renderer.device, span)!.bytes;
    for (usz index = 0; index < material::CUBE_FACE_COUNT; index++) {
        mirror_capture_face(cube[index * face_bytes:face_bytes], mapped[index * face_bytes:face_bytes], desc.size);
    }
}
