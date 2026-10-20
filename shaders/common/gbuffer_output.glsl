#ifndef C3D_GBUFFER_OUTPUT_GLSL
#define C3D_GBUFFER_OUTPUT_GLSL

#include "gbuffer.glsl"
#include "standard_surface.glsl"
#include "trace_surface.glsl"

#ifdef REFLECTION_PREPASS
// The thin target the reflection pass reads: octahedral normal, roughness and specular weight.
// A view that also traces ambient occlusion binds the proxy skip word at location 0.
#ifdef PROXY_SKIP
#include "proxy_skip_output.glsl"
layout(location = 1) out vec4 out_reflection_surface;
#else
layout(location = 0) out vec4 out_reflection_surface;
#endif

void write_gbuffer(StandardMaterialSample material_sample, float specular_weight, DrawRoot draw) {
    out_reflection_surface = vec4(
        encode_octahedral(material_sample.normal),
        material_sample.roughness,
        specular_weight
    );
#ifdef PROXY_SKIP
    write_proxy_skip();
#endif
}
#else
layout(location = 0) out vec4 out_base_color_metallic;
layout(location = 1) out vec4 out_normal_roughness;
layout(location = 2) out vec4 out_emissive_specular;
layout(location = 3) out uint out_layers;
layout(location = 4) out uint out_flags;

void write_gbuffer(StandardMaterialSample material_sample, float specular_weight, DrawRoot draw) {
    out_base_color_metallic = vec4(material_sample.base_color.rgb, material_sample.metallic);
    out_normal_roughness = vec4(
        encode_octahedral(material_sample.normal),
        material_sample.roughness,
        material_sample.occlusion
    );
    out_emissive_specular = vec4(material_sample.emissive, specular_weight);
    out_layers = draw.layers;
    out_flags = ((draw.flags & DRAW_RECEIVE_SHADOW) != 0u ? GBUFFER_FLAG_RECEIVE_SHADOW : 0u)
        | gbuffer_pack_proxy_skip(trace_proxy_skip_height);
}
#endif

#endif
