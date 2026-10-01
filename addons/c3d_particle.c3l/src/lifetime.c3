module c3d::particle;

import std::math;

<*
 Sample a scalar lifetime multiplier.
 @param life : "Normalized lifetime in [0, 1]."
 @require life >= 0 && life <= 1
 @pure
*>
fn float LifetimeTable.sample(&self, float life) {
    float position = life * (LIFETIME_TABLE_ENTRIES - 1);
    uint first = math::min((uint)position, LIFETIME_TABLE_ENTRIES - 2);
    float fraction = position - (float)first;
    return self.values[first] * (1 - fraction) + self.values[first + 1] * fraction;
}

<*
 Sample a colour lifetime multiplier.
 @param life : "Normalized lifetime in [0, 1]."
 @require life >= 0 && life <= 1
 @pure
*>
fn Vec4 LifetimeColorTable.sample(&self, float life) {
    float position = life * (LIFETIME_TABLE_ENTRIES - 1);
    uint first = math::min((uint)position, LIFETIME_TABLE_ENTRIES - 2);
    float fraction = position - (float)first;
    return self.values[first] * (1 - fraction) + self.values[first + 1] * fraction;
}
