layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer PeelTransport {
    uint64_t frame;
    uint anchor;
    uint sampler_index;
    uint flags;
    uint level_count;
    uint levels[8];
    uint opaque_color;
    uint opaque_depth;
    uint unused0;
    uint unused1;
    uint unused2;
    uint unused3;
    vec4 environment;
};

FogTerms transparency_camera_terms(FrameRoot frame, vec2 uv, float depth) {
    return depth == 0.0 ? fog_background_terms(frame, uv)
        : fog_terms(frame, uv, reconstruct_world_position(frame, uv, depth));
}

FogTerms transparency_connecting(FrameRoot frame, vec2 uv, vec3 position, float depth) {
    SkyFogGpu sky = SkyFogGpu(frame.sky_fog);
    vec3 origin;
    vec3 direction;
    float near_distance;
    fog_view_ray(frame, position, origin, direction, near_distance);
    if (depth == 0.0) return height_fog_beyond(frame, sky, uv, origin, direction, near_distance);
    vec3 forward = -normalize(vec3(frame.view[0][2], frame.view[1][2], frame.view[2][2]));
    float far_distance = max(view_distance(frame, depth) / max(dot(direction, forward), 1e-4), near_distance);
    FogTerms near_terms = fog_terms(frame, uv, position);
    FogTerms far_terms = fog_segment(frame, sky, uv, origin, direction,
        fog_clip_start(frame, origin, direction), far_distance);
    return fog_between(near_terms, far_terms);
}

vec3 transparency_transfer(FogTerms terms, vec3 color) {
    return terms.transmittance * color + terms.inscatter;
}

vec3 transparency_filtered(FrameRoot frame, PeelTransport transport, Surface surface, vec2 uv) {
    float roughness = uintBitsToFloat(surface.padding1);
    if (roughness == 0.0) return scene_color_at(frame, uv);
    float ior = uintBitsToFloat(surface.padding2);
    float lod = min(float(transport.level_count - 1u),
        log2(max(frame.camera_params.z, frame.camera_params.w)) * roughness * clamp(2.0 * ior - 2.0, 0.0, 1.0));
    uint low = uint(floor(lod));
    uint high = min(low + 1u, transport.level_count - 1u);
    vec3 first = sample_texture_2d(transport.levels[low], transport.sampler_index, uv).rgb;
    vec3 second = sample_texture_2d(transport.levels[high], transport.sampler_index, uv).rgb;
    return mix(first, second, fract(lod));
}

vec3 transparency_fog_surface(Draw root, Surface surface, float depth) {
    PeelTransport transport = PeelTransport(root.transport);
    FrameRoot frame = FrameRoot(transport.frame);
    vec2 uv = gl_FragCoord.xy / frame.camera_params.zw;
    vec3 position = reconstruct_world_position(frame, uv, depth);
    vec2 sample_uv = uv + surface.plane.zw;
    bool outside = any(lessThan(sample_uv, vec2(0.0))) || any(greaterThan(sample_uv, vec2(1.0)));
    vec3 behind = outside ? transport.environment.rgb : transparency_filtered(frame, transport, surface, sample_uv);
    float anchor = outside ? 0.0 : scene_depth_at(frame, sample_uv);
    bool sorted = root.mode == 2u || root.mode == 3u || (transport.flags & 1u) != 0u;
    vec3 transferred = sorted ? fog_behind(frame, position, behind, anchor)
        : transparency_transfer(transparency_connecting(frame, uv, position, anchor), behind);
    vec3 surface_color = surface.color.rgb + surface.color.a * transferred;
    if (!sorted) return surface_color;
    return apply_material_fog(frame, position, surface_color,
        surface.padding0 == 2u ? MATERIAL_BLEND_ADDITIVE : 0u);
}

void transparency_fog_phase(Draw root) {
    PeelTransport transport = PeelTransport(root.transport);
    FrameRoot frame = FrameRoot(transport.frame);
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec2 uv = gl_FragCoord.xy / frame.camera_params.zw;
    vec3 raw = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(root.scene))], pixel, 0).rgb;
    float anchor = fetch_depth(transport.anchor, pixel);
    if (root.mode == 4u) {
        float near_depth = fetch_depth(root.selected, pixel);
        if (near_depth != 0.0) {
            vec3 position = reconstruct_world_position(frame, uv, near_depth);
            raw = transparency_transfer(transparency_connecting(frame, uv, position, anchor), raw);
            anchor = near_depth;
        }
    } else if (root.mode == 5u) {
        anchor = fetch_depth(transport.opaque_depth, pixel);
        raw = transparency_transfer(transparency_camera_terms(frame, uv, anchor), raw);
    } else if (root.mode == 6u) {
        float tail_depth = fetch_depth(root.selected, pixel);
        if (tail_depth != 0.0) {
            FogTerms camera = transparency_camera_terms(frame, uv, tail_depth);
            raw = (raw - camera.inscatter) / max(camera.transmittance, vec3(FOG_TRANSMITTANCE_FLOOR));
            anchor = tail_depth;
        } else {
            raw = texelFetch(gpu_texture_heap[nonuniformEXT(GPU_HEAP_SLOT(transport.opaque_color))], pixel, 0).rgb;
            anchor = fetch_depth(transport.opaque_depth, pixel);
        }
    } else {
        raw = transparency_transfer(transparency_camera_terms(frame, uv, anchor), raw);
    }
    radiance = vec4(raw, 1.0);
    shade_depth = anchor;
}
