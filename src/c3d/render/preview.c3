module c3d::render;

import c3d;
import c3d::material;
import c3d::shader;
import gpu;
import std::math;

<*
 Image a preview visualizes.
*>
enum PreviewKind {
    VIEW_COLOR,
    VIEW_DEPTH,
    VIEW_VELOCITY,
    VIEW_SCENE_COLOR,
    VIEW_BLOOM,
    VIEW_DOF_NEAR,
    VIEW_DOF_FAR,
    VIEW_MOTION_BLUR,
    RENDER_TARGET,
    SHADOW_LAYER,
    ENVIRONMENT_FACE,
    TEXTURE,
    VIEW_CLUSTERS,
    VIEW_GBUFFER,
}

<*
 One preview source; only the fields its kind names are read.
*>
struct PreviewSource {
    PreviewKind    kind;
    ViewId         view;
    uint           level;
    RenderTargetId target;
    uint           layer;
    EnvironmentId  environment;
    CubeFace       face;
    TextureId      texture;
}

<*
 Extent and visualization scales of one preview: exposure for color sources, range as the depth or velocity shown white.
*>
struct PreviewParams {
    uint  width;
    uint  height;
    float exposure;
    float range;
}

<*
 Preview images a renderer keeps at once.
*>
const uint PREVIEW_CAPACITY = 8; // RGBA8 images at panel size, one dispatch each per frame

<*
 Largest preview edge in pixels.
*>
const uint PREVIEW_MAX_SIZE = 1024; // 4 MiB per image at the cap

<*
 Renderer-owned preview image and the request that fills it.
*>
struct PreviewSlot {
    Target        image;
    PreviewSource source;
    PreviewParams params;
    bool          requested;
}

const gpu::Format PREVIEW_FORMAT @local = gpu::Format.RGBA8_UNORM;

<*
 Request a visualization of a source into a preview slot for the next overlay.
 @param [&inout] self : "Allocates or resizes the slot image between frames."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? gpu::INVALID_ARGUMENT, gpu::UNSUPPORTED_FEATURE, gpu::SLOT_TABLE_FULL
 @return? gpu::DESCRIPTOR_HEAP_FULL, gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !self.frame_open, slot < PREVIEW_CAPACITY
*>
fn void? Renderer.request_preview(
    &self,
    uint slot,
    PreviewSource source,
    PreviewParams params,
) {
    uint layer_count = (uint)self.shadow_atlas.layers.len;
    uint bloom_levels;
    bool texture_is_cube;
    uint texture_depth;
    uint cluster_slices;
    switch (source.kind) {
        case VIEW_COLOR:
        case VIEW_DEPTH:
        case VIEW_VELOCITY:
        case VIEW_SCENE_COLOR:
        case VIEW_BLOOM:
        case VIEW_DOF_NEAR:
        case VIEW_DOF_FAR:
        case VIEW_MOTION_BLUR:
        case VIEW_GBUFFER:
            bloom_levels = self.views.try_get(source.view)!.bloom_levels;
        case VIEW_CLUSTERS:
            ViewRecord* record = self.views.try_get(source.view)!;
            if (record.desc.lights == CLUSTERED) cluster_slices = record.desc.clusters.depth_slices;
        case RENDER_TARGET:
            self.targets.try_get(source.target)!;
        case SHADOW_LAYER:
            break;
        case ENVIRONMENT_FACE:
            if (!self.assets.environments.is_live(source.environment)) return c3d::INVALID_ID~;
        case TEXTURE:
            if (!self.assets.textures.is_live(source.texture)) return c3d::INVALID_ID~;
            material::TextureDesc* desc = &self.assets.texture(source.texture).desc;
            texture_is_cube = desc.is_cube;
            texture_depth = desc.depth;
    }
    validate_preview_request(
        source:          source,
        params:          params,
        layer_count:     layer_count,
        bloom_levels:    bloom_levels,
        texture_is_cube: texture_is_cube,
        texture_depth:   texture_depth,
        cluster_slices:  cluster_slices,
    )!;

    PreviewSlot* preview = &self.previews[slot];
    acquire_preview_image(self, preview, params.width, params.height)!;
    preview.source = source;
    preview.params = params;
    preview.requested = true;
}

<*
 Sampled view index of a slot's preview image.
 @require slot < PREVIEW_CAPACITY, self.previews[slot].image.texture.is_valid()
*>
fn gpu::TextureIndex Renderer.preview_texture(&self, uint slot) {
    return self.previews[slot].image.view.index;
}

<*
 Reject a preview request whose extent or indices fall outside their source.
 @param texture_is_cube : "Only read for TEXTURE."
 @param texture_depth : "Only read for TEXTURE; nonzero for a volume."
 @param cluster_slices : "Configured slices; zero for an unavailable clustered source."
 @return? c3d::INVALID_ARGUMENT
 @pure
*>
fn void? validate_preview_request(
    PreviewSource source,
    PreviewParams params,
    uint layer_count,
    uint bloom_levels,
    bool texture_is_cube,
    uint texture_depth,
    uint cluster_slices = 0,
) {
    if (!params.width || !params.height) return c3d::INVALID_ARGUMENT~;
    if (params.width > PREVIEW_MAX_SIZE || params.height > PREVIEW_MAX_SIZE) return c3d::INVALID_ARGUMENT~;
    switch (source.kind) {
        case VIEW_BLOOM:
            if (source.level >= bloom_levels) return c3d::INVALID_ARGUMENT~;
        case VIEW_CLUSTERS:
            if (source.level >= cluster_slices) return c3d::INVALID_ARGUMENT~;
        case VIEW_GBUFFER:
            if (source.level >= GBUFFER_CHANNEL_COUNT) return c3d::INVALID_ARGUMENT~;
        case SHADOW_LAYER:
            if (source.layer >= layer_count) return c3d::INVALID_ARGUMENT~;
        case TEXTURE:
            if (texture_is_cube || texture_depth) return c3d::INVALID_ARGUMENT~;
        default:
            break;
    }
}

<*
 Direction a cube face preview samples at a texel; mirrored in preview.comp.glsl.
 @param uv : "Texel center in [0, 1] with y downward."
 @pure
*>
fn Vec3 preview_face_direction(CubeFace face, Vec2 uv) {
    float u = uv.x * 2 - 1;
    float v = uv.y * 2 - 1;
    switch (face) {
        case POSITIVE_X: return { 1, -v, -u };
        case NEGATIVE_X: return { -1, -v, u };
        case POSITIVE_Y: return { u, 1, v };
        case NEGATIVE_Y: return { u, -1, -v };
        case POSITIVE_Z: return { u, -v, 1 };
        case NEGATIVE_Z: return { -u, -v, -1 };
    }
}

<*
 Whether a preview of the view's bloom chain is waiting for this frame.
 @param [&in] record : "Live view record of the renderer."
*>
fn bool bloom_preview_requested(Renderer* renderer, ViewRecord* record) {
    usz view_index = (usz)(record - renderer.views.items.ptr);
    foreach (&preview : renderer.previews) {
        if (preview.requested && preview.source.kind == PreviewKind.VIEW_BLOOM
            && preview.source.view.index == view_index) return true;
    }
    return false;
}

fn void? record_previews(Renderer* renderer) @private {
    foreach (&preview : renderer.previews) {
        if (!preview.requested) continue;
        // A bloom request that arrived after its view finished waits for a frame that records the chain.
        if (preview.source.kind == PreviewKind.VIEW_BLOOM
            && !renderer.views.get(preview.source.view).bloom_recorded) continue;
        preview.requested = false;

        PreviewRoot root = {
            .output_texture = preview.image.view.index,
            .input_sampler  = renderer.linear_clamp_sampler,
            .width          = preview.image.width,
            .height         = preview.image.height,
            .mode           = shader::PREVIEW_MODE_CLEAR,
            .face           = (uint)preview.source.face.ordinal,
            .exposure       = preview.params.exposure,
            .range          = preview.params.range,
        };
        resolve_preview_source(renderer, preview, &root)!;

        acquire_compute_pipeline(renderer, &renderer.preview_pipeline, PREVIEW, "preview")!;
        preview.image.transition(&renderer.commands, gpu::storage_at({ .compute }, { .write }))!;

        Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan root_span = slot.upload.take(&renderer.device, PreviewRoot::size)!;
        *(PreviewRoot*)root_span.bytes.ptr = root;
        gpu::cmd_bind_pipeline(&renderer.commands, renderer.preview_pipeline)!;
        uint groups_x = (root.width + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
        uint groups_y = (root.height + shader::POST_GROUP_SIZE - 1) / shader::POST_GROUP_SIZE;
        gpu::cmd_dispatch(&renderer.commands, root_span.address, { groups_x, groups_y, 1 })!;

        preview.image.transition(&renderer.commands, gpu::sampled_at({ .fragment_shader }))!;
    }
}

fn void? resolve_preview_source(Renderer* renderer, PreviewSlot* preview, PreviewRoot* root) @private {
    PreviewSource source = preview.source;
    gpu::TextureState compute_read = gpu::sampled_at({ .compute });
    switch (source.kind) {
        case VIEW_COLOR:
        case VIEW_DEPTH:
        case VIEW_VELOCITY:
        case VIEW_SCENE_COLOR:
        case VIEW_BLOOM:
        case VIEW_DOF_NEAR:
        case VIEW_DOF_FAR:
        case VIEW_MOTION_BLUR:
        case VIEW_GBUFFER:
            ViewRecord* record = renderer.views.get(source.view);
            if (!record.live) return;
            Target* target = view_preview_target(record, source);
            if (!target.texture.is_valid()) return;
            target.transition(&renderer.commands, compute_read)!;
            root.input_texture = target.view.index;
            root.mode = shader::PREVIEW_MODE_COLOR;
            if (source.kind == PreviewKind.VIEW_DEPTH) {
                root.mode = shader::PREVIEW_MODE_DEPTH_VIEW;
                root.proj_22 = record.projection_terms.m22;
                root.proj_23 = record.projection_terms.m23;
                root.orthographic = record.projection_terms.orthographic ? 1 : 0;
            } else if (source.kind == PreviewKind.VIEW_VELOCITY) {
                root.mode = shader::PREVIEW_MODE_VELOCITY;
            } else if (source.kind == PreviewKind.VIEW_GBUFFER) {
                root.mode = gbuffer_preview_mode(GBufferChannel::from_ordinal(source.level));
            }
        case VIEW_CLUSTERS:
            if (!renderer.views.is_live(source.view)) return;
            ViewRecord* record = renderer.views.get(source.view);
            if (record.desc.lights != CLUSTERED || record.cluster_root == (gpu::GpuAddress)0) return;
            if (record.cluster_depth.near >= record.cluster_depth.far) return;
            if (record.cluster_depth.slices != record.desc.clusters.depth_slices) return;
            if (source.level >= record.cluster_depth.slices) return;
            root.clusters = record.cluster_root;
            root.cluster_slice = source.level;
            root.mode = shader::PREVIEW_MODE_CLUSTERS;
        case RENDER_TARGET:
            if (!renderer.targets.is_live(source.target)) return;
            Target* target = &renderer.targets.get(source.target).target;
            target.transition(&renderer.commands, compute_read)!;
            root.input_texture = target.view.index;
            root.mode = shader::PREVIEW_MODE_COLOR;
        case SHADOW_LAYER:
            if (source.layer >= renderer.shadow_atlas.layers.len) return;
            transition_shadow_atlas(&renderer.shadow_atlas, &renderer.commands, compute_read)!;
            root.input_texture = renderer.shadow_atlas.layers[source.layer].view.index;
            root.mode = shader::PREVIEW_MODE_DEPTH_RAW;
        case ENVIRONMENT_FACE:
            EnvironmentRes* environment = &renderer.environment_state.mirrors[source.environment.index];
            bool current = environment.asset.index == source.environment.index
                && environment.asset.generation == source.environment.generation;
            if (!current || !environment.lighting_ready) return;
            root.input_texture = environment.specular_view.index;
            root.input_sampler = renderer.environment_state.sampler;
            root.mode = shader::PREVIEW_MODE_CUBE_FACE;
        case TEXTURE:
            TextureRes* mirror = &renderer.textures[source.texture.index];
            bool current = mirror.asset.index == source.texture.index
                && mirror.asset.generation == source.texture.generation;
            if (!current || !mirror.texture.is_valid()) return;
            gpu::TextureBarrier barrier = gpu::texture_transition(mirror.texture, mirror.state, compute_read)!;
            gpu::cmd_texture_barrier(&renderer.commands, &barrier)!;
            mirror.state = compute_read;
            root.input_texture = mirror.view.index;
            root.mode = shader::PREVIEW_MODE_COLOR;
    }
}

fn Target* view_preview_target(ViewRecord* record, PreviewSource source) @private {
    switch (source.kind) {
        case VIEW_COLOR:       return &record.hdr_color;
        case VIEW_DEPTH:       return &record.depth;
        case VIEW_VELOCITY:    return &record.velocity;
        case VIEW_SCENE_COLOR: return &record.scene_color;
        case VIEW_BLOOM:       return &record.bloom[source.level];
        case VIEW_DOF_NEAR:    return &record.dof_near;
        case VIEW_DOF_FAR:     return &record.dof_far;
        case VIEW_MOTION_BLUR: return &record.motion_blur_out;
        case VIEW_GBUFFER:     return &record.gbuffer[source.level];
        default:               unreachable("not a view image");
    }
}

fn uint gbuffer_preview_mode(GBufferChannel channel) @local {
    switch (channel) {
        case BASE_COLOR_METALLIC: return shader::PREVIEW_MODE_RAW;
        case NORMAL_ROUGHNESS:    return shader::PREVIEW_MODE_OCTAHEDRAL_NORMAL;
        case EMISSIVE_SPECULAR:   return shader::PREVIEW_MODE_COLOR;
        case LAYERS:
        case FLAGS:               return shader::PREVIEW_MODE_BITS;
    }
}

fn void? acquire_preview_image(Renderer* renderer, PreviewSlot* preview, uint width, uint height) @private {
    Target* image = &preview.image;
    if (image.texture.is_valid() && image.width == width && image.height == height) return;
    if (image.texture.is_valid()) {
        RetireList* retire = &renderer.frames[renderer.recording_slot].retire;
        retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = image.view });
        retire.push({ .kind = RetiredKind.TEXTURE, .texture = image.texture });
        *image = {};
    }

    gpu::TextureDesc texture_desc = {
        .width      = width,
        .height     = height,
        .format     = PREVIEW_FORMAT,
        .usage      = { .sampled, .storage },
        .access     = { .graphics },
        .debug_name = "preview",
    };
    gpu::TextureHandle texture = gpu::create_texture(&renderer.device, &texture_desc)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, texture);
    gpu::TextureView view = gpu::create_texture_view(&renderer.device, texture, null)!;

    *image = {
        .texture = texture,
        .view    = view,
        .format  = PREVIEW_FORMAT,
        .width   = width,
        .height  = height,
    };
}

fn void release_previews(Renderer* renderer) @private {
    foreach (&preview : renderer.previews) {
        if (!preview.image.texture.is_valid()) continue;
        (void)gpu::destroy_texture_view(&renderer.device, preview.image.view);
        (void)gpu::destroy_texture(&renderer.device, preview.image.texture);
        preview.image = {};
    }
    if (renderer.preview_pipeline.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, renderer.preview_pipeline);
    renderer.preview_pipeline = {};
}

