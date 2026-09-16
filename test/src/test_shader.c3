module c3d::test::shader;

import c3d;
import c3d::shader;

const char[4] SPIRV_MAGIC_BYTES = { 0x03, 0x02, 0x23, 0x07 };

fn void test_every_manifest_entry_resolves_to_spirv() @test {
    foreach (&entry : shader::SHADER_ENTRIES) {
        char[] spirv = shader::BUILTIN_REGISTRY.get(entry.variant)!!;
        assert(spirv.len >= SPIRV_MAGIC_BYTES.len);
        assert(spirv.len % 4 == 0);
        foreach (index, expected : SPIRV_MAGIC_BYTES) assert(spirv[index] == expected);
    }
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
    ParticleRoot root = ParticleRoot(pc.root_gpu);
    uint index = gl_GlobalInvocationID.x;
    if (index >= root.count) return;
    Particles(root.particles).position_life[index].y += root.delta;
}
`;

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
