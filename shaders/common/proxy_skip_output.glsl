#ifndef C3D_PROXY_SKIP_OUTPUT_GLSL
#define C3D_PROXY_SKIP_OUTPUT_GLSL

#include "gbuffer.glsl"
#include "trace_surface.glsl"

layout(location = 0) out uint out_proxy_skip;

void write_proxy_skip() {
    out_proxy_skip = gbuffer_pack_proxy_skip(trace_proxy_skip_height);
}

#endif
