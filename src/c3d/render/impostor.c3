module c3d::render;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import c3d::render::post;
import gpu;
import std::math;
import std::time;
import std::time::clock;

const uint IMPOSTOR_MIN_FRAMES @local = 2;
const uint IMPOSTOR_MAX_FRAMES @local = 32;
const uint IMPOSTOR_MIN_CELL @local = 4;
const uint IMPOSTOR_TEXEL_BYTES @private = 4;
const float IMPOSTOR_CAPTURE_MARGIN @local = 0.01f; // Keeps valid surfaces away from the reverse-Z clear value.

<* Eight-megabyte atlas with sixty-four padded capture cells. *>
const ImpostorDesc IMPOSTOR_DESC_DEFAULT = {
    .frames_per_side = 8,
    .cell_size = 128,
};

<* Resolution of a static octahedral capture. *>
struct ImpostorDesc {
    uint frames_per_side;
    uint cell_size;
}

<* Measured authoring time and explicitly sized temporary storage. *>
struct ImpostorBakeStats {
    double elapsed_ms;
    usz atlas_bytes;
    usz capture_texel_bytes;
    usz readback_bytes;
    usz scene_host_peak;
}

struct ImpostorLayout @private {
    uint width;
    uint height;
    uint usable;
    usz bytes;
}

struct ImpostorFrames @private {
    uint[3] indices;
    Vec3 weights;
}

struct ImpostorSurface @private {
    Vec3 color;
    Vec3 normal;
    float roughness;
    float depth;
    bool covered;
}

struct PackedImpostorSurface @private {
    char[4] color;
    char[4] surface;
}

struct ImpostorPart @local {
    GeometryId geometry;
    MaterialId material;
    Mat4 world;
    Vec4 color;
}

<*
 Bake a rigid subject into a store-owned surface atlas.
 @param [&in] scene : "World transforms are current."
 @param [&in] subject : "Live member of scene; subtree is captured."
 @param key : "Asset key for the new atlas."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @return? c3d::CAPACITY_EXCEEDED, c3d::ASSET_DATA_UNAVAILABLE, c3d::RESOURCE_IN_USE
 @return? c3d::SHADER_NOT_FOUND, gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED
 @return? gpu::UNSUPPORTED_FEATURE, gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE
 @return? gpu::INVALID_RESOURCE_STATE, gpu::COMMAND_RECORDING_ERROR, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @return? gpu::RESOURCE_IN_USE, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED, gpu::SURFACE_LOST
 @require !self.frame_open
*>
fn Impostor? Renderer.bake_impostor(
    &self,
    Scene* scene,
    Node* subject,
    ImpostorDesc desc = IMPOSTOR_DESC_DEFAULT,
    String key = "",
) {
    time::Clock started = clock::now();
    self.last_impostor_bake = {};
    ImpostorLayout layout = impostor_layout(desc)!;
    if (!scene.world.is_alive(subject.id) || scene.node(subject.id) != subject) return c3d::INVALID_ID~;
    asset::check_key(self.assets, key)!;
    if (!self.assets.textures.free_count || !self.views.free_count || !self.targets.free_count) {
        return c3d::CAPACITY_EXCEEDED~;
    }
    if (!math::is_finite(subject.world.determinant()) || subject.world.determinant() == 0) return c3d::INVALID_ARGUMENT~;
    Mat4 inverse = maths::inverse_affine(subject.world);
    uint part_count;
    Aabb bounds;
    @each_impostor_part(scene, subject, inverse; ImpostorPart part) {
        validate_impostor_part(self.assets, &part)!;
        Aabb current = maths::aabb_transform(self.assets.geometry(part.geometry).data.bounds, part.world);
        bounds = part_count ? maths::aabb_merge(bounds, current) : current;
        if (part_count == uint::max - 1) return c3d::CAPACITY_EXCEEDED~;
        part_count++;
    };
    if (!part_count) return c3d::INVALID_ARGUMENT~;
    Sphere sphere = maths::aabb_sphere(bounds);
    if (!math::is_finite(sphere.radius) || sphere.radius <= 0) return c3d::INVALID_ARGUMENT~;
    gpu::Format[3] capture_formats = { gpu::Format.RGBA8_UNORM, gpu::Format.RGBA16_FLOAT, DEPTH_FORMAT };
    foreach (uint index, format : capture_formats) {
        gpu::TextureFormatSupport support = gpu::get_texture_format_support(&self.device, format)!;
        if (!support.features.transfer_src || !support.features.sampled
          || (index == 2 ? !support.features.depth_attach : !support.features.color_attach)) return gpu::UNSUPPORTED_FEATURE~;
    }

    TrackingAllocator tracker;
    tracker.init(self.allocator);
    defer tracker.free();
    Scene capture = scene::create_scene(&tracker, { .max_nodes = part_count + 1 });
    defer scene::destroy_scene(&capture);
    Transform[1] placement = { maths::TRANSFORM_IDENTITY };
    @each_impostor_part(scene, subject, inverse; ImpostorPart part) {
        Vec4[1] colors = { part.color };
        Node* captured = capture.add_instanced_mesh(
            geometry: part.geometry,
            material: part.material,
            capacity: 1,
            transforms: placement[..],
            colors: colors[..],
        )!;
        captured.world = part.world;
        capture.get(captured, InstancedMesh).cast_shadow = false;
    };
    float margin = sphere.radius * IMPOSTOR_CAPTURE_MARGIN;
    float far = 2 * (sphere.radius + margin);
    Node* camera_node = capture.add_camera(camera::orthographic(2 * sphere.radius, 0, far))!;
    wait_frames(self)!;
    RenderTargetId target = create_render_target(self, render_target_desc(layout.usable, layout.usable))!;
    defer (void)destroy_render_target(self, target);
    ViewDesc view_desc = texture_view_desc(target);
    view_desc.shading = ShadingPath.DEFERRED;
    view_desc.depth_prepass = false;
    view_desc.instance_culling = false;
    view_desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = create_view(self, view_desc)!;
    defer (void)destroy_view(self, view);
    ViewRecord* record = self.views.get(view);
    prepare_impostor_readback_targets(self, record)!;
    usz texels = (usz)layout.usable * layout.usable;
    usz color_bytes = texels * 4;
    usz normal_bytes = texels * 8;
    usz depth_offset = color_bytes + normal_bytes;
    usz readback_bytes = depth_offset + color_bytes;
    gpu::AllocationDesc allocation_desc = {
        .size = readback_bytes,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "impostor_readback",
    };
    gpu::GpuAllocation allocation = gpu::allocate_memory(&self.device, &allocation_desc)!;
    defer (void)gpu::free_allocation(&self.device, &allocation);
    gpu::GpuSpan span = gpu::get_allocation_span(&self.device, allocation)!;
    char[] atlas = alloc::new_array(self.assets.allocator, char, (sz)layout.bytes);
    defer catch alloc::free(self.assets.allocator, atlas.ptr);
    usz[] dilation = alloc::new_array(self.allocator, usz, (sz)desc.cell_size * desc.cell_size * 2);
    defer alloc::free(self.allocator, dilation.ptr);
    for (uint frame = 0; frame < desc.frames_per_side * desc.frames_per_side; frame++) {
        Vec3 direction = impostor_frame_direction(frame, desc.frames_per_side);
        camera_node.world = impostor_camera(sphere, direction, margin);
        begin_renderer_frame(self, { .reference_position = sphere.center }, false)!;
        defer catch { if (self.frame_open) abort_frame(self); }
        self.render_view(&capture, camera_node, view)!;
        self.finish_view(view)!;
        TextureReadback[3] reads = {
            { .target = &record.gbuffer[GBufferChannel.BASE_COLOR_METALLIC], .destination = span.unchecked_subspan(0, color_bytes) },
            { .target = &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS], .destination = span.unchecked_subspan(color_bytes, normal_bytes) },
            { .target = &record.depth, .destination = span.unchecked_subspan(depth_offset, color_bytes) },
        };
        foreach (&read : reads) record_texture_readback(&self.commands, read)!;
        self.end_frame()!;
        wait_frames(self)!;
        gpu::invalidate_mapped_span(&self.device, span)!;
        char[] mapped = gpu::mapped_gpu_span(&self.device, span)!.bytes;
        pack_impostor_frame(
            atlas: atlas,
            desc: desc,
            frame: frame,
            color: mapped[:color_bytes],
            normal: ((ushort*)(mapped.ptr + color_bytes))[:texels * 4],
            depth: ((float*)(mapped.ptr + depth_offset))[:texels],
        );
        dilate_impostor_frame(
            atlas: atlas,
            desc: desc,
            frame: frame,
            scratch: dilation,
        );
    }
    material::TextureDesc texture_desc = material::texture_2d_desc(layout.width, layout.height, PixelFormat.RGBA8_UNORM);
    texture_desc.generate_mips = false;
    TextureId texture = self.assets.add_texture_owned(texture_desc, atlas, key)!;
    self.last_impostor_bake = {
        .elapsed_ms = elapsed_ms(started),
        .atlas_bytes = layout.bytes,
        .capture_texel_bytes = texels * (8 + 8 + 4 + 4 + 8 + 8 + 4 + 4),
        .readback_bytes = readback_bytes,
        .scene_host_peak = (usz)tracker.max_allocated(),
    };
    return { .atlas = texture, .bounds = sphere, .frames_per_side = desc.frames_per_side, .cell_size = desc.cell_size };
}

macro void @each_impostor_part(Scene* scene, Node* subject, Mat4 inverse; @body(ImpostorPart part)) @local {
    foreach (&node : scene.nodes) {
        if (!scene.world.is_alive(node.id) || !node.visible_effective) continue;
        Node* ancestor = node;
        while (ancestor && ancestor != subject) ancestor = ancestor.parent;
        if (!ancestor) continue;
        Mat4 local = inverse.mul(node.world);
        if (scene.has(node, LodGroup)) {
            LodGroupState* group = scene.get(node, LodGroup).state;
            LodLevel level = group.desc.levels[0];
            uint count = group.mode == LodMode.INSTANCED ? group.count : 1;
            for (uint instance = 0; instance < count; instance++) {
                Mat4 world = group.mode == LodMode.INSTANCED ? local.mul(group.transforms[instance].to_mat4()) : local;
                Vec4 color = group.mode == LodMode.INSTANCED ? group.colors[instance] : (Vec4){ 1, 1, 1, 1 };
                foreach (part : group.desc.parts[level.first_part:level.part_count]) {
                    @body((ImpostorPart){ .geometry = part.geometry, .material = part.material, .world = world.mul(part.local), .color = color });
                }
            }
        } else if (scene.has(node, InstancedMesh)) {
            InstancedMesh* batch = scene.get(node, InstancedMesh);
            for (uint instance = 0; instance < batch.count; instance++) {
                @body((ImpostorPart){ .geometry = batch.geometry, .material = batch.material, .world = local.mul(batch.transforms[instance].to_mat4()), .color = batch.colors[instance] });
            }
        } else if (scene.has(node, Mesh)) {
            Mesh* mesh = scene.get(node, Mesh);
            @body((ImpostorPart){ .geometry = mesh.geometry, .material = mesh.material, .world = local, .color = { 1, 1, 1, 1 } });
        }
    }
}

fn void? validate_impostor_part(AssetStore* assets, ImpostorPart* part) @local {
    foreach (value : ((float*)&part.world)[:Mat4::size / float::size]) {
        if (!math::is_finite(value)) return c3d::INVALID_ARGUMENT~;
    }
    if (part.world.determinant() == 0) return c3d::INVALID_ARGUMENT~;
    GeometryAsset* geometry = assets.geometries.try_get(part.geometry)!;
    Material* material = &assets.materials.try_get(part.material)!.data;
    if (geometry.target_count || geometry.skin_bounds.joints.len || geometry.data.joints.len
      || material.kind != MaterialKind.STANDARD || material.common.alpha_mode == AlphaMode.BLEND
      || material.common.wireframe || !material.common.depth_test || !material.common.depth_write) return c3d::UNSUPPORTED~;
    StandardParams* surface = &material.standard;
    if (surface.metallic != 0 || (surface.emissive * surface.emissive_strength).length_sq() != 0
      || (surface.occlusion_strength != 0 && (surface.occlusion_map.texture.kind != TextureRefKind.ASSET
        || surface.occlusion_map.texture.asset.generation))) return c3d::UNSUPPORTED~;
    if (!geometry.data.positions.len) return c3d::ASSET_DATA_UNAVAILABLE~;
    TextureSlot*[3] slots = { &surface.base_color_map, &surface.normal_map, &surface.metallic_roughness_map };
    foreach (slot : slots) {
        if (slot.texture.kind != TextureRefKind.ASSET) return c3d::UNSUPPORTED~;
        if (slot.texture.asset.generation) (void)assets.textures.try_get(slot.texture.asset)!;
    }
}

fn Mat4 impostor_camera(Sphere sphere, Vec3 direction, float margin) @private {
    Vec3 up = math::abs(direction.y) > shader::IMPOSTOR_POLE_LIMIT ? (Vec3){ 0, 0, 1 } : (Vec3){ 0, 1, 0 };
    Vec3 side = up.cross(direction).normalize();
    up = direction.cross(side);
    Vec3 eye = sphere.center + direction * (sphere.radius + margin);
    return {
        .m00 = side.x, .m01 = up.x, .m02 = direction.x, .m03 = eye.x,
        .m10 = side.y, .m11 = up.y, .m12 = direction.y, .m13 = eye.y,
        .m20 = side.z, .m21 = up.z, .m22 = direction.z, .m23 = eye.z,
        .m33 = 1,
    };
}

fn void? prepare_impostor_readback_targets(Renderer* renderer, ViewRecord* record) @local {
    Target*[3] targets = { &record.gbuffer[GBufferChannel.BASE_COLOR_METALLIC], &record.gbuffer[GBufferChannel.NORMAL_ROUGHNESS], &record.depth };
    foreach (uint index, target : targets) {
        uint width = target.width;
        uint height = target.height;
        gpu::Format format = target.format;
        release_target(&renderer.device, target);
        *target = allocate_target(
            device: &renderer.device,
            width: width,
            height: height,
            format: format,
            usage: index == 2 ? (gpu::TextureUsage){ .depth_attach, .sampled, .transfer_src } : (gpu::TextureUsage){ .color_attach, .sampled, .transfer_src },
            debug_name: "impostor_capture",
        )!;
    }
}

fn void pack_impostor_frame(
    char[] atlas,
    ImpostorDesc desc,
    uint frame,
    char[] color,
    ushort[] normal,
    float[] depth,
) @private {
    uint width = desc.frames_per_side * desc.cell_size;
    uint usable = desc.cell_size - 2 * shader::IMPOSTOR_GUTTER;
    uint first_x = frame % desc.frames_per_side * desc.cell_size;
    uint first_y = frame / desc.frames_per_side * desc.cell_size;
    for (uint y = 0; y < desc.cell_size; y++) {
        for (uint x = 0; x < desc.cell_size; x++) {
            uint sample_x = (uint)math::clamp((int)x - (int)shader::IMPOSTOR_GUTTER, 0, (int)usable - 1);
            uint sample_y = (uint)math::clamp((int)y - (int)shader::IMPOSTOR_GUTTER, 0, (int)usable - 1);
            usz source = (usz)sample_y * usable + sample_x;
            float normalized_depth = ((1 - depth[source]) * 2 * (1 + IMPOSTOR_CAPTURE_MARGIN) - IMPOSTOR_CAPTURE_MARGIN) * 0.5f;
            PackedImpostorSurface packed = pack_impostor_surface({
                .color = (Vec3){ (float)color[source * 4], (float)color[source * 4 + 1], (float)color[source * 4 + 2] } / 255.0f,
                .normal = decode_octahedral({ impostor_half(normal[source * 4]), impostor_half(normal[source * 4 + 1]) }),
                .roughness = impostor_half(normal[source * 4 + 2]),
                .depth = normalized_depth,
                .covered = depth[source] > 0,
            });
            usz destination = ((usz)(first_y + y) * width + first_x + x) * IMPOSTOR_TEXEL_BYTES;
            atlas[destination:4] = packed.color[..];
            atlas[destination + (usz)width * width * IMPOSTOR_TEXEL_BYTES:4] = packed.surface[..];
        }
    }
}

fn void dilate_impostor_frame(
    char[] atlas,
    ImpostorDesc desc,
    uint frame,
    usz[] scratch,
) @private {
    usz width = (usz)desc.frames_per_side * desc.cell_size;
    usz count = (usz)desc.cell_size * desc.cell_size;
    usz first = ((usz)(frame / desc.frames_per_side) * desc.cell_size * width
      + (usz)(frame % desc.frames_per_side) * desc.cell_size) * IMPOSTOR_TEXEL_BYTES;
    usz surface_offset = width * width * IMPOSTOR_TEXEL_BYTES;
    usz[] nearest = scratch[:count];
    usz[] queue = scratch[count:count];
    usz queued;
    for (usz index = 0; index < count; index++) {
        usz pixel = first + (index / desc.cell_size * width + index % desc.cell_size) * IMPOSTOR_TEXEL_BYTES;
        nearest[index] = atlas[pixel + 3] ? index : usz::max;
        if (atlas[pixel + 3]) queue[queued++] = index;
    }
    for (usz cursor = 0; cursor < queued; cursor++) {
        usz index = queue[cursor];
        uint column = (uint)(index % desc.cell_size);
        uint row = (uint)(index / desc.cell_size);
        foreach (int[2] step : { { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 } }) {
            int next_column = (int)column + step[0];
            int next_row = (int)row + step[1];
            if (next_column < 0 || next_row < 0
              || (uint)next_column >= desc.cell_size || (uint)next_row >= desc.cell_size) continue;
            usz next = (usz)next_row * desc.cell_size + (usz)next_column;
            if (nearest[next] != usz::max) continue;
            nearest[next] = nearest[index];
            queue[queued++] = next;
            usz source = first + surface_offset
              + (nearest[next] / desc.cell_size * width + nearest[next] % desc.cell_size) * IMPOSTOR_TEXEL_BYTES;
            usz destination = first + surface_offset
              + ((usz)next_row * width + (usz)next_column) * IMPOSTOR_TEXEL_BYTES;
            atlas[destination:4] = atlas[source:4];
        }
    }
}

fn ImpostorLayout? impostor_layout(ImpostorDesc desc) @private {
    uint frames = desc.frames_per_side;
    if (frames < IMPOSTOR_MIN_FRAMES || frames > IMPOSTOR_MAX_FRAMES || (frames & (frames - 1)) != 0
      || desc.cell_size < IMPOSTOR_MIN_CELL) return c3d::INVALID_ARGUMENT~;
    ulong width = (ulong)frames * desc.cell_size;
    if (width > uint::max / 2 || width > (ulong)sz::max / (width * 2 * IMPOSTOR_TEXEL_BYTES)) {
        return c3d::INVALID_ARGUMENT~;
    }
    return {
        .width = (uint)width,
        .height = (uint)width * 2,
        .usable = desc.cell_size - 2 * shader::IMPOSTOR_GUTTER,
        .bytes = (usz)(width * width * 2 * IMPOSTOR_TEXEL_BYTES),
    };
}

fn Vec3 impostor_frame_direction(uint index, uint side) @private {
    if (side == shader::IMPOSTOR_TETRA_SIDE) {
        Vec3 direction = {
            (shader::IMPOSTOR_TETRA_X_BITS >> index) & 1 ? 1 : -1,
            (shader::IMPOSTOR_TETRA_Y_BITS >> index) & 1 ? 1 : -1,
            (shader::IMPOSTOR_TETRA_Z_BITS >> index) & 1 ? 1 : -1,
        };
        return direction.normalize();
    }
    Vec2 encoded = { (float)(index % side), (float)(index / side) };
    return decode_octahedral(encoded * (2.0f / (float)(side - 1)) - 1);
}

fn ImpostorFrames impostor_frames(Vec3 direction, uint side) @private {
    if (side == shader::IMPOSTOR_TETRA_SIDE) {
        float[4] weights;
        uint excluded;
        for (uint index = 0; index < 4; index++) {
            weights[index] = (1 + 3 * direction.dot(impostor_frame_direction(index, side))) * 0.25f;
            if (weights[index] < weights[excluded]) excluded = index;
        }
        ImpostorFrames selected;
        uint next;
        foreach (uint index, weight : weights) {
            if (index == excluded) continue;
            selected.indices[next] = index;
            selected.weights[next++] = math::max(weight, 0.0f);
        }
        selected.weights /= selected.weights.x + selected.weights.y + selected.weights.z;
        return selected;
    }
    Vec2 grid = (encode_octahedral(direction) * 0.5f + 0.5f) * (float)(side - 1);
    uint x = math::min((uint)math::max(grid.x, 0.0f), side - 2);
    uint y = math::min((uint)math::max(grid.y, 0.0f), side - 2);
    Vec2 fraction = math::clamp(grid - (Vec2){ (float)x, (float)y }, (Vec2){}, (Vec2){ 1, 1 });
    uint first = y * side + x;
    if (fraction.x + fraction.y <= 1) {
        return { .indices = { first, first + 1, first + side }, .weights = { 1 - fraction.x - fraction.y, fraction.x, fraction.y } };
    }
    return { .indices = { first + side + 1, first + side, first + 1 }, .weights = { fraction.x + fraction.y - 1, 1 - fraction.x, 1 - fraction.y } };
}

fn PackedImpostorSurface pack_impostor_surface(ImpostorSurface sample) @private {
    if (!sample.covered) return {};
    Vec2 normal = encode_octahedral(sample.normal) * 0.5f + 0.5f;
    return {
        .color = { impostor_unorm(sample.color.x), impostor_unorm(sample.color.y), impostor_unorm(sample.color.z), char::max },
        .surface = { impostor_unorm(normal.x), impostor_unorm(normal.y), impostor_unorm(sample.roughness), impostor_unorm(sample.depth) },
    };
}

fn char impostor_unorm(float value) @local {
    return (char)math::round(math::clamp(value, 0.0f, 1.0f) * (float)char::max);
}

fn float impostor_half(ushort bits) @private {
    uint exponent = (bits >> 10) & 31;
    uint mantissa = bits & 1023;
    float value = exponent ? (float)(1024 + mantissa) * math::exp2((float)exponent - 25)
      : (float)mantissa * math::exp2(-24.0f);
    return (bits & 0x8000) != 0 ? -value : value;
}

fn Material* candidate_material(Renderer* renderer, MeshCandidate* candidate) @private {
    if (!candidate.impostor) return &renderer.assets.material(candidate.material).data;
    renderer.impostor_material = material::standard();
    renderer.impostor_material.common.double_sided = true;
    return &renderer.impostor_material;
}

fn GpuGeometry* acquire_impostor_geometry(Renderer* renderer) @private {
    renderer.impostor_geometry = {
        .layout = { .vertex_count = 6 },
        .topology = Topology.TRIANGLES,
    };
    return &renderer.impostor_geometry;
}

fn gpu::GpuAddress? resolve_impostor(Renderer* renderer, LodSelection* selection) @private {
    Impostor* impostor = &selection.state.impostor;
    TextureBinding texture = resolve_texture_slot(renderer, {
        .texture = { .asset = impostor.atlas },
        .sampler = asset::SAMPLER_LINEAR_CLAMP,
    })!;
    ImpostorGpu block = {
        .bounds = { impostor.bounds.center.x, impostor.bounds.center.y, impostor.bounds.center.z, impostor.bounds.radius },
        .previous_camera = selection.history.committed.camera,
        .previous_direction = selection.history.committed.direction,
        .atlas = texture.texture_index,
        .sampler_index = texture.sampler_index,
        .frames_per_side = impostor.frames_per_side,
        .cell_size = impostor.cell_size,
    };
    if (selection.state.mode == LodMode.SINGLE) {
        Vec3 delta = selection.history.committed.origin - selection.previous_view_origin;
        block.previous_camera.x += delta.x;
        block.previous_camera.y += delta.y;
        block.previous_camera.z += delta.z;
    }
    return upload_bytes(renderer, &block, ImpostorGpu::size);
}

fn void? prepare_impostor(
    Renderer* renderer,
    Impostor* impostor,
    bool depth,
    bool gbuffer,
) @private {
    resolve_texture_slot(renderer, {
        .texture = { .asset = impostor.atlas },
        .sampler = asset::SAMPLER_LINEAR_CLAMP,
    })!;
    MeshCandidate candidate = { .impostor = true };
    Material* material = candidate_material(renderer, &candidate);
    ShaderVariant vertex = { .shader = IMPOSTOR_VERTEX };
    pipeline_for(renderer, material, vertex)!;
    if (gbuffer) gbuffer_pipeline_for(renderer, material, vertex)!;
    if (depth) shadow_pipeline_for(renderer, false, vertex)!;
}
