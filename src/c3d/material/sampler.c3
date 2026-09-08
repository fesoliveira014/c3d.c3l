module c3d::material;

<*
 Texel filtering; same order as the device enum.
*>
enum Filter {
    NEAREST,
    LINEAR,
}

<*
 Coordinate wrapping outside [0, 1]; same order as the device enum.
*>
enum AddressMode {
    REPEAT,
    MIRRORED_REPEAT,
    CLAMP_TO_EDGE,
    CLAMP_TO_BORDER,
}

<*
 Depth comparison of a shadow sampler; same order as the device enum.
*>
enum CompareOp {
    NEVER,
    LESS,
    EQUAL,
    LESS_EQUAL,
    GREATER,
    NOT_EQUAL,
    GREATER_EQUAL,
    ALWAYS,
}

<*
 Device-independent sampler description.
*>
struct SamplerDesc {
    Filter      min_filter;
    Filter      mag_filter;
    Filter      mip_filter;
    AddressMode address_u;
    AddressMode address_v;
    AddressMode address_w;
    bool        anisotropy_enable;
    float       max_anisotropy;
    bool        compare_enable;
    CompareOp   compare;
    ZString     debug_name;
}

<*
 Sampler with one filter for every stage and one address mode on every axis.
*>
fn SamplerDesc sampler_desc(Filter filter, AddressMode address, ZString debug_name = "") {
    return {
        .min_filter = filter,
        .mag_filter = filter,
        .mip_filter = filter,
        .address_u  = address,
        .address_v  = address,
        .address_w  = address,
        .debug_name = debug_name,
    };
}
