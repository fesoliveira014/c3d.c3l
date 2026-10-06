module c3d::light;

import std::math;

<* Maximum cascades in one directional shadow request. *>
const uint MAX_SHADOW_CASCADES = 4; // each cascade consumes one atlas layer and one depth pass

<* Default directional normal offset in texels of each cascade. *>
const float DEFAULT_DIRECTIONAL_NORMAL_BIAS_TEXELS = 2; // 3x3 filter reach: clears every slope; casters thinner than the offset vanish

<* Default spot and point normal offset in metres. *>
const float DEFAULT_PUNCTUAL_NORMAL_BIAS = 0.02f; // metres; two texels of a 2048-texel 45 degree spot at 10 m

<* Default shadow coverage and bias for each light kind. *>
const ShadowSettings SHADOW_SETTINGS_DEFAULT = {
    .enabled = true,
    .priority = 0,
    .bias = 0.0005f,
    .directional_normal_bias_texels = DEFAULT_DIRECTIONAL_NORMAL_BIAS_TEXELS,
    .punctual_normal_bias = DEFAULT_PUNCTUAL_NORMAL_BIAS,
    .cascades = MAX_SHADOW_CASCADES,
    .cascade_lambda = 0.8f,
    .cascade_blend = 0.1f,
    .max_distance = 100,
};

<* Shadow settings with kind-dependent coverage and normal offset. *>
struct ShadowSettings {
    bool enabled;
    int priority;
    float bias;
    float directional_normal_bias_texels; // directional lights only, texels of each cascade; others ignore it
    float punctual_normal_bias; // spot and point lights only, metres; directional lights ignore it
    uint cascades;
    float cascade_lambda;
    float cascade_blend;   // directional: blend band per cascade, a fraction of its depth span
    float max_distance;
    bool ray_traced;
}

<*
 Check the programming contract for this light's enabled shadows.
 @require !self.shadow.enabled || (self.shadow.bias >= 0 && math::is_finite(self.shadow.bias))
 @require !self.shadow.enabled || self.kind != DIRECTIONAL || (self.shadow.directional_normal_bias_texels >= 0 && math::is_finite(self.shadow.directional_normal_bias_texels))
 @require !self.shadow.enabled || self.kind == DIRECTIONAL || (self.shadow.punctual_normal_bias >= 0 && math::is_finite(self.shadow.punctual_normal_bias))
 @require !self.shadow.enabled || self.kind != DIRECTIONAL || (self.shadow.cascades >= 1 && self.shadow.cascades <= MAX_SHADOW_CASCADES)
 @require !self.shadow.enabled || self.kind != DIRECTIONAL || (self.shadow.cascade_lambda >= 0 && self.shadow.cascade_lambda <= 1)
 @require !self.shadow.enabled || self.kind != DIRECTIONAL || (self.shadow.cascade_blend >= 0 && self.shadow.cascade_blend <= 0.5)
 @require !self.shadow.enabled || self.kind == DIRECTIONAL || (self.range >= 0 && math::is_finite(self.range))
 @require !self.shadow.enabled || (self.kind != DIRECTIONAL && self.range > 0) || (self.shadow.max_distance > 0 && math::is_finite(self.shadow.max_distance))
 @require !self.shadow.enabled || self.kind != SPOT || (self.outer_cone > 0 && self.outer_cone < (float)math::PI / 2)
*>
fn void Light.validate_shadow(&self) {}
