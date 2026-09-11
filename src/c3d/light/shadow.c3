module c3d::light;

import std::math;

<* Maximum cascades in one directional shadow request. *>
const uint MAX_SHADOW_CASCADES = 4; // each cascade consumes one atlas layer and one depth pass

<* Default shadow coverage and bias for each light kind. *>
const ShadowSettings SHADOW_SETTINGS_DEFAULT = {
    .enabled = true,
    .priority = 0,
    .bias = 0.0005f,
    .normal_bias = 0.02f,
    .cascades = MAX_SHADOW_CASCADES,
    .cascade_lambda = 0.8f,
    .max_distance = 100,
};

<* Shadow settings with kind-dependent coverage and world-unit normal_bias. *>
struct ShadowSettings {
    bool enabled;
    int priority;
    float bias;
    float normal_bias;
    uint cascades;
    float cascade_lambda;
    float max_distance;
}

<*
 Check the programming contract for this light's enabled shadows.
 @require !self.shadow.enabled || (self.shadow.bias >= 0 && math::is_finite(self.shadow.bias))
 @require !self.shadow.enabled || (self.shadow.normal_bias >= 0 && math::is_finite(self.shadow.normal_bias))
 @require !self.shadow.enabled || self.kind != DIRECTIONAL || (self.shadow.cascades >= 1 && self.shadow.cascades <= MAX_SHADOW_CASCADES)
 @require !self.shadow.enabled || self.kind != DIRECTIONAL || (self.shadow.cascade_lambda >= 0 && self.shadow.cascade_lambda <= 1)
 @require !self.shadow.enabled || self.kind == DIRECTIONAL || (self.range >= 0 && math::is_finite(self.range))
 @require !self.shadow.enabled || (self.kind != DIRECTIONAL && self.range > 0) || (self.shadow.max_distance > 0 && math::is_finite(self.shadow.max_distance))
 @require !self.shadow.enabled || self.kind != SPOT || (self.outer_cone > 0 && self.outer_cone < (float)math::PI / 2)
*>
fn void Light.validate_shadow(&self) {}
