module c3d::serial;

import c3d::describe;
import c3d::light;
import c3d::scene;
import std::math::vector;

const ulong SHADOW_SETTINGS_V1_LAYOUT @private = 0x79ccc384defd9804;
const ulong LIGHT_V1_LAYOUT @private = 0xa41c0d2284b8d046;
const ulong SHADOW_SETTINGS_LAYOUT @private = 0x5b9670e585ad3d26;
const ulong LIGHT_LAYOUT @private = 0x5884c8dac168c2c8;

struct ShadowSettingsV1 @private {
    bool enabled;
    int priority;
    float bias;
    float directional_normal_bias_texels;
    float punctual_normal_bias;
    uint cascades;
    float cascade_lambda;
    float cascade_blend;
    float max_distance;
    bool ray_traced;
}

struct LightV1 @private {
    LightKind kind;
    Vec3 color;
    float intensity;
    float range;
    float inner_cone;
    float outer_cone;
    uint layers;
    ShadowSettingsV1 shadow;
}

BinaryCompatibility[1] light_binary_compatibility @local = {
    { .version = 1, .read = &read_light_v1 },
};
uint[1] light_text_default_versions @local = { 1 };

fn void? register_light_codec() @private {
    describe::register_reflected(ShadowSettingsV1)!;
    describe::register_reflected(LightV1)!;
    register_described_type(
        $Type: ShadowSettingsV1,
        version: 1,
        layout: SHADOW_SETTINGS_V1_LAYOUT,
        defaults: &defaults_shadow_v1,
    )!;
    register_described_type(
        $Type: LightV1,
        version: 1,
        layout: LIGHT_V1_LAYOUT,
        defaults: &defaults_light_v1,
    )!;
    register_described_type(
        $Type: ShadowSettings,
        version: 2,
        layout: SHADOW_SETTINGS_LAYOUT,
        defaults: &defaults_shadow,
    )!;
    register_described_type(
        $Type: Light,
        version: 2,
        layout: LIGHT_LAYOUT,
        defaults: &defaults_light,
    )!;
    register_described(Light, {
        .name = "c3d.Light",
        .binary_compatibility = light_binary_compatibility[..],
        .text_default_versions = light_text_default_versions[..],
    })!;
}

fn void defaults_shadow_v1(void* value) @local {
    ShadowSettings source = light::SHADOW_SETTINGS_DEFAULT;
    *(ShadowSettingsV1*)value = {
        .enabled = source.enabled,
        .priority = source.priority,
        .bias = source.bias,
        .directional_normal_bias_texels = source.directional_normal_bias_texels,
        .punctual_normal_bias = source.punctual_normal_bias,
        .cascades = source.cascades,
        .cascade_lambda = source.cascade_lambda,
        .cascade_blend = source.cascade_blend,
        .max_distance = source.max_distance,
        .ray_traced = source.ray_traced,
    };
}

fn void defaults_light_v1(void* value) @local {
    *(LightV1*)value = { .kind = DIRECTIONAL, .color = { 1, 1, 1 }, .intensity = 1 };
}

fn void defaults_shadow(void* value) @local {
    *(ShadowSettings*)value = light::SHADOW_SETTINGS_DEFAULT;
}

fn void defaults_light(void* value) @local {
    *(Light*)value = light::directional({ 1, 1, 1 }, 1);
}

fn void? read_light_v1(Reader* reader, ReadContext* context) @local {
    LightV1 source;
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();

    read_described_value(
        type: described_type(LightV1)!,
        reader: reader,
        context: context,
        owned: &owned,
        value: &source,
    )!;

    Light value = {
        .kind = source.kind,
        .color = source.color,
        .intensity = source.intensity,
        .range = source.range,
        .inner_cone = source.inner_cone,
        .outer_cone = source.outer_cone,
        .layers = source.layers,
        .shadow = {
            .enabled = source.shadow.enabled,
            .priority = source.shadow.priority,
            .bias = source.shadow.bias,
            .directional_normal_bias_texels = source.shadow.directional_normal_bias_texels,
            .punctual_normal_bias = source.shadow.punctual_normal_bias,
            .cascades = source.shadow.cascades,
            .cascade_lambda = source.shadow.cascade_lambda,
            .cascade_blend = source.shadow.cascade_blend,
            .max_distance = source.shadow.max_distance,
            .ray_traced = source.shadow.ray_traced,
            .colored_transmission = false,
        },
    };
    context.scene.add(context.node, value);
}
