module c3d::light;

import std::math;

<* Maximum cascades in one directional shadow request. *>
const uint MAX_SHADOW_CASCADES = 4; // four split depths occupy 16 bytes per light on the CPU

<* Default directional shadow coverage and bias. *>
const ShadowSettings SHADOW_SETTINGS_DEFAULT = {
    .enabled = true,
    .priority = 0,
    .bias = 0.0005f,
    .normal_bias = 0.02f,
    .cascades = MAX_SHADOW_CASCADES,
    .cascade_lambda = 0.8f,
    .max_distance = 100,
};

<* Shadow settings with camera-depth max_distance and world-unit normal_bias. *>
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
 Check the programming contract for enabled shadow settings.
 @param [&in] self : "Current light settings."
 @require !self.enabled || (self.cascades >= 1 && self.cascades <= MAX_SHADOW_CASCADES)
 @require !self.enabled || (self.bias >= 0 && math::is_finite(self.bias))
 @require !self.enabled || (self.normal_bias >= 0 && math::is_finite(self.normal_bias))
 @require !self.enabled || (self.cascade_lambda >= 0 && self.cascade_lambda <= 1)
 @require !self.enabled || (self.max_distance > 0 && math::is_finite(self.max_distance))
*>
fn void ShadowSettings.validate(&self) {}
