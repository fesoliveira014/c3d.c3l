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
