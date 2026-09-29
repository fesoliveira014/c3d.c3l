#ifndef C3D_SHADER_PACKAGE_SURFACE_GLSL
#define C3D_SHADER_PACKAGE_SURFACE_GLSL

#include "standard_surface.glsl"

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer SurfaceParams {
    vec4 base_color;
    vec4 metallic_roughness_occlusion;
};

StandardMaterialSample package_surface(SurfaceParams params, vec3 normal, vec3 view_direction) {
    StandardMaterialSample surface_sample;
    surface_sample.base_color = params.base_color;
    surface_sample.metallic = params.metallic_roughness_occlusion.x;
    surface_sample.roughness = params.metallic_roughness_occlusion.y;
    surface_sample.occlusion = params.metallic_roughness_occlusion.z;
    surface_sample.emissive = vec3(0.0);
    surface_sample.normal = normal;
    surface_sample.offset_normal = normal;
    surface_sample.view_direction = view_direction;
    return surface_sample;
}

#endif
