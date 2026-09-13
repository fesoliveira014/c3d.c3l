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

<* Preparation and submission state of one shared environment lookup. *>
enum EnvironmentLutState {
    NONE,
    PENDING,
    RECORDED,
    READY,
}

<* Submitted source and lighting resources for one environment. *>
struct EnvironmentRes {
    EnvironmentId asset;
    uint revision;
    EnvironmentDesc description;
    uint source_revision;
    uint source_binding_revision;
    uint source_size;
    bool source_owned;
    bool source_ready;
    bool lighting_ready;
    bool sheen_ready;
    gpu::TextureHandle source_cube;
    gpu::TextureView source_view;
    gpu::TextureHandle specular_cube;
    gpu::TextureView specular_view;
    gpu::TextureHandle sheen_cube;
    gpu::TextureView sheen_view;
    gpu::GpuAllocation irradiance;
    gpu::GpuAddress irradiance_address;
}

<* Stable tentative mirror and its unsubmitted ownership. *>
struct PendingEnvironment {
    EnvironmentRes result;
    bool active;
    bool new_source;
    bool new_lighting;
    bool new_sheen;
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
    RetireList temporaries;
    gpu::SamplerIndex source_sampler;
    gpu::SamplerIndex sampler;
    bool samplers_ready;
    gpu::TextureHandle brdf_texture;
    gpu::TextureView brdf_view;
    EnvironmentLutState brdf_state;
    gpu::TextureHandle sheen_lut_texture;
    gpu::TextureView sheen_lut_view;
    gpu::SamplerIndex sheen_sampler;
    EnvironmentLutState sheen_lut_state;
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
        ensure_environment(
            renderer: self,
            environment: environment,
            lighting: true,
            sheen: false,
        )!;
        return;
    }
    open_closed_frame_slot(self)!;
    defer catch discard_uploads(self);
    ensure_environment(
        renderer: self,
        environment: environment,
        lighting: true,
        sheen: false,
    )!;
    if (!has_environment_preparations(self) && !self.pending_texture_uploads.len()
        && !self.pending_copies.len() && !self.pending_upload_retire.len()) return;
    return submit_pending(self);
}

fn EnvironmentRes*? ensure_environment(
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
            texture = ensure_texture(renderer, description.source)!;
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
    bool same_source = current.asset.index == environment.index
      && current.asset.generation == environment.generation && current.source_ready
      && current.description.kind == description.kind
      && current.description.source.index == description.source.index
      && current.description.source.generation == description.source.generation
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
    bool new_source;
    bool new_lighting;
    bool new_sheen;
    defer catch {
        if (new_source) release_environment_source(&renderer.device, &result);
        if (new_lighting) release_environment_lighting(&renderer.device, &result);
        if (new_sheen) release_environment_sheen(&renderer.device, &result);
    }
    if (!same_source) {
        result = {
            .asset = environment,
            .source_revision = source_revision,
            .source_binding_revision = source_binding_revision,
            .source_size = source_size,
            .source_owned = source_owned,
        };
        if (source_owned) {
            create_environment_cube(renderer, &result, false)!;
            new_source = true;
        } else {
            result.source_cube = texture.texture;
            result.source_view = texture.view;
        }
        result.source_ready = true;
    }
    result.description = description;
    result.revision = record.header.revision;
    if (lighting && !same_lighting) {
        result.specular_cube = {};
        result.specular_view = {};
        result.irradiance = {};
        result.irradiance_address = (gpu::GpuAddress)0;
        create_environment_cube(renderer, &result, true)!;
        new_lighting = true;
        gpu::AllocationDesc allocation_desc = {
            .size = IrradianceGpu::size,
            .alignment = STREAM_ALIGNMENT,
            .memory_class = gpu::MemoryClass.GPU_PRIVATE,
            .access = { .graphics },
            .debug_name = "environment_irradiance",
        };
        result.irradiance = gpu::allocate_memory(&renderer.device, &allocation_desc)!;
        result.irradiance_address = gpu::get_span_address(
            &renderer.device, gpu::get_allocation_span(&renderer.device, result.irradiance)!,
        )!;
        ensure_environment_lut(renderer)!;
        result.lighting_ready = true;
    } else if (!same_lighting) {
        result.lighting_ready = false;
    }
    if (sheen && !same_sheen) {
        result.sheen_cube = {};
        result.sheen_view = {};
        create_environment_sheen(renderer, &result)!;
        new_sheen = true;
        ensure_sheen_lut(renderer)!;
        result.sheen_ready = true;
    } else if (!same_sheen) {
        result.sheen_cube = {};
        result.sheen_view = {};
        result.sheen_ready = false;
    }
    ensure_environment_samplers(renderer)!;
    if (!pending.active) renderer.stats.environment_prepares++;
    pending.active = true;
    pending.result = result;
    pending.new_source |= new_source;
    pending.new_lighting |= new_lighting;
    pending.new_sheen |= new_sheen;
    if (texture) pending.input_texture = texture.view.index;
    return &pending.result;
}

fn void? create_environment_cube(Renderer* renderer, EnvironmentRes* result, bool specular) @local {
    gpu::TextureDesc description = {
        .width = specular ? result.description.settings.specular_size : result.source_size,
        .height = specular ? result.description.settings.specular_size : result.source_size,
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
    if (specular) {
        result.specular_cube = texture;
        result.specular_view = view;
    } else {
        result.source_cube = texture;
        result.source_view = view;
    }
}

fn void? ensure_environment_samplers(Renderer* renderer) @local {
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

fn void release_environment_source(gpu::Device* device, EnvironmentRes* result) @private {
    if (!result.source_owned) return;
    if (result.source_view.is_valid()) (void)gpu::destroy_texture_view(device, result.source_view);
    if (result.source_cube.is_valid()) (void)gpu::destroy_texture(device, result.source_cube);
}

fn void release_environment_lighting(gpu::Device* device, EnvironmentRes* result) @private {
    if (result.specular_view.is_valid()) (void)gpu::destroy_texture_view(device, result.specular_view);
    if (result.specular_cube.is_valid()) (void)gpu::destroy_texture(device, result.specular_cube);
    if (result.irradiance.is_valid()) (void)gpu::free_allocation(device, &result.irradiance);
}

fn void retire_environment_source(RetireList* retire, EnvironmentRes* result) @local {
    if (!result.source_owned || !result.source_cube.is_valid()) return;
    retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = result.source_view });
    retire.push({ .kind = RetiredKind.TEXTURE, .texture = result.source_cube });
}

fn void retire_environment_lighting(RetireList* retire, EnvironmentRes* result) @local {
    if (result.specular_cube.is_valid()) {
        retire.push({ .kind = RetiredKind.TEXTURE_VIEW, .texture_view = result.specular_view });
        retire.push({ .kind = RetiredKind.TEXTURE, .texture = result.specular_cube });
    }
    if (result.irradiance.is_valid()) retire.push({ .kind = RetiredKind.ALLOCATION, .allocation = result.irradiance });
}

fn bool has_environment_preparations(Renderer* renderer) @private {
    if (renderer.environment_state.sheen_lut_state == EnvironmentLutState.PENDING
        || renderer.environment_state.sheen_lut_state == EnvironmentLutState.RECORDED) return true;
    if (renderer.environment_state.brdf_state == EnvironmentLutState.PENDING
        || renderer.environment_state.brdf_state == EnvironmentLutState.RECORDED) return true;
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
    if (renderer.environment_state.brdf_state == EnvironmentLutState.RECORDED) {
        renderer.environment_state.brdf_state = EnvironmentLutState.READY;
    }
    if (renderer.environment_state.sheen_lut_state == EnvironmentLutState.RECORDED) {
        renderer.environment_state.sheen_lut_state = EnvironmentLutState.READY;
    }
    foreach (retired : renderer.environment_state.temporaries) slot.environment_temporaries.push(retired);
    renderer.environment_state.temporaries.clear();
}

fn void discard_environment_preparations(Renderer* renderer) @private {
    drain_retired(&renderer.device, &renderer.environment_state.temporaries);
    foreach (&pending : renderer.environment_state.pending) {
        if (!pending.active) continue;
        if (pending.new_source) release_environment_source(&renderer.device, &pending.result);
        if (pending.new_lighting) release_environment_lighting(&renderer.device, &pending.result);
        if (pending.new_sheen) release_environment_sheen(&renderer.device, &pending.result);
        *pending = {};
    }
    if (renderer.environment_state.sheen_lut_state == EnvironmentLutState.PENDING
        || renderer.environment_state.sheen_lut_state == EnvironmentLutState.RECORDED) {
        release_sheen_lut(renderer);
    }
    if (renderer.environment_state.brdf_state == EnvironmentLutState.PENDING
        || renderer.environment_state.brdf_state == EnvironmentLutState.RECORDED) {
        (void)gpu::destroy_texture_view(&renderer.device, renderer.environment_state.brdf_view);
        (void)gpu::destroy_texture(&renderer.device, renderer.environment_state.brdf_texture);
        renderer.environment_state.brdf_view = {};
        renderer.environment_state.brdf_texture = {};
        renderer.environment_state.brdf_state = EnvironmentLutState.NONE;
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
    if (renderer.environment_state.brdf_state == EnvironmentLutState.READY) {
        (void)gpu::destroy_texture_view(&renderer.device, renderer.environment_state.brdf_view);
        (void)gpu::destroy_texture(&renderer.device, renderer.environment_state.brdf_texture);
    }
    if (renderer.environment_state.sheen_lut_state == EnvironmentLutState.READY) release_sheen_lut(renderer);
    gpu::PipelineHandle[7] pipelines = {
        renderer.environment_state.pipelines.source, renderer.environment_state.pipelines.prefilter,
        renderer.environment_state.pipelines.project, renderer.environment_state.pipelines.reduce,
        renderer.environment_state.pipelines.brdf, renderer.environment_state.pipelines.sheen_prefilter,
        renderer.environment_state.pipelines.sheen_lut,
    };
    foreach (pipeline : pipelines) if (pipeline.is_valid()) (void)gpu::destroy_pipeline(&renderer.device, pipeline);
    renderer.environment_state.temporaries.free();
    alloc::free(renderer.allocator, renderer.environment_state.pending.ptr);
    alloc::free(renderer.allocator, renderer.environment_state.mirrors.ptr);
}
