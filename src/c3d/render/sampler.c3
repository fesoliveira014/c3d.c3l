module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;
import gpu;

<*
 Store sampler resolved to a device-owned interned index.
*>
struct SamplerRes {
    SamplerId asset;
    uint revision;
    gpu::SamplerIndex index;
}

<*
 Intern the current sampler description on the device.
 @param [&inout] self : "Owns the interned index until device destruction."
 @return? c3d::INVALID_ID
 @return? gpu::intern_sampler!
*>
fn void? Renderer.upload_sampler(&self, SamplerId sampler) {
    if (!self.assets.samplers.is_live(sampler)) return c3d::INVALID_ID~;

    ensure_sampler(self, sampler)!;
}

fn SamplerRes*? ensure_sampler(Renderer* renderer, SamplerId sampler) @private {
    SamplerAsset* record = renderer.assets.sampler(sampler);
    SamplerRes* mirror = &renderer.samplers[sampler.index];
    bool same_asset = mirror.asset.index == sampler.index && mirror.asset.generation == sampler.generation;
    if (same_asset && mirror.revision == record.header.revision) return mirror;

    bool anisotropic = record.desc.anisotropy_enable && renderer.caps.max_sampler_anisotropy > 0;
    float anisotropy = record.desc.max_anisotropy > renderer.caps.max_sampler_anisotropy
        ? renderer.caps.max_sampler_anisotropy : record.desc.max_anisotropy;
    gpu::SamplerDesc description = {
        .min_filter = (gpu::Filter)record.desc.min_filter.ordinal,
        .mag_filter = (gpu::Filter)record.desc.mag_filter.ordinal,
        .mip_filter = (gpu::Filter)record.desc.mip_filter.ordinal,
        .address_u = (gpu::AddressMode)record.desc.address_u.ordinal,
        .address_v = (gpu::AddressMode)record.desc.address_v.ordinal,
        .address_w = (gpu::AddressMode)record.desc.address_w.ordinal,
        .max_lod = (float)(TEXTURE_MIP_CAPACITY - 1),
        .anisotropy_enable = anisotropic,
        .max_anisotropy = anisotropy,
        .compare_enable = record.desc.compare_enable,
        .compare = (gpu::CompareOp)record.desc.compare.ordinal,
        .debug_name = record.desc.debug_name,
    };
    gpu::SamplerIndex index = gpu::intern_sampler(&renderer.device, &description)!;
    *mirror = { .asset = sampler, .revision = record.header.revision, .index = index };

    return mirror;
}

fn void sweep_samplers(Renderer* renderer) @private {
    foreach (&mirror : renderer.samplers) {
        if (!mirror.asset.generation || renderer.assets.samplers.is_live(mirror.asset)) continue;
        *mirror = {};
    }
}
