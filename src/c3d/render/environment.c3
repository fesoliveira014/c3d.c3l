module c3d::render;

import c3d;
import c3d::asset;
import c3d::light;
import c3d::material;
import c3d::shader;
import gpu;

$assert shader::ENVIRONMENT_FACE_POSITIVE_X == (uint)material::CubeFace.POSITIVE_X.ordinal;
$assert shader::ENVIRONMENT_FACE_NEGATIVE_X == (uint)material::CubeFace.NEGATIVE_X.ordinal;
$assert shader::ENVIRONMENT_FACE_POSITIVE_Y == (uint)material::CubeFace.POSITIVE_Y.ordinal;
$assert shader::ENVIRONMENT_FACE_NEGATIVE_Y == (uint)material::CubeFace.NEGATIVE_Y.ordinal;
$assert shader::ENVIRONMENT_FACE_POSITIVE_Z == (uint)material::CubeFace.POSITIVE_Z.ordinal;
$assert shader::ENVIRONMENT_FACE_NEGATIVE_Z == (uint)material::CubeFace.NEGATIVE_Z.ordinal;
$assert shader::ENVIRONMENT_FACE_COUNT == material::CUBE_FACE_COUNT;

// Storage views per face and mip, mip-major.
const uint ENVIRONMENT_FILTERED_FACES @private = shader::ENVIRONMENT_FACE_COUNT * shader::ENVIRONMENT_SPECULAR_MIPS;

<* Preparation and submission state of one shared environment lookup. *>
enum EnvironmentLutState {
    NONE,
    PENDING,
    RECORDED,
    READY,
}

<* Owned texture and submission state of an environment lookup. *>
struct EnvironmentLut {
    gpu::TextureHandle texture;
    gpu::TextureView view;
    EnvironmentLutState state;
}

<* Submitted source and lighting resources for one environment. *>
struct EnvironmentRes {
    EnvironmentId asset;
    uint revision;
    uint lighting_revision;
    EnvironmentDesc description;
    uint source_revision;
    uint source_binding_revision;
    uint source_size;
    uint specular_size;
    uint sheen_size;
    bool source_owned;
    bool source_ready;
    bool lighting_ready;
    bool sheen_ready;
    gpu::TextureHandle source_cube;
    gpu::TextureView source_view;
    gpu::TextureView[shader::ENVIRONMENT_FACE_COUNT] source_faces;
    gpu::TextureHandle specular_cube;
    gpu::TextureView specular_view;
    gpu::TextureView[ENVIRONMENT_FILTERED_FACES] specular_faces;
    gpu::TextureHandle sheen_cube;
    gpu::TextureView sheen_view;
    gpu::TextureView[ENVIRONMENT_FILTERED_FACES] sheen_faces;
    gpu::GpuAllocation irradiance;
    gpu::GpuAddress irradiance_address;
    gpu::GpuAllocation irradiance_partials;
    gpu::GpuAddress partials_address;
}

<* Stable tentative mirror and its unsubmitted ownership. *>
struct PendingEnvironment {
    EnvironmentRes result;
    bool active;
    bool new_source;
    bool new_lighting;
    bool new_sheen;
    bool write_source;
    bool write_lighting;
    bool write_sheen;
    bool source_recorded;
    bool lighting_recorded;
    bool sheen_recorded;
    gpu::TextureIndex input_texture;
}

<* Renderer-shared fixed environment processing stages. *>
struct EnvironmentPipelines {
    gpu::PipelineHandle source;
    gpu::PipelineHandle prefilter;
    gpu::PipelineHandle project;
    gpu::PipelineHandle reduce;
    gpu::PipelineHandle brdf;
    gpu::PipelineHandle sheen_prefilter;
    gpu::PipelineHandle sheen_lut;
}

<* Renderer-owned environment resources and their pending preparation. *>
struct EnvironmentState {
    EnvironmentRes[] mirrors;
    PendingEnvironment[] pending;
    EnvironmentPipelines pipelines;
    gpu::SamplerIndex source_sampler;
    gpu::SamplerIndex sampler;
    bool samplers_ready;
    EnvironmentLut brdf_lut;
    EnvironmentLut sheen_lut;
    gpu::SamplerIndex sheen_sampler;
    uint lighting_serial;
}

<*
 Prepare an environment now or before this frame's sampling.
 Environment descriptions and source data stay stable until frame closure.
 @param [&inout] self : "Owns processing and its completion lifetime."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED
 @return? c3d::ASSET_DATA_UNAVAILABLE, c3d::SHADER_NOT_FOUND
 @return? gpu::SHADER_INVALID, gpu::PIPELINE_CREATE_FAILED, gpu::UNSUPPORTED_FEATURE
 @return? gpu::INVALID_ARGUMENT, gpu::INVALID_HANDLE, gpu::INVALID_RESOURCE_STATE
 @return? gpu::OUT_OF_HOST_MEMORY, gpu::OUT_OF_DEVICE_MEMORY
 @return? gpu::DEVICE_BUSY, gpu::RESOURCE_IN_USE, gpu::SLOT_TABLE_FULL, gpu::DESCRIPTOR_HEAP_FULL
 @return? gpu::COMMAND_RECORDING_ERROR, gpu::COMMAND_ALLOCATOR_CAPACITY_EXCEEDED
 @return? gpu::WAIT_TIMEOUT, gpu::DEVICE_LOST, gpu::BACKEND_ERROR
 @require !self.overlay_open, !self.frame_open || self.has_output
*>
fn void? Renderer.upload_environment(&self, EnvironmentId environment) {
    if (!self.assets.environments.is_live(environment)) return c3d::INVALID_ID~;
    if (self.frame_open) {
        resolve_environment(
            renderer: self,
            environment: environment,
            lighting: true,
            sheen: false,
        )!;
        return;
    }
    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    resolve_environment(
        renderer: self,
        environment: environment,
        lighting: true,
        sheen: false,
    )!;
    if (!has_environment_preparations(self) && !self.pending_texture_uploads.len()
        && !self.pending_copies.len() && !self.pending_upload_retire.len()) return;
    return submit_pending(self);
}

fn EnvironmentRes*? resolve_environment(
    Renderer* renderer,
    EnvironmentId environment,
    bool lighting,
    bool sheen,
) @private {
    EnvironmentAsset* record = renderer.assets.environment(environment);
    renderer.assets.validate_environment(record.desc)!;
    EnvironmentDesc description = record.desc;
    TextureRes* texture;
    uint source_revision;
    uint source_binding_revision;
    uint source_size = 1;
    bool source_owned = true;
    switch (description.kind) {
        case SOLID:
            description.source = {};
            description.settings.conversion_size = 0;
        case TEXTURE:
            texture = resolve_texture(renderer, description.source)!;
            source_revision = renderer.assets.texture(description.source).header.revision;
            source_binding_revision = texture.binding_revision;
            source_owned = !texture.is_cube;
            source_size = texture.is_cube ? texture.width : description.settings.conversion_size;
            description.solid_color = {};
            if (texture.is_cube) description.settings.conversion_size = 0;
    }

    PendingEnvironment* pending = &renderer.environment_state.pending[environment.index];
    EnvironmentRes* committed = &renderer.environment_state.mirrors[environment.index];
    EnvironmentRes* current = pending.active ? &pending.result : committed;
    bool same_source = c3d::same_id(current.asset, environment) && current.source_ready
      && current.description.kind == description.kind
      && c3d::same_id(current.description.source, description.source)
      && current.description.solid_color == description.solid_color
      && current.description.settings.conversion_size == description.settings.conversion_size
      && current.source_revision == source_revision
      && current.source_binding_revision == source_binding_revision
      && current.source_size == source_size && current.source_owned == source_owned;
    bool same_lighting = same_source && current.lighting_ready
      && current.description.settings.specular_size == description.settings.specular_size;
    bool same_sheen = same_source && current.sheen_ready
      && current.description.settings.specular_size == description.settings.specular_size;
    if (same_source && (!lighting || same_lighting) && (!sheen || same_sheen)) {
        current.revision = record.header.revision;
        return current;
    }

    EnvironmentRes result = *current;
    if (!c3d::same_id(result.asset, environment)) result = { .asset = environment };
    bool new_source;
    bool new_lighting;
    bool new_sheen;
    defer catch {
        if (new_source) release_environment_source(&renderer.device, &result);
        if (new_lighting) release_environment_lighting(&renderer.device, &result);
        if (new_sheen) release_environment_sheen(&renderer.device, &result);
    }
    if (!same_source) {
        bool rewrite = source_owned && result.source_owned && result.source_cube.is_valid()
          && result.source_size == source_size;
        result.source_revision = source_revision;
        result.source_binding_revision = source_binding_revision;
        result.source_size = source_size;
        result.source_owned = source_owned;
        if (!source_owned) {
            result.source_cube = texture.texture;
            result.source_view = texture.view;
            result.source_faces = {};
        } else if (!rewrite) {
            create_environment_cube(renderer, &result, false)!;
            new_source = true;
        }
        result.source_ready = true;
        result.lighting_ready = false;
        result.sheen_ready = false;
    }
    result.description = description;
    result.revision = record.header.revision;
    uint filtered_size = description.settings.specular_size;
    if (lighting && !same_lighting) {
        if (!result.specular_cube.is_valid() || result.specular_size != filtered_size) {
            result.specular_size = filtered_size;
            result.irradiance = {};
            result.irradiance_partials = {};
            create_environment_cube(renderer, &result, true)!;
            new_lighting = true;
            result.irradiance = allocate_environment_buffer(renderer, IrradianceGpu::size, "environment_irradiance")!;
            result.irradiance_address = environment_buffer_address(renderer, result.irradiance)!;
            result.irradiance_partials = allocate_environment_buffer(
                renderer,
                IrradianceGpu::size * shader::ENVIRONMENT_SH_GROUPS,
                "environment_irradiance_partials",
            )!;
            result.partials_address = environment_buffer_address(renderer, result.irradiance_partials)!;
        }
        acquire_environment_lut(renderer)!;
        result.lighting_ready = true;
        result.lighting_revision = ++renderer.environment_state.lighting_serial;
    } else if (!same_lighting) {
        result.lighting_ready = false;
    }
    if (sheen && !same_sheen) {
        if (!result.sheen_cube.is_valid() || result.sheen_size != filtered_size) {
            result.sheen_size = filtered_size;
            create_environment_sheen(renderer, &result)!;
            new_sheen = true;
        }
        acquire_sheen_lut(renderer)!;
        result.sheen_ready = true;
    } else if (!same_sheen) {
        result.sheen_ready = false;
    }
    acquire_environment_samplers(renderer)!;
    if (!pending.active) renderer.stats.environment_prepares++;
    pending.active = true;
    pending.result = result;
    pending.new_source |= new_source;
    pending.new_lighting |= new_lighting;
    pending.new_sheen |= new_sheen;
    pending.write_source |= !same_source && source_owned;
    pending.write_lighting |= lighting && !same_lighting;
    pending.write_sheen |= sheen && !same_sheen;
    if (texture) pending.input_texture = texture.view.index;
    return &pending.result;
}

fn void? create_environment_cube(Renderer* renderer, EnvironmentRes* result, bool specular) @local {
    gpu::TextureDesc description = {
        .width = specular ? result.specular_size : result.source_size,
        .height = specular ? result.specular_size : result.source_size,
        .mip_levels = specular ? shader::ENVIRONMENT_SPECULAR_MIPS : 1,
        .array_layers = shader::ENVIRONMENT_FACE_COUNT,
        .cube_compatible = true,
        .format = gpu::Format.RGBA16_FLOAT,
        .usage = { .sampled, .storage },
        .access = { .graphics },
        .debug_name = specular ? "environment_specular" : "environment_source",
    };
    gpu::TextureHandle texture = gpu::create_texture(&renderer.device, &description)!;
    defer catch (void)gpu::destroy_texture(&renderer.device, texture);
    gpu::TextureViewDesc view_desc = { .cube = true };
    gpu::TextureView view = gpu::create_texture_view(&renderer.device, texture, &view_desc)!;
    defer catch (void)gpu::destroy_texture_view(&renderer.device, view);
    if (specular) {
        create_environment_faces(renderer, texture, result.specular_faces[..])!;
        result.specular_cube = texture;
        result.specular_view = view;
    } else {
        create_environment_faces(renderer, texture, result.source_faces[..])!;
        result.source_cube = texture;
        result.source_view = view;
    }
}

fn void? create_environment_faces(Renderer* renderer, gpu::TextureHandle texture, gpu::TextureView[] faces) @private {
    usz created;
    defer catch release_environment_faces(&renderer.device, faces[:created]);
    foreach (index, &face : faces) {
        gpu::TextureViewDesc description = {
            .base_mip = (uint)(index / shader::ENVIRONMENT_FACE_COUNT),
            .mip_count = 1,
            .base_layer = (uint)(index % shader::ENVIRONMENT_FACE_COUNT),
            .layer_count = 1,
        };
        *face = gpu::create_texture_view(&renderer.device, texture, &description)!;
        created++;
    }
}

fn gpu::GpuAllocation? allocate_environment_buffer(Renderer* renderer, usz size, ZString debug_name) @local {
    gpu::AllocationDesc description = {
        .size = size,
        .alignment = STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.GPU_PRIVATE,
        .access = { .graphics },
        .debug_name = debug_name,
    };
    return gpu::allocate_memory(&renderer.device, &description);
}

fn gpu::GpuAddress? environment_buffer_address(Renderer* renderer, gpu::GpuAllocation allocation) @local {
    return gpu::get_span_address(&renderer.device, gpu::get_allocation_span(&renderer.device, allocation)!);
}

fn void? acquire_environment_samplers(Renderer* renderer) @local {
    if (renderer.environment_state.samplers_ready) return;
    gpu::SamplerDesc description = {
        .min_filter = gpu::Filter.LINEAR,
        .mag_filter = gpu::Filter.LINEAR,
        .mip_filter = gpu::Filter.LINEAR,
        .address_u = gpu::AddressMode.REPEAT,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_w = gpu::AddressMode.CLAMP_TO_EDGE,
        .max_lod = 0,
        .debug_name = "environment_equirectangular",
    };
    renderer.environment_state.source_sampler = gpu::intern_sampler(&renderer.device, &description)!;
    description.address_u = gpu::AddressMode.CLAMP_TO_EDGE;
    description.max_lod = (float)(shader::ENVIRONMENT_SPECULAR_MIPS - 1);
    description.debug_name = "environment_filtered";
    renderer.environment_state.sampler = gpu::intern_sampler(&renderer.device, &description)!;
    renderer.environment_state.samplers_ready = true;
}

fn void release_environment_faces(gpu::Device* device, gpu::TextureView[] faces) @private {
    foreach (face : faces) if (face.is_valid()) (void)gpu::destroy_texture_view(device, face);
}

fn void retire_environment_faces(RetireList* retire, gpu::TextureView[] faces) @private {
    foreach (face : faces) if (face.is_valid()) retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = face });
}

fn void release_environment_source(gpu::Device* device, EnvironmentRes* result) @private {
    if (!result.source_owned) return;
    release_environment_faces(device, result.source_faces[..]);
    if (result.source_view.is_valid()) (void)gpu::destroy_texture_view(device, result.source_view);
    if (result.source_cube.is_valid()) (void)gpu::destroy_texture(device, result.source_cube);
}

fn void release_environment_lighting(gpu::Device* device, EnvironmentRes* result) @private {
    release_environment_faces(device, result.specular_faces[..]);
    if (result.specular_view.is_valid()) (void)gpu::destroy_texture_view(device, result.specular_view);
    if (result.specular_cube.is_valid()) (void)gpu::destroy_texture(device, result.specular_cube);
    if (result.irradiance.is_valid()) (void)gpu::free_allocation(device, &result.irradiance);
    if (result.irradiance_partials.is_valid()) (void)gpu::free_allocation(device, &result.irradiance_partials);
}

fn void retire_environment_source(RetireList* retire, EnvironmentRes* result) @local {
    if (!result.source_owned || !result.source_cube.is_valid()) return;
    retire_environment_faces(retire, result.source_faces[..]);
    retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = result.source_view });
    retire.push({ .kind = RetiredKind.TEXTURE, .texture = result.source_cube });
}

fn void retire_environment_lighting(RetireList* retire, EnvironmentRes* result) @local {
    if (result.specular_cube.is_valid()) {
        retire_environment_faces(retire, result.specular_faces[..]);
        retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = result.specular_view });
        retire.push({ .kind = RetiredKind.TEXTURE, .texture = result.specular_cube });
    }
    if (result.irradiance.is_valid()) retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = result.irradiance });
    if (result.irradiance_partials.is_valid()) {
        retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = result.irradiance_partials });
    }
}

fn bool lut_unsubmitted(EnvironmentLut lut) @private {
    return lut.state == EnvironmentLutState.PENDING || lut.state == EnvironmentLutState.RECORDED;
}

fn void release_lut(gpu::Device* device, EnvironmentLut* lut) @private {
    (void)gpu::destroy_texture_view(device, lut.view);
    (void)gpu::destroy_texture(device, lut.texture);
    *lut = {};
}

fn bool has_environment_preparations(Renderer* renderer) @private {
    if (lut_unsubmitted(renderer.environment_state.sheen_lut)) return true;
    if (lut_unsubmitted(renderer.environment_state.brdf_lut)) return true;
    foreach (pending : renderer.environment_state.pending) if (pending.active) return true;
    return false;
}

fn void commit_environment_preparations(Renderer* renderer, Frame* slot) @private {
    foreach (index, &pending : renderer.environment_state.pending) {
        if (!pending.active) continue;
        EnvironmentRes* committed = &renderer.environment_state.mirrors[index];
        if (committed.source_cube != pending.result.source_cube) retire_environment_source(&slot.retire, committed);
        if (committed.specular_cube != pending.result.specular_cube) retire_environment_lighting(&slot.retire, committed);
        if (committed.sheen_cube != pending.result.sheen_cube) retire_environment_sheen(&slot.retire, committed);
        *committed = pending.result;
        *pending = {};
    }
    if (renderer.environment_state.brdf_lut.state == EnvironmentLutState.RECORDED) {
        renderer.environment_state.brdf_lut.state = EnvironmentLutState.READY;
    }
    if (renderer.environment_state.sheen_lut.state == EnvironmentLutState.RECORDED) {
        renderer.environment_state.sheen_lut.state = EnvironmentLutState.READY;
    }
}

fn void discard_environment_preparations(Renderer* renderer) @private {
    foreach (&pending : renderer.environment_state.pending) {
        if (!pending.active) continue;
        if (pending.new_source) release_environment_source(&renderer.device, &pending.result);
        if (pending.new_lighting) release_environment_lighting(&renderer.device, &pending.result);
        if (pending.new_sheen) release_environment_sheen(&renderer.device, &pending.result);
        *pending = {};
    }
    if (lut_unsubmitted(renderer.environment_state.sheen_lut)) {
        release_lut(&renderer.device, &renderer.environment_state.sheen_lut);
    }
    if (lut_unsubmitted(renderer.environment_state.brdf_lut)) {
        release_lut(&renderer.device, &renderer.environment_state.brdf_lut);
    }
}

fn void sweep_environments(Renderer* renderer) @private {
    foreach (&mirror : renderer.environment_state.mirrors) {
        if (!mirror.asset.generation || renderer.assets.environments.is_live(mirror.asset)) continue;
        retire_environment_source(&renderer.pending_upload_retire, mirror);
        retire_environment_lighting(&renderer.pending_upload_retire, mirror);
        retire_environment_sheen(&renderer.pending_upload_retire, mirror);
        *mirror = {};
    }
}

fn void free_environments(Renderer* renderer) @private {
    discard_environment_preparations(renderer);
    foreach (&mirror : renderer.environment_state.mirrors) {
        release_environment_source(&renderer.device, mirror);
        release_environment_lighting(&renderer.device, mirror);
        release_environment_sheen(&renderer.device, mirror);
    }
    if (renderer.environment_state.brdf_lut.state == EnvironmentLutState.READY) {
        release_lut(&renderer.device, &renderer.environment_state.brdf_lut);
    }
    if (renderer.environment_state.sheen_lut.state == EnvironmentLutState.READY) {
        release_lut(&renderer.device, &renderer.environment_state.sheen_lut);
    }
    gpu::PipelineHandle[7] pipelines = {
        renderer.environment_state.pipelines.source, renderer.environment_state.pipelines.prefilter,
        renderer.environment_state.pipelines.project, renderer.environment_state.pipelines.reduce,
        renderer.environment_state.pipelines.brdf, renderer.environment_state.pipelines.sheen_prefilter,
        renderer.environment_state.pipelines.sheen_lut,
    };
    foreach (pipeline : pipelines) if (pipeline.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, pipeline);
    alloc::free(renderer.allocator, renderer.environment_state.pending.ptr);
    alloc::free(renderer.allocator, renderer.environment_state.mirrors.ptr);
}
