module c3d::shader::compile @feat(C3D_SHADER_COMPILER);

import c3d::asset;
import c3d::shader;
import shaderc;

<*
 Pipeline stage a GLSL source is compiled as.
*>
enum ShaderStage {
    VERTEX,
    FRAGMENT,
    COMPUTE,
}

const String MISSING_INCLUDE_MESSAGE @private = "include is in neither the embedded nor the caller's include set";
const String EMPTY_SOURCE_NAME @private = "";

<*
 Compile GLSL to SPIR-V with the embedded and the caller's includes.
 @param allocator : "Owns the returned bytes and the log."
 @param source : "GLSL with #version."
 @param defines : "Names defined as 1, in order."
 @param debug_name : "Names the source in compiler messages."
 @param [out] log : "Compiler messages allocated with allocator; empty when clean. Null discards them."
 @param includes : "Searched after SHADER_INCLUDES, in order; borrowed for the call."
 @return? shader::SHADER_COMPILE_FAILED
*>
fn char[]? compile_glsl(
    Allocator allocator,
    String source,
    ShaderStage stage,
    String[] defines = {},
    String debug_name = "custom",
    String* log = null,
    asset::ShaderInclude[] includes = {},
) {
    shaderc::Compiler compiler = shaderc::compiler_create();
    defer compiler.release();
    shaderc::CompileOptions options = shaderc::options_create();
    defer options.release();
    options.set_target_env(shaderc::TargetEnv.TARGET_ENV_VULKAN, shaderc::EnvVersion.ENV_VERSION_VULKAN_1_3);
    options.set_target_spirv(shaderc::SpirvVersion.SPIRV_VERSION_1_5);
    options.set_optimization_level(shaderc::OptimizationLevel.OPTIMIZATION_LEVEL_ZERO);
    options.set_include_callbacks(&resolve_include, &release_include, &includes);
    foreach (define : defines) options.add_macro_definition(define.ptr, define.len, "1", 1);

    shaderc::Result result;
    @pool() {
        ZString name = debug_name.zstr_tcopy();
        result = compiler.compile_into_spv(
            source.ptr,
            source.len,
            shader_kind(stage),
            (char*)name,
            "main",
            options,
        );
    };
    defer result.release();

    if (log) *log = ((ZString)result.get_error_message()).str_view().copy(allocator);
    if (result.get_compilation_status() != shaderc::CompilationStatus.COMPILATION_STATUS_SUCCESS) {
        return shader::SHADER_COMPILE_FAILED~;
    }
    usz length = result.get_length();
    char[] spirv = alloc::new_array(allocator, char, (sz)length);
    mem::copy(spirv.ptr, result.get_bytes(), (sz)length);
    return spirv;
}

fn shaderc::ShaderKind shader_kind(ShaderStage stage) @private {
    switch (stage) {
        case VERTEX: return shaderc::ShaderKind.VERTEX_SHADER;
        case FRAGMENT: return shaderc::ShaderKind.FRAGMENT_SHADER;
        case COMPUTE: return shaderc::ShaderKind.COMPUTE_SHADER;
    }
}

fn shaderc::IncludeResult* resolve_include(
    void* user_data,
    char* requested_source,
    shaderc::IncludeType type,
    char* requesting_source,
    usz include_depth,
) @private {
    String requested = ((ZString)requested_source).str_view();
    shaderc::IncludeResult* result = mem::new(shaderc::IncludeResult);
    asset::ShaderInclude[][2] tables = { shader::SHADER_INCLUDES[..], *(asset::ShaderInclude[]*)user_data };
    foreach (table : tables) {
        foreach (&include : table) {
            if (include.name != requested) continue;
            *result = {
                .source_name        = include.name.ptr,
                .source_name_length = include.name.len,
                .content            = include.text.ptr,
                .content_length     = include.text.len,
            };
            return result;
        }
    }
    *result = {
        .source_name    = EMPTY_SOURCE_NAME.ptr,
        .content        = MISSING_INCLUDE_MESSAGE.ptr,
        .content_length = MISSING_INCLUDE_MESSAGE.len,
    };
    return result;
}

fn void release_include(void* user_data, shaderc::IncludeResult* include_result) @private {
    free(include_result);
}
