module c3d::shader;

import c3d;

<*
 The stages compiled from the manifest.
*>
const ShaderRegistry BUILTIN_REGISTRY = { .entries = SHADER_ENTRIES[..] };

<*
 Which compiled stage a pipeline stage selects.
*>
bitstruct ShaderVariant : uint {
    ShaderName shader : 0..7;
    uint       flags  : 8..31;
}

<*
 One compiled stage and the variant that selects it.
*>
struct ShaderEntry {
    ShaderVariant variant;
    char[]        spirv;
}

<*
 Compiled stages pipelines are built from.
*>
struct ShaderRegistry {
    ShaderEntry[] entries;
}

<*
 SPIR-V of the stage the variant selects.
 @return? c3d::SHADER_NOT_FOUND
*>
fn char[]? ShaderRegistry.get(&self, ShaderVariant variant) {
    foreach (&entry : self.entries) {
        if ((uint)entry.variant == (uint)variant) return entry.spirv;
    }
    return c3d::SHADER_NOT_FOUND~;
}
