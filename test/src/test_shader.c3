module c3d::test::shader;

import c3d;
import c3d::shader;

const char[4] SPIRV_MAGIC_BYTES = { 0x03, 0x02, 0x23, 0x07 };
const usz SPIRV_HEADER_WORDS @private = 5;
const uint SPIRV_OP_NAME @private = 5;                                // OpName
const uint SPIRV_OP_EXTENSION @private = 10;                          // OpExtension
const uint SPIRV_OP_CAPABILITY @private = 17;                         // OpCapability
const uint SPIRV_CAPABILITY_RAY_QUERY_PROVISIONAL @private = 4471;    // RayQueryProvisionalKHR
const uint SPIRV_CAPABILITY_RAY_QUERY @private = 4472;                // RayQueryKHR
const uint SPIRV_CAPABILITY_RAY_TRAVERSAL_CULLING @private = 4478;    // RayTraversalPrimitiveCullingKHR
const uint SPIRV_CAPABILITY_RAY_TRACING @private = 4479;              // RayTracingKHR

struct SpirvFeatures @private {
    bool ray_capability;
    bool ray_query_capability;
    bool ray_extension;
    bool ray_query_extension;
}

fn void test_every_manifest_entry_resolves_to_spirv() @test {
    foreach (&entry : shader::SHADER_ENTRIES) {
        char[] spirv = shader::BUILTIN_REGISTRY.get(entry.variant)!!;
        assert(spirv.len >= SPIRV_MAGIC_BYTES.len);
        assert(spirv.len % 4 == 0);
        foreach (index, expected : SPIRV_MAGIC_BYTES) assert(spirv[index] == expected);
    }
}

fn void test_probe_trace_variants_differ_by_trace_flag() @test {
    char[] ray_query = shader::BUILTIN_REGISTRY.get({ .shader = PROBE_TRACE })!!;
    ShaderVariant software_variant = { .shader = PROBE_TRACE, .flags = shader::SHADER_FLAG_SCENE_TRACE_BVH };
    char[] software = shader::BUILTIN_REGISTRY.get(software_variant)!!;
    assert(!(ray_query.len == software.len && mem::equals(ray_query.ptr, software.ptr, (sz)ray_query.len)));
}

fn void test_unlisted_variant_faults_shader_not_found() @test {
    shader::ShaderRegistry registry = { .entries = shader::SHADER_ENTRIES[:1] };
    if (catch excuse = registry.get(shader::SHADER_ENTRIES[1].variant)) {
        assert(excuse == c3d::SHADER_NOT_FOUND);
        return;
    }
    assert(false, "a variant outside the registry resolved");
}

fn void test_every_include_is_named_once() @test {
    foreach (index, &include : shader::SHADER_INCLUDES) {
        assert(include.name.len > 0 && include.text.len > 0);
        foreach (other : shader::SHADER_INCLUDES[:index]) assert(other.name != include.name);
    }
    bool has_abi;
    bool has_heap;
    foreach (&include : shader::SHADER_INCLUDES) {
        has_abi |= include.name == "c3d_abi.glsl";
        has_heap |= include.name == "descriptor_heap.glsl";
    }
    assert(has_abi && has_heap);
}

fn uint spirv_word(char[] spirv, usz word) @private {
    usz byte = word * 4;
    return (uint)spirv[byte] | (uint)spirv[byte + 1] << 8 | (uint)spirv[byte + 2] << 16 | (uint)spirv[byte + 3] << 24;
}

fn SpirvFeatures spirv_ray_features(char[] spirv) @private {
    SpirvFeatures features;
    usz word_count = spirv.len / 4;
    usz word = SPIRV_HEADER_WORDS;
    while (word < word_count) {
        uint instruction = spirv_word(spirv, word);
        uint length = instruction >> 16;
        uint opcode = instruction & 0xFFFF;
        if (opcode == SPIRV_OP_CAPABILITY) {
            uint capability = spirv_word(spirv, word + 1);
            features.ray_query_capability |= capability == SPIRV_CAPABILITY_RAY_QUERY;
            features.ray_capability |= capability == SPIRV_CAPABILITY_RAY_QUERY_PROVISIONAL
                || capability == SPIRV_CAPABILITY_RAY_QUERY || capability == SPIRV_CAPABILITY_RAY_TRAVERSAL_CULLING
                || capability == SPIRV_CAPABILITY_RAY_TRACING;
        }
        if (opcode == SPIRV_OP_EXTENSION) {
            ZString name = (ZString)&spirv[(word + 1) * 4];
            String extension = name.str_view();
            features.ray_query_extension |= extension == "SPV_KHR_ray_query";
            features.ray_extension |= extension == "SPV_KHR_ray_query" || extension == "SPV_KHR_ray_tracing";
        }
        word += length;
    }
    return features;
}

fn void test_registry_holds_the_software_trace_variants() @test {
    uint shadow_flags = shader::SHADER_FLAG_RT_SHADOWS | shader::SHADER_FLAG_SCENE_TRACE_BVH;
    ShaderVariant[6] variants = {
        { .shader = STANDARD, .flags = shadow_flags },
        { .shader = PHYSICAL, .flags = shadow_flags },
        { .shader = TOON, .flags = shadow_flags },
        { .shader = LIGHTING_RESOLVE, .flags = shadow_flags },
        { .shader = RT_AO, .flags = shader::SHADER_FLAG_SCENE_TRACE_BVH },
        { .shader = RT_REFLECTIONS, .flags = shader::SHADER_FLAG_SCENE_TRACE_BVH },
    };
    foreach (variant : variants) shader::BUILTIN_REGISTRY.get(variant)!!;
    ShaderVariant walk_alone = { .shader = STANDARD, .flags = shader::SHADER_FLAG_SCENE_TRACE_BVH };
    if (catch excuse = shader::BUILTIN_REGISTRY.get(walk_alone)) {
        assert(excuse == c3d::SHADER_NOT_FOUND);
        return;
    }
    assert(false, "the software walk resolved without traced shadows");
}

fn void test_software_trace_variants_declare_no_ray_capability() @test {
    SpirvFeatures hardware = spirv_ray_features(shader::BUILTIN_REGISTRY.get({ .shader = RT_AO })!!);
    assert(hardware.ray_query_capability && hardware.ray_query_extension);
    usz software_count;
    foreach (&entry : shader::SHADER_ENTRIES) {
        if ((entry.variant.flags & shader::SHADER_FLAG_SCENE_TRACE_BVH) == 0) continue;
        SpirvFeatures features = spirv_ray_features(entry.spirv);
        assert(!features.ray_capability && !features.ray_extension);
        software_count++;
    }
    assert(software_count == 7);
}

// glslang names a function by its signature, so the name up to the parenthesis is the function.
fn bool spirv_names_function(char[] spirv, String function) @local {
    usz word_count = spirv.len / 4;
    usz word = SPIRV_HEADER_WORDS;
    while (word < word_count) {
        uint instruction = spirv_word(spirv, word);
        uint length = instruction >> 16;
        if ((instruction & 0xFFFF) == SPIRV_OP_NAME) {
            String name = ((ZString)&spirv[(word + 2) * 4]).str_view();
            if (name.len > function.len && name[function.len] == '(' && name.starts_with(function)) return true;
        }
        word += length;
    }
    return false;
}

fn void test_builtin_standard_shades_through_the_public_include() @test {
    usz standard_count;
    usz resolve_count;
    foreach (&entry : shader::SHADER_ENTRIES) {
        if (entry.variant.shader == ShaderName.STANDARD) {
            assert(spirv_names_function(entry.spirv, "shade_standard_surface"));
            standard_count++;
        }
        if (entry.variant.shader == ShaderName.LIGHTING_RESOLVE) {
            assert(spirv_names_function(entry.spirv, "evaluate_standard_lights"));
            assert(spirv_names_function(entry.spirv, "standard_ambient_fill"));
            resolve_count++;
        }
    }
    assert(standard_count > 0 && resolve_count > 0);
}

module c3d::test::shader_compile @feat(C3D_SHADER_COMPILER);

import c3d::shader;
import c3d::shader::compile;

const char[4] SPIRV_MAGIC = { 0x03, 0x02, 0x23, 0x07 };

const String LIT_FRAGMENT = `#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
layout(location = 0) out vec4 out_color;
layout(push_constant) uniform Push { uint64_t vertex_root_gpu; uint64_t fragment_root_gpu; } pc;
void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
#ifdef DEPTH_ONLY
    out_color = vec4(material.alpha_cutoff);
#else
    out_color = vec4(float(material.map_flags)) + undefined_symbol;
#endif
}
`;

fn void test_compile_glsl_resolves_embedded_includes() @test {
    String log;
    char[] spirv = compile::compile_glsl(
        allocator:  mem,
        source:     LIT_FRAGMENT,
        stage:      ShaderStage.FRAGMENT,
        defines:    { "DEPTH_ONLY" },
        debug_name: "lit",
        log:        &log,
    )!!;
    defer free(spirv.ptr);
    defer free(log.ptr);
    assert(spirv.len >= SPIRV_MAGIC.len && spirv.len % 4 == 0);
    foreach (index, expected : SPIRV_MAGIC) assert(spirv[index] == expected);
}

const String PARTICLE_COMPUTE = `#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
layout(local_size_x = 64) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;
layout(buffer_reference, std430, buffer_reference_align = 16) buffer Particles { vec4 position_life[]; };
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer ParticleRoot { uint64_t particles; uint count; float delta; };
void main() {
    ParticleRoot root = ParticleRoot(DispatchRoot(pc.root_gpu).parameters);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;
    Particles(root.particles).position_life[index].y += root.delta;
}
`;

const String FOG_COMPUTE = `#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "descriptor_heap.glsl"
layout(local_size_x = 8, local_size_y = 8) in;
layout(push_constant) uniform Push { uint64_t root_gpu; } pc;
layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer FogRoot { vec4 color; uint width; uint height; };
void main() {
    DispatchRoot root = DispatchRoot(pc.root_gpu);
    DispatchTexturesGpu textures = DispatchTexturesGpu(root.textures);
    FogRoot fog = FogRoot(root.parameters);
    uvec2 coord = gl_GlobalInvocationID.xy;
    if (coord.x >= fog.width || coord.y >= fog.height) return;
    vec2 uv = (vec2(coord) + 0.5) / vec2(fog.width, fog.height);
    float depth = sample_texture_2d(textures.slots[0].texture_index, textures.slots[0].sampler_index, uv).r;
    vec4 color = load_storage_texture(textures.slots[1].texture_index, ivec2(coord));
    store_storage_texture(textures.slots[1].texture_index, ivec2(coord), mix(color, fog.color, depth));
}
`;

const String SCENE_SNAPSHOT_FRAGMENT = `#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "scene_snapshot.glsl"
layout(location = 0) out vec4 out_color;
layout(push_constant) uniform Push { uint64_t vertex_root_gpu; uint64_t fragment_root_gpu; } pc;
void main() {
    FrameRoot frame = FrameRoot(DrawRoot(pc.fragment_root_gpu).frame);
    vec2 uv = scene_uv(frame, gl_FragCoord.xy);
    vec3 position = scene_position_at(frame, uv);
    float gap = scene_depth_gap(frame, gl_FragCoord) + scene_view_distance_at(frame, uv);
    out_color = vec4(scene_color_at(frame, uv) + position, gap);
}
`;

fn void test_compile_glsl_compiles_the_scene_snapshot_helpers() @test {
    char[] spirv = compile::compile_glsl(mem, SCENE_SNAPSHOT_FRAGMENT, ShaderStage.FRAGMENT)!!;
    defer free(spirv.ptr);
    assert(spirv.len >= SPIRV_MAGIC.len && spirv.len % 4 == 0);
}

fn void test_compile_glsl_compiles_a_texture_compute_stage() @test {
    char[] spirv = compile::compile_glsl(mem, FOG_COMPUTE, ShaderStage.COMPUTE)!!;
    defer free(spirv.ptr);
    assert(spirv.len >= SPIRV_MAGIC.len && spirv.len % 4 == 0);
}

fn void test_compile_glsl_compiles_a_compute_stage() @test {
    char[] spirv = compile::compile_glsl(mem, PARTICLE_COMPUTE, ShaderStage.COMPUTE)!!;
    defer free(spirv.ptr);
    assert(spirv.len >= SPIRV_MAGIC.len && spirv.len % 4 == 0);
    foreach (index, expected : SPIRV_MAGIC) assert(spirv[index] == expected);
}

fn void test_compile_glsl_reports_failure() @test {
    String log;
    if (catch excuse = compile::compile_glsl(mem, LIT_FRAGMENT, ShaderStage.FRAGMENT, log: &log)) {
        defer free(log.ptr);
        assert(excuse == shader::SHADER_COMPILE_FAILED);
        assert(log.len > 0);
        return;
    }
    assert(false, "a fragment referencing an undefined symbol compiled");
}

fn void test_compile_glsl_rejects_unknown_include() @test {
    String log;
    String source = "#version 460\n#include \"not_embedded.glsl\"\nvoid main() {}\n";
    if (catch excuse = compile::compile_glsl(mem, source, ShaderStage.VERTEX, log: &log)) {
        defer free(log.ptr);
        assert(excuse == shader::SHADER_COMPILE_FAILED);
        return;
    }
    assert(false, "an include outside the embedded set resolved");
}
